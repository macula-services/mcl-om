# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [0.2.0] - 2026-09-19

### Added

- **The boot-time claim** (`mcl_om_claim`, a sup child): once the pool is
  connected, the service requests its provider authorization from the realm
  over the mesh (`io.macula/_realm/_realm/identity/request_provider_authorization_v1`),
  by its own wire-authenticated identity — no credentials. The realm either
  issues the D25 delegation or records the request as a pending row for its
  operator; either reply ends the retries, and the advertise path resolves
  the delegation independently. Stops normally when no seeds are configured;
  `service_name`/`box` app envs are informational labels the operator sees.

## [0.1.0] - 2026-09-18

### Changed

- **The hard break.** Forked from hecate-om 0.25.0 into the PQ-only
  `mcl_om` line; the version resets to 0.1.0 because the API and the wire
  are incompatible with every hecate-om release. Everything below is the
  inherited hecate-om history.
- **The 11.x port.** Identity is a puzzle-hardened pq_hybrid node key
  (`macula_node_keys`, `identity_key/0` replaces the 10.x keypair +
  service cert); seeds are pinned by station node id (D5, `MACULA_STATION_SEEDS`
  index-paired with `MACULA_STATION_NODE_IDS`); capabilities advertise the
  org-qualified procedure with the D25 authorization resolved from the DHT
  (`macula:provider_authorization/3`, macula >= 11.4.0) and call with the
  provider's node id as the CALL target; the cert-chain accessors and the
  bare-name/cert forms are deleted with the 10.x authorization model.
- **The service scaffold** is the `mcl_service` rebar3 template (renamed off
  the hecate lineage), carrying the mandatory PQ crypto block and the pinned
  seed pair; CI builds OpenSSL 3.6.4 + OTP 28.1 from source for the ML-DSA
  tests, and the release pipeline (`publish-hex.yml`) verifies the tag and
  publishes to hex behind the `hex-publish` environment gate.
- **The live smoke** (test_live/, run manually against the PQ pair) proves
  the whole path end to end: D25 chain publish, org-namespaced advertise,
  authorized direct-dial record, pinned dial, CALL, org-scoped calls and the
  org-capability browse. The content live test is gone: the PQ fleet serves
  no content procedures.

## [0.25.0] - 2026-09-11

### Added

- `health_ip` (optional): the address the `/health` listener binds, as a
  string such as `"127.0.0.1"` or an address tuple. Unset or empty, the
  listener binds every interface, as before. A service whose health is only
  probed from inside its own container or host sets `"127.0.0.1"`. New eunit
  tests (`hecate_om_health_listener_tests`) cover the socket options and a
  loopback listener refusing a connection on another interface.

- `t:hecate_om_service:capability/0`'s `auth` field now includes
  `{realm_member_required, RealmDid, RequiredCan}` -- `macula` added this
  policy after `PLAN_UCAN_GATED_CAPABILITIES.md` was written and called
  the realm-membership case unbuilt; `hecate_om_capabilities:auth_opts/1`
  needed no code change at all (it was already policy-agnostic), only
  the stale type and moduledoc did. New eunit test
  (`auth_opts_carries_a_realm_member_required_policy_test`) pins the
  round-trip. See the plan doc's own 2026-09-08 update.
- `c:hecate_om_service:describe_rpc_capabilities/0` +
  `describe_pubsub_capabilities/0` (both optional): human-facing
  documentation for a service's capabilities/topics, distinct from
  `capabilities/0`'s/`subscriptions/0`'s own dispatch-wiring-only
  metadata. When either is exported, `hecate_om:boot/2` advertises a
  synthetic `<service-name>.describe_capabilities` RPC
  (`hecate_om_describe`, stateless -- reads `hecate_om:service_module/0`)
  that returns both lists live. Motivating cost this closes:
  `macula-lazymesh`'s `MeshServices` catalog hand-maintains a hardcoded
  description list today purely because there was nowhere on the mesh to
  pull this metadata from.

