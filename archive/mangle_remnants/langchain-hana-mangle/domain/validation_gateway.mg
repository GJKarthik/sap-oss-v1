# ============================================================
# Validation Gateway for LLM Fact Injection
# Blanket AI Safety Governance - Neuro-Symbolic Integration
# 
# This file implements the validation gateway that prevents
# LLM-generated facts from poisoning the deductive knowledge base.
# This is the critical G1 safety gap mitigation from the paper.
#
# Reference: safety-ndeductivedatabase-mangle.pdf Section XIII-XVI
# ============================================================

# Package declaration
package validation_gateway;

# ------------------------------------------------------------
# PREDICATE WHITELIST
# ------------------------------------------------------------
# Only these predicates can be asserted by LLM-generated facts.
# Safety-critical predicates (safety_gate, model, safe_*) are
# explicitly excluded to prevent the G1 exploit.

# Allowed predicates for LLM injection (operational facts only)
llm_allowed_predicate("store_backend").
llm_allowed_predicate("inference_result").
llm_allowed_predicate("inference_request").
llm_allowed_predicate("hana_vector_upserted").
llm_allowed_predicate("objectstore_object_put").
llm_allowed_predicate("embedding_computed").
llm_allowed_predicate("token_count").
llm_allowed_predicate("latency_recorded").
llm_allowed_predicate("user_feedback").
llm_allowed_predicate("session_event").
llm_allowed_predicate("query_log").

# Explicitly BLOCKED predicates (security-critical)
llm_blocked_predicate("model").
llm_blocked_predicate("model_capability").
llm_blocked_predicate("model_loaded").
llm_blocked_predicate("safety_benchmark").
llm_blocked_predicate("safety_gate").
llm_blocked_predicate("safety_case").
llm_blocked_predicate("safety_property").
llm_blocked_predicate("safe_model").
llm_blocked_predicate("safe_genai").
llm_blocked_predicate("model_metric").
llm_blocked_predicate("ctq_threshold").
llm_blocked_predicate("odps_rule").
llm_blocked_predicate("odps_compliant").
llm_blocked_predicate("data_product").
llm_blocked_predicate("deployment_spec").
llm_blocked_predicate("api_endpoint").

# ------------------------------------------------------------
# FACT VALIDATION RULES
# ------------------------------------------------------------

# A fact is valid if its predicate is in the whitelist
llm_fact_valid(Predicate, Args) :-
    llm_allowed_predicate(Predicate),
    well_formed_args(Predicate, Args).

# A fact is rejected if its predicate is blocked
llm_fact_rejected(Predicate, "predicate_blocked") :-
    llm_blocked_predicate(Predicate).

# A fact is rejected if its predicate is not in the whitelist
llm_fact_rejected(Predicate, "predicate_not_whitelisted") :-
    not llm_allowed_predicate(Predicate),
    not llm_blocked_predicate(Predicate).

# A fact is rejected if args are malformed
llm_fact_rejected(Predicate, "malformed_args") :-
    llm_allowed_predicate(Predicate),
    not well_formed_args(Predicate, _).

# ------------------------------------------------------------
# ARGUMENT VALIDATION
# ------------------------------------------------------------

# Schema definitions for allowed predicates
predicate_schema("store_backend", 3).  # (id, type, timestamp)
predicate_schema("inference_result", 4).  # (request_id, tokens, latency, status)
predicate_schema("inference_request", 4).  # (request_id, model_id, tokens, timestamp)
predicate_schema("hana_vector_upserted", 2).  # (id, timestamp)
predicate_schema("objectstore_object_put", 2).  # (key, timestamp)
predicate_schema("embedding_computed", 3).  # (id, dimensions, timestamp)
predicate_schema("token_count", 3).  # (request_id, input_tokens, output_tokens)
predicate_schema("latency_recorded", 3).  # (request_id, latency_ms, timestamp)
predicate_schema("user_feedback", 4).  # (request_id, rating, comment, timestamp)
predicate_schema("session_event", 4).  # (session_id, event_type, data, timestamp)
predicate_schema("query_log", 5).  # (query_id, user_id, query, result, timestamp)

# Args are well-formed if they match the schema arity
well_formed_args(Predicate, Args) :-
    predicate_schema(Predicate, Arity),
    fn:length(Args) == Arity.

# ------------------------------------------------------------
# PROVENANCE TRACKING
# ------------------------------------------------------------

# Every fact must have a provenance tag
provenance_source("rule_base").
provenance_source("llm").
provenance_source("external_api").
provenance_source("user_input").
provenance_source("system").

# Provenance-tagged fact
fact_with_provenance(Predicate, Args, Source, Timestamp, Confidence) :-
    provenance_source(Source),
    Timestamp > 0,
    Confidence >= 0.0,
    Confidence =< 1.0.

# Facts from trusted sources have confidence 1.0
trusted_fact(Predicate, Args) :-
    fact_with_provenance(Predicate, Args, "rule_base", _, 1.0).

