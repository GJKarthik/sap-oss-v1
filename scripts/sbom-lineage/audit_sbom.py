#!/usr/bin/env python3
"""
SBOM Audit — CycloneDX 1.5 + NTIA Minimum Elements + Professional Policy Gates.

Evaluates every *.cyclonedx.json in the boms/ directory against:
  - CycloneDX 1.5 schema structure
  - NTIA Minimum Elements for Software Bill of Materials (July 2021)
  - SPDX 3.24 license identifier validity
  - Supply-chain best practices (hashes, supplier)
  - Copyleft propagation risk analysis
  - ECCN / EAR export-control classification
  - Policy-as-code gates (--policy policy.yaml)
  - Vulnerability severity gates (--vuln-fail-on CRITICAL/HIGH)
  - Executive risk scoring (composite risk tier per BOM)

Exit codes:
  0 — no FAIL findings
  1 — at least one FAIL finding (or policy violation)
  2 — no BOM files found

Usage:
  python3 scripts/sbom-lineage/audit_sbom.py [--boms-dir DIR] [--json]
          [--fail-on-warn] [--policy policy.yaml] [--vuln-fail-on CRITICAL]
          [--risk-report]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml as _yaml  # type: ignore
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

BOMS_DIR_DEFAULT  = Path(__file__).parent / "boms"
MANIFEST_DEFAULT  = Path(__file__).parents[2] / "docs" / "sbom" / "sbom-lineage-manifest.yaml"

# ── SPDX 3.24 identifiers (common subset; extend as needed) ──────────────────
KNOWN_SPDX = {
    "NOASSERTION", "NONE",   # SPDX special values — licence deliberately not stated
    "MIT", "MIT-0", "MIT-Modern-Variant",
    "Apache-2.0", "Apache-1.1",
    "BSD-2-Clause", "BSD-3-Clause", "BSD-4-Clause",
    "ISC", "0BSD", "Unlicense",
    "MPL-2.0", "EPL-1.0", "EPL-2.0", "EUPL-1.2",
    "GPL-2.0-only", "GPL-2.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later",
    "LGPL-2.0-only", "LGPL-2.0-or-later", "LGPL-2.1-only", "LGPL-2.1-or-later",
    "LGPL-3.0-only", "LGPL-3.0-or-later",
    "AGPL-3.0-only", "AGPL-3.0-or-later",
    "CC0-1.0", "CC-BY-3.0", "CC-BY-4.0", "CC-BY-SA-4.0",
    "CDDL-1.0", "CDDL-1.1", "CPL-1.0",
    "Artistic-2.0", "Python-2.0", "PSF-2.0",
    "BlueOak-1.0.0", "WTFPL", "Zlib", "Libpng",
    "NOASSERTION",  # valid CycloneDX marker for unknown license
}

PURL_RE = re.compile(
    r'^pkg:(npm|pypi|golang|maven|cargo|nuget|gem|composer|hex|swift|pub'
    r'|conda|cran|deb|rpm|docker|oci|github|gitlab|bitbucket|generic|nix'
    r'|conan|hackage|luarocks|opam|cocoapods|apk|alpm|mlflow|qpkg|swid)'
    r'/[^@\s]+@[^\s]+$',
    re.IGNORECASE,
)
VERSION_RANGE_RE = re.compile(r'[\^~><!=*]')

def _load_stub_boms(manifest_path: Path = MANIFEST_DEFAULT) -> set[str]:
    """
    Read the set of service path-slugs that are declared as stubs in the
    sbom-lineage-manifest.yaml (stub: true).  Falls back to a hardcoded
    default set if the manifest is absent or unparseable.
    """
    _fallback = {"ai-core-pal", "ai-core-streaming", "elasticsearch-main"}
    if not _YAML_AVAILABLE or not manifest_path.exists():
        return _fallback
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            data = _yaml.safe_load(fh) or {}
        return {
            svc["path"]
            for svc in data.get("services", [])
            if svc.get("stub") is True
        } or _fallback
    except Exception:
        return _fallback


# BOMs with legitimately empty components — driven from docs/sbom/sbom-lineage-manifest.yaml.
# Each entry must have `stub: true` in the manifest.  Do not add paths here directly.
STUB_BOMS: set[str] = _load_stub_boms()

# ── Copyleft license families (strong → weak → network) ──────────────────────
_STRONG_COPYLEFT = {
    "GPL-2.0-only", "GPL-2.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later",
    "AGPL-3.0-only", "AGPL-3.0-or-later",
    "OSL-3.0", "EUPL-1.2",
}
_WEAK_COPYLEFT = {
    "LGPL-2.0-only", "LGPL-2.0-or-later", "LGPL-2.1-only", "LGPL-2.1-or-later",
    "LGPL-3.0-only", "LGPL-3.0-or-later",
    "MPL-2.0", "EPL-1.0", "EPL-2.0", "CDDL-1.0", "CDDL-1.1", "CPL-1.0",
}
_NETWORK_COPYLEFT = {"AGPL-3.0-only", "AGPL-3.0-or-later", "EUPL-1.2"}

# ── ECCN 5D002 / EAR export-control: packages with cryptographic functionality ─
_ECCN_CRYPTO_PACKAGES = {
    # Python
    "cryptography", "pyca/cryptography", "pycryptodome", "pycrypto", "pyotp",
    "pyOpenSSL", "paramiko", "bcrypt", "passlib", "nacl", "pygnupg",
    # Node
    "node-forge", "crypto-js", "bcrypt", "bcryptjs", "sjcl", "openpgp",
    # Go
    "golang.org/x/crypto", "github.com/ProtonMail/gopenpgp",
    # Java / Maven
    "org.bouncycastle:bcprov-jdk15on", "com.nimbusds:nimbus-jose-jwt",
    # System / generic
    "openssl", "libssl", "libcrypto", "mbedtls", "wolfssl",
}

# ── Default policy (overridable by --policy yaml) ─────────────────────────────
_DEFAULT_POLICY: dict[str, Any] = {
    "licenses": {
        "blocklist":        [],         # FAIL if any component uses these
        "require_approval": [],         # WARN if any component uses these
    },
    "copyleft": {
        "strong_copyleft_action": "WARN",   # FAIL | WARN | INFO | IGNORE
        "network_copyleft_action": "WARN",
    },
    "export_control": {
        "eccn_action": "INFO",          # FAIL | WARN | INFO | IGNORE
    },
    "vulnerabilities": {
        "fail_on_severity": [],         # e.g. ["CRITICAL", "HIGH"]
        "warn_on_severity": ["CRITICAL", "HIGH", "MEDIUM"],
    },
}


def _load_policy(policy_path: Path | None) -> dict[str, Any]:
    if policy_path is None:
        return _DEFAULT_POLICY
    if not _YAML_AVAILABLE:
        raise RuntimeError("PyYAML required for --policy: pip install pyyaml")
    with open(policy_path, encoding="utf-8") as fh:
        raw = _yaml.safe_load(fh) or {}
    # Deep-merge with defaults so unspecified keys fall back to defaults
    merged: dict[str, Any] = {}
    for section, defaults in _DEFAULT_POLICY.items():
        merged[section] = {**defaults, **raw.get(section, {})}
    return merged


def _extract_license_ids(comp: dict) -> list[str]:
    """Return all SPDX IDs and expression strings from a component's licenses array."""
    ids: list[str] = []
    for le in comp.get("licenses", []):
        if le.get("expression"):
            ids.append(le["expression"])
        lid = le.get("license", {}).get("id", "")
        if lid:
            ids.append(lid)
    return ids


