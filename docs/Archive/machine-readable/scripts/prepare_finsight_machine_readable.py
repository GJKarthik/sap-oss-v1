#!/usr/bin/env python3
"""
Prepare AI-ready machine-readable outputs from FinSight onboarding CSV exports.

Inputs (default):
  - docs/Archive/1_register.csv
  - docs/Archive/2_stagingschema.csv
  - docs/Archive/2_stagingschema_logs.csv
  - docs/Archive/2_stagingschema_nonstagingschema.csv
  - docs/Archive/3_validations.csv

Outputs:
  - normalized/*.cleaned.csv + normalized/*.cleaned.jsonl
  - finsight_records.jsonl + finsight_records.csv
  - rag_chunks.jsonl + rag_chunks.csv
  - rag_manifest.json
  - rag_embedding_records.jsonl + rag_embedding_records.csv
  - rag_embedding_records_manifest.json
  - schema_summary.json
  - quality_report.json
  - quality_issues.csv
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import uuid
from collections import Counter, defaultdict
from datetime import UTC, datetime
from pathlib import Path


FILE_CONFIG: list[dict[str, object]] = [
    {"file": "1_register.csv", "table": "register", "header_row": 3},
    {"file": "2_stagingschema.csv", "table": "staging_schema", "header_row": 1},
    {"file": "2_stagingschema_logs.csv", "table": "staging_schema_logs", "header_row": 0},
    {
        "file": "2_stagingschema_nonstagingschema.csv",
        "table": "non_staging_schema",
        "header_row": 1,
    },
    {"file": "3_validations.csv", "table": "validations", "header_row": 0},
]


PRIMARY_KEY_PRIORITY = [
    "unique_id",
    "use_case",
    "btp_table_name",
    "source_system",
    "source_system_s",
    "source_table_name_structured_location_for_unstructured_data",
    "source_field_name",
]


NON_ALNUM = re.compile(r"[^a-z0-9]+")
MULTI_WS = re.compile(r"\s+")
UNIQUE_ID_PATTERN = re.compile(r"^FS_\d{3}(,\s*FS_\d{3})*$")
DATATYPE_SCORE_PATTERN = re.compile(r"^\d+(\.\d+)?\s*score$", re.IGNORECASE)

PLACEHOLDER_TOKENS = {
    "na",
    "n/a",
    "tba",
    "tbd",
    "none",
    "null",
    "unknown",
    "not available",
    "?",
    "??",
}

DATATYPE_ALIASES = {
    "VARCHAR": "NVARCHAR",
    "CHAR": "NCHAR",
    "INT": "INTEGER",
    "NUMERIC": "DECIMAL",
    "NUMBER": "DECIMAL",
    "FLOAT": "DOUBLE",
    "BOOL": "BOOLEAN",
}

ALLOWED_DATATYPES = {
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
}

YES_NO_FIELDS = {
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

YES_NO_NA_FIELDS = {
    "yes_no_not_applicable",
}

YES_NO_MAP = {
    "yes": "Yes",
    "y": "Yes",
    "true": "Yes",
    "1": "Yes",
    "no": "No",
    "n": "No",
    "false": "No",
    "0": "No",
}

YES_NO_NA_MAP = {
    **YES_NO_MAP,
    "na": "Not Applicable",
    "n/a": "Not Applicable",
    "not applicable": "Not Applicable",
    "not-applicable": "Not Applicable",
}

SENSITIVITY_MAP = {
    "public": "Public",
    "internal": "Internal",
    "confidential": "Confidential",
    "restricted": "Restricted",
}

LIFECYCLE_MAP = {
    "announcement": "Announcement",
    "draft": "Draft",
    "development": "Development",
    "testing": "Testing",
    "acceptance": "Acceptance",
    "production": "Production",
    "sunset": "Sunset",
    "retired": "Retired",
    "live": "Live",
    "prioritized": "Prioritized",
    "not prioritized": "Not Prioritized",
    "deprecated": "Deprecated",
}

DATA_TYPE_MAP = {
    "structured": "Structured",
    "unstructured": "Unstructured",
}

BTP_LAYER_MAP = {
    "staging": "Staging",
    "common": "Common",
    "use-case specific": "Use-Case Specific",
    "use case specific": "Use-Case Specific",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build machine-readable AI exports")
    parser.add_argument(
        "--input-dir",
        default="../..",
        help="Archive directory containing source CSV files",
    )
    parser.add_argument(
        "--output-dir",
        default="..",
        help="Output machine-readable directory",
    )
    return parser.parse_args()


def clean_text(value: object) -> str:
    text = str(value or "").replace("\r\n", "\n").replace("\r", "\n")
    text = " ".join(part.strip() for part in text.split("\n") if part.strip())
    text = MULTI_WS.sub(" ", text).strip()
    return text


def normalize_column_name(value: object, index: int) -> str:
    text = clean_text(value).lower().strip("`")
    text = NON_ALNUM.sub("_", text).strip("_")
    if not text:
        text = f"col_{index + 1}"
    return text


def normalize_column_label(value: object, index: int) -> str:
    text = clean_text(value)
    if not text:
        text = f"Column {index + 1}"
    return text


def dedupe_names(items: list[str], sep: str = "_", close_suffix: str = "") -> list[str]:
    seen: dict[str, int] = defaultdict(int)
    out: list[str] = []
    for item in items:
        seen[item] += 1
        if seen[item] == 1:
            out.append(item)
        else:
            out.append(f"{item}{sep}{seen[item]}{close_suffix}")
    return out


def read_csv_rows(path: Path) -> list[list[str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.reader(handle))


def is_placeholder_token(value: str) -> bool:
    token = value.strip().lower()
    if token.endswith("."):
        token = token[:-1].strip()
    return token in PLACEHOLDER_TOKENS


def normalize_from_map(
    value: str,
    mapping: dict[str, str],
) -> str | None:
    token = value.strip().lower()
    return mapping.get(token)


def make_issue(
    issue_type: str,
    field: str,
    raw_value: str,
    normalized_value: str,
    message: str,
    severity: str = "warning",
) -> dict[str, str]:
    return {
        "issue_type": issue_type,
        "severity": severity,
        "field": field,
        "raw_value": raw_value,
        "normalized_value": normalized_value,
        "message": message,
    }


def normalize_field_value(
    field: str,
    value: str,
    source_row_number: int,
) -> tuple[str, list[dict[str, str]]]:
    issues: list[dict[str, str]] = []
    raw = value
    normalized = value.strip()

    if field == "unique_id":
        if is_placeholder_token(normalized):
            replacement = f"FS_MISSING_{source_row_number:05d}"
            issues.append(
                make_issue(
                    issue_type="missing_unique_id_replaced",
                    field=field,
                    raw_value=raw,
                    normalized_value=replacement,
                    message="Replaced placeholder Unique ID with deterministic synthetic ID.",
                )
            )
            return replacement, issues

        if "," in normalized:
            compact = ", ".join(part.strip() for part in normalized.split(",") if part.strip())
            if compact != normalized:
                issues.append(
                    make_issue(
                        issue_type="unique_id_whitespace_normalized",
                        field=field,
                        raw_value=raw,
                        normalized_value=compact,
                        message="Normalized spacing in comma-separated Unique ID list.",
                        severity="info",
                    )
                )
                normalized = compact

        if normalized and not UNIQUE_ID_PATTERN.fullmatch(normalized):
            issues.append(
                make_issue(
                    issue_type="unique_id_format_unexpected",
                    field=field,
                    raw_value=raw,
                    normalized_value=normalized,
                    message="Unique ID does not match expected FS_### pattern.",
                )
            )
        return normalized, issues

    if field == "datatype":
        if not normalized:
            return normalized, issues

        if DATATYPE_SCORE_PATTERN.fullmatch(normalized):
            issues.append(
                make_issue(
                    issue_type="datatype_score_to_decimal",
                    field=field,
                    raw_value=raw,
                    normalized_value="DECIMAL",
                    message='Converted obvious non-type value like "2 Score" to DECIMAL.',
                )
            )
            return "DECIMAL", issues

        upper = normalized.upper()
        mapped = DATATYPE_ALIASES.get(upper, upper)
        if mapped != normalized:
            issues.append(
                make_issue(
                    issue_type="datatype_normalized",
                    field=field,
                    raw_value=raw,
                    normalized_value=mapped,
                    message="Normalized datatype casing/alias to canonical form.",
                    severity="info",
                )
            )
        if mapped not in ALLOWED_DATATYPES:
            issues.append(
                make_issue(
                    issue_type="datatype_unrecognized",
                    field=field,
                    raw_value=raw,
                    normalized_value=mapped,
                    message="Datatype not in expected canonical set.",
                )
            )
        return mapped, issues

    if field in YES_NO_FIELDS:
        yn = normalize_from_map(normalized, YES_NO_MAP)
        if yn is not None:
            if yn != normalized:
                issues.append(
                    make_issue(
                        issue_type="enum_normalized_yes_no",
                        field=field,
                        raw_value=raw,
                        normalized_value=yn,
                        message="Normalized yes/no value to canonical form.",
                        severity="info",
                    )
                )
            return yn, issues

    if field in YES_NO_NA_FIELDS:
        ynn = normalize_from_map(normalized, YES_NO_NA_MAP)
        if ynn is not None:
            if ynn != normalized:
                issues.append(
                    make_issue(
                        issue_type="enum_normalized_yes_no_na",
                        field=field,
                        raw_value=raw,
                        normalized_value=ynn,
                        message="Normalized Yes/No/Not Applicable value to canonical form.",
                        severity="info",
                    )
                )
            return ynn, issues

    if field == "sensitivity":
        mapped = normalize_from_map(normalized, SENSITIVITY_MAP)
        if mapped is not None:
            if mapped != normalized:
                issues.append(
                    make_issue(
                        issue_type="enum_normalized_sensitivity",
                        field=field,
                        raw_value=raw,
                        normalized_value=mapped,
                        message="Normalized sensitivity classification to canonical form.",
                        severity="info",
                    )
                )
            return mapped, issues

    if field == "life_cycle_status":
        mapped = normalize_from_map(normalized, LIFECYCLE_MAP)
        if mapped is not None:
            if mapped != normalized:
                issues.append(
                    make_issue(
                        issue_type="enum_normalized_lifecycle",
                        field=field,
                        raw_value=raw,
                        normalized_value=mapped,
                        message="Normalized life cycle status to canonical form.",
                        severity="info",
                    )
                )
            return mapped, issues

    if field == "data_type":
        mapped = normalize_from_map(normalized, DATA_TYPE_MAP)
        if mapped is not None:
            if mapped != normalized:
                issues.append(
                    make_issue(
                        issue_type="enum_normalized_data_type",
                        field=field,
                        raw_value=raw,
                        normalized_value=mapped,
                        message="Normalized data type to canonical form.",
                        severity="info",
                    )
                )
            return mapped, issues

    if field == "btp_layer":
        mapped = normalize_from_map(normalized, BTP_LAYER_MAP)
        if mapped is not None:
            if mapped != normalized:
                issues.append(
                    make_issue(
                        issue_type="enum_normalized_btp_layer",
                        field=field,
                        raw_value=raw,
                        normalized_value=mapped,
                        message="Normalized BTP layer value to canonical form.",
                        severity="info",
                    )
                )
            return mapped, issues

    if normalized and is_placeholder_token(normalized):
        issues.append(
            make_issue(
                issue_type="placeholder_cleared",
                field=field,
                raw_value=raw,
                normalized_value="",
                message="Cleared placeholder token value to empty.",
                severity="info",
            )
        )
        return "", issues

    return normalized, issues


def pick_primary_key(fields: dict[str, str]) -> str:
    for key in PRIMARY_KEY_PRIORITY:
        value = fields.get(key, "")
        if value:
            return value
    return ""


def build_record_text(
    table: str,
    source_file: str,
    source_row_number: int,
    label_value_pairs: list[tuple[str, str]],
) -> str:
    lines = [
        f"table: {table}",
        f"source_file: {source_file}",
        f"source_row_number: {source_row_number}",
    ]
    for label, value in label_value_pairs:
        lines.append(f"{label}: {value}")
    return "\n".join(lines)


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def write_csv(path: Path, rows: list[dict], fieldnames: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({name: row.get(name, "") for name in fieldnames})


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    input_dir = (script_dir / args.input_dir).resolve()
    output_dir = (script_dir / args.output_dir).resolve()
    normalized_dir = output_dir / "normalized"
    normalized_dir.mkdir(parents=True, exist_ok=True)

    all_records: list[dict] = []
    rag_chunks: list[dict] = []
    schema_summary: list[dict] = []
    quality_issues: list[dict[str, str | int]] = []

    source_counts: dict[str, int] = defaultdict(int)
    table_counts: dict[str, int] = defaultdict(int)
    issue_counts: Counter[str] = Counter()
    issue_counts_by_table: Counter[str] = Counter()
    normalized_change_counts_by_field: Counter[str] = Counter()
    normalized_change_counts_by_issue: Counter[str] = Counter()
    total_changed_values = 0

    mandatory_stats_by_table: dict[str, dict] = {}
    global_mandatory_total = 0
    global_mandatory_filled = 0

    for entry in FILE_CONFIG:
        source_file = str(entry["file"])
        table = str(entry["table"])
        header_row = int(entry["header_row"])
        source_path = input_dir / source_file
        if not source_path.exists():
            raise FileNotFoundError(f"Missing expected input file: {source_path}")

        rows = read_csv_rows(source_path)
        if len(rows) <= header_row:
            raise ValueError(
                f"Header row {header_row} out of range for {source_file} "
                f"(total rows={len(rows)})"
            )

        max_cols = max(len(r) for r in rows)
        raw_headers = list(rows[header_row]) + [""] * (max_cols - len(rows[header_row]))

        mandatory_indices: set[int] = set()
        for meta_row_idx in range(header_row):
            meta_row = list(rows[meta_row_idx]) + [""] * (max_cols - len(rows[meta_row_idx]))
            if len(meta_row) > max_cols:
                meta_row = meta_row[:max_cols]
            for i, value in enumerate(meta_row):
                if "mandatory" in clean_text(value).lower():
                    mandatory_indices.add(i)

        canonical_headers = dedupe_names(
            [normalize_column_name(value, i) for i, value in enumerate(raw_headers)],
            sep="_",
        )
        label_headers = dedupe_names(
            [normalize_column_label(value, i) for i, value in enumerate(raw_headers)],
            sep=" (",
            close_suffix=")",
        )

        header_map = [
            {
                "index": i,
                "raw_header": raw_headers[i],
                "label_header": label_headers[i],
                "canonical_header": canonical_headers[i],
                "is_mandatory": i in mandatory_indices,
            }
            for i in range(max_cols)
        ]

        cleaned_rows_for_csv: list[dict] = []
        cleaned_rows_for_jsonl: list[dict] = []

        table_mandatory_missing: Counter[str] = Counter()
        table_mandatory_total = 0
        table_mandatory_filled = 0

        for row_idx in range(header_row + 1, len(rows)):
            row = list(rows[row_idx]) + [""] * (max_cols - len(rows[row_idx]))
            if len(row) > max_cols:
                row = row[:max_cols]

            cleaned_values = [clean_text(value) for value in row]
            if not any(cleaned_values):
                continue

            # Skip accidental repeated header rows inside data.
            if all(
                cleaned_values[i].lower() == clean_text(raw_headers[i]).lower()
                for i in range(max_cols)
            ):
                continue

            source_row_number = row_idx + 1
            normalized_values: list[str] = []
            row_issues: list[dict[str, str]] = []
            for i in range(max_cols):
                field = canonical_headers[i]
                raw_value = cleaned_values[i]
                normalized_value, issues = normalize_field_value(
                    field=field,
                    value=raw_value,
                    source_row_number=source_row_number,
                )
                normalized_values.append(normalized_value)
                if normalized_value != raw_value:
                    total_changed_values += 1
                    normalized_change_counts_by_field[field] += 1
                for issue in issues:
                    normalized_change_counts_by_issue[issue["issue_type"]] += 1
                    row_issues.append(issue)

            values_by_col = dict(zip(canonical_headers, normalized_values))
            non_empty_fields = {
                key: value for key, value in values_by_col.items() if value != ""
            }
            label_value_pairs = [
                (label_headers[i], normalized_values[i])
                for i in range(max_cols)
                if normalized_values[i]
            ]

            source_counts[source_file] += 1
            table_counts[table] += 1
            record_seq = table_counts[table]
            record_id = f"{table}:{record_seq:06d}"
            primary_key = pick_primary_key(non_empty_fields)

            for idx in mandatory_indices:
                field = canonical_headers[idx]
                table_mandatory_total += 1
                if normalized_values[idx]:
                    table_mandatory_filled += 1
                else:
                    table_mandatory_missing[field] += 1

            for issue in row_issues:
                issue_counts[issue["issue_type"]] += 1
                issue_counts_by_table[table] += 1
                quality_issues.append(
                    {
                        "record_id": record_id,
                        "source_file": source_file,
                        "table": table,
                        "source_row_number": source_row_number,
                        **issue,
                    }
                )

            text = build_record_text(
                table=table,
                source_file=source_file,
                source_row_number=source_row_number,
                label_value_pairs=label_value_pairs,
            )
            word_count = len(text.split())

            record = {
                "record_id": record_id,
                "source_file": source_file,
                "table": table,
                "source_row_number": source_row_number,
                "primary_key": primary_key,
                "field_count": len(non_empty_fields),
                "word_count": word_count,
                "text": text,
                "fields": non_empty_fields,
            }
            all_records.append(record)

            chunk = {
                "chunk_id": f"{record_id}_c001",
                "record_id": record_id,
                "source_csv": source_file,
                "table": table,
                "source_row_number": source_row_number,
                "chunk_index_in_record": 1,
                "text": text,
                "word_count": word_count,
            }
            rag_chunks.append(chunk)

            cleaned_rows_for_csv.append(
                {
                    "record_id": record_id,
                    "source_row_number": source_row_number,
                    **values_by_col,
                }
            )
            cleaned_rows_for_jsonl.append(
                {
                    "record_id": record_id,
                    "source_file": source_file,
                    "table": table,
                    "source_row_number": source_row_number,
                    "fields": non_empty_fields,
                }
            )

        schema_summary.append(
            {
                "source_file": source_file,
                "table": table,
                "header_row_1_based": header_row + 1,
                "total_columns": max_cols,
                "total_clean_records": len(cleaned_rows_for_csv),
                "header_map": header_map,
            }
        )

        global_mandatory_total += table_mandatory_total
        global_mandatory_filled += table_mandatory_filled
        mandatory_stats_by_table[table] = {
            "source_file": source_file,
            "row_count": len(cleaned_rows_for_csv),
            "mandatory_columns": [canonical_headers[i] for i in sorted(mandatory_indices)],
            "mandatory_column_labels": [label_headers[i] for i in sorted(mandatory_indices)],
            "mandatory_total_cells": table_mandatory_total,
            "mandatory_filled_cells": table_mandatory_filled,
            "mandatory_missing_by_field": dict(table_mandatory_missing),
        }

        per_file_stem = Path(source_file).stem
        per_file_csv = normalized_dir / f"{per_file_stem}.cleaned.csv"
        per_file_jsonl = normalized_dir / f"{per_file_stem}.cleaned.jsonl"
        per_file_fieldnames = ["record_id", "source_row_number"] + canonical_headers
        write_csv(per_file_csv, cleaned_rows_for_csv, per_file_fieldnames)
        write_jsonl(per_file_jsonl, cleaned_rows_for_jsonl)

    # Combined records.
    records_jsonl_path = output_dir / "finsight_records.jsonl"
    records_csv_path = output_dir / "finsight_records.csv"
    records_csv_rows = [
        {
            "record_id": row["record_id"],
            "source_file": row["source_file"],
            "table": row["table"],
            "source_row_number": row["source_row_number"],
            "primary_key": row["primary_key"],
            "field_count": row["field_count"],
            "word_count": row["word_count"],
            "text": row["text"],
            "fields_json": json.dumps(row["fields"], ensure_ascii=False),
        }
        for row in all_records
    ]
    write_jsonl(records_jsonl_path, all_records)
    write_csv(
        records_csv_path,
        records_csv_rows,
        [
            "record_id",
            "source_file",
            "table",
            "source_row_number",
            "primary_key",
            "field_count",
            "word_count",
            "text",
            "fields_json",
        ],
    )

    # RAG chunks.
    rag_jsonl_path = output_dir / "rag_chunks.jsonl"
    rag_csv_path = output_dir / "rag_chunks.csv"
    write_jsonl(rag_jsonl_path, rag_chunks)
    write_csv(
        rag_csv_path,
        rag_chunks,
        [
            "chunk_id",
            "record_id",
            "source_csv",
            "table",
            "source_row_number",
            "chunk_index_in_record",
            "word_count",
            "text",
        ],
    )

    rag_manifest = {
        "generated_at": datetime.now(UTC).isoformat(),
        "input_directory": str(input_dir),
        "total_records": len(all_records),
        "total_chunks": len(rag_chunks),
        "sources": dict(source_counts),
        "tables": dict(table_counts),
        "outputs": {
            "finsight_records_jsonl": str(records_jsonl_path),
            "finsight_records_csv": str(records_csv_path),
            "rag_chunks_jsonl": str(rag_jsonl_path),
            "rag_chunks_csv": str(rag_csv_path),
        },
    }
    (output_dir / "rag_manifest.json").write_text(
        json.dumps(rag_manifest, indent=2),
        encoding="utf-8",
    )

    # Embedding-ready records.
    embedding_rows: list[dict] = []
    for row in rag_chunks:
        text = str(row["text"]).strip()
        text_sha256 = hashlib.sha256(text.encode("utf-8")).hexdigest()
        stable_key = "|".join(
            [
                str(row.get("source_csv", "")),
                str(row.get("chunk_id", "")),
                str(row.get("source_row_number", "")),
                text_sha256,
            ]
        )
        embedding_id = str(uuid.uuid5(uuid.NAMESPACE_URL, stable_key))
        metadata = {
            "chunk_id": row.get("chunk_id"),
            "record_id": row.get("record_id"),
            "source_csv": row.get("source_csv"),
            "table": row.get("table"),
            "source_row_number": row.get("source_row_number"),
            "chunk_index_in_record": row.get("chunk_index_in_record"),
            "word_count": row.get("word_count"),
            "text_sha256": text_sha256,
        }
        embedding_rows.append(
            {
                "embedding_id": embedding_id,
                "chunk_id": row.get("chunk_id"),
                "record_id": row.get("record_id"),
                "source_csv": row.get("source_csv"),
                "table": row.get("table"),
                "source_row_number": row.get("source_row_number"),
                "chunk_index_in_record": row.get("chunk_index_in_record"),
                "word_count": row.get("word_count"),
                "text_sha256": text_sha256,
                "text": text,
                "metadata": metadata,
            }
        )

    emb_jsonl_path = output_dir / "rag_embedding_records.jsonl"
    emb_csv_path = output_dir / "rag_embedding_records.csv"
    write_jsonl(emb_jsonl_path, embedding_rows)
    write_csv(
        emb_csv_path,
        embedding_rows,
        [
            "embedding_id",
            "chunk_id",
            "record_id",
            "source_csv",
            "table",
            "source_row_number",
            "chunk_index_in_record",
            "word_count",
            "text_sha256",
            "text",
        ],
    )

    embedding_manifest = {
        "generated_at": datetime.now(UTC).isoformat(),
        "input_jsonl": str(rag_jsonl_path),
        "total_records": len(embedding_rows),
        "sources": dict(source_counts),
        "tables": dict(table_counts),
        "fields": [
            "embedding_id",
            "chunk_id",
            "record_id",
            "source_csv",
            "table",
            "source_row_number",
            "chunk_index_in_record",
            "word_count",
            "text_sha256",
            "text",
            "metadata",
        ],
    }
    (output_dir / "rag_embedding_records_manifest.json").write_text(
        json.dumps(embedding_manifest, indent=2),
        encoding="utf-8",
    )

    (output_dir / "schema_summary.json").write_text(
        json.dumps(schema_summary, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    quality_issues_path = output_dir / "quality_issues.csv"
    write_csv(
        quality_issues_path,
        quality_issues,
        [
            "record_id",
            "source_file",
            "table",
            "source_row_number",
            "issue_type",
            "severity",
            "field",
            "raw_value",
            "normalized_value",
            "message",
        ],
    )

    mandatory_summary_rows = []
    for table, stats in mandatory_stats_by_table.items():
        total = stats["mandatory_total_cells"]
        filled = stats["mandatory_filled_cells"]
        coverage_pct = round((filled / total) * 100.0, 2) if total else None
        field_missing = []
        for field, missing in sorted(
            stats["mandatory_missing_by_field"].items(),
            key=lambda kv: kv[1],
            reverse=True,
        ):
            field_missing.append(
                {
                    "field": field,
                    "missing_cells": missing,
                }
            )
        mandatory_summary_rows.append(
            {
                "table": table,
                "source_file": stats["source_file"],
                "row_count": stats["row_count"],
                "mandatory_columns": stats["mandatory_columns"],
                "mandatory_total_cells": total,
                "mandatory_filled_cells": filled,
                "mandatory_coverage_pct": coverage_pct,
                "mandatory_missing_by_field": field_missing,
            }
        )

    global_coverage_pct = (
        round((global_mandatory_filled / global_mandatory_total) * 100.0, 2)
        if global_mandatory_total
        else None
    )

    quality_report = {
        "generated_at": datetime.now(UTC).isoformat(),
        "input_directory": str(input_dir),
        "total_records": len(all_records),
        "total_tables": len(table_counts),
        "total_sources": len(source_counts),
        "normalization": {
            "total_changed_values": total_changed_values,
            "changed_by_field": dict(normalized_change_counts_by_field.most_common()),
            "changed_by_issue_type": dict(normalized_change_counts_by_issue.most_common()),
        },
        "issues": {
            "total_issues": len(quality_issues),
            "by_type": dict(issue_counts.most_common()),
            "by_table": dict(issue_counts_by_table.most_common()),
            "example_issues": quality_issues[:50],
        },
        "mandatory_quality": {
            "global": {
                "mandatory_total_cells": global_mandatory_total,
                "mandatory_filled_cells": global_mandatory_filled,
                "mandatory_coverage_pct": global_coverage_pct,
            },
            "per_table": mandatory_summary_rows,
        },
        "outputs": {
            "quality_issues_csv": str(quality_issues_path),
        },
    }
    quality_report_path = output_dir / "quality_report.json"
    quality_report_path.write_text(
        json.dumps(quality_report, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    print(f"Input directory: {input_dir}")
    print(f"Output directory: {output_dir}")
    print(f"Total cleaned records: {len(all_records)}")
    for source, count in sorted(source_counts.items()):
        print(f"  {source}: {count}")
    print(f"Total normalized value changes: {total_changed_values}")
    print(f"Total quality issues: {len(quality_issues)}")
    if global_coverage_pct is not None:
        print(
            "Mandatory cell coverage: "
            f"{global_coverage_pct:.2f}% ({global_mandatory_filled}/{global_mandatory_total})"
        )
    print(f"Wrote {records_jsonl_path}")
    print(f"Wrote {records_csv_path}")
    print(f"Wrote {rag_jsonl_path}")
    print(f"Wrote {rag_csv_path}")
    print(f"Wrote {output_dir / 'rag_manifest.json'}")
    print(f"Wrote {emb_jsonl_path}")
    print(f"Wrote {emb_csv_path}")
    print(f"Wrote {output_dir / 'rag_embedding_records_manifest.json'}")
    print(f"Wrote {output_dir / 'schema_summary.json'}")
    print(f"Wrote {quality_report_path}")
    print(f"Wrote {quality_issues_path}")


if __name__ == "__main__":
    main()
