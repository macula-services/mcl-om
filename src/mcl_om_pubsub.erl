%%% @doc Publish onto the mesh via macula's supervised `macula_publisher',
%%% instead of every service hand-rolling `catch macula:publish(...)'.
%%%
%%% Confirmed by a 2026-08-24 workspace-wide survey (see
%%% `hecate-om/plans/PLAN_MCL_OM_MESH_WRAPPERS.md', piece C): ~20
%%% `hecate-services/*' repos independently wrote the same
%%%
%%%   case {mcl_om:macula_client(), mcl_om_identity:realm()} of
%%%       {{ok, Pool}, {ok, Realm}} -> catch macula:publish(...), ok;
%%%       _ -> ok
%%%   end
%%%
%%% idiom, in three different flavors of what to do with the outcome
%%% (silently discard it, log it, or return it to the caller). Building
%%% this against `macula_publisher' rather than a raw synchronous call
%%% gets every caller two things none of the hand-rolled sites had:
%%% cancellable in-flight publishes, and free `pubsub.publish_started_v1'
%%% / `pubsub.publish_completed_v1' mesh facts around every publish.
%%%
%%% `{error, mesh_unavailable}' when this service isn't attached to a
%%% pool or has no realm configured yet — same contract as
%%% `mcl_om:mesh_handles/0', so a caller that already checks for that
%%% shape elsewhere in its own code doesn't need a second case to learn.
-module(mcl_om_pubsub).

-export([publish/2, publish/3, publish_many/2, publish_many/3]).
-export([start_publisher/3, start_publisher/4, start_publisher/5]).
-export([ensure_subscriptions/1]).

