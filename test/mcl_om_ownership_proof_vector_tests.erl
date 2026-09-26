%%% The ownership proof v2 cross-SDK vector, pinned on this side too.
%%%
%%% The files in test/vector/ownership_proof_v2 come from macula-go
%%% (ownershipproof/testdata/vector, macula-go#6), which emitted them with this
%%% module at mcl_om 0.32.0 (91e59d8). macula-go reproduces message.hex byte
%%% for byte and verifies signature.hex. This test holds mcl_om to the same
%%% bytes, so a change to the message format fails here as well as there.
-module(mcl_om_ownership_proof_vector_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PROCEDURE, <<"mcl-graph/learn_link">>).
-define(TIMESTAMP, 1790000000000).

the_message_is_the_pinned_bytes_test() ->
    Message = mcl_om_ownership_proof:message(vector("identity"), realm(), ?PROCEDURE, ?TIMESTAMP,
                                             nonce(), fields()),
    ?assertEqual(vector("message"), Message).

the_pinned_identity_derives_from_the_pinned_key_test() ->
    ?assertEqual(vector("identity"), macula_node_keys:node_id(vector("public_key"), profile())).

the_pinned_signature_verifies_over_the_pinned_message_test() ->
    ?assert(macula_node_keys:verify(vector("message"), vector("signature"), vector("public_key"),
                                    profile())).

%% The inputs of macula-go's scripts/interop/erlang_ownership_proof.escript
%% emit. A text key named caller is a signed field like any other: only the
%% station's atom caller is stripped.
fields() ->
    #{{text, <<"subject">>} => {text, <<"entity:alpha">>},
      {text, <<"predicate">>} => {text, <<"knows">>},
      {text, <<"object">>} => {text, <<"entity:beta">>},
      {text, <<"confidence">>} => 0.75,
      {text, <<"weight">>} => 3,
      {text, <<"offset">>} => -7,
      {text, <<"digest">>} => <<1, 2, 3>>,
      {text, <<"note">>} => null,
      {text, <<"tags">>} => [{text, <<"a">>}, {text, <<"b">>}],
      {text, <<"metadata">>} => #{{text, <<"source">>} => {text, <<"field-notes">>},
                                  {text, <<"page">>} => 12},
      {text, <<"caller">>} => {text, <<"a text key named caller is signed">>}}.

realm() -> crypto:hash(sha256, <<"io.macula">>).

nonce() -> list_to_binary(lists:seq(0, 15)).

vector(Name) ->
    {ok, Hex} = file:read_file(filename:join(vector_dir(), Name ++ ".hex")),
    binary:decode_hex(string:trim(Hex)).

%% The source file's own directory, so the vector is found wherever the test
%% beam was compiled to.
vector_dir() ->
    Source = proplists:get_value(source, ?MODULE:module_info(compile)),
    filename:join([filename:dirname(Source), "vector", "ownership_proof_v2"]).

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.
