%%% @doc Tests for mcl_om_ownership_proof -- pure crypto, zero mesh,
%%% runs in the default `rebar3 eunit' gate. Mirrors (deliberately)
%%% hecate-citizens' own citizen_ownership_proof_tests.erl and
%%% hecate-mail's mailbox_ownership_proof_tests.erl, the two call sites
%%% this module was extracted from -- if either drifts, this is the
%%% same contract they were both already trusted against.
-module(mcl_om_ownership_proof_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PROC, <<"hecate_graph.learn_link">>).

sign(KeyPair, Identity, Timestamp, Procedure) ->
    macula_identity:sign(mcl_om_ownership_proof:message(Identity, Timestamp, Procedure), KeyPair).

fresh_proof(KeyPair, Identity, Procedure) ->
    Ts = erlang:system_time(millisecond),
    #{timestamp => Ts, signature => sign(KeyPair, Identity, Ts, Procedure)}.

accepts_a_genuine_fresh_proof_test() ->
    KeyPair = macula_identity:generate(),
    Identity = macula_identity:public(KeyPair),
    ?assertEqual(ok, mcl_om_ownership_proof:verify(
        Identity, fresh_proof(KeyPair, Identity, ?PROC), ?PROC)).

rejects_a_signature_from_a_different_key_test() ->
    Impostor = macula_identity:generate(),
    Owner = macula_identity:generate(),
    Identity = macula_identity:public(Owner),
    Proof = fresh_proof(Impostor, Identity, ?PROC),
    ?assertEqual({error, bad_signature}, mcl_om_ownership_proof:verify(Identity, Proof, ?PROC)).

rejects_a_stale_timestamp_test() ->
    KeyPair = macula_identity:generate(),
    Identity = macula_identity:public(KeyPair),
    Ts = erlang:system_time(millisecond) - 120_000,
    Proof = #{timestamp => Ts, signature => sign(KeyPair, Identity, Ts, ?PROC)},
    ?assertEqual({error, stale_proof}, mcl_om_ownership_proof:verify(Identity, Proof, ?PROC)).

rejects_a_missing_proof_test() ->
    KeyPair = macula_identity:generate(),
    Identity = macula_identity:public(KeyPair),
    ?assertEqual({error, missing_proof}, mcl_om_ownership_proof:verify(Identity, #{}, ?PROC)).

%% A proof minted for one procedure must not verify against another --
%% the whole reason Procedure is part of the signed message.
rejects_a_proof_minted_for_a_different_procedure_test() ->
    KeyPair = macula_identity:generate(),
    Identity = macula_identity:public(KeyPair),
    Proof = fresh_proof(KeyPair, Identity, <<"some.other_procedure">>),
    ?assertEqual({error, bad_signature}, mcl_om_ownership_proof:verify(Identity, Proof, ?PROC)).

%% decode_identity/1 -- the wire hands hex TEXT, not raw bytes.

decodes_wire_hex_text_to_raw_bytes_test() ->
    KeyPair = macula_identity:generate(),
    Identity = macula_identity:public(KeyPair),
    HexIdentity = binary:encode_hex(Identity, lowercase),
    ?assertEqual(Identity, mcl_om_ownership_proof:decode_identity(HexIdentity)).

%% macula's frame decoder converts a CBOR text VALUE to an atom
%% whenever the receiving VM already knows that atom, else leaves it
%% `{text, Bin}'-tagged (confirmed live -- see this module's own doc).

decode_identity_unwraps_a_text_tagged_hex_string_test() ->
    KeyPair = macula_identity:generate(),
    Identity = macula_identity:public(KeyPair),
    HexIdentity = binary:encode_hex(Identity, lowercase),
    ?assertEqual(Identity, mcl_om_ownership_proof:decode_identity({text, HexIdentity})).

decode_text_unwraps_an_atom_value_test() ->
    ?assertEqual(<<"agent">>, mcl_om_ownership_proof:decode_text(agent)).

decode_text_unwraps_a_text_tagged_value_test() ->
    ?assertEqual(<<"hello">>, mcl_om_ownership_proof:decode_text({text, <<"hello">>})).

accepts_a_genuine_proof_shaped_exactly_like_the_wire_test() ->
    KeyPair = macula_identity:generate(),
    Identity = macula_identity:public(KeyPair),
    Ts = erlang:system_time(millisecond),
    RawSig = macula_identity:sign(mcl_om_ownership_proof:message(Identity, Ts, ?PROC), KeyPair),
    WireIdentity = binary:encode_hex(Identity, lowercase),
    WireProof = #{timestamp => Ts, signature => binary:encode_hex(RawSig, lowercase)},
    DecodedIdentity = mcl_om_ownership_proof:decode_identity(WireIdentity),
    ?assertEqual(ok, mcl_om_ownership_proof:verify(DecodedIdentity, WireProof, ?PROC)).
