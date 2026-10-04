%%% @doc The guard''s counters, audit ring, and alert facts (mcl-om#13).
%%%
%%% Owns the named ETS table the rate stage hits on EVERY inbound call:
%%% a fixed-window counter per (procedure, caller), plus cumulative
%%% denial counters per (procedure, kind). allow/3 is atomic ETS work in
%%% the caller''s process -- no gen_server hop on the hot path. The rare
%%% paths do go through this process: record_change/2 (audit), the audit
%%% reads inside stats/1, and the periodic alert report.
%%%
%%% ALERT FACTS: sensing for the guardian is push, not poll. On a timer
%%% this process walks every declared procedure and publishes one
%%% `denials_observed' fact per procedure per window -- and only when
%%% that window saw a denial or an over-limit caller (should_report/3):
%%% a quiet window publishes nothing, so an attacker cannot use a quiet
%%% service as a fact amplifier, and a denial flood collapses into one
%%% fact per window. mcl-sec-guard subscribes to the topic and acts or
%%% not. The payload is binaries and numbers only; the procedure is in
%%% the payload, never in the topic.
%%%
%%% The window is keyed by its START time ((Now div WindowMs) * WindowMs),
%%% so one sweep can be conservative across procedures with different
%%% window lengths: a window older than three times the LARGEST window
%%% length in use is definitely stale for everyone.
%%%
%%% The audit ring is in-memory, bounded (32 entries per procedure), and
%%% additionally logger-logged per change -- a readable trail, NOT the
%%% tamper-evident event stream the register''s `Security audit log' row
%%% still owes. The guardian''s own store is where that stream will live.
-module(mcl_om_guard).
-behaviour(gen_server).

-export([start_link/0, allow/3, count_denial/2, stats/1, record_change/2,
         should_report/3, alert_payload/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, mcl_om_guard_table).
-define(GLOBAL_KEY, '$global').
-define(CLEANUP_INTERVAL_MS, 60000).
-define(RETAIN_WINDOWS, 3).
-define(AUDIT_RING, 32).
-define(DEFAULT_ALERT_TICK_MS, 10000).
-define(DEFAULT_ALERT_TOPIC, <<"denials_observed">>).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    %% A bad framework-wide limits config must stop the guard (and with
    %% it the app) before anything advertises itself as guarded.
    ok = mcl_om_guard_limits:validate_limits(mcl_om_guard_limits:effective_defaults()),
    ?TABLE = ets:new(?TABLE, [set, public, named_table, {write_concurrency, true}]),
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), sweep),
    erlang:send_after(alert_tick_ms(), self(), report),
    {ok, #{audit => #{}, reported => #{}}}.

%% @doc One fixed-window count for (Procedure, Caller); the denial
%% counter is bumped inside here so a denied call is observable
%% immediately in stats/1.
-spec allow(binary(), binary() | '$global', map()) -> allow | deny.
allow(Proc, Caller, Limits) ->
    Start = window_start(Limits),
    Max = max_for(Caller, Limits),
    Count = ets:update_counter(?TABLE, {Proc, Caller, Start},
                               {2, 1}, {{Proc, Caller, Start}, 0}),
    case Count =< Max of
        true -> allow;
        false -> count_denial(Proc, rate), deny
    end.

%% @doc One fixed-window denial counter, `rate' or 'size', keyed by the
%% window start exactly like the caller buckets: a quiet window reads
%% zero, so should_report/3 stops once its denials age out, and the
%% alert fact's denied counts describe the window they rode in — a
%% cumulative counter made one denial mark every later window denied,
%% turning the service into the fact amplifier should_report exists to
%% prevent.
-spec count_denial(binary(), rate | size) -> ok.
count_denial(Proc, Kind) ->
    #{limits := Limits} = mcl_om_guard_limits:get(Proc),
    Start = window_start(Limits),
    _ = ets:update_counter(?TABLE, {Proc, '$denied', Kind, Start}, {2, 1},
                           {{Proc, '$denied', Kind, Start}, 0}),
    ok.

%% @doc A guardian-facing view of one procedure''s CURRENT window: limits
%% and envelope in effect, global fill, callers over their budget, the
%% heaviest callers, both denial counters, and the recent audit entries.
-spec stats(binary()) -> map().
stats(Proc) ->
    #{limits := Limits, envelope := Envelope} = mcl_om_guard_limits:get(Proc),
    maps:merge(counters(Proc, Limits),
               #{limits => Limits, envelope => Envelope,
                 global_max => maps:get(global_max, Limits),
                 audit => gen_server:call(?MODULE, {audit, Proc})}).

%% @doc Record one applied limits change on the audit ring (and in the
%% log). Called by the control capabilities after a successful apply.
-spec record_change(binary(), map()) -> ok.
record_change(Proc, Change) ->
    gen_server:call(?MODULE, {record, Proc, Change}).

%% @doc Pure: does a procedure''s current window deserve an alert fact?
%% Yes when it is a NEW window (Start differs from the last reported
%% one) AND it saw a denial or an over-limit caller.
-spec should_report(integer(), integer() | undefined, map()) -> boolean().
should_report(Start, LastReported, Stats) ->
    Start =/= LastReported
        andalso (maps:get(denied_rate, Stats) > 0
                 orelse maps:get(denied_size, Stats) > 0
                 orelse maps:get(callers_over_limit, Stats) > 0).

%% @doc Pure: the `denials_observed' fact payload -- binaries and
%% numbers only, the procedure in the payload, never in the topic.
%% `top_callers' rides along (the stats already hold it in a wire-safe
%% shape: a list of maps with hex-encoded caller ids) so the guardian's
%% rule can name the actual offenders instead of proposing a blind
%% floor; `distinct_callers' tells it how wide the window's activity
%% was.
-spec alert_payload(binary(), map(), map()) -> map().
alert_payload(Proc, Limits, Stats) ->
    #{procedure => Proc,
      window_start_ms => maps:get(current_window, Stats),
      denied_rate => maps:get(denied_rate, Stats),
      denied_size => maps:get(denied_size, Stats),
      callers_over_limit => maps:get(callers_over_limit, Stats),
      global_count => maps:get(global_count, Stats),
      global_max => maps:get(global_max, Limits),
      per_caller_max => maps:get(per_caller_max, Limits),
      distinct_callers => maps:get(distinct_callers, Stats),
      top_callers => maps:get(top_callers, Stats)}.

