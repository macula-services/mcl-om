%%% @doc The guardian control surface (mcl-om#13): the `limits.get' /
%%% `limits.set' / 'limits.set_operator' capabilities every mcl_om
%%% service exposes for mcl-sec-guard.
%%%
%%% - `limits.get' is always advertised, 'auth => open': limits +
%%%   current-window stats for one procedure, or every declared one.
%%% - `limits.set' is the guardian tier''s actuator: within the
%%%   per-parameter envelope only (envelope_exceeded otherwise), and
%%%   never the envelope itself. `limits.set_operator' is the human
%%%   tier: anything valid, including a new envelope. Both are
%%%   advertised only when this app''s `inbound_guard.guardian' config
%%%   names the realm DID (32 bytes, the realm''s Ed25519 key) and both
%%%   tier names; without it they do not exist on the wire, and the
%%%   service logs that once.
%%%
%%% Every APPLIED change is recorded on the guard''s audit ring with
%%% caller, tier, before and after; an unchanged set is a no-op and gets
%%% no audit entry. The handlers are plain functions dispatched through
%%% mcl_om_simple_handler, so the pipeline wraps them like any other
%%% capability — the guardian pays the default rate budget too.
-module(mcl_om_guard_control).

-export([with_caps/1, get_limits/1, set_guardian/1, set_operator/1]).

-define(GET_NAME, <<"limits.get">>).
-define(SET_NAME, <<"limits.set">>).
-define(OPERATOR_NAME, <<"limits.set_operator">>).
-define(NAMES, [?GET_NAME, ?SET_NAME, ?OPERATOR_NAME]).

%% @doc The control capabilities, prepended to a service''s own list.
%% `limits.get' always; the two set capabilities only when the guardian
%% config exists. A service that declared its own `limits.*' name is
%% refused — these names are mcl_om''s, on every node.
-spec with_caps([mcl_om_service:capability()]) -> [mcl_om_service:capability()].
with_caps(Caps) ->
    ok = not_declared([Name || #{name := Name} <- Caps]),
    [limits_get_cap()] ++ set_caps() ++ Caps.

not_declared(Names) ->
    case [Name || Name <- Names, lists:member(Name, ?NAMES)] of
        [] -> ok;
        [Taken | _] -> error({mcl_om_guard_capability_name_reserved, Taken})
    end.

limits_get_cap() ->
    #{name => ?GET_NAME, version => 1, auth => open,
      handler => {mcl_om_simple_handler, {?MODULE, get_limits}}}.

set_caps() ->
    case guardian_config() of
        {ok, RealmDid, GuardianTier, OperatorTier} ->
            [#{name => ?SET_NAME, version => 1,
               auth => {realm_member_required, RealmDid, GuardianTier},
               handler => {mcl_om_simple_handler, {?MODULE, set_guardian}}},
             #{name => ?OPERATOR_NAME, version => 1,
               auth => {realm_member_required, RealmDid, OperatorTier},
               handler => {mcl_om_simple_handler, {?MODULE, set_operator}}}];
        undefined ->
            log_once_no_guardian(),
            []
    end.

guardian_config() ->
    case application:get_env(mcl_om, inbound_guard, #{}) of
        #{guardian := #{realm_did := RealmDid,
                        guardian_tier := GuardianTier,
                        operator_tier := OperatorTier}}
          when is_binary(RealmDid), byte_size(RealmDid) =:= 32,
               is_binary(GuardianTier), is_binary(OperatorTier) ->
            {ok, RealmDid, GuardianTier, OperatorTier};
        _NoConfig ->
            undefined
    end.

log_once_no_guardian() ->
    Warned = persistent_term:get({?MODULE, warned}, false),
    case Warned of
        false ->
            ok = logger:warning(
                   "mcl_om_guard_control: no inbound_guard.guardian config "
                   "(realm_did + guardian_tier + operator_tier), so "
                   "limits.set / limits.set_operator are not advertised; "
                   "limits.get is"),
            persistent_term:put({?MODULE, warned}, true);
        true ->
            ok
    end.

%% ---- handlers (mcl_om_simple_handler dispatch targets) ----

%% @doc Payload: none, or `#{procedure => Proc}'. Reply: that
%% procedure''s stats, or every declared procedure''s.
-spec get_limits(term()) -> {ok, map()} | {error, term()}.
get_limits(Payload) ->
    case procedure_of(Payload) of
        {error, _Reason} = Error -> Error;
        all -> {ok, #{procedures => all_stats()}};
        {one, Proc} -> {ok, mcl_om_guard:stats(Proc)}
    end.

procedure_of(Payload) when is_map(Payload) ->
    case maps:get(procedure, Payload, all) of
        all -> all;
        Proc when is_binary(Proc) -> {one, Proc};
        Other -> {error, {bad_procedure, Other}}
    end;
procedure_of(_Payload) ->
    all.

all_stats() ->
    maps:from_list([{Proc, mcl_om_guard:stats(Proc)}
                    || Proc <- mcl_om_guard_limits:procedures()]).

%% @doc Payload: `#{procedure => Proc, limits => Overrides}'. The
%% platform injects `caller' for map payloads; it lands in the audit
%% entry.
-spec set_guardian(map()) -> {ok, map()} | {error, term()}.
set_guardian(Payload) ->
    set_with_tier(Payload, guardian).

-spec set_operator(map()) -> {ok, map()} | {error, term()}.
set_operator(Payload) ->
    set_with_tier(Payload, operator).

set_with_tier(Payload, Tier) ->
    case payload_parts(Payload) of
        {error, _Reason} = Error -> Error;
        {ok, Proc, Overrides, Caller} -> apply_set(Proc, Overrides, Tier, Caller)
    end.

payload_parts(Payload) when is_map(Payload) ->
    Caller = maps:get(caller, Payload, unknown),
    case maps:get(procedure, Payload, undefined) of
        Proc when is_binary(Proc) ->
            parts_with_limits(Proc, maps:get(limits, Payload, undefined), Caller);
        _MissingOrBad -> {error, bad_procedure}
    end;
payload_parts(_NotMap) ->
    {error, bad_payload}.

parts_with_limits(Proc, Overrides, Caller) when is_map(Overrides) ->
    {ok, Proc, Overrides, Caller};
parts_with_limits(_Proc, _Overrides, _Caller) ->
    {error, bad_limits}.

apply_set(Proc, Overrides, Tier, Caller) ->
    Before = mcl_om_guard_limits:get(Proc),
    case mcl_om_guard_limits:set(Proc, Overrides, Tier) of
        {error, _Reason} = Error ->
            Error;
        {ok, After} ->
            maybe_record(Proc, Tier, Caller, Before, After),
            {ok, After}
    end.

%% An unchanged set is a no-op, not a change: no audit entry.
maybe_record(_Proc, _Tier, _Caller, Before, Before) ->
    ok;
maybe_record(Proc, Tier, Caller, Before, After) ->
    mcl_om_guard:record_change(Proc,
        #{tier => Tier, caller => Caller, before => Before, 'after' => After}).