- `c:hecate_om_service:read_model_ttl_sweep/0` (optional callback): a
  service can now arm barrel_docdb's native per-document TTL sweeper on
  its own read model -- `disabled` (default, unchanged behavior for every
  existing service) or `#{interval_ms := pos_integer(), batch :=
  pos_integer()}`. `hecate_om:boot/1` threads it into the database's
  `create_db` config via `hecate_om_read_model:ensure/3` (`ensure/2` still
  works, now a thin wrapper defaulting to `disabled`). Arming the sweeper
  only reclaims disk for documents that already carry `expires_at` in
  their own `put_doc/3` options -- barrel_docdb treats those as gone on
  read unconditionally regardless of this config (see
  `barrel_docdb_reader:expired/1`'s own doc comment); this setting only
  controls whether the background timer exists to turn that lazy expiry
  into a real, space-reclaiming tombstone. Motivated by hecate-agora's
  storage-retention design, where hand-rolling scan-and-delete would have
  duplicated a primitive barrel_docdb (`~> 1.3`, already the pinned
  dependency) already provides natively.

### Fixed

- `hecate_om_wire:field/2,3` now also finds a key that arrives as
  `{text, Bin}`. macula encodes every map key as CBOR text, and its frame
  decoder turns a key back into an atom only when that atom already exists
  in the receiving VM, so a key can arrive as `{text, Bin}` and `field/2,3`
  returned the default as if the field were absent. The lookup order is
  now the atom form, the binary form, then `{text, Bin}`. Releases that
  boot in embedded mode hid this, because every module a service names is
  loaded, and so every atom exists, before the first call arrives.
- `hecate_om_identity` generates a keypair only when the configured
  `identity_key_path` file is missing (`{error, enoent}`). Any other load
  failure now stops the service with `{identity_key_unloadable, Path,
  Reason}` and leaves the file untouched: a corrupt file, a directory or
  unreadable file at the path, or a key file readable by group or others,
  which the next macula release refuses to load. Before, every load error
  generated a new keypair and saved it over the old file, so the service
  silently came back under a new node id and its real key was gone.

- Documentation. `hecate_om_service`'s module doc never reached the
  generated docs (a module with `-doc` attributes takes its docs from the
  compiler, which ignores edoc comments); it is now a `-moduledoc`, updated
  to the current callbacks. Its callback docs used edoc quoting inside
  markdown and rendered as broken code spans. The read-model services guide
  is now published (the mesh-native services guide already linked to it),
  with its advertisement TTL section corrected to what
  `hecate_om_capabilities` does today, and the README no longer describes
  the removed `templates/` directory. References to private macula
  functions and to functions that do not exist are no longer written as
  links, so `rebar3 ex_doc` builds without warnings.

## [0.24.0] - 2026-09-05

### Fixed

- `hecate_service` scaffold now generates a `.tool-versions` pinning
  `erlang 28.4.2`, matching the OTP major (28) `Containerfile` and
  `lint.yml` already pinned. Without it, a generated repo built on a dev
  machine whose asdf/rebar3 global points at a newer OTP (29) compiles a
  dependency's deprecated bare-`catch` syntax under a version that turns
  it into a hard build failure via `warnings_as_errors` -- unrelated to
  the generated service's own code, and reproducing nowhere the pin is
  honored (CI, the container build, or a machine that has this file).
  Hit the same missing-pin symptom in four repos in one day before
  landing the fix here (reckon-db and evoq, unrelated to this scaffold
  but the same root cause; then two real `hecate_service`-generated
  services, hecate-sentinel and hecate-echo). This repo itself was a
  fifth, having no `.tool-versions` of its own despite depending on the
  same 28-pinned toolchain -- fixed alongside the template.

### Added

- `hecate_om_capabilities:unguarded_capabilities/1` (exported, pure): names
  every capability in a list with no explicit `auth` key -- i.e. every one
  that will silently advertise `open` via `auth_opts/1`'s own default,
  whether that's a real decision or nobody set it yet. `register/1` now
  logs exactly this list, once, whenever a service (re-)registers its
  capabilities -- free, per-boot visibility into fleet-wide `auth` adoption
  for every service that routes through this module. Phase 1 of rolling
  out `{ucan_required, Issuer}` fleet-wide without silently missing a
  service (the concern `PLAN_UCAN_GATED_CAPABILITIES.md`'s own "What's
  open" flagged: adoption is per-service, per-capability, opt-in, with
  nothing catching an omission). 3 new eunit tests.
- `scripts/audit-fleet-ucan-adoption.sh`: the other half of that same
  concern, since the runtime check above can only see what a service's own
  `capabilities/0` reports. A service that calls `macula:advertise/5`,
  `macula_response:advertise_direct/7` or `macula_streamer:advertise_direct/7`
  directly -- bypassing `hecate_om_capabilities:register/1` entirely, the
  pre-migration `hecate-rag` pattern this repo's own history already
  documents fixing for one service -- is advertising something the
  in-process audit never sees at all. This script greps every sibling
  `hecate-services/*` repo's real source (umbrella-app-aware: recursive,
  not a literal top-level `src/` glob, which silently missed every
  umbrella-structured repo the first time this was written) for that
  bypass pattern, excluding test fixtures. Run 2026-09-03 against the real
  fleet: 7 services (`hecate-dns`, `hecate-dronex`, `hecate-embedder`,
  `hecate-git`, `hecate-llm`, `hecate-tom-ocean`, `hecate-tom-world`)
  still advertise at least one capability outside this module's own
  registration path -- flagged for manual review, not fixed here; each
  needs its own migration decision, not a blind sweep.

### Fixed

- The `hecate_service` scaffold's `lint.yml` now installs a Rust toolchain
  before `rebar3 lint`/`eunit`, and its header no longer claims none is
  needed on the glibc image. `macula_cbor_nif` (macula >= 10.14, so every
  service on hecate_om >= 0.20) has no Erlang fallback and refuses to be
  skipped, so a freshly scaffolded service's very first CI run failed in the
  compile hook before a single test ran -- hit by hecate-agora on
  2026-09-02; hecate-stations had already patched its own copy by hand.
  Template-only change, no library code touched.
- The scaffold's `build-push.yml` now carries a per-ref `concurrency` group
  with `cancel-in-progress`, so quick successive pushes to `main` cannot
  race to overwrite `:latest` with whichever build happened to finish last
  (hecate-rag hit that live; hecate-agora nearly did on its first morning).

## [0.23.0] - 2026-09-02

### Added

- `hecate_om_ownership_proof:verify/3` -- proves a caller holds the
  private key for the Ed25519 identity (raw 32-byte pubkey) they claim
  to be asserting on behalf of, inside an otherwise-open mesh payload:
  a signature over `{identity, timestamp, procedure}`, procedure-bound
  so a proof minted for one gated capability can't be replayed against
  another. Extracted after the identical ~40-line verifier was written
  twice independently -- hecate-citizens' `citizen_ownership_proof` and
  hecate-mail's `mailbox_ownership_proof`, each one's own moduledoc
  naming the exact trigger for consolidating: "a third, unrelated
  consumer." hecate-graph needing the same mechanism to make its
  `learn_link` provenance mind-grained (an individual caller's own
  signed identity, not just the wire-level connection identity) is that
  third consumer. A DIFFERENT mechanism from `{ucan_required, Issuer}`
  capability gating (`plans/PLAN_UCAN_GATED_CAPABILITIES.md`): that
  controls who may call a procedure at all; this proves who asserted a
  specific claim inside one. Also exports `message/3` (the exact signed
  byte layout, for a caller building a proof) and `decode_identity/1`/
  `decode_text/1` (the same wire-shape-tolerant unwrap both existing
  consumers already needed). 10 new tests.
- Existing consumers (`hecate-citizens`, `hecate-mail`) keep their own
  local copies for now -- not migrated here, no bug in either, out of
  scope for this extraction. Worth doing later so there's one verifier
  instead of three.

## [0.22.0] - 2026-09-01

### Added

- `hecate_om_wire:caller/1` -- reads the RPC caller's wire-authenticated
  identity out of a decoded payload (`field(caller, Payload)` under one
  well-known name, same reasoning `field/2,3` itself already gives for
  existing as a shared helper). Only populated by macula >= 10.15.0,
  which is the version that first merges `caller` into `Payload` when
  macula's station link handles an inbound call -- on an older macula this
  reads `undefined`, same as any other absent field.

## [0.21.0] - 2026-09-01

### Fixed

- One capability's `advertise_direct` call raising during a republish
  tick used to crash the whole `hecate_om_capabilities` gen_server
  before it could register any other capability in the same batch --
  and, because `macula_response`/`macula_streamer` link each factory
  supervisor they create to whoever calls them (this process), the
  crash killed every OTHER, already-healthy capability's supervisor
  too, turning one transient timeout into an outage for every
  capability this node serves. Found live 2026-09-01 via hecate-rag:
  `hecate_om_capabilities` crashed on a timed-out advertise call for
  `ingest_document` and, minutes later, unrelated capabilities
  (`search_chunks_semantic`/`answer_query`/`add_knowledge`) started
  failing every inbound call with `noproc`. `advertise_one/7` is now
  called through `advertise_one_safely/7`, which catches per-capability
  and logs which one failed and why -- the documented exception to
  this org's let-it-crash default, since the alternative (a single
  opaque supervisor-exit report) erases exactly that distinction along
  with every sibling capability's live registration. A failed
  capability's previous registration is left in place and retried on
  the next ~30s republish tick. See also `macula` 10.14.5, which
  independently hardens the same failure class one layer down
  (`existing_or_new_sup/1` no longer trusts a dead `reuse_sup` pid).

