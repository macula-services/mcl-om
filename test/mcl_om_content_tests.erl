%%% Unit tests for mcl_om_content's pure realm resolution and its
%%% no-mesh degrade path.
-module(mcl_om_content_tests).
-include_lib("eunit/include/eunit.hrl").

resolve_realm_prefers_override_test() ->
    Default = crypto:strong_rand_bytes(32),
    Other   = crypto:strong_rand_bytes(32),
    ?assertEqual(Other, mcl_om_content:resolve_realm(#{realm => Other}, Default)),
    ?assertEqual(Default, mcl_om_content:resolve_realm(#{}, Default)).

%%%===================================================================
%%% Degrades without a mesh — same contract as every other piece.
%%%===================================================================

content_degrades_without_mesh_test_() ->
    {setup, fun start_identity_no_seeds/0, fun stop_identity/1,
     fun(_) ->
        [
         ?_assertEqual({error, mesh_unavailable},
                       mcl_om_content:put(<<"hello">>)),
         ?_assertEqual({error, mesh_unavailable},
                       mcl_om_content:get(<<1, 16#55, "not-a-real-mcid">>)),
         ?_assertEqual({error, mesh_unavailable},
                       mcl_om_content:start_feeder(some_module, <<"hello">>)),
         ?_assertEqual({error, mesh_unavailable},
                       mcl_om_content:start_downloader(
                         some_module, <<1, 16#55, "not-a-real-mcid">>))
        ]
     end}.

start_identity_no_seeds() ->
    application:unset_env(mcl_om, station_seeds),
    application:unset_env(mcl_om, realm),
    {ok, I} = mcl_om_identity:start_link(),
    I.

stop_identity(I) ->
    try gen_server:stop(I) catch _:_ -> ok end,
    ok.
