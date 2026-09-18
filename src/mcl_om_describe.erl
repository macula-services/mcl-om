%%% @doc Backs the synthetic `<service-name>.describe_capabilities'
%%% mesh capability `mcl_om:boot/2' advertises for any service
%%% exporting `describe_rpc_capabilities/0' and/or
%%% `describe_pubsub_capabilities/0' (see `mcl_om_service''s own
%%% moduledoc for both callbacks).
%%%
%%% Deliberately stateless: `describe/1' (the handler
%%% `mcl_om_simple_handler' dispatches to) reads the current
%%% service module from `mcl_om:service_module/0' -- the SAME
%%% `persistent_term' `boot/2' already populates for every other
%%% mcl_om internal that needs to know "which service am I" -- so
%%% this needs no gen_server of its own, matching `mcl_om_simple_handler`'s
%%% own "no per-request state" ethos.
-module(mcl_om_describe).

-export([describe/1, capability_for/2]).

%% @doc `mcl_om_simple_handler''s dispatch target: `Payload' is
%% ignored (this capability takes no meaningful arguments), the reply
%% is always the current service's full description.
-spec describe(term()) -> {ok, map()}.
describe(_Payload) ->
    {ok, describe_current_service()}.

describe_current_service() ->
    ServiceMod = mcl_om:service_module(),
    #{
        rpc    => rpc_capabilities(ServiceMod),
        pubsub => pubsub_capabilities(ServiceMod)
    }.

rpc_capabilities(ServiceMod) ->
    call_if_exported(ServiceMod, describe_rpc_capabilities).

pubsub_capabilities(ServiceMod) ->
    call_if_exported(ServiceMod, describe_pubsub_capabilities).

call_if_exported(undefined, _Fun) ->
    [];
call_if_exported(ServiceMod, Fun) ->
    result_or_empty(erlang:function_exported(ServiceMod, Fun, 0), ServiceMod, Fun).

result_or_empty(true, ServiceMod, Fun)  -> ServiceMod:Fun();
result_or_empty(false, _ServiceMod, _Fun) -> [].

%% @doc The synthetic `<ServiceName>.describe_capabilities' capability
%% map for `ServiceMod', or `undefined' when it exports neither
%% `describe_rpc_capabilities/0' nor `describe_pubsub_capabilities/0'
%% -- nothing to advertise, so nothing is. Left with no explicit `auth'
%% key (defaults to `open'): pure metadata about what a service exposes
%% is not sensitive, matching this codebase's own existing precedent
%% for other discovery-shaped capabilities (`hecate-llm.list_available'
%% / `hecate-llm.check_health').
-spec capability_for(module(), binary()) -> mcl_om_service:capability() | undefined.
capability_for(ServiceMod, ServiceName)
  when is_atom(ServiceMod), is_binary(ServiceName) ->
    _ = code:ensure_loaded(ServiceMod),
    HasRpc = erlang:function_exported(ServiceMod, describe_rpc_capabilities, 0),
    HasPubsub = erlang:function_exported(ServiceMod, describe_pubsub_capabilities, 0),
    capability_if_any(HasRpc orelse HasPubsub, ServiceName).

capability_if_any(false, _ServiceName) ->
    undefined;
capability_if_any(true, ServiceName) ->
    #{name    => <<ServiceName/binary, ".describe_capabilities">>,
      version => 1,
      handler => {mcl_om_simple_handler, {?MODULE, describe}}}.
