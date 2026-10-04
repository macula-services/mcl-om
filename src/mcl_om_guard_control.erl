%%% @doc The guardian control surface (mcl-om#13): the `get_limits' /
%%% `set_limits' capabilities every mcl_om service exposes for
%%% mcl-sec-guard.
%%%
%%% - `get_limits' is always advertised, `auth => open': limits +
%%%   current-window stats for one procedure, or every declared one.
%%% - `set_limits' is the guardian tier's actuator, advertised only when
%%%   this app's `inbound_guard.guardian' config names the realm DID
%%%   (32 bytes, the realm's Ed25519 key) and the guardian tier name;
%%%   without it, no gated surface exists on the wire, and the service
%%%   logs that once. The guardian may tune limits only within the
%%%   per-key envelope; the envelope itself is deploy config, changed by
%%%   a human, never over the mesh.
%%%
%%% Every APPLIED change is recorded on the guard's audit ring with
%%% caller, tier, before and after; an unchanged set is a no-op and gets
%%% no audit entry. The handlers are plain functions dispatched through
%%% mcl_om_simple_handler, so the pipeline wraps them like any other
%%% capability — the guardian pays the default rate budget too.
-module(mcl_om_guard_control).

-export([with_caps/1, get_limits/1, set_limits/1]).

-define(GET_NAME, <<"get_limits">>).
-define(SET_NAME, <<"set_limits">>).
-define(NAMES, [?GET_NAME, ?SET_NAME]).

%% @doc The control capabilities, prepended to a service's own list.
%% `get_limits' always; `set_limits' only when the guardian config
%% exists. A service that declared its own name is refused — these names
%% are mcl_om's, on every node.
-spec with_caps([mcl_om_service:capability()]) -> [mcl_om_service:capability()].
with_caps(Caps) ->
    ok = not_declared([Name || #{name := Name} <- Caps]),
    [get_limits_cap()] ++ set_limits_caps() ++ Caps.

not_declared(Names) ->
    case [Name || Name <- Names, lists:member(Name, ?NAMES)] of
        [] -> ok;
        [Taken | _] -> error({mcl_om_guard_capability_name_reserved, Taken})
    end.

get_limits_cap() ->
    #{name => ?GET_NAME, version => 1, auth => open,
      handler => {mcl_om_simple_handler, {?MODULE, get_limits}}}.

set_limits_caps() ->
    case guardian_config() of
        {ok, RealmDid, GuardianTier} ->
            [#{name => ?SET_NAME, version => 1,
               auth => {realm_member_required, RealmDid, GuardianTier},
               handler => {mcl_om_simple_handler, {?MODULE, set_limits}}}];
        undefined ->
            log_once_no_guardian(),
            []
    end.

guardian_config() ->
    case application:get_env(mcl_om, inbound_guard, #{}) of
        #{guardian := #{realm_did := RealmDid, guardian_tier := GuardianTier}}
          when is_binary(RealmDid), byte_size(RealmDid) =:= 32,
               is_binary(GuardianTier) ->
            {ok, RealmDid, GuardianTier};
        _NoConfig ->
            undefined
    end.

log_once_no_guardian() ->
    Warned = persistent_term:get({?MODULE, warned}, false),
    case Warned of
        false ->
            ok = logger:warning(
                   "mcl_om_guard_control: no inbound_guard.guardian config "
                   "(realm_did + guardian_tier), so set_limits is not "
                   "advertised; get_limits is"),
            persistent_term:put({?MODULE, warned}, true);
        true ->
            ok
    end.

%% ---- handlers (mcl_om_simple_handler dispatch targets) ----

%% @doc Payload: none, or `#{procedure => Proc}'. Reply: that
%% procedure's stats, or every declared procedure's.
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
%% guardian tier only: within the envelope, never the envelope itself.
%% The platform injects `caller' for map payloads; it lands in the
%% audit entry.
-spec set_limits(map()) -> {ok, map()} | {error, term()}.
set_limits(Payload) ->
    case payload_parts(Payload) of
        {error, _Reason} = Error -> Error;
        {ok, Proc, Overrides, Caller} -> apply_set(Proc, Overrides, guardian, Caller)
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
