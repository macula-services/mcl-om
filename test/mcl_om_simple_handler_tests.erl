-module(mcl_om_simple_handler_tests).
-include_lib("eunit/include/eunit.hrl").

%% Fake handler functions dispatched to via {?MODULE, Fun} -- must be
%% exported for Module:Function(Payload) to resolve them.
-export([ok_handler/1, bare_handler/1, error_handler/1]).

init_carries_the_module_function_pair_test() ->
    ?assertEqual({ok, {?MODULE, ok_handler}},
                 mcl_om_simple_handler:init({?MODULE, ok_handler})).

%% The critical case: without this unwrap, macula_response's own
%% outcome/1 re-wraps whatever handle_request/2 replies with in another
%% {ok, _}, so a migrated capability's wire payload would gain an extra
%% layer compared to before migration -- a bug no test of outcome/1 or
%% normalise_reply/1 alone would catch, since each strips exactly one
%% layer and neither knows the other exists.
handle_request_unwraps_an_ok_tuple_test() ->
    ?assertEqual({reply, hit, {?MODULE, ok_handler}},
                 mcl_om_simple_handler:handle_request(x, {?MODULE, ok_handler})).

handle_request_passes_through_a_bare_value_test() ->
    ?assertEqual({reply, hit, {?MODULE, bare_handler}},
                 mcl_om_simple_handler:handle_request(x, {?MODULE, bare_handler})).

handle_request_surfaces_an_error_tuple_test() ->
    ?assertEqual({error, boom, {?MODULE, error_handler}},
                 mcl_om_simple_handler:handle_request(x, {?MODULE, error_handler})).

ok_handler(x) -> {ok, hit}.
bare_handler(x) -> hit.
error_handler(x) -> {error, boom}.
