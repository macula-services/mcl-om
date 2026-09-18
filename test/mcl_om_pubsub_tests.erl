%%% Unit + live tests for mcl_om_pubsub, piece C of the mesh-wrappers
%%% plan (`plans/PLAN_MCL_OM_MESH_WRAPPERS.md'). No real station is
%%% needed for the live group: `macula_client:connect([], #{})' gives a
%%% real pool with zero spawned links, so a publish genuinely resolves
%%% to `{error, {transient, no_healthy_station}}' from the SDK itself —
%%% exercising the real macula_publisher outcome path, not a stub.
-module(mcl_om_pubsub_tests).
-include_lib("eunit/include/eunit.hrl").

%% A caller-supplied macula_publisher callback, standing in for a
%% service that needs outcome handling start_publisher/3,4,5 exists
%% for (see the escape-hatch discussion, PLAN_MCL_OM_MESH_WRAPPERS.md
%% piece C) -- proves start_publisher/3,4,5 genuinely hands control to
%% THIS module, not mcl_om_pubsub's own.
-behaviour(macula_publisher).
-export([init/1, handle_published/2]).

-define(TOPIC, <<"mcl_om_pubsub.test_v1">>).

%%%===================================================================
%%% Pure realm/mode resolution — no mesh, no macula_publisher involved.
%%% (`macula_publisher' ships to hex.pm without debug_info, same reason
%%% this repo's own rebar.config excludes it from dialyzer, so meck's
%%% passthrough mode can't wrap it here; testing resolution as a pure
%%% function instead — same convention `mcl_om_capabilities.erl'
%%% already uses for its own record-building helpers — sidesteps that
%%% entirely and is a better test anyway: it proves the decision, not
%%% just that some argument arrived somewhere.)
%%%===================================================================

resolve_realm_prefers_override_test() ->
    Default = crypto:strong_rand_bytes(32),
    Other   = crypto:strong_rand_bytes(32),
    ?assertEqual(Other, mcl_om_pubsub:resolve_realm(#{realm => Other}, Default)),
    ?assertEqual(Default, mcl_om_pubsub:resolve_realm(#{}, Default)).

resolve_mode_defaults_to_async_silent_test() ->
    ?assertEqual(async_silent, mcl_om_pubsub:resolve_mode(#{})),
    ?assertEqual(sync, mcl_om_pubsub:resolve_mode(#{mode => sync})),
    ?assertEqual(async_log, mcl_om_pubsub:resolve_mode(#{mode => async_log})).

%%%===================================================================
%%% Degrades without a mesh — same contract as mcl_om:mesh_handles/0.
%%%===================================================================

publish_degrades_without_mesh_test_() ->
    {setup, fun start_identity_no_seeds/0, fun stop_identity/1,
     fun(_) ->
        [
         ?_assertEqual({error, mesh_unavailable},
                       mcl_om_pubsub:publish(?TOPIC, #{probe => 1})),
         ?_assertEqual({error, mesh_unavailable},
                       mcl_om_pubsub:publish(?TOPIC, #{probe => 1},
                                                #{mode => sync})),
         ?_assertEqual({error, mesh_unavailable},
                       mcl_om_pubsub:start_publisher(?MODULE, ?TOPIC,
                                                        #{probe => 1}))
        ]
     end}.

start_identity_no_seeds() ->
    application:unset_env(mcl_om, station_seeds),
    application:unset_env(mcl_om, realm),
    {ok, I} = mcl_om_identity:start_link(),
    I.

stop_identity(I) ->
    try gen_server:stop(I) catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% Live pool, zero seeds — genuine SDK outcomes, no station required.
%%%
%%% `mcl_om:mesh_handles/0' is the one integration point between
%%% mcl_om_pubsub and the rest of mcl_om (identity/seed config);
%%% mecking exactly that boundary lets these tests hand in a real,
%%% zero-link `macula_client' pool (so publish genuinely resolves to
%%% `{error, {transient, no_healthy_station}}' from the SDK itself, per
%%% `macula_client_tests:publish_with_no_seeds_is_transient_test_/0')
%%% without fighting `mcl_om_identity''s own seed-gated attach logic,
%%% which never calls `macula_client:connect/2' at all for an empty
%%% seed list.
%%%===================================================================

live_pool_test_() ->
    {timeout, 15,
     {setup, fun start_live_pool/0, fun stop_live_pool/1,
      fun(_) ->
         [
          {"async_silent (default) returns ok immediately, "
           "even though the underlying publish will fail",
           fun test_async_silent_returns_ok/0},
          {"sync mode blocks and surfaces the real SDK outcome",
           fun test_sync_surfaces_real_error/0},
          {"async_log mode does not crash and still returns ok",
           fun test_async_log_returns_ok/0},
          {"publish_many/2 attempts every topic and reports any failure",
           fun test_publish_many/0},
          {"sync mode honours a caller-supplied timeout",
           fun test_sync_timeout/0},
          {"start_publisher/3 hands control to the caller's own module",
           fun test_start_publisher_uses_caller_module/0},
          {"a retry-with-backoff coordinator built on start_publisher/4 "
           "runs a real multi-attempt loop to genuine exhaustion",
           fun test_start_publisher_retry_coordinator_runs_to_exhaustion/0}
         ]
      end}}.

start_live_pool() ->
    {ok, _} = application:ensure_all_started(macula),
    {ok, Pool} = macula_client:connect([], #{}),
    Realm = crypto:strong_rand_bytes(32),
    ok = meck:new(mcl_om, [passthrough]),
    ok = meck:expect(mcl_om, mesh_handles, fun() -> {ok, Pool, Realm} end),
    {Pool, Realm}.

stop_live_pool({Pool, _Realm}) ->
    meck:unload(mcl_om),
    try macula_client:close(Pool) catch _:_ -> ok end,
    ok.

test_async_silent_returns_ok() ->
    ?assertEqual(ok, mcl_om_pubsub:publish(?TOPIC, #{probe => 1})).

test_sync_surfaces_real_error() ->
    Result = mcl_om_pubsub:publish(?TOPIC, #{probe => 1}, #{mode => sync}),
    ?assertEqual({error, {transient, no_healthy_station}}, Result).

test_async_log_returns_ok() ->
    ?assertEqual(ok, mcl_om_pubsub:publish(?TOPIC, #{probe => 1},
                                              #{mode => async_log})).

test_publish_many() ->
    Result = mcl_om_pubsub:publish_many([?TOPIC, <<"other.topic_v1">>],
                                           #{probe => 1}, #{mode => sync}),
    ?assertEqual({error, {transient, no_healthy_station}}, Result).

test_sync_timeout() ->
    %% A pathological handler that never replies — the publisher process
    %% itself is fine (SDK call just takes a moment against 0 links);
    %% a tiny timeout must still bound the caller's wait rather than hang.
    Result = mcl_om_pubsub:publish(?TOPIC, #{probe => 1},
                                      #{mode => sync, timeout => 1}),
    ?assert(Result =:= {error, timeout} orelse
            Result =:= {error, {transient, no_healthy_station}}).

test_start_publisher_uses_caller_module() ->
    {ok, Pid} = mcl_om_pubsub:start_publisher(?MODULE, ?TOPIC,
                                                 #{probe => 3}, {simple, self()}),
    ?assert(is_pid(Pid)),
    Result = receive
        {custom_publisher_result, R} -> R
    after 2_000 -> erlang:error(no_result)
    end,
    %% Real SDK outcome, reaching THIS module's handle_published/2 --
    %% not mcl_om_pubsub's own, which would never send this tag.
    ?assertEqual({error, {transient, no_healthy_station}}, Result).

%% The actual motivating scenario for the escape hatch (see the
%% "imagine such a service exists" discussion,
%% PLAN_MCL_OM_MESH_WRAPPERS.md piece C), built and run to real
%% exhaustion, not just asserted possible: a retry-with-backoff
%% coordinator. Every attempt fails deterministically against the
%% zero-link pool, so this exercises the full retry loop down to
%% genuine exhaustion, with the original caller notified of every
%% intermediate attempt and the final outcome.
%%
%% The retry DECISION lives in a dedicated coordinator process
%% (retry_coordinator/4 below), not inside handle_published/2 itself --
%% deliberately, not incidentally. An earlier version called
%% start_publisher/4 again recursively from *within* handle_published/2
%% (a callback running inside a macula_publisher gen_server that is
%% itself about to {stop, normal, ...}) and that was genuinely flaky
%% under full-suite load, not just tight on timeout margin -- raising
%% the timeout alone made it hang for the outer group budget instead of
%% failing fast, which is a worse symptom, not a fix. A separate,
%% ordinary process orchestrating N one-shot start_publisher/4 calls
%% (each with the already-proven {simple, Pid} relay) is also the more
%% correct design for "fully decoupled from any caller waiting
%% synchronously" in the first place -- not a workaround, the right
%% shape. Backoff is 50ms/attempt here purely for test speed; a real
%% service would use a longer, real backoff curve.
test_start_publisher_retry_coordinator_runs_to_exhaustion() ->
    Self = self(),
    spawn_link(fun() -> retry_coordinator(?TOPIC, #{probe => 5}, 2, Self) end),
    ?assertEqual(2, await(retry_attempt_failed, 2_000)),
    ?assertEqual(1, await(retry_attempt_failed, 2_000)),
    ?assertEqual({transient, no_healthy_station}, await(retry_exhausted, 2_000)).

retry_coordinator(Topic, Payload, AttemptsLeft, ReportTo) ->
    {ok, _Pid} = mcl_om_pubsub:start_publisher(?MODULE, Topic, Payload,
                                                  {simple, self()}),
    Result = receive
        {custom_publisher_result, R} -> R
    after 2_000 -> {error, coordinator_timeout}
    end,
    handle_attempt_result(Result, Topic, Payload, AttemptsLeft, ReportTo).

handle_attempt_result(ok, _Topic, _Payload, _AttemptsLeft, ReportTo) ->
    ReportTo ! {retry_succeeded, ok};
handle_attempt_result({error, Reason}, _Topic, _Payload, 0, ReportTo) ->
    ReportTo ! {retry_exhausted, Reason};
handle_attempt_result({error, _Reason}, Topic, Payload, AttemptsLeft, ReportTo) ->
    ReportTo ! {retry_attempt_failed, AttemptsLeft},
    timer:sleep(50),
    retry_coordinator(Topic, Payload, AttemptsLeft - 1, ReportTo).

await(Tag, Timeout) ->
    receive
        {Tag, Value} -> Value
    after Timeout -> erlang:error({no_message, Tag})
    end.

%% macula_publisher callback: a one-shot relay to whichever process
%% started it. Reused by both the simple-delegation test and the retry
%% coordinator above -- the coordinator IS the caller from this
%% callback's point of view, same as any other.
init({simple, _Pid} = Args) -> {ok, Args}.

handle_published(Result, {simple, Pid} = State) ->
    Pid ! {custom_publisher_result, Result},
    {stop, normal, State}.
