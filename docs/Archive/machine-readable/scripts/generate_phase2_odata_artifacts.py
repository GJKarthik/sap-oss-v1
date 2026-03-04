#!/usr/bin/env python3
"""
Generate Phase 2 OData schema + vocabulary artifacts from Phase 0 outputs.

Inputs (relative to this script):
  - ../hana_phase0/phase0_target_schemas.yaml
  - ../hana_phase0/phase0_field_catalog.json
  - ../../../../odata-vocabularies-main/vocabularies/Common.xml
  - ../../../../odata-vocabularies-main/vocabularies/PersonalData.xml

Outputs (default):
  - ../odata_phase2/finsight_schema.edmx
  - ../odata_phase2/finsight_column_annotations.json
  - ../odata_phase2/finsight_derived_checks.json
  - ../odata_phase2/phase2_validation_report.json
"""

from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from xml.dom import minidom

import yaml


EDMX_NS = "http://docs.oasis-open.org/odata/ns/edmx"
EDM_NS = "http://docs.oasis-open.org/odata/ns/edm"

COMMON_NS = "com.sap.vocabularies.Common.v1"
PERSONAL_NS = "com.sap.vocabularies.PersonalData.v1"

COMMON_URI = "https://sap.github.io/odata-vocabularies/vocabularies/Common.xml"
PERSONAL_URI = "https://sap.github.io/odata-vocabularies/vocabularies/PersonalData.xml"


RECORD_TEMPLATE_COLUMNS = [
    ("record_id", "NVARCHAR(120)", False, "Deterministic row identifier"),
    ("source_file", "NVARCHAR(255)", False, "Input source file key"),
    ("source_table", "NVARCHAR(120)", False, "Normalized source table name"),
    ("source_row_number", "BIGINT", False, "Source row ordinal"),
]

