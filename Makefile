# ════════════════════════════════════════════════════════════════════════════
# SBOM + LaTeX documentation pipeline
# See scripts/sbom-lineage/README.md for full documentation.
#
# Quick start:
#   make sbom-lineage            # collect lineage + build BOMs + generate .tex
#   make sbom-audit              # NTIA + CycloneDX 1.5 compliance audit
#   make sbom-audit-policy       # audit with policy gates (blocklist, copyleft, ECCN)
#   make sbom-risk-report        # executive risk scores across all BOMs
#   make sbom-vuln               # OSV vulnerability overlay + VEX generation
#   make sbom-spdx               # export all BOMs to SPDX 2.3 JSON
#   make sbom-diff-check         # CI gate: diff current vs snapshot (fail on new copyleft)
#   make sbom-sign               # write SHA-256 integrity manifest
#   make sbom-verify             # verify SHA-256 integrity manifest
#   make sbom-lineage-pdf        # also compile to PDF (requires pdflatex + packages)
#   make sbom-lineage-docx       # export combined report to Word (.docx, requires pandoc)
#   make sbom-per-service        # generate one .tex per service in docs/
#   make sbom-pdf-all-services   # compile all per-service .tex to PDF
#   make sbom-docx-all-services  # export all per-service .tex to Word
#   make sbom-lineage-export     # PDF + DOCX for combined report
#   make sbom-export-all-services # PDF + DOCX for all per-service reports
#   make technical-reports-pdf   # compile docs/technical-reports/*.tex to PDF
#   make technical-reports-docx  # export technical reports to Word
#   make technical-reports-export # PDF + DOCX for technical reports
#   make sbom-check              # verify generated .tex files are up-to-date (CI)
# ════════════════════════════════════════════════════════════════════════════

