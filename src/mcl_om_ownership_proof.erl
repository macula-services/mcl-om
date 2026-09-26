%%% @doc Proof that an identity authorised exactly this request, once: the
%%% `asserted_by' block of a payload (plans/PLAN_OWNERSHIP_PROOF_V2.md,
%%% mcl-om#7).
%%%
%%% The signer sends `asserted_by => #{identity => Hex, proof => Proof}'
%%% beside the fields it authorises. The proof signs the deterministic CBOR
%%% (macula_record_cbor:encode/1) of a map with text keys: tag
%%% "macula.ownership_proof", v 2, identity (32 bytes), realm (32 bytes),
%%% procedure (text), timestamp (ms), nonce (16 bytes) and fields: the
%%% payload as the handler receives it, minus asserted_by and minus caller in
%%% every key form. `caller' is never signed: macula_station_link:with_caller/2
%%% merges the authenticated atom `caller', and from macula 12.11.1 it also
%%% removes a caller-sent text "caller" before the handler runs, so a signed
%%% caller could never be rebuilt. Dropping it on both sides gives the same
%%% result on any macula version.
%%%
%%% The fields are re-encoded raw, never unwrapped: after macula 12's
%%% strict decode, text arrives as {text, B} and bytes as B, and those
%%% encode as different CBOR types. The one exception is a decoded null,
%%% which the frame hands over as undefined and which becomes null again.
%%% This departs from macula_signed_object, which signs bytes it never
%%% re-encodes, on purpose: what must be bound is what the handler reads,
%%% and that exists only as a decoded term.
%%%
%%% make/5,6 takes fields in the form an Erlang caller hands macula:call,
%%% and applies the frame's own conversion to them (atoms and binary keys to
%%% text keys, undefined to null, atom values to text), so the signer
%%% encodes what the verifier will rebuild.
%%%
%%% Replay: the nonce is recorded in mcl_om_ownership_proof_replay only
%%% after the signature has verified, so an identical proof is accepted
%%% once. The cache is per instance and empty after a restart, so a
%%% captured proof can be accepted once by each instance, and once more
%%% after a restart, within its 60 s window.
-module(mcl_om_ownership_proof).

-export([make/5, make/6, verify/5, verify_asserted_by/3, message/6]).
-export([decode_identity/1, decode_text/1]).

-define(TAG, <<"macula.ownership_proof">>).
-define(VERSION, 2).
-define(MAX_SKEW_MS, 60_000).

-type fields() :: #{term() => term()}.
-type reason() :: missing_proof | unsupported_version | stale_proof | replayed
                | bad_signature | invalid_identity.

%% @doc The asserted_by block for `Fields', signed now by `Key' for
%% `Identity' in the realm `Realm' (32 bytes) and `Procedure'.
-spec make(macula_node_keys:node_key(), binary(), binary(), binary(), fields()) -> map().
make(Key, Identity, Realm, Procedure, Fields) ->
    make(Key, Identity, Realm, Procedure, Fields, erlang:system_time(millisecond)).

%% @doc make/5 at a chosen timestamp, so a test can prove a stale proof fails.
-spec make(macula_node_keys:node_key(), binary(), binary(), binary(), fields(), integer()) -> map().
make(Key, Identity, Realm, Procedure, Fields, Timestamp) ->
    Nonce = crypto:strong_rand_bytes(16),
    Canonical = canonical(without_envelope(wire(Fields))),
    Signature = macula_node_keys:sign(message(Identity, Realm, Procedure, Timestamp, Nonce, Canonical), Key),
    #{identity => hex(Identity),
      proof => #{v => ?VERSION,
                 timestamp => Timestamp,
                 nonce => hex(Nonce),
                 signature => hex(Signature),
                 public => hex(macula_node_keys:public_key(Key))}}.

