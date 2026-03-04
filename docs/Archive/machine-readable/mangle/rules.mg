# FinSight Mangle Rules
# Derived quality and governance predicates

Decl missing_mandatory_field(RecordId, Table, FieldName).
Decl field_present(RecordId, FieldName).
Decl synthetic_primary_key(RecordId, Table, PrimaryKey).
Decl invalid_datatype(RecordId, Datatype).
Decl record_has_issue(RecordId, IssueType).
Decl high_risk_record(RecordId, Table, Reason).
Decl table_below_coverage_target(Table, Coverage, Gap).

field_present(RecordId, FieldName) :-
  field(RecordId, FieldName, _).

missing_mandatory_field(RecordId, Table, FieldName) :-
  record(RecordId, Table, _, _, _),
  mandatory_field(Table, FieldName),
  !field_present(RecordId, FieldName).

synthetic_primary_key(RecordId, Table, PrimaryKey) :-
  quality_issue(RecordId, Table, "missing_unique_id_replaced", _, "unique_id", _, PrimaryKey).

invalid_datatype(RecordId, Datatype) :-
  field(RecordId, "datatype", Datatype),
  !allowed_datatype(Datatype).

record_has_issue(RecordId, IssueType) :-
  quality_issue(RecordId, _, IssueType, _, _, _, _).

high_risk_record(RecordId, Table, Reason) :-
  missing_mandatory_field(RecordId, Table, _),
  Reason = "missing_mandatory".

high_risk_record(RecordId, Table, Reason) :-
  synthetic_primary_key(RecordId, Table, _),
  Reason = "synthetic_primary_key".

high_risk_record(RecordId, Table, Reason) :-
  record(RecordId, Table, _, _, _),
  invalid_datatype(RecordId, _),
  Reason = "invalid_datatype".

table_below_coverage_target(Table, Coverage, Gap) :-
  table_profile(Table, _, _, Coverage),
  missing_mandatory_field(_, Table, _),
  Gap = "has_missing_mandatory_fields".
