%%% @doc Tests for the pipeline itself (mcl-om#13): stage order, denials,
%%% pass-through to the wrapped handler, and the advertise-time wrapper.
%%% This module doubles as the wrapped handler (a `macula_response'
%%% implementation), the way mcl_om_capabilities_tests doubles as a
%%% placeholder handler.
-module(mcl_om_guard_pipeline_tests).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

-include_lib("eunit/include/eunit.hrl").

%% ---- the wrapped-handler half of this module ----

init(Args) -> {ok, Args}.

handle_request(_Payload, error_mode) -> {error, inner_failure, error_mode};
handle_request(Payload, State) -> {reply, {echoed, Payload}, State}.

%% ---- the tests ----

pipeline_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Pid) ->
        [
            fun wrapper_passes_streamers_and_guard_none_through_untouched/0,
            fun wrapper_names_the_pipeline_and_rejects_a_bad_spec/0,
            fun a_small_payload_reaches_the_wrapped_handler/0,
            fun an_oversized_payload_is_denied_before_the_handler/0,
            fun a_caller_over_its_budget_is_denied/0,
            fun a_handler_error_passes_through_unchanged/0
        ]
    end}.

setup() ->
    mcl_om_guard_limits:clear(),
    ok = mcl_om_guard_limits:declare(<<"t/proc">>,
        #{max_payload_external_size => 4096, per_caller_max => 2, global_max => 100}),
    {ok, Pid} = mcl_om_guard:start_link(),
    Pid.

teardown(Pid) ->
    Ref = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok end,
    mcl_om_guard_limits:clear().

init_pipeline(ModArgs) ->
    mcl_om_guard_pipeline:init({<<"t/proc">>, [mcl_om_guard_size, mcl_om_guard_rate],
                                {?MODULE, ModArgs}}).

wrapper_passes_streamers_and_guard_none_through_untouched() ->
    Base = #{name => <<"echo">>, version => 1, handler => {?MODULE, []}},
    ?assertEqual({?MODULE, []},
                 mcl_om_guard_pipeline:wrapper(<<"t/echo">>, Base#{guard => none}, {?MODULE, []})),
    ?assertEqual({?MODULE, []},
                 mcl_om_guard_pipeline:wrapper(<<"t/echo">>, Base#{kind => streamer}, {?MODULE, []})).

wrapper_names_the_pipeline_and_rejects_a_bad_spec() ->
    Base = #{name => <<"echo">>, version => 1, handler => {?MODULE, []}},
    ?assertMatch({mcl_om_guard_pipeline, {<<"t/echo">>, _, _}},
                 mcl_om_guard_pipeline:wrapper(<<"t/echo">>, Base, {?MODULE, []})),
    ?assertError({mcl_om_guard_bad_spec, <<"t/echo">>, bogus},
                 mcl_om_guard_pipeline:wrapper(<<"t/echo">>, Base#{guard => bogus},
                                               {?MODULE, []})).

a_small_payload_reaches_the_wrapped_handler() ->
    {ok, State} = init_pipeline(wrapped),
    {reply, {echoed, <<"hi">>}, _} =
        mcl_om_guard_pipeline:handle_request(<<"hi">>, State).

an_oversized_payload_is_denied_before_the_handler() ->
    {ok, State} = init_pipeline(wrapped),
    Oversized = binary:copy(<<"x">>, 5000),
    {error, payload_too_large, State} =
        mcl_om_guard_pipeline:handle_request(Oversized, State),
    ?assertEqual(1, maps:get(denied_size, mcl_om_guard:stats(<<"t/proc">>))).

a_caller_over_its_budget_is_denied() ->
    {ok, State0} = init_pipeline(wrapped),
    Payload = fun() -> #{<<"v">> => 1, caller => <<"c1">>} end,
    {reply, _, S1} = mcl_om_guard_pipeline:handle_request(Payload(), State0),
    {reply, _, S2} = mcl_om_guard_pipeline:handle_request(Payload(), S1),
    {error, rate_limited, S2} = mcl_om_guard_pipeline:handle_request(Payload(), S2).

a_handler_error_passes_through_unchanged() ->
    {ok, State} = init_pipeline(error_mode),
    {error, inner_failure, _} = mcl_om_guard_pipeline:handle_request(<<"x">>, State).
