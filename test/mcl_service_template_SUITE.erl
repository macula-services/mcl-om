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

%% Already there: leave it alone and do not claim it for cleanup.
link_entry({ok, _Info}, _Src, _Dest) ->
    false;
link_entry({error, enoent}, Src, Dest) ->
    ok = file:make_symlink(Src, Dest),
    {true, Dest}.

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
                 <<"macula-demo">>,       %% our GitOps repository
                 <<"beam0">>,             %% our node names
                 <<"reconcile.manifest">> %% our deployment mechanism
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
