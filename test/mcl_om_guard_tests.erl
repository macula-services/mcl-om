%%% @doc Tests for the guard's counters, stats and alert-fact decisions
%%% (mcl-om#13), against the real gen_server and its real ETS table.
%%% Every test declares its own procedure: the counters and the limits
%%% are per procedure and persist for the module's lifetime, so sharing
%%% one name would make the tests order-dependent.
-module(mcl_om_guard_tests).

-include_lib("eunit/include/eunit.hrl").

guard_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Pid) ->
        [
            fun a_callers_bucket_is_per_procedure_and_per_caller/0,
            fun the_global_key_has_its_own_bucket/0,
            fun stats_report_the_window_and_denial_counters/0,
            fun the_audit_ring_records_changes/0,
            fun should_report_only_flags_new_windows_with_activity/0,
            fun alert_payload_is_numbers_and_binaries_only/0
        ]
    end}.

setup() ->
    mcl_om_guard_limits:clear(),
    {ok, Pid} = mcl_om_guard:start_link(),
    Pid.

teardown(Pid) ->
    Ref = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok end,
    mcl_om_guard_limits:clear().

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
    ?assertEqual(3, maps:get(per_caller_max, maps:get(limits, Stats))).

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
              callers_over_limit => 1, global_count => 4},
    Payload = mcl_om_guard:alert_payload(<<"t/proc">>, L, Stats),
    ?assertEqual(<<"t/proc">>, maps:get(procedure, Payload)),
    ?assertEqual(2000, maps:get(window_start_ms, Payload)),
    ?assertEqual(maps:get(per_caller_max, L), maps:get(per_caller_max, Payload)),
    ?assertEqual(maps:get(global_max, L), maps:get(global_max, Payload)).
