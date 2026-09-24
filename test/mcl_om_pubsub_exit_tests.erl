%% @doc A publisher that dies is a failed publish, and never takes its caller
%% with it.
%%
%% macula 12.2's macula_publisher returns `{ok, Pid}' as soon as it runs and
%% announces afterwards, so a failed start announcement now ends the
%% publisher after start_link has returned. A publisher is linked to whoever
%% started it, so that exit reached the service process that called
%% mcl_om_pubsub:publish/2 and killed it; a crashed publish worker did the same
%% already. mcl_om_pubsub now starts each publisher under a watcher of its own,
%% which logs and counts an abnormal exit and, for a `sync' caller, answers it
%% at once rather than after its timeout.
%%
%% The failures are injected through macula_publisher's own `publish' and
%% `fact_publish' options, which mcl_om_pubsub passes through as
%% `publisher_opts'. The pool is never used by an injected function, so any pid
%% stands in for it.
-module(mcl_om_pubsub_exit_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REALM, <<16#11:256>>).
-define(TOPIC, <<"exit.test">>).

raises(_Pool, _Realm, _Topic, _Payload) -> error(pool_gone).
lands(_Pool, _Realm, _Topic, _Payload) -> ok.

%% Run Fun in a fresh process and report how it ended, so a test can observe a
%% caller being killed rather than being killed itself.
in_caller(Fun) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() -> Self ! {self(), Fun()}, timer:sleep(300) end),
    receive
        {Pid, Result} ->
            receive {'DOWN', Ref, process, Pid, Why} -> {Result, Why} end;
        {'DOWN', Ref, process, Pid, Why} ->
            {no_result, Why}
    after 5000 ->
        {timeout, still_running}
    end.

an_announcement_that_raises_does_not_kill_the_caller_test() ->
    Before = mcl_om_pubsub:failed_publishes(),
    Opts = #{mode => async_silent,
             publisher_opts => #{fact_publish => fun raises/4, publish => fun lands/4}},
    ?assertEqual({ok, normal},
                 in_caller(fun() -> mcl_om_pubsub:publish_on(self(), ?REALM, ?TOPIC, x, Opts) end)),
    ?assertEqual(Before + 1, mcl_om_pubsub:failed_publishes()).

a_sync_caller_hears_of_the_exit_at_once_test() ->
    Opts = #{mode => sync, timeout => 4000,
             publisher_opts => #{announce => false, publish => fun raises/4}},
    Started = erlang:monotonic_time(millisecond),
    {Result, normal} = in_caller(fun() -> mcl_om_pubsub:publish_on(self(), ?REALM, ?TOPIC, x, Opts) end),
    ?assertMatch({error, {publisher_exited, _}}, Result),
    ?assert(erlang:monotonic_time(millisecond) - Started < 2000).

a_publish_that_lands_is_not_counted_as_failed_test() ->
    Before = mcl_om_pubsub:failed_publishes(),
    Opts = #{mode => sync,
             publisher_opts => #{announce => false, publish => fun lands/4}},
    ?assertEqual({ok, normal},
                 in_caller(fun() -> mcl_om_pubsub:publish_on(self(), ?REALM, ?TOPIC, x, Opts) end)),
    ?assertEqual(Before, mcl_om_pubsub:failed_publishes()).

%% announce => false: the payload alone, no start/completed facts.
announce_false_publishes_no_facts_test() ->
    Self = self(),
    Opts = #{mode => sync,
             publisher_opts => #{announce => false,
                                 fact_publish => fun(_, _, T, _) -> Self ! {fact, T}, ok end,
                                 publish => fun lands/4}},
    ok = mcl_om_pubsub:publish_on(self(), ?REALM, ?TOPIC, x, Opts),
    receive {fact, T} -> ?assertEqual(no_fact, T) after 200 -> ok end.
