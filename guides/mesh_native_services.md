# How to write mesh-native services with hecate-om

A "mesh-native" service is one that talks to other services over the
mesh — connects, calls, publishes, subscribes, moves bytes — without
hand-rolling any of the plumbing macula already gives you.

If you only need the boot lifecycle (`mcl_om_service`, capability
declaration, store/read-model wiring), see
[`service_anatomy.md`](service_anatomy.md) first — this guide assumes
you already have a booting service and want it to actually talk to the
mesh.

**Status as of this writing (2026-08-25):** everything below is on
`main`, not yet in a tagged release. See
`../plans/PLAN_HECATE_OM_MESH_WRAPPERS.md` for the full design history
and evidence behind each piece, referenced below as piece A/B/C/D/E/F/G/H.

`mcl_om` does not reimplement mesh I/O. Every wrapper below is a
thin resolve-your-handles-then-call-the-real-thing layer over macula's
own **supervised** primitives — `macula_publisher`, `macula_subscriber`,
`macula_response`, `macula_feeder`/`macula_download` — not raw
synchronous calls (`macula:publish/4`, `macula:call/5`, ...). That
distinction is why you get things a hand-rolled `catch
macula:publish(...)` never gave you: cancellable in-flight operations,
automatic reconnect-survival, and (for publish) free
`pubsub.publish_started_v1`/`_completed_v1` mesh facts.

**Two layers, not one.** macula (the SDK) wraps its own raw wire
protocol into those supervised OTP behaviours — that work is macula's,
already done, for every primitive mentioned in this guide, streaming
and file-push included. `mcl_om` wraps a *second* time, on top of
some of those, resolving this service's own pool/realm automatically
so you don't repeat that boilerplate. Only some primitives have that
second layer yet — chapters 4 and 5 below are explicit about which.

## Chapter 1: How to connect to the mesh

