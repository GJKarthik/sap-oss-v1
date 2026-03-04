#!/usr/bin/env python3
"""
Generate Phase 0 HANA baseline artifacts from machine-readable outputs.

Inputs (relative to this script):
  - ../finsight_records.jsonl
  - ../quality_report.json
  - ../quality_issues.csv
  - ../finsight_onboarding.odps.yaml
  - ../odps_validation_report.json
  - ../mangle/*.mg and ../mangle/manifest.json
  - ../schema_summary.json
  - ../rag_chunks.jsonl
  - ../rag_embedding_records.jsonl

Outputs (default):
  - ../hana_phase0/phase0_field_catalog.csv
  - ../hana_phase0/phase0_field_catalog.json
  - ../hana_phase0/phase0_contract_freeze.json
  - ../hana_phase0/phase0_hana_domains.yaml
  - ../hana_phase0/phase0_target_schemas.yaml
  - ../hana_phase0/phase0_schema_skeleton.sql
  - ../hana_phase0/PHASE0_CONTRACT_FREEZE.md
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path


INT_RE = re.compile(r"^-?\d+$")
DEC_RE = re.compile(r"^-?\d+\.\d+$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?")

YN_FIELDS = {
    "any_technical_debt",
    "personal_data",
    "yes_no",
    "reviewed_by_data_chapter",
    "reviewed_by_data_chapter_2",
    "data_owner_data_sme_agreement_received",
    "arf_approval_received",
    "ftc_approval_received",
    "adf_approval_received",
}
YNN_FIELDS = {"yes_no_not_applicable"}
ID_FIELDS = {"unique_id", "use_case", "btp_table_name", "source_system", "source_field_name"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate Phase 0 HANA baseline artifacts")
    parser.add_argument(
        "--base-dir",
        default="..",
        help="Machine-readable base directory relative to script dir",
    )
    parser.add_argument(
        "--output-dir",
        default="../hana_phase0",
        help="Output directory relative to script dir",
    )
    return parser.parse_args()


def bucket_len(length: int) -> int:
    for bucket in (40, 80, 120, 255, 500, 1000, 2000, 5000):
        if length <= bucket:
            return bucket
    return 5000


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def infer_value_kind(text: str) -> str:
    if text in {"Yes", "No", "Not Applicable", "True", "False", "Y", "N", "0", "1"}:
        return "enum_boolish"
    if DT_RE.match(text):
        return "timestamp"
    if DATE_RE.match(text):
        return "date"
    if INT_RE.match(text):
        return "int"
    if DEC_RE.match(text):
        return "decimal"
    return "string"


def build_field_catalog(records_path: Path) -> dict:
    stats: dict[str, dict] = {}
    row_count = 0

    def get(field: str) -> dict:
        if field not in stats:
            stats[field] = {
                "present": 0,
                "max_len": 0,
                "tables": Counter(),
                "unique_small": set(),
                "kinds": Counter(),
                "examples": [],
            }
        return stats[field]

    with records_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            row_count += 1
            row = json.loads(line)
            table = str(row.get("table", ""))
            fields = row.get("fields", {})
            for field_name, value in fields.items():
                entry = get(field_name)
                entry["present"] += 1
                entry["tables"][table] += 1
                text = "" if value is None else str(value)
                entry["max_len"] = max(entry["max_len"], len(text))
                if len(entry["unique_small"]) < 200:
                    entry["unique_small"].add(text)
                if len(entry["examples"]) < 5 and text and text not in entry["examples"]:
                    entry["examples"].append(text)
                entry["kinds"][infer_value_kind(text)] += 1

    fields_out: list[dict] = []
    for field_name, entry in sorted(stats.items()):
        present = int(entry["present"])
        max_len = int(entry["max_len"])
        null_pct = round((1 - (present / row_count)) * 100, 2)
        unique_count_sampled = len(entry["unique_small"])
        dominant_kind = "string"
        dominant_count = 0
        if entry["kinds"]:
            dominant_kind, dominant_count = entry["kinds"].most_common(1)[0]
        dominant_ratio = (dominant_count / present) if present else 0.0

        domain = "DM_TEXT"
        hana_type = f"NVARCHAR({bucket_len(max_len)})"
        if field_name in ID_FIELDS:
            domain = "DM_IDENTIFIER"
            hana_type = f"NVARCHAR({max(40, bucket_len(max_len))})"
        elif field_name in YN_FIELDS:
            domain = "DM_YN"
            hana_type = "NVARCHAR(8)"
        elif field_name in YNN_FIELDS:
            domain = "DM_YN_NA"
            hana_type = "NVARCHAR(20)"
        elif dominant_kind == "int" and dominant_ratio > 0.98:
            domain = "DM_INTEGER"
            hana_type = "BIGINT"
        elif dominant_kind == "decimal" and dominant_ratio > 0.98:
            domain = "DM_DECIMAL"
            hana_type = "DECIMAL(34,10)"
        elif dominant_kind == "date" and dominant_ratio > 0.98:
            domain = "DM_DATE"
            hana_type = "DATE"
        elif dominant_kind == "timestamp" and dominant_ratio > 0.98:
            domain = "DM_TIMESTAMP"
            hana_type = "TIMESTAMP"
        elif max_len > 5000:
            domain = "DM_LONG_TEXT"
            hana_type = "NCLOB"
        elif max_len > 2000:
            domain = "DM_TEXT_LONG"
            hana_type = "NVARCHAR(5000)"
        elif max_len > 500:
            domain = "DM_TEXT_MEDIUM"
            hana_type = "NVARCHAR(2000)"
        elif max_len > 255:
            domain = "DM_TEXT_MEDIUM"
            hana_type = "NVARCHAR(500)"

        fields_out.append(
            {
                "field_name": field_name,
                "suggested_hana_type": hana_type,
                "domain": domain,
                "presence_count": present,
                "null_pct": null_pct,
                "max_length": max_len,
                "sample_unique_count": unique_count_sampled,
                "dominant_kind": dominant_kind,
                "dominant_kind_ratio": round(dominant_ratio, 4),
                "source_tables": ",".join(sorted(entry["tables"])),
                "examples": " | ".join(entry["examples"][:3]),
            }
        )

    return {
        "generated_from": str(records_path),
        "row_count": row_count,
        "field_count": len(fields_out),
        "fields": fields_out,
    }


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def build_contract_freeze(base_dir: Path, output_dir: Path, field_catalog: dict) -> dict:
    quality = json.loads((base_dir / "quality_report.json").read_text(encoding="utf-8"))
    odps_validation = json.loads(
        (base_dir / "odps_validation_report.json").read_text(encoding="utf-8")
    )
    mangle_manifest = json.loads((base_dir / "mangle/manifest.json").read_text(encoding="utf-8"))

    artifact_paths = [
        "finsight_records.jsonl",
        "schema_summary.json",
        "quality_report.json",
        "quality_issues.csv",
        "finsight_onboarding.odps.yaml",
        "odps_validation_report.json",
        "mangle/facts.mg",
        "mangle/rules.mg",
        "mangle/functions.mg",
        "mangle/aggregations.mg",
        "mangle/manifest.json",
        "rag_chunks.jsonl",
        "rag_embedding_records.jsonl",
    ]

    frozen_artifacts: list[dict] = []
    for rel in artifact_paths:
        path = base_dir / rel
        stat = path.stat()
        frozen_artifacts.append(
            {
                "path": str(path),
                "sha256": sha256_file(path),
                "size_bytes": stat.st_size,
                "last_modified_utc": datetime.fromtimestamp(stat.st_mtime, UTC).isoformat(),
            }
        )

    return {
        "phase": "Phase 0 - Baseline and Contract Freeze",
        "frozen_at_utc": datetime.now(UTC).isoformat(),
        "source_root": str(base_dir),
        "frozen_artifacts": frozen_artifacts,
        "baseline_metrics": {
            "records_total": quality["total_records"],
            "sources_total": quality["total_sources"],
            "tables_total": quality["total_tables"],
            "quality_issues_total": quality["issues"]["total_issues"],
            "mandatory_coverage_pct": quality["mandatory_quality"]["global"]["mandatory_coverage_pct"],
            "issue_breakdown": quality["issues"]["by_type"],
        },
        "odps_validation": {
            "is_valid": odps_validation["is_valid"],
            "schema_error_count": odps_validation["schema_error_count"],
            "missing_link_count": odps_validation["missing_link_count"],
            "schema_url": odps_validation["schema_url"],
        },
        "mangle_metrics": mangle_manifest["counts"],
        "field_catalog_summary": {
            "field_count": field_catalog["field_count"],
            "record_count_profiled": field_catalog["row_count"],
        },
        "target_schemas": [
            {
                "schema": "FINSIGHT_CORE",
                "purpose": "Normalized onboarding records and field-level data model",
            },
            {
                "schema": "FINSIGHT_RAG",
                "purpose": "Text chunks, embeddings, and vector retrieval artifacts",
            },
            {
                "schema": "FINSIGHT_GOV",
                "purpose": "Quality, validation, SLA, and governance evidence",
            },
            {
                "schema": "FINSIGHT_GRAPH",
                "purpose": "Lineage and semantic graph vertices/edges",
            },
        ],
        "status": "frozen",
    }


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    base_dir = (script_dir / args.base_dir).resolve()
    output_dir = (script_dir / args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    field_catalog = build_field_catalog(base_dir / "finsight_records.jsonl")
    field_catalog_json_path = output_dir / "phase0_field_catalog.json"
    field_catalog_csv_path = output_dir / "phase0_field_catalog.csv"
    field_catalog_json_path.write_text(
        json.dumps(field_catalog, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    write_csv(field_catalog_csv_path, field_catalog["fields"])

    contract_freeze = build_contract_freeze(base_dir, output_dir, field_catalog)
    contract_freeze_path = output_dir / "phase0_contract_freeze.json"
    contract_freeze_path.write_text(
        json.dumps(contract_freeze, indent=2),
        encoding="utf-8",
    )

    domains_yaml = """version: "1.0"
