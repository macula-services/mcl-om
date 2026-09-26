# mcl-om

**Over-mesh substrate for the PQ fleet**: the shared library every
`macula-services/mcl-X` service daemon stands on, built on macula 12
(`{macula, "~> 12.0"}`), post-quantum only. The `mcl-*` services it carries
replace the obsolete `hecate-*` services one port at a time.

Services in this org are **edge-first**. A service runs wherever its
operator puts it (a cooperative infrastructure node, a relay box, a lab
machine, a laptop) and **dials out** to a `macula-station` over QUIC. It
needs no inbound port, no public address and nothing underneath it: the
station it dials is what puts it on the mesh, and that is how a service
on one edge box reaches a service on another.

Placement is therefore a deployment decision, not a property of the
substrate. What a service always carries with it is its own
**node identity**: a puzzle-hardened pq_hybrid node key whose node id
derives from the carried public key. It answers as itself, never as the
human whose machine it happens to be running on. See
[`guides/identity_model.md`](guides/identity_model.md) for the
town/library metaphor that drives the identity choices.

```
                         mcl-om
                            │
        ┌──────────┬────────┼─────────┐
        ▼          ▼        ▼         ▼
    mcl-echo  mcl-warden mcl-sentinel …
```

Every service is a separate OTP release shipped as an OCI container
to `ghcr.io/macula-services/`. `mcl-om` is the library they all
link against to behave consistently on the mesh: the same service
contract, the same health endpoint, the same identity-claim flow, the
same capability-advertise pattern, and the same generated repository
(Containerfile, compose file, CI workflows).

## What this library is (and isn't)

It **is**:

- An Erlang `behaviour` (`mcl_om_service`) — six callbacks every
  service implements: `start/1`, `stop/1`, `health/0`, `capabilities/0`,
  `identity_spec/0`, `info/0`.
- Helpers for the bits every service needs: load (or generate) the
  puzzle-hardened node key, advertise a capability on the mesh as a signed
  DHT record (callable when it carries a handler), serve a `/health`
  endpoint.
