%%% Unit tests for the pure record-building + resolution helpers of
%%% mcl_om_capabilities (direct-dial discovery, Slice 2). The mesh
%%% I/O (put_record / find_records / links) is thin glue over macula,
%%% covered by macula-station's DHT handler tests and macula's record
%%% tests; here we prove hecate-om builds the right record, derives the
%%% same key on both sides, and decodes/verifies what it reads back.
-module(mcl_om_capabilities_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

%% Placeholder macula_response AND macula_streamer callback module (piece
%% B tests + the streamer-kind tests below) — referenced only by module
%% atom (`{?MODULE, []}'), dispatched at real inbound-call/stream-open
%% time, which these tests never reach (no live station). Only
%% `-behaviour(macula_response)' is declared: the compiler rejects two
%% `-behaviour' attributes sharing a callback name (both declare
%% `init/1'), so `handle_open/2' (macula_streamer's own callback) is
%% exported without the second attribute.
-behaviour(macula_response).
-export([init/1, handle_request/2, handle_open/2]).

realm()      -> crypto:strong_rand_bytes(32).
station()    -> crypto:strong_rand_bytes(32).
cap(Name)    -> #{name => Name, version => 1}.

%% Provider (advertising, from a capability map) and consumer (looking
%% up, from a bare name) must derive the SAME URI so their storage keys
%% match — otherwise a consumer could never find the provider.
procedure_uri_agrees_and_is_realm_scoped_test() ->
    R    = realm(),
    Name = <<"hecate-rag.query">>,
    FromCap  = mcl_om_capabilities:procedure_uri(R, <<"acme">>, cap(Name)),
    FromName = mcl_om_capabilities:procedure_uri(R, <<"acme">>, Name),
    ?assertEqual(FromName, FromCap),
    ?assertEqual(<<(binary:encode_hex(R, uppercase))/binary, "/acme/", Name/binary>>, FromCap).

build_advertisement_round_trips_test() ->
    Kp = macula_identity:generate(),
    R  = realm(),
    St = station(),
    Rec = mcl_om_capabilities:build_advertisement(Kp, R, <<"acme">>, cap(<<"svc.do">>), St),
    #{advertiser_node := Adv,
      serving_station := Sta,
      procedure_uri   := Uri} = macula_record:read_procedure_advertisement(Rec),
    ?assertEqual(macula_identity:public(Kp), Adv),
    ?assertEqual(St, Sta),
    ?assertEqual(mcl_om_capabilities:procedure_uri(R, <<"acme">>, <<"svc.do">>), Uri),
    %% and the record verifies (it was signed by the advertiser)
    ?assertMatch({ok, _}, macula_record:verify(Rec)).

%% The Slice-2 DONE-WHEN in pure form: two providers advertise one
%% capability; decode_resolved recovers both as {advertiser, station}.
decode_resolved_returns_verified_providers_test() ->
    R   = realm(),
    St1 = station(),
    St2 = station(),
    KpA = macula_identity:generate(),
    KpB = macula_identity:generate(),
    A = mcl_om_capabilities:build_advertisement(KpA, R, <<"acme">>, cap(<<"c">>), St1),
    B = mcl_om_capabilities:build_advertisement(KpB, R, <<"acme">>, cap(<<"c">>), St2),
    Got = mcl_om_capabilities:decode_resolved([A, B]),
    ?assertEqual(2, length(Got)),
    ?assert(lists:member(#{advertiser => macula_identity:public(KpA),
                           serving_station => St1}, Got)),
    ?assert(lists:member(#{advertiser => macula_identity:public(KpB),
                           serving_station => St2}, Got)).

decode_resolved_drops_tampered_and_foreign_records_test() ->
    R   = realm(),
    St  = station(),
    Kp  = macula_identity:generate(),
    Good     = mcl_om_capabilities:build_advertisement(Kp, R, <<"acme">>, cap(<<"c">>), St),
    Tampered = Good#{signature := <<0:512>>},
    %% a node_record is not a procedure_advertisement
    NodeKp = macula_identity:generate(),
    Node   = macula_record:sign(
               macula_record:node_record(macula_identity:public(NodeKp), [], 0),
               NodeKp),
    Got = mcl_om_capabilities:decode_resolved([Tampered, Node, Good]),
    ?assertEqual([#{advertiser => macula_identity:public(Kp),
                    serving_station => St}], Got).

%%% Org-scoped discovery — two orgs advertising the same bare capability
%%% name must resolve to genuinely distinct DHT buckets, so a caller
%%% targeting one org can never be silently answered by the other.

