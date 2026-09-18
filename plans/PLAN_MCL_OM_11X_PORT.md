# PLAN: the mcl-om 11.x port — the PQ-enablement of the om substrate

> This exists so the mcl-* services ride the 11.x wire, while hecate-om keeps
> serving the classical fleet untouched.

**Status:** in progress on `port-11x` (main stays on the green 10.x baseline
until this compiles and its tests pass). **Kind:** build.

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
- **mcl_om_content / content_downloader / content_feeder** — check
  macula:mcid + the content wire in 11.x.

## The first live test

Once compiling: run mcl-om's own `test_live/` against
`pq.station-de-nuremberg.macula.io` + `pq.station-fi-helsinki.macula.io`
(both up, both GREEN on the probe). A capability advertised by a local
mcl-om instance must be resolvable + callable across the PQ pair.
