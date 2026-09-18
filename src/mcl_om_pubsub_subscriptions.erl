%%% @doc Reconciles the desired subscription set against
%%% `mcl_om_pubsub_sup''s actual running children (piece D,
%%% `PLAN_MCL_OM_MESH_WRAPPERS.md').
%%%
%%% One supervised `macula_subscriber' per `{Topic, HandlerMod, Args}'
%%% not already running; any running one no longer desired is stopped.
%%% Same "declare it, reconcile on a timer" shape as
%%% `mcl_om_capabilities''s 30s republish -- and for the same
%%% reason: the desired set may be declared before the mesh is
%%% attached, so the tick also retries anything that couldn't start
%%% yet, and it's the backstop for the one scenario `let-it-crash'
%%% alone doesn't cover -- a full pool replacement (not just a link
%%% respawn) drops every subscription's `Pool' pid at once, and if the
%%% supervisor's own restart budget is exhausted before
%%% `mcl_om_identity' reconnects, nothing else would ever retry.
%%%
%%% Reconnect handling that is deliberately NOT here: no
%%% `macula_event_gone' listening, no resubscribe-on-DOWN. Confirmed
%%% live (`macula_link_respawn_replay_tests.erl') that an ordinary link
%%% respawn is invisible to a subscriber -- `macula_client_replay'
%%% already replays it one layer down. Building that in here would
%%% reintroduce the exact hand-rolled machinery this piece exists to
%%% make unnecessary.
-module(mcl_om_pubsub_subscriptions).
-behaviour(gen_server).

-export([start_link/0, ensure/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Pure helper — kept side-effect-free so the reconciliation decision
%% is unit-testable without a live mesh (same convention as
%% `mcl_om_capabilities.erl' / `mcl_om_pubsub.erl').
-export([diff/2]).

%% Re-reconcile this often: retries anything that couldn't start
%% (mesh not yet attached, or a supervised child that exhausted its
%% own restart budget after a full pool replacement).
-define(RECONCILE_INTERVAL_MS, 30_000).

-record(state, {
    desired = [] :: [{binary(), module(), term()}]
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Declare the desired subscription set. Safe to call repeatedly
%% whenever it changes at runtime -- e.g. a `federation_inbox'-shaped
%% service adding one topic per newly-registered entity -- diffs
%% against what is currently running and touches only the delta.
-spec ensure([{binary(), module(), term()}]) -> ok.
ensure(Desired) when is_list(Desired) ->
    gen_server:call(?MODULE, {ensure, Desired}).

init([]) ->
    {ok, arm_timer(#state{})}.

handle_call({ensure, Desired}, _From, S) ->
    reconcile(Desired),
    {reply, ok, S#state{desired = Desired}};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(reconcile_tick, #state{desired = Desired} = S) ->
    reconcile(Desired),
    {noreply, arm_timer(S)};
handle_info(_Other, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%% Internals

reconcile(Desired) ->
    reconcile_with(mcl_om:mesh_handles(), Desired).

reconcile_with({ok, Pool, Realm}, Desired) ->
    {ToStart, ToStop} = diff(Desired, current_topics()),
    _ = [stop_subscriber(Topic) || Topic <- ToStop],
    _ = [start_subscriber(Pool, Realm, Topic, Mod, Args)
         || {Topic, Mod, Args} <- ToStart],
    ok;
%% Missing pool / realm: cannot subscribe yet. No-op; the timer retries
%% once both are present.
reconcile_with({error, mesh_unavailable}, _Desired) ->
    ok.

%% @doc The delta between what's desired and what's currently running:
%% `{ToStart, ToStop}'. `ToStart' is the `{Topic, HandlerMod, Args}'
%% triples whose `Topic' has no running child; `ToStop' is the running
%% topics no longer in `Desired'.
-spec diff([{binary(), module(), term()}], [binary()]) ->
    {[{binary(), module(), term()}], [binary()]}.
diff(Desired, CurrentTopics) ->
    DesiredTopics = [Topic || {Topic, _Mod, _Args} <- Desired],
    ToStart = [Entry || {Topic, _Mod, _Args} = Entry <- Desired,
                        not lists:member(Topic, CurrentTopics)],
    ToStop = [Topic || Topic <- CurrentTopics,
                       not lists:member(Topic, DesiredTopics)],
    {ToStart, ToStop}.

current_topics() ->
    [Id || {Id, _Pid, worker, _Mods} <- supervisor:which_children(mcl_om_pubsub_sup)].

start_subscriber(Pool, Realm, Topic, Mod, Args) ->
    ChildSpec = #{
        id       => Topic,
        start    => {macula_subscriber, start_link, [Mod, Pool, Realm, Topic, Args]},
        restart  => transient,
        shutdown => 5_000,
        type     => worker,
        modules  => [Mod]
    },
    started(supervisor:start_child(mcl_om_pubsub_sup, ChildSpec)).

started({ok, _Pid})                     -> ok;
started({error, {already_started, _}})  -> ok;
started({error, _Reason})               -> ok.

stop_subscriber(Topic) ->
    _ = supervisor:terminate_child(mcl_om_pubsub_sup, Topic),
    _ = supervisor:delete_child(mcl_om_pubsub_sup, Topic),
    ok.

arm_timer(S) ->
    erlang:send_after(?RECONCILE_INTERVAL_MS, self(), reconcile_tick),
    S.
