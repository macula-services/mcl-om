%% @doc Admissions for the sealed-group subscription tests, and the canary
%% they all look for.
%%
%% The CANARY is what makes a leak testable: it is a token-shaped binary
%% that no correct path ever puts in a child spec, a failure reason or a
%% report, so finding it anywhere is finding the token where it must not
%% be. `raising/0' and `refused_with_token/0' are the two shapes that
%% matter most -- an admission that has read its token and then either
%% crashed holding it or refused with it in the reason, which is exactly
%% how a naively reported reason would carry the token into a log line or
%% `/health'.
-module(sealed_group_admission).

-export([canary/0, token/0, missing/0, raising/0, not_a_token/0, not_a_pair/0,
         refused_with_token/0, count/1]).

-spec canary() -> binary().
canary() -> <<"CANARY-admission-token-do-not-print">>.

-spec token() -> {ok, binary()}.
token() -> {ok, canary()}.

-spec missing() -> {error, atom()}.
missing() -> {error, no_admission_token}.

%% Reads the token and then fails on it: the reason a brute-force
%% implementation would echo straight into the supervisor's report.
-spec raising() -> no_return().
raising() -> error({badmatch, canary()}).

%% Refuses with a TUPLE that carries the token, the shape a real admission
%% takes when the keyring says the token it just read has expired. The
%% atom is passed through by mcl_om; a term is not, because this one is
%% where the token would ride out.
-spec refused_with_token() -> {error, {atom(), binary()}}.
refused_with_token() -> {error, {expired, canary()}}.

%% Answers a token and tells `Pid' it was called, so a test can count the
%% calls: once per subscribe attempt, never on a tick that finds the
%% subscriber running.
-spec count(pid()) -> {ok, binary()}.
count(Pid) -> Pid ! {admission_called, self()}, {ok, canary()}.

-spec not_a_token() -> {ok, atom()}.
not_a_token() -> {ok, not_a_binary}.

-spec not_a_pair() -> ok.
not_a_pair() -> ok.
