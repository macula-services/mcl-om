%%% @doc Public facade for hecate-om.
%%%
%%% Services typically only need a handful of these:
%%%
%%%   mcl_om:boot(MyServiceMod)         %% one-call lifecycle wiring
%%%   mcl_om:advertise_capabilities()   %% (re-)publish my caps
%%%   mcl_om:health()                   %% snapshot for /health
%%%   mcl_om:service_cert()             %% load my service-principal cert
%%%   mcl_om:macula_client()            %% returns the SDK client handle
%%%   mcl_om:read_model()               %% my barrel_docdb database name
-module(mcl_om).

-export([
    boot/1,
    boot/2,
    advertise_capabilities/0,
    call_capability/4,
    health/0,
    macula_client/0,
    realm/0,
    identity_key/0,
    mesh_handles/0,
    service_module/0,
    read_model/0
]).

-define(SERVICE_MODULE_KEY, mcl_om_service_module).
-define(READ_MODEL_KEY, mcl_om_read_model_db).

%% @doc Wire a service module into mcl_om and start it.
%%
%% Typical call from the hosting service's `_app:start/2':
%%
%%   start(_, _) ->
%%       mcl_om:boot(my_service).
-spec boot(module()) -> {ok, pid()} | {error, term()}.
boot(ServiceMod) ->
    boot(ServiceMod, #{}).

-spec boot(module(), map()) -> {ok, pid()} | {error, term()}.
boot(ServiceMod, Opts) when is_atom(ServiceMod), is_map(Opts) ->
    persistent_term:put(?SERVICE_MODULE_KEY, ServiceMod),
    ok = maybe_wire_store(ServiceMod),
    ok = maybe_wire_read_model(ServiceMod),
    ok = mcl_om_capabilities:register(capabilities_with_describe(ServiceMod)),
    ok = maybe_wire_subscriptions(ServiceMod),
    ok = mcl_om_health:register(ServiceMod),
    ServiceMod:start(Opts).

%% @private ServiceMod's own declared capabilities, plus a synthetic
%% `<service-name>.describe_capabilities' one when it exports either
%% `describe_rpc_capabilities/0' or `describe_pubsub_capabilities/0'
%% (see mcl_om_describe:capability_for/2) -- omitted entirely for a
%% service that exports neither, same "optional means genuinely absent,
%% not present-but-empty" contract every other optional callback here
%% already has.
capabilities_with_describe(ServiceMod) ->
    #{name := ServiceName} = ServiceMod:info(),
    Caps = ServiceMod:capabilities(),
    add_describe_capability(mcl_om_describe:capability_for(ServiceMod, ServiceName), Caps).

add_describe_capability(undefined, Caps)     -> Caps;
add_describe_capability(DescribeCap, Caps)   -> [DescribeCap | Caps].

%% @private When the service module exports subscriptions/0, wire each
%% declared {Topic, HandlerMod, Args} into a supervised macula_subscriber
%% before the service's own start/1 runs. Producer-only / consumer-only
%% services that omit the callback pay nothing.
maybe_wire_subscriptions(ServiceMod) ->
    _ = code:ensure_loaded(ServiceMod),
    Has = erlang:function_exported(ServiceMod, subscriptions, 0),
    wire_subscriptions(Has, ServiceMod).

wire_subscriptions(false, _ServiceMod) ->
    ok;
wire_subscriptions(true, ServiceMod) ->
    mcl_om_pubsub:ensure_subscriptions(ServiceMod:subscriptions()).

%% @private When the service module exports both `store_id/0' and
%% `data_dir/0', treat it as a CMD/PRJ service that owns a reckon-db
%% store. Wire the canonical pattern before the service's own
%% start/1 runs. Producer-only services omit the callbacks and pay
%% nothing.
maybe_wire_store(ServiceMod) ->
    _ = code:ensure_loaded(ServiceMod),
    Has = erlang:function_exported(ServiceMod, store_id, 0) andalso
          erlang:function_exported(ServiceMod, data_dir, 0),
    wire_store(Has, ServiceMod).

wire_store(false, _ServiceMod) ->
    ok;
wire_store(true, ServiceMod) ->
    StoreId = ServiceMod:store_id(),
    DataDir = ServiceMod:data_dir(),
    Indexes = store_indexes(ServiceMod),
    Mode    = store_mode(ServiceMod),
    Integ   = store_integrity(ServiceMod),
    ensured(mcl_om_store:ensure(StoreId, DataDir, Indexes, Mode, Integ), ServiceMod).

ensured(ok, _ServiceMod) ->
    ok;
ensured({error, Why}, ServiceMod) ->
    error({mcl_om_store_failed, ServiceMod, Why}).

%% Optional store_indexes/0 callback: the service's declared secondary
%% index list. Defaults to [] (no indexes) when the service doesn't
%% export it.
store_indexes(ServiceMod) ->
    case erlang:function_exported(ServiceMod, store_indexes, 0) of
        true  -> ServiceMod:store_indexes();
        false -> []
    end.

%% Optional store_mode/0 callback: `single' (default) or `cluster'.
%% `cluster' makes reckon-db form a Ra cluster across every node that
%% starts the same store_id. Defaults to `single' for services that
%% don't export it (backward compatible).
store_mode(ServiceMod) ->
    case erlang:function_exported(ServiceMod, store_mode, 0) of
        true  -> ServiceMod:store_mode();
        false -> single
    end.

%% Optional store_integrity/0 callback: the reckon-db integrity config
%% (`disabled', or `#{enabled => true, key_source => {env_var, Name}}').
%% Enables per-store HMAC event tamper-resistance. Defaults to `disabled'
%% for services that don't export it (backward compatible).
store_integrity(ServiceMod) ->
    case erlang:function_exported(ServiceMod, store_integrity, 0) of
        true  -> ServiceMod:store_integrity();
        false -> disabled
    end.

%% @private When the service module exports both `read_model_id/0' and
%% `data_dir/0', open its barrel_docdb read-model database before the
%% service's own start/1 runs. Independent of maybe_wire_store/1 — a
%% service may declare a read model, an event store, both, or neither.
%% Services that don't use one pay nothing beyond the idle barrel_docdb
%% application already started as part of mcl_om.
maybe_wire_read_model(ServiceMod) ->
    _ = code:ensure_loaded(ServiceMod),
    Has = erlang:function_exported(ServiceMod, read_model_id, 0) andalso
          erlang:function_exported(ServiceMod, data_dir, 0),
    wire_read_model(Has, ServiceMod).

wire_read_model(false, _ServiceMod) ->
    ok;
wire_read_model(true, ServiceMod) ->
    DbName   = ServiceMod:read_model_id(),
    DataDir  = ServiceMod:data_dir(),
    TtlSweep = read_model_ttl_sweep(ServiceMod),
    persistent_term:put(?READ_MODEL_KEY, DbName),
    ensured_read_model(mcl_om_read_model:ensure(DbName, DataDir, TtlSweep), ServiceMod).

ensured_read_model(ok, _ServiceMod) ->
    ok;
ensured_read_model({error, Why}, ServiceMod) ->
    error({mcl_om_read_model_failed, ServiceMod, Why}).

%% Optional read_model_ttl_sweep/0 callback: barrel_docdb's native per-doc
%% TTL sweep config for the read model, `disabled' by default (no expiry,
%% backward compatible with every service that doesn't export it).
read_model_ttl_sweep(ServiceMod) ->
    case erlang:function_exported(ServiceMod, read_model_ttl_sweep, 0) of
        true  -> ServiceMod:read_model_ttl_sweep();
        false -> disabled
    end.

-spec service_module() -> module() | undefined.
service_module() ->
    persistent_term:get(?SERVICE_MODULE_KEY, undefined).

%% @doc This service's read-model database name (the barrel_docdb handle —
%% pass it straight to barrel_docdb:put_doc/2, get_doc/2, fold_docs/3, ...).
%% `{error, no_read_model}' when the service module doesn't export
%% read_model_id/0 + data_dir/0.
-spec read_model() -> {ok, binary()} | {error, no_read_model}.
read_model() ->
    case persistent_term:get(?READ_MODEL_KEY, undefined) of
        undefined -> {error, no_read_model};
        DbName    -> {ok, DbName}
    end.

%% @doc (Re-)publish this service's capabilities onto the mesh.
%% Typically called once at boot; call again when the capability
%% set changes.
-spec advertise_capabilities() -> ok.
advertise_capabilities() ->
    mcl_om_capabilities:publish().

%% @doc Call a capability by name over the direct-dial data path:
%% resolve a provider from the DHT, dial its serving station directly,
%% and issue the CALL there (failing over to the next provider on
%% error). The CALL uses `CapName' as the procedure, realm-scoped.
-spec call_capability(binary(), binary(), term(), pos_integer()) ->
    {ok, term()} | {error, term()}.
call_capability(Org, CapName, Payload, TimeoutMs) ->
    mcl_om_capabilities:call_capability(Org, CapName, Payload, TimeoutMs, #{}).

%% @doc Snapshot of this service's health. Used by /health handler.
-spec health() -> mcl_om_service:health().
health() ->
    mcl_om_health:snapshot().

-spec macula_client() -> {ok, term()} | {error, term()}.
macula_client() ->
    mcl_om_identity:macula_client().

%% @doc This service's realm tag (32-byte binary). Previously reachable
%% only by calling `mcl_om_identity:realm/0' directly, past the public
%% facade -- every service wanting to publish/subscribe/advertise on the
%% mesh needs this alongside `macula_client/0', so it belongs here.
-spec realm() -> {ok, binary()} | {error, term()}.
realm() ->
    mcl_om_identity:realm().

%% @doc This service's stable signing node key, or
%% `{error, no_identity_key}' when running on an ephemeral identity.
%% Needed by every provider advertisement, which signs its own DHT
%% record with it.
-spec identity_key() -> {ok, macula_node_keys:node_key()} | {error, term()}.
identity_key() ->
    mcl_om_identity:identity_key().

%% @doc The `{Pool, Realm}' pair every PubSub/RPC-consumer/Content call
%% needs together. Replaces the hand-rolled
%% `case {macula_client(), realm()} of {{ok,P},{ok,R}} -> ...' pairing
%% four independent hecate-services repos each wrote for themselves
%% (`hecate_mesh.erl', `tom_ocean_mesh.erl', `tom_wire_macula.erl',
%% `tom_crier.erl') because mcl_om gave them nothing to build on.
%% Degrades to `{error, mesh_unavailable}' rather than crashing when
%% either half is missing (mesh unreachable, or no client attached yet).
-spec mesh_handles() -> {ok, term(), binary()} | {error, mesh_unavailable}.
mesh_handles() ->
    handles(macula_client(), realm()).

handles({ok, Pool}, {ok, Realm}) -> {ok, Pool, Realm};
handles(_MaculaClient, _Realm) -> {error, mesh_unavailable}.
