# =============================================================================
# schema_extractor.py — Extract table schemas from staging CSV files
# =============================================================================
from __future__ import annotations

from pathlib import Path

from .csv_parser import parse_csv_file, parse_csv_string
from .schema_registry import Column, Domain, SchemaRegistry, TableSchema


def _domain_from_use_case(use_case: str) -> Domain:
    """Infer domain from the use-case column value."""
    upper = use_case.upper()
    if "TREASURY" in upper or "CAPITAL" in upper:
        return Domain.TREASURY
    if "ESG" in upper:
        return Domain.ESG
    return Domain.PERFORMANCE


def extract_from_staging_csv(csv_path: str | Path, registry: SchemaRegistry) -> None:
    """Extract table schemas from a staging CSV file into the registry.

    Expects the first 3 rows to be metadata headers (skipped).
    Data rows are expected to have at least 10 columns with fields:
      [5] = BTP Staging Schema Name
      [6] = BTP Table Name
      [7] = BTP Field Name
      [8] = Field Description
      [9] = Data Type
    """
    rows = parse_csv_file(csv_path)
    _extract_rows(rows, registry)


def extract_from_staging_csv_string(csv_data: str, registry: SchemaRegistry) -> None:
    """Same as extract_from_staging_csv but from an in-memory string."""
    rows = parse_csv_string(csv_data)
    _extract_rows(rows, registry)


def _extract_rows(rows: list, registry: SchemaRegistry) -> None:
    """Internal: process parsed CSV rows into the schema registry."""
    # Skip 3 metadata header rows
    data_rows = rows[3:] if len(rows) > 3 else []

    for row in data_rows:
        if len(row.fields) < 10:
            continue

        use_case = row.fields[1] if len(row.fields) > 1 else ""
        schema_name = row.fields[5]
        table_name = row.fields[6]
        field_name = row.fields[7]
        field_desc = row.fields[8] if len(row.fields) > 8 else ""
        data_type = row.fields[9] if len(row.fields) > 9 else "NVARCHAR"

        if not table_name or not field_name:
            continue

        # Add table if not already registered
        registry.add_table(
            TableSchema(
                name=table_name,
                schema_name=schema_name,
                domain=_domain_from_use_case(use_case),
            )
        )

        # Add column to the table
        registry.add_column(
            table_name,
            Column(
                name=field_name,
                data_type=data_type,
                description=field_desc,
            ),
        )
