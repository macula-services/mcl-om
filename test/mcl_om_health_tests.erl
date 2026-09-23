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
-define(REPORT, [#{procedure => <<"acme/x">>, status => <<"waiting">>}]).

ok_body_carries_the_service_info_and_the_grants_test() ->
    ?assertEqual(#{name => <<"svc">>, status => <<"ok">>, provider_grants => ?REPORT},
                 mcl_om_health_handler:body(ok, #{name => <<"svc">>}, ?REPORT)).

degraded_body_carries_the_reason_and_the_grants_test() ->
    ?assertEqual(#{status => <<"degraded">>, reason => <<"slow">>,
                   provider_grants => ?REPORT},
                 mcl_om_health_handler:body({degraded, slow}, #{}, ?REPORT)).

down_body_carries_the_reason_and_the_grants_test() ->
    ?assertEqual(#{status => <<"down">>, reason => <<"crashed">>,
                   provider_grants => []},
                 mcl_om_health_handler:body({down, crashed}, #{}, [])).