phase: "Phase 0"
name: "FinSight HANA Canonical Domains"
domains:
  DM_IDENTIFIER:
    hana_type: "NVARCHAR(120)"
    description: "Business and technical identifiers (unique IDs, table names, source keys)."
  DM_TEXT_SHORT:
    hana_type: "NVARCHAR(80)"
    description: "Short labels and categorical text values."
  DM_TEXT:
    hana_type: "NVARCHAR(255)"
    description: "General-purpose text fields in core onboarding records."
  DM_TEXT_MEDIUM:
    hana_type: "NVARCHAR(2000)"
    description: "Narrative fields and filter logic with medium text length."
  DM_TEXT_LONG:
    hana_type: "NVARCHAR(5000)"
    description: "Large text retained in-column where feasible."
  DM_LONG_TEXT:
    hana_type: "NCLOB"
    description: "Very large free text and generated context beyond NVARCHAR limits."
  DM_YN:
    hana_type: "NVARCHAR(8)"
    allowed_values:
      - "Yes"
      - "No"
    description: "Canonical yes/no enumerations from normalized pipeline."
  DM_YN_NA:
    hana_type: "NVARCHAR(20)"
    allowed_values:
      - "Yes"
      - "No"
      - "Not Applicable"
    description: "Canonical yes/no/not-applicable values."
  DM_INTEGER:
    hana_type: "BIGINT"
    description: "Whole-number metrics inferred from content profile."
  DM_DECIMAL:
    hana_type: "DECIMAL(34,10)"
    description: "High-precision decimal values for typed numeric measures."
  DM_DATE:
    hana_type: "DATE"
    description: "ISO-style calendar dates where field values are date-conformant."
  DM_TIMESTAMP:
    hana_type: "TIMESTAMP"
    description: "Timestamp fields when records contain date-time values."
