%%% @doc The stage behaviour the inbound guard pipeline runs per request,
%%% in order.
%%%
%%% A stage is a small module answering ONE question about an inbound
%%% call: pass it on, or deny it. The pipeline (mcl_om_guard_pipeline)
%%% is the only caller, in the fixed order its wrapper names; a stage
%%% never calls another stage, and the request context is read-only.
%%%
%%% The stages are FIXED ORDER, not arbitrary composition -- size first
%%% (the cheapest refusal), then rate -- a chain of two well-understood
%%% stages, deliberately not a user-composable one (mcl-om#13).
-module(mcl_om_guard_stage).

-type ctx() :: #{procedure := binary(),
                 limits := map(),
                 caller := binary() | '$global'}.
-type verdict() :: pass | {deny, term()}.

-export_type([ctx/0, verdict/0]).

-callback check(term(), ctx()) -> verdict().