max_for(?GLOBAL_KEY, Limits) -> maps:get(global_max, Limits);
max_for(_Caller, Limits) -> maps:get(per_caller_max, Limits).

%% Caller ids ride the wire as text, which must be valid UTF-8: hex.
wire_caller(Caller) when is_binary(Caller) ->
    binary:encode_hex(Caller, lowercase);
wire_caller(Other) ->
    Other.

denied(Proc, Kind, Start) ->
    case ets:lookup(?TABLE, {Proc, '$denied', Kind, Start}) of
        [{_Key, Count}] -> Count;
        [] -> 0
    end.

counters(Proc, Limits) ->
    Start = window_start(Limits),
    {GlobalCount, Callers} = current_window_counts(Proc, Start),
    PerCallerMax = maps:get(per_caller_max, Limits),
    OverLimit = [Caller || {Caller, Count} <- Callers, Count > PerCallerMax],
    %% `top_callers' is a LIST OF MAPS, not a list of tuples: the wire
    %% codec refuses tuples in payloads (unknown_error on the caller),
    %% and this map rides get_limits' reply.
    Sorted = lists:reverse(lists:keysort(2, Callers)),
    %% `top_callers' is a LIST OF MAPS, and each caller is HEX-ENCODED:
    %% the wire turns binaries into text, which must be valid UTF-8, and
    %% node ids are arbitrary bytes. (Tuples would be refused outright —
    %% both failure modes surface as unknown_error on the caller.)
    TopCallers = [#{caller => binary:encode_hex(Caller, lowercase), count => Count}
                  || {Caller, Count} <- lists:sublist(Sorted, 10)],
    #{current_window => Start,
      global_count => GlobalCount,
      distinct_callers => length(Callers),
      callers_over_limit => length(OverLimit),
      top_callers => TopCallers,
      denied_rate => denied(Proc, rate, Start),
      denied_size => denied(Proc, size, Start)}.