TABLE_COLUMN_TEMPLATES: dict[str, list[tuple[str, str, bool, str]]] = {
    "FINSIGHT_CORE.FIELDS": [
        ("record_id", "NVARCHAR(120)", False, "Parent record identifier"),
        ("field_name", "NVARCHAR(255)", False, "Normalized field name"),
        ("field_value", "NVARCHAR(5000)", True, "Raw field value as text"),
        ("source_table", "NVARCHAR(120)", True, "Origin table"),
        ("source_file", "NVARCHAR(255)", True, "Origin source file"),
    ],
    "FINSIGHT_CORE.SOURCE_FILES": [
        ("source_file", "NVARCHAR(255)", False, "Source file key"),
        ("source_table", "NVARCHAR(120)", True, "Primary logical table"),
        ("row_count", "BIGINT", True, "Observed row count"),
        ("last_seen_utc", "TIMESTAMP", True, "Last processing timestamp"),
    ],
    "FINSIGHT_RAG.CHUNKS": [
        ("chunk_id", "NVARCHAR(120)", False, "Chunk identifier"),
        ("record_id", "NVARCHAR(120)", False, "Back-reference to RECORDS"),
        ("chunk_index", "BIGINT", False, "Chunk ordinal"),
        ("text", "NCLOB", True, "Chunk text"),
        ("token_estimate", "BIGINT", True, "Approximate token count"),
    ],
    "FINSIGHT_RAG.EMBEDDINGS": [
        ("embedding_id", "NVARCHAR(120)", False, "Embedding record identifier"),
        ("chunk_id", "NVARCHAR(120)", False, "Back-reference to CHUNKS"),
        ("model_name", "NVARCHAR(255)", True, "Embedding model"),
        ("vector_dim", "BIGINT", True, "Embedding dimension"),
        ("vector_payload", "NCLOB", True, "Serialized vector payload"),
        ("text_sha256", "NVARCHAR(80)", True, "Chunk text hash"),
    ],
    "FINSIGHT_RAG.EMBEDDING_MANIFEST": [
        ("run_id", "NVARCHAR(120)", False, "Embedding run identifier"),
        ("generated_at_utc", "TIMESTAMP", True, "Generation timestamp"),
        ("record_count", "BIGINT", True, "Rows generated in run"),
        ("model_name", "NVARCHAR(255)", True, "Embedding model"),
        ("manifest_json", "NCLOB", True, "Run manifest payload"),
    ],
    "FINSIGHT_GOV.QUALITY_ISSUES": [
        ("record_id", "NVARCHAR(120)", False, "Affected record"),
        ("issue_type", "NVARCHAR(120)", False, "Issue type"),
        ("field", "NVARCHAR(255)", False, "Affected field"),
        ("source_row_number", "BIGINT", False, "Source row ordinal"),
        ("issue_detail", "NVARCHAR(2000)", True, "Issue details"),
    ],
    "FINSIGHT_GOV.QUALITY_REPORTS": [
        ("report_id", "NVARCHAR(120)", False, "Report identifier"),
        ("generated_at_utc", "TIMESTAMP", True, "Report timestamp"),
        ("mandatory_coverage_pct", "DECIMAL(10,4)", True, "Mandatory coverage"),
        ("total_issues", "BIGINT", True, "Total quality issues"),
        ("report_json", "NCLOB", True, "Full report payload"),
    ],
    "FINSIGHT_GOV.TABLE_PROFILE": [
        ("table_name", "NVARCHAR(255)", False, "Table name"),
        ("report_id", "NVARCHAR(120)", False, "Foreign key to report"),
        ("mandatory_fields", "BIGINT", True, "Mandatory field count"),
        ("populated_mandatory_fields", "BIGINT", True, "Populated mandatory field count"),
        ("coverage_pct", "DECIMAL(10,4)", True, "Coverage percentage"),
    ],
    "FINSIGHT_GOV.ODPS_VALIDATION": [
        ("validation_run_id", "NVARCHAR(120)", False, "Validation run identifier"),
        ("generated_at_utc", "TIMESTAMP", True, "Validation timestamp"),
        ("is_valid", "NVARCHAR(10)", True, "Overall validation status"),
        ("schema_error_count", "BIGINT", True, "Schema error count"),
        ("missing_link_count", "BIGINT", True, "Broken/missing link count"),
        ("report_json", "NCLOB", True, "Validation report payload"),
    ],
    "FINSIGHT_GRAPH.VERTEX": [
        ("vertex_id", "NVARCHAR(120)", False, "Vertex identifier"),
        ("vertex_type", "NVARCHAR(120)", True, "Vertex type"),
        ("label", "NVARCHAR(500)", True, "Display label"),
        ("payload_json", "NCLOB", True, "Vertex payload"),
    ],
    "FINSIGHT_GRAPH.EDGE": [
        ("edge_id", "NVARCHAR(120)", False, "Edge identifier"),
        ("edge_type", "NVARCHAR(120)", True, "Edge type"),
        ("source_vertex_id", "NVARCHAR(120)", True, "Source vertex"),
        ("target_vertex_id", "NVARCHAR(120)", True, "Target vertex"),
        ("payload_json", "NCLOB", True, "Edge payload"),
    ],
    "FINSIGHT_GRAPH.EDGE_TYPE": [
        ("edge_type", "NVARCHAR(120)", False, "Edge type code"),
        ("description", "NVARCHAR(500)", True, "Edge type description"),
    ],
}

DIGIT_SEQUENCE_COLUMNS = {
    "source_row_number",
    "chunk_index",
    "token_estimate",
    "vector_dim",
    "record_count",
    "schema_error_count",
    "missing_link_count",
    "total_issues",
    "mandatory_fields",
    "populated_mandatory_fields",
}

UPPERCASE_COLUMNS = {
    "btp_schema_name",
    "unique_id",
    "edge_type",
}

PERSONAL_COLUMNS = {
    "requester",
}

SENSITIVE_COLUMNS = {
    "personal_data",
    "sensitivity",
}


