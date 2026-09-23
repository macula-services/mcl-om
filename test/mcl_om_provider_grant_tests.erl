%%% Unit tests for mcl_om_provider_grant: what each provider_authorization
%%% answer means for /health.
%%%
%%% A provider with no D25 grant used to look healthy while serving nothing:
%%% mcl_om_capabilities retried quietly on every republish tick and /health
%%% said ok. The rules these pin down:
%%%   - no procedure_delegation for this node: degraded at once, an operator
%%%     has to act;
%%%   - no org_directory, or any other refusal: waiting for a grace window,
%%%     then degraded, with macula's reason as given. The realm republishes
%%%     an absent chain within seconds, so a gap past the window is a real
%%%     fault, and a transient lookup failure should not flap /health.
-module(mcl_om_provider_grant_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GRACE, 60_000).
-define(T0, 1_000_000).
-define(PROC, <<"acme/svc.answer">>).

no_delegation() ->
    {error, {provider_authorization, {procedure_delegation, not_found}}}.
no_org_directory() ->
    {error, {provider_authorization, {org_directory, not_found}}}.
granted() ->
    {ok, #{org_directory => <<"d">>, procedure_delegation => <<"g">>}}.

observe(Result, Now) ->
    mcl_om_provider_grant:observed(Result, Now, undefined).

verdict(Entries, Now) ->
    mcl_om_provider_grant:verdict(Entries, Now, ?GRACE).

a_granted_procedure_is_healthy_test() ->
    ?assertEqual(ok, verdict(#{?PROC => observe(granted(), ?T0)}, ?T0)).

no_procedures_is_healthy_test() ->
    ?assertEqual(ok, verdict(#{}, ?T0)).

a_missing_delegation_degrades_at_once_test() ->
    Entries = #{?PROC => observe(no_delegation(), ?T0)},
    ?assertMatch({degraded, #{provider_grants := [#{procedure := ?PROC,
                                                     status := not_granted,
                                                     cause := operator_must_grant}]}},
                 verdict(Entries, ?T0)).

%% An unset org is a configuration fault only an operator can fix, like a
%% missing delegation: degraded at once, not after a grace window.
an_unset_org_degrades_at_once_test() ->
    Entries = #{<<"_/svc.answer">> => observe({error, {org_unset, <<"_">>}}, ?T0)},
    ?assertMatch({degraded, #{provider_grants := [#{status := not_granted,
                                                     cause := operator_must_set_org}]}},
                 verdict(Entries, ?T0)).

a_missing_org_directory_waits_out_the_grace_window_test() ->
    Entries = #{?PROC => observe(no_org_directory(), ?T0)},
    ?assertEqual(ok, verdict(Entries, ?T0 + ?GRACE - 1)),
    ?assertMatch({degraded, #{provider_grants := [#{procedure := ?PROC,
                                                     status := not_granted,
                                                     cause := realm_has_not_published}]}},
                 verdict(Entries, ?T0 + ?GRACE)).

any_other_refusal_waits_then_degrades_with_the_reason_as_given_test() ->
    Reason = {provider_authorization, {error, timeout}},
    Entries = #{?PROC => observe({error, Reason}, ?T0)},
    ?assertEqual(ok, verdict(Entries, ?T0 + 1)),
    ?assertMatch({degraded, #{provider_grants := [#{cause := Reason}]}},
                 verdict(Entries, ?T0 + ?GRACE)).

%% The window runs from the first failure, not the latest: a gap that keeps
%% failing on every tick must still come due.
consecutive_failures_keep_the_first_failure_time_test() ->
    First  = observe(no_org_directory(), ?T0),
    Second = mcl_om_provider_grant:observed(no_org_directory(), ?T0 + 30_000, First),
    ?assertMatch({degraded, _}, verdict(#{?PROC => Second}, ?T0 + ?GRACE)).

a_grant_resets_the_window_test() ->
    Failed  = observe(no_org_directory(), ?T0),
    Granted = mcl_om_provider_grant:observed(granted(), ?T0 + 10, Failed),
    Again   = mcl_om_provider_grant:observed(no_org_directory(), ?T0 + ?GRACE, Granted),
    ?assertEqual(ok, verdict(#{?PROC => Again}, ?T0 + ?GRACE + 1)).

%% One failing procedure degrades the service even when another is granted,
%% and only the failing ones are named.
only_failing_procedures_are_named_test() ->
    Entries = #{?PROC => observe(no_delegation(), ?T0),
                <<"acme/svc.other">> => observe(granted(), ?T0)},
    {degraded, #{provider_grants := Named}} = verdict(Entries, ?T0),
    ?assertEqual([?PROC], [P || #{procedure := P} <- Named]).

%% What /health lists in every state, waiting included: a service inside
%% its grace window is ok, and says why it is not yet granted.
report_lists_every_procedure_with_its_state_test() ->
    Entries = #{?PROC => observe(no_org_directory(), ?T0),
                <<"acme/svc.other">> => observe(granted(), ?T0)},
    Report = mcl_om_provider_grant:report(Entries, ?T0 + 5_000, ?GRACE),
    ?assertEqual([#{procedure => <<"acme/svc.answer">>, status => <<"waiting">>,
                    reason => <<"{provider_authorization,{org_directory,not_found}}">>,
                    since_ms => 5_000},
                  #{procedure => <<"acme/svc.other">>, status => <<"granted">>}],
                 Report).
