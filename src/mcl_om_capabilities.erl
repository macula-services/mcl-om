%%% @doc Advertises a service's capabilities on the mesh, and resolves
%%% other services' capabilities from the DHT.
%%%
%%% A capability carrying `handler => {HandlerModule, Args}' is advertised
%%% TWICE via `advertise_direct/7' on its provider module (see
%%% `provider_module/1') — `macula_response' (request/reply RPC, the
%%% default) or `macula_streamer' (a `kind => streamer' capability) — the
%%% SDK's own supervised wrapper, which registers a handler with the pool
%%% AND publishes the signed `procedure_advertisement' DHT record naming
%%% this pool's connected station, in one call:
%%%
%%%   1. under the bare capability name (`Name') — the any-provider,
%%%      backward-compatible registration every caller could always reach;
%%%   2. under `org_procedure(Org, Name)' (`<<Org/binary, "/",
%%%      Name/binary>>') — a SEPARATE wire-level ADVERTISE and DHT record.
%%%      `macula_remote_advertise_registry' (station-side) keys purely on
%%%      the opaque procedure string, so this lands as a genuinely
%%%      distinct registry entry, not a second write to the same slot.
%%%      Two orgs serving the same capability name from the SAME relay
%%%      station therefore each hold their own entry, rather than one
%%%      shared bare-name slot where whichever republish landed last wins
%%%      — the exact bug a live test
%%%      (`test_live/mcl_om_capabilities_live_station_tests.erl''s
%%%      `org_scoped_call_reaches_only_the_targeted_org_test_') caught
%%%      2026-08-29: both an acme- and a contoso-targeted call were
%%%      answered by whichever org's registration was most recent.
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
%%% `call_capability/5,7' resolves `CapName' under `Org' first
%%% (`discovery_key_org/3'), falling back to the bare (any-provider) key
%%% only when `Org' has published nothing there yet. `resolve_full/4' tags
%%% each resolved provider with which wire-level procedure string actually
%%% matched, and the CALL uses that string, not the raw `CapName' — an
%%% org-scoped resolution CALLs `org_procedure(Org, CapName)', never the
%%% bare name, so a targeted call can only ever be answered by that org's
%%% own registration, all the way to the wire.
%%%
%%% `reuse_sup/0''s pid is round-tripped through this worker's state — one
%%% slot per DISTINCT procedure string, so the bare and org-qualified
%%% registrations each keep their own supervisor — and passed back in as
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
%%% Signing needs the service's stable keypair
%%% (`mcl_om_identity:keypair/0'); an ephemeral service cannot sign
%%% and is correctly not advertised.
-module(mcl_om_capabilities).
-behaviour(gen_server).

-export([start_link/0, register/1, publish/0, lookup/1, list/0,
         list_org_capabilities/1]).
