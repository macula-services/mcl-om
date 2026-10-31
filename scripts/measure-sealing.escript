#!/usr/bin/env escript
%% -*- erlang -*-
%%
%% Measure payload sealing, as the fleet actually advertises it.
%%
%% WHY THIS EXISTS. The sealing design (macula-io/macula#135, releases A0/A/B in
%% #137 and #138) closes the register row "Payload sealing for calls and streams"
%% on a MEASUREMENT, not on a merge. The measurement is the set of
%% `procedure_advertisement' records the fleet is serving right now, each with the
%% one fact that decides the row: whether the advertisement names a KEM key. A
%% keyed advertisement is one a caller can seal to; a keyless one is readable by
%% every station on the path, whatever the service's source says it meant to do.
%%
%% WHAT IT DOES NOT DECIDE. It reads; it does not judge. A keyless advertisement
%% is not a failure here -- release A lets an operator write `off' and say so. The
%% judgement, and the two opinions this listing cannot carry on its own (which
%% services must appear, and which procedures were WRITTEN `off'), live in
%% scripts/check-sealing.sh. Run this, then run that on the output.
%%
%% WHAT IT CANNOT SEE. macula:find_records_by_type/2 returns only the records a
%% pool's connected stations know: each station holds its local replicas plus what
%% its peers gossiped. A record that fails to verify under this node's crypto
%% profile is dropped by the SDK before we see it, and an expired advertisement is
%% gone. So a procedure missing from this file is not proof it is unadvertised --
%% it is a reason to look. That is exactly why check-sealing.sh treats absence as
%% a finding rather than a zero.
%%
%% Usage:
%%
%%   scripts/measure-sealing.escript [options]
%%
%%   --lib DIR          Directory holding the SDK's build: either a rebar3
%%                      `_build/<profile>/lib' or a release's `lib'. Default:
%%                      $MCL_SEALING_LIB, else <repo>/_build/default/lib.
%%   --seed SPEC        host:port[:<64-hex node id>], repeated. Default:
%%                      $MCL_SEALING_SEEDS (comma or space separated).
%%   --comment TEXT     Extra `# ' line at the top of the output, repeated. Use it
%%                      to record which stations were queried and why.
%%   --out FILE         Write to FILE instead of stdout.
%%   --timeout MS       Give up waiting for the pool to become healthy
%%                      (default 30000).
%%   --profile NAME     Crypto profile (default pq_hybrid, which is the fleet's).
%%                      A measurement must read records the fleet signed, so a
%%                      profile that cannot verify them reports an empty fleet.
%%   --realm HEX        Only advertisements in this realm. Without it the listing
%%                      carries every realm the stations know, including the
%%                      agents' own ring procedures, and every one of those reads
%%                      as a service nobody declared.
%%
%% The measurement runs under a THROWAWAY identity in a temporary directory, never
%% the operator's own stored key: reading the DHT needs an identity to connect
%% with, and nothing else.
%%
%% Output: one line per advertisement, tab separated, plus `#' comments.
%%
%%   <procedure>	<keyed|keyless>
%%
%% A procedure advertised by several boxes appears once per advertisement, so a
%% service mid-roll that is keyed on one box and keyless on another shows BOTH
%% lines. That is the honest reading of a mixed fleet and it is what
%% check-sealing.sh needs to refuse a roll that is only half done.

-mode(compile).

-define(DEFAULT_TIMEOUT_MS, 30000).

main(Args) ->
    Opts = parse_args(Args, #{seeds => [], comments => [], timeout => ?DEFAULT_TIMEOUT_MS}),
    Lib = maps:get(lib, Opts, default_lib()),
    Seeds = seeds(Opts),
    ok = add_code_paths(Lib),
    ok = configure_sdk(maps:get(profile, Opts, pq_hybrid)),
    ok = start_macula(),
    Pool = connect(Seeds, maps:get(timeout, Opts)),
    {ok, Records} = find_advertisements(Pool),
    Lines = listing(Records, Opts),
    Header = header(Seeds, Records, Opts),
    emit(Header ++ Lines, maps:get(out, Opts, undefined)),
    catch macula_client:close(Pool),
    halt(0).

%%%===================================================================
%%% Arguments
%%%===================================================================

parse_args([], Opts) ->
    Opts;
parse_args(["--lib", Dir | Rest], Opts) ->
    parse_args(Rest, Opts#{lib => Dir});
parse_args(["--seed", Spec | Rest], Opts) ->
    parse_args(Rest, Opts#{seeds := maps:get(seeds, Opts) ++ [Spec]});
parse_args(["--comment", Text | Rest], Opts) ->
    parse_args(Rest, Opts#{comments := maps:get(comments, Opts) ++ [Text]});
parse_args(["--out", File | Rest], Opts) ->
    parse_args(Rest, Opts#{out => File});
parse_args(["--timeout", Ms | Rest], Opts) ->
    parse_args(Rest, Opts#{timeout => list_to_integer(Ms)});
parse_args(["--profile", Name | Rest], Opts) ->
    parse_args(Rest, Opts#{profile => list_to_atom(Name)});
parse_args(["--realm", Hex | Rest], Opts) ->
    parse_args(Rest, Opts#{realm => normalise_realm(list_to_binary(Hex))});
parse_args(["-h" | _], _Opts) ->
    usage(0);
parse_args(["--help" | _], _Opts) ->
    usage(0);
parse_args([Other | _], _Opts) ->
    io:format(standard_error, "measure-sealing: unknown argument: ~ts~n", [Other]),
    usage(2).

usage(Code) ->
    io:format(standard_error,
              "measure-sealing.escript [--lib DIR] [--seed host:port[:nodeid]]... "
              "[--realm HEX] [--profile NAME] [--comment TEXT] [--out FILE] "
              "[--timeout MS]~n", []),
    halt(Code).

default_lib() ->
    case os:getenv("MCL_SEALING_LIB") of
        false -> filename:join([repo_root(), "_build", "default", "lib"]);
        Dir -> Dir
    end.

%% The script lives in <repo>/scripts, so the repo is its parent's parent.
%% os:script_name/0 is the path escript was invoked with, which is enough here:
%% the fallback only has to be right when the caller passed no --lib.
repo_root() ->
    Script = filename:absname(escript:script_name()),
    filename:dirname(filename:dirname(Script)).

seeds(#{seeds := []}) ->
    case os:getenv("MCL_SEALING_SEEDS") of
        false -> no_seeds();
        Raw -> [parse_seed(S) || S <- split_seeds(Raw)]
    end;
seeds(#{seeds := Specs}) ->
    [parse_seed(S) || S <- Specs].

split_seeds(Raw) ->
    [S || S <- string:lexemes(Raw, ", "), S =/= ""].

no_seeds() ->
    io:format(standard_error,
              "measure-sealing: no seed given. Pass --seed host:port[:nodeid] "
              "or set MCL_SEALING_SEEDS. A measurement against no station is "
              "not a measurement.~n", []),
    halt(2).

parse_seed(Spec) ->
    case string:lexemes(Spec, ":") of
        [Host, Port] ->
            #{host => list_to_binary(Host), port => list_to_integer(Port)};
        [Host, Port, NodeId] ->
            #{host => list_to_binary(Host), port => list_to_integer(Port),
              expected_node_id => hex_to_bin(NodeId)};
        _ ->
            io:format(standard_error,
                      "measure-sealing: a seed is host:port[:<64 hex>], got: ~ts~n",
                      [Spec]),
            halt(2)
    end.

hex_to_bin(Hex) ->
    binary:decode_hex(list_to_binary(string:lowercase(Hex))).

%%%===================================================================
%%% The SDK
%%%===================================================================

add_code_paths(Lib) ->
    case ebins(Lib) of
        [] -> no_lib(Lib);
        Paths -> ok = code:add_pathsz(Paths)
    end.

%% Either <lib>/<app>/ebin (a rebar3 build, or a release's lib) or <lib> itself
%% being one ebin directory.
ebins(Lib) ->
    case filelib:is_dir(Lib) of
        false -> no_lib(Lib);
        true ->
            case filename:basename(Lib) of
                "ebin" -> [Lib];
                _ -> lists:sort(filelib:wildcard(filename:join([Lib, "*", "ebin"])))
            end
    end.

no_lib(Lib) ->
    io:format(standard_error,
              "measure-sealing: no SDK to load at ~ts. Pass --lib with a rebar3 "
              "_build/<profile>/lib or a release's lib.~n", [Lib]),
    halt(2).

%% The SDK refuses to start without a crypto profile, and refuses to fall back to
%% an operator's stored key when identity_dir is unset. Both are set here, before
%% the application starts, so measuring never depends on -- or writes to -- the
%% account running it.
configure_sdk(Profile) ->
    ok = application:load(macula),
    ok = application:set_env(macula, crypto_profile, Profile),
    ok = application:set_env(macula, identity_dir, throwaway_identity_dir()).

throwaway_identity_dir() ->
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"),
                         "mcl-sealing-identity-" ++ os:getpid()]),
    ok = filelib:ensure_path(Dir),
    Dir.

start_macula() ->
    case application:ensure_all_started(macula) of
        {ok, _} -> ok;
        {error, Reason} ->
            io:format(standard_error,
                      "measure-sealing: the SDK would not start: ~p~n", [Reason]),
            halt(2)
    end.

connect(Seeds, TimeoutMs) ->
    {ok, Profile} = macula_crypto_profile:configured(),
    {ok, Key} = macula_node_keys:generate(identity, Profile, #{}),
    case macula_client:connect(Seeds, #{node_identity => Key}) of
        {ok, Pool} ->
            ok = wait_healthy(Pool, TimeoutMs),
            Pool;
        {error, Reason} ->
            io:format(standard_error,
                      "measure-sealing: could not start a pool for ~p: ~p~n",
                      [Seeds, Reason]),
            halt(2)
    end.

wait_healthy(Pool, Left) when Left =< 0 ->
    io:format(standard_error,
              "measure-sealing: no link to a station became healthy in time; "
              "status was ~p~n", [macula_client:status(Pool)]),
    halt(2);
wait_healthy(Pool, Left) ->
    case macula_client:status(Pool) of
        {ok, #{healthy_links := H}} when H > 0 -> ok;
        _Status -> timer:sleep(100), wait_healthy(Pool, Left - 100)
    end.

find_advertisements(Pool) ->
    case macula:find_records_by_type(Pool, macula_record:type_procedure_advertisement()) of
        {ok, Records} -> {ok, Records};
        {error, Reason} ->
            io:format(standard_error,
                      "measure-sealing: the DHT read failed: ~p. A listing that "
                      "could not be taken must not look like an empty fleet.~n",
                      [Reason]),
            halt(2)
    end.

%%%===================================================================
%%% The listing
%%%===================================================================

listing(Records, Opts) ->
    Realm = maps:get(realm, Opts, any),
    Rows = [row(macula_record:read_procedure_advertisement(R), Realm) || R <- Records],
    sorted([R || R <- Rows, R =/= skip]).

%% The one fact that decides a row. A keyed advertisement names a KEM key and a
%% caller can seal to it; anything else is clear to every station on the path,
%% including one that carries a KEM key id but no key.
row(#{procedure := Procedure} = Ad, Realm) ->
    in_realm(Ad, Realm) andalso mode(Procedure, Ad).

%% Only one realm is the fleet's. Without this, every other realm's procedures --
%% and every agent's own ring -- land in the listing and read as services nobody
%% declared. A listing is about one realm; say which.
in_realm(_Ad, any) -> true;
in_realm(#{realm_id := RealmId}, Wanted) -> realm_hex(RealmId) =:= Wanted;
in_realm(_Ad, _Wanted) -> false.

mode(Procedure, Ad) when is_binary(Procedure), Procedure =/= <<>> ->
    case maps:is_key(kem_key, Ad) of
        true -> {Procedure, <<"keyed">>};
        false -> {Procedure, <<"keyless">>}
    end;
mode(_Procedure, _Ad) -> skip.

%% A realm id arrives as the 32 raw bytes or as text, depending on how the
%% advertiser wrote it, and the operator may type either spelling. Compare hex.
realm_hex(<<_:64/binary>> = Hex) -> normalise_realm(Hex);
realm_hex(<<_:32/binary>> = Raw) -> binary:encode_hex(Raw);
realm_hex(_Other) -> any.

normalise_realm(<<"0x", Rest/binary>>) -> normalise_realm(Rest);
normalise_realm(Bin) -> case Bin of <<_:64/binary>> -> string:lowercase(Bin); _ -> Bin end.

sorted(Rows) ->
    Lines = [<<Procedure/binary, "\t", Mode/binary, "\n">> || {Procedure, Mode} <- Rows],
    lists:usort(Lines).

header(Seeds, Records, Opts) ->
    Station = fun(#{host := H, port := P}) ->
                      [H, ":", integer_to_list(P)]
              end,
    Which = lists:join(",", [Station(S) || S <- Seeds]),
    [<<"# measured at ">>, timestamp(), <<"\n">>,
     <<"# stations queried: ">>, Which, <<"\n">>,
     <<"# realm: ">>, realm_label(maps:get(realm, Opts, any)), <<"\n">>,
     <<"# advertisements returned and verified: ">>, integer_to_list(length(Records)), <<"\n">>]
        ++ [<<"# ", (list_to_binary(C))/binary, "\n">> || C <- maps:get(comments, Opts)].

realm_label(any) ->
    <<"every realm this pool's stations know (pass --realm to scope it)">>;
realm_label(Hex) ->
    Hex.

timestamp() ->
    list_to_binary(
      calendar:system_time_to_rfc3339(erlang:system_time(second),
                                      [{unit, second}, {offset, "Z"}])).

emit(Lines, undefined) ->
    io:put_chars([Lines]);
emit(Lines, File) ->
    ok = file:write_file(File, [Lines]).
