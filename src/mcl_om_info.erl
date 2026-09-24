%%% @doc `<org>/info': who this service is, answered on every mcl_om node with
%%% no code in the service.
%%%
%%% The realm's Providers desk counts a node online only while it has an
%%% unexpired procedure advertisement signed by it, so a service that only
%%% publishes (the mpong bots) advertised nothing and always showed offline,
%%% even while it worked. mcl_om:boot/2 adds this capability to every
%%% service's own, through the same delegation path as the rest: it appears
%%% once the org is admitted.
%%%
%%% OPEN AND CHEAP. Any mesh caller may ask; the request takes no arguments
%%% and the reply is a handful of public facts. The health word comes from the
%%% verdict mcl_om_health last computed, never a fresh probe per call, so a
%%% flood of calls cannot turn into a flood of the service's own health checks.
%%% No environment, paths, keys, grants or failure reasons are ever included.
%%%
%%% A service cannot switch it off, and may not declare its own `info'.
-module(mcl_om_info).

-export([capability/0, with_info/1, answer/1, render/1]).

-define(NAME, <<"info">>).

%% @doc The capability mcl_om advertises for every service.
-spec capability() -> mcl_om_service:capability().
capability() ->
    #{name => ?NAME, version => 1, auth => open,
      handler => {mcl_om_simple_handler, {?MODULE, answer}}}.

%% @doc A service's capabilities with `info' added. A service that declares
%% its own `info' is refused: the name is mcl_om's, on every node.
-spec with_info([mcl_om_service:capability()]) -> [mcl_om_service:capability()].
with_info(Caps) ->
    ok = not_declared([Name || #{name := Name} <- Caps]),
    [capability() | Caps].

not_declared(Names) ->
    declared(lists:member(?NAME, Names)).

declared(false) -> ok;
declared(true) -> error({mcl_om_capability_name_reserved, ?NAME}).

%% @doc The handler: the payload is ignored, since info takes no arguments.
-spec answer(term()) -> map().
answer(_Payload) ->
    render(facts(mcl_om:service_module())).

facts(ServiceMod) ->
    #{name := Name, version := Version, description := Description} = ServiceMod:info(),
    #{<<"service_name">> := ServiceName, <<"box">> := Box} = mcl_om_claim:labels(),
    Org = mcl_om_identity:org(),
    {WallMs, _} = erlang:statistics(wall_clock),
    #{name => Name, version => Version, description => Description,
      service_name => ServiceName, box => Box, org => Org,
      node_id => node_id(mcl_om_identity:identity_key()),
      macula_version => app_vsn(macula), mcl_om_version => app_vsn(mcl_om),
      uptime_s => WallMs div 1000,
      status => mcl_om_health:last(),
      capabilities => [<<Org/binary, "/", N/binary>> || #{name := N} <- mcl_om_capabilities:list()]}.

node_id({ok, Key}) -> macula_node_keys:key_id(Key);
node_id({error, _}) -> <<>>.

app_vsn(App) ->
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.

%% @doc The reply, from the facts: every string as `{text, _}' so a non-BEAM
%% caller reads text rather than bytes, numbers as numbers, no booleans.
-spec render(map()) -> map().
render(#{node_id := NodeId, status := Status, capabilities := Caps,
         macula_version := MaculaVsn, mcl_om_version := OmVsn, uptime_s := Uptime} = Facts) ->
    Text = maps:from_list([{K, text(maps:get(K, Facts))}
                           || K <- [name, version, description, service_name, box, org]]),
    Text#{node_id => text(binary:encode_hex(NodeId, lowercase)),
          macula_version => text(unicode:characters_to_binary(MaculaVsn)),
          mcl_om_version => text(unicode:characters_to_binary(OmVsn)),
          uptime_s => Uptime,
          status => text(status_word(Status)),
          capabilities => [text(C) || C <- Caps]}.

text(Bin) when is_binary(Bin) -> {text, Bin}.

%% The verdict's word, never its reason: a reason can carry internal detail.
status_word(ok) -> <<"ok">>;
status_word({degraded, _}) -> <<"degraded">>;
status_word({down, not_started}) -> <<"unknown">>;
status_word({down, _}) -> <<"down">>;
status_word({error, _}) -> <<"unknown">>.
