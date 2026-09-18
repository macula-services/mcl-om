%%% @doc Test fixture only: a fake service exporting NEITHER describe_*
%%% callback, for mcl_om_describe_tests.erl -- the "nothing to
%%% advertise" case.
-module(mcl_om_describe_fake_none).

-export([info/0]).

info() ->
    #{name => <<"svc-none">>, version => <<"0.1.0">>, description => <<"">>}.
