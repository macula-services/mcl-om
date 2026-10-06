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
%%% the request as a pending row for its operator. An issued claim ends
%%% this worker's retries. A pending one is asked again every RETRY_MS:
%%% the realm answers a repeat with not_admitted while the row is pending
%%% and issues at once after an operator admits the node, so the state
%%% /health shows moves to issued within a minute of the admission
%%% (mcl-om#12). The advertise path
%%% (`mcl_om_capabilities:resolved_authorization/3') resolves the
%%% delegation independently once it exists.
%%%
%%% No credentials travel: there is nothing to configure here beyond
%%% the informational labels the realm's operator sees on the pending
%%% row, `service_name' and `box' (see labels/0).
%%%
%%% THE CLAIM'S STATE IS LOUD. Each change (not delivered, pending,
%%% issued) is one log line naming the realm and the org, and /health
%%% carries it under `claim' (status/0). A pending claim is an operator's
%%% to admit; it must be visible without reading debug logs.
%%%
%%% See PLAN_PROVIDER_AUTHORIZATION_FLOW.md §3.2 (macula-realm).
%%%-------------------------------------------------------------------
-module(mcl_om_claim).
-behaviour(gen_server).

-export([start_link/0, labels/0, status/0]).
%% Exported for mcl_om_claim_tests.erl: pure classification and announcing.
-export([classify/1, announcement/4, asks_again/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RETRY_MS, 60_000).
-define(CALL_TIMEOUT_MS, 15_000).
%% Where the worker publishes its claim state for status/0. Read, never
%% called: the worker spends up to CALL_TIMEOUT_MS inside a claim call, and
%% /health must not wait on it. Written only when the state changes.
-define(STATUS_KEY, {mcl_om_claim, status}).

%% The realm's HOPE name for the request RPC — its configured name is
%% io.macula, the realm every mcl-* service lives in.
-define(CLAIM_PROCEDURE,
        <<"io.macula/_realm/_realm/identity/request_provider_authorization_v1">>).

-type claim() :: unsent | pending | issued | {not_delivered, term()}.

-record(state, {retry_ref :: reference() | undefined,
                claim = unsent :: claim(),
                since = erlang:monotonic_time(millisecond) :: integer()}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    case mcl_om_identity:configured_seeds() of
        [] ->
            %% No seeds configured: the pool never exists, there is
            %% nothing to claim, and the service keeps its no-mesh
            %% degrade contract. `ignore', not `{stop, normal}': a
            %% supervisor treats a stop from init/1 as a failed start and
            %% takes the whole application down with it.
            _ = persistent_term:erase(?STATUS_KEY),
            ignore;
        _ ->
            State = #state{retry_ref = undefined},
            ok = publish(State),
            {ok, claim(State)}
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
    settle(Reply, Org, Realm, State).

%% The realm answered: either it issued the delegation or it recorded
%% the pending request. Both mean the claim is on file: stop retrying.
%% Anything else (mesh not resolved yet, pool still connecting) retries.
%% Each change of state is announced once (announcement/4).
settle(Reply, Org, Realm, #state{claim = Old} = State) ->
    New = classify(Reply),
    announce(announcement(Old, New, Org, Realm)),
    next(New, published(Old, New, (moved(Old, New, State))#state{claim = New})).

%% Written on a change of kind only, as the log line is.
published(Old, New, State) ->
    publish_if(same_kind(Old, New), State).

publish_if(true, State)  -> State;
publish_if(false, State) -> ok = publish(State), State.

publish(#state{claim = Claim, since = Since}) ->
    persistent_term:put(?STATUS_KEY, {Claim, Since}).

next(Claim, State) ->
    next_if(asks_again(Claim), State).

next_if(true, State)  -> retry(State);
next_if(false, State) -> State.

%% @doc Whether a claim in this state is asked again after RETRY_MS: one not
%% delivered, and one pending (an operator may admit the node at any time);
%% never one issued.
-spec asks_again(claim()) -> boolean().
asks_again({not_delivered, _}) -> true;
asks_again(pending)            -> true;
asks_again(_Settled)           -> false.

moved(Old, New, State) ->
    moved_since(same_kind(Old, New), State).

moved_since(true, State)   -> State;
moved_since(false, State)  -> State#state{since = erlang:monotonic_time(millisecond)}.

%% @doc The realm's reply, classified. The refusal of a not yet admitted
%% node is the realm filing the claim as pending. Under macula 13 it
%% arrives as a bare `{error, <<"not_admitted">>}'; before, as a
%% `call_error' carrying the same text under whatever code the responder
%% used (measured live as both handler_error and unknown_error). mcl_om
%% 0.33.1 knew only the second shape, so on macula 13 a pending claim was
%% taken for "not delivered" and re-sent every minute, silently.
-spec classify({ok, term()} | {error, term()}) -> claim().
classify({ok, _Result})                                 -> issued;
classify({error, <<"not_admitted">>})                   -> pending;
classify({error, {call_error, _Code, <<"not_admitted">>}}) -> pending;
classify({error, Reason})                               -> {not_delivered, Reason}.

%% @doc The log line a change of state deserves, or `none' when the state
%% has not changed kind (a claim that cannot be delivered for an hour is one
%% warning, not sixty lines). Names the realm and the org.
-spec announcement(claim(), claim(), binary(), binary()) ->
    none | {logger:level(), string()}.
announcement(Old, New, Org, Realm) ->
    announce_change(same_kind(Old, New), New, Org, Realm).

announce_change(true, _New, _Org, _Realm) ->
    none;
announce_change(false, pending, Org, Realm) ->
    {warning, lists:flatten(io_lib:format(
        "mcl_om_claim: claim for org=~s is pending in realm ~s: an operator must "
        "admit this node before its procedures can be advertised",
        [Org, binary:encode_hex(Realm, lowercase)]))};
announce_change(false, issued, Org, Realm) ->
    {notice, lists:flatten(io_lib:format(
        "mcl_om_claim: realm ~s issued the delegation for org=~s",
        [binary:encode_hex(Realm, lowercase), Org]))};
announce_change(false, {not_delivered, Reason}, Org, Realm) ->
    {warning, lists:flatten(io_lib:format(
        "mcl_om_claim: claim for org=~s not delivered to realm ~s (~0p); retrying every ~b s",
        [Org, binary:encode_hex(Realm, lowercase), Reason, ?RETRY_MS div 1000]))};
announce_change(false, unsent, _Org, _Realm) ->
    none.

same_kind({not_delivered, _}, {not_delivered, _}) -> true;
same_kind(Same, Same)                             -> true;
same_kind(_Old, _New)                             -> false.

announce(none)           -> ok;
announce({Level, Text})  -> logger:log(Level, "~ts", [Text]).

%% @doc The boot claim's state for /health: `unsent' (the pool or realm is
%% not ready), `not_delivered', `pending' (an operator must admit the node)
%% or `issued'; `no_mesh' when the service runs without seeds, so there is
%% no claim to make.
-spec status() -> map().
status() ->
    status_of(persistent_term:get(?STATUS_KEY, undefined)).

status_of(undefined)       -> #{state => <<"no_mesh">>};
status_of({Claim, Since})  -> status_map(Claim, Since).

status_map(Claim, Since) ->
    (claim_fields(Claim))#{org => mcl_om_identity:org(),
                           since_ms => erlang:monotonic_time(millisecond) - Since}.

claim_fields({not_delivered, Reason}) ->
    #{state => <<"not_delivered">>, reason => iolist_to_binary(io_lib:format("~0p", [Reason]))};
claim_fields(Claim) ->
    #{state => atom_to_binary(Claim)}.

claim_target() ->
    case {mcl_om_identity:org(), mcl_om_identity:macula_client(), mcl_om_identity:realm()} of
        {<<"_">>, _, _}                -> none;
        {_, {error, no_client}, _}     -> not_ready;
        {_, _, {error, _}}             -> not_ready;
        {Org, {ok, Pool}, {ok, Realm}} -> {Org, Pool, Realm}
    end.

payload(Org) ->
    (labels())#{<<"org">> => Org}.

%% @doc The labels a claim carries, so the realm's operator can tell what is
%% asking and where it runs. Each is mcl_om's app env if set, else an OS
%% variable the deploy sets (`MCL_SERVICE_NAME', `MCL_BOX'); `service_name'
%% then falls back to the service's own name from info/0, `box' to empty.
%% Only the app env existed before, which two services set and the template
%% did not, so most claims arrived unlabelled.
-spec labels() -> #{binary() => binary()}.
labels() ->
    #{<<"service_name">> => label(service_name, "MCL_SERVICE_NAME", fun service_info_name/0),
      <<"box">> => label(box, "MCL_BOX", fun() -> <<>> end)}.

label(Key, Var, Default) ->
    from_app_env(application:get_env(mcl_om, Key), Var, Default).

%% An empty value is no label: a sys.config line like `{box, <<"${MCL_BOX}">>}'
%% leaves one behind whenever the variable is unset.
from_app_env({ok, Value}, Var, Default) -> non_empty(iolist_to_binary(Value), Var, Default);
from_app_env(undefined, Var, Default) -> from_os_env(os:getenv(Var), Default).

non_empty(<<>>, Var, Default) -> from_os_env(os:getenv(Var), Default);
non_empty(Value, _Var, _Default) -> Value.

from_os_env(Unset, Default) when Unset =:= false; Unset =:= "" -> Default();
from_os_env(Value, _Default) -> unicode:characters_to_binary(Value).

service_info_name() ->
    info_name(mcl_om:service_module()).

info_name(undefined) -> <<>>;
info_name(ServiceMod) -> maps:get(name, ServiceMod:info()).

retry(State) ->
    State#state{retry_ref = erlang:send_after(?RETRY_MS, self(), claim)}.

cancel(undefined) -> undefined;
cancel(Ref) ->
    _ = erlang:cancel_timer(Ref),
    undefined.
