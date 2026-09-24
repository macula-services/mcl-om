%% @doc Which org values a service may boot with.
%%
%% The org is the `Org' in every procedure a service offers (`Org/Name') and the
%% org the realm's grant names. Without a usable one, mcl_om used to log
%% "advertise skipped, no org configured" and carry on: the service ran green,
%% advertised nothing and never sent the realm a claim. A bot on beam01 ran
%% like that unnoticed. checked_org/1 is what mcl_om:boot/2 now refuses on.
-module(mcl_om_org_tests).

-include_lib("eunit/include/eunit.hrl").

a_wire_segment_is_an_org_test_() ->
    [?_assertEqual(ok, mcl_om_identity:checked_org(Org))
     || Org <- [<<"mcl-echo">>, <<"acme">>, <<"a.b_c-d">>, <<"0rg">>]].

%% Unset (mcl_om_identity:org/0 answers `_'), empty, the placeholder, an
%% environment variable relx did not expand, and anything else that is not a
%% wire segment.
not_an_org_is_refused_test_() ->
    [?_assertMatch({error, {not_an_org, Org}}, mcl_om_identity:checked_org(Org))
     || Org <- [<<"_">>, <<>>, <<"${MCL_ORG}">>, <<"Acme">>, <<"-acme">>,
                <<"acme/x">>, <<"acme org">>]].
