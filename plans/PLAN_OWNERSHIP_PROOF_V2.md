# PLAN: Ownership proof v2, bound to every field it authorises

**End goal:** a service can check that an identity authorised exactly this request, once, and not a relay's variation
or repetition of it.

**Status:** planned. **Kind:** BUILD (a format and a verifier; the weakness is known, no claim to test).
**Created:** 2026-09-26. **Owner:** Saturnus; mcl-om belongs to Uranus. **Issue:** macula-services/mcl-om#7.
**Size:** one mcl_om release, one mcl-graph change, two signers (macula-mcp's `ownership_proof.ts` and macula-cli's
`identity sign`, both Venus).

## Today (v1)

`mcl_om_ownership_proof` (origin/main 2fbfb19):

- **Message:** `identity (32 bytes) ++ timestamp (8 bytes, big-endian) ++ procedure`.
- **Checks:** 60 s of skew; the carried public key derives the asserted identity; the signature verifies in the
  configured profile.
- **One consumer:** mcl-graph `learn_link` verifies `asserted_by` with it.

Weaknesses:

1. **No payload field is covered.** A relay holding a captured proof can make the same identity assert any triple
   within 60 s.
2. **No domain separation.** The message is a bare concatenation. Another structure signed by the same node key could
   produce the same bytes.
3. **No version.** A format change cannot be told apart from a malformed proof.
4. **Identical replay.** The same request can be replayed within the skew, and `learn_link` is NOT idempotent: its
   `link_id` includes the time (`link_id(S, P, O, Now)`), so every accepted call inserts a new link, new provenance
   edges and new mesh facts. A replay duplicates evidence.
5. **No realm binding.** A proof accepted in one realm is equally valid in another.

## v2

Revised after Fable's review (2026-09-26): required changes R1 to R3 and observations a to e are applied below.

### Message

The signed message is the deterministic CBOR encoding of the map below. In Erlang that is
`macula_record_cbor:encode/1`, the reference encoder of macula's record layer (`pack_deterministic/1` is documented
as additive and not wired into the frame yet). In Go it is
`macula-go/cbor/encode.go`; TypeScript signs through the macula-go FFI. Never a generic JS CBOR library: it
shortens 1.0 to a half float and the bytes never match.

```
#{tag       => tstr "macula.ownership_proof",
  v         => uint 2,
  identity  => bstr 32   (raw node_id; the wire carries it as hex text, the message holds raw bytes),
  realm     => bstr 32   (the realm tag the service runs under: mcl_om:realm/0),
  procedure => tstr      ("Org/Name"),
  timestamp => uint      (milliseconds),
  nonce     => bstr 16   (random),
  fields    => map       (see below)}
```

Every value's CBOR type is fixed as written:

- floats are always binary64, as `macula_record_cbor:encode/1` writes them (never RFC 8949's shortened floats);
- no booleans (the house rule: 0/1).

**`fields` (R1).** It is the decoded payload **exactly as delivered to the handler**, minus two keys, re-encoded
**raw**, never through `mcl_om_wire:unwrap/1`:

- **Minus `asserted_by`,** in every key form it can arrive in (`{text, <<"asserted_by">>}` on the wire, a binary or an
  atom in a local call).
- **A decoded null becomes null again:** the frame hands a CBOR null to the handler as `undefined`, which the
  encoder would write as text. This was found by Fable's review of the sibling realm plan (macula-realm#29, R3).
- **Minus the atom key `caller`,** which `macula_station_link:with_caller/2` merges into every CALL after decode. The
  signer never sees it, because the relay is the wire caller.
- **Why raw:** after macula 12's strict decode (`macula_frame:frame_read/2` uses
  `macula_record_cbor:decode_strict/1`), text arrives as `{text, B}`, bytes as `B`, and floats and integers stay
  distinct. Re-encoding that term gives back the bytes the signer encoded. Unwrapping `{text, B}` to `B` would
  re-encode it as a byte string (major 2 instead of 3) and fail every string field a TypeScript or Go caller sends.
  Only `identity` and the `proof` block are read through `mcl_om_wire`.

**`tag` and `v`** give domain separation and a version: the message is a CBOR map with this tag, so it can never
equal a v1 concatenation or another signed structure in the stack. A proof with no `v`, like every v1 proof, and a
proof whose `v` is not 2, are both refused as `unsupported_version`.

**`realm`** is `mcl_om:realm/0`, the 32-byte tag. `mcl_graph_facts:check_realm_name/0` already refuses to boot without
it. A proof made for one realm fails in another.

**A deliberate departure (observation c).** `macula_signed_object:sign/3`, the stack's rule for signed objects, signs
bytes it never re-encodes. This proof re-encodes on purpose: what it must bind is what the handler reads, and that
exists only as a decoded term. The moduledoc says so, and a test pins the property the departure rests on (below).

**`make/5` takes fields in wire form (observation b).** It accepts only `macula_record_cbor:value()` terms and refuses
any atom other than the null the frame uses, so an Erlang signer cannot sign `undefined` as the text "undefined"
while the frame sends null.

### Identical replay: decided (R2)

**Decision: bind a nonce, and keep a replay cache owned by mcl_om.** Each proof carries a 16-byte random nonce.
`macula_response` runs every inbound CALL in its own supervised process, so the cache cannot belong to the verifying
call. It belongs to a process in mcl_om's supervision tree, inside the ownership-proof slice:

- it owns a public, named ETS table created at boot, and sweeps entries older than 2 x 60 s on a timer;
- the verifier inserts `{Identity, Nonce}` with `ets:insert_new/2` **only after the signature has verified**, so a
  corrupted copy forwarded first cannot pin the nonce and get the genuine request refused;
