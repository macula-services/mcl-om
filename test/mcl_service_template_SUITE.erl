%%% @doc The scaffold template, generated for real and then inspected.
%%%
%%% THIS SUITE EXISTS BECAUSE THE PREVIOUS TEMPLATES ROTTED IN SILENCE. They sat
%%% in this repository for months emitting a Quadlet unit nothing on the fleet
%%% uses, TODO comments in place of two callbacks, a store-backed default for a
%%% mostly producer-only estate, and an identity_spec claiming authority over
%%% resources the generated service could not touch. Nothing exercised them, so
%%% nothing said so. A template with no test is documentation that compiles.
%%%
%%% It runs `rebar3 new' as a real subprocess rather than rendering the templates
%%% itself, because the things most likely to break are exactly the parts a
%%% hand-rolled renderer would not reproduce: the manifest's destination paths,
%%% the chmod entry, and mustache's own behaviour.
%%%
%%% THE DELIMITER CHANGE IS THE POINT OF generated_workflow_keeps_actions_syntax.
%%% GitHub Actions writes ${{ secrets.GITHUB_TOKEN }} and mustache reads {{...}},
%%% so a template without the delimiter change silently renders that to "$" and
%%% reports success. The workflow then fails at its login step with an empty
%%% password, a long way from the cause.
-module(mcl_service_template_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/file.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([generates_every_expected_file/1,
         health_script_is_executable/1,
         sys_config_configures_a_stable_identity/1,
         stable_identity_survives_a_recreate/1,
         image_build_decides_from_the_pushed_range/1,
         docs_only_gate_decides_each_push_shape/1,
         release_tag_does_not_move_latest/1,
         generated_service_is_pinned_to_one_otp/1,
         generated_runtime_guard_passes/1,
         generated_lint_toolchain_runs_in_its_image/1,
         generated_build_takes_its_toolchain_from_the_builder_image/1,
         generated_service_builds_on_the_images_it_was_given/1,
         house_scaffold_builds_on_the_fleet_pair/1,
         scaffold_refuses_half_an_image_pair/1,
         this_repository_builds_in_the_scaffold_builder/1,
         generated_service_has_its_org/1,
         generated_image_carries_its_revision/1,
         generated_ci_runs_dialyzer_with_macula_in_view/1,
         generated_gitignore_covers_what_the_tests_write/1,
         generated_text_is_current/1,
         no_unrendered_variable_survives/1,
         generated_workflow_keeps_actions_syntax/1,
         leaks_no_house_specifics/1,
         generated_sources_satisfy_the_behaviour/1,
         generated_service_reports_the_scaffolded_names/1,
         generated_service_requires_the_mesh/1,
         generated_service_floor_is_this_release/1,
         licence_follows_the_visibility/1,
         runner_follows_the_visibility/1,
         scaffold_asks_the_visibility/1,
         public_scaffold_says_public_and_stays_off_our_runners/1,
         closing_text_is_true_to_the_template/1,
         image_build_runs_on_docker_and_podman_alike/1,
         only_main_and_release_tags_publish/1,
         house_images_are_signed_by_digest/1,
         generated_tests_guard_the_behaviour_attribute/1,
         storeless_scaffold_names_no_store/1,
         store_scaffold_owns_its_store/1]).

-define(REPO, "mcl-probe-svc").
-define(APP,  "mcl_probe_svc").
-define(DESC, "A generated probe service").
-define(PORT, "8499").
%% DELIBERATELY NOT OUR OWN ORG OR REGISTRY. Generating as a stranger is what
%% makes leaked_house_specifics/1 able to prove the scaffold is usable by one.
-define(ORG,      "acme-widgets").
-define(REGISTRY, "registry.example.test").
%% The stranger's own copyright holder: ours must not survive into their LICENSE.
-define(HOLDER,   "Acme Widgets Ltd").
%% The stranger's own image pair. Never pulled: the image a generated service
%% builds in is proven by generated_lint_toolchain_runs_in_its_image/1, against
%% the house pair, which is the one this repository answers for.
-define(BUILDER_IMAGE,
        "registry.example.test/acme-widgets/otp-build:28.4.3"
        "@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef").
-define(RUNTIME_IMAGE,
        "registry.example.test/acme-widgets/otp-run:28.4.3"
        "@sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210").
%% What scaffold-service.sh generates when nobody overrides anything.
-define(HOUSE_REPO, "mcl-house-probe").
-define(HOUSE_APP,  "mcl_house_probe").
-define(STORE_REPO, "mcl-store-probe").
-define(STORE_APP,  "mcl_store_probe").

all() ->
    [generates_every_expected_file,
     health_script_is_executable,
     sys_config_configures_a_stable_identity,
     stable_identity_survives_a_recreate,
     image_build_decides_from_the_pushed_range,
     docs_only_gate_decides_each_push_shape,
     release_tag_does_not_move_latest,
     generated_service_is_pinned_to_one_otp,
     generated_runtime_guard_passes,
     generated_lint_toolchain_runs_in_its_image,
     generated_build_takes_its_toolchain_from_the_builder_image,
     generated_service_builds_on_the_images_it_was_given,
     house_scaffold_builds_on_the_fleet_pair,
     scaffold_refuses_half_an_image_pair,
     this_repository_builds_in_the_scaffold_builder,
     generated_service_has_its_org,
     generated_image_carries_its_revision,
     generated_ci_runs_dialyzer_with_macula_in_view,
     generated_gitignore_covers_what_the_tests_write,
     generated_text_is_current,
     no_unrendered_variable_survives,
     generated_workflow_keeps_actions_syntax,
     leaks_no_house_specifics,
     generated_sources_satisfy_the_behaviour,
     generated_service_reports_the_scaffolded_names,
     generated_service_requires_the_mesh,
     generated_service_floor_is_this_release,
     licence_follows_the_visibility,
     runner_follows_the_visibility,
     scaffold_asks_the_visibility,
     public_scaffold_says_public_and_stays_off_our_runners,
     closing_text_is_true_to_the_template,
     image_build_runs_on_docker_and_podman_alike,
     only_main_and_release_tags_publish,
     house_images_are_signed_by_digest,
     generated_tests_guard_the_behaviour_attribute,
     storeless_scaffold_names_no_store,
     store_scaffold_owns_its_store].

%%%---------------------------------------------------------------------------
%%% Generate once, compile once, then assert
%%%---------------------------------------------------------------------------

%% Generation and compilation both happen here rather than as test cases,
%% because everything below is meaningless if either fails, and a suite-level
%% failure says so in one place instead of six.
init_per_suite(Config) ->
    Rebar3 = os:find_executable("rebar3"),
    false =:= Rebar3 andalso ct:fail(rebar3_not_on_path),
    Priv = ?config(priv_dir, Config),
    Work = filename:join(Priv, "work"),
    Ebin = filename:join(Priv, "ebin"),
    ok = filelib:ensure_path(Work),
    ok = filelib:ensure_path(Ebin),
    Added = install_templates(templates_dir()),
    Out = run(Rebar3, ["new", "mcl_service",
                       "repo=" ?REPO, "name=" ?APP,
                       "desc=" ?DESC, "health_port=" ?PORT,
                       "org=" ?ORG, "registry=" ?REGISTRY,
                       "holder=" ?HOLDER,
                       "builder_image=" ?BUILDER_IMAGE,
                       "runtime_image=" ?RUNTIME_IMAGE],
              Work),
    ct:pal("rebar3 new said:~n~s", [Out]),
    Root = filename:join(Work, ?REPO),
    filelib:is_dir(Root) orelse ct:fail({no_output_dir, Root, Out}),
    Compiled = compile_generated(Root, Ebin),
    {HouseRoot, HouseOut} = scaffold_as_the_house(filename:join(Priv, "house")),
    StoreRoot = scaffold_with_a_store(Rebar3, filename:join(Priv, "store")),
    [{root, Root}, {house_root, HouseRoot}, {house_out, HouseOut}, {store_root, StoreRoot},
     {ebin, Ebin}, {compiled, Compiled}, {added, Added} | Config].

%% THE STORE VARIANT (store=1) is generated AND compiled too: since 0.35.0 the
%% service carries its own copy of the store wiring (in <name>_app, since a
%% rebar3 template cannot generate a file conditionally), so a template that
%% renders it wrong fails here, not in the next service's first build. It
%% compiles into its own ebin, under names nothing above uses.
scaffold_with_a_store(Rebar3, Dir) ->
    ok = filelib:ensure_path(Dir),
    Out = run(Rebar3, ["new", "mcl_service",
                       "repo=" ?STORE_REPO, "name=" ?STORE_APP,
                       "desc=A store probe", "health_port=8497",
                       "org=" ?ORG, "registry=" ?REGISTRY, "holder=" ?HOLDER,
                       "builder_image=" ?BUILDER_IMAGE, "runtime_image=" ?RUNTIME_IMAGE,
                       "store=1"],
              Dir),
    ct:pal("rebar3 new (store=1) said:~n~s", [Out]),
    Root = filename:join(Dir, ?STORE_REPO),
    filelib:is_dir(Root) orelse ct:fail({no_store_output_dir, Root, Out}),
    Ebin = filename:join(Dir, "ebin"),
    ok = filelib:ensure_path(Ebin),
    Srcs = [filename:join([Root, "apps", ?STORE_APP, "src", ?STORE_APP ++ Suffix])
            || Suffix <- ["_app.erl", "_sup.erl", "_service.erl"]],
    Bad = [{S, R} || S <- Srcs,
                     R <- [compile:file(S, [{outdir, Ebin}, return, warnings_as_errors, debug_info])],
                     element(1, R) =/= ok],
    [] =:= Bad orelse ct:fail({store_scaffold_does_not_compile, Bad}),
    Root.

%% THE HOUSE GENERATION GOES THROUGH scripts/scaffold-service.sh, the way we
%% scaffold, with every override cleared, so what it produces is the defaults
%% and nothing a developer's shell happened to export. The house scaffolds
%% private services, which is the one choice it must make.
scaffold_as_the_house(Dir) ->
    ok = filelib:ensure_path(Dir),
    Out = run(scaffold_script(), [?HOUSE_REPO, "A house default probe", "8498"], Dir,
              [{"MCL_VISIBILITY", "private"} | cleared_overrides()]),
    ct:pal("scaffold-service.sh said:~n~s", [Out]),
    Root = filename:join(Dir, ?HOUSE_REPO),
    filelib:is_dir(Root) orelse ct:fail({no_house_output_dir, Root, Out}),
    {Root, Out}.

cleared_overrides() ->
    [{"MCL_ORG", false}, {"MCL_REGISTRY", false},
     {"MCL_BUILDER_IMAGE", false}, {"MCL_RUNTIME_IMAGE", false},
     {"MCL_RUNS_ON", false}, {"MCL_HOLDER", false}].

scaffold_script() ->
    filename:join([filename:dirname(?FILE), "..", "scripts", "scaffold-service.sh"]).

end_per_suite(Config) ->
    _ = code:del_path(?config(ebin, Config)),
    %% Only what this suite put there. A developer who had already run
    %% scripts/install-templates.sh keeps their installation.
    lists:foreach(fun(P) -> _ = file:delete(P) end, ?config(added, Config)),
    ok.

%%% SANDBOXING HOME LOOKED RIGHT AND WAS WRONG, TWICE, so the reason for doing it
%%% this way is recorded rather than rediscovered. rebar3 resolves its global
%%% config from `init:get_argument(home)', so a private HOME is what would
%%% redirect template lookup. But on a machine where rebar3 is an asdf shim, that
%%% same override breaks asdf: it looks for its installs under $HOME/.asdf and
%%% exits 126, and then for its version selection in $HOME/.tool-versions and
%%% exits with "No version is set". Chasing that means teaching a test about a
%%% version manager.
%%%
%%% So the suite installs into the real rebar3 template directory and removes
%%% exactly what it added. It works the same on a laptop and in a bare CI
%%% container, and it exercises the installation path the humans use.
templates_dir() ->
    {ok, [[Home]]} = init:get_argument(home),
    filename:join([Home, ".config", "rebar3", "templates"]).

