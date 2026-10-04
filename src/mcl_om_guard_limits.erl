%%% @doc Per-procedure inbound limits + envelope, in persistent_term.
%%%
%%% THE DATA SHAPE OF THE GUARD (mcl-om#13): every capability that flows
%%% through mcl_om_guard_pipeline has ONE entry here, keyed by its
%%% org-qualified procedure:
%%%
%%% - `declared': the limits the capability itself declares (its 'limits'
%%%   key merged over the framework defaults), recomputed on every
%%%   advertise tick;
%%% - `overrides': runtime changes, from 'limits.set' (guardian tier,
%%%   inside the envelope) or `limits.set_operator' (human, anything);
%%% - `limits': the effective set = merge(declared, overrides) -- what the
%%%   stages enforce on every call;
%%% - `envelope' / 'declared_envelope': per-key min/max clamps. Only the
%%%   operator tier may change them, and a guardian-tier set that a key''s
%%%   envelope does not cover fails with `envelope_exceeded' -- no
%%%   envelope, no guardian movement, by default.
%%%
%%% WHY persistent_term: the stages read `limits' on EVERY inbound call,
%%% in the caller''s own process, and must not serialize through a
%%% gen_server; reads are shared and copy-free, writes are rare (a
%%% declare tick, or an explicit limits.set).
%%%
%%% A redeclare at republish time recomputes `limits' as
%%% merge(declared', overrides), so a service upgrade re-declares its
%%% base without wiping the guardian''s runtime changes -- the tick must
%%% never undo what an operator or a guardian set.
-module(mcl_om_guard_limits).

%% `get/1' is this module''s own API name, next to the auto-imported
%% `erlang:get/1'; the clash is resolved here once instead of at every
%% call site.
-compile({no_auto_import, [get/1]}).

-export([defaults/0, effective_defaults/0, declare/2, get/1, reset/1,
         set/3, validate_limits/1, validate_envelope/1, max_window_ms/0,
         procedures/0]).

-ifdef(TEST).
-export([clear/0]).
-endif.

-define(PT_KEY, {?MODULE, entries}).
-define(KEYS, [max_payload_external_size, window_ms, per_caller_max, global_max,
               max_distinct_callers]).
-define(ENVELOPE_KEY, envelope).

-type limits() :: #{max_payload_external_size := pos_integer(),
                    window_ms := pos_integer(),
                    per_caller_max := pos_integer(),
                    global_max := pos_integer(),
                    max_distinct_callers := pos_integer()}.
-type envelope() :: #{atom() => #{min := pos_integer(), max := pos_integer()}}.

-export_type([limits/0, envelope/0]).

