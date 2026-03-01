#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
mangle_audit.py — SBOM policy evaluation using the Google Mangle Datalog engine.

Architecture
============
  CycloneDX BOMs
       │
       ▼  (export_bom_facts)
  Mangle facts file (.mg)  ── sbom_policy.mg rules
       │
       ▼  (run_mg_query)
  mg -load facts.mg,rules.mg -exec "<query>"
       │
       ▼  (parse_mg_output)
  Structured findings  →  audit report + JSON

Why Mangle instead of Python?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Transitive copyleft propagation is a natural recursive Datalog rule;
  in Python it requires explicit BFS over the dependency graph.
• Policy rules are declarative, auditable and version-controlled independently
  of the evaluation engine.
• Mangle is already present in this repository (mangle-main/) and is used
  by mangle-query-service for production query routing — this reuses the
  same engine rather than adding a new dependency.

Mangle CLI:
  Built from mangle-main/interpreter/mg/mg.go
  Binary cached at: scripts/sbom-lineage/bin/mg

Fallback:
  If Go is not available and no pre-built binary exists, the tool falls back
  to a pure-Python policy evaluator that covers the non-recursive rules only
  (no transitive copyleft propagation).  A clear warning is emitted.

Usage
=====
  python3 scripts/sbom-lineage/mangle_audit.py [--boms-dir DIR] [--json]
          [--fail-on-blocked] [--fail-on-transitive-copyleft]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT        = Path(__file__).resolve().parents[2]
BOMS_DIR_DEFAULT = Path(__file__).parent / "boms"
RULES_FILE       = Path(__file__).parent / "rules" / "sbom_policy.mg"
BIN_DIR          = Path(__file__).parent / "bin"
MANGLE_DIR       = REPO_ROOT / "mangle-main"


# ── mg binary management ──────────────────────────────────────────────────────

def _find_prebuilt_mg() -> Path | None:
    """Return pre-built mg binary if it exists."""
    candidates = [
        BIN_DIR / "mg",
        REPO_ROOT / "mangle-query-service" / "bin" / "mg",
    ]
    for c in candidates:
        if c.exists() and c.is_file():
            return c
    return None


def _build_mg() -> Path | None:
    """Build the mg binary from mangle-main. Returns path or None on failure."""
    if not MANGLE_DIR.is_dir():
        return None
    out = BIN_DIR / "mg"
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    print("  Building mg from mangle-main/ ...", file=sys.stderr, flush=True)
    result = subprocess.run(
        ["go", "build", "-o", str(out), "./interpreter/mg/..."],
        cwd=str(MANGLE_DIR),
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"  [WARN] go build failed:\n{result.stderr}", file=sys.stderr)
        return None
    print(f"  mg binary built at {out}", file=sys.stderr)
    return out


def _find_or_build_mg() -> Path | None:
    mg = _find_prebuilt_mg()
    if mg:
        return mg
    return _build_mg()


# ── BOM → Mangle facts export ─────────────────────────────────────────────────

