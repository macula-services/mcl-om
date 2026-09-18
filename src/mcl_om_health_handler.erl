%%% @doc Cowboy handler — GET /health.
%%%
%%% Returns 200 + JSON when the service is `ok'; 503 + JSON for
%%% `{degraded, _}' or `{down, _}'. Podman's HEALTHCHECK and
%%% Kubernetes-style liveness probes consume this.
-module(mcl_om_health_handler).

-export([init/2, routes/0]).

routes() ->
    [{"/health", ?MODULE, []}].

init(Req0, State) ->
    reply(mcl_om:health(), Req0, State).

reply(ok, Req0, State) ->
    Info = service_info(mcl_om:service_module()),
    Body = jsx:encode(Info#{status => <<"ok">>}),
    Req  = cowboy_req:reply(200,
                            #{<<"content-type">> => <<"application/json">>},
                            Body, Req0),
    {ok, Req, State};
reply({degraded, Reason}, Req0, State) ->
    reply_unhealthy(503, <<"degraded">>, Reason, Req0, State);
reply({down, Reason}, Req0, State) ->
    reply_unhealthy(503, <<"down">>, Reason, Req0, State).

service_info(undefined) -> #{};
service_info(Mod)       -> Mod:info().

reply_unhealthy(Code, Status, Reason, Req0, State) ->
    Body = jsx:encode(#{
        status => Status,
        reason => iolist_to_binary(io_lib:format("~p", [Reason]))
    }),
    Req = cowboy_req:reply(Code,
                           #{<<"content-type">> => <<"application/json">>},
                           Body, Req0),
    {ok, Req, State}.
