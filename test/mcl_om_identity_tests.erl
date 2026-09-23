%%% Unit tests for mcl_om_identity: node key resolution
%%% (mcl_om_identity:node_key_from/1) -- generate on a MISSING key file,
%%% refuse any other load failure. Confirmed live: without generate-on-
%%% missing, a service whose job is a direct-dial RPC/Streaming provider
%%% (hecate-tube) silently never advertises anything -- identity_key/0
%%% stays {error, no_identity_key} forever, unless something out-of-band
%%% provisions the file first. Generating on any OTHER failure would
%%% silently replace the service's identity, so those stop the service
%%% instead.
%%% Also configured_seeds/0 (piece A) and the non-raising accessor
%%% contract (piece H) -- see PLAN_MCL_OM_MESH_WRAPPERS.md.
%%% The 11.x port: fixtures generate real pq_hybrid node keys
%%% (macula_node_keys), and the seed contract carries the station node
%%% ids every dial must be pinned to.
-module(mcl_om_identity_tests).
-include_lib("eunit/include/eunit.hrl").

tmp_path() ->
    Name = binary:encode_hex(crypto:strong_rand_bytes(8)),
    filename:join("/tmp", <<"mcl_om_identity_test_", Name/binary, ".key">>).

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.

%% A real pq_hybrid node key, generated at difficulty 0 (no puzzle
%% grind): the puzzle is generate_and_save/1's own concern, exercised
%% by the first-boot test below, not a tax on every fixture.
node_key() ->
    {ok, K} = macula_node_keys:generate(identity, profile(),
                                        #{puzzle_difficulty => 0}),
    K.

unconfigured_path_stays_ephemeral_test() ->
    ?assertEqual(undefined, mcl_om_identity:node_key_from(undefined)).

first_boot_generates_and_persists_a_keypair_test() ->
    Path = tmp_path(),
    ?assertEqual(false, filelib:is_regular(Path)),

    Key = mcl_om_identity:node_key_from({ok, Path}),

    ?assertMatch(#{purpose := identity, profile := _, components := [_ | _]}, Key),
    ?assert(filelib:is_regular(Path)),
    %% and it's genuinely loadable back via the same path macula_node_keys
    %% itself would use -- not just "a file exists".
    ?assertEqual({ok, Key}, macula_node_keys:load(Path, identity, profile())),
    %% Regression: a non-puzzle-hardened identity's handshake gets
    %% closed with puzzle_invalid by every station in this fleet,
    %% forever -- confirmed live, see generate_and_save/1's own comment.
    {ok, NodeId} = macula_node_keys:node_id(Key),
    ?assert(macula_node_keys:puzzle_solved(NodeId,
                                           macula_node_keys:puzzle_difficulty())),
    file:delete(Path).

existing_keypair_is_loaded_not_regenerated_test() ->
    Path = tmp_path(),
    Original = node_key(),
    ok = macula_node_keys:save(Path, Original),

    Loaded = mcl_om_identity:node_key_from({ok, Path}),

    ?assertEqual(Original, Loaded),
    file:delete(Path).

%% A key file that exists but will not load is refused and left untouched.
%% Regenerating would give the service a new node id and overwrite its
%% real key: macula refuses key files readable by group or others, so a
%% permissions mistake would otherwise become a silent identity change.
corrupt_keypair_file_is_refused_and_left_untouched_test() ->
    Path = tmp_path(),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"not a real key file">>),

    ?assertMatch({error, {identity_key_unloadable, Path, _}},
                 mcl_om_identity:node_key_from({ok, Path})),
    ?assertEqual({ok, <<"not a real key file">>}, file:read_file(Path)),
    file:delete(Path).

%% Same refusal for a path that exists but is no key file at all. Unlike
%% an unreadable-mode file, this stays a real case when tests run as root.
key_path_that_is_a_directory_is_refused_test() ->
    Path = tmp_path(),
    ok = file:make_dir(Path),

    ?assertMatch({error, {identity_key_unloadable, Path, _}},
                 mcl_om_identity:node_key_from({ok, Path})),
    ?assert(filelib:is_dir(Path)),
    ?assertEqual({ok, []}, file:list_dir(Path)),
    file:del_dir(Path).

%% At boot the refusal stops mcl_om_identity itself, so mcl_om_sup,
%% and with it the service, does not start -- and the file stays as it was.
unloadable_key_file_stops_the_identity_process_test_() ->
    {setup, fun corrupt_key_configured/0, fun restore_key_config/1,
     fun({Path, _Saved}) ->
        [?_assertMatch({error, {identity_key_unloadable, Path, _}}, start_in_helper()),
         ?_assertEqual({ok, <<"not a real key file">>}, file:read_file(Path)),
         ?_assertEqual(undefined, whereis(mcl_om_identity))]
     end}.

corrupt_key_configured() ->
    Running = ensure_identity_not_running(),
    SavedPath = application:get_env(mcl_om, identity_key_path),
    Path = tmp_path(),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"not a real key file">>),
    ok = application:set_env(mcl_om, identity_key_path, Path),
    {Path, {Running, SavedPath}}.