-export([call_capability/5, call_capability/7]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Pure helpers — the record-building, dispatch-decision, and resolution
%% logic, kept side-effect-free so it is unit-testable without a live
%% mesh.
-export([procedure_uri/3, org_procedure/2, build_advertisement/5,
         build_advertisement/6, decode_resolved/1, station_url/2,
         has_handler/1, auth_opts/1, unguarded_capabilities/1,
         reuse_sup_opts/1, advertise_opts/1,
         provider_module/1, stream_opts/1,
         discovery_key/2, discovery_key_org/3,
         org_scoped_or_any/4, org_scoped_full_or_any/5,
         org_capability_pattern/2, matches_org_pattern/2,
         resolve_org_capabilities/3, republish_delay_ms/0]).

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
-define(RESOLVE_RETRIES, 50).
-define(RESOLVE_RETRY_MS, 100).

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

publish() ->
    gen_server:call(?MODULE, publish).

%% @doc Resolve a capability by name to the providers advertising it.
%% `{ok, [#{advertiser := Pubkey, serving_station := Pubkey}]}'. Empty
%% when nothing is advertised or the mesh is unreachable.
-spec lookup(binary()) -> {ok, [map()]}.
lookup(CapName) when is_binary(CapName) ->
    gen_server:call(?MODULE, {lookup, CapName}).

%% @doc Every capability `Org' has advertised — `{ok,
%% [#{procedure_uri := binary(), advertiser := Pubkey, serving_station :=
%% Pubkey}]}'. See moduledoc for why this is a client-side filter over
%% `find_records_by_type', not a DHT-indexed query: a WARM-START view of
%% whatever this pool's connected station(s) locally hold, not an
%% authoritative mesh-wide listing. Empty when nothing matches or the
%% mesh is unreachable, same as `lookup/1'.
-spec list_org_capabilities(binary()) -> {ok, [map()]}.
list_org_capabilities(Org) when is_binary(Org) ->
    gen_server:call(?MODULE, {list_org_capabilities, Org}).

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
    {ok, arm_timer(#state{})}.

handle_call({register, Caps}, _From, #state{advertise_sups = Sups} = S) ->
    log_unguarded(Caps),
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
                   mcl_om_identity:keypair(),
                   mcl_om_identity:realm(),
                   mcl_om_identity:org(),
                   advertise_opts(mcl_om_identity:cert_chain()),
                   Caps, Sups).

%% Embed the service cert chain when one is provisioned (Slice 7c
%% Direction B); otherwise advertise without it (open-mode discovery).
%% Always carries `ttl_ms' — see moduledoc.
advertise_opts(CertChain) ->
    maps:merge(cert_chain_opts(CertChain), #{ttl_ms => ?ADVERTISEMENT_TTL_MS}).

cert_chain_opts({ok, Pem})  -> #{cert_chain => Pem};
cert_chain_opts({error, _}) -> #{}.

advertise_with({ok, Pool}, {ok, KeyPair}, {ok, Realm}, Org, CertOpts, Caps, Sups) ->
    lists:foldl(fun(Cap, Acc) ->
                    advertise_one_safely(Pool, KeyPair, Realm, Org, CertOpts, Cap, Acc)
                end, Sups, Caps);
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
advertise_with(PoolR, KeyPairR, RealmR, _Org, _CertOpts, _Caps, Sups) ->
    log_advertise_gate_once({error_of(PoolR), error_of(KeyPairR), error_of(RealmR)}),
    Sups.

error_of({ok, _}) -> ok;
error_of({error, Reason}) -> Reason.

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
            logger:warning(
              "mcl_om_capabilities: advertise skipped, not all of "
              "pool/keypair/realm are ready yet: ~p (pool_error, "
              "keypair_error, realm_error -- 'ok' means that one is fine)",
              [Reasons])
    end.

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
advertise_one_safely(Pool, KeyPair, Realm, Org, CertOpts, Cap, Acc) ->
    try
        advertise_one(Pool, KeyPair, Realm, Org, CertOpts, Cap, Acc)
    catch
        Class:Reason ->
            logger:warning(
              "mcl_om_capabilities: advertise failed for ~s (~p:~p) "
              "-- keeping the prior registration, retried on the next "
              "republish tick",
              [maps:get(name, Cap, unknown), Class, Reason]),
            Acc
    end.

advertise_one(Pool, KeyPair, Realm, Org, CertOpts,
             #{name := Name, handler := {Mod, Args}} = Cap, Sups) ->
    Provider = provider_module(Cap),
    OrgProcedure = org_procedure(Org, Name),
    AuthOpts = auth_opts(Cap),
    StreamOpts = stream_opts(Cap),
    BareOpts = maps:merge(maps:merge(maps:merge(CertOpts, AuthOpts), StreamOpts),
                          reuse_sup_opts(maps:get(Name, Sups, undefined))),
    OrgOpts  = maps:merge(maps:merge(maps:merge(CertOpts, AuthOpts), StreamOpts),
                          reuse_sup_opts(maps:get(OrgProcedure, Sups, undefined))),
    %% Two independent advertise_direct calls, two independent wire-level
    %% ADVERTISE registrations and DHT records -- see moduledoc for why
    %% this is both necessary (station-side dispatch is opaque-string-
    %% keyed, so two orgs sharing a bare name collide) and sufficient (no
    %% separate record-only write needed; advertise_direct's own DHT
    %% publish for the org-qualified name already lands at
    %% discovery_key_org/3's key). `Provider' is `macula_response' for
    %% every existing capability (no `kind' key set); `macula_streamer'
    %% only for one that opts in with `kind => streamer' -- both publish
    %% the identical `procedure_advertisement' record type, see
    %% `mcl_om_service:capability()''s doc.
    BareResult = Provider:advertise_direct(Pool, Realm, Name, Mod, Args,
                                           KeyPair, BareOpts),
    OrgResult  = Provider:advertise_direct(Pool, Realm, OrgProcedure, Mod,
                                           Args, KeyPair, OrgOpts),
    Sups1 = advertised(BareResult, Name, Sups),
    advertised(OrgResult, OrgProcedure, Sups1);
advertise_one(Pool, KeyPair, Realm, Org, CertOpts, Cap, Sups) ->
    %% No handler declared — legacy discoverable-but-not-callable path,
    %% kept for a capability another mechanism serves.
    advertise_record_only(serving_station(Pool), Pool, KeyPair, Realm, Org,
                          CertOpts, Cap),
    Sups.

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

advertised({ok, Sup}, Name, Sups)   -> Sups#{Name => Sup};
advertised({error, Reason}, Name, Sups) ->
    logger:warning("mcl_om_capabilities: advertise_direct for ~s failed: ~p",
                   [Name, Reason]),
    Sups.

advertise_record_only({ok, Station}, Pool, KeyPair, Realm, Org, CertOpts, Cap) ->
    put_advertisement(Pool, build_advertisement(KeyPair, Realm, Org, Cap,
                                                Station, CertOpts));
advertise_record_only({error, no_station}, _Pool, _KeyPair, _Realm, _Org,
                      _CertOpts, _Cap) ->
    ok.

%% `macula:put_record/2' returns `ok | {error, term()}' -- both branches
%% were previously discarded outright (the old `try ... catch _:_ -> ok
%% end' only guarded against an exception, never inspected a plain
%% `{error, _}' return at all), so a rejected or failed record-only
%% advertisement had no trace anywhere. Logged now, matching
%% `advertised/3''s own fix -- this is the legacy no-handler path
%% (`advertise_one/7''s second clause), the handler-bearing path's own
%% failures are `advertised/3''s concern above.
put_advertisement(Pool, Record) ->
    log_put_result(try macula:put_record(Pool, Record)
                    catch Class:Reason -> {error, {Class, Reason}}
                    end).

log_put_result(ok) -> ok;
log_put_result({error, Reason}) ->
    logger:warning("mcl_om_capabilities: put_record (record-only advertisement) failed: ~p",
                   [Reason]),
    ok.

%% One station this service is reachable through, from the pool's
%% connected links. Slice 2 advertises ONE serving station per provider
%% (the store dedups records by signer); multi-station is Q10 / Slice 5.
serving_station(Pool) ->
    case connected_node_ids(Pool) of
        [NodeId | _] -> {ok, NodeId};
        []           -> {error, no_station}
    end.

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
    Pattern = org_capability_pattern(Realm, Org),
    lists:filtermap(fun(R) -> decode_if_org_matches(R, Pattern) end,
                    find_by_type(Pool)).

%% `RealmHex/Org/*' -- the pattern every one of Org's advertisements'
%% procedure_uri must match, in the SAME `RealmHex/Org/Name' shape
%% `procedure_uri/3' builds (a wildcard trailing segment, matched via
%% `macula_topic_pattern:matches/2').
org_capability_pattern(Realm, Org) ->
    [binary:encode_hex(Realm, uppercase), Org, <<"*">>].

find_by_type(Pool) ->
    on_find_by_type(find_records_by_type(Pool)).

find_records_by_type(Pool) ->
    try macula:find_records_by_type(Pool, ?TYPE_PROCEDURE_ADVERTISEMENT)
    catch _:_ -> {error, unreachable}
    end.

on_find_by_type({ok, Records}) -> Records;
on_find_by_type(_Other)        -> [].

decode_if_org_matches(Record, Pattern) ->
    decode_verified_if_org_matches(macula_record:verify(Record), Record, Pattern).

decode_verified_if_org_matches({ok, _Payload}, Record, Pattern) ->
    try macula_record:read_procedure_advertisement(Record) of
        #{procedure_uri := Uri} = Decoded ->
            keep_if_matches(matches_org_pattern(Pattern, Uri), Decoded, Record)
    catch _:_ ->
        false
    end;
decode_verified_if_org_matches({error, _}, _Record, _Pattern) ->
    false.

%% @doc Whether `Uri' (a procedure_advertisement's own `procedure_uri'
%% field) matches the `RealmHex/Org/*' `Pattern'. Split purely on `/' --
%% `Uri''s own Name segment may itself contain `.' (`weather.get_forecast')
%% but never `/', matching `procedure_uri/3''s own construction.
-spec matches_org_pattern([binary()], binary()) -> boolean().
matches_org_pattern(Pattern, Uri) ->
    macula_topic_pattern:matches(Pattern, binary:split(Uri, <<"/">>, [global])).

keep_if_matches(true, Decoded, Record) ->
    {true, Decoded#{record => Record}};
keep_if_matches(false, _Decoded, _Record) ->
    false.

%% Org-scoped first: as of advertise_one/7, a handler-bearing capability
%% publishes BOTH the bare key (below) and an org-qualified one. Resolving
%% the org-qualified key first can only ever return `Org''s own
%% providers -- two orgs running the same capability name never mix.
%% Falls back to the bare (any-provider) key when the org-qualified
%% lookup is empty, which is what keeps this backward compatible with a
%% provider that hasn't upgraded to publish the org-qualified record yet
%% -- no fleet-wide flag day required, resolution just gets more precise
%% as each provider upgrades independently.
resolve_at(Pool, Realm, Org, CapName) ->
    org_scoped_or_any(resolve_records(find(Pool, discovery_key_org(Realm, Org, CapName))),
                      Pool, Realm, CapName).

org_scoped_or_any([_ | _] = OrgScoped, _Pool, _Realm, _CapName) ->
    OrgScoped;
org_scoped_or_any([], Pool, Realm, CapName) ->
    resolve_records(find(Pool, discovery_key(Realm, CapName))).

%% The key a handler-bearing capability is actually reachable under, when
%% no org-qualified record exists for it (yet, or at all): Realm + the
%% bare capability name, matching macula_direct_dial's own (private, so
%% replicated here) discovery_uri/2 formula -- NOT procedure_uri/3 alone.
%% A capability advertised via the legacy record-only path (no handler,
%% never callable via call_capability regardless) is not resolvable
%% through this lookup — documented as written "for a capability another
%% mechanism serves".
discovery_key(Realm, Name) ->
    macula_record:procedure_key(<<(binary:encode_hex(Realm, uppercase))/binary, "/",
                                  Name/binary>>).

%% Org-qualified discovery key -- Realm/Org/Name, procedure_uri/3's own
%% formula (already realm-prefixed; do not also wrap it in discovery_key/2's
%% own prefixing, that would double the realm segment). A distinct DHT
%% bucket per org: resolving this key can only ever return the named
%% org's own providers.
discovery_key_org(Realm, Org, Name) ->
    macula_record:procedure_key(procedure_uri(Realm, Org, Name)).

%% find/2 always returns `{ok, List}' (its retry loop converts an
%% exhausted/persistent error into `{ok, []}' rather than passing
%% `{error, _}' through) -- no `_Other' clause needed here any more.
resolve_records({ok, Records}) -> decode_resolved(Records).

%% Like resolve_at/4 but keeps each raw record so the verifying-consumer
%% path (7c Direction B) can chain-check the embedded service cert. Same
%% org-scoped-with-fallback resolution as resolve_at/4, PLUS: tags every
%% returned provider with `procedure' -- the actual wire-level string the
%% CALL must use. This is what makes the org-scoping real all the way to
%% the wire: an org-scoped hit is tagged `org_procedure(Org, CapName)', a
%% fallback-to-bare hit is tagged the bare `CapName' -- never derived from
%% `Org' alone at call time, because a fallback hit's provider may not be
%% `Org' at all (that's the point of the fallback), and CALLing with the
%% wrong tag would target a registration that provider never made.
resolve_full(Pool, Realm, Org, CapName) ->
    org_scoped_full_or_any(
      resolve_full_records(find(Pool, discovery_key_org(Realm, Org, CapName))),
      Pool, Realm, Org, CapName).

org_scoped_full_or_any([_ | _] = OrgScoped, _Pool, _Realm, Org, CapName) ->
    tag_procedure(OrgScoped, org_procedure(Org, CapName));
org_scoped_full_or_any([], Pool, Realm, _Org, CapName) ->
    tag_procedure(resolve_full_records(find(Pool, discovery_key(Realm, CapName))),
                 CapName).

tag_procedure(Providers, Procedure) ->
    [P#{procedure => Procedure} || P <- Providers].

%% Same reasoning as resolve_records/1 -- find/2 always returns
%% `{ok, List}' now.
resolve_full_records({ok, Records}) -> decode_resolved_full(Records).

decode_resolved_full(Records) ->
    lists:filtermap(fun decode_one_full/1, Records).

decode_one_full(Record) ->
    decode_verified_full(macula_record:verify(Record), Record).

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
%% 100ms = up to 5s) -- a budget this module does NOT get for free by
%% calling `macula:find_records/2' directly (the bare, single-shot SDK
%% RPC; the retrying version is private to macula_direct_dial). Found
%% live 2026-08-29: two providers advertising back-to-back, the second
%% one's own resolve raced its own just-written record with zero retry
%% margin, `{error, no_provider}' even though the record existed --
%% `run_org_scoped/0' only sleeps a fixed 2s between the last advertise
%% and the first call, not long enough for eager replication AND both
%% providers' writes to settle every time.
find(Pool, Key) ->
    find(Pool, Key, ?RESOLVE_RETRIES).

find(_Pool, _Key, 0) ->
    {ok, []};
find(Pool, Key, Retries) ->
    on_find(try_find(Pool, Key), Pool, Key, Retries).

try_find(Pool, Key) ->
    try macula:find_records(Pool, Key)
    catch _:_ -> {error, unreachable}
    end.

on_find({ok, [_ | _]} = Result, _Pool, _Key, _Retries) ->
    Result;
on_find(_Other, Pool, Key, Retries) ->
    timer:sleep(?RESOLVE_RETRY_MS),
    find(Pool, Key, Retries - 1).

%%% Internals — call a capability (resolve -> verify -> dial -> call)

call_capability_via({ok, Pool}, {ok, Realm}, Org, CapName, Payload,
                    TimeoutMs, Opts) ->
    call_capability(Pool, Realm, Org, CapName, Payload, TimeoutMs, Opts);
call_capability_via(_Pool, _Realm, _Org, _CapName, _Payload, _TimeoutMs, _Opts) ->
    {error, not_configured}.

%% @doc Explicit-pool form (testable without mcl_om_identity).
%% `Opts': `verify => boolean()' (default false = open; when true, drop
%% providers whose embedded service-cert chain does not verify to the
%% realm CA, Slice 7c Direction B) and `ucan_token => binary()'
%% (presented to a gated provider, Slice 7b).
-spec call_capability(pid(), binary(), binary(), binary(), term(),
                      pos_integer(), map()) -> {ok, term()} | {error, term()}.
call_capability(Pool, Realm, Org, CapName, Payload, TimeoutMs, Opts) ->
    Providers = verify_providers(maps:get(verify, Opts, false), Org,
                                 resolve_full(Pool, Realm, Org, CapName)),
    call_providers(Providers, Pool, Realm, CapName, Payload, TimeoutMs,
                   maps:get(ucan_token, Opts, <<>>)).

%% Verifying-consumer mode (7c Direction B): keep only providers whose
%% embedded service-cert chain verifies to the realm CA and whose leaf
%% is issued for `Org'. Open mode (default): keep all.
verify_providers(false, _Org, Providers) ->
    Providers;
verify_providers(true, Org, Providers) ->
    keep_chain_verified(mcl_om_identity:realm_ca(), Org, Providers).

%% `verify => true' but no realm CA provisioned: nothing can be verified,
%% so drop every provider rather than trust blindly.
keep_chain_verified({ok, RealmCaPem}, Org, Providers) ->
    [P || #{record := Rec} = P <- Providers,
          macula_record:verify_advertisement_cert_chain(RealmCaPem, Rec, Org)
              =:= ok];
keep_chain_verified({error, _}, _Org, _Providers) ->
    [].

call_providers([], _Pool, _Realm, _CapName, _Payload, _TimeoutMs, _Ucan) ->
    {error, no_provider};
call_providers([#{serving_station := Station, procedure := Procedure} | Rest],
               Pool, Realm, CapName, Payload, TimeoutMs, Ucan) ->
    dial_provider(resolve_endpoint(Pool, Station), Station, Procedure,
                  Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan).

%% Endpoint resolved: dial + call; on error, fail over to the next.
%%
%% CALLs with `Procedure' -- the wire-level string `resolve_full/4' tagged
%% this provider with (`org_procedure(Org, CapName)' on an org-scoped
%% resolve, bare `CapName' on the any-provider fallback) -- NOT the raw
%% `CapName' argument. This is what makes org-scoping real all the way to
%% the wire: this provider only ever registered a wire-level ADVERTISE
%% under `Procedure', so CALLing with anything else would hit whatever
%% (possibly a different org's) registration currently holds the bare
%% name at this station.
%%
%% Trust triad matches macula_direct_dial:call/6 exactly (verified
%% against a real demo-fleet station, 2026-08-24 -- omitting it makes
%% every direct-dial call fail with `not_connected', not a signature
%% or auth error, because the failure is at the TLS layer before the
%% application-level trust check ever runs): a resolved provider is
%% trusted because the signed DHT `procedure_advertisement' chain
%% named exactly this `Station' pubkey, not because its TLS
%% certificate chains to a CA -- a production station's TLS cert has
%% no relationship to its macula identity. `verify => none' +
%% `pin_tls_cert => false' skip the (irrelevant) TLS check;
%% `expected_node_id => Station' is what actually pins trust, enforced
%% at the application layer during the CONNECT/HELLO handshake.
dial_provider({ok, Url}, Station, Procedure, Rest, Pool, Realm, CapName,
              Payload, TimeoutMs, Ucan) ->
    CallResult = macula:call_station(Pool, Url, Realm, Procedure, Payload,
                                     TimeoutMs,
                                     #{ucan_token => Ucan,
                                       expected_node_id => Station,
                                       pin_tls_cert => false,
                                       verify => none}),
    failover(CallResult, Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan);
dial_provider({error, _}, _Station, _Procedure, Rest, Pool, Realm, CapName,
              Payload, TimeoutMs, Ucan) ->
    call_providers(Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan).

failover({ok, _} = Ok, _R, _P, _Rlm, _Cap, _Pl, _Tmo, _Ucan) ->
    Ok;
failover({error, _}, Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan) ->
    call_providers(Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan).

%% Resolve a serving_station pubkey to a dialable `quic://' URL via its
%% signed `station_endpoint' record.
resolve_endpoint(Pool, Station) ->
    endpoint_url(find_endpoint(Pool, Station)).

find_endpoint(Pool, Station) ->
    read_endpoint(find_record(Pool, macula_record:station_endpoint_key(Station))).

find_record(Pool, Key) ->
    try macula:find_record(Pool, Key)
    catch _:_ -> {error, unreachable}
    end.

read_endpoint({ok, Record}) ->
    {ok, macula_record:read_station_endpoint(Record)};
read_endpoint(_Other) ->
    {error, no_endpoint}.

endpoint_url({ok, #{quic_port := Port, host_advertised := [Host | _]}}) ->
    {ok, station_url(Host, Port)};
endpoint_url(_Other) ->
    {error, no_endpoint}.

%%% Pure helpers (unit-tested)

%% Realm-namespaced procedure URI. The org segment (Q8) rides with
%% Slice 7 trust; realm-scoping is enough for discovery and
%% cross-realm collision-freedom now.
%% `<realm-hex>/<org>/<capability>' — the org segment (Slice 7c) roots
%% the delegation chain and keeps two orgs' same-named capabilities
%% distinct.
-spec procedure_uri(binary(), binary(), binary() | map()) -> binary().
procedure_uri(Realm, Org, #{name := Name}) ->
    procedure_uri(Realm, Org, Name);
procedure_uri(Realm, Org, Name)
  when is_binary(Realm), is_binary(Org), is_binary(Name) ->
    <<(binary:encode_hex(Realm, uppercase))/binary, "/", Org/binary, "/", Name/binary>>.

%% Build the `quic://' seed URL a pool dials, bracketing IPv6 hosts.
-spec station_url(binary(), 1..65535) -> binary().
station_url(Host, Port) when is_binary(Host), is_integer(Port) ->
    HostPart = bracket_if_ipv6(Host),
    <<"quic://", HostPart/binary, ":", (integer_to_binary(Port))/binary>>.

bracket_if_ipv6(Host) ->
    add_brackets(binary:match(Host, <<":">>), Host).

add_brackets(nomatch, Host) -> Host;
add_brackets(_Found, Host)  -> <<"[", Host/binary, "]">>.

-spec build_advertisement(macula_identity:key_pair(), binary(), binary(),
                          mcl_om_service:capability(),
                          macula_identity:pubkey()) -> map().
build_advertisement(KeyPair, Realm, Org, Cap, Station) ->
    build_advertisement(KeyPair, Realm, Org, Cap, Station, #{}).

%% `CertOpts' carries `cert_chain => Pem' (leaf ++ org CA) so a verifying
%% consumer can chain the advertiser to the realm CA (Slice 7c Direction B);
%% `#{}' when the service has no provisioned chain.
-spec build_advertisement(macula_identity:key_pair(), binary(), binary(),
                          mcl_om_service:capability(),
                          macula_identity:pubkey(),
                          macula_record:procedure_advertisement_opts()) -> map().
build_advertisement(KeyPair, Realm, Org, #{name := Name}, Station, CertOpts) ->
    Advertiser = macula_identity:public(KeyPair),
    Uri        = procedure_uri(Realm, Org, Name),
    Record     = macula_record:procedure_advertisement(Advertiser, Uri, Station,
                                                       CertOpts),
    macula_record:sign(Record, KeyPair).

%% Verify each record's signature and project it to
%% `{advertiser, serving_station}'. Non-procedure records and bad
%% signatures are dropped. (Full trust-chain checking is Slice 7; this
%% is the authenticity floor.)
-spec decode_resolved([map()]) -> [map()].
decode_resolved(Records) ->
    lists:filtermap(fun decode_one/1, Records).

decode_one(Record) ->
    decode_verified(macula_record:verify(Record), Record).

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
