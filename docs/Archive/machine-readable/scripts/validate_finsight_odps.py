#!/usr/bin/env python3
"""
Validate FinSight ODPS 4.1 package.

Checks:
1) JSON Schema validation against official ODPS 4.1 schema.
2) Local file:// link existence checks for referenced artifacts.
3) Writes machine-readable validation report.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import unquote, urlparse

import requests
import yaml
from jsonschema import Draft202012Validator


DEFAULT_SCHEMA_URL = "https://opendataproducts.org/v4.1/schema/odps.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate FinSight ODPS package")
    parser.add_argument(
        "--odps",
        default="../finsight_onboarding.odps.yaml",
        help="Path to ODPS YAML file (relative to script dir)",
    )
    parser.add_argument(
        "--schema-url",
        default=DEFAULT_SCHEMA_URL,
        help="ODPS JSON schema URL",
    )
    parser.add_argument(
        "--report",
        default="../odps_validation_report.json",
        help="Output validation report path (relative to script dir)",
    )
    return parser.parse_args()


def load_yaml(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def fetch_schema(url: str) -> dict:
    response = requests.get(url, timeout=30)
    response.raise_for_status()
    return response.json()


def validate_schema(instance: dict, schema: dict) -> list[dict]:
    validator = Draft202012Validator(schema)
    errors: list[dict] = []
    for err in sorted(validator.iter_errors(instance), key=lambda e: list(e.path)):
        path = ".".join(str(p) for p in err.path)
        schema_path = ".".join(str(p) for p in err.schema_path)
        errors.append(
            {
                "path": path or "<root>",
                "message": err.message,
                "schema_path": schema_path,
            }
        )
    return errors


def extract_file_urls(obj: object, found: list[str]) -> None:
    if isinstance(obj, dict):
        for value in obj.values():
            extract_file_urls(value, found)
        return
    if isinstance(obj, list):
        for value in obj:
            extract_file_urls(value, found)
        return
    if isinstance(obj, str) and obj.startswith("file://"):
        found.append(obj)


def file_uri_to_path(file_uri: str) -> Path:
    parsed = urlparse(file_uri)
    return Path(unquote(parsed.path))


def validate_local_links(instance: dict) -> list[dict]:
    file_uris: list[str] = []
    extract_file_urls(instance, file_uris)

    link_results: list[dict] = []
    for uri in sorted(set(file_uris)):
        path = file_uri_to_path(uri)
        exists = path.exists()
        link_results.append(
            {
                "uri": uri,
                "path": str(path),
                "exists": exists,
            }
        )
    return link_results


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    odps_path = (script_dir / args.odps).resolve()
    report_path = (script_dir / args.report).resolve()

    instance = load_yaml(odps_path)
    schema = fetch_schema(args.schema_url)

    schema_errors = validate_schema(instance, schema)
    link_results = validate_local_links(instance)
    missing_links = [item for item in link_results if not item["exists"]]

    is_valid = not schema_errors and not missing_links
    report = {
        "generated_at": datetime.now(UTC).isoformat(),
        "odps_path": str(odps_path),
        "schema_url": args.schema_url,
        "is_valid": is_valid,
        "schema_error_count": len(schema_errors),
        "missing_link_count": len(missing_links),
        "schema_errors": schema_errors,
        "link_checks": link_results,
    }
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"ODPS file: {odps_path}")
    print(f"Schema URL: {args.schema_url}")
    print(f"Schema errors: {len(schema_errors)}")
    print(f"File URI links checked: {len(link_results)}")
    print(f"Missing file URI links: {len(missing_links)}")
    print(f"Wrote {report_path}")
    print(f"VALID={is_valid}")

    if not is_valid:
        sys.exit(1)


if __name__ == "__main__":
    main()
