%%% @doc Tests for the guard's counters, stats and alert-fact decisions
%%% (mcl-om#13), against the real gen_server and its real ETS table.
%%% Every test declares its own procedure: the counters and the limits
%%% are per procedure and persist for the module's lifetime, so sharing
%%% one name would make the tests order-dependent.
%%%
%%% The guard starts under a KEEPER process, not the eunit setup
%%% process: start_link makes the caller the gen_server's parent, and
%%% eunit exits its setup process once the fixture is built — which
%%% takes the guard (and its table) down with it, mid-fixture.
-module(mcl_om_guard_tests).

-include_lib("eunit/include/eunit.hrl").

guard_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Ctx) ->
        [
            fun a_callers_bucket_is_per_procedure_and_per_caller/0,
            fun the_global_key_has_its_own_bucket/0,
            fun stats_report_the_window_and_denial_counters/0,
            fun the_stats_reply_passes_the_wire_codec_test/0,
            fun the_audit_ring_records_changes/0,
            fun should_report_only_flags_new_windows_with_activity/0,
            fun alert_payload_is_numbers_and_binaries_only/0,
            fun the_alert_payload_names_the_offenders/0
        ]
    end}.

setup() ->
    mcl_om_guard_limits:clear(),
    start_guard().

teardown({Pid, Keeper}) ->
    Keeper ! stop,
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok end,
    mcl_om_guard_limits:clear().

%% The keeper holds the parent link instead of the (short-lived) eunit
%% setup process, so the guard survives the fixture build.
start_guard() ->
    Parent = self(),
    Keeper = spawn(fun() ->
                           Pid = start_tolerating_stray(),
                           Parent ! {guard_started, self(), Pid},
                           receive stop -> ok end
                   end),
    receive {guard_started, Keeper, Pid} -> {Pid, Keeper} end.

%% A previous module's in-test guard can still hold the name when this
%% module's setup runs; wait for it, then start.
start_tolerating_stray() ->
    case mcl_om_guard:start_link() of
        {ok, Pid} ->
            Pid;
        {error, {already_started, Stray}} ->
            Ref = erlang:monitor(process, Stray),
            receive {'DOWN', Ref, _, _, _Reason} -> ok
            after 5000 ->
                exit(Stray, kill),
                receive {'DOWN', Ref, _, _, _Reason} -> ok end
            end,
            {ok, Pid} = mcl_om_guard:start_link(),
            Pid
    end.

