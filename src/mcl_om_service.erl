-module(mcl_om_service).
-moduledoc """
The behaviour every hecate-service implements.

Six callbacks are required: `c:info/0`, `c:start/1`, `c:stop/1`,
`c:health/0`, `c:capabilities/0` and `c:identity_spec/0`. The optional
callbacks let a service own a reckon-db store, a barrel_docdb read model,
mesh subscriptions and human-facing capability descriptions. Health wiring,
capability advertisement and the optional stores are handled by the rest of
mcl_om; a new service repository (release, Containerfile, CI workflows,
compose file) is generated with `rebar3 new mcl_service` from
`priv/templates/mcl_service/` (see `scripts/scaffold-service.sh`).

When a service exports the optional `c:store_id/0` and `c:data_dir/0`
callbacks, `mcl_om:boot/1` does the following before it calls
`ServiceMod:start/1`:

- starts the store at `<data_dir>/<store_id>/` with
  `reckon_db_sup:start_store/1`, in the mode `c:store_mode/0` names
  (`single` when it is not exported);
- waits up to 30s for the store to appear in
  `reckon_db_sup:which_stores/0`;
- starts `evoq_store_subscription:start_link/1` so projections and process
  managers receive events.

Producer-only services (no event store) omit both callbacks. See
`m:mcl_om_store` for the helper module.
""".

-type info()           :: #{name := binary(), version := binary(), description := binary()}.
-type health()         :: ok | {degraded, term()} | {down, term()}.
%% `kind' selects which macula provider module `mcl_om_capabilities'
%% advertises `handler' through: `response' (default,
%% `macula_response:advertise_direct/7' — request/reply RPC) or
%% `streamer' (`macula_streamer:advertise_direct/7' — a
%% `-behaviour(macula_streamer)' handler, consumed via
%% `macula_stream_sink:start_link_direct/5,6', not `call_capability/5,7'
%% — that path is response-only). `stream_opts' is forwarded to the
%% streamer only, e.g. `#{mode => client_stream}' (default
%% `server_stream'). Both provider modules publish the same
%% `procedure_advertisement' DHT record and read the same `Opts' keys
%% (`ttl_ms', `reuse_sup', `cert_chain', `auth'), so `kind' changes only
%% which module gets called, nothing else about advertisement.
-type capability()     :: #{name := binary(), version := pos_integer(),
                            handler => {module(), term()},
                            auth => open
                                  | {ucan_required, <<_:256>>}
                                  | {realm_member_required, <<_:256>>, binary()},
                            kind => response | streamer,
                            stream_opts => #{mode => server_stream | client_stream}}.
-type identity_spec()  :: #{scope := binary(),
                            actions := [binary()],
                            resources := [binary()],
                            ttl_days := pos_integer()}.

-export_type([info/0, health/0, capability/0, identity_spec/0]).

-doc "Static metadata about the service. Reported on /health.".
-callback info() -> info().

-doc "Start the service's supervision tree. Called once on boot.".
-callback start(map()) -> {ok, pid()} | {error, term()}.

-doc "Stop the service. Called on shutdown.".
-callback stop(term()) -> ok.

-doc "Snapshot of current health. Called every /health hit.".
-callback health() -> health().

-doc "Capabilities this service exposes, to be advertised on the mesh. "
     "Other services find this one by these names. A capability whose "
     "map includes `handler => {HandlerModule, Args}` (HandlerModule "
     "implementing the `macula_response` behaviour) is advertised via "
     "`macula_response:advertise_direct/7` -- discoverable AND directly "
     "callable. A capability with no `handler` key is written as a "
     "bare discovery record only (today's behavior, kept for services "
     "that advertise a capability another mechanism serves).".
-callback capabilities() -> [capability()].

-doc "UCAN this service wants minted by hecate-realm at boot. "
     "Until UCAN-delegation lands in realm, this is informational only.".
-callback identity_spec() -> identity_spec().

-doc "OPTIONAL. The reckon-db store_id this service owns. When "
     "exported alongside data_dir/0, mcl_om:boot/1 auto-starts "
     "the store and the per-store evoq subscription before the "
     "service module's own start/1 fires.".
-callback store_id() -> atom().

-doc "OPTIONAL. The on-disk root for this service's reckon-db store. "
     "The store data lands at data_dir/store_id.".
-callback data_dir() -> string().

-doc "OPTIONAL. The reckon-db secondary index declarations this service's "
     "store maintains, e.g. [tags, event_type, {payload, <<\"plate\">>}, "
     "{payload_hash, [<<\"lot_id\">>, <<\"plate\">>]}]. When exported "
     "alongside store_id/0 + data_dir/0, mcl_om:boot/1 installs these on "
     "the auto-started store so CCC payload indexes are declared. Omit for a "
     "store with no secondary indexes.".
-callback store_indexes() -> [term()].

-doc "OPTIONAL. The reckon-db store mode: `single` (default) or `cluster`. "
     "`cluster` makes reckon-db discover peers and form a Ra cluster across "
     "every node that starts the same store_id (RF = number of such nodes). "
     "When exported alongside store_id/0 + data_dir/0, mcl_om:boot/1 "
     "auto-starts the store in this mode. Omit for a standalone single-node "
     "store.".
