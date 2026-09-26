%%% Tests for mcl_om_ownership_proof v2 (plans/PLAN_OWNERSHIP_PROOF_V2.md,
%%% mcl-om#7). A proof binds the identity, the realm, the procedure, a nonce
%%% and every field of the payload as the handler receives it. The payloads
%%% here travel through macula's own frame codec and the station's caller
%%% merge, because a hand-written map proves only that hand-written maps
%%% verify (v1 shipped refusing every real caller that way).
-module(mcl_om_ownership_proof_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PROC, <<"mcl-graph/learn_link">>).
-define(OTHER_PROC, <<"mcl-graph/forget_link">>).

%%--------------------------------------------------------------------
%% Fixture: the replay cache mcl_om runs under its supervisor
%%--------------------------------------------------------------------

proof_test_() ->
    {setup, fun start_cache/0, fun stop_cache/1,
     [{"a genuine proof over a delivered payload verifies", fun genuine/0},
      {"a changed field fails", fun changed_field/0},
      {"an added field fails", fun added_field/0},
      {"a dropped field fails", fun dropped_field/0},
      {"text changed to bytes of the same content fails", fun text_to_bytes/0},
      {"an integer changed to a float fails", fun int_to_float/0},
      {"null changed to absent fails", fun null_to_absent/0},
      {"the same proof under another procedure fails", fun other_procedure/0},
      {"the same proof under another realm fails", fun other_realm/0},
      {"a proof with no version is unsupported", fun no_version/0},
      {"a v1-shaped proof is unsupported", fun v1_shaped/0},
      {"the same proof twice, from two processes: once, then replayed", fun replayed/0},
      {"two nonces from one identity are both accepted", fun two_nonces/0},
      {"a corrupted copy first does not block the genuine proof", fun corrupted_first/0},
      {"a stale timestamp fails", fun stale/0},
      {"a key that does not derive the identity fails", fun wrong_identity/0},
      {"a signature by another key fails", fun other_signer/0},
      {"a missing proof fails", fun missing/0},
      {"make refuses fields that are not wire values", fun make_refuses_non_wire/0},
      {"a signer's caller field is never signed: it verifies after the station removes it",
       fun signer_caller_is_not_signed/0},
      {"the delivery helper mirrors macula_station_link:with_caller/2", fun helper_mirrors_with_caller/0}]}.

start_cache() ->
    {ok, Pid} = mcl_om_ownership_proof_replay:start_link(),
    unlink(Pid),
    Pid.

stop_cache(Pid) ->
    exit(Pid, shutdown).

%%--------------------------------------------------------------------
%% The fields a learn_link caller authorises, in wire form, exactly as an
%% Erlang caller hands them to both make/5 and macula:call: text as
%% {text, B} (what a TypeScript or Go caller sends for a string), bytes as a
%% bare binary, an integer, a float, a null (undefined) and a nested map.
%%--------------------------------------------------------------------

fields() ->
    #{subject => {text, <<"entity:alpha">>},
      predicate => {text, <<"knows">>},
      object => {text, <<"entity:beta">>},
      confidence => 0.75,
      weight => 3,
      digest => <<1, 2, 3>>,
      note => undefined,
      metadata => #{source => {text, <<"field-notes">>}, page => 12}}.

%% A payload carrying `asserted_by', as the handler receives it after the
%% frame codec and the station's caller merge.
signed_delivery(Key, Realm, Procedure, Fields) ->
    AssertedBy = mcl_om_ownership_proof:make(Key, node_id(Key), Realm, Procedure, Fields),
    delivered(Fields#{asserted_by => AssertedBy}, node_key(), Procedure).

genuine() ->
    Key = node_key(),
    Payload = signed_delivery(Key, realm(), ?PROC, fields()),
    ?assertEqual(ok, verify(Payload, ?PROC, realm())).

changed_field() ->
    ?assertEqual({error, bad_signature}, tampered(fun(F) -> F#{object := {text, <<"entity:gamma">>}} end)).

added_field() ->
    ?assertEqual({error, bad_signature}, tampered(fun(F) -> F#{extra => {text, <<"x">>}} end)).

dropped_field() ->
    ?assertEqual({error, bad_signature}, tampered(fun(F) -> maps:remove(weight, F) end)).

text_to_bytes() ->
    ?assertEqual({error, bad_signature},
                 tampered(fun(F) -> F#{predicate := <<"knows">>} end)).

int_to_float() ->
    ?assertEqual({error, bad_signature}, tampered(fun(F) -> F#{weight := 3.0} end)).

null_to_absent() ->
    ?assertEqual({error, bad_signature}, tampered(fun(F) -> maps:remove(note, F) end)).

%% The proof is made over fields(); the payload the verifier receives is
%% changed by Change. The proof itself is carried unchanged.
tampered(Change) ->
    Key = node_key(),
    AssertedBy = mcl_om_ownership_proof:make(Key, node_id(Key), realm(), ?PROC, fields()),
    Payload = delivered((Change(fields()))#{asserted_by => AssertedBy}, node_key(), ?PROC),
    verify(Payload, ?PROC, realm()).

other_procedure() ->
    Key = node_key(),
    Payload = signed_delivery(Key, realm(), ?PROC, fields()),
    ?assertEqual({error, bad_signature}, verify(Payload, ?OTHER_PROC, realm())).

other_realm() ->
    Key = node_key(),
    Payload = signed_delivery(Key, realm(), ?PROC, fields()),
    ?assertEqual({error, bad_signature},
                 verify(Payload, ?PROC, crypto:hash(sha256, <<"org.example">>))).

no_version() ->
    ?assertEqual({error, unsupported_version}, with_proof(fun(P) -> maps:remove(v, P) end)).

%% What v1 signers send: timestamp, signature, public, and nothing else.
v1_shaped() ->
    ?assertEqual({error, unsupported_version},
                 with_proof(fun(P) -> maps:with([timestamp, signature, public], P) end)).

with_proof(Change) ->
    Key = node_key(),
    #{proof := Proof} = AssertedBy =
        mcl_om_ownership_proof:make(Key, node_id(Key), realm(), ?PROC, fields()),
    Payload = delivered((fields())#{asserted_by => AssertedBy#{proof := Change(Proof)}},
                        node_key(), ?PROC),
    verify(Payload, ?PROC, realm()).

replayed() ->
    Key = node_key(),
    Payload = signed_delivery(Key, realm(), ?PROC, fields()),
    ?assertEqual(ok, in_new_process(fun() -> verify(Payload, ?PROC, realm()) end)),
    ?assertEqual({error, replayed}, in_new_process(fun() -> verify(Payload, ?PROC, realm()) end)).

two_nonces() ->
    Key = node_key(),
    First = signed_delivery(Key, realm(), ?PROC, fields()),
    Second = signed_delivery(Key, realm(), ?PROC, fields()),
    ?assertEqual(ok, in_new_process(fun() -> verify(First, ?PROC, realm()) end)),
    ?assertEqual(ok, in_new_process(fun() -> verify(Second, ?PROC, realm()) end)).

%% A relay that forwards a copy with a broken signature first must not pin
%% the nonce: the cache takes a nonce only after the signature verifies.
corrupted_first() ->
    Key = node_key(),
    #{proof := Proof} = AssertedBy =
        mcl_om_ownership_proof:make(Key, node_id(Key), realm(), ?PROC, fields()),
    Bad = AssertedBy#{proof := Proof#{signature := flip_hex(maps:get(signature, Proof))}},
    Corrupted = delivered((fields())#{asserted_by => Bad}, node_key(), ?PROC),
    Genuine = delivered((fields())#{asserted_by => AssertedBy}, node_key(), ?PROC),
    ?assertEqual({error, bad_signature}, verify(Corrupted, ?PROC, realm())),
    ?assertEqual(ok, verify(Genuine, ?PROC, realm())).

stale() ->
    Key = node_key(),
    AssertedBy = mcl_om_ownership_proof:make(Key, node_id(Key), realm(), ?PROC, fields(),
                                             erlang:system_time(millisecond) - 120_000),
    Payload = delivered((fields())#{asserted_by => AssertedBy}, node_key(), ?PROC),
    ?assertEqual({error, stale_proof}, verify(Payload, ?PROC, realm())).

%% Signed by the carried key, but asserting another node's identity.
wrong_identity() ->
    Signer = node_key(),
    AssertedBy = mcl_om_ownership_proof:make(Signer, node_id(node_key()), realm(), ?PROC, fields()),
    Payload = delivered((fields())#{asserted_by => AssertedBy}, node_key(), ?PROC),
    ?assertEqual({error, bad_signature}, verify(Payload, ?PROC, realm())).

%% The carried public key is swapped for another node's.
other_signer() ->
    Key = node_key(),
    Other = node_key(),
    #{proof := Proof} = AssertedBy =
        mcl_om_ownership_proof:make(Key, node_id(Key), realm(), ?PROC, fields()),
    Swapped = AssertedBy#{proof := Proof#{public := hex(macula_node_keys:public_key(Other))}},
    Payload = delivered((fields())#{asserted_by => Swapped}, node_key(), ?PROC),
    ?assertEqual({error, bad_signature}, verify(Payload, ?PROC, realm())).

missing() ->
    Payload = delivered(fields(), node_key(), ?PROC),
    ?assertEqual({error, missing_proof}, verify(Payload, ?PROC, realm())).

%% macula 12.11.1's with_caller/2 removes a caller-sent text "caller" before
%% the handler reads the payload. A signer that put one in its fields must not
%% have signed it, or every such proof is refused bad_signature.
signer_caller_is_not_signed() ->
    Key = node_key(),
    Fields = (fields())#{caller => {text, <<"a caller the payload names">>}},
    AssertedBy = mcl_om_ownership_proof:make(Key, node_id(Key), realm(), ?PROC, Fields),
    Payload = delivered(Fields#{asserted_by => AssertedBy}, node_key(), ?PROC),
    ?assertEqual(ok, verify(Payload, ?PROC, realm())).

%% macula does not export with_caller/2, so this pins the helper's copy of it:
%% the text caller is removed, and the atom is the authenticated one.
helper_mirrors_with_caller() ->
    Authenticated = <<9:256>>,
    ?assertEqual(#{{text, <<"x">>} => 1, caller => Authenticated},
                 with_caller(#{{text, <<"x">>} => 1,
                               {text, <<"caller">>} => {text, <<"spoofed">>},
                               caller => <<8:256>>}, Authenticated)).

make_refuses_non_wire() ->
    Key = node_key(),
    ?assertError({not_a_wire_value, _},
                 mcl_om_ownership_proof:make(Key, node_id(Key), realm(), ?PROC,
                                             #{pid => self()})).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

verify(Payload, Procedure, Realm) ->
    mcl_om_ownership_proof:verify_asserted_by(Payload, Procedure, Realm).

in_new_process(Fun) ->
    Self = self(),
    Ref = make_ref(),
    spawn(fun() -> Self ! {Ref, Fun()} end),
    receive {Ref, Result} -> Result after 5000 -> error(timeout) end.

%% `Payload' as the handler receives it: carried in a CALL frame by `Caller',
%% encoded, decoded and verified by macula's codec, then the station's
%% caller merge (macula_station_link:with_caller/2).
delivered(Payload, Caller, Procedure) ->
    Spec = #{request_id => crypto:strong_rand_bytes(16),
             realm => realm(),
             procedure => Procedure,
             target => node_id(node_key()),
             deadline => erlang:system_time(millisecond) + 60_000,
             payload => Payload},
    Frame = macula_frame:call(Spec, Caller),
    {ok, Decoded, <<>>} = macula_frame:decode(macula_frame:encode(Frame)),
    {ok, #{payload := Delivered, caller := CallerId}} =
        macula_frame:verify_request(Decoded, profile()),
    with_caller(Delivered, CallerId).

%% macula_station_link:with_caller/2 (macula 12.11.1): a caller-sent text
%% "caller" is removed, then the wire-authenticated caller is merged.
with_caller(Payload, Caller) ->
    (maps:remove({text, <<"caller">>}, Payload))#{caller => Caller}.

node_key() ->
    {ok, K} = macula_node_keys:generate(identity, profile(), #{puzzle_difficulty => 0}),
    K.

node_id(Key) ->
    {ok, Id} = macula_node_keys:node_id(Key),
    Id.

realm() ->
    crypto:hash(sha256, <<"io.macula">>).

hex(B) ->
    binary:encode_hex(B, lowercase).

flip_hex(<<C, Rest/binary>>) when C =:= $0 -> <<$1, Rest/binary>>;
flip_hex(<<_, Rest/binary>>) -> <<$0, Rest/binary>>.

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.