@dataclass
class ColumnSpec:
    name: str
    hana_type: str
    edm_type: str
    nullable: bool
    description: str = ""
    annotations: list[str] = field(default_factory=list)
    annotation_reasons: list[str] = field(default_factory=list)


@dataclass
class TableSpec:
    schema_name: str
    table_name: str
    table_key: str
    description: str
    primary_key: list[str]
    columns: dict[str, ColumnSpec] = field(default_factory=dict)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate Phase 2 OData artifacts")
    parser.add_argument(
        "--phase0-dir",
        default="../hana_phase0",
        help="Directory containing Phase 0 baseline outputs (relative to script dir)",
    )
    parser.add_argument(
        "--output-dir",
        default="../odata_phase2",
        help="Directory to write Phase 2 artifacts (relative to script dir)",
    )
    parser.add_argument(
        "--vocab-dir",
        default="../../../../odata-vocabularies-main/vocabularies",
        help="Path to SAP OData vocabularies folder (relative to script dir)",
    )
    parser.add_argument(
        "--copilot-root",
        default="../../../../data-cleaning-copilot-main",
        help="Path to data-cleaning-copilot root (relative to script dir)",
    )
    return parser.parse_args()


def safe_load_yaml(path: Path) -> dict[str, Any]:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def map_hana_type_to_edm(hana_type: str) -> str:
    normalized = hana_type.strip().upper()
    if normalized.startswith(("NVARCHAR", "VARCHAR", "NCLOB", "CLOB", "CHAR")):
        return "Edm.String"
    if normalized.startswith(("SMALLINT", "INTEGER", "INT")):
        return "Edm.Int32"
    if normalized.startswith("BIGINT"):
        return "Edm.Int64"
    if normalized.startswith("DECIMAL"):
        return "Edm.Decimal"
    if normalized.startswith("DATE"):
        return "Edm.Date"
    if normalized.startswith(("TIMESTAMP", "SECONDDATE")):
        return "Edm.DateTimeOffset"
    if normalized.startswith("BOOLEAN"):
        return "Edm.Boolean"
    return "Edm.String"


def guess_hana_type(column_name: str) -> str:
    if column_name in DIGIT_SEQUENCE_COLUMNS:
        return "BIGINT"
    if column_name.endswith("_utc") or column_name.endswith("_at"):
        return "TIMESTAMP"
    if column_name.startswith("is_") or column_name in {"is_valid"}:
        return "NVARCHAR(10)"
    return "NVARCHAR(255)"


def extract_vocabulary_terms(path: Path) -> dict[str, Any]:
    ns = {"edm": EDM_NS}
    tree = ET.parse(path)
    root = tree.getroot()
    schema = root.find(".//edm:Schema", ns)
    if schema is None:
        raise ValueError(f"No Schema element found in {path}")

    namespace = schema.get("Namespace", "")
    alias = schema.get("Alias", "")
    terms: dict[str, dict[str, str]] = {}

    for term in schema.findall("edm:Term", ns):
        name = term.get("Name")
        if not name:
            continue
        qualified = f"{namespace}.{name}"
        terms[qualified] = {
            "qualified_name": qualified,
            "name": name,
            "type": term.get("Type", ""),
            "applies_to": term.get("AppliesTo", ""),
        }

    return {
        "path": str(path),
        "namespace": namespace,
        "alias": alias,
        "terms": terms,
    }


def add_column(table: TableSpec, name: str, hana_type: str, nullable: bool, description: str) -> None:
    if name in table.columns:
        return
    table.columns[name] = ColumnSpec(
        name=name,
        hana_type=hana_type,
        edm_type=map_hana_type_to_edm(hana_type),
        nullable=nullable,
        description=description,
    )


