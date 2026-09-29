# mcl_om without a store (mcl-om#10)

This exists so an mcl-* service starts only the persistence it chose, and so mcl_om is the basis
for on-mesh services and nothing more.

**Kind:** BUILD. **Status:** step 1 (mcl_om 0.35.0) built 2026-09-29, untagged until step 5.
**Decision (Raf, mcl-om#10):** mcl_om neither depends on nor starts reckon_db, evoq or
reckon_evoq; the `store_id/0`-gated store start goes; event-sourced services declare those deps
themselves. mcl_om ships it as a minor, with a CHANGELOG entry naming the move.

## What mcl_om does today (origin/main 4594844, 0.34.0)

- `src/mcl_om.app.src` lists `reckon_db`, `evoq`, `reckon_evoq` as hard `applications`, so every
  service boots khepri, ra, reckon_db, reckon_gater, evoq and reckon_evoq, store or not.
- `mcl_om_service` declares the optional callbacks `store_id/0`, `data_dir/0`, `store_mode/0`.
- `mcl_om:boot/1` (mcl_om.erl:119) calls `mcl_om_store:ensure/…` when they are exported:
  `reckon_db_sup:start_store/1`, wait, `evoq_store_subscription:start_link/1` (148 lines).
- The mcl_service template: the STORE option generates `store_id/0`, `data_dir/0`, the evoq block
  in sys.config.src and two tests; the storeless app.erl and rebar.config comments describe it.

## Consumers (fetched origin/main of all 27 non-archived mcl-* repos, Erlang, Elixir and Gleam)

**Export `store_id/0`, so mcl_om starts their store today (8):**

| Service | store_id in | Declares itself today | Missing |
|---|---|---|---|
| mcl-bookclub | mcl_bookclub_service.erl | rebar: reckon_db, evoq, reckon_evoq | store start |
| mcl-bookclub-gleam | service.gleam, internal/evoq.gleam | gleam.toml: evoq, reckon_evoq | reckon_db; store start |
| mcl-bookclub-phoenix | service.ex | mix: reckon_db (root), evoq, reckon_evoq | store start |
| mcl-mail | mcl_mail_service.erl | rebar: evoq; app.src: all three | rebar: reckon_db, reckon_evoq; store start |
| mcl-sentinel | mcl_sentinel_service.erl | rebar: evoq | reckon_db, reckon_evoq; store start |
| mcl-tube | mcl_tube_service.erl | rebar: evoq, reckon_evoq | reckon_db; store start |
| mcl-victron | mcl_victron_service.erl | rebar: all three | store start |
| mcl-whiteboard | service.ex | mix: reckon_db (root), evoq | reckon_evoq; store start |

**Use evoq or reckon-* without exporting store_id (verify at build: each must declare what it
starts, since mcl_om will no longer bring it in):** mcl-bookclub-observer (rebar: evoq),
mcl-graph (rebar: reckon_evoq), mcl-rag (app.src: all three; rebar: evoq only; Neptunus says it
has no store, so it likely drops them instead).

**Storeless (15), no code change:** mcl-citizens, mcl-echo, mcl-embedder, mcl-fovea, mcl-mpong,
mcl-news, mcl-nvidia-pair, mcl-search, mcl-stations, mcl-turn-credentials, mcl-warden, mcl-embed,
mcl-testkit, mcl-fovea-assessments, mcl-fovea-fleet. Their generated comments and READMEs say
"export store_id/0 and mcl_om starts the store"; each is corrected when it next moves its floor,
not in a sweep of its own.

## Where the store wiring goes: DECIDED (B)

Raf, 2026-09-29: **each of the 8 event-sourced services carries its own copy** of the store
wiring (`mcl_om_store`: start the reckon-db store, wait for it, start its evoq subscription), with
its tests, and declares reckon_db, evoq and reckon_evoq itself. No shared library: each service
owns its persistence. (Rejected: a small reckon-db-org library; the dependency rules keep the
wiring out of reckon_evoq and reckon_db either way.)

## Order (each step its own range, Mercurius reads, Raf's yes)

Revised 2026-09-29 (Supervisor, approved): consumers FIRST, the tag last, so no consumer is ever
exposed. `~> 0.N` in hex means `< 1.0.0`, so 9 of the 11 store-using consumers would float onto
0.35.0 at their next build (only mcl-mail and mcl-rag, `~> 0.33.1`, are held).

1. mcl_om 0.35.0 lands on main (e72fbb5), NOT tagged: nothing is published, no consumer sees it.
2. mcl-bookclub-observer and mcl-graph first: they use evoq/reckon_evoq without a store, so they
   declare what they use and nothing more.
3. The 8 store owners, one range each: declare reckon_db, evoq and reckon_evoq; open the store in
   their own start/2 before `mcl_om:boot/1` (their own copy of the wiring, with its tests); set the
   constraint to `">= 0.34.0 and < 0.36.0"`, gated green on 0.34, where boot's own store ensure
   then finds the store up (both are idempotent), so they are ready for 0.35 by construction. The
   deployed ones (the bookclubs, mcl-mail, mcl-tube) get their fleet repin as its own step.
4. mcl-rag settled by what its code starts.
5. Tag mcl_om v0.35.0 only when no consumer floats onto it unmigrated (checked on fetched
   origin/main of each, in the tag ask).

## Done when

Every service boots the applications it declares and no others (checked per release with
`application:which_applications/0` in the gate), the 8 consumers open their stores as before,
and mcl_om 0.35.0 on hex carries no reckon-db or evoq dependency.
