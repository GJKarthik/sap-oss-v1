# FinSight Mangle Aggregations
# Aggregated quality and governance metrics

Decl record_count_by_table(Table, Count).
Decl field_count_by_table(Table, Count).
Decl quality_issue_count_by_table(Table, Count).
Decl quality_issue_count_by_type(IssueType, Count).
Decl missing_mandatory_count_by_table(Table, Count).
Decl synthetic_key_count_by_table(Table, Count).
Decl invalid_datatype_count(Datatype, Count).

record_count_by_table(Table, Count) :-
  record(_, Table, _, _, _) |> do fn:group_by(Table), let Count = fn:count().

field_count_by_table(Table, Count) :-
  record(RecordId, Table, _, _, _),
  field(RecordId, _, _) |> do fn:group_by(Table), let Count = fn:count().

quality_issue_count_by_table(Table, Count) :-
  quality_issue(_, Table, _, _, _, _, _) |> do fn:group_by(Table), let Count = fn:count().

quality_issue_count_by_type(IssueType, Count) :-
  quality_issue(_, _, IssueType, _, _, _, _) |> do fn:group_by(IssueType), let Count = fn:count().

missing_mandatory_count_by_table(Table, Count) :-
  missing_mandatory_field(_, Table, _) |> do fn:group_by(Table), let Count = fn:count().

synthetic_key_count_by_table(Table, Count) :-
  synthetic_primary_key(_, Table, _) |> do fn:group_by(Table), let Count = fn:count().

invalid_datatype_count(Datatype, Count) :-
  invalid_datatype(_, Datatype) |> do fn:group_by(Datatype), let Count = fn:count().