%% The property the whole fix depends on: two different orgs (or an org
%% vs. the bare/any-provider key) derive DIFFERENT storage keys for the
%% identical capability name. Before this fix, Org was accepted by
%% call_capability/5,7 but never reached key derivation at all — every
%% org collided on the same bare key.
discovery_key_org_is_distinct_per_org_and_from_bare_test() ->
    R    = realm(),
    Name = <<"svc.do">>,
    Bare   = mcl_om_capabilities:discovery_key(R, Name),
    Acme   = mcl_om_capabilities:discovery_key_org(R, <<"acme">>, Name),
    Contoso = mcl_om_capabilities:discovery_key_org(R, <<"contoso">>, Name),
    ?assertNotEqual(Bare, Acme),
    ?assertNotEqual(Bare, Contoso),
    ?assertNotEqual(Acme, Contoso).

%% Read/write agreement: the key a consumer derives via discovery_key_org/3
%% must be EXACTLY the key macula_record:storage_key/1 computes for a
%% record built via build_advertisement/5 with the same (Realm, Org,
%% Name) — otherwise the org-qualified record advertise_one/7 now
%% publishes would be unfindable by the org-scoped lookup that's
%% supposed to find it, and the fix would silently do nothing.
discovery_key_org_matches_what_gets_published_under_it_test() ->
    Kp   = macula_identity:generate(),
    R    = realm(),
    St   = station(),
    Org  = <<"acme">>,
    Name = <<"svc.do">>,
    Rec = mcl_om_capabilities:build_advertisement(Kp, R, Org, cap(Name), St),
    ?assertEqual(mcl_om_capabilities:discovery_key_org(R, Org, Name),
                 macula_record:storage_key(Rec)).

%% Pure decision logic: a non-empty org-scoped result is returned as-is —
%% the fallback branch (which would need a real find/2 mesh call) is
%% never reached, matching Erlang's own clause selection, not something
%% this test has to prove separately.
org_scoped_or_any_prefers_org_scoped_when_present_test() ->
    OrgScoped = [#{advertiser => <<1:256>>, serving_station => <<2:256>>}],
    ?assertEqual(OrgScoped,
                 mcl_om_capabilities:org_scoped_or_any(
                   OrgScoped, unused_pool, unused_realm, unused_cap)).

%% Empty org-scoped result: falls back to the bare-key resolution path
%% rather than reporting "no provider" outright. Uses the same zero-seed
%% real-pool technique as the live_pool_* tests above — proves the
%% fallback branch reaches real code (discovery_key/2 + find/2 +
%% resolve_records/1) and degrades to [] without crashing, rather than
%% proving a non-empty result (which needs a real station).
org_scoped_or_any_falls_back_when_org_scoped_is_empty_test_() ->
    {timeout, 15,
     fun() ->
        {ok, _} = application:ensure_all_started(macula),
        {ok, Pool} = macula_client:connect([], #{}),
        Got = mcl_om_capabilities:org_scoped_or_any(
                [], Pool, realm(), <<"svc.do">>),
        ?assertEqual([], Got),
        try macula_client:close(Pool) catch _:_ -> ok end
     end}.

%%% Org-scoped wire dispatch (2026-08-29) — the shared-station fix. Two
%%% orgs advertising the same bare capability name from the SAME station
%%% used to collide on macula_remote_advertise_registry's single-provider-
%%% per-bare-name invariant; a targeted call could be silently answered
%%% by whichever org's registration was most recent. Fixed by CALLing
%%% with a per-org wire-level procedure string, not the bare name.

org_procedure_is_org_slash_name_test() ->
    ?assertEqual(<<"acme/svc.do">>,
                 mcl_om_capabilities:org_procedure(<<"acme">>, <<"svc.do">>)),
    ?assertNotEqual(
       mcl_om_capabilities:org_procedure(<<"acme">>, <<"svc.do">>),
       mcl_om_capabilities:org_procedure(<<"contoso">>, <<"svc.do">>)).

%% The property advertise_one/7's dual-advertise depends on: publishing
%% under org_procedure(Org, Name) as the wire-level Procedure lands the
%% DHT record at EXACTLY discovery_key_org/3's key, because
%% macula_direct_dial:discovery_uri/2 (RealmHex/Procedure) and
%% procedure_uri/3 (RealmHex/Org/Name) produce the identical string when
%% Procedure = org_procedure(Org, Name). If this ever stopped being true,
%% the org-qualified advertise_direct call would publish somewhere the
%% org-scoped resolver can never find.
org_procedure_matches_procedure_uri_when_realm_prefixed_test() ->
    R    = realm(),
    Org  = <<"acme">>,
    Name = <<"svc.do">>,
    DiscoveryUriShape = <<(binary:encode_hex(R, uppercase))/binary, "/",
                          (mcl_om_capabilities:org_procedure(Org, Name))/binary>>,
    ?assertEqual(mcl_om_capabilities:procedure_uri(R, Org, Name),
                 DiscoveryUriShape).

%% org_scoped_full_or_any/5's whole job: tag each provider with the
%% wire-level procedure the CALL must use. An org-scoped hit is tagged
%% org_procedure(Org, CapName) -- never CapName alone -- so dial_provider
%% can only ever reach that org's own registration.
org_scoped_full_or_any_tags_org_scoped_hits_with_the_org_procedure_test() ->
    OrgScoped = [#{advertiser => <<1:256>>, serving_station => <<2:256>>,
                  record => ignored}],
    Got = mcl_om_capabilities:org_scoped_full_or_any(
            OrgScoped, unused_pool, unused_realm, <<"acme">>, <<"svc.do">>),
    ?assertEqual([#{advertiser => <<1:256>>, serving_station => <<2:256>>,
                    record => ignored, procedure => <<"acme/svc.do">>}],
                Got).

