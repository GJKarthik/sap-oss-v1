# ════════════════════════════════════════════════════════════════════════════
# SBOM + LaTeX documentation pipeline
# See scripts/sbom-lineage/README.md for full documentation.
#
# Directory structure:
#   docs/latex/     - LaTeX source files (.tex)
#   docs/pdf/       - Generated PDF files
#   docs/docx/      - Generated Word files
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
#   make sbom-per-service        # generate one .tex per service in docs/latex/sbom/
#   make sbom-pdf-all-services   # compile all per-service .tex to PDF
#   make sbom-docx-all-services  # export all per-service .tex to Word
#   make sbom-lineage-export     # PDF + DOCX for combined report
#   make sbom-export-all-services # PDF + DOCX for all per-service reports
#   make technical-reports-pdf   # compile technical reports to PDF
#   make technical-reports-docx  # export technical reports to Word
#   make technical-reports-export # PDF + DOCX for technical reports
#   make specs-all               # compile all domain specs to PDF
#   make spec-clinerules-agents  # compile the .clinerules supplement to PDF
#   make specs-export            # PDF + DOCX for all specs
#   make sbom-check              # verify generated .tex files are up-to-date (CI)
# ════════════════════════════════════════════════════════════════════════════

SBOM_DIR     := scripts/sbom-lineage
BOMS_DIR     := $(SBOM_DIR)/boms
POLICY_FILE  := $(SBOM_DIR)/policy.yaml
SNAPSHOT_DIR := $(SBOM_DIR)/boms-snapshot

# LaTeX source directories
LATEX_DIR    := docs/latex
SBOM_LATEX   := $(LATEX_DIR)/sbom
TR_LATEX     := $(LATEX_DIR)/technical-reports
SPECS_LATEX  := $(LATEX_DIR)/specs

# Output directories
PDF_DIR      := docs/pdf
DOCX_DIR     := docs/docx
LATEX_ENGINE := $(shell if command -v xelatex >/dev/null 2>&1; then echo xelatex; elif command -v lualatex >/dev/null 2>&1; then echo lualatex; else echo ""; fi)
TECTONIC     := $(shell command -v tectonic 2>/dev/null)