%% Returns the paths created, so end_per_suite removes those and nothing else.
%% Symlinks, so an edit to a template in this checkout is what the next run sees.
install_templates(Dest) ->
    Src = filename:join(code:priv_dir(mcl_om), "templates"),
    ok = filelib:ensure_path(Dest),
    {ok, Entries} = file:list_dir(Src),
    lists:filtermap(fun(E) -> link_entry(filename:join(Src, E),
                                         filename:join(Dest, E))
                    end, Entries).

link_entry(Src, Dest) ->
    link_entry(file:read_link_info(Dest), Src, Dest).

%% Already there: leave it alone and do not claim it for cleanup, provided it is
%% THIS checkout's template. An installation from another checkout (the main
%% one, while this is a worktree, or the other way round) would have this suite
%% render and assert THOSE files, and pass or fail on templates it never
%% looked at. Refuse, naming both, rather than test the wrong thing.
link_entry({ok, _Info}, Src, Dest) ->
    installed_from_here(same_file(Src, Dest), Src, Dest);
link_entry({error, enoent}, Src, Dest) ->
    ok = file:make_symlink(Src, Dest),
    {true, Dest}.

installed_from_here(true, _Src, _Dest) ->
    false;
installed_from_here(false, Src, Dest) ->
    ct:fail({templates_installed_from_another_checkout,
             #{installed => Dest, points_at => file:read_link(Dest), this_checkout => Src,
               fix => "run scripts/install-templates.sh from this checkout"}}).

%% Whether two paths reach the same file once every link is followed. A link
%% target compared as text never matches: priv_dir is reached through
%% _build/<profile>/lib/mcl_om/priv, itself a link to the checkout's priv.
same_file(A, B) ->
    identity(file:read_file_info(A)) =:= identity(file:read_file_info(B)).

identity({ok, #file_info{major_device = Dev, inode = Inode}}) -> {Dev, Inode};
identity(Other) -> Other.

%% The outer run's rebar environment is cleared so the nested invocation cannot
%% inherit this suite's own build state, profile or config. HOME is deliberately
%% left alone; see templates_dir/0 for why.
run(Exe, Args, Cwd) ->
    run(Exe, Args, Cwd, []).

run(Exe, Args, Cwd, Env) ->
    Port = erlang:open_port(
             {spawn_executable, Exe},
             [{args, Args}, {cd, Cwd}, exit_status, stderr_to_stdout, binary,
              {env, [{"REBAR_BASE_DIR", false},
                     {"REBAR_CONFIG", false},
                     {"REBAR_PROFILE", false} | Env]}]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Bin}}      -> collect(Port, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, 0}} -> Acc;
        {Port, {exit_status, N}} -> ct:fail({rebar3_new_failed, N, Acc})
    after 120000 ->
        ct:fail({rebar3_new_timeout, Acc})
    end.

