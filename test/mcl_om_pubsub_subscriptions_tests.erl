%%% Unit tests for mcl_om_pubsub_subscriptions: the declaration check, the
%%% read-back of a running child's declaration, the reconciliation diff
%%% built on it, the start-failure bookkeeping, and the no-mesh degrade
%%% path. Everything that decides what is started or stopped is pure, so it
%%% is pinned here without a live mesh -- the same split
%%% `mcl_om_capabilities.erl' and `mcl_om_pubsub.erl' already use.
-module(mcl_om_pubsub_subscriptions_tests).
-include_lib("eunit/include/eunit.hrl").

-define(OPEN_REASON, <<"public telemetry anyone may publish">>).

%% A declared subscription, with the sources each test is about.
sub(Topic, Sources) -> #{topic => Topic, module => handler, sources => Sources}.
sub(Topic, Sources, Args) ->
    #{topic => Topic, module => handler, args => Args, sources => Sources}.

%% What a running child's declaration reads back as: the whole declaration
%% minus the pool and the realm, plus `args' as it was actually started.
running(Topic, Sources) ->
    #{topic => Topic, module => handler, args => [], sources => Sources}.
running(Topic, Sources, Args) ->
    #{topic => Topic, module => handler, args => Args, sources => Sources}.

%%%===================================================================
%%% diff/2 — pure, no mesh involved.
%%%===================================================================

diff_starts_missing_and_stops_extra_test() ->
    Desired = [sub(<<"a">>, members), sub(<<"b">>, members)],
    Current = [running(<<"b">>, members), running(<<"c">>, members)],
    {ToStart, ToStop} = mcl_om_pubsub_subscriptions:diff(Desired, Current),
    ?assertEqual([sub(<<"a">>, members)], ToStart),
    ?assertEqual([<<"c">>], ToStop).

diff_touches_nothing_when_declarations_match_test() ->
    Desired = [sub(<<"a">>, {org, <<"acme">>})],
    Current = [running(<<"a">>, {org, <<"acme">>})],
    ?assertEqual({[], []}, mcl_om_pubsub_subscriptions:diff(Desired, Current)).

diff_on_empty_desired_stops_everything_test() ->
    Current = [running(<<"a">>, members), running(<<"b">>, members)],
    ?assertEqual({[], [<<"a">>, <<"b">>]},
                 mcl_om_pubsub_subscriptions:diff([], Current)).

diff_on_empty_current_starts_everything_test() ->
    Desired = [sub(<<"a">>, members), sub(<<"b">>, members)],
    ?assertEqual({Desired, []},
                 mcl_om_pubsub_subscriptions:diff(Desired, [])).

%% THE POINT OF COMPARING THE WHOLE DECLARATION (mcl-om#41): narrowing who
%% may deliver to one topic restarts that topic and nothing else. Both
%% lists name it, and the reconcile stops before it starts.
diff_restarts_only_the_topic_whose_sources_changed_test() ->
    Desired = [sub(<<"a">>, members), sub(<<"b">>, {nodes, [<<0:256>>]}),
               sub(<<"c">>, members)],
    Current = [running(<<"a">>, members), running(<<"b">>, members),
               running(<<"c">>, members)],
    {ToStart, ToStop} = mcl_om_pubsub_subscriptions:diff(Desired, Current),
    ?assertEqual([sub(<<"b">>, {nodes, [<<0:256>>]})], ToStart),
    ?assertEqual([<<"b">>], ToStop).

diff_restarts_a_topic_whose_args_changed_test() ->
    Desired = [sub(<<"a">>, members, #{shard => 2}), sub(<<"b">>, members, [])],
    Current = [running(<<"a">>, members, #{shard => 1}), running(<<"b">>, members, [])],
    ?assertEqual({[sub(<<"a">>, members, #{shard => 2})], [<<"a">>]},
                 mcl_om_pubsub_subscriptions:diff(Desired, Current)).

%% A declaration that leaves `args' out and the `[]' the child was started
%% with are the same declaration: the reconcile must not restart that
%% subscriber every tick.
diff_does_not_restart_over_an_omitted_args_test() ->
    Desired = [#{topic => <<"a">>, module => handler, sources => members}],
    ?assertEqual({[], []}, mcl_om_pubsub_subscriptions:diff(Desired, [running(<<"a">>, members)])).

%% The written reason is the service's documentation of an opt-out, not
%% something the running subscriber differs on: both forms ride as macula's
%% `open', so changing the sentence does not restart anything.
diff_does_not_restart_over_a_reworded_open_reason_test() ->
    Desired = [sub(<<"a">>, {open, ?OPEN_REASON})],
    Current = [running(<<"a">>, open)],
    ?assertEqual({[], []}, mcl_om_pubsub_subscriptions:diff(Desired, Current)).

%% Anything running under the subscription supervisor that mcl_om did not
%% start is stopped rather than kept: it is a subscriber nothing asked for.
diff_stops_a_child_it_cannot_read_back_test() ->
    Unknown = mcl_om_pubsub_subscriptions:declaration(<<"x">>, undefined),
    ?assertEqual({[], [<<"x">>]},
                 mcl_om_pubsub_subscriptions:diff([], [Unknown])).

%%%===================================================================
%%% declaration/2 — what a running child was started with.
%%%===================================================================

declaration_reads_back_the_start_args_test() ->
    Spec = #{id => <<"svc.events">>,
             start => {macula_subscriber, start_link,
                       [my_handler, self(), <<0:256>>, <<"svc.events">>,
                        [], #{sources => {org, <<"acme">>}}]}},
    ?assertEqual(#{topic => <<"svc.events">>, module => my_handler,
                   args => [], sources => {org, <<"acme">>}},
                 mcl_om_pubsub_subscriptions:declaration(<<"svc.events">>, Spec)).

declaration_is_unknown_for_a_foreign_child_test() ->
    ?assertEqual(#{topic => <<"t">>, module => unknown, args => undefined,
                   sources => undefined},
                 mcl_om_pubsub_subscriptions:declaration(
                   <<"t">>, #{start => {some_other_module, start_link, []}})).

%%%===================================================================
%%% start_failure/1 — what supervisor:start_child/2 answered.
%%%===================================================================

start_failure_of_a_started_child_is_none_test() ->
    ?assertEqual(none, mcl_om_pubsub_subscriptions:start_failure({ok, self()})),
    ?assertEqual(none, mcl_om_pubsub_subscriptions:start_failure({ok, self(), extra})).

start_failure_of_a_duplicate_id_is_already_started_test() ->
    ?assertEqual(already_started,
                 mcl_om_pubsub_subscriptions:start_failure(
                   {error, {already_started, self()}})).

%% supervisor:start_child/2 wraps a start function's own refusal as
%% {error, {Reason, Child}}, `Child' being the supervisor's record. The
%% reason is what a service needs to see, not the record.
start_failure_unwraps_the_supervisor_record_test() ->
    Child = {child, undefined, <<"t">>, {m, f, []}, transient, 5000, worker, [m]},
    ?assertEqual({error, {sources, required}},
                 mcl_om_pubsub_subscriptions:start_failure(
                   {error, {{sources, required}, Child}})).

start_failure_passes_any_other_refusal_through_test() ->
    ?assertEqual({error, not_found},
                 mcl_om_pubsub_subscriptions:start_failure({error, not_found})).

%%%===================================================================
%%% The failure record: kept until that topic starts, then cleared.
%%%===================================================================

a_failure_is_recorded_and_then_cleared_by_a_later_start_test() ->
    F0 = #{},
    F1 = mcl_om_pubsub_subscriptions:recorded(<<"t">>, {error, {sources, required}}, F0),
    ?assertEqual(#{<<"t">> => {sources, required}}, F1),
    ?assertEqual([], mcl_om_pubsub_subscriptions:failures(F0)),
    ?assertEqual([#{topic => <<"t">>, reason => <<"{sources,required}">>}],
                 mcl_om_pubsub_subscriptions:failures(F1)),
    %% A later successful start of the SAME topic clears it.
    ?assertEqual(#{}, mcl_om_pubsub_subscriptions:recorded(<<"t">>, none, F1)).

%% A duplicate start says nothing: the child is running, and the next tick
%% reads its declaration.
a_duplicate_start_leaves_the_record_alone_test() ->
    F1 = #{<<"t">> => boom},
    ?assertEqual(F1, mcl_om_pubsub_subscriptions:recorded(<<"t">>, already_started, F1)).

%% A failing subscription is a degraded node, never an `ok' with a log line
%% nobody reads -- and the reason rides in the body as text, so jsx can
%% write it.
a_recorded_failure_degrades_the_verdict_test() ->
    Report = #{desired => [<<"t">>], running => [],
               failed => mcl_om_pubsub_subscriptions:failures(#{<<"t">> => {error, boom}})},
    Verdict = mcl_om_pubsub_subscriptions:verdict(Report),
    ?assertMatch({degraded, #{subscriptions := [#{topic := <<"t">>}]}}, Verdict),
    {degraded, #{subscriptions := Failed}} = Verdict,
    [Entry] = Failed,
    ?assert(is_binary(jsx:encode(maps:get(reason, Entry)))).

nothing_failing_is_ok_test() ->
    ?assertEqual(ok, mcl_om_pubsub_subscriptions:verdict(
                       #{desired => [<<"t">>], running => [<<"t">>], failed => []})).

%%%===================================================================
%%% validate/1 — the declaration check, and its refusals by name.
%%%===================================================================

validate_accepts_every_source_class_test() ->
    NodeId = <<0:256>>,
    ?assertEqual(ok, mcl_om_pubsub_subscriptions:validate(
                       [sub(<<"t">>, members),
                        sub(<<"u">>, {org, <<"acme">>}),
                        sub(<<"v">>, {nodes, [NodeId]}),
                        sub(<<"w">>, {open, ?OPEN_REASON})])).

validate_accepts_an_empty_list_test() ->
    ?assertEqual(ok, mcl_om_pubsub_subscriptions:validate([])).

validate_refuses_a_subscription_with_no_sources_test() ->
    ?assertEqual({error, {mcl_om_subscription_invalid,
                          #{topic => <<"t">>, reason => {sources, required}}}},
                 mcl_om_pubsub_subscriptions:validate(
                   [#{topic => <<"t">>, module => handler}])).

validate_refuses_an_unknown_source_class_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{topic := <<"t">>, reason := {sources, unknown, anybody}}}},
                 mcl_om_pubsub_subscriptions:validate([sub(<<"t">>, anybody)])).

%% macula's own `open' carries no reason, and an opt-out nobody wrote down
%% is exactly what mcl_om refuses.
validate_refuses_a_bare_open_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {sources, open_requires_a_written_reason}}}},
                 mcl_om_pubsub_subscriptions:validate([sub(<<"t">>, open)])).

