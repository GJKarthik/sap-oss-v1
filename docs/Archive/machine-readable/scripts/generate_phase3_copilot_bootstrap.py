#!/usr/bin/env python3
"""
Generate Phase 3 copilot bootstrap artifacts for FinSight.

This script validates that:
- FinSight database schema can be instantiated in data-cleaning-copilot
- Machine-readable data can be loaded into the FinSight copilot model
- Baseline checks execute and return usable validation outputs

Outputs:
  - ../copilot_phase3/phase3_validation_report.json
  - ../copilot_phase3/phase3_session_blueprint.json
  - ../copilot_phase3/PHASE3_COPILOT_BOOTSTRAP.md
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate Phase 3 copilot bootstrap artifacts")
    parser.add_argument(
        "--machine-readable-dir",
        default="..",
        help="Machine-readable directory (relative to script dir)",
    )
    parser.add_argument(
        "--copilot-root",
        default="../../../../data-cleaning-copilot-main",
        help="data-cleaning-copilot root directory (relative to script dir)",
    )
    parser.add_argument(
        "--output-dir",
        default="../copilot_phase3",
        help="Output directory (relative to script dir)",
    )
    parser.add_argument(
        "--validate-checks",
        action="store_true",
        help="Run db.validate() for a runtime smoke test",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    machine_readable_dir = (script_dir / args.machine_readable_dir).resolve()
    copilot_root = (script_dir / args.copilot_root).resolve()
    output_dir = (script_dir / args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    sys.path.insert(0, str(copilot_root))

    from definition.impl.database.finsight import FinSight, load_finsight_data

    phase2_dir = machine_readable_dir / "odata_phase2"
    db = FinSight(
        database_id="finsight_phase3_bootstrap",
        max_output_tokens=10000,
        max_execution_time=120,
        phase2_dir=phase2_dir,
    )
    loaded_count, total_count = load_finsight_data(db, machine_readable_dir)

    table_rows = {
        table_name: int(len(df))
        for table_name, df in sorted(db.table_data.items())
    }

    validation_summary = {
        "executed": False,
        "check_count_total": len(db.rule_based_checks) + len(db.checks),
        "checks_with_violations": 0,
        "checks_without_violations": 0,
        "checks_failed": 0,
    }

    if args.validate_checks:
        validation_results = db.validate()
        checks_with_violations = 0
        checks_without_violations = 0
        checks_failed = 0
        for value in validation_results.values():
            if isinstance(value, Exception):
                checks_failed += 1
            else:
                row_count = len(value)
                if row_count > 0:
                    checks_with_violations += 1
                else:
                    checks_without_violations += 1
        validation_summary = {
            "executed": True,
            "check_count_total": len(validation_results),
            "checks_with_violations": checks_with_violations,
            "checks_without_violations": checks_without_violations,
            "checks_failed": checks_failed,
        }

    phase3_report = {
        "phase": "Phase 3 - Copilot Integration",
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "inputs": {
            "machine_readable_dir": str(machine_readable_dir),
            "copilot_root": str(copilot_root),
            "phase2_dir": str(phase2_dir),
        },
        "copilot_integration": {
            "database_class": "definition.impl.database.finsight.FinSight",
            "loaded_tables": loaded_count,
            "total_tables": total_count,
            "table_row_counts": table_rows,
            "phase2_derived_checks_loaded": len(db.checks),
            "pandera_rule_checks_loaded": len(db.rule_based_checks),
        },
        "validation_smoke_test": validation_summary,
        "status": "ready",
    }

    blueprint = {
        "phase": "Phase 3 - Copilot Session Blueprint",
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "default_database": "finsight",
        "default_data_dir": str(machine_readable_dir),
        "copilot_command": (
            f"cd {copilot_root} && "
            f"uv run python -m bin.copilot -d finsight --data-dir {machine_readable_dir}"
        ),
        "api_command": (
            f"cd {copilot_root} && "
            f"uv run python -m bin.api -d finsight --data-dir {machine_readable_dir} --port 8000"
        ),
        "recommended_table_scopes": [
            "FINSIGHT_CORE_RECORDS",
            "FINSIGHT_GOV_QUALITY_ISSUES",
            "FINSIGHT_RAG_CHUNKS",
            "FINSIGHT_GRAPH_EDGE",
        ],
        "starter_prompts": [
            "Profile FINSIGHT_CORE_RECORDS and summarize data quality risk by column.",
            "Run validation and list checks with the highest violation counts.",
            "Investigate fields related to personal data and sensitivity classifications.",
            "Analyze SOURCE_TO_TABLE and TABLE_TO_FIELD graph edges for coverage gaps.",
        ],
    }

    report_path = output_dir / "phase3_validation_report.json"
    blueprint_path = output_dir / "phase3_session_blueprint.json"

    report_path.write_text(json.dumps(phase3_report, indent=2, ensure_ascii=False), encoding="utf-8")
    blueprint_path.write_text(json.dumps(blueprint, indent=2, ensure_ascii=False), encoding="utf-8")

    md = f"""# Phase 3 Copilot Integration

Generated at: {datetime.now(UTC).isoformat()}

## Scope

- Copilot database class: `FinSight`
- Data source: `{machine_readable_dir}`
- Schema source: `{phase2_dir / "finsight_schema.edmx"}`
- Derived checks source: `{phase2_dir / "finsight_derived_checks.json"}`

## Integration Status

- Tables loaded: `{loaded_count}/{total_count}`
- Rule-based checks: `{len(db.rule_based_checks)}`
- Phase 2 derived checks: `{len(db.checks)}`
- Validation smoke test executed: `{validation_summary['executed']}`

## Commands

```bash
cd {copilot_root}
uv run python -m bin.copilot -d finsight --data-dir {machine_readable_dir}
```

```bash
cd {copilot_root}
uv run python -m bin.api -d finsight --data-dir {machine_readable_dir} --port 8000
```

## Outputs

- `phase3_validation_report.json`
- `phase3_session_blueprint.json`
"""
    (output_dir / "PHASE3_COPILOT_BOOTSTRAP.md").write_text(md, encoding="utf-8")

    print(f"Machine-readable dir: {machine_readable_dir}")
    print(f"Copilot root: {copilot_root}")
    print(f"Output dir: {output_dir}")
    print(f"Loaded tables: {loaded_count}/{total_count}")
    print(f"Rule-based checks: {len(db.rule_based_checks)}")
    print(f"Phase2 derived checks: {len(db.checks)}")
    print(f"Wrote {report_path}")
    print(f"Wrote {blueprint_path}")
    print(f"Wrote {output_dir / 'PHASE3_COPILOT_BOOTSTRAP.md'}")


if __name__ == "__main__":
    main()
