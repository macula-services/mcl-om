%% @doc A `macula_subscriber' that does nothing, so a test can drive the
%% subscribe path (which is where an admission is called) without a mesh
%% or a meaningful handler. It is never subscribed successfully in these
%% tests: the admission refuses first, which is the point.
-module(sealed_group_subscriber).

-behaviour(macula_subscriber).

-export([init/1, handle_event/4, terminate/2]).

-spec init(term()) -> {ok, map()}.
init(_Args) -> {ok, #{}}.

-spec handle_event(binary(), term(), map(), map()) -> {noreply, map()}.
handle_event(_Topic, _Payload, _Meta, State) -> {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, _State) -> ok.
