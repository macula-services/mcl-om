%%% /health over a Unix socket (`health_socket'): no service listens on a port
%%% just to be health-checked. Set, the listener is a local socket only, a stale
%%% socket file is replaced, and only the service's own user may connect; no TCP
%%% health listener runs, whatever `health_port' says. Unset, `health_port' is
%%% the fallback.
-module(mcl_om_health_socket_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%% This module is also the supervisor the listener specs start under.
-behaviour(supervisor).
-export([init/1]).

socket_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun get_health_answers_over_the_socket/1,
      fun no_tcp_port_is_open_when_the_socket_is_set/1,
      fun a_stale_socket_file_is_replaced/1,
      fun only_the_owner_may_connect/1,
      fun without_a_socket_the_port_is_the_fallback/1]}.

get_health_answers_over_the_socket(#{path := Path}) ->
    ok = application:set_env(mcl_om, health_socket, Path),
    started(mcl_om_sup:health_listener()),
    ?_assertMatch(<<"HTTP/1.1 200", _/binary>>, get_health({local, Path})).

no_tcp_port_is_open_when_the_socket_is_set(#{path := Path}) ->
    Port = free_port(),
    ok = application:set_env(mcl_om, health_socket, Path),
    ok = application:set_env(mcl_om, health_port, Port),
    Specs = mcl_om_sup:health_listener(),
    started(Specs),
    [?_assertEqual(1, length(Specs)),
     ?_assertEqual({error, econnrefused},
                   gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 2000)),
     ?_assertMatch(<<"HTTP/1.1 200", _/binary>>, get_health({local, Path}))].

a_stale_socket_file_is_replaced(#{path := Path}) ->
    ok = file:write_file(Path, <<"left by a container that died">>),
    ok = application:set_env(mcl_om, health_socket, Path),
    started(mcl_om_sup:health_listener()),
    ?_assertMatch(<<"HTTP/1.1 200", _/binary>>, get_health({local, Path})).

only_the_owner_may_connect(#{path := Path}) ->
    ok = application:set_env(mcl_om, health_socket, Path),
    started(mcl_om_sup:health_listener()),
    {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
    ?_assertEqual(8#600, Mode band 8#777).

without_a_socket_the_port_is_the_fallback(_) ->
    Port = free_port(),
    ok = application:unset_env(mcl_om, health_socket),
    ok = application:set_env(mcl_om, health_port, Port),
    started(mcl_om_sup:health_listener()),
    ?_assertMatch(<<"HTTP/1.1 200", _/binary>>, get_health({127, 0, 0, 1}, Port)).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

setup() ->
    {ok, Apps} = application:ensure_all_started(cowboy),
    _ = application:load(mcl_om),
    Saved = [{K, application:get_env(mcl_om, K)} || K <- [health_socket, health_port]],
    Dir = filename:join("/tmp", "mcl_om_health_socket_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    %% The handler's verdict is not what this suite tests: a stand-in answers.
    _ = catch meck:unload(mcl_om_health_handler),
    ok = meck:new(mcl_om_health_handler, [passthrough]),
    ok = meck:expect(mcl_om_health_handler, init,
                     fun(Req, State) -> {ok, cowboy_req:reply(200, #{}, <<"ok">>, Req), State} end),
    #{apps => Apps, saved => Saved, dir => Dir, path => filename:join(Dir, "health.sock"),
      sup => start_holder()}.

teardown(#{apps := Apps, saved := Saved, dir := Dir, sup := {Holder, Sup}}) ->
    Holder ! stop,
    wait_down(Sup),
    meck:unload(mcl_om_health_handler),
    [restore(K, V) || {K, V} <- Saved],
    lists:foreach(fun application:stop/1, lists:reverse(Apps)),
    _ = file:del_dir_r(Dir),
    ok.

restore(K, undefined) -> application:unset_env(mcl_om, K);
restore(K, {ok, V}) -> application:set_env(mcl_om, K, V).

%% A supervisor the listener child specs are started under, as mcl_om_sup does.
start_holder() ->
    Parent = self(),
    Holder = spawn(fun() ->
                           {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
                           Parent ! {holder, Sup},
                           receive stop -> exit(shutdown) end
                   end),
    receive {holder, Sup} -> {Holder, Sup} after 5000 -> error(no_holder) end.

started(Specs) ->
    Sup = whereis(?MODULE),
    [{ok, _} = supervisor:start_child(Sup, Spec) || Spec <- Specs],
    ok.

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, []}}.

wait_down(Pid) ->
    Ref = erlang:monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end.

get_health(Address) ->
    get_health(Address, 0).

get_health(Address, Port) ->
    {ok, S} = gen_tcp:connect(Address, Port, [binary, {active, false}], 2000),
    ok = gen_tcp:send(S, <<"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n">>),
    {ok, Reply} = gen_tcp:recv(S, 0, 2000),
    gen_tcp:close(S),
    Reply.

free_port() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(L),
    gen_tcp:close(L),
    Port.
