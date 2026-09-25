%%% @doc Public facade for mcl_om — the PQ-only over-mesh substrate.
%%%
%%% Services typically only need a handful of these:
%%%
%%%   mcl_om:boot(MyServiceMod)         %% one-call lifecycle wiring
%%%   mcl_om:advertise_capabilities()   %% (re-)publish my caps
%%%   mcl_om:health()                   %% snapshot for /health
%%%   mcl_om:identity_key()             %% my node key, or {error, ...}
%%%   mcl_om:macula_client()            %% returns the SDK client handle
-module(mcl_om).

-export([
    boot/1,
    boot/2,
    advertise_capabilities/0,
    call_capability/4,
    call_capability/5,    health/0,
    macula_client/0,
    realm/0,
    identity_key/0,
    mesh_handles/0,
    service_module/0
]).

-define(SERVICE_MODULE_KEY, mcl_om_service_module).

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
    ok = org_configured(mcl_om_identity:org()),
    ok = maybe_wire_store(ServiceMod),
    ok = mcl_om_health:register(ServiceMod),
    %% ADVERTISE ONLY AFTER A SUCCESSFUL START. A procedure is announced
    %% only once the service can answer it, and a service that refuses to
    %% start leaves no advertisement behind. ServiceMod:start/1 is where
    %% the processes its handlers call come up, so capabilities and
    %% subscriptions are registered only once it has returned {ok, Pid}.
    %% (Health registers before start, deliberately: the /health listener
    %% must answer during boot, and health() reports the half-up tree
    %% honestly.)
    case ServiceMod:start(Opts) of
        {ok, Pid} ->
            ok = mcl_om_capabilities:register(capabilities_with_describe(ServiceMod)),
            ok = maybe_wire_subscriptions(ServiceMod),
            {ok, Pid};
        {error, _} = Err ->
            Err
    end.

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
    mcl_om_info:with_info(
      add_describe_capability(mcl_om_describe:capability_for(ServiceMod, ServiceName), Caps)).

add_describe_capability(undefined, Caps)     -> Caps;
add_describe_capability(DescribeCap, Caps)   -> [DescribeCap | Caps].

%% @private A service without an org offers nothing: every procedure is
%% `Org/Name', and the realm grants per org. It used to boot anyway, log
%% "advertise skipped, no org configured" and run green without ever
%% advertising or claiming. It refuses to boot now, naming the setting.
org_configured(Org) ->
    org_verdict(mcl_om_identity:checked_org(Org), Org).

org_verdict(ok, _Org) ->
    ok;
org_verdict({error, _}, Org) ->
    error({mcl_om_org_not_configured,
           #{got => Org,
             setting => <<"the mcl_om `org' app env, e.g. {org, <<\"${MCL_ORG}\">>} in "
                          "sys.config with MCL_ORG set, or the repository name as a literal">>}}).

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

-spec service_module() -> module() | undefined.
service_module() ->
    persistent_term:get(?SERVICE_MODULE_KEY, undefined).

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

%% @doc As call_capability/4, with `Opts'. One caller-facing option so
%% far, and it is the one the many-provider contract model needs:
%%
%%   advertiser => <<_:256>>   call ONLY the provider whose signed
%%       advertisement was published by this node id. One org procedure
%%       with many providers -- a thousand book clubs, one
%%       `get_bookclub_by_id' -- resolves to whoever the DHT lists first;
%%       a club that does not own the asked id answers `not_found', which
%%       is a valid answer and NOT a failover signal, so the wrong club
%%       wins by order. The fix is not a smarter retry, it is a pin: the
%%       caller that holds the club's node id (the publisher of the facts
%%       it consumed) names it here, and only that club is dialed. An
%%       absent or stale pin resolves to nothing and fails closed with
%%       `{error, no_provider}'.
-spec call_capability(binary(), binary(), term(), pos_integer(), map()) ->
    {ok, term()} | {error, term()}.
call_capability(Org, CapName, Payload, TimeoutMs, Opts) ->
    mcl_om_capabilities:call_capability(Org, CapName, Payload, TimeoutMs, Opts).

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
