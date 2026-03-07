# Agent Classification Rules for Mangle Query Service
# 
# Based on: 2025-AI-Agent-Index.pdf (MIT/Cambridge/Stanford/Harvard)
# MGF Reference: mgf-for-agentic-ai.pdf (Singapore IMDA)
#
# Defines agent categories, autonomy levels, and safety controls
# for proper routing and governance decisions.

# =============================================================================
# Agent Index Reference (2025-AI-Agent-Index.pdf)
# =============================================================================
# The 2025 AI Agent Index documents 30 state-of-the-art AI agents across:
# - Chat applications with agentic tools (12 systems)
# - Browser-based agents (5 systems)
# - Enterprise workflow agents (13 systems)

# =============================================================================
# Agent Category Declarations
# 2025-AI-Agent-Index.pdf, chunk_id: "2025-AI-Agent-Index_p005_c002"
# =============================================================================

Decl agent_category(agent_id: string, category: string) descr [
    "Classify agent into category: chat, browser, enterprise"
].

# Chat applications with agentic tools
# "Chat interfaces with extensive tool access"
agent_category(AgentId, "chat") :-
    agent_interface(AgentId, "chat"),
    agent_has_tools(AgentId, true).

# Browser-based agents
# "Primary interface is browser or computer use"
agent_category(AgentId, "browser") :-
    agent_interface(AgentId, "browser");
    agent_interface(AgentId, "computer_use").

# Enterprise workflow agents  
# "Business management platforms with agentic features"
agent_category(AgentId, "enterprise") :-
    agent_interface(AgentId, "workflow");
    agent_interface(AgentId, "canvas").

# =============================================================================
# Autonomy Level Classification
# 2025-AI-Agent-Index.pdf, chunk_id: "2025-AI-Agent-Index_p004_c002"
# MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_007"
# =============================================================================

Decl autonomy_level(agent_id: string, level: string) descr [
    "Autonomy level from L1 (human-in-loop) to L5 (full autonomy)"
].

# L1: Human-in-the-loop
# "User directs and makes decisions, agent provides on-demand support"
autonomy_level(AgentId, "L1") :-
    agent_requires_approval(AgentId, "every_action").

# L2: Human-on-the-loop (DEFAULT for mangle-query-service)
# "User and agent collaboratively plan, delegate, and execute"
autonomy_level(AgentId, "L2") :-
    agent_requires_approval(AgentId, "significant_steps"),
    agent_human_can_intervene(AgentId, true).

# L3: Human oversight
# "Agent takes initiative, user as consultant"
autonomy_level(AgentId, "L3") :-
    agent_requires_approval(AgentId, "critical_only"),
    agent_has_guardrails(AgentId, true).

# L4: Limited autonomy
# "Interaction only when agent encounters blockers"
autonomy_level(AgentId, "L4") :-
    agent_requires_approval(AgentId, "blockers_only"),
    agent_has_emergency_stop(AgentId, true).

# L5: Full autonomy (NOT RECOMMENDED)
# "No means for user involvement"
autonomy_level(AgentId, "L5") :-
    agent_requires_approval(AgentId, "none").

# =============================================================================
# Agency Criteria (2025-AI-Agent-Index.pdf Inclusion Criteria)
# 2025-AI-Agent-Index.pdf, chunk_id: "2025-AI-Agent-Index_p004_c001"
# =============================================================================

Decl is_agentic(agent_id: string) descr [
    "Check if system meets agency criteria from Agent Index"
].

# All four criteria must be satisfied for agency
is_agentic(AgentId) :-
    has_autonomy(AgentId),
    has_goal_complexity(AgentId),
    has_env_interaction(AgentId),
    has_generality(AgentId).

# Autonomy criterion: "operate with minimal human oversight"
Decl has_autonomy(agent_id: string).
has_autonomy(AgentId) :-
    autonomy_level(AgentId, Level),
    Level :> match("L[2-5]").

# Goal complexity: "pursue high-level objectives through long-term planning"
Decl has_goal_complexity(agent_id: string).
has_goal_complexity(AgentId) :-
    agent_tool_calls(AgentId, Count),
    Count >= 3.

# Environmental interaction: "directly interact with the world through tools"
Decl has_env_interaction(agent_id: string).
has_env_interaction(AgentId) :-
    agent_has_tools(AgentId, true),
    agent_write_access(AgentId, true).

# Generality: "handle under-specified instructions"
Decl has_generality(agent_id: string).
has_generality(AgentId) :-
    agent_general_purpose(AgentId, true).

# =============================================================================
# Safety Controls (2025-AI-Agent-Index.pdf + MGF)
# 2025-AI-Agent-Index.pdf, chunk_id: "2025-AI-Agent-Index_p010_c001"
# MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_015"
# =============================================================================

Decl safety_control_present(agent_id: string, control: string) descr [
    "Check which safety controls are implemented for agent"
].

# Guardrails: "limit permissions and action space of tools"
safety_control_present(AgentId, "guardrails") :-
    agent_has_guardrails(AgentId, true).

# Sandboxing: "VM isolation documented"
safety_control_present(AgentId, "sandboxing") :-
    agent_sandboxed(AgentId, true).

# Approval gates: "explicit confirmations for sensitive operations"
safety_control_present(AgentId, "approval_gates") :-
    agent_requires_approval(AgentId, Level),
    Level != "none".

