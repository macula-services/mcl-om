%%% @doc Tracks a single service's health snapshot.
%%%
%%% Exposed over HTTP by `mcl_om_health_handler' (Cowboy) at
%%% `GET /health' on port `health_port' (default 8470). Podman's
%%% HEALTHCHECK and systemd's `EXEC_START' Readiness mechanics use it.
-module(mcl_om_health).
-behaviour(gen_server).

-export([start_link/0, register/1, snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    service_module :: module() | undefined,
    last_health    :: mcl_om_service:health()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(ServiceMod) when is_atom(ServiceMod) ->
    gen_server:call(?MODULE, {register, ServiceMod}).

snapshot() ->
    gen_server:call(?MODULE, snapshot).

init([]) ->
    {ok, #state{last_health = {down, not_started}}}.

handle_call({register, Mod}, _From, S) ->
    Health = safely(fun() -> Mod:health() end),
    {reply, ok, S#state{service_module = Mod, last_health = Health}};
handle_call(snapshot, _From, #state{service_module = undefined} = S) ->
    {reply, S#state.last_health, S};
handle_call(snapshot, _From, #state{service_module = Mod} = S) ->
    Health = safely(fun() -> Mod:health() end),
    {reply, Health, S#state{last_health = Health}};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Msg, S) -> {noreply, S}.
terminate(_Reason, _State) -> ok.

safely(Fun) ->
    try Fun()
    catch C:R -> {down, {C, R}}
    end.