%% Empty org-scoped result falls back to bare-key resolution AND tags the
%% fallback hits with the bare CapName, never org_procedure/2 -- a
%% fallback hit's provider may not even be the targeted org (that's the
%% point of the fallback), so tagging it org-qualified would target a
%% registration that provider never made.
org_scoped_full_or_any_falls_back_and_tags_with_bare_name_test_() ->
    {timeout, 15,
     fun() ->
        {ok, _} = application:ensure_all_started(macula),
        {ok, Pool} = macula_client:connect([], #{}),
        Got = mcl_om_capabilities:org_scoped_full_or_any(
                [], Pool, realm(), <<"acme">>, <<"svc.do">>),
        ?assertEqual([], Got),
        try macula_client:close(Pool) catch _:_ -> ok end
     end}.

%% advertise_opts/1 always carries ttl_ms proportioned to the republish
%% interval, with or without a cert chain -- the property slice 6 (TTL
%% fix) depends on: a dead service's advertisement should age out in
%% minutes, not the ~48h envelope default.
advertise_opts_always_carries_a_proportioned_ttl_test() ->
    ?assertMatch(#{ttl_ms := Ttl} when is_integer(Ttl) andalso Ttl > 0,
                 mcl_om_capabilities:advertise_opts({error, no_chain})),
    ?assertMatch(#{ttl_ms := _, cert_chain := <<"pem">>},
                 mcl_om_capabilities:advertise_opts({ok, <<"pem">>})).

%% End-to-end proof (pure, no mesh): the record-only path's ttl_ms
%% actually reaches the signed record's expires_at -- this path builds
%% via macula_record:procedure_advertisement/4 directly, so it is NOT
%% affected by the macula_direct_dial:adv_opts/1 forwarding gap the
%% handler-bearing path depends on macula shipping past 10.11.1 for.
build_advertisement_honors_a_proportioned_ttl_test() ->
    Kp   = macula_identity:generate(),
    R    = realm(),
    St   = station(),
    Opts = mcl_om_capabilities:advertise_opts({error, no_chain}),
    #{ttl_ms := TtlMs} = Opts,
    Rec = mcl_om_capabilities:build_advertisement(
            Kp, R, <<"acme">>, cap(<<"svc.do">>), St, Opts),
    ?assertEqual(TtlMs,
                 macula_record:expires_at(Rec) - macula_record:created_at(Rec)).

%%% Org capability browse (2026-08-29, slice 4) -- client-side filter
%%% over find_records_by_type, matched via macula_topic_pattern.

org_capability_pattern_is_realm_hex_org_star_test() ->
    R = realm(),
    ?assertEqual([binary:encode_hex(R, uppercase), <<"acme">>, <<"*">>],
                 mcl_om_capabilities:org_capability_pattern(R, <<"acme">>)).

matches_org_pattern_matches_any_name_under_the_org_test() ->
    R = realm(),
    Pattern = mcl_om_capabilities:org_capability_pattern(R, <<"acme">>),
    AcmeUri = mcl_om_capabilities:procedure_uri(R, <<"acme">>, <<"svc.do">>),
    ContosoUri = mcl_om_capabilities:procedure_uri(R, <<"contoso">>, <<"svc.do">>),
    ?assert(mcl_om_capabilities:matches_org_pattern(Pattern, AcmeUri)),
    ?assertNot(mcl_om_capabilities:matches_org_pattern(Pattern, ContosoUri)).

%% Pure proof (no mesh) that resolve_org_capabilities/3's actual filter
%% (decode_if_org_matches -> matches_org_pattern) keeps the right
%% records and drops the wrong ones, exercised via find_records_by_type's
%% real decode path (macula_record:verify + read_procedure_advertisement),
%% not just the pattern-matching primitive in isolation above.
%% Uses the zero-seed real-pool technique (find_records_by_type against
%% a pool with no links degrades to [] without crashing).
resolve_org_capabilities_degrades_cleanly_with_no_mesh_test_() ->
    {timeout, 15,
     fun() ->
        {ok, _} = application:ensure_all_started(macula),
        {ok, Pool} = macula_client:connect([], #{}),
        Got = mcl_om_capabilities:resolve_org_capabilities(
                Pool, realm(), <<"acme">>),
        ?assertEqual([], Got),
        try macula_client:close(Pool) catch _:_ -> ok end
     end}.

station_url_brackets_ipv6_only_test() ->
    ?assertEqual(<<"quic://[::1]:4433">>,
                 mcl_om_capabilities:station_url(<<"::1">>, 4433)),
    ?assertEqual(<<"quic://[2001:db8::5]:9000">>,
                 mcl_om_capabilities:station_url(<<"2001:db8::5">>, 9000)),
    ?assertEqual(<<"quic://10.0.0.7:4433">>,
                 mcl_om_capabilities:station_url(<<"10.0.0.7">>, 4433)).

%%% Direct-dial dual-trust (Slice 7c Direction B) — the advertise side
%%% embeds the service cert chain; the SDK verifies it to the realm CA.

%% build_advertisement/6 embeds the cert chain so a verifying consumer
%% can read it back off the record; /5 leaves it absent (open-mode).
build_advertisement_embeds_cert_chain_test() ->
    Kp    = macula_identity:generate(),
    R     = realm(),
    St    = station(),
    Chain = <<"-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n">>,
    With  = mcl_om_capabilities:build_advertisement(
              Kp, R, <<"acme">>, cap(<<"svc.do">>), St, #{cert_chain => Chain}),
    Without = mcl_om_capabilities:build_advertisement(
                Kp, R, <<"acme">>, cap(<<"svc.do">>), St),
    ?assertMatch(#{cert_chain := Chain},
                 macula_record:read_procedure_advertisement(With)),
    ?assertMatch(#{cert_chain := undefined},
                 macula_record:read_procedure_advertisement(Without)).

%% An advertisement built with a REAL service-cert chain verifies to the
%% realm CA via the SDK; the same capability advertised without a chain
%% (a would-be squatter in verify-mode) is rejected as no_cert_chain.
%% This proves the embed side produces records the verify side accepts.
build_advertisement_chain_verifies_to_realm_ca_test() ->
    Kp     = macula_identity:generate(),
    AdvKey = macula_identity:public(Kp),
    R      = realm(),
    St     = station(),
    #{realm_ca := RealmCa, chain := Chain} = issue_chain(AdvKey, <<"acme">>),
    Good = mcl_om_capabilities:build_advertisement(
             Kp, R, <<"acme">>, cap(<<"svc.do">>), St, #{cert_chain => Chain}),
    NoChain = mcl_om_capabilities:build_advertisement(
                Kp, R, <<"acme">>, cap(<<"svc.do">>), St),
    ?assertEqual(ok,
                 macula_record:verify_advertisement_cert_chain(RealmCa, Good, <<"acme">>)),
    ?assertEqual({error, no_cert_chain},
                 macula_record:verify_advertisement_cert_chain(RealmCa, NoChain, <<"acme">>)).

%%% Piece B (PLAN_MCL_OM_MESH_WRAPPERS.md): a capability carrying
%%% `handler => {Module, Args}' is advertised via
%%% `macula_response:advertise_direct/7' instead of the legacy bare
%%% `put_record'. `has_handler/1' is the dispatch decision;
%%% `reuse_sup_opts/1' is what keeps a periodic re-advertise from
%%% leaking one factory supervisor per tick.

has_handler_distinguishes_capability_shapes_test() ->
    ?assert(mcl_om_capabilities:has_handler(
              #{name => <<"svc.do">>, version => 1,
                handler => {my_mod, []}})),
    ?assertNot(mcl_om_capabilities:has_handler(
                 #{name => <<"svc.do">>, version => 1})).

reuse_sup_opts_carries_a_known_sup_and_nothing_else_test() ->
    ?assertEqual(#{}, mcl_om_capabilities:reuse_sup_opts(undefined)),
    Sup = self(),
    ?assertEqual(#{reuse_sup => Sup},
                 mcl_om_capabilities:reuse_sup_opts(Sup)).

%%% PLAN_UCAN_GATED_CAPABILITIES.md: a capability may opt into gating
%%% via its own `auth' key, forwarded into advertise_direct's Opts.
%%% Absence must merge nothing -- an explicit #{auth => open} would work
%%% too (macula:advertise/5 treats them identically) but silently
%%% differs from every existing capability map already in the wild.

auth_opts_is_absent_when_the_capability_sets_none_test() ->
    ?assertEqual(#{}, mcl_om_capabilities:auth_opts(
                         #{name => <<"svc.do">>, version => 1,
                           handler => {my_mod, []}})).

auth_opts_carries_an_explicit_open_policy_test() ->
    ?assertEqual(#{auth => open},
                 mcl_om_capabilities:auth_opts(
                   #{name => <<"svc.do">>, version => 1,
                     handler => {my_mod, []}, auth => open})).

auth_opts_carries_a_ucan_required_policy_test() ->
    Issuer = <<0:256>>,
    ?assertEqual(#{auth => {ucan_required, Issuer}},
                 mcl_om_capabilities:auth_opts(
                   #{name => <<"svc.prune">>, version => 1,
                     handler => {my_mod, []},
                     auth => {ucan_required, Issuer}})).