## [0.20.0] - 2026-09-01

### Added

- `hecate_om_wire:unwrap/1` (exported, pure): recursively converts
  `macula_record_cbor`'s wire-level value representation into plain
  Erlang terms -- `{text, Bin}` (CBOR text string, major type 3) to
  `Bin`, `null` to `undefined`, through list elements and map values.

### Fixed

- `hecate_om_wire:field/2,3` returned the wire-level CBOR value
  representation unchanged, not the plain Erlang term a caller's
  `is_binary/1` guard or `:: binary()` field spec actually needs. A
  JSON string sent as an RPC arg is encoded as a CBOR text string,
  which decodes to `{text, binary()}`, not a bare `binary()` -- a
  plain binary is reserved for a CBOR BYTE string (major type 2), a
  different wire type (see `macula_record_cbor`'s own moduledoc for
  the full value() table). Every consumer of `field/2,3` -- this
  module's own fix for the atom/binary KEY hazard notwithstanding --
  was still silently failing every VALUE-shape check on a real mesh
  caller's payload, indistinguishable from a missing field. Found live
  2026-09-01 diagnosing hecate-rag's `get_document_verbatim`: a
  temporary diagnostic log showed the actual payload as
  `#{source_path => {text, <<"...">>}}` -- the key lookup was already
  correct, the value never was. `field/2,3` now runs whatever it finds
  (or the caller's own `Default`) through `unwrap/1` before returning.

## [0.19.0] - 2026-09-01

### Added

- `hecate_om_capabilities:republish_delay_ms/0` (exported, pure): the
  periodic re-advertise tick (`?REPUBLISH_INTERVAL_MS`) now schedules
  itself with +/- 3s of uniform jitter around the nominal 30s instead
  of a perfectly fixed interval.

### Fixed

- A fixed-period republish timer can permanently lose a race against a
  station-side cooldown of the same length: `macula-station`'s
  `macula_remote_advertise_registry` tombstones a re-registration for
  `?TOMBSTONE_TTL_MS` (30s, deliberately bumped from 10s in `ea95857`
  for its own gossip-convergence reasons) whenever it is unregistered,
  and only the same advertiser node-id may re-register during that
  window. Found live 2026-09-01: `hecate-rag`'s `get_document_verbatim`
  capability stayed `unknown_method` for 45+ minutes across roughly 90
  identically-timed retries, while every sibling capability in the same
  advertise batch (registered moments earlier or later, landing just
  outside whatever tombstone it individually raced) self-healed on its
  next tick. Neither side's 30s value was wrong on its own -- the bug
  was the two periods being exactly equal, which gives a losing retry
  no drift to ever land outside the window again. Root cause traced
  through `hecate_om_capabilities`, `macula_response:advertise_direct/7`,
  and `macula_remote_advertise_registry` before landing here: this is
  the one client-side fix that protects against ANY station's cooldown
  period, known or not, rather than tuning to one station's specific
  constant.

## [0.18.0] - 2026-09-01

### Added

- `hecate_om_service:capability()` may now carry `kind => streamer`
  (default `response`) and `stream_opts => #{mode => server_stream |
  client_stream}`. The internal advertise dispatch in
  `hecate_om_capabilities` now sends the two `advertise_direct` calls
  (bare + org-qualified) through `macula_streamer` instead of
  `macula_response` for a streamer-kind capability -- both provider
  modules publish the identical
  `procedure_advertisement` DHT record and read the same `Opts` keys
  (`ttl_ms`, `reuse_sup`, `cert_chain`), so this changes only which
  module gets called. New `provider_module/1` and `stream_opts/1`
  (exported, pure). `call_capability/5,7` (the direct-dial CALL path)
  stays response-only, unchanged -- a streamer capability is consumed
  via `macula_stream_sink:start_link_direct/5,6`, a genuinely different
  client-side API, not a gap in this change.
- Motivated by `hecate-tube`'s `tube_mesh_providers.erl`: three of its
  four hand-rolled `macula_response:advertise_direct` calls migrated
  onto `capabilities/0` when this module already existed (0.17.0's own
  hand-rolled-loop migration story, above, for `hecate-rag`), but the
  fourth (`tube.watch_video_clip`) is `macula_streamer`-backed and had
  nothing to migrate onto until now.

## [0.17.0] - 2026-09-01

### Added

- A capability passed to `hecate_om_capabilities:register/1` may now
  carry `auth => {ucan_required, IssuerPubkey}` (default, and every
  existing caller's behavior: `open`), forwarded through both
  `advertise_direct` calls into `macula:advertise/5` and enforced on
  every inbound call by `macula`'s own `authorize_policy/2`. The
  primitive already existed one layer down (`macula`'s `{ucan_required,
  Issuer}` auth policy); nothing in `hecate_om` used it, so no
  hecate-service could gate a capability without bypassing
  `hecate_om_capabilities` entirely. New `auth_opts/1` (exported, pure).
  This is a direct-signature check against one pre-known issuer, not a
  delegation-chain walk to a realm root -- see
  `plans/PLAN_UCAN_GATED_CAPABILITIES.md` for the full scope and that
  boundary.
- `hecate_om_simple_handler`: bridges a stateless one-arity
  `{Module, Function}` handler (`macula`'s own native calling
  convention) into `macula_response`'s per-request `init/1` +
  `handle_request/2` contract, so a hecate-service migrating a
  capability onto `hecate_om_capabilities:register/1` doesn't need to
  hand-write that pair itself. Unwraps an `{ok, Value}` reply so the
  wire payload matches what the bare `{Module, Function}` path already
  produced -- migrating a capability changes nothing a caller can
  observe. First real user: `hecate-rag`, migrating all 15 of its
  capabilities off a hand-rolled `macula:advertise/5` loop onto this
  path in the same release cycle.

## [0.16.5] - 2026-09-01

### Changed

- Picked up `reckon_db` 5.11.1 (already permitted by this repo's own
  `~> 5.4` constraint; no rebar.config change needed, just a fresh
  resolve + this release marking it verified). Fixes `read_all_global/3`
  re-scanning and re-sorting the ENTIRE store on every paginated call --
  every evoq-based service's catch-up-on-restart replay is affected, not
  just the one (hecate-sentinel) that surfaced it. See reckon_db's own
  CHANGELOG for the full writeup (a secondary index was tried first and
  measured to make it WORSE; fixed with a `global_event_count/1`-
  fingerprinted cache instead -- ~5.6x on a realistic 10k-event catch-up
  burst). 82/82 eunit + 15/15 CT pass against the new version.

## [0.16.4] - 2026-08-31

### Fixed

- `hecate_om_capabilities`: `procedure_uri/3`, `discovery_key/2`, and
  `org_capability_pattern/2` used `binary:encode_hex(Realm)` (lowercase) while
  the live fleet's DHT `procedure_advertisement` records carry uppercase hex.
  Since `SHA-256(uppercase) != SHA-256(lowercase)`, direct-dial resolvers
  looked up the wrong DHT key. Changed all three call sites to
  `binary:encode_hex(Realm, uppercase)`, matching the discovery URI
  `macula_direct_dial` builds (fixed in macula 10.14.4) and
  macula-go/macula-rust/macula-dotnet.

## [0.16.3] - 2026-08-31

### Fixed

- **The actual root cause**, found by deploying 0.16.2's new logging to
  `hecate-stations` (beam03) and reading it: `{ok, no_keypair, ok}` --
  pool and realm were both fine, but no stable signing keypair.
  `identity_key_path` was simply absent from `hecate-stations`' own
  `config/sys.config.src` (and, worse, from the scaffold template every
  service is generated from -- `priv/templates/hecate_service/sys.config.src`,
  fixed here too). Without it, `hecate_om_identity:load_keypair/0` returns
  `undefined` forever (the self-heal, auto-generate-and-persist path only
  fires when a path IS configured but the file at it fails to load), so
  `keypair/0` stays `{error, no_keypair}` permanently, and
  `hecate_om_capabilities:advertise_with/7` no-ops on every republish tick
  by design ("an ephemeral service cannot sign and is correctly not
  advertised"). This is the exact failure mode this module's own comment
  already named as a known recurring issue (hecate-tube hit it before) --
  it just wasn't caught at generation time.
  Both the template and `hecate-stations`' own config now set
  `identity_key_path` to `/etc/hecate/secrets/identity.key`, the same
  already-mounted secrets volume `service_cert_path` uses -- no new
  infrastructure needed. Added `sys_config_configures_a_stable_identity`
  to `hecate_service_template_SUITE` so a future template regeneration
  can't silently drop this again; confirmed RED without the template fix,
  GREEN with it. 82/82 eunit + 15/15 CT pass, dialyzer clean.

## [0.16.2] - 2026-08-31

### Fixed

- **Second silent-failure path in the same area as 0.16.1**:
  `advertise_with/7`'s fallback clause (pool/keypair/realm not all ready)
  had NO logging at all -- worse than 0.16.1's bug, since that one at
  least implies `advertise_direct` got called. This clause's own comment
  assumed a "transient mesh gap" resolved within a few republish ticks;
  a genuinely stuck pool or identity means this clause fires forever,
  silently, with capabilities never advertised and nothing anywhere to
  say why. Deployed 0.16.1 to `hecate-stations` (beam03) specifically to
  observe this in production and found exactly this: 0.16.1's new
  logging never fired at all, and `hecate_stations.list_stations` still
  wasn't in the DHT (confirmed via `macula-cli dht find-records-by-type`)
  -- meaning the failure was happening one level earlier than 0.16.1
  could see.
  Now logs the specific reason for each of pool/keypair/realm
  (`hecate_om_capabilities: advertise skipped, not all of pool/keypair/
  realm are ready yet: {PoolError, KeyPairError, RealmError}`), throttled
  to once per distinct reason triple (a process-dictionary-scoped gate)
  so a persistent boot problem doesn't spam a warning every 30s forever.
  30/30 capabilities tests + 82/82 full suite pass, dialyzer clean.

## [0.16.1] - 2026-08-31

### Fixed

- **Silent advertise failures**: `hecate_om_capabilities:advertised/3`
  discarded `advertise_direct`'s `{error, Reason}` outright, and
  `put_advertisement/2`'s `try ... catch _:_ -> ok end` discarded BOTH a
  plain `{error, _}` return from `macula:put_record/2` (never pattern-matched
  at all, not just the exception guard) and any real exception, all with no
  logging anywhere. Combined with `register/1`'s `handle_call` always
  replying `ok` regardless of what `do_advertise` actually did, a service
  could run "healthy" indefinitely with its capability never actually
  reaching the mesh's DHT and nothing anywhere to indicate why. Also a
  correctness gap against this repo's own CLAUDE.md: a `try/catch` here is
  only justified when it adds monitoring value neither branch did.
  Both paths now `logger:warning/2` the real reason
  (`hecate_om_capabilities: advertise_direct for ~s failed: ~p` /
  `... put_record (record-only advertisement) failed: ~p`). Found live
  investigating why `hecate_stations.list_stations` was unreachable
  through the mesh: confirmed via `macula-cli dht find-records-by-type`
  that its advertisement genuinely never reached the DHT, but nothing in
  the service's own logs said why until this fix — existing tests already
  exercise the failure path and now show a real reason (`no_healthy_station`
  in the test fixture's case) instead of silence. 30/30 existing tests
  still pass.

## [0.16.0] - 2026-08-29

### Fixed

- **Shared-station capability dispatch**: two orgs advertising the same bare
  capability name from the same relay station collided on
  `macula_remote_advertise_registry`'s single-provider-per-bare-name
  invariant — whichever org's 30s republish landed last silently answered
  every targeted `call_capability`, regardless of `Org`. `advertise_one/7`
  now makes two independent `advertise_direct` registrations per
  handler-bearing capability (bare name, plus `Org/Name` as a genuinely
  distinct wire-level registration); `resolve_full/4` tags each resolved
  provider with the wire-level procedure string that actually matched, and
  `call_capability` CALLs with that string, not the raw capability name.
  Live-verified against `station-de-frankfurt.macula.io`.
- `find/2`'s DHT resolution had no retry margin against write-propagation
  lag, unlike `macula_direct_dial`'s own internal resolution — mirrored its
  retry budget (50 x 100ms).
- Advertisements now carry a `ttl_ms` proportioned to the 30s republish
  interval instead of the ~48h envelope default, live effect confirmed
  after bumping the `macula` dependency past the `adv_opts/1` fix below.

### Added

- `list_org_capabilities/1` / `resolve_org_capabilities/3` — browse every
  capability an org has advertised, without knowing any capability name in
  advance. Client-side filter over `macula:find_records_by_type/2`
  (matched via `macula`'s new `macula_topic_pattern`), same local-relay-view,
  warm-start-only semantics `read_model_services.md` already documents for
  that call.

### Changed

- Bumped `macula` dependency 10.10.0 -> 10.13.1: `adv_opts/1` in
  `macula_direct_dial` no longer silently drops `ttl_ms`; `macula_client`'s connection pool no
  longer dials a redundant duplicate connection to a station it already
  holds a live link to under a different seed spelling (was reproducible,
  live, as literally the second `call_station` from one pool to the same
  station); `macula_topic_pattern` and station-local wildcard pubsub
  subscriptions added. See macula's own CHANGELOG [10.11.1]-[10.13.1].

## [0.15.1] - 2026-08-27

### Fixed

- Bumped `macula` dependency 10.0.0 -> 10.10.0. Had drifted 10 releases
  behind the fleet (currently 10.10.0), including the domain-filter fix
  that was silently dropping every `macula_diagnostics:event/2,3` call
  on any consumer of this library (see macula CHANGELOG [10.10.0]).
  Confirmed no use of anything removed in 10.0.0's macula-net deletion;
  full eunit + CT suite clean at the new version.
- `rebar3 dialyzer` failed the release gate with 3 "Callback info about
  the X behaviour is not available" warnings (macula_publisher,
  macula_feeder, macula_download) — confirmed pre-existing at macula
  10.0.0 too, not caused by the bump above. Root cause: `exclude_apps`
  drops `macula` from the PLT entirely (it ships without `debug_info`,
  a NIF-heavy lib, which otherwise hard-fails dialyzer), so the three
  behaviours this module implements have no callback info to check
  against. `no_unknown` doesn't cover this — the warning is tagged
  `?WARN_UNDEFINED_CALLBACK` internally (`dialyzer_behaviours.erl`),
  not `?WARN_UNKNOWN`, and `no_behaviours` (`?WARN_BEHAVIOUR`) is also
  the wrong option, verified against dialyzer 5.4's own source before
  picking `no_undefined_callbacks`. Clean run confirmed on a fully
  fresh PLT.

## [0.15.0] - 2026-08-24

### Added

- `read_model_id/0` optional `hecate_om_service` callback (alongside
  `data_dir/0`): `hecate_om:boot/1` opens a `barrel_docdb` database at
  `<data_dir>/<read_model_id>/` before the service's own `start/1` runs,
  the same shape as the existing `store_id/0` reckon-db wiring but for a
  persistent, queryable read model instead of an event store. New
  `hecate_om_read_model:ensure/2` helper, new `hecate_om:read_model/0`
  facade accessor. `barrel_docdb` is now a hard dependency (same "everyone
  pays, only starts if declared" shape as reckon_db/evoq — note this one
  carries a real native build cost too, rocksdb's C++ library, not a free
  dep). Only `barrel_docdb`, not the full `barrel`/`barrel_vectordb`
  umbrella; a service that wants vector or hybrid search in its read model
  adds that itself. Meant to replace the class of bug where an ETS-backed
  read model silently loses its contents on every restart (see
  hecate-spartan's registry/inbox history) — barrel_docdb reopens from its
  on-disk RocksDB directory, nothing to rebuild.

## [0.14.2] - 2026-08-23

### Fixed

- Self-healed keypairs are now puzzle-hardened (`macula_identity:generate(#{puzzle => true})`),
  mirroring macula-realm's own mesh identity. Every station in this fleet
  enforces S/Kademlia puzzle validation on CONNECT/HELLO; a plain identity's
  handshake completes and is then closed with `puzzle_invalid` — a graceful
  drain, then `drained` — on every single connection, forever. Confirmed
  live: this is the full explanation for why `tube_mesh_providers` could
  report `advertised => true` (its own local, client-side bookkeeping)
  while no station's DHT-facing advertise registry ever actually held the
  advertisement — a ~96-second reject/reconnect loop, invisible until the
  underlying station logged its disconnect reason at all (a separate fix,
  `macula-station` `4188a1d`).

## [0.14.1] - 2026-08-23

### Fixed

- `hecate_om_identity`'s stable keypair now self-heals instead of silently
  staying unconfigured. `load_keypair/0` previously only ever *loaded* from
  `identity_key_path` — a service deployed with the env pointed at a path
  with nothing there yet (the common case: nobody's provisioned it
  out-of-band) got `keypair() -> {error, no_keypair}` forever, every single
  boot, with no error logged anywhere. Confirmed live on hecate-tube: its
  `tube_mesh_providers` retries advertising `tube.watch_video_clip` /
  `tube.lookup_channel` / `tube.lookup_video_clip` every 5s pending both
  `mesh_handles/0` and `keypair/0` — `mesh_handles/0` resolved fine (the
  service peers and calls just fine on an ephemeral identity), `keypair/0`
  never did, so the service silently never advertised any of its three
  direct-dial providers, ever, since its first deployment. No amount of
  local testing catches this — it only surfaces against a real deployment
  that actually tries to be *called*, not just to call out.

  Now: any load failure (missing file — the common case — or a corrupt
  one) generates a fresh keypair via `macula_identity:generate/0` and
  persists it to the configured path via `macula_identity:save/2` (which
  `ensure_dir`s it), same self-provisioning pattern macula-realm's own mesh
  identity already uses. Falls back to `undefined` (ephemeral, prior
  behavior) only if the save itself fails, e.g. a read-only filesystem.
  `identity_key_path` left unconfigured is unaffected — still ephemeral by
  design, unchanged.

## [0.14.0] - 2026-08-22

### Added

- `hecate_om:mesh_handles/0` — the shared `{Pool, Realm}` fetch every
  PubSub/RPC-consumer/Content call needs together, replacing the hand-rolled
  `case {macula_client(), realm()} of {{ok,P},{ok,R}} -> ...` pairing four
  independent hecate-services repos each wrote for themselves because
  hecate_om gave them nothing to build on.
- `hecate_om:realm/0` and `hecate_om:keypair/0` — re-exported on the public
  facade. Both already existed on `hecate_om_identity`; a service previously
  had to reach past the facade to get them. `keypair/0` is needed by every
  direct-dial PROVIDER desk (`macula_response:advertise_direct/6,7`,
  `macula_streamer:advertise_direct/6,7`, ...), which sign their own DHT
  advertisement record with it.

### Changed

- Bumped macula dependency `~> 9.0` → `~> 10.0`. macula 10.0.0 removed the
  dormant macula-net L3 substrate; grepped `src/`/`include/` first —
  hecate-om never called any of it. Verified against a genuine fresh fetch
  off hex (not a local checkout): clean compile, 13/13 eunit.
- Bumped macula dependency to `~> 9.0`, pulling in direct-dial across all
  four SDK primitive pairs (RPC/PubSub/Content/Streaming).
- Slice 7c verify switched to **Direction B** (managed-realm X.509 cert chain),
  replacing the Ed25519 delegation-record chain that could never go live (the realm
  tag is a keyless `SHA-256(name)` and the realm holds no signing key). Requires
  macula `~> 8.7`.
  - Advertise: `hecate_om_capabilities:build_advertisement/6` embeds the service's
    cert chain (leaf ++ org CA) in the `procedure_advertisement`, from
    `hecate_om_identity:cert_chain/0`. Services with no provisioned chain advertise
    without one (open-mode only).
  - Verify: under `verify => true`, providers are kept only if their embedded chain
    verifies to the realm CA (`macula_record:verify_advertisement_cert_chain/3`,
    org-scoped) instead of resolving `org_directory` / `procedure_delegation`
    records. No realm CA provisioned → every provider dropped.
  - `hecate_om_identity` loads the org CA (`org_ca_cert_path`, default
    `/etc/hecate/secrets/org-ca.pem`) and realm CA (`realm_ca_cert_path`, default
    `/etc/hecate/secrets/realm-ca.pem`); exposes `cert_chain/0` and `realm_ca/0`.

### Fixed

- `priv/templates/hecate_service/rebar.config` pinned `{hecate_om, "~> 0.8"}`,
  six major versions stale — every service scaffolded via `rebar3 new
  hecate_service` inherited it. Now `~> 0.13`.

## [0.13.0] - 2026-08-19

### Added

- Slice 7c consumer side + org-namespaced addressing:
  - Capabilities are addressed by `(realm, org, name)`: `procedure_uri/3` and the
    advertisements carry the `<org>` segment. `hecate_om_identity:org/0` reads the
    `org` app env (default `<<"_">>`).
  - `hecate_om:call_capability/4` `(Org, CapName, Payload, Timeout)` and
    `hecate_om_capabilities:call_capability/5` with `Opts`: `verify => true` drops
    providers whose realm → org → server delegation chain does not verify (7c);
    `ucan_token => Bin` presents a token to a gated provider (7b). Default is open
    (no verify, no token).

### Changed

- Requires macula `~> 8.6`, which also FIXES capability publishing. SDK
  `put_record` of a `procedure_advertisement` crashed the station's store handler
  on wire-decoded records before macula 8.6.0 (it had only been exercised via
  direct erpc puts). On this release publishing works end-to-end.

### Note

- The verifying-consumer path (`verify => true`) needs the realm and org to have
  published `org_directory` / `procedure_delegation` records (realm/org
  infrastructure, not the service). Until that exists, use the default open mode;
  the verification mechanism is proven in macula-station's delegation e2e.

## [0.12.0] - 2026-08-19

### Added

- `call_capability/3` in `hecate_om` — call a capability by name over the direct-dial
  data path: resolve a provider from the DHT (`procedure_advertisement`), resolve
  its serving station to a dialable endpoint (`station_endpoint`), dial it directly
  and CALL the raw `CapName` there, failing over to the next provider on error.

### Fixed

- Capability RESOLUTION now works over the real SDK path. On macula 8.2.0-8.4.0 a
  consumer resolving via `find_records/2` got `undefined` fields (the record
  readers did not handle the atomised payload keys the SDK path returns), so
  discovery silently returned no usable providers. macula 8.4.1 fixes the readers.

### Changed

- Requires macula `~> 8.4` (was `~> 8.2`): `call_station` + `station_endpoint`
  readers (8.3.0), TLS-policy forwarding (8.4.0), and the reader atom-key fix
  (8.4.1).

## [0.11.0] - 2026-08-19

### Changed

- **Capability discovery is now DHT record-based, replacing the pubsub
  `_mesh.cap.announce` broadcast.** On capability register (and a 30s republish
  tick) a service writes one signed `procedure_advertisement` per capability to
  the mesh DHT (advertiser = the service's key, serving_station = a connected
  station, procedure_uri = realm-namespaced capability name). `lookup/1` resolves
  by reading those records via `macula:find_records/2`, verifying each signature,
  and returns `{ok, [#{advertiser, serving_station}]}` — a consumer then dials one
  of those stations directly (direct-dial discovery, no multi-hop).
- **Requires macula `~> 8.2`** (was `~> 8.0`): uses `find_records/2`,
  `read_procedure_advertisement/1`, `procedure_key/1` from macula 8.2.0.

### Added

- `hecate_om_identity:keypair/0` — the service's retained stable signing keypair,
  or `{error, no_keypair}` for an ephemeral service (which is then not advertised
  and stays invisible to DHT discovery, by design).

### Removed

- The pubsub `_mesh.cap.announce` publish/subscribe path and `peers/0`. There
  were no callers of the old `lookup/1` summary shape.

## [0.10.0] - 2026-08-13

### Changed

- **Requires macula `~> 8.0`** (was `~> 7.0`). This is the release that lets a
  hecate-om service say WHY it refused.

  macula 8.0.0 stopped answering `{error, {call_error, 16#0F, unknown_error}}`
  when a handler returns `{error, Reason}` and now returns the handler's own
  reason. `0x0F` is the code the SDK stamps when a handler says no, so it never
  meant "unknown error" in practice — it meant a service had refused and could
  not tell you why. Every refusal in the world arrived as the same three words.

  ```erlang
  %% handler
  handle(_) -> {error, <<"hold_full">>}.

  %% caller, on 7.x
  {error, {call_error, 15, unknown_error}}
  %% caller, on 8.x
  {error, <<"hold_full">>}
  ```

  Measured rather than assumed: a two-service torture across two live stations
  with no direct edge fails this on 7.0.0 with exactly the old constant and
  passes on 8.0.0 with the reason intact.

  **Consumer impact.** Nothing in this library matches the old shape — there is
  no `call_error` or `unknown_error` anywhere in `src/`, `priv/` or `test/`. A
  consumer that pattern-matches `{error, {call_error, _, _}}` on a REFUSAL will
  stop matching; one that matches `{error, _}` is unaffected. Transport failures
  keep the `{call_error, Code, Name}` shape, so only the handler-refusal case
  changes.

  ⚠ A binary reason now crosses the wire verbatim; non-binary reasons arrive as
  printed binaries. See macula CHANGELOG 8.0.0.

### Added

- **`store` variable on `rebar3 new hecate_service`, off by default.** Empty
  generates a storeless service exactly as before, which is what most services
  want. `store=1` generates the whole thing at once: `store_id/0` and
  `data_dir/0`, a store named `<name>_store`, the `evoq` adapter block in
  `config/sys.config.src`, a data volume and `HECATE_DATA_DIR` in the compose
  file, and three boundary guards keeping them in step.

  It exists because adding a store by hand is **three** things and not one, and
  omitting the third crash-loops the node before any service code runs. A sibling
  service put two of three fleet nodes into a boot loop by exporting the
  callbacks without adding the `evoq` block, which raises
  `{not_configured, event_store_adapter}` at release boot. The generated README
  says the same thing in both branches, so a service scaffolded without a store
  is told what adding one really costs.

  ⚠ **The value must be exactly one character, so `1` and not `yes`.** rebar3
  passes template variables as strings and mustache iterates a string as a list,
  so a longer value repeats every conditional block once per character. That is a
  limitation of the template engine rather than a preference, it is documented on
  the variable itself, and it fails loudly at the first `rebar3 compile` with
  `spec for store_id/0 already defined` rather than shipping anything.

- **The generated suite now checks that the two OTP pins agree, and that you are
  running what they name.** `rebar3 new hecate_service` has always pinned the
  release in two files, the `Containerfile` and `.github/workflows/lint.yml`, and
  0.9.0's own commit message said they must agree. Nothing enforced it.

  A sibling service shipped with its `Containerfile` on 27 while development ran
  on 28, so a local `rebar3 eunit` meant "passing on 28" and nothing more, CI
  failed for three commits on a crash that does not occur on 28 at all, and
  because the image build is a separate workflow the image reached the fleet
  regardless.

  The generated `*_service_tests.erl` now reads both files and compares them
  against `erlang:system_info(otp_release)`. **It fails rather than warns when
  the running VM differs**, because developing on a release you do not ship makes
  a green suite mean less than it appears to. Moving to another release means
  moving both pins, which is the point of having them.

  No change to `src/`.

### Fixed

- **README no longer claims services never run on user laptops.** It said
  Layer-2 services "run on realm infrastructure nodes ... not on user
  laptops. They are institutions, not user agents", in the opening
  paragraph and again in the layering diagram. That is a deployment
  policy for the realm's own shared services, stated as if it were a
  property of this substrate, and it is the wrong way round: a hecate-om
  service is **edge-first**. It dials out to a `macula-station` over
  QUIC, needs no inbound port and no public address, and reaches its
  peers through the station. Running one on a laptop is the ordinary
  case, not an exception.

  What the sentence was reaching for is the identity rule, which stands
  and is now stated on its own: a service answers with its own
  service-principal credential chaining to a realm root, never as the
  human whose machine it runs on. Placement is a deployment decision;
  identity is not.

  No change to `src/`.

## [0.9.0] - 2026-07-31

No change to `src/`. This release is the scaffold, its guard, and a
documentation pass; consumers of the library itself get the same behaviour
they had on 0.8.0.

### Added

- **`rebar3 new hecate_service`**, a real rebar3 template in `priv/templates`,
  generating a repository that compiles, tests and deploys: the OTP application
  and supervisor, the six-callback service module, a eunit suite asserting the
  contract, a relx release, a `Containerfile`, both CI workflows, an executable
  `scripts/health.sh`, `deploy/docker-compose.yml`, and the usual documentation.
- `scripts/install-templates.sh`, because rebar3 only finds custom templates
  under `~/.config/rebar3/templates` and an empty directory has no dependency to
  carry them there.
- `hecate_service_template_SUITE`, which generates a service for real through
  `rebar3 new` and then compiles it against this library, so the
  `-behaviour(hecate_om_service)` attribute checks all six callbacks. It also
  asserts the file set, that `health.sh` is executable, that no unrendered
  variable survives, and that GitHub Actions expressions are intact.
- `.github/workflows/lint-and-test.yml`. This repository had no CI at all, which
  is how the old templates drifted unnoticed.

### Changed

- **`scripts/scaffold-service.sh` is now a wrapper over the template** and takes
  the service name once, deriving the snake_case application name from the
  kebab-case repository name. It previously rendered a handful of files with sed
  and left you to write `rebar.config`, the `.app.src` and the supervisor by
  hand, so a scaffolded service did not compile.

### Fixed

- The hex package links and the ex_doc `source_url` pointed at Codeberg.
  GitHub has been canonical since 2026-07-26.
- `guides/container_deployment.md` described a deployment that does not exist:
  system-wide Podman Quadlets reconciled by `hecate-gitops`, a
  `hecate-realm-admin` CLI, a loopback-published health port. It referenced
  three template files that no longer exist. Rewritten to describe what the
  generated service actually does, with a closing section naming what is
  intended rather than built.
- `guides/service_anatomy.md` showed a repository layout with `quadlet/`, a
  `manifest.json` and a flat `src/`, none of which the scaffold produces.
- The README's status line claimed v0.5.0.

### Removed

- **The old `templates/` directory.** It had drifted from the estate it was
  meant to serve: a Quadlet unit that nothing on the fleet uses (the beam nodes
  run docker compose under a pull-based reconciler), `TODO` comments in place of
  two callbacks, a store-backed service as the default in a mostly producer-only
  estate, an `identity_spec` claiming two actions and a wildcard resource for a
  service that could exercise none of them, and no test file at all. Nothing
  consumed it: the `hecate-om scaffold` CLI its own README documented was never
  written.

## [0.8.0] - 2026-07-26

### Changed

- **Requires macula `~> 7.0`** (was `~> 6.0`). macula 7.0.0 teaches the
  canonical encoder floats (IEEE 754 binary64, RFC 8949 major type 7), so
  services publish raw float telemetry again and stop scaling to integers to
  get a number past our own codec.

  This is a WIRE change upstream: a peer on macula 6.x finds no clause for
  major 7 and rejects a frame carrying a float. Both ends of any topic that
  will carry floats must be on 7.x, so roll stations and services together
  rather than piecemeal.

  0.7.0 was the stopgap that made the old restriction loud instead of silent.
  This is the release that removes the restriction. See macula CHANGELOG 7.0.0.

## [0.7.0] - 2026-07-26

### Changed

- **Requires macula `~> 6.0`** (was `~> 5.1`). BREAKING for consumers, because
  macula 6.0.0 changed publish behaviour and that passes straight through:
  `macula:publish/4,5` now returns `{error, {unsupported_payload_type, Type,
  Path}}` where it previously returned `ok`, for raw floats, tuples, colliding
  map keys, out-of-range integers and oversized payloads.

  Those publishes were not working before. A float was silently rewritten as a
  six-decimal text string, and an unrepresentable term killed the shared
  peering connection while its sender was told `ok`. Services publishing raw
  floats must scale to integers (micro-units) or send binary strings.

  No wire-format change, so a service on 0.7.0 interoperates with stations and
  peers on older macula; the guard is entirely sender-side.

  See macula CHANGELOG 6.0.0.


## [0.6.0] - 2026-07-14

### Fixed

- `GET /health` is now actually served. `hecate_om_health_handler` defined the
  route but nothing ever mounted it on a listener, so `/health` was dead code
  and every hecate_om service reported unhealthy to Podman/k8s (nothing bound
  `health_port`). `hecate_om_sup` now starts a Cowboy listener on `health_port`,
  dispatching to the handler — gated on a valid `health_port`, so a service that
  wants no HTTP health endpoint simply omits the config. `snapshot/0` already
  calls the registered service's `health/0` live, so a healthy service returns
  200.

### Changed

- `macula` dependency bumped to `~> 5.1` (connect-hang fix).

## [0.5.0] - 2026-07-04

### Added

- Optional `store_integrity/0` service callback. When exported, `hecate_om:boot/1`
  threads its value (`disabled`, or `#{enabled => true, key_source => ...}`) into
  the reckon-db store config, enabling per-store HMAC event tamper-resistance.
  Defaults to `disabled` (backward compatible). `hecate_om_store:ensure/5` +
  `ensure_store/5` accept the integrity config explicitly.

## [0.4.0] - 2026-07-02

### Added
- **Optional `store_mode/0` service callback** — `single` (default) or
  `cluster`. When a service exports it, `hecate_om:boot/1` auto-starts its
  reckon-db store in that mode; `cluster` enables reckon-db discovery + Ra
  clustering so the store spans every node that starts the same `store_id`.
  New `hecate_om_store:ensure/4` + `ensure_store/4` carry the mode; the
  `/2` and `/3` arities keep defaulting to `single` (backward compatible).
  Previously the auto-started store was always `single`, with no override.

## [0.3.4] - 2026-06-24

### Fixed
- **`hecate_om_store:ensure/3` and `ensure_store/3` were not exported** in
  0.3.3, so `hecate_om:boot/1`'s cross-module call crashed with `undef` at
  boot (`{hecate_om_store_failed, ..., undef}`). The store-index wiring added
  in 0.3.3 was therefore dead on arrival. Added both to `-export`.

## [0.3.3] - 2026-06-24

### Added
- **Optional `store_indexes/0` service callback.** When a service exports it
  alongside `store_id/0` + `data_dir/0`, `hecate_om:boot/1` installs the
  returned reckon-db secondary index declarations (e.g. `{payload, Key}`,
  `{payload_hash, [Keys]}`) on the auto-started store. Previously the
  auto-wired store was created with **no** indexes, so a service that also
  declared indexes via its own `start_store` call hit `{already_started}`
  and its declarations were silently dropped — CCC payload indexes never got
  registered. `hecate_om_store:ensure/3` and `ensure_store/3` carry the index
  list; the `/2` arities delegate with `[]`.

### Changed
- Bumped the reckon-db stack pins to the current ecosystem: `reckon_db
  ~> 5.4` (was `~> 2.3` — needed for the `#store_config.indexes` field),
  `evoq ~> 1.21` (was `~> 1.15`), `reckon_evoq ~> 2.6` (was `~> 2.1`).

## [0.3.2] - 2026-06-03

### Added
- **`MACULA_STATION_SEEDS` env override for station seeds.** When set
  (comma-separated station URLs), it takes precedence over the
  `station_seeds` app env in `hecate_om_identity:configured_seeds/0`;
  empty/unset falls back to the app env. Lets one deployed image dial a
  distinct station per instance without a rebuild (e.g. one bot per node,
  one station each), matching the existing seed-via-env convention.

## [0.3.1] - 2026-06-01

### Fixed
- **Mesh connect no longer gated on the service-principal cert.**
  hecate_om_identity:attach_client/1 previously short-circuited to
  `undefined` (never calling macula:connect/2) whenever the cert file was
  absent, leaving every cert-less service permanently `no_client`. The cert
  was a spurious gate: it is never passed to `connect` (the SDK
  auto-generates an ephemeral peering identity for empty opts), only loaded
  and held for `service_cert/0` / the v2 realm-membership swap-in. Connect
  now keys off configured `station_seeds`, not cert presence.
- **Connect is deferred off the init path and retried.** At boot `hecate_om`
  could start before the macula SDK app was fully up; a single inline connect
  raced it and lost. `init/1` now schedules `self() ! connect`, retries every
  `?RECONNECT_MS` until a pool attaches, monitors the pool, and re-attaches
  if it later dies.

### Added
- Optional `identity_key_path` env: when set + loadable, the service peers
  under a stable on-disk macula-native keypair (consistent node id across
  restarts) via `#{identity => KeyPair}`; otherwise the SDK auto-generates an
  ephemeral identity. Identity is for peering, not authorization.

## [0.3.0] - 2026-05-19

### Added
- `hecate_om_store` module: canonical reckon-db + evoq wiring helper.
  Encapsulates `reckon_db_sup:start_store/1` + 30s readiness wait +
  `evoq_store_subscription:start_link/1`. The pattern documented as
  mandatory in `hecate-corpus/skills/ANTIPATTERNS_EVENT_SOURCING.md`
  now lives in one place.
- Optional callbacks on `hecate_om_service`: `store_id/0` and
  `data_dir/0`. When a service module exports both, `hecate_om:boot/1`
  auto-runs the canonical wiring before `ServiceMod:start/1`.
- New template `templates/sys.config.src.tmpl` with the canonical
  reckon_db + evoq blocks.
- `scripts/scaffold-service.sh` now renders `config/sys.config.src`
  alongside the service modules.

### Changed
- `_service.erl.tmpl` includes the optional `store_id/0` + `data_dir/0`
  callbacks by default; producer-only services remove both.
- `rebar.config` adds reckon_db, evoq, reckon_evoq as deps so services
  using `hecate_om` get the store-wiring stack for free. Producer-only
  services inherit the image-size cost but not the runtime cost
  (nothing starts unless the service module declares `store_id/0`).

### Why
Each new CMD/PRJ service was rediscovering the canonical reckon-db
wiring (or, more often, missing pieces of it). The parksim trio
shipped without `{evoq, [{event_store_adapter, ...}]}` and without
any `reckon_db_sup:start_store/1` call, leaving evoq in default
in-memory mode despite being configured as event-sourced. This
release moves the pattern into the library so future services pick
it up just by exporting two callbacks.

## [0.2.0]

### Added
- Initial scaffold: `hecate_om_service` behaviour, helpers for
  identity claim, capability advertise, and `/health` endpoint.
- Templates for `Containerfile`, Quadlet unit, `manifest.json`, and
  CI workflow.
- Guides: service anatomy, identity model, container deployment.

### Planned
- UCAN-delegated identity wiring once `hecate-realm` issues service
  principals
- Common Test framework helpers for service test suites

## [0.1.0] - YYYY-MM-DD

_Not yet released._
