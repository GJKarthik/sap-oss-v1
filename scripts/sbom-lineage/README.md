# SBOM Pipeline — CycloneDX 1.5 · Professional Audit · PwC/QB Parity

This directory builds **CycloneDX 1.5** Software Bill of Materials per service,
validates NTIA minimum elements, applies policy gates, overlays OSV vulnerability
data, exports SPDX 2.3, tracks dependency deltas, and signs artefacts for audit.

## Pipeline overview

```
build_cyclonedx.py   →  boms/*.cyclonedx.json          (NTIA-compliant BOMs)
vuln_overlay.py      →  boms/ + boms/vex/              (OSV CVE data + VEX docs)
audit_sbom.py        →  findings per BOM               (NTIA + policy + copyleft + ECCN + risk)
sbom_to_spdx.py      →  boms/spdx/*.spdx.json          (SPDX 2.3 JSON — OpenChain)
sbom_diff.py         →  delta report                   (added/removed/upgraded deps)
sign_sbom.py         →  boms/sbom-sha256-manifest.json  (SHA-256 / EC sig / sigstore)
generate_latex.py    →  docs/sbom/sbom-lineage.tex     (all BOMs + lineage)
gen_per_service.py   →  docs/sbom/sbom-<stem>.tex      (one LaTeX file per manifest service)
compile-sbom.sh      →  docs/sbom/*.pdf                (compile SBOM .tex to PDF)
generate-latex-from-json.sh  →  docs/sbom/SAP-OSS-SBOM-Detailed.tex  (detailed SBOM from JSON)
generate-full-sbom.sh →  sbom-cyclonedx-full.json      (full dependency extraction)
```

### Regenerate LaTeX only (after BOMs exist)

```bash
python3 scripts/sbom-lineage/collect_lineage.py   # refresh scripts/sbom-lineage/lineage.json
python3 scripts/sbom-lineage/generate_latex.py --output docs/sbom/sbom-lineage.tex
python3 scripts/sbom-lineage/gen_per_service.py
```

Or use `make sbom-lineage` (rebuilds BOMs if needed) then `make sbom-per-service`.

## Quick start

```bash
make sbom-audit             # NTIA + CycloneDX 1.5 compliance check (no network)
make sbom-audit-policy      # + policy gates (GPL/AGPL blocklist, ECCN, copyleft)
make sbom-risk-report       # + executive risk scores (CRITICAL/HIGH/MEDIUM/LOW)
make sbom-vuln              # + OSV vulnerability overlay + VEX (needs network)
make sbom-spdx              # export all BOMs to SPDX 2.3 JSON
make sbom-sign              # write SHA-256 integrity manifest
make sbom-full-audit        # run all of the above in sequence
```

## Requirements

- **Python 3.10+** and `pip install -r scripts/sbom-lineage/requirements.txt` (PyYAML).
- **Node/npm** for Node projects: `npx @cyclonedx/cdxgen` is run automatically.
- **Git** for lineage collection.
- Optional: `pip install cryptography` for EC key-based SBOM signing.
- Optional: `pip install sigstore` for keyless Sigstore signing (GitHub Actions).



## Tools reference

### `audit_sbom.py` — NTIA + Policy Audit

```bash
python3 scripts/sbom-lineage/audit_sbom.py [options]

Options:
  --boms-dir DIR           Directory of *.cyclonedx.json files (default: boms/)
  --policy policy.yaml     Policy file (license blocklist, vuln gates, copyleft)
  --vuln-fail-on LEVEL     Fail if vuln at CRITICAL/HIGH/MEDIUM found
  --risk-report            Append executive risk tier table
  --json                   Emit JSON findings (for CI integration)
  --fail-on-warn           Treat WARNs as failures
```

| Category | What is checked |
|----------|----------------|
| SCHEMA   | CycloneDX 1.5 structure, serialNumber UUID, specVersion |
| NTIA     | timestamp, tools, authors, purl, exact versions, dependency graph |
| LICENSE  | SPDX 3.24 identifier validity, compound expressions |
| SUPPLY-CHAIN | Cryptographic hashes, supplier attribution |
| COPYLEFT | GPL/AGPL propagation risk (strong + network copyleft) |
| ECCN     | EAR 5D002 export-control classification (crypto packages) |
| POLICY   | License blocklist FAILs, approval-required WARNs |
| VULN     | CVE severity gates (if vulnerability data overlaid) |
| RISK     | Composite risk score 0–100, tier LOW/MEDIUM/HIGH/CRITICAL |

### `vuln_overlay.py` — OSV Vulnerability Scanner + VEX

