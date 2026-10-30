%% @doc The helper that makes a capability test speak the wire's own shape
%% (mcl-om#31).
%%
%% What is pinned here is not the helper's convenience but its KILLING POWER:
%% a handler with mcl-chess 0.7.0's bug is a handler that reads
%% `maps:get(<<"key">>, Payload, Default)', and a test written through this
%% helper must fail on it. The bug's own service passed 206 tests that could not,
%% and then refused every real caller on the live mesh (mcl-chess#10).
-module(mcl_om_wire_test_tests).

-include_lib("eunit/include/eunit.hrl").

%% A node id is 32 raw bytes on the wire; the hex form is what a service stores.
-define(CALLER_RAW, crypto:hash(sha256, <<"wire-test caller">>)).
-define(CALLER_HEX, binary:encode_hex(?CALLER_RAW, lowercase)).
-define(GAME_ID, <<"game-01a158037b817682ab3c7490dc5588b7">>).

%%====================================================================
%% What the handler is handed
%%====================================================================

%% A text key arrives as `{text, Bin}', never as a bare `<<"bin">>', and the
%% verified caller arrives under the ATOM key. This is the whole reason a
%% handler that reads bare binary keys is unreachable.
the_handler_is_handed_the_wire_shape_test() ->
    Payload = mcl_om_wire_test:deliver(#{game_id => ?GAME_ID, ply => 3}, ?CALLER_RAW),
    ?assertMatch(#{{text, <<"game_id">>} := {text, ?GAME_ID}}, Payload),
    ?assertMatch(#{{text, <<"ply">>} := 3}, Payload),
    ?assertEqual(?CALLER_RAW, maps:get(caller, Payload)),
    ?assertEqual(error, maps:find(<<"game_id">>, Payload)),
    ?assertEqual(error, maps:find(<<"caller">>, Payload)).

%% A peer that names itself does not survive delivery: what a handler reads as
%% `caller' is the identity macula verified.
a_caller_sent_text_caller_is_dropped_test() ->
    Payload = mcl_om_wire_test:deliver(#{caller => <<"a peer that is lying">>}, ?CALLER_RAW),
    ?assertEqual(?CALLER_RAW, maps:get(caller, Payload)),
    ?assertEqual(error, maps:find({text, <<"caller">>}, Payload)).

%% A hex caller would pass a handler that never hexes the raw one, which is half
%% the mcl-chess#10 fault, so the helper refuses it instead of being kind.
a_hex_caller_is_refused_test() ->
    Hex = binary:encode_hex(?CALLER_RAW, lowercase),
    ?assertError({caller_must_be_a_raw_32_byte_node_id, Hex},
                 mcl_om_wire_test:deliver(#{game_id => ?GAME_ID}, Hex)).

%% The mesh carries 1/0; a boolean in a test request is a request no client
%% could ever send.
a_boolean_in_a_request_is_refused_test() ->
    ?assertError({wire_carries_no_booleans, true, use_1_or_0},
                 mcl_om_wire_test:deliver(#{running => true}, ?CALLER_RAW)).

%%====================================================================
%% What the client sees back
%%====================================================================

%% Text comes back as text, unwrapped, and numbers as numbers: a test asserts on
%% what the value means, not on the codec's own tuple.
the_client_view_is_unwrapped_test() ->
    View = mcl_om_wire_test:reply(#{<<"game_id">> => {text, ?GAME_ID},
                                    <<"ply">> => 4,
                                    <<"outcome">> => {text, <<"winner">>}}),
    ?assertEqual(#{<<"game_id">> => ?GAME_ID,
                   <<"ply">> => 4,
                   <<"outcome">> => <<"winner">>}, View).

%% The mirror hazard, pinned: a reply carrying the RAW node id as text is not
%% UTF-8, which macula refuses, so the caller would get `unknown_error'. The
%% helper raises here, in the test, instead of on the first live call.
a_reply_with_a_raw_node_id_as_text_is_refused_test() ->
    ?assertError({bad_reply, {unsupported_payload_type, invalid_text, [<<"winner">>]}},
                 mcl_om_wire_test:reply(#{<<"winner">> => {text, ?CALLER_RAW}})).

%% THE OTHER HALF OF THE SAME HAZARD, and the one that used to pass (mcl-om#32).
%% A plain binary in a reply is a CBOR BYTE string, so a client reads a blob
%% where the service meant a string, and `macula_frame:check_payload/1' accepts
%% it. Reading it back as the same `Bin' as `{text, Bin}' let a responder
%% regress a field to bytes and keep every test green, so the client view names
%% it for what the client got.
a_replys_byte_string_does_not_read_as_text_test() ->
    ?assertEqual(#{<<"game_id">> => {bytes, ?GAME_ID}},
                 mcl_om_wire_test:reply(#{<<"game_id">> => ?GAME_ID})),
    ?assertEqual(#{<<"game_id">> => ?GAME_ID},
                 mcl_om_wire_test:reply(#{<<"game_id">> => {text, ?GAME_ID}})),
    %% The assertion a capability test writes is the text one, and it does not
    %% hold for bytes: which is what makes it a test of the wire.
    ?assertNotEqual(mcl_om_wire_test:reply(#{<<"game_id">> => {text, ?GAME_ID}}),
                    mcl_om_wire_test:reply(#{<<"game_id">> => ?GAME_ID})).

%% A byte string nested in a list and in a map reads as bytes too, because a
%% client that got one there is just as unable to read it.
a_nested_byte_string_is_named_as_bytes_test() ->
    ?assertEqual(#{<<"moves">> => [{bytes, <<"e2e4">>}, <<"e7e5">>]},
                 mcl_om_wire_test:reply(#{<<"moves">> => [<<"e2e4">>, {text, <<"e7e5">>}]})).

%%====================================================================
%% A handler refusing, and the context it runs in
%%====================================================================

%% The behaviour's own refusal is answered rather than crashed on. macula puts
%% the reason's name on an ERROR frame and the client's call answers
%% `{error, Detail}', so the helper answers that. Before this, `call/3' matched
%% only `{reply, Reply, _}' and a refusing handler raised badmatch in the test.
a_handler_refusal_is_the_callers_error_test() ->
    ?assertEqual({error, <<"maintenance">>},
                 mcl_om_wire_test:call(refusing_handler, #{game_id => ?GAME_ID}, ?CALLER_RAW)).

%% A reason with no name to cross with writes no detail field, so the client
%% falls through to the generic error it builds for an unnamed code.
a_nameless_refusal_is_the_generic_error_test() ->
    ?assertEqual({error, {call_error, <<"handler_error">>, undefined}},
                 mcl_om_wire_test:call(refusing_handler, #{nameless => 1}, ?CALLER_RAW)).

%% macula runs a handler inside the request's caller context, so a payload with
%% no map to read a caller from still has one (`macula_response:caller/0').
%% A helper that ran the handler bare would fail every such handler in test.
a_handler_reading_caller_zero_sees_the_verified_caller_test() ->
    ?assertEqual(#{<<"caller">> => ?CALLER_HEX},
                 mcl_om_wire_test:call(caller_context_handler, #{game_id => ?GAME_ID}, ?CALLER_RAW)),
    %% and the identity does not outlive the call in the test process
    ?assertEqual(undefined, erlang:get('$macula_handler_caller')).

%% An element inside a list converts as a value, not as a bare element: a
%% tagged byte string nested in a list is the bytes it names.
a_tagged_byte_string_inside_a_list_stays_bytes_test() ->
    Payload = mcl_om_wire_test:deliver(#{chunks => [{bytes, <<1, 2, 3>>}]}, ?CALLER_RAW),
    ?assertEqual([<<1, 2, 3>>], maps:get({text, <<"chunks">>}, Payload)).

%%====================================================================
%% A `handler_authorizes' capability's own token and proofs
%%====================================================================

%% The link runs no gate for this policy; it hands the handler the request's
%% token and proofs under the ATOM keys, `<<>>' and `[]' when the request carried
%% none, and drops a payload's text-keyed pair of those names first (macula 18,
%% macula_station_link:with_call_token/3). A helper that delivered them only when
%% the caller sent some would pass a handler whose check trusts an absent key.
a_handler_authorizes_request_carries_the_call_token_test() ->
    Payload = mcl_om_wire_test:deliver(#{game_id => ?GAME_ID}, ?CALLER_RAW,
                                       #{ucan_token => <<"grant">>, proofs => [<<1, 2, 3>>]}),
    ?assertEqual(<<"grant">>, maps:get(ucan_token, Payload)),
    ?assertEqual([<<1, 2, 3>>], maps:get(proofs, Payload)),
    ?assertEqual(error, maps:find({text, <<"ucan_token">>}, Payload)).

%% Both keys are ALWAYS there for this policy, as the link writes them: a
%% request that carried nothing gets `<<>>' and `[]', never an absent key.
a_handler_authorizes_request_with_no_token_still_carries_both_keys_test() ->
    Payload = mcl_om_wire_test:deliver(#{game_id => ?GAME_ID}, ?CALLER_RAW, #{}),
    ?assertEqual(<<>>, maps:get(ucan_token, Payload)),
    ?assertEqual([], maps:get(proofs, Payload)).

%% A payload that names its own token does not survive delivery, for the same
%% reason a caller-sent `caller' does not: what the handler reads must be what
%% the request carried, not what the fields claim.
a_payload_sent_token_is_dropped_test() ->
    Payload = mcl_om_wire_test:deliver(#{ucan_token => <<"a claim">>, proofs => [<<"claimed">>]},
                                       ?CALLER_RAW, #{ucan_token => <<"grant">>}),
    ?assertEqual(<<"grant">>, maps:get(ucan_token, Payload)),
    ?assertEqual([], maps:get(proofs, Payload)),
    %% the claim is gone, not merely shadowed: a handler reading the text key
    %% must find nothing there rather than a value it would trust
    ?assertEqual(error, maps:find({text, <<"ucan_token">>}, Payload)),
    ?assertEqual(error, maps:find({text, <<"proofs">>}, Payload)).

%% Any OTHER policy is delivered without them, because that is what a station
%% does: a helper that merged them everywhere would test a shape no link sends.
another_policy_merges_no_call_token_test() ->
    Payload = mcl_om_wire_test:deliver(#{game_id => ?GAME_ID}, ?CALLER_RAW),
    ?assertEqual(error, maps:find(ucan_token, Payload)),
    ?assertEqual(error, maps:find(proofs, Payload)).

%% The killing power, for this policy: the handler's own check is the only gate,
%% so a helper that hands it no token refuses everybody. `call/3' is the helper
%% that did, and `call/4' is the one that reaches the admitted path.
a_handler_checking_the_token_is_refused_without_it_and_admitted_with_it_test() ->
    Request = #{game_id => ?GAME_ID},
    ?assertEqual(#{<<"admitted">> => <<"no">>, <<"proof_count">> => -1},
                 mcl_om_wire_test:call(token_checking_handler, Request, ?CALLER_RAW)),
    ?assertEqual(#{<<"admitted">> => <<"yes">>, <<"proof_count">> => 2},
                 mcl_om_wire_test:call(token_checking_handler, Request, ?CALLER_RAW,
                                       #{ucan_token => <<"the token the operator granted">>,
                                         proofs => [<<1>>, <<2>>]})).

%% macula refuses a non-binary `ucan_token' opt before it dials, so a test that
%% passed one would be describing a call no client can make.
a_non_binary_token_is_refused_test() ->
    ?assertError({ucan_token_must_be_bytes, 42},
                 mcl_om_wire_test:deliver(#{game_id => ?GAME_ID}, ?CALLER_RAW,
                                          #{ucan_token => 42})).

%%====================================================================
%% The killing power: mcl-chess 0.7.0's handler
%%====================================================================

%% The handler as mcl-chess 0.7.1 wrote it: keys read as bare binaries, which
%% the wire never delivers. Through the helper it refuses a well-formed request
%% exactly as the live service did; a test that asserted on the answer would fail
%% on this line, which is the point of the helper existing.
a_handler_reading_bare_binary_keys_is_refused_test() ->
    ?assertEqual(#{<<"error">> => <<"missing_required_fields">>},
                 mcl_om_wire_test:call(old_style_handler, #{game_id => ?GAME_ID}, ?CALLER_RAW)).

%% The same handler written against the wire, through the same helper, answers.
a_handler_reading_the_wire_and_its_caller_passes_test() ->
    View = mcl_om_wire_test:call(wire_style_handler,
                                 #{game_id => ?GAME_ID, move => <<"e2e4">>},
                                 ?CALLER_RAW),
    ?assertEqual(#{<<"game_id">> => ?GAME_ID,
                   <<"move">> => <<"e2e4">>,
                   <<"caller">> => ?CALLER_HEX}, View).