window_start(Limits) ->
    WindowMs = maps:get(window_ms, Limits),
    %% WALL CLOCK, deliberately: window starts ride the wire (stats and
    %% alert facts) and OTP 28's `monotonic_time' is signed — negative —
    %% which the wire codec refuses. Wall-clock windows also let the
    %% guardian correlate across services.
    (erlang:system_time(millisecond) div WindowMs) * WindowMs.

current_window_counts(Proc, Start) ->
    Fold = fun({{P, ?GLOBAL_KEY, W}, Count}, {Global, Callers})
                 when P =:= Proc, W =:= Start ->
                   {Global + Count, Callers};
              ({{P, Caller, W}, Count}, {Global, Callers})
                 when P =:= Proc, W =:= Start ->
                   {Global, [{Caller, Count} | Callers]};
              (_Entry, Acc) ->
                   Acc
           end,
    ets:foldl(Fold, {0, []}, ?TABLE).

report_window_denials(Reported) ->
    case mcl_om:mesh_handles() of
        {ok, _Pool, _Realm} ->
            lists:foldl(fun report_procedure/2, Reported,
                        mcl_om_guard_limits:procedures());
        {error, mesh_unavailable} ->
            Reported
    end.

report_procedure(Proc, Reported) ->
    #{limits := Limits} = mcl_om_guard_limits:get(Proc),
    Stats = counters(Proc, Limits),
    Start = maps:get(current_window, Stats),
    Last = maps:get(Proc, Reported, undefined),
    case should_report(Start, Last, Stats) of
        true ->
            Payload = alert_payload(Proc, Limits, Stats),
            _ = mcl_om_pubsub:publish(alert_topic(), Payload, #{mode => async_log}),
            Reported#{Proc => Start};
        false ->
            Reported
    end.

alert_topic() ->
    case application:get_env(mcl_om, inbound_guard, #{}) of
        #{alert_topic := Topic} when is_binary(Topic) -> Topic;
        _NoConfig -> ?DEFAULT_ALERT_TOPIC
    end.

alert_tick_ms() ->
    case application:get_env(mcl_om, inbound_guard, #{}) of
        #{alert_tick_ms := Tick} when is_integer(Tick), Tick > 0 -> Tick;
        _NoConfig -> ?DEFAULT_ALERT_TICK_MS
    end.

handle_call({record, Proc, Change}, _From, #{audit := Audit} = State) ->
    Change1 = Change#{caller => wire_caller(maps:get(caller, Change, unknown))},
    Ring = maps:get(Proc, Audit, []),
    NewRing = lists:sublist([Change1 | Ring], ?AUDIT_RING),
    ok = logger:notice(
           "mcl_om_guard: limits changed proc=~s tier=~p caller=~p "
           "before=~p after=~p",
           [Proc, maps:get(tier, Change1, unknown), maps:get(caller, Change1, unknown),
            maps:get(before, Change1), maps:get('after', Change1)]),
    {reply, ok, State#{audit := Audit#{Proc => NewRing}}};
handle_call({audit, Proc}, _From, #{audit := Audit} = State) ->
    {reply, maps:get(Proc, Audit, []), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    sweep_old_windows(),
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), sweep),
    {noreply, State};
handle_info(report, #{reported := Reported} = State) ->
    NewReported = report_window_denials(Reported),
    erlang:send_after(alert_tick_ms(), self(), report),
    {noreply, State#{reported := NewReported}};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

sweep_old_windows() ->
    %% The same wall clock the window keys use (see window_start/1).
    Now = erlang:system_time(millisecond),
    Cutoff = Now - ?RETAIN_WINDOWS * mcl_om_guard_limits:max_window_ms(),
    %% Windowed entries carry an integer start time: the caller buckets
    %% in the third element, the denial counters ({Proc, '$denied',
    %% Kind, Start}) in the fourth.
    BucketSpec = [{{{'_', '_', '$1'}, '_'},
                   [{is_integer, '$1'}, {'<', '$1', Cutoff}], [true]}],
    DenialSpec = [{{{'_', '_', '_', '$1'}, '_'},
                   [{is_integer, '$1'}, {'<', '$1', Cutoff}], [true]}],
    _ = ets:select_delete(?TABLE, BucketSpec),
    _ = ets:select_delete(?TABLE, DenialSpec),
    ok.
