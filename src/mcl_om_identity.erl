%%% @doc Identity, seed and realm resolution for the mesh pool
%%% `mcl_om_sup' supervises alongside this gen_server.
%%%
%%% 11.x model (the PQ port): the service identity is a `macula_node_keys'
%%% node key (purpose identity, pq_hybrid, puzzle-hardened at the fleet's
%%% difficulty) — the same thing a station or pool identity is. The 10.x
%%% Ed25519 keypair and the realm-signed service cert are gone with the
%%% 11.x wire: realm membership is what the D25 authorization records and
%%% the pool's `realm_trust' keys attest, not a TLS cert chain.
%%%
%%% Seeds must carry the station node ids they expect: the 11.x peering
%%% layer refuses a client dial without an `expected_node_id' pin (D5).
%%% `MACULA_STATION_SEEDS' (comma-separated hosts, ports default 4433)
%%% pairs index-for-index with `MACULA_STATION_NODE_IDS' (comma-separated
%%% 64-hex node ids); a seed without a matching pin is refused at boot —
%%% a silent unpinned seed would be a dial that can never connect.
%%%
%%% Connect-degradation: with no seeds configured, `mcl_om_sup'
%%% never starts a mesh pool child at all, and `macula_client/0'
%%% returns `{error, no_client}' forever — consumers fall back to
%%% no-op behaviour. The service stays up either way.
%%%
%%% The pool itself is not this gen_server's state: it is an ordinary
%%% supervised sibling (`mcl_om_sup', `restart => permanent'), started
%%% strictly after this gen_server has loaded the key, so `identity_key/0'
%%% is read back rather than re-loaded.
-module(mcl_om_identity).
-behaviour(gen_server).

-export([start_link/0, macula_client/0, realm/0, identity_key/0, org/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% Exported for mcl_om_identity_tests.erl — pure resolution logic.
-export([node_key_from/1]).
%% Exported for mcl_om_sup.erl and as the mesh pool child's start function.
-export([configured_seeds/0, start_mesh_pool/0]).

-define(MESH_POOL_NAME, mcl_om_mesh_pool).

-record(state, {
    realm     :: binary() | undefined,  %% 32-byte realm tag
    %% Stable service node key, loaded from `identity_key_path' at boot
    %% and RETAINED so the service can sign its own DHT records
    %% (procedure_advertisement). Undefined when the service runs on an
    %% ephemeral SDK identity — such a service peers and calls fine but
    %% cannot sign records, so it is (correctly) invisible to DHT
    %% discovery.
    key       :: macula_node_keys:node_key() | undefined,
    org       :: binary()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc The mesh pool handle, or `{error, no_client}' when no seeds are
%% configured (so `mcl_om_sup' never started the pool child at all).
-spec macula_client() -> {ok, pid()} | {error, no_client}.
macula_client() ->
    case whereis(?MESH_POOL_NAME) of
        Pid when is_pid(Pid) -> {ok, Pid};
        undefined             -> {error, no_client}
    end.

%% @doc The 32-byte realm tag, `{error, no_realm}' when unset, or
%% `{error, not_booted}' when called before this gen_server has started.
-spec realm() -> {ok, <<_:256>>} | {error, no_realm | not_booted}.
realm() ->
    safe_call(realm).

%% @doc The service's stable signing node key, `{error, no_identity_key}'
%% when running on an ephemeral identity, or `{error, not_booted}' when
%% called before this gen_server has started.
-spec identity_key() -> {ok, macula_node_keys:node_key()} |
                        {error, no_identity_key | not_booted}.
identity_key() ->
    safe_call(identity_key).

%% @doc This service's org name (the `<org>' segment of its procedure
%% URIs). Always a binary — `<<"_">>' both when unconfigured and when
%% called before this gen_server has started.
-spec org() -> binary().
org() ->
    case safe_call(org) of
        {error, not_booted} -> <<"_">>;
        Org                  -> Org
    end.

safe_call(Msg) ->
    try gen_server:call(?MODULE, Msg)
    catch exit:{noproc, _} -> {error, not_booted}
    end.

init([]) ->
    init_with_key(load_node_key()).

init_with_key({error, Reason}) ->
    {stop, Reason};
init_with_key(Key) ->
    {ok, #state{realm = load_realm(),
                key = Key,
                org = load_org()}}.

handle_call(realm, _From, #state{realm = undefined} = S) ->
    {reply, {error, no_realm}, S};
handle_call(realm, _From, #state{realm = R} = S) ->
    {reply, {ok, R}, S};

handle_call(identity_key, _From, #state{key = undefined} = S) ->
    {reply, {error, no_identity_key}, S};
handle_call(identity_key, _From, #state{key = K} = S) ->
    {reply, {ok, K}, S};

handle_call(org, _From, #state{org = Org} = S) ->
    {reply, Org, S};

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _State) -> ok.

%%% Internals

%% Realm tag = 32-byte binary, read from env (the operator pins it in
%% the service's deploy env), hex or raw.
load_realm() ->
    case application:get_env(mcl_om, realm) of
        {ok, R} when is_binary(R), byte_size(R) =:= 32 ->
            R;
        {ok, HexB} when is_binary(HexB), byte_size(HexB) =:= 64 ->
            decode_hex(HexB);
        undefined ->
            undefined
    end.

%% Start function for the mesh-pool child `mcl_om_sup' includes whenever
%% pinned seeds are configured. Runs strictly after this gen_server, so
%% the node key is already resolved.
-spec start_mesh_pool() -> {ok, pid()} | {error, term()}.
start_mesh_pool() ->
    NodeKey = case identity_key() of
        {ok, K}   -> K;
        {error, _} -> undefined
    end,
    case macula:connect(configured_seeds(), pool_opts(NodeKey)) of
        {ok, Pid} ->
            true = erlang:register(?MESH_POOL_NAME, Pid),
            {ok, Pid};
        {error, _Reason} = Err ->
            Err
    end.

