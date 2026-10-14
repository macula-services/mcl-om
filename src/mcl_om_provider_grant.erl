%%%-------------------------------------------------------------------
%%% @doc Whether this service holds the D25 grant each of its
%%% org-namespaced procedures needs, and what that means for /health.
%%%
%%% A provider with no grant used to look healthy while serving nothing:
%%% the advertise path asked `macula:provider_authorization/3' on every
%%% republish tick, dropped the refusal, and retried quietly. That answer
%%% is kept now, per procedure, and judged here:
%%%
%%% - no `procedure_delegation' naming this node: degraded at once. The
%%%   realm has the service's claim on file and an operator has to grant
%%%   it; nothing will change until someone does.
%%% - no org configured (`org_unset', recorded by mcl_om_capabilities, which
%%%   then advertises nothing): degraded at once; an operator sets the org.
%%% - no `org_directory', or any other refusal: waiting for a grace window
%%%   (`provider_grant_grace_ms', default 60 s), then degraded. The realm
%%%   republishes an absent chain within seconds, so a gap that outlasts the
%%%   window is a real fault, while a lookup that fails once should not flap
%%%   /health. The reason is macula's, as given.
%%%
%%% The window runs from the FIRST failure of an unbroken run, so a gap
%%% that fails on every tick still comes due, and a grant resets it.
%%%
%%% Pure: the caller supplies the clock. `mcl_om_capabilities' records one
%%% entry per procedure per tick; `mcl_om_health' judges them on read, so
%%% /health changes the moment a window closes, not at the next tick.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_om_provider_grant).

-export([observed/4, verdict/3, report/3, expiry/2, grace_ms/0]).
-export_type([entry/0, window/0, clock/0]).

-define(DEFAULT_GRACE_MS, 60_000).

%% The chain's validity, system time in ms: the binding record's
%% `created_at' and the chain's bound, the earlier `expires_at' of the org
%% directory and the delegation (what macula bounds an advertisement by).
-type window() :: {CreatedAt :: integer(), NotAfter :: integer()} | undefined.

%% /health reads both clocks: the grace window runs on monotonic time, a
%% chain's bound is a wall-clock time written by the realm.
-type clock() :: #{mono := integer(), sys := integer()}.

-type entry() :: #{result := granted | {not_granted, term()},
                   since  := integer() | undefined,
                   window := window()}.

%% @doc The entry for one procedure, from its `provider_authorization'
%% answer at `Now' (monotonic), the window of the chain it carries
%% (`undefined' when there is none), and its previous entry (`undefined'
%% on the first tick). A refusal keeps the previous window: the
%% registration still carries that chain until its bound passes.
-spec observed({ok, term()} | {error, term()}, window(), integer(),
               entry() | undefined) -> entry().
observed({ok, _Authorization}, Window, _Now, _Previous) ->
    #{result => granted, since => undefined, window => Window};
observed({error, Reason}, _Window, Now, Previous) ->
    #{result => {not_granted, Reason}, since => failing_since(Previous, Now),
      window => previous_window(Previous)}.

