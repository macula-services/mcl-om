{{=<% %>=}}# <%repo%>

**<%desc%>**

## Status: scaffold

The service boots, joins the mesh and answers `/health` on <%health_port%>. It
does nothing else yet.

It announces no capability and asks the realm for no authority, because it can do
nothing yet. Both lists grow when the thing they name exists. Advertising a
capability before it exists puts a lie on the mesh where another service can find
it and call it.

## Running it

    rebar3 compile
    rebar3 eunit
    rebar3 lint

    scripts/health.sh                      # against a running node

The image builds in one pinned image and runs on another, a pair named by
digest in the two `FROM` lines of the `Containerfile`. The builder carries the
whole toolchain (OTP 28.4.3 with ML-DSA, rebar3, Rust for macula's NIFs), so
building needs nothing on the host but podman or docker. CI lints and tests in
that same builder image, and the service's tests fail if the two drift apart.

    podman build -t <%repo%> -f Containerfile .

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `MCL_REALM` | required | 64-hex realm tag, the `sha256` of the realm's name. No default: a service that guesses its realm announces itself where nobody can attribute it. |
| `MCL_REALM_KEY` | required | The realm's public signing key, hex encoded: the **trust anchor**, not an identifier. Every org-namespaced advertisement is verified against it, so without it nothing resolves, the boot claim never reaches the realm, and the service stays green while unreachable. Public material, not a secret. |
| `MACULA_STATION_SEEDS` | required | Station hosts to dial, `host[:port]`, comma-separated. No default: naming a realm costs nothing, dialling somebody else's live station from every dev clone does. |
| `MACULA_STATION_NODE_IDS` | required | The matching 64-hex station node ids, comma-separated, index-paired with the seeds. The dial is pinned (D5): mcl_om refuses to boot a pool with an unpinned seed. |
| `MCL_SERVICE_NAME` | `<%repo%>` | Label on the boot claim the realm's operator sees. Falls back to the service's own name. |
| `MCL_BOX` | empty | Label naming the host, also on the boot claim. Set it where you deploy. |
| `MCL_HEALTH_PORT` | `<%health_port%>` | Health endpoint. Host networking makes a collision a silent bind failure, so check the host before changing.  |
| `MCL_NODE_NAME` | `<%name%>` | Erlang node name. |
| `MCL_NODE_HOST` | `127.0.0.1` | Erlang node host. |
| `MCL_COOKIE` | `<%name%>` | Erlang cookie. |

`deploy/docker-compose.yml` runs it, and carries what the service knows about
itself. If you deploy through something else, let that carry **placement**: which
host, which station, which realm, which secret store. Keeping the two apart is
what stops a config table in a README and the real environment drifting.

## Deployment

The image has two channels. A push to `main` publishes
`<%registry%>/<%org%>/<%repo%>:latest`, the deploy channel: a host that follows
`:latest` deploys every merge. A `v*` tag publishes its own version and nothing
else, the rollback archive: pin a host to one to roll back. A push that changes
only documentation builds no image (`scripts/is_image_push.sh`).

The service's org, the `<org>` in every procedure it offers (`<org>/<name>`), is
this repository's name, fixed in `config/sys.config.src`. The realm's grant names
it; without an org mcl_om advertises nothing.

Two things CI cannot do for you, both of which have bitten:

1. The registry package may be created **private**, and the pull then fails on
   the host with a bare `unauthorized` that names nothing. Check it after the
   first build. On ghcr the `org.opencontainers.image.source` label in the
   Containerfile is what links the package to the repository.
2. The host needs `MCL_REALM` and the pinned station pair supplied from
   somewhere they are not committed.

## The service contract

Six callbacks in `<%name%>_service`, all required, all resolved **by name** by
`mcl_om` at startup on a live node. The `-behaviour(mcl_om_service)`
attribute turns a missing one into a compile error rather than an `undef` where
nobody is watching, and the eunit suite guards the attribute itself.

mcl_om adds one capability of its own to every service: `<%repo%>/info`, open to
any mesh caller, answering the service's name, version, labels, health word and
advertised procedures. It needs no code here, and this service may not declare
a capability named `info`.

<%#store%>### The store

This service was scaffolded with `store=1`, so it owns a `reckon-db` store called
`<%name%>_store`. Persistence is the service's own: `mcl_om` opens no store and
starts no reckon-db or evoq application. This service declares `reckon_db`, `evoq`
and `reckon_evoq` in `rebar.config` and its app.src, and `<%name%>_app` opens the
store and its evoq subscription in `start/2`, before `mcl_om:boot/1`, from what
`<%name%>_service:event_store/0` says (id, directory, indexes, mode, integrity).
`config/sys.config.src` carries the `evoq`
adapter block the subscription requires.

⚠ **The store id is written in two places**, `event_store/0` and the `evoq` block,
and nothing makes them agree by itself. A generated test compares them, along
with a second one asserting the `evoq` block is present at all. Keep both.

⚠ **`deploy/docker-compose.yml` mounts a volume, and on a node it must.** Without
it the record lives inside the container and every recreate destroys it, which is
the same as not keeping one.

The store is node-local. To make it span every node running the same store id,
set its `mode` to `cluster`, and reckon-db forms a Ra cluster across them.

⚠ **Not `store_id/0` and `data_dir/0`.** Those were mcl_om callbacks before 0.35;
a service module exporting both is taken for one built on the old contract, and
mcl_om warns about it at every boot.
<%/store%><%^store%>### Adding a store later

This service has no `reckon-db` store, which is the right answer for most, and
runs no reckon-db or evoq application: `mcl_om` brings none.

The cheapest way to get one is to scaffold again with `store=1` and compare. It is
four things, not one, and a missing one crash-loops the node or loses the record:
declare `reckon_db`, `evoq` and `reckon_evoq` in `rebar.config` and the app.src;
open the store in the application's `start/2` before `mcl_om:boot/1` (the
generated `<name>_app` shows how); add the `evoq` adapter block to
`config/sys.config.src`, without which the subscription raises
`{not_configured, event_store_adapter}`; and mount a volume in the compose file.
<%/store%>

## Licence

<%#proprietary%>Proprietary. All rights reserved; see [LICENSE](LICENSE).<%/proprietary%><%^proprietary%>Apache-2.0.<%/proprietary%>
