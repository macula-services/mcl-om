%%% @doc The inbound guard pipeline (mcl-om#13): a `macula_response'
%%% handler that runs every inbound call through the guard stages, in
%%% order, before delegating to the capability''s own handler.
%%%
%%% EVERY response-kind capability advertised through mcl_om_capabilities
%%% flows through this pipeline by default -- including the framework''s
%%% own `info' and 'describe' -- because advertise_one/6 wraps its
%%% `handler' with 'wrapper/3'. A capability opts out deliberately with
%%% `guard => none' (the reason lives in the service''s own code), and
%%% streamer-kind capabilities keep their own path (macula_streamer has
%%% no macula_response contract to wrap). The stage order is fixed:
%%% size first (cheapest refusal), then rate, then the handler -- see
%%% mcl-om_guard_stage for why it is deliberately not user-composable.
%%%
%%% A denial is reported exactly as the echo did before this existed:
%%% `{error, payload_too_large | rate_limited, State}', which the wire
%%% carries as handler_error.
-module(mcl_om_guard_pipeline).

-behaviour(macula_response).

-export([init/1, handle_request/2]).
-export([wrapper/3]).

default_stages() ->
    [mcl_om_guard_size, mcl_om_guard_rate].

%% @doc The advertise-time wrap: declare the capability''s limits, then
%% either hand back the handler untouched (`guard => none', or a
%% streamer), or hand back this pipeline carrying the handler.
-spec wrapper(binary(), mcl_om_service:capability(), {module(), term()}) ->
          {module(), term()}.
wrapper(OrgProcedure, Cap, Handler) ->
    case maps:get(kind, Cap, response) of
        streamer ->
            Handler;
        response ->
            guard_wrapper(OrgProcedure, Cap, Handler)
    end.

guard_wrapper(OrgProcedure, Cap, Handler) ->
    ok = mcl_om_guard_limits:declare(OrgProcedure, maps:get(limits, Cap, #{})),
    case maps:get(guard, Cap, default) of
        none -> Handler;
        default -> {?MODULE, {OrgProcedure, default_stages(), Handler}};
        Other -> error({mcl_om_guard_bad_spec, OrgProcedure, Other})
    end.

%% The wrapped handler''s own init runs once per pipeline instance, the
%% same way macula_response would have run it without the wrap.
init({OrgProcedure, Stages, {Mod, ModArgs}}) ->
    {ok, HandlerState} = Mod:init(ModArgs),
    {ok, #{proc => OrgProcedure, stages => Stages,
           handler => {Mod, HandlerState}}}.

handle_request(Payload,
               #{proc := Proc, stages := Stages,
                 handler := {Mod, HandlerState}} = State) ->
    Ctx = ctx(Proc, Payload),
    case run_stages(Stages, Payload, Ctx) of
        {deny, Reason} ->
            count_denial_for(Proc, Reason),
            {error, Reason, State};
        pass ->
            delegate(Mod, Payload, HandlerState, State)
    end.

delegate(Mod, Payload, HandlerState, State) ->
    case Mod:handle_request(Payload, HandlerState) of
        {reply, Reply, NewHandlerState} ->
            {reply, Reply, State#{handler := {Mod, NewHandlerState}}};
        {error, Reason, NewHandlerState} ->
            {error, Reason, State#{handler := {Mod, NewHandlerState}}}
    end.

run_stages([], _Payload, _Ctx) ->
    pass;
run_stages([Stage | Rest], Payload, Ctx) ->
    case Stage:check(Payload, Ctx) of
        pass -> run_stages(Rest, Payload, Ctx);
        {deny, _Reason} = Deny -> Deny
    end.

ctx(Proc, Payload) ->
    #{limits := Limits} = mcl_om_guard_limits:get(Proc),
    #{procedure => Proc, limits => Limits, caller => caller_of(Payload)}.

%% The wire-authenticated caller reaches a handler in the payload only
%% when it is a map (macula_station_link:with_caller/2); everything else
%% shares the per-procedure global bucket -- the honest fallback, not a
%% per-caller limiter wearing a global disguise. macula-io/macula#60
%% tracks the attribution root cause.
caller_of(Payload) when is_map(Payload) -> maps:get(caller, Payload, '$global');
caller_of(_Payload) -> '$global'.

%% The rate stage counts its own denials inside mcl_om_guard:allow/3;
%% the size stage is pure, so the pipeline counts its refusals here.
count_denial_for(Proc, payload_too_large) ->
    mcl_om_guard:count_denial(Proc, size),
    ok;
count_denial_for(_Proc, _OtherReason) ->
    ok.
