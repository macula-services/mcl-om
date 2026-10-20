%% @doc A handler that uses the behaviour's own refusal, `{error, Reason,
%% State}', instead of answering a reply that carries an error. macula turns it
%% into an ERROR frame, so the caller never sees a reply at all.
%%
%% Two shapes come out of it, because they reach a caller differently: a reason
%% that is text crosses as that text, and a reason with no name to cross with
%% leaves the client building its own error.
-module(refusing_handler).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init([]) -> {ok, undefined}.

handle_request(Payload, State) ->
    case mcl_om_wire:field(nameless, Payload) of
        1 -> {error, #{why => blocked}, State};
        _ -> {error, <<"maintenance">>, State}
    end.
