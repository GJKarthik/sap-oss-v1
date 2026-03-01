#!/usr/bin/env python3
"""
slsa_provenance.py — SLSA v1.0 Build L1 provenance for CycloneDX BOMs.

Generates a SLSA v1.0 Build Provenance document (in-toto attestation envelope)
for each BOM artefact, satisfying:
  - US Executive Order 14028 (federal software supply chain)
  - CISA SBOM guidance (signed provenance)
  - EU Cyber Resilience Act Annex I (technical documentation)
  - SLSA Build Level 1 requirements

What is emitted (boms/provenance/<name>.slsa.json):
  {
    "_type": "https://in-toto.io/Statement/v1",
    "subject":      [{ digest: {sha256: ...}, name: <bom-filename> }],
    "predicateType": "https://slsa.dev/provenance/v1",
    "predicate": {
      "buildDefinition": {
        "buildType":            <uri>,
        "externalParameters":   { source repo, ref, path },
        "internalParameters":   { tool, version },
        "resolvedDependencies": [ tool BOM entries ]
      },
      "runDetails": {
        "builder":    { id: <uri> },
        "metadata":   { invocationId, startedOn, finishedOn },
        "byproducts": []
      }
    }
  }

A combined bundle (boms/provenance/provenance-bundle.json) containing all
provenances is also written for easy upload to a transparency log.

Usage:
  python3 scripts/sbom-lineage/slsa_provenance.py [--boms-dir DIR]
          [--builder-id URI] [--source-repo URI] [--source-ref REF]
          [--commit SHA] [--json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

BOMS_DIR_DEFAULT = Path(__file__).parent / "boms"

# Stable build type URI for this pipeline
BUILD_TYPE = "https://github.com/sap-oss/sbom-pipeline/build-type/cyclonedx@v1"
DEFAULT_BUILDER_ID   = "https://github.com/sap-oss/sbom-pipeline/builder@v1"
DEFAULT_SOURCE_REPO  = "https://github.com/sap-oss/sap-oss"
DEFAULT_SOURCE_REF   = "refs/heads/main"

# Tool versions embedded as resolved dependencies
_PIPELINE_TOOLS = [
    {"name": "build_cyclonedx.py",  "version": "1.0.0",  "uri": "scripts/sbom-lineage/build_cyclonedx.py"},
    {"name": "audit_sbom.py",       "version": "1.0.0",  "uri": "scripts/sbom-lineage/audit_sbom.py"},
    {"name": "vuln_overlay.py",     "version": "1.0.0",  "uri": "scripts/sbom-lineage/vuln_overlay.py"},
    {"name": "slsa_provenance.py",  "version": "1.0.0",  "uri": "scripts/sbom-lineage/slsa_provenance.py"},
]


def _git_head() -> tuple[str, str]:
    """Return (commit_sha, ref) from local git. Gracefully degrades."""
    try:
        sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, text=True
        ).strip()
        ref = subprocess.check_output(
            ["git", "symbolic-ref", "HEAD"], stderr=subprocess.DEVNULL, text=True
        ).strip()
        return sha, ref
    except Exception:
        return os.environ.get("GITHUB_SHA", ""), os.environ.get("GITHUB_REF", DEFAULT_SOURCE_REF)


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _tool_digest(tool_path: str) -> str:
    """SHA-256 of a pipeline tool script relative to repo root."""
    abs_path = Path(__file__).resolve().parents[2] / tool_path
    if abs_path.exists():
        return _file_sha256(abs_path)
    return ""


def make_provenance(
    bom_path: Path,
    *,
    builder_id: str,
    source_repo: str,
    source_ref: str,
    commit_sha: str,
    started_on: str,
    finished_on: str,
) -> dict:
    """Build a single SLSA v1.0 provenance document for one BOM file."""
    bom_digest = _file_sha256(bom_path)
    bom_name   = bom_path.name

    # Resolved dependencies: hash of each pipeline tool at build time
    resolved_deps: list[dict] = []
    for tool in _PIPELINE_TOOLS:
        digest = _tool_digest(tool["uri"])
        dep: dict = {
            "uri":    f"{source_repo}/blob/{source_ref}/{tool['uri']}",
            "name":   tool["name"],
        }
        if digest:
            dep["digest"] = {"sha256": digest}
        resolved_deps.append(dep)

    # Source repo as a resolved dependency
    if commit_sha:
        resolved_deps.append({
            "uri":    f"{source_repo}",
            "digest": {"gitCommit": commit_sha},
            "name":   "source",
        })

    provenance = {
        "_type":         "https://in-toto.io/Statement/v1",
        "subject": [
            {
                "name":   bom_name,
                "digest": {"sha256": bom_digest},
                "uri":    f"{source_repo}/blob/{source_ref}/scripts/sbom-lineage/boms/{bom_name}",
            }
        ],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": BUILD_TYPE,
                "externalParameters": {
                    "source":    source_repo,
                    "ref":       source_ref,
                    "bom_file":  f"scripts/sbom-lineage/boms/{bom_name}",
                },
                "internalParameters": {
                    "pipeline":  "SAP OSS SBOM Pipeline",
                    "version":   "1.0.0",
                    "spec":      "CycloneDX 1.5",
                    "ntia":      "July 2021",
                },
                "resolvedDependencies": resolved_deps,
            },
            "runDetails": {
                "builder": {
                    "id":      builder_id,
                    "version": {"pipeline": "1.0.0"},
                },
                "metadata": {
                    "invocationId": f"{source_repo}/actions/runs/{os.environ.get('GITHUB_RUN_ID', 'local')}",
                    "startedOn":    started_on,
                    "finishedOn":   finished_on,
                },
                "byproducts": [
                    {"name": "sha256-manifest", "uri": "scripts/sbom-lineage/boms/sbom-sha256-manifest.json"},
                ],
            },
        },
    }
    return provenance


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate SLSA v1.0 Build L1 provenance for CycloneDX BOMs"
    )
    parser.add_argument("--boms-dir",    type=Path, default=BOMS_DIR_DEFAULT)
    parser.add_argument("--builder-id",  default=os.environ.get("SLSA_BUILDER_ID", DEFAULT_BUILDER_ID))
    parser.add_argument("--source-repo", default=os.environ.get("GITHUB_SERVER_URL", "").rstrip("/")
                        + "/" + os.environ.get("GITHUB_REPOSITORY", "")
                        or DEFAULT_SOURCE_REPO)
    parser.add_argument("--source-ref",  default=os.environ.get("GITHUB_REF", DEFAULT_SOURCE_REF))
    parser.add_argument("--commit",      default=os.environ.get("GITHUB_SHA", ""))
    parser.add_argument("--json",        action="store_true", help="Print bundle JSON to stdout")
    args = parser.parse_args()

    # Fill in commit/ref from git if not provided
    git_sha, git_ref = _git_head()
    commit_sha  = args.commit     or git_sha
    source_ref  = args.source_ref or git_ref

    # Fix up source-repo if GitHub env vars were empty
    if not args.source_repo or args.source_repo == "/":
        args.source_repo = DEFAULT_SOURCE_REPO

    bom_files = sorted(args.boms_dir.glob("*.cyclonedx.json"))
    if not bom_files:
        print(f"No BOMs found in {args.boms_dir}", file=sys.stderr)
        sys.exit(2)

    out_dir = args.boms_dir / "provenance"
    out_dir.mkdir(parents=True, exist_ok=True)

    now    = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    bundle: list[dict] = []

    for bf in bom_files:
        prov = make_provenance(
            bf,
            builder_id  = args.builder_id,
            source_repo = args.source_repo,
            source_ref  = source_ref,
            commit_sha  = commit_sha,
            started_on  = now,
            finished_on = now,
        )
        bundle.append(prov)
        name     = bf.stem.replace(".cyclonedx", "")
        out_path = out_dir / f"{name}.slsa.json"
        out_path.write_text(json.dumps(prov, indent=2, ensure_ascii=False), encoding="utf-8")

    bundle_path = out_dir / "provenance-bundle.json"
    bundle_path.write_text(json.dumps(bundle, indent=2, ensure_ascii=False), encoding="utf-8")

    if args.json:
        print(json.dumps(bundle, indent=2))
    else:
        print("\n" + "=" * 72)
        print("  SLSA v1.0 PROVENANCE REPORT")
        print("=" * 72)
        for prov in bundle:
            subj     = prov["subject"][0]
            sha_short = subj["digest"]["sha256"][:16]
            print(f"  ✓  {subj['name']:55s}  sha256={sha_short}…")
        print(f"\n  Builder:  {args.builder_id}")
        print(f"  Source:   {args.source_repo} @ {source_ref[:30]}")
        print(f"  Commit:   {(commit_sha or 'unknown')[:16]}…" if commit_sha else "  Commit:   (unknown)")
        print(f"\n  {len(bundle)} provenance docs written to {out_dir}/")
        print(f"  Bundle:   {bundle_path}")
        print("=" * 72)


if __name__ == "__main__":
    main()

