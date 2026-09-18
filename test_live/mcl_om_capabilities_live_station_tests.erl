%% Live end-to-end proof for piece B (PLAN_MCL_OM_MESH_WRAPPERS.md):
%% a capability carrying a `handler' is genuinely CALLABLE mesh-to-mesh
%% via macula_response:advertise_direct, not just discoverable. Run
%% against a real PQ-fleet station (pq.station-fi-helsinki.macula.io,
%% paired with pq.station-fi-helsinki.macula.io), since macula's own
%% test suite has no local station and defers this exact case to a
%% separate cross-station suite.
%%
%% The 11.x port changes what this proves AND what it needs:
%%
%%   - The procedure is org-namespaced (11.x refuses a bare name with
%%     no_org_namespace), so a REAL D25 authorization chain must be in
%%     the DHT before the advertise: the realm's signed `org_directory'
%%     and the org's signed `procedure_delegation' naming the
%%     provider's node id. The SDK's advertise path resolves that chain
%%     itself and fails fast with `{error, {provider_authorization,
%%     _}}' without it.
%%   - Every pool holds a puzzle-hardened pq_hybrid node key, and every
%%     seed is pinned with the station's node id (D5).
%%   - The station's admission is form-only (D28 owns the trust-list
%%     signatures), so a test realm of our own making exercises the
%%     whole path without touching the io.macula realm the stations
%%     actually serve.
%%   - The call path resolves the provider's serving station to a
%%     dialable URL from its `station_endpoint' record, so the fleet
%%     station these tests use must PUBLISH that record: helsinki
%%     does, nuremberg currently does not (its announcer publishes no
%%     endpoint, and its DHT find misses every record -- a live-fleet
%%     finding, 2026-09-18, not something this repo can fix).
%%
%% Lives in test_live/, NOT test/ -- excluded from the default
%% `rebar3 eunit' (and CI's main gate) on purpose: the PQ pair is
%% disposable dev infra with no uptime guarantee, so a station blip
%% must never block an unrelated PR. Run explicitly:
%%   rebar3 as live_test eunit --dir test_live
%% or, for just this module:
%%   rebar3 as live_test eunit --dir test_live --module=mcl_om_capabilities_live_station_tests
-module(mcl_om_capabilities_live_station_tests).
-include_lib("eunit/include/eunit.hrl").

-behaviour(macula_response).
-export([init/1, handle_request/2]).

-define(SEED_HOST, <<"pq.station-fi-helsinki.macula.io">>).
-define(SEED_PORT, 4433).
-define(SEED_NODE_ID,
        <<16#004d1f470097ccf8826ce291900e882fdb1f20375e53901facaec0f23eb4efd8:256>>).
-define(CAP_NAME, <<"mcl_om_live_test.echo">>).

capability_with_handler_is_genuinely_callable_test_() ->
    {timeout, 120, fun run/0}.

run() ->
    {ok, _} = application:ensure_all_started(macula),
    Realm = crypto:strong_rand_bytes(32),
    ProviderKey = identity_key(),
    {RealmKey, OrgKey} = realm_and_org_keys(),
    {ok, ProviderPool} = provider_pool(Realm, RealmKey, ProviderKey),

    publish_chain(ProviderPool, Realm, RealmKey, OrgKey, ProviderKey,
                  <<"acme">>),

    {ok, I} = mcl_om_identity:start_link(),
    ok = meck:new(mcl_om_identity, [passthrough]),
    ok = meck:expect(mcl_om_identity, macula_client, fun() -> {ok, ProviderPool} end),
    ok = meck:expect(mcl_om_identity, realm, fun() -> {ok, Realm} end),
    ok = meck:expect(mcl_om_identity, org, fun() -> <<"acme">> end),
    ok = meck:expect(mcl_om_identity, identity_key, fun() -> {ok, ProviderKey} end),

    {ok, C} = mcl_om_capabilities:start_link(),
    Cap = #{name => ?CAP_NAME, version => 1, handler => {?MODULE, <<"acme">>}},
    ok = mcl_om_capabilities:register([Cap]),

    %% A genuinely separate consumer identity/pool -- provider and
    %% caller are different services in any real deployment. The
    %% consumer pins the realm key, so it COULD verify the D25 chain.
    {ok, ConsumerPool} = consumer_pool(Realm, RealmKey),

    DirectResult = mcl_om_capabilities:call_capability(
                     ConsumerPool, Realm, <<"acme">>, ?CAP_NAME,
                     #{<<"ping">> => <<"pong">>}, 15_000, #{}),

    meck:unload(mcl_om_identity),
    catch gen_server:stop(C),
    catch gen_server:stop(I),
    catch macula_client:close(ProviderPool),
    catch macula_client:close(ConsumerPool),

    %% Reply keys arrive as {text, _} markers (the 11.x wire marks
    %% every text key explicitly, D26) -- mcl_om_wire:field/2 is the
    %% contract every caller reads them through; see piece F,
    %% PLAN_MCL_OM_MESH_WRAPPERS.md. The echo carries the payload the
    %% provider received, which includes the wire-authenticated caller
    %% (macula >= 10.15.0 threads it into every RPC payload).
    {ok, Reply} = DirectResult,
    ?assertEqual(<<"acme">>, mcl_om_wire:field(answered_by, Reply)),
    Echo = mcl_om_wire:field(echo, Reply),
    ?assertEqual(<<"pong">>, mcl_om_wire:field(ping, Echo)),
    ?assert(is_binary(mcl_om_wire:field(caller, Echo))).

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).

%% macula_response callbacks -- a trivial echo carrying the ReplyTag it
%% was registered with, which is how the org-scoped test below tells
%% "acme answered" from "contoso answered" apart live.
init(Args) -> {ok, Args}.

handle_request(Payload, Tag) ->
    {reply, #{<<"answered_by">> => Tag, <<"echo">> => Payload}, Tag}.

%%%===================================================================
%%% Two orgs, same capability name -- the shared-station fix. In 11.x
%%% every procedure is org-namespaced, so two orgs advertising the same
%%% name are two genuinely distinct wire-level procedures, each with
%%% its own D25 chain. A targeted call can only ever be answered by the
%%% org it names.
%%%===================================================================

org_scoped_call_reaches_only_the_targeted_org_test_() ->
    {timeout, 120, fun run_org_scoped/0}.

run_org_scoped() ->
    {ok, _} = application:ensure_all_started(macula),
    Realm = crypto:strong_rand_bytes(32),
    CapName = <<"mcl_om_live_test.org_scoped_echo">>,
    {RealmKey, AcmeOrgKey} = realm_and_org_keys(),
    {ok, ContosoOrgKey} = macula_node_keys:generate(org, profile()),
    RealmPub = macula_node_keys:public_key(RealmKey),

    AcmeKp = identity_key(),
    ContosoKp = identity_key(),
    {ok, PoolAcme} = macula_client:connect(
                       seed(), #{node_identity => AcmeKp,
                                 realm_trust => #{Realm => RealmPub}}),
    {ok, PoolContoso} = macula_client:connect(
                          seed(), #{node_identity => ContosoKp,
                                    realm_trust => #{Realm => RealmPub}}),
    ok = wait_healthy(PoolAcme, 200),
    ok = wait_healthy(PoolContoso, 200),

    %% Each org's chain: its own org key, its own delegation naming its
    %% own provider node id, both under the same test realm.
    publish_chain(PoolAcme, Realm, RealmKey, AcmeOrgKey, AcmeKp, <<"acme">>),
    publish_chain(PoolContoso, Realm, RealmKey, ContosoOrgKey, ContosoKp,
                  <<"contoso">>),

    ok = advertise_org(PoolAcme, Realm, CapName, AcmeKp, <<"acme">>, <<"acme">>),
    ok = advertise_org(PoolContoso, Realm, CapName, ContosoKp, <<"contoso">>,
                       <<"contoso">>),

    ConsumerKp = identity_key(),
    {ok, ConsumerPool} = macula_client:connect(
                           seed(), #{node_identity => ConsumerKp,
                                     realm_trust => #{Realm => RealmPub}}),
    ok = wait_healthy(ConsumerPool, 200),

    %% Give DHT propagation a moment past the initial writes -- same
    %% retry-tolerant spirit as macula_direct_dial's own resolve loop;
    %% find/2's own retry is the safety net if this margin is ever too
    %% tight.
    timer:sleep(2_000),

    ToAcme = mcl_om_capabilities:call_capability(
               ConsumerPool, Realm, <<"acme">>, CapName,
               #{<<"who">> => <<"?">>}, 15_000, #{}),
    ToContoso = mcl_om_capabilities:call_capability(
                  ConsumerPool, Realm, <<"contoso">>, CapName,
                  #{<<"who">> => <<"?">>}, 15_000, #{}),

    catch macula_client:close(PoolAcme),
    catch macula_client:close(PoolContoso),
    catch macula_client:close(ConsumerPool),

    {ok, AcmeReply} = ToAcme,
    ?assertEqual(<<"acme">>, mcl_om_wire:field(answered_by, AcmeReply)),
    {ok, ContosoReply} = ToContoso,
    ?assertEqual(<<"contoso">>, mcl_om_wire:field(answered_by, ContosoReply)).

%%%===================================================================
%%% Org capability browse (slice 4) -- list_org_capabilities/1 finds
%%% every capability an org has advertised, live, without knowing any
%%% capability name in advance.
%%%===================================================================

list_org_capabilities_finds_everything_the_org_advertised_test_() ->
    {timeout, 120, fun run_list_org_capabilities/0}.

run_list_org_capabilities() ->
    {ok, _} = application:ensure_all_started(macula),
    Realm = crypto:strong_rand_bytes(32),
    {RealmKey, AcmeOrgKey} = realm_and_org_keys(),
    {ok, ContosoOrgKey} = macula_node_keys:generate(org, profile()),
    RealmPub = macula_node_keys:public_key(RealmKey),

    KpAcme = identity_key(),
    {ok, PoolAcme} = macula_client:connect(
                       seed(), #{node_identity => KpAcme,
                                 realm_trust => #{Realm => RealmPub}}),
    ok = wait_healthy(PoolAcme, 200),
    publish_chain(PoolAcme, Realm, RealmKey, AcmeOrgKey, KpAcme, <<"acme">>),

    %% Acme advertises TWO distinct capabilities; a third org (Contoso)
    %% advertises one under the SAME bare name as one of Acme's, to
    %% prove the browse is genuinely org-scoped, not name-collision-prone.
    ok = advertise_org(PoolAcme, Realm, <<"mcl_om_live_test.browse_a">>,
                       KpAcme, <<"acme">>, <<"acme">>),
    ok = advertise_org(PoolAcme, Realm, <<"mcl_om_live_test.browse_b">>,
                       KpAcme, <<"acme">>, <<"acme">>),
    KpContoso = identity_key(),
    {ok, PoolContoso} = macula_client:connect(
                          seed(), #{node_identity => KpContoso,
                                    realm_trust => #{Realm => RealmPub}}),
    ok = wait_healthy(PoolContoso, 200),
    publish_chain(PoolContoso, Realm, RealmKey, ContosoOrgKey, KpContoso,
                  <<"contoso">>),
    ok = advertise_org(PoolContoso, Realm, <<"mcl_om_live_test.browse_a">>,
                       KpContoso, <<"contoso">>, <<"contoso">>),

    ConsumerKp = identity_key(),
    {ok, ConsumerPool} = macula_client:connect(
                           seed(), #{node_identity => ConsumerKp,
                                     realm_trust => #{Realm => RealmPub}}),
    ok = wait_healthy(ConsumerPool, 200),
    timer:sleep(2_000),

    %% Explicit-args form (resolve_org_capabilities/3), not the
    %% gen_server-backed list_org_capabilities/1 -- this proves the
    %% underlying browse mechanism; the identity-mocking plumbing
    %% list_org_capabilities/1 would need is already proven by every
    %% other live test in this module.
    Found = mcl_om_capabilities:resolve_org_capabilities(
              ConsumerPool, Realm, <<"acme">>),

    catch macula_client:close(PoolAcme),
    catch macula_client:close(PoolContoso),
    catch macula_client:close(ConsumerPool),

    Procedures = [maps:get(procedure, F) || F <- Found],
    ?assert(lists:member(<<"acme/mcl_om_live_test.browse_a">>, Procedures)),
    ?assert(lists:member(<<"acme/mcl_om_live_test.browse_b">>, Procedures)),
    ?assertNot(lists:member(<<"contoso/mcl_om_live_test.browse_a">>, Procedures)).

%%%===================================================================
%%% Helpers
%%%===================================================================

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.

%% A puzzle-hardened identity key at the fleet's difficulty (about
%% 0.4 s per key in pq_hybrid).
identity_key() ->
    {ok, K} = macula_node_keys:generate(
               identity, profile(),
               #{puzzle_difficulty => macula_node_keys:puzzle_difficulty()}),
    K.

%% The realm's signing key and an org's signing key -- ordinary node
%% keys of those purposes, no puzzle.
realm_and_org_keys() ->
    {ok, RealmKey} = macula_node_keys:generate(realm, profile()),
    {ok, OrgKey} = macula_node_keys:generate(org, profile()),
    {RealmKey, OrgKey}.

seed() ->
    [#{host => ?SEED_HOST, port => ?SEED_PORT, expected_node_id => ?SEED_NODE_ID}].

provider_pool(Realm, RealmKey, ProviderKey) ->
    {ok, Pool} = macula_client:connect(
                   seed(), #{node_identity => ProviderKey,
                             realm_trust =>
                               #{Realm => macula_node_keys:public_key(RealmKey)}}),
    ok = wait_healthy(Pool, 200),
    {ok, Pool}.

consumer_pool(Realm, RealmKey) ->
    {ok, Pool} = macula_client:connect(
                   seed(), #{node_identity => identity_key(),
                             realm_trust =>
                               #{Realm => macula_node_keys:public_key(RealmKey)}}),
    ok = wait_healthy(Pool, 200),
    {ok, Pool}.

%% The pool's D25 authorization chain, published through the pool's own
%% connection before advertise (the SDK's advertise path fetches it back
%% from the DHT): the realm-signed org_directory and the org-signed
%% procedure_delegation naming the provider's node id.
publish_chain(Pool, Realm, RealmKey, OrgKey, ProviderKey, Org) ->
    OrgKeyId = macula_node_keys:key_id(OrgKey),
    {ok, ProviderNodeId} = macula_node_keys:node_id(ProviderKey),
    OrgDir = macula_record:sign(
               macula_record:org_directory(Realm, Org, OrgKeyId), RealmKey),
    Deleg  = macula_record:sign(
               macula_record:procedure_delegation(OrgKeyId, ProviderNodeId),
               OrgKey),
    ok = macula:put_record(Pool, macula_record:encode(OrgDir)),
    ok = macula:put_record(Pool, macula_record:encode(Deleg)).

%% The org-qualified wire-level procedure, advertised through the SDK's
%% own direct-dial path. Like mcl_om_capabilities:advertise_one/7, the
%% D25 authorization is resolved from the DHT and embedded: the SDK's
%% advertise path resolves it for the WIRE frame only, and the station
%% refuses the direct-dial record without it (no_authorization).
advertise_org(Pool, Realm, CapName, KeyPair, Org, ReplyTag) ->
    OrgProcedure = mcl_om_capabilities:org_procedure(Org, CapName),
    {ok, Dir} = macula:find_record(
                  Pool, macula_record:org_directory_key(Realm, Org)),
    #{org_key := OrgKeyId} = macula_record:read_org_directory(Dir),
    {ok, NodeId} = macula_node_keys:node_id(KeyPair),
    {ok, Del} = macula:find_record(
                  Pool, macula_record:procedure_delegation_key(OrgKeyId, NodeId)),
    Auth = #{authorization =>
               #{org_directory => macula_record:encode(Dir),
                 procedure_delegation => macula_record:encode(Del)}},
    {ok, Sup} = macula_response:advertise_direct(Pool, Realm, OrgProcedure,
                                                 ?MODULE, ReplyTag, KeyPair,
                                                 Auth),
    unlink(Sup),
    ok.
