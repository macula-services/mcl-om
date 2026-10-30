%%% @doc Reconciles the desired subscription set against
%%% `mcl_om_pubsub_sup''s actual running children (piece D,
%%% guides/mesh_native_services.md).
%%%
%%% One supervised `macula_subscriber' per declared subscription not already
%%% running as declared; any running one whose declaration no longer matches
%%% is stopped and started again. Same "declare it, reconcile on a timer"
%%% shape as `mcl_om_capabilities''s 30s republish -- and for the same
%%% reason: the desired set may be declared before the mesh is
%%% attached, so the tick also retries anything that couldn't start
%%% yet, and it's the backstop for the one scenario `let-it-crash'
%%% alone doesn't cover -- a full pool replacement (not just a link
%%% respawn) drops every subscription's `Pool' pid at once, and if the
%%% supervisor's own restart budget is exhausted before
%%% `mcl_om_identity' reconnects, nothing else would ever retry.
%%%
%%% A DECLARATION IS COMPARED WHOLE (mcl-om#41). The child's own start args
%%% carry everything the service asked for -- handler module, args and
%%% `sources' beside the topic -- so what is running is read back from
%%% `supervisor:get_childspec/2' rather than remembered here: changing one
%%% subscription's `sources' restarts that subscriber and no other, and a
%%% change that reached the running child by any other route is undone on
%%% the next tick rather than silently kept.
%%%
%%% A CHILD THAT STOPPED IS NOT A CHILD THAT IS RUNNING. The children are
%%% `transient': a subscription that ends normally (`macula_subscriber'
%%% passes a handler's `{stop, normal, State}' straight through) keeps its
%%% child spec and no process, and OTP never restarts it -- so the next tick
%%% deletes that spec and starts the subscriber again, `/health' never lists
%%% it as running, and `diff/2' is not fooled by a spec that still reads
%%% back as the declaration it was made from.
%%%
%%% A SUBSCRIPTION THAT CANNOT START IS NOT FORGOTTEN. The reason is logged
%%% once at `warning' and kept per topic, `/health' reports it, and the
%%% verdict is `degraded' until the same topic starts -- the facts that
%%% subscriber exists to react to are not arriving, which a service
%%% answering `ok' would otherwise hide. A declaration macula would refuse
%%% anyway (`sources' missing, say: macula 18 does not default it,
%%% macula#147) is refused by `validate/1' before anything is attempted, so
%%% the mistake is named at boot rather than discovered from a log.
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

-export([start_link/0, ensure/1, report/0, verdict/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Pure helpers — kept side-effect-free so the reconciliation decision, the
%% read-back of a running child's declaration, the declaration check and
%% the failure bookkeeping are unit-testable without a live mesh (same
%% convention as `mcl_om_capabilities.erl' / `mcl_om_pubsub.erl').
-export([diff/2, declaration/2, validate/1, start_failure/1,
         recorded/3, failures/1,
         children/0, running_topics/1, dead_specs/1, coming_back/1]).

%% The report /health reads, written by this server on every reconcile.
-define(REPORT, mcl_om_pubsub_subscriptions_report).

%% Re-reconcile this often: retries anything that couldn't start
%% (mesh not yet attached, or a supervised child that exhausted its
%% own restart budget after a full pool replacement).
-define(RECONCILE_INTERVAL_MS, 30_000).

%% What a running child was started with, read back from its child spec:
%% the whole declaration minus `Pool' and `Realm', which are the node's
%% current handles rather than the service's intent.
-type declaration() :: #{topic := binary(), module := module() | unknown,
                         args := term(), sources := term()}.

-type failure_report() :: [map()].

-record(state, {
    desired  = []  :: [mcl_om_service:subscription()],
    %% topic => the reason its last start attempt failed. Cleared when the
    %% same topic starts, and dropped when it leaves the desired set.
    failures = #{} :: #{binary() => term()}
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Declare the desired subscription set. Safe to call repeatedly
%% whenever it changes at runtime -- e.g. a `federation_inbox'-shaped
%% service adding one topic per newly-registered entity -- diffs
%% against what is currently running and touches only the delta.
%%
%% A declaration mcl_om cannot wire raises `{mcl_om_subscription_invalid,
%% #{topic := Topic, reason := Reason}}' in the CALLER, before anything is
%% stopped or started: a service whose `subscriptions/0' is wrong fails its
%% own boot naming the topic, instead of leaving a subscriber macula will
%% refuse to make.
-spec ensure([mcl_om_service:subscription()]) -> ok.
ensure(Desired) when is_list(Desired) ->
    ok = valid_or_raise(validate(Desired)),
    gen_server:call(?MODULE, {ensure, Desired}).

%% @doc What is declared, what is running and what last failed, for
%% `/health' and for an operator: `desired' and `running' are topics,
%% `failed' is one `#{topic, reason}' per topic whose last start attempt
%% failed, the reason printed so the body stays JSON-encodable.
%%
%% READ LOCK-FREE, never through this server (`mcl_om_capabilities`'s
%% grant and liveness tables are read the same way): a /health request must
%% not queue behind a reconcile that is subscribing, and subscribing is
%% network I/O. The report is written once per reconcile, which is the only
%% thing that can change it.
%%
%% Never raises: before boot, or in a test that started only part of the
%% tree, the table does not exist and the answer is an empty report.
-spec report() -> #{desired := [binary()], running := [binary()],
                    failed := failure_report()}.
report() ->
    try ets:lookup(?REPORT, report) of
        [{report, Report}] -> Report;
        []                 -> empty_report()
    catch error:badarg -> empty_report()
    end.

empty_report() ->
    #{desired => [], running => [], failed => []}.

%% @doc The verdict a report contributes to `/health': `ok' while nothing
%% is failing, `{degraded, #{subscriptions => Failed}}' otherwise.
-spec verdict(map()) -> ok | {degraded, #{subscriptions := failure_report()}}.
verdict(#{failed := []}) ->
    ok;
verdict(#{failed := Failed}) ->
    {degraded, #{subscriptions => Failed}}.

init([]) ->
    %% `public': /health reads it from another process, the way it reads
    %% the provider-grant and advertise-liveness tables.
    ?REPORT = ets:new(?REPORT, [set, public, named_table, {read_concurrency, true}]),
    publish_report([], #{}),
    {ok, arm_timer(#state{})}.

handle_call({ensure, Desired}, _From, S) ->
    Failures = reconcile(Desired, S#state.failures),
    publish_report(Desired, Failures),
    {reply, ok, S#state{desired = Desired, failures = Failures}};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(reconcile_tick, #state{desired = Desired, failures = Failures} = S) ->
    NewFailures = reconcile(Desired, Failures),
    publish_report(Desired, NewFailures),
    {noreply, arm_timer(S#state{failures = NewFailures})};
handle_info(_Other, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%% Internals — reconciliation

reconcile(Desired, Failures) ->
    prune(reconcile_with(mcl_om:mesh_handles(), Desired, Failures), Desired).

reconcile_with({ok, Pool, Realm}, Desired, Failures) ->
    Children = children(),
    {ToStart, ToStop} = diff(Desired, current_declarations(Children)),
    %% `dead_specs' as well as `ToStop': a `transient' child that stopped
    %% NORMALLY leaves its spec behind with no process (OTP deletes no such
    %% spec and never restarts it), and `supervisor:start_child/2' answers
    %% `{error, already_present}' against a spec that is still there. Left
    %% alone, that topic is never subscribed again and `start_child' keeps
    %% refusing it -- so the spec goes, and the start below makes a new one.
    _ = [stop_subscriber(Topic) || Topic <- ToStop ++ dead_specs(Children)],
    lists:foldl(fun(Sub, F) -> start_subscriber(Pool, Realm, Sub, F) end,
                Failures, ToStart);
%% Missing pool / realm: cannot subscribe yet. No-op; the timer retries once
%% both are present. What failed while the mesh WAS up stays in the report
%% until that topic starts, so a mesh that goes away does not erase the last
%% thing that went wrong.
reconcile_with({error, mesh_unavailable}, _Desired, Failures) ->
    Failures.

%% A topic that left the desired set takes its failure with it: the service
%% no longer asks for those facts, so its last refusal is not a reason to
%% degrade the node.
prune(Failures, Desired) ->
    maps:with([Topic || #{topic := Topic} <- Desired], Failures).

%% @doc The delta between what's desired and what's running, compared
%% declaration by declaration: `{ToStart, ToStop}'. `ToStart' is every
%% desired subscription a running child does not already match (a missing
%% topic, or one whose module, args or sources changed); `ToStop' is every
%% running declaration no desired one matches -- which is exactly the set
%% that changed or is no longer wanted.
%%
%% A declaration that changed appears in both lists, and the reconcile stops
%% before it starts, so the child id is free by the time it is started
%% again.
-spec diff([mcl_om_service:subscription()], [declaration()]) ->
    {[mcl_om_service:subscription()], [binary()]}.
diff(Desired, Current) ->
    ToStart = [Sub || Sub <- Desired, not matches(Sub, Current)],
    ToStop  = [Topic || #{topic := Topic} = Decl <- Current,
                        not matches(Decl, Desired)],
    {ToStart, ToStop}.

matches(Declaration, Declarations) ->
    lists:any(fun(Other) -> same_declaration(Declaration, Other) end, Declarations).

%% Same topic, same handler, same args, same sources. The sources compare in
%% the form the SDK takes them (`{open, Reason}' is macula's `open'): the
%% reason is the service's written documentation of an opt-out, not
%% something a running subscriber can differ on. `args' compares through
%% `args/1', so a declaration that leaves it out and the `[]' the child was
%% actually started with are the same declaration, not a restart every tick.
same_declaration(#{topic := Topic} = A, #{topic := Topic} = B) ->
    maps:get(module, A, undefined) =:= maps:get(module, B, undefined)
        andalso args(A) =:= args(B)
        andalso wire_sources(maps:get(sources, A, undefined))
                =:= wire_sources(maps:get(sources, B, undefined));
same_declaration(_A, _B) ->
    false.

%% @doc The `sources' option macula takes, from a declaration's own form:
%% `{open, Reason}' is the opt-out plus the reason mcl_om requires be
%% written; every other form (`members', `{org, _}', `{nodes, _}') is the
%% SDK's value already.
-spec wire_sources(term()) -> term().
wire_sources({open, _Reason}) -> open;
wire_sources(Sources)         -> Sources.

%% @doc The subscription supervisor's children, as `{Topic, Pid}': `Pid' is
%% a pid while the child runs, `restarting' while the supervisor is bringing
%% it back, and `undefined' when only its spec is left. That third state is
%% the one worth knowing about: a `transient' child that stops NORMALLY --
%% a handler answering `{stop, normal, State}' to an event, say -- is left
%% with its spec and no process, and is never restarted.
-spec children() -> [{binary(), pid() | restarting | undefined}].
children() ->
    [{Id, Pid} || {Id, Pid, worker, _Mods} <- supervisor:which_children(mcl_om_pubsub_sup)].

%% @doc The topics with a process behind them. A spec with no process is not
%% running, whatever it declares.
-spec running_topics([{binary(), term()}]) -> [binary()].
running_topics(Children) ->
    [Id || {Id, Pid} <- Children, is_pid(Pid)].

%% @doc The topics whose child is gone and whose spec is still there: not
%% running, and not restartable in place.
-spec dead_specs([{binary(), term()}]) -> [binary()].
dead_specs(Children) ->
    [Id || {Id, Pid} <- Children, Pid =:= undefined].

%% @doc The topics the supervisor is restarting right now. Neither running
%% nor dead: the next tick sees how it ended.
-spec coming_back([{binary(), term()}]) -> [binary()].
coming_back(Children) ->
    [Id || {Id, Pid} <- Children, Pid =:= restarting].

%% What is running, plus what the supervisor is bringing back, as the
%% declarations they were started with: a `restarting' child is not
%% restarted AGAIN from here (its spec is intact and the supervisor owns the
%% retry), and a dead one is not counted at all, so the diff asks for it.
current_declarations(Children) ->
    [declaration(Topic, childspec(Topic))
     || Topic <- running_topics(Children) ++ coming_back(Children)].

childspec(Topic) ->
    case supervisor:get_childspec(mcl_om_pubsub_sup, Topic) of
        {ok, Spec}    -> Spec;
        {error, _Why} -> undefined
    end.

%% @doc The declaration a running child was started with, read back from its
%% own child spec: `macula_subscriber:start_link/6''s start args are Module,
%% Pool, Realm, Topic, Args, Opts, and `sources' lives in Opts. Anything
%% else running under the subscription supervisor is reported as `unknown',
%% which matches no declaration -- so it is stopped rather than kept as a
%% subscriber nothing asked for.
-spec declaration(binary(), term()) -> declaration().
declaration(Topic,
            #{start := {macula_subscriber, start_link,
                        [Mod, _Pool, _Realm, Topic, Args, Opts]}})
  when is_map(Opts) ->
    #{topic => Topic, module => Mod, args => Args,
      sources => maps:get(sources, Opts, undefined)};
declaration(Topic, _ChildSpec) ->
    #{topic => Topic, module => unknown, args => undefined, sources => undefined}.

start_subscriber(Pool, Realm, Sub, Failures) ->
    #{topic := Topic, module := Module, sources := Sources} = Sub,
    ChildSpec = #{id       => Topic,
                  start    => {macula_subscriber, start_link,
                               [Module, Pool, Realm, Topic, args(Sub),
                                #{sources => wire_sources(Sources)}]},
                  restart  => transient,
                  shutdown => 5_000,
                  type     => worker,
                  modules  => [Module]},
    recorded(Topic, start_failure(supervisor:start_child(mcl_om_pubsub_sup, ChildSpec)),
             Failures).

args(Sub) ->
    maps:get(args, Sub, []).

%% @doc What `supervisor:start_child/2' answered, as a failure to record or
%% `none'. A start function's own refusal comes back wrapped
%% `{error, {Reason, Child}}' -- `Child' being the supervisor's own record,
%% whose tag is `child' -- a duplicate id as `{error, {already_started,
%% Pid}}', and a spec left behind by a child that stopped as
%% `{error, already_present}'.
-spec start_failure(term()) -> none | already_started | {error, term()}.
start_failure({ok, _Pid})                      -> none;
start_failure({ok, _Pid, _Extra})              -> none;
start_failure({error, {already_started, _Pid}}) -> already_started;
start_failure({error, {Reason, Child}}) when tuple_size(Child) > 1,
                                             element(1, Child) =:= child ->
    {error, Reason};
start_failure({error, Reason})                 -> {error, Reason}.

%% A successful start clears the topic's failure; a duplicate start says
%% nothing (the child is running, and the next tick reads its declaration);
%% a refusal is logged once and kept until that topic starts.
recorded(Topic, none, Failures) ->
    maps:remove(Topic, Failures);
recorded(_Topic, already_started, Failures) ->
    Failures;
recorded(Topic, {error, Reason}, Failures) ->
    logger:warning("mcl_om_pubsub: subscription to ~ts did not start: ~p",
                   [Topic, Reason]),
    Failures#{Topic => Reason}.

stop_subscriber(Topic) ->
    _ = supervisor:terminate_child(mcl_om_pubsub_sup, Topic),
    _ = supervisor:delete_child(mcl_om_pubsub_sup, Topic),
    ok.

%% @doc The `failed' list a report carries: one `#{topic, reason}' per topic
%% with a recorded failure, the reason printed so the body stays
%% JSON-encodable.
failures(Failures) ->
    [#{topic => Topic, reason => printed(Reason)}
     || {Topic, Reason} <- lists:sort(maps:to_list(Failures))].

build_report(Desired, Failures) ->
    #{desired => [Topic || #{topic := Topic} <- Desired],
      running => running_now(),
      failed  => failures(Failures)}.

publish_report(Desired, Failures) ->
    true = ets:insert(?REPORT, {report, build_report(Desired, Failures)}),
    ok.

%% A child that stopped normally is not running, so it is not listed: the
%% report says what IS subscribed, never what was once declared. The
%% reconciler answering while its supervisor is gone would otherwise take
%% /health down with it, so nothing is answered rather than an exit.
running_now() ->
    try running_topics(children()) catch exit:_ -> [] end.

%% The body is JSON and a reason is anything the SDK or the start raised, so
%% it is printed rather than encoded.
printed(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

arm_timer(S) ->
    erlang:send_after(?RECONCILE_INTERVAL_MS, self(), reconcile_tick),
    S.

%%% Internals — the declaration check

%% @doc Is this something mcl_om can wire? Pure, so a service's boot can ask
%% before it starts anything, and so every refusal is testable without a
%% mesh. Refused: `sources' missing; a source class macula does not know;
%% `open' with no written reason, or a reason that is not text; an empty or
%% malformed `{nodes, _}' / `{org, _}'; a non-binary topic; a non-atom
%% module; the same topic twice; and anything that is not a map at all.
-spec validate(term()) -> ok | {error, {mcl_om_subscription_invalid, map()}}.
validate(Desired) when is_list(Desired) ->
    validate_each(Desired, []);
validate(Other) ->
    invalid(none, {subscriptions, not_a_list, Other}).

validate_each([], _Seen) ->
    ok;
validate_each([#{topic := Topic} = Sub | Rest], Seen) when is_binary(Topic) ->
    validated(lists:member(Topic, Seen), Sub, Rest, Seen);
validate_each([#{topic := Topic} | _Rest], _Seen) ->
    invalid(none, {topic, not_a_binary, Topic});
validate_each([#{} | _Rest], _Seen) ->
    invalid(none, {topic, required});
validate_each([Other | _Rest], _Seen) ->
    invalid(none, {subscription, not_a_map, Other}).

validated(true, #{topic := Topic}, _Rest, _Seen) ->
    invalid(Topic, {topic, declared_twice});
validated(false, Sub, Rest, Seen) ->
    continued(validate_one(Sub), Sub, Rest, Seen).

continued(ok, #{topic := Topic}, Rest, Seen) ->
    validate_each(Rest, [Topic | Seen]);
continued({error, _} = Error, _Sub, _Rest, _Seen) ->
    Error.

validate_one(#{topic := Topic, module := Module} = Sub) when is_atom(Module) ->
    validate_sources(Topic, maps:get(sources, Sub, undefined));
validate_one(#{topic := Topic, module := Module}) ->
    invalid(Topic, {module, not_an_atom, Module});
validate_one(#{topic := Topic}) ->
    invalid(Topic, {module, required}).

validate_sources(_Topic, members) ->
    ok;
validate_sources(Topic, {org, Org}) ->
    validate_org(Topic, Org, is_binary(Org) andalso byte_size(Org) > 0);
validate_sources(Topic, {nodes, NodeIds}) ->
    validate_nodes(Topic, NodeIds);
validate_sources(Topic, {open, Reason}) ->
    validate_open_reason(Topic, Reason);
validate_sources(Topic, open) ->
    invalid(Topic, {sources, open_requires_a_written_reason});
validate_sources(Topic, undefined) ->
    invalid(Topic, {sources, required});
validate_sources(Topic, Other) ->
    invalid(Topic, {sources, unknown, Other}).

validate_org(_Topic, _Org, true) ->
    ok;
validate_org(Topic, Org, false) ->
    invalid(Topic, {sources, {org, invalid}, Org}).

%% `{open, Reason}': the reason is what makes an opt-out a decision somebody
%% made, so an empty one is refused exactly as a missing one is.
validate_open_reason(_Topic, Reason) when is_binary(Reason), byte_size(Reason) > 0 ->
    ok;
validate_open_reason(Topic, Reason) when is_binary(Reason) ->
    invalid(Topic, {sources, open_reason_is_empty});
validate_open_reason(Topic, Reason) ->
    invalid(Topic, {sources, {open_reason, not_a_binary}, Reason}).

%% Walked by pattern rather than `lists:all/2': an improper list raises there,
%% and this runs inside a service's boot.
validate_nodes(Topic, []) ->
    invalid(Topic, {sources, {nodes, empty}});
validate_nodes(Topic, [_ | _] = NodeIds) ->
    validate_node_ids(Topic, NodeIds);
validate_nodes(Topic, Other) ->
    invalid(Topic, {sources, {nodes, not_a_list}, Other}).

validate_node_ids(_Topic, []) ->
    ok;
validate_node_ids(Topic, [Id | Rest]) when is_binary(Id), byte_size(Id) =:= 32 ->
    validate_node_ids(Topic, Rest);
validate_node_ids(Topic, [Id | _Rest]) ->
    invalid(Topic, {sources, {nodes, not_node_ids}, Id});
validate_node_ids(Topic, _Improper) ->
    invalid(Topic, {sources, {nodes, not_a_list}}).

invalid(Topic, Reason) ->
    {error, {mcl_om_subscription_invalid, #{topic => Topic, reason => Reason}}}.

valid_or_raise(ok) ->
    ok;
valid_or_raise({error, Reason}) ->
    error(Reason).
