%%% @doc Cowboy handler — GET /health.
%%%
%%% Returns 200 + JSON when the service is `ok'; 503 + JSON for
%%% `{degraded, _}' or `{down, _}'. Podman's HEALTHCHECK and
%%% Kubernetes-style liveness probes consume this.
-module(mcl_om_health_handler).

-export([init/2, routes/0, body/7]).

routes() ->
    [{"/health", ?MODULE, []}].

init(Req0, State) ->
    Health = mcl_om:health(),
    Body = body(Health, service_info(mcl_om:service_module()), grant_report(),
                advertise_report(), subscription_report(), mcl_om_claim:status(),
                mcl_om_pubsub:failed_publishes()),
    Req = cowboy_req:reply(code(Health),
                           #{<<"content-type">> => <<"application/json">>},
                           jsx:encode(Body), Req0),
    {ok, Req, State}.

%% @doc The JSON body for a health verdict. Every state lists the
%% provider grants, so a service still inside its waiting window
%% answers ok and says which procedure is not granted yet and why;
%% every state also lists the advertise loop's last outcome per
%% procedure (last successful advertise age), so a dead advertise loop
%% cannot hide behind `ok' + `failed_publishes: 0' -- zero is exactly
%% what a loop that makes no attempts produces (issue #5). Every state
%% also carries the boot claim's state (mcl_om_claim:status/0), so a
%% claim the realm holds as pending is visible to its operator here, and
%% the subscription set's own report (declared, running, last failure per
%% topic), so a subscriber that will not start is visible without reading
%% a log -- and, through the verdict, rather than behind an `ok'
%% (mcl-om#41).
-spec body(mcl_om_service:health(), map(), [map()], [map()], map(), map(),
           non_neg_integer()) -> map().
body(ok, Info, Grants, Advertise, Subscriptions, Claim, FailedPublishes) ->
    Info#{status => <<"ok">>, provider_grants => Grants,
          advertise_liveness => Advertise, subscriptions => Subscriptions,
          claim => Claim, failed_publishes => FailedPublishes};
body({degraded, Reason}, _Info, Grants, Advertise, Subscriptions, Claim, FailedPublishes) ->
    (unhealthy(<<"degraded">>, Reason, Grants, Advertise, Subscriptions))#{claim => Claim,
                                                                         failed_publishes => FailedPublishes};
body({down, Reason}, _Info, Grants, Advertise, Subscriptions, Claim, FailedPublishes) ->
    (unhealthy(<<"down">>, Reason, Grants, Advertise, Subscriptions))#{claim => Claim,
                                                                     failed_publishes => FailedPublishes}.

unhealthy(Status, Reason, Grants, Advertise, Subscriptions) ->
    #{status             => Status,
      reason             => iolist_to_binary(io_lib:format("~p", [Reason])),
      provider_grants    => Grants,
      advertise_liveness => Advertise,
      subscriptions      => Subscriptions}.

code(ok)     -> 200;
code(_NotOk) -> 503.

service_info(undefined) -> #{};
service_info(Mod)       -> Mod:info().

grant_report() ->
    mcl_om_provider_grant:report(mcl_om_capabilities:provider_grants(),
                                 #{mono => erlang:monotonic_time(millisecond),
                                    sys  => erlang:system_time(millisecond)},
                                 mcl_om_provider_grant:grace_ms()).

advertise_report() ->
    mcl_om_advertise_liveness:report(mcl_om_capabilities:advertise_liveness(),
                                     erlang:monotonic_time(millisecond),
                                     mcl_om_advertise_liveness:stale_after_ms()).

subscription_report() ->
    mcl_om_pubsub_subscriptions:report().
