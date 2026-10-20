%% @doc A capability handler as mcl-chess 0.7.1 wrote one: keys read as bare
%% binaries, the caller read as a bare binary. Kept as a fixture because it is
%% the shape that passes 206 tests and refuses every real caller
%% (mcl-chess#10); a test through mcl_om_wire_test sees it refuse, which is the
%% helper's whole reason for existing.
-module(old_style_handler).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init([]) -> {ok, undefined}.

handle_request(Payload, State) ->
    {reply, answered(Payload), State}.

answered(Payload) when is_map(Payload) ->
    answered_with(maps:get(<<"game_id">>, Payload, undefined),
                  maps:get(<<"caller">>, Payload, <<>>));
answered(_) ->
    #{<<"error">> => {text, <<"invalid_request">>}}.

answered_with(GameId, Caller) when is_binary(GameId), GameId =/= <<>>,
                                   is_binary(Caller), Caller =/= <<>> ->
    #{<<"game_id">> => {text, GameId}};
answered_with(_GameId, _Caller) ->
    #{<<"error">> => {text, <<"missing_required_fields">>}}.