%% @doc The shipped framework defaults, per procedure. Deliberately
%% roomier than the echo''s hand-rolled numbers: a capability that needs
%% tighter bounds declares its own `limits'.
-spec defaults() -> limits().
defaults() ->
    #{max_payload_external_size => 65536,
      window_ms                 => 10000,
      per_caller_max            => 600,
      global_max                => 6000,
      max_distinct_callers      => 1024}.

%% @doc The framework defaults with the app env''s
%% `{mcl_om, [{inbound_guard, #{default_limits => ...}}]}' merged over
%% them. Validated at guard boot (mcl_om_guard:init/1); this is the
%% read side.
-spec effective_defaults() -> limits().
effective_defaults() ->
    case application:get_env(mcl_om, inbound_guard, #{}) of
        #{default_limits := Overrides} when is_map(Overrides) ->
            maps:merge(defaults(), Overrides);
        _NoConfig ->
            defaults()
    end.

%% @doc Register (or re-register) a capability''s declared limits and
%% envelope, from its capability map''s `limits' key. A redeclare with
%% the same base is a no-op -- runtime overrides survive. Raises
%% `{mcl_om_guard_bad_limits, Proc, Reason}' on a bad map, so the
%% advertise tick that carries it fails loud and keeps the prior
%% registration.
-spec declare(binary(), map()) -> ok.
declare(Proc, CapLimits) when is_map(CapLimits) ->
    Envelope = maps:get(?ENVELOPE_KEY, CapLimits, #{}),
    Declared = maps:merge(effective_defaults(), maps:remove(?ENVELOPE_KEY, CapLimits)),
    case {validate_limits(Declared), validate_envelope(Envelope)} of
        {ok, ok} -> declare_validated(Proc, Declared, Envelope), ok;
        {{error, _} = Error, _} -> error({mcl_om_guard_bad_limits, Proc, Error});
        {_, {error, _} = Error} -> error({mcl_om_guard_bad_limits, Proc, Error})
    end;
declare(Proc, NotMap) ->
    error({mcl_om_guard_bad_limits, Proc, {not_a_map, NotMap}}).

declare_validated(Proc, Declared, Envelope) ->
    Current = entries(),
    case maps:get(Proc, Current, undefined) of
        #{declared := Declared, declared_envelope := Envelope} ->
            ok;   %% same base: the republish tick must not touch runtime state
        undefined ->
            put_entries(Current#{Proc => new_entry(Declared, Envelope, #{})});
        #{overrides := Overrides} ->
            put_entries(Current#{Proc => new_entry(Declared, Envelope, Overrides)})
    end.

%% @doc The effective limits and envelope of one procedure. Falls back
%% to the framework defaults (and no envelope) before the first declare.
-spec get(binary()) -> #{limits := limits(), envelope := envelope()}.
get(Proc) ->
    case maps:get(Proc, entries(), undefined) of
        undefined -> #{limits => effective_defaults(), envelope => #{}};
        #{limits := Limits, envelope := Envelope} ->
            #{limits => Limits, envelope => Envelope}
    end.

%% @doc Drop all runtime overrides and the runtime envelope: back to the
%% declared base (which the next advertise tick recomputes).
-spec reset(binary()) -> {ok, #{limits := limits(), envelope := envelope()}}.
reset(Proc) ->
    case maps:get(Proc, entries(), undefined) of
        undefined -> {ok, get(Proc)};
        #{declared := Declared, declared_envelope := Envelope} ->
            Current = entries(),
            put_entries(Current#{Proc => new_entry(Declared, Envelope, #{})}),
            {ok, #{limits => Declared, envelope => Envelope}}
    end.

%% @doc Apply an override set at a tier. `guardian': within the envelope
%% only, never the envelope itself. `operator': anything valid, and may
%% carry a new `envelope'. Returns the new effective pair, or the
%% validation error; on error nothing changes.
-spec set(binary(), map(), guardian | operator) ->
          {ok, #{limits := limits(), envelope := envelope()}} | {error, term()}.
set(Proc, Overrides, Tier) when is_map(Overrides) ->
    case maps:get(Proc, entries(), undefined) of
        undefined -> {error, {unknown_procedure, Proc}};
        Entry -> do_set(Proc, Entry, Overrides, Tier)
    end;
set(_Proc, NotMap, _Tier) ->
    {error, {not_a_map, NotMap}}.

do_set(Proc, Entry, Request, guardian) ->
    case maps:is_key(?ENVELOPE_KEY, Request) of
        true ->
            {error, envelope_operator_only};
        false ->
            guardian_set(Proc, Entry, Request)
    end;
do_set(Proc, Entry, Request, operator) ->
    operator_set(Proc, Entry, Request).

guardian_set(Proc, #{declared := Declared, declared_envelope := DeclaredEnvelope,
                     overrides := Overrides} = Entry, Request) ->
    case {validate_limits_keys(Request), within_envelope(Request, Entry)} of
        {ok, ok} ->
            apply_and_put(Proc, Declared, DeclaredEnvelope,
                          maps:merge(Overrides, Request), DeclaredEnvelope);
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

operator_set(Proc, #{declared := Declared, declared_envelope := DeclaredEnvelope,
                     overrides := Overrides}, Request) ->
    LimitsPart = maps:remove(?ENVELOPE_KEY, Request),
    NewEnvelope = maps:get(?ENVELOPE_KEY, Request, undefined),
    case {validate_limits_keys(LimitsPart), validate_new_envelope(NewEnvelope)} of
        {ok, ok} ->
            apply_and_put(Proc, Declared, DeclaredEnvelope,
                          maps:merge(Overrides, LimitsPart),
                          envelope_or(NewEnvelope, DeclaredEnvelope));
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

apply_and_put(Proc, Declared, DeclaredEnvelope, Overrides, Envelope) ->
    NewLimits = maps:merge(Declared, Overrides),
    case validate_limits(NewLimits) of
        {error, _} = Error ->
            Error;
        ok ->
            Entry = #{declared => Declared, declared_envelope => DeclaredEnvelope,
                      overrides => Overrides, envelope => Envelope,
                      limits => NewLimits},
            All = entries(),
            put_entries(All#{Proc => Entry}),
            {ok, #{limits => NewLimits, envelope => Envelope}}
    end.

envelope_or(undefined, DeclaredEnvelope) -> DeclaredEnvelope;
envelope_or(Envelope, _DeclaredEnvelope) -> Envelope.

validate_new_envelope(undefined) -> ok;
validate_new_envelope(Envelope) -> validate_envelope(Envelope).

%% A guardian-tier set: every key it changes must sit inside the
%% envelope''s clamp for that key. A key the envelope does not cover
%% cannot be moved by the guardian at all.
within_envelope(Request, #{envelope := Envelope}) ->
    Fold = fun(Key, Value, Acc) -> envelope_verdict(Key, Value, Envelope, Acc) end,
    maps:fold(Fold, ok, Request).

envelope_verdict(_Key, _Value, _Envelope, {error, _} = Error) ->
    Error;
envelope_verdict(Key, Value, Envelope, ok) ->
    case maps:get(Key, Envelope, undefined) of
        #{min := Min, max := Max} when Min =< Value, Value =< Max ->
            ok;
        _ClampOrMissing ->
            {error, {envelope_exceeded, Key, Value}}
    end.

%% @doc Full-map validation: known keys, positive integers, and the
%% per-caller budget at most the shared one.
-spec validate_limits(map()) -> ok | {error, term()}.
validate_limits(Map) when is_map(Map) ->
    case validate_entries(maps:to_list(Map)) of
        ok -> validate_relation(Map);
        {error, _} = Error -> Error
    end;
validate_limits(NotMap) ->
    {error, {not_a_map, NotMap}}.

%% @doc Envelope validation: every clamp names a limit key, and carries
%% positive `min' and `max' integers, min not above max.
-spec validate_envelope(map()) -> ok | {error, term()}.
validate_envelope(Envelope) when is_map(Envelope) ->
    validate_envelope_entries(maps:to_list(Envelope));
validate_envelope(NotMap) ->
    {error, {not_a_map, NotMap}}.

validate_envelope_entries([]) ->
    ok;
validate_envelope_entries([{Key, Clamp} | Rest]) ->
    case lists:member(Key, ?KEYS) of
        false -> {error, {unknown_key, Key}};
        true -> validate_clamp(Key, Clamp, Rest)
    end.

validate_clamp(_Key, #{min := Min, max := Max}, Rest)
  when is_integer(Min), Min > 0, is_integer(Max), Max > 0, Min =< Max ->
    validate_envelope_entries(Rest);
validate_clamp(Key, Clamp, _Rest) ->
    {error, {bad_envelope_clamp, Key, Clamp}}.

%% @doc The largest window length any declared procedure uses -- the
%% sweep''s conservative cutoff horizon (mcl_om_guard:sweep_old_windows/0).
-spec max_window_ms() -> pos_integer().
max_window_ms() ->
    lists:max([maps:get(window_ms, effective_defaults())
               | [maps:get(window_ms, maps:get(limits, Entry))
                  || {_Proc, Entry} <- maps:to_list(entries())]]).

%% @doc Every procedure with a declared entry -- the alert report walks
%% these (mcl_om_guard:report_window_denials/1).
-spec procedures() -> [binary()].
procedures() ->
    maps:keys(entries()).

%% The override-set check: only the keys a caller names are validated
%% here; the merge and the relation run against the full result in
%% apply_and_put/5.
validate_limits_keys(Map) ->
    validate_entries(maps:to_list(Map)).

validate_entries([]) ->
    ok;
validate_entries([{Key, Value} | Rest]) ->
    case lists:member(Key, ?KEYS) of
        false -> {error, {unknown_key, Key}};
        true -> validate_entry_value(Key, Value, Rest)
    end.

validate_entry_value(_Key, Value, Rest) when is_integer(Value), Value > 0 ->
    validate_entries(Rest);
validate_entry_value(Key, Value, _Rest) ->
    {error, {not_a_positive_integer, Key, Value}}.

validate_relation(#{per_caller_max := PerCaller, global_max := Global})
  when PerCaller > Global ->
    {error, {per_caller_above_global, PerCaller, Global}};
validate_relation(_Limits) ->
    ok.

new_entry(Declared, Envelope, Overrides) ->
    #{declared => Declared, declared_envelope => Envelope,
      overrides => Overrides, envelope => Envelope,
      limits => maps:merge(Declared, Overrides)}.

entries() ->
    persistent_term:get(?PT_KEY, #{}).

put_entries(Entries) ->
    persistent_term:put(?PT_KEY, Entries).

-ifdef(TEST).
clear() ->
    persistent_term:erase(?PT_KEY),
    ok.
-endif.
