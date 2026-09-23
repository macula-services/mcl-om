%%% @doc Cowboy handler — GET /health.
%%%
%%% Returns 200 + JSON when the service is `ok'; 503 + JSON for
%%% `{degraded, _}' or `{down, _}'. Podman's HEALTHCHECK and
%%% Kubernetes-style liveness probes consume this.
-module(mcl_om_health_handler).

-export([init/2, routes/0, body/3]).

routes() ->
    [{"/health", ?MODULE, []}].

init(Req0, State) ->
    Health = mcl_om:health(),
    Body = body(Health, service_info(mcl_om:service_module()), grant_report()),
    Req = cowboy_req:reply(code(Health),
                           #{<<"content-type">> => <<"application/json">>},
                           jsx:encode(Body), Req0),
    {ok, Req, State}.

%% @doc The JSON body for a health verdict. Every state lists the provider
%% grants, so a service still inside its waiting window answers ok and says
%% which procedure is not granted yet and why.
-spec body(mcl_om_service:health(), map(), [map()]) -> map().
body(ok, Info, Grants) ->
    Info#{status => <<"ok">>, provider_grants => Grants};
body({degraded, Reason}, _Info, Grants) ->
    unhealthy(<<"degraded">>, Reason, Grants);
body({down, Reason}, _Info, Grants) ->
    unhealthy(<<"down">>, Reason, Grants).

unhealthy(Status, Reason, Grants) ->
    #{status          => Status,
      reason          => iolist_to_binary(io_lib:format("~p", [Reason])),
      provider_grants => Grants}.

code(ok)     -> 200;
code(_NotOk) -> 503.

service_info(undefined) -> #{};
service_info(Mod)       -> Mod:info().

grant_report() ->
    mcl_om_provider_grant:report(mcl_om_capabilities:provider_grants(),
                                 erlang:monotonic_time(millisecond),
                                 mcl_om_provider_grant:grace_ms()).
