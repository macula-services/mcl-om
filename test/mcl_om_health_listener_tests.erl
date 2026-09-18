%%% The /health listener's bind address. `health_ip' unset (or empty) keeps
%%% the listener on every interface; set, the listener accepts only there.
-module(mcl_om_health_listener_tests).

-include_lib("eunit/include/eunit.hrl").

unset_health_ip_gives_the_port_only_test() ->
    ?assertEqual([{port, 8470}], mcl_om_sup:health_socket_opts(8470, undefined)).

empty_health_ip_counts_as_unset_test() ->
    ?assertEqual([{port, 8470}], mcl_om_sup:health_socket_opts(8470, "")),
    ?assertEqual([{port, 8470}], mcl_om_sup:health_socket_opts(8470, <<>>)).

health_ip_as_a_string_is_parsed_test() ->
    ?assertEqual([{port, 8470}, {ip, {127, 0, 0, 1}}],
                 mcl_om_sup:health_socket_opts(8470, "127.0.0.1")),
    ?assertEqual([{port, 8470}, {ip, {127, 0, 0, 1}}],
                 mcl_om_sup:health_socket_opts(8470, <<"127.0.0.1">>)).

health_ip_as_a_tuple_is_kept_test() ->
    ?assertEqual([{port, 8470}, {ip, {127, 0, 0, 1}}],
                 mcl_om_sup:health_socket_opts(8470, {127, 0, 0, 1})).

listener_test_() ->
    {setup, fun start_apps/0, fun stop_apps/1,
     [fun unset_health_ip_accepts_on_another_interface/0,
      fun loopback_health_ip_accepts_on_loopback/0,
      fun loopback_health_ip_refuses_another_interface/0]}.

unset_health_ip_accepts_on_another_interface() ->
    with_listener(undefined, fun(Port) ->
        ?assertEqual(ok, connect(other_interface(), Port))
    end).

loopback_health_ip_accepts_on_loopback() ->
    with_listener("127.0.0.1", fun(Port) ->
        ?assertEqual(ok, connect({127, 0, 0, 1}, Port))
    end).

loopback_health_ip_refuses_another_interface() ->
    with_listener("127.0.0.1", fun(Port) ->
        ?assertEqual({error, econnrefused}, connect(other_interface(), Port))
    end).

%% The same socket options mcl_om_sup gives the real listener, on an
%% ephemeral port.
with_listener(Ip, Check) ->
    Ref = {?MODULE, make_ref()},
    Dispatch = cowboy_router:compile([{'_', []}]),
    {ok, _} = ranch:start_listener(Ref, ranch_tcp, mcl_om_sup:health_socket_opts(0, Ip),
                                   cowboy_clear, #{env => #{dispatch => Dispatch}}),
    Check(ranch:get_port(Ref)),
    ok = ranch:stop_listener(Ref).

connect(Address, Port) ->
    closed(gen_tcp:connect(Address, Port, [binary, {active, false}], 2000)).

closed({ok, Socket}) ->
    gen_tcp:close(Socket);
closed(Error) ->
    Error.

%% An IPv4 address of this machine that is not loopback.
other_interface() ->
    {ok, Interfaces} = inet:getifaddrs(),
    [Address | _] = [A || {_Name, Opts} <- Interfaces, {addr, A} <- Opts,
                          tuple_size(A) =:= 4, element(1, A) =/= 127],
    Address.

start_apps() ->
    {ok, Apps} = application:ensure_all_started(cowboy),
    Apps.

stop_apps(Apps) ->
    lists:foreach(fun application:stop/1, lists:reverse(Apps)).
