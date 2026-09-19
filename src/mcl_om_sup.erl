%%% @doc Top-level supervisor for hecate-om.
%%%
%%% Owns four workers and one nested supervisor, all shared by the
%%% hosting service:
%%%   1. mcl_om_identity  — keeps the realm cert + UCAN cached
%%%   2. mcl_om_capabilities — fans capability advertisements out
%%%   3. mcl_om_pubsub_sup — dynamic supervisor of this service's
%%%      macula_subscriber children (piece D)
%%%   4. mcl_om_pubsub_subscriptions — reconciles the desired
%%%      subscription set against (3)'s actual running children
%%%   5. mcl_om_health    — bookkeeping for /health responses
%%%
%%% and, when `health_port' is configured, the Cowboy listener that actually
%%% serves `GET /health' on it (so Podman's HEALTHCHECK and k8s liveness probes
%%% have something to hit).
%%%
%%% When station seeds are configured, also the mesh pool itself
%%% (piece A, `PLAN_MCL_OM_MESH_WRAPPERS.md'): an ordinary
%%% `restart => permanent' child wrapping `macula_client:connect/2'
%%% (via `mcl_om_identity:start_mesh_pool/0', which needs this
%%% gen_server's already-loaded keypair — hence positioned right after
%%% it). A pool crash is no longer this app's problem to notice and
%%% react to; OTP just restarts the child, same as any other. With no
%%% seeds configured the child is omitted entirely — same `health_
%%% listener/0' pattern as the HTTP listener below — so
%%% `mcl_om_identity:macula_client/0' degrades to `{error,
%%% no_client}' exactly as it did before this piece, not a
%%% harmlessly-idle pool masking "nothing configured" as "connected".
-module(mcl_om_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-ifdef(TEST).
-export([health_socket_opts/2]).
-endif.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 10
    },
    Children = [
        worker(mcl_om_identity)
    ] ++ mesh_pool_children() ++ [
        worker(mcl_om_capabilities),
        worker(mcl_om_claim),
        supervisor_child(mcl_om_pubsub_sup),
        worker(mcl_om_pubsub_subscriptions),
        worker(mcl_om_health)
    ] ++ health_listener(),
    {ok, {SupFlags, Children}}.

%% The mesh pool (piece A): present only when seeds are configured, so
%% a service with none keeps today's exact degrade contract
%% (`mcl_om_identity:macula_client/0' -> `{error, no_client}')
%% rather than holding a real-but-permanently-idle pool that would
%% make "nothing configured" indistinguishable from "connected" to any
%% caller checking `mesh_handles/0' alone. Positioned right after
%% `mcl_om_identity' in the list above -- its start function reads
%% that gen_server's already-loaded keypair.
mesh_pool_children() ->
    case mcl_om_identity:configured_seeds() of
        []    -> [];
        _Seeds -> [mesh_pool_child()]
    end.

mesh_pool_child() ->
    #{
        id       => mcl_om_mesh_pool,
        start    => {mcl_om_identity, start_mesh_pool, []},
        restart  => permanent,
        shutdown => 5000,
        type     => worker,
        modules  => [macula_client]
    }.

%% The GET /health HTTP endpoint: a Cowboy listener on `health_port', dispatching
%% to mcl_om_health_handler. The handler and its routes existed but nothing
%% ever mounted them, so /health was dead code and every service reported
%% unhealthy to Podman/k8s. Returns [] (no listener) when no `health_port' is
%% configured, so a service that does not want an HTTP health endpoint simply
%% omits the config.
%%
%% `health_ip' (optional) is the address the listener binds: a string such as
%% "127.0.0.1" or an address tuple. Unset or empty, it binds every interface.
health_listener() ->
    health_listener(application:get_env(mcl_om, health_port),
                    application:get_env(mcl_om, health_ip, undefined)).

health_listener({ok, Port}, Ip) when is_integer(Port), Port > 0 ->
    Dispatch = cowboy_router:compile([{'_', mcl_om_health_handler:routes()}]),
    [ranch:child_spec(mcl_om_health_http,
                      ranch_tcp, health_socket_opts(Port, Ip),
                      cowboy_clear, #{env => #{dispatch => Dispatch}})];
health_listener(_NoPort, _Ip) ->
    [].

health_socket_opts(Port, Unset) when Unset =:= undefined; Unset =:= ""; Unset =:= <<>> ->
    [{port, Port}];
health_socket_opts(Port, Ip) when is_binary(Ip) ->
    health_socket_opts(Port, binary_to_list(Ip));
health_socket_opts(Port, Ip) when is_list(Ip) ->
    {ok, Address} = inet:parse_address(Ip),
    [{port, Port}, {ip, Address}];
health_socket_opts(Port, Ip) when is_tuple(Ip) ->
    [{port, Port}, {ip, Ip}].

worker(Module) ->
    #{
        id       => Module,
        start    => {Module, start_link, []},
        restart  => permanent,
        shutdown => 5000,
        type     => worker,
        modules  => [Module]
    }.

supervisor_child(Module) ->
    #{
        id       => Module,
        start    => {Module, start_link, []},
        restart  => permanent,
        shutdown => infinity,
        type     => supervisor,
        modules  => [Module]
    }.