def _component_has_copyleft(comp: dict, copyleft_set: set) -> bool:
    for lid in _extract_license_ids(comp):
        for cid in copyleft_set:
            if cid.lower() in lid.lower():
                return True
    return False


def _component_matches_eccn(comp: dict) -> bool:
    name = (comp.get("name") or "").lower()
    group = (comp.get("group") or "").lower()
    purl = (comp.get("purl") or "").lower()
    for pkg in _ECCN_CRYPTO_PACKAGES:
        p = pkg.lower()
        if p == name or p in purl or (group and p == group):
            return True
    return False


def _compute_risk_score(findings: list[tuple[str, str, str]], vuln_summary: dict) -> dict:
    """
    Compute a composite risk score (0–100) and tier (LOW/MEDIUM/HIGH/CRITICAL).
    Higher score = worse.
    """
    score = 0
    for sev, cat, _ in findings:
        if sev == "FAIL":
            score += 20
        elif sev == "WARN":
            if cat in ("LICENSE", "ECCN"):
                score += 10
            else:
                score += 5
    # Vulnerability contribution
    score += vuln_summary.get("CRITICAL", 0) * 25
    score += vuln_summary.get("HIGH", 0)     * 10
    score += vuln_summary.get("MEDIUM", 0)   * 3
    score += vuln_summary.get("LOW", 0)      * 1
    score = min(score, 100)
    if score >= 60:    tier = "CRITICAL"
    elif score >= 35:  tier = "HIGH"
    elif score >= 15:  tier = "MEDIUM"
    else:              tier = "LOW"
    return {"score": score, "tier": tier}


