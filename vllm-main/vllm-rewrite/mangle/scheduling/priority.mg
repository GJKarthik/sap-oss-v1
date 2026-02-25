# vLLM Scheduling Priority Rules
#
# This file defines the declarative rules for request scheduling priority.
# These rules determine the order in which requests are processed by the engine.
#
# Mangle is a logic programming language developed by Google for defining
# rules and policies in a declarative manner.

# =============================================================================
# CONSTANTS AND CONFIGURATION
# =============================================================================

# Priority levels (higher = more urgent)
fn urgent_priority() = 1000.
fn high_priority() = 500.
fn normal_priority() = 100.
fn low_priority() = 10.
fn background_priority() = 1.

# Thresholds
fn urgent_wait_threshold_ms() = 30000.  # 30 seconds
fn high_wait_threshold_ms() = 10000.    # 10 seconds
fn min_preempt_tokens() = 16.           # Minimum tokens before preemption allowed
fn max_queue_length() = 1000.

# =============================================================================
# BASE PRIORITY CALCULATION
# =============================================================================

# Calculate base priority from request properties
schedule_priority(Request, Priority) :-
    Request.user_tier == "enterprise",
    Priority = Request.base_priority + 200.

schedule_priority(Request, Priority) :-
    Request.user_tier == "premium",
    Priority = Request.base_priority + 100.

schedule_priority(Request, Priority) :-
    Request.user_tier == "standard",
    Priority = Request.base_priority.

schedule_priority(Request, Priority) :-
    Request.user_tier == "free",
    Priority = max(Request.base_priority - 50, background_priority()).

# =============================================================================
# WAIT TIME ESCALATION
# =============================================================================

# Escalate priority based on wait time
priority_escalation(Request, Escalation) :-
    wait_time_ms(Request, WaitTime),
    WaitTime >= urgent_wait_threshold_ms(),
    Escalation = urgent_priority().

priority_escalation(Request, Escalation) :-
    wait_time_ms(Request, WaitTime),
    WaitTime >= high_wait_threshold_ms(),
    WaitTime < urgent_wait_threshold_ms(),
    Escalation = high_priority().

priority_escalation(Request, Escalation) :-
    wait_time_ms(Request, WaitTime),
    WaitTime < high_wait_threshold_ms(),
    Escalation = 0.

# Calculate wait time in milliseconds
wait_time_ms(Request, WaitTime) :-
    current_time_ms(Now),
    WaitTime = Now - Request.arrival_time_ms.

# =============================================================================
# FINAL PRIORITY CALCULATION
# =============================================================================

# Combine base priority with escalation
final_priority(Request, FinalPriority) :-
    schedule_priority(Request, BasePriority),
    priority_escalation(Request, Escalation),
    FinalPriority = BasePriority + Escalation.

# =============================================================================
# PREEMPTION RULES
# =============================================================================

# Determine if a running request can be preempted
can_preempt(Victim, Preemptor) :-
    Victim.state == "running",
    Preemptor.state == "pending",
    final_priority(Victim, VictimPriority),
    final_priority(Preemptor, PreemptorPriority),
    PreemptorPriority > VictimPriority + 100,  # Significant priority difference
    Victim.tokens_generated >= min_preempt_tokens(),
    Victim.can_checkpoint == true.

# Cannot preempt if victim is in prefill phase
cannot_preempt(Victim, _) :-
    Victim.state == "running",
    Victim.phase == "prefill".

# Cannot preempt if victim is near completion
cannot_preempt(Victim, _) :-
    Victim.state == "running",
    remaining_tokens(Victim, Remaining),
    Remaining < 10.

# Calculate remaining tokens
remaining_tokens(Request, Remaining) :-
    Remaining = Request.max_tokens - Request.tokens_generated.

# =============================================================================
# BATCH COMPATIBILITY
# =============================================================================

# Check if two requests can be batched together
batch_compatible(Request1, Request2) :-
    Request1.model_id == Request2.model_id,
    Request1.lora_id == Request2.lora_id,
    compatible_sequence_lengths(Request1, Request2).

# Sequence length compatibility for efficient batching
compatible_sequence_lengths(Request1, Request2) :-
    abs(Request1.seq_len - Request2.seq_len) < 128.