%% mcl_om is compiled right here, so the generated modules can be compiled
%% against it and the `-behaviour(mcl_om_service)' attribute makes the
%% compiler check all six callbacks. warnings_as_errors matches what the
%% generated rebar.config sets, so a template emitting an unused variable fails
%% here too, exactly as it would for whoever scaffolds next.
compile_generated(Root, Ebin) ->
    Srcs = [filename:join([Root, "apps", ?APP, "src", ?APP ++ Suffix])
            || Suffix <- ["_app.erl", "_sup.erl", "_service.erl"]],
    Results = [{S, compile:file(S, [{outdir, Ebin}, return, warnings_as_errors,
                                    debug_info])}
               || S <- Srcs],
    Bad = [R || R = {_S, Res} <- Results, element(1, Res) =/= ok],
    [] =:= Bad orelse ct:fail({generated_sources_do_not_compile, Bad}),
    true = code:add_patha(Ebin),
    Results.

%%%---------------------------------------------------------------------------
%%% What was generated
%%%---------------------------------------------------------------------------

%% Spelled out rather than globbed, so DELETING an entry from the manifest breaks
%% this test. A generated repository missing its CI or its compose file still
%% compiles and still passes every other assertion here.
generates_every_expected_file(Config) ->
    Root = ?config(root, Config),
    Expected =
        ["rebar.config", ".gitignore", "README.md", "CHANGELOG.md", "LICENSE",
         "Containerfile",
         ".github/workflows/build-push.yml",
         ".github/workflows/lint.yml",
         "config/sys.config.src", "config/vm.args.src",
         "deploy/docker-compose.yml",
         "scripts/health.sh",
         "scripts/is_image_push.sh",
         "apps/" ?APP "/src/" ?APP ".app.src",
         "apps/" ?APP "/src/" ?APP "_app.erl",
         "apps/" ?APP "/src/" ?APP "_sup.erl",
         "apps/" ?APP "/src/" ?APP "_service.erl",
         "apps/" ?APP "/test/" ?APP "_service_tests.erl"],
    Missing = [P || P <- Expected,
                    not filelib:is_regular(filename:join(Root, P))],
    ?assertEqual([], Missing).

%% Forgetting the chmod entry produces a script that looks right and cannot run,
%% and it is a recorded recurring mistake in this estate.
health_script_is_executable(Config) ->
    Path = filename:join(?config(root, Config), "scripts/health.sh"),
    {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
    ?assertEqual(8#100, Mode band 8#100).

%% Forgetting identity_key_path produces a sys.config that renders clean,
%% boots clean, peers and calls fine, and NEVER advertises a single
%% handler-bearing capability -- silently, forever, on every republish tick
%% ("an ephemeral service cannot sign and is correctly not advertised" by
%% design, mcl_om_capabilities's own moduledoc). Confirmed live 2026-08-31
%% on a service generated from an earlier copy of this template that lacked
%% this key: keypair/0 stayed {error, no_keypair} for its entire deployed
%% lifetime, and hecate_stations.list_stations never once reached the DHT.
%% Same class of recorded recurring mistake as the chmod one above -- a
%% generated repo that looks completely healthy while doing nothing.
sys_config_configures_a_stable_identity(Config) ->
    Path = filename:join(?config(root, Config), "config/sys.config.src"),
    {ok, Bin} = file:read_file(Path),
    ?assert(binary:match(Bin, <<"identity_key_path">>) =/= nomatch).

%% The identity path above only helps if the file outlives the container. The
%% image declares /etc/mcl/secrets a VOLUME, and with nothing mounted there
%% docker gives each new container a fresh anonymous volume, so every
%% watchtower recreate generated a new key: a new node id per image, with the
%% service looking healthy throughout. The compose file must mount a NAMED
%% volume there, and name it itself so a different `-p' cannot fork it.
stable_identity_survives_a_recreate(Config) ->
    Path = filename:join(?config(root, Config), "deploy/docker-compose.yml"),
    {ok, Bin} = file:read_file(Path),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"- secrets:/etc/mcl/secrets\n">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Bin, <<"\nvolumes:\n  secrets:\n    name: ", ?REPO, "-secrets\n">>)).

%% A variable named in a file but not declared in the manifest renders as empty
%% and reports success, so the only way to see it is to look for what is left
%% behind. Both delimiter styles are searched: mustache's default, and the
%% alternate the templates switch to on their first line.
no_unrendered_variable_survives(Config) ->
    Root = ?config(root, Config),
    Offenders = [{F, Left} || F <- all_files(Root),
                              Left <- [unrendered(read(F))],
                              Left =/= []],
    ?assertEqual([], Offenders).