def build_table_specs(target_schema: dict[str, Any], field_catalog: dict[str, Any]) -> list[TableSpec]:
    row_count = int(field_catalog.get("row_count", 0))
    field_rows = field_catalog.get("fields", [])
    field_by_name = {row["field_name"]: row for row in field_rows}
    specs: list[TableSpec] = []

    for schema_name, schema_info in target_schema.get("schemas", {}).items():
        tables = schema_info.get("tables", {})
        for table_name, table_info in tables.items():
            table_key = f"{schema_name}_{table_name}"
            primary_key = list(table_info.get("primary_key", []))
            spec = TableSpec(
                schema_name=schema_name,
                table_name=table_name,
                table_key=table_key,
                description=table_info.get("description", ""),
                primary_key=primary_key,
            )

            if schema_name == "FINSIGHT_CORE" and table_name == "RECORDS":
                for name, hana_type, nullable, description in RECORD_TEMPLATE_COLUMNS:
                    add_column(spec, name, hana_type, nullable, description)
                for row in field_rows:
                    field_name = row["field_name"]
                    nullable = int(row.get("presence_count", 0)) < row_count
                    add_column(
                        spec,
                        field_name,
                        row.get("suggested_hana_type", "NVARCHAR(255)"),
                        nullable,
                        "Profile-derived field from Phase 0 field catalog",
                    )
            else:
                template_key = f"{schema_name}.{table_name}"
                for name, hana_type, nullable, description in TABLE_COLUMN_TEMPLATES.get(template_key, []):
                    add_column(spec, name, hana_type, nullable, description)

            for key_col in primary_key:
                if key_col not in spec.columns:
                    inferred_type = field_by_name.get(key_col, {}).get(
                        "suggested_hana_type",
                        guess_hana_type(key_col),
                    )
                    add_column(
                        spec,
                        key_col,
                        inferred_type,
                        False,
                        "Primary key column from target schema blueprint",
                    )
                spec.columns[key_col].nullable = False

            specs.append(spec)

    return specs


def infer_annotation_terms(column_name: str) -> list[tuple[str, str]]:
    terms: list[tuple[str, str]] = []

    if column_name in DIGIT_SEQUENCE_COLUMNS:
        terms.append(
            (
                f"{COMMON_NS}.IsDigitSequence",
                "Numeric sequence column used for row/index/count semantics",
            )
        )
    if column_name in UPPERCASE_COLUMNS:
        terms.append(
            (
                f"{COMMON_NS}.IsUpperCase",
                "Technical code/identifier expected in uppercase format",
            )
        )
    if column_name in PERSONAL_COLUMNS:
        terms.append(
            (
                f"{PERSONAL_NS}.IsPotentiallyPersonal",
                "Column may contain a natural person identifier",
            )
        )
    if column_name in SENSITIVE_COLUMNS:
        terms.append(
            (
                f"{PERSONAL_NS}.IsPotentiallySensitive",
                "Column carries sensitivity/personal-data classification metadata",
            )
        )

    return terms


def apply_annotations(
    specs: list[TableSpec], available_terms: set[str]
) -> tuple[dict[str, dict[str, list[str]]], list[dict[str, Any]], list[str]]:
    table_annotations_short: dict[str, dict[str, list[str]]] = {}
    annotation_rows: list[dict[str, Any]] = []
    missing_vocab_terms: set[str] = set()

    for table in specs:
        table_annotations_short[table.table_key] = {}
        for column in table.columns.values():
            selected_terms: list[str] = []
            selected_reasons: list[str] = []

            for qualified, reason in infer_annotation_terms(column.name):
                if qualified not in available_terms:
                    missing_vocab_terms.add(qualified)
                    continue
                selected_terms.append(qualified)
                selected_reasons.append(reason)

            if not selected_terms:
                continue

            column.annotations = selected_terms
            column.annotation_reasons = selected_reasons
            short_terms = [term.split(".")[-1] for term in selected_terms]
            table_annotations_short[table.table_key][column.name] = short_terms

            annotation_rows.append(
                {
                    "schema": table.schema_name,
                    "table": table.table_name,
                    "table_key": table.table_key,
                    "column": column.name,
                    "qualified_terms": selected_terms,
                    "short_terms": short_terms,
                    "reasons": selected_reasons,
                }
            )

    return table_annotations_short, annotation_rows, sorted(missing_vocab_terms)


