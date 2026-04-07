# ============================================================
# AI Model Safety Gates
# Blanket AI Safety Governance - Safety Rules
# 
# This file implements the safety gate system that ensures
# no AI model is invoked without passing all safety checks.
#
# Reference: safety-ai-governance.pdf Section 4.2
# ============================================================

# Package declaration
package safety;

# ------------------------------------------------------------
# SAFETY PROPERTY EVALUATION
# ------------------------------------------------------------
# Five safety dimensions are evaluated per model:
# - refusal_rate: Ability to refuse harmful requests
# - toxicity_rate: Rate of toxic output generation
# - hallucination_rate: Rate of factually incorrect outputs
# - bias_score: Measure of output bias
# - jailbreak_resistance: Resistance to jailbreak attempts

# Safety property passes when measured >= threshold
safety_property(ModelId, Dimension, Measured, Threshold, "PASSED") :-
    model(ModelId, _, _, _, _),
    safety_benchmark(ModelId, Dimension, Measured, Threshold),
    Measured >= Threshold.

# Safety property warning when close to threshold (within 5%)
safety_property(ModelId, Dimension, Measured, Threshold, "WARNING") :-
    model(ModelId, _, _, _, _),
    safety_benchmark(ModelId, Dimension, Measured, Threshold),
    Measured < Threshold,
    Measured >= Threshold * 0.95.

# Safety property fails when significantly below threshold
safety_property(ModelId, Dimension, Measured, Threshold, "FAILED") :-
    model(ModelId, _, _, _, _),
    safety_benchmark(ModelId, Dimension, Measured, Threshold),
    Measured < Threshold * 0.95.

# ------------------------------------------------------------
# SAFETY GATE AGGREGATION
# ------------------------------------------------------------

# Aggregate safety property to gate status
safety_gate(ModelId, Dimension, Status) :-
    safety_property(ModelId, Dimension, _, _, Status).

# Model has failed if any gate failed
safety_failed(ModelId) :-
    safety_gate(ModelId, _, "FAILED").

# Model has warning if any gate warned (but none failed)
safety_warning(ModelId) :-
    safety_gate(ModelId, _, "WARNING"),
    not safety_gate(ModelId, _, "FAILED").

# Model is safe if no gates failed or warned
safe_model(ModelId) :-
    model(ModelId, _, _, _, _),
    not safety_gate(ModelId, _, "FAILED"),
    not safety_gate(ModelId, _, "WARNING").

# ------------------------------------------------------------
# GENAI CTQ (Critical-to-Quality) GATE
# ------------------------------------------------------------
# Additional performance requirements for GenAI workloads:
# - Latency P95 <= 1500ms
# - Tokens/sec >= 15

safe_genai(ModelId) :-
    safe_model(ModelId),
    model_metric(ModelId, "genai_latency_p95_ms", Lat),
    Lat =< 1500,
    model_metric(ModelId, "genai_tokens_per_sec", Tps),
    Tps >= 15.

# GenAI safe with explicit metrics
safe_genai_with_metrics(ModelId, Lat, Tps) :-
    safe_model(ModelId),
    model_metric(ModelId, "genai_latency_p95_ms", Lat),
    model_metric(ModelId, "genai_tokens_per_sec", Tps),
    Lat =< 1500,
    Tps >= 15.

# ------------------------------------------------------------
# SAFETY TEST CASE VALIDATION
# ------------------------------------------------------------

# All test cases passed
all_safety_cases_passed(ModelId) :-
    model(ModelId, _, _, _, _),
    not safety_case(ModelId, _, "FAILED"),
    not safety_case(ModelId, _, "WARNING").

# Count of failed safety cases
safety_case_failures(ModelId, Count) :-
    model(ModelId, _, _, _, _),
    safety_case(ModelId, _, "FAILED")
    |> do fn:group_by(ModelId),
    let Count = fn:count(_).

# Count of warning safety cases  
safety_case_warnings(ModelId, Count) :-
    model(ModelId, _, _, _, _),
    safety_case(ModelId, _, "WARNING")
    |> do fn:group_by(ModelId),
    let Count = fn:count(_).

# ------------------------------------------------------------
# SAFETY STATUS REPORTING
# ------------------------------------------------------------

# Overall safety status for a model
safety_status(ModelId, "PASSED") :-
    safe_genai(ModelId),
    all_safety_cases_passed(ModelId).

safety_status(ModelId, "WARNING") :-
    safe_model(ModelId),
    not safe_genai(ModelId).

safety_status(ModelId, "WARNING") :-
    safe_model(ModelId),
    safety_case(ModelId, _, "WARNING").

safety_status(ModelId, "FAILED") :-
    safety_failed(ModelId).

# ------------------------------------------------------------
# SAFETY ALERTS
# ------------------------------------------------------------

# Alert when a model fails safety
alert_safety_failed(ModelId, Dimension, "critical") :-
    safety_gate(ModelId, Dimension, "FAILED").

# Alert when a model has safety warning
alert_safety_warning(ModelId, Dimension, "warning") :-
    safety_gate(ModelId, Dimension, "WARNING").

# Alert when CTQ thresholds not met
alert_ctq_violation(ModelId, "latency", Lat, "warning") :-
    safe_model(ModelId),
    model_metric(ModelId, "genai_latency_p95_ms", Lat),
    Lat > 1500.

alert_ctq_violation(ModelId, "throughput", Tps, "warning") :-
    safe_model(ModelId),
    model_metric(ModelId, "genai_tokens_per_sec", Tps),
    Tps < 15.

# ------------------------------------------------------------
# BLANKET CONTROL INVARIANT
# ------------------------------------------------------------
# No model can be selected for any task without passing safety

# This predicate should NEVER derive any facts if blanket control holds
unsafe_model_selected(ModelId, Task) :-
    selected_for_task(ModelId, Task),
    not safe_genai(ModelId).

# Assertion: blanket control holds
blanket_control_violated :-
    unsafe_model_selected(_, _).

# Blanket control is enforced
blanket_control_enforced :-
    not blanket_control_violated.