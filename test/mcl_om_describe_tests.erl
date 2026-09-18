-module(mcl_om_describe_tests).

-include_lib("eunit/include/eunit.hrl").

%% `mcl_om:service_module/0' reads this exact `persistent_term' key
%% -- set directly here rather than via `mcl_om:boot/2' (which also
%% starts stores/pubsub/HTTP listeners this suite has no business
%% touching just to exercise a stateless read). Mirrored from
%% `mcl_om.erl''s own `?SERVICE_MODULE_KEY' -- if that atom ever
%% changes, this suite is meant to fail loudly, not silently test
%% nothing.
-define(SERVICE_MODULE_KEY, mcl_om_service_module).

capability_for_test_() ->
    [fun capability_for_is_undefined_when_neither_callback_is_exported/0,
     fun capability_for_is_present_when_only_rpc_is_exported/0,
     fun capability_for_is_present_when_both_are_exported/0,
     fun capability_for_has_no_auth_key_by_default/0].

describe_test_() ->
    {foreach, fun set_none/0, fun clear_service_module/1,
     [fun describe_reads_the_current_service_module/0,
      fun describe_defaults_missing_callbacks_to_empty_lists/0,
      fun describe_ignores_its_payload_argument/0]}.

capability_for_is_undefined_when_neither_callback_is_exported() ->
    ?assertEqual(undefined,
                 mcl_om_describe:capability_for(mcl_om_describe_fake_none, <<"svc">>)).

capability_for_is_present_when_only_rpc_is_exported() ->
    ?assertMatch(#{name := <<"svc.describe_capabilities">>},
                 mcl_om_describe:capability_for(mcl_om_describe_fake_rpc_only, <<"svc">>)).

capability_for_is_present_when_both_are_exported() ->
    ?assertMatch(#{name := <<"other-svc.describe_capabilities">>},
                 mcl_om_describe:capability_for(mcl_om_describe_fake_full, <<"other-svc">>)).

capability_for_has_no_auth_key_by_default() ->
    Cap = mcl_om_describe:capability_for(mcl_om_describe_fake_full, <<"svc">>),
    ?assertNot(maps:is_key(auth, Cap)).

set_none() ->
    persistent_term:put(?SERVICE_MODULE_KEY, mcl_om_describe_fake_none).

clear_service_module(_) ->
    persistent_term:erase(?SERVICE_MODULE_KEY).

describe_reads_the_current_service_module() ->
    persistent_term:put(?SERVICE_MODULE_KEY, mcl_om_describe_fake_full),
    ?assertEqual({ok, #{
        rpc    => [#{name => <<"svc.chat">>, description => <<"Chat completion">>}],
        pubsub => [#{topic => <<"svc.events">>, description => <<"Lifecycle events">>}]
    }}, mcl_om_describe:describe(ignored)).

describe_defaults_missing_callbacks_to_empty_lists() ->
    persistent_term:put(?SERVICE_MODULE_KEY, mcl_om_describe_fake_rpc_only),
    ?assertEqual({ok, #{
        rpc    => [#{name => <<"svc.ping">>, description => <<"Liveness check">>}],
        pubsub => []
    }}, mcl_om_describe:describe(ignored)).

describe_ignores_its_payload_argument() ->
    persistent_term:put(?SERVICE_MODULE_KEY, mcl_om_describe_fake_none),
    ?assertEqual({ok, #{rpc => [], pubsub => []}},
                 mcl_om_describe:describe(#{some => <<"payload">>})).
