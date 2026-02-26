# Governance Rules for OData Vocabularies
# Phase 4: GDPR Compliance and Data Governance
#
# These rules implement data governance policies using OData PersonalData vocabulary.

# =============================================================================
# Predicate Declarations
# =============================================================================

Decl is_data_subject_entity(EntityType) descr [
    "Check if entity type represents a data subject (natural person)"
].

Decl is_personal_data_field(EntityType, FieldName) descr [
    "Check if field contains personal data"
].

Decl is_sensitive_data_field(EntityType, FieldName) descr [
    "Check if field contains sensitive personal data (GDPR special category)"
].

Decl requires_consent(EntityType, Operation) descr [
    "Check if operation requires explicit consent"
].

Decl data_retention_expired(EntityType, EntityID) descr [
    "Check if data retention period has expired"
].

Decl must_anonymize(EntityType, FieldName) descr [
    "Check if field must be anonymized before output"
].

Decl audit_required(Query, Reason) descr [
    "Check if query requires audit logging"
].

Decl access_allowed(Query, UserRole, Reason) descr [
    "Check if user role allows query access"
].

# =============================================================================
# Data Subject Entity Detection
# =============================================================================

# Entities annotated with PersonalData.EntitySemantics
is_data_subject_entity(EntityType) :-
    term("PersonalData", "EntitySemantics", _, _),
    entity_annotation(EntityType, "PersonalData.EntitySemantics", "DataSubject").

is_data_subject_entity(EntityType) :-
    entity_annotation(EntityType, "PersonalData.EntitySemantics", "DataSubjectDetails").

# Pattern-based detection (fallback)
is_data_subject_entity(EntityType) :-
    EntityType :> match("(?i)customer|employee|user|person|contact|patient|member").

# =============================================================================
# Personal Data Field Detection
# =============================================================================

# Fields annotated as potentially personal
is_personal_data_field(EntityType, FieldName) :-
    field_annotation(EntityType, FieldName, "PersonalData.IsPotentiallyPersonal", true).

# Pattern-based detection for common personal data fields
is_personal_data_field(EntityType, FieldName) :-
    FieldName :> match("(?i)(first|last|given|family).*name"),
    is_data_subject_entity(EntityType).

is_personal_data_field(EntityType, FieldName) :-
    FieldName :> match("(?i)e?mail|phone|address|birth.*date|dob|ssn"),
    is_data_subject_entity(EntityType).

is_personal_data_field(EntityType, FieldName) :-
    field_annotation(EntityType, FieldName, "PersonalData.FieldSemantics", _).

# =============================================================================
# Sensitive Data Field Detection
# =============================================================================

# Fields annotated as potentially sensitive
is_sensitive_data_field(EntityType, FieldName) :-
    field_annotation(EntityType, FieldName, "PersonalData.IsPotentiallySensitive", true).

# Pattern-based detection for GDPR special categories
is_sensitive_data_field(EntityType, FieldName) :-
    FieldName :> match("(?i)health|medical|ethnic|religion|political|sexual|genetic|biometric|criminal").

# =============================================================================
# Consent Requirements
# =============================================================================

# Sensitive data always requires consent
requires_consent(EntityType, Operation) :-
    is_sensitive_data_field(EntityType, _),
    Operation = "read".

requires_consent(EntityType, Operation) :-
    is_sensitive_data_field(EntityType, _),
    Operation = "export".

# Export of personal data requires consent
requires_consent(EntityType, "export") :-
    is_data_subject_entity(EntityType).

# =============================================================================
# Anonymization Rules
# =============================================================================

# Sensitive fields must be anonymized in non-production
must_anonymize(EntityType, FieldName) :-
    is_sensitive_data_field(EntityType, FieldName),
    environment("non-production").

# Personal fields should be masked in logs/exports
must_anonymize(EntityType, FieldName) :-
    is_personal_data_field(EntityType, FieldName),
    context("audit_log").

# =============================================================================
# Audit Requirements
# =============================================================================

# Audit required for data subject access
audit_required(Query, "data_subject_access") :-
    extract_entities(Query, EntityType, _),
    is_data_subject_entity(EntityType).

# Audit required for personal data queries
audit_required(Query, "personal_data_query") :-
    Query :> match("(?i)(customer|employee|user).*data"),
    Query :> match("(?i)(select|fetch|export|download)").

# Audit required for all sensitive data access
audit_required(Query, "sensitive_data_access") :-
    extract_entities(Query, EntityType, _),
    is_sensitive_data_field(EntityType, _).

# Audit required for bulk exports
audit_required(Query, "bulk_export") :-
    Query :> match("(?i)(export|download|dump).*all").

