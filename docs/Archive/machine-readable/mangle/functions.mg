# FinSight Mangle Functions (helper predicates)
# Function-heavy predicates used by quality queries

Decl field_contains_placeholder(RecordId, FieldName).
Decl field_contains_fs_missing(RecordId, FieldName).
Decl record_from_source(RecordId, SourceFile).
Decl record_in_table(RecordId, Table).

field_contains_placeholder(RecordId, FieldName) :-
  field(RecordId, FieldName, Value),
  :string:contains(Value, "placeholder").

field_contains_fs_missing(RecordId, FieldName) :-
  field(RecordId, FieldName, Value),
  :string:contains(Value, "FS_MISSING_").

record_from_source(RecordId, SourceFile) :-
  record(RecordId, _, SourceFile, _, _).

record_in_table(RecordId, Table) :-
  record(RecordId, Table, _, _, _).
