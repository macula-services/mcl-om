%%% @doc Advertises a service's capabilities on the mesh, and resolves
%%% other services' capabilities from the DHT.
%%%
%%% A capability carrying `handler => {HandlerModule, Args}' is advertised
%%% ONCE, by `advertise_one/6', via `advertise_direct/7' on its provider
%%% module (see `provider_module/1') — `macula_response' (request/reply
%%% RPC, the default) or `macula_streamer' (a `kind => streamer'
%%% capability) — the SDK's own supervised wrapper, which registers a
%%% handler with the pool AND publishes the signed
%%% `procedure_advertisement' DHT record naming this pool's connected
%%% station, in one call.
%%%
%%% The one registration is under `org_procedure(Org, Name)'
%%% (`<<Org/binary, "/", Name/binary>>'). THERE IS NO BARE-NAME
%%% REGISTRATION: 11.x refuses a procedure with no org namespace
%%% (`no_org_namespace'), so a caller reaches a capability by its
%%% org-qualified string and by nothing else. A service whose org is
%%% `acme' and whose capability is `echo' is called as `acme/echo'.
%%%
%%% `macula_remote_advertise_registry' (station-side) keys purely on the
%%% opaque procedure string, so two orgs serving the same capability name
%%% from the SAME relay station each hold their own entry. Before the org
%%% namespace was mandatory they shared one bare-name slot and whichever
%%% republish landed last won — the exact bug a live test
%%% (`test_live/mcl_om_capabilities_live_station_tests.erl''s
%%% `org_scoped_call_reaches_only_the_targeted_org_test_') caught: both an
%%% acme- and a contoso-targeted call were answered by whichever org's
%%% registration was most recent.
%%%
%%% ⚠ 10.x ADVERTISED TWICE, under the bare name as well, and callers
%%% written against that era hardcode the bare string. Those calls do not
%%% reach an 11.x service at all. This is not a silent-fallback situation:
%%% there is nothing to fall back to.
%%%
%%% The discovery URI macula_direct_dial builds internally
%%% (`RealmHex/Procedure') and this module's `procedure_uri/3'
%%% (`RealmHex/Org/Name') produce the IDENTICAL string when
%%% `Procedure = org_procedure(Org, Name)' — so
%%% `advertise_direct''s own internal DHT publish already lands the
%%% org-qualified record at exactly the key `discovery_key_org/3' resolves
%%% on read. No separate record-only write is needed for the
%%% handler-bearing case.
%%%
%%% A capability with no `handler' key gets the legacy record-only path
%%% (`build_advertisement/5,6' + `put_record'): discoverable, never
%%% callable via `call_capability', kept for a capability another
%%% mechanism serves.
%%%
%%% A handler-bearing capability may also carry an `auth' policy —
%%% `open' (default, and every existing caller's behavior before this
%%% key existed), `{ucan_required, IssuerPubkey}', or
%%% `{realm_member_required, RealmDid, RequiredCan}' — forwarded via
%%% `auth_opts/1' into BOTH `advertise_direct' calls' `Opts', through to
%%% `macula:advertise/5' and enforced on every inbound call by
%%% `macula_station_link''s `authorize_policy/2'.
%%%
%%% `{ucan_required, IssuerPubkey}' is a direct-signature check against
%%% ONE pre-known issuer, not a delegation-chain walk — it fits "only
%%% this one known identity may call this capability" (an operator-only
%%% capability like a corpus-mutating one).
%%%
%%% `{realm_member_required, RealmDid, RequiredCan}' is the
%%% "anyone whose UCAN traces back to a trusted realm root" case
%%% `ucan_required' does not cover: a valid token signed by the realm's
%%% own DID (RealmDid — an Ed25519 keypair the realm holds, NOT the
%%% 32-byte `RealmId' routing/scoping hash used elsewhere) whose
%%% audience is the wire-authenticated caller itself, at the specific
%%% membership tier `RequiredCan' names (mandatory, no default — a
%%% realm mints membership at more than one tier from the same signing
%%% key, see the comment on the auth_policy() type in macula_client for
%%% why a caller must name the tier it actually needs). See
%%% `macula-mcp/plans/PLAN_AGENT_IDENTITY_UCAN.md' for the caller side
%%% of presenting a token shaped for either policy.
%%%
%%% `call_capability/5,7' resolves `CapName' under `Org' and only under
%%% `Org' (`discovery_key_org/3'). There is no bare-key fallback on the
%%% read side either: `resolve_at/4' looks up exactly one key, and an org
%%% that has published nothing there resolves to nothing rather than to
%%% somebody else's registration. `resolve_full/4' tags each resolved
%%% provider with the wire-level procedure string that matched, and the
%%% CALL uses that string rather than the raw `CapName', so a targeted
%%% call can only ever be answered by that org's own registration, all the
%%% way to the wire.
%%%
%%% `reuse_sup/0''s pid is round-tripped through this worker's state — one
%%% slot per DISTINCT procedure string, which since 11.x means one slot
%%% per org-qualified registration — and passed back in as
%%% `advertise_direct's own `reuse_sup' option on every 30s republish tick
%%% — a station's wire-level registration for a procedure is tied to the
%%% connection that sent it and does not survive that connection being
%%% replaced (see `macula_response:advertise_direct/7' and `hecate-tube''s
%%% `tube_mesh_providers.erl', which hit this bug live before this option
%%% existed); periodic re-advertise without `reuse_sup' would also leak
%%% one factory supervisor per tick.
%%%
%%% Every advertisement carries `ttl_ms => ?ADVERTISEMENT_TTL_MS' (4x the
%%% republish interval, matching the buffer `macula_station_announcer''s
%%% own 75%-of-TTL refresh leaves for stations) instead of the ~48h
%%% envelope default — a dead service's advertisement should age out on
%%% the order of minutes, not days. The handler-bearing path's `ttl_ms'
%%% needs macula 10.11.1 or later: earlier releases dropped `ttl_ms'
%%% while macula_direct_dial forwarded the advertisement options; the
%%% record-only (no-handler) path builds the record directly and is
%%% unaffected by that gap.
%%%
%%% `lookup/1' resolves a capability by name: derive the same procedure
%%% key, read every advertisement stored there, verify each signature,
%%% return the `{advertiser, serving_station}' set.
%%%
%%% `list_org_capabilities/1' browses every capability an org has
%%% advertised — genuinely new, unlike `lookup/1'/`call_capability': the
%%% bare key needs a capability NAME to look anything up, and so does the
%%% org-qualified key (`discovery_key_org/3', `Realm/Org/Name' — Name is
%%% part of the key, not something a lookup can search past). There is no
%%% NAME-less "everything Org has" key to resolve. A DHT-composite-key
%%% design (publish the same record again under an org-prefix-only key) —
%%% the original plan for this — turned out infeasible:
%%% `macula_record:storage_key/1' DERIVES a `procedure_advertisement''s
%%% storage key from its own `procedure_uri' payload, so a record cannot
%%% be stored under an independently-chosen key without its `procedure_uri'
%%% field lying about what it actually is. Building a second, genuinely
%%% separate DHT record type just for this (with its own write-conflict
%%% semantics for multiple advertisers of one org) was judged more than
%%% this needs. Instead: `list_org_capabilities/1' is a CLIENT-SIDE filter
%%% over `macula:find_records_by_type/2' (matched via
%%% `macula_topic_pattern:matches/2') — the exact same local-relay-view,
%%% warm-start-only mechanism `read_model_services.md' already documents
%%% for bulk browsing, honestly inheriting its "one relay's local view,
%%% not authoritative" limitation rather than pretending to a DHT-wide
%%% index this record type cannot support.
%%%
%%% Signing needs the service's stable identity key
%%% (`mcl_om_identity:identity_key/0'); an ephemeral service cannot sign
%%% and is correctly not advertised.
-module(mcl_om_capabilities).
-behaviour(gen_server).

-export([start_link/0, register/1, publish/0, lookup/1, list/0, provider_grants/0,
         advertise_liveness/0,
         list_org_capabilities/1]).
-export([call_capability/5, call_capability/7]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Pure helpers — the record-building, dispatch-decision, and resolution
%% logic, kept side-effect-free so it is unit-testable without a live
%% mesh.
-export([org_procedure/2, build_advertisement/5, decode_resolved/1,
         station_url/2, has_handler/1, auth_opts/1, unguarded_capabilities/1,
         reuse_sup_opts/1, advertise_opts/0,
         provider_module/1, stream_opts/1, handler_timeout_opts/1,
         discovery_key_org/3, org_scoped_full_or_any/5,
         pinned_providers/2,
         choose_serving_station/2,
         org_capability_pattern/1, matches_org_pattern/2,
         resolve_org_capabilities/3, republish_delay_ms/0]).

%% The `publish_advertisement' opt advertise_direct/7 takes (see
%% publish_advertisement/5 below) and the `advertise' opt (see
%% advertise_on_serving_station/6 below): exported so the module fun
%% references the advertise path passes as opts are genuine uses, and
%% so the record-building and single-station registration are
%% testable without a live mesh.
-export([publish_advertisement/5, advertisement_opts/1,
         advertise_on_serving_station/6]).

%% `macula_record.erl''s own `?TYPE_PROCEDURE_ADVERTISEMENT' — not
%% exported there (no shared header defines it either), so mirrored here.
%% MUST match `macula_record.erl''s definition exactly; a mismatch would
%% make `list_org_capabilities/1' silently see nothing.
-define(TYPE_PROCEDURE_ADVERTISEMENT, 6).

%% Process dictionary key for advertise_with/7's log-once throttle. Scoped
%% to this gen_server's own process, not shared/global state.
-define(ADVERTISE_GATE_LOG_KEY, mcl_om_capabilities_advertise_gate_reason).

%% Re-assert advertisements this often. Records outlive one interval;
%% the tick also retries the initial write until the pool + a station
%% link are present.
-define(REPUBLISH_INTERVAL_MS, 30_000).

%% +/- jitter applied to every scheduled republish tick (see arm_timer/1).
%% A station-side cooldown this republish races against -- e.g.
%% macula_remote_advertise_registry's tombstone, deliberately 30s
%% (bumped from 10s in ea95857 for its own gossip-convergence reasons,
%% unrelated to this timer) -- is opaque to this module and can equal
%% or evenly divide ?REPUBLISH_INTERVAL_MS by coincidence. A perfectly
%% fixed-period retry that loses that race once has no drift to ever
%% land outside the cooldown window again: found live 2026-09-01,
%% hecate-rag's `get_document_verbatim` capability stayed
%% `unknown_method' for 45+ minutes across ~90 identically-timed retries
%% while sibling capabilities (registered moments earlier or later in
%% the same advertise batch, landing just outside whatever tombstone
%% they raced) self-healed on their next tick. Jitter costs nothing
%% when there is no race and guarantees one eventually lands clear when
%% there is.
-define(REPUBLISH_JITTER_MS, 6_000).