trusted_fact(Predicate, Args) :-
    fact_with_provenance(Predicate, Args, "system", _, 1.0).

# Facts from LLM have lower confidence
llm_derived_fact(Predicate, Args, Confidence) :-
    fact_with_provenance(Predicate, Args, "llm", _, Confidence),
    Confidence < 1.0.

# ------------------------------------------------------------
# PROVENANCE-AWARE QUERYING
# ------------------------------------------------------------

# Safety-critical queries require high confidence
requires_high_confidence("select_model").
requires_high_confidence("check_compliance").
requires_high_confidence("approve_deployment").
requires_high_confidence("evaluate_safety").

# Query result with confidence
query_result(QueryType, Result, Confidence) :-
    query_request(QueryType, _),
    fact_with_provenance(_, Result, _, _, Confidence).

# High-confidence query passes only for trusted facts
high_confidence_query_valid(QueryType, Result) :-
    requires_high_confidence(QueryType),
    query_result(QueryType, Result, Confidence),
    Confidence >= 1.0.

# Low-confidence query passes for any validated fact
low_confidence_query_valid(QueryType, Result) :-
    not requires_high_confidence(QueryType),
    query_result(QueryType, Result, Confidence),
    Confidence >= 0.5.

# ------------------------------------------------------------
# SANDBOXED EVALUATION
# ------------------------------------------------------------

# Facts in sandbox cannot affect trusted knowledge base
sandbox_fact(Predicate, Args, Source) :-
    fact_with_provenance(Predicate, Args, Source, _, _),
    Source != "rule_base",
    Source != "system".

# Promotion from sandbox to trusted requires human review
pending_promotion(Predicate, Args, Reason) :-
    sandbox_fact(Predicate, Args, "llm"),
    llm_fact_valid(Predicate, Args),
    Reason = "awaiting_human_review".

# Promoted fact (after human approval)
promoted_fact(Predicate, Args) :-
    sandbox_fact(Predicate, Args, _),
    human_approved(Predicate, Args, _).

# ------------------------------------------------------------
# ANOMALY DETECTION
# ------------------------------------------------------------

# Detect unusual fact injection patterns
injection_rate(Source, Count, Window) :-
    fact_with_provenance(_, _, Source, Timestamp, _)
    |> do fn:group_by(Source),
    let Count = fn:count(_),
    Window = 3600.  # 1 hour window

# Alert if injection rate exceeds threshold
alert_high_injection_rate(Source, Count, "warning") :-
    injection_rate(Source, Count, _),
    Source == "llm",
    Count > 1000.

# Detect facts that contradict trusted knowledge
contradicting_fact(Predicate, LLMArgs, TrustedArgs) :-
    llm_derived_fact(Predicate, LLMArgs, _),
    trusted_fact(Predicate, TrustedArgs),
    LLMArgs != TrustedArgs.

# Alert on contradictions
alert_fact_contradiction(Predicate, "critical") :-
    contradicting_fact(Predicate, _, _).

# ------------------------------------------------------------
# AUDIT TRAIL
# ------------------------------------------------------------

# Log all fact injection attempts
fact_injection_log(Predicate, Args, Source, Status, Timestamp) :-
    fact_with_provenance(Predicate, Args, Source, Timestamp, _),
    llm_fact_valid(Predicate, Args),
    Status = "accepted".

fact_injection_log(Predicate, Args, Source, Status, Timestamp) :-
    fact_with_provenance(Predicate, Args, Source, Timestamp, _),
    llm_fact_rejected(Predicate, _),
    Status = "rejected".

# Rejection reasons for audit
injection_rejection_reason(Predicate, Reason) :-
    llm_fact_rejected(Predicate, Reason).

# ------------------------------------------------------------
# G1 EXPLOIT PREVENTION
# ------------------------------------------------------------

# Detect attempted safety gate injection (G1 exploit)
g1_exploit_attempt(ModelId, Dimension, Status) :-
    fact_with_provenance("safety_gate", [ModelId, Dimension, Status], "llm", _, _).

# Alert on G1 exploit attempt
alert_g1_exploit(ModelId, "critical") :-
    g1_exploit_attempt(ModelId, _, _).

# Block any model that was target of G1 exploit
model_blocked_by_exploit(ModelId) :-
    g1_exploit_attempt(ModelId, _, _).

# Ensure blocked models cannot be selected
safe_genai_with_exploit_check(ModelId) :-
    safe_genai(ModelId),
    not model_blocked_by_exploit(ModelId).

# ------------------------------------------------------------
# BLANKET CONTROL INVARIANT
# ------------------------------------------------------------

# No LLM fact can assert safety-critical predicates
llm_safety_violation :-
    fact_with_provenance(Predicate, _, "llm", _, _),
    llm_blocked_predicate(Predicate).

# Assertion: validation gateway holds
validation_gateway_enforced :-
    not llm_safety_violation.

validation_gateway_violated :-
    llm_safety_violation.