There is nothing to call to "connect." A service configured with
station seeds (see `service_anatomy.md`'s `sys.config.src` section)
connects automatically at boot: `mcl_om_sup` starts the mesh pool
as an ordinary supervised child (piece A) alongside your service's own
supervision tree. If the pool process ever dies unexpectedly, OTP
restarts it — no code anywhere reacts to a crash, because nothing
needs to. A station being temporarily unreachable doesn't crash
anything either: each seed dials and retries forever on its own timer,
invisibly, whether or not any station ever answers.

What you actually interact with is **`mcl_om:mesh_handles/0`** —
the pool + realm pair every wrapper in this guide resolves internally
before doing real work:

```erlang
-spec mesh_handles() -> {ok, pool(), Realm :: binary()} | {error, mesh_unavailable}.
```

You will rarely call this directly — every function in chapters 2–5
resolves it for you and degrades the same way if this service isn't
attached to a pool or has no realm configured yet: `{error,
mesh_unavailable}`, never a raise. If you ever find yourself writing
`case {mcl_om:macula_client(), mcl_om:realm()} of {{ok,_},
{ok,_}} -> ... ; _ -> ok end` by hand, stop — that pairing already
exists, and reaching for it yourself means duplicating boilerplate ~20
services in this workspace independently wrote before it did.

The individual accessors underneath (`macula_client/0`, `realm/0`,
`identity_key/0`, and `mcl_om_identity`'s `org/0`) never raise either,
even if called before this service's identity subsystem has started —
they return `{error, not_booted}` (piece H) rather than the `noproc`
exit three independent services used to hand-roll a try/catch around.
In practice you shouldn't need to know this; it matters only if you're
reaching past the facade into `mcl_om_identity` directly.

## Chapter 2: How to call functions over the mesh (RPC)

### Serving a call (piece B)

Add `handler => {HandlerModule, Args}` to a capability in your
`capabilities/0` callback. `HandlerModule` implements
`-behaviour(macula_response)`:

```erlang
%% my_x_service.erl
capabilities() ->
    [#{name => <<"my_x.echo">>, version => 1,
       handler => {my_x_echo_handler, []}}].
```

```erlang
%% my_x_echo_handler.erl
-module(my_x_echo_handler).
-behaviour(macula_response).
-export([init/1, handle_request/2]).

init(_Args) -> {ok, []}.

handle_request(Payload, State) ->
    {reply, #{echo => Payload}, State}.
```

`mcl_om:boot/1` registers this into `mcl_om_capabilities`, which
advertises it via `macula_response:advertise_direct/7` — the one call
that both registers the handler with the pool *and* publishes the
signed `procedure_advertisement` DHT record naming your serving
station, so it's discoverable **and** callable. Re-advertised every
30s; a station's wire-level registration is tied to the connection
that sent it and doesn't survive that connection being replaced, so a
single advertise-at-boot isn't enough (`hecate-tube` hit this live
before `advertise_direct` existed).

A capability with no `handler` key still gets the legacy
discoverable-but-not-callable path — for a capability another
mechanism serves.

### Calling another service's RPC (pre-existing, piece B's consumer side)

```erlang
mcl_om:call_capability(Org, <<"my_x.echo">>, #{ping => <<"pong">>},
                          5_000).
%% => {ok, #{echo := #{ping := <<"pong">>}}}
```

This resolves the provider from the DHT and dials its serving station
directly (`macula:call_station/7` under the hood, not pool-routed
`macula:call/5`), failing over to the next provider on error. Pass
`Opts` (via `mcl_om_capabilities:call_capability/5,7`) for
`ucan_token` (present a capability token to a gated provider). The
10.x `verify => true` cert-chain mode is gone with the cert
authorization form: in 11.x the trust check is the D25 authorization
(the pool verifies the advertisement chain against its pinned
`realm_trust` keys) plus the pinned `expected_node_id` dial.

### Payload keys, and whether to retry (pieces F and G)

**Reply/args keys arrive as atoms, not binaries.** macula's frame
decoder round-trips a payload's keys through
`binary_to_existing_atom/1`. Use `mcl_om_wire:field/2,3` instead of
pattern-matching binary keys directly — it tries the atom form first,
falls back to binary, and takes an optional default:

```erlang
handle_request(Payload, State) ->
    Text = mcl_om_wire:field(text, Payload),
    Kind = mcl_om_wire:field(<<"kind">>, Payload, <<"raw">>),
    ...
```

**Deciding whether a failed call is worth retrying**:
`mcl_om_wire:retryable/1` asks macula's own published BOLT#4 retry
policy (`macula_bolt4:is_retryable/1`) rather than you keeping a
hand-copied code table that rots the moment BOLT#4 grows a code:

```erlang
case mcl_om:call_capability(Org, CapName, Payload, 5_000) of
    {ok, Reply} -> handle(Reply);
    Failure ->
        case mcl_om_wire:retryable(Failure) of
            true  -> schedule_retry();
            false -> give_up()
        end
end.
```

## Chapter 3: How to do Pub/Sub over the mesh

### Publishing (piece C)

```erlang
mcl_om_pubsub:publish(<<"my_x.thing_happened">>, #{id => Id}).
%% => ok  (fire-and-forget, default mode)
```

Three outcome-handling modes via `Opts`:

| Mode | Behavior |
|---|---|
| `async_silent` (default) | Starts the publish, returns `ok` immediately, discards the outcome. |
| `async_log` | Same, but logs a warning if the publish failed. |
| `sync` | Blocks until the publish resolves (or `Opts`'s `timeout`, default 5000ms) and returns the real outcome. |

```erlang
mcl_om_pubsub:publish(Topic, Payload, #{mode => sync, timeout => 2_000}).
mcl_om_pubsub:publish(Topic, Payload, #{realm => OtherRealm}).  %% dual-realm publish
mcl_om_pubsub:publish_many([TopicA, TopicB], Payload).          %% one fact, N topics
```

`realm` lets you publish on a realm other than this service's own —
a real, deployed pattern (a fleet realm for internal plumbing, a
separate business/public realm for the facts themselves, off the same
pool).

### Subscribing (piece D)

Declare the desired set in your service module's optional
`subscriptions/0` callback — `mcl_om:boot/1` wires each one into a
supervised `macula_subscriber` before your own `start/1` runs:

```erlang
%% my_x_service.erl
subscriptions() ->
    [{<<"other.thing_happened">>, my_x_event_handler, []}].
```

```erlang
%% my_x_event_handler.erl
-module(my_x_event_handler).
-behaviour(macula_subscriber).
-export([init/1, handle_event/4]).

init(Args) -> {ok, Args}.

handle_event(_Topic, Payload, _Meta, State) ->
    %% handle it
    {noreply, State}.
```

For a **dynamic** topic set (one topic per entity your service
locally owns, changing at runtime), call
`mcl_om_pubsub:ensure_subscriptions/1` again whenever the desired
set changes — it diffs against what's currently running and
starts/stops only the delta, leaving everything else untouched:

```erlang
mcl_om_pubsub:ensure_subscriptions(
    [{Topic, my_x_event_handler, EntityId} || EntityId <- my_entities()]).
```

You do not need to handle reconnect yourself. An ordinary link respawn
(a station blip) is invisible to a subscription — macula's pool
replays it automatically on the new link. `mcl_om_pubsub_subscriptions`
also self-heals on a 30s reconcile tick independent of any caller, so
a topic that couldn't start because the mesh wasn't attached yet at
boot is retried automatically.

### The escape hatch

The three publish modes above cover every real call site surveyed
across the workspace, but not everything — e.g. retry-with-backoff on
a failed publish, fully decoupled from any caller. `start_publisher/3,4,5`
resolves `mesh_handles/0` exactly like `publish/2,3`, then hands full
callback control to a **caller-supplied** module implementing
`-behaviour(macula_publisher)` yourself:

```erlang
{ok, _Pid} = mcl_om_pubsub:start_publisher(my_retry_coordinator,
                                              Topic, Payload).
```

`mcl_om` has no say over what your module's callback does with the
outcome — reach for this only when `publish/2,3`'s three fixed modes
genuinely don't fit.

## Chapter 4: How to Upload/Download files over the mesh

### Put/get (piece E)

```erlang
{ok, Mcid} = mcl_om_content:put(Bytes).
{ok, Bytes} = mcl_om_content:get(Mcid).
```

Both block until the transfer resolves or `Opts`'s `timeout` (default
15000ms) elapses — a timed-out transfer is genuinely cancelled, not
just given up on locally, since it holds an open QUIC stream on the
other end until told otherwise.

**This is content-addressed storage, not a destination-addressed file
transfer.** `put/1,2` doesn't take a filename, a path, or a recipient
— it returns an MCID (a content identifier: a codec byte plus a hash,
not anything human-readable), and `get/1,2` fetches by that identifier
from *whoever* is currently serving it, not necessarily from you.
Think "content-addressed store," not "upload this file to that
server." If your bytes have no meaningful filename or destination —
a thumbnail, a document, a generated report — this is exactly what
you want.

Always uses the **pooled** path (`macula_feeder:start_link/4,5`,
`macula_download:start_link/4,5`), never `_direct`. This matters:
`macula_download`'s direct-dial path only resolves content that has a
`content_announcement` DHT record, and only *chunked* content gets
one — a small blob (a logo, a thumbnail) never does, so
`start_link_direct` would 404 even immediately after upload (confirmed
live on beam02). Put and get through this module can never disagree
about which path a given piece of content is reachable through.

The escape hatch (`start_feeder/2,3,4` / `start_downloader/2,3,4`, a
caller-supplied `-behaviour(macula_feeder)`/`macula_download` module)
exists for the same reason as pubsub's — e.g. a batch upload wanting a
per-item completion side effect without blocking the caller on each
one — and resolves `mesh_handles/0` the same way `put/1,2` does.

### If you actually need "send this to a specific recipient"

`mcl_om_content` is deliberately **not** what you want if the real
requirement is "push these bytes at a service that's already
expecting them" rather than "store this somewhere content-addressed
for whoever asks later." That's a genuinely different, and already
supervised, macula primitive pair: `macula_upload` (recipient) /
`macula_pusher` (sender).

**`mcl_om` does not wrap this pair.** Not "not yet" in the sense
chapter 5's streaming gap is — no service in this workspace has needed
it at all, so there's no real usage to design a facade from. Call the
supervised behaviours directly, resolving `mcl_om:mesh_handles/0`
and `mcl_om:identity_key/0` yourself exactly the way `mcl_om_content`
does internally — this is still the supervised macula API, just
without a second `mcl_om`-level layer on top of it yet.

```erlang
%% Recipient: advertise an upload procedure, same advertise_direct
%% shape as chapter 2's RPC providers.
-module(my_x_upload_handler).
-behaviour(macula_upload).
-export([init/1, handle_open/2, handle_chunk/2, handle_eof/1]).

init(_Args) -> {ok, []}.
handle_open(_UploadArgs, State) -> {ok, State}.
handle_chunk(Bytes, State) -> {ok, [Bytes | State]}.
handle_eof(State) -> {reply, {ok, iolist_to_binary(lists:reverse(State))}, State}.

register() ->
    {ok, Pool, Realm} = mcl_om:mesh_handles(),
    {ok, NodeKey}     = mcl_om:identity_key(),
    macula_upload:advertise_direct(Pool, Realm, <<"my_x.receive_report">>,
                                   ?MODULE, [], NodeKey).
```

```erlang
%% Sender: push bytes at that specific, already-known recipient.
{ok, Pool, Realm} = mcl_om:mesh_handles(),
{ok, _PusherPid} = macula_pusher:start_link(my_x_push_result_handler,
                                            Pool, Realm,
                                            <<"my_x.receive_report">>, Bytes).
```

`macula_pusher:start_link/5,6` and `macula_upload:advertise_direct/6,7`
are the same kind of supervised, callback-driven primitive as every
other call in this guide — `mcl_om` just hasn't grown a
`mesh_handles`-resolving facade over this specific pair yet.

## Chapter 5: How to stream media over the mesh

**`mcl_om` does not wrap streaming.** `macula_streamer` (provider)
and `macula_stream_sink` (consumer) are real, supervised OTP
behaviours in the SDK — that layer is done, by macula. What's missing
is the second layer this guide's other chapters have: a `mcl_om`-
level facade that resolves `mesh_handles/0` for you and picks a
default callback shape. It doesn't exist because exactly one service
in the whole workspace survey uses streaming at all
(`hecate-services/hecate-tube`, for video), and its callback logic —
chunking a specific video file off disk — is genuinely
service-specific in a way a generic wrapper can't cleanly generalize
from a single example. A second real exemplar would make building one
worth it.

Until then, call `macula_streamer`/`macula_stream_sink` directly —
still the supervised API, not the raw wire protocol — resolving your
own pool/realm/node key via `mcl_om:mesh_handles()`/
`mcl_om:identity_key()` exactly the way every wrapper in this guide
does internally.

### Serving a stream

```erlang
%% Real example: hecate-tube's stream_video_clip_by_id.erl, trimmed.
-module(stream_video_clip_by_id).
-behaviour(macula_streamer).
-export([init/1, handle_open/2]).

init(_Args) -> {ok, undefined}.

handle_open(#{clip_id := ClipId}, State) ->
    open_from(project_tube_store:get_clip(ClipId), ClipId, State);
handle_open(_StreamArgs, State) ->
    {stop, bad_request, State}.

open_from({ok, #{status := <<"published">>, local_ref := LocalRef}}, _ClipId, State) ->
    %% spawn a sender process that reads the file in chunks and calls
    %% macula_streamer:send/2,3 on this streamer's own pid, then
    %% macula_streamer:close/1 when done
    {ok, State};
open_from(_NotFoundOrUnpublished, _ClipId, State) ->
    {stop, not_found, State}.
```

`init/1` and `handle_open/2` are the required callbacks; sending is
push-based and driven from outside them once `handle_open/2` has
returned `{ok, State}` — any process holding the streamer's pid calls
`macula_streamer:send/2,3`/`close/1` on it, so a natural shape is
spawning a dedicated sender process from inside `handle_open/2` itself
(as `hecate-tube` does), not sending inline.

Registering this as callable — the supervised call, not a hand-rolled
wire-level ADVERTISE — is `macula_streamer:advertise_direct/6,7`, the
same shape chapter 2's `macula_response:advertise_direct/7` uses for
plain RPC handlers:

```erlang
{ok, Pool, Realm} = mcl_om:mesh_handles(),
{ok, NodeKey}     = mcl_om:identity_key(),
{ok, _Sup} = macula_streamer:advertise_direct(Pool, Realm,
                                              <<"my_x.watch_clip">>,
                                              stream_video_clip_by_id, [],
                                              NodeKey).
```

Re-advertise this periodically (a station's wire-level registration
doesn't survive a connection replacement, same as chapter 2's RPC
providers) by tracking the returned supervisor pid and passing it back
in as `advertise_direct/7`'s `reuse_sup` option on each tick — the
exact pattern `mcl_om_capabilities` already runs for
`macula_response`; read that module's `do_advertise/2` for the
mechanism to copy.

### Consuming a stream

`macula_stream_sink:start_link/5,6` is the supervised consumer-side
call — not `macula:call_stream/5`, which hands back a raw stream pid
you'd otherwise have to hand-write your own `recv` loop around.
`start_link/5,6` opens the stream, runs that loop for you in a linked
reader process (so a slow peer never blocks your gen_server's own
mailbox), and calls `Module:handle_chunk/2` once per item,
`Module:handle_close/2` when the stream ends or errors:

```erlang
-module(my_x_clip_consumer).
-behaviour(macula_stream_sink).
-export([init/1, handle_chunk/2, handle_close/2]).

init(Args) -> {ok, Args}.

handle_chunk(Bytes, State) ->
    %% do something with this chunk
    {ok, State}.

handle_close(_Reason, State) ->
    {stop, normal, State}.
```

```erlang
{ok, Pool, Realm} = mcl_om:mesh_handles(),
{ok, _SinkPid} = macula_stream_sink:start_link(my_x_clip_consumer, Pool,
                                               Realm, <<"my_x.watch_clip">>,
                                               #{clip_id => ClipId}).
```

## Testing your service's mesh code

Three techniques, in order of how much you should reach for them
(cheapest first):

1. **Pure functions.** If your handler has any decision logic
   (`resolve_realm/2`-shaped, `resolve_mode/1`-shaped), export it and
   test it directly — no mesh at all. Every wrapper module in this
   library follows this convention; match it in your own handler
   modules.

2. **Zero-seed real pool.** `macula_client:connect([], #{})` boots a
   genuinely real pool with no station to reach, so every mesh call
   against it resolves to a real, deterministic SDK error
   (`{error, {transient, no_healthy_station}}`) fast and locally — no
   network, no mocking `macula` itself. This is the right tool for
   "does my code degrade correctly with no mesh," which is most of
   what needs covering.

3. **A real station.** The only way to prove a *success* path — a
   capability genuinely answers a call, a subscription genuinely
   receives a published event, content genuinely round-trips. `macula
   .io`'s demo fleet (`station-de-frankfurt.macula.io`) is documented,
   disposable dev infra safe to hit directly in tests. Every real bug
   pieces A–H's own tests found (a DHT key mismatch, a missing TLS
   trust triad, a nonexistent supervisor:stop/1, a race in a
   retry-inside-a-dying-callback design) was only found this way —
   budget for at least one test per mesh-facing feature that actually
   round-trips through a real station, not just a mocked one.