# =============================================================================
# Access Control Rules
# =============================================================================

# Data protection officer can access all
access_allowed(Query, "dpo", "role:dpo") :-
    is_data_subject_entity(_).

# Admin can access non-sensitive
access_allowed(Query, "admin", "role:admin") :-
    extract_entities(Query, EntityType, _),
    !is_sensitive_data_field(EntityType, _).

# Regular user access based on consent
access_allowed(Query, "user", "consent_verified") :-
    extract_entities(Query, EntityType, EntityID),
    consent_verified(EntityType, EntityID).

# Deny access to sensitive data without proper role
!access_allowed(Query, Role, _) :-
    extract_entities(Query, EntityType, _),
    is_sensitive_data_field(EntityType, _),
    Role != "dpo",
    Role != "medical_staff".

# =============================================================================
# Data Retention Rules
# =============================================================================

# Check if retention period expired
data_retention_expired(EntityType, EntityID) :-
    field_annotation(EntityType, _, "PersonalData.EndOfBusinessDate", EndDateField),
    entity_field_value(EntityType, EntityID, EndDateField, EndDate),
    EndDate < current_date().

# Entities past retention must be deleted
should_delete(EntityType, EntityID) :-
    data_retention_expired(EntityType, EntityID),
    !legal_hold(EntityType, EntityID).

# =============================================================================
# Resolution Rules with Governance
# =============================================================================

# Apply governance before resolution
resolve_with_governance(Query, Answer, ResPath, Score) :-
    audit_required(Query, AuditReason),
    log_audit(Query, AuditReason),
    access_allowed(Query, current_user_role(), AccessReason),
    resolve(Query, RawAnswer, ResPath, RawScore),
    apply_anonymization(Query, RawAnswer, Answer),
    Score = RawScore.

# Deny resolution if access not allowed
resolve_with_governance(Query, "Access denied", "denied", 0) :-
    !access_allowed(Query, current_user_role(), _).

# =============================================================================
# GDPR Subject Rights
# =============================================================================

# Right to access - get all personal data for a subject
subject_access_request(SubjectID, PersonalData) :-
    is_data_subject_entity(EntityType),
    entity_has_id(EntityType, SubjectID, EntityID),
    collect_personal_data(EntityType, EntityID, PersonalData).

# Right to erasure - identify data for deletion
subject_erasure_request(SubjectID, DataToDelete) :-
    is_data_subject_entity(EntityType),
    entity_has_id(EntityType, SubjectID, EntityID),
    !legal_hold(EntityType, EntityID),
    DataToDelete = {"entity_type": EntityType, "entity_id": EntityID}.

# Right to rectification - identify fields to update
subject_rectification_request(SubjectID, Field, NewValue, UpdateSpec) :-
    is_data_subject_entity(EntityType),
    entity_has_id(EntityType, SubjectID, EntityID),
    is_personal_data_field(EntityType, Field),
    UpdateSpec = {"entity_type": EntityType, "entity_id": EntityID, 
                  "field": Field, "new_value": NewValue}.

# Right to portability - export personal data in standard format
subject_portability_request(SubjectID, ExportData) :-
    is_data_subject_entity(EntityType),
    entity_has_id(EntityType, SubjectID, EntityID),
    collect_personal_data(EntityType, EntityID, PersonalData),
    format_portable(PersonalData, ExportData).

# =============================================================================
# Consent Management
# =============================================================================

# Verify consent for data processing
consent_verified(EntityType, EntityID) :-
    consent_record(EntityType, EntityID, Purpose, Status),
    Status = "granted",
    !consent_withdrawn(EntityType, EntityID, Purpose).

# Check consent for specific purpose
consent_for_purpose(EntityType, EntityID, Purpose) :-
    consent_record(EntityType, EntityID, Purpose, "granted"),
    consent_valid_until(EntityType, EntityID, ValidUntil),
    ValidUntil > current_date().

# =============================================================================
# Legal Basis Detection
# =============================================================================

# Determine legal basis for processing
legal_basis(EntityType, "contract") :-
    entity_annotation(EntityType, "ProcessingBasis", "Contract").

legal_basis(EntityType, "consent") :-
    entity_annotation(EntityType, "ProcessingBasis", "Consent").

legal_basis(EntityType, "legitimate_interest") :-
    entity_annotation(EntityType, "ProcessingBasis", "LegitimateInterest").

legal_basis(EntityType, "legal_obligation") :-
    entity_annotation(EntityType, "ProcessingBasis", "LegalObligation").

# Default to consent for personal data without explicit basis
legal_basis(EntityType, "consent") :-
    is_data_subject_entity(EntityType),
    !entity_annotation(EntityType, "ProcessingBasis", _).