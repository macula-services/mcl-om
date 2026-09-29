%% @doc mcl_om is the basis for on-mesh services and nothing more: each service
%% chooses its own persistence (mcl-om#10, Raf, 2026-09-29). So mcl_om neither
%% depends on nor starts reckon_db, evoq or reckon_evoq, and it opens no store.
%% A service built for the old contract, which exported store_id/0 so that
%% mcl_om:boot/1 would open its store, now boots without one; it is told so
%% loudly, naming the callbacks it still exports and what to do instead.
-module(mcl_om_storeless_tests).
-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

mcl_om_starts_no_store_application_test() ->
    ok = load(mcl_om),
    {ok, Apps} = application:get_key(mcl_om, applications),
    ?assertEqual([], [A || A <- [reckon_db, evoq, reckon_evoq, reckon_gater, khepri, ra],
                           lists:member(A, Apps)]).

mcl_om_ships_no_store_module_test() ->
    ok = load(mcl_om),
    {ok, Mods} = application:get_key(mcl_om, modules),
    ?assertNot(lists:member(mcl_om_store, Mods)),
    ?assertEqual(non_existing, code:which(mcl_om_store)).

%% A service module still exporting the old store callbacks: every one it still
%% exports is named, in the order the old contract listed them.
leftover_store_callbacks_are_named_test() ->
    ?assertEqual([store_id, data_dir, store_mode],
                 mcl_om:leftover_store_callbacks(leftover_service())),
    ?assertEqual([], mcl_om:leftover_store_callbacks(mcl_om_storeless_tests)).

%% Only the old contract's activation counts: store_id/0 AND data_dir/0, which is
%% what made 0.34 open a store. A storeless service with its own data_dir/0 (for
%% its files) never had a store and is told nothing (Mercurius, on e72fbb5).
a_data_dir_alone_is_not_a_leftover_store_test() ->
    Mod = compiled(mcl_om_storeless_data_dir_only, [{data_dir, "/tmp/y"}]),
    ?assertEqual([], mcl_om:leftover_store_callbacks(Mod)),
    ?assertEqual(ok, mcl_om:warn_leftover_store(Mod)).

%% ...and boot says so as a warning, once, with the change and the way out.
leftover_store_is_warned_at_boot_test() ->
    ok = logger:add_handler(?MODULE, ?MODULE, #{level => warning, config => #{pid => self()}}),
    try
        ?assertEqual({warned, [store_id, data_dir, store_mode]},
                     mcl_om:warn_leftover_store(leftover_service())),
        receive
            {log, warning, #{what := mcl_om_no_longer_opens_a_store,
                             service := Mod, callbacks := Cbs, instead := Instead}} ->
                ?assertEqual(leftover_service(), Mod),
                ?assertEqual([store_id, data_dir, store_mode], Cbs),
                ?assert(is_binary(Instead)),
                %% The way out names the file the template really generates.
                ?assertNotEqual(nomatch, binary:match(Instead, <<"<name>_app">>)),
                ?assertEqual(nomatch, binary:match(Instead, <<"<name>_store.erl">>))
        after 2000 -> error(no_warning_logged)
        end,
        ?assertEqual(ok, mcl_om:warn_leftover_store(mcl_om_storeless_tests))
    after
        logger:remove_handler(?MODULE)
    end.

%% logger handler: forward warning reports to the test process.
log(#{level := Level, msg := {report, Report}}, #{config := #{pid := Pid}}) ->
    Pid ! {log, Level, Report};
log(_Event, _Config) ->
    ok.

%% A module compiled here, exporting store_id/0, data_dir/0 and store_mode/0
%% the way a pre-0.35 CMD/PRJ service module did.
leftover_service() ->
    Mod = mcl_om_storeless_leftover_service,
    Forms = [{attribute, 1, module, Mod},
             {attribute, 2, export, [{store_id, 0}, {data_dir, 0}, {store_mode, 0}]},
             {function, 3, store_id, 0, [{clause, 3, [], [], [{atom, 3, leftover_store}]}]},
             {function, 4, data_dir, 0, [{clause, 4, [], [], [{string, 4, "/tmp/x"}]}]},
             {function, 5, store_mode, 0, [{clause, 5, [], [], [{atom, 5, single}]}]}],
    {ok, Mod, Bin} = compile:forms(Forms),
    {module, Mod} = code:load_binary(Mod, "leftover.erl", Bin),
    Mod.

%% compiled(Mod, [{Fun, Value}]): a module exporting each Fun/0 returning Value.
compiled(Mod, Funs) ->
    Forms = [{attribute, 1, module, Mod},
             {attribute, 2, export, [{F, 0} || {F, _} <- Funs]}
             | [{function, 3, F, 0, [{clause, 3, [], [], [erl_parse:abstract(V)]}]} || {F, V} <- Funs]],
    {ok, Mod, Bin} = compile:forms(Forms),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".erl", Bin),
    Mod.

load(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.
