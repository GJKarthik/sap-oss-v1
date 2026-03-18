# ============================================================================
# GDPR / GDPR Data Processing Controls
# ============================================================================

regulatory_framework("GDPR", "General Data Protection Regulation", "enforced").
regulatory_framework("GDPR-Data-Processing", "GDPR data processing controls", "enforced").

framework_dimension("GDPR", "accountability").
framework_dimension("GDPR", "transparency").
framework_dimension("GDPR", "fairness").

framework_dimension("GDPR-Data-Processing", "accountability").
framework_dimension("GDPR-Data-Processing", "transparency").
framework_dimension("GDPR-Data-Processing", "fairness").

framework_review_reason("GDPR", "accountability", "gdpr-controller-accountability").
framework_review_reason("GDPR", "transparency", "gdpr-data-subject-notice").
framework_review_reason("GDPR", "fairness", "gdpr-lawful-processing-review").

framework_review_reason("GDPR-Data-Processing", "accountability", "gdpr-controller-accountability").
framework_review_reason("GDPR-Data-Processing", "transparency", "gdpr-data-subject-notice").
framework_review_reason("GDPR-Data-Processing", "fairness", "gdpr-lawful-processing-review").

framework_action("GDPR", "gdpr_subject_access", "fairness").
framework_action("GDPR", "data_export", "accountability").
framework_action("GDPR-Data-Processing", "export_data", "accountability").