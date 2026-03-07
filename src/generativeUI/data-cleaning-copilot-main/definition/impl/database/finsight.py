# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
FinSight database integration for data-cleaning-copilot.

Phase 3 scope:
- Load table schema from Phase 2 OData EDMX (`finsight_schema.edmx`)
- Build Table classes dynamically for copilot interaction
- Load machine-readable FinSight datasets into those tables
- Preload Phase 2 derived OData checks into the copilot database session
"""

from __future__ import annotations

import json
import uuid
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pandas as pd
import pandera.pandas as pa
from loguru import logger

from definition.base.database import Database
from definition.base.executable_code import CheckLogic
from definition.base.table import Table


EDM_NS = "http://docs.oasis-open.org/odata/ns/edm"


DEFAULT_MACHINE_READABLE_DIR = Path(__file__).resolve().parents[4] / "docs/Archive/machine-readable"
DEFAULT_PHASE2_DIR = DEFAULT_MACHINE_READABLE_DIR / "odata_phase2"
DEFAULT_EDMX_PATH = DEFAULT_PHASE2_DIR / "finsight_schema.edmx"
DEFAULT_DERIVED_CHECKS_PATH = DEFAULT_PHASE2_DIR / "finsight_derived_checks.json"


@dataclass
class ColumnSpec:
    name: str
    edm_type: str
    nullable: bool


@dataclass
class TableSpec:
    table_name: str
    primary_keys: list[str]
    columns: list[ColumnSpec]


FOREIGN_KEYS: dict[str, dict[str, tuple[str, str]]] = {
    "FINSIGHT_CORE_FIELDS": {
        "record_id": ("FINSIGHT_CORE_RECORDS", "record_id"),
    },
    "FINSIGHT_RAG_CHUNKS": {
        "record_id": ("FINSIGHT_CORE_RECORDS", "record_id"),
    },
    "FINSIGHT_RAG_EMBEDDINGS": {
        "chunk_id": ("FINSIGHT_RAG_CHUNKS", "chunk_id"),
    },
    "FINSIGHT_GOV_QUALITY_ISSUES": {
        "record_id": ("FINSIGHT_CORE_RECORDS", "record_id"),
    },
    "FINSIGHT_GOV_TABLE_PROFILE": {
        "report_id": ("FINSIGHT_GOV_QUALITY_REPORTS", "report_id"),
    },
    "FINSIGHT_GRAPH_EDGE": {
        "source_vertex_id": ("FINSIGHT_GRAPH_VERTEX", "vertex_id"),
        "target_vertex_id": ("FINSIGHT_GRAPH_VERTEX", "vertex_id"),
    },
}


def _edm_to_python_type(edm_type: str) -> type[Any]:
    normalized = edm_type.strip()
    if normalized in {"Edm.Int16", "Edm.Int32", "Edm.Int64", "Edm.Byte", "Edm.SByte"}:
        return int
    if normalized in {"Edm.Decimal", "Edm.Double", "Edm.Single"}:
        return float
    if normalized in {"Edm.Boolean"}:
        return bool
    if normalized in {"Edm.Date", "Edm.DateTime", "Edm.DateTimeOffset", "Edm.Time", "Edm.TimeOfDay"}:
        return Any
    return str


def _parse_phase2_edmx(edmx_path: Path) -> list[TableSpec]:
    if not edmx_path.exists():
        raise FileNotFoundError(f"Phase 2 EDMX not found: {edmx_path}")

    tree = ET.parse(edmx_path)
    root = tree.getroot()
    ns = {"edm": EDM_NS}
    schema = root.find(".//edm:Schema", ns)
    if schema is None:
        raise ValueError(f"No edm:Schema found in {edmx_path}")

    specs: list[TableSpec] = []
    for entity in schema.findall("edm:EntityType", ns):
        table_name = entity.get("Name", "")
        if not table_name:
            continue

        key_elem = entity.find("edm:Key", ns)
        primary_keys: list[str] = []
        if key_elem is not None:
            primary_keys = [ref.get("Name", "") for ref in key_elem.findall("edm:PropertyRef", ns) if ref.get("Name")]

        columns: list[ColumnSpec] = []
        for prop in entity.findall("edm:Property", ns):
            col_name = prop.get("Name")
            col_type = prop.get("Type", "Edm.String")
            nullable = prop.get("Nullable", "true").lower() == "true"
            if not col_name:
                continue
            columns.append(ColumnSpec(name=col_name, edm_type=col_type, nullable=nullable))

        specs.append(
            TableSpec(
                table_name=table_name,
                primary_keys=primary_keys,
                columns=columns,
            )
        )

    if not specs:
        raise ValueError(f"No EntityType definitions found in {edmx_path}")

    return specs


def _table_class_name(table_name: str) -> str:
    return "".join(part.capitalize() for part in table_name.lower().split("_")) + "Table"


def _build_table_class(spec: TableSpec, foreign_keys: dict[str, tuple[str, str]]) -> type[Table]:
    attrs: dict[str, Any] = {
        "__annotations__": {},
        "__doc__": f"Generated FinSight table for {spec.table_name}",
    }
    for column in spec.columns:
        attrs["__annotations__"][column.name] = _edm_to_python_type(column.edm_type)
        attrs[column.name] = pa.Field(nullable=column.nullable)

    table_class = type(_table_class_name(spec.table_name), (Table,), attrs)
    table_class._pks = list(spec.primary_keys)
    table_class._fks = dict(foreign_keys)
    return table_class


def _safe_read_csv(path: Path) -> pd.DataFrame:
    if not path.exists():
        logger.warning(f"Missing CSV input: {path}")
        return pd.DataFrame()
    return pd.read_csv(path, dtype=str, keep_default_na=True)


def _safe_read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        logger.warning(f"Missing JSON input: {path}")
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        logger.warning(f"Failed to parse JSON from {path}: {exc}")
        return {}


def _parse_fields_json(value: Any) -> dict[str, Any]:
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return {}
    if isinstance(value, dict):
        return value
    text = str(value).strip()
    if not text:
        return {}
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


def _as_int_series(series: pd.Series) -> pd.Series:
    return pd.to_numeric(series, errors="coerce").astype("Int64")


def _empty_dataframe_for_spec(spec: TableSpec) -> pd.DataFrame:
    return pd.DataFrame(columns=[column.name for column in spec.columns])


def _safe_json_string(payload: Any) -> str:
    return json.dumps(payload, ensure_ascii=False)


def _build_core_records(records_raw: pd.DataFrame, spec: TableSpec) -> pd.DataFrame:
    if records_raw.empty:
        return _empty_dataframe_for_spec(spec)

    field_dicts = records_raw.get("fields_json", pd.Series([None] * len(records_raw))).apply(_parse_fields_json)
    base_df = pd.DataFrame(
        {
            "record_id": records_raw.get("record_id"),
            "source_file": records_raw.get("source_file"),
            "source_table": records_raw.get("table"),
            "source_row_number": _as_int_series(records_raw.get("source_row_number", pd.Series(dtype="object"))),
        }
    )

    base_cols = {"record_id", "source_file", "source_table", "source_row_number"}
    payload_cols = [column.name for column in spec.columns if column.name not in base_cols]
    payload_df = pd.json_normalize(field_dicts).reindex(columns=payload_cols)

    out = pd.concat([base_df, payload_df], axis=1)
    return out.reindex(columns=[column.name for column in spec.columns])


def _build_core_fields(records_raw: pd.DataFrame, spec: TableSpec) -> pd.DataFrame:
    if records_raw.empty:
        return _empty_dataframe_for_spec(spec)

    rows: list[dict[str, Any]] = []
    for _, row in records_raw.iterrows():
        record_id = row.get("record_id")
        source_file = row.get("source_file")
        source_table = row.get("table")
        fields = _parse_fields_json(row.get("fields_json"))
        for field_name, field_value in fields.items():
            rows.append(
                {
                    "record_id": record_id,
                    "field_name": str(field_name),
                    "field_value": None if field_value is None else str(field_value),
                    "source_table": source_table,
                    "source_file": source_file,
                }
            )
    out = pd.DataFrame(rows)
    return out.reindex(columns=[column.name for column in spec.columns])


def _build_core_source_files(records_raw: pd.DataFrame, spec: TableSpec) -> pd.DataFrame:
    if records_raw.empty:
        return _empty_dataframe_for_spec(spec)

    grouped = (
        records_raw.groupby("source_file", dropna=False)
        .agg(
            source_table=("table", lambda s: next((str(v) for v in s.dropna().unique()), None)),
            row_count=("record_id", "size"),
        )
        .reset_index()
    )
    grouped["last_seen_utc"] = datetime.now(UTC).isoformat()
    grouped["row_count"] = _as_int_series(grouped["row_count"])
    return grouped.reindex(columns=[column.name for column in spec.columns])


def _build_rag_chunks(rag_chunks_raw: pd.DataFrame, spec: TableSpec) -> pd.DataFrame:
    if rag_chunks_raw.empty:
        return _empty_dataframe_for_spec(spec)
    out = pd.DataFrame(
        {
            "chunk_id": rag_chunks_raw.get("chunk_id"),
            "record_id": rag_chunks_raw.get("record_id"),
            "chunk_index": _as_int_series(rag_chunks_raw.get("chunk_index_in_record", pd.Series(dtype="object"))),
            "text": rag_chunks_raw.get("text"),
            "token_estimate": _as_int_series(rag_chunks_raw.get("word_count", pd.Series(dtype="object"))),
        }
    )
    return out.reindex(columns=[column.name for column in spec.columns])


def _build_rag_embeddings(embeddings_raw: pd.DataFrame, spec: TableSpec) -> pd.DataFrame:
    if embeddings_raw.empty:
        return _empty_dataframe_for_spec(spec)
    out = pd.DataFrame(
        {
            "embedding_id": embeddings_raw.get("embedding_id"),
            "chunk_id": embeddings_raw.get("chunk_id"),
            "model_name": "unknown",
            "vector_dim": pd.Series([None] * len(embeddings_raw), dtype="Int64"),
            "vector_payload": pd.Series([None] * len(embeddings_raw), dtype="object"),
            "text_sha256": embeddings_raw.get("text_sha256"),
        }
    )
    return out.reindex(columns=[column.name for column in spec.columns])


def _build_embedding_manifest(manifest_json: dict[str, Any], spec: TableSpec) -> pd.DataFrame:
    if not manifest_json:
        return _empty_dataframe_for_spec(spec)

    generated_at = manifest_json.get("generated_at")
    run_id = f"embedding_manifest_{generated_at}" if generated_at else f"embedding_manifest_{uuid.uuid4().hex[:8]}"
    row = {
        "run_id": run_id,
        "generated_at_utc": generated_at,
        "record_count": manifest_json.get("total_records"),
        "model_name": manifest_json.get("model_name", "unknown"),
        "manifest_json": _safe_json_string(manifest_json),
    }
    out = pd.DataFrame([row])
    out["record_count"] = _as_int_series(out["record_count"])
    return out.reindex(columns=[column.name for column in spec.columns])


def _build_quality_issues(issues_raw: pd.DataFrame, spec: TableSpec) -> pd.DataFrame:
    if issues_raw.empty:
        return _empty_dataframe_for_spec(spec)

    detail = issues_raw.get("message", pd.Series(dtype="object")).fillna("")
    if "severity" in issues_raw.columns:
        detail = issues_raw["severity"].fillna("").astype(str).str.strip() + " | " + detail.astype(str).str.strip()
        detail = detail.str.strip(" |")

    out = pd.DataFrame(
        {
            "record_id": issues_raw.get("record_id"),
            "issue_type": issues_raw.get("issue_type"),
            "field": issues_raw.get("field"),
            "source_row_number": _as_int_series(issues_raw.get("source_row_number", pd.Series(dtype="object"))),
            "issue_detail": detail,
        }
    )
    return out.reindex(columns=[column.name for column in spec.columns])


def _build_quality_reports(quality_report_json: dict[str, Any], spec: TableSpec) -> pd.DataFrame:
    if not quality_report_json:
        return _empty_dataframe_for_spec(spec)

    generated_at = quality_report_json.get("generated_at")
    report_id = f"quality_report_{generated_at}" if generated_at else f"quality_report_{uuid.uuid4().hex[:8]}"
    mandatory = quality_report_json.get("mandatory_quality", {}).get("global", {})
    issues = quality_report_json.get("issues", {})

    row = {
        "report_id": report_id,
        "generated_at_utc": generated_at,
        "mandatory_coverage_pct": mandatory.get("mandatory_coverage_pct"),
        "total_issues": issues.get("total_issues"),
        "report_json": _safe_json_string(quality_report_json),
    }
    out = pd.DataFrame([row])
    out["mandatory_coverage_pct"] = pd.to_numeric(out["mandatory_coverage_pct"], errors="coerce")
    out["total_issues"] = _as_int_series(out["total_issues"])
    return out.reindex(columns=[column.name for column in spec.columns])


def _build_table_profile(quality_report_json: dict[str, Any], report_id: str, spec: TableSpec) -> pd.DataFrame:
    if not quality_report_json:
        return _empty_dataframe_for_spec(spec)

    rows = []
    for entry in quality_report_json.get("mandatory_quality", {}).get("per_table", []):
        rows.append(
            {
                "table_name": entry.get("table"),
                "report_id": report_id,
                "mandatory_fields": len(entry.get("mandatory_columns", []) or []),
                "populated_mandatory_fields": entry.get("mandatory_filled_cells"),
                "coverage_pct": entry.get("mandatory_coverage_pct"),
            }
        )
    out = pd.DataFrame(rows)
    if out.empty:
        return _empty_dataframe_for_spec(spec)
    out["mandatory_fields"] = _as_int_series(out["mandatory_fields"])
    out["populated_mandatory_fields"] = _as_int_series(out["populated_mandatory_fields"])
    out["coverage_pct"] = pd.to_numeric(out["coverage_pct"], errors="coerce")
    return out.reindex(columns=[column.name for column in spec.columns])


def _build_odps_validation(odps_json: dict[str, Any], spec: TableSpec) -> pd.DataFrame:
    if not odps_json:
        return _empty_dataframe_for_spec(spec)

    generated_at = odps_json.get("generated_at")
    row = {
        "validation_run_id": f"odps_validation_{generated_at}" if generated_at else f"odps_validation_{uuid.uuid4().hex[:8]}",
        "generated_at_utc": generated_at,
        "is_valid": str(bool(odps_json.get("is_valid"))).lower(),
        "schema_error_count": odps_json.get("schema_error_count"),
        "missing_link_count": odps_json.get("missing_link_count"),
        "report_json": _safe_json_string(odps_json),
    }
    out = pd.DataFrame([row])
    out["schema_error_count"] = _as_int_series(out["schema_error_count"])
    out["missing_link_count"] = _as_int_series(out["missing_link_count"])
    return out.reindex(columns=[column.name for column in spec.columns])


def _build_graph_tables(
    core_records: pd.DataFrame,
    core_fields: pd.DataFrame,
    vertex_spec: TableSpec,
    edge_spec: TableSpec,
    edge_type_spec: TableSpec,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    if core_records.empty:
        return (
            _empty_dataframe_for_spec(vertex_spec),
            _empty_dataframe_for_spec(edge_spec),
            _empty_dataframe_for_spec(edge_type_spec),
        )

    vertices: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []

    source_values = sorted({str(v) for v in core_records.get("source_file", pd.Series(dtype="object")).dropna()})
    table_values = sorted({str(v) for v in core_records.get("source_table", pd.Series(dtype="object")).dropna()})
    field_values = sorted({str(v) for v in core_fields.get("field_name", pd.Series(dtype="object")).dropna()})

    for source in source_values:
        vertices.append(
            {
                "vertex_id": f"SOURCE::{source}",
                "vertex_type": "SOURCE_FILE",
                "label": source,
                "payload_json": _safe_json_string({"source_file": source}),
            }
        )
    for table in table_values:
        vertices.append(
            {
                "vertex_id": f"TABLE::{table}",
                "vertex_type": "TABLE",
                "label": table,
                "payload_json": _safe_json_string({"table": table}),
            }
        )
    for field_name in field_values:
        vertices.append(
            {
                "vertex_id": f"FIELD::{field_name}",
                "vertex_type": "FIELD",
                "label": field_name,
                "payload_json": _safe_json_string({"field_name": field_name}),
            }
        )

    source_table_pairs = (
        core_records[["source_file", "source_table"]]
        .dropna()
        .drop_duplicates()
        .astype(str)
        .to_dict(orient="records")
    )
    for pair in source_table_pairs:
        edges.append(
            {
                "edge_id": f"EDGE::{len(edges) + 1:08d}",
                "edge_type": "SOURCE_TO_TABLE",
                "source_vertex_id": f"SOURCE::{pair['source_file']}",
                "target_vertex_id": f"TABLE::{pair['source_table']}",
                "payload_json": _safe_json_string(pair),
            }
        )

    if not core_fields.empty:
        table_field_pairs = (
            core_fields[["source_table", "field_name"]]
            .dropna()
            .drop_duplicates()
            .astype(str)
            .to_dict(orient="records")
        )
        for pair in table_field_pairs:
            edges.append(
                {
                    "edge_id": f"EDGE::{len(edges) + 1:08d}",
                    "edge_type": "TABLE_TO_FIELD",
                    "source_vertex_id": f"TABLE::{pair['source_table']}",
                    "target_vertex_id": f"FIELD::{pair['field_name']}",
                    "payload_json": _safe_json_string(pair),
                }
            )

    vertex_df = pd.DataFrame(vertices).reindex(columns=[column.name for column in vertex_spec.columns])
    edge_df = pd.DataFrame(edges).reindex(columns=[column.name for column in edge_spec.columns])

    edge_types = sorted({row["edge_type"] for row in edges}) if edges else []
    edge_type_rows = [
        {
            "edge_type": edge_type,
            "description": edge_type.replace("_", " ").title(),
        }
        for edge_type in edge_types
    ]
    edge_type_df = pd.DataFrame(edge_type_rows).reindex(columns=[column.name for column in edge_type_spec.columns])

    return vertex_df, edge_df, edge_type_df


def _load_phase2_checks(checks_path: Path) -> dict[str, CheckLogic]:
    payload = _safe_read_json(checks_path)
    status = str(payload.get("status", "")).lower()
    if not status.startswith("generated"):
        logger.warning(f"Phase 2 checks file not generated; status='{payload.get('status')}' at {checks_path}")
        return {}

    raw_checks = payload.get("checks", {})
    loaded: dict[str, CheckLogic] = {}
    for check_name, check_data in raw_checks.items():
        if not isinstance(check_data, dict):
            continue
        check_payload = dict(check_data)
        if check_payload.get("sql") is None:
            check_payload["sql"] = ""
        if "description" not in check_payload:
            check_payload["description"] = f"Phase2 imported check {check_name}"
        if "parameters" not in check_payload:
            check_payload["parameters"] = "tables: Mapping[str, pd.DataFrame]"
        if "return_statement" not in check_payload:
            check_payload["return_statement"] = "violations"
        check_payload.setdefault("imports", ["import pandas as pd"])
        check_payload.setdefault("body_lines", ["    violations = {}"])
        try:
            loaded[check_name] = CheckLogic(**check_payload)
        except Exception as exc:  # noqa: BLE001
            logger.warning(f"Skipping invalid check '{check_name}': {exc}")
    return loaded


def resolve_machine_readable_dir(data_dir: Path | str | None = None) -> Path:
    if data_dir:
        return Path(data_dir).resolve()
    return DEFAULT_MACHINE_READABLE_DIR.resolve()


class FinSight(Database):
    """FinSight onboarding data product model for copilot interaction."""

    def __init__(
        self,
        database_id: str = "finsight",
        phase2_dir: Path | str | None = None,
        **kwargs,
    ):
        super().__init__(database_id=database_id, **kwargs)

        phase2_base = Path(phase2_dir).resolve() if phase2_dir else DEFAULT_PHASE2_DIR.resolve()
        edmx_path = phase2_base / "finsight_schema.edmx"
        checks_path = phase2_base / "finsight_derived_checks.json"

        specs = _parse_phase2_edmx(edmx_path)
        self.table_specs: dict[str, TableSpec] = {spec.table_name: spec for spec in specs}

        for spec in specs:
            fk_map = FOREIGN_KEYS.get(spec.table_name, {})
            filtered_fk_map = {
                fk_column: (target_table, target_column)
                for fk_column, (target_table, target_column) in fk_map.items()
                if target_table in self.table_specs
            }
            table_class = _build_table_class(spec, filtered_fk_map)
            self.create_table(spec.table_name, table_class)

        self.derive_rule_based_checks()
        phase2_checks = _load_phase2_checks(checks_path)
        if phase2_checks:
            self.add_checks(phase2_checks)
            logger.info(f"Loaded {len(phase2_checks)} Phase 2 OData checks into FinSight database")


def load_finsight_data(db: FinSight, data_dir: Path | str | None = None) -> tuple[int, int]:
    """
    Load FinSight machine-readable artifacts into a FinSight database instance.

    Returns:
        (loaded_table_count, total_table_count)
    """
    base_dir = resolve_machine_readable_dir(data_dir)
    logger.info(f"Loading FinSight machine-readable data from {base_dir}")

    records_raw = _safe_read_csv(base_dir / "finsight_records.csv")
    rag_chunks_raw = _safe_read_csv(base_dir / "rag_chunks.csv")
    embeddings_raw = _safe_read_csv(base_dir / "rag_embedding_records.csv")
    quality_issues_raw = _safe_read_csv(base_dir / "quality_issues.csv")

    embedding_manifest_json = _safe_read_json(base_dir / "rag_embedding_records_manifest.json")
    quality_report_json = _safe_read_json(base_dir / "quality_report.json")
    odps_validation_json = _safe_read_json(base_dir / "odps_validation_report.json")

    specs = db.table_specs
    tables: dict[str, pd.DataFrame] = {}

    tables["FINSIGHT_CORE_RECORDS"] = _build_core_records(records_raw, specs["FINSIGHT_CORE_RECORDS"])
    tables["FINSIGHT_CORE_FIELDS"] = _build_core_fields(records_raw, specs["FINSIGHT_CORE_FIELDS"])
    tables["FINSIGHT_CORE_SOURCE_FILES"] = _build_core_source_files(records_raw, specs["FINSIGHT_CORE_SOURCE_FILES"])
    tables["FINSIGHT_RAG_CHUNKS"] = _build_rag_chunks(rag_chunks_raw, specs["FINSIGHT_RAG_CHUNKS"])
    tables["FINSIGHT_RAG_EMBEDDINGS"] = _build_rag_embeddings(embeddings_raw, specs["FINSIGHT_RAG_EMBEDDINGS"])
    tables["FINSIGHT_RAG_EMBEDDING_MANIFEST"] = _build_embedding_manifest(
        embedding_manifest_json,
        specs["FINSIGHT_RAG_EMBEDDING_MANIFEST"],
    )
    tables["FINSIGHT_GOV_QUALITY_ISSUES"] = _build_quality_issues(quality_issues_raw, specs["FINSIGHT_GOV_QUALITY_ISSUES"])
    tables["FINSIGHT_GOV_QUALITY_REPORTS"] = _build_quality_reports(quality_report_json, specs["FINSIGHT_GOV_QUALITY_REPORTS"])

    report_id = (
        tables["FINSIGHT_GOV_QUALITY_REPORTS"]["report_id"].iloc[0]
        if not tables["FINSIGHT_GOV_QUALITY_REPORTS"].empty
        else f"quality_report_{uuid.uuid4().hex[:8]}"
    )
    tables["FINSIGHT_GOV_TABLE_PROFILE"] = _build_table_profile(
        quality_report_json,
        str(report_id),
        specs["FINSIGHT_GOV_TABLE_PROFILE"],
    )
    tables["FINSIGHT_GOV_ODPS_VALIDATION"] = _build_odps_validation(
        odps_validation_json,
        specs["FINSIGHT_GOV_ODPS_VALIDATION"],
    )

    vertex_df, edge_df, edge_type_df = _build_graph_tables(
        tables["FINSIGHT_CORE_RECORDS"],
        tables["FINSIGHT_CORE_FIELDS"],
        specs["FINSIGHT_GRAPH_VERTEX"],
        specs["FINSIGHT_GRAPH_EDGE"],
        specs["FINSIGHT_GRAPH_EDGE_TYPE"],
    )
    tables["FINSIGHT_GRAPH_VERTEX"] = vertex_df
    tables["FINSIGHT_GRAPH_EDGE"] = edge_df
    tables["FINSIGHT_GRAPH_EDGE_TYPE"] = edge_type_df

    loaded = 0
    total = len(specs)
    for table_name, spec in specs.items():
        table_df = tables.get(table_name, _empty_dataframe_for_spec(spec))
        ordered_df = table_df.reindex(columns=[column.name for column in spec.columns])
        db.set_table_data(table_name, ordered_df)
        if not ordered_df.empty:
            loaded += 1

    return loaded, total
