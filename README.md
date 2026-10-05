# mcl-om

**Over-mesh substrate for the PQ fleet**: the shared library every
`macula-services/mcl-X` service daemon stands on, built on macula 12
(`{macula, "~> 12.0"}`), post-quantum only.

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

See [`philosophy/TIER_MODEL.md`](https://github.com/macula-services/mcl-corpus/blob/main/philosophy/TIER_MODEL.md)
in mcl-corpus for the longer cut-criteria discussion.

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
- **`confidential`** on a capability (0.34.0, macula 13's provider modes): how
  its calls must be protected on the wire. `off` names no KEM key (the
  procedure stays keyless even with `kem_advertise` enabled); `preferred`
  names one when macula's `kem_advertise` is enabled, so callers seal;
  `required` also refuses a clear call and needs `kem_advertise` enabled
  (`{macula, [{kem_advertise, enabled}]}` in sys.config). Absent, nothing
  changes (macula reads it as `preferred`). Response and streamer capabilities
  alike. A service refuses to boot, naming the capability and the setting, on
  any other value, on a `kem_advertise` that is not `enabled`/`disabled`, and on
  `required` without `kem_advertise` enabled, instead of running green and
  unreachable.
- **`failed_publishes`** on /health: publishes whose publisher exited before
  resolving. `mcl_om_pubsub` runs each publisher under a watcher, so such an
  exit is counted and logged instead of killing the process that published.

## Persistence is the service's own

`mcl_om` opens no store and starts no `reckon_db`, `evoq` or `reckon_evoq`
application (0.35.0, mcl-om#10): it is the basis for on-mesh services, and each
service chooses its own persistence. An event-sourced service declares those
three in its own `rebar.config` and app.src and opens its store in its
application's `start/2`, before `mcl_om:boot/1`, so projections and process
managers find it up when `start/1` runs. `rebar3 new mcl_service store=1`
generates exactly that: the deps, the wiring in `<name>_app` (start the store,
wait until reckon-db lists it, start the per-store evoq subscription), the
store's id, directory, indexes, mode and integrity in
`<name>_service:event_store/0`, and the `evoq` adapter block in
`config/sys.config.src`.

A service module that still exports the old `store_id/0` and `data_dir/0`
callbacks together boots WITHOUT a store, and `mcl_om:boot/1` logs a warning
(`mcl_om_no_longer_opens_a_store`) naming them and the way out. So a service that
opens its own store must not export those two names from its service module.

## Scaffold a new service

```bash
# From the directory that will hold the new repository,
# typically ~/work/github.com/macula-services:
MCL_VISIBILITY=private scripts/scaffold-service.sh mcl-newservice "Does X over the mesh" 8484
```

**`MCL_VISIBILITY` is asked, never assumed**: `private` or `public`, and the
script refuses anything else before it generates a file. It decides three
things that must agree:

| | `private` | `public` |
|---|---|---|
| `LICENSE`, app.src `licenses`, README | proprietary notice, `["Proprietary"]` | Apache-2.0 |
| CI runner (`runs-on`) | the org's own, `["self-hosted", "msi00", "pq"]`, in macula-services and macula-internal; GitHub's elsewhere | GitHub's, `["ubuntu-latest"]`; a self-hosted runner is refused |
| `gh repo create` in the closing text | `--private` | `--public` |

A public repository never runs on a self-hosted runner, because a pull request
from anyone would run its code on that machine. `MCL_RUNS_ON` overrides the
runner and `MCL_HOLDER` the copyright holder.

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

**The scaffold is not house-specific.** `org`, `registry`, `builder_image`,
`runtime_image`, `holder`, `proprietary` and `runs_on` are variables, and
nothing generated names our organisation, our registry, our images, our
copyright holder, our runners, our deployment repository or our hosts. If you
are building a service for your own mesh, set the first five and everything
else follows (`proprietary` is empty for Apache-2.0, `1` for a proprietary
notice; `runs_on` is a JSON array and defaults to `["ubuntu-latest"]`). In the house orgs (macula-services, macula-internal, macula-io) `attest` is set, so every image the service pushes is signed by digest, with its SBOM and provenance attested, by macula-ci-images' `attest-image.yml` pinned by commit. `scaffold-service.sh` defaults
them to ours because that is who runs it most; `MCL_ORG`, `MCL_REGISTRY`,
`MCL_BUILDER_IMAGE`, `MCL_RUNTIME_IMAGE`, `MCL_HOLDER` and `MCL_RUNS_ON`
override, and `MCL_VISIBILITY` sets `proprietary`. A test generates a service as a stranger and
fails if any of our own specifics survive.

**The image pair.** `builder_image` is the image the release is built in and
the one the generated lint job runs in; `runtime_image` is the one it runs on.
Both are pinned by digest, and they are a pair: a release built in one runs on
the other's libc and OpenSSL, so `scaffold-service.sh` refuses to override
just one. The defaults are the current plain pair from
`macula-io/macula-ci-images`, the one build (20260928-1800) that republished
every download against a pinned checksum. Services move onto it as they
release; until then some still build on the previous pair (20260923-1444), and
the services with a rocksdb read model (mcl-stations, mcl-mail, mcl-rag) use
the rocksdb pair.

| Variable | Default | Must carry |
|----------|---------|------------|
| `builder_image` | `ghcr.io/macula-io/macula-ci-otp:20260928-1800@sha256:7318a443…` | OTP 28.4.3 with an OpenSSL that has ML-DSA, rebar3, Rust, a C toolchain, git |
| `runtime_image` | `ghcr.io/macula-io/macula-pq-runtime:20260928-1800@sha256:a1d18c6a…` | the builder's libc, OpenSSL with ML-DSA, libstdc++, ncurses, curl |

They are named once, as the defaults in `priv/templates/mcl_service.template`;
the script passes an image only when one is overridden, and the template suite
reads them from there. The generated `Containerfile` refuses to build on any
OTP but 28.4.3 with `mldsa87`, and the generated lint job checks every tool in
the table before it checks out the code. A service that links the erlang
`rocksdb` binding (barrel_docdb) moves both lines to the rocksdb pair,
`macula-ci-otp-rocksdb` and `macula-pq-runtime-rocksdb`. On the plain pair
rocksdb's CMake silently disables any compression backend whose `-dev` package
is missing, the build stays green, and barrel's default snappy blob
compression then fails at `db_open` ("The specified blob compression type
Snappy is not available").

Generates a repository that compiles, tests and deploys:

- `apps/<app>/src/` — the `.app.src`, `_app.erl`, `_sup.erl` and a
  `_service.erl` implementing the behaviour
- `apps/<app>/test/` — a suite asserting the contract's shape, the two names,
  and that the reported version is the application's own
- `rebar.config` with a relx release, the prod profile and the elvis ruleset
- `config/sys.config.src` and `config/vm.args.src`. The sys.config sets
  `{mesh, required}`: the service refuses to boot without `MCL_REALM`,
  `MCL_REALM_KEY`, `MACULA_STATION_SEEDS` and `MACULA_STATION_NODE_IDS`,
  naming every one that is missing, instead of booting green with no mesh
- `Containerfile`: built in `builder_image`, run on `runtime_image`
- `deploy/docker-compose.yml` — the service's own run contract, **not** the
  deployed file; fleet placement lives in `macula-io/macula-fleet`. It mounts a named
  volume, `<repo>-secrets`, at `/etc/mcl/secrets`, where the service's identity
  key lives, so the node id survives a container recreate
- `.github/workflows/`: `lint` (in `builder_image`) and `build-push` to
  `registry`
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
(`mcl_om_identity`, `mcl_om_capabilities`, `mcl_om_health`), the boot path
(`mcl_om:boot/1`)
is exercised by a Common Test suite (`mcl_om_SUITE`), and `rebar3 new
mcl_service` generates a service that compiles, tests and deploys, guarded
by a suite that generates one for real. `mcl_om:mesh_handles/0` gives every
service the shared `{Pool, Realm}` pair its own PubSub/RPC/Content code needs,
alongside `realm/0` and `identity_key/0` on the same public facade.
Lint, EUnit and the Common Test suites run on every pull request and every
push to main.

Persistence left mcl_om in two steps: the read model in 0.27.0, the event store
in 0.35.0. See the [CHANGELOG](CHANGELOG.md).

Consumers: the `macula-services/mcl-*` services, `mcl-echo` deployed on the
fleet. Not yet burned in under sustained load.

## License

Apache-2.0. See [LICENSE](LICENSE).
