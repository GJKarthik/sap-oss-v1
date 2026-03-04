#!/usr/bin/env python3
"""Execute a query corpus against a Kuzu Python backend and emit canonical JSON."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any


def _canonicalize(value: Any) -> Any:
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, bytes):
        return {"__type__": "bytes", "hex": value.hex()}
    if isinstance(value, tuple):
        return [_canonicalize(v) for v in value]
    if isinstance(value, list):
        return [_canonicalize(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _canonicalize(v) for k, v in sorted(value.items(), key=lambda x: str(x[0]))}
    return {"__type__": type(value).__name__, "repr": str(value)}


def _normalize_rows(rows: list[Any], ordered: bool) -> list[Any]:
    if ordered:
        return rows
    return sorted(rows, key=lambda row: json.dumps(row, sort_keys=True))


def _close_result(result: Any) -> None:
    if isinstance(result, list):
        for entry in result:
            if hasattr(entry, "close"):
                entry.close()
        return
    if hasattr(result, "close"):
        result.close()


def _load_corpus(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("Corpus file must be a JSON object.")
    if "cases" not in data or not isinstance(data["cases"], list):
        raise ValueError("Corpus JSON must include a list field named 'cases'.")
    return data


def _run_case(kuzu: Any, case: dict[str, Any], db_path: Path) -> dict[str, Any]:
    database = kuzu.Database(str(db_path))
    connection = kuzu.Connection(database)
    name = case.get("name", "<unnamed>")
    ordered = bool(case.get("ordered", True))
    setup = case.get("setup", [])
    parameters = case.get("parameters", {})
    query = case.get("query")
    expected_error = case.get("expect_error_contains")

    if not isinstance(setup, list):
        raise ValueError(f"Case '{name}' has invalid setup. Expected list[str].")
    if not isinstance(parameters, dict):
        raise ValueError(f"Case '{name}' has invalid parameters. Expected dict.")
    if not isinstance(query, str):
        raise ValueError(f"Case '{name}' is missing string query.")

    try:
        for stmt in setup:
            if not isinstance(stmt, str):
                raise ValueError(f"Case '{name}' has non-string setup statement.")
            result = connection.execute(stmt)
            _close_result(result)

        result = connection.execute(query, parameters)
        if isinstance(result, list):
            raise RuntimeError(f"Case '{name}' returned multiple QueryResult objects. Use a single query.")

        columns = result.get_column_names()
        types = result.get_column_data_types()
        rows: list[Any] = []
        while result.has_next():
            rows.append(_canonicalize(result.get_next()))
        result.close()

        return {
            "name": name,
            "ordered": ordered,
            "status": "ok",
            "columns": columns,
            "types": types,
            "rows": _normalize_rows(rows, ordered),
        }
    except Exception as exc:  # noqa: BLE001
        message = str(exc)
        if isinstance(expected_error, str) and expected_error in message:
            return {
                "name": name,
                "ordered": ordered,
                "status": "expected_error",
                "error": message,
            }
        return {
            "name": name,
            "ordered": ordered,
            "status": "error",
            "error": message,
        }
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True, help="Path to query corpus JSON file.")
    parser.add_argument("--db-root", default=None, help="Directory for temporary databases.")
    parser.add_argument("--module", default="kuzu", help="Python module name for backend (default: kuzu).")
    parser.add_argument("--output", default=None, help="Optional output path. Defaults to stdout.")
    args = parser.parse_args()

    try:
        kuzu = __import__(args.module)
    except Exception as exc:  # noqa: BLE001
        print(
            json.dumps(
                {
                    "runner": "kuzu-python",
                    "status": "runner_error",
                    "error": f"Failed to import module '{args.module}': {exc}",
                },
                indent=2,
            ),
            file=sys.stderr,
        )
        return 2

    corpus_path = Path(args.corpus).resolve()
    corpus = _load_corpus(corpus_path)
    cases = corpus["cases"]

    db_root = Path(args.db_root).resolve() if args.db_root else Path(tempfile.mkdtemp(prefix="hippocpp-db-"))
    db_root.mkdir(parents=True, exist_ok=True)

    run_results: list[dict[str, Any]] = []
    for idx, case in enumerate(cases):
        if not isinstance(case, dict):
            raise ValueError(f"Case index {idx} must be a JSON object.")
        db_path = db_root / f"case_{idx}_{case.get('name', 'unnamed')}.kuzu"
        if db_path.exists():
            if db_path.is_dir():
                shutil.rmtree(db_path)
            else:
                db_path.unlink()
        run_results.append(_run_case(kuzu, case, db_path))

    payload = {
        "runner": "kuzu-python",
        "module": args.module,
        "corpus_name": corpus.get("name", corpus_path.stem),
        "corpus_path": str(corpus_path),
        "cases": run_results,
        "error_count": sum(1 for c in run_results if c["status"] not in ("ok", "expected_error")),
    }

    encoded = json.dumps(payload, indent=2, sort_keys=True)
    if args.output:
        output_path = Path(args.output).resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(encoded + os.linesep, encoding="utf-8")
    else:
        print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