def audit_bom(name: str, bom: dict, policy: dict | None = None) -> list[tuple[str, str, str]]:
    """Return list of (severity, category, message) findings for one BOM."""
    findings: list[tuple[str, str, str]] = []

    def record(sev: str, cat: str, msg: str) -> None:
        findings.append((sev, cat, msg))

    meta = bom.get("metadata", {})
    comps = bom.get("components", [])
    deps = bom.get("dependencies", [])

    # ── Top-level required fields ─────────────────────────────────────────────
    for req in ("bomFormat", "specVersion", "serialNumber", "version", "metadata", "components"):
        if req not in bom:
            record("FAIL", "SCHEMA", f"Missing required field: '{req}'")

    sn = bom.get("serialNumber", "")
    if not re.match(r"^urn:uuid:[0-9a-f-]{36}$", sn, re.IGNORECASE):
        record("FAIL", "SCHEMA", f"serialNumber not valid urn:uuid: '{sn}'")

    sv = str(bom.get("specVersion", ""))
    if sv != "1.5":
        record("WARN", "SCHEMA", f"specVersion='{sv}' (expected 1.5)")

    # ── metadata ─────────────────────────────────────────────────────────────
    if not meta.get("timestamp"):
        record("FAIL", "NTIA", "metadata.timestamp missing (NTIA §3.7)")
    else:
        ts = meta["timestamp"]
        if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", ts):
            record("FAIL", "SCHEMA", f"metadata.timestamp not ISO-8601: '{ts}'")

    tools = meta.get("tools")
    if not tools:
        record("FAIL", "NTIA", "metadata.tools missing (NTIA §3.6)")
    elif isinstance(tools, list):
        record("WARN", "SCHEMA",
               "metadata.tools uses deprecated array format — use {components:[...]} (CycloneDX 1.5)")

    if not meta.get("authors"):
        record("WARN", "NTIA", "metadata.authors missing (NTIA §3.6 SBOM author)")

    if not meta.get("lifecycles"):
        record("INFO", "SCHEMA", "metadata.lifecycles missing (recommended: [{phase:'build'}])")

    root = meta.get("component", {})
    is_stub = any(
        p.get("name") == "sap-oss:sbom-note"
        for p in meta.get("properties", [])
    )
    if not root:
        record("FAIL", "NTIA", "metadata.component (root) missing")
    else:
        if not root.get("purl"):
            record("WARN", "NTIA", "metadata.component.purl missing (NTIA §3.4 unique identifier)")
        rv = str(root.get("version", ""))
        if rv in ("0.0.0", "", "0"):
            sev_ver = "INFO" if is_stub else "WARN"
            record(sev_ver, "NTIA",
                   f"metadata.component.version='{rv}' — set to real release version")

    # ── Root duplicated in components[] ──────────────────────────────────────
    root_ref = root.get("bom-ref", "")
    if root_ref and any(c.get("bom-ref") == root_ref for c in comps):
        record("WARN", "SCHEMA",
               "Root component duplicated in components[] — belongs only in metadata.component")

    # ── components ────────────────────────────────────────────────────────────
    non_root = [c for c in comps if c.get("bom-ref") != root_ref]
    nt = len(non_root)

    if nt == 0 and name not in STUB_BOMS:
        record("FAIL", "NTIA", "components[] empty — no dependency information")

    no_purl = no_ver = no_lic = no_sup = no_hash = null_desc = range_ver = 0
    bad_purls: list[str] = []
    non_spdx: set[str] = set()

    for c in non_root:
        purl = c.get("purl", "")
        if not purl:
            no_purl += 1
        elif not PURL_RE.match(purl):
            bad_purls.append(purl[:80])

        ver = str(c.get("version", ""))
        if not ver:
            no_ver += 1
        elif VERSION_RANGE_RE.search(ver):
            range_ver += 1

        if not c.get("licenses"):
            no_lic += 1
        else:
            for le in c["licenses"]:
                # Accept SPDX expression entries (compound AND/OR expressions)
                if le.get("expression"):
                    continue
                lid = le.get("license", {}).get("id", "")
                # LicenseRef-* is valid CycloneDX extension for non-SPDX licences
                if lid and lid not in KNOWN_SPDX and not lid.startswith("LicenseRef-"):
                    non_spdx.add(lid)

        # GitHub Actions (pkg:github/...) have no conventional supplier in registry
        is_gh_action = str(c.get("purl", "")).startswith("pkg:github/")
        if not is_gh_action and not any(
            c.get(k) for k in ("supplier", "author", "publisher", "manufacturer")
        ):
            no_sup += 1

        if not c.get("hashes"):
            no_hash += 1

        if c.get("description") is None and "description" in c:
            null_desc += 1

    if no_purl:
        record("FAIL", "NTIA", f"{no_purl}/{nt} components missing purl (NTIA §3.4)")
    if bad_purls:
        record("FAIL", "SCHEMA", f"Malformed purls: {bad_purls[:3]}")
    if range_ver:
        record("FAIL", "NTIA",
               f"{range_ver}/{nt} components have version ranges, not exact versions (NTIA §3.3)")
    if no_ver:
        record("FAIL", "NTIA", f"{no_ver}/{nt} components missing version (NTIA §3.3)")
    if nt > 0:
        if no_lic:
            record("WARN", "LICENSE",
                   f"{no_lic}/{nt} ({round(100*no_lic/nt)}%) components missing license")
        if non_spdx:
            record("WARN", "LICENSE",
                   f"Unrecognised SPDX IDs (add to KNOWN_SPDX if valid): {sorted(non_spdx)[:6]}")
        if no_sup:
            record("WARN", "NTIA",
                   f"{no_sup}/{nt} ({round(100*no_sup/nt)}%) components missing supplier (NTIA §3.1)")
        if no_hash:
            record("INFO", "SUPPLY-CHAIN",
                   f"{no_hash}/{nt} ({round(100*no_hash/nt)}%) components missing cryptographic hash")
        if null_desc:
            record("INFO", "SCHEMA",
                   f"{null_desc} components have explicit description:null — omit field instead")

    # ── dependencies ─────────────────────────────────────────────────────────
    if not deps:
        record("FAIL", "NTIA", "dependencies[] empty — NTIA §3.5 requires dependency relationships")
    else:
        comp_refs = {c.get("bom-ref") for c in comps if c.get("bom-ref")}
        dep_refs_set = {d.get("ref") for d in deps}
        orphaned = comp_refs - dep_refs_set - {root_ref}
        if orphaned:
            record("WARN", "NTIA",
                   f"{len(orphaned)} component bom-refs unreferenced in dependencies[] "
                   f"(e.g. {list(orphaned)[:2]})")

    pol = policy or _DEFAULT_POLICY

    # ── Copyleft propagation analysis ────────────────────────────────────────
    strong_action  = pol["copyleft"].get("strong_copyleft_action", "WARN").upper()
    network_action = pol["copyleft"].get("network_copyleft_action", "WARN").upper()
    if strong_action != "IGNORE":
        sc_comps = [c for c in non_root if _component_has_copyleft(c, _STRONG_COPYLEFT)]
        if sc_comps:
            names = [c.get("name", "?") for c in sc_comps[:4]]
            sev = strong_action if strong_action in ("FAIL", "WARN", "INFO") else "WARN"
            record(sev, "COPYLEFT",
                   f"{len(sc_comps)} component(s) under strong copyleft "
                   f"(GPL/AGPL/OSL) — verify licensing compatibility: {names}")
    if network_action != "IGNORE":
        nc_comps = [c for c in non_root if _component_has_copyleft(c, _NETWORK_COPYLEFT)]
        if nc_comps:
            names = [c.get("name", "?") for c in nc_comps[:4]]
            sev = network_action if network_action in ("FAIL", "WARN", "INFO") else "WARN"
            record(sev, "COPYLEFT",
                   f"{len(nc_comps)} component(s) under network-copyleft "
                   f"(AGPL/EUPL) — affects SaaS deployments: {names}")

    # ── ECCN / EAR export-control classification ──────────────────────────────
    eccn_action = pol["export_control"].get("eccn_action", "INFO").upper()
    if eccn_action != "IGNORE":
        eccn_comps = [c for c in non_root if _component_matches_eccn(c)]
        if eccn_comps:
            names = [c.get("name", "?") for c in eccn_comps[:6]]
            sev = eccn_action if eccn_action in ("FAIL", "WARN", "INFO") else "INFO"
            record(sev, "ECCN",
                   f"{len(eccn_comps)} component(s) may require ECCN 5D002 review "
                   f"(EAR cryptographic item): {names}")

    # ── Policy: license blocklist ─────────────────────────────────────────────
    blocklist: list[str] = pol["licenses"].get("blocklist", [])
    req_approval: list[str] = pol["licenses"].get("require_approval", [])
    if blocklist:
        blocked = [c for c in non_root
                   if any(b in _extract_license_ids(c) for b in blocklist)]
        if blocked:
            names = [c.get("name", "?") for c in blocked[:4]]
            record("FAIL", "POLICY",
                   f"{len(blocked)} component(s) use blocklisted license(s) "
                   f"{blocklist}: {names}")
    if req_approval:
        approval_needed = [c for c in non_root
                           if any(a in _extract_license_ids(c) for a in req_approval)]
        if approval_needed:
            names = [c.get("name", "?") for c in approval_needed[:4]]
            record("WARN", "POLICY",
                   f"{len(approval_needed)} component(s) require licence approval "
                   f"{req_approval}: {names}")

    # ── Policy: vulnerability severity gates ─────────────────────────────────
    vuln_pol = pol.get("vulnerabilities", {})
    fail_on_sev: list[str] = [s.upper() for s in vuln_pol.get("fail_on_severity", [])]
    warn_on_sev: list[str] = [s.upper() for s in vuln_pol.get("warn_on_severity", [])]
    vuln_entries = bom.get("vulnerabilities", [])
    if vuln_entries:
        SORD = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}
        by_sev: dict[str, int] = {}
        for ve in vuln_entries:
            sev_tag = ((ve.get("ratings") or [{}])[0].get("severity") or "unknown").upper()
            by_sev[sev_tag] = by_sev.get(sev_tag, 0) + 1
        total_v = sum(by_sev.values())
        sev_str = "  ".join(f"{k}={v}" for k, v in sorted(by_sev.items(), key=lambda x: SORD.get(x[0],9)))
        record("INFO", "VULN", f"{total_v} known vulnerabilities overlaid: {sev_str}")
        for sev_level in fail_on_sev:
            if by_sev.get(sev_level, 0) > 0:
                record("FAIL", "VULN",
                       f"Policy violation: {by_sev[sev_level]} {sev_level} vulnerability(ies) found")
        for sev_level in warn_on_sev:
            if sev_level not in fail_on_sev and by_sev.get(sev_level, 0) > 0:
                record("WARN", "VULN",
                       f"{by_sev[sev_level]} {sev_level} vulnerability(ies) — review required")

    return findings


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Audit CycloneDX SBOMs: NTIA + CycloneDX 1.5 + Policy Gates + Risk Scoring"
    )
    parser.add_argument("--boms-dir",       type=Path, default=BOMS_DIR_DEFAULT,
                        help="Directory containing *.cyclonedx.json files")
    parser.add_argument("--json",           action="store_true", help="Output JSON instead of text")
    parser.add_argument("--fail-on-warn",   action="store_true",
                        help="Exit 1 if any WARN findings (not just FAIL)")
    parser.add_argument("--policy",         type=Path, default=None,
                        help="Path to policy.yaml (license blocklist, vuln severity gates, etc.)")
    parser.add_argument("--vuln-fail-on",   default=None,
                        choices=["CRITICAL", "HIGH", "MEDIUM"],
                        help="Override: fail if any vuln at this severity or above is found")
    parser.add_argument("--risk-report",    action="store_true",
                        help="Append executive risk scores to the output")
    args = parser.parse_args()

    policy = _load_policy(args.policy)

    # Override vuln severity via CLI flag
    if args.vuln_fail_on:
        sev_order = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
        idx = sev_order.index(args.vuln_fail_on)
        policy["vulnerabilities"]["fail_on_severity"] = sev_order[: idx + 1]

    bom_files = sorted(args.boms_dir.glob("*.cyclonedx.json"))
    if not bom_files:
        print(f"No BOMs found in {args.boms_dir}", file=sys.stderr)
        sys.exit(2)

    all_findings: dict[str, list[tuple[str, str, str]]] = {}
    all_boms: dict[str, dict] = {}
    for bom_path in bom_files:
        bom_name = bom_path.stem.replace(".cyclonedx", "")
        try:
            bom = json.loads(bom_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as e:
            all_findings[bom_name] = [("FAIL", "PARSE", str(e))]
            continue
        all_boms[bom_name] = bom
        all_findings[bom_name] = audit_bom(bom_name, bom, policy=policy)

    SEV = {"FAIL": 0, "WARN": 1, "INFO": 2}
    tot_fail = tot_warn = tot_info = 0

    # Build risk scores if requested
    risk_scores: dict[str, dict] = {}
    if args.risk_report or args.json:
        for bom_name, findings in all_findings.items():
            bom = all_boms.get(bom_name, {})
            vuln_sev: dict[str, int] = {}
            for ve in bom.get("vulnerabilities", []):
                sev_tag = ((ve.get("ratings") or [{}])[0].get("severity") or "unknown").upper()
                vuln_sev[sev_tag] = vuln_sev.get(sev_tag, 0) + 1
            risk_scores[bom_name] = _compute_risk_score(findings, vuln_sev)

    if args.json:
        out: dict = {}
        for name, findings in all_findings.items():
            out[name] = {
                "findings": [{"severity": s, "category": c, "message": m} for s, c, m in findings],
                "risk":     risk_scores.get(name, {}),
            }
        print(json.dumps(out, indent=2))
    else:
        print("=" * 72)
        print("  SBOM AUDIT — CycloneDX 1.5 + NTIA + Policy + Risk")
        print(f"  {len(bom_files)} BOMs in {args.boms_dir}")
        if args.policy:
            print(f"  Policy: {args.policy}")
        print("=" * 72)
        for name, findings in sorted(all_findings.items()):
            findings_sorted = sorted(findings, key=lambda x: SEV.get(x[0], 9))
            fails = [f for f in findings_sorted if f[0] == "FAIL"]
            warns = [f for f in findings_sorted if f[0] == "WARN"]
            infos = [f for f in findings_sorted if f[0] == "INFO"]
            tot_fail += len(fails); tot_warn += len(warns); tot_info += len(infos)
            status = "FAIL" if fails else ("WARN" if warns else "PASS")
            label = {"FAIL": "✗ FAIL", "WARN": "~ WARN", "PASS": "✓ PASS"}[status]
            risk  = risk_scores.get(name)
            risk_tag = f"  [RISK: {risk['tier']} {risk['score']}/100]" if risk else ""
            print(f"\n{'─'*72}")
            print(f"  {label}  {name}{risk_tag}")
            print(f"{'─'*72}")
            for sev, cat, msg in findings_sorted:
                icon = {"FAIL": "[FAIL]", "WARN": "[WARN]", "INFO": "[INFO]"}.get(sev, "[?]")
                print(f"  {icon} [{cat}] {msg}")
        print(f"\n{'='*72}")
        print(f"  TOTALS: {tot_fail} FAIL  |  {tot_warn} WARN  |  {tot_info} INFO")
        boms_fail = sum(1 for f in all_findings.values() if any(i[0] == "FAIL" for i in f))
        boms_warn = sum(1 for f in all_findings.values()
                        if not any(i[0] == "FAIL" for i in f) and any(i[0] == "WARN" for i in f))
        boms_pass = len(bom_files) - boms_fail - boms_warn
        print(f"  BOMs:   {boms_fail} FAIL  |  {boms_warn} WARN-only  |  {boms_pass} PASS")
        if args.risk_report and risk_scores:
            print(f"\n  EXECUTIVE RISK SUMMARY")
            print(f"  {'BOM':<55} {'TIER':<10} {'SCORE':>5}")
            print(f"  {'─'*55} {'─'*10} {'─'*5}")
            for bom_name in sorted(risk_scores):
                r = risk_scores[bom_name]
                tier_icon = {"CRITICAL": "🔴", "HIGH": "🟠", "MEDIUM": "🟡", "LOW": "🟢"}.get(r["tier"], " ")
                print(f"  {bom_name:<55} {tier_icon} {r['tier']:<8} {r['score']:>5}/100")
            avg = sum(r["score"] for r in risk_scores.values()) // len(risk_scores)
            print(f"\n  Portfolio avg risk score: {avg}/100")
        print("=" * 72)

    any_fail = any(i[0] == "FAIL" for f in all_findings.values() for i in f)
    any_warn = any(i[0] == "WARN" for f in all_findings.values() for i in f)
    if any_fail or (args.fail_on_warn and any_warn):
        sys.exit(1)


if __name__ == "__main__":
    main()