%% 4x the republish interval — the same margin `macula_station_announcer'
%% leaves by refreshing at 75% of TTL — so one or two missed ticks (a
%% transient mesh gap) don't age the record out, but a genuinely dead
%% service's advertisement is gone in minutes, not the ~48h envelope
%% default.
-define(ADVERTISEMENT_TTL_MS, ?REPUBLISH_INTERVAL_MS * 4).

%% find/2's DHT-propagation-lag retry budget -- same values as
%% macula_direct_dial's own private find_records_retry/3, see find/2.
-define(RESOLVE_BUDGET_MS, 5_000).
%% One row per org procedure: its last provider_authorization answer.
-define(GRANTS, mcl_om_provider_grants).
%% One row per org procedure: its advertise loop's last outcome.
-define(ADVERTISE, mcl_om_advertise_state).
-define(RESOLVE_RETRY_MS, 100).

%% How long a caller of the gen_server's mesh-reading calls (lookup/1,
%% list_org_capabilities/1) waits before giving up. Deliberately longer
%% than the gen_server call default (5s): the resolve inside is bounded
%% at ?RESOLVE_BUDGET_MS (see find/2), and a slow DHT used to wedge the
%% server for up to ~255s while every caller timed out at 5s (issue #5).
%% This timeout is the CALLER's patience, not the server's work budget.
-define(LOOKUP_CALL_TIMEOUT_MS, 15_000).

-record(state, {
    capabilities   = []        :: [mcl_om_service:capability()],
    timer          = undefined :: reference() | undefined,
    %% Capability name -> factory supervisor pid from a prior
    %% advertise_direct/7 call. Passed back in as `reuse_sup' on the
    %% next tick for that capability; see moduledoc.
    advertise_sups = #{}       :: #{binary() => pid()}
}).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Caps) when is_list(Caps) ->
    gen_server:call(?MODULE, {register, Caps}).

