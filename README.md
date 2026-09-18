# mcl-om

**Hecate-over-mesh**: the shared substrate every `hecate-services/hecate-X`
service daemon stands on.

Services in this org are **edge-first**. A service runs wherever its
operator puts it (a cooperative infrastructure node, a relay box, a lab
machine, a laptop) and **dials out** to a `macula-station` over QUIC. It
needs no inbound port, no public address and nothing underneath it: the
station it dials is what puts it on the mesh, and that is how a service
on one edge box reaches a service on another.

Placement is therefore a deployment decision, not a property of the
substrate. What a service always carries with it is its own
**service-principal identity**. It answers as itself, chaining to a realm
root, never as the human whose machine it happens to be running on. See
[`guides/identity_model.md`](guides/identity_model.md) for the
town/library metaphor that drives the identity choices.

```
                        hecate-om
                            │
        ┌──────────┬────────┼─────────┬──────────┬─────────┐
        ▼          ▼        ▼         ▼          ▼         ▼
   hecate-rag  hecate-llm hecate-dns hecate-git hecate-blob …
```

Every service is a separate OTP release shipped as an OCI container
to `ghcr.io/hecate-services/`. `hecate-om` is the library they all
link against to behave consistently on the mesh: the same service
contract, the same health endpoint, the same identity-claim flow, the
same capability-advertise pattern, and the same generated repository
(Containerfile, compose file, CI workflows).

## What this library is (and isn't)

It **is**:

- An Erlang `behaviour` (`hecate_om_service`) — six callbacks every
  service implements: `start/1`, `stop/1`, `health/0`, `capabilities/0`,
  `identity_spec/0`, `info/0`.
- Helpers for the bits every service needs: load the realm cert,
  advertise a capability on the mesh as a signed DHT record (callable
  when it carries a handler), serve a `/health` endpoint.
