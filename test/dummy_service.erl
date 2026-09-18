%%% @doc Minimal `mcl_om_service` impl used by the CT suite.
-module(dummy_service).
-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{
        name        => <<"dummy">>,
        version     => <<"0.0.0">>,
        description => <<"Test fixture">>
    }.

start(_Opts) ->
    %% Just spawn a trivial worker so the boot returns {ok, pid()}.
    Pid = spawn_link(fun() -> receive stop -> ok end end),
    {ok, Pid}.

stop(_State) -> ok.

health() -> ok.

capabilities() ->
    [#{name => <<"dummy.do_thing">>, version => 1}].

identity_spec() ->
    #{
        scope     => <<"dummy">>,
        actions   => [<<"none">>],
        resources => [<<"dummy/*">>],
        ttl_days  => 1
    }.
