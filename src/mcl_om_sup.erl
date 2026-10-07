%%% @doc Top-level supervisor for mcl-om.
%%%
%%% Owns five workers and one nested supervisor, all shared by the
%%% hosting service:
%%%   1. mcl_om_identity  — keeps the realm cert + UCAN cached
%%%   2. mcl_om_capabilities — fans capability advertisements out
%%%   3. mcl_om_guard        — the inbound guard''s counters, audit ring
%%%                            and alert facts (mcl-om#13), up before
%%%                            capabilities so no inbound call can outrun
%%%                            its table
%%%   4. mcl_om_pubsub_sup — dynamic supervisor of this service''s
%%%      macula_subscriber children (piece D)
%%%   5. mcl_om_pubsub_subscriptions — reconciles the desired
%%%      subscription set against (4)'s actual running children
%%%   6. mcl_om_health    — bookkeeping for /health responses
%%%
%%% and, when `health_port' is configured, the Cowboy listener that actually
%%% serves `GET /health' on it (so Podman''s HEALTHCHECK and k8s liveness probes
%%% have something to hit).
%%%
%%% When station seeds are configured, also the mesh pool itself
%%% (piece A, guides/mesh_native_services.md): an ordinary
%%% `restart => permanent' child wrapping 'macula_client:connect/2'
%%% (via `mcl_om_identity:start_mesh_pool/0', which needs this
%%% gen_server''s already-loaded keypair — hence positioned right after
%%% it). A pool crash is no longer this app''s problem to notice and
%%% react to; OTP just restarts the child, same as any other. With no
%%% seeds configured the child is omitted entirely — same `health_
%%% listener/0' pattern as the HTTP listener below — so
%%% `mcl_om_identity:macula_client/0' degrades to '{error,
%%% no_client}' exactly as it did before this piece, not a
%%% harmlessly-idle pool masking "nothing configured" as "connected".
-module(mcl_om_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
%% The /health listener's start function, named in its child spec.
-export([start_health_socket/2]).

-ifdef(TEST).
-export([health_socket_opts/2, health_listener/0]).
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
        worker(mcl_om_identity),
        %% The nonces of accepted ownership proofs (mcl_om_ownership_proof),
        %% so an identical proof is accepted once.
        worker(mcl_om_ownership_proof_replay)
    ] ++ mesh_pool_children() ++ [
        %% The inbound guard (mcl-om#13): its ETS must exist before any
        %% handler can answer a call, so it starts ahead of capabilities.
        worker(mcl_om_guard),
        worker(mcl_om_capabilities),
        worker(mcl_om_claim),
        supervisor_child(mcl_om_pubsub_sup),
        worker(mcl_om_pubsub_subscriptions),
        worker(mcl_om_health)
    ] ++ health_listener(),
    {ok, {SupFlags, Children}}.

%% The mesh pool (piece A): present only when seeds are configured, so
%% a service with none keeps today''s exact degrade contract
%% (`mcl_om_identity:macula_client/0' -> '{error, no_client}')
%% rather than holding a real-but-permanently-idle pool that would
%% make "nothing configured" indistinguishable from "connected" to any
%% caller checking `mesh_handles/0' alone. Positioned right after
%% `mcl_om_identity' in the list above -- its start function reads
%% that gen_server''s already-loaded keypair.
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

%% The GET /health HTTP endpoint, dispatching to mcl_om_health_handler. The
%% handler and its routes existed but nothing ever mounted them, so /health was
%% dead code and every service reported unhealthy to Podman/k8s.
%%
%% ⚠ NO SERVICE LISTENS ON A PORT JUST TO BE HEALTH-CHECKED. With
%% `health_socket' set (a path such as "/run/mcl/health.sock") the listener is
%% that Unix socket and nothing else: no TCP listener runs, whatever
%% `health_port' says. The container's health check reaches it with
%% `curl -fsS --unix-socket <path> http://localhost/health'. A stale socket file
%% left by a previous container is replaced, and the socket is mode 0600, so
%% only the service's own user may connect.
%%
%% Without `health_socket', `health_port' is the fallback: a TCP listener there,
%% on `health_ip' (optional: a string such as "127.0.0.1" or an address tuple;
%% unset or empty binds every interface). Neither set: no listener, for a
%% service that wants no health endpoint.
-spec health_listener() -> [supervisor:child_spec()].
health_listener() ->
    health_listener(socket_path(application:get_env(mcl_om, health_socket, undefined)),
                    application:get_env(mcl_om, health_port),
                    application:get_env(mcl_om, health_ip, undefined)).

health_listener({ok, Path}, _Port, _Ip) ->
    [#{id       => mcl_om_health_http,
       start    => {?MODULE, start_health_socket, [Path, health_dispatch()]},
       restart  => permanent,
       shutdown => infinity,
       type     => supervisor,
       modules  => [ranch_listener_sup]}];
health_listener(none, {ok, Port}, Ip) when is_integer(Port), Port > 0 ->
    [ranch:child_spec(mcl_om_health_http,
                      ranch_tcp, health_socket_opts(Port, Ip),
                      cowboy_clear, #{env => #{dispatch => health_dispatch()}})];
health_listener(none, _NoPort, _Ip) ->
    [].

%% A configured socket path, or `none'. Empty counts as unset.
socket_path(Unset) when Unset =:= undefined; Unset =:= ""; Unset =:= <<>> -> none;
socket_path(Path) when is_binary(Path) -> {ok, binary_to_list(Path)};
socket_path(Path) when is_list(Path) -> {ok, Path}.

health_dispatch() ->
    cowboy_router:compile([{'_', mcl_om_health_handler:routes()}]).

%% @doc Starts the /health listener on the Unix socket `Path': the stale file a
%% previous container left is removed first (a bind on an existing path fails),
%% and the socket is made mode 0600 once it exists.
-spec start_health_socket(file:filename(), cowboy_router:dispatch_rules()) -> {ok, pid()} | {error, term()}.
start_health_socket(Path, Dispatch) ->
    ok = filelib:ensure_dir(Path),
    ok = without_stale(file:delete(Path)),
    {M, F, A} = start_of(ranch:child_spec(mcl_om_health_http, ranch_tcp,
                                          [{ip, {local, Path}}, {port, 0}],
                                          cowboy_clear, #{env => #{dispatch => Dispatch}})),
    owner_only(apply(M, F, A), Path).

%% ranch gives its child spec as a map or as the classic tuple.
start_of(#{start := Start}) -> Start;
start_of({_Id, Start, _Restart, _Shutdown, _Type, _Modules}) -> Start.

without_stale(ok) -> ok;
without_stale({error, enoent}) -> ok.

owner_only({ok, Pid}, Path) ->
    ok = file:change_mode(Path, 8#600),
    {ok, Pid};
owner_only(Error, _Path) ->
    Error.

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
