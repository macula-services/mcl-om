%%% @doc Tests for the guardian control surface (mcl-om#13): the
%%% capability pair, its gating config, and the handler semantics
%%% (envelope, audit, no-op).
-module(mcl_om_guard_control_tests).

-include_lib("eunit/include/eunit.hrl").

control_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Pid) ->
        [
            fun with_caps_always_adds_get_limits/0,
            fun without_guardian_config_set_limits_is_absent/0,
            fun with_guardian_config_set_limits_carries_the_guardian_tier/0,
            fun a_service_declaring_its_own_name_is_refused/0,
            fun get_limits_answers_one_procedure_or_all/0,
            fun the_guardian_set_is_envelope_bound_and_audited/0,
            fun the_guardian_cannot_change_the_envelope/0,
            fun an_unchanged_set_is_a_noop_without_an_audit_entry/0,
            fun bad_payloads_are_refused/0
        ]
    end}.

setup() ->
    application:unset_env(mcl_om, inbound_guard),
    persistent_term:erase({mcl_om_guard_control, warned}),
    mcl_om_guard_limits:clear(),
    {ok, Pid} = mcl_om_guard:start_link(),
    Pid.

teardown(Pid) ->
    Ref = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok end,
    application:unset_env(mcl_om, inbound_guard),
    persistent_term:erase({mcl_om_guard_control, warned}),
    mcl_om_guard_limits:clear().

declare_proc() ->
    Proc = proc_name(),
    ok = mcl_om_guard_limits:declare(Proc,
        #{per_caller_max => 30,
          envelope => #{per_caller_max => #{min => 10, max => 50}}}),
    Proc.

proc_name() ->
    N = erlang:unique_integer([positive, monotonic]),
    <<"t/c", (integer_to_binary(N))/binary>>.

guardian_env() ->
    application:set_env(mcl_om, inbound_guard,
        #{guardian => #{realm_did => crypto:strong_rand_bytes(32),
                        guardian_tier => <<"guardian">>}}).

audit_of(Proc) ->
    maps:get(audit, mcl_om_guard:stats(Proc)).

with_caps_always_adds_get_limits() ->
    Caps = mcl_om_guard_control:with_caps([]),
    ?assertEqual([<<"get_limits">>], [maps:get(name, C) || C <- Caps]),
    [GetCap | _] = Caps,
    ?assertEqual(open, maps:get(auth, GetCap)),
    ?assertEqual({mcl_om_simple_handler, {mcl_om_guard_control, get_limits}},
                 maps:get(handler, GetCap)).

without_guardian_config_set_limits_is_absent() ->
    Caps = mcl_om_guard_control:with_caps([#{name => <<"echo">>, version => 1}]),
    ?assertEqual([<<"get_limits">>, <<"echo">>], [maps:get(name, C) || C <- Caps]).

with_guardian_config_set_limits_carries_the_guardian_tier() ->
    guardian_env(),
    Caps = mcl_om_guard_control:with_caps([]),
    [_GetCap, SetCap] = Caps,
    ?assertEqual(<<"set_limits">>, maps:get(name, SetCap)),
    ?assertMatch({realm_member_required, <<_:256>>, <<"guardian">>},
                 maps:get(auth, SetCap)),
    application:unset_env(mcl_om, inbound_guard).

a_service_declaring_its_own_name_is_refused() ->
    ?assertError({mcl_om_guard_capability_name_reserved, <<"get_limits">>},
                 mcl_om_guard_control:with_caps([#{name => <<"get_limits">>, version => 1}])).

get_limits_answers_one_procedure_or_all() ->
    Proc = declare_proc(),
    {ok, Stats} = mcl_om_guard_control:get_limits(#{procedure => Proc}),
    ?assertEqual(30, maps:get(per_caller_max, maps:get(limits, Stats))),
    {ok, All} = mcl_om_guard_control:get_limits(no_map_payload),
    ?assert(maps:is_key(Proc, maps:get(procedures, All))),
    ?assertEqual({error, {bad_procedure, 42}},
                 mcl_om_guard_control:get_limits(#{procedure => 42})).

the_guardian_set_is_envelope_bound_and_audited() ->
    Proc = declare_proc(),
    Payload = #{procedure => Proc, limits => #{per_caller_max => 40}, caller => <<"g1">>},
    ?assertMatch({ok, _}, mcl_om_guard_control:set_limits(Payload)),
    ?assertEqual({error, {envelope_exceeded, per_caller_max, 60}},
                 mcl_om_guard_control:set_limits(
                     Payload#{limits := #{per_caller_max => 60}})),
    ?assertEqual({error, {unknown_procedure, <<"nope/x">>}},
                 mcl_om_guard_control:set_limits(Payload#{procedure := <<"nope/x">>})),
    Audit = audit_of(Proc),
    ?assertEqual(1, length(Audit)),
    ?assertEqual(guardian, maps:get(tier, hd(Audit))),
    ?assertEqual(<<"g1">>, maps:get(caller, hd(Audit))).

the_guardian_cannot_change_the_envelope() ->
    Proc = declare_proc(),
    Payload = #{procedure => Proc,
                limits => #{envelope => #{per_caller_max => #{min => 1, max => 5}}},
                caller => <<"g1">>},
    ?assertEqual({error, envelope_operator_only},
                 mcl_om_guard_control:set_limits(Payload)),
    ?assertEqual(0, length(audit_of(Proc))).

an_unchanged_set_is_a_noop_without_an_audit_entry() ->
    Proc = declare_proc(),
    Payload = #{procedure => Proc, limits => #{per_caller_max => 40}, caller => <<"g1">>},
    {ok, _} = mcl_om_guard_control:set_limits(Payload),
    {ok, _} = mcl_om_guard_control:set_limits(Payload),
    ?assertEqual(1, length(audit_of(Proc))).

bad_payloads_are_refused() ->
    ?assertEqual({error, bad_payload},
                 mcl_om_guard_control:set_limits(not_a_map)),
    ?assertEqual({error, bad_procedure},
                 mcl_om_guard_control:set_limits(#{limits => #{per_caller_max => 1}})),
    ?assertEqual({error, bad_limits},
                 mcl_om_guard_control:set_limits(#{procedure => <<"t/x">>})).