%% Pure helpers — realm/mode resolution kept side-effect-free so it is
%% unit-testable without a live mesh (same convention as
%% `mcl_om_capabilities.erl''s exported pure helpers).
-export([resolve_realm/2, resolve_mode/1]).

%% macula_publisher callbacks. Not meant to be called directly — public
%% only because the behaviour contract requires exported functions.
-behaviour(macula_publisher).
-export([init/1, handle_published/2]).

-define(DEFAULT_SYNC_TIMEOUT_MS, 5_000).

-type mode() :: async_silent | async_log | sync.
-type publish_opts() :: #{
    realm   => binary(),
    mode    => mode(),
    timeout => pos_integer()
}.

-export_type([mode/0, publish_opts/0]).

%% @doc Publish `Payload' on `Topic' using this service's own mesh
%% handle and realm. Default mode is `async_silent': starts the publish
%% and returns `ok' immediately without waiting for it to land, matching
%% how most real call sites in the fleet already behave — nobody blocks
%% on a fact publish today.
-spec publish(binary(), term()) -> ok | {error, term()}.
publish(Topic, Payload) ->
    publish(Topic, Payload, #{}).

%% @doc As `publish/2', with `Opts':
%%
%%   `realm'   — publish on a realm other than this service's own.
%%               A real, deployed need (see `hecate-dronex',
%%               `hecate-robo-rumbler', `hecate-biotope'/`hecate-society'
%%               in the survey): a fleet realm for mcl_om's own
%%               plumbing and a separate business/public realm for the
%%               facts themselves, off the same pool.
%%   `mode'    — `async_silent' (default): fire-and-forget, outcome
%%                 discarded.
%%               `async_log': fire-and-forget, but a failed publish is
%%                 logged (`hecate-victron'/`hecate-warden'/`hecate-sentinel'
%%                 all re-added this after an earlier silent-swallow
%%                 version ate refused frames unnoticed).
%%               `sync': blocks until the publish resolves and returns
%%                 its outcome (`hecate-biotope'/`hecate-society'/
%%                 `hecate-mpong-bot' all already block their own
%%                 caller today; this just moves that blocking here).
%%   `timeout' — `sync' mode only. Milliseconds to wait for the
%%               outcome before returning `{error, timeout}'. Default
%%               5000.
-spec publish(binary(), term(), publish_opts()) -> ok | {error, term()}.
publish(Topic, Payload, Opts)
  when is_binary(Topic), is_map(Opts) ->
    do_publish(mcl_om:mesh_handles(), Topic, Payload, Opts).

do_publish({ok, Pool, DefaultRealm}, Topic, Payload, Opts) ->
    Realm = resolve_realm(Opts, DefaultRealm),
    Mode  = resolve_mode(Opts),
    publish_with_mode(Mode, Pool, Realm, Topic, Payload, Opts);
do_publish({error, mesh_unavailable} = Err, _Topic, _Payload, _Opts) ->
    Err.

%% @doc The realm a publish actually uses: `Opts''s `realm' override
%% when given, otherwise this service's own default realm.
-spec resolve_realm(publish_opts(), binary()) -> binary().
resolve_realm(Opts, DefaultRealm) ->
    maps:get(realm, Opts, DefaultRealm).

%% @doc The outcome-handling mode a publish actually uses: `Opts''s
%% `mode', defaulting to `async_silent'.
-spec resolve_mode(publish_opts()) -> mode().
resolve_mode(Opts) ->
    maps:get(mode, Opts, async_silent).

publish_with_mode(sync, Pool, Realm, Topic, Payload, Opts) ->
    sync_publish(Pool, Realm, Topic, Payload, Opts);
publish_with_mode(Mode, Pool, Realm, Topic, Payload, _Opts) ->
    started(macula_publisher:start_link(?MODULE, Pool, Realm, Topic, Payload,
                                        {Mode, Topic})).

started({ok, _Pid}) -> ok;
started({error, _Reason} = Err) -> Err.

sync_publish(Pool, Realm, Topic, Payload, Opts) ->
    Ref     = make_ref(),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_SYNC_TIMEOUT_MS),
    reply_or_timeout(
      macula_publisher:start_link(?MODULE, Pool, Realm, Topic, Payload,
                                  {sync, self(), Ref}),
      Ref, Timeout).

reply_or_timeout({ok, _Pid}, Ref, Timeout) ->
    receive
        {?MODULE, Ref, Result} -> Result
    after Timeout ->
        {error, timeout}
    end;
reply_or_timeout({error, _Reason} = Err, _Ref, _Timeout) ->
    Err.

%% @doc Publish `Payload' on every topic in `Topics'. Convenience for a
%% one-fact-fans-to-N-topics service (`hecate-news' publishes to a
%% firehose topic plus one sub-topic per non-empty axis). Every topic
%% is attempted regardless of an earlier one's outcome; returns `ok'
%% only if every publish returned `ok'.
-spec publish_many([binary()], term()) -> ok | {error, term()}.
publish_many(Topics, Payload) ->
    publish_many(Topics, Payload, #{}).

-spec publish_many([binary()], term(), publish_opts()) -> ok | {error, term()}.
publish_many(Topics, Payload, Opts)
  when is_list(Topics), is_map(Opts) ->
    fold_publish(Topics, Payload, Opts, ok).

fold_publish([], _Payload, _Opts, Acc) ->
    Acc;
fold_publish([Topic | Rest], Payload, Opts, Acc) ->
    fold_publish(Rest, Payload, Opts, combine(Acc, publish(Topic, Payload, Opts))).

combine(ok, Result) -> Result;
combine({error, _} = Err, _Result) -> Err.

%% @doc Start a supervised `macula_publisher' with a caller-supplied
%% callback `Module', using this service's own mesh handle and realm —
%% the escape hatch for outcome handling `publish/2,3''s three fixed
%% modes don't cover (e.g. retry-with-backoff on failure, fully
%% decoupled from any caller waiting synchronously — a real need that
%% just hasn't shown up in a surveyed repo yet, unlike the three modes,
%% which were each derived from one). Resolves
%% `mcl_om:mesh_handles/0' the same way `publish/2,3' does, so
%% reaching for this instead of `publish/2,3' doesn't mean duplicating
%% that boilerplate — that resolution is the one thing worth getting
%% from `mcl_om_pubsub' either way. `Module' must implement
%% `-behaviour(macula_publisher)' itself; `mcl_om_pubsub' has no
%% say over what its `handle_published/2' does.
%%
%% `Args' is passed to `Module:init/1', same as
%% `macula_publisher:start_link/6' itself; default `undefined' when
%% omitted. `Opts' accepts `realm' only (see `publish/3') — `mode' and
%% `timeout' don't apply, since the caller's own `Module' owns the
%% outcome entirely.
-spec start_publisher(module(), binary(), term()) ->
    {ok, pid()} | {error, term()}.
