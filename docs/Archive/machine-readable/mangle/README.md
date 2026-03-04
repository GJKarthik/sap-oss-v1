# FinSight Mangle Governance Layer

Generated governance layer for FinSight machine-readable onboarding data.

## Files

- `facts.mg`: Base facts (records, fields, mandatory definitions, quality issues)
- `rules.mg`: Derived quality/governance rules
- `functions.mg`: Function-based helper predicates
- `aggregations.mg`: Aggregate metrics predicates
- `manifest.json`: Generation metadata

## Example Queries

```mangle
missing_mandatory_field(RecordId, Table, Field).
high_risk_record(RecordId, Table, Reason).
quality_issue_count_by_type(IssueType, Count).
table_below_coverage_target(Table, Coverage, Gap).
record_count_by_table(Table, Count).
```