If a test needs technique 3, put it in `test_live/`, not `test/` —
excluded from the default `rebar3 eunit`/CI gate on purpose, since a
station blip must never block an unrelated merge. See any file in this
repo's own `test_live/` for the pattern, and this repo's
`.github/workflows/lint-and-test.yml` for how CI runs it separately
and non-blocking.

## Where to look next

- [`service_anatomy.md`](service_anatomy.md) — the boot lifecycle this
  guide assumes.
- [`identity_model.md`](identity_model.md) — why a service has its own
  identity, not the operator's.
- [`read_model_services.md`](read_model_services.md) — if your
  subscription (chapter 3) is feeding a queryable local read model rather
  than just triggering a side effect: the Listener/Policy/Projection split
  that keeps it from serving stale entries forever, and the discovery-at-
  scale reasoning behind relying on the subscription rather than a
  `find_records_by_type` crawl.
- `hecate-services/hecate-tube` — the fullest real exemplar of a
  service using every primitive in this guide, including the two
  chapters 4–5 note aren't wrapped yet (streaming, and content's
  put/get before `mcl_om_content` existed) — built directly against
  the SDK, and the source this whole plan was derived from.
- `../plans/PLAN_HECATE_OM_MESH_WRAPPERS.md` — the design history,
  evidence, and every bug each piece's tests found, if you want the
  "why," not just the "how" above.
