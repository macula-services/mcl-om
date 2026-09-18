%%% @doc Test fixture only: a fake service module exporting BOTH
%%% describe_* callbacks, for mcl_om_describe_tests.erl. A real,
%%% compiled module is required here -- erlang:function_exported/3
%%% has nothing to see on a bare, undefined atom.
-module(mcl_om_describe_fake_full).

-export([describe_rpc_capabilities/0, describe_pubsub_capabilities/0]).

describe_rpc_capabilities() ->
    [#{name => <<"svc.chat">>, description => <<"Chat completion">>}].

describe_pubsub_capabilities() ->
    [#{topic => <<"svc.events">>, description => <<"Lifecycle events">>}].
