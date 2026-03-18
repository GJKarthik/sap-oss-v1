# ============================================================================
# S/4HANA Finance Governance Rules
# ============================================================================

domain_scope("finance", "S/4HANA Finance").

is_dimension_field("CompanyCode", "accountability").
is_dimension_field("ControllingArea", "accountability").
is_dimension_field("ProfitCenter", "accountability").
is_dimension_field("Ledger", "accountability").

is_dimension_field("GLAccount", "transparency").
is_dimension_field("FiscalYear", "transparency").
is_dimension_field("FiscalPeriod", "transparency").
is_dimension_field("PostingDate", "transparency").

is_dimension_field("BusinessArea", "fairness").
is_dimension_field("Segment", "fairness").
is_dimension_field("CostCenter", "fairness").

is_dimension_field("AccountingDocumentType", "safety").
is_dimension_field("ApprovalThreshold", "safety").

action_needs_review("apply_transformation", "accountability").
action_needs_review("bulk_update", "accountability").
action_needs_review("export_data", "transparency").
action_needs_review("delete_records", "safety").
action_needs_review("modify_schema", "safety").