def build_edmx(specs: list[TableSpec]) -> str:
    ET.register_namespace("edmx", EDMX_NS)

    root = ET.Element(f"{{{EDMX_NS}}}Edmx", Version="4.0")
    ref_common = ET.SubElement(root, f"{{{EDMX_NS}}}Reference", Uri=COMMON_URI)
    ET.SubElement(
        ref_common,
        f"{{{EDMX_NS}}}Include",
        Namespace=COMMON_NS,
        Alias="Common",
    )
    ref_personal = ET.SubElement(root, f"{{{EDMX_NS}}}Reference", Uri=PERSONAL_URI)
    ET.SubElement(
        ref_personal,
        f"{{{EDMX_NS}}}Include",
        Namespace=PERSONAL_NS,
        Alias="PersonalData",
    )

    data_services = ET.SubElement(root, f"{{{EDMX_NS}}}DataServices")
    schema = ET.SubElement(
        data_services,
        f"{{{EDM_NS}}}Schema",
        Namespace="FinSight.Service",
        Alias="FinSight",
    )

    for table in specs:
        entity = ET.SubElement(schema, f"{{{EDM_NS}}}EntityType", Name=table.table_key)
        if table.primary_key:
            key = ET.SubElement(entity, f"{{{EDM_NS}}}Key")
            for key_col in table.primary_key:
                ET.SubElement(key, f"{{{EDM_NS}}}PropertyRef", Name=key_col)

        for column in table.columns.values():
            prop_attrs = {
                "Name": column.name,
                "Type": column.edm_type,
            }
            if not column.nullable:
                prop_attrs["Nullable"] = "false"
            prop = ET.SubElement(entity, f"{{{EDM_NS}}}Property", prop_attrs)
            for qualified in column.annotations:
                short_name = qualified.split(".")[-1]
                if qualified.startswith(COMMON_NS):
                    term = f"Common.{short_name}"
                elif qualified.startswith(PERSONAL_NS):
                    term = f"PersonalData.{short_name}"
                else:
                    continue
                ET.SubElement(prop, f"{{{EDM_NS}}}Annotation", Term=term)

    container = ET.SubElement(schema, f"{{{EDM_NS}}}EntityContainer", Name="Container")
    for table in specs:
        ET.SubElement(
            container,
            f"{{{EDM_NS}}}EntitySet",
            Name=table.table_key,
            EntityType=f"FinSight.Service.{table.table_key}",
        )

    rough_xml = ET.tostring(root, encoding="utf-8")
    pretty_xml = minidom.parseString(rough_xml).toprettyxml(indent="  ")
    lines = [line for line in pretty_xml.splitlines() if line.strip()]
    return "\n".join(lines) + "\n"


