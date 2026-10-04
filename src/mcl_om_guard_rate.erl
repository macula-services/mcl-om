%%% @doc Stage 2: the fixed-window request-rate limiter.
%%%
%%% The window and both maxima come from the procedure's effective
%%% limits; the counters live in mcl_om_guard's ETS table, keyed by
%%% (procedure, caller), so one capability's bucket is its own. The
%%% caller is the platform-injected `caller' key for map payloads and
%%% the shared `'$global'' bucket otherwise -- the same honest fallback
%%% mcl-echo documents. A denial is counted inside mcl_om_guard:allow/3.
-module(mcl_om_guard_rate).

-behaviour(mcl_om_guard_stage).

-export([check/2]).

check(_Payload, #{procedure := Proc, caller := Caller, limits := Limits}) ->
    case mcl_om_guard:allow(Proc, Caller, Limits) of
        allow -> pass;
        deny -> {deny, rate_limited}
    end.
