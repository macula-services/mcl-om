%%% @doc Bridges `macula''s native `{Module, Function}' single-call
%%% handler convention into `macula_response''s per-request `init/1' +
%%% `handle_request/2' contract, for a handler that needs no per-request
%%% state — the common case for a hecate-service migrating a capability
%%% from bare `macula:advertise/5' onto
%%% `mcl_om_capabilities:register/1' (see
%%% `plans/PLAN_UCAN_GATED_CAPABILITIES.md').
%%%
%%% Without this, every migrating service would hand-write its own
%%% `init/1'/`handle_request/2' pair per capability just to keep calling
%%% the one-arity function it already had.
%%%
%%% Wire-compatible with the bare `{Module, Function}' path it replaces:
%%% `macula_station_link''s native dispatch strips an `{ok, _}' wrapper
%%% from a successful reply before it hits the wire
%%% (`normalise_reply/1'); `macula_response''s own `outcome/1' re-wraps
%%% whatever `handle_request/2' replies with in `{ok, _}' one layer up.
%%% This module strips `{ok, _}' itself so the two layers don't compose
%%% into a double-wrapped payload — a migrated capability's wire
%%% response is byte-for-byte the same as before migration.
-module(mcl_om_simple_handler).

-export([init/1, handle_request/2]).

%% @doc `macula_response''s per-request `init/1' callback. State is just
%% the `{Module, Function}' pair this handler will dispatch to — there
%% is nothing else to initialize for a stateless handler.
-spec init({module(), atom()}) -> {ok, {module(), atom()}}.
init({Module, Function} = State) when is_atom(Module), is_atom(Function) ->
    {ok, State}.

%% @doc `macula_response''s per-request `handle_request/2' callback.
%% Calls `Module:Function(Payload)' and translates its result into the
%% `{reply, _, _} | {error, _, _}' shape `macula_response' expects,
%% unwrapping an `{ok, Value}' result to just `Value' — see this
%% module's own doc for why that unwrap has to happen here.
-spec handle_request(term(), {module(), atom()}) ->
    {reply, term(), {module(), atom()}} | {error, term(), {module(), atom()}}.
handle_request(Payload, {Module, Function} = State) ->
    case Module:Function(Payload) of
        {error, Reason} -> {error, Reason, State};
        {ok, Value}     -> {reply, Value, State};
        Other           -> {reply, Other, State}
    end.