failing_since(#{result := {not_granted, _}, since := Since}, _Now) -> Since;
failing_since(_GrantedOrNew, Now)                                   -> Now.

previous_window(#{window := Window}) -> Window;
previous_window(_None)               -> undefined.

%% @doc `ok', or `{degraded, #{provider_grants => Failing}}' naming each
%% procedure that is past waiting, or whose chain is expiring or expired,
%% with the cause an operator acts on.
-spec verdict(#{binary() => entry()}, clock(), non_neg_integer()) ->
    ok | {degraded, #{provider_grants := [map()]}}.
verdict(Entries, Clock, GraceMs) ->
    Failing = [failing(Proc, E, State)
               || {Proc, E} <- sorted(Entries),
                  State <- [state(E, Clock, GraceMs)],
                  State =/= granted, State =/= waiting],
    degraded_if_any(Failing).

failing(Proc, #{result := {not_granted, Reason}}, not_granted) ->
    #{procedure => Proc, status => not_granted, cause => cause(Reason)};
failing(Proc, #{window := {_Created, NotAfter}}, Expiry) ->
    #{procedure => Proc, status => Expiry, cause => expiry_cause(Expiry),
      not_after_ms => NotAfter}.

expiry_cause(expiring) -> realm_has_not_renewed;
expiry_cause(expired)  -> chain_expired.

degraded_if_any([])      -> ok;
degraded_if_any(Failing) -> {degraded, #{provider_grants => Failing}}.

%% @doc Every procedure with its state, for /health to list whatever the
%% verdict: a service inside its window is ok and still says why, and a
%% procedure with a chain says when it ends.
-spec report(#{binary() => entry()}, clock(), non_neg_integer()) -> [map()].
report(Entries, Clock, GraceMs) ->
    [reported(Proc, E, Clock, GraceMs) || {Proc, E} <- sorted(Entries)].

reported(Proc, #{result := granted} = E, Clock, GraceMs) ->
    with_window(E, #{procedure => Proc,
                     status => atom_to_binary(state(E, Clock, GraceMs))});
reported(Proc, #{result := {not_granted, Reason}, since := Since} = E,
         #{mono := Now} = Clock, GraceMs) ->
    with_window(E, #{procedure => Proc,
                     status    => atom_to_binary(state(E, Clock, GraceMs)),
                     reason    => iolist_to_binary(io_lib:format("~0p", [Reason])),
                     since_ms  => Now - Since}).

with_window(#{window := {_Created, NotAfter}}, Report) -> Report#{not_after_ms => NotAfter};
with_window(_NoWindow, Report)                         -> Report.

%% @doc Where a chain stands at wall-clock `SysNow': `fresh' with more than
%% a third of its life left, `expiring' with a third or less (a healthy
%% realm reissues every 10 min, so a 30-min delegation never gets there),
%% `expired' past its bound, `unknown' with no chain.
-spec expiry(window(), integer()) -> fresh | expiring | expired | unknown.
expiry(undefined, _SysNow) ->
    unknown;
expiry({_Created, NotAfter}, SysNow) when SysNow >= NotAfter ->
    expired;
expiry({Created, NotAfter}, SysNow) when (NotAfter - SysNow) * 3 =< NotAfter - Created ->
    expiring;
expiry(_Window, _SysNow) ->
    fresh.

%% @doc The grace window from `mcl_om' app env, default 60 s.
-spec grace_ms() -> non_neg_integer().
grace_ms() ->
    grace_of(application:get_env(mcl_om, provider_grant_grace_ms)).

grace_of({ok, Ms}) when is_integer(Ms), Ms >= 0 -> Ms;
grace_of(_Unset)                                -> ?DEFAULT_GRACE_MS.

%%% Internals

state(#{result := granted, window := Window}, #{sys := SysNow}, _GraceMs) ->
    granted_state(expiry(Window, SysNow));
state(#{result := {not_granted, Reason}, since := Since}, #{mono := Now}, GraceMs) ->
    waited(immediate(Reason), Now - Since >= GraceMs).

granted_state(expiring) -> expiring;
granted_state(expired)  -> expired;
granted_state(_Fresh)   -> granted.

waited(true, _Elapsed) -> not_granted;
waited(false, true)    -> not_granted;
waited(false, false)   -> waiting.

%% Past waiting from the start: a missing delegation (the realm has published
%% everything it will until an operator grants this node) and an unset org
%% (nothing is advertised until an operator sets one).
immediate({provider_authorization, {procedure_delegation, not_found}}) -> true;
immediate({org_unset, _Org})                                           -> true;
immediate(_Other)                                                      -> false.

cause({provider_authorization, {procedure_delegation, not_found}}) -> operator_must_grant;
cause({provider_authorization, {org_directory, not_found}})       -> realm_has_not_published;
cause({org_unset, _Org})                                           -> operator_must_set_org;
cause(Reason)                                                      -> Reason.

sorted(Entries) ->
    lists:keysort(1, maps:to_list(Entries)).
