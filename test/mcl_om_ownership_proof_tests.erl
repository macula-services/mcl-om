%%% Tests for mcl_om_ownership_proof -- pure crypto, zero mesh,
%%% runs in the default `rebar3 eunit' gate. Mirrors (deliberately)
%%% hecate-citizens' own citizen_ownership_proof_tests.erl and
%%% hecate-mail's mailbox_ownership_proof_tests.erl, the two call sites
%%% this module was extracted from -- the 11.x port of the same
%%% contract: the identity is a pq_hybrid node id, so the proof carries
%%% the node key's public half alongside the signature.
-module(mcl_om_ownership_proof_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PROC, <<"hecate_graph.learn_link">>).

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.

node_key() ->
    {ok, K} = macula_node_keys:generate(identity, profile(),
                                        #{puzzle_difficulty => 0}),
    K.

node_id(Key) ->
    {ok, Id} = macula_node_keys:node_id(Key),
    Id.

sign(NodeKey, Identity, Timestamp, Procedure) ->
    macula_node_keys:sign(mcl_om_ownership_proof:message(Identity, Timestamp, Procedure),
                          NodeKey).

fresh_proof(NodeKey, Identity, Procedure) ->
    Ts = erlang:system_time(millisecond),
    #{timestamp => Ts, signature => sign(NodeKey, Identity, Ts, Procedure),
      public => binary:encode_hex(macula_node_keys:public_key(NodeKey), lowercase)}.

accepts_a_genuine_fresh_proof_test() ->
    Key = node_key(),
    Identity = node_id(Key),
    ?assertEqual(ok, mcl_om_ownership_proof:verify(
        Identity, fresh_proof(Key, Identity, ?PROC), ?PROC)).

rejects_a_signature_from_a_different_key_test() ->
    Impostor = node_key(),
    Owner = node_key(),
    Identity = node_id(Owner),
    Proof = fresh_proof(Impostor, Identity, ?PROC),
    ?assertEqual({error, bad_signature}, mcl_om_ownership_proof:verify(Identity, Proof, ?PROC)).

%% A signature that verifies, but against a carried key whose node id is
%% NOT the asserted identity -- the identity must genuinely derive from
%% the key that signed.
rejects_a_public_key_that_derives_a_different_identity_test() ->
    Signer = node_key(),
    Other = node_key(),
    Identity = node_id(Other),
    Ts = erlang:system_time(millisecond),
    Proof = #{timestamp => Ts,
              signature => sign(Signer, Identity, Ts, ?PROC),
              public => binary:encode_hex(macula_node_keys:public_key(Signer), lowercase)},
    ?assertEqual({error, bad_signature}, mcl_om_ownership_proof:verify(Identity, Proof, ?PROC)).

rejects_a_stale_timestamp_test() ->
    Key = node_key(),
    Identity = node_id(Key),
    Ts = erlang:system_time(millisecond) - 120_000,
    Proof = #{timestamp => Ts, signature => sign(Key, Identity, Ts, ?PROC),
              public => binary:encode_hex(macula_node_keys:public_key(Key), lowercase)},
    ?assertEqual({error, stale_proof}, mcl_om_ownership_proof:verify(Identity, Proof, ?PROC)).

rejects_a_missing_proof_test() ->
    Key = node_key(),
    Identity = node_id(Key),
    ?assertEqual({error, missing_proof}, mcl_om_ownership_proof:verify(Identity, #{}, ?PROC)).

%% A proof minted for one procedure must not verify against another --
%% the whole reason Procedure is part of the signed message.
rejects_a_proof_minted_for_a_different_procedure_test() ->
    Key = node_key(),
    Identity = node_id(Key),
    Proof = fresh_proof(Key, Identity, <<"some.other_procedure">>),
    ?assertEqual({error, bad_signature}, mcl_om_ownership_proof:verify(Identity, Proof, ?PROC)).

%% decode_identity/1 -- the wire hands hex TEXT, not raw bytes.

decodes_wire_hex_text_to_raw_bytes_test() ->
    Key = node_key(),
    Identity = node_id(Key),
    HexIdentity = binary:encode_hex(Identity, lowercase),
    ?assertEqual(Identity, mcl_om_ownership_proof:decode_identity(HexIdentity)).

%% macula's frame decoder converts a CBOR text VALUE to an atom
%% whenever the receiving VM already knows that atom, else leaves it
%% `{text, Bin}'-tagged (confirmed live -- see this module's own doc).

decode_identity_unwraps_a_text_tagged_hex_string_test() ->
    Key = node_key(),
    Identity = node_id(Key),
    HexIdentity = binary:encode_hex(Identity, lowercase),
    ?assertEqual(Identity, mcl_om_ownership_proof:decode_identity({text, HexIdentity})).

decode_text_unwraps_an_atom_value_test() ->
    ?assertEqual(<<"agent">>, mcl_om_ownership_proof:decode_text(agent)).

decode_text_unwraps_a_text_tagged_value_test() ->
    ?assertEqual(<<"hello">>, mcl_om_ownership_proof:decode_text({text, <<"hello">>})).

accepts_a_genuine_proof_shaped_exactly_like_the_wire_test() ->
    Key = node_key(),
    Identity = node_id(Key),
    Ts = erlang:system_time(millisecond),
    RawSig = sign(Key, Identity, Ts, ?PROC),
    WireIdentity = binary:encode_hex(Identity, lowercase),
    WireProof = #{timestamp => Ts,
                  signature => binary:encode_hex(RawSig, lowercase),
                  public => binary:encode_hex(macula_node_keys:public_key(Key), lowercase)},
    DecodedIdentity = mcl_om_ownership_proof:decode_identity(WireIdentity),
    ?assertEqual(ok, mcl_om_ownership_proof:verify(DecodedIdentity, WireProof, ?PROC)).
