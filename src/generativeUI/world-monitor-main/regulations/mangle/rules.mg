# ============================================================================
# Regulations - Mangle Governance Dimension Rules
#
# LOCAL STUB — the canonical version of this file lives in the sibling
# `regulations/` repository.  This stub is present so that the include
# directive in `mangle/domain/agents.mg` resolves during local development
# and the `governance_dimension` predicate is available to the
# `requires_human_review` rule.
#
# Import path from agents.mg:
#   include "../../../regulations/mangle/rules.mg".
# which resolves (relative to world-monitor-main) to:
#   world-monitor-main/regulations/mangle/rules.mg   ← this file
# ============================================================================

# =============================================================================
# GOVERNANCE DIMENSIONS
# Declares the four core AI governance axes used by the agent.
# =============================================================================

governance_dimension("accountability",  "Ensures actors can be held responsible for AI decisions").
governance_dimension("transparency",    "Requires AI reasoning to be explainable and auditable").
governance_dimension("fairness",        "Prohibits discriminatory or biased AI outcomes").
governance_dimension("safety",          "Requires AI actions to avoid harm to people or systems").

# =============================================================================
# REGULATORY FRAMEWORKS
# Maps framework identifiers to human-readable names and enforcement status.
# =============================================================================

regulatory_framework("MGF-Agentic-AI",   "SAP Model Governance Framework - Agentic AI",    "enforced").
regulatory_framework("AI-Agent-Index",   "EU AI Act - Agentic Systems Index",               "enforced").
regulatory_framework("EU-AI-Act",        "European Union Artificial Intelligence Act",       "enforced").
regulatory_framework("GDPR",             "General Data Protection Regulation",               "enforced").

# =============================================================================
# HIGH-RISK ACTIONS (supplement agents.mg)
# Actions that always require human review regardless of autonomy level.
# =============================================================================

high_risk_action("strategic_recommendation").
high_risk_action("gdpr_subject_access").
high_risk_action("model_fine_tune").
high_risk_action("data_export").

# =============================================================================
# GOVERNANCE DIMENSION → ACTION MAPPING
# Binds governance dimensions to categories of agent actions so that
# requires_human_review in agents.mg can fire on dimension-aware checks.
# =============================================================================

requires_dimension("impact_assessment",        "accountability").
requires_dimension("impact_assessment",        "transparency").
requires_dimension("competitor_analysis",      "fairness").
requires_dimension("export_report",            "accountability").
requires_dimension("strategic_recommendation", "accountability").
requires_dimension("strategic_recommendation", "safety").
requires_dimension("gdpr_subject_access",      "fairness").
requires_dimension("data_export",              "accountability").

# =============================================================================
# DERIVED RULES
# =============================================================================

# An action implicates a governance dimension if it has a declared binding.
implicates_dimension(Action, Dimension) :-
    requires_dimension(Action, Dimension).

# An action is subject to governance review if it implicates any dimension
# whose framework is currently enforced.
subject_to_review(Action) :-
    implicates_dimension(Action, _Dimension).

# Cross-dimension compliance: action is fully compliant only when all
# required dimensions have been satisfied.
fully_compliant(Action) :-
    not subject_to_review(Action).
