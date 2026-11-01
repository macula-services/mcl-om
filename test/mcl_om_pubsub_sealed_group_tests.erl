%%% Tests for a subscription under a sealed group (mcl-om#49): the
%%% declaration check, the child spec that must never carry a token, the
%%% admission called at each subscribe attempt and not before, and the
%%% fail-closed path that leaves `/health' naming the topic and the reason.
%%%
%%% The token's whole security argument is that it exists in exactly one
%%% place -- the frame of the subscribe fun, for the length of one call --
%%% so most of these tests are leak tests: they look for the canary in
%%% every artefact mcl_om produces.
-module(mcl_om_pubsub_sealed_group_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GROUP, <<"io.example/mcl-tenders/tenders">>).
-define(TOPIC, <<"io.example/mcl-tenders/tenders/wire/tender_notice_reported_v1">>).
-define(ADMISSION, {sealed_group_admission, token, []}).

canary() -> sealed_group_admission:canary().

realm() -> <<0:256>>.

%% A declared subscription under the group, admitted by `Admission'.
sealed(Admission) ->
    #{topic => ?TOPIC, module => sealed_group_subscriber, sources => {org, <<"mcl-tenders">>},
      group => ?GROUP, admission => Admission}.

%% The same, with no group at all: the shape every service already used.
open_sub() ->
    #{topic => ?TOPIC, module => sealed_group_subscriber, sources => members}.

contains(Term, Needle) ->
    binary:match(term_to_binary(Term), Needle) =/= nomatch.

%%%===================================================================
%%% The child spec: the fun and the {M, F, A}, never a token.
%%%===================================================================

