%%%-------------------------------------------------------------------
%%% @doc Whether this service's advertise loop is alive, per capability,
%%% and what that means for /health.
%%%
%%% The grants table answers "does the realm authorize this provider"
%%% (mcl_om_provider_grant). This answers "is the provider's own
%%% advertise loop actually running": `mcl_om_capabilities' records the
%%% last advertise outcome per org-namespaced procedure on every
%%% republish tick, and /health judges the entries here.
%%%
%%% Why it exists: an advertise loop can be dead while everything else
%%% is green. A provider whose republish timer stopped (found live
%%% 2026-09-25, beam03: the loop went silent after a pre-grant
%%% advertise failure) still answered `/health ok' with
%%% `failed_publishes: 0' -- zero is exactly what a loop that makes no
%%% attempts produces. The last successful advertise's age is the
%%% signal: once it outlives the advertisement record's own TTL, the
%%% record is gone from the DHT and no caller can resolve this
%%% provider, whatever the grants say.
%%%
%%% Judging rules (the caller supplies the clock, like
%%% mcl_om_provider_grant):
%%%
%%% - `alive': a success within `stale_after_ms/0'.
%%% - `stale': a success older than that -- the record has expired and
%%%   the loop is not replacing it. Degraded at once.
%%% - `never_succeeded': attempts have failed but none has succeeded.
%%%   Degraded once the failure run is older than `grace_ms/0' (default
%%%   60s, the same grace the grants use): a pre-grant boot fails its
%%%   first advertises for reasons the grants already report, and one
%%%   transient failure should not flap /health.
%%%
%%% A procedure with no entry at all has never been attempted (or its
%%%   service just booted): not listed, and not degrading -- the first
%%%   tick writes the first entry.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_om_advertise_liveness).

-export([observed/4, verdict/3, report/3, stale_after_ms/0, grace_ms/0]).
-export_type([entry/0]).

%% The advertisement record's TTL (4x the republish interval,
%% mcl_om_capabilities's ADVERTISEMENT_TTL_MS): the longest a healthy
%% loop goes between successes is the republish interval, so a success
%% older than the record's own lifetime means the record is gone from
%% the DHT and the loop is not replacing it.
-define(DEFAULT_STALE_AFTER_MS, 120_000).
%% The same grace the provider grants use before degrading a
%% not-granted procedure: one failure should not flap /health.
-define(DEFAULT_GRACE_MS, 60_000).

-type entry() :: #{last_success := integer() | undefined,
                   last_failure := {integer(), term()} | undefined}.

%% @doc The entry for one procedure, from its advertise outcome at
%% `Now' (monotonic ms) and its previous entry (`undefined' on the
%% first tick). A success clears the failure; a failure leaves the
%% last success in place, so an alive-then-failing loop still ages its
%% last success toward stale.
-spec observed(ok | {error, term()}, binary(), integer(), entry() | undefined) ->
    entry().
observed(ok, _Proc, Now, _Previous) ->
    #{last_success => Now, last_failure => undefined};
observed({error, Reason}, _Proc, Now, undefined) ->
    #{last_success => undefined, last_failure => {Now, Reason}};
observed({error, Reason}, _Proc, Now, #{last_success := Success}) ->
    #{last_success => Success, last_failure => {Now, Reason}}.

%% @doc `ok', or `{degraded, #{advertise_liveness => Failing}}' naming
%% each procedure whose loop is stale or has never succeeded past the
%% grace window.
-spec verdict(#{binary() => entry()}, integer(), non_neg_integer()) ->
    ok | {degraded, #{advertise_liveness := [map()]}}.
verdict(Entries, Now, StaleAfterMs) ->
    Failing = [#{procedure => Proc, status => State,
                 last_advertise_ms_ago => age(maps:get(last_success, E), Now)}
               || {Proc, E} <- sorted(Entries),
                  State <- [liveness_state(E, Now, StaleAfterMs)],
                  State =/= alive],
    degraded_if_any(Failing).

degraded_if_any([])      -> ok;
degraded_if_any(Failing) -> {degraded, #{advertise_liveness => Failing}}.

%% @doc Every procedure with its state, for /health to list whatever
%% the verdict: a procedure inside its grace window is ok and still
%% says what its loop last did. The report shows the raw state
%% (`alive' | `stale' | `never_succeeded'); the verdict separately
%% grace-buffers `never_succeeded'.
-spec report(#{binary() => entry()}, integer(), non_neg_integer()) -> [map()].
report(Entries, Now, StaleAfterMs) ->
    [reported(Proc, E, Now, StaleAfterMs) || {Proc, E} <- sorted(Entries)].

reported(Proc, #{last_success := Success, last_failure := Failure}, Now,
         StaleAfterMs) ->
    Base = #{procedure => Proc,
             status    => atom_to_binary(raw_state(Success, Now, StaleAfterMs)),
             last_advertise_ms_ago => age(Success, Now)},
    with_failure(Failure, Now, Base).

raw_state(undefined, _Now, _StaleAfterMs) -> never_succeeded;
raw_state(Success, Now, StaleAfterMs) ->
    case Now - Success > StaleAfterMs of
        true  -> stale;
        false -> alive
    end.

with_failure({FailureAt, Reason}, Now, Map) ->
    Map#{last_advertise_failure => #{ms_ago => Now - FailureAt,
                                     reason => iolist_to_binary(
                                                 io_lib:format("~0p", [Reason]))}};
with_failure(undefined, _Now, Map) ->
    Map.

%% @doc The staleness window from `mcl_om' app env, default 120s (the
%% advertisement record's TTL).
-spec stale_after_ms() -> non_neg_integer().
stale_after_ms() ->
    window(application:get_env(mcl_om, advertise_stale_after_ms),
           ?DEFAULT_STALE_AFTER_MS).

%% @doc The grace window for a never-succeeded procedure, from `mcl_om'
%% app env, default 60s.
-spec grace_ms() -> non_neg_integer().
grace_ms() ->
    window(application:get_env(mcl_om, advertise_grace_ms), ?DEFAULT_GRACE_MS).

window({ok, Ms}, _Default) when is_integer(Ms), Ms >= 0 -> Ms;
window(_Unset, Default)                                  -> Default.

%%% Internals

liveness_state(#{last_success := Success}, Now, StaleAfterMs)
  when Success =/= undefined ->
    case Now - Success > StaleAfterMs of
        true  -> stale;
        false -> alive
    end;
liveness_state(#{last_success := undefined, last_failure := {FailureAt, _}},
               Now, _StaleAfterMs) ->
    case Now - FailureAt > grace_ms() of
        true  -> never_succeeded;
        false -> alive
    end;
liveness_state(#{last_success := undefined}, _Now, _StaleAfterMs) ->
    alive.

age(undefined, _Now) -> undefined;
age(Success, Now)    -> Now - Success.

sorted(Entries) ->
    lists:keysort(1, maps:to_list(Entries)).
