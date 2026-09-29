{{=<% %>=}}%% @doc OTP application entry.
%%
%% mcl_om:boot/1 wires the mesh, the realm identity and health, then starts
%% this service. It opens NO store and starts no reckon-db or evoq application:
%% persistence is each service's own choice (mcl_om 0.35.0, mcl-om#10).
<%^store%>%%
%% STORELESS as generated. To give this service an event store, scaffold with
%% `store=1' and compare: the service then declares its own store dependencies
%% and this module opens the store before mcl_om:boot/1.
<%/store%><%#store%>%%
%% THIS SERVICE OWNS A reckon-db STORE, and this module opens it in start/2
%% BEFORE mcl_om:boot/1, so the store and its evoq subscription are up when the
%% service's own start/1 runs its projections and process managers. The wiring
%% below is this service's own copy of the canonical pattern (start the store,
%% wait until reckon_db lists it, start the per-store evoq subscription); the
%% store's name, directory, indexes, mode and integrity come from
%% <%name%>_service.
%%
%% ⚠ config/sys.config.src MUST CARRY THE `evoq' BLOCK: the subscription reads
%% the global log through evoq, which crashes on
%% `{not_configured, event_store_adapter}' without it.
<%/store%>-module(<%name%>_app).

-behaviour(application).
<%#store%>
-include_lib("reckon_db/include/reckon_db.hrl").
<%/store%>
-export([start/2, stop/1]).

<%^store%>start(_Type, _Args) -> mcl_om:boot(<%name%>_service).
<%/store%><%#store%>start(_Type, _Args) ->
    ok = open_store(),
    mcl_om:boot(<%name%>_service).
<%/store%>
stop(_State) -> ok.
<%#store%>

%% ==========================================================================
%% The store, opened before the service boots
%% ==========================================================================

-define(STORE_READY_TIMEOUT_MS, 30_000).

%% A store that cannot open stops the boot, naming why: a service whose store
%% is not there would otherwise start green and lose every command.
open_store() ->
    S = <%name%>_service,
    opened(ensure_store(S:store_id(), S:data_dir(), S:store_indexes(), S:store_mode(),
                        S:store_integrity())).

opened(ok) -> ok;
opened({error, Why}) -> error({<%name%>_store_failed, Why}).

ensure_store(StoreId, DataDir, Indexes, Mode, Integrity) ->
    subscribed(started(StoreId, DataDir, Indexes, Mode, Integrity), StoreId).

subscribed(ok, StoreId) -> ensure_subscription(StoreId);
subscribed({error, _} = Err, _StoreId) -> Err.

%% Idempotent: a store already running is fine. It lives at
%% <DataDir>/<StoreId>/.
started(StoreId, DataDir, Indexes, Mode, Integrity) ->
    SubDir = filename:join(DataDir, atom_to_list(StoreId)),
    ok = filelib:ensure_path(SubDir),
    Config = #store_config{store_id = StoreId,
                           data_dir = SubDir,
                           mode = Mode,
                           indexes = Indexes,
                           integrity = Integrity,
                           writer_pool_size = 5,
                           reader_pool_size = 5,
                           gateway_pool_size = 1,
                           options = #{}},
    store_start(reckon_db_sup:start_store(Config), StoreId).

store_start({ok, _Pid}, StoreId) -> wait_for_store(StoreId);
store_start({error, {already_started, _Pid}}, _StoreId) -> ok;
store_start({error, Reason}, _StoreId) -> {error, {start_store_failed, Reason}}.

%% Blocks until reckon_db lists the store, or the deadline passes.
wait_for_store(StoreId) ->
    wait_loop(StoreId, erlang:monotonic_time(millisecond) + ?STORE_READY_TIMEOUT_MS).

wait_loop(StoreId, Deadline) ->
    wait_ready(listed(StoreId), StoreId, Deadline).

%% try/catch on purpose: reckon_db_sup can refuse the call while reckon_db is
%% still starting, and that means "not listed yet", which the deadline covers.
listed(StoreId) ->
    try lists:member(StoreId, reckon_db_sup:which_stores())
    catch _:_ -> false
    end.

wait_ready(true, _StoreId, _Deadline) ->
    ok;
wait_ready(false, StoreId, Deadline) ->
    wait_retry(erlang:monotonic_time(millisecond) > Deadline, StoreId, Deadline).

wait_retry(true, StoreId, _Deadline) ->
    {error, {store_not_ready, StoreId}};
wait_retry(false, StoreId, Deadline) ->
    timer:sleep(100),
    wait_loop(StoreId, Deadline).

%% The per-store evoq subscription, so projections and process managers receive
%% events. Idempotent.
ensure_subscription(StoreId) ->
    subscription(evoq_store_subscription:start_link(StoreId)).

subscription({ok, _Pid}) -> ok;
subscription({error, {already_started, _Pid}}) -> ok;
subscription({error, Reason}) -> {error, {start_subscription_failed, Reason}}.
<%/store%>