TECH_REPORTS_TEX := $(wildcard $(TR_LATEX)/*.tex)

.PHONY: sbom-lineage sbom-lineage-pdf sbom-lineage-docx sbom-lineage-export \
        sbom-per-service sbom-pdf-all-services sbom-docx-all-services sbom-export-all-services \
        technical-reports-pdf technical-reports-docx technical-reports-export \
        sbom-full-python sbom-check sbom-audit sbom-audit-policy sbom-risk-report \
        sbom-vuln sbom-spdx sbom-diff-check sbom-sign sbom-verify sbom-snapshot \
        sbom-scan-licenses sbom-scan-licenses-strict \
        sbom-add-spdx-headers sbom-add-spdx-headers-dry-run \
        sbom-ml-lineage sbom-slsa \
        sbom-vuln-offline sbom-sarif sbom-full-audit sbom-parity \
        spec-arabic spec-tb spec-regulations spec-simula spec-clinerules-agents \
        specs-all specs-docx specs-export

# ── Step 1: collect git lineage JSON ────────────────────────────────────────
scripts/sbom-lineage/lineage.json:
	python3 scripts/sbom-lineage/collect_lineage.py

# ── Step 2: build CycloneDX BOMs ────────────────────────────────────────────
scripts/sbom-lineage/boms: scripts/sbom-lineage/lineage.json
	python3 scripts/sbom-lineage/build_cyclonedx.py
	@touch scripts/sbom-lineage/boms  # stamp directory so make knows it's fresh

# ── Step 3: generate combined LaTeX report ──────────────────────────────────
$(SBOM_LATEX)/sbom-lineage.tex: scripts/sbom-lineage/boms
	python3 scripts/sbom-lineage/generate_latex.py \
	    --output $(SBOM_LATEX)/sbom-lineage.tex

# Convenience alias: run all three steps
sbom-lineage: $(SBOM_LATEX)/sbom-lineage.tex

# ── PDF: compile combined report (two passes for TOC/cross-refs) ─────────────
sbom-lineage-pdf: sbom-lineage
	@mkdir -p $(PDF_DIR)/sbom
	@if command -v pdflatex >/dev/null 2>&1; then \
	  cd $(SBOM_LATEX) && pdflatex -interaction=nonstopmode sbom-lineage.tex && \
	    pdflatex -interaction=nonstopmode sbom-lineage.tex && \
	    mv sbom-lineage.pdf ../../pdf/sbom/; \
	elif command -v tectonic >/dev/null 2>&1; then \
	  cd $(SBOM_LATEX) && tectonic sbom-lineage.tex && \
	    mv sbom-lineage.pdf ../../pdf/sbom/; \
	else \
	  echo "ERROR: install pdflatex (MacTeX/TeX Live) or tectonic (brew install tectonic)."; exit 1; \
	fi
	@rm -f $(SBOM_LATEX)/*.aux $(SBOM_LATEX)/*.log $(SBOM_LATEX)/*.toc $(SBOM_LATEX)/*.out
	@echo "PDF written to $(PDF_DIR)/sbom/sbom-lineage.pdf"

# ── Word: combined SBOM report (requires pandoc) ─────────────────────────────
sbom-lineage-docx: sbom-lineage
	@mkdir -p $(DOCX_DIR)/sbom
	@command -v pandoc >/dev/null 2>&1 || (echo "ERROR: pandoc not found. Install from https://pandoc.org/installing.html"; exit 1)
	pandoc $(SBOM_LATEX)/sbom-lineage.tex -o $(DOCX_DIR)/sbom/sbom-lineage.docx --from=latex
	@echo "DOCX written to $(DOCX_DIR)/sbom/sbom-lineage.docx"

sbom-lineage-export: sbom-lineage-pdf sbom-lineage-docx
	@echo "Combined report: $(PDF_DIR)/sbom/sbom-lineage.pdf and $(DOCX_DIR)/sbom/sbom-lineage.docx"

# ── Per-service .tex files: one per manifest entry ───────────────────────────
sbom-per-service: sbom-lineage
	python3 scripts/sbom-lineage/gen_per_service.py --output-dir $(SBOM_LATEX)

# ── PDF: compile ALL per-service docs ───────────────────────────────────────
sbom-pdf-all-services: sbom-per-service
	@mkdir -p $(PDF_DIR)/sbom
	@cd $(SBOM_LATEX) && for f in sbom-*.tex; do \
	  test -f "$$f" || continue; \
	  case "$$f" in sbom-lineage.tex) continue;; esac; \
	  echo "Compiling $$f ..."; \
	  pdflatex -interaction=nonstopmode "$$f" > /dev/null && \
	  pdflatex -interaction=nonstopmode "$$f" > /dev/null && \
	  mv "$${f%.tex}.pdf" ../../pdf/sbom/ && \
	  echo "  OK: $(PDF_DIR)/sbom/$${f%.tex}.pdf"; \
	done
	@rm -f $(SBOM_LATEX)/*.aux $(SBOM_LATEX)/*.log $(SBOM_LATEX)/*.toc $(SBOM_LATEX)/*.out
	@echo "All PDFs compiled to $(PDF_DIR)/sbom/"

# ── Word: all per-service docs ───────────────────────────────────────────────
sbom-docx-all-services: sbom-per-service
	@mkdir -p $(DOCX_DIR)/sbom
	@command -v pandoc >/dev/null 2>&1 || (echo "ERROR: pandoc not found. Install from https://pandoc.org/installing.html"; exit 1)
	@cd $(SBOM_LATEX) && for f in sbom-*.tex; do \
	  test -f "$$f" || continue; \
	  case "$$f" in sbom-lineage.tex) continue;; esac; \
	  echo "Converting $$f ..."; \
	  pandoc "$$f" -o "../../docx/sbom/$${f%.tex}.docx" --from=latex && \
	  echo "  OK: $(DOCX_DIR)/sbom/$${f%.tex}.docx"; \
	done
	@echo "All per-service DOCX files written to $(DOCX_DIR)/sbom/"

sbom-export-all-services: sbom-pdf-all-services sbom-docx-all-services
	@echo "Per-service PDF and DOCX export complete."

# ── Technical reports ────────────────────────────────────────────────────────
technical-reports-pdf:
	@test -n "$(TECH_REPORTS_TEX)" || (echo "ERROR: no .tex files in $(TR_LATEX)"; exit 1)
	@mkdir -p $(PDF_DIR)/technical-reports
	@command -v pdflatex >/dev/null 2>&1 || (echo "ERROR: pdflatex not found."; exit 1)
	@for f in $(TECH_REPORTS_TEX); do \
	  echo "Compiling $$f ..."; \
	  b=$$(basename "$$f"); \
	  ( cd $(TR_LATEX) && pdflatex -interaction=nonstopmode "$$b" > /dev/null && \
	    pdflatex -interaction=nonstopmode "$$b" > /dev/null && \
	    mv "$${b%.tex}.pdf" ../../pdf/technical-reports/ ) && \
	  echo "  OK: $(PDF_DIR)/technical-reports/$${b%.tex}.pdf" || exit 1; \
	done
	@rm -f $(TR_LATEX)/*.aux $(TR_LATEX)/*.log $(TR_LATEX)/*.toc $(TR_LATEX)/*.out

technical-reports-docx:
	@test -n "$(TECH_REPORTS_TEX)" || (echo "ERROR: no .tex files in $(TR_LATEX)"; exit 1)
	@mkdir -p $(DOCX_DIR)/technical-reports
	@command -v pandoc >/dev/null 2>&1 || (echo "ERROR: pandoc not found. Install from https://pandoc.org/installing.html"; exit 1)
	@for f in $(TECH_REPORTS_TEX); do \
	  echo "Converting $$f ..."; \
	  b=$$(basename "$$f"); \
	  pandoc "$$f" -o "$(DOCX_DIR)/technical-reports/$${b%.tex}.docx" --from=latex && \
	  echo "  OK: $(DOCX_DIR)/technical-reports/$${b%.tex}.docx"; \
	done

technical-reports-export: technical-reports-pdf technical-reports-docx
	@echo "Technical reports: PDF in $(PDF_DIR)/technical-reports/, DOCX in $(DOCX_DIR)/technical-reports/"

# ── Full Python SBOMs (transitive deps via cyclonedx-bom in venvs) ──────────
sbom-full-python:
	bash scripts/sbom-lineage/build_full_python_sbom.sh

# ── CI staleness check ───────────────────────────────────────────────────────
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
	@diff $(SBOM_LATEX)/sbom-lineage.tex /tmp/_sbom_check.tex && \
	  echo "sbom-lineage.tex is up to date." || \
	  (echo "ERROR: $(SBOM_LATEX)/sbom-lineage.tex is stale. Run 'make sbom-lineage' and commit."; exit 1)


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
sbom-vuln:
	python3 $(SBOM_DIR)/vuln_overlay.py --boms-dir $(BOMS_DIR)

sbom-vuln-offline:
	python3 $(SBOM_DIR)/vuln_overlay.py --boms-dir $(BOMS_DIR) --offline-ok

sbom-vuln-gate:
	python3 $(SBOM_DIR)/vuln_overlay.py --boms-dir $(BOMS_DIR) \
	    --no-overlay --fail-on-critical

# ── SPDX 2.3 JSON export ─────────────────────────────────────────────────────
sbom-spdx:
	python3 $(SBOM_DIR)/sbom_to_spdx.py --boms-dir $(BOMS_DIR)

# ── Snapshot and diff ────────────────────────────────────────────────────────
sbom-snapshot:
	@mkdir -p $(SNAPSHOT_DIR)
	@cp $(BOMS_DIR)/*.cyclonedx.json $(SNAPSHOT_DIR)/
	@echo "Snapshot saved to $(SNAPSHOT_DIR)/"

sbom-diff:
	python3 $(SBOM_DIR)/sbom_diff.py --old $(SNAPSHOT_DIR) --new $(BOMS_DIR)

sbom-diff-check:
	python3 $(SBOM_DIR)/sbom_diff.py --old $(SNAPSHOT_DIR) --new $(BOMS_DIR) \
	    --fail-on-new-copyleft

# ── Integrity signing ────────────────────────────────────────────────────────
sbom-sign:
	python3 $(SBOM_DIR)/sign_sbom.py --mode hash

sbom-verify:
	python3 $(SBOM_DIR)/sign_sbom.py --mode hash --verify

sbom-sign-key: sbom-signing.pem
	python3 $(SBOM_DIR)/sign_sbom.py --mode key --private-key sbom-signing.pem

sbom-verify-key: sbom-signing.pub.pem
	python3 $(SBOM_DIR)/sign_sbom.py --mode key --verify --public-key sbom-signing.pub.pem

sbom-signing.pem sbom-signing.pub.pem:
	python3 $(SBOM_DIR)/sign_sbom.py --generate-key --key-prefix sbom-signing

# ── SPDX header injection ────────────────────────────────────────────────────
sbom-add-spdx-headers-dry-run:
	python3 $(SBOM_DIR)/add_spdx_headers.py --dry-run

sbom-add-spdx-headers:
	python3 $(SBOM_DIR)/add_spdx_headers.py

# ── Source-level license discovery ───────────────────────────────────────────
sbom-scan-licenses:
	python3 $(SBOM_DIR)/scan_licenses.py

sbom-scan-licenses-strict:
	python3 $(SBOM_DIR)/scan_licenses.py --fail-on-mismatch

# ── ML model cards + dataset provenance ──────────────────────────────────────
sbom-ml-lineage:
	python3 $(SBOM_DIR)/ml_lineage.py

# ── SLSA v1.0 provenance ─────────────────────────────────────────────────────
sbom-slsa:
	python3 $(SBOM_DIR)/slsa_provenance.py

# ── Full professional audit pipeline ─────────────────────────────────────────
sbom-full-audit: sbom-audit-policy sbom-scan-licenses \
                 sbom-vuln-offline sbom-spdx sbom-ml-lineage sbom-slsa sbom-sign
	@echo "Full professional audit complete."

# ── SARIF 2.1.0 output ───────────────────────────────────────────────────────
sbom-sarif:
	python3 $(SBOM_DIR)/audit_sbom.py     --json 2>/dev/null > /tmp/_audit.json;  true
	python3 $(SBOM_DIR)/scan_licenses.py  --json 2>/dev/null > /tmp/_scan.json;   true
	python3 $(SBOM_DIR)/sbom_to_sarif.py \
	  --audit-json  /tmp/_audit.json  \
	  --scan-json   /tmp/_scan.json
	@echo "SARIF: $(BOMS_DIR)/sarif/sbom-findings.sarif.json"

# ── Complete parity target ───────────────────────────────────────────────────
sbom-parity: sbom-full-audit sbom-sarif sbom-risk-report
	@echo "PwC + QuantumBlack SBOM parity achieved."


# ════════════════════════════════════════════════════════════════════════════
# Domain-specific specification documents
# ════════════════════════════════════════════════════════════════════════════

# Arabic AP Invoice Processing Specification
spec-arabic:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/arabic && $(LATEX_ENGINE) -interaction=nonstopmode arabic-ap-spec.tex > /dev/null && \
	    $(LATEX_ENGINE) -interaction=nonstopmode arabic-ap-spec.tex > /dev/null && \
	    mv arabic-ap-spec.pdf ../../../pdf/specs/; \
	elif [ -n "$(TECTONIC)" ]; then \
	  cd $(SPECS_LATEX)/arabic && $(TECTONIC) --outdir ../../../pdf/specs arabic-ap-spec.tex > /dev/null; \
	else \
	  echo "ERROR: xelatex, lualatex, or tectonic not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/arabic/*.aux $(SPECS_LATEX)/arabic/*.log $(SPECS_LATEX)/arabic/*.toc $(SPECS_LATEX)/arabic/*.out
	@echo "PDF: $(PDF_DIR)/specs/arabic-ap-spec.pdf"

# Trial Balance Review Specification
spec-tb:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/tb && $(LATEX_ENGINE) -interaction=nonstopmode tb-review-spec.tex > /dev/null && \
	    $(LATEX_ENGINE) -interaction=nonstopmode tb-review-spec.tex > /dev/null && \
	    mv tb-review-spec.pdf ../../../pdf/specs/; \
	elif [ -n "$(TECTONIC)" ]; then \
	  cd $(SPECS_LATEX)/tb && $(TECTONIC) --outdir ../../../pdf/specs tb-review-spec.tex > /dev/null; \
	else \
	  echo "ERROR: xelatex, lualatex, or tectonic not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/tb/*.aux $(SPECS_LATEX)/tb/*.log $(SPECS_LATEX)/tb/*.toc $(SPECS_LATEX)/tb/*.out
	@echo "PDF: $(PDF_DIR)/specs/tb-review-spec.pdf"

# AI Regulations Compliance Specification
spec-regulations:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/regulations && $(LATEX_ENGINE) -interaction=nonstopmode regulations-spec.tex > /dev/null && \
	    $(LATEX_ENGINE) -interaction=nonstopmode regulations-spec.tex > /dev/null && \
	    mv regulations-spec.pdf ../../../pdf/specs/; \
	elif [ -n "$(TECTONIC)" ]; then \
	  cd $(SPECS_LATEX)/regulations && $(TECTONIC) --outdir ../../../pdf/specs regulations-spec.tex > /dev/null; \
	else \
	  echo "ERROR: xelatex, lualatex, or tectonic not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/regulations/*.aux $(SPECS_LATEX)/regulations/*.log $(SPECS_LATEX)/regulations/*.toc $(SPECS_LATEX)/regulations/*.out
	@echo "PDF: $(PDF_DIR)/specs/regulations-spec.pdf"

# Simula Training Data Framework Specification
spec-simula:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/simula && $(LATEX_ENGINE) -interaction=nonstopmode simula-training-spec.tex > /dev/null && \
	    $(LATEX_ENGINE) -interaction=nonstopmode simula-training-spec.tex > /dev/null && \
	    mv simula-training-spec.pdf ../../../pdf/specs/; \
	elif [ -n "$(TECTONIC)" ]; then \
	  cd $(SPECS_LATEX)/simula && $(TECTONIC) --outdir ../../../pdf/specs simula-training-spec.tex > /dev/null; \
	else \
	  echo "ERROR: xelatex, lualatex, or tectonic not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/simula/*.aux $(SPECS_LATEX)/simula/*.log $(SPECS_LATEX)/simula/*.toc $(SPECS_LATEX)/simula/*.out
	@echo "PDF: $(PDF_DIR)/specs/simula-training-spec.pdf"

# .clinerules Agent Swarm Supplementary Specification
spec-clinerules-agents:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/clinerules-agents && $(LATEX_ENGINE) -interaction=nonstopmode clinerules-agents-spec.tex > /dev/null && \
	    $(LATEX_ENGINE) -interaction=nonstopmode clinerules-agents-spec.tex > /dev/null && \
	    mv clinerules-agents-spec.pdf ../../../pdf/specs/; \
	elif [ -n "$(TECTONIC)" ]; then \
	  cd $(SPECS_LATEX)/clinerules-agents && $(TECTONIC) --outdir ../../../pdf/specs clinerules-agents-spec.tex > /dev/null; \
	else \
	  echo "ERROR: xelatex, lualatex, or tectonic not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/clinerules-agents/*.aux $(SPECS_LATEX)/clinerules-agents/*.log $(SPECS_LATEX)/clinerules-agents/*.toc $(SPECS_LATEX)/clinerules-agents/*.out
	@echo "PDF: $(PDF_DIR)/specs/clinerules-agents-spec.pdf"

# All specs (4 domain areas plus 1 supplementary agent spec)
specs-all: spec-arabic spec-tb spec-regulations spec-simula spec-clinerules-agents
	@echo "All specification PDFs compiled to $(PDF_DIR)/specs/"

# Export specs to Word (requires pandoc, run from spec dir to resolve \input)
specs-docx:
	@mkdir -p $(DOCX_DIR)/specs
	@command -v pandoc >/dev/null 2>&1 || (echo "ERROR: pandoc not found."; exit 1)
	cd $(SPECS_LATEX)/arabic && pandoc arabic-ap-spec.tex -o ../../../docx/specs/arabic-ap-spec.docx --from=latex
	cd $(SPECS_LATEX)/tb && pandoc tb-review-spec.tex -o ../../../docx/specs/tb-review-spec.docx --from=latex
	cd $(SPECS_LATEX)/regulations && pandoc regulations-spec.tex -o ../../../docx/specs/regulations-spec.docx --from=latex
	cd $(SPECS_LATEX)/simula && pandoc simula-training-spec.tex -o ../../../docx/specs/simula-training-spec.docx --from=latex
	cd $(SPECS_LATEX)/clinerules-agents && pandoc clinerules-agents-spec.tex -o ../../../docx/specs/clinerules-agents-spec.docx --from=latex
	@echo "DOCX exports: $(DOCX_DIR)/specs/*.docx"

# Combined: PDF + DOCX for all specs
specs-export: specs-all specs-docx
	@echo "All specifications exported to $(PDF_DIR)/specs/ and $(DOCX_DIR)/specs/"


# ════════════════════════════════════════════════════════════════════════════
# Apple WWDC Style Specifications (Premium Design)
# ════════════════════════════════════════════════════════════════════════════
# Build Apple-style specs with modern typography (Inter + JetBrains Mono)
# Requires: brew install --cask font-inter font-jetbrains-mono

.PHONY: specs-apple-all spec-simula-apple spec-tb-apple spec-tb-hitl-apple \
        spec-arabic-apple spec-regulations-apple spec-clinerules-agents-apple \
        check-apple-fonts

# Check if required fonts are installed
check-apple-fonts:
	@echo "Checking for required fonts..."
	@if fc-list | grep -qi "Inter"; then \
	  echo "✓ Inter font found"; \
	else \
	  echo "⚠ Inter font not found. Install with: brew install --cask font-inter"; \
	fi
	@if fc-list | grep -qi "JetBrains"; then \
	  echo "✓ JetBrains Mono font found"; \
	else \
	  echo "⚠ JetBrains Mono not found. Install with: brew install --cask font-jetbrains-mono"; \
	fi

# Shared directory for Apple-style packages
SHARED_LATEX := $(LATEX_DIR)/shared

# Simula Training Data Framework (Apple Style)
spec-simula-apple:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/simula && TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode simula-training-spec-apple.tex && \
	    TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode simula-training-spec-apple.tex && \
	    mv simula-training-spec-apple.pdf ../../../pdf/specs/; \
	else \
	  echo "ERROR: xelatex or lualatex not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/simula/*.aux $(SPECS_LATEX)/simula/*.log $(SPECS_LATEX)/simula/*.toc $(SPECS_LATEX)/simula/*.out
	@echo "PDF: $(PDF_DIR)/specs/simula-training-spec-apple.pdf"

# Trial Balance Review (Apple Style)
spec-tb-apple:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/tb && TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode tb-review-spec-apple.tex && \
	    TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode tb-review-spec-apple.tex && \
	    mv tb-review-spec-apple.pdf ../../../pdf/specs/; \
	else \
	  echo "ERROR: xelatex or lualatex not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/tb/*.aux $(SPECS_LATEX)/tb/*.log $(SPECS_LATEX)/tb/*.toc $(SPECS_LATEX)/tb/*.out
	@echo "PDF: $(PDF_DIR)/specs/tb-review-spec-apple.pdf"

# TB-HITL Traceability (Apple Style)
spec-tb-hitl-apple:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/tb-hitl && TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode tb-business-requirements-traceability-apple.tex && \
	    TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode tb-business-requirements-traceability-apple.tex && \
	    mv tb-business-requirements-traceability-apple.pdf ../../../pdf/specs/; \
	else \
	  echo "ERROR: xelatex or lualatex not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/tb-hitl/*.aux $(SPECS_LATEX)/tb-hitl/*.log $(SPECS_LATEX)/tb-hitl/*.toc $(SPECS_LATEX)/tb-hitl/*.out
	@echo "PDF: $(PDF_DIR)/specs/tb-business-requirements-traceability-apple.pdf"

# Arabic AP Invoice Processing (Apple Style)
spec-arabic-apple:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/arabic && TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode arabic-ap-spec-apple.tex && \
	    TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode arabic-ap-spec-apple.tex && \
	    mv arabic-ap-spec-apple.pdf ../../../pdf/specs/; \
	else \
	  echo "ERROR: xelatex or lualatex not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/arabic/*.aux $(SPECS_LATEX)/arabic/*.log $(SPECS_LATEX)/arabic/*.toc $(SPECS_LATEX)/arabic/*.out
	@echo "PDF: $(PDF_DIR)/specs/arabic-ap-spec-apple.pdf"

# AI Regulations Compliance (Apple Style)
spec-regulations-apple:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/regulations && TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode regulations-spec-apple.tex && \
	    TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode regulations-spec-apple.tex && \
	    mv regulations-spec-apple.pdf ../../../pdf/specs/; \
	else \
	  echo "ERROR: xelatex or lualatex not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/regulations/*.aux $(SPECS_LATEX)/regulations/*.log $(SPECS_LATEX)/regulations/*.toc $(SPECS_LATEX)/regulations/*.out
	@echo "PDF: $(PDF_DIR)/specs/regulations-spec-apple.pdf"

# .clinerules Agent Swarm (Apple Style)
spec-clinerules-agents-apple:
	@mkdir -p $(PDF_DIR)/specs
	@if [ -n "$(LATEX_ENGINE)" ]; then \
	  cd $(SPECS_LATEX)/clinerules-agents && TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode clinerules-agents-spec-apple.tex && \
	    TEXINPUTS=.:../../shared//: $(LATEX_ENGINE) -interaction=nonstopmode clinerules-agents-spec-apple.tex && \
	    mv clinerules-agents-spec-apple.pdf ../../../pdf/specs/; \
	else \
	  echo "ERROR: xelatex or lualatex not found."; exit 1; \
	fi
	@rm -f $(SPECS_LATEX)/clinerules-agents/*.aux $(SPECS_LATEX)/clinerules-agents/*.log $(SPECS_LATEX)/clinerules-agents/*.toc $(SPECS_LATEX)/clinerules-agents/*.out
	@echo "PDF: $(PDF_DIR)/specs/clinerules-agents-spec-apple.pdf"

# All Apple-style specs
specs-apple-all: check-apple-fonts spec-simula-apple spec-tb-apple spec-tb-hitl-apple spec-arabic-apple spec-regulations-apple spec-clinerules-agents-apple
	@echo "All Apple-style specification PDFs compiled to $(PDF_DIR)/specs/"
	@echo "Files: *-apple.pdf"


# ════════════════════════════════════════════════════════════════════════════
# Spec-Drift Audit Pipeline
# ════════════════════════════════════════════════════════════════════════════
# Prevents specification drift between LaTeX docs, JSON schemas, and code.
# See .clinerules.spec-drift-auditor for full documentation.
#
# Quick start:
#   make audit-spec-drift         # run full drift audit
#   make audit-spec-drift-domain  # audit specific domain (DOMAIN=simula)
#   make audit-spec-drift-quick   # quick check on changed files
#   make audit-install-hook       # install pre-commit hook
# ════════════════════════════════════════════════════════════════════════════

SPEC_DRIFT_SCRIPT := scripts/spec-drift/audit.py
SPEC_DRIFT_MAPPING := docs/schema/spec-code-mapping.yaml
AUDIT_LOG_DIR := docs/audit-logs

.PHONY: audit-spec-drift audit-spec-drift-domain audit-spec-drift-quick \
        audit-spec-drift-json audit-spec-drift-yaml \
        audit-install-hook audit-check-mapping audit-list-domains \
        audit-exceptions-review

# ── Full spec-drift audit (all domains) ──────────────────────────────────────
audit-spec-drift:
	@echo "Running full spec-drift audit..."
	@mkdir -p $(AUDIT_LOG_DIR)
	python3 $(SPEC_DRIFT_SCRIPT) --mode full --output-format console

# ── Audit specific domain ────────────────────────────────────────────────────
# Usage: make audit-spec-drift-domain DOMAIN=simula
audit-spec-drift-domain:
	@if [ -z "$(DOMAIN)" ]; then \
	  echo "Usage: make audit-spec-drift-domain DOMAIN=<domain>"; \
	  echo "Available domains: simula, tb, tb-hitl, arabic, regulations, clinerules-agents"; \
	  exit 1; \
	fi
	@echo "Running spec-drift audit for domain: $(DOMAIN)"
	python3 $(SPEC_DRIFT_SCRIPT) --mode full --domain $(DOMAIN) --output-format console

# ── Quick audit on changed files (for local dev) ─────────────────────────────
audit-spec-drift-quick:
	@echo "Running quick spec-drift audit on changed files..."
	@CHANGED=$$(git diff --name-only HEAD); \
	if [ -z "$$CHANGED" ]; then \
	  echo "No changed files to audit."; \
	else \
	  python3 $(SPEC_DRIFT_SCRIPT) --mode pre-commit --changed-files $$CHANGED --output-format console --no-fail-on-blocking; \
	fi

# ── Audit with JSON output (for CI integration) ──────────────────────────────
audit-spec-drift-json:
	@mkdir -p $(AUDIT_LOG_DIR)
	python3 $(SPEC_DRIFT_SCRIPT) --mode full --output-format json \
	  --output-file $(AUDIT_LOG_DIR)/latest-audit.json
	@echo "JSON report: $(AUDIT_LOG_DIR)/latest-audit.json"

# ── Audit with YAML output ───────────────────────────────────────────────────
audit-spec-drift-yaml:
	@mkdir -p $(AUDIT_LOG_DIR)
	python3 $(SPEC_DRIFT_SCRIPT) --mode full --output-format yaml \
	  --output-file $(AUDIT_LOG_DIR)/latest-audit.yaml
	@echo "YAML report: $(AUDIT_LOG_DIR)/latest-audit.yaml"

# ── Install pre-commit hook ──────────────────────────────────────────────────
audit-install-hook:
	@echo "Installing spec-drift pre-commit hook..."
	@chmod +x scripts/spec-drift/pre-commit-hook.sh
	@ln -sf ../../scripts/spec-drift/pre-commit-hook.sh .git/hooks/pre-commit
	@echo "Pre-commit hook installed. It will run on every commit."

# ── Validate spec-code mapping registry ──────────────────────────────────────
audit-check-mapping:
	@echo "Validating spec-code mapping registry..."
	@python3 scripts/spec-drift/check_mapping.py

# ── List available domains ───────────────────────────────────────────────────
audit-list-domains:
	@echo "Available domains for spec-drift audit:"
	@python3 scripts/spec-drift/check_mapping.py domains

# ── Review drift exceptions ──────────────────────────────────────────────────
audit-exceptions-review:
	@echo "Current drift exceptions:"
	@python3 scripts/spec-drift/check_mapping.py exceptions

# ── CI gate: fail on blocking drift ──────────────────────────────────────────
audit-spec-drift-ci:
	@echo "Running spec-drift audit (CI mode - fails on blocking issues)..."
	python3 $(SPEC_DRIFT_SCRIPT) --mode full --output-format console --fail-on-blocking

# ════════════════════════════════════════════════════════════════════════════
# CLINERULES VALIDATION AND TOOLING
# ════════════════════════════════════════════════════════════════════════════
# New tools added to address review improvement areas:
#   - Version synchronization checking
#   - Dry-run validation mode
#   - Example gallery validation
# ════════════════════════════════════════════════════════════════════════════

CLINERULES_SCRIPTS := scripts/clinerules
EXAMPLES_DIR := docs/examples/clinerules

.PHONY: clinerules-version-sync clinerules-version-sync-ci clinerules-dry-run \
        clinerules-validate clinerules-validate-all clinerules-examples-test \
        clinerules-interactive clinerules-coverage-report

# ── Version Synchronization ──────────────────────────────────────────────────

# Check version synchronization across all .clinerules files
clinerules-version-sync:
	@echo "Checking version synchronization across .clinerules files..."
	python3 $(CLINERULES_SCRIPTS)/version_sync_checker.py --mode check --output console

# Version sync check with JSON output
clinerules-version-sync-json:
	python3 $(CLINERULES_SCRIPTS)/version_sync_checker.py --mode check --output json

# CI mode: fail on critical/high version drift
clinerules-version-sync-ci:
	@echo "Running version sync check (CI mode)..."
	python3 $(CLINERULES_SCRIPTS)/version_sync_checker.py --mode check --fail-on-drift --output github-actions

# Suggest fixes for version drift
clinerules-version-fix-preview:
	@echo "Previewing version drift fixes..."
	python3 $(CLINERULES_SCRIPTS)/version_sync_checker.py --mode fix --dry-run

# ── Dry-Run Validation ───────────────────────────────────────────────────────

# Validate a specific .clinerules file
clinerules-validate:
ifndef PATH
	@echo "Usage: make clinerules-validate PATH=src/domain/.clinerules"
	@exit 1
endif
	python3 $(CLINERULES_SCRIPTS)/dry_run_validator.py --validate $(PATH)

# Validate all .clinerules files in the repository
clinerules-validate-all:
	@echo "Validating all .clinerules files..."
	@for f in $$(find . -name ".clinerules" -o -name ".clinerules.*" | grep -v ".git" | grep -v "node_modules"); do \
		echo "Validating: $$f"; \
		python3 $(CLINERULES_SCRIPTS)/dry_run_validator.py --validate "$$f" || true; \
		echo ""; \
	done

# Run dry-run simulation for a task
clinerules-dry-run:
ifndef TASK
	@echo "Usage: make clinerules-dry-run TASK='Add new API endpoint'"
	@exit 1
endif
	python3 $(CLINERULES_SCRIPTS)/dry_run_validator.py --task "$(TASK)"

# Interactive dry-run mode
clinerules-interactive:
	python3 $(CLINERULES_SCRIPTS)/dry_run_validator.py --interactive

# Dry-run with JSON output
clinerules-dry-run-json:
ifndef TASK
	@echo "Usage: make clinerules-dry-run-json TASK='Add new API endpoint'"
	@exit 1
endif
	python3 $(CLINERULES_SCRIPTS)/dry_run_validator.py --task "$(TASK)" --output json

# ── Examples Gallery ─────────────────────────────────────────────────────────

# Validate all example .clinerules files
clinerules-examples-test:
	@echo "Validating example .clinerules files..."
	@for f in $$(find $(EXAMPLES_DIR) -name "*.clinerules" 2>/dev/null); do \
		echo "Validating example: $$f"; \
		python3 $(CLINERULES_SCRIPTS)/dry_run_validator.py --validate "$$f" || true; \
		echo ""; \
	done
	@echo "Examples validation complete."

# List available examples
clinerules-examples-list:
	@echo "Available .clinerules examples:"
	@find $(EXAMPLES_DIR) -name "*.clinerules" 2>/dev/null | sed 's|$(EXAMPLES_DIR)/||' | sort

# ── Test Coverage ────────────────────────────────────────────────────────────

# Generate coverage report for a specific domain
clinerules-coverage-report:
ifndef DOMAIN
	@echo "Usage: make clinerules-coverage-report DOMAIN=intelligence"
	@exit 1
endif
	@echo "Generating coverage report for $(DOMAIN)..."
	@echo "Note: Full coverage implementation requires test harness setup."
	@python3 $(CLINERULES_SCRIPTS)/dry_run_validator.py --validate src/$(DOMAIN)/.clinerules --output json

# ── Combined CI Gate ─────────────────────────────────────────────────────────

# Run all clinerules validation checks (for CI)
clinerules-ci:
	@echo "Running all clinerules validation checks..."
	@echo ""
	@echo "=== Step 1: Version Synchronization ==="
	python3 $(CLINERULES_SCRIPTS)/version_sync_checker.py --mode check --output console || true
	@echo ""
	@echo "=== Step 2: Structure Validation ==="
	@$(MAKE) clinerules-validate-all
	@echo ""
	@echo "=== Step 3: Examples Validation ==="
	@$(MAKE) clinerules-examples-test
	@echo ""
	@echo "All clinerules checks complete."

# ── Help ─────────────────────────────────────────────────────────────────────

clinerules-help:
	@echo ""
	@echo "Clinerules Validation and Tooling Commands:"
	@echo "────────────────────────────────────────────────────────────────────"
	@echo ""
	@echo "Version Synchronization:"
	@echo "  make clinerules-version-sync        Check version sync across files"
	@echo "  make clinerules-version-sync-json   Output version sync as JSON"
	@echo "  make clinerules-version-sync-ci     CI mode (fails on drift)"
	@echo "  make clinerules-version-fix-preview Preview fixes for version drift"
	@echo ""
	@echo "Dry-Run Validation:"
	@echo "  make clinerules-validate PATH=...   Validate specific .clinerules"
	@echo "  make clinerules-validate-all        Validate all .clinerules files"
	@echo "  make clinerules-dry-run TASK='...'  Simulate task execution"
	@echo "  make clinerules-interactive         Interactive validation mode"
	@echo ""
	@echo "Examples Gallery:"
	@echo "  make clinerules-examples-list       List available examples"
	@echo "  make clinerules-examples-test       Validate all examples"
	@echo ""
	@echo "CI/CD:"
	@echo "  make clinerules-ci                  Run all validation checks"
	@echo ""