%% ${{ ... }} IS NOT AN UNRENDERED TAG. GitHub Actions expressions are supposed
%% to reach the workflow file intact, and this test's first version flagged them,
%% which would have made the honest case indistinguishable from the broken one.
%% A leftover mustache tag is a `{{' that no dollar precedes.
unrendered(Bin) ->
    [P || {P, _} <- binary:matches(Bin, <<"{{">>), not dollar_before(Bin, P)]
        ++ [P || {P, _} <- binary:matches(Bin, <<"<%">>)].

dollar_before(_Bin, 0) -> false;
dollar_before(Bin, P)  -> binary:at(Bin, P - 1) =:= $$.

generated_workflow_keeps_actions_syntax(Config) ->
    Body = read(filename:join(?config(root, Config),
                              ".github/workflows/build-push.yml")),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"${{ secrets.GITHUB_TOKEN }}">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"${{ steps.tag.outputs.tags }}">>)).

%% A DOCS-ONLY PUSH MUST NOT ROLL THE FLEET, AND A NEW BRANCH MUST ALWAYS BUILD.
%% Both used to be answered with `paths-ignore', which gets the second wrong:
%% on the push that CREATES a branch GitHub compares against nothing and
%% evaluates the filter on the head commit alone, so a first push ending in a
%% README edit built no image at all (hit on mcl-warden). The decision is made
%% by a script from the pushed range instead, so the workflow carries no path
%% filter and every image step waits on the script's answer.
image_build_decides_from_the_pushed_range(Config) ->
    Body = read(filename:join(?config(root, Config),
                              ".github/workflows/build-push.yml")),
    ?assertEqual(nomatch, binary:match(Body, <<"paths-ignore:">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"paths:">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"scripts/is_image_push.sh \"${{ github.event.before }}\" \"${{ github.sha }}\"">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"fetch-depth: 0">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"if: steps.gate.outputs.build == 'true'">>)),
    Mode = file_mode(filename:join(?config(root, Config), "scripts/is_image_push.sh")),
    ?assertEqual(8#100, Mode band 8#100).

%% The script against a real history, one push shape at a time.
docs_only_gate_decides_each_push_shape(Config) ->
    Script = filename:join(?config(root, Config), "scripts/is_image_push.sh"),
    Repo = filename:join(?config(priv_dir, Config), "gate_repo"),
    ok = filelib:ensure_path(Repo),
    git(Repo, "init -q"),
    Code0 = commit(Repo, "src/svc.erl", "a"),
    Docs1 = commit(Repo, "README.md", "a"),
    Docs2 = commit(Repo, "docs/guide.txt", "a"),
    Lic3  = commit(Repo, "LICENSE", "a"),
    Code4 = commit(Repo, "src/svc.erl", "b"),
    Zero = lists:duplicate(40, $0),
    Unknown = lists:duplicate(40, $d),
    Gate = fun(Before, After) -> gate(Script, Repo, Before, After) end,
    ?assertEqual(<<"build=true\n">>,  Gate(Zero, Docs1)),     %% branch created
    ?assertEqual(<<"build=true\n">>,  Gate("", Docs1)),       %% no before at all
    ?assertEqual(<<"build=false\n">>, Gate(Code0, Docs1)),    %% README only
    ?assertEqual(<<"build=false\n">>, Gate(Code0, Lic3)),     %% docs, guide, licence
    ?assertEqual(<<"build=true\n">>,  Gate(Lic3, Code4)),     %% code
    ?assertEqual(<<"build=true\n">>,  Gate(Docs2, Code4)),    %% docs and code
    ?assertEqual(<<"build=true\n">>,  Gate(Unknown, Code4)).  %% before not in history

%% ONE OTP, NAMED THREE TIMES, NONE OF THEM FLOATING. The builder was
%% `erlang:28-alpine' and lint `erlang:28'; when Docker Hub moved them on
%% 2026-09-22, mcl-echo (generated from this) shipped OTP 28.5 without anyone
%% choosing it. The images are now whatever pair the scaffold was given, pinned
%% by digest, and an image's tag need not name a release at all (the house
%% pair's names a date). So the release is ASSERTED where it is used: the
%% builder stage refuses to build on anything but 28.4.3 with mldsa87, lint's
%% toolchain step refuses the same, and .tool-versions names the same release.
generated_service_is_pinned_to_one_otp(Config) ->
    Root = ?config(root, Config),
    Check = <<"{<<\"28.4.3\">>, true} -> halt(0);">>,
    Containerfile = read(filename:join(Root, "Containerfile")),
    Lint = read(filename:join(Root, ".github/workflows/lint.yml")),
    ?assertNotEqual(nomatch, binary:match(Containerfile, Check)),
    ?assertNotEqual(nomatch, binary:match(Lint, Check)),
    %% The builder's check runs BEFORE anything is built, so an image on
    %% another release fails at its first step, not after a full compile.
    {FromBuilder, _} = binary:match(Containerfile, <<" AS builder\n">>),
    {CheckAt, _} = binary:match(Containerfile, Check),
    {GetDeps, _} = binary:match(Containerfile, <<"RUN rebar3 get-deps">>),
    ?assert(FromBuilder < CheckAt andalso CheckAt < GetDeps),
    ?assertMatch({match, _},
                 re:run(read(filename:join(Root, ".tool-versions")), "^erlang 28\\.4\\.3$",
                        [multiline])).

%% THE GENERATED SERVICE'S OWN RUNTIME GUARD, RUN FOR REAL. This suite used to
%% compile the generated sources and never run the generated tests, so a pin
%% the guard could no longer parse passed here and would have failed every
%% newly scaffolded service on its first `rebar3 eunit'. The guard finds the
%% pinned files relative to its own beam, so it is compiled inside the
%% generated repository. It also compares against the running VM, which is
%% this suite's own: mcl_om's CI and the scaffold name the same release.
generated_runtime_guard_passes(Config) ->
    Root = ?config(root, Config),
    Src = filename:join([Root, "apps", ?APP, "test", ?APP "_service_tests.erl"]),
    Out = filename:join(Root, "guard_ebin"),
    ok = filelib:ensure_path(Out),
    {ok, Mod} = compile:file(Src, [{outdir, Out}, return_errors, debug_info]),
    {module, Mod} = code:load_abs(filename:join(Out, atom_to_list(Mod))),
    try
        ok = Mod:the_runtime_agrees_between_the_image_the_ci_and_this_vm_test(),
        ok = Mod:ci_builds_in_the_builder_and_both_images_are_digest_pinned_test()
    after
        code:purge(Mod),
        code:delete(Mod),
        %% Gone before the cases that scan every generated file: a compiled
        %% beam is binary, and its bytes can contain `{{' or a house name by
        %% chance, which made no_unrendered_variable_survives flaky.
        ok = file:del_dir_r(Out)
    end.

%% THE GENERATED LINT JOB'S TOOLCHAIN STEP, RUN IN THE IMAGE IT NAMES. Every
%% other check here reads the workflow's TEXT, and the text was right while the
%% pinned image had no rebar3, git or curl: a generated service's first push
%% died on `rebar3 version'. scripts/is_lint_toolchain_runnable.sh runs that
%% step for real. It needs podman or docker; without either (mcl_om's own CI
%% container) this case is skipped by name, and the `template-lint-image' job
%% in lint-and-test.yml runs the same script on a host that has one.
%%
%% The HOUSE generation's, because its image is real: the stranger's pair above
%% is made up and never pulled.
generated_lint_toolchain_runs_in_its_image(Config) ->
    Lint = filename:join(?config(house_root, Config), ".github/workflows/lint.yml"),
    Script = filename:join([filename:dirname(?FILE), "..", "scripts",
                            "is_lint_toolchain_runnable.sh"]),
    Port = erlang:open_port({spawn_executable, Script},
                            [{args, [Lint]}, exit_status, stderr_to_stdout, binary]),
    lint_toolchain_outcome(collect_status(Port, <<>>)).

lint_toolchain_outcome({0, Out}) ->
    ?assertNotEqual(nomatch, binary:match(Out, <<"OTP 28.4.3, mldsa87 true">>)),
    ok;
lint_toolchain_outcome({3, _Out}) ->
    {skip, no_container_runtime_here_covered_by_the_template_lint_image_ci_job};
lint_toolchain_outcome({Status, Out}) ->
    ct:fail({lint_toolchain_failed_in_its_image, Status, Out}).

collect_status(Port, Acc) ->
    receive
        {Port, {data, Bin}}      -> collect_status(Port, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, N}} -> {N, Acc}
    after 900000 ->
        ct:fail({lint_toolchain_timeout, Acc})
    end.

%% THE BUILDER IMAGE IS THE TOOLCHAIN, AND ITS DIGEST IS THE ONE PIN. The
%% template used to install its own on top of a bare OTP image: rustup's
%% `stable', which floats, and a rebar3 pinned by sha256 in two files. On the
%% house pair all of it is already in the image, pinned exactly, so a second
%% install is a second pin that can disagree with the first. What remains is a
%% check: lint's toolchain step names each tool the build needs, so an image
%% without one fails that step (generated_lint_toolchain_runs_in_its_image/1
%% runs it in the image) rather than a service's first build.
generated_build_takes_its_toolchain_from_the_builder_image(Config) ->
    Root = ?config(root, Config),
    Lint = read(filename:join(Root, ".github/workflows/lint.yml")),
    Installs = [<<"sh.rustup.rs">>, <<"releases/download">>, <<"s3.amazonaws.com">>,
                <<"apk add">>, <<"apt-get install">>],
    Found = [{F, I} || F <- ["Containerfile", ".github/workflows/lint.yml"],
                       I <- Installs,
                       binary:match(read(filename:join(Root, F)), I) =/= nomatch],
    ?assertEqual([], Found),
    Step = toolchain_step(Lint),
    Missing = [T || T <- [<<"git --version">>, <<"rebar3 version">>,
                          <<"rustc --version">>, <<"cargo --version">>,
                          <<"openssl version">>, <<"mldsa87">>],
                    binary:match(Step, T) =:= nomatch],
    ?assertEqual([], Missing).

toolchain_step(Lint) ->
    {match, [Step]} = re:run(Lint, "# toolchain-begin(.*)# toolchain-end",
                             [dotall, {capture, all_but_first, binary}]),
    Step.

%% THE IMAGES ARE VARIABLES, and a generated service builds on exactly the pair
%% it was given: the builder in the Containerfile's first stage and in lint,
%% the runtime in the last stage, two stages and no third image.
generated_service_builds_on_the_images_it_was_given(Config) ->
    Root = ?config(root, Config),
    ?assertEqual([{<<?BUILDER_IMAGE>>, <<"AS builder">>}, {<<?RUNTIME_IMAGE>>, <<>>}],
                 from_lines(read(filename:join(Root, "Containerfile")))),
    ?assertEqual([<<?BUILDER_IMAGE>>],
                 lint_images(read(filename:join(Root, ".github/workflows/lint.yml")))).

%% WHAT WE SCAFFOLD STARTS ON THE FLEET'S PAIR. The template once pinned
%% hexpm's Alpine OTP and Alpine while every running mcl service had moved to
%% macula-ci-images' build and runtime pair, so each new service was born on
%% retired images and had to be moved by hand.
%%
%% The pair is named in ONE place, the manifest's defaults, and read from
%% there: scaffold-service.sh passes an image only when one is overridden.
%% The house generation is compared with it line for line, and the pair itself
%% must be the macula-ci-images build and runtime images of one dated build,
%% each by digest, because a build and a runtime from different dates carry
%% different glibc and OpenSSL.
house_scaffold_builds_on_the_fleet_pair(Config) ->
    Root = ?config(house_root, Config),
    {Builder, Runtime} = house_image_pair(),
    Pinned = ":([0-9]{8}-[0-9]{4})@sha256:[0-9a-f]{64}$",
    {match, [BuildDate]} = re:run(Builder, "^ghcr\\.io/macula-io/macula-ci-otp" ++ Pinned,
                                  [{capture, all_but_first, binary}]),
    {match, [RunDate]} = re:run(Runtime, "^ghcr\\.io/macula-io/macula-pq-runtime" ++ Pinned,
                                [{capture, all_but_first, binary}]),
    ?assertEqual(BuildDate, RunDate),
    ?assertEqual([{Builder, <<"AS builder">>}, {Runtime, <<>>}],
                 from_lines(read(filename:join(Root, "Containerfile")))),
    ?assertEqual([Builder],
                 lint_images(read(filename:join(Root, ".github/workflows/lint.yml")))).

%% ONE BUILD IMAGE PER REPOSITORY. mcl_om's own CI ran in one dated build of
%% macula-ci-otp while the scaffold handed every new service another, so this
%% suite was green in an image no generated service would ever build in. The
%% `check' job's container image, the one this suite runs in on CI, must be
%% the scaffold's builder_image default.
this_repository_builds_in_the_scaffold_builder(_Config) ->
    Workflow = read(filename:join([filename:dirname(?FILE), "..", ".github", "workflows",
                                   "lint-and-test.yml"])),
    {match, [CheckImage]} =
        re:run(Workflow, "^  check:\\n(?:(?!^  \\S).*\\n)*?\\s+image: (\\S+)$",
               [multiline, {capture, all_but_first, binary}]),
    {Builder, _Runtime} = house_image_pair(),
    ?assertEqual(Builder, CheckImage).

%% THE PAIR MOVES TOGETHER OR NOT AT ALL. A release built in one image runs on
%% the other's glibc and OpenSSL, so overriding the builder and keeping the
%% house runtime (or the reverse) generates a service that builds and then
%% fails to load its NIFs, or fails every PQ handshake. The script refuses,
%% naming both, before it generates anything. The variables are set through
%% `env', so an empty value reaches the script exported and empty.
scaffold_refuses_half_an_image_pair(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "half_pair"),
    ok = filelib:ensure_path(Dir),
    Image = "registry.example.test/x/y@sha256:" ++ lists:duplicate(64, $a),
    %% An exported but EMPTY variable is half a pair too: `MCL_BUILDER_IMAGE='
    %% on its own must not quietly fall back to the house pair.
    Halves = [[{"MCL_BUILDER_IMAGE", Image}],
              [{"MCL_RUNTIME_IMAGE", Image}],
              [{"MCL_BUILDER_IMAGE", ""}],
              [{"MCL_RUNTIME_IMAGE", ""}],
              [{"MCL_BUILDER_IMAGE", Image}, {"MCL_RUNTIME_IMAGE", ""}],
              [{"MCL_BUILDER_IMAGE", ""}, {"MCL_RUNTIME_IMAGE", ""}]],
    Refusals =
        [begin
             Port = erlang:open_port(
                      {spawn_executable, "/usr/bin/env"},
                      [{args, ["-u", "MCL_BUILDER_IMAGE", "-u", "MCL_RUNTIME_IMAGE",
                               "MCL_VISIBILITY=private"]
                              ++ [K ++ "=" ++ V || {K, V} <- Half]
                              ++ [scaffold_script(), "mcl-half-pair", "Half a pair", "8497"]},
                       {cd, Dir}, exit_status, stderr_to_stdout, binary]),
             collect_status(Port, <<>>)
         end || Half <- Halves],
    [begin
         ?assertNotEqual(0, Status),
         ?assertNotEqual(nomatch, binary:match(Out, <<"MCL_BUILDER_IMAGE">>)),
         ?assertNotEqual(nomatch, binary:match(Out, <<"MCL_RUNTIME_IMAGE">>))
     end || {Status, Out} <- Refusals],
    ?assertNot(filelib:is_dir(filename:join(Dir, "mcl-half-pair"))).

%% The defaults of the two image variables, from the template manifest itself.
house_image_pair() ->
    Manifest = filename:join([code:priv_dir(mcl_om), "templates", "mcl_service.template"]),
    {ok, Terms} = file:consult(Manifest),
    Variables = proplists:get_value(variables, Terms),
    Default = fun(Key) ->
                  {Key, Value, _Doc} = lists:keyfind(Key, 1, Variables),
                  list_to_binary(Value)
              end,
    {Default(builder_image), Default(runtime_image)}.

%% Every FROM line, as {Image, Rest}: Rest is `AS builder' or empty.
from_lines(Containerfile) ->
    {match, Lines} = re:run(Containerfile, "^FROM (\\S+)(?: (.*))?$",
                            [multiline, global, {capture, all_but_first, binary}]),
    [{Image, rest(Rest)} || [Image | Rest] <- Lines].

rest([])     -> <<>>;
rest([Rest]) -> Rest.

lint_images(Lint) ->
    {match, Images} = re:run(Lint, "^\\s+image: (\\S+)$",
                             [multiline, global, {capture, all_but_first, binary}]),
    [I || [I] <- Images].

%% ONE ORG PER SERVICE, NAMED AFTER THE REPOSITORY, fixed in the release rather
%% than left to an environment variable someone can forget. Without it
%% mcl_om_identity:org/0 answers `_', and mcl_om now refuses to advertise
%% under that: the service would announce nothing.
generated_service_has_its_org(Config) ->
    SysConfig = read(filename:join(?config(root, Config), "config/sys.config.src")),
    ?assertMatch({match, _},
                 re:run(SysConfig, "\\{org,\\s*<<\"" ?REPO "\">>\\}")).

%% THE IMAGE SAYS WHICH COMMIT IT WAS BUILT FROM. build-push passes the sha as
%% REVISION and the runtime stage labels the image with it, so a digest a fleet
%% pins can be traced to its commit without the registry's history.
generated_image_carries_its_revision(Config) ->
    Root = ?config(root, Config),
    Containerfile = read(filename:join(Root, "Containerfile")),
    ?assertMatch({match, _}, re:run(Containerfile, "^ARG REVISION=unknown$", [multiline])),
    ?assertMatch({match, _},
                 re:run(Containerfile,
                        "^LABEL org\\.opencontainers\\.image\\.revision=\"\\$\\{REVISION\\}\"$",
                        [multiline])),
    ?assertMatch({match, _},
                 re:run(read(filename:join(Root, ".github/workflows/build-push.yml")),
                        "--build-arg REVISION=\\$\\{\\{ github\\.sha \\}\\}", [multiline])).

%% DIALYZER IS A GATE, SO CI RUNS IT. A service's handler implements
%% `macula_response' and calls `macula' directly, but macula reaches the
%% service only through mcl_om, so it is not in the PLT: dialyzer reports
%% every macula call as unknown and the behaviour's callbacks as unavailable.
%% `plt_extra_apps' puts it in view.
generated_ci_runs_dialyzer_with_macula_in_view(Config) ->
    Root = ?config(root, Config),
    ?assertMatch({match, _},
                 re:run(read(filename:join(Root, ".github/workflows/lint.yml")),
                        "^      - run: rebar3 dialyzer$", [multiline])),
    {ok, Terms} = file:consult(filename:join(Root, "rebar.config")),
    Dialyzer = proplists:get_value(dialyzer, Terms, []),
    ?assert(lists:member(macula, proplists:get_value(plt_extra_apps, Dialyzer, []))).

%% A service with a read model starts barrel_docdb in its tests, and
%% barrel_docdb writes its system databases to `data/' in the working
%% directory: the repository root. Unignored, they get committed.
generated_gitignore_covers_what_the_tests_write(Config) ->
    Ignore = read(filename:join(?config(root, Config), ".gitignore")),
    ?assertMatch({match, _}, re:run(Ignore, "^/data/$", [multiline])).

%% What the generated files say must be true of the platform they generate
%% for: macula 12, and an image policy of two channels. Whitespace is folded
%% first, because a stale phrase wrapped across two lines is just as stale.
generated_text_is_current(Config) ->
    Root = ?config(root, Config),
    Stale = [{filename:basename(F), S}
             || F <- all_files(Root),
                S <- [<<"11.x">>, <<"plus the semver tag">>,
                      <<"both `:latest` and the semver tag">>,
                      %% the fleet is a dev and demo fleet (Raf, 2026-09-28)
                      <<"production">>],
                binary:match(folded(read(F)), S) =/= nomatch],
    ?assertEqual([], Stale),
    Readme = read(filename:join(Root, "README.md")),
    ?assertMatch({match, _},
                 re:run(Readme, "publishes\\s+its\\s+own\\s+version\\s+and\\s+nothing\\s+else")).

folded(Bin) ->
    re:replace(Bin, "\\s+", " ", [global, {return, binary}]).

%% TWO CHANNELS: main publishes :latest, a v* tag publishes its own version and
%% NOTHING ELSE. Watchtower rolls every box on :latest, so a tag that also
%% moved :latest made cutting a release the same act as deploying one.
release_tag_does_not_move_latest(Config) ->
    Body = read(filename:join(?config(root, Config),
                              ".github/workflows/build-push.yml")),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"tags=" ?REGISTRY "/" ?ORG "/" ?REPO ":${GITHUB_REF#refs/tags/v}\"">>)),
    ?assertEqual(1, length(binary:matches(Body, <<":latest\"">>))).

