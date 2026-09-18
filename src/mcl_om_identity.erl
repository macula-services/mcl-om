%%% @doc Loads the service-principal cert at boot; identity + seed/opts
%%% resolution for the mesh pool `mcl_om_sup' supervises alongside
%%% this gen_server (piece A, `PLAN_MCL_OM_MESH_WRAPPERS.md').
%%%
%%% Each hecate-service has its OWN realm-signed credential (NOT a
%%% user's). The credential lives at /etc/hecate/secrets/service-cert.pem
%%% inside the container; the host mounts the per-service directory
%%% from `/etc/hecate/secrets/<service-name>/' onto that path.
%%%
%%% v1: long-lived realm-signed cert provisioned out-of-band by a
%%% realm-admin script. v2: short-lived UCAN auto-rotated from a
%%% realm HTTP endpoint. The v2 swap-in lands here without touching
%%% consumers.
%%%
%%% Connect-degradation: with no seeds configured, `mcl_om_sup'
%%% never starts a mesh pool child at all, and `macula_client/0'
%%% returns `{error, no_client}' forever -- consumers fall back to
%%% no-op behaviour, same contract as before this piece. The service
%%% stays up either way; it just doesn't talk to the mesh.
%%%
%%% **The pool itself is no longer this gen_server's state.** It used
%%% to be: a hand-rolled `self() ! connect' / 5s-retry / `erlang:
%%% monitor' + `DOWN' dance defending against a pool crash and an
%%% early-boot race against the `macula' OTP application not being up
%%% yet. Both turned out to be things `macula_client' and OTP already
%%% give for free once the pool is an ordinary supervised sibling
%%% (`mcl_om_sup', `restart => permanent'): each seed link dials
%%% and retries forever on its own timer without ever crashing the
%%% pool process for an unreachable seed (confirmed by reading
%%% `macula_client.erl' directly), so there is nothing for a hand-
%%% rolled monitor to catch that OTP's own restart doesn't already
%%% cover; and `mcl_om.app.src' already lists `macula' in
%%% `applications', so standard OTP boot ordering means `macula' has
%%% already finished starting before `mcl_om_app:start/2' -- and so
%%% this module's own `init/1' -- is ever called. `start_mesh_pool/0'
%%% below is that sibling child's start function: it runs strictly
%%% after this gen_server (an earlier sibling in `mcl_om_sup''s
%%% children list) has already loaded the keypair, so it reads it back
%%% via `keypair/0' rather than duplicating the loading logic.
%%% `macula_client/0' now simply checks whether that sibling is
%%% registered and alive -- no gen_server round trip, no state to keep
%%% in sync with reality.
%%%
%%% **Piece H** (`PLAN_MCL_OM_MESH_WRAPPERS.md'): every OTHER
%%% accessor here (`service_cert/0', `realm/0', `keypair/0', `org/0',
%%% `cert_chain/0', `realm_ca/0') used to be a bare `gen_server:call',
%%% which raises `{noproc, _}' if called before this gen_server has
%%% started. Three independent repos (`hecate-biotope', `hecate-
%%% society', `hecate-dronex') hand-rolled a try/catch around exactly
%%% this -- `mcl_om_identity:realm()' specifically, confirmed by
%%% reading `biotope_mesh.erl'/`society_mesh.erl'/`dronex_mesh.erl'
%%% directly, not assumed. `safe_call/1' converts that one specific
%%% failure mode (not a genuine timeout -- a hung gen_server is a real
%%% bug worth crashing loudly over, not silently degrading) into
%%% `{error, not_booted}', obsoleting all three call sites' defenses at
%%% once rather than leaving each caller to reinvent it.
-module(mcl_om_identity).
-behaviour(gen_server).

-export([start_link/0, service_cert/0, macula_client/0, realm/0, keypair/0,
         org/0, cert_chain/0, realm_ca/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% Exported for mcl_om_identity_tests.erl -- pure resolution logic,
%% same testing convention mcl_om_capabilities.erl already uses.
-export([keypair_from/1]).
%% Exported for mcl_om_sup.erl (deciding whether to include the mesh
%% pool child at all) and as that child's own start function.
-export([configured_seeds/0, start_mesh_pool/0]).

%% Registered name of the mesh-pool sibling child mcl_om_sup starts
%% (piece A) -- `macula_client/0' below looks it up directly rather
%% than round-tripping through this gen_server.
-define(MESH_POOL_NAME, mcl_om_mesh_pool).

-record(state, {
    cert      :: binary() | undefined,
    realm     :: binary() | undefined,  %% 32-byte realm tag
    %% Stable service keypair, loaded from `identity_key_path' at boot
    %% and RETAINED so the service can sign its own DHT records
    %% (procedure_advertisement). Undefined when the service runs on an
    %% ephemeral SDK identity — such a service peers and calls fine but
    %% cannot sign records, so it is (correctly) invisible to DHT
    %% discovery.
    keypair   :: macula_identity:key_pair() | undefined,
    %% This service's org name (the `<org>' segment of its procedure
    %% URIs, and the delegation-chain root below the realm). From the
    %% `org' app env; defaults to `<<"_">>' when unset. Direct-dial
    %% dual-trust (Slice 7c).
    org       :: binary(),
    %% Direct-dial dual-trust (Slice 7c Direction B). `org_ca' is the org
    %% CA that issued this service's leaf cert; leaf ++ org CA is embedded
    %% in advertisements so a consumer can chain to the realm CA. `realm_ca'
    %% is the trust anchor a verifying consumer checks resolved
    %% advertisements against. Both provisioned onto disk beside the leaf
    %% cert; `undefined' when absent (service then advertises without a
    %% chain / cannot run `verify => true').
    org_ca    :: binary() | undefined,
    realm_ca  :: binary() | undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc The realm-signed service-principal cert, `{error, no_cert}'
%% when unset, or `{error, not_booted}' (piece H) when called before
%% this gen_server has started.
-spec service_cert() -> {ok, binary()} | {error, no_cert | not_booted}.
service_cert() ->
    safe_call(service_cert).

%% @doc The mesh pool handle, or `{error, no_client}' when no seeds are
%% configured (so `mcl_om_sup' never started the pool child at all)
%% or the pool hasn't registered itself yet. A direct `whereis/1' check
%% on the pool's own registered name -- no gen_server round trip to
%% this module, and nothing here to fall out of sync with reality.
-spec macula_client() -> {ok, pid()} | {error, no_client}.
macula_client() ->
    case whereis(?MESH_POOL_NAME) of
        Pid when is_pid(Pid) -> {ok, Pid};
        undefined             -> {error, no_client}
    end.

%% @doc The 32-byte realm tag, `{error, no_realm}' when unset, or
%% `{error, not_booted}' (piece H) when called before this gen_server
%% has started -- this is the specific accessor `hecate-biotope',
%% `hecate-society', and `hecate-dronex' each wrap in a hand-rolled
%% try/catch today, confirmed by reading their `*_mesh.erl' directly.
-spec realm() -> {ok, <<_:256>>} | {error, no_realm | not_booted}.
realm() ->
    safe_call(realm).

%% @doc The service's stable signing keypair, `{error, no_keypair}'
%% when running on an ephemeral identity (callers that sign DHT records
%% degrade to no-op on that), or `{error, not_booted}' (piece H) when
%% called before this gen_server has started.
-spec keypair() -> {ok, macula_identity:key_pair()} |
                    {error, no_keypair | not_booted}.
keypair() ->
    safe_call(keypair).

%% @doc This service's org name (the `<org>' segment of its procedure
%% URIs). Always a binary -- `<<"_">>' both when unconfigured and
%% (piece H) when called before this gen_server has started, since
%% "we don't have a real org value yet" is the same situation to every
%% caller either way, and this accessor's whole contract is never
%% raising and never asking the caller to unwrap a tuple.
-spec org() -> binary().
org() ->
    case safe_call(org) of
        {error, not_booted} -> <<"_">>;
        Org                  -> Org
    end.

%% @doc The cert chain to embed in advertisements: this service's leaf
%% cert followed by its org CA (PEM). `{error, no_cert_chain}' when
%% either half is missing — the service then advertises without a chain
%% and is reachable only by open-mode consumers (Slice 7c Direction B).
%% `{error, not_booted}' (piece H) when called before this gen_server
%% has started.
-spec cert_chain() -> {ok, binary()} | {error, no_cert_chain | not_booted}.
cert_chain() ->
    safe_call(cert_chain).

%% @doc The realm CA a verifying consumer trusts as the direct-dial
%% trust anchor (PEM). `{error, no_realm_ca}' when unconfigured — a
%% `verify => true' call then cannot verify and drops every provider.
%% `{error, not_booted}' (piece H) when called before this gen_server
%% has started.
-spec realm_ca() -> {ok, binary()} | {error, no_realm_ca | not_booted}.
realm_ca() ->
    safe_call(realm_ca).

%% @doc `gen_server:call/2' to this identity process, converting the
%% one failure mode that means "called before boot" (`{noproc, _}' --
%% no such registered process, or it died between the lookup and the
%% send) into `{error, not_booted}' instead of raising. A genuine
%% timeout is a different, real bug -- a hung gen_server is worth
%% crashing loudly over, not silently degrading -- so it is
%% deliberately left to propagate, not caught here.
safe_call(Msg) ->
    try gen_server:call(?MODULE, Msg)
    catch exit:{noproc, _} -> {error, not_booted}
    end.

init([]) ->
    init_with_keypair(load_keypair()).

%% A configured key file that exists but will not load stops this process,
%% and with it `mcl_om_sup' and the service, with the load error. See
%% load_keypair/0 for why that beats generating a replacement.
init_with_keypair({error, Reason}) ->
    {stop, Reason};
init_with_keypair(KeyPair) ->
    Cert  = case load_cert() of
        {ok, C}    -> C;
        {error, _} -> undefined
    end,
    Realm   = load_realm(),
    Org     = load_org(),
    {ok, #state{cert = Cert, realm = Realm,
                keypair = KeyPair, org = Org,
                org_ca = load_org_ca(), realm_ca = load_realm_ca()}}.

handle_call(service_cert, _From, #state{cert = undefined} = S) ->
    {reply, {error, no_cert}, S};
handle_call(service_cert, _From, #state{cert = C} = S) ->
    {reply, {ok, C}, S};

handle_call(realm, _From, #state{realm = undefined} = S) ->
    {reply, {error, no_realm}, S};
handle_call(realm, _From, #state{realm = R} = S) ->
    {reply, {ok, R}, S};

handle_call(keypair, _From, #state{keypair = undefined} = S) ->
    {reply, {error, no_keypair}, S};
handle_call(keypair, _From, #state{keypair = Kp} = S) ->
    {reply, {ok, Kp}, S};

handle_call(org, _From, #state{org = Org} = S) ->
    {reply, Org, S};

handle_call(cert_chain, _From, #state{cert = C, org_ca = O} = S)
  when is_binary(C), is_binary(O) ->
    {reply, {ok, <<C/binary, "\n", O/binary>>}, S};
handle_call(cert_chain, _From, S) ->
    {reply, {error, no_cert_chain}, S};

handle_call(realm_ca, _From, #state{realm_ca = undefined} = S) ->
    {reply, {error, no_realm_ca}, S};
handle_call(realm_ca, _From, #state{realm_ca = RC} = S) ->
    {reply, {ok, RC}, S};

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _State) -> ok.

%%% Internals

load_cert() ->
    Path = application:get_env(mcl_om, service_cert_path,
                               "/etc/hecate/secrets/service-cert.pem"),
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        Err       -> Err
    end.

%% Org CA and realm CA (Slice 7c Direction B), provisioned onto disk
%% beside the leaf cert. Absent = `undefined' (advertise without a
%% chain / no `verify => true').
load_org_ca() ->
    read_pem(application:get_env(mcl_om, org_ca_cert_path,
                                 "/etc/hecate/secrets/org-ca.pem")).

load_realm_ca() ->
    read_pem(application:get_env(mcl_om, realm_ca_cert_path,
                                 "/etc/hecate/secrets/realm-ca.pem")).

read_pem(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        _         -> undefined
    end.

%% @doc Realm tag = 32-byte binary. v1: read from env (operator
%% pins it via `hecate-gitops/system/<service>.env'). v2: extract
%% from the service-principal cert at boot.
load_realm() ->
    case application:get_env(mcl_om, realm) of
        {ok, R} when is_binary(R), byte_size(R) =:= 32 ->
            R;
        {ok, HexB} when is_binary(HexB), byte_size(HexB) =:= 64 ->
            decode_hex(HexB);
        undefined ->
            undefined
    end.

%% @doc Start function for the mesh-pool child `mcl_om_sup' includes
%% in its children list whenever seeds are configured (piece A). Runs
%% as a sibling started strictly after this gen_server, so `keypair/0'
%% is already resolved -- no duplicated loading logic here, just a
%% read-back. Registers the pool under `?MESH_POOL_NAME' so
%% `macula_client/0' can find it without a round trip through this
%% module, then hands `{ok, Pid}' (or a genuine `{error, _}') back to
%% the supervisor exactly like any other child start function.
%%
%% NOTE: connection no longer depends on the realm-signed cert. The macula
%% `identity' opt wants a raw Ed25519 keypair, not a cert, and the mesh does
%% not yet verify realm membership at connect/publish — so requiring a cert
%% to connect was spurious (it kept every service dark). The cert is still
%% loaded + held (`service_cert/0') for the v2 swap-in, when the SDK enforces
%% realm-signed identity and this is where it gets passed.
-spec start_mesh_pool() -> {ok, pid()} | {error, term()}.
start_mesh_pool() ->
    %% Runs strictly after this gen_server has already started (an
    %% earlier sibling in mcl_om_sup's children list), so keypair/0
    %% can never actually see {error, not_booted} here -- matched
    %% alongside {error, no_keypair} anyway rather than pattern-
    %% matching the specific reason, so this stays correct regardless
    %% of what keypair/0's error shape does in the future (piece H).
    KeyPair = case keypair() of
        {ok, Kp}    -> Kp;
        {error, _}  -> undefined
    end,
    case macula:connect(configured_seeds(), keypair_opts(KeyPair)) of
        {ok, Pid} ->
            true = erlang:register(?MESH_POOL_NAME, Pid),
            {ok, Pid};
        {error, _Reason} = Err ->
            Err
    end.

%% Load the stable on-disk service keypair (macula-native format, via
%% `macula_identity:save/2') when `identity_key_path' is configured;
%% `undefined' (the SDK auto-generates an ephemeral identity at
%% connect) only when `identity_key_path' itself is unconfigured. The
%% keypair is for peering AND for signing the service's own DHT
%% records — an ephemeral service peers and calls fine but cannot
%% advertise procedure records, so a service whose whole job is a
%% direct-dial RPC/Streaming *provider* silently never advertises
%% anything if this stays unset — confirmed live, not theoretical
%% (hecate-tube's `tube_mesh_providers' retried forever, `keypair/0'
%% never resolving, until this existed).
%%
%% First boot needs no out-of-band provisioning: a MISSING key file
%% (`{error, enoent}') generates a fresh keypair and persists it to the
%% configured path via `macula_identity:save/2', which `ensure_dir's the
%% path itself. Falls back to `undefined' only if that save fails (e.g. a
%% read-only filesystem).
%%
%% Any OTHER load failure returns `{error, {identity_key_unloadable, Path,
%% Reason}}', which stops the service and leaves the file untouched: a
%% corrupt file, a directory or unreadable file at the path, or (from the
%% macula release that refuses them) a key file readable by group or
%% others. Generating a replacement there would give the service a new
%% node id and overwrite its real key on disk, turning a fixable
%% permissions or disk problem into a silent identity change.
load_keypair() ->
    keypair_from(application:get_env(mcl_om, identity_key_path)).

-spec keypair_from({ok, file:filename_all()} | undefined) ->
    macula_identity:key_pair() | undefined |
    {error, {identity_key_unloadable, file:filename_all(), term()}}.
keypair_from({ok, Path}) ->
    loaded_or_generated(macula_identity:load(Path), Path);
keypair_from(undefined) ->
    undefined.

loaded_or_generated({ok, Kp}, _Path) ->
    Kp;
loaded_or_generated({error, enoent}, Path) ->
    generate_and_save(Path);
loaded_or_generated({error, Reason}, Path) ->
    {error, {identity_key_unloadable, Path, Reason}}.

%% Puzzle-hardened (mirrors macula-realm's own mesh identity, see
%% MaculaRealm.Mesh.mesh_identity/0): every station in this fleet
%% enforces S/Kademlia puzzle validation on CONNECT/HELLO. A plain
%% (non-puzzle) identity's handshake completes and then gets closed
%% with `puzzle_invalid' -> a graceful drain -> `drained', every
%% single connection, forever -- confirmed live: this is why
%% tube_mesh_providers could reach `advertised => true' (the local,
%% client-side bookkeeping) while no station's DHT-facing registry
%% ever actually held the advertisement, on a repeating ~96s
%% reject/reconnect cycle. Grinding difficulty 8 is sub-millisecond;
%% there's no reason to skip it.
generate_and_save(Path) ->
    KeyPair = macula_identity:generate(#{puzzle => true}),
    save_result(macula_identity:save(Path, KeyPair), KeyPair).

save_result(ok, KeyPair) -> KeyPair;
save_result({error, _Reason}, _KeyPair) -> undefined.

keypair_opts(undefined) -> #{};
keypair_opts(KeyPair)   -> #{identity => KeyPair}.

%% Org name from the `org' app env; `<<"_">>' when unset (records still
%% resolve, just under the placeholder org until one is configured).
load_org() ->
    case application:get_env(mcl_om, org) of
        {ok, O} when is_binary(O), O =/= <<>> -> O;
        _                                     -> <<"_">>
    end.

%% Station seeds, in precedence order:
%%   1. MACULA_STATION_SEEDS env var (comma-separated URLs) — lets each
%%      deployed instance dial a distinct station without rebuilding the
%%      image (e.g. one mpong-bot per beam node, one station each).
%%   2. `station_seeds' app env (sys.config default).
configured_seeds() ->
    case parse_seed_csv(os:getenv("MACULA_STATION_SEEDS")) of
        []    -> app_env_seeds();
        Seeds -> Seeds
    end.

app_env_seeds() ->
    case application:get_env(mcl_om, station_seeds) of
        {ok, Seeds} when is_list(Seeds) -> Seeds;
        _                                -> []
    end.

parse_seed_csv(false) -> [];
parse_seed_csv(Csv) ->
    [list_to_binary(Trimmed)
     || Part <- string:split(Csv, ",", all),
        Trimmed <- [string:trim(Part)],
        Trimmed =/= ""].

decode_hex(Hex) ->
    << <<(list_to_integer([A,B], 16))>> || <<A:8, B:8>> <= Hex >>.
