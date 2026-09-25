%%% @doc Minimal `mcl_om_service` impl used by the CT suite.
%%%
%%% The dummy's start/1 spawns a worker and REMEMBERS it; capabilities/0
%%% answers only while that worker is alive. That dependency is the point:
%%% boot/2 must run start/1 BEFORE it registers capabilities, so a handler
%%% whose process comes up in start/1 is up when the advertisement goes
%%% out -- the ordering this fixture turns into a red test if it ever
%%% regresses.
-module(dummy_service).
-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

-define(WORKER_KEY, {?MODULE, worker}).

info() ->
    #{
        name        => <<"dummy">>,
        version     => <<"0.0.0">>,
        description => <<"Test fixture">>
    }.

start(_Opts) ->
    %% Spawn a trivial worker, remember it, and hand it back as the boot pid.
    Pid = spawn_link(fun() -> receive stop -> ok end end),
    persistent_term:put(?WORKER_KEY, Pid),
    {ok, Pid}.

stop(_State) -> ok.

health() -> ok.

capabilities() ->
    %% Only answerable once start/1 has run: a boot that registers before
    %% start sees no worker and this list is empty.
    case worker_alive() of
        true -> [#{name => <<"dummy.do_thing">>, version => 1}];
        false -> []
    end.

identity_spec() ->
    #{
        scope     => <<"dummy">>,
        actions   => [<<"none">>],
        resources => [<<"dummy/*">>],
        ttl_days  => 1
    }.

worker_alive() ->
    case persistent_term:get(?WORKER_KEY, undefined) of
        Pid when is_pid(Pid) -> is_process_alive(Pid);
        _ -> false
    end.
