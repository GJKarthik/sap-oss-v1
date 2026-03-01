#!/usr/bin/env python3
"""Collect git lineage per service from manifest. Output JSON for LaTeX generator."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "docs" / "sbom-lineage-manifest.yaml"


def load_manifest(path: Path) -> list[dict]:
    if not path.exists():
        return []
    if yaml is None:
        raise RuntimeError("PyYAML required: pip install pyyaml")
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    return data.get("services", [])


def git_log(repo_root: Path, path: str, max_entries: int) -> list[dict]:
    out: list[dict] = []
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "log", f"--max-count={max_entries}",
             "--format=%H%x09%ai%x09%an%x09%s", "--", path],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            return out
        for line in result.stdout.strip().splitlines():
            parts = line.split("\t", 3)
            if len(parts) >= 4:
                out.append({"hash": parts[0][:12], "date": parts[1], "author": parts[2], "subject": parts[3]})
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--repo", type=Path, default=REPO_ROOT)
    p.add_argument("--manifest", type=Path, default=MANIFEST_PATH)
    p.add_argument("--output", type=Path, default=REPO_ROOT / "scripts" / "sbom-lineage" / "lineage.json")
    p.add_argument("--git-max", type=int, default=200)
    args = p.parse_args()
    manifest = load_manifest(args.manifest)
    services = []
    for svc in manifest:
        path_str = svc.get("path") or ""
        if not (args.repo / path_str).is_dir():
            continue
        services.append({
            "path": path_str,
            "name": svc.get("name") or path_str,
            "upstream": svc.get("upstream") or "",
            "plans_path": svc.get("plans_path") or "",
            "commits": git_log(args.repo, path_str, args.git_max),
        })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"lineage": {"services": services}}, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
