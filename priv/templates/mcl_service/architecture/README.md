{{=<% %>=}}# <%repo%> architecture: C4 model

*This exists so a reader can see what <%repo%> talks to, and what it is made of,
without reading it.*

**Status: scaffold.** The service boots, joins the
mesh and answers `/health`; it advertises no capability and asks the realm for no
authority, because it can do nothing yet. The model below is the model of that
state, and it grows with the service.

## Level 1: system context

![<%repo%> system context](../assets/c4-context.svg)

| Element | Kind | Role |
| --- | --- | --- |
| <%repo%> | In scope | <%desc%>. One OTP release in one container, an `mcl_om` mesh service on its own box |
| Service operator | Person | Runs the box and deploys the release, and holds the node's identity key file |
| macula-realm | Macula infrastructure | Endorses the node's identity and decides who may offer what |
| macula stations, mesh DHT | Macula infrastructure | The service dials out to two pinned stations; nothing dials in. What the service publishes lands in the DHT |
| What it serves | External | Nothing yet: a scaffold advertises no capability |

## Level 2: containers and components

![<%repo%> components](../assets/c4-components.svg)

| Component | Technology | Responsibility |
| --- | --- | --- |
| `<%name%>_service` | Erlang, the `mcl_om_service` behaviour | The six callbacks `mcl_om` boots: what this service is, and nothing else |
| `mcl_om` | library | `boot/1`: opens the pool, joins the mesh, announces the boot claim, serves `/health` |
| macula SDK | library | The QUIC pool, pubsub, RPC and the DHT |
| Identity key | named volume, `/etc/mcl/secrets` | The node id the realm endorses; it never leaves the box |

## Drawing them

`assets/c4-context.svg` and `assets/c4-components.svg` are the two diagrams. The
front page shows the context one, and this file shows both; a diagram is a model
only if a reader can reach it.

They are drawn from the code, never from this page: the routes in `Containerfile`,
the callbacks in `<%name%>_service.erl`, the dependencies in `rebar.config`, the
volumes in `deploy/docker-compose.yml`. When one of those changes, the diagram
changes in the same commit. Two rules for the files themselves, so they render
everywhere they are read (GitHub, an IDE, `rsvg-convert`):

- self-contained SVG;
- literal colours in plain classes plus a `prefers-color-scheme` dark block, never
  CSS custom properties, which `rsvg-convert` renders black.

<%#c4%>
The check that keeps them here is the `c4-model` job in
`.github/workflows/build-push.yml`. It is red until both files exist and are
shown, and it stays red if either one goes missing.
<%/c4%>
A worked reference, generator included, is the fovea service's own `assets/` and
`architecture/` directory, in the same organisation as this repository.
