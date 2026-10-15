%%% @doc Is this node an admitted member of this org? Cached, for a subscriber.
%%%
%%% macula verifies who SIGNED a publication (the `publisher' in a delivery's
%%% meta), not who may publish on a topic: any node in the realm can publish on
%%% any topic, whatever org its name carries. A service that must hear only an
%%% org's own nodes (a keeper hearing its speakers, a mind hearing the news
%%% sensor) asks this about the delivery's `publisher'. The answer is the
%%% realm's own: `macula:org_member/4' reads the chain a Providers-desk
%%% admission publishes and a revocation tombstones.
%%%
%%% A MEMBER IS CACHED UNTIL THE CHAIN EXPIRES, AND NO LONGER. The realm
%%% reissues a delegation every 10 minutes with a 30-minute life, so a revoked
%%% node is heard for at most that long, and a node on the hot path costs no
%%% lookup per fact.
%%%
%%% A REFUSAL IS CACHED TOO, BRIEFLY. Without it a stranger publishing in a loop
%%% would turn each of its facts into two DHT lookups by this service: the
%%% filter would be the amplifier. One minute, and at most `?MAX_ENTRIES'
%%% entries, so a crowd of strangers cannot grow the table without bound; past
%%% the cap a refusal is simply not remembered.
%%%
%%% "COULD NOT FIND OUT" IS NEVER CACHED and never reads as a refusal: a station
%%% roll empties the record stores for under a minute, and a service that read
%%% that as a revocation would go deaf to its own org during every roll.
-module(mcl_om_org_member).

-behaviour(gen_server).

-export([start_link/0, org_member/2]).
-export([checked/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, mcl_om_org_member_cache).
-define(REFUSAL_TTL_MS, 60000).
-define(MAX_ENTRIES, 10000).
-define(SWEEP_MS, 60000).

-type answer() :: {ok, non_neg_integer()} | {error, {not_a_member | unavailable, term()}}.
-export_type([answer/0]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Whether `NodeId' (the 32-byte node id a delivery names as `publisher')
%% is an admitted member of `Org' in this service's realm.
-spec org_member(binary(), <<_:256>>) -> answer().
org_member(Org, <<_:256>> = NodeId) when is_binary(Org) ->
    checked(Org, NodeId, erlang:system_time(millisecond), fun lookup/2).

%% @doc The cached check, with the lookup passed in, so the cache's rules are
%% tested without a mesh. `Lookup(Org, NodeId)' answers as `macula:org_member/4'.
-spec checked(binary(), <<_:256>>, integer(), fun((binary(), <<_:256>>) -> answer())) -> answer().
checked(Org, NodeId, Now, Lookup) ->
    cached(ets:lookup(?TABLE, {Org, NodeId}), Org, NodeId, Now, Lookup).

cached([{_Key, Answer, Until}], _Org, _NodeId, Now, _Lookup) when Until > Now ->
    Answer;
cached(_MissOrStale, Org, NodeId, Now, Lookup) ->
    remembered(Lookup(Org, NodeId), {Org, NodeId}, Now).

remembered({ok, ExpiresAt} = Member, Key, _Now) ->
    true = ets:insert(?TABLE, {Key, Member, ExpiresAt}),
    Member;
remembered({error, {not_a_member, _}} = Refusal, Key, Now) ->
    remember_refusal(ets:info(?TABLE, size) < ?MAX_ENTRIES, Key, Refusal, Now);
remembered({error, {unavailable, _}} = Unknown, _Key, _Now) ->
    Unknown.

remember_refusal(true, Key, Refusal, Now) ->
    true = ets:insert(?TABLE, {Key, Refusal, Now + ?REFUSAL_TTL_MS}),
    Refusal;
remember_refusal(false, _Key, Refusal, _Now) ->
    Refusal.

lookup(Org, NodeId) ->
    asked(mcl_om:mesh_handles(), Org, NodeId).

asked({ok, Pool, Realm}, Org, NodeId) -> macula:org_member(Pool, Realm, Org, NodeId);
asked({error, Reason}, _Org, _NodeId) -> {error, {unavailable, Reason}}.

%%------------------------------------------------------------------------------
%% The table's owner, and its sweep of what has lapsed.

init([]) ->
    ?TABLE = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    {ok, sweep_later(#{})}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    Now = erlang:system_time(millisecond),
    _ = ets:select_delete(?TABLE, [{{'_', '_', '$1'}, [{'=<', '$1', Now}], [true]}]),
    {noreply, sweep_later(State)};
handle_info(_Other, State) ->
    {noreply, State}.

sweep_later(State) ->
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    State.
