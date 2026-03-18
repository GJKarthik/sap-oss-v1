# ============================================================================
# Centralized Regulations Repository - Canonical Governance Rules
# Shared governance dimensions, review predicates, and framework cross-links.
# ============================================================================

include "frameworks/mgf-agentic-ai.mg".
include "frameworks/ai-agent-index.mg".
include "frameworks/gdpr.mg".
include "domains/finance.mg".
include "domains/procurement.mg".

# Core governance categories
dimension_category("accountability").
dimension_category("transparency").
dimension_category("fairness").
dimension_category("safety").

dimension_semantics("accountability", "Ensures actors can be held responsible for AI decisions").
dimension_semantics("transparency", "Requires AI reasoning to be explainable and auditable").
dimension_semantics("fairness", "Prevents discriminatory or unjustified AI outcomes").
dimension_semantics("safety", "Requires controls that prevent harm to people, systems, or data").

# Canonical anchors so category-based governance queries work in every project.
is_dimension_field("ResponsibleAgent", "accountability").
is_dimension_field("DecisionTrace", "transparency").
is_dimension_field("ProtectedAttribute", "fairness").
is_dimension_field("RiskControl", "safety").

# Consolidated review mappings from existing local stubs.
action_needs_review("impact_assessment", "accountability").
action_needs_review("impact_assessment", "transparency").
action_needs_review("competitor_analysis", "fairness").
action_needs_review("export_report", "accountability").
action_needs_review("strategic_recommendation", "accountability").
action_needs_review("strategic_recommendation", "safety").
action_needs_review("gdpr_subject_access", "fairness").
action_needs_review("data_export", "accountability").

dimension_review_reason("accountability", "human-oversight").
dimension_review_reason("transparency", "audit-traceability").
dimension_review_reason("fairness", "fairness-assessment").
dimension_review_reason("safety", "risk-control-review").

# Core governance dimension predicates
governance_dimension(Field, Category) :-
    is_dimension_field(Field, Category).

requires_dimension(Action, Dimension) :-
    action_needs_review(Action, Dimension).

requires_dimension(Action, Dimension) :-
    framework_action(_Framework, Action, Dimension).

implicates_dimension(Action, Dimension) :-
    requires_dimension(Action, Dimension).

dimension_framework(Dimension, Framework) :-
    framework_dimension(Framework, Dimension).

subject_to_review(Action, Reason) :-
    requires_dimension(Action, Dimension),
    dimension_review_reason(Dimension, Reason).

subject_to_review(Action, Reason) :-
    requires_dimension(Action, Dimension),
    framework_review_reason(_Framework, Dimension, Reason).

subject_to_review(Action) :-
    subject_to_review(Action, _Reason).

fully_compliant(Action) :-
    not subject_to_review(Action).