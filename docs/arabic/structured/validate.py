#!/usr/bin/env python3
"""Validate every structured JSON record against its declared schema_ref.

Usage:
    python3 docs/arabic/structured/validate.py
Exit code is 0 iff every record (and corpus path) validates.
"""
from __future__ import annotations
import json
import sys
from pathlib import Path

import jsonschema
from jsonschema import Draft7Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parent


def main() -> int:
    schemas: dict[str, dict] = {}
    resources: list[tuple[str, Resource]] = []
    for p in (ROOT / "schema").glob("*.json"):
        s = json.loads(p.read_text())
        schemas[p.name] = s
        resources.append((p.name, Resource.from_contents(s)))
        if "$id" in s:
            resources.append((s["$id"], Resource.from_contents(s)))
    registry = Registry().with_resources(resources)

    fail = 0
    ok = 0
    for p in ROOT.rglob("*.json"):
        if p.parent.name == "schema" or p.name == "corpus.json":
            continue
        data = json.loads(p.read_text())
        ref = data.get("schema_ref")
        if not ref or ref not in schemas:
            print(f"SKIP {p}: schema_ref={ref!r}")
            continue
        v = Draft7Validator(schemas[ref], registry=registry)
        errs = list(v.iter_errors(data))
        if errs:
            for e in errs:
                print(f"INVALID {p}: {e.message} at {list(e.path)}")
            fail += 1
        else:
            ok += 1

    # Corpus integrity: every referenced path must exist
    corpus = json.loads((ROOT / "corpus.json").read_text())
    path_errs = 0
    repo_root = ROOT.parent.parent.parent  # docs/arabic/structured → repo
    for item in corpus["items"]:
        for key in ("source_path", "text_path", "structured_path"):
            if item.get(key):
                candidate = repo_root / item[key]
                if not candidate.exists():
                    print(f"MISSING {key}: {item[key]}")
                    path_errs += 1

    print(f"records: {ok} OK, {fail} failures; corpus paths missing: {path_errs}")
    return 0 if (fail == 0 and path_errs == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
