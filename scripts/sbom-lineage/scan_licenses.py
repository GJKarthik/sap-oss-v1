#!/usr/bin/env python3
"""
scan_licenses.py — Source-level license & copyright discovery (binary-fingerprinting analog).

For every service in the manifest this tool:
  1. Walks the source tree and extracts inline SPDX-License-Identifier and
     copyright notice lines from every source file.
  2. Computes a SHA-256 digest for each scanned file and emits a file-level
     manifest (the closest pure-Python approximation of Black Duck's byte-level
     fingerprinting without a commercial knowledge base).
  3. Compares the *discovered* license set against the *declared* license set
     in the corresponding CycloneDX BOM and flags any discrepancy.
  4. Generates a per-service REUSE-compatible SPDX summary JSON.

Output:
  boms/scan/<service>.scan.json  — per-file hash + discovered SPDX info
  boms/scan/summary.json         — cross-service discrepancy report

Exit codes:
  0 — completed (discrepancies are WARNs, not failures by default)
  1 — at least one declared-vs-discovered license mismatch with --fail-on-mismatch
  2 — no source directories found

Usage:
  python3 scripts/sbom-lineage/scan_licenses.py [--repo-root DIR]
          [--boms-dir DIR] [--fail-on-mismatch] [--json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

try:
    import yaml as _yaml
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

REPO_ROOT         = Path(__file__).resolve().parents[2]
MANIFEST_PATH     = REPO_ROOT / "docs" / "sbom" / "sbom-lineage-manifest.yaml"
BOMS_DIR_DEFAULT  = Path(__file__).parent / "boms"

# Source file extensions to scan
_SOURCE_EXTS = {
    ".py", ".js", ".ts", ".tsx", ".jsx", ".mjs", ".cjs",
    ".go", ".rs", ".java", ".kt", ".scala",
    ".c", ".cpp", ".h", ".hpp", ".cc",
    ".sh", ".bash", ".zsh",
    ".yaml", ".yml", ".toml",
}

# Directories to always skip
_SKIP_DIRS = {
    "node_modules", ".git", "__pycache__", ".mypy_cache", ".tox",
    "dist", "build", "target", ".gradle", ".cargo", "vendor",
    ".venv", "venv", ".sbom-venv", "coverage", ".nyc_output",
}

_SPDX_HEADER_RE = re.compile(
    r"SPDX-License-Identifier\s*:\s*([A-Za-z0-9\.\-\+\(\) ]+)", re.IGNORECASE
)
_COPYRIGHT_RE = re.compile(
    r"(Copyright\s.*?(?=\n|$))", re.IGNORECASE
)

# Long-form boilerplate → SPDX ID mapping (for upstream trees that ship the full
# Apache 2.0 header block rather than the compact SPDX short-form).
_LONG_FORM_HEADERS: list[tuple[str, str]] = [
    ("Licensed under the Apache License, Version 2.0",        "Apache-2.0"),
    ("GNU Affero General Public License",                      "AGPL-3.0-only"),
    ("GNU General Public License",                            "GPL-3.0-only"),
    ("GNU Lesser General Public License",                     "LGPL-2.1-only"),
    ("Mozilla Public License, Version 2.0",                   "MPL-2.0"),
    ("Eclipse Public License",                                "EPL-2.0"),
    ("MIT License",                                           "MIT"),
    ("Permission is hereby granted, free of charge",          "MIT"),
    ("BSD 3-Clause",                                          "BSD-3-Clause"),
    ("BSD 2-Clause",                                          "BSD-2-Clause"),
    ("ISC License",                                           "ISC"),
]

# Known SPDX prefixes for quick normalization
_SPDX_ALIASES = {
    "apache 2.0": "Apache-2.0", "apache-2.0": "Apache-2.0",
    "mit": "MIT", "bsd-3-clause": "BSD-3-Clause", "bsd-2-clause": "BSD-2-Clause",
    "gpl-3.0": "GPL-3.0-only", "gpl-2.0": "GPL-2.0-only",
    "lgpl-2.1": "LGPL-2.1-only", "lgpl-3.0": "LGPL-3.0-only",
    "agpl-3.0": "AGPL-3.0-only", "mpl-2.0": "MPL-2.0",
}


def _normalize_spdx(raw: str) -> str:
    s = raw.strip()
    return _SPDX_ALIASES.get(s.lower(), s)


def scan_file(path: Path) -> dict:
    """Return {path, sha256, spdx_ids, copyrights}. Reads up to first 100 lines for headers."""
    result: dict = {"path": str(path), "sha256": "", "spdx_ids": [], "copyrights": []}
    try:
        data = path.read_bytes()
        result["sha256"] = hashlib.sha256(data).hexdigest()
        # Scan first 100 lines for SPDX headers (avoid reading huge binary blobs)
        try:
            text = data[:8192].decode("utf-8", errors="replace")
        except Exception:
            return result
        for m in _SPDX_HEADER_RE.finditer(text):
            lid = _normalize_spdx(m.group(1).strip())
            if lid and lid not in result["spdx_ids"]:
                result["spdx_ids"].append(lid)
        # If no compact SPDX header found, fall back to long-form boilerplate detection
        if not result["spdx_ids"]:
            for pattern, spdx_id in _LONG_FORM_HEADERS:
                if pattern in text:
                    if spdx_id not in result["spdx_ids"]:
                        result["spdx_ids"].append(spdx_id)
                    break  # use first (most specific) match
        for m in _COPYRIGHT_RE.finditer(text):
            notice = m.group(1).strip()
            if notice and notice not in result["copyrights"]:
                result["copyrights"].append(notice[:200])
    except OSError:
        pass
    return result


def _load_reuse_toml(service_dir: Path) -> list[tuple[list[str], str, str]]:
    """
    Parse REUSE.toml (REUSE 3.x spec) and return a list of
    (glob_patterns, spdx_id, copyright) tuples.
    Files matching a glob pattern are considered covered even without inline headers.
    Falls back gracefully if the file is absent or tomllib is unavailable.
    """
    toml_path = service_dir / "REUSE.toml"
    if not toml_path.exists():
        return []
    try:
        # Python 3.11+: tomllib is stdlib. Earlier versions: fall back.
        try:
            import tomllib
            with open(toml_path, "rb") as fh:
                data = tomllib.load(fh)
        except ImportError:
            try:
                import tomli as tomllib  # type: ignore[no-redef]
                with open(toml_path, "rb") as fh:
                    data = tomllib.load(fh)
            except ImportError:
                # Manual best-effort parse: extract SPDX-License-Identifier lines
                text = toml_path.read_text(encoding="utf-8")
                lid  = ""
                for line in text.splitlines():
                    m = re.search(r'SPDX-License-Identifier\s*=\s*"([^"]+)"', line)
                    if m:
                        lid = m.group(1)
                return [([("**",)], lid, "")] if lid else []

        entries = []
        for ann in data.get("annotations", []):
            raw_paths = ann.get("path", [])
            if isinstance(raw_paths, str):
                raw_paths = [raw_paths]
            spdx_id   = ann.get("SPDX-License-Identifier", "")
            copyright = ann.get("SPDX-FileCopyrightText", "")
            if spdx_id and raw_paths:
                entries.append((raw_paths, spdx_id, copyright))
        return entries
    except Exception:
        return []


def _reuse_covers(rel_path: str, entries: list[tuple[list[str], str, str]]) -> tuple[str, str]:
    """Return (spdx_id, copyright) from REUSE.toml if rel_path matches any annotation, else ('','')."""
    import fnmatch
    for globs, spdx_id, copyright in entries:
        for pattern in globs:
            if fnmatch.fnmatch(rel_path, pattern) or fnmatch.fnmatch(rel_path.replace("\\", "/"), pattern):
                return spdx_id, copyright
    return "", ""


def scan_service(service_dir: Path) -> dict:
    """Scan all source files in a service directory. Returns aggregated results."""
    files: list[dict] = []
    all_spdx: set[str] = set()
    all_copyrights: set[str] = set()
    skipped = 0

    # Parse REUSE.toml once for the whole service directory (P2-C).
    reuse_entries = _load_reuse_toml(service_dir)

    for f in service_dir.rglob("*"):
        if not f.is_file():
            continue
        # Skip blacklisted directories
        if any(part in _SKIP_DIRS for part in f.parts):
            skipped += 1
            continue
        if f.suffix.lower() not in _SOURCE_EXTS:
            continue
        result = scan_file(f)
        rel = str(f.relative_to(service_dir))
        result["path"] = rel

        # If no inline SPDX header found, check REUSE.toml annotations.
        if not result["spdx_ids"] and reuse_entries:
            covered_id, covered_copy = _reuse_covers(rel, reuse_entries)
            if covered_id:
                result["spdx_ids"]    = [covered_id]
                result["copyrights"]  = [covered_copy] if covered_copy else result["copyrights"]
                result["via_reuse_toml"] = True

        files.append(result)
        all_spdx.update(result["spdx_ids"])
        all_copyrights.update(result["copyrights"])

    files_with_spdx    = sum(1 for f in files if f["spdx_ids"])
    files_with_copy    = sum(1 for f in files if f["copyrights"])
    coverage_pct       = round(100 * files_with_spdx / len(files)) if files else 0

    return {
        "total_files":      len(files),
        "files_with_spdx":  files_with_spdx,
        "files_with_copyright": files_with_copy,
        "spdx_coverage_pct": coverage_pct,
        "discovered_spdx":   sorted(all_spdx),
        "discovered_copyrights": sorted(all_copyrights)[:20],
        "files":             files,
        "reuse_toml_active": bool(reuse_entries),
    }


def _bom_declared_licenses(bom: dict) -> set[str]:
    """Extract all SPDX IDs declared in a CycloneDX BOM (root + components)."""
    ids: set[str] = set()
    all_comps = [bom.get("metadata", {}).get("component", {})] + bom.get("components", [])
    for comp in all_comps:
        for le in comp.get("licenses", []):
            if le.get("expression"):
                ids.add(le["expression"])
            lid = le.get("license", {}).get("id", "")
            if lid:
                ids.add(lid)
    return ids


def compare_licenses(
    discovered: set[str], declared: set[str]
) -> dict:
    """Return {extra_discovered, missing_from_declared, verdict}."""
    # Only compare standard SPDX IDs (not LicenseRef-*)
    std_disc = {s for s in discovered if not s.startswith("LicenseRef-")}
    std_decl = {s for s in declared  if not s.startswith("LicenseRef-")}

    extra   = std_disc - std_decl   # found in source, not in BOM
    missing = std_decl - std_disc   # in BOM, not found in source headers

    if extra:
        verdict = "MISMATCH"
    elif not std_disc and std_decl:
        verdict = "NO_HEADERS"   # BOM has licenses but no inline SPDX headers
    else:
        verdict = "OK"
    return {"extra_in_source": sorted(extra), "missing_in_source": sorted(missing), "verdict": verdict}


def load_manifest() -> list[dict]:
    if not _YAML_AVAILABLE:
        raise RuntimeError("PyYAML required: pip install pyyaml")
    with open(MANIFEST_PATH, encoding="utf-8") as fh:
        return (_yaml.safe_load(fh) or {}).get("services", [])


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Source-level license discovery and declared-vs-discovered comparison"
    )
    parser.add_argument("--repo-root",        type=Path, default=REPO_ROOT)
    parser.add_argument("--boms-dir",         type=Path, default=BOMS_DIR_DEFAULT)
    parser.add_argument("--fail-on-mismatch", action="store_true",
                        help="Exit 1 if any declared-vs-discovered license mismatch found")
    parser.add_argument("--json",             action="store_true")
    parser.add_argument("--no-file-detail",   action="store_true",
                        help="Omit per-file list from output (faster, smaller JSON)")
    args = parser.parse_args()

    try:
        services = load_manifest()
    except Exception as exc:
        print(f"Cannot load manifest: {exc}", file=sys.stderr)
        sys.exit(2)

    out_dir = args.boms_dir / "scan"
    out_dir.mkdir(parents=True, exist_ok=True)

    all_summaries: list[dict] = []
    any_mismatch = False

    for svc in services:
        path_str = svc.get("path", "")
        bom_stem = svc.get("bom_stem", path_str)
        report_key = bom_stem.replace("/", "-")
        svc_dir  = args.repo_root / path_str
        bom_path = args.boms_dir / f"{bom_stem}.cyclonedx.json"

        if not svc_dir.is_dir():
            continue

        print(f"  Scanning {path_str} ({report_key}) ...", file=sys.stderr, flush=True)
        scan = scan_service(svc_dir)

        # Load declared licenses from BOM
        declared: set[str] = set()
        if bom_path.exists():
            try:
                bom = json.loads(bom_path.read_text(encoding="utf-8"))
                declared = _bom_declared_licenses(bom)
            except Exception:
                pass

        comparison = compare_licenses(set(scan["discovered_spdx"]), declared)

        summary = {
            "service":            report_key,
            "total_files":        scan["total_files"],
            "files_with_spdx":    scan["files_with_spdx"],
            "spdx_coverage_pct":  scan["spdx_coverage_pct"],
            "files_with_copyright": scan["files_with_copyright"],
            "discovered_spdx":    scan["discovered_spdx"],
            "declared_spdx":      sorted(declared),
            "comparison":         comparison,
        }
        all_summaries.append(summary)

        if comparison["verdict"] in ("MISMATCH",):
            any_mismatch = True

        # Write per-service scan file (with file details unless suppressed)
        scan_out = dict(summary)
        if not args.no_file_detail:
            scan_out["files"] = scan["files"]
        scan_out["discovered_copyrights"] = scan.get("discovered_copyrights", [])
        out_path = out_dir / f"{report_key}.scan.json"
        out_path.write_text(json.dumps(scan_out, indent=2, ensure_ascii=False), encoding="utf-8")

    # Write cross-service summary
    summary_path = out_dir / "summary.json"
    summary_path.write_text(
        json.dumps({"generated": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "services": all_summaries}, indent=2),
        encoding="utf-8",
    )

    if args.json:
        print(json.dumps({"services": all_summaries}, indent=2))
    else:
        print("\n" + "=" * 72)
        print("  SOURCE LICENSE SCAN — Declared vs Discovered")
        print("=" * 72)
        for s in all_summaries:
            verdict = s["comparison"]["verdict"]
            icon = {"OK": "✓", "NO_HEADERS": "~", "MISMATCH": "✗"}.get(verdict, "?")
            cov  = s["spdx_coverage_pct"]
            print(f"\n  {icon}  {s['service']:50s}  SPDX headers: {cov}%  [{verdict}]")
            if s["discovered_spdx"]:
                print(f"      discovered : {s['discovered_spdx']}")
            if s["comparison"]["extra_in_source"]:
                print(f"      ⚠  in-source only (not in BOM): {s['comparison']['extra_in_source']}")
            if s["comparison"]["missing_in_source"]:
                print(f"      ℹ  in BOM only (no header): {s['comparison']['missing_in_source'][:4]}")
        print(f"\n  Scan files written to {out_dir}/")
        print("=" * 72)

    if args.fail_on_mismatch and any_mismatch:
        sys.exit(1)


if __name__ == "__main__":
    main()

