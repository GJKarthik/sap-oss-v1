#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
sbom_to_sarif.py — Convert all SBOM audit findings to SARIF 2.1.0.

SARIF (Static Analysis Results Interchange Format) is the OASIS standard
consumed by GitHub Advanced Security, VS Code, GitLab SAST, SonarQube,
Grype, Trivy, pip-audit, OWASP dependency-check, and every enterprise
supply-chain tool.  Uploading SARIF to GitHub surfaces findings directly
in the repository Security tab and in PR review annotations.

Rule taxonomy
━━━━━━━━━━━━━
  SBOM001  BlockedLicense           — component uses AGPL/GPL/SSPL/BUSL
  SBOM002  RequiresApproval         — LGPL / MPL / copyleft requiring OSS review
  SBOM003  TransitiveStrongCopyleft — transitive GPL/AGPL exposure
  SBOM004  TransitiveWeakCopyleft   — transitive LGPL/MPL exposure
  SBOM005  Eccn5D002Review          — cryptographic library: EAR review needed
  SBOM006  MissingLicense           — NOASSERTION licence identifier
  SBOM007  MissingSupplier          — no supplier/author field in BOM
  SBOM008  MissingHash              — no cryptographic hash in BOM
  SBOM009  NtiaIncomplete           — NTIA minimum element missing
  SBOM010  CycloneDxSchemaViolation — component fails CycloneDX 1.5 schema
  SBOM011  VulnCritical             — OSV CRITICAL vulnerability
  SBOM012  VulnHigh                 — OSV HIGH vulnerability
  SBOM013  VulnMedium               — OSV MEDIUM vulnerability
  SBOM014  SpdxCoverageMissing      — source file has no SPDX-License-Identifier
  SBOM015  SpdxLicenseMismatch      — declared vs. discovered licence differs

Inputs (all optional — tool gracefully skips missing files):
  --mangle-json    output of: mangle_audit.py --json
  --audit-json     output of: audit_sbom.py --json
  --scan-json      output of: scan_licenses.py --json
  --vuln-json      output of: vuln_overlay.py --json

Output:
  boms/sarif/sbom-findings.sarif.json   (SARIF 2.1.0 document)

Usage:
  # Generate all inputs then convert:
  python3 scripts/sbom-lineage/mangle_audit.py --json > /tmp/mangle.json
  python3 scripts/sbom-lineage/audit_sbom.py   --json > /tmp/audit.json
  python3 scripts/sbom-lineage/scan_licenses.py --json > /tmp/scan.json
  python3 scripts/sbom-lineage/sbom_to_sarif.py \\
      --mangle-json /tmp/mangle.json \\
      --audit-json  /tmp/audit.json  \\
      --scan-json   /tmp/scan.json

  # Or one-liner via make:
  make sbom-sarif
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml as _yaml
    _YAML_OK = True
except ImportError:
    _YAML_OK = False

BOMS_DIR_DEFAULT      = Path(__file__).parent / "boms"
SUPPRESSIONS_DEFAULT  = Path(__file__).parent / "sbom-suppressions.yaml"
REPO_ROOT             = Path(__file__).resolve().parents[2]
SARIF_SCHEMA     = "https://json.schemastore.org/sarif-2.1.0.json"
TOOL_NAME        = "SAP OSS SBOM Pipeline"
TOOL_VERSION     = "1.0.0"
TOOL_URI         = "https://github.com/sap-oss/sbom-pipeline"

# ── Rule registry ─────────────────────────────────────────────────────────────
# Each entry: ruleId → (name, shortDescription, level, security_severity, tags, helpUri)
# level:            "error" | "warning" | "note"
# security_severity: CVSS-like float 0.1–10.0 (GitHub uses this for severity badge)

