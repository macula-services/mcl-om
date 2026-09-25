# PLAN: the mcl-om 11.x port — the PQ-enablement of the om substrate

> This exists so the mcl-* services ride the 11.x wire, while hecate-om keeps
> serving the classical fleet untouched.

**Status:** DONE on `port-11x` — compiles, eunit 141/0, ct 16/16, lint +
dialyzer clean, and the live smoke (test_live/) passes end-to-end against the
PQ pair (5/5, 2026-09-18). main stays on the green 10.x baseline until this
merges. **Kind:** build.

## The floor

`{macula, "~> 10.0"}` → `{macula, "~> 11.3"}`. The bump is the port; every
API below changed in 11.x.

## API map (10.x → 11.x), verified against the 11.3.1 source

| 10.x call in mcl-om | 11.x replacement | Notes |
|---|---|---|
| `macula_identity:load/save/generate` | `macula_node_keys:load/3, save/2, generate/3` | node_key (purpose identity, pq_hybrid). Puzzle: `generate(identity, Profile, #{puzzle_difficulty => N})`; difficulty from `{macula, puzzle_difficulty}` app env (8). Key file format changes — the om's on-disk identity files are 10.x Ed25519; mcl-* services get fresh keys (hard break). |
| `macula_identity:public/1` | `macula_node_keys:public_key/1` | |
| `macula_identity:key_pair()` type | `macula_node_keys:node_key()` | `keypair/0` becomes the node_key accessor. |
| `macula:connect(Seeds, #{identity => Kp})` | `macula:connect(Seeds, #{node_identity => Kp, expected_node_id => NodeId, realm_trust => #{...}, verify => ...})` | 11.x REFUSES an unpinned dial: the om's seed config must carry node ids. New seed shape: `station_seeds` entries as `#{host, port, expected_node_id}`; `MACULA_STATION_SEEDS` gains a pinned variant. |
| `macula_identity:generate(#{puzzle => true})` | node_keys generate with puzzle difficulty (above) | |
| `macula_record:verify/1` | `macula_record:verify(Bytes|Map, Profile)` | profile from `macula_crypto_profile:configured()`. |
| `macula_record:procedure_advertisement(Advertiser, Uri, Station, Opts)` | `procedure_advertisement(AdvertiserNode, RealmId, Procedure, ServingStation, Opts)` | positional order changed; Realm is now its own field (no more realm-hex-inside-Uri). The om's `procedure_uri/3` must stop embedding the realm prefix for the record; the DHT key derivation changes with it (`procedure_key/1` now derives from realm_id + procedure). |
| `macula_record:verify_advertisement_cert_chain/3` | REMOVED (cert authorization form removed in 11.0) | Slice 7c's cert-chain verify dies; replaced by D25: the authorization's org_directory + procedure_delegation verify against `realm_trust` pairs. `cert_chain/realm_ca/org_ca` accessors + `verify_providers/3` + `advertise_opts/1`'s cert half are deleted. |
| `macula:advertise/5` with `auth => {ucan_required, ...}` | `macula:advertise(Pool, Realm, Procedure, Handler, Opts)` — 11.x provider advertise resolves the pool's own D25 authorization from the DHT and signs it | the pool must hold a realm-trusted identity chain: `realm_trust` keys + the org_directory/procedure_delegation records published for the pool's node id. The om's `auth_opts/1` policies: UCAN gating still exists on the 11.x station link (gated_call suite); realm_member_required maps to the D25 authorization. |
| `macula_response:advertise_direct/7` / `macula_streamer:advertise_direct/7` | still exist in 11.x with the same arity; their `advertise`/`publish_advertisement` defaults changed shape | verify against macula_response.erl (options table). |
| `macula_direct_dial:call/5` | `macula:call/5` → `macula_direct_dial:call` still present | |
| `macula:call_station/8` | `macula:call_station/7` via `macula_client:call_station/7` | the om's trust triad (`expected_node_id` + `verify => none` + `pin_tls_cert => false`) is exactly the 11.x pinned-dial model — mostly survives. |
| `macula:links/1` | unchanged | |
| `macula:find_record(s)/2, find_records_by_type/2, put_record/2` | unchanged (record_key(), bytes vs decoded — find_record returns the verified decoded record) | |
| `macula_bolt4:is_retryable(Code)` | 11.x call errors are `{error, {call_error, C, Detail}}` with BINARY codes (`<<"temporary_relay_failure">>`, `<<"unauthorized">>`, `<<"unknown_error">>`) or the atom `unknown_next_peer` | `mcl_om_wire:retryable/1` port: retry unknown_next_peer + temporary_relay_failure + unknown codes; never unauthorized. |
| `macula_identity:verify/2` | `macula_node_keys:verify/4` or frame-level verify | only one call site (grep says) — check it. |
| `macula_topic_pattern:matches/2` | check existence in 11.x | list_org_capabilities client-side filter. |
| `macula:mcid` | exists? (7 call sites — content layer) | check. |

