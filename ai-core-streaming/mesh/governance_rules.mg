# ============================================================================
# SAP OSS Service Mesh - Common Governance Rules
# MGF-Agentic-AI and AI-Agent-Index Compliance
# ============================================================================

# =============================================================================
# REGULATORY FRAMEWORKS
# =============================================================================

regulatory_framework("MGF-Agentic-AI").
regulatory_framework("AI-Agent-Index").
regulatory_framework("GDPR-Data-Processing").
regulatory_framework("Infrastructure-Security").

# =============================================================================
# AUTONOMY LEVELS (MGF-Agentic-AI)
# =============================================================================

autonomy_level("L1", "Lowest - Human approval for all actions").
autonomy_level("L2", "Standard - Human approval for sensitive actions").
autonomy_level("L3", "Higher - Autonomous with monitoring").
autonomy_level("L4", "Highest - Full autonomy").

autonomy_level_value("L1", 1).
autonomy_level_value("L2", 2).
autonomy_level_value("L3", 3).
autonomy_level_value("L4", 4).

# Service autonomy assignments
service_autonomy("vllm", "L1").
service_autonomy("data-cleaning-copilot", "L2").
service_autonomy("gen-ai-toolkit-hana", "L2").
service_autonomy("ai-core-pal", "L2").
service_autonomy("langchain-hana", "L2").
service_autonomy("elasticsearch", "L2").
service_autonomy("ai-sdk-js", "L2").
service_autonomy("cap-llm-plugin", "L2").
service_autonomy("ai-core-streaming", "L2").
service_autonomy("world-monitor", "L2").
service_autonomy("odata-vocabularies", "L3").
service_autonomy("ui5-webcomponents-ngx", "L3").

# =============================================================================
# HUMAN OVERSIGHT REQUIREMENTS
# =============================================================================

requires_human_oversight(Service) :-
    service_autonomy(Service, Level),
    autonomy_level_value(Level, Value),
    Value =< 2.

# Actions that always require human review
always_requires_approval("delete_data").
always_requires_approval("write_production").
always_requires_approval("train_model").
always_requires_approval("deploy_model").
always_requires_approval("modify_config").
always_requires_approval("grant_access").

requires_human_review(Service, Action) :-
    always_requires_approval(Action).

requires_human_review(Service, Action) :-
    service_autonomy(Service, "L1").

# =============================================================================
# SAFETY CONTROLS
# =============================================================================

safety_control("guardrails").
safety_control("monitoring").
safety_control("audit-logging").
safety_control("access-control").
safety_control("encryption").
safety_control("rate-limiting").

# Required safety controls by security class
required_safety_controls("public", ["guardrails", "monitoring"]).
required_safety_controls("internal", ["guardrails", "monitoring", "access-control"]).
required_safety_controls("confidential", ["guardrails", "monitoring", "audit-logging", "access-control"]).
required_safety_controls("restricted", ["guardrails", "monitoring", "audit-logging", "access-control", "encryption"]).

# =============================================================================
# DATA PROTECTION (GDPR)
# =============================================================================

# Data retention policies
data_retention_policy("no-storage", 0).
data_retention_policy("short-term", 7).
data_retention_policy("standard", 30).
data_retention_policy("long-term", 90).
data_retention_policy("archive", 365).

# Service data retention
service_data_retention("vllm", "no-storage").
service_data_retention("ai-core-streaming", "standard").
service_data_retention("data-cleaning-copilot", "short-term").
service_data_retention("gen-ai-toolkit-hana", "standard").
service_data_retention("langchain-hana", "standard").

# PII detection
pii_indicator("email").
pii_indicator("phone").
pii_indicator("ssn").
pii_indicator("credit_card").
pii_indicator("address").
pii_indicator("name").
pii_indicator("dob").

contains_pii(Content) :-
    pii_indicator(Indicator),
    fn:contains(fn:lower(Content), Indicator).

# =============================================================================
# AUDIT REQUIREMENTS
# =============================================================================

audit_level("none", 0).
audit_level("minimal", 1).
audit_level("standard", 2).
audit_level("full", 3).

# Service audit levels
service_audit_level("vllm", "full").
service_audit_level("data-cleaning-copilot", "full").
service_audit_level("gen-ai-toolkit-hana", "full").
service_audit_level("ai-core-pal", "full").
service_audit_level("langchain-hana", "full").
service_audit_level("ai-core-streaming", "standard").
service_audit_level("ai-sdk-js", "standard").
service_audit_level("cap-llm-plugin", "standard").
service_audit_level("elasticsearch", "standard").
service_audit_level("world-monitor", "standard").
service_audit_level("odata-vocabularies", "minimal").
service_audit_level("ui5-webcomponents-ngx", "minimal").

# What to audit
audit_field("timestamp").
audit_field("service_id").
audit_field("action").
audit_field("user_id").
audit_field("security_class").
audit_field("backend").
audit_field("status").

# =============================================================================
# COMPLIANCE CHECKS
# =============================================================================

compliance_check_passed(Service, Request) :-
    service_autonomy(Service, Level),
    not requires_human_review(Service, Request),
    safety_controls_enabled(Service).

safety_controls_enabled(Service) :-
    service_security_class(Service, Class),
    required_safety_controls(Class, Controls),
    all_controls_active(Service, Controls).

# =============================================================================
# ERROR CODES (OpenAI-Compatible)
# =============================================================================

error_code("invalid_request", 400).
error_code("unauthorized", 401).
error_code("forbidden", 403).
error_code("not_found", 404).
error_code("rate_limited", 429).
error_code("internal_error", 500).
error_code("service_unavailable", 503).

governance_error("blocked", 403, "Request blocked by governance policy").
governance_error("pending_approval", 202, "Request pending human approval").
governance_error("audit_required", 200, "Request logged for audit").