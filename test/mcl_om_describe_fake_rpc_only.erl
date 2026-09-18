%%% @doc Test fixture only: a fake service exporting ONLY
%%% describe_rpc_capabilities/0, for mcl_om_describe_tests.erl.
-module(mcl_om_describe_fake_rpc_only).

-export([describe_rpc_capabilities/0]).

describe_rpc_capabilities() ->
    [#{name => <<"svc.ping">>, description => <<"Liveness check">>}].
