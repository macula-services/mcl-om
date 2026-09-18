%%% @doc `macula_download' callback implementation for `mcl_om_content:get/1,2'.
%%%
%%% Named for the SDK contract it satisfies — see
%%% `mcl_om_content_feeder''s moduledoc for the full reasoning (the
%%% same applies here, mirrored for the get/download side). Not meant
%%% to be called directly by anything but `mcl_om_content' and
%%% `macula_download' itself.
-module(mcl_om_content_downloader).
-behaviour(macula_download).

-export([init/1, handle_downloaded/2]).

init({Pid, Ref}) -> {ok, {Pid, Ref}}.

handle_downloaded(Result, {Pid, Ref} = State) ->
    Pid ! {mcl_om_content_result, Ref, Result},
    {stop, normal, State}.
