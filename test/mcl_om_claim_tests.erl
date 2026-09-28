%% @doc The labels a boot claim carries to the realm's operator.
%%
%% `service_name' and `box' are informational: the realm's pending row shows
%% them so an operator knows what is asking. They came only from mcl_om's app
%% env, which two services set and the template did not, so most claims
%% arrived unlabelled. Each now falls back to an OS variable the compose file
%% sets, and `service_name' finally to the service's own name from info/0.
-module(mcl_om_claim_tests).

-include_lib("eunit/include/eunit.hrl").

labels_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun app_env_wins/1,
      fun os_env_when_no_app_env/1,
      fun service_info_name_when_nothing_is_set/1,
      fun an_empty_os_variable_counts_as_unset/1,
      fun an_empty_app_env_value_counts_as_unset/1]}.

setup() ->
    _ = application:load(mcl_om),
    Saved = {application:get_env(mcl_om, service_name),
             application:get_env(mcl_om, box),
             os:getenv("MCL_SERVICE_NAME"), os:getenv("MCL_BOX"),
             persistent_term:get(mcl_om_service_module, undefined)},
    application:unset_env(mcl_om, service_name),
    application:unset_env(mcl_om, box),
    os:unsetenv("MCL_SERVICE_NAME"),
    os:unsetenv("MCL_BOX"),
    persistent_term:put(mcl_om_service_module, dummy_service),
    Saved.

teardown({Name, Box, OsName, OsBox, Mod}) ->
    restore_app(service_name, Name),
    restore_app(box, Box),
    restore_os("MCL_SERVICE_NAME", OsName),
    restore_os("MCL_BOX", OsBox),
    persistent_term:put(mcl_om_service_module, Mod).

restore_app(Key, {ok, V}) -> application:set_env(mcl_om, Key, V);
restore_app(Key, undefined) -> application:unset_env(mcl_om, Key).

restore_os(Var, false) -> os:unsetenv(Var);
restore_os(Var, V) -> os:putenv(Var, V).

app_env_wins(_) ->
    ok = application:set_env(mcl_om, service_name, <<"from-app-env">>),
    ok = application:set_env(mcl_om, box, <<"beam00">>),
    true = os:putenv("MCL_SERVICE_NAME", "from-os-env"),
    true = os:putenv("MCL_BOX", "msi00"),
    ?_assertEqual(#{<<"service_name">> => <<"from-app-env">>, <<"box">> => <<"beam00">>},
                  mcl_om_claim:labels()).

os_env_when_no_app_env(_) ->
    true = os:putenv("MCL_SERVICE_NAME", "mcl-stations"),
    true = os:putenv("MCL_BOX", "beam02"),
    ?_assertEqual(#{<<"service_name">> => <<"mcl-stations">>, <<"box">> => <<"beam02">>},
                  mcl_om_claim:labels()).

service_info_name_when_nothing_is_set(_) ->
    #{name := Name} = dummy_service:info(),
    ?_assertEqual(#{<<"service_name">> => Name, <<"box">> => <<>>},
                  mcl_om_claim:labels()).

an_empty_os_variable_counts_as_unset(_) ->
    true = os:putenv("MCL_SERVICE_NAME", ""),
    true = os:putenv("MCL_BOX", ""),
    #{name := Name} = dummy_service:info(),
    ?_assertEqual(#{<<"service_name">> => Name, <<"box">> => <<>>},
                  mcl_om_claim:labels()).

%% A release whose sys.config still carries `{box, <<"${MCL_BOX}">>}' gets an
%% EMPTY app env value when the variable is unset. That is not a label, and it
%% must not hide the OS variable or the service name behind it.
an_empty_app_env_value_counts_as_unset(_) ->
    ok = application:set_env(mcl_om, service_name, <<>>),
    ok = application:set_env(mcl_om, box, ""),
    true = os:putenv("MCL_BOX", "beam00.lab"),
    #{name := Name} = dummy_service:info(),
    ?_assertEqual(#{<<"service_name">> => Name, <<"box">> => <<"beam00.lab">>},
                  mcl_om_claim:labels()).

%%% THE REALM'S ANSWER, CLASSIFIED. Under macula 13 a refusal from the realm's
%%% responder arrives as a bare {error, <<"not_admitted">>}; before it, as
%%% {error, {call_error, Code, <<"not_admitted">>}}. mcl_om 0.33.1 knew only
%%% the second, so on macula 13 a claim the realm had filed as pending was
%%% taken for "not delivered" and re-sent every minute, forever, logged at
%%% debug (found on mcl-fovea, 2026-09-28).