%% `macula_client:auth_policy/0' gained this variant after
%% PLAN_UCAN_GATED_CAPABILITIES.md's own "Implemented" note was
%% written (that plan explicitly called chain-walking-to-a-realm-root
%% verification unbuilt "anywhere in macula today" -- no longer true).
%% auth_opts/1 is policy-agnostic by design (see its own doc), so this
%% pins that the THIRD variant round-trips identically to the other
%% two, not just that the first two still do.
auth_opts_carries_a_realm_member_required_policy_test() ->
    RealmDid = <<0:256>>,
    RequiredCan = <<"member/email-verified">>,
    ?assertEqual(#{auth => {realm_member_required, RealmDid, RequiredCan}},
                 mcl_om_capabilities:auth_opts(
                   #{name => <<"svc.chat">>, version => 1,
                     handler => {my_mod, []},
                     auth => {realm_member_required, RealmDid, RequiredCan}})).

%%% unguarded_capabilities/1: which of a service's own declared
%%% capabilities have no explicit auth key at all -- register/1 logs
%%% exactly this list at boot (see mcl_om_capabilities' own
%%% moduledoc for why this can only see what capabilities/0 reports,
%%% not a capability advertised out-of-band).

unguarded_capabilities_is_empty_when_every_capability_sets_auth_test() ->
    ?assertEqual([],
                 mcl_om_capabilities:unguarded_capabilities(
                   [#{name => <<"svc.read">>, version => 1,
                      handler => {my_mod, []}, auth => open},
                    #{name => <<"svc.prune">>, version => 1,
                      handler => {my_mod, []}, auth => {ucan_required, <<0:256>>}}])).

unguarded_capabilities_names_every_capability_with_no_auth_key_test() ->
    ?assertEqual([<<"svc.read">>, <<"svc.prune">>],
                 mcl_om_capabilities:unguarded_capabilities(
                   [#{name => <<"svc.read">>, version => 1,
                      handler => {my_mod, []}},
                    #{name => <<"svc.prune">>, version => 1,
                      handler => {my_mod, []}},
                    #{name => <<"svc.reviewed">>, version => 1,
                      handler => {my_mod, []}, auth => open}])).

unguarded_capabilities_treats_explicit_open_as_reviewed_not_unguarded_test() ->
    %% auth => open and no auth key at all advertise identically
    %% (macula:advertise/5 treats them the same), but only the latter
    %% is a decision nobody actually made yet.
    ?assertEqual([],
                 mcl_om_capabilities:unguarded_capabilities(
                   [#{name => <<"svc.read">>, version => 1,
                      handler => {my_mod, []}, auth => open}])).

%%% A capability opts into being advertised via macula_streamer instead
%%% of macula_response with `kind => streamer' -- absent (every
%%% capability declared before this existed) it's macula_response,
%%% unchanged. `stream_opts' only ever applies to the streamer branch.

provider_module_is_macula_response_by_default_test() ->
    ?assertEqual(macula_response,
                 mcl_om_capabilities:provider_module(
                   #{name => <<"svc.do">>, version => 1,
                     handler => {my_mod, []}})).

provider_module_is_macula_streamer_when_the_capability_opts_in_test() ->
    ?assertEqual(macula_streamer,
                 mcl_om_capabilities:provider_module(
                   #{name => <<"svc.watch">>, version => 1,
                     handler => {my_mod, []}, kind => streamer})).

stream_opts_is_absent_for_a_response_kind_capability_test() ->
    ?assertEqual(#{}, mcl_om_capabilities:stream_opts(
                         #{name => <<"svc.do">>, version => 1,
                           handler => {my_mod, []},
                           stream_opts => #{mode => client_stream}})).

stream_opts_carries_the_streamer_capabilitys_own_opts_test() ->
    ?assertEqual(#{mode => client_stream},
                 mcl_om_capabilities:stream_opts(
                   #{name => <<"svc.watch">>, version => 1,
                     handler => {my_mod, []}, kind => streamer,
                     stream_opts => #{mode => client_stream}})).

stream_opts_is_absent_for_a_streamer_capability_with_none_set_test() ->
    ?assertEqual(#{}, mcl_om_capabilities:stream_opts(
                         #{name => <<"svc.watch">>, version => 1,
                           handler => {my_mod, []}, kind => streamer})).

%%% Republish jitter (found live 2026-09-01) — a perfectly fixed 30s
%%% republish period can permanently lose a race against a station-side
%%% cooldown of the same length (macula_remote_advertise_registry's
%%% tombstone TTL, deliberately 30s for its own gossip-convergence
%%% reasons — see that module's history). republish_delay_ms/0 must
%%% actually vary, not just be renamed, or the fix is a no-op.

republish_delay_ms_stays_within_the_jittered_bound_test() ->
    Delays = [mcl_om_capabilities:republish_delay_ms() || _ <- lists:seq(1, 200)],
    ?assert(lists:all(fun(D) -> D >= 27_000 andalso D =< 33_000 end, Delays)).

republish_delay_ms_actually_varies_test() ->
    Delays = [mcl_om_capabilities:republish_delay_ms() || _ <- lists:seq(1, 200)],
    ?assert(sets:size(sets:from_list(Delays)) > 1).

%%% gen_server + graceful degradation (no mesh) — this is the path that
%%% actually runs at boot before a pool/keypair are present. Exercises
%%% init, register/publish/lookup/list, and the no-op / empty degradation.

gen_server_degrades_without_mesh_test_() ->
    {setup, fun start_servers/0, fun stop_servers/1,
     fun(_) ->
        Cap = #{name => <<"svc.do">>, version => 1},
        %% A handler-bearing capability must degrade exactly the same
        %% way — advertise_direct is never even reached with no
        %% pool/keypair/realm, same as the legacy put_record path.
        HandlerCap = #{name => <<"svc.answer">>, version => 1,
                       handler => {?MODULE, []}},
        [
         %% register + publish must not crash when there is no pool /
         %% keypair / realm — they no-op and the timer retries later.
         ?_assertEqual(ok, mcl_om_capabilities:register([Cap, HandlerCap])),
         ?_assertEqual(ok, mcl_om_capabilities:publish()),
         %% own caps are still reported (used by /health + the SUITE)
         ?_assertEqual([Cap, HandlerCap], mcl_om_capabilities:list()),
         %% resolution with no pool yields an empty set, not a crash
         ?_assertEqual({ok, []}, mcl_om_capabilities:lookup(<<"svc.do">>)),
         %% and identity reports the missing signing key cleanly
         ?_assertEqual({error, no_keypair}, mcl_om_identity:keypair()),
         %% call_capability with no pool degrades, does not crash
         ?_assertEqual({error, not_configured},
                       mcl_om_capabilities:call_capability(<<"acme">>,
                                                              <<"svc.do">>,
                                                              #{}, 1_000, #{}))
        ]
     end}.

start_servers() ->
    {ok, I} = mcl_om_identity:start_link(),
    {ok, C} = mcl_om_capabilities:start_link(),
    {I, C}.

stop_servers({I, C}) ->
    try gen_server:stop(C) catch _:_ -> ok end,
    try gen_server:stop(I) catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% Live pool, zero seeds — reaches the real macula_response:advertise_direct
%%% boundary without a station. Same technique as mcl_om_pubsub_tests:
%%% macula_client:connect([], #{}) gives a real pool with zero spawned
%%% links, so macula:advertise/5 (which advertise_direct calls first)
%%% genuinely returns {error, no_healthy_station} from the SDK itself —
%%% proving the wiring reaches macula_response correctly, even though it
%%% can't succeed without a real station to register with. The stronger
%%% claim -- a handler-bearing capability is genuinely CALLABLE end to
%%% end -- needs a real macula-station and is NOT covered here; see the
%%% plan doc's acceptance note for piece B.
%%%===================================================================

live_pool_handler_capability_test_() ->
    {timeout, 15,
     {setup, fun start_live/0, fun stop_live/1,
      fun(_) ->
         Cap = #{name => <<"svc.answer">>, version => 1,
                handler => {?MODULE, []}},
         [
          {"register with a handler-bearing capability reaches the SDK "
           "boundary and degrades cleanly with no healthy station",
           fun() ->
              ?assertEqual(ok, mcl_om_capabilities:register([Cap]))
           end},
          {"a second tick (simulating the 30s republish timer) is just "
           "as stable -- proves repeated failed advertise_direct calls "
           "don't accumulate state or crash the worker",
           fun() ->
              ?assertEqual(ok, mcl_om_capabilities:publish()),
              ?assertEqual(ok, mcl_om_capabilities:publish())
           end}
         ]
      end}}.

init(_Args) -> {ok, []}.
handle_request(_Payload, State) -> {reply, ok, State}.
handle_open(_StreamArgs, State) -> {ok, State}.

%%%===================================================================
%%% Same live-pool, zero-seeds technique as live_pool_handler_capability_test_/0,
%%% for a `kind => streamer' capability: proves advertise_one/6 dispatches
%%% to macula_streamer:advertise_direct (not macula_response) and reaches
%%% the real SDK boundary, degrading the same way with no station.
%%%===================================================================