%% @doc The last `macula:provider_authorization/3' answer for each
%% org-namespaced procedure this service advertises, as
%% `mcl_om_provider_grant' entries. Read from a table, not by a call, so
%% /health never waits behind a republish tick. `#{}' before anything was
%% advertised.
-spec provider_grants() -> #{binary() => mcl_om_provider_grant:entry()}.
provider_grants() ->
    grants_in(ets:whereis(?GRANTS)).

grants_in(undefined) -> #{};
grants_in(_Tid)      -> maps:from_list(ets:tab2list(?GRANTS)).

%% @doc Whether this service's advertise loop is alive, per
%% org-namespaced procedure, as `mcl_om_advertise_liveness' entries —
%% the last successful advertise and the last failure. Read from a
%% table, not by a call, for the same reason as provider_grants/0.
%% `#{}' before anything was advertised (or attempted).
-spec advertise_liveness() -> #{binary() => mcl_om_advertise_liveness:entry()}.
advertise_liveness() ->
    liveness_in(ets:whereis(?ADVERTISE)).

liveness_in(undefined) -> #{};
liveness_in(_Tid)      -> maps:from_list(ets:tab2list(?ADVERTISE)).

publish() ->
    gen_server:call(?MODULE, publish).

%% @doc Resolve a capability by name to the providers advertising it.
%% `{ok, [#{advertiser := Pubkey, serving_station := Pubkey}]}'. Empty
%% when nothing is advertised or the mesh is unreachable.
%%
%% The resolve runs inside the capabilities gen_server, bounded at
%% `?RESOLVE_BUDGET_MS' wall clock (see find/2); the caller waits at
%% most `?LOOKUP_CALL_TIMEOUT_MS', well past that bound, so a slow DHT
%% degrades this call instead of wedging the server behind it (issue #5).
-spec lookup(binary()) -> {ok, [map()]}.
lookup(CapName) when is_binary(CapName) ->
    gen_server:call(?MODULE, {lookup, CapName}, ?LOOKUP_CALL_TIMEOUT_MS).

%% @doc Every capability `Org' has advertised — `{ok,
%% [#{procedure_uri := binary(), advertiser := Pubkey, serving_station :=
%% Pubkey}]}'. See moduledoc for why this is a client-side filter over
%% `find_records_by_type', not a DHT-indexed query: a WARM-START view of
%% whatever this pool's connected station(s) locally hold, not an
%% authoritative mesh-wide listing. Empty when nothing matches or the
%% mesh is unreachable, same as `lookup/1'.
-spec list_org_capabilities(binary()) -> {ok, [map()]}.
list_org_capabilities(Org) when is_binary(Org) ->
    gen_server:call(?MODULE, {list_org_capabilities, Org},
                    ?LOOKUP_CALL_TIMEOUT_MS).

%% @doc Call a capability by name over the DIRECT-DIAL data path: resolve
%% the providers of `CapName' UNDER `Org' specifically (their
%% `procedure_advertisement' records, keyed `Realm/Org/CapName' —
%% `discovery_key_org/3'), resolve one provider's serving station to a
%% dialable endpoint, dial it directly and issue the CALL there. On
%% failure (unresolvable endpoint, dead station, error reply) fail over
%% to the next provider *of the same org* — this never silently falls
%% over to a different org's own implementation of the same capability
%% name.
%%
%% Falls back to the bare, any-provider key (`discovery_key/2') only when
%% `Org' has published no org-qualified advertisement at all — a fleet
%% mid-migration onto this org-scoping keeps resolving exactly as it did
%% before this existed. Once `Org' is genuinely irrelevant to you (any
%% provider will do, e.g. a realm-wide commodity capability), pass
%% whatever value is convenient; it only narrows the search, it never
%% widens it beyond what an org-blind lookup would already find.
%%
%% The CALL uses whichever wire-level procedure string actually resolved
%% (`resolve_full/4' tags each provider with it) — `org_procedure(Org,
%% CapName)' on an org-scoped hit, the bare `CapName' only on the
%% any-provider fallback — matching whichever registration that specific
%% provider made via `advertise_one/7'. Org-scoping therefore changes both
%% WHICH station gets dialed AND what's sent once dialed; a targeted call
%% can only ever be answered by that org's own registration, never a
%% different org's provider sharing the same station. Runs in the
%% caller's process (not the capabilities gen_server), so a slow mesh
%% never blocks capability registration.
-spec call_capability(binary(), binary(), term(), pos_integer(), map()) ->
    {ok, term()} | {error, term()}.
call_capability(Org, CapName, Payload, TimeoutMs, Opts)
  when is_binary(Org), is_binary(CapName),
       is_integer(TimeoutMs), TimeoutMs > 0, is_map(Opts) ->
    call_capability_via(mcl_om_identity:macula_client(),
                        mcl_om_identity:realm(),
                        Org, CapName, Payload, TimeoutMs, Opts).

list() ->
    gen_server:call(?MODULE, list).

%%% gen_server

init([]) ->
    ?GRANTS = ets:new(?GRANTS, [set, protected, named_table,
                                {read_concurrency, true}]),
    ?ADVERTISE = ets:new(?ADVERTISE, [set, protected, named_table,
                                      {read_concurrency, true}]),
    {ok, arm_timer(#state{})}.

handle_call({register, Caps}, _From, #state{advertise_sups = Sups} = S) ->
    log_unguarded(Caps),
    %% A new capability set: a procedure no longer advertised must not keep
    %% degrading /health -- neither as a stale grant nor as a stale
    %% advertise loop.
    true = ets:delete_all_objects(?GRANTS),
    true = ets:delete_all_objects(?ADVERTISE),
    NewSups = do_advertise(Caps, Sups),
    {reply, ok, S#state{capabilities = Caps, advertise_sups = NewSups}};

handle_call(publish, _From, #state{capabilities = Caps,
                                   advertise_sups = Sups} = S) ->
    NewSups = do_advertise(Caps, Sups),
    {reply, ok, S#state{advertise_sups = NewSups}};

handle_call({lookup, CapName}, _From, S) ->
    {reply, {ok, do_resolve(CapName)}, S};

handle_call({list_org_capabilities, Org}, _From, S) ->
    {reply, {ok, do_list_org_capabilities(Org)}, S};

handle_call(list, _From, #state{capabilities = Caps} = S) ->
    {reply, Caps, S};

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(republish, #state{capabilities = Caps,
                              advertise_sups = Sups} = S) ->
    NewSups = do_advertise(Caps, Sups),
    {noreply, arm_timer(S#state{advertise_sups = NewSups})};
handle_info(_Other, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%% Internals — advertise (write records / register handlers)

%% Logged once per `register/1' call (boot, or an explicit
%% re-registration — never on a republish timer tick, `publish/0'/
%% `handle_info(republish, ...)' both reuse the already-registered
%% `Caps' without calling this again) — see `unguarded_capabilities/1'
%% for exactly what this can and can't see.
log_unguarded(Caps) ->
    case unguarded_capabilities(Caps) of
        []        -> ok;
        Unguarded ->
            logger:warning(
              "mcl_om_capabilities: ~p capabilit~s registered with no "
              "explicit auth policy, defaulting to open: ~p -- set "
              "auth => open to confirm that's intended, auth => "
              "{ucan_required, IssuerPubkey} to gate it to one exact "
              "identity, or auth => {realm_member_required, RealmDid, "
              "RequiredCan} to gate it to a realm membership tier",
              [length(Unguarded), plural_suffix(Unguarded), Unguarded])
    end.

plural_suffix([_]) -> "y was";
plural_suffix(_)   -> "ies were".

do_advertise(Caps, Sups) ->
    advertise_with(mcl_om_identity:macula_client(),
                   mcl_om_identity:identity_key(),
                   mcl_om_identity:realm(),
                   mcl_om_identity:org(),
                   Caps, Sups).

%% Every advertisement carries `ttl_ms' — see moduledoc.
advertise_opts() ->
    #{ttl_ms => ?ADVERTISEMENT_TTL_MS}.

advertise_with({ok, Pool}, {ok, Key}, {ok, Realm}, Org, Caps, Sups) ->
    advertise_in_org(valid_org(Org), Pool, Key, Realm, Org, Caps, Sups);
%% Missing pool / keypair / realm: cannot reach the mesh or sign. No-op;
%% the timer retries once all three are present. Existing sups (if any)
%% are kept as-is — a transient mesh gap does not invalidate them.
%%
%% This clause used to be silent, matching advertised/3's old bug: a
%% genuinely stuck pool/identity (not a transient few-tick gap, the
%% comment's original assumption) meant NO advertise attempt is EVER
%% actually made, forever, with no trace anywhere -- worse than
%% advertised/3's bug, since that one at least implies advertise_direct
%% got called. Logged now, throttled to once per distinct reason
%% (see log_advertise_gate_once/1) so a genuinely stuck boot doesn't
%% spam a warning every 30s republish tick forever.
advertise_with(PoolR, KeyR, RealmR, _Org, _Caps, Sups) ->
    log_advertise_gate_once({error_of(PoolR), error_of(KeyR), error_of(RealmR)}),
    Sups.

error_of({ok, _}) -> ok;
error_of({error, Reason}) -> Reason.

%% NO ORG, NO ADVERTISEMENT. mcl_om_identity:org/0 answers `_' when nothing
%% set it, and that used to go out as `_/Name': a procedure in no org, which
%% no realm grants, from a service that looked healthy. An org must be a wire
%% segment (`^[a-z0-9][a-z0-9._-]*$'), which `_' and an unsubstituted
%% `${MCL_ORG}' are not. Without one, nothing is advertised, and each
%% handler-bearing procedure is recorded as not granted for that reason, which
%% /health reports as degraded at once (mcl_om_provider_grant).
advertise_in_org(true, Pool, Key, Realm, Org, Caps, Sups) ->
    lists:foldl(fun(Cap, Acc) ->
                    advertise_one_safely(Pool, Key, Realm, Org, Cap, Acc)
                end, Sups, Caps);
advertise_in_org(false, _Pool, _Key, _Realm, Org, Caps, Sups) ->
    log_advertise_gate_once({org_unset, Org}),
    Now = erlang:monotonic_time(millisecond),
    [record_org_unset(org_procedure(Org, Name), Org, Now)
     || #{name := Name} = Cap <- Caps, has_handler(Cap)],
    Sups.

record_org_unset(OrgProcedure, Org, Now) ->
    Previous = previous_grant(ets:lookup(?GRANTS, OrgProcedure)),
    Entry = mcl_om_provider_grant:observed({error, {org_unset, Org}}, Now, Previous),
    true = ets:insert(?GRANTS, {OrgProcedure, Entry}).

valid_org(Org) ->
    match =:= re:run(Org, <<"^[a-z0-9][a-z0-9._-]*$">>, [{capture, none}]).

%% Logs at most once per distinct (Pool, KeyPair, Realm) error triple per
%% process lifetime -- a persistent boot problem calls advertise_with/7
%% every 30s forever, and an unthrottled warning there is exactly the
%% kind of self-inflicted log spam that gets a real signal muted. A
%% CHANGED triple (e.g. pool recovers, keypair still missing) logs again,
%% since that's new information.
log_advertise_gate_once(Reasons) ->
    case get(?ADVERTISE_GATE_LOG_KEY) of
        Reasons -> ok;
        _ ->
            put(?ADVERTISE_GATE_LOG_KEY, Reasons),
            log_advertise_gate(Reasons)
    end.

log_advertise_gate({org_unset, Org}) ->
    logger:warning(
      "mcl_om_capabilities: advertise skipped, no org configured (got ~p): "
      "set mcl_om's `org' to this service's org; /health reports it as "
      "operator_must_set_org", [Org]);
log_advertise_gate(Reasons) ->
    logger:warning(
      "mcl_om_capabilities: advertise skipped, not all of "
      "pool/keypair/realm are ready yet: ~p (pool_error, "
      "keypair_error, realm_error -- 'ok' means that one is fine)",
      [Reasons]).

%% @doc Whether `Cap' carries a handler (and so should be advertised via
%% `advertise_direct', not just written to the DHT as a bare discovery
%% record).
-spec has_handler(mcl_om_service:capability()) -> boolean().
has_handler(#{handler := _}) -> true;
has_handler(_) -> false.

%% @doc The `auth' entry to merge into `advertise_direct''s `Opts', from
%% a capability's own optional `auth' key (`open' | `{ucan_required,
%% Issuer}' | `{realm_member_required, RealmDid, RequiredCan}',
%% forwarded all the way to `macula_station_link''s inbound call
%% authorization — see moduledoc). Absent when the capability doesn't
%% set one, matching `macula:advertise/5''s own default: open. A
%% hecate-service opts a specific capability into gating by adding the
%% appropriate `auth' value to that capability's map; every other
%% capability advertised through this module is unaffected. This
%% function is deliberately policy-agnostic — it forwards whatever
%% value `auth' holds without inspecting which variant it is, so a
%% future policy `macula' adds needs no change here, only to the
%% {@link mcl_om_service:capability()} type.
-spec auth_opts(mcl_om_service:capability()) -> map().
auth_opts(#{auth := Policy}) -> #{auth => Policy};
auth_opts(_)                 -> #{}.

%% @doc The names of every capability in `Caps' with no explicit `auth'
%% key -- i.e. every one that will silently advertise `open' via
%% `auth_opts/1''s own default, whether that policy was actually
%% decided or simply never set. Pure and unit-testable without a live
%% mesh, matching this module's other pure helpers.
%%
%% This can only see what a service's own `capabilities/0' reports --
%% `register/1' warns about exactly this list on every registration
%% (see `log_unguarded_once/1'), giving free, per-boot visibility to
%% every service that routes through this module. It cannot see a
%% capability a service advertises out-of-band via its own direct
%% `macula:advertise/5'/`macula_response:advertise_direct/7' call
%% instead of declaring it here -- `capabilities/0' under-reporting is
%% the pre-migration `hecate-rag' pattern this module's own moduledoc
%% already documents fixing for one service, not yet audited fleet-wide.
%% See `scripts/audit-fleet-ucan-adoption.sh' for that separate,
%% source-scan half of the check.
-spec unguarded_capabilities([mcl_om_service:capability()]) -> [binary()].
unguarded_capabilities(Caps) ->
    [Name || #{name := Name} = Cap <- Caps, not has_auth(Cap)].

has_auth(#{auth := _}) -> true;
has_auth(_)            -> false.

%% @doc Which macula provider module advertises `Cap''s handler --
%% `macula_streamer' only when the capability opts in with `kind =>
%% streamer', `macula_response' (request/reply RPC) otherwise. Every
%% capability declared before `kind' existed has no such key and keeps
%% advertising through `macula_response', unchanged.
-spec provider_module(mcl_om_service:capability()) -> module().
provider_module(#{kind := streamer}) -> macula_streamer;
provider_module(_)                  -> macula_response.

%% @doc `Cap''s `stream_opts' (e.g. `#{mode => client_stream}'), merged
%% into `advertise_direct''s `Opts' only for a `kind => streamer'
%% capability -- `macula_response:advertise_direct' has no `mode' concept
%% and a `response'-kind capability has no `stream_opts' to begin with,
%% so this is `#{}' for every non-streamer capability.
-spec stream_opts(mcl_om_service:capability()) -> map().
stream_opts(#{kind := streamer, stream_opts := Opts}) -> Opts;
stream_opts(_)                                        -> #{}.

%% @doc `Cap''s `handler_timeout_ms', merged into `advertise_direct''s `Opts':
%% how long macula_response waits for the handler before answering the caller
%% `temporary_relay_failure' (1 to 600000 ms, macula's default 30000; macula
%% refuses anything else). Only a response capability has one: macula_streamer
%% takes no such option, so a streamer that sets it is refused by name rather
%% than advertised as if it had taken effect.
-spec handler_timeout_opts(mcl_om_service:capability()) -> map().
handler_timeout_opts(#{kind := streamer, handler_timeout_ms := _, name := Name}) ->
    error({handler_timeout_ms_is_for_responses, Name});
handler_timeout_opts(#{handler_timeout_ms := Ms}) ->
    #{handler_timeout_ms => Ms};
handler_timeout_opts(_) ->
    #{}.

%% `advertise_one/7' does real network I/O -- a synchronous call into
%% the station-link connection process -- for every capability on every
%% republish tick. A single slow or timed-out call must not crash this
%% whole gen_server: `macula_response:advertise/6' (and
%% `macula_streamer:advertise/6') LINKS each factory supervisor it
%% creates to whoever calls it, i.e. this process, so a crash here kills
%% every OTHER capability's already-healthy supervisor too, turning one
%% transient timeout into an outage for every capability this node
%% serves. Found live 2026-09-01: hecate-rag generated `noproc' on
%% `search_chunks_semantic'/`answer_query'/`add_knowledge' minutes after
%% a clean boot, none of which had anything to do with the capability
%% that actually timed out (`ingest_document') -- the crash cascaded
%% through the link, not through any fault of theirs.
%%
%% Catching per-capability here is the documented exception to
%% let-it-crash (see this org's CLAUDE.md): it distinguishes which
%% capability failed and why, a signal a single opaque
%% `mcl_om_capabilities' supervisor-exit report would otherwise erase
%% along with every other capability's live registration. `Acc' returned
%% unchanged means the failed capability's PREVIOUS (still live)
%% registration is left in place; the next republish tick (~30s) retries
%% it. `macula_response'/`macula_streamer''s own `existing_or_new_sup/1'
%% additionally verifies a reused sup is still alive before trusting it,
%% so a sup that DOES die between ticks (this path or any other) self-
%% heals on the next successful call rather than handing `dispatch' a
%% dead pid.
advertise_one_safely(Pool, Key, Realm, Org, Cap, Acc) ->
    try
        advertise_one(Pool, Key, Realm, Org, Cap, Acc)
    catch
        Class:Reason ->
            logger:warning(
              "mcl_om_capabilities: advertise failed for ~s (~p:~p) "
              "-- keeping the prior registration, retried on the next "
              "republish tick",
              [maps:get(name, Cap, unknown), Class, Reason]),
            Acc
    end.

advertise_one(Pool, Key, Realm, Org,
             #{name := Name, handler := {Mod, Args}} = Cap, Sups) ->
    Provider = provider_module(Cap),
    %% 11.x refuses a procedure without an org namespace
    %% (no_org_namespace), so the one registration is the org-qualified
    %% procedure. The SDK's advertise path resolves this pool's own D25
    %% authorization from the DHT (org_directory + procedure_delegation
    %% naming the pool's node id) for the WIRE frame -- but the
    %% direct-dial DHT record advertise_direct publishes carries only
    %% what its Opts say, and the station refuses an org-namespaced
    %% record without one ({call_error, <<"no_authorization">>}). So
    %% this module resolves the chain itself -- via the SDK's own
    %% `macula:provider_authorization/3' (11.4.0) -- and embeds it, or
    %% the record never lands and every mcl_om caller resolves
    %% no_provider.
    OrgProcedure = org_procedure(Org, Name),
    Authorization = recorded_authorization(
                      OrgProcedure,
                      macula:provider_authorization(Pool, Realm, OrgProcedure)),
    %% The DHT record's serving station is mcl_om's choice (see
    %% publish_advertisement/5), and the wire registration goes ONLY
    %% to that station (see advertise_on_serving_station/6): a station's
    %% registry holds ONE advertiser per (realm, procedure), so two
    %% providers of one procedure must not share a serving station --
    %% and the SDK's default advertise fans the ADVERTISE frame out to
    %% EVERY connected link, which would register this provider at all
    %% four stations and keep the last-write-wins fight alive at each
    %% of them (issue #5).
    Opts = maps:merge(maps:merge(maps:merge(auth_opts(Cap), stream_opts(Cap)),
                                 handler_timeout_opts(Cap)),
                      maps:merge(Authorization,
                                 maps:merge(
                                   reuse_sup_opts(
                                     maps:get(OrgProcedure, Sups, undefined)),
                                   serving_station_opts(Provider, Key)))),
    Result = Provider:advertise_direct(Pool, Realm, OrgProcedure, Mod,
                                       Args, Key, Opts),
    advertised(Result, OrgProcedure, Sups);
advertise_one(Pool, Key, Realm, Org, Cap, Sups) ->
    %% No handler declared — discoverable-but-not-callable path,
    %% kept for a capability another mechanism serves.
    advertise_record_only(serving_station(Pool, Key), Pool, Key, Realm, Org, Cap),
    Sups.

%% @doc The `publish_advertisement' function advertise_direct/7
%% publishes its DHT record with (the SDK's opt of that name; its
%% default is macula_direct_dial:publish_advertisement/5). Same record
%% shape and options, ONE difference: the serving station is THIS
%% node's own pick (choose_serving_station/2) instead of the pool's
%% first-connected link (map-term order over the seed set — alphabetical
%% host name, nothing a deploy can steer), which is what put both
%% bookclubs' records on one station and left only one dialable
%% (issue #5). The wire-level ADVERTISE frame still fans out to every
%% connected station (macula:advertise/6 registers the handler on all
%% of them), so the station named here has the registry entry to route
%% the call.
publish_advertisement(Pool, Realm, Procedure, NodeIdentity, Opts) ->
    case serving_station(Pool, NodeIdentity) of
        {ok, Station} ->
            Advertiser = macula_node_keys:key_id(NodeIdentity),
            Record = macula_record:sign(
                       macula_record:procedure_advertisement(
                         Advertiser, Realm, Procedure, Station,
                         advertisement_opts(Opts)),
                       NodeIdentity),
            macula:put_record(Pool, Record);
        {error, _} = Error ->
            Error
    end.

%% Forwards each opt macula_record:procedure_advertisement/5 actually
%% recognizes, from the opts advertise_direct handed through
%% (authorization, ttl_ms) — the same set
%% macula_direct_dial:publish_advertisement/5 forwards.
advertisement_opts(Opts) ->
    maps:with([authorization, ttl_ms], Opts).


%% @doc The custom advertise/publish pair that makes the many-club
%% spread real. For a RESPONSE capability:
%% - `advertise' is advertise_on_serving_station/6 -- the wire
%%   registration goes ONLY to this node's serving station, instead of
%%   the SDK default (macula:advertise/5) which fans the ADVERTISE
%%   frame out to EVERY connected link. The fanout is what kept the
%%   last-write-wins fight alive on every shared station even after
%%   the records named distinct stations: each provider registered at
%%   all four stations, so each station's registry still flipped
%%   between them (issue #5, live on beam03). Registering only at the
%%   station the record names gives each station's registry exactly
%%   its own providers.
%% - `publish_advertisement' is publish_advertisement/5 -- the record
%%   names the same serving station, so callers dial where the handler
%%   is registered.
%% A streamer capability keeps the SDK's default advertise (its
%% registration carries mode/session semantics this module does not
%% replicate) and overrides only the record publish.
serving_station_opts(macula_response, Key) ->
    #{advertise => fun(P, R, Pr, H, O) ->
                       advertise_on_serving_station(Key, P, R, Pr, H, O)
                   end,
      publish_advertisement => fun mcl_om_capabilities:publish_advertisement/5};
serving_station_opts(macula_streamer, _Key) ->
    #{publish_advertisement => fun mcl_om_capabilities:publish_advertisement/5}.

%% @doc The `advertise' function advertise_direct/7 registers the
%% handler with (the SDK's opt of that name). `Key' is closed over by
%% the caller (the service's identity key) so the serving station is
%% chosen per node, see choose_serving_station/2.
advertise_on_serving_station(Key, Pool, Realm, Procedure, Handler, Opts) ->
    case serving_station_link(Pool, Key) of
        {ok, LinkPid} ->
            register_on_link(Key, LinkPid, Pool, Realm, Procedure, Handler,
                             Opts);
        {error, _} = Error ->
            Error
    end.

%% The link-level registration the SDK's own fanout performs per link
%% (macula_client's safe_link_advertise), applied to the ONE chosen
%% link: send the pool-signed provider advertisement as an ADVERTISE
%% frame on that link. `ok' only means the frame went out on this
%% link; the station's acceptance is its own business (the same is
%% true of the SDK's fanout).
register_on_link(Key, LinkPid, Pool, Realm, Procedure, Handler, Opts) ->
    case wire_advertisement(Key, Realm, Procedure, Opts, Pool) of
        {ok, EncodedAd} ->
            Policy = maps:get(auth, Opts, open),
            macula_station_link:advertise(LinkPid, Realm, Procedure, Handler,
                                          Policy, EncodedAd);
        {error, Reason} ->
            {error, {provider_authorization, Reason}}
    end.

%% The pool-signed provider advertisement the ADVERTISE frame carries.
%% The SDK's advertise path builds the same record -- advertiser and
%% serving station both the provider's own node id, the D25
%% authorization embedded -- and verifies it against the pool's pinned
%% realm key before sending (macula:advertise/5's
%% trusted_provider_advertisement); both are replicated here so the
%% single-station registration drops none of the SDK's safety checks.
%% The authorization comes from Opts, resolved and recorded by
%% recorded_authorization/2 from the same chain the SDK would read.
wire_advertisement(Key, Realm, Procedure, Opts, Pool) ->
    case maps:get(authorization, Opts, undefined) of
        #{org_directory := Dir, procedure_delegation := Deleg}
          when is_binary(Dir), is_binary(Deleg) ->
            {ok, NodeId} = macula_node_keys:node_id(Key),
            Record = macula_record:sign(
                       macula_record:procedure_advertisement(
                         NodeId, Realm, Procedure, NodeId,
                         #{authorization => #{org_directory => Dir,
                                              procedure_delegation => Deleg}}),
                       Key),
            verified_advertisement(Record, Pool, Realm);
        _NoAuthorization ->
            {error, no_authorization}
    end.

verified_advertisement(Record, Pool, Realm) ->
    case macula_client:realm_key(Pool, Realm) of
        {ok, RealmKey} ->
            {ok, Profile} = macula_crypto_profile:configured(),
            Trust = #{profile => Profile, realm_key => RealmKey},
            case macula_record:verify_authorization(
                   Record, Trust, erlang:system_time(millisecond)) of
                ok -> {ok, macula_record:encode(Record)};
                {error, _} = E -> {error, E}
            end;
        none ->
            {error, no_realm_key}
    end.

%% The link to this node's serving station, from the pool's connected
%% links: the one link the ADVERTISE frame goes out on.
serving_station_link(Pool, Key) ->
    case serving_station(Pool, Key) of
        {ok, Station} ->
            link_for_station(Pool, Station);
        {error, _} = Error ->
            Error
    end.

link_for_station(Pool, Station) ->
    try macula:links(Pool) of
        {ok, Links} ->
            case [Pid || #{node_id := S, pid := Pid, connected := true} <- Links,
                         S =:= Station, is_pid(Pid)] of
                [Pid | _] -> {ok, Pid};
                []        -> {error, no_station}
            end;
        _ ->
            {error, no_station}
    catch _:_ ->
        {error, no_station}
    end.

%% The D25 authorization this provider's org-namespaced procedure
%% needs, as the `authorization' opt to embed in the record the SDK
%% publishes. `#{}' when the chain is not published yet: the wire
%% advertise then fails fast with its own `{provider_authorization,
%% _}' error, and the next republish tick retries the whole thing.
%%
%% The answer is recorded either way, for /health: a provider with no
%% grant must not look healthy while serving nothing (see
%% `mcl_om_provider_grant').
recorded_authorization(OrgProcedure, Answer) ->
    Previous = previous_grant(ets:lookup(?GRANTS, OrgProcedure)),
    Entry = mcl_om_provider_grant:observed(Answer,
                                           erlang:monotonic_time(millisecond),
                                           Previous),
    true = ets:insert(?GRANTS, {OrgProcedure, Entry}),
    authorization_opts(Answer).

previous_grant([{_Proc, Entry}]) -> Entry;
previous_grant([])               -> undefined.

authorization_opts({ok, Authorization}) -> #{authorization => Authorization};
authorization_opts({error, _Reason})    -> #{}.

%% @doc The org-qualified wire-level procedure string a handler-bearing
%% capability's SECOND `advertise_direct' registration uses. Deliberately
%% NOT `procedure_uri/3''s realm-hex-prefixed form: the ADVERTISE/CALL
%% wire frames already carry `realm' as a separate field
%% (`macula_frame:advertise/1'), so re-embedding it here would be
%% redundant on every wire message. The DHT KEY still ends up
%% realm-prefixed regardless — see moduledoc, `discovery_uri/2' does that
%% wrapping on the publish side, matching `discovery_key_org/3' on the
%% read side.
-spec org_procedure(binary(), binary()) -> binary().
org_procedure(Org, Name) when is_binary(Org), is_binary(Name) ->
    <<Org/binary, "/", Name/binary>>.

%% @doc The extra `Opts' entry an `advertise_direct' retry needs to reuse
%% a prior call's factory supervisor instead of leaking a new one every
%% republish tick. `#{}' on a capability's first-ever advertise.
-spec reuse_sup_opts(pid() | undefined) -> map().
reuse_sup_opts(undefined)            -> #{};
reuse_sup_opts(Sup) when is_pid(Sup) -> #{reuse_sup => Sup}.

advertised({ok, Sup}, Name, Sups) ->
    record_advertise_ok(Name),
    Sups#{Name => Sup};
advertised({error, Reason}, Name, Sups) ->
    logger:warning("mcl_om_capabilities: advertise_direct for ~s failed: ~p",
                   [Name, Reason]),
    record_advertise_failed(Name, Reason),
    Sups.

%% The advertise loop's last outcome, per procedure — /health's
%% advertise-liveness signal (see mcl_om_advertise_liveness). The
%% grants table records what the realm thinks of this provider; this
%% records what the provider's own loop actually did. A dead loop
%% (silent, no attempt at all) is seen by neither, which is exactly
%% the point: /health judges a procedure stale when its last success
%% outlives the advertisement's own TTL.
record_advertise_ok(Proc) ->
    record_advertise(Proc, ok).

record_advertise_failed(Proc, Reason) ->
    record_advertise(Proc, {error, Reason}).

record_advertise(Proc, Outcome) ->
    Now = erlang:monotonic_time(millisecond),
    Previous = previous_liveness(ets:lookup(?ADVERTISE, Proc)),
    Entry = mcl_om_advertise_liveness:observed(Outcome, Proc, Now, Previous),
    true = ets:insert(?ADVERTISE, {Proc, Entry}).

previous_liveness([{_Proc, Entry}]) -> Entry;
previous_liveness([])               -> undefined.

advertise_record_only({ok, Station}, Pool, Key, Realm, Org, Cap) ->
    put_advertisement(Pool, build_advertisement(Key, Realm, Org, Cap, Station),
                      org_procedure(Org, maps:get(name, Cap)));
advertise_record_only({error, no_station}, _Pool, _Key, _Realm, _Org, _Cap) ->
    ok.

%% `macula:put_record/2' returns `ok | {error, term()}' -- both branches
%% were previously discarded outright (the old `try ... catch _:_ -> ok
%% end' only guarded against an exception, never inspected a plain
%% `{error, _}' return at all), so a rejected or failed record-only
%% advertisement had no trace anywhere. Logged now, matching
%% `advertised/3''s own fix -- this is the legacy no-handler path
%% (`advertise_one/7''s second clause), the handler-bearing path's own
%% failures are `advertised/3''s concern above.
put_advertisement(Pool, Record, Proc) ->
    log_put_result(Proc, try macula:put_record(Pool, Record)
                          catch Class:Reason -> {error, {Class, Reason}}
                          end).

log_put_result(Proc, ok) ->
    record_advertise_ok(Proc),
    ok;
log_put_result(Proc, {error, Reason}) ->
    logger:warning("mcl_om_capabilities: put_record (record-only advertisement) failed: ~p",
                   [Reason]),
    record_advertise_failed(Proc, Reason),
    ok.

%% One station this service is reachable through, from the pool's
%% connected links -- chosen deterministically per node (see
%% choose_serving_station/2), NOT "the first connected link": the
%% station a provider names is the one callers dial, and a station's
%% remote_advertise_registry holds ONE advertiser per (realm,
%% procedure) -- last direct ADVERTISE wins (macula-station's
%% single-provider invariant). Two providers of one procedure that
%% both name the same station are therefore not both dialable; the
%% per-node spread keeps co-org providers on different stations
%% whenever there are stations to spare (issue #5). Slice 2 advertises
%% ONE serving station per provider (the store dedups records by
%% signer); multi-station is Q10 / Slice 5.
serving_station(Pool, Key) ->
    case connected_node_ids(Pool) of
        []          -> {error, no_station};
        Connected   ->
            {ok, NodeId} = macula_node_keys:node_id(Key),
            {ok, choose_serving_station(NodeId, Connected)}
    end.

%% @doc The serving station one node names among the connected
%% stations: `phash2(NodeId)' over the SORTED set, so the pick is
%% stable across republish ticks (links arrive and depart in arbitrary
%% order; the sort removes that noise) and spreads distinct nodes
%% across the stations. Two providers of one procedure with different
%% node ids land on different stations whenever the station set has
%% room -- the deployment half of the many-club contract. Pure.
-spec choose_serving_station(<<_:256>>, [<<_:256>>]) -> <<_:256>>.
choose_serving_station(_NodeId, [Station]) ->
    %% One station: the choice is that station, whatever the hash.
    Station;
choose_serving_station(NodeId, Stations) ->
    Sorted = lists:sort(Stations),
    lists:nth(erlang:phash2(NodeId, length(Sorted)) + 1, Sorted).

connected_node_ids(Pool) ->
    try macula:links(Pool) of
        {ok, Links} ->
            [NodeId || #{connected := true, node_id := NodeId} <- Links,
                       is_binary(NodeId)];
        _ ->
            []
    catch _:_ ->
        []
    end.

%%% Internals — resolve (read records)

do_resolve(CapName) ->
    resolve_with(mcl_om_identity:macula_client(),
                 mcl_om_identity:realm(),
                 mcl_om_identity:org(), CapName).

resolve_with({ok, Pool}, {ok, Realm}, Org, CapName) ->
    resolve_at(Pool, Realm, Org, CapName);
resolve_with(_Pool, _Realm, _Org, _CapName) ->
    [].

do_list_org_capabilities(Org) ->
    list_org_with(mcl_om_identity:macula_client(),
                 mcl_om_identity:realm(), Org).

list_org_with({ok, Pool}, {ok, Realm}, Org) ->
    resolve_org_capabilities(Pool, Realm, Org);
list_org_with(_Pool, _Realm, _Org) ->
    [].

%% @doc Every capability `Org' has advertised, under `Realm' — see
%% moduledoc for why this is a client-side filter over
%% `find_records_by_type', not a DHT-indexed query.
-spec resolve_org_capabilities(pid(), binary(), binary()) -> [map()].
resolve_org_capabilities(Pool, Realm, Org) ->
    Pattern = org_capability_pattern(Org),
    lists:filtermap(fun(R) -> decode_if_org_matches(R, Realm, Pattern) end,
                    find_by_type(Pool)).

%% `Org/*' -- the pattern every one of Org's advertisements' procedure
%% string must match (a wildcard trailing segment, matched via
%% `macula_topic_pattern:matches/2'). The realm is checked as the
%% record's own realm_id field, not as part of the pattern.
org_capability_pattern(Org) ->
    [Org, <<"*">>].

find_by_type(Pool) ->
    on_find_by_type(find_records_by_type(Pool)).

find_records_by_type(Pool) ->
    try macula:find_records_by_type(Pool, ?TYPE_PROCEDURE_ADVERTISEMENT)
    catch _:_ -> {error, unreachable}
    end.

on_find_by_type({ok, Records}) -> Records;
on_find_by_type(_Other)        -> [].

decode_if_org_matches(Record, Realm, Pattern) ->
    decode_verified_if_org_matches(reverify(Record), Record, Realm, Pattern).

%% find_records/2 and find_records_by_type/2 already return records
%% verified under the node's profile; re-verify the {key, tbs,
%% signature} projection -- the map form macula_record:verify/2 takes.
%% Passing the full decoded record would trip verify/2's map_size =:= 3
%% guard and drop every record as malformed.
reverify(Record) ->
    macula_record:verify(maps:with([key, tbs, signature], Record), profile()).

decode_verified_if_org_matches({ok, _Payload}, Record, Realm, Pattern) ->
    try macula_record:read_procedure_advertisement(Record) of
        #{realm_id := RecordRealm, procedure := Procedure} = Decoded ->
            keep_if_matches(RecordRealm =:= Realm
                            andalso matches_org_pattern(Pattern, Procedure),
                            Decoded, Record)
    catch _:_ ->
        false
    end;
decode_verified_if_org_matches({error, _}, _Record, _Realm, _Pattern) ->
    false.

%% @doc Whether `Procedure' (a procedure_advertisement's own procedure
%% string, `Org/Name') matches the `Org/*' `Pattern'. Split purely on
%% `/'. The realm is the record's own realm_id, checked by the caller.
-spec matches_org_pattern([binary()], binary()) -> boolean().
matches_org_pattern(Pattern, Procedure) ->
    macula_topic_pattern:matches(Pattern, binary:split(Procedure, <<"/">>, [global])).

keep_if_matches(true, Decoded, Record) ->
    {true, Decoded#{record => Record}};
keep_if_matches(false, _Decoded, _Record) ->
    false.

%% Org-scoped, the only form 11.x accepts: a procedure without an org
%% namespace is refused at the station (no_org_namespace), so every
%% registration and therefore every resolution is under
%% `Realm/Org/CapName'.
resolve_at(Pool, Realm, Org, CapName) ->
    resolve_records(find(Pool, discovery_key_org(Realm, Org, CapName))).

%% Org-qualified discovery key. The 11.x procedure_key takes the realm
%% as its own argument; the procedure is the org-qualified string.
discovery_key_org(Realm, Org, Name) ->
    macula_record:procedure_key(Realm, org_procedure(Org, Name)).

%% find/2 always returns `{ok, List}' (its retry loop converts an
%% exhausted/persistent error into `{ok, []}' rather than passing
%% `{error, _}' through) -- no `_Other' clause needed here any more.
resolve_records({ok, Records}) -> decode_resolved(Records).

%% Like resolve_at/4 but keeps each raw record so the verifying-consumer
%% path (7c Direction B) can chain-check the embedded service cert. Same
%% org-scoped resolution as resolve_at/4, PLUS: tags every returned
%% provider with `procedure' -- the actual wire-level string the CALL must
%% use. This is what makes the org-scoping real all the way to the wire:
%% every hit is tagged `org_procedure(Org, CapName)', which in 11.x is the
%% only string anything was registered under.
%%
%% NOTE THE NAME `org_scoped_full_or_any/5' IS A LEFTOVER. It dates from
%% the 10.x bare-name fallback and takes no `any' branch any more; it
%% tags and returns. Renaming it is an API change (it is exported) and is
%% deliberately not folded into a documentation fix.
resolve_full(Pool, Realm, Org, CapName) ->
    org_scoped_full_or_any(
      resolve_full_records(find(Pool, discovery_key_org(Realm, Org, CapName))),
      Pool, Realm, Org, CapName).

org_scoped_full_or_any(OrgScoped, _Pool, _Realm, Org, CapName) ->
    tag_procedure(OrgScoped, org_procedure(Org, CapName)).

tag_procedure(Providers, Procedure) ->
    [P#{procedure => Procedure} || P <- Providers].

%% Same reasoning as resolve_records/1 -- find/2 always returns
%% `{ok, List}' now.
resolve_full_records({ok, Records}) -> decode_resolved_full(Records).

decode_resolved_full(Records) ->
    lists:filtermap(fun decode_one_full/1, Records).

decode_one_full(Record) ->
    decode_verified_full(reverify(Record), Record).

decode_verified_full({ok, _Payload}, Record) ->
    try macula_record:read_procedure_advertisement(Record) of
        #{advertiser_node := Adv, serving_station := Sta} ->
            {true, #{advertiser => Adv, serving_station => Sta, record => Record}}
    catch _:_ ->
        false
    end;
decode_verified_full({error, _}, _Record) ->
    false.

%% Retries a fresh publish out of DHT-propagation lag. Matches
%% macula_direct_dial's own internal find_records_retry/3 budget (50 x
%% 100ms = up to 5s) — a budget this module does NOT get for free by
%% calling `macula:find_records/2' directly (the bare, single-shot SDK
%% RPC; the retrying version is private to macula_direct_dial). Found
%% live 2026-08-29: two providers advertising back-to-back, the second
%% one's own resolve raced its own just-written record with zero retry
%% margin, `{error, no_provider}' even though the record existed --
%% `run_org_scoped/0' only sleeps a fixed 2s between the last advertise
%% and the first call, not long enough for eager replication AND both
%% providers' writes to settle every time.
%%
%% THE BUDGET IS WALL CLOCK, NOT A RETRY COUNTER. The first version
%% counted 50 retries x the 100ms sleep and ignored how long each
%% `find_records' RPC itself took: a slow DHT (every attempt eating its
%% full ?DHT_RECORD_TIMEOUT_MS = 5s internal timeout) stretched one
%% resolve to ~255s, and `lookup/1' runs that resolve synchronously in
%% the capabilities gen_server -- a single slow resolve wedged every
%% other capability call behind it while every caller timed out at the
%% 5s gen_server default (issue #5, live on beam03 2026-09-25). Now:
%% each attempt asks for only the time left of the budget, the loop
%% stops when the budget is spent, and the whole resolve is done in at
%% most ?RESOLVE_BUDGET_MS regardless of DHT slowness.
find(Pool, Key) ->
    find_until(Pool, Key, deadline(?RESOLVE_BUDGET_MS)).

deadline(BudgetMs) ->
    erlang:monotonic_time(millisecond) + BudgetMs.

find_until(Pool, Key, Deadline) ->
    case deadline_left_ms(Deadline) of
        Left when Left > 0 ->
            on_find(try_find(Pool, Key, Left), Pool, Key, Deadline);
        _Expired ->
            {ok, []}
    end.

try_find(Pool, Key, TimeoutMs) ->
    try macula:find_records(Pool, Key, TimeoutMs)
    catch _:_ -> {error, unreachable}
    end.

on_find({ok, [_ | _]} = Result, _Pool, _Key, _Deadline) ->
    Result;
on_find(_Other, Pool, Key, Deadline) ->
    case deadline_left_ms(Deadline) of
        Left when Left > 0 ->
            timer:sleep(min(?RESOLVE_RETRY_MS, Left)),
            find_until(Pool, Key, Deadline);
        _Expired ->
            {ok, []}
    end.

deadline_left_ms(Deadline) ->
    Deadline - erlang:monotonic_time(millisecond).

%%% Internals — call a capability (resolve -> verify -> dial -> call)

call_capability_via({ok, Pool}, {ok, Realm}, Org, CapName, Payload,
                    TimeoutMs, Opts) ->
    call_capability(Pool, Realm, Org, CapName, Payload, TimeoutMs, Opts);
call_capability_via(_Pool, _Realm, _Org, _CapName, _Payload, _TimeoutMs, _Opts) ->
    {error, not_configured}.

%% @doc Explicit-pool form (testable without mcl_om_identity).
%% `Opts':
%% - `ucan_token => binary()' (presented to a gated provider).
%% - `advertiser => <<_:256>>' (dial ONLY the provider whose advertisement
%%   was published by this node id -- the pin that makes one procedure with
%%   many providers addressable, see mcl_om:call_capability/5. A pin that
%%   matches no resolved provider fails closed with `{error, no_provider}'.)
%%
%% `{error, no_provider}' is reserved for "nothing to dial": no provider
%% resolved, or the pin matched none. A provider that WAS dialed reports
%% its own failure (`{error, timeout}', `{error, {station_endpoint,
%% Reason}}', a call error...) -- see call_providers/7 for why the two
%% must never collapse into one.
%%
%% There is no TLS mode to choose. The 10.x `verify => true' cert-chain
%% form went with the cert authorization form, and macula 12 refuses
%% `verify' in any value: the trust check is the D25 authorization the
%% pool verifies against its realm_trust keys, plus the pinned
%% expected_node_id below.
-spec call_capability(pid(), binary(), binary(), binary(), term(),
                      pos_integer(), map()) -> {ok, term()} | {error, term()}.
call_capability(Pool, Realm, Org, CapName, Payload, TimeoutMs, Opts) ->
    call_providers(pinned_providers(maps:get(advertiser, Opts, undefined),
                                    resolve_full(Pool, Realm, Org, CapName)),
                   Pool, Realm, CapName, Payload, TimeoutMs,
                   maps:get(ucan_token, Opts, <<>>)).

%% @doc The pin: keep only the provider whose advertisement was published
%% by `NodeId'. No pin, no filter.
pinned_providers(undefined, Providers) ->
    Providers;
pinned_providers(NodeId, Providers) ->
    [Provider || #{advertiser := Adv} = Provider <- Providers, Adv =:= NodeId].

%% `{error, no_provider}' means exactly one thing: nothing to dial --
%% the resolve returned no provider at all, or the `advertiser' pin
%% matched none of the providers the resolve DID return (a stale pin,
%% which fails closed by contract). A provider that WAS dialed and
%% failed reports ITS failure (e.g. `{error, timeout}') instead of
%% masquerading as a resolve miss: before this split, every dial
%% failure on the LAST candidate fell through the failover tail into
%% `{error, no_provider}', so a dead provider was indistinguishable
%% from a stale pin -- the misdirection that sent issue #5's diagnosis
%% into the resolve path while the real failure was the dial timing
%% out. The station-endpoint lookup is the same: an unresolvable
%% station reports `{error, {station_endpoint, Reason}}'.
call_providers([], _Pool, _Realm, _CapName, _Payload, _TimeoutMs, _Ucan) ->
    {error, no_provider};
call_providers([#{serving_station := Station, advertiser := Advertiser,
                  procedure := Procedure} | Rest],
               Pool, Realm, CapName, Payload, TimeoutMs, Ucan) ->
    dial_provider(resolve_endpoint(Pool, Station), Station, Advertiser,
                  Procedure, Rest, Pool, Realm, CapName, Payload, TimeoutMs,
                  Ucan).

%% Endpoint resolved: dial + call; on error, fail over to the next.
%%
%% Trust: a resolved provider is trusted because the signed DHT
%% `procedure_advertisement' named exactly this `Station' node id — the
%% 11.x call_station pins the dial on it as the Target (D5): the
%% CONNECT/HELLO handshake refuses any other identity, and a station's
%% TLS cert has no relationship to its macula identity. The CALL's
%% target is the PROVIDER's node id (the station routes by it, and the
%% reply verifies as answered by that exact target); the station proves
%% only that it holds the key of the self-signed ML-DSA-87 certificate
%% it presents, so the pinned handshake is the whole transport trust,
%% exactly macula's own direct-dial caller
%% (macula_station_gated_call_SUITE's call/6).
dial_provider({ok, Url}, Station, Advertiser, Procedure, Rest, Pool, Realm,
              CapName, Payload, TimeoutMs, Ucan) ->
    CallResult = macula:call_station(Pool, Url, Advertiser, Realm, Procedure,
                                     Payload, TimeoutMs,
                                     #{ucan_token => Ucan,
                                       expected_node_id => Station}),
    failover(CallResult, Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan);
dial_provider({error, Reason}, _Station, _Advertiser, _Procedure, Rest, Pool,
              Realm, CapName, Payload, TimeoutMs, Ucan) ->
    failover({error, {station_endpoint, Reason}}, Rest, Pool, Realm, CapName,
             Payload, TimeoutMs, Ucan).

failover({ok, _} = Ok, _R, _P, _Rlm, _Cap, _Pl, _Tmo, _Ucan) ->
    Ok;
%% The last candidate failed: its failure is the answer. `no_provider'
%% was already impossible here (a non-empty list was dialed), so this
%% never masquerades a dial failure as a resolve miss.
failover({error, _} = Error, [], _Pool, _Realm, _CapName, _Payload,
         _TimeoutMs, _Ucan) ->
    Error;
failover({error, _}, Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan) ->
    call_providers(Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan).

%% Resolve a serving_station pubkey to a dialable `quic://' URL. The
%% SDK's own resolver: it retries past an absent, expired or malformed
%% endpoint record until its deadline (the station re-announces its
%% endpoint periodically, and a one-shot lookup misses), and verifies
%% the record's signer is exactly the station.
resolve_endpoint(Pool, Station) ->
    macula_direct_dial:resolve_station_endpoint(Pool, Station).

%%% Pure helpers (unit-tested)

%% Build the `quic://' seed URL a pool dials, bracketing IPv6 hosts.
-spec station_url(binary(), 1..65535) -> binary().
station_url(Host, Port) when is_binary(Host), is_integer(Port) ->
    HostPart = bracket_if_ipv6(Host),
    <<"quic://", HostPart/binary, ":", (integer_to_binary(Port))/binary>>.

bracket_if_ipv6(Host) ->
    add_brackets(binary:match(Host, <<":">>), Host).

add_brackets(nomatch, Host) -> Host;
add_brackets(_Found, Host)  -> <<"[", Host/binary, "]">>.

-spec build_advertisement(macula_node_keys:node_key(), binary(), binary(),
                          mcl_om_service:capability(),
                          <<_:256>>) -> map().
build_advertisement(Key, Realm, Org, #{name := Name}, Station) ->
    {ok, Advertiser} = macula_node_keys:node_id(Key),
    %% The 11.x record names the realm as its own field; the procedure
    %% is the org-qualified string, no realm-hex prefix.
    Record = macula_record:procedure_advertisement(Advertiser, Realm,
                                                   org_procedure(Org, Name),
                                                   Station),
    macula_record:sign(Record, Key).

%% Verify each record's signature and project it to
%% `{advertiser, serving_station}'. Non-procedure records and bad
%% signatures are dropped. (Full trust-chain checking is Slice 7; this
%% is the authenticity floor.)
-spec decode_resolved([map()]) -> [map()].
decode_resolved(Records) ->
    lists:filtermap(fun decode_one/1, Records).

decode_one(Record) ->
    decode_verified(reverify(Record), Record).

decode_verified({ok, _Payload}, Record) ->
    try macula_record:read_procedure_advertisement(Record) of
        #{advertiser_node := Adv, serving_station := Sta} ->
            {true, #{advertiser => Adv, serving_station => Sta}}
    catch _:_ ->
        false
    end;
decode_verified({error, _}, _Record) ->
    false.

%%% Timer

arm_timer(S) ->
    Ref = erlang:send_after(republish_delay_ms(), self(), republish),
    S#state{timer = Ref}.

%% @doc `?REPUBLISH_INTERVAL_MS' +/- up to `?REPUBLISH_JITTER_MS' / 2,
%% uniformly -- see `?REPUBLISH_JITTER_MS''s own doc for why a fixed
%% period is the actual bug being fixed here, not just a nice-to-have.
-spec republish_delay_ms() -> pos_integer().
republish_delay_ms() ->
    ?REPUBLISH_INTERVAL_MS - (?REPUBLISH_JITTER_MS div 2)
        + rand:uniform(?REPUBLISH_JITTER_MS + 1) - 1.

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.