def _escape(s: str) -> str:
    """Escape a string value for Mangle (double-quote with backslash escaping)."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def export_bom_facts(bom: dict, service_name: str) -> str:
    """Convert a CycloneDX BOM dict into Mangle fact declarations."""
    lines: list[str] = [
        f"# Mangle facts generated from CycloneDX BOM: {service_name}",
        f"# Schema: component(Purl, Name, Version, License)",
        f"#         depends_on(FromPurl, ToPurl)",
        f"#         has_vulnerability(Purl, VulnId, Severity)",
        f"#         component_no_supplier(Purl, Name)",
        f"#         component_no_hash(Purl, Name)",
        f"#         component_scope(Purl, Scope)   -- only for optional/excluded",
        "",
        # Declare every extensional predicate so Mangle accepts rules that
        # reference them even when there are zero matching facts for this BOM.
        'Decl component(Purl, Name, Version, License) descr [extensional()].',
        'Decl depends_on(From, To) descr [extensional()].',
        'Decl has_vulnerability(Purl, VulnId, Severity) descr [extensional()].',
        'Decl component_no_supplier(Purl, Name) descr [extensional()].',
        'Decl component_no_hash(Purl, Name) descr [extensional()].',
        # component_scope only emitted for non-default (optional / excluded).
        # Rules use negation-as-failure: !component_scope(P,"optional") succeeds
        # for required components (no fact) and fails for optional ones (fact exists).
        'Decl component_scope(Purl, Scope) descr [extensional()].',
        "",
    ]

    def fact(pred: str, *args: str) -> str:
        inner = ", ".join(f'"{_escape(a)}"' for a in args)
        return f"{pred}({inner})."

    components = bom.get("components", [])
    meta_comp  = bom.get("metadata", {}).get("component", {})
    if meta_comp:
        components = [meta_comp] + components

    comp_purls: set[str] = set()
    for comp in components:
        purl    = comp.get("purl", "")          or comp.get("bom-ref", "")
        name    = comp.get("name", "")
        version = comp.get("version", "")
        lics    = comp.get("licenses", [])
        lid     = "NOASSERTION"
        if lics:
            lic_node = lics[0]
            lid = (
                lic_node.get("license", {}).get("id", "")
                or lic_node.get("expression", "")
                or "NOASSERTION"
            )
        if not purl or not name:
            continue
        comp_purls.add(purl)
        lines.append(fact("component", purl, name, version, lid))

        # Missing supplier
        supplier = comp.get("supplier", {}).get("name", "") or comp.get("author", "")
        if not supplier:
            lines.append(fact("component_no_supplier", purl, name))

        # Missing hash
        hashes = comp.get("hashes", [])
        if not hashes:
            lines.append(fact("component_no_hash", purl, name))

        # Scope fact — only emitted for non-default scopes (optional / excluded).
        # "required" is the CycloneDX default and the vast majority of components,
        # so emitting it would bloat the facts file without adding information.
        scope = (comp.get("scope") or "").strip()
        if scope in ("optional", "excluded"):
            lines.append(fact("component_scope", purl, scope))

        # Vulnerability overlay (from formulation or annotations if present)
        for vuln in comp.get("_vulnerabilities", []):
            lines.append(fact("has_vulnerability", purl, vuln["id"], vuln.get("severity", "UNKNOWN")))

    # Dependency graph
    lines.append("")
    for dep in bom.get("dependencies", []):
        from_ref = dep.get("ref", "")
        for to_ref in dep.get("dependsOn", []):
            if from_ref in comp_purls or to_ref in comp_purls:
                lines.append(fact("depends_on", from_ref, to_ref))

    # Load vulnerability data from VEX file if it exists
    vex_path = BOMS_DIR_DEFAULT / "vex" / f"{service_name}.vex.json"
    if vex_path.exists():
        try:
            vex = json.loads(vex_path.read_text())
            for vuln in vex.get("vulnerabilities", []):
                vid  = vuln.get("id", "")
                sev  = (vuln.get("ratings", [{}])[0].get("severity", "UNKNOWN")).upper()
                for aff in vuln.get("affects", []):
                    ref = aff.get("ref", "")
                    if ref:
                        lines.append(fact("has_vulnerability", ref, vid, sev))
        except Exception:
            pass

    return "\n".join(lines) + "\n"


# ── Mangle query execution ────────────────────────────────────────────────────

_FACT_RE = re.compile(r'^([a-z_]+)\((.+)\)\s*$')
_ARG_RE  = re.compile(r'"((?:[^"\\]|\\.)*)"')


def _parse_mg_output(raw: str) -> list[dict]:
    """Parse mg output lines into structured finding dicts."""
    findings: list[dict] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _FACT_RE.match(line)
        if not m:
            continue
        pred = m.group(1)
        args = _ARG_RE.findall(m.group(2))
        findings.append({"predicate": pred, "args": args})
    return findings


def run_mg_query(mg_bin: Path, facts_file: Path, query: str) -> list[dict]:
    """Execute a single Mangle query and return parsed results."""
    result = subprocess.run(
        [str(mg_bin),
         "-load", f"{facts_file},{RULES_FILE}",
         "-exec", query],
        capture_output=True, text=True, timeout=60,
    )
    return _parse_mg_output(result.stdout)


# ── Python fallback (non-transitive rules only) ───────────────────────────────

_BLOCKED = {
    "AGPL-3.0-only","AGPL-3.0-or-later","GPL-3.0-only","GPL-3.0-or-later",
    "SSPL-1.0","BUSL-1.1","Commons-Clause",
}
_REQUIRES_APPROVAL = {
    "GPL-2.0-only","GPL-2.0-or-later","LGPL-2.0-only","LGPL-2.0-or-later",
    "LGPL-2.1-only","LGPL-2.1-or-later","LGPL-3.0-only","LGPL-3.0-or-later",
    "CC-BY-SA-4.0","EUPL-1.2","OSL-3.0",
}


def python_fallback(bom: dict) -> list[dict]:
    """
    Non-recursive policy evaluation used when Mangle is unavailable.

    Mirrors the scope-awareness of sbom_policy.mg:
    - optional / excluded components are exempt from BLOCKED_LICENSE and
      REQUIRES_APPROVAL (they are dev/test tools, not shipped to customers).
    - LICENSE_NOASSERTION is reported for all components regardless of scope
      (it is a data-quality issue, not a policy violation).
    """
    findings: list[dict] = []
    for comp in bom.get("components", []):
        purl  = comp.get("purl", comp.get("bom-ref", ""))
        name  = comp.get("name", "")
        scope = (comp.get("scope") or "required").strip()
        lics  = comp.get("licenses", [])
        lid   = "NOASSERTION"
        if lics:
            lid = lics[0].get("license", {}).get("id", "NOASSERTION")

        # Scope guard: dev/test tools do not ship; copyleft/blocked-licence
        # obligations do not apply.  Mirrors !component_scope(Purl,"optional")
        # in sbom_policy.mg → production_component(Purl).
        is_production = scope not in ("optional", "excluded")

        if is_production:
            if lid in _BLOCKED:
                findings.append({"predicate": "policy_violation",
                                 "args": [purl, name, lid, "BLOCKED_LICENSE"]})
            elif lid in _REQUIRES_APPROVAL:
                findings.append({"predicate": "policy_violation",
                                 "args": [purl, name, lid, "REQUIRES_APPROVAL"]})

        # Data-quality: NOASSERTION is reported for all components (including dev)
        # because it means the BOM generator could not determine the licence.
        if lid == "NOASSERTION":
            findings.append({"predicate": "missing_attribution",
                             "args": [purl, name, "LICENSE_NOASSERTION"]})
    return findings


# ── Main audit loop ───────────────────────────────────────────────────────────

_QUERIES = [
    ("policy_violation",  'policy_violation(A, B, C, D)'),
    ("copyleft_tainted",  'copyleft_tainted(A, B, C)'),
    ("vuln_violation",    'vuln_violation(A, B, C, D)'),
    ("missing_attribution", 'missing_attribution(A, B, C)'),
]

_SEVERITY_MAP = {
    "BLOCKED_LICENSE":              "FAIL",
    "TRANSITIVE_STRONG_COPYLEFT":   "FAIL",
    "REQUIRES_APPROVAL":            "WARN",
    "TRANSITIVE_WEAK_COPYLEFT":     "WARN",
    "ECCN_5D002_REVIEW":            "INFO",
    "NO_SUPPLIER":                  "WARN",
    "NO_HASH":                      "INFO",
    "LICENSE_NOASSERTION":          "WARN",
}

# ── Remediation table (P3-C) ──────────────────────────────────────────────────
# Static guidance for known blocked / approval-required packages.
# Keys are lowercase package name. Values are surfaced in SARIF helpText and
# in the --json output so that downstream tools (Dependabot, Renovate) can act.
_REMEDIATION_TABLE: dict[str, dict] = {
    "rfc3987": {
        "fixedIn":     "No drop-in upgrade; replace with rfc3986 (Apache-2.0) or uri-template (MIT)",
        "advisoryUrl": "https://pypi.org/project/rfc3987/",
        "alternative": "pkg:pypi/rfc3986@1.5.0",
    },
    "html2text": {
        "fixedIn":     "No drop-in upgrade; replace with markdownify (MIT) or bleach (Apache-2.0)",
        "advisoryUrl": "https://pypi.org/project/html2text/",
        "alternative": "pkg:pypi/markdownify@0.13.1",
    },
    "world-monitor": {
        "fixedIn":     "Intentional — world-monitor is AGPL-3.0 by design (see SUP-003)",
        "advisoryUrl": "https://github.com/SAP-samples/digital-manufacturing-open-sapcapabilities",
        "alternative": None,
    },
    "ua-parser-js": {
        "fixedIn":     "ua-parser-js v1.x is MIT; v2.x+ is dual MIT/AGPL — pin to <2.0.0",
        "advisoryUrl": "https://www.npmjs.com/package/ua-parser-js",
        "alternative": "pkg:npm/ua-parser-js@1.0.41",
    },
    "cryptography": {
        "fixedIn":     "N/A — ECCN review required; document encryption use-case before export",
        "advisoryUrl": "https://www.bis.doc.gov/index.php/encryption-and-export-administration-regulations-ear",
        "alternative": None,
    },
}


def audit_bom(bom: dict, service_name: str, mg_bin: Path | None) -> dict:
    """Run all Mangle queries against one BOM. Return structured report."""
    facts_text = export_bom_facts(bom, service_name)
    all_findings: list[dict] = []
    engine_used = "mangle"

    if mg_bin:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".mg", prefix=f"sbom_{service_name}_", delete=False
        ) as tf:
            tf.write(facts_text)
            facts_path = Path(tf.name)
        try:
            for pred, query in _QUERIES:
                for finding in run_mg_query(mg_bin, facts_path, query):
                    all_findings.append(finding)
        finally:
            facts_path.unlink(missing_ok=True)
    else:
        print(f"  [WARN] Mangle unavailable — using Python fallback for {service_name}",
              file=sys.stderr)
        engine_used = "python-fallback"
        all_findings = python_fallback(bom)

    # Annotate severity + remediation (fixedIn, advisoryUrl)
    for f in all_findings:
        reason = f["args"][-1] if f["args"] else ""
        f["severity"] = _SEVERITY_MAP.get(reason, "INFO")
        # args[1] is the component name for policy_violation and vuln_violation
        comp_name = (f["args"][1] if len(f["args"]) > 1 else "").lower()
        remediation = _REMEDIATION_TABLE.get(comp_name)
        if remediation:
            f["fixedIn"]     = remediation["fixedIn"]
            f["advisoryUrl"] = remediation["advisoryUrl"]
            if remediation.get("alternative"):
                f["alternative"] = remediation["alternative"]

    fail_count = sum(1 for f in all_findings if f["severity"] == "FAIL")
    warn_count = sum(1 for f in all_findings if f["severity"] == "WARN")

    return {
        "service":      service_name,
        "engine":       engine_used,
        "findings":     all_findings,
        "summary": {
            "total":    len(all_findings),
            "FAIL":     fail_count,
            "WARN":     warn_count,
            "INFO":     len(all_findings) - fail_count - warn_count,
        },
        "verdict":      "FAIL" if fail_count > 0 else ("WARN" if warn_count > 0 else "PASS"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="SBOM policy evaluation via Google Mangle Datalog engine"
    )
    parser.add_argument("--boms-dir",                type=Path, default=BOMS_DIR_DEFAULT)
    parser.add_argument("--json",                    action="store_true")
    parser.add_argument("--fail-on-blocked",         action="store_true",
                        help="Exit 1 if any BLOCKED_LICENSE finding")
    parser.add_argument("--fail-on-transitive-copyleft", action="store_true",
                        help="Exit 1 if any TRANSITIVE_STRONG_COPYLEFT finding")
    parser.add_argument("--skip-build",              action="store_true",
                        help="Do not attempt to build mg; use fallback if absent")
    args = parser.parse_args()

    mg_bin = None if args.skip_build else _find_or_build_mg()
    if not mg_bin:
        print("  [WARN] mg binary not found/built — using Python fallback", file=sys.stderr)

    bom_files = sorted(args.boms_dir.glob("*.cyclonedx.json"))
    if not bom_files:
        print(f"No BOMs in {args.boms_dir}", file=sys.stderr)
        sys.exit(2)

    results: list[dict] = []
    exit_code = 0

    for bf in bom_files:
        service_name = bf.stem.replace(".cyclonedx", "")
        print(f"  Auditing {service_name} ...", file=sys.stderr, flush=True)
        bom    = json.loads(bf.read_text())
        report = audit_bom(bom, service_name, mg_bin)
        results.append(report)

        if args.fail_on_blocked and any(
            f["args"][-1] == "BLOCKED_LICENSE" for f in report["findings"]
        ):
            exit_code = 1
        if args.fail_on_transitive_copyleft and any(
            f["args"][-1] == "TRANSITIVE_STRONG_COPYLEFT" for f in report["findings"]
        ):
            exit_code = 1

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        engine_tag = f"[{results[0]['engine']}]" if results else ""
        print(f"\n{'='*72}")
        print(f"  MANGLE SBOM POLICY AUDIT  {engine_tag}")
        print("=" * 72)
        for r in results:
            s = r["summary"]
            icon = "✗" if r["verdict"] == "FAIL" else ("⚠" if r["verdict"] == "WARN" else "✓")
            print(f"  {icon} {r['service']:50s}  "
                  f"FAIL={s['FAIL']}  WARN={s['WARN']}  INFO={s['INFO']}")
            for f in r["findings"]:
                if f["severity"] in ("FAIL", "WARN"):
                    args_str = "  ".join(f["args"][1:])
                    print(f"      [{f['severity']}] {f['predicate']}  {args_str}")
        fails  = sum(r["summary"]["FAIL"] for r in results)
        warns  = sum(r["summary"]["WARN"] for r in results)
        print(f"\n  TOTALS  FAIL={fails}  WARN={warns}")
        print("=" * 72)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()