## Module-by-module

- **mcl_om_identity** — node_key load-or-generate (puzzle 8), pinned seeds,
  realm_trust opts, pool connect; cert/org_ca/realm_ca state fields and
  accessors deleted (Slice 7c gone with the cert authorization form).
- **mcl_om_capabilities** — advertise via macula_response/macula_streamer's
  11.x opts (D25 authorization instead of cert_chain); build_advertisement
  ported to the new procedure_advertisement/4,5 field order; the
  verify_providers cert-chain path deleted (D25 verification is the station
  + trust list's job); call path keeps the pinned-dial triad.
- **mcl_om_wire** — retryable/1 to the 11.x code set; field/unwrap already
  D26-aware.
- **mcl_om_service** — capability() type: `auth` values lose the cert-chain
  forms; handler/advertise shapes otherwise survive.
- **mcl_om_pubsub / pubsub_subscriptions / health / health_handler /
  simple_handler / describe / ownership_proof** — mostly facade calls that
  survive; ownership_proof needs the node_keys key_id model.
- **mcl_om_store / mcl_om_read_model** — reckon-db side, wire-agnostic;
  should survive unchanged.
- **mcl_om_content / content_downloader / content_feeder** — REMOVED in
  0.30.0 (Raf, 2026-09-25): no service used them, and macula 12.6.0's
  `share_content`/`get_content` are what a service calls.

## The first live test — DONE, 2026-09-18

`rebar3 as live_test eunit --dir test_live` runs the ported live suite
against `pq.station-fi-helsinki.macula.io` (5 tests, 0 failures): the
om boot + real publish, real pubsub events with dynamic subscriptions,
and the capabilities path end to end — publish the D25 chain
(org_directory + procedure_delegation under a test realm), advertise a
handler-bearing capability through `mcl_om_capabilities:register/1`,
resolve + dial + CALL it from a separate consumer pool, org-scoped
calls and the org-capability browse.

The live run paid for four real port bugs the unit tests could not
reach, all fixed at the source:

1. **The DHT record needs the authorization embedded.** The SDK's
   advertise path resolves the D25 chain for the WIRE frame only; the
   direct-dial record `advertise_direct` publishes carries just its
   Opts, and the 11.x station refuses an org-namespaced record without
   one (`{call_error, <<"no_authorization">>}`). `advertise_one/7` now
   resolves the chain itself (the same two DHT reads the SDK makes)
   and embeds `authorization` in the Opts.
2. **The CALL target is the provider, not the station.** 11.x routes
   the CALL by the provider's node id and the reply must verify as
   that target (`not_the_target` otherwise); the ported dial passed
   the serving station as target.
3. **The direct dial needs the pinned trust triad.** The endpoint's
   IP literal has no IP SAN, so `verify => none` +
   `expected_node_id => Station` (D5 handshake pin), exactly the
   station suite's own direct-dial caller.
4. **Endpoint resolution must retry.** The station re-announces its
   `station_endpoint` periodically; the ported one-shot lookup missed
   it. Now `macula_direct_dial:resolve_station_endpoint/3` (retrying,
   signer-checked).
5. Also fixed: `decode_verified_if_org_matches/4` matched a bound
   `realm_id` inside a `try ... of` — a mismatch raises `try_clause`,
   which a try's `catch` does NOT catch (the catch covers the
   expression, not the `of` clauses), so any foreign-realm record
   crashed the browse instead of being filtered.

Fleet findings from the smoke (not fixable in this repo):

- **nuremberg publishes no `station_endpoint`** and its DHT find
  misses every record (helsinki's own endpoint resolves fine through
  helsinki). The live tests therefore pin helsinki. The PQ probe's
  three legs (connect/pair/SWIM) don't exercise DHT record finds, so
  this was invisible to it.
- **The PQ fleet serves no content procedures** — the 11.x station
  dropped the pooled content store (the SDK's content transfer targets
  a content-serving peer). `test_live/mcl_om_content_live_station_tests`
  was deleted: a live test that can never pass against any deployed
  target is a lie. (mcl_om_content itself went in 0.30.0; macula 12.6.0
  serves content from the sharing node.)
- **Pubsub and RPC payload keys arrive as `{text, _}` markers** (D26)
  on the PQ wire — `mcl_om_wire:field/2,3` is the contract, and the
  live assertions read through it.
