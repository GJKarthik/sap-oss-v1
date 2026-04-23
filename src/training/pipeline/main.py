#!/usr/bin/env python3
# =============================================================================
# main.py — Text-to-SQL pipeline CLI (Python + SAP HANA Cloud)
#
# ⚠️  DEPRECATION NOTICE (Simula v1.2)
# ═══════════════════════════════════════════════════════════════════════════════
# This legacy template/Spider pipeline is DEPRECATED as of Simula v1.2.
#
# The authoritative pipeline is now the Simula HANA-direct flow:
#   python -m scripts.run_hana_pipeline [options]
#
# Or via Make:
#   make simula-pipeline
#
# This legacy pipeline will be removed in v1.3. Please migrate to the Simula
# pipeline for spec-compliant training data generation with:
# - HANA schema extraction
# - Reasoning-driven taxonomy generation (Algorithm 1)
# - Agentic data synthesis with double-critic filtering (Algorithm 2)
# - Elo-calibrated complexity scoring (Algorithm 3)
# - Full evaluation framework (coverage, diversity, critic calibration)
#
# See: docs/latex/specs/simula/chapters/12-implementation-instructions.tex
# ═══════════════════════════════════════════════════════════════════════════════
#
# LEGACY Usage (deprecated):
#   python -m pipeline extract-schema <staging_csv> <output_json>
#   python -m pipeline parse-templates <templates_csv> <domain> <output_json>
#   python -m pipeline expand <templates_csv> <output_pairs_json> [max]
#   python -m pipeline format-spider <pairs_json> <output_dir> [db_id]
#   python -m pipeline upload <pairs_json>              # upload to HANA Cloud
# =============================================================================
from __future__ import annotations

import json
import sys
import warnings
from pathlib import Path

from . import __version__
from .json_emitter import emit_pairs_json, emit_schema_json, emit_templates_json, load_pairs_json
from .schema_extractor import extract_from_staging_csv
from .schema_registry import SchemaRegistry
from .spider_formatter import format_for_spider, write_spider_dataset
from .template_expander import expand_all
from .template_parser import parse_templates_csv

# Deprecation warning
_DEPRECATION_MESSAGE = """
╔═══════════════════════════════════════════════════════════════════════════════╗
║  ⚠️  DEPRECATION WARNING: Legacy Template/Spider Pipeline                      ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║  This pipeline is DEPRECATED as of Simula v1.2.                               ║
║                                                                               ║
║  Please migrate to the Simula HANA-direct pipeline:                           ║
║    python -m scripts.run_hana_pipeline [options]                              ║
║    make simula-pipeline                                                       ║
║                                                                               ║
║  This legacy pipeline will be REMOVED in v1.3.                                ║
╚═══════════════════════════════════════════════════════════════════════════════╝
"""


def _emit_deprecation_warning() -> None:
    """Emit deprecation warning to stderr."""
    warnings.warn(
        "Legacy template/Spider pipeline is deprecated. Use Simula HANA-direct pipeline instead. "
        "See: python -m scripts.run_hana_pipeline --help",
        DeprecationWarning,
        stacklevel=3,
    )
    print(_DEPRECATION_MESSAGE, file=sys.stderr)


def _usage() -> None:
    print(f"text2sql-pipeline v{__version__} (Python + HANA Cloud)")
    print("Usage: python -m pipeline <command> [args]\n")
    print("Commands:")
    print("  extract-schema  <staging_csv> <output_json>")
    print("  parse-templates <templates_csv> <domain> <output_json>")
    print("  expand          <templates_csv> <output_pairs_json> [max_expansions]")
    print("  format-spider   <pairs_json> <output_dir> [db_id]")
    print("  upload          <pairs_json>")
    print("  version")


def cmd_extract_schema(args: list[str]) -> None:
    if len(args) < 2:
        print("extract-schema: expected <staging_csv> <output_json>", file=sys.stderr)
        sys.exit(1)

    csv_path, out_path = args[0], args[1]
    registry = SchemaRegistry()
    extract_from_staging_csv(csv_path, registry)
    emit_schema_json(registry, out_path)
    print(f"extract-schema: {registry.table_count()} tables written to {out_path}")


def cmd_parse_templates(args: list[str]) -> None:
    if len(args) < 3:
        print("parse-templates: expected <templates_csv> <domain> <output_json>", file=sys.stderr)
        sys.exit(1)

    csv_path, domain, out_path = args[0], args[1], args[2]
    templates = parse_templates_csv(csv_path, domain)
    emit_templates_json(templates, out_path)
    print(f"parse-templates: {len(templates)} templates written to {out_path}")


def cmd_expand(args: list[str]) -> None:
    if len(args) < 2:
        print("expand: expected <templates_csv> <output_pairs_json> [max_expansions]", file=sys.stderr)
        sys.exit(1)

    csv_path, out_path = args[0], args[1]
    max_expansions = int(args[2]) if len(args) >= 3 else 500

    # Infer domain from filename
    basename = Path(csv_path).stem.lower()
    if "treasury" in basename:
        domain = "treasury"
    elif "esg" in basename:
        domain = "esg"
    elif "performance" in basename:
        domain = "performance"
    else:
        domain = "banking"

    templates = parse_templates_csv(csv_path, domain)
    pairs = expand_all(templates, max_per_template=max_expansions)
    emit_pairs_json(pairs, out_path)
    print(f"expand: {len(pairs)} pairs written to {out_path}")


def cmd_format_spider(args: list[str]) -> None:
    if len(args) < 2:
        print("format-spider: expected <pairs_json> <output_dir> [db_id]", file=sys.stderr)
        sys.exit(1)

    pairs_path, out_dir = args[0], args[1]
    db_id = args[2] if len(args) >= 3 else "banking_db"

    pairs = load_pairs_json(pairs_path)
    split = format_for_spider(pairs, db_id=db_id)
    write_spider_dataset(split, out_dir)
    print(
        f"format-spider: train={len(split.train)} dev={len(split.dev)} "
        f"test={len(split.test_set)} → {out_dir}/"
    )


def cmd_upload(args: list[str]) -> None:
    if len(args) < 1:
        print("upload: expected <pairs_json>", file=sys.stderr)
        sys.exit(1)

    pairs_path = args[0]
    pairs = load_pairs_json(pairs_path)

    from .hana_client import HanaClient

    client = HanaClient()
    with client.session():
        data = [
            {"question": p.question, "sql": p.sql, "domain": p.domain, "difficulty": p.difficulty}
            for p in pairs
        ]
        count = client.upload_training_pairs(data)
        print(f"upload: {count} pairs uploaded to HANA Cloud")


def main() -> None:
    args = sys.argv[1:]
    if not args:
        _usage()
        sys.exit(1)

    command = args[0]
    rest = args[1:]

    commands = {
        "extract-schema": cmd_extract_schema,
        "parse-templates": cmd_parse_templates,
        "expand": cmd_expand,
        "format-spider": cmd_format_spider,
        "upload": cmd_upload,
    }

    # Always emit deprecation warning for legacy pipeline commands
    if command in commands:
        _emit_deprecation_warning()

    if command in ("version", "--version"):
        print(f"text2sql-pipeline v{__version__} [DEPRECATED - use Simula pipeline]")
    elif command in ("help", "--help", "-h"):
        _usage()
        print("\n⚠️  This legacy pipeline is DEPRECATED. Use: make simula-pipeline")
    elif command in commands:
        commands[command](rest)
    else:
        print(f"Unknown command: {command}\n", file=sys.stderr)
        _usage()
        sys.exit(1)


if __name__ == "__main__":
    main()
