%%% @doc `macula_feeder' callback implementation for `mcl_om_content:put/1,2'.
%%%
%%% Named for the SDK contract it satisfies, not for the caller-facing
%%% operation (`put') — unlike the facade, this file carries no domain
%%% content of its own. Every bit of real logic (mesh handle
%%% resolution, realm override, timeout, cancel-on-timeout) lives in
%%% `mcl_om_content'; this module exists purely because
%%% `macula_feeder' needs an `init/1'/`handle_fed/2' pair to call, and
%%% the single most salient fact about it is which contract that is.
%%%
%%% Split out from `mcl_om_content' itself (rather than declaring
%%% both `-behaviour(macula_feeder)' and `-behaviour(macula_download)'
%%% on one module) because the two behaviours both declare `init/1' —
%%% the compiler rejects that combination outright ("conflicting
%%% behaviours"), and dropping the attributes to work around it would
%%% trade away real callback-arity/missing-callback checking for
%%% convenience. Not meant to be called directly by anything but
%%% `mcl_om_content' and `macula_feeder' itself.
-module(mcl_om_content_feeder).
-behaviour(macula_feeder).

-export([init/1, handle_fed/2]).

init({Pid, Ref}) -> {ok, {Pid, Ref}}.

handle_fed(Result, {Pid, Ref} = State) ->
    Pid ! {mcl_om_content_result, Ref, Result},
    {stop, normal, State}.