SBOM_DIR     := scripts/sbom-lineage
BOMS_DIR     := $(SBOM_DIR)/boms
POLICY_FILE  := $(SBOM_DIR)/policy.yaml
SNAPSHOT_DIR := $(SBOM_DIR)/boms-snapshot
TECH_REPORTS_DIR := docs/technical-reports
TECH_REPORTS_TEX := $(wildcard $(TECH_REPORTS_DIR)/*.tex)

.PHONY: sbom-lineage sbom-lineage-pdf sbom-lineage-docx sbom-lineage-export \
        sbom-per-service sbom-pdf-all-services sbom-docx-all-services sbom-export-all-services \
        technical-reports-pdf technical-reports-docx technical-reports-export \
        sbom-full-python sbom-check sbom-audit sbom-audit-policy sbom-risk-report \
        sbom-vuln sbom-spdx sbom-diff-check sbom-sign sbom-verify sbom-snapshot \
        sbom-scan-licenses sbom-scan-licenses-strict \
        sbom-add-spdx-headers sbom-add-spdx-headers-dry-run \
        sbom-ml-lineage sbom-slsa sbom-mangle-audit sbom-mangle-build \
        sbom-mangle-audit-strict sbom-vuln-offline sbom-sarif sbom-full-audit sbom-parity

# ── Step 1: collect git lineage JSON ────────────────────────────────────────
scripts/sbom-lineage/lineage.json:
	python3 scripts/sbom-lineage/collect_lineage.py

# ── Step 2: build CycloneDX BOMs ────────────────────────────────────────────
scripts/sbom-lineage/boms: scripts/sbom-lineage/lineage.json
	python3 scripts/sbom-lineage/build_cyclonedx.py
	@touch scripts/sbom-lineage/boms  # stamp directory so make knows it's fresh

# ── Step 3: generate combined LaTeX report ──────────────────────────────────
docs/sbom-lineage.tex: scripts/sbom-lineage/boms
	python3 scripts/sbom-lineage/generate_latex.py \
	    --output docs/sbom-lineage.tex

# Convenience alias: run all three steps
sbom-lineage: docs/sbom-lineage.tex

# ── PDF: compile combined report (two passes for TOC/cross-refs) ─────────────
sbom-lineage-pdf: sbom-lineage
	cd docs && \
	  pdflatex -interaction=nonstopmode sbom-lineage.tex && \
	  pdflatex -interaction=nonstopmode sbom-lineage.tex
	@echo "PDF written to docs/sbom-lineage.pdf"

# ── Word: combined SBOM report (requires pandoc) ─────────────────────────────
sbom-lineage-docx: sbom-lineage
	@command -v pandoc >/dev/null 2>&1 || (echo "ERROR: pandoc not found. Install from https://pandoc.org/installing.html"; exit 1)
	cd docs && pandoc sbom-lineage.tex -o sbom-lineage.docx --from=latex
	@echo "DOCX written to docs/sbom-lineage.docx"

sbom-lineage-export: sbom-lineage-pdf sbom-lineage-docx
	@echo "Combined report: docs/sbom-lineage.pdf and docs/sbom-lineage.docx"

# ── Per-service .tex files: one per manifest entry ───────────────────────────
# Reads service paths from the manifest and generates docs/sbom-<service>.tex
sbom-per-service: sbom-lineage
	python3 scripts/sbom-lineage/gen_per_service.py

# ── PDF: compile ALL per-service docs ───────────────────────────────────────
sbom-pdf-all-services: sbom-per-service
	@cd docs && for f in sbom-*.tex; do \
	  echo "Compiling $$f ..."; \
	  pdflatex -interaction=nonstopmode "$$f" > /dev/null && \
	  pdflatex -interaction=nonstopmode "$$f" > /dev/null && \
	  echo "  OK: $${f%.tex}.pdf"; \
	done
	@echo "All PDFs compiled."

# ── Word: all per-service docs ───────────────────────────────────────────────
sbom-docx-all-services: sbom-per-service
	@command -v pandoc >/dev/null 2>&1 || (echo "ERROR: pandoc not found. Install from https://pandoc.org/installing.html"; exit 1)
	@cd docs && for f in sbom-*.tex; do \
	  echo "Converting $$f ..."; \
	  pandoc "$$f" -o "$${f%.tex}.docx" --from=latex && \
	  echo "  OK: $${f%.tex}.docx"; \
	done
	@echo "All per-service DOCX files written under docs/."

sbom-export-all-services: sbom-pdf-all-services sbom-docx-all-services
	@echo "Per-service PDF and DOCX export complete."

# ── Technical reports (docs/technical-reports/*.tex) ──────────────────────────
technical-reports-pdf:
	@test -n "$(TECH_REPORTS_TEX)" || (echo "ERROR: no .tex files in $(TECH_REPORTS_DIR)"; exit 1)
	@command -v pdflatex >/dev/null 2>&1 || (echo "ERROR: pdflatex not found."; exit 1)
	@for f in $(TECH_REPORTS_TEX); do \
	  echo "Compiling $$f ..."; \
	  d=$$(dirname "$$f"); b=$$(basename "$$f"); \
	  ( cd "$$d" && pdflatex -interaction=nonstopmode "$$b" > /dev/null && \
	    pdflatex -interaction=nonstopmode "$$b" > /dev/null ) && \
	  echo "  OK: $${f%.tex}.pdf" || exit 1; \
	done

technical-reports-docx:
	@test -n "$(TECH_REPORTS_TEX)" || (echo "ERROR: no .tex files in $(TECH_REPORTS_DIR)"; exit 1)
	@command -v pandoc >/dev/null 2>&1 || (echo "ERROR: pandoc not found. Install from https://pandoc.org/installing.html"; exit 1)
	@for f in $(TECH_REPORTS_TEX); do \
	  echo "Converting $$f ..."; \
	  pandoc "$$f" -o "$${f%.tex}.docx" --from=latex && \
	  echo "  OK: $${f%.tex}.docx"; \
	done

technical-reports-export: technical-reports-pdf technical-reports-docx
	@echo "Technical reports: PDF and DOCX in $(TECH_REPORTS_DIR)/"

# ── Full Python SBOMs (transitive deps via cyclonedx-bom in venvs) ──────────
sbom-full-python:
	bash scripts/sbom-lineage/build_full_python_sbom.sh

# ── CI staleness check ───────────────────────────────────────────────────────
# Regenerates sbom-lineage.tex into a temp file and diffs against committed.
# Exits non-zero if the committed file is out of date.
sbom-check:
	@echo "Checking sbom-lineage.tex is up to date..."
	@python3 scripts/sbom-lineage/collect_lineage.py \
	    --output /tmp/_sbom_check_lineage.json
	@python3 scripts/sbom-lineage/build_cyclonedx.py \
	    --out-dir /tmp/_sbom_check_boms
	@python3 scripts/sbom-lineage/generate_latex.py \
	    --boms-dir /tmp/_sbom_check_boms \
	    --lineage /tmp/_sbom_check_lineage.json \
	    --output /tmp/_sbom_check.tex
	@diff docs/sbom-lineage.tex /tmp/_sbom_check.tex && \
	  echo "sbom-lineage.tex is up to date." || \
	  (echo "ERROR: docs/sbom-lineage.tex is stale. Run 'make sbom-lineage' and commit."; exit 1)


# ════════════════════════════════════════════════════════════════════════════
# Professional Audit Targets (PwC / QuantumBlack parity)
# ════════════════════════════════════════════════════════════════════════════

# ── NTIA + CycloneDX 1.5 compliance audit (baseline) ────────────────────────
sbom-audit:
	python3 $(SBOM_DIR)/audit_sbom.py --boms-dir $(BOMS_DIR)

# ── Policy-gated audit (licence blocklist + copyleft + ECCN) ────────────────
sbom-audit-policy:
	python3 $(SBOM_DIR)/audit_sbom.py --boms-dir $(BOMS_DIR) --policy $(POLICY_FILE)

# ── Executive risk report ────────────────────────────────────────────────────
sbom-risk-report:
	python3 $(SBOM_DIR)/audit_sbom.py --boms-dir $(BOMS_DIR) \
	    --policy $(POLICY_FILE) --risk-report

# ── OSV vulnerability overlay + VEX generation ──────────────────────────────
# Writes vulnerability data into BOMs and VEX docs to boms/vex/
sbom-vuln:
	python3 $(SBOM_DIR)/vuln_overlay.py --boms-dir $(BOMS_DIR)

# Offline-safe VEX stub generation (no network required).
# Always writes boms/vex/<service>.vex.cdx.json for every BOM.
# Used in sbom-full-audit so VEX artefacts are always present in CI.
sbom-vuln-offline:
	python3 $(SBOM_DIR)/vuln_overlay.py --boms-dir $(BOMS_DIR) --offline-ok

# Vulnerability scan: fail on CRITICAL
sbom-vuln-gate:
	python3 $(SBOM_DIR)/vuln_overlay.py --boms-dir $(BOMS_DIR) \
	    --no-overlay --fail-on-critical

# ── SPDX 2.3 JSON export (OpenChain / Linux Foundation) ─────────────────────
sbom-spdx:
	python3 $(SBOM_DIR)/sbom_to_spdx.py --boms-dir $(BOMS_DIR)

# ── Save a snapshot of current BOMs for diff tracking ───────────────────────
sbom-snapshot:
	@mkdir -p $(SNAPSHOT_DIR)
	@cp $(BOMS_DIR)/*.cyclonedx.json $(SNAPSHOT_DIR)/
	@echo "Snapshot saved to $(SNAPSHOT_DIR)/ ($(shell ls $(BOMS_DIR)/*.cyclonedx.json | wc -l | tr -d ' ') BOMs)"

# ── Diff current BOMs against snapshot ───────────────────────────────────────
sbom-diff:
	python3 $(SBOM_DIR)/sbom_diff.py --old $(SNAPSHOT_DIR) --new $(BOMS_DIR)

# CI gate: fail if any newly introduced dependency uses a copyleft licence
sbom-diff-check:
	python3 $(SBOM_DIR)/sbom_diff.py --old $(SNAPSHOT_DIR) --new $(BOMS_DIR) \
	    --fail-on-new-copyleft

# ── Integrity signing: SHA-256 manifest (no dependencies required) ───────────
sbom-sign:
	python3 $(SBOM_DIR)/sign_sbom.py --mode hash

sbom-verify:
	python3 $(SBOM_DIR)/sign_sbom.py --mode hash --verify

# EC key-based signing (requires: pip install cryptography)
sbom-sign-key: sbom-signing.pem
	python3 $(SBOM_DIR)/sign_sbom.py --mode key --private-key sbom-signing.pem

sbom-verify-key: sbom-signing.pub.pem
	python3 $(SBOM_DIR)/sign_sbom.py --mode key --verify --public-key sbom-signing.pub.pem

# Generate a signing key pair (run once, store keys securely)
sbom-signing.pem sbom-signing.pub.pem:
	python3 $(SBOM_DIR)/sign_sbom.py --generate-key --key-prefix sbom-signing

# ── SPDX header injection (REUSE compliance) ─────────────────────────────────
# Preview what would be changed without writing any files:
sbom-add-spdx-headers-dry-run:
	python3 $(SBOM_DIR)/add_spdx_headers.py --dry-run

# Apply SPDX headers to all SAP-owned source files (idempotent):
sbom-add-spdx-headers:
	python3 $(SBOM_DIR)/add_spdx_headers.py

# ── Source-level license discovery (binary fingerprinting analog) ─────────────
sbom-scan-licenses:
	python3 $(SBOM_DIR)/scan_licenses.py

sbom-scan-licenses-strict:
	python3 $(SBOM_DIR)/scan_licenses.py --fail-on-mismatch

# ── ML model cards + dataset provenance (QuantumBlack parity) ────────────────
sbom-ml-lineage:
	python3 $(SBOM_DIR)/ml_lineage.py

# ── SLSA v1.0 provenance documents ──────────────────────────────────────────
sbom-slsa:
	python3 $(SBOM_DIR)/slsa_provenance.py

# ── Mangle Datalog policy engine ─────────────────────────────────────────────
# Build the mg binary from mangle-main/ (requires Go):
sbom-mangle-build:
	cd mangle-main && go build -o ../$(SBOM_DIR)/bin/mg ./interpreter/mg/...
	@echo "mg binary built at $(SBOM_DIR)/bin/mg"

# Run Mangle Datalog policy audit across all BOMs:
sbom-mangle-audit: sbom-mangle-build
	python3 $(SBOM_DIR)/mangle_audit.py

# Run with strict mode (exit 1 on BLOCKED_LICENSE):
sbom-mangle-audit-strict: sbom-mangle-build
	python3 $(SBOM_DIR)/mangle_audit.py \
	  --fail-on-blocked \
	  --fail-on-transitive-copyleft

# ── Full professional audit pipeline (PwC + QB + Mangle parity) ──────────────
# Runs all checks in sequence; any FAIL stops the pipeline.
sbom-full-audit: sbom-audit-policy sbom-mangle-audit-strict sbom-scan-licenses \
                 sbom-vuln-offline sbom-spdx sbom-ml-lineage sbom-slsa sbom-sign
	@echo "Full professional audit complete."
	@echo "  - Policy gates:       passed"
	@echo "  - Mangle Datalog:     $(SBOM_DIR)/bin/mg"
	@echo "  - Source scan:        $(BOMS_DIR)/scan/"
	@echo "  - SPDX 2.3 export:   $(BOMS_DIR)/spdx/"
	@echo "  - ML lineage:         $(BOMS_DIR)/ml/"
	@echo "  - SLSA provenance:    $(BOMS_DIR)/provenance/"
	@echo "  - Hash manifest:      $(BOMS_DIR)/sbom-sha256-manifest.json"
	@echo ""
	@echo "Network-dependent (run separately):"
	@echo "  make sbom-vuln        — OSV vulnerability overlay + VEX"
	@echo "  make sbom-risk-report — executive risk scores"

# ── SARIF 2.1.0 output (industry / QB standard) ──────────────────────────────
# Generates SARIF from all available input files; skips any that don't exist.
sbom-sarif:
	python3 $(SBOM_DIR)/mangle_audit.py   --json 2>/dev/null > /tmp/_mangle.json; true
	python3 $(SBOM_DIR)/audit_sbom.py     --json 2>/dev/null > /tmp/_audit.json;  true
	python3 $(SBOM_DIR)/scan_licenses.py  --json 2>/dev/null > /tmp/_scan.json;   true
	python3 $(SBOM_DIR)/sbom_to_sarif.py \
	  --mangle-json /tmp/_mangle.json \
	  --audit-json  /tmp/_audit.json  \
	  --scan-json   /tmp/_scan.json
	@echo "SARIF: $(BOMS_DIR)/sarif/sbom-findings.sarif.json"
	@echo "Upload: gh api repos/{owner}/{repo}/code-scanning/sarifs --field sarif=@$(BOMS_DIR)/sarif/sbom-findings.sarif.json --field ref=\$$(git rev-parse HEAD)"

# ── Complete parity target — the one-stop command ────────────────────────────
sbom-parity: sbom-full-audit sbom-sarif sbom-risk-report
	@echo ""
	@echo "========================================================"
	@echo "  PwC + QuantumBlack + Mangle parity achieved."
	@echo "  Run 'make sbom-vuln' for vulnerability data (network)."
	@echo "========================================================"

# ════════════════════════════════════════════════════════════════════════════
# SAC AI Widget Build Pipeline
#
# Quick start:
#   make sac-widget           # full build → widget.zip (production)
#   make sac-widget-dev       # dev build (unminified)
#   make sac-widget-libs      # build ng-packagr libraries only
#   make sac-widget-clean     # remove all dist/ artifacts
# ════════════════════════════════════════════════════════════════════════════

SAC_DIR := src/generativeUI/sac-webcomponents-ngx

.PHONY: sac-widget sac-widget-dev sac-widget-libs sac-widget-clean sac-widget-install

# Install all dependencies (single package)
sac-widget-install:
	@echo "→ Installing @sap-oss/sac-webcomponents-ngx dependencies..."
	cd $(SAC_DIR) && npm install

# Build ng-packagr Angular libraries
sac-widget-libs:
	@echo "→ Building Angular libraries..."
	cd $(SAC_DIR) && npm run build

# Production widget build + zip
sac-widget: sac-widget-libs
	@echo "→ Building SAC AI widget (production)..."
	cd $(SAC_DIR) && npm run build:widget
	@echo "→ Packaging widget.zip..."
	cd $(SAC_DIR) && node scripts/package-widget.js
	@echo ""
	@echo "════════════════════════════════════════════════════════"
	@echo "  widget.zip → $(SAC_DIR)/widget.zip"
	@echo "  Upload via SAC Designer > Custom Widget > Import"
	@echo "════════════════════════════════════════════════════════"

# Dev build (unminified, faster iteration)
sac-widget-dev: sac-widget-libs
	@echo "→ Building SAC AI widget (development)..."
	cd $(SAC_DIR) && npm run build:widget-dev
	@echo "→ Packaging widget.zip..."
	cd $(SAC_DIR) && node scripts/package-widget.js

# Clean all dist artifacts
sac-widget-clean:
	rm -rf $(SAC_DIR)/dist
	rm -f  $(SAC_DIR)/widget.zip
	@echo "→ Cleaned all SAC widget dist artifacts."
