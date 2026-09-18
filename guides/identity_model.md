# Identity model

## The picture in plain language

Think of the **realm** as a small town.

- **Citizens** of the town are users. Each carries a citizen ID. The
  town clerk (macula-realm) mints these IDs.
- The town also has **institutions**: the library, the post office,
  the water utility. Each institution has its own **staff badge**.
  The library doesn't borrow Alice's citizen ID to lend her a book —
  it acts as *"the library, on behalf of the town"*.
- Citizens and institutions are both legitimate town members, but
  they have **different kinds of identity**:
  - Citizens are mortal, mobile, and present an ID when they want to
    do something personal.
  - Institutions are persistent, fixed, and act for the town.
- If Alice leaves town for a month, the library keeps lending books.
  If a librarian retires, the library hires another — the badge
  stays with the building, not the person.

An mcl service (`mcl-echo`, `mcl-warden`, `mcl-sentinel`, …) is an
**institution**. It has its own **node key** and its authority comes
from the realm's published trust records, not from a borrowed citizen
identity. It runs on infrastructure the realm owns (the beam cluster,
the lab box) — never on a citizen's personal laptop.

## The 11.x identity: a node key, not a certificate

The 10.x model — an Ed25519 keypair plus a realm-signed service
certificate chain — is gone with the 11.x wire. In its place, every
service (and every station, and every pool) holds a **node key**:

- **pq_hybrid**: ML-DSA-87 plus an RSA-PSS composite, so signatures
  stay safe against both classical and quantum adversaries.
- **purpose `identity`**: the purpose a node uses to BE a node.
- **node id**: the SHA-256 digest of the key's carried public half.
  A node id earns no trust on its own — a verifier relies on it only
  after a signature by the same carried key has verified.
- **puzzle-hardened**: the id's first `puzzle_difficulty` bits are
  zero. Every PQ station refuses a CONNECT/HELLO from an identity
  whose id does not meet the fleet's difficulty (8), so an
  unhardened key is a dial that can never connect.

`mcl_om_identity` owns the key for a service:

- `identity_key_path` names the on-disk key file (the deploy mounts
  it at `/etc/mcl/secrets/identity.key`). Missing on first boot, the
  key is **generated and persisted** — no out-of-band provisioning
  step. Any OTHER load failure (a corrupt file, a directory, a
  permissions mistake) stops the service rather than silently
  replacing the key and changing the service's node id.
- Unconfigured, the pool runs on an ephemeral SDK identity: it can
  peer and call, but cannot sign records, so it is (correctly)
  invisible to DHT discovery.

## Where authority comes from: D25, not a cert chain

The 10.x certificate chain proved "signed by the realm, scoped to
this service". The 11.x wire replaces that with **D25
authorization**:

- A realm's key travels in its `foundation_realm_trust_list` DHT
  record. A pool pins the keys it trusts at connect, one per realm
  id (`realm_trust`).
- For an org's procedures, the realm publishes an `org_directory`
  record (the org's key) and `procedure_delegation` records naming
  which advertiser node may speak for the org.
- An org-namespaced `procedure_advertisement` verifies through that
  chain: the advertisement's signer is named by a delegation, the
  delegation chains to the org key, the org key is pinned by the
  realm's trust list. A service that RESOLVES org-namespaced
  capabilities pins the realm keys; one that only publishes does not
  need to.

## What citizens (users) do

Citizens **call** services through the mesh. Alice's agent issues an
RPC that resolves the service's advertisement and calls it directly.
The service answers as itself; authorization at the call boundary is
the station's job — a capability may be `open`, gated to one exact
issuer (`{ucan_required, Issuer}`), or gated to a realm membership
tier (`{realm_member_required, RealmDid, RequiredCan}`).

Authorisation has **two sides**:

1. The **caller's** credential proves they're allowed to ask the
   question.
2. The **service's** registration proves it's allowed to answer for
   the realm — its advertisement chains to a delegation the realm
   published.

Neither side borrows the other's identity.

## The service's declared scope

When a service's `identity_spec/0` returns:

```erlang
identity_spec() ->
    #{
        scope     => <<"mcl-echo">>,
        actions   => [],
        resources => [],
        ttl_days  => 30
    }.
```

it's telling the realm *"this is the namespace I act under, and
nothing more"*. A service that does nothing yet declares no actions
and no resources — the generated scaffold ships exactly this and a
generated test fails when it grows, so asking for authority is a
deliberate act.

## Every dial is pinned

The 11.x peering layer refuses a client dial that does not name the
station it expects (`expected_node_id`, D5) — the CONNECT/HELLO
handshake closes anything else. `mcl_om_identity` therefore refuses a
seed without a matching pin at boot: `MACULA_STATION_SEEDS` pairs
index-for-index with `MACULA_STATION_NODE_IDS`, and an unpinned seed
would be a dial that can never connect.
