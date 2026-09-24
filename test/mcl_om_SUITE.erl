%%% @doc Smoke tests for mcl_om.
-module(mcl_om_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([behaviour_attributes/1, boot_dummy_service/1, health_snapshot/1,
         boot_refuses_a_service_without_an_org/1]).

all() ->
    [behaviour_attributes, boot_dummy_service, health_snapshot,
     boot_refuses_a_service_without_an_org].

init_per_suite(Config) ->
    %% Bind the /health listener on an OS-assigned ephemeral port so the
    %% suite never collides with a real service (or a prior run's beam)
    %% holding the production default. The health tests exercise
    %% mcl_om:health/0, not the HTTP socket, so the port is irrelevant.
    application:load(mcl_om),
    application:set_env(mcl_om, health_port, 0),
    %% Every service boots with an org (boot_refuses_a_service_without_an_org).
    application:set_env(mcl_om, org, <<"dummy">>),
    {ok, _} = application:ensure_all_started(mcl_om),
    Config.

end_per_suite(_Config) ->
    application:stop(mcl_om),
    ok.

behaviour_attributes(_Config) ->
    %% mcl_om_service declares 6 required callbacks + 8 optional ones
    %% (store_id/0, data_dir/0, store_indexes/0, store_mode/0,
    %% store_integrity/0, subscriptions/0) for CMD/PRJ services that wire a
    %% reckon-db store and/or a declarative pubsub subscription set, plus
    %% describe_rpc_capabilities/0 and describe_pubsub_capabilities/0 for the
    %% describe_capabilities RPC. behaviour_info(callbacks) returns all 14.
    %% A read model is the service's own business since 0.27.0: no
    %% read_model_id/0 or read_model_ttl_sweep/0.
    Callbacks = mcl_om_service:behaviour_info(callbacks),
    ?assertEqual(14, length(Callbacks)),
    Names = lists:sort(lists:map(fun({N, _A}) -> N end, Callbacks)),
    Expected = lists:sort([info, start, stop, health, capabilities,
                           identity_spec, store_id, data_dir, store_indexes,
                           store_mode, store_integrity, subscriptions,
                           describe_rpc_capabilities,
                           describe_pubsub_capabilities]),
    ?assertEqual(Expected, Names),
    %% The store-wiring, subscriptions and describe
    %% callbacks must be the optional set.
    Optional = lists:sort(mcl_om_service:behaviour_info(optional_callbacks)),
    ?assertEqual(lists:sort([{store_id, 0}, {data_dir, 0},
                             {store_indexes, 0}, {store_mode, 0},
                             {store_integrity, 0}, {subscriptions, 0},
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

%% A release whose MCL_ORG was never set carries the literal "${MCL_ORG}". The
%% service must not come up at all: running green while advertising nothing
%% and never claiming is how a bot on beam01 went unnoticed. mcl_om reads the
%% org once, at start, so it is restarted around the case.
boot_refuses_a_service_without_an_org(_Config) ->
    ok = application:stop(mcl_om),
    ok = application:set_env(mcl_om, org, <<"${MCL_ORG}">>),
    {ok, _} = application:ensure_all_started(mcl_om),
    try
        ?assertError({mcl_om_org_not_configured, #{got := <<"${MCL_ORG}">>}},
                     mcl_om:boot(dummy_service, #{}))
    after
        ok = application:stop(mcl_om),
        ok = application:set_env(mcl_om, org, <<"dummy">>),
        {ok, _} = application:ensure_all_started(mcl_om)
    end.
