%%% @doc Tests for the guard's per-procedure limits + envelope (mcl-om#13):
%%% defaults, declare/redeclare semantics, tier-gated sets and validation.
-module(mcl_om_guard_limits_tests).

-include_lib("eunit/include/eunit.hrl").

limits_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Ok) ->
        [
            fun declares_merge_over_the_framework_defaults/0,
            fun redeclare_keeps_runtime_overrides/0,
            fun guardian_tier_is_bound_by_the_envelope/0,
            fun guardian_tier_cannot_move_unenveloped_keys/0,
            fun guardian_tier_cannot_change_the_envelope/0,
            fun operator_tier_may_exceed_and_set_the_envelope/0,
            fun rejects_unknown_keys_and_bad_values/0,
            fun reset_restores_the_declared_base/0,
            fun an_unknown_procedure_is_refused/0
        ]
    end}.

setup() ->
    mcl_om_guard_limits:clear(),
    ok.

teardown(_Ok) ->
    mcl_om_guard_limits:clear(),
    ok.

declares_merge_over_the_framework_defaults() ->
    ok = mcl_om_guard_limits:declare(<<"acme/echo">>, #{max_payload_external_size => 4096}),
    #{limits := Limits} = mcl_om_guard_limits:get(<<"acme/echo">>),
    ?assertEqual(4096, maps:get(max_payload_external_size, Limits)),
    ?assertEqual(600, maps:get(per_caller_max, Limits)).

redeclare_keeps_runtime_overrides() ->
    ok = mcl_om_guard_limits:declare(<<"acme/echo">>, #{per_caller_max => 30}),
    {ok, _} = mcl_om_guard_limits:set(<<"acme/echo">>, #{per_caller_max => 40}, operator),
    ok = mcl_om_guard_limits:declare(<<"acme/echo">>, #{per_caller_max => 30}),
    #{limits := Limits} = mcl_om_guard_limits:get(<<"acme/echo">>),
    ?assertEqual(40, maps:get(per_caller_max, Limits)).

guardian_tier_is_bound_by_the_envelope() ->
    ok = mcl_om_guard_limits:declare(<<"acme/echo">>,
        #{per_caller_max => 30,
          envelope => #{per_caller_max => #{min => 10, max => 50}}}),
    ?assertMatch({ok, _},
                 mcl_om_guard_limits:set(<<"acme/echo">>, #{per_caller_max => 40}, guardian)),
    ?assertEqual({error, {envelope_exceeded, per_caller_max, 60}},
                 mcl_om_guard_limits:set(<<"acme/echo">>, #{per_caller_max => 60}, guardian)).

guardian_tier_cannot_move_unenveloped_keys() ->
    ok = mcl_om_guard_limits:declare(<<"acme/echo">>, #{}),
    ?assertEqual({error, {envelope_exceeded, global_max, 5}},
                 mcl_om_guard_limits:set(<<"acme/echo">>, #{global_max => 5}, guardian)).

guardian_tier_cannot_change_the_envelope() ->
    ok = mcl_om_guard_limits:declare(<<"acme/echo">>, #{}),
    ?assertEqual({error, envelope_operator_only},
                 mcl_om_guard_limits:set(<<"acme/echo">>,
                     #{envelope => #{per_caller_max => #{min => 1, max => 2}}}, guardian)).

operator_tier_may_exceed_and_set_the_envelope() ->
    ok = mcl_om_guard_limits:declare(<<"acme/echo">>, #{}),
    ?assertMatch({ok, _},
                 mcl_om_guard_limits:set(<<"acme/echo">>,
                     #{per_caller_max => 99999, global_max => 100000,
                       envelope => #{per_caller_max => #{min => 1, max => 100000}}}, operator)),
    #{limits := Limits, envelope := Envelope} = mcl_om_guard_limits:get(<<"acme/echo">>),
    ?assertEqual(99999, maps:get(per_caller_max, Limits)),
    ?assertEqual(100000, maps:get(global_max, Limits)),
    ?assertEqual(#{min => 1, max => 100000}, maps:get(per_caller_max, Envelope)).

rejects_unknown_keys_and_bad_values() ->
    ok = mcl_om_guard_limits:declare(<<"acme/echo">>, #{}),
    ?assertEqual({error, {unknown_key, nope}},
                 mcl_om_guard_limits:set(<<"acme/echo">>, #{nope => 1}, operator)),
    ?assertEqual({error, {not_a_positive_integer, window_ms, 0}},
                 mcl_om_guard_limits:set(<<"acme/echo">>, #{window_ms => 0}, operator)),
    ?assertEqual({error, {per_caller_above_global, 9999, 10}},
                 mcl_om_guard_limits:set(<<"acme/echo">>,
                     #{per_caller_max => 9999, global_max => 10}, operator)),
    ?assertEqual({error, {bad_envelope_clamp, per_caller_max, #{min => 50, max => 10}}},
                 mcl_om_guard_limits:set(<<"acme/echo">>,
                     #{envelope => #{per_caller_max => #{min => 50, max => 10}}}, operator)).

reset_restores_the_declared_base() ->
    ok = mcl_om_guard_limits:declare(<<"acme/echo">>, #{per_caller_max => 30}),
    {ok, _} = mcl_om_guard_limits:set(<<"acme/echo">>, #{per_caller_max => 40}, operator),
    {ok, #{limits := Limits}} = mcl_om_guard_limits:reset(<<"acme/echo">>),
    ?assertEqual(30, maps:get(per_caller_max, Limits)).

an_unknown_procedure_is_refused() ->
    ?assertEqual({error, {unknown_procedure, <<"nope/never">>}},
                 mcl_om_guard_limits:set(<<"nope/never">>, #{per_caller_max => 1}, operator)).
