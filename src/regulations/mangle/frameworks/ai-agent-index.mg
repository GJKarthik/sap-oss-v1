# ============================================================================
# AI Agent Index / Agentic Systems Controls
# ============================================================================

regulatory_framework("AI-Agent-Index", "AI Agent Index governance profile", "enforced").

framework_dimension("AI-Agent-Index", "accountability").
framework_dimension("AI-Agent-Index", "transparency").
framework_dimension("AI-Agent-Index", "safety").

framework_review_reason("AI-Agent-Index", "accountability", "agent-index-human-approval").
framework_review_reason("AI-Agent-Index", "transparency", "agent-index-traceability").
framework_review_reason("AI-Agent-Index", "safety", "agent-index-safety-check").

framework_action("AI-Agent-Index", "strategic_recommendation", "accountability").
framework_action("AI-Agent-Index", "export_report", "transparency").
framework_action("AI-Agent-Index", "model_fine_tune", "safety").