%% The 11.x pool: the node identity (generated by the SDK when absent —
%% puzzle-hardened at the configured difficulty), the pinned seeds, and
%% the realm trust keys the pool verifies org-namespaced advertisements
%% against (D25/D28). `realm_trust' comes from the deploy env; the pool
%% refuses to start with a trust entry whose id/key is malformed.
pool_opts(undefined) ->
    base_pool_opts();
pool_opts(NodeKey) ->
    maps:merge(base_pool_opts(), #{node_identity => NodeKey}).

base_pool_opts() ->
    #{verify => verify_mode()}.

verify_mode() ->
    case os:getenv("MCL_OM_VERIFY", "webpki") of
        "none" -> none;
        _      -> webpki
    end.

%% Load the stable on-disk service node key when `identity_key_path' is
%% configured; `undefined' (the SDK auto-generates an ephemeral
%% puzzle-hardened identity at connect) only when the path itself is
%% unconfigured. First boot needs no out-of-band provisioning: a MISSING
%% key file generates a fresh key and persists it. Any OTHER load failure
%% stops the service and leaves the file untouched — generating a
%% replacement would silently change the service's node id.
load_node_key() ->
    node_key_from(application:get_env(mcl_om, identity_key_path)).

-spec node_key_from({ok, file:filename_all()} | undefined) ->
    macula_node_keys:node_key() | undefined |
    {error, {identity_key_unloadable, file:filename_all(), term()}}.
node_key_from(undefined) ->
    undefined;
node_key_from({ok, Path}) ->
    loaded_or_generated(macula_node_keys:load(Path, identity, profile()),
                        Path).

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.

loaded_or_generated({ok, K}, _Path) ->
    K;
loaded_or_generated({error, enoent}, Path) ->
    generate_and_save(Path);
loaded_or_generated({error, Reason}, Path) ->
    {error, {identity_key_unloadable, Path, Reason}}.

%% Puzzle-hardened at the fleet's difficulty: every PQ station enforces
%% the puzzle on the CONNECT/HELLO handshake, and an unhardened identity
%% is closed as puzzle_invalid on every connection, forever.
generate_and_save(Path) ->
    {ok, Key} = macula_node_keys:generate(
                  identity, profile(),
                  #{puzzle_difficulty => macula_node_keys:puzzle_difficulty()}),
    save_result(macula_node_keys:save(Path, Key), Key).

save_result(ok, Key) -> Key;
save_result({error, _Reason}, _Key) -> undefined.

%% Org name from the `org' app env; `<<"_">>' when unset.
load_org() ->
    case application:get_env(mcl_om, org) of
        {ok, O} when is_binary(O), O =/= <<>> -> O;
        _                                     -> <<"_">>
    end.

%% Station seeds, in precedence order:
%%   1. MACULA_STATION_SEEDS env var (comma-separated hosts) paired with
%%      MACULA_STATION_NODE_IDS (comma-separated 64-hex node ids) by
%%      index — the 11.x pin every dial needs. A seed without a matching
%%      pin is refused: an unpinned dial can never connect (D5).
%%   2. `station_seeds' app env: [#{host, port, expected_node_id}].
configured_seeds() ->
    case pinned_env_seeds() of
        []    -> app_env_seeds();
        Seeds -> Seeds
    end.

pinned_env_seeds() ->
    Hosts = parse_csv(os:getenv("MACULA_STATION_SEEDS")),
    Ids   = parse_csv(os:getenv("MACULA_STATION_NODE_IDS")),
    pair_seeds(Hosts, Ids, []).

pair_seeds([], [], Acc) ->
    lists:reverse(Acc);
pair_seeds([Host | Hosts], [IdHex | Ids], Acc) ->
    {HostName, Port} = split_host(Host),
    pair_seeds(Hosts, Ids,
               [#{host => HostName, port => Port,
                  expected_node_id => decode_hex(IdHex)} | Acc]);
pair_seeds([], _Ids, _Acc) ->
    %% Ids without hosts: configuration error, loud.
    error({mcl_om, node_ids_without_seeds});
pair_seeds(_Hosts, [], _Acc) ->
    %% Seeds without pins: each is a dial that can never connect — refuse
    %% the whole list rather than boot a pool that holds dead seeds.
    error({mcl_om, seeds_without_node_ids}).

split_host(HostBin) ->
    case binary:split(HostBin, <<":">>) of
        [Host]           -> {Host, 4433};
        [Host, PortBin]  -> {Host, binary_to_integer(PortBin)};
        _                -> {HostBin, 4433}
    end.

app_env_seeds() ->
    case application:get_env(mcl_om, station_seeds) of
        {ok, Seeds} when is_list(Seeds) -> Seeds;
        _                                -> []
    end.

parse_csv(false) -> [];
parse_csv(Csv) ->
    [list_to_binary(Trimmed)
     || Part <- string:split(Csv, ",", all),
        Trimmed <- [string:trim(Part)],
        Trimmed =/= ""].

decode_hex(Hex) ->
    << <<(list_to_integer([A,B], 16))>> || <<A:8, B:8>> <= Hex >>.
