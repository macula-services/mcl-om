%%% @doc Canonical reckon-db + evoq wiring helper for hecate-services.
%%%
%%% Encapsulates the "start a store, wait for it, start the
%%% per-store evoq subscription" pattern documented as MANDATORY in
%%% `hecate-social/hecate-corpus/skills/ANTIPATTERNS_EVENT_SOURCING.md'.
%%%
%%% Services don't call this module directly — `mcl_om:boot/1'
%%% dispatches here when the service module exports the optional
%%% `store_id/0' + `data_dir/0' callbacks from `mcl_om_service'.
%%%
%%% The sys.config for any service that uses this helper MUST also
%%% set evoq's adapter to reckon_evoq_adapter:
%%%
%%%   {evoq, [
%%%       {event_store_adapter, reckon_evoq_adapter},
%%%       {subscription_adapter, reckon_evoq_adapter},
%%%       {store_id, my_service_store},   %% fallback for dispatch
%%%       {consistency, eventual}
%%%   ]}
%%%
%%% Without that block, evoq crashes on first dispatch with
%%% `{not_configured, event_store_adapter}'. mcl_om can't inject
%%% it at runtime because evoq starts as a release-boot application
%%% before any service's start/2 runs.
-module(mcl_om_store).

-include_lib("reckon_db/include/reckon_db.hrl").

-export([ensure/2,
         ensure/3,
         ensure/4,
         ensure/5,
         ensure_store/2,
         ensure_store/3,
         ensure_store/4,
         ensure_store/5,
         ensure_subscription/1,
         wait_for_store/2]).

-define(DEFAULT_TIMEOUT_MS, 30_000).

%% @doc One-call wiring: ensure the store + the subscription. Called
%% by mcl_om:boot/1 when the service module declares store_id/0
%% and data_dir/0.
-spec ensure(atom(), file:filename_all()) -> ok | {error, term()}.
ensure(StoreId, DataDir) when is_atom(StoreId) ->
    ensure(StoreId, DataDir, []).

%% @doc As ensure/2, but installs the given reckon-db secondary index
%% declarations on the store (so CCC payload indexes are declared at
%% start). Pass [] for a store with no secondary indexes.
-spec ensure(atom(), file:filename_all(), [term()]) -> ok | {error, term()}.
ensure(StoreId, DataDir, Indexes) when is_atom(StoreId), is_list(Indexes) ->
    ensure(StoreId, DataDir, Indexes, single).

%% @doc As ensure/3, but starts the store in the given mode. `cluster'
%% enables reckon-db's discovery + Ra clustering (a store spans every
%% node that starts it under the same store_id); `single' is a
%% standalone store. Driven by the optional store_mode/0 service callback.
-spec ensure(atom(), file:filename_all(), [term()], single | cluster) ->
    ok | {error, term()}.
ensure(StoreId, DataDir, Indexes, Mode) when is_atom(StoreId), is_list(Indexes) ->
    ensure(StoreId, DataDir, Indexes, Mode, disabled).

%% @doc As ensure/4, with an explicit reckon-db integrity config
%% (`disabled' or `#{enabled => true, key_source => ...}'). Driven by the
%% optional store_integrity/0 service callback.
-spec ensure(atom(), file:filename_all(), [term()], single | cluster, term()) ->
    ok | {error, term()}.
ensure(StoreId, DataDir, Indexes, Mode, Integrity)
  when is_atom(StoreId), is_list(Indexes) ->
    case ensure_store(StoreId, DataDir, Indexes, Mode, Integrity) of
        ok           -> ensure_subscription(StoreId);
        {error, _}=E -> E
    end.

%% @doc Idempotent. Starts a `single'-mode reckon_db_store at
%% `<DataDir>/<StoreId>/' and waits for it to register.
-spec ensure_store(atom(), file:filename_all()) -> ok | {error, term()}.
ensure_store(StoreId, DataDir) when is_atom(StoreId) ->
    ensure_store(StoreId, DataDir, []).

-spec ensure_store(atom(), file:filename_all(), [term()]) -> ok | {error, term()}.
ensure_store(StoreId, DataDir, Indexes) when is_atom(StoreId), is_list(Indexes) ->
    ensure_store(StoreId, DataDir, Indexes, single).

-spec ensure_store(atom(), file:filename_all(), [term()], single | cluster) ->
    ok | {error, term()}.
ensure_store(StoreId, DataDir, Indexes, Mode) when is_atom(StoreId), is_list(Indexes) ->
    ensure_store(StoreId, DataDir, Indexes, Mode, disabled).

-spec ensure_store(atom(), file:filename_all(), [term()], single | cluster, term()) ->
    ok | {error, term()}.
ensure_store(StoreId, DataDir, Indexes, Mode, Integrity)
  when is_atom(StoreId), is_list(Indexes) ->
    SubDir = filename:join(DataDir, atom_to_list(StoreId)),
    ok = filelib:ensure_path(SubDir),
    Config = #store_config{
        store_id          = StoreId,
        data_dir          = SubDir,
        mode              = Mode,
        indexes           = Indexes,
        integrity         = Integrity,
        writer_pool_size  = 5,
        reader_pool_size  = 5,
        gateway_pool_size = 1,
        options           = #{}
    },
    case reckon_db_sup:start_store(Config) of
        {ok, _Pid}                       -> wait_for_store(StoreId, ?DEFAULT_TIMEOUT_MS);
        {error, {already_started, _Pid}} -> ok;
        {error, Reason}                  -> {error, {start_store_failed, Reason}}
    end.

%% @doc Block until the store is registered with reckon_db, or the
%% deadline passes.
-spec wait_for_store(atom(), pos_integer()) -> ok | {error, term()}.
wait_for_store(StoreId, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(StoreId, Deadline).

wait_loop(StoreId, Deadline) ->
    wait_ready(lists:member(StoreId, safe_which_stores()), StoreId, Deadline).

wait_ready(true, _StoreId, _Deadline) ->
    ok;
wait_ready(false, StoreId, Deadline) ->
    wait_retry(erlang:monotonic_time(millisecond) > Deadline, StoreId, Deadline).

wait_retry(true, StoreId, _Deadline) ->
    {error, {store_not_ready, StoreId}};
wait_retry(false, StoreId, Deadline) ->
    timer:sleep(100),
    wait_loop(StoreId, Deadline).

safe_which_stores() ->
    try reckon_db_sup:which_stores()
    catch _:_ -> []
    end.

%% @doc Start the per-store evoq subscription. Idempotent.
-spec ensure_subscription(atom()) -> ok | {error, term()}.
ensure_subscription(StoreId) when is_atom(StoreId) ->
    case evoq_store_subscription:start_link(StoreId) of
        {ok, _Pid}                       -> ok;
        {error, {already_started, _Pid}} -> ok;
        {error, Reason}                  -> {error, {start_subscription_failed, Reason}}
    end.
