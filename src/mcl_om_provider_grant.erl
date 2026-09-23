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

-export([observed/3, verdict/3, report/3, grace_ms/0]).
-export_type([entry/0]).

-define(DEFAULT_GRACE_MS, 60_000).

-type entry() :: #{result := granted | {not_granted, term()},
                   since  := integer() | undefined}.

%% @doc The entry for one procedure, from its `provider_authorization'
%% answer at `Now' and its previous entry (`undefined' on the first tick).
-spec observed({ok, term()} | {error, term()}, integer(), entry() | undefined) ->
    entry().
observed({ok, _Authorization}, _Now, _Previous) ->
    #{result => granted, since => undefined};
observed({error, Reason}, Now, Previous) ->
    #{result => {not_granted, Reason}, since => failing_since(Previous, Now)}.

failing_since(#{result := {not_granted, _}, since := Since}, _Now) -> Since;
failing_since(_GrantedOrNew, Now)                                   -> Now.

%% @doc `ok', or `{degraded, #{provider_grants => Failing}}' naming each
%% procedure that is past waiting, with the cause an operator acts on.
-spec verdict(#{binary() => entry()}, integer(), non_neg_integer()) ->
    ok | {degraded, #{provider_grants := [map()]}}.
verdict(Entries, Now, GraceMs) ->
    Failing = [#{procedure => Proc, status => not_granted, cause => cause(Reason)}
               || {Proc, #{result := {not_granted, Reason}} = E} <- sorted(Entries),
                  state(E, Now, GraceMs) =:= not_granted],
    degraded_if_any(Failing).

degraded_if_any([])      -> ok;
degraded_if_any(Failing) -> {degraded, #{provider_grants => Failing}}.

%% @doc Every procedure with its state, for /health to list whatever the
%% verdict: a service inside its window is ok and still says why.
-spec report(#{binary() => entry()}, integer(), non_neg_integer()) -> [map()].
report(Entries, Now, GraceMs) ->
    [reported(Proc, E, Now, GraceMs) || {Proc, E} <- sorted(Entries)].

reported(Proc, #{result := granted}, _Now, _GraceMs) ->
    #{procedure => Proc, status => <<"granted">>};
reported(Proc, #{result := {not_granted, Reason}, since := Since} = E, Now, GraceMs) ->
    #{procedure => Proc,
      status    => atom_to_binary(state(E, Now, GraceMs)),
      reason    => iolist_to_binary(io_lib:format("~0p", [Reason])),
      since_ms  => Now - Since}.

%% @doc The grace window from `mcl_om' app env, default 60 s.
-spec grace_ms() -> non_neg_integer().
grace_ms() ->
    grace_of(application:get_env(mcl_om, provider_grant_grace_ms)).

grace_of({ok, Ms}) when is_integer(Ms), Ms >= 0 -> Ms;
grace_of(_Unset)                                -> ?DEFAULT_GRACE_MS.

%%% Internals

state(#{result := {not_granted, Reason}, since := Since}, Now, GraceMs) ->
    waited(immediate(Reason), Now - Since >= GraceMs).

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