start_publisher(Module, Topic, Payload) ->
    start_publisher(Module, Topic, Payload, undefined, #{}).

%% @doc As `start_publisher/3', with `Args' passed to `Module:init/1'.
-spec start_publisher(module(), binary(), term(), term()) ->
    {ok, pid()} | {error, term()}.
start_publisher(Module, Topic, Payload, Args) ->
    start_publisher(Module, Topic, Payload, Args, #{}).

%% @doc As `start_publisher/4', with `Opts' (`realm' only — see above).
-spec start_publisher(module(), binary(), term(), term(), #{realm => binary()}) ->
    {ok, pid()} | {error, term()}.
start_publisher(Module, Topic, Payload, Args, Opts)
  when is_atom(Module), is_binary(Topic), is_map(Opts) ->
    do_start_publisher(mcl_om:mesh_handles(), Module, Topic, Payload,
                       Args, Opts).

do_start_publisher({ok, Pool, DefaultRealm}, Module, Topic, Payload, Args, Opts) ->
    Realm = resolve_realm(Opts, DefaultRealm),
    macula_publisher:start_link(Module, Pool, Realm, Topic, Payload, Args);
do_start_publisher({error, mesh_unavailable} = Err, _Module, _Topic, _Payload,
                   _Args, _Opts) ->
    Err.

%% @doc Declare the desired subscription set: one supervised
%% `macula_subscriber' per `{Topic, HandlerMod, Args}' not already
%% running (`HandlerMod' implementing the `macula_subscriber'
%% behaviour); any running one no longer in the set is stopped. Safe to
%% call repeatedly whenever the desired set changes at runtime — e.g. a
%% `federation_inbox'-shaped service adding one topic per newly-
%% registered entity — diffs against what's currently running and
%% touches only the delta. Self-heals on a 30s reconcile tick
%% independent of any caller: a topic that couldn't start because the
%% mesh wasn't attached yet, or whose child exhausted its own restart
%% budget after a full pool replacement, is retried automatically. See
%% `mcl_om_pubsub_subscriptions' for the mechanism.
-spec ensure_subscriptions([{binary(), module(), term()}]) -> ok.
ensure_subscriptions(Desired) ->
    mcl_om_pubsub_subscriptions:ensure(Desired).

%%%===================================================================
%%% macula_publisher callbacks
%%%===================================================================

init({async_silent, Topic}) -> {ok, {async_silent, Topic}};
init({async_log, Topic})    -> {ok, {async_log, Topic}};
init({sync, Pid, Ref})      -> {ok, {sync, Pid, Ref}}.

handle_published(_Result, {async_silent, _Topic} = State) ->
    {stop, normal, State};
handle_published(ok, {async_log, _Topic} = State) ->
    {stop, normal, State};
handle_published({error, Reason}, {async_log, Topic} = State) ->
    logger:warning("mcl_om_pubsub: publish to ~s failed: ~p",
                   [Topic, Reason]),
    {stop, normal, State};
handle_published(Result, {sync, Pid, Ref} = State) ->
    Pid ! {?MODULE, Ref, Result},
    {stop, normal, State}.
