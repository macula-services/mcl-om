%%% @doc The nonces of ownership proofs this node accepted in the last two
%%% minutes, so an identical proof is accepted once (mcl_om_ownership_proof).
%%%
%%% Every inbound CALL runs in its own macula_response child, so the table
%%% belongs to this supervised process: a public named ETS table created at
%%% boot. record/2 is one ets:insert_new/2, atomic, so two concurrent copies
%%% of one proof cannot both pass. A sweep every 30 s drops entries older
%%% than twice the 60 s proof skew.
-module(mcl_om_ownership_proof_replay).
-behaviour(gen_server).

-export([start_link/0, record/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, ?MODULE).
-define(KEEP_MS, 120_000).
-define(SWEEP_MS, 30_000).

%% @doc Start the cache, registered under its module name.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc true the first time {Identity, Nonce} is recorded, false on every later attempt.
-spec record(binary(), binary()) -> boolean().
record(Identity, Nonce) ->
    ets:insert_new(?TABLE, {{Identity, Nonce}, erlang:monotonic_time(millisecond)}).

%% @private
init([]) ->
    ?TABLE = ets:new(?TABLE, [set, public, named_table, {write_concurrency, true}]),
    schedule_sweep(),
    {ok, nil}.

%% @private
handle_call(_Request, _From, State) -> {reply, {error, unsupported}, State}.

%% @private
handle_cast(_Msg, State) -> {noreply, State}.

%% @private
handle_info(sweep, State) ->
    Cutoff = erlang:monotonic_time(millisecond) - ?KEEP_MS,
    _ = ets:select_delete(?TABLE, [{{'_', '$1'}, [{'<', '$1', Cutoff}], [true]}]),
    schedule_sweep(),
    {noreply, State};
handle_info(_Other, State) ->
    {noreply, State}.

schedule_sweep() ->
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    ok.