%% THE CENTRAL ONE. A token must not be in the child spec, and the way to
%% know a token is not there is to make the admission answer one and look
%% -- which also proves the admission was not called while the declaration
%% was being wired. It is called at subscribe time, per attempt, and at
%% no other time.
child_spec_carries_the_admission_and_never_its_token_test_() ->
    Spec = mcl_om_pubsub_subscriptions:child_spec(self(), realm(), sealed(?ADMISSION)),
    {ok, #{start := {macula_subscriber, start_link, [Module, _, _, ?TOPIC, _, Opts]}}} = {ok, Spec},
    [?_assertEqual(sealed_group_subscriber, Module),
     ?_assertEqual(?GROUP, maps:get(group, Opts)),
     ?_assertEqual(?ADMISSION, maps:get(admission, Opts)),
     ?_assertEqual(5, fun_arity(maps:get(subscribe, Opts))),
     ?_assertEqual({org, <<"mcl-tenders">>}, maps:get(sources, Opts)),
     ?_assertNot(contains(Spec, canary()))].

fun_arity(F) -> proplists:get_value(arity, erlang:fun_info(F)).

%% A subscription that declares neither is started exactly as before:
%% macula's own subscribe function, and no key mcl_om does not need.
plain_child_spec_has_no_subscribe_function_test() ->
    Spec = mcl_om_pubsub_subscriptions:child_spec(self(), realm(), open_sub()),
    {ok, #{start := {macula_subscriber, start_link, [_, _, _, _, _, Opts]}}} = {ok, Spec},
    ?assertNot(maps:is_key(subscribe, Opts)),
    ?assertNot(maps:is_key(admission, Opts)),
    ?assertEqual(members, maps:get(sources, Opts)).

%% What a RUNNING child reads back as carries the group and the admission,
%% which is what the reconcile compares. The fun is not read back: it is
%% opaque by design, and everything the comparison needs is beside it.
declaration_reads_the_group_and_the_admission_back_test() ->
    Spec = mcl_om_pubsub_subscriptions:child_spec(self(), realm(), sealed(?ADMISSION)),
    Decl = mcl_om_pubsub_subscriptions:declaration(?TOPIC, Spec),
    ?assertEqual(?GROUP, maps:get(group, Decl)),
    ?assertEqual(?ADMISSION, maps:get(admission, Decl)),
    ?assertNot(contains(Decl, canary())).

%%%===================================================================
%%% The options macula is finally given.
%%%===================================================================

subscribe_opts_name_the_group_and_the_token_and_drop_the_admission_test_() ->
    Opts = mcl_om_pubsub_subscriptions:subscribe_opts(
             ?GROUP, canary(),
             #{sources => {org, <<"mcl-tenders">>}, admission => ?ADMISSION, delivery => 7}),
    [?_assertEqual(?GROUP, maps:get(group, Opts)),
     ?_assertEqual(canary(), maps:get(ucan_token, Opts)),
     %% mcl_om's own key, not one macula knows.
     ?_assertNot(maps:is_key(admission, Opts)),
     %% The declaration's own options are still the delegate's.
     ?_assertEqual({org, <<"mcl-tenders">>}, maps:get(sources, Opts)),
     ?_assertEqual(7, maps:get(delivery, Opts))].

%%%===================================================================
%%% The admission, and what a failure may say.
%%%===================================================================

admission_token_answers_the_token_test() ->
    ?assertEqual({ok, canary()}, mcl_om_pubsub_subscriptions:admission_token(?ADMISSION)).

admission_token_passes_a_refusal_through_test() ->
    ?assertEqual({error, no_admission_token},
                 mcl_om_pubsub_subscriptions:admission_token(
                   {sealed_group_admission, missing, []})).

%% An admission that answers something that is not a token is refused by a
%% fixed atom: whatever it answered is not echoed, because an admission
%% that got this far may be answering with the token itself.
admission_token_refuses_a_non_token_without_echoing_it_test_() ->
    [?_assertEqual({error, not_a_token},
                   mcl_om_pubsub_subscriptions:admission_token(
                     {sealed_group_admission, not_a_token, []})),
     ?_assertEqual({error, not_an_admission},
                   mcl_om_pubsub_subscriptions:admission_token(
                     {sealed_group_admission, not_a_pair, []}))].

%% THE LEAK THAT WOULD MATTER: an admission reads the token, then crashes
%% holding it. The reason it is reported by is a fixed atom, so the token
%% reaches no reason, no report and no log line.
admission_token_reports_a_raise_without_its_reason_test_() ->
    Result = mcl_om_pubsub_subscriptions:admission_token(
               {sealed_group_admission, raising, []}),
    [?_assertEqual({error, admission_raised}, Result),
     ?_assertNot(contains(Result, canary()))].

%%%===================================================================
%%% Fail closed: a refused admission starts nothing.
%%%===================================================================

%% The subscriber is started for real, under the real supervisor, against
%% a pool that is never reached: the admission refuses first, which is the
%% fail-closed property. Nothing is left running, the topic is recorded
%% with the reason, and `/health' is fed from that record.
refused_admission_starts_no_subscriber_and_keeps_the_reason_test() ->
    with_pubsub_sup(
      fun() ->
              Failures = mcl_om_pubsub_subscriptions:start_subscriber(
                           self(), realm(),
                           sealed({sealed_group_admission, missing, []}), #{}),
              ?assertEqual(#{?TOPIC => {group, {admission, no_admission_token}}}, Failures),
              ?assertEqual([], mcl_om_pubsub_subscriptions:children()),
              ?assertEqual([#{topic => ?TOPIC,
                              reason => printed({group, {admission, no_admission_token}})}],
                           mcl_om_pubsub_subscriptions:failures(Failures))
      end).

%% The same, for the admission that raised while holding the token: the
%% recorded reason and the /health report it becomes carry neither.
raising_admission_leaves_the_token_in_no_reason_test() ->
    with_pubsub_sup(
      fun() ->
              Failures = mcl_om_pubsub_subscriptions:start_subscriber(
                           self(), realm(),
                           sealed({sealed_group_admission, raising, []}), #{}),
              ?assertEqual(#{?TOPIC => {group, {admission, admission_raised}}}, Failures),
              ?assertEqual([], mcl_om_pubsub_subscriptions:children()),
              ?assertNot(contains(Failures, canary())),
              ?assertNot(contains(mcl_om_pubsub_subscriptions:failures(Failures), canary()))
      end).

printed(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

with_pubsub_sup(Body) ->
    {ok, Sup} = mcl_om_pubsub_sup:start_link(),
    try Body()
    after
        unlink(Sup),
        exit(Sup, kill)
    end.

%%%===================================================================
%%% The declaration check.
%%%===================================================================

valid_sealed_declaration_is_accepted_test() ->
    ?assertEqual(ok, mcl_om_pubsub_subscriptions:validate([sealed(?ADMISSION)])).

valid_plain_declaration_is_accepted_test() ->
    ?assertEqual(ok, mcl_om_pubsub_subscriptions:validate([open_sub()])).

%% They are a pair. Half of one is a subscription nobody can open.
group_without_an_admission_is_refused_test() ->
    Sub = maps:remove(admission, sealed(?ADMISSION)),
    ?assertEqual(invalid(?TOPIC, {group, requires_an_admission}),
                 mcl_om_pubsub_subscriptions:validate([Sub])).

admission_without_a_group_is_refused_test() ->
    Sub = maps:remove(group, sealed(?ADMISSION)),
    ?assertEqual(invalid(?TOPIC, {admission, requires_a_group}),
                 mcl_om_pubsub_subscriptions:validate([Sub])).

%% The group must be a WHOLE SEGMENT of the topic: `<realm>/tenders' is a
%% group of `<realm>/tenders/wire/x', and never of `<realm>/tenders_archive'.
group_must_be_a_segment_of_the_topic_test_() ->
    [?_assertMatch(ok, validate_group(?GROUP, <<?GROUP/binary, "/wire/x">>)),
     ?_assertMatch(ok, validate_group(?GROUP, ?GROUP)),
     ?_assertMatch({error, {mcl_om_subscription_invalid, #{reason := {group, not_a_prefix_of_topic}}}},
                   validate_group(?GROUP, <<?GROUP/binary, "_archive/wire/x">>)),
     ?_assertMatch({error, {mcl_om_subscription_invalid, #{reason := {group, not_a_prefix_of_topic}}}},
                   validate_group(<<"other/group">>, <<?GROUP/binary, "/wire/x">>)),
     ?_assertMatch({error, {mcl_om_subscription_invalid, #{reason := {group, is_empty}}}},
                   validate_group(<<>>, ?TOPIC)),
     ?_assertMatch({error, {mcl_om_subscription_invalid, #{reason := {group, not_a_binary}}}},
                   validate_group(not_a_prefix, ?TOPIC))].

validate_group(Group, Topic) ->
    mcl_om_pubsub_subscriptions:validate(
      [#{topic => Topic, module => sealed_group_subscriber, sources => members,
         group => Group, admission => ?ADMISSION}]).

%% A function that is not there would be discovered at the first subscribe,
%% by a subscriber failing to start every 30s; it is a boot refusal instead.
admission_must_be_an_exported_mfa_test_() ->
    [?_assertMatch({error, {mcl_om_subscription_invalid, #{reason := {admission, not_an_mfa}}}},
                   validate_admission({sealed_group_admission, token})),
     ?_assertMatch({error, {mcl_om_subscription_invalid,
                            #{reason := {admission, {not_exported, sealed_group_admission,
                                                     no_such_function, 0}}}}},
                   validate_admission({sealed_group_admission, no_such_function, []})),
     ?_assertMatch({error, {mcl_om_subscription_invalid,
                            #{reason := {admission, {not_loadable, no_such_admission_module}}}}},
                   validate_admission({no_such_admission_module, token, []})),
     ?_assertMatch(ok, validate_admission(?ADMISSION))].

%% The declared term is never echoed: a declaration that put something else
%% here (a token, in the worst case) must not have it printed at boot.
admission_refusal_does_not_echo_the_term_test() ->
    Answer = mcl_om_pubsub_subscriptions:validate(
               [sealed(not_an_mfa)]),
    ?assertEqual(invalid(?TOPIC, {admission, not_an_mfa}), Answer),
    ?assertNot(contains(Answer, canary())).

validate_admission(Admission) ->
    mcl_om_pubsub_subscriptions:validate([sealed(Admission)]).

%% A declaration mcl_om cannot wire is a boot refusal, in the caller, the
%% same way a missing `sources' already is.
invalid_declaration_raises_in_the_caller_test() ->
    ?assertError({mcl_om_subscription_invalid, #{topic := ?TOPIC}},
                 mcl_om_pubsub_subscriptions:ensure([sealed({sealed_group_admission, no_such_function, []})])).

invalid(Topic, Reason) ->
    {error, {mcl_om_subscription_invalid, #{topic => Topic, reason => Reason}}}.

%%%===================================================================
%%% Changing the group, or the admission, restarts that subscriber -- and
%%% nothing else.
%%%===================================================================

changing_the_group_restarts_that_subscriber_test() ->
    Other = <<"io.example/mcl-tenders/tenders_archive">>,
    Desired = [(sealed(?ADMISSION))#{group := Other}],
    Current = [running(sealed(?ADMISSION))],
    ?assertEqual({Desired, [?TOPIC]}, mcl_om_pubsub_subscriptions:diff(Desired, Current)).

changing_the_admission_restarts_that_subscriber_test() ->
    Desired = [sealed({sealed_group_admission, missing, []})],
    Current = [running(sealed(?ADMISSION))],
    ?assertEqual({Desired, [?TOPIC]}, mcl_om_pubsub_subscriptions:diff(Desired, Current)).

%% The comparison is whole: a declaration with no group and one with a
%% group are different declarations, even on the same topic.
adding_a_group_restarts_that_subscriber_test() ->
    Desired = [sealed(?ADMISSION)],
    Current = [running(open_sub())],
    ?assertEqual({Desired, [?TOPIC]}, mcl_om_pubsub_subscriptions:diff(Desired, Current)).

sealed_declarations_that_match_are_not_restarted_test() ->
    ?assertEqual({[], []},
                 mcl_om_pubsub_subscriptions:diff([sealed(?ADMISSION)],
                                                  [running(sealed(?ADMISSION))])).

%% What a running sealed child reads back as: the declaration as the spec
%% holds it, group and admission included.
running(Sub) ->
    Spec = mcl_om_pubsub_subscriptions:child_spec(self(), realm(), Sub),
    mcl_om_pubsub_subscriptions:declaration(?TOPIC, Spec).