_RULES: dict[str, dict] = {
    "SBOM001": {
        "name":         "BlockedLicense",
        "short":        "Component uses a licence that is blocked by policy.",
        "full":         "The component's declared SPDX licence identifier is on the "
                        "organisation's blocklist (AGPL-3.0, GPL-3.0, SSPL-1.0, BUSL-1.1). "
                        "Remove or replace the component before shipping.",
        "level":        "error",
        "security":     9.0,
        "tags":         ["license", "supply-chain", "policy"],
        "help":         f"{TOOL_URI}/blob/main/scripts/sbom-lineage/policy.yaml",
    },
    "SBOM002": {
        "name":         "RequiresApproval",
        "short":        "Component licence requires legal/OSS review before use.",
        "full":         "The component uses a weak-copyleft licence (LGPL, MPL, EUPL). "
                        "Obtain written approval from the OSS Legal team before shipping.",
        "level":        "warning",
        "security":     5.0,
        "tags":         ["license", "supply-chain"],
        "help":         f"{TOOL_URI}/blob/main/scripts/sbom-lineage/policy.yaml",
    },
    "SBOM003": {
        "name":         "TransitiveStrongCopyleft",
        "short":        "Transitive dependency carries a strong copyleft licence.",
        "full":         "A transitive dependency in the component's graph has a GPL/AGPL "
                        "licence that propagates to the entire program. Audit the full "
                        "dependency chain and replace or isolate the copyleft component.",
        "level":        "error",
        "security":     8.0,
        "tags":         ["license", "supply-chain", "transitive"],
        "help":         f"{TOOL_URI}/blob/main/scripts/sbom-lineage/rules/sbom_policy.mg",
    },
    "SBOM004": {
        "name":         "TransitiveWeakCopyleft",
        "short":        "Transitive dependency carries a weak copyleft licence.",
        "full":         "A transitive dependency uses LGPL/MPL which may affect "
                        "modifications to that library. Review the use case.",
        "level":        "warning",
        "security":     4.0,
        "tags":         ["license", "supply-chain", "transitive"],
        "help":         f"{TOOL_URI}/blob/main/scripts/sbom-lineage/rules/sbom_policy.mg",
    },
    "SBOM005": {
        "name":         "Eccn5D002Review",
        "short":        "Cryptographic component may require EAR/ECCN 5D002 classification.",
        "full":         "This component implements cryptographic functions. US Export "
                        "Administration Regulations (EAR) may require classification as "
                        "ECCN 5D002 and filing of an encryption registration (ERN).",
        "level":        "note",
        "security":     3.0,
        "tags":         ["export-control", "eccn", "crypto"],
        "help":         "https://www.bis.doc.gov/index.php/policy-guidance/encryption",
    },
    "SBOM006": {
        "name":         "MissingLicense",
        "short":        "Component has no licence identifier (NOASSERTION).",
        "full":         "The component's BOM entry declares 'NOASSERTION' as its licence. "
                        "Legal review is required before including this component in a "
                        "shipped product.",
        "level":        "warning",
        "security":     6.0,
        "tags":         ["license", "ntia", "supply-chain"],
        "help":         "https://www.ntia.doc.gov/report/2021/minimum-elements-software-bill-materials-sbom",
    },
    "SBOM007": {
        "name":         "MissingSupplier",
        "short":        "Component has no supplier/author declared in the BOM.",
        "full":         "NTIA minimum elements require each BOM component to identify its "
                        "supplier. Add a 'supplier' or 'author' field in the CycloneDX BOM.",
        "level":        "warning",
        "security":     4.0,
        "tags":         ["ntia", "supply-chain"],
        "help":         "https://www.ntia.doc.gov/report/2021/minimum-elements-software-bill-materials-sbom",
    },
    "SBOM008": {
        "name":         "MissingHash",
        "short":        "Component has no cryptographic hash in the BOM.",
        "full":         "CISA and NTIA guidance requires cryptographic hashes (SHA-256 minimum) "
                        "for each BOM component to enable integrity verification.",
        "level":        "note",
        "security":     3.0,
        "tags":         ["ntia", "integrity"],
        "help":         "https://www.cisa.gov/sbom",
    },
    "SBOM009": {
        "name":         "NtiaIncomplete",
        "short":        "BOM is missing an NTIA minimum element.",
        "full":         "The BOM does not satisfy all seven NTIA minimum elements: "
                        "supplier, name, version, other unique identifiers, dependency "
                        "relationships, author, and timestamp.",
        "level":        "warning",
        "security":     5.0,
        "tags":         ["ntia"],
        "help":         "https://www.ntia.doc.gov/report/2021/minimum-elements-software-bill-materials-sbom",
    },
    "SBOM010": {
        "name":         "CycloneDxSchemaViolation",
        "short":        "BOM component does not conform to CycloneDX 1.5 schema.",
        "full":         "The BOM entry fails CycloneDX 1.5 schema validation. Correct the "
                        "BOM generator configuration to produce spec-compliant output.",
        "level":        "warning",
        "security":     4.0,
        "tags":         ["schema", "cyclonedx"],
        "help":         "https://cyclonedx.org/specification/overview/",
    },
    "SBOM011": {
        "name":         "VulnCritical",
        "short":        "Component has a CRITICAL severity vulnerability.",
        "full":         "An OSV advisory rated CRITICAL has been found for this component. "
                        "Update or replace the component immediately.",
        "level":        "error",
        "security":     9.8,
        "tags":         ["vulnerability", "osv"],
        "help":         "https://osv.dev",
    },
    "SBOM012": {
        "name":         "VulnHigh",
        "short":        "Component has a HIGH severity vulnerability.",
        "full":         "An OSV advisory rated HIGH has been found. Update the component "
                        "as part of the next scheduled release.",
        "level":        "error",
        "security":     7.5,
        "tags":         ["vulnerability", "osv"],
        "help":         "https://osv.dev",
    },
    "SBOM013": {
        "name":         "VulnMedium",
        "short":        "Component has a MEDIUM severity vulnerability.",
        "full":         "An OSV advisory rated MEDIUM has been found. Schedule a fix "
                        "within 90 days per SLA.",
        "level":        "warning",
        "security":     5.0,
        "tags":         ["vulnerability", "osv"],
        "help":         "https://osv.dev",
    },
    "SBOM014": {
        "name":         "SpdxCoverageMissing",
        "short":        "Source file is missing an SPDX-License-Identifier header.",
        "full":         "The file does not carry a compact SPDX-License-Identifier comment. "
                        "Run 'make sbom-add-spdx-headers' to add headers automatically.",
        "level":        "note",
        "security":     2.0,
        "tags":         ["reuse", "spdx", "license"],
        "help":         "https://reuse.software/spec/",
    },
    "SBOM015": {
        "name":         "SpdxLicenseMismatch",
        "short":        "Discovered source licence differs from declared BOM licence.",
        "full":         "The SPDX identifiers found in source files do not match the "
                        "licence declared in the CycloneDX BOM. Update one or both to "
                        "ensure consistency.",
        "level":        "warning",
        "security":     5.0,
        "tags":         ["reuse", "spdx", "license"],
        "help":         "https://reuse.software/spec/",
    },
}