pending_in_both_reply_shapes_test() ->
    ?assertEqual(pending, mcl_om_claim:classify({error, <<"not_admitted">>})),
    ?assertEqual(pending, mcl_om_claim:classify({error, {call_error, handler_error, <<"not_admitted">>}})),
    ?assertEqual(pending, mcl_om_claim:classify({error, {call_error, unknown_error, <<"not_admitted">>}})).

issued_when_the_realm_answers_ok_test() ->
    ?assertEqual(issued, mcl_om_claim:classify({ok, #{<<"issued">> => 1}})).

anything_else_is_not_delivered_test() ->
    ?assertEqual({not_delivered, timeout}, mcl_om_claim:classify({error, timeout})),
    ?assertEqual({not_delivered, <<"other">>}, mcl_om_claim:classify({error, <<"other">>})).

%%% LOUD ONCE PER CHANGE. Each change of state is one log line naming the realm
%%% and the org; the same state again is silent, so a claim that cannot be
%%% delivered for an hour is one warning, not sixty debug lines.

-define(REALM, <<16#abb81b5a:32, 0:224>>).

pending_is_announced_naming_realm_and_org_test() ->
    {Level, Text} = mcl_om_claim:announcement(unsent, pending, <<"acme">>, ?REALM),
    ?assertEqual(warning, Level),
    ?assertNotEqual(nomatch, string:find(Text, "acme")),
    ?assertNotEqual(nomatch, string:find(Text, "abb81b5a")),
    ?assertNotEqual(nomatch, string:find(Text, "pending")).

not_delivered_is_announced_once_test() ->
    ?assertMatch({warning, _}, mcl_om_claim:announcement(unsent, {not_delivered, timeout},
                                                         <<"acme">>, ?REALM)),
    ?assertEqual(none, mcl_om_claim:announcement({not_delivered, timeout}, {not_delivered, timeout},
                                                 <<"acme">>, ?REALM)),
    ?assertEqual(none, mcl_om_claim:announcement({not_delivered, timeout}, {not_delivered, closed},
                                                 <<"acme">>, ?REALM)).

issued_is_announced_test() ->
    ?assertMatch({notice, _}, mcl_om_claim:announcement(pending, issued, <<"acme">>, ?REALM)).

%%% /health's view of the claim, and a service with no mesh says so.
status_without_a_claim_worker_test() ->
    ?assertEqual(#{state => <<"no_mesh">>}, mcl_om_claim:status()).

%%% /HEALTH NEVER WAITS ON A CLAIM CALL. The claim runs inside the worker (in
%%% init/1 and on every retry), and a call to an unreachable realm takes up to
%%% 15 s; a status that asked the worker waited 5 s and crashed /health with a
%%% 500 (Mercurius). status/0 reads what the worker last wrote instead.

status_answers_while_a_claim_call_is_in_flight_test_() ->
    {setup, fun blocked_claim/0, fun release_blocked/1,
     fun({_Starter, Answer}) ->
        [?_assertMatch({Ms, #{state := <<"unsent">>}} when Ms < 1000, Answer)]
     end}.

blocked_claim() ->
    Parent = self(),
    ok = meck:new(mcl_om_identity, [passthrough]),
    ok = meck:expect(mcl_om_identity, configured_seeds, fun() -> [#{host => <<"h">>}] end),
    ok = meck:expect(mcl_om_identity, org, fun() -> <<"acme">> end),
    ok = meck:expect(mcl_om_identity, macula_client, fun() -> {ok, self()} end),
    ok = meck:expect(mcl_om_identity, realm, fun() -> {ok, <<1:256>>} end),
    ok = meck:new(macula, [passthrough, no_link]),
    ok = meck:expect(macula, call, fun(_, _, _, _, _) ->
                                           Parent ! in_call,
                                           receive release -> {error, <<"not_admitted">>} end
                                   end),
    Starter = spawn(fun() -> Parent ! {started, mcl_om_claim:start_link()},
                             receive stop -> ok end
                    end),
    receive in_call -> ok after 5000 -> error(claim_never_called) end,
    T0 = erlang:monotonic_time(millisecond),
    Status = mcl_om_claim:status(),
    {Starter, {erlang:monotonic_time(millisecond) - T0, Status}}.

release_blocked({Starter, _}) ->
    whereis(mcl_om_claim) ! release,
    receive {started, _} -> ok after 5000 -> ok end,
    Starter ! stop,
    wait_gone(mcl_om_claim),
    meck:unload([macula, mcl_om_identity]),
    persistent_term:erase({mcl_om_claim, status}),
    ok.

wait_gone(Name) ->
    wait_gone(whereis(Name), Name).

wait_gone(undefined, _Name) -> ok;
wait_gone(Pid, _Name) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.