-callback store_mode() -> single | cluster.

-doc "OPTIONAL. The reckon-db integrity config for the store: `disabled` "
     "(default), or `#{enabled => true, key_source => {env_var, Name} | "
     "{sealed_file, Path}}` to enable per-store HMAC event tamper-resistance. "
     "When exported, mcl_om:boot/1 threads it into the store config. The "
     "store refuses to start if integrity is enabled but the key cannot be "
     "loaded, so provision the key before enabling.".
-callback store_integrity() -> disabled | map().

-doc "OPTIONAL. The barrel_docdb database name this service's read model "
     "lives in (lowercase alphanumerics/underscore/hyphen, 1-63 chars — see "
     "barrel_docdb:validate_db_name/1). When exported alongside data_dir/0, "
     "mcl_om:boot/1 opens the database at data_dir/read_model_id before "
     "calling ServiceMod:start/1. PRJ code writes to it with barrel_docdb "
     "directly, using this same name as the database handle — there is no "
     "separate accessor to call first. Independent of store_id/0: a service "
     "may have a read model, an event store, both, or neither.".
-callback read_model_id() -> binary().

-doc "OPTIONAL. The barrel_docdb TTL sweep config for this service's read "
     "model: `disabled` (default, no automatic expiry -- today's behavior "
     "for every service), or `#{interval_ms := pos_integer(), batch := "
     "pos_integer()}` to turn on barrel_docdb's native per-document TTL "
     "sweeper. `interval_ms` is how often it folds the expiry index; "
     "`batch` caps how many due documents it hard-deletes per pass. This "
     "only arms the sweeper -- a document still needs `expires_at` set "
     "(a unix-ms deadline) in its own `barrel_docdb:put_doc/3` `Opts` to "
     "ever expire; omitting it on a write preserves whatever expiry the "
     "document already had. When exported alongside read_model_id/0 + "
     "data_dir/0, mcl_om:boot/1 threads this into the database's "
     "create_db config. Omit for a read model where nothing expires.".
-callback read_model_ttl_sweep() -> disabled | #{interval_ms := pos_integer(),
                                                 batch := pos_integer()}.

-doc "OPTIONAL. Topics this service subscribes to at boot: a list of "
     "{Topic, HandlerModule, Args} triples, HandlerModule implementing "
     "the `macula_subscriber` behaviour. mcl_om:boot/1 wires each "
     "into a supervised macula_subscriber under mcl_om_pubsub_sup "
     "before the service module's own start/1 runs. Call "
     "mcl_om_pubsub:ensure_subscriptions/1 again whenever the "
     "desired set changes at runtime (e.g. a new topic per newly-"
     "registered entity) -- it diffs against what's currently running "
     "and starts/stops only the delta.".
-callback subscriptions() -> [{binary(), module(), term()}].

%% Human-facing, NOT dispatch-wiring: `capability()' (above) is exactly
%% enough for `mcl_om_capabilities' to advertise and route a call,
%% and deliberately carries nothing about what a capability actually
%% DOES or what a topic's payload looks like. `rpc_capability_doc()' /
%% `pubsub_capability_doc()' are that missing layer -- real evidence of
%% its cost: `macula-lazymesh''s `MeshServices' catalog hand-maintains a
%% hardcoded, hand-written-description list of other services'
%% procedures today purely because there is nowhere on the mesh to pull
%% that metadata from live.
-type rpc_capability_doc()    :: #{name := binary(), description := binary(),
                                   params => [binary()],
                                   example_payload => map()}.
-type pubsub_capability_doc() :: #{topic := binary(), description := binary(),
                                   payload_shape => map()}.

-export_type([rpc_capability_doc/0, pubsub_capability_doc/0]).

-doc "OPTIONAL. Human-facing documentation for this service's RPC "
     "capabilities -- name, a plain-language description, and "
     "optionally the params a caller sends / an example payload. "
     "Distinct from capabilities/0's own dispatch-wiring metadata "
     "(name/version/handler/auth/kind), which says how to route a "
     "call, never what it does. When exported (alongside either this "
     "or describe_pubsub_capabilities/0), mcl_om:boot/1 advertises "
     "a synthetic `<service-name>.describe_capabilities` RPC that "
     "returns both lists live -- so a mesh consumer (e.g. a tooling "
     "catalog) can call it instead of hand-maintaining descriptions.".
-callback describe_rpc_capabilities() -> [rpc_capability_doc()].

-doc "OPTIONAL. Human-facing documentation for the pubsub topics this "
     "service publishes or subscribes to -- topic name, a "
     "plain-language description, and optionally the payload shape. "
     "Distinct from subscriptions/0, which wires actual subscriber "
     "processes and carries no description. See "
     "describe_rpc_capabilities/0's own doc for how this is exposed on "
     "the mesh once exported.".
-callback describe_pubsub_capabilities() -> [pubsub_capability_doc()].

-optional_callbacks([store_id/0, data_dir/0, store_indexes/0, store_mode/0,
                     store_integrity/0, read_model_id/0,
                     read_model_ttl_sweep/0, subscriptions/0,
                     describe_rpc_capabilities/0,
                     describe_pubsub_capabilities/0]).