# Monitoring: "detailed action traces"
safety_control_present(AgentId, "monitoring") :-
    agent_has_monitoring(AgentId, true).

# Emergency stop: "pause/stop mechanisms"
safety_control_present(AgentId, "emergency_stop") :-
    agent_has_emergency_stop(AgentId, true).

# =============================================================================
# Action Space Classification
# 2025-AI-Agent-Index.pdf, chunk_id: "2025-AI-Agent-Index_p008_c003"
# MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_006"
# =============================================================================

Decl action_space_type(agent_id: string, action_type: string) descr [
    "Classify agent action space: crm, cli, browser, read_only, write"
].

# CRM connectors (enterprise agents)
action_space_type(AgentId, "crm") :-
    agent_category(AgentId, "enterprise"),
    agent_has_tool(AgentId, "crm_connector").

# CLI/filesystem (developer agents)
action_space_type(AgentId, "cli") :-
    agent_has_tool(AgentId, "bash");
    agent_has_tool(AgentId, "filesystem").

# Browser manipulation
action_space_type(AgentId, "browser") :-
    agent_category(AgentId, "browser"),
    agent_has_tool(AgentId, "click");
    agent_has_tool(AgentId, "navigate").

# Read-only (low risk)
action_space_type(AgentId, "read_only") :-
    agent_write_access(AgentId, false).

# Write access (higher risk)
action_space_type(AgentId, "write") :-
    agent_write_access(AgentId, true).

# =============================================================================
# MCP Protocol Support
# 2025-AI-Agent-Index.pdf, chunk_id: "2025-AI-Agent-Index_p008_c003"
# =============================================================================

Decl supports_mcp(agent_id: string) descr [
    "Check if agent supports Model Context Protocol"
].

# 20/30 agents support MCP per Agent Index
supports_mcp(AgentId) :-
    agent_protocol(AgentId, "MCP").

# A2A protocol (enterprise only)
Decl supports_a2a(agent_id: string).
supports_a2a(AgentId) :-
    agent_category(AgentId, "enterprise"),
    agent_protocol(AgentId, "A2A").

# =============================================================================
# Risk Level Assessment
# Combined from Agent Index + MGF
# =============================================================================

Decl agent_risk_level(agent_id: string, risk: string) descr [
    "Assess overall risk level: low, medium, high, critical"
].

# Critical: Full autonomy + write access + external systems
agent_risk_level(AgentId, "critical") :-
    autonomy_level(AgentId, "L5"),
    agent_write_access(AgentId, true),
    agent_external_access(AgentId, true).

# High: L4 autonomy OR browser category with write
agent_risk_level(AgentId, "high") :-
    autonomy_level(AgentId, "L4");
    (agent_category(AgentId, "browser"), agent_write_access(AgentId, true)).

# Medium: L2-L3 with write access
agent_risk_level(AgentId, "medium") :-
    autonomy_level(AgentId, Level),
    Level :> match("L[23]"),
    agent_write_access(AgentId, true).

# Low: L1-L2 with read only
agent_risk_level(AgentId, "low") :-
    autonomy_level(AgentId, Level),
    Level :> match("L[12]"),
    action_space_type(AgentId, "read_only").

# =============================================================================
# Routing Decisions Based on Agent Classification
# Integration with mangle-query-service routing
# =============================================================================

Decl route_to_vllm(agent_id: string, reason: string) descr [
    "Check if agent should route to vLLM for safety"
].

# Route to vLLM for high-risk agents
route_to_vllm(AgentId, "high_risk_agent") :-
    agent_risk_level(AgentId, "critical");
    agent_risk_level(AgentId, "high").

# Route to vLLM if handling confidential data
route_to_vllm(AgentId, "confidential_data") :-
    agent_accesses_entity(AgentId, EntityType),
    is_sensitive_data_field(EntityType, _).

# Route to vLLM if no emergency stop
route_to_vllm(AgentId, "no_emergency_stop") :-
    autonomy_level(AgentId, Level),
    Level :> match("L[345]"),
    !safety_control_present(AgentId, "emergency_stop").

Decl route_to_aicore(agent_id: string, reason: string) descr [
    "Check if agent can safely route to AI Core"
].

# AI Core OK for low-risk, well-controlled agents
route_to_aicore(AgentId, "low_risk_controlled") :-
    agent_risk_level(AgentId, "low"),
    safety_control_present(AgentId, "guardrails"),
    safety_control_present(AgentId, "monitoring").

# AI Core OK for read-only access
route_to_aicore(AgentId, "read_only") :-
    action_space_type(AgentId, "read_only").

# =============================================================================
# Mangle Query Service Classification
# Self-classification for regulatory compliance
# =============================================================================

# mangle-query-service default classification
agent_category("mangle-query-service", "enterprise").
autonomy_level("mangle-query-service", "L2").
safety_control_present("mangle-query-service", "guardrails").
safety_control_present("mangle-query-service", "monitoring").
safety_control_present("mangle-query-service", "approval_gates").
safety_control_present("mangle-query-service", "emergency_stop").
supports_mcp("mangle-query-service").
agent_risk_level("mangle-query-service", "medium").

# =============================================================================
# Exports
# =============================================================================

# Available for routing decisions:
# - agent_category/2
# - autonomy_level/2
# - safety_control_present/2
# - agent_risk_level/2
# - route_to_vllm/2
# - route_to_aicore/2