FALLBACK_REGEX_PATTERNS: dict[str, str] = {
    "IsDigitSequence": r"\d+",
    "IsCurrency": r"[A-Z]{3}",
    "IsUnit": r"[A-Za-z0-9]{1,3}",
    "IsLanguageIdentifier": r"[a-z]{2,3}(-[A-Z]{2})?(-[A-Za-z]{4})?",
    "IsTimezone": r"([A-Za-z_]+/[A-Za-z_]+|UTC([+-]\d{1,2}(:\d{2})?)?)",
    "IsCalendarYear": r"-?([1-9][0-9]{3,}|0[0-9]{3})",
    "IsCalendarHalfyear": r"[1-2]",
    "IsCalendarQuarter": r"[1-4]",
    "IsCalendarMonth": r"0[1-9]|1[0-2]",
    "IsCalendarWeek": r"0[1-9]|[1-4][0-9]|5[0-3]",
    "IsCalendarYearHalfyear": r"-?([1-9][0-9]{3,}|0[0-9]{3})[1-2]",
    "IsCalendarYearQuarter": r"-?([1-9][0-9]{3,}|0[0-9]{3})[1-4]",
    "IsCalendarYearMonth": r"-?([1-9][0-9]{3,}|0[0-9]{3})(0[1-9]|1[0-2])",
    "IsCalendarYearWeek": r"-?([1-9][0-9]{3,}|0[0-9]{3})(0[1-9]|[1-4][0-9]|5[0-3])",
    "IsCalendarDate": r"-?([1-9][0-9]{3,}|0[0-9]{3})(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])",
    "IsFiscalYear": r"[1-9][0-9]{3}",
    "IsFiscalPeriod": r"[0-9]{3}",
    "IsFiscalYearPeriod": r"([1-9][0-9]{3})([0-9]{3})",
    "IsFiscalQuarter": r"[1-4]",
    "IsFiscalYearQuarter": r"[1-9][0-9]{3}[1-4]",
    "IsFiscalWeek": r"0[1-9]|[1-4][0-9]|5[0-3]",
    "IsFiscalYearWeek": r"[1-9][0-9]{3}(0[1-9]|[1-4][0-9]|5[0-3])",
}


def build_regex_check_payload(
    table_name: str,
    column_name: str,
    term_name: str,
    regex_pattern: str,
) -> dict[str, Any]:
    fn_name = f"OData_{table_name}_{column_name}_{term_name}"
    pattern_literal = json.dumps(f"^{regex_pattern}$")
    return {
        "function_name": fn_name,
        "description": f"OData {term_name} regex validation for {table_name}.{column_name}",
        "scope": [(table_name, column_name)],
        "parameters": "tables: Mapping[str, pd.DataFrame]",
        "imports": ["import pandas as pd", "import re"],
        "body_lines": [
            "    violations = {}",
            f"    table_df = tables.get('{table_name}', pd.DataFrame())",
            "    if table_df.empty:",
            "        return violations",
            f"    if '{column_name}' not in table_df.columns:",
            "        return violations",
            f"    col = table_df['{column_name}']",
            "    mask = col.notna() & (col.astype(str).str.strip() != '')",
            "    if not mask.any():",
            "        return violations",
            f"    pattern = re.compile({pattern_literal})",
            "    invalid_mask = mask & ~col.astype(str).str.match(pattern, na=False)",
            "    if invalid_mask.any():",
            "        invalid_indices = table_df.index[invalid_mask].tolist()",
            f"        violations['{table_name}'] = pd.Series(invalid_indices, name='{column_name}')",
        ],
        "return_statement": "violations",
        "sql": None,
    }


def build_uppercase_check_payload(table_name: str, column_name: str) -> dict[str, Any]:
    fn_name = f"OData_{table_name}_{column_name}_IsUpperCase"
    return {
        "function_name": fn_name,
        "description": f"OData IsUpperCase validation for {table_name}.{column_name}",
        "scope": [(table_name, column_name)],
        "parameters": "tables: Mapping[str, pd.DataFrame]",
        "imports": ["import pandas as pd"],
        "body_lines": [
            "    violations = {}",
            f"    table_df = tables.get('{table_name}', pd.DataFrame())",
            "    if table_df.empty:",
            "        return violations",
            f"    if '{column_name}' not in table_df.columns:",
            "        return violations",
            f"    col = table_df['{column_name}']",
            "    mask = col.notna() & (col.astype(str).str.strip() != '')",
            "    if not mask.any():",
            "        return violations",
            "    str_col = col[mask].astype(str)",
            "    invalid_mask = mask.copy()",
            "    invalid_mask[mask] = ~str_col.str.upper().eq(str_col)",
            "    if invalid_mask.any():",
            "        invalid_indices = table_df.index[invalid_mask].tolist()",
            f"        violations['{table_name}'] = pd.Series(invalid_indices, name='{column_name}')",
        ],
        "return_statement": "violations",
        "sql": None,
    }


