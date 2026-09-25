%%% The many-club contract, live: TWO providers under ONE org, one
%%% procedure, on the real PQ station. This is the fixture issue #5
%%% called the gap -- the first two-provider fleet deployment (beam03,
%%% 2026-09-25) is what found the bug, because no test exercised two
%%% providers of one org procedure at once.
%%%
%%% What it proves, in order:
%%%
%%%   1. BOTH org-key records resolve: the observer symptom of issue #5
%%%      was read as "resolve_full drops one org-key advertisement".
%%%      It does not: find_records at discovery_key_org/3 returns both
%%%      records, and decode_resolved keeps both. This assertion is the
%%%      regression net for that reading.
%%%   2. The pin dials the NAMED provider: re-advertise A, pin A, A's
%%%      tag answers; re-advertise B, pin B, B's tag answers.
%%%   3. The station's single-provider invariant (one advertiser per
%%%      (realm, procedure) per station, last direct ADVERTISE wins --
%%%      macula-station's macula_remote_advertise_registry) means the
%%%      NOT-most-recent provider's pin fails: its CALL is delivered to
%%%      the other provider's connection, which answers with the wrong
%%%      signer, the caller refuses the reply (not_the_target), and the
%%%      call times out. The regression net here is that this surfaces
%%%      as a DIAL error ({error, timeout}), NEVER as {error,
%%%      no_provider} -- 0.29.0's split, without which a dead provider
%%%      was indistinguishable from a stale pin and diagnosis went into
%%%      the resolve path.
%%%   4. A stale pin fails closed with {error, no_provider}.
%%%
%%% Two providers on ONE station is deliberate: it reproduces the fleet
%%% collision exactly. The estate's deployment answer (each club names
%%% a different serving station) is fleet configuration, not this
%%% module's concern; this module pins the CONTRACT the call path must
%%% keep whatever the station holds.
%%%
%%% Lives in test_live/, NOT test/ -- excluded from the default
%%% `rebar3 eunit' (and CI's main gate) on purpose: the PQ pair is
%%% disposable dev infra with no uptime guarantee, so a station blip
%%% must never block an unrelated PR. Run explicitly:
%%%   rebar3 as live_test eunit --dir test_live --module=mcl_om_capabilities_two_providers_tests
-module(mcl_om_capabilities_two_providers_tests).
-include_lib("eunit/include/eunit.hrl").

-behaviour(macula_response).
-export([init/1, handle_request/2]).

-define(SEED_HOST, <<"pq.station-fi-helsinki.macula.io">>).
-define(SEED_PORT, 4433).
-define(SEED_NODE_ID,
        <<16#004d1f470097ccf8826ce291900e882fdb1f20375e53901facaec0f23eb4efd8:256>>).
-define(ORG, <<"mcl_om_two_providers">>).
-define(CAP_NAME, <<"mcl_om_live_test.two_providers_echo">>).

two_providers_under_one_org_test_() ->
    {timeout, 180, fun run/0}.

run() ->
    {ok, _} = application:ensure_all_started(macula),
    Realm = crypto:strong_rand_bytes(32),
    {RealmKey, OrgKey} = realm_and_org_keys(),
    RealmPub = macula_node_keys:public_key(RealmKey),

    KpA = identity_key(),
    KpB = identity_key(),
    {ok, NodeA} = macula_node_keys:node_id(KpA),
    {ok, NodeB} = macula_node_keys:node_id(KpB),
    {ok, PoolA} = macula_client:connect(
                    seed(), #{node_identity => KpA,
                              realm_trust => #{Realm => RealmPub}}),
    {ok, PoolB} = macula_client:connect(
                    seed(), #{node_identity => KpB,
                              realm_trust => #{Realm => RealmPub}}),
    ok = wait_healthy(PoolA, 200),
    ok = wait_healthy(PoolB, 200),

    %% One org, two providers: one org directory, two delegations (one
    %% naming each provider's node id), both under the same test realm.
    publish_chain(PoolA, Realm, RealmKey, OrgKey, KpA, ?ORG),
    publish_chain(PoolB, Realm, RealmKey, OrgKey, KpB, ?ORG),

    ConsumerKp = identity_key(),
    {ok, ConsumerPool} = macula_client:connect(
                           seed(), #{node_identity => ConsumerKp,
                                     realm_trust => #{Realm => RealmPub}}),
    ok = wait_healthy(ConsumerPool, 200),

    %% A advertises first, then B: B is the most recent registrant.
    ok = advertise_org(PoolA, Realm, ?CAP_NAME, KpA, ?ORG, <<"A">>),
    ok = advertise_org(PoolB, Realm, ?CAP_NAME, KpB, ?ORG, <<"B">>),
    timer:sleep(2_000),

    %% 1. BOTH org-key records resolve -- the issue-#5 regression net.
    Key = mcl_om_capabilities:discovery_key_org(Realm, ?ORG, ?CAP_NAME),
    {ok, Records} = macula:find_records(ConsumerPool, Key),
    ?assertEqual(2, length(Records)),
    Decoded = mcl_om_capabilities:decode_resolved(Records),
    ?assertEqual(2, length(Decoded)),
    Advertisers = lists:sort([maps:get(advertiser, D) || D <- Decoded]),
    ?assertEqual(lists:sort([NodeA, NodeB]), Advertisers),

    %% 2. The pin dials the NAMED provider. The station routes by
    %% (realm, procedure) to ONE connection -- the most recent direct
    %% advertiser -- so each provider is reached by re-advertising it
    %% and pinning it.
    ok = advertise_org(PoolA, Realm, ?CAP_NAME, KpA, ?ORG, <<"A">>),
    {ok, ReplyA} = call_pinned(ConsumerPool, Realm, NodeA, <<"A">>),
    ?assertEqual(<<"A">>, mcl_om_wire:field(answered_by, ReplyA)),

    ok = advertise_org(PoolB, Realm, ?CAP_NAME, KpB, ?ORG, <<"B">>),
    {ok, ReplyB} = call_pinned(ConsumerPool, Realm, NodeB, <<"B">>),
    ?assertEqual(<<"B">>, mcl_om_wire:field(answered_by, ReplyB)),

    %% 3. The displaced provider fails with the REAL dial error, never
    %% no_provider: B advertised last, so A's pin is delivered to B's
    %% connection, B answers with the wrong signer, the reply is
    %% refused (not_the_target), and the call times out. (0.29.0 split;
    %% before it, this timeout masqueraded as {error, no_provider} and
    %% diagnosis went into the resolve path.)
    Displaced = call_pinned(ConsumerPool, Realm, NodeA, <<"A">>),
    ?assertMatch({error, _}, Displaced),
    ?assertNotEqual({error, no_provider}, Displaced),

    %% 4. A stale pin fails closed.
    Stale = mcl_om_capabilities:call_capability(
              ConsumerPool, Realm, ?ORG, ?CAP_NAME,
              #{<<"who">> => <<"?">>}, 8_000,
              #{advertiser => crypto:strong_rand_bytes(32)}),
    ?assertEqual({error, no_provider}, Stale),

    catch macula_client:close(PoolA),
    catch macula_client:close(PoolB),
    catch macula_client:close(ConsumerPool),
    ok.

call_pinned(Pool, Realm, NodeId, Tag) ->
    mcl_om_capabilities:call_capability(
      Pool, Realm, ?ORG, ?CAP_NAME, #{<<"who">> => Tag}, 8_000,
      #{advertiser => NodeId}).

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).

%% macula_response callbacks -- an echo carrying the tag it was
%% registered with, which is how the tests tell "A answered" from
%% "B answered" apart.
init(Args) -> {ok, Args}.

handle_request(Payload, Tag) ->
    {reply, #{<<"answered_by">> => Tag, <<"echo">> => Payload}, Tag}.

%%%===================================================================
%%% Helpers (same shapes as mcl_om_capabilities_live_station_tests)
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

%% The pool's D25 authorization chain, published through the pool's own
%% connection before advertise: the realm-signed org_directory and the
%% org-signed procedure_delegation naming the provider's node id.
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
%% own direct-dial path, with the D25 authorization resolved from the
%% DHT and embedded (the station refuses an org-namespaced record
%% without one: no_authorization).
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