validate_refuses_an_empty_open_reason_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {sources, open_reason_is_empty}}}},
                 mcl_om_pubsub_subscriptions:validate([sub(<<"t">>, {open, <<>>})])).

validate_refuses_a_non_binary_open_reason_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {sources, {open_reason, not_a_binary}, anyone}}}},
                 mcl_om_pubsub_subscriptions:validate([sub(<<"t">>, {open, anyone})])).

validate_refuses_an_empty_or_malformed_nodes_class_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {sources, {nodes, empty}}}}},
                 mcl_om_pubsub_subscriptions:validate([sub(<<"t">>, {nodes, []})])),
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {sources, {nodes, not_node_ids}, short}}}},
                 mcl_om_pubsub_subscriptions:validate([sub(<<"t">>, {nodes, [short]})])),
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {sources, {nodes, not_a_list}, nope}}}},
                 mcl_om_pubsub_subscriptions:validate([sub(<<"t">>, {nodes, nope})])).

%% An improper list has no `[]' to end on: walked by pattern so it comes out
%% as a named refusal instead of a raise inside a service's boot.
validate_refuses_an_improper_node_list_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {sources, {nodes, not_a_list}}}}},
                 mcl_om_pubsub_subscriptions:validate(
                   [sub(<<"t">>, {nodes, [<<0:256>> | <<1:256>>]})])).

validate_refuses_an_empty_org_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {sources, {org, invalid}, <<>>}}}},
                 mcl_om_pubsub_subscriptions:validate([sub(<<"t">>, {org, <<>>})])).

validate_refuses_a_non_binary_topic_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{topic := none, reason := {topic, not_a_binary, t}}}},
                 mcl_om_pubsub_subscriptions:validate(
                   [#{topic => t, module => handler, sources => members}])).

validate_refuses_a_missing_or_non_atom_module_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{topic := <<"t">>, reason := {module, required}}}},
                 mcl_om_pubsub_subscriptions:validate(
                   [#{topic => <<"t">>, sources => members}])),
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{topic := <<"t">>, reason := {module, not_an_atom, "h"}}}},
                 mcl_om_pubsub_subscriptions:validate(
                   [#{topic => <<"t">>, module => "h", sources => members}])).

%% Two declarations of one topic mean two children with one supervisor id.
validate_refuses_the_same_topic_twice_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{topic := <<"t">>, reason := {topic, declared_twice}}}},
                 mcl_om_pubsub_subscriptions:validate(
                   [sub(<<"t">>, members), sub(<<"t">>, members)])).

validate_refuses_things_that_are_not_subscriptions_at_all_test() ->
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {subscriptions, not_a_list, nope}}}},
                 mcl_om_pubsub_subscriptions:validate(nope)),
    ?assertMatch({error, {mcl_om_subscription_invalid,
                          #{reason := {subscription, not_a_map, nope}}}},
                 mcl_om_pubsub_subscriptions:validate([nope])).

%%%===================================================================
%%% Degrades without a mesh — same contract as every other piece.
%%%===================================================================

ensure_degrades_without_mesh_test_() ->
    {setup, fun start_servers/0, fun stop_servers/1,
     fun(_) ->
        [
         %% No pool/realm attached: reconcile no-ops instead of
         %% crashing, and does not start anything.
         ?_assertEqual(ok, mcl_om_pubsub:ensure_subscriptions(
                              [sub(<<"t">>, members)])),
         ?_assertEqual([], supervisor:which_children(mcl_om_pubsub_sup)),
         %% The declared set is still what the report says it is: the
         %% service asked for it, the mesh is just not there yet.
         ?_assertEqual(#{desired => [<<"t">>], running => [], failed => []},
                       mcl_om_pubsub_subscriptions:report())
        ]
     end}.

%% A declaration mcl_om cannot wire is refused in the CALLER, before the
%% reconciler is told anything (mcl-om#41): a service's boot fails naming
%% the topic instead of starting a subscriber macula would refuse.
ensure_refuses_a_bad_declaration_in_the_caller_test_() ->
    {setup, fun start_servers/0, fun stop_servers/1,
     fun(_) ->
        [
         ?_assertError({mcl_om_subscription_invalid,
                        #{topic := <<"t">>, reason := {sources, required}}},
                       mcl_om_pubsub:ensure_subscriptions(
                         [#{topic => <<"t">>, module => handler}])),
         %% Nothing was recorded: the refusal happened before the call.
         ?_assertEqual(#{desired => [], running => [], failed => []},
                       mcl_om_pubsub_subscriptions:report())
        ]
     end}.

start_servers() ->
    {ok, I} = mcl_om_identity:start_link(),
    {ok, Sup} = mcl_om_pubsub_sup:start_link(),
    {ok, Subs} = mcl_om_pubsub_subscriptions:start_link(),
    {I, Sup, Subs}.

stop_servers({I, Sup, Subs}) ->
    try gen_server:stop(Subs) catch _:_ -> ok end,
    stop_supervisor(Sup),
    try gen_server:stop(I) catch _:_ -> ok end,
    ok.

%% supervisor:stop/1 does not exist (unlike gen_server:stop/1) --
%% unlink first so the shutdown exit signal doesn't propagate back and
%% kill this (non-trapping) test process, then wait for confirmation.
stop_supervisor(Sup) ->
    unlink(Sup),
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5_000 -> ok
    end.
