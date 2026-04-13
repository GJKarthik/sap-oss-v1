#!/usr/bin/env python3
"""
Extract schema, sample data, and metadata from TB/PL Excel workbooks (.xlsm).

Uses openpyxl in read_only mode only (critical for 50-74MB files).
Skips full-mode load (formulas/validations) to avoid timeouts.
"""

import csv
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import openpyxl
import yaml

TB_DIR = Path(__file__).resolve().parent.parent.parent  # docs/tb/
OUTPUT_DIR = Path(__file__).resolve().parent.parent / "training-data"

# Key sheets to extract (based on profiling)
TB_KEY_SHEETS = [
    "BS Variance", "PL Variance", "RAW TB NOV'25", "RAW TB OCT'25",
    "GCOA", "Dept Mapping", "Base file", "Rates", "Count of Comments",
]
PL_KEY_SHEETS = [
    "PL Variance", "Raw TB Nov'25", "Raw TB oct'25",
    "GCOA", "Dept Mapping", "Base file", "Rates", "ecl check",
]

WORKBOOKS = [
    {
        "filename": "HKG_TB review Nov'25.xlsm",
        "id": "hkg-tb",
        "name": "HKG TB Review Nov 2025",
        "key_sheets": TB_KEY_SHEETS,
        "schema_output": "hkg-tb-schema.yaml",
        "sample_output": "hkg-tb-sample.csv",
    },
    {
        "filename": "HKG_PL review Nov'25.xlsm",
        "id": "hkg-pl",
        "name": "HKG PL Review Nov 2025",
        "key_sheets": PL_KEY_SHEETS,
        "schema_output": "hkg-pl-schema.yaml",
        "sample_output": "hkg-pl-sample.csv",
    },
]

# Field classification patterns
MEASURE_PATTERNS = [
    "amount", "balance", "total", "sum", "variance", "debit", "credit",
    "net", "gross", "value", "mtm", "exposure", "ytd", "mtd",
    "actual", "budget", "forecast", "prior", "current", "rate",
]
DATE_PATTERNS = ["date", "period", "month", "year", "quarter"]
ID_PATTERNS = ["_id", "account", "code", "gl_", "cost_center", "entity", "dept"]


def classify_field(col_name: str) -> Dict[str, Optional[str]]:
    name_lower = col_name.lower()
    for p in ID_PATTERNS:
        if p in name_lower:
            return {"fieldType": "identifier", "analyticsAnnotation": None}
    for p in DATE_PATTERNS:
        if p in name_lower:
            return {"fieldType": "date", "analyticsAnnotation": None}
    for p in MEASURE_PATTERNS:
        if p in name_lower:
            return {"fieldType": "measure", "analyticsAnnotation": "@Analytics.Measure"}
    return {"fieldType": "dimension", "analyticsAnnotation": "@Analytics.Dimension"}


def infer_data_type(values: list) -> str:
    non_null = [v for v in values if v is not None]
    if not non_null:
        return "UNKNOWN"
    type_counts = {"int": 0, "float": 0, "str": 0, "date": 0}
    for v in non_null[:30]:
        if isinstance(v, bool):
            type_counts["str"] += 1
        elif isinstance(v, int):
            type_counts["int"] += 1
        elif isinstance(v, float):
            type_counts["float"] += 1
        elif isinstance(v, datetime):
            type_counts["date"] += 1
        else:
            type_counts["str"] += 1
    dominant = max(type_counts, key=type_counts.get)
    return {"int": "INTEGER", "float": "DECIMAL", "str": "NVARCHAR", "date": "DATE"}.get(dominant, "NVARCHAR")