%% THE SCAFFOLD MUST BE USABLE BY SOMEONE WHO IS NOT US, and the first version
%% was not: it hardcoded our organisation, our registry, our GitOps repository
%% and our fleet's port allocations, so a stranger generating a service got a
%% repository that pushed to an account they cannot write to and told them to
%% edit a repository they have never seen.
%%
%% This suite generates as `acme-widgets' against a made-up registry, so any
%% house-specific string that survives is a value that is not really a variable.
%% Asserting the ABSENCE is what makes the property hold under later edits;
%% asserting the presence of <%org%> would not, because a comment mentioning us
%% by name would still slip through.
leaks_no_house_specifics(Config) ->
    Root = ?config(root, Config),
    Forbidden = [<<"macula-services">>,   %% our organisation
                 <<"hecate-services">>,   %% the parent org -- a leak here
                                          %% means the rename missed one
                 <<"ghcr.io/">>,          %% our registry, as a path prefix
                 <<"macula-io">>,         %% the org our build images live in
                 <<"macula-ci-">>,        %% our build images, by name
                 <<"macula-pq-runtime">>, %% our runtime image, by name
                 <<"macula-demo">>,       %% our old GitOps repository
                 <<"macula-fleet">>,      %% our GitOps repository
                 <<"beam0">>,             %% our node names
                 <<"reconcile.manifest">>,%% our deployment mechanism
                 <<"hecate">>,            %% the obsolete services' prefix
                 <<"Lefever">>,           %% our copyright holder
                 <<"self-hosted">>        %% our runners
                ],
    Leaks = [{filename:basename(F), S}
             || F <- all_files(Root),
                S <- Forbidden,
                binary:match(read(F), S) =/= nomatch],
    ?assertEqual([], Leaks).

%%%---------------------------------------------------------------------------
%%% Does the generated service hold up
%%%---------------------------------------------------------------------------

%% init_per_suite already failed the run if they did not compile. What is left to
%% assert is that the behaviour attribute is actually present, since that is the
%% guard turning a forgotten callback into a compile error for the next service.
generated_sources_satisfy_the_behaviour(Config) ->
    Results = ?config(compiled, Config),
    ?assertEqual(3, length(Results)),
    Mod = list_to_atom(?APP "_service"),
    {module, Mod} = code:ensure_loaded(Mod),
    %% One `-behaviour' attribute, whose value is itself a list of one.
    Attrs = Mod:module_info(attributes),
    ?assertEqual([[mcl_om_service]],
                 proplists:get_all_values(behaviour, Attrs)).

