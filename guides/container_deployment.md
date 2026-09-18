# Container deployment

An mcl service ships as an OCI image and runs on an infrastructure
node. This guide describes how that actually works today, and says
plainly where something is intended rather than built.

`rebar3 new mcl_service` generates the `Containerfile`, both CI
workflows and a `deploy/docker-compose.yml` that runs the service. The
registry and organisation are template variables: nothing here is
specific to the fleet the authors happen to run.

## What runs where

Services run **for a realm, on realm infrastructure**. A user's laptop
is a citizen rather than an institution: it consults services across
the mesh and does not host them.

## The image

Two stages, both in the generated `Containerfile`.

The builder is `erlang:28-alpine` and installs a Rust toolchain,
because macula ships a QUIC NIF. `MACULA_FORCE_SOURCE_BUILD=1` makes it
compile that NIF here rather than fetch a prebuilt one, which would be
linked against a different libc: the fetched artifact loads on the
build host and then fails on alpine at runtime.

Dependencies are fetched from `rebar.config` alone, before the source
is copied, so editing `apps/` does not re-run the Rust build.

The runtime stage is `alpine:3.22` with the assembled release, an
embedded ERTS, and a `HEALTHCHECK` that hits `/health`.

`LABEL org.opencontainers.image.source` links the package to its
repository. On registries that read it, ghcr among them, a package
without that label is an orphan: it does not appear on the repository
page and does not inherit its visibility. A service that shipped
private by accident failed its first pull with a bare `unauthorized`,
which names nothing and sends you looking in the wrong place.

## CI publish

`.github/workflows/build-push.yml` triggers on pushes to `main`,
publishing `:latest`, and on `vX.Y.Z` tags, publishing `:X.Y.Z`. Both
tags are pushed every time, so `:latest` can drive zero-touch updates
while the semver tags remain for pinning.

One trap when pushing that file itself: an **HTTPS** push that creates
or updates anything under `.github/workflows/` needs a token carrying
the `workflow` scope, and the error names the file rather than the
missing scope. Use an SSH remote and it does not arise.

## Running it

`deploy/docker-compose.yml` in a generated service is runnable as-is:

```bash
MCL_REALM=<64-hex> \
  MACULA_STATION_SEEDS=station.example:4433 \
  MACULA_STATION_NODE_IDS=<64-hex node id of that station> \
  docker compose -p mcl-x -f deploy/docker-compose.yml up -d
```

Two things in it are deliberate and worth keeping.

**Host networking.** macula stations are reachable over IPv6 only, and
a default docker bridge has no IPv6, so a bridged container connects
and then sits there with no healthy links, looking fine. If you do want
a bridge, give it IPv6 explicitly. The cost of host networking is that a
port already bound on the host fails **silently**, so choose the health
port knowing what else runs there.

**The realm has no default.** A service that guesses its realm
announces itself where nobody can attribute it, which is
indistinguishable from a healthy node. Same for the station pins:
naming a realm costs nothing, dialling somebody's production station
from every dev clone does — and the 11.x dial is **pinned**: every
seed host pairs with its station's node id (D5), and mcl_om refuses
to boot a pool holding an unpinned seed, since that dial could never
connect anyway.

## Separating the service from its placement

The compose file above carries what the **service** knows about itself:
its image, its port, the environment variables its own code reads, its
health check.

Whatever you deploy with should carry **placement**: which host, which
station, which realm, which secret store. Keeping the two apart is what
stops a configuration table in a README and the real environment
drifting apart with nothing checking them.

The beam fleet does this with **watchtower**: CI pushes `:latest` to
ghcr.io, watchtower on each node polls and rolls the container within
seconds of the push, and a rollback is pinning the node to a semver
tag. Secrets are seeded once out of band on the node. That is one
arrangement, not a requirement of mcl_om.

## Secrets

`sys.config.src` expects the node identity key at
`/etc/mcl/secrets/identity.key`, and the `Containerfile` declares that
path as a volume. How the file gets there is the deployment's
business. A missing key file is not an error: `mcl_om_identity`
generates a fresh puzzle-hardened key and persists it there on first
boot.

The realm tag arrives as `MCL_REALM` and is translated into
application environment by `sys.config.src`. That translation is the
only place the shell variable and the application environment meet:
`mcl_om_identity:realm/0` reads `application:get_env(mcl_om,
realm)`, so exporting the shell variable and expecting that to be
enough has cost a service an hour of confusion.

## Rollback

Pin the image to a semver tag instead of `:latest` and redeploy. Both
tags are published by every CI run precisely so this works.

## Not built yet

Stated so nothing here reads as describing a working system.

`identity_spec/0` is informational today: the realm-side provisioning
that would enforce it is not wired. The enforcement that DOES exist on
the 11.x wire is the D25 authorization (the org_directory +
procedure_delegation chain a station checks against the realm's trust
records) and the per-capability `auth` policies. See
`identity_model.md`.

Images are built for `linux/amd64` only. Add `linux/arm64` to the
build matrix when the first arm64 node joins.