- The `hecate_service` rebar3 template for a new service repository:
  application, supervisor, service module with its eunit suite, release
  config, `Containerfile`, `compose.yml`, `health.sh` and both CI
  workflows. See [Scaffold a new service](#scaffold-a-new-service).

It **is not**:

- A daemon. It has no `application:start_phase` of its own beyond
  the library's facade.
- A plugin host. Services are containerised. Plugins live in
  `hecate-daemon` (different repo, different model).
- A network library. Services talk to `macula-station` via the
  macula SDK like any other Macula client: **outbound only**. The
  station does the peering, the DHT and the routing, which is what
  lets a service sit behind NAT at the edge and still be reachable.

## Layering position

```
Layer 4 — apps        hecate-app-martha, hecate-app-rag (UI), …
                      User-facing plugins, live in hecate-daemon

Layer 3 — session     hecate-daemon
                      Per-identity, plugin host, UI surface

Layer 2 — services    hecate-services/hecate-rag, -llm, -dns, -git, …
                      Always-on, containerised, system-class workloads,
                      each with its own service-principal identity.
                      Run at the edge or on realm infrastructure; either
                      way they dial out to a station.
                      ↑↑↑ this library is the substrate ↑↑↑

Layer 1 — identity    hecate-realm / macula-realm

Layer 0 — kernel      macula-station
```

See [`philosophy/HECATE_TIER_MODEL.md`](https://github.com/hecate-social/hecate-corpus/blob/main/philosophy/HECATE_TIER_MODEL.md)
in hecate-corpus for the longer cut-criteria discussion. Note that the
tier model still phrases the L2 placement rule absolutely ("NOT on user
laptops"); read that as a policy about where the realm's own shared
services belong, not as a limit on what a hecate-om service can do.

## The contract

```erlang
-module(my_service).
-behaviour(hecate_om_service).

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

%% Advertised onto the mesh via hecate_om_capabilities:advertise/1.
%% Other services / plugins find you by these.
capabilities() ->
    [
        #{name => <<"my_service.do_thing">>, version => 1},
        #{name => <<"my_service.list_things">>, version => 1}
    ].

%% Tells hecate-realm what UCAN this service needs.
identity_spec() ->
    #{
        scope     => <<"my_service">>,
        actions   => [<<"publish_summary">>, <<"answer_query">>],
        resources => [<<"my_service/*">>],
        ttl_days  => 30
    }.

info() ->
    #{
        name        => <<"hecate-my-service">>,
        version     => <<"0.1.0">>,
        description => <<"What this service does in one line">>
    }.
```

That's the whole user-side contract. Six small functions. Health
endpoint wiring and mesh advertisement come from `hecate-om`; the
release, container image, compose file and CI workflows come from the
`hecate_service` template described below.

## Optional: store-backed services

CMD/PRJ services that own a `reckon-db` event store export three more
**optional** callbacks. When a service exports `store_id/0` + `data_dir/0`,
`hecate_om:boot/1` auto-starts the store and its evoq subscription *before*
`start/1` runs — you never call `reckon_db_sup:start_store/1` yourself.
Producer-only services (no store) omit these and pay nothing.

```erlang
%% Optional store-wiring callbacks (only if the service owns a store)
-export([store_id/0, data_dir/0, store_indexes/0]).

%% Atom store id. Data lands at <data_dir>/<store_id>/.
store_id() -> my_service_store.

data_dir() -> "/var/lib/hecate-my-service".

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

> Requires `hecate_om >= 0.3.4`. (0.3.3 introduced the callback but failed
> to export the helper it calls, crashing boot — use 0.3.4+.)

## Scaffold a new service

```bash
# From the directory that will hold the new repository,
# typically ~/work/github.com/hecate-services:
scripts/scaffold-service.sh hecate-newservice "Does X over the mesh" 8484
```

That is a thin wrapper over `rebar3 new hecate_service`, and it exists so you
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
rebar3 new hecate_service repo=hecate-newservice name=hecate_newservice \
    desc="Does X over the mesh" org=your-org registry=ghcr.io health_port=8484
```

**The scaffold is not house-specific.** `org` and `registry` are variables, and
nothing generated names our organisation, our registry, our deployment
repository or our hosts. If you are building a hecate service for your own mesh,
set those two and everything else follows. `scaffold-service.sh` defaults them
to ours because that is who runs it most; `HECATE_ORG` and `HECATE_REGISTRY`
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
  deployed file; fleet placement lives in `macula-demo`
- `.github/workflows/` — `lint-and-test` and `build-push` to ghcr.io
- `scripts/health.sh`, executable
- `README.md`, `CHANGELOG.md`, `LICENSE`, `.gitignore`

**It emits no TODO and no stub.** What it generates is honestly complete and
empty: the supervisor has no children, and the service announces no capability
and requests no authority. Those are the correct answers for a service that does
nothing yet, and each is asserted by a generated test, so filling one in is a
deliberate act that breaks a test rather than a comment someone forgets.

The templates are exercised by `hecate_service_template_SUITE`, which generates
a service for real and compiles it. The suite exists because the previous
templates drifted unnoticed for months, and a template with no test is
documentation that compiles.

One thing it cannot do for you, and it has bitten: the registry package may be
created **private**, and the pull then fails on the host with a bare
`unauthorized` that names nothing. Check it after the first build.

### Deploying on the BEAM Campus fleet

Ours, and deliberately not part of the scaffold. `deploy/docker-compose.yml` in
a generated service carries what the service knows about itself; the fleet's
GitOps state lives in `macula-demo` and carries **placement**.

1. Add a compose file under `macula-demo/infrastructure/scripts/` with the node,
   the station seed, the realm, the secret file and the compose project name.
2. Add a line to that node's `reconcile.manifest`.
3. Seed the node's secret at `~/.hecate/secrets/`, 0600. A manifest entry
   without it is a silent no-op that looks exactly like a successful deploy.

Health ports already bound across the fleet: 8450, 8471, 8481, 8482, 8483. Host
networking makes a collision a silent bind failure.

## Status

**Working library — v0.14.2.** The behaviour and all helpers are implemented
(`hecate_om_identity`, `hecate_om_capabilities`, `hecate_om_store`,
`hecate_om_health`), the boot path (`hecate_om:boot/1` with auto store-wiring)
is exercised by a Common Test suite (`hecate_om_SUITE`), and `rebar3 new
hecate_service` generates a service that compiles, tests and deploys, guarded
by a suite that generates one for real. `hecate_om:mesh_handles/0` gives every
service the shared `{Pool, Realm}` pair its own PubSub/RPC/Content code needs,
alongside `realm/0` and `keypair/0` on the same public facade.

The behaviour surface has grown since the first cut: the store-wiring
callbacks are `store_id/0` + `data_dir/0` (required together) plus optional
`store_indexes/0` (CCC secondary indexes), `store_mode/0` (`single` | `cluster`),
and `store_integrity/0` (per-store HMAC event tamper-resistance). See the
[CHANGELOG](CHANGELOG.md) for the evolution.

Known gap: the store-wiring callbacks are the part of the contract with no test
of their own. `hecate_om_SUITE` boots a producer-only dummy service.

First consumers are onboarding: `hecate-services/hecate-spartan` links against
the store-wiring path, and `hecate-services/hecate-rag` follows when the RAG
daemon is extracted from `hecate-app-rag`. Not yet burned in under sustained
production load.

## License

Apache-2.0. See [LICENSE](LICENSE).
