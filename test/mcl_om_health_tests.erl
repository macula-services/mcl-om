%%% Unit tests for how mcl_om_health combines the service's own health with
%%% the provider-grant verdict. The service's own verdict wins when it is not
%%% ok; a service that says ok is degraded by a grant that is past waiting.
-module(mcl_om_health_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GRANTS, {degraded, #{provider_grants => [#{procedure => <<"acme/x">>}]}}).

ok_and_granted_is_ok_test() ->
    ?assertEqual(ok, mcl_om_health:combined(ok, ok)).

ok_service_without_its_grant_is_degraded_test() ->
    ?assertEqual(?GRANTS, mcl_om_health:combined(ok, ?GRANTS)).

a_down_service_stays_down_test() ->
    ?assertEqual({down, crashed}, mcl_om_health:combined({down, crashed}, ?GRANTS)).

a_degraded_service_keeps_its_own_reason_test() ->
    ?assertEqual({degraded, slow}, mcl_om_health:combined({degraded, slow}, ?GRANTS)).

%% /health lists the grants in EVERY state. A service inside its waiting
%% window answers ok and still says which procedure is not granted and why.
%% It also counts the publishes whose publisher exited before resolving, so a
%% service that publishes into a dead pool is visible without its logs, and
%% lists the advertise loop's last outcome per procedure, so a dead
%% advertise loop cannot hide behind ok + failed_publishes: 0.
-define(REPORT, [#{procedure => <<"acme/x">>, status => <<"waiting">>}]).
-define(ADVERTISE, [#{procedure => <<"acme/x">>, status => <<"alive">>,
                      last_advertise_ms_ago => 12000}]).
%% The boot claim's state, in every body: a claim the realm holds as pending
%% is the operator's to admit, and it must be visible without reading logs.
-define(CLAIM, #{state => <<"pending">>, org => <<"acme">>, since_ms => 5000}).

ok_body_carries_the_service_info_and_the_grants_test() ->
    ?assertEqual(#{name => <<"svc">>, status => <<"ok">>, provider_grants => ?REPORT,
                   advertise_liveness => ?ADVERTISE, claim => ?CLAIM,
                   failed_publishes => 0},
                 mcl_om_health_handler:body(ok, #{name => <<"svc">>}, ?REPORT,
                                            ?ADVERTISE, ?CLAIM, 0)).

%% A service may name a normal setup wait in its own info(), and it rides
%% in the ok body verbatim: a node waiting on the operator (an id it has
%% not been given yet, say) stays healthy, so it fails no canary, while
%% the wait is still there for whoever reads /health
%% (mcl-distributor#5, mcl-om#36).
ok_body_carries_a_wait_the_service_names_test() ->
    ?assertEqual(#{name => <<"svc">>, org_key_id => unknown, status => <<"ok">>,
                   provider_grants => ?REPORT, advertise_liveness => ?ADVERTISE,
                   claim => ?CLAIM, failed_publishes => 0},
                 mcl_om_health_handler:body(ok, #{name => <<"svc">>, org_key_id => unknown},
                                            ?REPORT, ?ADVERTISE, ?CLAIM, 0)).

%% The canary reads the body through `jsx:encode', so what it encodes is
%% the contract: a value jsx cannot write raises inside the handler and
%% /health answers 500 — the failure the service key exists to avoid
%% (mcl-om#36, Mars's R1). Comparing maps cannot see that, so this test
%% encodes. A nested map and a list ride through, keys as strings.
ok_body_encodes_a_wait_the_service_names_test() ->
    Body = mcl_om_health_handler:body(ok,
                                      #{name => <<"svc">>, org_key_id => unknown,
                                        setup => #{waiting_on => [<<"MCL_ORG_KEY_ID">>],
                                                   attempts => 3}},
                                      ?REPORT, ?ADVERTISE, ?CLAIM, 0),
    Decoded = jsx:decode(jsx:encode(Body), [return_maps]),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Decoded)),
    ?assertEqual(<<"unknown">>, maps:get(<<"org_key_id">>, Decoded)),
    ?assertEqual(#{<<"waiting_on">> => [<<"MCL_ORG_KEY_ID">>], <<"attempts">> => 3},
                 maps:get(<<"setup">>, Decoded)).

degraded_body_carries_the_reason_and_the_grants_test() ->
    ?assertEqual(#{status => <<"degraded">>, reason => <<"slow">>,
                   provider_grants => ?REPORT, advertise_liveness => ?ADVERTISE,
                   claim => ?CLAIM, failed_publishes => 3},
                 mcl_om_health_handler:body({degraded, slow}, #{}, ?REPORT,
                                            ?ADVERTISE, ?CLAIM, 3)).

down_body_carries_the_reason_and_the_grants_test() ->
    ?assertEqual(#{status => <<"down">>, reason => <<"crashed">>,
                   provider_grants => [], advertise_liveness => [],
                   claim => ?CLAIM, failed_publishes => 0},
                 mcl_om_health_handler:body({down, crashed}, #{}, [], [], ?CLAIM, 0)).