restore_key_config({Path, {Running, SavedPath}}) ->
    restore_key_path(SavedPath),
    file:delete(Path),
    restore_identity(Running).

restore_key_path(undefined)  -> application:unset_env(mcl_om, identity_key_path);
restore_key_path({ok, Path}) -> application:set_env(mcl_om, identity_key_path, Path).

%% start_link/0 from a helper that traps exits, so a refused start
%% (init/1 returning {stop, _}) can't take the test process down with it.
start_in_helper() ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        Parent ! {start_result, self(), mcl_om_identity:start_link()}
    end),
    receive
        {start_result, Pid, Result} ->
            receive {'DOWN', Ref, process, Pid, _} -> ok after 2_000 -> ok end,
            Result
    after 10_000 ->
        timeout
    end.

%% mcl_om_identity:configured_seeds/0 -- exported for mcl_om_sup's
%% own use deciding whether the mesh pool child (piece A,
%% PLAN_MCL_OM_MESH_WRAPPERS.md) belongs in the children list at
%% all, which makes a wrong answer here higher-stakes than before this
%% piece: it used to only pick which seeds a connect attempt used, now
%% it decides whether a pool is started at all.
%%
%% The 11.x contract: seeds are maps #{host, port, expected_node_id},
%% and an env seed without a matching node-id pin is refused outright
%% (D5 -- an unpinned dial can never connect).
configured_seeds_test_() ->
    {setup, fun clear_seed_config/0, fun restore_seed_config/1,
     fun(_) ->
         [
          ?_assertEqual([], seeds(false, false, undefined)),
          %% app env seeds pass through as configured
          ?_assertEqual([#{host => <<"a">>, port => 1, expected_node_id => <<1:256>>}],
                        seeds(false, false,
                              [#{host => <<"a">>, port => 1, expected_node_id => <<1:256>>}])),
          %% env seeds pair with env node ids by index; ports default 4433
          ?_assertEqual([#{host => <<"a">>, port => 4433, expected_node_id => <<1:256>>},
                         #{host => <<"b">>, port => 2, expected_node_id => <<2:256>>}],
                        seeds("a,b:2", node_id_hex(1) ++ "," ++ node_id_hex(2), undefined)),
          %% whitespace and empty slots are tolerated
          ?_assertEqual([#{host => <<"a">>, port => 4433, expected_node_id => <<1:256>>}],
                        seeds(" a ,, ", node_id_hex(1) ++ " ,, ", undefined)),
          %% env seeds win over the app env
          ?_assertEqual([#{host => <<"env">>, port => 4433, expected_node_id => <<1:256>>}],
                        seeds("env", node_id_hex(1),
                              [#{host => <<"app">>, port => 1, expected_node_id => <<2:256>>}])),
          %% a seed without a matching pin is refused: it would be a
          %% dial that can never connect
          ?_assertError({mcl_om, seeds_without_node_ids},
                        seeds("env", false, undefined)),
          ?_assertError({mcl_om, seeds_without_node_ids},
                        seeds("env", "", undefined)),
          %% and a pin without a seed is a configuration error, loud
          ?_assertError({mcl_om, node_ids_without_seeds},
                        seeds(false, node_id_hex(1), undefined))
         ]
     end}.

%% A 64-hex node id for env seeding: pins are hex text on the env
%% (os:putenv takes a string), decoded to 32 raw bytes by
%% configured_seeds/0 itself.
node_id_hex(N) ->
    binary_to_list(binary:encode_hex(<<N:256>>, lowercase)).

clear_seed_config() ->
    {os:getenv("MACULA_STATION_SEEDS"),
     os:getenv("MACULA_STATION_NODE_IDS"),
     application:get_env(mcl_om, station_seeds)}.

restore_seed_config({Env, EnvIds, AppEnv}) ->
    restore_env("MACULA_STATION_SEEDS", Env),
    restore_env("MACULA_STATION_NODE_IDS", EnvIds),
    restore_app_env(AppEnv).

restore_env(_Var, false) -> ok;
restore_env(Var, Val)    -> os:putenv(Var, Val).

restore_app_env(undefined)  -> application:unset_env(mcl_om, station_seeds);
restore_app_env({ok, Seeds}) -> application:set_env(mcl_om, station_seeds, Seeds).

%% EnvSeeds/EnvIds: string to putenv, or `false' to unsetenv.
%% AppEnvSeeds: seed list to set as app env, or `undefined' to unset.
seeds(EnvSeeds, EnvIds, AppEnvSeeds) ->
    set_env("MACULA_STATION_SEEDS", EnvSeeds),
    set_env("MACULA_STATION_NODE_IDS", EnvIds),
    set_app_env(AppEnvSeeds),
    mcl_om_identity:configured_seeds().

set_env(Var, false) -> os:unsetenv(Var);
set_env(Var, Val)   -> os:putenv(Var, Val).

set_app_env(undefined) -> application:unset_env(mcl_om, station_seeds);
set_app_env(Seeds)     -> application:set_env(mcl_om, station_seeds, Seeds).

%% Piece H (PLAN_MCL_OM_MESH_WRAPPERS.md): calling an accessor
%% before mcl_om_identity has started must degrade to {error,
%% not_booted} rather than raising {noproc, _}. Several OTHER test
%% modules in this suite start a real mcl_om_identity in their own
%% fixtures, so "not started yet" cannot be assumed from ordinary
%% EUnit execution order in a shared VM -- ensured directly here
%% instead, same defensive-teardown discipline as
%% mcl_om_pubsub_subscriptions_tests.erl's stop_supervisor/1.
accessors_degrade_instead_of_raising_when_not_booted_test_() ->
    {setup, fun ensure_identity_not_running/0, fun restore_identity/1,
     fun(_) ->
        [
         ?_assertEqual({error, not_booted}, mcl_om_identity:realm()),
         ?_assertEqual({error, not_booted}, mcl_om_identity:identity_key()),
         %% org/0's contract is "always a binary" -- not_booted collapses
         %% into the same placeholder as "unconfigured", not a new shape.
         ?_assertEqual(<<"_">>, mcl_om_identity:org())
        ]
     end}.

%% Returns whatever was running before (a pid, or `undefined') so the
%% teardown can decide whether to put a fresh one back -- this suite
%% doesn't own whether some other module wants one alive afterwards,
%% only that it's genuinely absent for the body of this test.
ensure_identity_not_running() ->
    case whereis(mcl_om_identity) of
        undefined -> undefined;
        Pid ->
            unlink(Pid),
            Ref = monitor(process, Pid),
            exit(Pid, kill),
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            after 2_000 -> ok
            end,
            running
    end.

restore_identity(undefined) -> ok;
restore_identity(running)   -> {ok, _} = mcl_om_identity:start_link(), ok.

%%%-------------------------------------------------------------------
%%% Realm trust: the pool's anchor for org-namespaced advertisements
%%%
%%% These exist because the absence of this pin is not detectable from
%%% outside a running service. A pool without it starts, the node goes
%%% green, /health answers, and every org-namespaced resolution is
%%% refused with `no_realm_key' forever. The failure surfaced as
%%% `{unresolved, no_trusted_advertisement}' on a deployed box and cost
%%% an evening to trace back to an unset variable.
%%%-------------------------------------------------------------------

-define(TRUST_REALM, <<16#abb81b5a614b63551b400b810648c0c8a78efad845442630c94b46cc95d2fcd1:256>>).
-define(TRUST_KEY_RAW, <<16#deadbeefcafe:48>>).
-define(TRUST_KEY_HEX, <<"deadbeefcafe">>).

realm_trust_is_decoded_from_hex_test_() ->
    {setup, fun save_realm_env/0, fun restore_realm_env/1,
     fun(_) ->
        set_realm_env(binary:encode_hex(?TRUST_REALM, lowercase), ?TRUST_KEY_HEX),
        %% The map macula:connect/2 receives: raw 32-byte id, raw key.
        %% Hex anywhere in here is refused by the SDK, which is the whole
        %% reason the decode happens in this module.
        [?_assertEqual(#{realm_trust => #{?TRUST_REALM => ?TRUST_KEY_RAW}},
                       mcl_om_identity:realm_trust_opts())]
     end}.

%% The clause this whole change exists for. It used to return #{}.
realm_trust_unset_refuses_to_start_a_pool_test_() ->
    {setup, fun save_realm_env/0, fun restore_realm_env/1,
     fun(_) ->
        set_realm_env(binary:encode_hex(?TRUST_REALM, lowercase), undefined),
        [?_assertError({mcl_om_realm_trust, realm_key_unconfigured},
                       mcl_om_identity:realm_trust_opts())]
     end}.

realm_unset_refuses_to_start_a_pool_test_() ->
    {setup, fun save_realm_env/0, fun restore_realm_env/1,
     fun(_) ->
        set_realm_env(undefined, ?TRUST_KEY_HEX),
        [?_assertError({mcl_om_realm_trust, realm_unconfigured},
                       mcl_om_identity:realm_trust_opts())]
     end}.

%% A stray character must name the variable, not raise a bare badarg out
%% of the hex decoder with nothing to act on.
realm_key_that_is_not_hex_names_the_variable_test_() ->
    {setup, fun save_realm_env/0, fun restore_realm_env/1,
     fun(_) ->
        RealmHex = binary:encode_hex(?TRUST_REALM, lowercase),
        [?_assertError({mcl_om_realm_trust, {realm_key_not_hex, _}},
                       begin set_realm_env(RealmHex, <<"not hex at all">>),
                             mcl_om_identity:realm_trust_opts() end),
         %% Odd length is the other way a paste goes wrong.
         ?_assertError({mcl_om_realm_trust, {realm_key_not_hex, _}},
                       begin set_realm_env(RealmHex, <<"abc">>),
                             mcl_om_identity:realm_trust_opts() end)]
     end}.

%%%-------------------------------------------------------------------
%%% The pool's trust options
%%%
%%% ⚠ NO `verify' ENTRY, AND THAT IS NOW A HARD CONTRACT. macula 12 has
%%% ONE verification mode: a client verifies the station's own ML-DSA-87
%%% certificate and nothing else. It refuses `verify' in any value, on a
%%% seed, at `connect' and in `call_station' opts, with
%%% `{error, {refused, {verify, one_verification_mode}}}'. A pool that
%%% still composed one would not quietly get a different TLS policy --
%%% it would fail to start.
%%%
%%% The three modes this suite used to assert over (`none', `webpki',
%%% and a named error for anything else) are gone with the option, and
%%% `MCL_OM_VERIFY' with them. What binds a station link to the node it
%%% dialled is unchanged, and is what was always doing the work: the D16
%%% handshake pin, `expected_node_id', required on every seed.
%%%-------------------------------------------------------------------

%% The regression guard for the 12 port. Composing a `verify' entry back
%% into the pool opts breaks the service at start on a live deploy, and
%% this is the cheapest place to catch it.
pool_opts_carry_no_verify_entry_test_() ->
    {setup, fun save_realm_env/0, fun restore_realm_env/1,
     fun(_) ->
        [?_assertNot(maps:is_key(verify, pool_opts())),
         %% The trust anchor is still composed in. Asserting only the
         %% absence above would pass just as well on an empty map.
         ?_assertEqual(1, map_size(maps:get(realm_trust, pool_opts())))]
     end}.

pool_opts() ->
    set_realm_env(binary:encode_hex(?TRUST_REALM, lowercase), ?TRUST_KEY_HEX),
    mcl_om_identity:base_pool_opts().

save_realm_env() ->
    {application:get_env(mcl_om, realm), application:get_env(mcl_om, realm_key)}.

restore_realm_env({Realm, Key}) ->
    restore_app_env(realm, Realm),
    restore_app_env(realm_key, Key).

restore_app_env(K, {ok, V})   -> application:set_env(mcl_om, K, V);
restore_app_env(K, undefined) -> application:unset_env(mcl_om, K).

set_realm_env(Realm, Key) ->
    restore_app_env(realm, env_value(Realm)),
    restore_app_env(realm_key, env_value(Key)).

env_value(undefined) -> undefined;
env_value(V)         -> {ok, V}.
