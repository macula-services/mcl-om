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
