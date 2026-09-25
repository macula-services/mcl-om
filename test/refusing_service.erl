%%% @doc A service whose start/1 refuses: the fixture for the invariant that
%%% a service that will not start leaves no advertisement behind.
-module(refusing_service).
-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{
        name        => <<"refusing">>,
        version     => <<"0.0.0">>,
        description => <<"Test fixture: refuses to start">>
    }.

start(_Opts) ->
    {error, refused}.

stop(_State) -> ok.

health() -> ok.

capabilities() ->
    [#{name => <<"refusing.never_answered">>, version => 1}].

identity_spec() ->
    #{
        scope     => <<"dummy">>,
        actions   => [<<"none">>],
        resources => [<<"dummy/*">>],
        ttl_days  => 1
    }.