"""
    (output_dir / "phase0_hana_domains.yaml").write_text(domains_yaml, encoding="utf-8")

    schema_yaml = """version: "1.0"
phase: "Phase 0"
name: "FinSight Target HANA Schema Blueprint"
schemas:
  FINSIGHT_CORE:
    purpose: "Machine-readable onboarding master model"
    tables:
      RECORDS:
        description: "One row per source record from finsight_records"
        primary_key: [record_id]
      FIELDS:
        description: "EAV projection of per-record normalized fields"
        primary_key: [record_id, field_name]
      SOURCE_FILES:
        description: "Source file inventory and row counts"
        primary_key: [source_file]

  FINSIGHT_RAG:
    purpose: "Retrieval and embedding layer"
    tables:
      CHUNKS:
        description: "RAG chunks aligned to RECORDS"
        primary_key: [chunk_id]
      EMBEDDINGS:
        description: "Embedding vectors and metadata"
        primary_key: [embedding_id]
      EMBEDDING_MANIFEST:
        description: "Embedding generation run metadata"
        primary_key: [run_id]

  FINSIGHT_GOV:
    purpose: "Quality and governance evidence"
    tables:
      QUALITY_ISSUES:
        description: "Row-level normalization and data quality issues"
        primary_key: [record_id, issue_type, field, source_row_number]
      QUALITY_REPORTS:
        description: "Run-level quality report snapshots"
        primary_key: [report_id]
      TABLE_PROFILE:
        description: "Mandatory coverage and table-level completeness metrics"
        primary_key: [table_name, report_id]
      ODPS_VALIDATION:
        description: "ODPS schema/link validation results"
        primary_key: [validation_run_id]

  FINSIGHT_GRAPH:
    purpose: "Lineage and semantic graph"
    tables:
      VERTEX:
        description: "Graph nodes: sources, tables, fields, records, issues"
        primary_key: [vertex_id]
      EDGE:
        description: "Typed graph relationships between vertices"
        primary_key: [edge_id]
      EDGE_TYPE:
        description: "Reference catalog of allowed relationship types"
        primary_key: [edge_type]
