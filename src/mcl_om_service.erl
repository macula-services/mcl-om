-module(mcl_om_service).
-moduledoc """
The behaviour every mcl service implements.

Six callbacks are required: `c:info/0', `c:start/1', `c:stop/1',
`c:health/0', `c:capabilities/0' and `c:identity_spec/0'. The optional
callbacks let a service declare mesh subscriptions and human-facing capability
descriptions. Health wiring and capability advertisement are handled by the rest
of mcl_om; a new service repository (release, Containerfile, CI workflows,
compose file) is generated with `rebar3 new mcl_service' from
`priv/templates/mcl_service/' (see `scripts/scaffold-service.sh').

Persistence is the service''s own. mcl_om opens no store and starts no reckon-db
or evoq application (mcl-om#10, 0.35.0): an event-sourced service declares
reckon_db, evoq and reckon_evoq itself and opens its store in its own `start/2'
before `mcl_om:boot/1'. `rebar3 new mcl_service store=1' generates that wiring
in the service''s own `<name>_app', reading the store''s settings from
`<name>_service:event_store/0'. A service module that still exports the old
`store_id/0' and `data_dir/0' callbacks together boots without a store, and
`mcl_om:boot/1' warns, naming them.
""".

-type info()           :: #{name := binary(), version := binary(), description := binary()}.
-type health()         :: ok | {degraded, term()} | {down, term()}.
%% `kind' selects which macula provider module 'mcl_om_capabilities'
%% advertises `handler' through: 'response' (default,
%% `macula_response:advertise_direct/7' — request/reply RPC) or
%% `streamer' ('macula_streamer:advertise_direct/7' — a
%% `-behaviour(macula_streamer)' handler, consumed via
%% `macula_stream_sink:start_link_direct/5,6', not 'call_capability/5,7'
%% — that path is response-only). `stream_opts' is forwarded to the
%% streamer only, e.g. `#{mode => client_stream}' (default
%% `server_stream'). Both provider modules publish the same
%% `procedure_advertisement' DHT record and read the same 'Opts' keys
%% (`ttl_ms', 'reuse_sup', `cert_chain', 'auth'), so `kind' changes only
%% which module gets called, nothing else about advertisement.
-type capability()     :: #{name := binary(), version := pos_integer(),
                            handler => {module(), term()},
                            auth => open
                                  | {ucan_required, <<_:256>>}
                                  | {realm_member_required, <<_:256>>, binary()},
                            kind => response | streamer,
                            stream_opts => #{mode => server_stream | client_stream},
                            %% A response capability''s handler budget, 1 to
                            %% 600000 ms (macula 12.2; default 30000).
                            handler_timeout_ms => 1..600000,
                            %% Per-capability inbound guard (mcl-om#13):
                            %% `limits' overrides the framework defaults for
                            %% this capability''s pipeline stages, and may
                            %% carry an `envelope' of per-key min/max clamps
                            %% (changed only by the operator tier). `guard =>
                            %% none' opts this capability out of the pipeline
                            %% deliberately -- the reason lives in the
                            %% service''s own code.
                            limits => map(),
                            guard => none,
                            %% How calls must be protected on the wire (0.34.0,
                            %% macula 13's provider modes): `off' names no KEM key,
                            %% `preferred' names one when macula''s kem_advertise is
                            %% enabled, `required' also refuses a clear call and
                            %% needs kem_advertise enabled. Absent: as before.
                            confidential => off | preferred | required}.
-type identity_spec()  :: #{scope := binary(),
                            actions := [binary()],
                            resources := [binary()],
                            ttl_days := pos_integer()}.

-export_type([info/0, health/0, capability/0, identity_spec/0]).

-doc "Static metadata about the service. Reported on /health.".
-callback info() -> info().

-doc "Start the service''s supervision tree. Called once on boot.".
-callback start(map()) -> {ok, pid()} | {error, term()}.

-doc "Stop the service. Called on shutdown.".
-callback stop(term()) -> ok.

-doc "Snapshot of current health. Called every /health hit.".
-callback health() -> health().

-doc "Capabilities this service exposes, to be advertised on the mesh. "
     "Other services find this one by these names. A capability whose "
     "map includes `handler => {HandlerModule, Args}' (HandlerModule "
     "implementing the `macula_response' behaviour) is advertised via "
     "`macula_response:advertise_direct/7' -- discoverable AND directly "
     "callable. A capability with no `handler' key is written as a "
     "bare discovery record only (today''s behavior, kept for services "
     "that advertise a capability another mechanism serves).".
-callback capabilities() -> [capability()].

-doc "UCAN this service wants minted by hecate-realm at boot. "
     "Until UCAN-delegation lands in realm, this is informational only.".
-callback identity_spec() -> identity_spec().

-doc "OPTIONAL. Topics this service subscribes to at boot: a list of "
     "{Topic, HandlerModule, Args} triples, HandlerModule implementing "
     "the `macula_subscriber' behaviour. mcl_om:boot/1 wires each "
     "into a supervised macula_subscriber under mcl_om_pubsub_sup "
     "before the service module''s own start/1 runs. Call "
     "mcl_om_pubsub:ensure_subscriptions/1 again whenever the "
     "desired set changes at runtime (e.g. a new topic per newly-"
     "registered entity) -- it diffs against what''s currently running "
     "and starts/stops only the delta.".
-callback subscriptions() -> [{binary(), module(), term()}].

%% Human-facing, NOT dispatch-wiring: `capability()' (above) is exactly
%% enough for `mcl_om_capabilities' to advertise and route a call,
%% and deliberately carries nothing about what a capability actually
%% DOES or what a topic''s payload looks like. `rpc_capability_doc()' /
%% `pubsub_capability_doc()' are that missing layer -- real evidence of
%% its cost: `macula-lazymesh''s 'MeshServices' catalog hand-maintains a
%% hardcoded, hand-written-description list of other services'
%% procedures today purely because there is nowhere on the mesh to pull
%% that metadata from live.
-type rpc_capability_doc()    :: #{name := binary(), description := binary(),
                                   params => [binary()],
                                   example_payload => map()}.
-type pubsub_capability_doc() :: #{topic := binary(), description := binary(),
                                   payload_shape => map()}.

-export_type([rpc_capability_doc/0, pubsub_capability_doc/0]).

-doc "OPTIONAL. Human-facing documentation for this service''s RPC "
     "capabilities -- name, a plain-language description, and "
     "optionally the params a caller sends / an example payload. "
     "Distinct from capabilities/0's own dispatch-wiring metadata "
     "(name/version/handler/auth/kind), which says how to route a "
     "call, never what it does. When exported (alongside either this "
     "or describe_pubsub_capabilities/0), mcl_om:boot/1 advertises "
     "a synthetic `<service-name>.describe_capabilities' RPC that "
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

-optional_callbacks([subscriptions/0,
                     describe_rpc_capabilities/0,
                     describe_pubsub_capabilities/0]).
