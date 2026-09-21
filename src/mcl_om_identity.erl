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
%% `base_pool_opts/0' is the composed map that reaches `macula:connect/2',
%% and its `verify' entry decides whether a station link does a real X.509
%% chain check; asserting on the composed result rather than on
%% `verify_mode/0' alone is what catches a regression in either half.
-export([node_key_from/1, realm_trust_opts/0, base_pool_opts/0]).
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
    maps:merge(#{verify => verify_mode()}, realm_trust_opts()).

%% The realm key the pool pins for org-namespaced advertisement
%% verification (D25): `#{RealmId => RealmKey}', the realm's public
%% signing key as carried, built from the `realm' and `realm_key' deploy
%% envs. One realm per service, matching one org per service.
%%
%% ⚠ REQUIRED, AND LOUD WHEN ABSENT. This used to fall through to `#{}'
%% when nothing was configured. That is how a service reached a box, went
%% green, answered /health, and was PERMANENTLY unable to resolve anything
%% org-namespaced: with no realm key
%% `macula_record:verify_authorization/3' refuses every advertisement with
%% `no_realm_key', `macula_direct_dial' reports `{unresolved,
%% no_trusted_advertisement}', and the boot claim never reaches the realm,
%% so there is no pending row for an operator to approve, no delegation,
%% and no advertise. An unconfigured trust anchor is not a deployment that
%% half works; it is one that cannot work, and it should not boot.
%%
%% THE HEX DECODE LIVES HERE, not in the SDK and not in a service.
%% `macula:connect/2' takes `realm_trust' as raw bytes and deliberately
%% refuses anything else: it is a typed, in-memory contract. A deploy
%% environment can only carry text. Translating one into the other is
%% exactly what this module already does for `realm' (64-hex to 32 bytes)
%% and for every seed's `expected_node_id'. Anywhere else means every
%% mcl-* service doing it again, which is the duplication that produced
%% the outage this clause exists to prevent.
%%
%% A malformed entry would also be refused by macula:connect/2 itself
%% (`{error, {realm_trust, invalid}}'), but by then the reason is about a
%% map the operator never typed. The checks here name the variable.
realm_trust_opts() ->
    #{realm_trust => realm_trust(load_realm(), configured_realm_key())}.

realm_trust(undefined, _KeyHex) ->
    error({mcl_om_realm_trust, realm_unconfigured});
realm_trust(_Realm, undefined) ->
    error({mcl_om_realm_trust, realm_key_unconfigured});
realm_trust(<<_:256>> = Realm, KeyHex) ->
    #{Realm => realm_key_decoded(hex_shaped(KeyHex), KeyHex)}.

configured_realm_key() ->
    case application:get_env(mcl_om, realm_key) of
        {ok, Hex} when is_binary(Hex), Hex =/= <<>> -> Hex;
        _                                           -> undefined
    end.

%% Checked before decoding rather than after: decode_hex/1 on a stray
%% character raises a bare badarg naming nothing.
realm_key_decoded(true, KeyHex) ->
    decode_hex(KeyHex);
realm_key_decoded(false, KeyHex) ->
    error({mcl_om_realm_trust, {realm_key_not_hex, byte_size(KeyHex)}}).

hex_shaped(Hex) ->
    byte_size(Hex) rem 2 =:= 0 andalso
        match =:= re:run(Hex, <<"^[0-9a-fA-F]+$">>, [{capture, none}]).

%% The pool's TLS policy for every station link it dials.
%%
%% ⚠ `none' IS THE DEFAULT AND IS THE SAFE DIRECTION HERE. It was
%% `webpki', which was harmless only by accident: macula 11.4.0's
%% `macula_peering_conn:start_dial/1' discarded the caller's value and
%% passed a literal `{verify, none}', so the option was decorative. 11.5.0
%% fixes that bug and honours the target's value, which turns this default
%% into a real X.509 chain check against the QUIC NIF's built-in public
%% roots on every station dial.
%%
%% Nothing is lost by not checking the chain. What binds a link to the
%% node it dialled is the D16 handshake pin: `expected_node_id' is
%% required and a link without one refuses to start. 11.5.0's own
%% `dial_opts/1' says it plainly -- a station's leaf is self-signed or
%% issued by an unrelated PKI, and the signed handshake is what binds the
%% connection, not the certificate chain. Checking the chain as well adds
%% nothing the pin does not already give, and it makes reaching the mesh
%% depend on a public CA and on a certificate renewal nobody is watching.
%% A lapsed or rotated cert would take every mcl-* pool offline for a
%% reason with nothing to do with the mesh, and nobody would look there
%% first.
%%
%% macula-station reached the same conclusion for its own outbound links
%% in `e07010d'. This is the consumer-side equivalent, and because the
%% service scaffold's `sys.config.src' sets no `verify' at all, this
%% default is what every mcl-* service yet to be written will inherit.
%%
%% `MCL_OM_VERIFY=webpki' remains the opt-in for a caller that genuinely
%% has a chain worth checking. Anything else NAMES THE VARIABLE rather
%% than silently picking a mode: `verify => true' was the 10.x spelling
%% and still appears in this repo's older guides, so a stale deploy
%% carrying it is not hypothetical, and under a silent fallback it would
%% get whichever mode the fallback happened to be while its operator
%% believed they had asked for the other.
verify_mode() ->
    verify_mode_of(os:getenv("MCL_OM_VERIFY", "none")).

verify_mode_of("none")   -> none;
verify_mode_of("webpki") -> webpki;
verify_mode_of(Other)    -> error({mcl_om_verify, {unknown_mode, Other}}).

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
