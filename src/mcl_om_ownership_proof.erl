%%% @doc Verifies a caller actually holds the private key for the
%%% A caller proves it holds the private half of the node key whose
%%% carried public key it asserts as its identity, inside an otherwise-
%%% open mesh payload: the 11.x identity is a pq_hybrid node key, and
%%% ownership is proved by signing `{identity, timestamp, procedure}'
%%% with its private half -- `procedure' included so a proof minted for
%%% one gated capability can't be replayed against another this or any
%%% other service adds later.
%%%
%%% Extracted here after the identical ~40-line verifier had been
%%% written twice independently -- hecate-citizens'
%%% `citizen_ownership_proof` (proving a `register_presence` caller
%%% holds the `citizen_did` it's registering) and hecate-mail's
%%% `mailbox_ownership_proof` (proving a caller may read a mailbox) --
%%% each one's own moduledoc naming the same test for when to stop
%%% duplicating it: "would a second, unrelated consumer plausibly want
%%% this same fact." hecate-graph's `learn_link` needing it too (to make
%%% graph provenance mind-grained rather than only connection-grained,
%%% PLAN_MESH_TRUTHS_AND_PROVENANCE.md) is the third consumer that
%%% crosses it.
%%%
%%% A DIFFERENT mechanism from macula's own `{ucan_required, Issuer}`
%%% capability gating (`hecate-om/plans/PLAN_UCAN_GATED_CAPABILITIES.md`):
%%% that controls who may CALL a procedure at all, enforced by the
%%% serving station before any handler runs. This proves WHO ASSERTED a
%%% specific claim inside an otherwise-open procedure's payload --
%%% provenance, not access control. A procedure can use either, both, or
%%% neither.
%%%
%%% WIRE ENCODING: macula's frame decoder walks a payload map and
%%% converts every CBOR TEXT value to an ATOM via
%%% `binary_to_existing_atom/1' whenever the RECEIVING VM already has
%%% that atom loaded -- if not, it stays a `{text, Binary}' tuple. Which
%%% shape a given value arrives as therefore depends on what atoms this
%%% VM happens to already know, not on anything the caller controls: a
%%% real identity (effectively random hex) is essentially never already
%%% an atom, so it always arrives `{text, Bin}'-tagged. `unwrap_text/1'
%%% handles all three shapes (bare binary, bare atom, `{text, Bin}')
%%% plus `undefined'; `decode_identity/1' layers hex-decoding on top for
%%% identity/signature fields, `decode_text/1' is the same unwrap alone
%%% for any other wire-transported string.
-module(mcl_om_ownership_proof).

-export([verify/3, message/3, decode_identity/1, decode_text/1]).

-define(MAX_SKEW_MS, 60_000).

%% @doc Unwraps whatever shape a wire-transported string value arrived
%% in (bare binary, bare atom, or `{text, Binary}') into a plain
%% binary. `undefined' passes through unchanged.
-spec unwrap_text(term()) -> binary() | undefined.
unwrap_text(undefined) -> undefined;
unwrap_text(Bin) when is_binary(Bin) -> Bin;
unwrap_text({text, Bin}) when is_binary(Bin) -> Bin;
unwrap_text(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
unwrap_text(_Other) -> undefined.

%% @doc `unwrap_text/1' alone, for any wire-transported string that
%% isn't an identity/signature.
-spec decode_text(term()) -> binary() | undefined.
decode_text(V) -> unwrap_text(V).

%% @doc Unwraps, then hex-decodes, a wire-transported identity (or
%% signature) into its raw bytes.
-spec decode_identity(term()) -> binary() | undefined.
decode_identity(V) -> hex_or_raw(unwrap_text(V)).

hex_or_raw(undefined) ->
    undefined;
hex_or_raw(Hex) when byte_size(Hex) =:= 64 ->
    try binary:decode_hex(Hex) catch error:badarg -> undefined end;
hex_or_raw(Raw) when byte_size(Raw) =:= 32 ->
    Raw;
hex_or_raw(_Other) ->
    undefined.

-spec message(binary(), integer(), binary()) -> binary().
message(Identity, Timestamp, Procedure)
  when is_binary(Identity), is_integer(Timestamp), is_binary(Procedure) ->
    <<Identity/binary, Timestamp:64/big, Procedure/binary>>.

%% @doc Verify that `Proof' (a map with `timestamp' and `signature')
%% proves possession of the private key behind `Identity' (a raw
%% 32-byte Ed25519 pubkey), bound to `Procedure'.
-spec verify(binary(), map(), binary()) -> ok | {error, atom()}.
verify(Identity, Proof, Procedure)
  when is_binary(Identity), byte_size(Identity) =:= 32, is_map(Proof), is_binary(Procedure) ->
    checked_fields(maps:find(timestamp, Proof), maps:find(signature, Proof),
                   Identity, Procedure);
verify(_Identity, _Proof, _Procedure) ->
    {error, invalid_identity}.

checked_fields({ok, Ts}, {ok, Sig}, Identity, Procedure) when is_integer(Ts) ->
    decoded_sig(hex_or_raw_sig(unwrap_text(Sig)), Ts, Identity, Procedure);
checked_fields(_Ts, _Sig, _Identity, _Procedure) ->
    {error, missing_proof}.

hex_or_raw_sig(undefined) ->
    undefined;
hex_or_raw_sig(Sig) when byte_size(Sig) =:= 128 ->
    try binary:decode_hex(Sig) catch error:badarg -> undefined end;
hex_or_raw_sig(Sig) when byte_size(Sig) =:= 64 ->
    Sig;
hex_or_raw_sig(_Other) ->
    undefined.

decoded_sig(undefined, _Ts, _Identity, _Procedure) ->
    {error, bad_signature};
decoded_sig(Sig, Ts, Identity, Procedure) ->
    fresh(Ts, Identity, Sig, Procedure).

fresh(Ts, Identity, Sig, Procedure) ->
    skew_checked(abs(erlang:system_time(millisecond) - Ts), Ts, Identity, Sig, Procedure).

skew_checked(Skew, Ts, Identity, Sig, Procedure) when Skew =< ?MAX_SKEW_MS ->
    signed(macula_node_keys:verify(message(Identity, Ts, Procedure), Sig,
                                    Identity, profile()));
skew_checked(_Skew, _Ts, _Identity, _Sig, _Procedure) ->
    {error, stale_proof}.

signed(true) -> ok;
signed(false) -> {error, bad_signature}.

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.
