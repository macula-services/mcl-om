%% @doc Admissions for the sealed-group subscription tests, and the canary
%% they all look for.
%%
%% The CANARY is what makes a leak testable: it is a token-shaped binary
%% that no correct path ever puts in a child spec, a failure reason or a
%% report, so finding it anywhere is finding the token where it must not
%% be. `raising/0' is the shape that matters most -- an admission that has
%% read its token and then crashed holding it, which is exactly how a
%% naively reported reason would carry the token into a crash report.
-module(sealed_group_admission).

-export([canary/0, token/0, missing/0, raising/0, not_a_token/0, not_a_pair/0]).

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

-spec not_a_token() -> {ok, atom()}.
not_a_token() -> {ok, not_a_binary}.

-spec not_a_pair() -> ok.
not_a_pair() -> ok.
