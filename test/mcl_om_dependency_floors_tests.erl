%% @doc The store dependencies every mcl service inherits resolve at or above
%% their floors. rebar.config's constraints are the pin (no lock is
%% committed), so this reads the versions actually built and loaded.
%%
%% reckon_evoq 2.7.2: 2.7.0 read snapshots back empty (reckon-db 5.5.2 already
%% unwraps them, and reckon_evoq unwrapped again), so an aggregate reloaded
%% past a snapshot rebuilt from nothing. evoq 1.26.1: telemetry durations
%% come from the monotonic clock in native units.
-module(mcl_om_dependency_floors_tests).
-include_lib("eunit/include/eunit.hrl").

reckon_evoq_is_at_least_2_7_2_test() ->
    ?assert(at_least(vsn(reckon_evoq), [2, 7, 2])).

evoq_is_at_least_1_26_1_test() ->
    ?assert(at_least(vsn(evoq), [1, 26, 1])).

vsn(App) ->
    _ = application:load(App),
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.

%% Numeric compare of the release part, so 2.10.0 is above 2.7.2.
at_least(Vsn, Floor) ->
    [Release | _] = string:split(Vsn, "-"),
    [list_to_integer(P) || P <- string:split(Release, ".", all)] >= Floor.