# Map from mangle predicate reason / audit_sbom category → rule ID
_MANGLE_REASON_MAP: dict[str, str] = {
    "BLOCKED_LICENSE":             "SBOM001",
    "REQUIRES_APPROVAL":           "SBOM002",
    "TRANSITIVE_STRONG_COPYLEFT":  "SBOM003",
    "TRANSITIVE_WEAK_COPYLEFT":    "SBOM004",
    "ECCN_5D002_REVIEW":           "SBOM005",
    "LICENSE_NOASSERTION":         "SBOM006",
    "NO_SUPPLIER":                 "SBOM007",
    "NO_HASH":                     "SBOM008",
}
_AUDIT_CATEGORY_MAP: dict[str, str] = {
    "NTIA":                        "SBOM009",
    "SCHEMA":                      "SBOM010",
    "VULN":                        "SBOM011",   # refined by severity below
    "LICENSE":                     "SBOM001",
}
_VULN_SEVERITY_MAP: dict[str, str] = {
    "CRITICAL": "SBOM011",
    "HIGH":     "SBOM012",
    "MEDIUM":   "SBOM013",
}


# ── SARIF helpers ─────────────────────────────────────────────────────────────

def _fingerprint(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:32]


def _rule_descriptor(rule_id: str) -> dict:
    r = _RULES[rule_id]
    return {
        "id":               rule_id,
        "name":             r["name"],
        "shortDescription": {"text": r["short"]},
        "fullDescription":  {"text": r["full"]},
        "defaultConfiguration": {
            "level": r["level"],
        },
        "helpUri":          r["help"],
        "help":             {
            "text":     r["short"],
            "markdown": f"**{r['name']}** — {r['full']}\n\nSee [{r['help']}]({r['help']})",
        },
        "properties": {
            "tags":              r["tags"],
            "security-severity": str(r["security"]),
            "precision":         "high",
            "problem.severity":  r["level"],
        },
    }


