%%% @doc Dynamic supervisor for this service's `macula_subscriber'
%%% children (piece D, `PLAN_MCL_OM_MESH_WRAPPERS.md').
%%%
%%% Starts empty; `mcl_om_pubsub_subscriptions' adds/removes one
%%% child per declared `{Topic, HandlerMod, Args}', keyed by `Topic' so
%%% it can be looked up and torn down individually. `restart =>
%%% transient': a genuine subscription loss (`macula_subscriber' turns
%%% `{macula_event_gone, ...}' into `{stop, Reason, State}') gets an
%%% ordinary supervisor restart -- "let it crash" is the whole
%%% reconnect story here, since `macula_client_replay:subs_to/2'
%%% already replays a subscription across an ordinary link respawn
%%% with no message to this process at all (confirmed live,
%%% `macula_link_respawn_replay_tests.erl' in `macula-io/macula').
%%% An explicit `terminate_child' (no longer desired) is not a crash
%%% and triggers no restart.
-module(mcl_om_pubsub_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 10
    },
    {ok, {SupFlags, []}}.
