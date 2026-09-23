%%% @doc Connection-lifecycle acceptance tests for piece A
%%% (`PLAN_MCL_OM_MESH_WRAPPERS.md'): the mesh pool as an ordinary
%%% `mcl_om_sup' child (`macula_client:child_spec/3'-shaped, via
%%% `mcl_om_identity:start_mesh_pool/0') instead of `mcl_om_
%%% identity''s old hand-rolled `self() ! connect' / 5s-retry /
%%% `erlang:monitor' + `DOWN' dance.
%%%
%%% Each case boots `mcl_om' as a real OTP application (not just
%%% `mcl_om_identity' standalone) with a different `station_seeds'
%%% app env, and tears the whole application down afterwards -- the
%%% only way to genuinely exercise "does the pool child get included
%%% at all" and "does OTP, not hand-rolled code, react to a pool
%%% crash", both of which are supervisor-tree-shape questions, not
%%% gen_server-state questions.
%%%
%%% Seeds here are deliberately unreachable (`127.0.0.1:1', a
%%% privileged port nothing listens on) -- these tests are about
%%% process lifecycle, not real mesh connectivity, which is what
%%% `test_live/mcl_om_mesh_pool_live_station_tests.erl' proves
%%% separately against a real demo-fleet station.
-module(mcl_om_mesh_pool_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([no_seeds_means_no_pool_child/1,
         seeds_configured_starts_pool_without_a_retry_loop/1,
         pool_crash_is_restarted_by_the_supervisor_not_hand_rolled_code/1]).

%% The 11.x seed shape: a map pinning the station's node id (D5) --
%% every dial refuses to connect without one. The pin itself is a
%% placeholder: the dial fails at the transport long before the pin is
%% ever checked.
-define(UNREACHABLE_SEED, #{host => <<"127.0.0.1">>, port => 1,
                            expected_node_id => <<0:256>>}).

%% The realm this suite's pool pins. mcl_om REFUSES to start a pool with
%% no realm trust (`mcl_om_identity:realm_trust_opts/0'), so without these
%% two the seeded cases fail on configuration before they ever reach
%% macula, and prove nothing about whether a pool starts.
-define(REALM, <<16#5A:256>>).

all() ->
    [no_seeds_means_no_pool_child,
     seeds_configured_starts_pool_without_a_retry_loop,
     pool_crash_is_restarted_by_the_supervisor_not_hand_rolled_code].

init_per_testcase(_TestCase, Config) ->
    application:load(mcl_om),
    %% Ephemeral health port per suite convention (mcl_om_SUITE) --
    %% these tests don't touch /health, but a boot must not collide
    %% with the production default.
    application:set_env(mcl_om, health_port, 0),
    application:set_env(mcl_om, realm, ?REALM),
    application:set_env(mcl_om, realm_key, realm_key_hex()),
    Config.

end_per_testcase(_TestCase, _Config) ->
    application:stop(mcl_om),
    application:unset_env(mcl_om, station_seeds),
    application:unset_env(mcl_om, realm),
    application:unset_env(mcl_om, realm_key),
    ok.

%% A real realm public key in the configured profile, hex as the deploy
%% env carries it. macula checks every pinned key is well formed for the
%% profile, so a placeholder would be refused as `{realm_trust, invalid}'.
realm_key_hex() ->
    {ok, Profile} = macula_crypto_profile:configured(),
    {ok, Key} = macula_node_keys:generate(realm, Profile),
    binary:encode_hex(macula_node_keys:public_key(Key), lowercase).

%% Acceptance (piece A): "a boot with zero configured seeds still
%% starts the service (degrades, doesn't crash)" -- and, specifically
%% to this migration, degrades to the *exact same* observable contract
%% as before it (`{error, no_client}'), not a real-but-idle pool that
%% would make "nothing configured" look like "connected".
no_seeds_means_no_pool_child(_Config) ->
    application:set_env(mcl_om, station_seeds, []),
    {ok, _} = application:ensure_all_started(mcl_om),

    ?assertEqual({error, no_client}, mcl_om:macula_client()),
    ?assertEqual(undefined, whereis(mcl_om_mesh_pool)).

%% Acceptance: "a boot with seeds present connects" -- and, the actual
%% point of piece A's boot-race question, *without the test needing to
%% poll or retry*. Under the old hand-rolled design this assertion
%% would have been flaky (client only attached after handle_info(connect)
%% ran, racing this call); under child_spec/3-shaped supervision the
%% pool is a live pid by the time application:ensure_all_started/1
%% returns, full stop -- proving the boot-race concern doesn't apply
%% to this design, not just asserting the end state eventually holds.
seeds_configured_starts_pool_without_a_retry_loop(_Config) ->
    application:set_env(mcl_om, station_seeds, [?UNREACHABLE_SEED]),
    {ok, _} = application:ensure_all_started(mcl_om),

    {ok, Pid} = mcl_om:macula_client(),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(Pid, whereis(mcl_om_mesh_pool)).

%% Acceptance: "a station restart mid-run reconnects without service
%% restart" -- covered at the SDK level already (each seed link dials
%% and retries forever on its own timer, confirmed by reading
%% macula_client.erl directly; per-link respawn transparency to
%% subscribers is regression-tested in macula's own
%% macula_link_respawn_replay_tests.erl). What piece A actually adds
%% on top is this: if the *pool process itself* ever dies, an ordinary
%% supervised child recovers with zero code in this repo, where the
%% old design needed a hand-rolled monitor + DOWN handler to notice
%% and reconnect. Proven directly: kill the pool pid and confirm
%% mcl_om_sup, not mcl_om_identity, brings a new one up.
pool_crash_is_restarted_by_the_supervisor_not_hand_rolled_code(_Config) ->
    application:set_env(mcl_om, station_seeds, [?UNREACHABLE_SEED]),
    {ok, _} = application:ensure_all_started(mcl_om),
    {ok, OldPid} = mcl_om:macula_client(),

    Ref = monitor(process, OldPid),
    exit(OldPid, kill),
    receive
        {'DOWN', Ref, process, OldPid, killed} -> ok
    after 2_000 -> error(pool_did_not_die)
    end,

    NewPid = await_new_pool(OldPid, 50),
    ?assertNotEqual(OldPid, NewPid),
    ?assert(is_process_alive(NewPid)).

await_new_pool(_OldPid, 0) ->
    error(pool_not_restarted);
await_new_pool(OldPid, N) ->
    case mcl_om:macula_client() of
        {ok, Pid} when is_pid(Pid), Pid =/= OldPid -> Pid;
        _ ->
            timer:sleep(100),
            await_new_pool(OldPid, N - 1)
    end.