- `insert_new` is atomic, so two concurrent copies cannot both pass;
- a failed insert is `{error, replayed}`.

**Why not rely on idempotency:** `learn_link` is not idempotent, and making it so would change what a link means (the
time is part of its identity).

**Why not bind the mesh request_id:** the signer does not choose it before the SDK sends the call, and it would tie
the proof to one transport.

**Residuals, stated in the moduledoc:**

- the cache is per instance, so with N instances a captured proof can be accepted once by each within its 60 s window;
- the cache is empty after a restart, so it can be accepted once more after each restart within that window.

A shared cache is not worth it for today's single consumer.

**learn_link on `replayed` (observation d): it refuses the call.** Today a failed proof falls back to the wire caller
(`learn_link:verified_or_wire/2`), which would still insert a duplicate link attributed to the relay. A relay that
replays a proof is misbehaving, so `replayed` becomes a refusal, not a fallback. Every other failure keeps today's
fallback to the wire caller.

### API

- `mcl_om_ownership_proof:make(Key, Identity, Realm, Procedure, Fields) -> Proof`, for Erlang signers and tests,
  fields in wire form.
- `mcl_om_ownership_proof:verify(Identity, Proof, Procedure, Realm, Payload) -> ok | {error, Reason}`.
  - `Reason` is one of `missing_proof`, `unsupported_version`, `stale_proof`, `replayed`, `bad_signature` or
    `invalid_identity`.
  - `Payload` is the handler's payload as delivered.
- `verify/3` (v1) is removed from mcl_om (see Scope and migration).

## Tests first (each seen red on v1 or on a named buggy v2)

1. **Field tamper (observation e).** The proof is made once. Then the **payload handed to `verify/5`** is tampered
   with, and the proof stays unchanged:
   - a field changed, added or dropped: `bad_signature`;
   - a text value changed to bytes of the same content, 1 changed to 1.0, null changed to absent: `bad_signature`.
     This pins the departure in observation c.
2. **Cross-context replay:**
   - under another procedure: `bad_signature`;
   - under another realm: `bad_signature`;
   - a v1-shaped proof with no `v`: `unsupported_version`.
3. **Identical replay (R2),** verifies issued from two different processes:
   - the same proof twice: accepted once, then `replayed`;
   - two proofs from the same identity with different nonces: both accepted;
   - a corrupted copy first, then the genuine one: `bad_signature`, then `ok`.
4. **Carried over:** a stale timestamp, a carried key that does not derive the identity, and a wrong signature still
   fail.
5. **The real path (R1).** A payload built with `{text, _}` strings, an integer, a float and a nested map is signed by
   a TypeScript-shaped signer (text strings), run through `macula_frame:call`, encode, decode and `verify_request`,
   **and** the station's caller merge (the shape of mcl-graph's `test/delivered_call.erl:delivered/2`). The result is
   `ok`.
6. **Cross-SDK vector:** one fixed message, containing a text value, a byte value, an integer, a float and a nested
   map, gives identical bytes from Erlang, macula-go and the TypeScript FFI. The CLI's JSON-to-CBOR mapping is pinned:
   strings to tstr, numbers with a fraction to float64, integers to uint, no booleans.

## Scope and migration (R3)

**The v1 byte layout (`identity ++ ts:64/big ++ procedure`) has users outside mcl_om. This plan does not touch them:**

- macula-realm `device_key_ownership_proof.ex:message/3` (device-key join and membership proofs);
- macula-mcp `proofMessage` / `signOwnershipProof` (`macula_ts_client.ts:356`), used by `realm.ts`, `bin/realm.ts`
  and `device_membership.ts` for realm joins;
- macula-cli `identity sign` (`cmd/macula-cli/identity.go:proofMessage`);
- macula-mcp `src/ownership_proof.ts`, the Ed25519 ring verifier (10.x lineage).

Switching those would refuse every realm join. They stay v1 and are out of scope. Hardening them is a separate
decision for the realm.

**v2 gets new signer entry points, for `asserted_by` only:**

- macula-mcp: `signAssertedBy(identityPath, realm, procedure, fields)`, emitting the whole `asserted_by` block,
  nonce included;
- macula-cli: a new subcommand taking `--realm` and the payload, emitting the same block.

**Migration for mcl_om's own verifier (house rule: no backward compatibility unless something live depends on it):**

- **Check first:** is mcl-graph (`learn_link`) deployed, and does any live caller send `asserted_by`?
- **If not (expected):**
  - one mcl_om release with v2 only;
  - mcl-graph on it;
  - the two new signer entry points in the same batch;
  - a v1 `asserted_by` is then refused as `unsupported_version`, for mcl_om consumers only.
- **If so:** stop and ask. The only acceptable bridge is v1 accepted until a date Raf sets, each acceptance logged at
  warning level.

## Military-grade baseline

Add a row to `macula/plans/PLAN_MILITARY_GRADE_BASELINE.md`:

| Property | Requirement | Current state | Gap | Size |
|---|---|---|---|---|
| Ownership proofs bound to what they authorise | CRA I(2)(d), (f); NIS2 21(2)(i) | mcl_om v1 signs identity, time and procedure only; no domain tag, version or realm; replayable for 60 s (mcl-om#7) | v2 per `mcl-om/plans/PLAN_OWNERSHIP_PROOF_V2.md`; realm-join proofs keep the v1 layout, a separate decision | S |

## Review

Fable reviewed this plan once (2026-09-26). The three required changes (R1 `fields` as delivered and raw, R2 the
cache's owner and insertion rule, R3 the v1 scope) and all five observations are applied above. Next: build, test
first, then one range per repository.