%% The two names must agree and the version must be the application's own. The
%% GENERATED suite asserts these too; asserting them here means a template that
%% breaks the pair is caught in this repository rather than in whatever service
%% gets scaffolded next.
generated_service_reports_the_scaffolded_names(_Config) ->
    Mod = list_to_atom(?APP "_service"),
    #{name := Name, description := Desc, version := Vsn} = Mod:info(),
    ?assertEqual(list_to_binary(?REPO), Name),
    ?assertEqual(list_to_binary(?DESC), Desc),
    ?assertEqual(<<"0.1.0">>, Vsn),
    #{scope := Scope, actions := Actions, resources := Resources} =
        Mod:identity_spec(),
    ?assertEqual(list_to_binary(?REPO), Scope),
    %% Empty on purpose: a service that does nothing must not claim authority,
    %% and the previous template claimed two actions and a wildcard resource.
    ?assertEqual([], Actions),
    ?assertEqual([], Resources),
    ?assertEqual([], Mod:capabilities()).

%%%---------------------------------------------------------------------------
%%% The choices a scaffold makes, and what it says afterwards
%%%---------------------------------------------------------------------------

%% A SCAFFOLDED SERVICE EXISTS TO ANSWER ON THE MESH, so it refuses to boot
%% without its realm, realm key and pinned seeds, naming each missing one,
%% rather than booting green with no pool (mcl_om_identity, `mesh').
generated_service_requires_the_mesh(Config) ->
    SysConfig = read(filename:join(?config(root, Config), "config/sys.config.src")),
    ?assertMatch({match, _}, re:run(SysConfig, "^\\s+\\{mesh,\\s*required\\},?$",
                                    [multiline])).

%% THE FLOOR IS THIS RELEASE'S MINOR. The template is released with mcl_om and
%% relies on what that release does (`{mesh, required}' above), so a service
%% generated from it depends on at least the minor it came from. The floor was
%% left at 0.26 for seven minors.
generated_service_floor_is_this_release(Config) ->
    {ok, Terms} = file:consult(filename:join(?config(root, Config), "rebar.config")),
    Deps = proplists:get_value(deps, Terms),
    {mcl_om, Constraint} = lists:keyfind(mcl_om, 1, Deps),
    _ = application:load(mcl_om),
    {ok, Vsn} = application:get_key(mcl_om, vsn),
    [Major, Minor | _] = string:split(Vsn, ".", all),
    ?assertEqual("~> " ++ Major ++ "." ++ Minor, Constraint).

%% THE LICENCE IS A CHOICE, and the visibility makes it: a public service is
%% Apache-2.0, a private one carries a proprietary notice. The two must agree
%% in the LICENSE file, the app.src hex reads, and the README.
licence_follows_the_visibility(Config) ->
    Year = integer_to_binary(element(1, element(1, calendar:local_time()))),
    Public = ?config(root, Config),
    ?assertNotEqual(nomatch, binary:match(licence(Public), <<"Apache License">>)),
    ?assertNotEqual(nomatch, binary:match(licence(Public),
                                          <<"Copyright ", Year/binary, " " ?HOLDER>>)),
    ?assertEqual(["Apache-2.0"], app_licences(Public, ?APP)),
    ?assertMatch({match, _}, re:run(read(filename:join(Public, "README.md")),
                                    "^## Licence\n\nApache-2\\.0\\.$", [multiline])),
    Private = ?config(house_root, Config),
    ?assertNotEqual(nomatch, binary:match(licence(Private), <<"All rights reserved">>)),
    ?assertNotEqual(nomatch, binary:match(licence(Private), <<"is proprietary">>)),
    ?assertEqual(nomatch, binary:match(licence(Private), <<"Apache">>)),
    ?assertEqual(["Proprietary"], app_licences(Private, ?HOUSE_APP)),
    ?assertMatch({match, _}, re:run(read(filename:join(Private, "README.md")),
                                    "^## Licence\n\nProprietary", [multiline])).

licence(Root) ->
    read(filename:join(Root, "LICENSE")).

app_licences(Root, App) ->
    {ok, [{application, _, Keys}]} =
        file:consult(filename:join([Root, "apps", App, "src", App ++ ".app.src"])),
    proplists:get_value(licenses, Keys).

%% THE RUNNER IS A CHOICE. The house runs private services' CI on its own
%% runners, labelled per org; anyone else, and anything public, gets GitHub's.
runner_follows_the_visibility(Config) ->
    ?assertEqual([<<"[\"ubuntu-latest\"]">>, <<"[\"ubuntu-latest\"]">>],
                 runners(?config(root, Config))),
    ?assertEqual([<<"[\"self-hosted\", \"msi00\", \"pq\"]">>,
                  <<"[\"self-hosted\", \"msi00\", \"pq\"]">>],
                 runners(?config(house_root, Config))).

runners(Root) ->
    [runs_on(read(filename:join([Root, ".github", "workflows", W])))
     || W <- ["lint.yml", "build-push.yml"]].

runs_on(Workflow) ->
    {match, [Runner]} = re:run(Workflow, "^    runs-on: (.+)$",
                               [multiline, {capture, all_but_first, binary}]),
    Runner.

%% PRIVATE OR PUBLIC IS ASKED, NEVER ASSUMED. It decides the licence, the
%% runner and the repository's visibility, and the old closing text answered
%% it for you with `--public'. No value, or one that is neither, is refused
%% naming the variable, before anything is generated.
scaffold_asks_the_visibility(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "no_visibility"),
    ok = filelib:ensure_path(Dir),
    Refusals = [scaffold_status(Dir, "mcl-no-visibility", Env)
                || Env <- [[], ["MCL_VISIBILITY="], ["MCL_VISIBILITY=yes"]]],
    [begin
         ?assertNotEqual(0, Status),
         ?assertNotEqual(nomatch, binary:match(Out, <<"MCL_VISIBILITY">>))
     end || {Status, Out} <- Refusals],
    ?assertNot(filelib:is_dir(filename:join(Dir, "mcl-no-visibility"))).

%% A PUBLIC REPOSITORY NEVER RUNS ON OUR RUNNERS: a pull request from anyone
%% would run its code on our machine. Asking for it is refused; the public
%% scaffold says `--public', never `--private', and is Apache-2.0.
public_scaffold_says_public_and_stays_off_our_runners(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "public"),
    ok = filelib:ensure_path(Dir),
    %% A runner that is not a JSON array would break attest-image.yml's
    %% runs-on input at run time; the script refuses it at scaffold time.
    {NotJson, WhyNot} = scaffold_status(Dir, "mcl-runner-not-json",
                                        ["MCL_VISIBILITY=private", "MCL_RUNS_ON=[self-hosted, msi00, pq]"]),
    ?assertNotEqual(0, NotJson),
    ?assertNotEqual(nomatch, binary:match(WhyNot, <<"JSON array">>)),
    ?assertNot(filelib:is_dir(filename:join(Dir, "mcl-runner-not-json"))),
    {Refused, Why} = scaffold_status(Dir, "mcl-public-on-ours",
                                     ["MCL_VISIBILITY=public",
                                      "MCL_RUNS_ON=[\"self-hosted\", \"msi00\", \"pq\"]"]),
    ?assertNotEqual(0, Refused),
    ?assertNotEqual(nomatch, binary:match(Why, <<"self-hosted">>)),
    ?assertNot(filelib:is_dir(filename:join(Dir, "mcl-public-on-ours"))),
    {0, Out} = scaffold_status(Dir, "mcl-public-probe", ["MCL_VISIBILITY=public"]),
    Root = filename:join(Dir, "mcl-public-probe"),
    ?assertNotEqual(nomatch, binary:match(Out, <<"--public">>)),
    ?assertEqual(nomatch, binary:match(Out, <<"--private">>)),
    ?assertEqual([<<"[\"ubuntu-latest\"]">>, <<"[\"ubuntu-latest\"]">>], runners(Root)),
    ?assertEqual(["Apache-2.0"], app_licences(Root, "mcl_public_probe")).

%% WHAT THE SCRIPT SAYS WHEN IT IS DONE MUST BE TRUE OF WHAT IT GENERATED. It
%% said a merge pushes `:latest and the semver tag' (a tag pushes only its own
%% version), that watchtower rolls the beams (they reconcile from the fleet
%% repository), and offered `--public' whatever the service was.
closing_text_is_true_to_the_template(Config) ->
    Out = folded(?config(house_out, Config)),
    ?assertNotEqual(nomatch, binary:match(Out, <<"--private">>)),
    [?assertEqual({S, nomatch}, {S, binary:match(Out, S)})
     || S <- [<<"--public">>, <<"the semver tag">>, <<"watchtower">>,
              <<"--remote=github">>]],
    ?assertNotEqual(nomatch, binary:match(Out, <<"--remote=origin">>)).

%% THE IMAGE BUILD RUNS ON GITHUB'S RUNNERS AND ON OURS ALIKE. Ours have no
%% docker: a shim hands the `docker' CLI to podman, and docker/build-push-action
%% needs Docker's buildx, which podman is not. Plain `docker' CLI steps run on
%% both. The registry login goes to files under $RUNNER_TEMP, DOCKER_CONFIG for
%% docker and REGISTRY_AUTH_FILE for podman, because the runners on one box share
%% one podman and one default auth file. The image is built under a tag unique
%% to the run and removed by name afterwards, never by wildcard. And in docker
%% format, or podman drops the image's HEALTHCHECK (seen on msi00, 2026-09-28).
image_build_runs_on_docker_and_podman_alike(Config) ->
    [begin
         Body = read(filename:join([Root, ".github", "workflows", "build-push.yml"])),
         ?assertEqual(nomatch, binary:match(Body, <<"uses: docker/">>)),
         [?assertNotEqual({S, nomatch}, {S, binary:match(Body, S)})
          || S <- [<<"DOCKER_CONFIG=$RUNNER_TEMP/">>,
                   <<"REGISTRY_AUTH_FILE=$RUNNER_TEMP/">>,
                   <<"--password-stdin">>,
                   <<"${{ github.run_id }}">>,
                   <<"docker rmi ">>,
                   %% the credentials are removed whenever a login ran, even
                   %% when a later step failed before the build
                   <<"steps.login.outcome != 'skipped'">>,
                   %% podman builds OCI by default, which has no HEALTHCHECK:
                   %% the image would lose the one its Containerfile declares.
                   %% docker ignores the variable.
                   <<"BUILDAH_FORMAT: docker">>]],
         ?assertEqual(nomatch, binary:match(Body, <<"prune">>))
     end || Root <- [?config(root, Config), ?config(house_root, Config)]].

%% ONLY MAIN FEEDS :latest AND ONLY A v* TAG FEEDS THE ARCHIVE. The workflow
%% can be run by hand, and from a branch every ref that was not a v* tag fell
%% through to :latest: an ungated branch build overwrote the deploy channel
%% (Fable, on mcl-fovea). Any other ref is refused, naming it.
only_main_and_release_tags_publish(Config) ->
    Body = read(filename:join(?config(root, Config), ".github/workflows/build-push.yml")),
    ?assertMatch({match, _}, re:run(Body, "^\\s+refs/heads/main\\) echo \"tags=\\S+:latest\"",
                                    [multiline])),
    ?assertMatch({match, _}, re:run(Body, "^\\s+\\*\\) echo \"::error::.*\\$GITHUB_REF.*exit 1",
                                    [multiline])),
    ?assertEqual(nomatch, binary:match(Body, <<"else">>)).

%% EVERY HOUSE IMAGE IS SIGNED BY DIGEST (M6). mcl-mail shipped unsigned
%% because its build-push had no attest job, and the scaffold had none either.
%% The house scaffold now calls macula-ci-images' attest-image.yml, pinned by
%% full commit sha (the signing identity is that file at that ref), after the
%% build, with the digest the build pushed and the build's own runner. The
%% stranger's scaffold has no attest job: the workflow is ours.
house_images_are_signed_by_digest(Config) ->
    House = read(filename:join(?config(house_root, Config), ".github/workflows/build-push.yml")),
    ?assertMatch({match, _},
                 re:run(House, "^  attest:\n    needs: build-and-push\n", [multiline])),
    ?assertMatch({match, _},
                 re:run(House, "^    uses: macula-io/macula-ci-images/\\.github/workflows/"
                               "attest-image\\.yml@[0-9a-f]{40}$", [multiline])),
    ?assertMatch({match, _},
                 re:run(House, "^      image: ghcr\\.io/macula-services/" ?HOUSE_REPO "$", [multiline])),
    ?assertMatch({match, _},
                 re:run(House, "^      digest: \\$\\{\\{ needs\\.build-and-push\\.outputs\\.digest \\}\\}$",
                        [multiline])),
    ?assertMatch({match, _},
                 re:run(House, "^      runs-on: '\\[\"self-hosted\", \"msi00\", \"pq\"\\]'$", [multiline])),
    ?assertMatch({match, _},
                 re:run(House, "^      digest: \\$\\{\\{ steps\\.digest\\.outputs\\.digest \\}\\}$",
                        [multiline])),
    Stranger = read(filename:join(?config(root, Config), ".github/workflows/build-push.yml")),
    ?assertEqual(nomatch, binary:match(Stranger, <<"attest">>)).

%% THE GENERATED SUITE GUARDS THE ATTRIBUTE, as the generated README and
%% service module say it does. The export check survives the attribute being
%% removed, so on its own it made that claim false (Fable, on mcl-fovea).
generated_tests_guard_the_behaviour_attribute(Config) ->
    Tests = read(filename:join([?config(root, Config), "apps", ?APP, "test",
                                ?APP "_service_tests.erl"])),
    ?assertMatch({match, _},
                 re:run(Tests, "lists:member\\(mcl_om_service,\\s*proplists:get_value\\(behaviour")).

scaffold_status(Dir, Repo, Env) ->
    Port = erlang:open_port(
             {spawn_executable, "/usr/bin/env"},
             [{args, ["-u", "MCL_VISIBILITY", "-u", "MCL_RUNS_ON", "-u", "MCL_ORG",
                      "-u", "MCL_BUILDER_IMAGE", "-u", "MCL_RUNTIME_IMAGE"]
                     ++ Env ++ [scaffold_script(), Repo, "A visibility probe", "8496"]},
              {cd, Dir}, exit_status, stderr_to_stdout, binary]),
    collect_status(Port, <<>>).

%%%---------------------------------------------------------------------------
%%% Helpers
%%%---------------------------------------------------------------------------

all_files(Root) ->
    filelib:fold_files(Root, ".*", true, fun(F, Acc) -> [F | Acc] end, []).

read(Path) ->
    {ok, Bin} = file:read_file(Path),
    Bin.

file_mode(Path) ->
    {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
    Mode.

git(Repo, Args) ->
    os:cmd("git -C " ++ Repo ++ " -c user.email=t@example.test -c user.name=t "
           "-c commit.gpgsign=false " ++ Args).

%% Writes one file and commits it, returning the new commit's sha.
commit(Repo, Rel, Content) ->
    Path = filename:join(Repo, Rel),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Content),
    git(Repo, "add -A"),
    git(Repo, "commit -q -m " ++ filename:basename(Rel)),
    string:trim(git(Repo, "rev-parse HEAD")).

gate(Script, Repo, Before, After) ->
    run(Script, [Before, After], Repo).

%%%---------------------------------------------------------------------------
%%% Persistence is the service's own (mcl-om#10)
%%%---------------------------------------------------------------------------

%% A storeless service names no store at all: not in its deps, not in its
%% applications, and not in the text that tells a reader how to add one by
%% exporting callbacks to mcl_om, which no longer opens a store.
storeless_scaffold_names_no_store(Config) ->
    Root = ?config(root, Config),
    lists:foreach(
      fun(F) ->
              Text = read(Root, F),
              [ct:fail({storeless_scaffold_names, D, F})
               || D <- [<<"reckon_db">>, <<"reckon_evoq">>, <<"{evoq">>, <<"mcl_om_store">>],
                  nomatch =/= binary:match(Text, D)]
      end,
      ["rebar.config", "apps/" ?APP "/src/" ?APP ".app.src",
       "apps/" ?APP "/src/" ?APP "_app.erl"]).

%% A service scaffolded with store=1 owns its store: its own copy of the wiring,
%% the three applications declared at ~> MAJOR.MINOR, and the
%% store opened in its own start/2 before mcl_om:boot/1.
store_scaffold_owns_its_store(Config) ->
    Root = ?config(store_root, Config),
    Src = "apps/" ?STORE_APP "/src/",
    Rebar = read(Root, "rebar.config"),
    [nomatch =/= binary:match(Rebar, Dep) orelse ct:fail({store_dep_missing, Dep})
     || Dep <- [<<"{reckon_db,">>, <<"{evoq,        \"~> 1.26\"}">>,
                <<"{reckon_evoq, \"~> 2.7\"}">>]],
    {ok, [{application, _, Props}]} = file:consult(filename:join(Root, Src ++ ?STORE_APP ".app.src")),
    Apps = proplists:get_value(applications, Props),
    [lists:member(A, Apps) orelse ct:fail({store_application_missing, A})
     || A <- [reckon_db, evoq, reckon_evoq]],
    App = read(Root, Src ++ ?STORE_APP "_app.erl"),
    [nomatch =/= binary:match(App, W) orelse ct:fail({store_wiring_missing, W})
     || W <- [<<"reckon_db_sup:start_store(">>, <<"reckon_db_sup:which_stores()">>,
              <<"evoq_store_subscription:start_link(">>]],
    {Open, _} = binary:match(App, <<"ok = open_store(),">>),
    {Boot, _} = binary:match(App, <<"mcl_om:boot(">>),
    Open < Boot orelse ct:fail(store_opened_after_boot),
    %% A service generated by this very release must not trip the warning meant for
    %% services built on the old contract (Mercurius, on e72fbb5): its service
    %% module exports none of the old store callbacks.
    true = code:add_patha(filename:join(filename:dirname(Root), "ebin")),
    Service = list_to_atom(?STORE_APP "_service"),
    {module, Service} = code:ensure_loaded(Service),
    [] = mcl_om:leftover_store_callbacks(Service).

read(Root, Rel) ->
    {ok, Bin} = file:read_file(filename:join(Root, Rel)),
    Bin.