%% @doc The exact bytes that are signed. Exported so another SDK's signer can
%% be checked against it byte for byte.
-spec message(binary(), binary(), binary(), integer(), binary(), fields()) -> binary().
message(Identity, Realm, Procedure, Timestamp, Nonce, Fields) ->
    macula_record_cbor:encode(
      #{{text, <<"tag">>} => {text, ?TAG},
        {text, <<"v">>} => ?VERSION,
        {text, <<"identity">>} => Identity,
        {text, <<"realm">>} => Realm,
        {text, <<"procedure">>} => {text, Procedure},
        {text, <<"timestamp">>} => Timestamp,
        {text, <<"nonce">>} => Nonce,
        {text, <<"fields">>} => Fields}).

%% @doc Verify the asserted_by block of a payload as the handler received it.
-spec verify_asserted_by(map(), binary(), binary()) -> ok | {error, reason()}.
verify_asserted_by(Payload, Procedure, Realm) when is_map(Payload) ->
    asserted(mcl_om_wire:field(asserted_by, Payload), Payload, Procedure, Realm).

%% @doc Verify that `Proof' shows `Identity' (32 bytes) authorised the fields
%% of `Payload' (as the handler received it) for `Procedure' in `Realm'.
-spec verify(binary(), map(), binary(), binary(), map()) -> ok | {error, reason()}.
verify(Identity, Proof, Procedure, Realm, Payload)
  when is_binary(Identity), byte_size(Identity) =:= 32, is_map(Proof) ->
    versioned(mcl_om_wire:field(v, Proof), Identity, Proof, Procedure, Realm, Payload);
verify(_Identity, _Proof, _Procedure, _Realm, _Payload) ->
    {error, invalid_identity}.

asserted(AssertedBy, Payload, Procedure, Realm) when is_map(AssertedBy) ->
    identified(decode_identity(mcl_om_wire:field(identity, AssertedBy)),
               mcl_om_wire:field(proof, AssertedBy), Payload, Procedure, Realm);
asserted(_Absent, _Payload, _Procedure, _Realm) ->
    {error, missing_proof}.

identified(undefined, _Proof, _Payload, _Procedure, _Realm) -> {error, invalid_identity};
identified(Identity, Proof, Payload, Procedure, Realm) when is_map(Proof) ->
    verify(Identity, Proof, Procedure, Realm, Payload);
identified(_Identity, _Proof, _Payload, _Procedure, _Realm) -> {error, missing_proof}.

%%--------------------------------------------------------------------
%% Verification steps, one decision each
%%--------------------------------------------------------------------

versioned(?VERSION, Identity, Proof, Procedure, Realm, Payload) ->
    timed(mcl_om_wire:field(timestamp, Proof), Identity, Proof, Procedure, Realm, Payload);
versioned(_Other, _Identity, _Proof, _Procedure, _Realm, _Payload) ->
    {error, unsupported_version}.

timed(Ts, Identity, Proof, Procedure, Realm, Payload) when is_integer(Ts) ->
    fresh(abs(erlang:system_time(millisecond) - Ts) =< ?MAX_SKEW_MS,
          Ts, Identity, Proof, Procedure, Realm, Payload);
timed(_Ts, _Identity, _Proof, _Procedure, _Realm, _Payload) ->
    {error, missing_proof}.

fresh(true, Ts, Identity, Proof, Procedure, Realm, Payload) ->
    decoded(bytes(mcl_om_wire:field(nonce, Proof), 16),
            bytes(mcl_om_wire:field(signature, Proof), any),
            bytes(mcl_om_wire:field(public, Proof), any),
            Ts, Identity, Procedure, Realm, Payload);
fresh(false, _Ts, _Identity, _Proof, _Procedure, _Realm, _Payload) ->
    {error, stale_proof}.

decoded({ok, Nonce}, {ok, Sig}, {ok, Pub}, Ts, Identity, Procedure, Realm, Payload) ->
    derived(macula_node_keys:node_id(Pub, profile()), Nonce, Sig, Pub, Ts, Identity, Procedure, Realm, Payload);
decoded(_Nonce, _Sig, _Pub, _Ts, _Identity, _Procedure, _Realm, _Payload) ->
    {error, bad_signature}.

