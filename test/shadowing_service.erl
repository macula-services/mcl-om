%%% @doc A service whose `info/0' names a key `/health' sets itself, in
%%% BINARY form — the shape that produced a second JSON key beside the
%%% verdict, after which a reader that keeps the last one reports the
%%% service's value as the node's health (mcl-om#36, Mars's R2).
%%%
%%% `mcl_om:boot/2' must refuse it before `start/1' runs, so this module
%%% never needs a tree: `start/1' raising is the assertion that boot got
%%% there, and the suite asserts the refusal names the key.
-module(shadowing_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{name        => <<"shadowing">>,
      version     => <<"0.0.0">>,
      description => <<"A service claiming the health verdict for its own">>,
      <<"status">> => <<"ok">>,
      provider_grants => []}.

start(_Opts) ->
    error(shadowing_service_started).

stop(_State) ->
    ok.

health() ->
    ok.

capabilities() ->
    [].

identity_spec() ->
    #{scope => <<"shadowing">>, actions => [], resources => [], ttl_days => 1}.
