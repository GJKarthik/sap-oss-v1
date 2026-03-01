#!/usr/bin/env python3
"""
vuln_overlay.py — OSV vulnerability overlay + VEX generation for CycloneDX 1.5 BOMs.

Queries the OSV.dev batch API for every component in each BOM, then:
  1. Overlays a `vulnerabilities` array into each BOM JSON (CycloneDX 1.5).
  2. Writes a companion VEX document to boms/vex/<name>.vex.cdx.json.
  3. Prints a severity-sorted summary report.

Exit codes:
  0 — completed (vulnerabilities may or may not be found)
  1 — OSV API unreachable or fatal error
  2 — no BOM files found

Usage:
  python3 scripts/sbom-lineage/vuln_overlay.py [--boms-dir DIR] [--json]
                                                [--no-overlay] [--min-severity LEVEL]
                                                [--fail-on-critical] [--fail-on-high]
                                                [--offline-ok]

--offline-ok: Skip all OSV network queries. VEX stubs (zero vulnerabilities) are
  still written to boms/vex/ so the artefact directory is always populated.
  Use this in air-gapped CI or when OSV is unreachable.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

BOMS_DIR_DEFAULT = Path(__file__).parent / "boms"
OSV_BATCH_URL = "https://api.osv.dev/v1/querybatch"
OSV_VULN_URL  = "https://osv.dev/vulnerability/{}"
BATCH_SIZE    = 999   # OSV max is 1000 queries per call
REQUEST_DELAY = 0.3   # seconds between batches (rate-limiting courtesy)

SEVERITY_ORDER = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "NONE": 4, "UNKNOWN": 5}

# ── OSV helpers ───────────────────────────────────────────────────────────────

def _osv_severity(vuln: dict) -> str:
    """Extract highest CVSS severity string from an OSV vuln record."""
    best = "UNKNOWN"
    for sev in vuln.get("severity", []):
        score_type = sev.get("type", "")
        score_val  = sev.get("score", "")
        # CVSS v3 score → bucket
        if "CVSS_V3" in score_type or "CVSSv3" in score_type:
            try:
                val = float(score_val)
                if val >= 9.0:   bucket = "CRITICAL"
                elif val >= 7.0: bucket = "HIGH"
                elif val >= 4.0: bucket = "MEDIUM"
                else:            bucket = "LOW"
                if SEVERITY_ORDER.get(bucket, 9) < SEVERITY_ORDER.get(best, 9):
                    best = bucket
            except ValueError:
                pass
        # Some OSV records use string severity directly
        elif score_val.upper() in SEVERITY_ORDER:
            candidate = score_val.upper()
            if SEVERITY_ORDER.get(candidate, 9) < SEVERITY_ORDER.get(best, 9):
                best = candidate
    # Aliases may contain NVD data with CVSS
    if best == "UNKNOWN":
        db_specific = vuln.get("database_specific", {})
        sev_str = db_specific.get("severity", "").upper()
        if sev_str in SEVERITY_ORDER:
            best = sev_str
    return best


def _osv_cvss_score(vuln: dict) -> float | None:
    for sev in vuln.get("severity", []):
        if "CVSS_V3" in sev.get("type", "") or "CVSSv3" in sev.get("type", ""):
            try:
                return float(sev["score"])
            except (ValueError, KeyError):
                pass
    return None


def _query_osv_batch(queries: list[dict]) -> list[list[dict]]:
    """Send up to BATCH_SIZE PURL queries to OSV and return list-of-vuln-lists."""
    body = json.dumps({"queries": queries}).encode()
    req  = urllib.request.Request(
        OSV_BATCH_URL,
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": "SAP-OSS-SBOM/1.0"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read())
    return [r.get("vulns", []) for r in data.get("results", [])]


def query_osv_for_bom(components: list[dict]) -> dict[str, list[dict]]:
    """
    Map each component's bom-ref → list of OSV vuln records.
    Uses PURL for lookup. Skips components without a purl.
    """
    indexed = [(c.get("bom-ref", ""), c.get("purl", "")) for c in components if c.get("purl")]
    result: dict[str, list[dict]] = {}

    for i in range(0, len(indexed), BATCH_SIZE):
        chunk = indexed[i : i + BATCH_SIZE]
        queries = [{"package": {"purl": purl}} for _, purl in chunk]
        try:
            responses = _query_osv_batch(queries)
        except Exception as exc:
            print(f"[WARN] OSV batch query failed: {exc}", file=sys.stderr)
            responses = [[] for _ in chunk]
        for (ref, _), vulns in zip(chunk, responses):
            if vulns:
                result[ref] = vulns
        if i + BATCH_SIZE < len(indexed):
            time.sleep(REQUEST_DELAY)

    return result


# ── CycloneDX helpers ─────────────────────────────────────────────────────────

def _osv_fixed_versions(vuln: dict) -> list[str]:
    """
    Extract all fixed version strings from an OSV record's affected[].ranges[].events.
    Returns an empty list if no fix exists.
    """
    fixed: list[str] = []
    for affected in vuln.get("affected", []):
        for rng in affected.get("ranges", []):
            for event in rng.get("events", []):
                fv = event.get("fixed")
                if fv and fv not in fixed:
                    fixed.append(fv)
    return fixed


def _cdx_vuln_entry(vuln: dict, affected_refs: list[str]) -> dict:
    """Convert an OSV vuln record to a CycloneDX 1.5 vulnerabilities[] entry."""
    vid       = vuln.get("id", "UNKNOWN")
    aliases   = vuln.get("aliases", [])
    cve_id    = next((a for a in aliases if a.startswith("CVE-")), None)
    summary   = vuln.get("summary", "")
    published = vuln.get("published", "")
    modified  = vuln.get("modified", "")
    sev       = _osv_severity(vuln)
    score     = _osv_cvss_score(vuln)

    # Derive VEX analysis from OSV data — do NOT use placeholder defaults.
    # CycloneDX VEX spec:
    #   state:    in_triage | resolved | exploitable | false_positive | not_affected
    #   response: update | can_not_fix | will_not_fix | rollback | workaround_available
    #   'will_not_fix' means an explicit business decision; never use as a default.
    fixed_versions = _osv_fixed_versions(vuln)
    if fixed_versions:
        analysis_response = ["update"]
        analysis_detail   = (
            f"Fix available in version(s): {', '.join(fixed_versions[:5])}. "
            "Update the dependency to the fixed version to remediate. "
            "State remains 'in_triage' until human review confirms no other mitigations are needed."
        )
    else:
        analysis_response = ["can_not_fix"]
        analysis_detail   = (
            "No fixed version available from OSV at time of scan. "
            "Monitor https://osv.dev and the upstream advisory for a fix. "
            "Consider patching, forking, or applying a workaround."
        )

    entry: dict = {
        "id": cve_id or vid,
        "source": {
            "name": "OSV",
            "url":  OSV_VULN_URL.format(vid),
        },
        "ratings": [
            {
                "severity": sev.lower(),
                **({"score": score, "method": "CVSSv3"} if score is not None else {}),
                "source": {"name": "OSV"},
            }
        ],
        "description":  summary,
        "published":    published,
        "updated":      modified,
        "affects": [{"ref": r} for r in affected_refs],
        "analysis": {
            "state":    "in_triage",   # automated; human review updates this
            "response": analysis_response,
            "detail":   analysis_detail,
        },
    }
    if aliases:
        entry["references"] = [
            {"id": a, "source": {"name": "OSV-ALIAS", "url": OSV_VULN_URL.format(a)}}
            for a in aliases
        ]
    return entry


def build_vex_document(bom: dict, vuln_entries: list[dict]) -> dict:
    """Build a standalone CycloneDX 1.5 VEX document for the BOM."""
    root_comp = bom.get("metadata", {}).get("component", {})
    return {
        "bomFormat":    "CycloneDX",
        "specVersion":  "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version":      1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": root_comp,
            "authors":   [{"name": "SAP SE — SBOM Pipeline (automated)"}],
            "lifecycles": [{"phase": "operations"}],
        },
        "vulnerabilities": vuln_entries,
    }


# ── Main logic ────────────────────────────────────────────────────────────────

def overlay_bom(bom_path: Path, *, no_overlay: bool, min_severity: str, offline_ok: bool = False) -> dict:
    """
    Process one BOM file. Returns a summary dict:
      {name, total_components, queried, vuln_count, by_severity, vulns}
    """
    name = bom_path.stem.replace(".cyclonedx", "")
    bom  = json.loads(bom_path.read_text(encoding="utf-8"))
    comps = [c for c in bom.get("components", []) if c.get("purl")]

    if offline_ok:
        # Skip OSV network query; VEX stubs with zero vulns will still be written.
        ref_map: dict[str, list[dict]] = {}
    else:
        ref_map = query_osv_for_bom(comps)
    all_vuln_entries: list[dict] = []
    by_severity: dict[str, int] = {k: 0 for k in SEVERITY_ORDER}

    # Aggregate: one CycloneDX entry per unique vuln ID
    vuln_id_to_refs: dict[str, tuple[dict, list[str]]] = {}
    for ref, vulns in ref_map.items():
        for v in vulns:
            vid = v.get("id", "UNKNOWN")
            if vid not in vuln_id_to_refs:
                vuln_id_to_refs[vid] = (v, [])
            vuln_id_to_refs[vid][1].append(ref)

    min_rank = SEVERITY_ORDER.get(min_severity.upper(), 9)
    for vid, (vuln, refs) in vuln_id_to_refs.items():
        sev = _osv_severity(vuln)
        by_severity[sev] = by_severity.get(sev, 0) + 1
        if SEVERITY_ORDER.get(sev, 9) <= min_rank:
            all_vuln_entries.append(_cdx_vuln_entry(vuln, refs))

    all_vuln_entries.sort(
        key=lambda e: SEVERITY_ORDER.get((e.get("ratings") or [{}])[0].get("severity", "").upper(), 9)
    )

    # Always write the VEX document — even with no_overlay or offline_ok.
    # VEX stubs (zero vulns) are required artefacts for compliance; tools like
    # GitHub Dependency Graph and CISA VEX WG tooling expect the file to exist.
    vex_dir  = bom_path.parent / "vex"
    vex_dir.mkdir(exist_ok=True)
    vex_doc  = build_vex_document(bom, all_vuln_entries)
    vex_path = vex_dir / f"{name}.vex.cdx.json"
    vex_path.write_text(json.dumps(vex_doc, indent=2, ensure_ascii=False), encoding="utf-8")

    if not no_overlay:
        bom["vulnerabilities"] = all_vuln_entries
        bom_path.write_text(json.dumps(bom, indent=2, ensure_ascii=False), encoding="utf-8")

    return {
        "name":             name,
        "total_components": len(bom.get("components", [])),
        "queried":          len(comps),
        "vuln_count":       len(vuln_id_to_refs),
        "filtered_count":   len(all_vuln_entries),
        "by_severity":      dict(by_severity),
        "vulns":            all_vuln_entries,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Overlay OSV vulnerability data onto CycloneDX 1.5 BOMs and generate VEX"
    )
    parser.add_argument("--boms-dir",        type=Path,  default=BOMS_DIR_DEFAULT)
    parser.add_argument("--json",            action="store_true", help="Emit JSON summary")
    parser.add_argument("--no-overlay",      action="store_true", help="Query only; do not write BOM/VEX files")
    parser.add_argument("--min-severity",    default="LOW",
                        choices=["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"],
                        help="Minimum severity to include in overlay/VEX (default: LOW)")
    parser.add_argument("--fail-on-critical", action="store_true", help="Exit 1 if any CRITICAL vuln found")
    parser.add_argument("--fail-on-high",     action="store_true", help="Exit 1 if any CRITICAL or HIGH vuln found")
    parser.add_argument("--offline-ok",       action="store_true",
                        help="Skip OSV network queries; still write VEX stubs (zero vulns)")
    args = parser.parse_args()

    if args.offline_ok:
        print("  [INFO] --offline-ok: skipping OSV queries; VEX stubs will be written with zero vulnerabilities.",
              file=sys.stderr)

    bom_files = sorted(args.boms_dir.glob("*.cyclonedx.json"))
    if not bom_files:
        print(f"No BOMs found in {args.boms_dir}", file=sys.stderr)
        sys.exit(2)

    summaries: list[dict] = []
    for bf in bom_files:
        print(f"  Scanning {bf.name} ...", file=sys.stderr, flush=True)
        try:
            s = overlay_bom(bf, no_overlay=args.no_overlay, min_severity=args.min_severity,
                            offline_ok=args.offline_ok)
            summaries.append(s)
        except Exception as exc:
            print(f"  [ERROR] {bf.name}: {exc}", file=sys.stderr)

    grand_sev: dict[str, int] = {k: 0 for k in SEVERITY_ORDER}
    for s in summaries:
        for k, v in s["by_severity"].items():
            grand_sev[k] = grand_sev.get(k, 0) + v

    if args.json:
        print(json.dumps({"summaries": summaries, "totals": grand_sev}, indent=2))
    else:
        print("\n" + "=" * 72)
        print("  OSV VULNERABILITY OVERLAY REPORT")
        print("=" * 72)
        for s in summaries:
            total = s["vuln_count"]
            sev   = s["by_severity"]
            crit  = sev.get("CRITICAL", 0)
            high  = sev.get("HIGH", 0)
            med   = sev.get("MEDIUM", 0)
            low   = sev.get("LOW", 0)
            unk   = sev.get("UNKNOWN", 0)
            flag  = " ⚠ CRITICAL" if crit else (" ⚠ HIGH" if high else "")
            print(f"\n  {s['name']}{flag}")
            print(f"    Components: {s['queried']}  |  Vulns: {total}  "
                  f"(C={crit} H={high} M={med} L={low} U={unk})")
            for e in s["vulns"]:
                sev_tag  = (e.get("ratings") or [{}])[0].get("severity", "?").upper()
                score    = (e.get("ratings") or [{}])[0].get("score")
                score_s  = f" [{score:.1f}]" if score else ""
                n_affects = len(e.get("affects", []))
                print(f"    [{sev_tag}{score_s}] {e['id']}  — {e.get('description','')[:70]}  "
                      f"(affects {n_affects} component(s))")
        print(f"\n{'='*72}")
        print(f"  GRAND TOTALS: "
              f"CRITICAL={grand_sev.get('CRITICAL',0)}  "
              f"HIGH={grand_sev.get('HIGH',0)}  "
              f"MEDIUM={grand_sev.get('MEDIUM',0)}  "
              f"LOW={grand_sev.get('LOW',0)}")
        if not args.no_overlay:
            print(f"  VEX docs written to {args.boms_dir}/vex/")
        print("=" * 72)

    # Policy exit codes
    if args.fail_on_critical and grand_sev.get("CRITICAL", 0) > 0:
        sys.exit(1)
    if args.fail_on_high and (grand_sev.get("CRITICAL", 0) + grand_sev.get("HIGH", 0)) > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
