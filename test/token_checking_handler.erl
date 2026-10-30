%% @doc A handler for a `handler_authorizes' capability: the link runs no gate,
%% so the token check this module makes is the only thing between a caller and
%% the answer (macula 18, macula#129). A test of it means something only if the
%% call put the request's own token beside the fields first — with a helper that
%% merged nothing, this handler refuses everybody and a test asserting the
%% refusal would agree with a service no caller can reach.
-module(token_checking_handler).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

-define(ADMITTED, <<"the token the operator granted">>).

init([]) -> {ok, undefined}.

handle_request(Payload, State) ->
    Token = maps:get(ucan_token, Payload, none),
    Proofs = maps:get(proofs, Payload, none),
    {reply, #{<<"admitted">> => {text, admitted(Token =:= ?ADMITTED)},
              <<"proof_count">> => counted(Proofs)}, State}.

admitted(true) -> <<"yes">>;
admitted(false) -> <<"no">>.

%% `none' is what a payload without the key looks like, and it is not a list:
%% counting it would hide the very fault this handler exists to catch.
counted(Proofs) when is_list(Proofs) -> length(Proofs);
counted(_Absent) -> -1.