def extract_sheet_schema(wb, sheet_name: str, max_rows: int = 50) -> Dict:
    """Extract schema from a single worksheet using read-only API."""
    try:
        ws = wb[sheet_name]
    except KeyError:
        return {"sheetName": sheet_name, "error": "not found"}

    rows = []
    for i, row in enumerate(ws.iter_rows(values_only=True)):
        rows.append(row)
        if i >= max_rows + 5:  # +5 to handle header offset
            break

    if not rows:
        return {"sheetName": sheet_name, "empty": True, "fields": []}

    # Find header row (first row with >=2 non-empty cells)
    header_row = None
    header_idx = 0
    for idx, row in enumerate(rows):
        non_empty = [c for c in row if c is not None]
        if len(non_empty) >= 2:
            header_row = row
            header_idx = idx
            break

    if header_row is None:
        return {"sheetName": sheet_name, "noHeaders": True, "fields": []}

    # Build headers list
    headers = []
    for j, h in enumerate(header_row):
        if h is not None:
            headers.append((j, str(h).strip()))

    if not headers:
        return {"sheetName": sheet_name, "empty": True, "fields": []}

    # Data rows after header
    data_rows = rows[header_idx + 1:]

    # Build field schemas
    fields = []
    for col_idx, col_name in headers:
        values = []
        for row in data_rows:
            if col_idx < len(row):
                values.append(row[col_idx])

        non_null = [v for v in values if v is not None]
        null_count = len(values) - len(non_null)
        classification = classify_field(col_name)

        try:
            col_letter = openpyxl.utils.get_column_letter(col_idx + 1)
        except Exception:
            col_letter = str(col_idx)

        field = {
            "technicalName": re.sub(r'[^a-zA-Z0-9_]', '_', col_name.upper()).strip('_'),
            "columnLetter": col_letter,
            "columnIndex": col_idx,
            "businessName": col_name,
            "fieldType": classification["fieldType"],
            "dataType": infer_data_type(values),
            "analyticsAnnotation": classification["analyticsAnnotation"],
            "nullRate": round(null_count / max(len(values), 1), 3),
            "sampleValues": [str(v)[:80] for v in non_null[:5]],
        }
        fields.append(field)

    return {
        "sheetName": sheet_name,
        "headerRow": header_idx + 1,
        "sampleDataRows": len(data_rows),
        "fieldCount": len(fields),
        "fields": fields,
    }


def extract_sample_csv(wb, sheet_names: list, output_path: Path, max_rows: int = 100):
    """Extract sample rows from first significant sheet as CSV."""
    for sheet_name in sheet_names:
        try:
            ws = wb[sheet_name]
        except KeyError:
            continue

        rows_written = 0
        with open(output_path, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            for row in ws.iter_rows(values_only=True):
                if rows_written > max_rows:
                    break
                writer.writerow([str(c)[:200] if c is not None else "" for c in row])
                rows_written += 1

        if rows_written > 1:
            print(f"    Sample CSV: {rows_written} rows from '{sheet_name}'")
            return rows_written

    return 0


def process_workbook(wb_config: Dict):
    filepath = TB_DIR / wb_config["filename"]
    if not filepath.exists():
        print(f"[SKIP] {wb_config['filename']} not found")
        return

    file_size = filepath.stat().st_size
    print(f"\n{'='*60}")
    print(f"Processing: {wb_config['filename']} ({file_size / 1024 / 1024:.1f} MB)")
    print(f"{'='*60}")

    wb = openpyxl.load_workbook(str(filepath), read_only=True, data_only=True)
    all_sheets = wb.sheetnames
    print(f"  Sheets: {len(all_sheets)}: {', '.join(all_sheets)}")

    # Extract schemas for key sheets
    print(f"\n  Schema extraction (key sheets)...")
    sheet_schemas = []
    for sn in all_sheets:
        if sn in wb_config["key_sheets"]:
            schema = extract_sheet_schema(wb, sn)
            field_count = schema.get("fieldCount", 0)
            if field_count > 0:
                print(f"    '{sn}': {field_count} fields")
            sheet_schemas.append(schema)
        else:
            # Just record name for non-key sheets
            sheet_schemas.append({"sheetName": sn, "skipped": True, "reason": "not in key_sheets"})

    # Sample CSV from variance sheets (most useful for training)
    print(f"\n  Sample data...")
    sample_path = OUTPUT_DIR / wb_config["sample_output"]
    variance_sheets = [s for s in wb_config["key_sheets"] if "Variance" in s or "RAW" in s or "Raw" in s]
    extract_sample_csv(wb, variance_sheets, sample_path)

    wb.close()

    # Write schema YAML
    schema_doc = {
        "workbookId": wb_config["id"],
        "name": wb_config["name"],
        "sourceFile": wb_config["filename"],
        "extractedAt": datetime.now(timezone.utc).isoformat(),
        "fileSize": file_size,
        "sheetCount": len(all_sheets),
        "allSheetNames": all_sheets,
        "sheets": [s for s in sheet_schemas if not s.get("skipped")],
    }

    schema_path = OUTPUT_DIR / wb_config["schema_output"]
    with open(schema_path, "w", encoding="utf-8") as f:
        yaml.dump(schema_doc, f, default_flow_style=False, sort_keys=False, allow_unicode=True, width=120)
    print(f"\n  -> {schema_path}")


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("Excel Workbook Extraction Pipeline")
    print("=" * 60)

    for wb_config in WORKBOOKS:
        process_workbook(wb_config)

    print(f"\n{'='*60}")
    print(f"Done. Output in {OUTPUT_DIR}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
