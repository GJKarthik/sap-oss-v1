# ============================================================================
# Ariba / Procurement Governance Rules
# ============================================================================

domain_scope("procurement", "Ariba and procurement workflows").

is_dimension_field("PurchasingOrganization", "accountability").
is_dimension_field("CompanyCode", "accountability").
is_dimension_field("BuyerGroup", "accountability").

is_dimension_field("Contract", "transparency").
is_dimension_field("PurchaseOrder", "transparency").
is_dimension_field("SourcingEvent", "transparency").

is_dimension_field("Supplier", "fairness").
is_dimension_field("Vendor", "fairness").
is_dimension_field("PaymentTerms", "fairness").

is_dimension_field("ApprovalThreshold", "safety").
is_dimension_field("BlockedSupplierFlag", "safety").

action_needs_review("competitor_analysis", "fairness").
action_needs_review("data_export", "accountability").
action_needs_review("export_report", "accountability").
action_needs_review("strategic_recommendation", "safety").