declare_proc() ->
    Proc = proc_name(),
    ok = mcl_om_guard_limits:declare(Proc,
        #{max_payload_external_size => 4096, per_caller_max => 3, global_max => 50}),
    Proc.

proc_name() ->
    N = erlang:unique_integer([positive, monotonic]),
    <<"t/p", (integer_to_binary(N))/binary>>.

limits_for(Proc) ->
    maps:get(limits, mcl_om_guard_limits:get(Proc)).

a_callers_bucket_is_per_procedure_and_per_caller() ->
    Proc = declare_proc(),
    Other = declare_proc(),
    L = limits_for(Proc),
    C1 = <<"c1">>, C2 = <<"c2">>,
    [?assertEqual(allow, mcl_om_guard:allow(Proc, C1, L)) || _ <- lists:seq(1, 3)],
    ?assertEqual(deny, mcl_om_guard:allow(Proc, C1, L)),
    ?assertEqual(allow, mcl_om_guard:allow(Proc, C2, L)),
    ?assertEqual(allow, mcl_om_guard:allow(Other, C1, L)).

the_global_key_has_its_own_bucket() ->
    Proc = declare_proc(),
    L = limits_for(Proc),
    C1 = <<"c1">>,
    [?assertEqual(allow, mcl_om_guard:allow(Proc, C1, L)) || _ <- lists:seq(1, 3)],
    ?assertEqual(deny, mcl_om_guard:allow(Proc, C1, L)),
    ?assertEqual(allow, mcl_om_guard:allow(Proc, '$global', L)).

stats_report_the_window_and_denial_counters() ->
    Proc = declare_proc(),
    L = limits_for(Proc),
    [mcl_om_guard:allow(Proc, <<"c1">>, L) || _ <- lists:seq(1, 3)],
    _ = mcl_om_guard:allow(Proc, <<"c1">>, L),
    ok = mcl_om_guard:count_denial(Proc, size),
    Stats = mcl_om_guard:stats(Proc),
    ?assertEqual(1, maps:get(denied_rate, Stats)),
    ?assertEqual(1, maps:get(denied_size, Stats)),
    ?assert(maps:get(callers_over_limit, Stats) >= 1),
    ?assertEqual(3, maps:get(per_caller_max, maps:get(limits, Stats))),
    Top = maps:get(top_callers, Stats),
    ?assert(lists:any(fun(#{caller := C, count := N}) ->
                              C =:= <<"6331">> andalso N >= 4
                      end, Top)).

%% The wire codec refuses tuples and non-UTF-8 binaries-as-text; a stats
%% reply carrying a real node id must pass check_payload/1 outright.
%% The guard is ensured here rather than assumed: eunit fixture timing
%% can take the fixture's instance down before the last test, so this
%% test starts its own (linked to this test process, dying with it).
the_stats_reply_passes_the_wire_codec_test() ->
    case mcl_om_guard:start_link() of
        {ok, _OwnPid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end,
    Proc = declare_proc(),
    L = limits_for(Proc),
    BadCaller = <<0, 255, 1, 2>>,
    [mcl_om_guard:allow(Proc, BadCaller, L) || _ <- lists:seq(1, 3)],
    _ = mcl_om_guard:allow(Proc, BadCaller, L),
    {ok, Reply} = mcl_om_guard_control:get_limits(#{procedure => Proc}),
    ?assertEqual(ok, macula_frame:check_payload(Reply)).

the_audit_ring_records_changes() ->
    Proc = declare_proc(),
    ok = mcl_om_guard:record_change(Proc,
        #{tier => operator, caller => <<"me">>, before => #{}, 'after' => #{}}),
    Stats = mcl_om_guard:stats(Proc),
    ?assertEqual(1, length(maps:get(audit, Stats))),
    ?assertEqual(operator, maps:get(tier, hd(maps:get(audit, Stats)))).

should_report_only_flags_new_windows_with_activity() ->
    Quiet = #{current_window => 1000, denied_rate => 0, denied_size => 0,
              callers_over_limit => 0, global_count => 0},
    Active = Quiet#{denied_rate => 1},
    ?assertNot(mcl_om_guard:should_report(1000, undefined, Quiet)),
    ?assertNot(mcl_om_guard:should_report(1000, 1000, Active)),
    ?assert(mcl_om_guard:should_report(2000, 1000, Active)).

alert_payload_is_numbers_and_binaries_only() ->
    L = mcl_om_guard_limits:defaults(),
    Stats = #{current_window => 2000, denied_rate => 1, denied_size => 0,
              callers_over_limit => 1, global_count => 4,
              distinct_callers => 1, top_callers => []},
    Payload = mcl_om_guard:alert_payload(<<"t/proc">>, L, Stats),
    ?assertEqual(<<"t/proc">>, maps:get(procedure, Payload)),
    ?assertEqual(2000, maps:get(window_start_ms, Payload)),
    ?assertEqual(maps:get(per_caller_max, L), maps:get(per_caller_max, Payload)),
    ?assertEqual(maps:get(global_max, L), maps:get(global_max, Payload)).

%% The guardian's rule can only counter what the fact tells it: without
%% the offenders in the payload, a proposal is a blind floor. The stats
%% already compute top_callers in a wire-safe shape (list of maps,
%% hex-encoded caller ids) — the alert fact must carry them, and the
%% payload must pass the wire codec outright.
the_alert_payload_names_the_offenders() ->
    L = mcl_om_guard_limits:defaults(),
    Stats = #{current_window => 2000, denied_rate => 1, denied_size => 2,
              callers_over_limit => 1, global_count => 4,
              distinct_callers => 2,
              top_callers => [#{caller => <<"00ff">>, count => 5}]},
    Payload = mcl_om_guard:alert_payload(<<"t/proc">>, L, Stats),
    ?assertEqual(2, maps:get(distinct_callers, Payload)),
    ?assertEqual([#{caller => <<"00ff">>, count => 5}],
                 maps:get(top_callers, Payload)),
    ?assertEqual(ok, macula_frame:check_payload(Payload)).