# LoRA compatibility (null matches anything)
batch_compatible(Request1, Request2) :-
    Request1.model_id == Request2.model_id,
    Request1.lora_id == null,
    Request2.lora_id == null.

# =============================================================================
# SCHEDULING ACTIONS
# =============================================================================

# Determine scheduling action for a request
schedule_action(Request, "schedule_immediately") :-
    final_priority(Request, Priority),
    Priority >= urgent_priority(),
    has_capacity(Request).

schedule_action(Request, "add_to_queue") :-
    final_priority(Request, Priority),
    Priority < urgent_priority(),
    queue_length() < max_queue_length().

schedule_action(Request, "reject_with_backpressure") :-
    queue_length() >= max_queue_length().

schedule_action(Request, "reject_invalid") :-
    not valid_request(Request).

# =============================================================================
# CAPACITY CHECKS
# =============================================================================

# Check if there's capacity to run a request
has_capacity(Request) :-
    required_blocks(Request, RequiredBlocks),
    available_blocks() >= RequiredBlocks.

# Estimate required blocks for a request
required_blocks(Request, NumBlocks) :-
    estimated_tokens(Request, Tokens),
    block_size(BlockSize),
    NumBlocks = ceiling(Tokens / BlockSize).

# Estimate total tokens for a request
estimated_tokens(Request, Tokens) :-
    Tokens = Request.prompt_len + Request.max_tokens.

# =============================================================================
# REQUEST VALIDATION
# =============================================================================

# Validate request parameters
valid_request(Request) :-
    Request.max_tokens > 0,
    Request.max_tokens <= max_allowed_tokens(),
    Request.prompt_len > 0,
    Request.prompt_len <= max_prompt_length(),
    valid_sampling_params(Request.sampling_params).

# Validate sampling parameters
valid_sampling_params(Params) :-
    Params.temperature >= 0,
    Params.top_p > 0,
    Params.top_p <= 1,
    Params.top_k >= 0.

# System limits
fn max_allowed_tokens() = 32768.
fn max_prompt_length() = 128000.

# =============================================================================
# FAIRNESS RULES
# =============================================================================

# Fair scheduling - prevent starvation
should_boost_priority(Request) :-
    wait_time_ms(Request, WaitTime),
    WaitTime > urgent_wait_threshold_ms(),
    Request.times_preempted >= 2.

# Boost factor for repeatedly preempted requests
preemption_boost(Request, Boost) :-
    should_boost_priority(Request),
    Boost = Request.times_preempted * 100.

preemption_boost(Request, 0) :-
    not should_boost_priority(Request).

# =============================================================================
# SLA ENFORCEMENT
# =============================================================================

# Check if request is approaching SLA violation
sla_at_risk(Request) :-
    Request.sla_deadline_ms > 0,
    current_time_ms(Now),
    estimated_completion_time(Request, CompletionTime),
    CompletionTime > Request.sla_deadline_ms.

# Estimate completion time
estimated_completion_time(Request, CompletionTime) :-
    wait_time_ms(Request, WaitTime),
    estimated_processing_time(Request, ProcessingTime),
    CompletionTime = Request.arrival_time_ms + WaitTime + ProcessingTime.

# Estimate processing time based on token count
estimated_processing_time(Request, ProcessingTime) :-
    estimated_tokens(Request, Tokens),
    tokens_per_second(TPS),
    ProcessingTime = (Tokens / TPS) * 1000.

# Default tokens per second (can be adjusted based on model)
fn tokens_per_second() = 100.

# =============================================================================
# LOGGING AND METRICS
# =============================================================================

# Log priority decision for debugging
log_priority_decision(Request, Priority, Reason) :-
    final_priority(Request, Priority),
    priority_reason(Request, Reason).

priority_reason(Request, "urgent_wait_time") :-
    wait_time_ms(Request, WaitTime),
    WaitTime >= urgent_wait_threshold_ms().

priority_reason(Request, "enterprise_tier") :-
    Request.user_tier == "enterprise".

priority_reason(Request, "sla_at_risk") :-
    sla_at_risk(Request).

priority_reason(Request, "normal") :-
    not wait_time_ms(Request, WaitTime) >= urgent_wait_threshold_ms(),
    not Request.user_tier == "enterprise",
    not sla_at_risk(Request).