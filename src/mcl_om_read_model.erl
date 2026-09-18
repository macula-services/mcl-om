%%% @doc Canonical barrel_docdb read-model wiring for hecate-services.
%%%
%%% Encapsulates "open (or create) a database at data_dir/read_model_id".
%%% Services don't call this module directly — `mcl_om:boot/1'
%%% dispatches here when the service module exports the optional
%%% `read_model_id/0' + `data_dir/0' callbacks from `mcl_om_service',
%%% additionally arming barrel_docdb's native TTL sweeper when the service
%%% also exports `read_model_ttl_sweep/0'.
%%%
%%% After boot, a service (its PRJ code, typically) reads/writes the read
%%% model with `barrel_docdb' directly, using the same `read_model_id/0'
%%% binary as the database name — barrel_docdb accepts the name or the pid
%%% interchangeably everywhere, so there is no separate handle to thread
%%% through. This mirrors `mcl_om_store', which likewise hands nothing
%%% back: the service already knows its own store_id/read_model_id.
-module(mcl_om_read_model).

-export([ensure/2, ensure/3]).

%% @doc Idempotent. Opens (creating on first boot) a barrel_docdb database
%% named `DbName' at `<DataDir>/<DbName>/', with no TTL sweep (barrel_docdb's
%% default: nothing expires). Equivalent to `ensure(DbName, DataDir, disabled)'.
-spec ensure(binary(), file:filename_all()) -> ok | {error, term()}.
ensure(DbName, DataDir) ->
    ensure(DbName, DataDir, disabled).

%% @doc Same as `ensure/2', additionally arming barrel_docdb's native
%% per-document TTL sweeper when `TtlSweep' is `#{interval_ms := integer(),
%% batch := integer()}' rather than `disabled'. Arming the sweeper alone
%% expires nothing — documents also need `expires_at' set in their own
%% `put_doc/3' `Opts' — see the `read_model_ttl_sweep/0' callback in
%% {@link mcl_om_service}.
-spec ensure(binary(), file:filename_all(),
             disabled | #{interval_ms := pos_integer(), batch := pos_integer()}) ->
    ok | {error, term()}.
ensure(DbName, DataDir, TtlSweep) when is_binary(DbName) ->
    SubDir = filename:join(DataDir, binary_to_list(DbName)),
    ok = filelib:ensure_path(SubDir),
    Opts = maps:merge(#{data_dir => SubDir}, ttl_sweep_opts(TtlSweep)),
    opened(barrel_docdb:create_db(DbName, Opts), DbName, SubDir).

ttl_sweep_opts(disabled) ->
    #{};
ttl_sweep_opts(#{interval_ms := Interval, batch := Batch})
  when is_integer(Interval), Interval > 0, is_integer(Batch), Batch > 0 ->
    #{ttl_sweep_interval => Interval, ttl_sweep_batch => Batch}.

%% First boot: create_db opens it too (barrel keeps it open until closed or
%% the app stops). Later boots: the in-memory registry is empty again (the
%% prior process is gone), so create_db retries against the same on-disk
%% RocksDB directory and reopens it — that IS the "ensure" semantics, same
%% shape as reckon_db_sup:start_store's {already_started} short-circuit.
opened({ok, _Pid}, _DbName, _SubDir) ->
    ok;
opened({error, already_exists}, _DbName, _SubDir) ->
    ok;
opened({error, Reason}, DbName, SubDir) ->
    {error, {read_model_open_failed, DbName, SubDir, Reason}}.
