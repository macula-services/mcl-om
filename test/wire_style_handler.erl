%% @doc The same capability written against the wire: fields read through
%% `mcl_om_wire:field/3', the caller through `mcl_om_wire:caller_hex/1', the
%% one form a reply can carry. It is what a service's handler should look
%% like, and it is here so the helper has something that passes through the
%% same path that catches the fixture beside it.
-module(wire_style_handler).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init([]) -> {ok, undefined}.

handle_request(Payload, State) ->
    {reply, answered(Payload), State}.

answered(Payload) when is_map(Payload) ->
    answered_with(mcl_om_wire:field(game_id, Payload),
                  mcl_om_wire:field(move, Payload),
                  mcl_om_wire:caller_hex(Payload));
answered(_) ->
    #{<<"error">> => {text, <<"invalid_request">>}}.

%% A caller is named in the reply only when macula verified one: `caller_hex/1'
%% is `undefined' for an absent caller and for anything that is not a 32-byte
%% node id, and `{text, undefined}' is not a reply.
answered_with(GameId, Move, CallerHex)
  when is_binary(GameId), is_binary(Move), is_binary(CallerHex) ->
    #{<<"game_id">> => {text, GameId},
      <<"move">> => {text, Move},
      <<"caller">> => {text, CallerHex}};
answered_with(_GameId, _Move, _CallerHex) ->
    #{<<"error">> => {text, <<"missing_required_fields">>}}.
