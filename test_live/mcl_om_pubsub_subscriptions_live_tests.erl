%% Live end-to-end proof for piece D (PLAN_MCL_OM_MESH_WRAPPERS.md):
%% a service declaring a subscription via `mcl_om_pubsub:ensure_
%% subscriptions/1' genuinely receives real events published (via
%% piece C's `mcl_om_pubsub:publish/2') on a real PQ-fleet station --
%% and `ensure_subscriptions/1' called again with a changed
%% desired set starts exactly the new child and stops exactly the
%% removed one, touching nothing else (the supervision-membership
%% design for a `federation_inbox'-shaped dynamic topic set).
%%
%% The 11.x port: the pool is a puzzle-hardened pq_hybrid node key
%% connected to a pinned seed (D5). Pubsub topics carry no org
%% namespace -- the no-org-namespace rule is procedure admission, not
%% pubsub.
%%
%% Lives in test_live/, NOT test/ -- excluded from the default
%% `rebar3 eunit' and CI's main gate on purpose; see
%% `mcl_om_capabilities_live_station_tests.erl''s moduledoc for why.
%% Run explicitly:
%%   rebar3 as live_test eunit --dir test_live
-module(mcl_om_pubsub_subscriptions_live_tests).
-include_lib("eunit/include/eunit.hrl").

-behaviour(macula_subscriber).
-export([init/1, handle_event/4]).

-define(SEED_HOST, <<"pq.station-fi-helsinki.macula.io">>).
-define(SEED_PORT, 4433).
-define(SEED_NODE_ID,
        <<16#004d1f470097ccf8826ce291900e882fdb1f20375e53901facaec0f23eb4efd8:256>>).
-define(TOPIC1, <<"mcl_om_subs_test.topic1">>).
-define(TOPIC2, <<"mcl_om_subs_test.topic2">>).

subscriptions_receive_real_events_and_are_dynamic_test_() ->
    {timeout, 60, fun run/0}.

run() ->
    {ok, _} = application:ensure_all_started(macula),
    {ok, Pool} = macula_client:connect(
                   [#{host => ?SEED_HOST, port => ?SEED_PORT,
                      expected_node_id => ?SEED_NODE_ID}],
                   #{node_identity => identity_key()}),
    ok = wait_healthy(Pool, 200),
    Realm = crypto:strong_rand_bytes(32),

    ok = meck:new(mcl_om, [passthrough]),
    ok = meck:expect(mcl_om, mesh_handles, fun() -> {ok, Pool, Realm} end),

    {ok, Sup} = mcl_om_pubsub_sup:start_link(),
    {ok, Subs} = mcl_om_pubsub_subscriptions:start_link(),

    %% 1. Declare one subscription, receive a real event on it.
    ok = mcl_om_pubsub:ensure_subscriptions([{?TOPIC1, ?MODULE, self()}]),
    ok = mcl_om_pubsub:publish(?TOPIC1, #{probe => 1}, #{mode => sync}),
    Event1 = await_event(?TOPIC1, 10_000),
    %% Pubsub payloads arrive in the 11.x wire shape (text keys as
    %% {text, _} markers, D26) -- mcl_om_wire:field/2 is the contract
    %% every handler reads them through.
    ?assertEqual(1, mcl_om_wire:field(probe, Event1)),

    [{?TOPIC1, Topic1Pid, worker, _}] = supervisor:which_children(mcl_om_pubsub_sup),
    ?assert(is_pid(Topic1Pid)),

    %% 2. Add a second topic. The first child is untouched (same pid);
    %% the new one is genuinely subscribed too.
    ok = mcl_om_pubsub:ensure_subscriptions(
           [{?TOPIC1, ?MODULE, self()}, {?TOPIC2, ?MODULE, self()}]),
    ok = mcl_om_pubsub:publish(?TOPIC2, #{probe => 2}, #{mode => sync}),
    Event2 = await_event(?TOPIC2, 10_000),
    ?assertEqual(2, mcl_om_wire:field(probe, Event2)),

    Children2 = lists:sort(supervisor:which_children(mcl_om_pubsub_sup)),
    [{?TOPIC1, Topic1PidAgain, worker, _}, {?TOPIC2, Topic2Pid, worker, _}] = Children2,
    ?assertEqual(Topic1Pid, Topic1PidAgain),
    ?assert(is_pid(Topic2Pid)),

    %% 3. Remove the first topic. Only it disappears; the second one's
    %% pid is still untouched.
    ok = mcl_om_pubsub:ensure_subscriptions([{?TOPIC2, ?MODULE, self()}]),
    Children3 = supervisor:which_children(mcl_om_pubsub_sup),
    ?assertEqual([{?TOPIC2, Topic2Pid, worker, [?MODULE]}], Children3),

    %% Stop the subscribers before closing the pool -- otherwise
    %% macula_subscriber correctly (if noisily) reacts to a real
    %% pool_closed event and crashes, which is expected behavior but
    %% not what this test is trying to demonstrate.
    stop_supervisor(Sup),
    catch gen_server:stop(Subs),
    meck:unload(mcl_om),
    catch macula_client:close(Pool),
    ok.

%% A puzzle-hardened identity key at the fleet's difficulty -- the PQ
%% stations refuse a CONNECT/HELLO from a node id that does not meet
%% it (about 0.4 s per key in pq_hybrid).
identity_key() ->
    {ok, K} = macula_node_keys:generate(
               identity, profile(),
               #{puzzle_difficulty => macula_node_keys:puzzle_difficulty()}),
    K.

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.

%% supervisor:stop/1 does not exist (unlike gen_server:stop/1) --
%% unlink first so the shutdown exit signal doesn't propagate back and
%% kill this (non-trapping) test process, then wait for confirmation.
stop_supervisor(Sup) ->
    unlink(Sup),
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5_000 -> ok
    end.

await_event(Topic, Timeout) ->
    receive
        {subscriber_event, Topic, Payload} -> Payload
    after Timeout ->
        erlang:error({event_not_received, Topic})
    end.

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).

%% macula_subscriber callbacks -- forward every event to whichever
%% test process subscribed (passed as Args).
init(TestPid) -> {ok, TestPid}.

handle_event(Topic, Payload, _Meta, TestPid) ->
    TestPid ! {subscriber_event, Topic, Payload},
    {noreply, TestPid}.