"""
    (output_dir / "phase0_target_schemas.yaml").write_text(schema_yaml, encoding="utf-8")

    schema_sql = """-- Phase 0 schema skeleton (no table DDL yet)
CREATE SCHEMA FINSIGHT_CORE;
CREATE SCHEMA FINSIGHT_RAG;
CREATE SCHEMA FINSIGHT_GOV;
CREATE SCHEMA FINSIGHT_GRAPH;
"""
    (output_dir / "phase0_schema_skeleton.sql").write_text(schema_sql, encoding="utf-8")

    quality = contract_freeze["baseline_metrics"]
    issues = quality["issue_breakdown"]
    md = f"""# Phase 0 Baseline and Contract Freeze

Generated at: {datetime.now(UTC).isoformat()}

## Frozen Contract Status

- Status: `frozen`
- Source root: `{base_dir}`
- Contract manifest: `phase0_contract_freeze.json`

## Baseline Metrics

- Total records: `{quality['records_total']}`
- Total tables: `{quality['tables_total']}`
- Total sources: `{quality['sources_total']}`
- Quality issues: `{quality['quality_issues_total']}`
- Mandatory coverage: `{quality['mandatory_coverage_pct']}%`
- ODPS valid: `{contract_freeze['odps_validation']['is_valid']}`

## Issue Breakdown

- placeholder_cleared: `{issues.get('placeholder_cleared', 0)}`
- missing_unique_id_replaced: `{issues.get('missing_unique_id_replaced', 0)}`
- datatype_score_to_decimal: `{issues.get('datatype_score_to_decimal', 0)}`

## HANA Preparation Outputs

- `phase0_field_catalog.csv`
- `phase0_field_catalog.json`
- `phase0_hana_domains.yaml`
- `phase0_target_schemas.yaml`
- `phase0_schema_skeleton.sql`

## Target Schemas

- `FINSIGHT_CORE` - normalized onboarding data model
- `FINSIGHT_RAG` - chunk + embedding retrieval model
- `FINSIGHT_GOV` - quality and ODPS governance evidence
- `FINSIGHT_GRAPH` - lineage/semantic graph model

## Notes

- Field typing in `phase0_field_catalog` is intentionally conservative and profile-driven.
- Exact physical table DDL, constraints, and indexes are Phase 1 deliverables.
"""
    (output_dir / "PHASE0_CONTRACT_FREEZE.md").write_text(md, encoding="utf-8")

    print(f"Base dir: {base_dir}")
    print(f"Output dir: {output_dir}")
    print(f"Wrote {field_catalog_json_path}")
    print(f"Wrote {field_catalog_csv_path}")
    print(f"Wrote {contract_freeze_path}")
    print(f"Wrote {output_dir / 'phase0_hana_domains.yaml'}")
    print(f"Wrote {output_dir / 'phase0_target_schemas.yaml'}")
    print(f"Wrote {output_dir / 'phase0_schema_skeleton.sql'}")
    print(f"Wrote {output_dir / 'PHASE0_CONTRACT_FREEZE.md'}")


if __name__ == "__main__":
    main()