def _build_manifest_index(repo_root: Path) -> dict[tuple[str, str], tuple[str, int]]:
    """
    Build an index: {(service_slug, pkg_name_lower) -> (rel_file_path, line_no)}.

    Scans four manifest formats relative to repo_root:
      • npm  : <service>/package.json              (dependencies + devDependencies)
      • pypi : <service>/requirements*.txt
      • go   : <service>/go.mod
      • rust : <service>/Cargo.toml and <service>/**/Cargo.toml

    The returned paths are relative to repo_root so they can be used as SARIF
    physicalLocation URIs directly (uriBaseId = %SRCROOT%).
    """
    index: dict[tuple[str, str], tuple[str, int]] = {}

    def _add(svc: str, pkg: str, rel: str, line: int) -> None:
        index[(svc, pkg.lower())] = (rel, line)

    # ── npm: package.json ────────────────────────────────────────────────────
    for pkg_json in repo_root.glob("*/package.json"):
        svc = pkg_json.parent.name
        try:
            lines = pkg_json.read_text(encoding="utf-8", errors="replace").splitlines()
            for i, line in enumerate(lines, 1):
                m = re.match(r'\s*"(@?[^"]+)"\s*:', line)
                if m:
                    _add(svc, m.group(1), str(pkg_json.relative_to(repo_root)), i)
        except OSError:
            pass

    # ── Python: requirements*.txt ────────────────────────────────────────────
    for req_txt in repo_root.glob("*/requirements*.txt"):
        svc = req_txt.parent.name
        try:
            for i, line in enumerate(req_txt.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                m = re.match(r"^([A-Za-z0-9][A-Za-z0-9_\-\.]*)", line.strip())
                if m:
                    _add(svc, m.group(1), str(req_txt.relative_to(repo_root)), i)
        except OSError:
            pass

    # ── Python: pyproject.toml ───────────────────────────────────────────────
    for pyproj in repo_root.glob("*/pyproject.toml"):
        svc = pyproj.parent.name
        try:
            for i, line in enumerate(pyproj.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                # Match: "pkg>=1.0" or pkg = ">=1.0" in [dependencies] sections
                m = re.search(r'"([A-Za-z0-9][A-Za-z0-9_\-\.]+)', line)
                if m:
                    _add(svc, m.group(1), str(pyproj.relative_to(repo_root)), i)
        except OSError:
            pass

    # ── Go: go.mod ───────────────────────────────────────────────────────────
    for go_mod in repo_root.glob("*/go.mod"):
        svc = go_mod.parent.name
        try:
            for i, line in enumerate(go_mod.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                m = re.match(r"^\s+([^\s]+)\s+v", line)
                if m:
                    module = m.group(1)
                    name   = module.split("/")[-1]
                    _add(svc, module, str(go_mod.relative_to(repo_root)), i)
                    _add(svc, name,   str(go_mod.relative_to(repo_root)), i)
        except OSError:
            pass

    # ── Rust: Cargo.toml ─────────────────────────────────────────────────────
    for cargo_toml in repo_root.glob("*/Cargo.toml"):
        svc = cargo_toml.parts[-3] if len(cargo_toml.parts) >= 3 else cargo_toml.parent.name
        try:
            for i, line in enumerate(cargo_toml.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                m = re.match(r'^([a-zA-Z0-9_\-]+)\s*=', line)
                if m and not line.strip().startswith("#"):
                    _add(svc, m.group(1), str(cargo_toml.relative_to(repo_root)), i)
        except OSError:
            pass

    return index


# Module-level manifest index (built lazily on first call to _from_mangle)
_MANIFEST_INDEX: dict[tuple[str, str], tuple[str, int]] | None = None


def _get_manifest_index() -> dict[tuple[str, str], tuple[str, int]]:
    global _MANIFEST_INDEX
    if _MANIFEST_INDEX is None:
        _MANIFEST_INDEX = _build_manifest_index(REPO_ROOT)
    return _MANIFEST_INDEX


def _result(rule_id: str, message: str, uri: str | None = None, line: int | None = None) -> dict:
    level = _RULES[rule_id]["level"]
    fp    = _fingerprint(f"{rule_id}:{message}")
    res: dict = {
        "ruleId":              rule_id,
        "level":               level,
        "message":             {"text": message},
        "partialFingerprints": {"primaryLocationLineHash": fp},
        "properties": {
            "security-severity": str(_RULES[rule_id]["security"]),
        },
    }
    if uri:
        phys: dict = {"artifactLocation": {"uri": uri, "uriBaseId": "%SRCROOT%"}}
        if line:
            phys["region"] = {"startLine": line}
        res["locations"] = [{"physicalLocation": phys}]
    return res


# ── Per-source converters ─────────────────────────────────────────────────────

def _from_mangle(data: list[dict]) -> tuple[list[dict], set[str]]:
    results: list[dict] = []
    used_rules: set[str] = set()
    manifest_idx = _get_manifest_index()
    for svc_report in data:
        svc  = svc_report.get("service", "")
        bom_uri = f"scripts/sbom-lineage/boms/{svc}.cyclonedx.json"
        for finding in svc_report.get("findings", []):
            args   = finding.get("args", [])
            reason = args[-1] if args else ""
            name   = args[1] if len(args) > 1 else "unknown"
            lic    = args[2] if len(args) > 2 else ""
            rule_id = _MANGLE_REASON_MAP.get(reason)
            if not rule_id:
                continue
            msg = f"[{svc}] {reason}: component '{name}'"
            if lic and lic not in (name, reason):
                msg += f" (licence: {lic})"
            # Append fixedIn / advisoryUrl when the mangle_audit already enriched
            fixed_in = finding.get("fixedIn", "")
            advisory = finding.get("advisoryUrl", "")
            alt      = finding.get("alternative", "")
            if fixed_in:
                msg += f" | fixedIn: {fixed_in}"
            if alt:
                msg += f" | alternative: {alt}"

            # P2-A: resolve physicalLocation to the dependency manifest file:line.
            # Fall back to the BOM file if the package isn't found in any manifest.
            loc = manifest_idx.get((svc, name.lower())) or manifest_idx.get((svc, name))
            if loc:
                src_uri, src_line = loc
                sarif_result = _result(rule_id, msg, src_uri, src_line)
            else:
                sarif_result = _result(rule_id, msg, bom_uri)

            if advisory:
                sarif_result.setdefault("properties", {})["advisoryUrl"] = advisory
            results.append(sarif_result)
            used_rules.add(rule_id)
    return results, used_rules


def _from_audit(data: dict) -> tuple[list[dict], set[str]]:
    results: list[dict] = []
    used_rules: set[str] = set()
    for svc, report in data.items():
        uri = f"scripts/sbom-lineage/boms/{svc}.cyclonedx.json"
        for finding in report.get("findings", []):
            cat = finding.get("category", "")
            msg_text = finding.get("message", "")
            sev = finding.get("severity", "INFO")
            # Map category to rule
            if cat == "VULN":
                rule_id = _VULN_SEVERITY_MAP.get(sev, "SBOM013")
            else:
                rule_id = _AUDIT_CATEGORY_MAP.get(cat)
            if not rule_id:
                rule_id = "SBOM009"   # default: NTIA
            msg = f"[{svc}] {msg_text}"
            results.append(_result(rule_id, msg, uri))
            used_rules.add(rule_id)
    return results, used_rules


def _from_scan(data: dict) -> tuple[list[dict], set[str]]:
    results: list[dict] = []
    used_rules: set[str] = set()
    for svc_info in data.get("services", []):
        svc     = svc_info.get("service", "")
        verdict = svc_info.get("comparison", {}).get("verdict", "OK")
        cov     = svc_info.get("spdx_coverage_pct", 100)
        if verdict == "MISMATCH":
            msg = (f"[{svc}] SPDX licence mismatch: "
                   f"discovered differs from BOM-declared. Coverage: {cov}%")
            results.append(_result("SBOM015", msg,
                                   f"scripts/sbom-lineage/boms/scan/{svc}.scan.json"))
            used_rules.add("SBOM015")
        elif cov < 50 and svc_info.get("total_files", 0) > 5:
            msg = (f"[{svc}] Low SPDX header coverage: {cov}% of source files "
                   f"lack SPDX-License-Identifier. Run: make sbom-add-spdx-headers")
            results.append(_result("SBOM014", msg,
                                   f"scripts/sbom-lineage/boms/scan/{svc}.scan.json"))
            used_rules.add("SBOM014")
    return results, used_rules


def _from_vuln(data: dict) -> tuple[list[dict], set[str]]:
    results: list[dict] = []
    used_rules: set[str] = set()
    for summary in data.get("summaries", []):
        svc = summary.get("name", "")
        uri = f"scripts/sbom-lineage/boms/{svc}.cyclonedx.json"
        for vuln in summary.get("vulns", []):
            vid  = vuln.get("id", "")
            sev  = (vuln.get("severity", "") or "MEDIUM").upper()
            pkg  = vuln.get("package", "") or vuln.get("name", "")
            rule_id = _VULN_SEVERITY_MAP.get(sev, "SBOM013")
            msg = f"[{svc}] {sev} vulnerability {vid} in '{pkg}'"
            results.append(_result(rule_id, msg, uri))
            used_rules.add(rule_id)
    return results, used_rules


# ── Main ──────────────────────────────────────────────────────────────────────

def build_sarif(
    mangle_data:  list[dict] | None,
    audit_data:   dict | None,
    scan_data:    dict | None,
    vuln_data:    dict | None,
) -> dict:
    all_results: list[dict] = []
    all_rules:   set[str]   = set()

    for converter, data in [
        (_from_mangle, mangle_data or []),
        (_from_audit,  audit_data  or {}),
        (_from_scan,   scan_data   or {}),
        (_from_vuln,   vuln_data   or {}),
    ]:
        res, rules = converter(data)  # type: ignore[operator]
        all_results.extend(res)
        all_rules.update(rules)

    # Dedup by fingerprint
    seen: set[str] = set()
    deduped: list[dict] = []
    for r in all_results:
        fp = r.get("partialFingerprints", {}).get("primaryLocationLineHash", "")
        if fp not in seen:
            seen.add(fp)
            deduped.append(r)

    rule_descriptors = [_rule_descriptor(rid) for rid in sorted(all_rules)]

    return {
        "$schema": SARIF_SCHEMA,
        "version": "2.1.0",
        "runs": [
            {
                "tool": {
                    "driver": {
                        "name":            TOOL_NAME,
                        "version":         TOOL_VERSION,
                        "informationUri":  TOOL_URI,
                        "organization":    "SAP SE",
                        "rules":           rule_descriptors,
                        "properties": {
                            "generated":   datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                            "spec":        "SARIF 2.1.0",
                            "sbom-spec":   "CycloneDX 1.5",
                        },
                    }
                },
                "results":       deduped,
                "columnKind":    "utf16CodeUnits",
                "properties": {
                    "semmle.formatSpecifier": "2.1.0",
                },
            }
        ],
    }


def _load_json(path: Path | None) -> dict | list | None:
    if not path or not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        print(f"  [WARN] Could not load {path}: {exc}", file=sys.stderr)
        return None


# ── Suppression support ───────────────────────────────────────────────────────

def _load_suppressions(path: Path) -> list[dict]:
    if not _YAML_OK or not path.exists():
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            data = _yaml.safe_load(fh) or {}
        return data.get("suppressions", [])
    except Exception as exc:
        print(f"  [WARN] Could not load suppressions {path}: {exc}", file=sys.stderr)
        return []


def _check_suppression_expiry(suppressions: list[dict]) -> list[dict]:
    """Return list of suppression entries whose expires date is in the past."""
    from datetime import date
    today   = date.today()
    expired = []
    for sup in suppressions:
        raw = sup.get("expires", "")
        if not raw:
            continue
        try:
            if date.fromisoformat(str(raw)) < today:
                expired.append(sup)
        except ValueError:
            print(f"  [WARN] Suppression {sup.get('id','?')} has unparseable expires date: {raw!r}",
                  file=sys.stderr)
    return expired


def _apply_suppressions(results: list[dict], suppressions: list[dict]) -> tuple[list[dict], int]:
    """
    For each SARIF result that matches a suppression entry, add a SARIF
    suppressions[] block and move the result to the end of the list.
    Returns (annotated_results, suppressed_count).
    """
    suppressed = 0
    for result in results:
        rule_id = result.get("ruleId", "")
        msg     = result.get("message", {}).get("text", "")
        for sup in suppressions:
            if sup.get("rule", "") != rule_id:
                continue
            # Match by component name and service appearing in the message text
            comp    = sup.get("component", "")
            service = sup.get("service", "")
            if comp and comp not in msg:
                continue
            if service and service not in msg:
                continue
            # Annotate as suppressed (SARIF §3.27.8)
            result["suppressions"] = [{
                "kind":              "inSource",
                "justification":     sup.get("justification", "").strip(),
                "properties": {
                    "suppressionId":  sup.get("id", ""),
                    "resolution":     sup.get("resolution", ""),
                    "approvedBy":     sup.get("approved_by", ""),
                    "expires":        str(sup.get("expires", "")),
                    "remediation":    sup.get("remediation", ""),
                },
            }]
            result["properties"] = result.get("properties", {})
            result["properties"]["suppressed"] = True
            suppressed += 1
            break
    return results, suppressed


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert SBOM audit findings to SARIF 2.1.0"
    )
    parser.add_argument("--boms-dir",      type=Path, default=BOMS_DIR_DEFAULT)
    parser.add_argument("--mangle-json",   type=Path, default=None)
    parser.add_argument("--audit-json",    type=Path, default=None)
    parser.add_argument("--scan-json",     type=Path, default=None)
    parser.add_argument("--vuln-json",     type=Path, default=None)
    parser.add_argument("--suppressions",  type=Path, default=SUPPRESSIONS_DEFAULT)
    parser.add_argument("--out",           type=Path, default=None,
                        help="Output path (default: boms/sarif/sbom-findings.sarif.json)")
    parser.add_argument("--stdout",        action="store_true",
                        help="Also print SARIF to stdout")
    args = parser.parse_args()

    mangle = _load_json(args.mangle_json)
    audit  = _load_json(args.audit_json)
    scan   = _load_json(args.scan_json)
    vuln   = _load_json(args.vuln_json)

    sarif = build_sarif(mangle, audit, scan, vuln)

    # Apply suppressions — check expiry first
    suppressions = _load_suppressions(args.suppressions)
    expired = _check_suppression_expiry(suppressions)
    if expired:
        print("\n[EXPIRED_SUPPRESSION] The following suppressions are past their expiry date and must be reviewed:", file=sys.stderr)
        for s in expired:
            print(f"  {s.get('id','?'):8s}  {s.get('component','?'):20s}  in {s.get('service','?'):30s}  expired {s.get('expires','?')}", file=sys.stderr)
        print("  Update sbom-suppressions.yaml: re-approve and extend expires, or remove the suppression.", file=sys.stderr)
        sys.exit(3)  # 3 = EXPIRED_SUPPRESSION (distinct from 1=error, 2=no BOMs)

    sarif["runs"][0]["results"], n_suppressed = _apply_suppressions(
        sarif["runs"][0]["results"], suppressions
    )

    out_dir  = args.boms_dir / "sarif"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = args.out or (out_dir / "sbom-findings.sarif.json")
    out_path.write_text(json.dumps(sarif, indent=2, ensure_ascii=False), encoding="utf-8")

    all_results = sarif["runs"][0]["results"]
    total       = len(all_results)
    n_rules     = len(sarif["runs"][0]["tool"]["driver"]["rules"])
    errors      = sum(1 for r in all_results if r.get("level") == "error" and not r.get("properties", {}).get("suppressed"))
    warns       = sum(1 for r in all_results if r.get("level") == "warning" and not r.get("properties", {}).get("suppressed"))
    notes       = sum(1 for r in all_results if r.get("level") == "note" and not r.get("properties", {}).get("suppressed"))
    active      = errors + warns + notes

    print(f"\n{'='*72}")
    print(f"  SARIF 2.1.0 — SBOM FINDINGS")
    print("=" * 72)
    print(f"  Rules:      {n_rules}")
    print(f"  Active:     {active}  (error={errors}  warning={warns}  note={notes})")
    print(f"  Suppressed: {n_suppressed}  (documented exceptions — see sbom-suppressions.yaml)")
    print(f"  Total:      {total}")
    print(f"  Output:     {out_path}")
    print(f"  Schema:     {SARIF_SCHEMA}")
    if errors == 0:
        print("  ✓  No active errors — all ERRORs are either fixed or suppressed with justification")
    else:
        print(f"  ✗  {errors} active error(s) require remediation")
    print("=" * 72)
    import os, subprocess
    # Resolve the real repo slug from the environment (CI) or git remote (local).
    gh_repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not gh_repo:
        try:
            remote = subprocess.check_output(
                ["git", "remote", "get-url", "origin"], stderr=subprocess.DEVNULL, text=True
            ).strip()
            # Normalise git+ssh and https remote URLs to owner/repo
            import re as _re
            m = _re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", remote)
            if m:
                gh_repo = m.group(1)
        except Exception:
            pass
    gh_repo = gh_repo or "{owner}/{repo}"

    print("  Upload to GitHub Security tab:")
    print(f"    gh api repos/{gh_repo}/code-scanning/sarifs \\")
    print(f"         --field sarif=@{out_path} --field ref=$(git rev-parse HEAD)")
    print("  Or use: github/codeql-action/upload-sarif@v3 in CI")
    print("=" * 72)

    if args.stdout:
        print(json.dumps(sarif, indent=2))


if __name__ == "__main__":
    main()