%% The identity must derive from the carried key before the signature is spent on it.
derived(Identity, Nonce, Sig, Pub, Ts, Identity, Procedure, Realm, Payload) ->
    Message = message(Identity, Realm, Procedure, Ts, Nonce, fields_of(Payload)),
    signed(macula_node_keys:verify(Message, Sig, Pub, profile()), Identity, Nonce);
derived(_Derived, _Nonce, _Sig, _Pub, _Ts, _Identity, _Procedure, _Realm, _Payload) ->
    {error, bad_signature}.

%% The nonce is recorded only after the signature has verified.
signed(true, Identity, Nonce) -> first_use(mcl_om_ownership_proof_replay:record(Identity, Nonce));
signed(false, _Identity, _Nonce) -> {error, bad_signature}.

first_use(true) -> ok;
first_use(false) -> {error, replayed}.

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.

%%--------------------------------------------------------------------
%% Canonical fields
%%--------------------------------------------------------------------

%% The payload as delivered, minus the proof block and the caller.
fields_of(Payload) ->
    canonical(without_envelope(Payload)).

%% asserted_by and caller are never signed, in any key form.
without_envelope(Map) ->
    maps:without([{text, <<"asserted_by">>}, asserted_by, <<"asserted_by">>,
                  {text, <<"caller">>}, caller, <<"caller">>], Map).

%% A decoded null arrives as undefined; everything else stays as delivered.
canonical(undefined) -> null;
canonical(Map) when is_map(Map) -> maps:map(fun(_K, V) -> canonical(V) end, Map);
canonical(List) when is_list(List) -> [canonical(V) || V <- List];
canonical(Value) -> Value.

%% macula_frame's to_wire/1 rules, so make/5 encodes what the frame sends.
wire(Map) when is_map(Map) -> maps:fold(fun(K, V, Acc) -> Acc#{wire_key(K) => wire(V)} end, #{}, Map);
wire(List) when is_list(List) -> [wire(V) || V <- List];
wire(undefined) -> null;
wire({text, B} = Text) when is_binary(B) -> Text;
wire(Atom) when is_atom(Atom) -> {text, atom_to_binary(Atom, utf8)};
wire(B) when is_binary(B) -> B;
wire(N) when is_integer(N); is_float(N) -> N;
wire(Other) -> erlang:error({not_a_wire_value, Other}).

wire_key(A) when is_atom(A) -> {text, atom_to_binary(A, utf8)};
wire_key({text, B} = Text) when is_binary(B) -> Text;
wire_key(B) when is_binary(B) -> {text, B};
wire_key(I) when is_integer(I) -> I;
wire_key(Other) -> erlang:error({not_a_wire_value, Other}).

%%--------------------------------------------------------------------
%% Wire text helpers (also used by learn_link)
%%--------------------------------------------------------------------

%% @doc A wire-transported string as a plain binary; undefined passes through.
-spec decode_text(term()) -> binary() | undefined.
decode_text(V) -> unwrap_text(V).

%% @doc A wire-transported identity (hex text or 32 raw bytes) as its raw bytes.
-spec decode_identity(term()) -> binary() | undefined.
decode_identity(V) -> hex_or_raw(unwrap_text(V)).

unwrap_text(undefined) -> undefined;
unwrap_text(Bin) when is_binary(Bin) -> Bin;
unwrap_text({text, Bin}) when is_binary(Bin) -> Bin;
unwrap_text(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
unwrap_text(_Other) -> undefined.

hex_or_raw(undefined) -> undefined;
hex_or_raw(Hex) when byte_size(Hex) =:= 64 ->
    try binary:decode_hex(Hex) catch error:badarg -> undefined end;
hex_or_raw(Raw) when byte_size(Raw) =:= 32 -> Raw;
hex_or_raw(_Other) -> undefined.

bytes(Hex, Size) when is_binary(Hex) ->
    sized(try {ok, binary:decode_hex(Hex)} catch error:badarg -> error end, Size);
bytes(_Hex, _Size) ->
    error.

sized({ok, Raw}, any) -> {ok, Raw};
sized({ok, Raw}, Size) when byte_size(Raw) =:= Size -> {ok, Raw};
sized(_Decoded, _Size) -> error.

hex(B) -> binary:encode_hex(B, lowercase).