- The `mcl_service` rebar3 template for a new service repository:
  application, supervisor, service module with its eunit suite, release
  config, `Containerfile`, `compose.yml`, `health.sh` and both CI
  workflows. See [Scaffold a new service](#scaffold-a-new-service).

It **is not**:

- A daemon. It has no `application:start_phase` of its own beyond
  the library's facade.
- A plugin host. Services are containerised.
- A network library. Services talk to a PQ `macula-station` via the
  macula 12 SDK like any other Macula client: **outbound only**. The
  station does the peering, the DHT and the routing, which is what
  lets a service sit behind NAT at the edge and still be reachable.

## Layering position

```
Layer 4 — apps        user-facing apps

Layer 3 — session     per-identity sessions and UI

Layer 2 — services    macula-services/mcl-echo, -warden, -sentinel, …
                      Always-on, containerised, system-class workloads,
                      each with its own node identity.
                      Run at the edge or on realm infrastructure; either
                      way they dial out to a station.
                      ↑↑↑ this library is the substrate ↑↑↑

Layer 1 — identity    macula-realm

Layer 0 — kernel      macula-station (the PQ fleet)
```

See [`philosophy/HECATE_TIER_MODEL.md`](https://github.com/hecate-social/hecate-corpus/blob/main/philosophy/HECATE_TIER_MODEL.md)
in hecate-corpus for the longer cut-criteria discussion. Note that the
tier model still phrases the L2 placement rule absolutely ("NOT on user
laptops"); read that as a policy about where the realm's own shared
services belong, not as a limit on what an mcl-om service can do.

**Service ≠ provider.** A node that serves a procedure is not thereby a
service: every SDK lets a client serve procedures (`pool.Serve` in
macula-go, say). A *service* is a node under this contract — always-on,
containerised, a claimed identity answering `Org/info` and `/health`,
advertised capabilities, and placement through macula-fleet. For mesh
services the org runs BEAM only, and this library is the substrate; for
mesh clients the SDKs are enough. A daemon written in another stack
that wants onto the fleet under this contract is ported to
Erlang/mcl-om, or runs outside the fleet's responsibility.

## The contract

```erlang
-module(my_service).
-behaviour(mcl_om_service).

%% lifecycle
-export([start/1, stop/1]).

%% introspection
-export([health/0, capabilities/0, identity_spec/0, info/0]).

start(_Opts) ->
    my_service_sup:start_link().

stop(_State) ->
    ok.

%% Reported on /health endpoint. Return ok | {degraded, Reason} | {down, Reason}.
health() ->
    ok.

%% Advertised onto the mesh via mcl_om_capabilities:advertise/1.
%% Other services / plugins find you by these.
capabilities() ->
    [
        #{name => <<"my_service.do_thing">>, version => 1},
        #{name => <<"my_service.list_things">>, version => 1}
    ].

%% The authority this service asks the realm for, and deliberately nothing
%% more. Ask for exactly the topics you publish and subscribe to.
identity_spec() ->
    #{
        scope     => <<"my_service">>,
        actions   => [<<"publish_summary">>, <<"answer_query">>],
        resources => [<<"my_service/*">>],
        ttl_days  => 30
    }.

info() ->
    #{
        name        => <<"mcl-my-service">>,
        version     => <<"0.1.0">>,
        description => <<"What this service does in one line">>
    }.
```

That's the whole user-side contract. Six small functions. Health
endpoint wiring and mesh advertisement come from `mcl-om`; the
release, container image, compose file and CI workflows come from the
`mcl_service` template described below.

On the wire every procedure is `Org/Name`, with the org from mcl_om's `org`
app env; a service without a usable org refuses to boot. What every service
gets without writing it:

- **`Org/info`**, open to any mesh caller: name, version, description, the
  claim labels (`service_name`, `box`), org, node id, macula and mcl_om
  versions, uptime, the health word (`ok`, `degraded`, `down`, `unknown`, from
  the verdict /health last computed, never a fresh probe) and the procedures
  it advertises. No environment, paths, keys or reasons. It is also what makes
  a publish-only service count as online on the realm's Providers desk. A
  service may not declare its own `info`.
- **`handler_timeout_ms`** on a capability, 1 to 600000: how long macula waits
  for the handler before answering the caller `temporary_relay_failure`
  (default 30000). Response capabilities only.
- **`failed_publishes`** on /health: publishes whose publisher exited before
  resolving. `mcl_om_pubsub` runs each publisher under a watcher, so such an
  exit is counted and logged instead of killing the process that published.

## Optional: store-backed services

CMD/PRJ services that own a `reckon-db` event store export three more
**optional** callbacks. When a service exports `store_id/0` + `data_dir/0`,
`mcl_om:boot/1` auto-starts the store and its evoq subscription *before*
`start/1` runs — you never call `reckon_db_sup:start_store/1` yourself.
Producer-only services (no store) omit these and pay nothing.

```erlang
%% Optional store-wiring callbacks (only if the service owns a store)
-export([store_id/0, data_dir/0, store_indexes/0]).

%% Atom store id. Data lands at <data_dir>/<store_id>/.
store_id() -> my_service_store.

data_dir() -> "/var/lib/mcl-my-service".

%% reckon-db secondary index declarations installed on the store. This is
%% how CCC payload indexes get declared — without it the store starts with
%% no secondary indexes and payload/hash queries find nothing.
store_indexes() ->
    [tags, event_type,
     {payload, <<"plate">>},                            %% single-field index
     {payload_hash, [<<"lot_id">>, <<"plate">>]}].      %% composite hash index
```

`store_indexes/0` is itself optional: export it only when the store needs
secondary indexes. Omit it (or return `[]`) for a store with none.

## Scaffold a new service

```bash
# From the directory that will hold the new repository,
# typically ~/work/github.com/macula-services:
scripts/scaffold-service.sh mcl-newservice "Does X over the mesh" 8484
```

That is a thin wrapper over `rebar3 new mcl_service`, and it exists so you
**say the name once**. A service has two names: the repository, the container
image and the name it answers to on the mesh are kebab-case, while the OTP
application and every module prefix are snake_case because they are Erlang
atoms. Mustache has no functions, so a template cannot derive one from the
other. The generated eunit suite asserts the two agree modulo the separator, so
a hand-rolled `rebar3 new` with a mismatched pair still fails on its first test
run.

To use `rebar3 new` directly, install the templates once. rebar3 only finds
custom templates under `~/.config/rebar3/templates`, and an empty directory has
no dependencies to carry them there:

```bash
scripts/install-templates.sh          # symlinks; --remove to undo
rebar3 new mcl_service repo=mcl-newservice name=mcl_newservice \
    desc="Does X over the mesh" org=your-org registry=ghcr.io health_port=8484
```

**The scaffold is not house-specific.** `org` and `registry` are variables, and
nothing generated names our organisation, our registry, our deployment
repository or our hosts. If you are building a service for your own mesh,
set those two and everything else follows. `scaffold-service.sh` defaults them
to ours because that is who runs it most; `MCL_ORG` and `MCL_REGISTRY`
override. A test generates a service as a stranger and fails if any of our own
specifics survive.

Generates a repository that compiles, tests and deploys:

- `apps/<app>/src/` — the `.app.src`, `_app.erl`, `_sup.erl` and a
  `_service.erl` implementing the behaviour
- `apps/<app>/test/` — a suite asserting the contract's shape, the two names,
  and that the reported version is the application's own
- `rebar.config` with a relx release, the prod profile and the elvis ruleset
- `config/sys.config.src` and `config/vm.args.src`
- `Containerfile` (multi-stage, macula's QUIC NIF built from source)
- `deploy/docker-compose.yml` — the service's own run contract, **not** the
  deployed file; fleet placement lives in `macula-io/macula-fleet`. It mounts a named
  volume, `<repo>-secrets`, at `/etc/mcl/secrets`, where the service's identity
  key lives, so the node id survives a container recreate
- `.github/workflows/` — `lint` and `build-push` to ghcr.io
- `scripts/health.sh`, executable
- `README.md`, `CHANGELOG.md`, `LICENSE`, `.gitignore`

**It emits no TODO and no stub.** What it generates is honestly complete and
empty: the supervisor has no children, and the service announces no capability
and requests no authority. Those are the correct answers for a service that does
nothing yet, and each is asserted by a generated test, so filling one in is a
deliberate act that breaks a test rather than a comment someone forgets.

The templates are exercised by `mcl_service_template_SUITE`, which generates
a service for real and compiles it. The suite exists because the previous
templates drifted unnoticed for months, and a template with no test is
documentation that compiles.

One thing it cannot do for you, and it has bitten: the registry package may be
created **private**, and the pull then fails on the host with a bare
`unauthorized` that names nothing. Check it after the first build.

### Deploying on the BEAM Campus fleet

Ours, and deliberately not part of the scaffold. `deploy/docker-compose.yml` in
a generated service carries what the service knows about itself;
`macula-io/macula-fleet` carries **placement**: which box, which station pins,
which realm key, which secret file. The boxes pull it; nothing is pushed to them.

**How a box runs its services.** Each box has macula-fleet checked out at
`~/gitops/macula-fleet`. The `hecate-reconcile` systemd `--user` timer runs
`edge/gitops/reconcile.sh` every 2 minutes: it fast-forwards the checkout and
runs `docker compose up -d` for every row of `edge/<box>/reconcile.manifest`.
Who updates images is set per box in `edge/<box>/reconcile.options`. The
default is watchtower, which polls every 60 s and rolls any container labelled
`com.centurylinklabs.watchtower.enable=true` onto a new `:latest`; the
reconciler then applies config only.

**To put a new service on a box:**

1. Add `edge/scripts/docker-compose.<service>.yml` to macula-fleet: the image,
   `network_mode: host`, the named identity volume at `/etc/mcl/secrets`, the
   watchtower label, and the environment the service reads.
2. Add a row to `edge/<box>/reconcile.manifest`:
   `<project> <compose> <config-env|-> <secret-file|-> <prep|->`. Public per-box
   configuration, such as `MCL_REALM_KEY` (the realm's public key), goes in a
   committed `edge/<box>/<service>-config.env`.
3. Seed the secrets once, on the box, at `~/.hecate/secrets/<name>.env`, 0600,
   never committed (`MCL_COOKIE`, for one). A row whose secret file is missing
   starts nothing: the reconciler logs `[reconcile] FAILED: <project>`, and only
   `journalctl --user -u hecate-reconcile` shows it.
4. Push macula-fleet. The box picks it up on its next tick, within 2 minutes.

Health ports bound on beam00 today: 8450, 8461 (mcl-echo), 8484, 8494. Host
networking turns a collision into a silent bind failure.

## Status

**Working library — 0.31.x, on macula 12.7.** The behaviour and all helpers are implemented
(`mcl_om_identity`, `mcl_om_capabilities`, `mcl_om_store`,
`mcl_om_health`), the boot path (`mcl_om:boot/1` with auto store-wiring)
is exercised by a Common Test suite (`mcl_om_SUITE`), and `rebar3 new
mcl_service` generates a service that compiles, tests and deploys, guarded
by a suite that generates one for real. `mcl_om:mesh_handles/0` gives every
service the shared `{Pool, Realm}` pair its own PubSub/RPC/Content code needs,
alongside `realm/0` and `identity_key/0` on the same public facade.
Lint, EUnit and the Common Test suites run on every pull request and every
push to main.

The behaviour surface has grown since the first cut: the store-wiring
callbacks are `store_id/0` + `data_dir/0` (required together) plus optional
`store_indexes/0` (CCC secondary indexes), `store_mode/0` (`single` | `cluster`),
and `store_integrity/0` (per-store HMAC event tamper-resistance). See the
[CHANGELOG](CHANGELOG.md) for the evolution.

Known gap: the store-wiring callbacks are the part of the contract with no test
of their own. `mcl_om_SUITE` boots a producer-only dummy service.

Consumers: the `macula-services/mcl-*` services, `mcl-echo` deployed on the
fleet. Not yet burned in under sustained production load.

## License

Apache-2.0. See [LICENSE](LICENSE).
