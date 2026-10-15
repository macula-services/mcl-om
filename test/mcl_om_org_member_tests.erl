%% EUnit tests for mcl_om_org_member: the cache in front of macula:org_member/4.
%%
%% Each rule is a way the cache could go wrong in the field: a member looked up
%% on every fact, a revoked node remembered past its chain, a stranger's flood
%% turned into DHT lookups, or a station roll remembered as a revocation.
-module(mcl_om_org_member_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ORG, <<"mcl-news">>).
-define(NODE, <<7:256>>).
-define(TABLE, mcl_om_org_member_cache).

org_member_test_() ->
    {foreach,
     fun() -> {ok, Pid} = mcl_om_org_member:start_link(), unlink(Pid), Pid end,
     fun(Pid) -> exit(Pid, kill), wait_down(Pid) end,
     [fun a_member_is_looked_up_once_until_its_chain_expires/1,
      fun a_member_is_asked_again_once_its_chain_expires/1,
      fun a_refusal_is_remembered_for_a_minute/1,
      fun not_finding_out_is_never_remembered/1,
      fun a_full_table_does_not_remember_refusals/1,
      fun the_sweep_drops_what_has_lapsed/1]}.

a_member_is_looked_up_once_until_its_chain_expires(_Pid) ->
    ?_test(begin
        Lookup = counting({ok, 5000}),
        First = mcl_om_org_member:checked(?ORG, ?NODE, 1000, Lookup),
        Second = mcl_om_org_member:checked(?ORG, ?NODE, 4999, Lookup),
        ?assertEqual({{ok, 5000}, {ok, 5000}, 1}, {First, Second, asked()})
    end).

a_member_is_asked_again_once_its_chain_expires(_Pid) ->
    ?_test(begin
        Lookup = counting({ok, 5000}),
        _ = mcl_om_org_member:checked(?ORG, ?NODE, 1000, Lookup),
        _ = mcl_om_org_member:checked(?ORG, ?NODE, 5000, Lookup),
        ?assertEqual(2, asked())
    end).

a_refusal_is_remembered_for_a_minute(_Pid) ->
    ?_test(begin
        Refusal = {error, {not_a_member, {procedure_delegation, not_found}}},
        Lookup = counting(Refusal),
        _ = mcl_om_org_member:checked(?ORG, ?NODE, 1000, Lookup),
        Within = mcl_om_org_member:checked(?ORG, ?NODE, 60999, Lookup),
        AskedWithin = asked(),
        _ = mcl_om_org_member:checked(?ORG, ?NODE, 61000, Lookup),
        ?assertEqual({Refusal, 1, 2}, {Within, AskedWithin, asked()})
    end).

not_finding_out_is_never_remembered(_Pid) ->
    ?_test(begin
        Lookup = counting({error, {unavailable, timeout}}),
        _ = mcl_om_org_member:checked(?ORG, ?NODE, 1000, Lookup),
        _ = mcl_om_org_member:checked(?ORG, ?NODE, 1001, Lookup),
        ?assertEqual({2, []}, {asked(), ets:tab2list(?TABLE)})
    end).

a_full_table_does_not_remember_refusals(_Pid) ->
    ?_test(begin
        true = ets:insert(?TABLE, [{{?ORG, <<N:256>>}, {ok, 1}, 1000000000000000} || N <- lists:seq(1, 10000)]),
        Lookup = counting({error, {not_a_member, delegation_mismatch}}),
        _ = mcl_om_org_member:checked(?ORG, <<0:256>>, 1000, Lookup),
        ?assertEqual([], ets:lookup(?TABLE, {?ORG, <<0:256>>}))
    end).

the_sweep_drops_what_has_lapsed(Pid) ->
    ?_test(begin
        Now = erlang:system_time(millisecond),
        true = ets:insert(?TABLE, [{{?ORG, <<1:256>>}, {ok, 1}, Now - 1},
                                   {{?ORG, <<2:256>>}, {ok, Now + 60000}, Now + 60000}]),
        Pid ! sweep,
        _ = sys:get_state(Pid),
        ?assertEqual([{?ORG, <<2:256>>}], [Key || {Key, _, _} <- ets:tab2list(?TABLE)])
    end).

%%------------------------------------------------------------------------------

counting(Answer) ->
    put(asked, 0),
    fun(_Org, _NodeId) -> put(asked, get(asked) + 1), Answer end.

asked() -> get(asked).

wait_down(Pid) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.
