# ============================================================================
# Regulations - Mangle Governance Dimension Rules
#
# LOCAL STUB — the canonical version of this file lives in the sibling
# `regulations/` repository.  This stub is present so that the include
# directive in `mangle/domain/agents.mg` resolves during local development
# and the `governance_dimension` predicate is available to any
# `requires_human_review` rule.
#
# Import path from agents.mg:
#   include "../../../regulations/mangle/rules.mg".
# which resolves (relative to ui5-webcomponents-ngx-main) to:
#   ui5-webcomponents-ngx-main/regulations/mangle/rules.mg   ← this file
# ============================================================================

# =============================================================================
# GOVERNANCE DIMENSIONS
# =============================================================================

governance_dimension("accountability",  "Ensures actors can be held responsible for AI decisions").
governance_dimension("transparency",    "Requires AI reasoning to be explainable and auditable").
governance_dimension("fairness",        "Prohibits discriminatory or biased AI outcomes").
governance_dimension("safety",          "Requires AI actions to avoid harm to people or systems").

# =============================================================================
# REGULATORY FRAMEWORKS
# =============================================================================

regulatory_framework("MGF-Agentic-AI",   "SAP Model Governance Framework - Agentic AI",    "enforced").
regulatory_framework("AI-Agent-Index",   "EU AI Act - Agentic Systems Index",               "enforced").
regulatory_framework("EU-AI-Act",        "European Union Artificial Intelligence Act",       "enforced").

# =============================================================================
# HIGH-RISK ACTIONS
# Public code-generation tools are NOT high-risk; listed here for completeness
# and to support future expansion to higher-autonomy or data-touching tools.
# =============================================================================

high_risk_action("data_export").
high_risk_action("gdpr_subject_access").
high_risk_action("model_fine_tune").

# =============================================================================
# GOVERNANCE DIMENSION → ACTION MAPPING
# ui5-ngx-agent operates at L3 on public code — no actions currently require
# a human-review dimension, but the mapping table is provided for extension.
# =============================================================================

requires_dimension("data_export",       "accountability").
requires_dimension("gdpr_subject_access", "fairness").

# =============================================================================
# DERIVED RULES
# =============================================================================

implicates_dimension(Action, Dimension) :-
    requires_dimension(Action, Dimension).

subject_to_review(Action) :-
    implicates_dimension(Action, _Dimension).

fully_compliant(Action) :-
    not subject_to_review(Action).