def build_fallback_checks(annotations_short: dict[str, dict[str, list[str]]]) -> dict[str, dict[str, Any]]:
    checks: dict[str, dict[str, Any]] = {}
    for table_name, column_annotations in annotations_short.items():
        for column_name, terms in column_annotations.items():
            for term_name in terms:
                payload: dict[str, Any] | None = None
                if term_name == "IsUpperCase":
                    payload = build_uppercase_check_payload(table_name, column_name)
                elif term_name in FALLBACK_REGEX_PATTERNS:
                    payload = build_regex_check_payload(
                        table_name=table_name,
                        column_name=column_name,
                        term_name=term_name,
                        regex_pattern=FALLBACK_REGEX_PATTERNS[term_name],
                    )
                if payload:
                    checks[payload["function_name"]] = payload
    return checks


def derive_checks_with_copilot(
    annotations_short: dict[str, dict[str, list[str]]],
    copilot_root: Path,
    common_xml: Path,
    personal_xml: Path,
) -> dict[str, Any]:
    output: dict[str, Any] = {"status": "skipped", "error": None, "checks": {}}

    if not copilot_root.exists():
        output["error"] = f"data-cleaning-copilot root not found: {copilot_root}"
        return output

    added_to_sys_path = False
    try:
        sys.path.insert(0, str(copilot_root))
        added_to_sys_path = True

        from definition.odata.database_integration import derive_odata_checks
        from definition.odata.vocabulary_parser import ODataVocabularyParser, ValidationTermRegistry

        parser = ODataVocabularyParser()
        registry = ValidationTermRegistry()
        for vocab_path in (common_xml, personal_xml):
            if vocab_path.exists():
                parsed = parser.parse_file(vocab_path)
                registry.register_vocabulary(parsed)

        checks = derive_odata_checks(annotations_short, registry)
        output["checks"] = {name: check.to_dict() for name, check in checks.items()}
        output["status"] = "generated"
        return output
    except Exception as exc:  # noqa: BLE001 - graceful optional integration fallback
        output["error"] = f"{type(exc).__name__}: {exc}"
        fallback_checks = build_fallback_checks(annotations_short)
        if fallback_checks:
            output["status"] = "generated_fallback"
            output["checks"] = fallback_checks
        return output
    finally:
        if added_to_sys_path and str(copilot_root) in sys.path:
            sys.path.remove(str(copilot_root))


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    phase0_dir = (script_dir / args.phase0_dir).resolve()
    output_dir = (script_dir / args.output_dir).resolve()
    vocab_dir = (script_dir / args.vocab_dir).resolve()
    copilot_root = (script_dir / args.copilot_root).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    target_schema_path = phase0_dir / "phase0_target_schemas.yaml"
    field_catalog_path = phase0_dir / "phase0_field_catalog.json"
    common_xml_path = vocab_dir / "Common.xml"
    personal_xml_path = vocab_dir / "PersonalData.xml"

    target_schema = safe_load_yaml(target_schema_path)
    field_catalog = json.loads(field_catalog_path.read_text(encoding="utf-8"))

    common_vocab = extract_vocabulary_terms(common_xml_path)
    personal_vocab = extract_vocabulary_terms(personal_xml_path)
    available_terms = set(common_vocab["terms"]) | set(personal_vocab["terms"])

    table_specs = build_table_specs(target_schema, field_catalog)
    annotations_short, annotation_rows, missing_vocab_terms = apply_annotations(
        table_specs,
        available_terms,
    )

    edmx_path = output_dir / "finsight_schema.edmx"
    edmx_path.write_text(build_edmx(table_specs), encoding="utf-8")

    annotations_json_path = output_dir / "finsight_column_annotations.json"
    annotations_payload = {
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "source_inputs": {
            "phase0_target_schemas": str(target_schema_path),
            "phase0_field_catalog": str(field_catalog_path),
            "common_vocabulary": str(common_xml_path),
            "personaldata_vocabulary": str(personal_xml_path),
        },
        "vocabularies": [
            {
                "namespace": common_vocab["namespace"],
                "alias": common_vocab["alias"],
                "term_count": len(common_vocab["terms"]),
            },
            {
                "namespace": personal_vocab["namespace"],
                "alias": personal_vocab["alias"],
                "term_count": len(personal_vocab["terms"]),
            },
        ],
        "table_annotations": annotations_short,
        "column_annotations": annotation_rows,
    }
    annotations_json_path.write_text(
        json.dumps(annotations_payload, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    derived_checks = derive_checks_with_copilot(
        annotations_short=annotations_short,
        copilot_root=copilot_root,
        common_xml=common_xml_path,
        personal_xml=personal_xml_path,
    )

    derived_checks_path = output_dir / "finsight_derived_checks.json"
    derived_checks_payload = {
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "status": derived_checks["status"],
        "error": derived_checks["error"],
        "checks": derived_checks["checks"],
        "check_count": len(derived_checks["checks"]),
    }
    derived_checks_path.write_text(
        json.dumps(derived_checks_payload, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    total_columns = sum(len(table.columns) for table in table_specs)
    annotated_columns = len(annotation_rows)
    total_annotations = sum(len(item["qualified_terms"]) for item in annotation_rows)
    terms_used = sorted(
        {
            term
            for row in annotation_rows
            for term in row["qualified_terms"]
        }
    )

    check_names = set(derived_checks["checks"])
    unmapped_terms: list[dict[str, str]] = []
    if derived_checks["status"].startswith("generated"):
        for row in annotation_rows:
            table_key = row["table_key"]
            column = row["column"]
            for term in row["short_terms"]:
                expected = f"OData_{table_key}_{column}_{term}"
                if expected not in check_names:
                    unmapped_terms.append(
                        {
                            "table_key": table_key,
                            "column": column,
                            "term": term,
                        }
                    )

    report = {
        "phase": "Phase 2 - OData Vocabulary Projection",
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "inputs": {
            "phase0_target_schemas": str(target_schema_path),
            "phase0_field_catalog": str(field_catalog_path),
            "common_vocabulary": str(common_xml_path),
            "personaldata_vocabulary": str(personal_xml_path),
            "copilot_root": str(copilot_root),
        },
        "outputs": {
            "schema_edmx": str(edmx_path),
            "column_annotations": str(annotations_json_path),
            "derived_checks": str(derived_checks_path),
        },
        "coverage": {
            "table_count": len(table_specs),
            "total_columns": total_columns,
            "annotated_columns": annotated_columns,
            "column_coverage_pct": round((annotated_columns / total_columns) * 100, 2)
            if total_columns
            else 0.0,
            "total_annotations": total_annotations,
        },
        "terms": {
            "used_count": len(terms_used),
            "used_terms": terms_used,
            "missing_in_vocab_count": len(missing_vocab_terms),
            "missing_in_vocab_terms": missing_vocab_terms,
            "unmapped_to_checks_count": len(unmapped_terms),
            "unmapped_to_checks": unmapped_terms,
        },
        "derived_checks": {
            "status": derived_checks["status"],
            "error": derived_checks["error"],
            "check_count": len(derived_checks["checks"]),
        },
    }
    report_path = output_dir / "phase2_validation_report.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"Phase 0 dir: {phase0_dir}")
    print(f"Vocab dir: {vocab_dir}")
    print(f"Output dir: {output_dir}")
    print(f"Tables projected: {len(table_specs)}")
    print(f"Columns projected: {total_columns}")
    print(f"Annotated columns: {annotated_columns}")
    print(f"Derived checks status: {derived_checks['status']}")
    print(f"Wrote {edmx_path}")
    print(f"Wrote {annotations_json_path}")
    print(f"Wrote {derived_checks_path}")
    print(f"Wrote {report_path}")


if __name__ == "__main__":
    main()
