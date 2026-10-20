%% @doc A handler that reads its caller the way a non-map payload has to:
%% `macula_response:caller/0', out of the serving process's context, rather
%% than out of the payload map. A test of this handler only means anything if
%% the call put the verified identity there first.
-module(caller_context_handler).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init([]) -> {ok, undefined}.

handle_request(_Payload, State) ->
    Seen = mcl_om_wire:caller_hex(#{caller => macula_response:caller()}),
    {reply, #{<<"caller">> => {text, Seen}}, State}.