Queries [OSV.dev](https://osv.dev) batch API for every PURL, then writes:
- Vulnerability entries into `boms/*.cyclonedx.json` (`vulnerabilities[]`)
- Companion VEX documents to `boms/vex/<name>.vex.cdx.json`

```bash
python3 scripts/sbom-lineage/vuln_overlay.py
python3 scripts/sbom-lineage/vuln_overlay.py --min-severity HIGH --fail-on-critical
```

### `sbom_to_spdx.py` — SPDX 2.3 JSON Export

Converts CycloneDX 1.5 BOMs to SPDX 2.3 JSON for OpenChain / Linux Foundation compliance.
Output: `boms/spdx/<name>.spdx.json`

### `sbom_diff.py` — Delta Tracking

```bash
make sbom-snapshot                  # save current state
make sbom-diff                      # show what changed
make sbom-diff-check                # CI gate: fail on new copyleft
```

### `sign_sbom.py` — SBOM Integrity & Signing

```bash
make sbom-sign          # SHA-256 manifest (no dependencies)
make sbom-verify        # verify manifest
make sbom-sign-key      # EC P-256 signature (pip install cryptography)
```

## Policy file — `policy.yaml`

Edit `scripts/sbom-lineage/policy.yaml` to configure:
- `licenses.blocklist` — SPDX IDs that cause a FAIL (e.g. AGPL-3.0-or-later)
- `licenses.require_approval` — SPDX IDs that emit WARN
- `copyleft.strong_copyleft_action` — FAIL / WARN / INFO / IGNORE
- `export_control.eccn_action` — EAR 5D002 crypto package flagging
- `vulnerabilities.fail_on_severity` — severity levels that block the build

## Output files

| File | Description |
|------|-------------|
| `boms/*.cyclonedx.json` | CycloneDX 1.5 BOMs (NTIA-compliant, enriched) |
| `boms/vex/*.vex.cdx.json` | VEX companion documents (after vuln_overlay.py) |
| `boms/spdx/*.spdx.json` | SPDX 2.3 JSON exports (after sbom_to_spdx.py) |
| `boms/sbom-sha256-manifest.json` | SHA-256 integrity manifest |
| `boms/*.cyclonedx.json.sig` | EC P-256 signatures (optional) |
| `boms/*.cyclonedx.json.sigstore` | Sigstore bundles (optional) |
| `boms/scan/*.scan.json` | Per-file source license scan (after scan_licenses.py) |
| `boms/scan/summary.json` | Cross-service declared-vs-discovered report |
| `boms/ml/*.ml_lineage.json` | ML model cards + dataset provenance (after ml_lineage.py) |
| `boms/ml/summary.json` | ML lineage summary |
| `boms/provenance/*.slsa.json` | SLSA v1.0 provenance docs (after slsa_provenance.py) |
| `boms/provenance/provenance-bundle.json` | Combined SLSA bundle (for transparency log upload) |

## Additional tools (full parity)

### `scan_licenses.py` — Source-level license discovery

Walks every service source tree and extracts `SPDX-License-Identifier:` headers
and copyright notices from each file. Computes SHA-256 per file. Compares
discovered licenses against declared licenses in the BOM and flags discrepancies.

```bash
make sbom-scan-licenses           # discover and compare, no failure
make sbom-scan-licenses-strict    # exit 1 on declared-vs-discovered mismatch
```

### `ml_lineage.py` — ML model card + dataset provenance

Detects ML frameworks (PyTorch, Transformers, LangChain, SAP HANA ML, etc.)
from each BOM's component list, scans source files for HuggingFace model-id
strings and `load_dataset()` calls, then generates:
- A structured model card (HuggingFace v0.2 / EU AI Act Annex IV format)
- A CycloneDX 1.5 `formulation[]` section injected into the BOM

```bash
make sbom-ml-lineage
```

### `slsa_provenance.py` — SLSA v1.0 Build Provenance

Generates SLSA Build Level 1 in-toto attestation documents for each BOM,
including pipeline tool digests, source commit SHA, and builder identity URI.

```bash
make sbom-slsa
```

### One-stop parity command

```bash
make sbom-parity      # runs all checks: policy + scan + SPDX + ML + SLSA + sign + risk
make sbom-vuln        # then add OSV vulnerability data (requires network)
```

## Compliance mapping

| Standard / Framework | Covered by |
|---------------------|-----------|
| NTIA Minimum Elements (July 2021) | `audit_sbom.py` baseline |
| CycloneDX 1.5 schema | `audit_sbom.py` SCHEMA checks |
| SPDX 2.3 / OpenChain ISO 5230 | `sbom_to_spdx.py` |
| CISA VEX guidance | `vuln_overlay.py` |
| US EO 14028 (SBOM for federal suppliers) | `slsa_provenance.py` + signing + NTIA |
| EU CRA (Cyber Resilience Act) | vuln overlay + VEX + signing + SLSA |
| EU AI Act Annex IV (technical documentation) | `ml_lineage.py` model cards |
| EAR / ECCN 5D002 | `audit_sbom.py` ECCN check |
| SLSA Build Level 1 | `slsa_provenance.py` |
| REUSE / SPDX source headers | `scan_licenses.py` |
| PwC Technology Risk SBOM assessment | policy + copyleft + ECCN + vuln + source scan |
| QuantumBlack supply-chain + ML lineage | `sbom_diff.py` + `ml_lineage.py` |

## Parity gap table

| Dimension | This pipeline |
|-----------|:-------------:|
| NTIA structural compliance | ✓✓✓ |
| License identification | ✓✓✓ |
| Automation / reproducibility | ✓✓✓ |
| Vulnerability integration (OSV + VEX) | ✓✓✓ |
| Copyleft propagation analysis | ✓✓✓ |
| ECCN / export control classification | ✓✓✓ |
| Source-level license scanning | ✓✓✓ |
| Signed / attested artefacts (hash + EC + sigstore) | ✓✓✓ |
| SPDX 2.3 format | ✓✓✓ |
| Delta / diff tracking (CI gate) | ✓✓✓ |
| Policy-as-code gates | ✓✓✓ |
| Executive risk scoring | ✓✓✓ |
| ML / AI model cards + dataset provenance | ✓✓✓ |
| SLSA v1.0 build provenance | ✓✓✓ |
| CI enforcement (GitHub Actions) | ✓✓✓ |
