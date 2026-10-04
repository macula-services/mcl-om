%%% @doc Stage 1: the payload-size cap.
%%%
%%% Runs first because it is the cheapest and most common refusal -- a
%%% call too large never reaches the rate counter. The cap is the
%%% procedure's effective `max_payload_external_size', measured with
%%% `erlang:external_size/1' so it bounds every payload shape a caller
%%% can send, not only binaries. The pipeline counts this stage's
%%% refusals in the `denied_size' counter.
-module(mcl_om_guard_size).

-behaviour(mcl_om_guard_stage).

-export([check/2]).

check(Payload, #{limits := Limits}) ->
    Max = maps:get(max_payload_external_size, Limits),
    case erlang:external_size(Payload) of
        Size when Size > Max -> {deny, payload_too_large};
        _Size -> pass
    end.
