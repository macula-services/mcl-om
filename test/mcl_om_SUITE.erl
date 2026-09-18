%%% @doc Smoke tests for mcl_om.
-module(mcl_om_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([behaviour_attributes/1, boot_dummy_service/1, health_snapshot/1,
         boot_dummy_service_with_read_model/1,
         boot_dummy_service_with_ttl_sweep/1]).

all() ->
    [behaviour_attributes, boot_dummy_service, health_snapshot,
     boot_dummy_service_with_read_model,
     boot_dummy_service_with_ttl_sweep].

init_per_suite(Config) ->
    %% Bind the /health listener on an OS-assigned ephemeral port so the
    %% suite never collides with a real service (or a prior run's beam)
    %% holding the production default. The health tests exercise
    %% mcl_om:health/0, not the HTTP socket, so the port is irrelevant.
    application:load(mcl_om),
    application:set_env(mcl_om, health_port, 0),
    {ok, _} = application:ensure_all_started(mcl_om),
    Config.

end_per_suite(_Config) ->
    application:stop(mcl_om),
    ok.

behaviour_attributes(_Config) ->
    %% mcl_om_service declares 6 required callbacks + 10 optional ones
    %% (store_id/0, data_dir/0, store_indexes/0, store_mode/0,
    %% store_integrity/0, read_model_id/0, read_model_ttl_sweep/0,
    %% subscriptions/0) for CMD/PRJ services that wire a reckon-db store, a
    %% barrel_docdb read model, and/or a declarative pubsub subscription
    %% set, plus describe_rpc_capabilities/0 and
    %% describe_pubsub_capabilities/0 for the describe_capabilities RPC.
    %% behaviour_info(callbacks) returns all 16.
    Callbacks = mcl_om_service:behaviour_info(callbacks),
    ?assertEqual(16, length(Callbacks)),
    Names = lists:sort(lists:map(fun({N, _A}) -> N end, Callbacks)),
    Expected = lists:sort([info, start, stop, health, capabilities,
                           identity_spec, store_id, data_dir, store_indexes,
                           store_mode, store_integrity, read_model_id,
                           read_model_ttl_sweep, subscriptions,
                           describe_rpc_capabilities,
                           describe_pubsub_capabilities]),
    ?assertEqual(Expected, Names),
    %% The store-wiring, read-model-wiring, subscriptions and describe
    %% callbacks must be the optional set.
    Optional = lists:sort(mcl_om_service:behaviour_info(optional_callbacks)),
    ?assertEqual(lists:sort([{store_id, 0}, {data_dir, 0},
                             {store_indexes, 0}, {store_mode, 0},
                             {store_integrity, 0}, {read_model_id, 0},
                             {read_model_ttl_sweep, 0}, {subscriptions, 0},
                             {describe_rpc_capabilities, 0},
                             {describe_pubsub_capabilities, 0}]),
                 Optional).

boot_dummy_service(_Config) ->
    {ok, _Pid} = mcl_om:boot(dummy_service, #{}),
    ?assertEqual(dummy_service, mcl_om:service_module()),
    Caps = mcl_om_capabilities:list(),
    ?assertEqual([#{name => <<"dummy.do_thing">>, version => 1}], Caps).

health_snapshot(_Config) ->
    ?assertEqual(ok, mcl_om:health()).

boot_dummy_service_with_read_model(Config) ->
    %% Point the fixture's data_dir/0 at CT's own per-suite priv_dir so the
    %% database lands somewhere CT already owns and cleans up.
    true = os:putenv("MCL_OM_CT_DATA_DIR", ?config(priv_dir, Config)),
    {ok, _Pid} = mcl_om:boot(dummy_read_model_service, #{}),
    ?assertEqual({ok, <<"dummy_read_model_chunks">>}, mcl_om:read_model()),
    %% Not just "the callback wired" — the database is genuinely open and
    %% usable: round-trip a real document through it.
    {ok, DbName} = mcl_om:read_model(),
    {ok, Written} = barrel_docdb:put_doc(DbName, #{<<"kind">> => <<"probe">>}),
    Id = maps:get(<<"id">>, Written),
    {ok, Read} = barrel_docdb:get_doc(DbName, Id),
    ?assertEqual(<<"probe">>, maps:get(<<"kind">>, Read)).

boot_dummy_service_with_ttl_sweep(Config) ->
    %% barrel_docdb treats an expires_at'd document as gone on every read
    %% the instant its deadline passes, UNCONDITIONALLY -- that's "lazy
    %% expiry" and it happens with or without a sweep config at all (see
    %% barrel_docdb_reader:expired/1's own doc comment: "reads treat them
    %% as gone in the meantime"). So a read-visibility assertion here
    %% would pass even if mcl_om's config passthrough were entirely
    %% broken -- it wouldn't be testing this module's code at all.
    %%
    %% What mcl_om actually owns is getting
    %% dummy_ttl_read_model_service:read_model_ttl_sweep/0's config into
    %% the create_db call so barrel_docdb's *background reclamation*
    %% timer gets armed (ttl_sweep_interval/batch, otherwise 0/off and
    %% never reclaiming disk for lazily-expired docs). db_info/1 reports
    %% back the exact config a database was created with, so assert on
    %% that boundary instead of on barrel's own already-verified expiry
    %% behavior.
    true = os:putenv("MCL_OM_CT_TTL_DATA_DIR", ?config(priv_dir, Config)),
    {ok, _Pid} = mcl_om:boot(dummy_ttl_read_model_service, #{}),
    ?assertEqual({ok, <<"dummy_ttl_read_model_chunks">>}, mcl_om:read_model()),
    {ok, DbName} = mcl_om:read_model(),
    {ok, Info} = barrel_docdb:db_info(DbName),
    DbConfig = maps:get(config, Info),
    ?assertEqual(100, maps:get(ttl_sweep_interval, DbConfig)),
    ?assertEqual(100, maps:get(ttl_sweep_batch, DbConfig)).