live_pool_streamer_capability_test_() ->
    {timeout, 15,
     {setup, fun start_live/0, fun stop_live/1,
      fun(_) ->
         Cap = #{name => <<"svc.watch">>, version => 1,
                handler => {?MODULE, []}, kind => streamer},
         [
          {"register with a streamer-kind capability reaches macula_streamer's "
           "advertise_direct and degrades cleanly with no healthy station",
           fun() ->
              ?assertEqual(ok, mcl_om_capabilities:register([Cap]))
           end},
          {"a second tick is just as stable for the streamer path too",
           fun() ->
              ?assertEqual(ok, mcl_om_capabilities:publish()),
              ?assertEqual(ok, mcl_om_capabilities:publish())
           end}
         ]
      end}}.

%%%===================================================================
%%% Regression test for the crash-cascade bug found live 2026-09-01
%%% (hecate-rag): one capability's `advertise_direct' call raising (the
%%% real incident was a `gen_server:call' timeout against the station
%%% link) used to crash the whole `mcl_om_capabilities' process
%%% before it could register any OTHER capability in the same batch --
%%% and, via `macula_response'/`macula_streamer' linking each factory
%%% supervisor to this process, killed every already-healthy sibling
%%% supervisor too. `advertise_one_safely/7' isolates one capability's
%%% failure instead. Same live-pool-zero-seeds technique as
%%% live_pool_handler_capability_test_/0, with `macula_response:
%%% advertise_direct/7' meck'd to raise for one specific capability
%%% while the other still reaches the real (station-less) SDK boundary.
%%%===================================================================

advertise_one_timeout_test_() ->
    {timeout, 15,
     {setup, fun start_live/0, fun stop_live/1,
      fun(_) ->
         Ok   = #{name => <<"svc.answer">>, version => 1, handler => {?MODULE, []}},
         Boom = #{name => <<"svc.ingest">>, version => 1, handler => {?MODULE, []}},
         [
          {"a capability whose advertise_direct call raises does not "
           "crash the registration process or block its siblings",
           fun() ->
              Pid = whereis(mcl_om_capabilities),
              %% No [passthrough]: the real advertise_direct/7 would
              %% just return {error, no_healthy_station} in this
              %% zero-seed test pool anyway (see
              %% live_pool_handler_capability_test_/0), so a plain stub
              %% for BOTH branches proves the isolation without needing
              %% meck's passthrough (which needs debug_info this
              %% dependency build doesn't carry).
              ok = meck:new(macula_response, []),
              ok = meck:expect(macula_response, advertise_direct,
                    fun(_Pool, _Realm, Proc, _Mod, _Args, _Kp, _Opts) ->
                       advertise_direct_stub(Proc)
                    end),
              ?assertEqual(ok, mcl_om_capabilities:register([Ok, Boom])),
              ?assert(is_process_alive(Pid)),
              ?assertEqual(Pid, whereis(mcl_om_capabilities)),
              meck:unload(macula_response)
           end}
         ]
      end}}.

%% `Proc' is `Name' or `org_procedure(Org, Name)' depending on which of
%% advertise_one/7's two calls this is -- match on substring so either
%% form triggers the same simulated timeout for the "boom" capability;
%% the other capability gets a plain, valid-looking {ok, Sup} so the
%% test proves it registers normally alongside the failing one.
advertise_direct_stub(Proc) ->
    advertise_direct_stub(Proc, binary:match(Proc, <<"svc.ingest">>)).

advertise_direct_stub(Proc, {_, _}) ->
    exit({timeout, {gen_server, call,
                    [self(), {advertise, Proc, fake_handler, open}, 5000]}});
advertise_direct_stub(_Proc, nomatch) ->
    {ok, self()}.

start_live() ->
    {ok, _} = application:ensure_all_started(macula),
    {ok, Pool} = macula_client:connect([], #{}),
    Realm = crypto:strong_rand_bytes(32),
    KeyPair = macula_identity:generate(),
    %% A real mcl_om_identity too -- do_advertise/2 also calls org/0
    %% and cert_chain/0, which passthrough would otherwise route to a
    %% real gen_server:call with nothing registered to answer it.
    {ok, I} = mcl_om_identity:start_link(),
    ok = meck:new(mcl_om_identity, [passthrough]),
    ok = meck:expect(mcl_om_identity, macula_client, fun() -> {ok, Pool} end),
    ok = meck:expect(mcl_om_identity, realm, fun() -> {ok, Realm} end),
    ok = meck:expect(mcl_om_identity, keypair, fun() -> {ok, KeyPair} end),
    {ok, C} = mcl_om_capabilities:start_link(),
    {I, Pool, C}.

stop_live({I, Pool, C}) ->
    try gen_server:stop(C) catch _:_ -> ok end,
    meck:unload(mcl_om_identity),
    try gen_server:stop(I) catch _:_ -> ok end,
    try macula_client:close(Pool) catch _:_ -> ok end,
    ok.

%%% Minimal in-process X.509 CA (realm CA -> org CA -> Ed25519 leaf
%%% binding `LeafPub', O=`Org'). Returns the trusted realm CA PEM and the
%%% leaf-first [leaf, org CA] PEM bundle a service embeds.
issue_chain(LeafPub, Org) ->
    {RealmPub, RealmPriv} = ca_key(),
    {OrgPub, OrgPriv}     = ca_key(),
    RealmSubj = subject(<<"io.macula">>, <<"io.macula">>),
    OrgSubj   = subject(<<"io.macula.", Org/binary>>, Org),
    LeafSubj  = subject(<<"mri:app:io.macula/", Org/binary, "/svc">>, Org),
    RealmDer = sign_cert(RealmSubj, ed_spki(RealmPub), RealmSubj, RealmPriv, true),
    OrgDer   = sign_cert(OrgSubj, ed_spki(OrgPub), RealmSubj, RealmPriv, true),
    LeafDer  = sign_cert(LeafSubj, ed_spki(LeafPub), OrgSubj, OrgPriv, false),
    #{realm_ca => pem([RealmDer]), chain => pem([LeafDer, OrgDer])}.

ca_key() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    {Pub, #'ECPrivateKey'{version = 1, privateKey = Priv,
                          parameters = {namedCurve, ?'id-Ed25519'},
                          publicKey = Pub}}.

ed_spki(Pub) ->
    #'OTPSubjectPublicKeyInfo'{
       algorithm = #'PublicKeyAlgorithm'{algorithm = ?'id-Ed25519',
                                         parameters = asn1_NOVALUE},
       subjectPublicKey = #'ECPoint'{point = Pub}}.

subject(CN, O) ->
    {rdnSequence,
     [[#'AttributeTypeAndValue'{type = {2, 5, 4, 3}, value = {utf8String, CN}}],
      [#'AttributeTypeAndValue'{type = {2, 5, 4, 10}, value = {utf8String, O}}]]}.

sign_cert(Subject, Spki, IssuerSubject, IssuerKey, IsCA) ->
    TBS = #'OTPTBSCertificate'{
             version = v3,
             serialNumber = rand:uniform(1 bsl 60),
             signature = #'SignatureAlgorithm'{algorithm = ?'id-Ed25519',
                                               parameters = asn1_NOVALUE},
             issuer = IssuerSubject,
             validity = #'Validity'{notBefore = {utcTime, "230101000000Z"},
                                    notAfter  = {utcTime, "330101000000Z"}},
             subject = Subject,
             subjectPublicKeyInfo = Spki,
             extensions = [basic_constraints(IsCA)]},
    public_key:pkix_sign(TBS, IssuerKey).

basic_constraints(IsCA) ->
    #'Extension'{extnID = ?'id-ce-basicConstraints', critical = true,
                 extnValue = #'BasicConstraints'{cA = IsCA,
                                                 pathLenConstraint = asn1_NOVALUE}}.

pem(Ders) ->
    public_key:pem_encode([{'Certificate', D, not_encrypted} || D <- Ders]).
