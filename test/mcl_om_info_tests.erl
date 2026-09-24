%% @doc `<org>/info': every mcl_om service answers who it is, with no code of
%% its own.
%%
%% The realm's Providers desk counts a node online only while it has an
%% unexpired procedure advertisement signed by it. A service that only
%% publishes advertised nothing and always showed offline, even while working.
%% mcl_om now advertises `info' for every service, and answers it with public
%% facts only: no environment, paths, keys, grants or failure reasons.
-module(mcl_om_info_tests).

-include_lib("eunit/include/eunit.hrl").

facts() ->
    #{name => <<"mcl-probe">>, version => <<"0.1.0">>, description => <<"A probe">>,
      service_name => <<"mcl-probe">>, box => <<"beam00.lab">>, org => <<"mcl-probe">>,
      node_id => <<16#ab:256>>, macula_version => "12.2.0", mcl_om_version => "0.28.0",
      uptime_s => 42, status => ok,
      capabilities => [<<"mcl-probe/info">>, <<"mcl-probe/do">>]}.

the_capability_is_open_info_served_by_mcl_om_test() ->
    ?assertEqual(#{name => <<"info">>, version => 1, auth => open,
                   handler => {mcl_om_simple_handler, {mcl_om_info, answer}}},
                 mcl_om_info:capability()).

render_tags_text_and_keeps_numbers_test() ->
    Reply = mcl_om_info:render(facts()),
    ?assertEqual({text, <<"mcl-probe">>}, maps:get(name, Reply)),
    ?assertEqual({text, <<"0.1.0">>}, maps:get(version, Reply)),
    ?assertEqual({text, <<"beam00.lab">>}, maps:get(box, Reply)),
    ?assertEqual({text, binary:encode_hex(<<16#ab:256>>, lowercase)}, maps:get(node_id, Reply)),
    ?assertEqual({text, <<"12.2.0">>}, maps:get(macula_version, Reply)),
    ?assertEqual({text, <<"0.28.0">>}, maps:get(mcl_om_version, Reply)),
    ?assertEqual(42, maps:get(uptime_s, Reply)),
    ?assertEqual({text, <<"ok">>}, maps:get(status, Reply)),
    ?assertEqual([{text, <<"mcl-probe/info">>}, {text, <<"mcl-probe/do">>}],
                 maps:get(capabilities, Reply)).

%% Exactly these keys, so a later edit cannot slip an env value or a path in.
render_answers_public_facts_only_test() ->
    ?assertEqual(lists:sort([name, version, description, service_name, box, org, node_id,
                             macula_version, mcl_om_version, uptime_s, status, capabilities]),
                 lists:sort(maps:keys(mcl_om_info:render(facts())))).

%% The verdict /health last computed, reduced to its word: never the reason.
status_is_the_verdict_word_test_() ->
    [?_assertEqual({text, <<"ok">>}, status_of(ok)),
     ?_assertEqual({text, <<"degraded">>}, status_of({degraded, #{secret => x}})),
     ?_assertEqual({text, <<"down">>}, status_of({down, crashed})),
     ?_assertEqual({text, <<"unknown">>}, status_of({down, not_started})),
     ?_assertEqual({text, <<"unknown">>}, status_of({error, not_booted}))].

status_of(Verdict) ->
    maps:get(status, mcl_om_info:render((facts())#{status => Verdict})).

%% What a non-BEAM caller receives: text as text, not bytes; numbers as numbers.
%% Encoded and decoded by macula's own frame codec, the path a reply takes.
through_the_codec_every_string_is_text_test() ->
    {ok, Key} = macula_node_keys:generate(identity, profile()),
    Spec = #{request_id => crypto:strong_rand_bytes(16),
             realm => crypto:hash(sha256, <<"io.macula">>),
             procedure => <<"mcl-probe/info">>,
             target => macula_node_keys:key_id(Key),
             deadline => erlang:system_time(millisecond) + 60_000,
             payload => mcl_om_info:render(facts())},
    {ok, Decoded, <<>>} = macula_frame:decode(macula_frame:encode(macula_frame:call(Spec, Key))),
    {ok, #{payload := Delivered}} = macula_frame:verify_request(Decoded, profile()),
    Values = maps:values(Delivered),
    Bytes = [V || V <- lists:flatten(Values), is_binary(V)],
    ?assertEqual([], Bytes),
    ?assert(lists:member(42, Values)).

%% A service may not declare its own `info': the name is mcl_om's, on every node.
a_service_declaring_info_is_refused_test() ->
    ?assertError({mcl_om_capability_name_reserved, <<"info">>},
                 mcl_om_info:with_info([#{name => <<"do">>, version => 1},
                                        #{name => <<"info">>, version => 1}])).

with_info_adds_it_to_the_services_own_test() ->
    Caps = mcl_om_info:with_info([#{name => <<"do">>, version => 1}]),
    ?assertEqual([<<"info">>, <<"do">>], [N || #{name := N} <- Caps]).

profile() ->
    ok = application:set_env(macula, crypto_profile, pq_hybrid),
    {ok, Profile} = macula_crypto_profile:configured(),
    Profile.
