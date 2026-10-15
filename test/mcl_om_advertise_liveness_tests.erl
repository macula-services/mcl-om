%%% Unit tests for mcl_om_advertise_liveness -- the /health signal that
%%% a dead advertise loop cannot hide behind `ok' + `failed_publishes: 0'.
%%% Pure: the clock is supplied by the caller, so every window here is
%%% deterministic.
-module(mcl_om_advertise_liveness_tests).
-include_lib("eunit/include/eunit.hrl").

%% A sample staleness window passed explicitly into verdict/report; the
%% real default is exercised by defaults_track_the_republish_macro_test.
-define(STALE, 120_000).

%% observed/4: a success stamps last_success and clears the failure; a
%% failure keeps the last success and stamps the failure.
observed_success_stamps_and_clears_test() ->
    Prev = mcl_om_advertise_liveness:observed({error, boom}, <<"p">>, 1_000,
                                              undefined),
    ?assertMatch(#{last_success := undefined,
                   last_failure := {1_000, boom}}, Prev),
    Now = mcl_om_advertise_liveness:observed(ok, <<"p">>, 2_000, Prev),
    ?assertMatch(#{last_success := 2_000, last_failure := undefined}, Now).

observed_failure_keeps_the_last_success_test() ->
    Prev = mcl_om_advertise_liveness:observed(ok, <<"p">>, 1_000, undefined),
    Now = mcl_om_advertise_liveness:observed({error, timeout}, <<"p">>, 2_000,
                                             Prev),
    ?assertMatch(#{last_success := 1_000,
                   last_failure := {2_000, timeout}}, Now).

%% A healthy loop: success within the staleness window is alive, and
%% /health stays ok.
alive_within_the_window_test() ->
    Entry = mcl_om_advertise_liveness:observed(ok, <<"p">>, 1_000, undefined),
    ?assertEqual(ok, mcl_om_advertise_liveness:verdict(#{<<"p">> => Entry},
                                                       1_000 + ?STALE, ?STALE)),
    [Report] = mcl_om_advertise_liveness:report(#{<<"p">> => Entry},
                                                1_000 + ?STALE, ?STALE),
    ?assertEqual(<<"alive">>, maps:get(status, Report)),
    ?assertEqual(?STALE, maps:get(last_advertise_ms_ago, Report)).

%% The signal the handover asked for: a loop whose last success is older
%% than the advertisement's TTL is stale -- the record is gone from the
%% DHT -- and /health degrades.
stale_past_the_window_degrades_test() ->
    Entry = mcl_om_advertise_liveness:observed(ok, <<"p">>, 1_000, undefined),
    Now = 1_000 + ?STALE + 1,
    ?assertEqual({degraded,
                  #{advertise_liveness =>
                        [#{procedure => <<"p">>, status => stale,
                           last_advertise_ms_ago => ?STALE + 1}]}},
                 mcl_om_advertise_liveness:verdict(#{<<"p">> => Entry},
                                                   Now, ?STALE)).

%% A never-succeeded procedure: degraded only once the failure run is
%% older than the grace window (a pre-grant boot fails its first
%% advertises for reasons the grants already report).
never_succeeded_waits_out_the_grace_test() ->
    Grace = mcl_om_advertise_liveness:grace_ms(),
    Entry = mcl_om_advertise_liveness:observed({error, denied}, <<"p">>, 1_000,
                                               undefined),
    ?assertEqual(ok, mcl_om_advertise_liveness:verdict(#{<<"p">> => Entry},
                                                       1_000 + Grace, ?STALE)),
    Now = 1_000 + Grace + 1,
    ?assertEqual({degraded,
                  #{advertise_liveness =>
                        [#{procedure => <<"p">>, status => never_succeeded,
                           last_advertise_ms_ago => undefined}]}},
                 mcl_om_advertise_liveness:verdict(#{<<"p">> => Entry},
                                                   Now, ?STALE)).

%% The report always names the raw state, whatever the verdict: a
%% never-succeeded procedure inside its grace window still says so.
report_names_the_raw_state_inside_the_grace_test() ->
    Entry = mcl_om_advertise_liveness:observed({error, denied}, <<"p">>, 1_000,
                                               undefined),
    [Report] = mcl_om_advertise_liveness:report(#{<<"p">> => Entry},
                                                1_000 + 1, ?STALE),
    ?assertEqual(<<"never_succeeded">>, maps:get(status, Report)),
    ?assertEqual(undefined, maps:get(last_advertise_ms_ago, Report)),
    ?assertMatch(#{ms_ago := 1, reason := <<"denied">>},
                 maps:get(last_advertise_failure, Report)).

%% A procedure with no entry has never been attempted: not listed, not
%% degrading.
no_entry_does_not_degrade_test() ->
    ?assertEqual(ok, mcl_om_advertise_liveness:verdict(#{}, 0, ?STALE)),
    ?assertEqual([], mcl_om_advertise_liveness:report(#{}, 0, ?STALE)).

%% The /health windows are not independent constants: they derive from
%% the one republish-cadence knob in mcl_om_capabilities, so raising the
%% cadence moves the staleness window with it and a longer tick does not
%% turn /health into a flapper on one missed run (mcl-om#26, Fable round).
defaults_track_the_republish_macro_test() ->
    %% The stale window defaults to the advertisement TTL (= four
    %% republish intervals): it watches a record for exactly as long as
    %% the record lives, whatever the cadence.
    ?assertEqual(mcl_om_capabilities:advertisement_ttl_ms(),
                 mcl_om_advertise_liveness:stale_after_ms()),
    %% Grace defaults to two republish intervals: a cold boot gets two
    %% advertise attempts before a never-succeeded loop degrades /health,
    %% as it did at the old cadence.
    ?assertEqual(2 * mcl_om_capabilities:republish_interval_ms(),
                 mcl_om_advertise_liveness:grace_ms()).
