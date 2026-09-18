%%% @doc Tolerant field lookup on a decoded mesh payload map (RPC/stream
%%% `args', or a pubsub event payload), instead of every provider desk
%%% re-solving the same two gotchas independently.
%%%
%%% Gotcha one -- KEYS: macula's frame decoder round-trips a payload's
%%% keys through `binary_to_existing_atom/1' on the way in, so a caller
%%% that sent binary keys can find them waiting as atoms on the other
%%% side. A key whose atom does not exist in the receiving VM stays as it
%%% was sent instead: `{text, Bin}', since macula encodes every map key
%%% as CBOR text (`macula_frame''s `wire_key/1' and `envelope_key/1'), or
%%% a plain binary from a sender that used a byte-string key. Three
%%% incompatible ways of coping with this were already live
%%% in the workspace when this was written (see
%%% `hecate-om/plans/PLAN_MCL_OM_MESH_WRAPPERS.md', piece F):
%%% `hecate-embedder' tries the atom form first, falling back to binary;
%%% `hecate-spartan' reimplements the same fallback (`mget/2,3') 11+
%%% times across its `federation_*' modules for pubsub payloads, not
%%% just RPC args; and `hecate-dns'/`-git'/`-llm'/`-rag''s `route/2'
%%% handlers pattern-match binary keys only, with zero tolerance —
%%% silently wrong if a real caller's payload ever arrives atom-keyed.
%%%
%%% Gotcha two -- VALUES, found live 2026-09-01 fixing hecate-rag: a
%%% JSON string sent as an RPC arg is encoded as a CBOR text string
%%% (major type 3), which `macula_record_cbor''s own documented value
%%% representation decodes to `{text, binary()}', NOT a bare `binary()'
%%% -- a plain binary is reserved for a CBOR BYTE string (major type 2),
%%% a different wire type. Every `is_binary/1' guard and `:: binary()'
%%% field spec in hecate-rag (and any other consumer) assumed the wire
%%% delivers plain binaries for a text field; every one of them silently
%%% failed to match a real caller's payload instead, indistinguishable
%%% from a missing field. This one recurses: a list of strings decodes
%%% to a list of `{text, _}' tuples, and a list of maps (e.g. a caller
%%% round-tripping a prior response's hits back in) decodes to maps
%%% whose OWN values need the identical unwrap.
%%%
%%% `field/2,3' accepts either an atom or a binary key literal, whichever
%%% the caller naturally reaches for. Either way the atom form is tried
%%% first (the confirmed-live shape for both RPC/stream args and pubsub
%%% payloads, piece C/D's own live tests), then the binary form, then
%%% `{text, Bin}'. Whatever value is found (or the caller's own
%%% `Default') is run through `unwrap/1' before returning, so both
%%% gotchas are resolved in one call regardless of which one a given
%%% field happens to hit.
%%%
%%% `retryable/1' (piece G) is the response-side counterpart: whether a
%%% failed RPC/stream call outcome is worth retrying, per macula's own
%%% published BOLT#4 retry policy. `hecate-tom-player''s `tom_wire_
%%% macula.erl' was, before this, the one place in the workspace doing
%%% this at all -- asking `macula_bolt4:is_retryable/1' rather than
%%% keeping a second copy of its code table locally, which would rot
%%% the moment BOLT#4 grows a code.
-module(mcl_om_wire).

-export([field/2, field/3, unwrap/1]).
-export([retryable/1]).
-export([caller/1]).

%% @equiv field(Key, Payload, undefined)
-spec field(atom() | binary(), map()) -> term().
field(Key, Payload) ->
    field(Key, Payload, undefined).

%% @doc Look up `Key' in `Payload', trying its atom, binary and
%% `{text, Bin}' forms in that order regardless of which one the caller
%% passed in, and unwrapping whatever value is found (see `unwrap/1').
%% Returns `unwrap(Default)' if no form is present, a no-op for the
%% plain Erlang term a caller's own literal `Default' almost always
%% already is.
-spec field(atom() | binary(), map(), term()) -> term().
field(Key, Payload, Default) when is_atom(Key) ->
    BinKey = atom_to_binary(Key, utf8),
    lookup([Key, BinKey, {text, BinKey}], Payload, Default);
field(Key, Payload, Default) when is_binary(Key) ->
    lookup([existing_atom(Key), Key, {text, Key}], Payload, Default).

%% The first key form present in `Payload' wins.
lookup([], _Payload, Default) ->
    unwrap(Default);
lookup([Key | Rest], Payload, Default) ->
    found(maps:find(Key, Payload), Rest, Payload, Default).

found({ok, Value}, _Rest, _Payload, _Default) -> unwrap(Value);
found(error, Rest, Payload, Default) -> lookup(Rest, Payload, Default).

%% @doc Recursively unwrap `macula_record_cbor''s wire-level value
%% representation into the plain Erlang terms a handler actually wants
%% to pattern-match or guard against. `{text, Bin}' (CBOR text string,
%% major type 3 -- see that module's own moduledoc for the full value()
%% table) unwraps to `Bin' — through list elements and map values, so a
%% `topics :: [binary()]' field or a `hits :: [map()]' field round-trips
%% correctly, not just a flat top-level field. `null' (CBOR major 7/22)
%% unwraps to `undefined', matching every existing "absent field"
%% convention in this codebase rather than leaking a wire-protocol atom
%% no caller ever chose. A plain `binary()' (CBOR BYTE string, major
%% type 2) passes through untouched -- it is already the shape a caller
%% wants; unwrapping only ever undoes major type 3's wrapping. Exported
%% as a pure helper: usable directly on an already-extracted nested
%% value `field/2,3' never sees (e.g. a hit map recovered from inside a
%% list), not just internally by this module.
-spec unwrap(term()) -> term().
unwrap({text, Bin}) when is_binary(Bin) -> Bin;
unwrap(null) -> undefined;
unwrap(List) when is_list(List) -> [unwrap(V) || V <- List];
unwrap(Map) when is_map(Map) -> maps:map(fun(_K, V) -> unwrap(V) end, Map);
unwrap(Other) -> Other.

%% @doc The identity that made this RPC call, or `undefined' if the
%% connected macula doesn't thread it yet (pre-10.15.0 -- macula's own
%% CHANGELOG explains why it took until then) or if this payload didn't
%% arrive via an RPC path at all (a pubsub event's caller-equivalent is
%% `publisher', delivered via a separate Meta argument, not the payload).
%%
%% Just `field(caller, Payload)' under a name every desk that wants
%% provenance can reach for instead of re-deciding the field name --
%% the same reasoning `field/2,3''s own moduledoc gives for existing as
%% a shared helper rather than N per-desk reimplementations.
-spec caller(map()) -> binary() | undefined.
caller(Payload) ->
    field(caller, Payload).

%% `binary_to_existing_atom/2' raises for a binary with no atom form
%% anywhere in the VM yet. `Key' is a literal the calling handler wrote,
%% so its atom form almost always already exists -- but "almost always"
%% isn't a guarantee this module gets to lean on, so a miss here just
%% falls through to `undefined', same as any other absent key, rather
%% than crashing the handler over a decode-convenience lookup.
existing_atom(Bin) ->
    try binary_to_existing_atom(Bin, utf8) catch error:badarg -> undefined end.

%% @doc Whether a failed RPC/stream call outcome is worth retrying.
%%
%% `{error, {call_error, Code, _Name}}' is macula's own documented
%% outcome shape for a CALL failure (`macula_station_link.erl''s own
%% doc table), not a caller-specific convention -- covers `macula:
%% call/5', `call_station/6,7,8', and `mcl_om_capabilities:
%% call_capability/5,7' uniformly. A success, or an error macula
%% didn't code-classify at all (a raw `catch', a timeout), has nothing
%% for the BOLT#4 table to say, so those are decided directly here
%% rather than delegated.
-spec retryable({ok, term()} | {error, term()} | {'EXIT', term()}) ->
    boolean().
retryable({ok, _Reply}) ->
    false;
retryable({error, {call_error, Code, _Name}}) ->
    bolt4_retryable(Code);
retryable({error, _Reason}) ->
    true;
retryable({'EXIT', _Reason}) ->
    true.

%% An unrecognized code raises INSIDE macula_bolt4:is_retryable/1
%% itself (an unknown-code lookup errors, it doesn't return `false') --
%% a real possibility across a protocol version skew, not defensive
%% paranoia. Treated as retryable rather than as a reason to abandon a
%% call outright over a code this build doesn't recognize yet.
bolt4_retryable(Code) ->
    try macula_bolt4:is_retryable(Code)
    catch _:_ -> true
    end.
