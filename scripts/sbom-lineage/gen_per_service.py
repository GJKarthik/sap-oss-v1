#!/usr/bin/env python3
"""
Generate one sbom-<service>.tex report per service listed in the manifest.

Usage:
    python3 scripts/sbom-lineage/gen_per_service.py
    python3 scripts/sbom-lineage/gen_per_service.py --service src/intelligence/ai-core-pal
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

REPO_ROOT = Path(__file__).parent.parent.parent
MANIFEST = REPO_ROOT / "docs" / "sbom" / "sbom-lineage-manifest.yaml"
SBOM_TEX_DIR = REPO_ROOT / "docs" / "sbom"
GENERATE_SCRIPT = Path(__file__).parent / "generate_latex.py"


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate per-service LaTeX SBOM files")
    parser.add_argument(
        "--service",
        help="Only generate for this service path (e.g. src/intelligence/ai-core-pal). Omit to generate all.",
    )
    args = parser.parse_args()

    manifest = yaml.safe_load(MANIFEST.read_text(encoding="utf-8"))
    services = manifest.get("services", [])

    if args.service:
        services = [s for s in services if s.get("path") == args.service]
        if not services:
            sys.exit(f"Service '{args.service}' not found in manifest.")

    SBOM_TEX_DIR.mkdir(parents=True, exist_ok=True)
    failed: list[str] = []

    for svc in services:
        path = svc["path"]
        out_stem = (svc.get("bom_stem") or path.replace("/", "-")).strip()
        out = SBOM_TEX_DIR / f"sbom-{out_stem}.tex"
        print(f"  Generating {out.relative_to(REPO_ROOT)} ...")
        cmd = [
            sys.executable,
            str(GENERATE_SCRIPT),
            "--service",
            path,
            "--output",
            str(out),
        ]
        if svc.get("bom_stem"):
            cmd.extend(["--bom-stem", svc["bom_stem"]])
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"  [ERROR] {path}:\n{result.stderr}", file=sys.stderr)
            failed.append(path)
        else:
            print(f"  [OK]    {out.name}")

    if failed:
        sys.exit(f"\n{len(failed)} service(s) failed: {', '.join(failed)}")
    else:
        print(f"\nAll {len(services)} per-service .tex file(s) written to docs/sbom/")


if __name__ == "__main__":
    main()

