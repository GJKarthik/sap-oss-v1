#!/usr/bin/env python3
"""Fail CI when parity metrics regress past configured thresholds."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


PATTERN = re.compile(r"\b(TODO|FIXME|UNIMPLEMENTED|stub)\b")


def _count_todo_markers(root: Path) -> int:
    count = 0
    for path in root.rglob("*.zig"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for line in text.splitlines():
            if PATTERN.search(line):
                count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", required=True, help="Path to PARITY-SUMMARY.json")
    parser.add_argument("--baseline", required=True, help="Path to baseline JSON thresholds")
    parser.add_argument("--zig-src", required=True, help="Path to zig/src directory")
    args = parser.parse_args()

    summary = json.loads(Path(args.summary).read_text(encoding="utf-8"))
    baseline = json.loads(Path(args.baseline).read_text(encoding="utf-8"))
    todo_count = _count_todo_markers(Path(args.zig_src))

    failures: list[str] = []

    required_mirror_status = baseline.get("require_mirror_status")
    if required_mirror_status and summary.get("mirror_status") != required_mirror_status:
        failures.append(
            f"mirror_status={summary.get('mirror_status')} (required {required_mirror_status})"
        )

    max_kuzu_only = baseline.get("kuzu_only_total_max")
    if isinstance(max_kuzu_only, int) and int(summary.get("kuzu_only_total", 0)) > max_kuzu_only:
        failures.append(
            f"kuzu_only_total={summary.get('kuzu_only_total')} exceeded max={max_kuzu_only}"
        )

    min_exact_matches = baseline.get("exact_match_total_min")
    if isinstance(min_exact_matches, int) and int(summary.get("exact_match_total", 0)) < min_exact_matches:
        failures.append(
            f"exact_match_total={summary.get('exact_match_total')} below min={min_exact_matches}"
        )

    max_todo = baseline.get("todo_markers_max")
    if isinstance(max_todo, int) and todo_count > max_todo:
        failures.append(f"todo_markers={todo_count} exceeded max={max_todo}")

    print(
        json.dumps(
            {
                "summary_file": args.summary,
                "baseline_file": args.baseline,
                "mirror_status": summary.get("mirror_status"),
                "kuzu_only_total": summary.get("kuzu_only_total"),
                "exact_match_total": summary.get("exact_match_total"),
                "todo_markers": todo_count,
                "failure_count": len(failures),
                "failures": failures,
            },
            indent=2,
            sort_keys=True,
        )
    )

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
