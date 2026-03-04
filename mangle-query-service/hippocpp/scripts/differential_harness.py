#!/usr/bin/env python3
"""Compare query corpus outputs from two backend commands."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def _run_backend(name: str, cmd_template: str, corpus_path: Path) -> dict[str, Any]:
    tmp_dir = tempfile.mkdtemp(prefix=f"hippocpp-diff-{name}-")
    command = cmd_template.replace("{corpus}", shlex.quote(str(corpus_path))).replace(
        "{tmpdir}", shlex.quote(tmp_dir)
    )
    proc = subprocess.run(command, shell=True, capture_output=True, text=True, check=False)

    if proc.returncode != 0:
        return {
            "runner_status": "error",
            "runner_error": f"Command failed with exit code {proc.returncode}",
            "command": command,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        }

    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return {
            "runner_status": "error",
            "runner_error": f"Invalid JSON output: {exc}",
            "command": command,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        }

    payload["runner_status"] = "ok"
    payload["command"] = command
    return payload


def _indexed_cases(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    cases = payload.get("cases", [])
    out: dict[str, dict[str, Any]] = {}
    for case in cases:
        if not isinstance(case, dict):
            continue
        name = str(case.get("name", "<unnamed>"))
        out[name] = case
    return out


def _case_key(case: dict[str, Any]) -> dict[str, Any]:
    return {
        "status": case.get("status"),
        "columns": case.get("columns"),
        "types": case.get("types"),
        "rows": case.get("rows"),
        "error": case.get("error"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--left-name", default="left")
    parser.add_argument("--right-name", default="right")
    parser.add_argument("--left-cmd", required=True, help="Shell command. Supports {corpus} and {tmpdir} placeholders.")
    parser.add_argument("--right-cmd", required=True, help="Shell command. Supports {corpus} and {tmpdir} placeholders.")
    parser.add_argument("--corpus", required=True, help="Path to corpus JSON.")
    parser.add_argument("--output", default=None, help="Optional output path for diff JSON.")
    args = parser.parse_args()

    corpus_path = Path(args.corpus).resolve()
    if not corpus_path.exists():
        print(f"error: corpus file does not exist: {corpus_path}", file=sys.stderr)
        return 2

    left = _run_backend(args.left_name, args.left_cmd, corpus_path)
    right = _run_backend(args.right_name, args.right_cmd, corpus_path)

    mismatches: list[dict[str, Any]] = []
    if left.get("runner_status") != "ok":
        mismatches.append({"kind": "runner", "side": args.left_name, "detail": left.get("runner_error")})
    if right.get("runner_status") != "ok":
        mismatches.append({"kind": "runner", "side": args.right_name, "detail": right.get("runner_error")})

    if not mismatches:
        left_cases = _indexed_cases(left)
        right_cases = _indexed_cases(right)
        for case_name in sorted(set(left_cases.keys()) | set(right_cases.keys())):
            left_case = left_cases.get(case_name)
            right_case = right_cases.get(case_name)
            if left_case is None:
                mismatches.append({"kind": "case_missing", "case": case_name, "side": args.left_name})
                continue
            if right_case is None:
                mismatches.append({"kind": "case_missing", "case": case_name, "side": args.right_name})
                continue
            if _case_key(left_case) != _case_key(right_case):
                mismatches.append(
                    {
                        "kind": "case_mismatch",
                        "case": case_name,
                        args.left_name: _case_key(left_case),
                        args.right_name: _case_key(right_case),
                    }
                )

    summary = {
        "corpus": str(corpus_path),
        "left_name": args.left_name,
        "right_name": args.right_name,
        "left_command": args.left_cmd,
        "right_command": args.right_cmd,
        "mismatch_count": len(mismatches),
        "mismatches": mismatches,
    }

    if args.output:
        output_path = Path(args.output).resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + os.linesep, encoding="utf-8")

    if mismatches:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1

    print(
        json.dumps(
            {
                "status": "ok",
                "corpus": str(corpus_path),
                "left_name": args.left_name,
                "right_name": args.right_name,
                "message": "No differential mismatches detected.",
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
