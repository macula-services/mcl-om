%%%-------------------------------------------------------------------
%%% @doc Boot-time provider-authorization claim.
%%%
%%% Once the mesh pool is connected, this worker asks the realm — over
%%% the mesh, by this service's own wire-authenticated identity — for
%%% the D25 delegation its org-namespaced procedures need:
%%% `io.macula/_realm/_realm/identity/request_provider_authorization_v1'.
%%%
%%% The realm verifies the caller (the connection proves it), checks
%%% membership + org binding, and either issues immediately or records
%%% the request as a pending row for its operator. EITHER reply ends
%%% this worker's retries — the realm has the claim on file — and the
%%% advertise path (`mcl_om_capabilities:resolved_authorization/3')
%%% resolves the delegation independently once it exists.
%%%
%%% No credentials travel: there is nothing to configure here beyond
%%% the optional informational labels (`service_name', `box', app env)
%%% the realm's operator sees on the pending row.
%%%
%%% See PLAN_PROVIDER_AUTHORIZATION_FLOW.md §3.2 (macula-realm).
%%%-------------------------------------------------------------------
-module(mcl_om_claim).
-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RETRY_MS, 60_000).
-define(CALL_TIMEOUT_MS, 15_000).

%% The realm's HOPE name for the request RPC — its configured name is
%% io.macula, the realm every mcl-* service lives in.
-define(CLAIM_PROCEDURE,
        <<"io.macula/_realm/_realm/identity/request_provider_authorization_v1">>).

-record(state, {retry_ref :: reference() | undefined}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    case mcl_om_identity:configured_seeds() of
        [] ->
            %% No seeds configured: the pool never exists, there is
            %% nothing to claim, and the service keeps its no-mesh
            %% degrade contract. Stop normally.
            {stop, normal};
        _ ->
            {ok, claim(#state{retry_ref = undefined})}
    end.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(claim, State) ->
    {noreply, claim(State#state{retry_ref = undefined})};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{retry_ref = Ref}) ->
    cancel(Ref),
    ok.

%%%===================================================================
%%% Internal
%%%===================================================================

claim(#state{retry_ref = Ref} = State) ->
    _ = cancel(Ref),
    dispatch_claim(State#state{retry_ref = undefined}, claim_target()).

%% An unconfigured org (`<<"_">>') has no org-namespaced procedures
%% and nothing to request — done, silently.
dispatch_claim(State, none) ->
    State;
%% The pool is not connected yet (or the realm tag is unset): retry on
%% the regular cadence.
dispatch_claim(State, not_ready) ->
    retry(State);
dispatch_claim(State, {Org, Pool, Realm}) ->
    Reply = macula:call(Pool, Realm, ?CLAIM_PROCEDURE,
                        payload(Org), ?CALL_TIMEOUT_MS),
    settle(Reply, Org, State).

%% The realm answered: either it issued the delegation or it recorded
%% the pending request (the refusal text arrives under whatever
%% call_error code the responder used — measured live as both
%% handler_error and unknown_error). Both mean the claim is on file —
%% stop retrying. Anything else (mesh not resolved yet, pool still
%% connecting) retries.
settle({ok, Result}, Org, State) ->
    logger:info("mcl_om_claim: realm answered for org=~s: ~p", [Org, Result]),
    State;
settle({error, {call_error, _Code, <<"not_admitted">>}}, Org, State) ->
    logger:notice("mcl_om_claim: claim recorded as pending for org=~s", [Org]),
    State;
settle({error, Reason}, Org, State) ->
    logger:debug("mcl_om_claim: claim not delivered for org=~s (~p); retrying",
                 [Org, Reason]),
    retry(State).

claim_target() ->
    case {mcl_om_identity:org(), mcl_om_identity:macula_client(), mcl_om_identity:realm()} of
        {<<"_">>, _, _}                -> none;
        {_, {error, no_client}, _}     -> not_ready;
        {_, _, {error, _}}             -> not_ready;
        {Org, {ok, Pool}, {ok, Realm}} -> {Org, Pool, Realm}
    end.

payload(Org) ->
    #{<<"org">> => Org,
      <<"service_name">> => application:get_env(mcl_om, service_name, <<>>),
      <<"box">> => application:get_env(mcl_om, box, <<>>)}.

retry(State) ->
    State#state{retry_ref = erlang:send_after(?RETRY_MS, self(), claim)}.

cancel(undefined) -> undefined;
cancel(Ref) ->
    _ = erlang:cancel_timer(Ref),
    undefined.
