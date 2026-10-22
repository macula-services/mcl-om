%%% @doc The one way to test a capability: deliver the request the way a
%%% station does, then read the reply the way a client does (mcl-om#31).
%%%
%%% WHY THIS EXISTS. mcl-chess 0.7.1 passed 206 eunit tests and refused every
%%% real call on the live mesh (mcl-chess#10). Its handlers read
%%% `maps:get(<<"key">>, Payload, ...)', and on this wire no payload looks like
%%% that: every text key arrives as `{text, Bin}', and the verified caller
%%% arrives under the ATOM key as a raw 32-byte node id. Its tests built the
%%% request by hand in the shape the handler expected, so they agreed with the
%%% handler and disagreed with the wire. A reply has the mirror hazard: a plain
%%% binary is a CBOR BYTE string, so a `game_id' sent that way reaches a client
%%% as an opaque blob, and 32 raw bytes tagged as text are refused outright
%%% because CBOR text must be UTF-8.
%%%
%%% WHAT IT DOES, in the order the mesh does it:
%%%
%%% 1. the request is encoded with `macula_record_cbor:encode/1' and decoded
%%%    with `macula_frame:plain_payload/1', which is the provider's own path,
%%%    so the handler sees exactly what a station hands it;
%%% 2. the verified caller is merged the way macula_station_link's own
%%%    `with_caller/2' merges it, including dropping a caller-sent text
%%%    `caller' (a peer that
%%%    names itself is not read);
%%% 3. the handler runs inside the request's caller context, the way
%%%    `macula_station_link' runs it, so a handler reading
%%%    `macula_response:caller/0' is tested on the path a station gives it;
%%% 4. the reply is put through `macula_frame:check_payload/1', the same check a
%%%    provider runs before answering, so a reply macula would refuse fails the
%%%    TEST rather than the first real caller;
%%% 5. the reply is encoded and decoded again and handed back as the client's
%%%    own view: text unwraps to its `Bin', and a byte string stays named as
%%%    one, `{bytes, Bin}', so an assertion that expects text fails on bytes
%%%    rather than reading the two as the same value (mcl-om#32).
%%%
%%% WHAT IT DOES NOT DO. It does not sign, dial, or check the D25 grant: this is
%%% the payload contract, not the mesh integration (mcl_om_SUITE is that). It
%%% does not know which caller a service considers authorised, it only makes
%%% sure the handler is handed one at all.
%%%
%%% THE CALLER IS RAW. A node id is 32 bytes on the wire; a handler that stores
%%% or republishes it wants the 64-character hex form and gets it from
%%% `mcl_om_wire:caller_hex/1'. Passing hex here would hide the fault this
%%% helper exists to catch, so a 64-character caller is refused rather than
%%% accepted.
-module(mcl_om_wire_test).

-include_lib("macula/include/macula_caller.hrl").

-export([call/3, deliver/2, reply/1]).

%% How a test author writes a request: atom or binary keys, strings as
%% binaries, numbers as numbers. `{text, Bin}' and `{bytes, Bin}' are passed
%% through for the cases where the distinction is the point.
-type authored() :: #{term() => term()}.

-type client_view() :: map().

%% What a client's CALL comes back with: the reply it reads, or the provider
%% refusing it.
-type call_outcome() :: client_view() | {error, term()}.

%% @doc Call a capability handler as a station would, and answer what the client
%% would see.
%%
%% `Handler' is a `macula_response' module (its `handle_request/2' is called
%% with the state `init/1' returned). `Caller' is the caller's raw 32-byte node
%% id: on a real call the station has verified it and macula injects it, so a
%% test states it here instead of a handler accepting it.
%%
%% TWO KINDS OF REFUSAL, and a caller sees them differently:
%%
%%   * an APPLICATION refusal is a handler answering a reply that says so,
%%     `#{<<"error">> => {text, <<"invalid_color">>}}'. It comes back as a reply
%%     like any other, because that is what the client reads;
%%   * a HANDLER refusal is the behaviour's own `{error, Reason, State}'. macula
%%     answers that with an ERROR frame carrying the reason's name, and the
%%     client's call answers `{error, Detail}', so this returns `{error,
%%     Detail}' too: the reason's text capped at 256 bytes, or
%%     `{call_error, <<"handler_error">>, undefined}' when the reason has no
%%     name to cross with.
%%
%% A reply macula would not put on the wire raises `bad_reply'.
-spec call(module(), authored(), binary()) -> call_outcome().
call(Handler, Request, Caller) ->
    {ok, State} = Handler:init([]),
    Raw = caller(Caller),
    Payload = deliver(Request, Raw),
    answered(in_caller_context(Raw, fun() -> Handler:handle_request(Payload, State) end)).

answered({reply, Reply, _State}) -> reply(Reply);
answered({error, Reason, _State}) -> handler_error(Reason).

%% The handler runs with the request's verified caller in this process's
%% context, exactly as `macula_station_link:caller_context/2' runs it, so
%% `macula_response:caller/0' answers the identity a station authenticated. A
%% payload that is not a map has nowhere else to read a caller from, which is
%% why the link carries it in the process at all (macula#60). Erased after, as
%% the link erases it: a test process serving one call must not hand the
%% identity to the next.
in_caller_context(Caller, Fun) ->
    erlang:put(?CALLER_CONTEXT_KEY, Caller),
    try Fun()
    after erlang:erase(?CALLER_CONTEXT_KEY)
    end.

%% What the caller sees when the handler refused. The link puts the reason's
%% text on an ERROR frame (`handler_error_detail/1' over
%% `macula_reason_name:reply_text/1', at most 256 bytes) and the client's own
%% `call_result/1' answers `{error, Detail}'. A reason with no name writes no
%% detail field at all, so the client falls through to the generic error it
%% builds for an unnamed code.
handler_error(Reason) ->
    case macula_reason_name:reply_text(Reason) of
        {ok, Detail} -> {error, Detail};
        error -> {error, {call_error, <<"handler_error">>, undefined}}
    end.

%% @doc The payload the handler is handed for this request: what a station
%% delivers, caller merged in. Use it only to assert on the shape itself; a test
%% that wants an answer calls `call/3'.
-spec deliver(authored(), binary()) -> map().
deliver(Request, Caller) when is_map(Request) ->
    Payload = decoded(encoded(on_the_wire(Request))),
    with_caller(Payload, caller(Caller)).

%% @doc The reply as a client receives it, after the check a provider runs
%% before answering. Text arrives as its `Bin'; a CBOR byte string arrives as
%% `{bytes, Bin}', because a client would get bytes and a test that read them as
%% text could not tell a regression from a correct answer (mcl-om#32).
-spec reply(term()) -> client_view().
reply(Reply) ->
    ok = checked(Reply),
    unwrapped(encoded(frame_wire(Reply))).

%% THE TWO DIRECTIONS DO NOT CONVERT THE SAME WAY, and that is the wire's own
%% asymmetry, not a convenience of this module.
%%
%% A REQUEST comes from a JSON client: macula-mcp and the SDKs send a string as
%% CBOR text, so a test author writing `<<"e2e4">>' gets `{text, <<"e2e4">>}' and
%% a handler that expects text is tested against text. A KEY is always text,
%% because the strict decoder refuses anything else.
%%
%% A REPLY is the provider's own terms, and macula converts them with
%% `macula_frame:to_wire/1': atoms become text, `undefined' becomes null, map
%% keys become text, and A PLAIN BINARY STAYS A BYTE STRING. That last one is
%% how a service can answer `game_id' as an opaque blob to every client while
%% its own tests assert on the string, so this module reproduces it rather than
%% smoothing it over: which is why the client view names a byte string
%% `{bytes, Bin}' instead of handing back a `Bin' no different from text.

%% A test author writes atoms and strings; a JSON client sends text. A BOOLEAN
%% IS REFUSED rather than translated: the mesh carries 1/0, and a helper that
%% quietly rewrote `true' would let a handler be written against a value no
%% client can send.
on_the_wire(Map) when is_map(Map) ->
    maps:from_list([{wire_key(Key), wire_value(Value)} || {Key, Value} <- maps:to_list(Map)]);
on_the_wire(List) when is_list(List) ->
    [wire_value(Element) || Element <- List];
on_the_wire(true) ->
    erlang:error({wire_carries_no_booleans, true, use_1_or_0});
on_the_wire(false) ->
    erlang:error({wire_carries_no_booleans, false, use_1_or_0});
on_the_wire(Atom) when is_atom(Atom) ->
    {text, atom_to_binary(Atom, utf8)};
on_the_wire(Bin) when is_binary(Bin) ->
    {text, Bin};
on_the_wire(Other) ->
    Other.

wire_key(Key) when is_atom(Key) -> {text, atom_to_binary(Key, utf8)};
wire_key({text, _} = Key) -> Key;
wire_key(Bin) when is_binary(Bin) -> {text, Bin};
wire_key(Integer) when is_integer(Integer) -> Integer.

%% An element inside a list is a value like any other, so it converts as one:
%% a `{bytes, Bin}' nested in a list is the bytes, not a tuple the encoder
%% would refuse.
wire_value({text, _} = Value) -> Value;
wire_value({bytes, Bin}) when is_binary(Bin) -> Bin;
wire_value(List) when is_list(List) -> [wire_value(Element) || Element <- List];
wire_value(Value) -> on_the_wire(Value).

%% macula_frame:to_wire/1 and its wire_key/1, reproduced because neither is
%% exported. A divergence here would be a bug in this helper, not a difference
%% of opinion: the point is to hand the client what macula would have encoded.
frame_wire(Map) when is_map(Map) ->
    maps:fold(fun(Key, Value, Acc) -> Acc#{wire_key(Key) => frame_wire(Value)} end, #{}, Map);
frame_wire(List) when is_list(List) ->
    [frame_wire(Element) || Element <- List];
frame_wire(undefined) -> null;
frame_wire(Atom) when is_atom(Atom) -> {text, atom_to_binary(Atom, utf8)};
frame_wire({text, Bin} = Text) when is_binary(Bin) -> Text;
frame_wire(Bin) when is_binary(Bin) -> Bin;
frame_wire(Integer) when is_integer(Integer) -> Integer;
frame_wire(Other) -> Other.

%% The provider's own decode path, so the handler is handed the shape a station
%% produces and not one this module invented.
encoded(Term) ->
    macula_record_cbor:encode(Term).

decoded(Bytes) ->
    {ok, Payload} = macula_frame:plain_payload(Bytes),
    Payload.

%% `macula_frame:check_payload/1' is what a provider runs before answering: it
%% refuses a `{text, _}' that is not UTF-8, a nesting depth no decoder accepts,
%% and a size past the frame's own limit. A reply that fails it here would fail
%% for the first real caller as `unknown_error', with nothing to act on.
checked(Reply) ->
    case macula_frame:check_payload(Reply) of
        ok -> ok;
        {error, Reason} -> erlang:error({bad_reply, Reason})
    end.

%% The client's view: decoded, then unwrapped, so a `{text, <<"w">>}' is
%% `<<"w">>' and a test asserts on what it means rather than on the codec.
%% `mcl_om_wire:unwrap/1' unwraps VALUES only (a handler reads a key through
%% `field/2', never as a term), so keys are unwrapped here: a client sees map
%% keys as the text they are.
unwrapped(Bytes) ->
    {ok, Value} = macula_record_cbor:decode_strict(Bytes),
    client_view(Value).

%% TEXT AND BYTES DO NOT COME OUT THE SAME, which is the whole point of reading a
%% reply here instead of in the reply's own terms (mcl-om#32). The strict decoder
%% answers `{text, Bin}' for CBOR text and a PLAIN `Bin' for CBOR bytes, so a
%% test can tell them apart only if this function keeps them apart: text unwraps
%% to `Bin', and a bare binary is named for what the client got, `{bytes, Bin}'.
%% Unwrapping both to `Bin' made a responder that regressed a field to bytes pass
%% every test, which is the mirror of the fault this module was built for, and it
%% is why the request side already authors a byte string as `{bytes, Bin}'.
client_view(Map) when is_map(Map) ->
    maps:from_list([{client_key(Key), client_view(Value)} || {Key, Value} <- maps:to_list(Map)]);
client_view(List) when is_list(List) ->
    [client_view(Element) || Element <- List];
client_view(Bin) when is_binary(Bin) ->
    {bytes, Bin};
client_view(Value) ->
    mcl_om_wire:unwrap(Value).

client_key({text, Bin}) -> Bin;
client_key(Key) -> mcl_om_wire:unwrap(Key).

%% The raw node id, and nothing else. macula verifies CALL callers and merges
%% the raw id; a hex caller here would pass a handler that forgets to hex it,
%% which is the mcl-chess#10 fault this helper exists to catch.
caller(Caller) when is_binary(Caller), byte_size(Caller) =:= 32 ->
    Caller;
caller(Caller) ->
    erlang:error({caller_must_be_a_raw_32_byte_node_id, Caller}).

%% Copied from macula_station_link:with_caller/2 on purpose: that function is
%% not exported, and a helper that guessed at its rule would be the very thing
%% this module is fixing. A caller-sent text `caller' is dropped, because what a
%% handler reads as `caller' must be the verified identity and never a claim.
with_caller(Payload, Caller) when is_map(Payload) ->
    (maps:remove({text, <<"caller">>}, Payload))#{caller => Caller}.
