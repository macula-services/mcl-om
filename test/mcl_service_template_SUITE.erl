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
         generated_rebar3_is_pinned_by_sha256/1,
         generated_service_has_its_org/1,
         generated_ci_runs_dialyzer_with_macula_in_view/1,
         generated_gitignore_covers_what_the_tests_write/1,
         generated_text_is_current/1,
         no_unrendered_variable_survives/1,
         generated_workflow_keeps_actions_syntax/1,
         leaks_no_house_specifics/1,
         generated_sources_satisfy_the_behaviour/1,
         generated_service_reports_the_scaffolded_names/1]).

-define(REPO, "mcl-probe-svc").
-define(APP,  "mcl_probe_svc").
-define(DESC, "A generated probe service").
-define(PORT, "8499").
%% DELIBERATELY NOT OUR OWN ORG OR REGISTRY. Generating as a stranger is what
%% makes leaked_house_specifics/1 able to prove the scaffold is usable by one.
-define(ORG,      "acme-widgets").
-define(REGISTRY, "registry.example.test").

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
     generated_rebar3_is_pinned_by_sha256,
     generated_service_has_its_org,
     generated_ci_runs_dialyzer_with_macula_in_view,
     generated_gitignore_covers_what_the_tests_write,
     generated_text_is_current,
     no_unrendered_variable_survives,
     generated_workflow_keeps_actions_syntax,
     leaks_no_house_specifics,
     generated_sources_satisfy_the_behaviour,
     generated_service_reports_the_scaffolded_names].

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
                       "org=" ?ORG, "registry=" ?REGISTRY],
              Work),
    ct:pal("rebar3 new said:~n~s", [Out]),
    Root = filename:join(Work, ?REPO),
    filelib:is_dir(Root) orelse ct:fail({no_output_dir, Root, Out}),
    Compiled = compile_generated(Root, Ebin),
    [{root, Root}, {ebin, Ebin}, {compiled, Compiled}, {added, Added} | Config].

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
    Port = erlang:open_port(
             {spawn_executable, Exe},
             [{args, Args}, {cd, Cwd}, exit_status, stderr_to_stdout, binary,
              {env, [{"REBAR_BASE_DIR", false},
                     {"REBAR_CONFIG", false},
                     {"REBAR_PROFILE", false}]}]),
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
%% choosing it. The builder and the lint image are both pinned by tag and
%% digest, public hexpm images a stranger can pull (never ours: see
%% leaks_no_house_specifics/1; Docker's own `erlang' has no 28.4.3), the
%% builder on the same Alpine as the runtime stage, lint's first step refuses
%% anything but 28.4.3 with mldsa87, and .tool-versions names the same release.
generated_service_is_pinned_to_one_otp(Config) ->
    Root = ?config(root, Config),
    Containerfile = read(filename:join(Root, "Containerfile")),
    Lint = read(filename:join(Root, ".github/workflows/lint.yml")),
    ?assertMatch({match, _},
                 re:run(Containerfile,
                        "^FROM docker\\.io/hexpm/erlang:28\\.4\\.3-alpine-3\\.22\\.[0-9]+@sha256:[0-9a-f]{64} AS builder$",
                        [multiline])),
    ?assertMatch({match, _},
                 re:run(Lint, "image: docker\\.io/hexpm/erlang:28\\.4\\.3-debian-trixie-[0-9]{8}@sha256:[0-9a-f]{64}$",
                        [multiline])),
    ?assertNotEqual(nomatch, binary:match(Lint, <<"{<<\"28.4.3\">>, true} -> halt(0);">>)),
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
        ok = Mod:the_runtime_agrees_between_the_image_the_ci_and_this_vm_test()
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
generated_lint_toolchain_runs_in_its_image(Config) ->
    Lint = filename:join(?config(root, Config), ".github/workflows/lint.yml"),
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

%% rebar3 is a tool in the build and test path, pinned like the images: one
%% release, verified by sha256, the SAME in the image build and in lint. The
%% image build fetched it from an S3 URL that serves whatever was published
%% last.
generated_rebar3_is_pinned_by_sha256(Config) ->
    Root = ?config(root, Config),
    Pinned = [read(filename:join(Root, F))
              || F <- ["Containerfile", ".github/workflows/lint.yml"]],
    Sums = [re:run(B, "\\b([0-9a-f]{64})  /usr/local/bin/rebar3", [{capture, all_but_first, binary}])
            || B <- Pinned],
    ?assertMatch([{match, [Sum]}, {match, [Sum]}], Sums),
    [?assertNotEqual(nomatch,
                     binary:match(B, <<"releases/download/3.27.0/rebar3">>)) || B <- Pinned],
    [?assertEqual(nomatch, binary:match(B, <<"s3.amazonaws.com/rebar3">>)) || B <- Pinned].

%% ONE ORG PER SERVICE, NAMED AFTER THE REPOSITORY, fixed in the release rather
%% than left to an environment variable someone can forget. Without it
%% mcl_om_identity:org/0 answers `_', and mcl_om now refuses to advertise
%% under that: the service would announce nothing.
generated_service_has_its_org(Config) ->
    SysConfig = read(filename:join(?config(root, Config), "config/sys.config.src")),
    ?assertMatch({match, _},
                 re:run(SysConfig, "\\{org,\\s*<<\"" ?REPO "\">>\\}")).

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
                      <<"both `:latest` and the semver tag">>],
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
                 <<"macula-demo">>,       %% our old GitOps repository
                 <<"macula-fleet">>,      %% our GitOps repository
                 <<"beam0">>,             %% our node names
                 <<"reconcile.manifest">>,%% our deployment mechanism
                 <<"hecate">>             %% the obsolete services' prefix
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
