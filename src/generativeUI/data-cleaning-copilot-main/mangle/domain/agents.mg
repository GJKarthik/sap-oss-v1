// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
//
// Mangle Datalog Governance Rules
// Data Cleaning Copilot Agent Configuration
//

// =============================================================================
// Agent Registration
// =============================================================================

// Register the data cleaning copilot agent
agent(data_cleaning_copilot).
agent_version(data_cleaning_copilot, "0.1.0").
agent_description(data_cleaning_copilot, "AI-powered data quality validation framework").

// MCP server endpoint
agent_endpoint(data_cleaning_copilot, "http://localhost:9110/mcp").

// =============================================================================
// Autonomy Levels
// =============================================================================
// L1: Fully supervised - all actions require approval
// L2: Semi-autonomous - read ops auto, write ops require approval
// L3: Autonomous - all ops auto-approved (public data only)
// L4: Fully autonomous - no human in loop (forbidden for enterprise)

// Data Cleaning Copilot operates at L2 (semi-autonomous)
// Read operations are auto-approved, write/mutation ops need approval
agent_autonomy_level(data_cleaning_copilot, l2).

// =============================================================================
// Tool Permissions
// =============================================================================

// Read-only tools - auto-approved at L2
tool_permission(data_cleaning_copilot, data_quality_check, auto).
tool_permission(data_cleaning_copilot, schema_analysis, auto).
tool_permission(data_cleaning_copilot, data_profiling, auto).
tool_permission(data_cleaning_copilot, anomaly_detection, auto).
tool_permission(data_cleaning_copilot, ai_chat, auto).
tool_permission(data_cleaning_copilot, mangle_query, auto).
tool_permission(data_cleaning_copilot, kuzu_index, auto).
tool_permission(data_cleaning_copilot, kuzu_query, auto).

// Write/mutation tools - require human approval
tool_permission(data_cleaning_copilot, generate_cleaning_query, requires_approval).
tool_permission(data_cleaning_copilot, execute_cleaning_query, requires_approval).

// Derive auto-approval status
auto_approved(Agent, Tool) :- 
    tool_permission(Agent, Tool, auto).

requires_approval(Agent, Tool) :- 
    tool_permission(Agent, Tool, requires_approval).

// =============================================================================
// Data Classification Rules
// =============================================================================

// Keywords that indicate PII or sensitive data
pii_keyword(customer).
pii_keyword(personal).
pii_keyword(confidential).
pii_keyword(pii).
pii_keyword(ssn).
pii_keyword(social_security).
pii_keyword(credit_card).
pii_keyword(cc_number).
pii_keyword(bank_account).
pii_keyword(passport).
pii_keyword(driver_license).
pii_keyword(date_of_birth).
pii_keyword(dob).
pii_keyword(email).
pii_keyword(phone).
pii_keyword(address).
pii_keyword(salary).
pii_keyword(compensation).

// Check if a query contains PII keywords
contains_pii(Query) :-
    pii_keyword(Keyword),
    string_contains(Query, Keyword).

// Data security classifications
data_security_class(public).
data_security_class(internal).
data_security_class(confidential).
data_security_class(restricted).

// Classification requires on-premise processing
requires_onprem(confidential).
requires_onprem(restricted).

// =============================================================================
// LLM Backend Routing
// =============================================================================

// Available backends
llm_backend(aicore, "SAP AI Core", cloud).
llm_backend(vllm, "vLLM On-Premise", onprem).
llm_backend(ollama, "Ollama Local", local).

// Default backend for data cleaning copilot
default_backend(data_cleaning_copilot, aicore).

// Route to vLLM if query contains PII
route_to_backend(Query, vllm) :-
    contains_pii(Query).

// Route to vLLM if data is classified as confidential/restricted
route_to_backend(Query, vllm) :-
    query_data_class(Query, Class),
    requires_onprem(Class).

// Default routing to AI Core
route_to_backend(Query, aicore) :-
    \+ contains_pii(Query),
    \+ (query_data_class(Query, Class), requires_onprem(Class)).

// =============================================================================
// Audit Requirements
// =============================================================================

// All tool invocations must be audited
audit_required(data_cleaning_copilot, Tool) :-
    tool_permission(data_cleaning_copilot, Tool, _).

// Audit retention period (days)
audit_retention(data_cleaning_copilot, 90).

// Audit fields to capture
audit_field(data_cleaning_copilot, timestamp).
audit_field(data_cleaning_copilot, session_id).
audit_field(data_cleaning_copilot, tool_name).
audit_field(data_cleaning_copilot, arguments_hash).
audit_field(data_cleaning_copilot, backend_used).
audit_field(data_cleaning_copilot, outcome).
audit_field(data_cleaning_copilot, latency_ms).

// Fields that should NOT be audited (raw content)
audit_exclude(data_cleaning_copilot, raw_prompt).
audit_exclude(data_cleaning_copilot, raw_response).
audit_exclude(data_cleaning_copilot, table_data).

// =============================================================================
// Rate Limits
// =============================================================================

// Global rate limit (requests per minute)
rate_limit(data_cleaning_copilot, global, 1000).

// Per-client rate limit
rate_limit(data_cleaning_copilot, per_client, 100).

// Per-tool rate limits
rate_limit(data_cleaning_copilot, data_quality_check, 100).
rate_limit(data_cleaning_copilot, schema_analysis, 50).
rate_limit(data_cleaning_copilot, data_profiling, 50).
rate_limit(data_cleaning_copilot, anomaly_detection, 30).
rate_limit(data_cleaning_copilot, generate_cleaning_query, 20).

// =============================================================================
// Resource Limits
// =============================================================================

// Sandbox execution limits
sandbox_timeout(data_cleaning_copilot, 30).  // seconds
sandbox_memory(data_cleaning_copilot, 512).  // MB

// Request/response size limits (bytes)
max_request_size(data_cleaning_copilot, 1048576).   // 1 MB
max_response_size(data_cleaning_copilot, 10485760). // 10 MB

// =============================================================================
// Service Mesh Integration
// =============================================================================

// Agent can communicate with these other agents
can_communicate(data_cleaning_copilot, ui5_ngx_agent).
can_communicate(data_cleaning_copilot, mcp_gateway).

// Ports agent exposes
exposes_port(data_cleaning_copilot, mcp, 9110).
exposes_port(data_cleaning_copilot, metrics, 9110).
exposes_port(data_cleaning_copilot, health, 9110).

// =============================================================================
// Compliance
// =============================================================================

// Regulatory frameworks this agent complies with
compliance_framework(data_cleaning_copilot, "MGF-Agentic-AI").

// Required attestations before production deployment
required_attestation(data_cleaning_copilot, security_review).
required_attestation(data_cleaning_copilot, data_governance_approval).
required_attestation(data_cleaning_copilot, rate_limit_validation).