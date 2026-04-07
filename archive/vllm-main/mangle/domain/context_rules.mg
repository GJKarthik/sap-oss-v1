# Mangle rules for context management in ainuc-be-log-local-models
# These rules define how conversation context is managed and enhanced

# =============================================================================
# External / Base Predicates
#
# These predicates are populated at runtime by the host application before
# evaluation. They are declared here so the rule set is self-contained and
# can be validated without external input.
# =============================================================================

# message(MsgId, Role, Content) — provided by the conversation loader.
# Declared as an extensional predicate (no rules) so the engine knows its arity.
:- decl message(symbol, symbol, symbol).

# message_index(MsgId, Idx) — zero-based position of a message.
:- decl message_index(symbol, number).

# total_messages(Count) — number of messages in the current conversation.
:- decl total_messages(number).

# contains_code(Content) — true when Content contains a code block.
:- decl contains_code(symbol).

# contains_text(Substring) — true when any message contains Substring.
:- decl contains_text(symbol).

# recent_message(MsgId, Content) — messages in the recency window.
:- decl recent_message(symbol, symbol).

# contains_keyword(Content, Keyword) — true when Content contains Keyword.
:- decl contains_keyword(symbol, symbol).

# =============================================================================
# Context Window Management
# =============================================================================

# Define context window limits
context_limit(/phi3-lora, 4096).
context_limit(/llama3-8b, 8192).
context_limit(/codellama-7b, 16384).
context_limit(/mistral-7b, 8192).
context_limit(/qwen2-7b, 32768).

# Message role types
message_role(/system).
message_role(/user).
message_role(/assistant).

# Priority levels for context retention
priority(/critical, 10).
priority(/high, 7).
priority(/medium, 5).
priority(/low, 3).

# =============================================================================
# Message Priority Rules
# =============================================================================

# System messages are always critical
message_priority(MsgId, /critical) :-
    message(MsgId, /system, _).

# Recent messages (last 5) are high priority
message_priority(MsgId, /high) :-
    message(MsgId, _, _),
    message_index(MsgId, Idx),
    total_messages(Total),
    fn:minus(Total, Idx) < 5.

# Messages with code are medium priority
message_priority(MsgId, /medium) :-
    message(MsgId, _, Content),
    contains_code(Content).

# Older messages are low priority
message_priority(MsgId, /low) :-
    message(MsgId, _, _),
    !message_priority(MsgId, /critical),
    !message_priority(MsgId, /high),
    !message_priority(MsgId, /medium).

# =============================================================================
# Context Summarization Triggers
# =============================================================================

# Context needs summarization when exceeding threshold
needs_summarization(Model, CurrentTokens) :-
    context_limit(Model, Limit),
    Threshold = fn:mult(Limit, 0.8),
    CurrentTokens > Threshold.

# Calculate available space
available_context(Model, CurrentTokens, Available) :-
    context_limit(Model, Limit),
    Available = fn:minus(Limit, CurrentTokens).

# =============================================================================
# Context Retention Rules
# =============================================================================

# Messages to keep in context
retain_message(MsgId) :-
    message_priority(MsgId, Priority),
    priority(Priority, Score),
    Score > 5.

# Messages that can be summarized
can_summarize(MsgId) :-
    message(MsgId, Role, _),
    message_priority(MsgId, /low),
    Role != /system.

# Never summarize system prompts
never_summarize(MsgId) :-
    message(MsgId, /system, _).

# =============================================================================
# Context Enhancement Rules
# =============================================================================

# Add context based on detected entities
enhance_with_entity(EntityType, EntityValue) :-
    detected_entity(EntityType, EntityValue),
    relevant_context(EntityType).

# Relevant context types
relevant_context(/code_file).
relevant_context(/error_type).
relevant_context(/log_level).
relevant_context(/service_name).
relevant_context(/timestamp).

# Entity detection patterns
detected_entity(/error_type, "NullPointerException") :- contains_text("NullPointerException").
detected_entity(/error_type, "OutOfMemoryError") :- contains_text("OutOfMemoryError").
detected_entity(/error_type, "TimeoutException") :- contains_text("TimeoutException").
detected_entity(/log_level, "ERROR") :- contains_text("[ERROR]").
detected_entity(/log_level, "WARN") :- contains_text("[WARN]").
detected_entity(/log_level, "INFO") :- contains_text("[INFO]").

# =============================================================================
# Conversation Memory Rules
# =============================================================================

# Track conversation topic
conversation_topic(Topic) :-
    recent_message(_, Content),
    topic_keyword(Keyword, Topic),
    contains_keyword(Content, Keyword).

topic_keyword("kubernetes", /infrastructure).
topic_keyword("docker", /infrastructure).
topic_keyword("deployment", /infrastructure).
topic_keyword("database", /data).
topic_keyword("query", /data).
topic_keyword("performance", /optimization).
topic_keyword("slow", /optimization).
topic_keyword("latency", /optimization).
topic_keyword("error", /debugging).
topic_keyword("exception", /debugging).
topic_keyword("failed", /debugging).

# Maintain topic continuity
should_include_context(Topic, ContextType) :-
    conversation_topic(Topic),
    topic_context_map(Topic, ContextType).

topic_context_map(/infrastructure, /deployment_history).
topic_context_map(/infrastructure, /service_config).
topic_context_map(/data, /schema_info).
topic_context_map(/data, /query_patterns).
topic_context_map(/optimization, /metrics).
topic_context_map(/optimization, /benchmarks).
topic_context_map(/debugging, /error_logs).
topic_context_map(/debugging, /stack_traces).

# =============================================================================
# RAG (Retrieval Augmented Generation) Rules
# =============================================================================

# Documents to search for context
rag_source(/codebase, "Local code repository").
rag_source(/documentation, "Project documentation").
rag_source(/logs, "Application logs").
rag_source(/metrics, "Performance metrics").

# When to use RAG
should_use_rag(Source) :-
    conversation_topic(Topic),
    rag_source_for_topic(Topic, Source).

rag_source_for_topic(/infrastructure, /documentation).
rag_source_for_topic(/data, /codebase).
rag_source_for_topic(/optimization, /metrics).
rag_source_for_topic(/debugging, /logs).

# RAG priority by relevance
rag_priority(Source, Topic, Score) :-
    rag_source_for_topic(Topic, Source),
    rag_source(Source, _),
    source_relevance_score(Source, Topic, Score).

source_relevance_score(/logs, /debugging, 10).
source_relevance_score(/codebase, /debugging, 8).
source_relevance_score(/documentation, /infrastructure, 9).
source_relevance_score(/metrics, /optimization, 10).

# =============================================================================
# Tests
# =============================================================================

test_context_limit() :-
    context_limit(/phi3-lora, Limit),
    Limit > 0.

test_priority() :-
    priority(/critical, Score),
    Score > 8.

test_topic() :-
    topic_keyword("error", Topic),
    Topic = /debugging.