#!/usr/bin/env python3
"""
Generate Mangle governance artifacts for FinSight machine-readable exports.

Inputs:
  - ../finsight_records.jsonl
  - ../quality_report.json
  - ../quality_issues.csv

Outputs:
  - ../mangle/facts.mg
  - ../mangle/rules.mg
  - ../mangle/functions.mg
  - ../mangle/aggregations.mg
  - ../mangle/README.md
  - ../mangle/manifest.json
"""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path


ALLOWED_DATATYPES = [
    "NVARCHAR",
    "DECIMAL",
    "DATE",
    "TIMESTAMP",
    "INTEGER",
    "BOOLEAN",
    "BIGINT",
    "NCLOB",
    "SMALLINT",
    "NCHAR",
    "VARBINARY",
    "TIME",
    "DOUBLE",
    "TINYINT",
    "BLOB",
    "REAL_VECTOR",
    "REAL",
    "BINARY",
]


RULES_MG = """# FinSight Mangle Rules
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
"""


FUNCTIONS_MG = """# FinSight Mangle Functions (helper predicates)
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
"""


AGGREGATIONS_MG = """# FinSight Mangle Aggregations
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
"""


README_MD = """# FinSight Mangle Governance Layer

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
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate FinSight Mangle artifacts")
    parser.add_argument(
        "--records-jsonl",
        default="../finsight_records.jsonl",
        help="Path to finsight_records.jsonl relative to script dir",
    )
    parser.add_argument(
        "--quality-report-json",
        default="../quality_report.json",
        help="Path to quality_report.json relative to script dir",
    )
    parser.add_argument(
        "--quality-issues-csv",
        default="../quality_issues.csv",
        help="Path to quality_issues.csv relative to script dir",
    )
    parser.add_argument(
        "--output-dir",
        default="../mangle",
        help="Output mangle directory relative to script dir",
    )
    return parser.parse_args()


def mg_escape(value: object) -> str:
    s = str(value)
    s = s.replace("\\", "\\\\")
    s = s.replace('"', '\\"')
    s = s.replace("\n", "\\n")
    return s


def load_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def load_quality_issues(path: Path) -> list[dict]:
    out: list[dict] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            out.append(row)
    return out


def write_text(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def generate_facts(
    records: list[dict],
    quality_report: dict,
    quality_issues: list[dict],
) -> tuple[str, dict[str, int]]:
    lines: list[str] = []
    stats: dict[str, int] = {
        "record_facts": 0,
        "field_facts": 0,
        "mandatory_field_facts": 0,
        "quality_issue_facts": 0,
        "source_file_facts": 0,
        "table_profile_facts": 0,
        "allowed_datatype_facts": 0,
    }

    lines.extend(
        [
            "# FinSight Mangle Facts",
            "# Generated from machine-readable FinSight outputs",
            "",
            "Decl source_file(SourceFile, RowCount).",
            "Decl table_profile(Table, SourceFile, RowCount, MandatoryCoveragePct).",
            "Decl mandatory_field(Table, FieldName).",
            "",
            "Decl record(RecordId, Table, SourceFile, SourceRowNumber, PrimaryKey).",
            "Decl field(RecordId, FieldName, FieldValue).",
            "",
            "Decl allowed_datatype(Datatype).",
            "",
            "Decl quality_issue(RecordId, Table, IssueType, Severity, Field, RawValue, NormalizedValue).",
            "",
            "# -----------------------------------------------------------------------------",
            "# Source and table summary facts",
            "# -----------------------------------------------------------------------------",
        ]
    )

    sources = quality_report.get("sources") or {}
    if not sources:
        for row in records:
            source = row["source_file"]
            sources[source] = sources.get(source, 0) + 1

    for source_file, count in sorted(sources.items()):
        lines.append(f'source_file("{mg_escape(source_file)}", {int(count)}).')
        stats["source_file_facts"] += 1

    mandatory = quality_report.get("mandatory_quality", {})
    per_table = mandatory.get("per_table", [])
    for item in per_table:
        table = str(item["table"])
        source_file = str(item["source_file"])
        row_count = int(item["row_count"])
        coverage = float(item["mandatory_coverage_pct"] or 0.0)
        lines.append(
            f'table_profile("{mg_escape(table)}", "{mg_escape(source_file)}", {row_count}, {coverage:.2f}).'
        )
        stats["table_profile_facts"] += 1
        for field_name in item.get("mandatory_columns", []):
            lines.append(
                f'mandatory_field("{mg_escape(table)}", "{mg_escape(field_name)}").'
            )
            stats["mandatory_field_facts"] += 1

    lines.extend(
        [
            "",
            "# -----------------------------------------------------------------------------",
            "# Datatype vocabulary",
            "# -----------------------------------------------------------------------------",
        ]
    )
    for datatype in ALLOWED_DATATYPES:
        lines.append(f'allowed_datatype("{datatype}").')
        stats["allowed_datatype_facts"] += 1

    lines.extend(
        [
            "",
            "# -----------------------------------------------------------------------------",
            "# Record and field facts",
            "# -----------------------------------------------------------------------------",
        ]
    )
    for row in records:
        record_id = mg_escape(row["record_id"])
        table = mg_escape(row["table"])
        source_file = mg_escape(row["source_file"])
        source_row_number = int(row["source_row_number"])
        primary_key = mg_escape(row.get("primary_key", ""))
        lines.append(
            f'record("{record_id}", "{table}", "{source_file}", {source_row_number}, "{primary_key}").'
        )
        stats["record_facts"] += 1

        fields = row.get("fields", {})
        for field_name, field_value in sorted(fields.items()):
            if field_value is None or str(field_value) == "":
                continue
            lines.append(
                'field("{}", "{}", "{}").'.format(
                    record_id,
                    mg_escape(field_name),
                    mg_escape(field_value),
                )
            )
            stats["field_facts"] += 1

    lines.extend(
        [
            "",
            "# -----------------------------------------------------------------------------",
            "# Quality issue facts",
            "# -----------------------------------------------------------------------------",
        ]
    )
    for issue in quality_issues:
        lines.append(
            'quality_issue("{}", "{}", "{}", "{}", "{}", "{}", "{}").'.format(
                mg_escape(issue.get("record_id", "")),
                mg_escape(issue.get("table", "")),
                mg_escape(issue.get("issue_type", "")),
                mg_escape(issue.get("severity", "")),
                mg_escape(issue.get("field", "")),
                mg_escape(issue.get("raw_value", "")),
                mg_escape(issue.get("normalized_value", "")),
            )
        )
        stats["quality_issue_facts"] += 1

    return "\n".join(lines) + "\n", stats


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    records_path = (script_dir / args.records_jsonl).resolve()
    quality_report_path = (script_dir / args.quality_report_json).resolve()
    quality_issues_path = (script_dir / args.quality_issues_csv).resolve()
    output_dir = (script_dir / args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    records = load_jsonl(records_path)
    quality_report = json.loads(quality_report_path.read_text(encoding="utf-8"))
    quality_issues = load_quality_issues(quality_issues_path)

    facts_content, fact_stats = generate_facts(
        records=records,
        quality_report=quality_report,
        quality_issues=quality_issues,
    )

    facts_path = output_dir / "facts.mg"
    rules_path = output_dir / "rules.mg"
    functions_path = output_dir / "functions.mg"
    aggregations_path = output_dir / "aggregations.mg"
    readme_path = output_dir / "README.md"
    manifest_path = output_dir / "manifest.json"

    write_text(facts_path, facts_content)
    write_text(rules_path, RULES_MG)
    write_text(functions_path, FUNCTIONS_MG)
    write_text(aggregations_path, AGGREGATIONS_MG)
    write_text(readme_path, README_MD)

    issue_counts = Counter(issue.get("issue_type", "") for issue in quality_issues)
    manifest = {
        "generated_at": datetime.now(UTC).isoformat(),
        "inputs": {
            "records_jsonl": str(records_path),
            "quality_report_json": str(quality_report_path),
            "quality_issues_csv": str(quality_issues_path),
        },
        "outputs": {
            "facts_mg": str(facts_path),
            "rules_mg": str(rules_path),
            "functions_mg": str(functions_path),
            "aggregations_mg": str(aggregations_path),
            "readme_md": str(readme_path),
        },
        "counts": {
            "records": len(records),
            "quality_issues": len(quality_issues),
            "issue_types": dict(issue_counts),
            **fact_stats,
        },
    }
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    print(f"Input records: {records_path}")
    print(f"Input quality report: {quality_report_path}")
    print(f"Input quality issues: {quality_issues_path}")
    print(f"Wrote {facts_path}")
    print(f"Wrote {rules_path}")
    print(f"Wrote {functions_path}")
    print(f"Wrote {aggregations_path}")
    print(f"Wrote {readme_path}")
    print(f"Wrote {manifest_path}")
    print("Fact counts:")
    for key, value in fact_stats.items():
        print(f"  {key}: {value}")


if __name__ == "__main__":
    main()
