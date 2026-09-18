%%% @doc Minimal `mcl_om_service' impl that declares a barrel_docdb
%%% read model with TTL sweep armed, for the CT suite.
-module(dummy_ttl_read_model_service).
-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
-export([read_model_id/0, data_dir/0, read_model_ttl_sweep/0]).

info() ->
    #{
        name        => <<"dummy_ttl_read_model">>,
        version     => <<"0.0.0">>,
        description => <<"Test fixture with a TTL-swept read model">>
    }.

start(_Opts) ->
    Pid = spawn_link(fun() -> receive stop -> ok end end),
    {ok, Pid}.

stop(_State) -> ok.

health() -> ok.

capabilities() ->
    [#{name => <<"dummy_ttl_read_model.do_thing">>, version => 1}].

identity_spec() ->
    #{
        scope     => <<"dummy_ttl_read_model">>,
        actions   => [<<"none">>],
        resources => [<<"dummy_ttl_read_model/*">>],
        ttl_days  => 1
    }.

read_model_id() -> <<"dummy_ttl_read_model_chunks">>.

data_dir() ->
    case os:getenv("MCL_OM_CT_TTL_DATA_DIR") of
        Dir when is_list(Dir), Dir =/= "" -> Dir;
        _Unset -> "/tmp/mcl_om_ct_ttl_read_model"
    end.

%% Fast enough for a CT test to actually observe a sweep without a slow
%% suite: fold the expiry index every 100ms.
read_model_ttl_sweep() ->
    #{interval_ms => 100, batch => 100}.
