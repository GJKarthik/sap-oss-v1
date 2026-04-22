# =============================================================================
# SAP-OSS LaTeX Specs — Build Pipeline
# =============================================================================
# Targets:
#   make diagrams         Render every *.mmd under specs/*/diagrams/ to PDF
#   make pdf              Build both simula and clinerules-agents PDFs
#   make pdf-simula       Build simula PDF only (xelatex + biber + xelatex x2)
#   make pdf-clinerules   Build clinerules-agents PDF only
#   make docx             Convert both specs to DOCX via pandoc
#   make all              diagrams + pdf + docx
#   make clean            Remove auxiliary artefacts (.aux .toc .out .log .bbl .blg)
#   make distclean        clean + remove generated PDFs/DOCX (keeps .mmd sources)
#
# Requirements:
#   xelatex, biber (TeX Live), pandoc 3+, npx (Node 18+). mermaid-cli is
#   fetched on demand via `npx -y @mermaid-js/mermaid-cli`.
# =============================================================================

SHELL          := /bin/bash
ROOT           := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
SPECS_DIR      := $(ROOT)specs
SHARED_DIR     := $(ROOT)shared
MERMAID_THEME  := $(SHARED_DIR)/mermaid-theme.json

MMDC           := npx -y @mermaid-js/mermaid-cli
# -b transparent keeps the PDF page transparent so Apple-style page colour shows
# through; -s 2 renders at 2x for crisp raster output.
MMDC_FLAGS     := -c $(MERMAID_THEME) -b transparent -f
MMDC_PNG_FLAGS := -c $(MERMAID_THEME) -b white -s 2

XELATEX        := xelatex -interaction=nonstopmode -halt-on-error
BIBER          := biber
PANDOC         := pandoc

# -----------------------------------------------------------------------------
# Diagram targets
# -----------------------------------------------------------------------------
MMD_SOURCES    := $(shell find $(SPECS_DIR) $(SHARED_DIR) -name '*.mmd' 2>/dev/null)
MMD_PDFS       := $(MMD_SOURCES:.mmd=.pdf)
MMD_PNGS       := $(MMD_SOURCES:.mmd=.png)

.PHONY: diagrams diagrams-pdf diagrams-png
# `make diagrams' produces BOTH .pdf (for LaTeX/xelatex) and .png (for
# DOCX/pandoc, since Word cannot render PDF inline).
diagrams: diagrams-pdf diagrams-png
diagrams-pdf: $(MMD_PDFS)
diagrams-png: $(MMD_PNGS)

%.pdf: %.mmd $(MERMAID_THEME)
	@echo "[mmdc pdf] $<"
	@$(MMDC) $(MMDC_FLAGS) -i $< -o $@

%.png: %.mmd $(MERMAID_THEME)
	@echo "[mmdc png] $<"
	@$(MMDC) $(MMDC_PNG_FLAGS) -i $< -o $@

# -----------------------------------------------------------------------------
# PDF targets
# -----------------------------------------------------------------------------
SIMULA_DIR     := $(SPECS_DIR)/simula
SIMULA_TEX     := simula-training-spec-apple.tex
SIMULA_PDF     := $(SIMULA_DIR)/simula-training-spec-apple.pdf

CLINE_DIR      := $(SPECS_DIR)/clinerules-agents
CLINE_TEX      := clinerules-agents-spec-apple.tex
CLINE_PDF      := $(CLINE_DIR)/clinerules-agents-spec-apple.pdf

REG_DIR        := $(SPECS_DIR)/regulations
REG_TEX        := regulations-spec-apple.tex
REG_PDF        := $(REG_DIR)/regulations-spec-apple.pdf

SGSAFETY_DIR   := $(SPECS_DIR)/singapore-ai-safety
SGSAFETY_TEX   := singapore-ai-safety-spec-apple.tex
SGSAFETY_PDF   := $(SGSAFETY_DIR)/singapore-ai-safety-spec-apple.pdf

IPTRACE_DIR    := $(SPECS_DIR)/ip-traceability
IPTRACE_TEX    := ip-traceability-spec-apple.tex
IPTRACE_PDF    := $(IPTRACE_DIR)/ip-traceability-spec-apple.pdf

.PHONY: pdf pdf-simula pdf-clinerules pdf-regulations pdf-sgsafety pdf-iptrace
pdf: pdf-simula pdf-clinerules pdf-regulations pdf-sgsafety pdf-iptrace

pdf-simula: diagrams
	@echo "[xelatex] simula (pass 1)"
	@cd $(SIMULA_DIR) && $(XELATEX) $(SIMULA_TEX) > /dev/null
	@echo "[biber] simula"
	@cd $(SIMULA_DIR) && $(BIBER) $(basename $(SIMULA_TEX)) > /dev/null || true
	@echo "[xelatex] simula (pass 2)"
	@cd $(SIMULA_DIR) && $(XELATEX) $(SIMULA_TEX) > /dev/null
	@echo "[xelatex] simula (pass 3)"
	@cd $(SIMULA_DIR) && $(XELATEX) $(SIMULA_TEX) > /dev/null
	@echo "[ok]     $(SIMULA_PDF)"

pdf-clinerules: diagrams
	@echo "[xelatex] clinerules (pass 1)"
	@cd $(CLINE_DIR) && $(XELATEX) $(CLINE_TEX) > /dev/null
	@echo "[xelatex] clinerules (pass 2)"
	@cd $(CLINE_DIR) && $(XELATEX) $(CLINE_TEX) > /dev/null
	@echo "[ok]     $(CLINE_PDF)"

pdf-regulations: diagrams
	@echo "[xelatex] regulations (pass 1)"
	@cd $(REG_DIR) && $(XELATEX) $(REG_TEX) > /dev/null
	@echo "[xelatex] regulations (pass 2)"
	@cd $(REG_DIR) && $(XELATEX) $(REG_TEX) > /dev/null
	@echo "[xelatex] regulations (pass 3)"
	@cd $(REG_DIR) && $(XELATEX) $(REG_TEX) > /dev/null
	@echo "[ok]     $(REG_PDF)"

pdf-sgsafety: diagrams
	@echo "[xelatex] singapore-ai-safety (pass 1)"
	@cd $(SGSAFETY_DIR) && $(XELATEX) $(SGSAFETY_TEX) > /dev/null
	@echo "[xelatex] singapore-ai-safety (pass 2)"
	@cd $(SGSAFETY_DIR) && $(XELATEX) $(SGSAFETY_TEX) > /dev/null
	@echo "[xelatex] singapore-ai-safety (pass 3)"
	@cd $(SGSAFETY_DIR) && $(XELATEX) $(SGSAFETY_TEX) > /dev/null
	@echo "[ok]     $(SGSAFETY_PDF)"

pdf-iptrace: diagrams
	@echo "[xelatex] ip-traceability (pass 1)"
	@cd $(IPTRACE_DIR) && $(XELATEX) $(IPTRACE_TEX) > /dev/null
	@echo "[xelatex] ip-traceability (pass 2)"
	@cd $(IPTRACE_DIR) && $(XELATEX) $(IPTRACE_TEX) > /dev/null
	@echo "[xelatex] ip-traceability (pass 3)"
	@cd $(IPTRACE_DIR) && $(XELATEX) $(IPTRACE_TEX) > /dev/null
	@echo "[ok]     $(IPTRACE_PDF)"

# -----------------------------------------------------------------------------
# DOCX targets
# -----------------------------------------------------------------------------
.PHONY: docx docx-simula docx-clinerules docx-regulations docx-sgsafety docx-iptrace
docx: docx-simula docx-clinerules docx-regulations docx-sgsafety docx-iptrace

# The DOCX build needs three transformations that LaTeX/pandoc would
# otherwise differ on:
#
#   1. Swap `.pdf' -> `.png' in \includegraphics{...} (Word can't render PDF).
#   2. Expand \mermaidfig{...}{cap}{lbl} -> raw \begin{figure}...\end{figure}
#      because pandoc doesn't load our .cls file and silently skips unknown
#      commands (dropping every Mermaid figure from the DOCX otherwise).
#   3. Do the work in a throw-away tempdir mirroring the spec tree so the
#      source files on disk are not modified.
#
# The pandoc `--include-in-header' trick alone is not enough: pandoc's LaTeX
# reader treats `\includegraphics' specially *only* when it sees it in the
# body, not when it appears inside a user-defined command expansion. So we
# pre-expand \mermaidfig with perl slurp-mode regex before invoking pandoc.
EXPAND_MERMAID := perl $(ROOT)scripts/expand-mermaidfig.pl

docx-simula: diagrams-png
	@echo "[pandoc] simula (PNG diagrams via tempdir)"
	@set -e; TMP=$$(mktemp -d); \
	rsync -a --exclude='*.aux' --exclude='*.log' --exclude='*.toc' --exclude='*.out' \
	      --exclude='*.bbl' --exclude='*.blg' --exclude='*.bcf' --exclude='*.run.xml' \
	      --exclude='*.docx' \
	      $(SPECS_DIR)/ $$TMP/specs/; \
	rsync -a $(SHARED_DIR)/ $$TMP/shared/; \
	find $$TMP -name '*.tex' -print0 | xargs -0 $(EXPAND_MERMAID); \
	find $$TMP -name '*.tex' -exec sed -i.bak -E \
	  's|(\\includegraphics(\[[^]]*\])?\{[^}]*)\.pdf\}|\1.png}|g' {} +; \
	find $$TMP -name '*.bak' -delete; \
	cd $$TMP/specs/simula && $(PANDOC) $(SIMULA_TEX) -f latex -t docx \
		--toc --toc-depth=3 --bibliography=references.bib \
		-o $(SIMULA_DIR)/simula-training-spec-apple.docx; \
	rm -rf $$TMP
	@echo "[ok]     $(SIMULA_DIR)/simula-training-spec-apple.docx"

docx-clinerules: diagrams-png
	@echo "[pandoc] clinerules (PNG diagrams via tempdir)"
	@set -e; TMP=$$(mktemp -d); \
	rsync -a --exclude='*.aux' --exclude='*.log' --exclude='*.toc' --exclude='*.out' \
	      --exclude='*.docx' \
	      $(SPECS_DIR)/ $$TMP/specs/; \
	rsync -a $(SHARED_DIR)/ $$TMP/shared/; \
	find $$TMP -name '*.tex' -print0 | xargs -0 $(EXPAND_MERMAID); \
	find $$TMP -name '*.tex' -exec sed -i.bak -E \
	  's|(\\includegraphics(\[[^]]*\])?\{[^}]*)\.pdf\}|\1.png}|g' {} +; \
	find $$TMP -name '*.bak' -delete; \
	cd $$TMP/specs/clinerules-agents && $(PANDOC) $(CLINE_TEX) -f latex -t docx \
		--toc --toc-depth=3 \
		-o $(CLINE_DIR)/clinerules-agents-spec-apple.docx; \
	rm -rf $$TMP
	@echo "[ok]     $(CLINE_DIR)/clinerules-agents-spec-apple.docx"

docx-regulations: diagrams-png
	@echo "[pandoc] regulations (PNG diagrams via tempdir)"
	@set -e; TMP=$$(mktemp -d); \
	rsync -a --exclude='*.aux' --exclude='*.log' --exclude='*.toc' --exclude='*.out' \
	      --exclude='*.docx' \
	      $(SPECS_DIR)/ $$TMP/specs/; \
	rsync -a $(SHARED_DIR)/ $$TMP/shared/; \
	find $$TMP -name '*.tex' -print0 | xargs -0 $(EXPAND_MERMAID); \
	find $$TMP -name '*.tex' -exec sed -i.bak -E \
	  's|(\\includegraphics(\[[^]]*\])?\{[^}]*)\.pdf\}|\1.png}|g' {} +; \
	find $$TMP -name '*.bak' -delete; \
	cd $$TMP/specs/regulations && $(PANDOC) $(REG_TEX) -f latex -t docx \
		--toc --toc-depth=3 \
		-o $(REG_DIR)/regulations-spec-apple.docx; \
	rm -rf $$TMP
	@echo "[ok]     $(REG_DIR)/regulations-spec-apple.docx"

docx-sgsafety: diagrams-png
	@echo "[pandoc] singapore-ai-safety (PNG diagrams via tempdir)"
	@set -e; TMP=$$(mktemp -d); \
	rsync -a --exclude='*.aux' --exclude='*.log' --exclude='*.toc' --exclude='*.out' \
	      --exclude='*.docx' \
	      $(SPECS_DIR)/ $$TMP/specs/; \
	rsync -a $(SHARED_DIR)/ $$TMP/shared/; \
	find $$TMP -name '*.tex' -print0 | xargs -0 $(EXPAND_MERMAID); \
	find $$TMP -name '*.tex' -exec sed -i.bak -E \
	  's|(\\includegraphics(\[[^]]*\])?\{[^}]*)\.pdf\}|\1.png}|g' {} +; \
	find $$TMP -name '*.bak' -delete; \
	cd $$TMP/specs/singapore-ai-safety && $(PANDOC) $(SGSAFETY_TEX) -f latex -t docx \
		--toc --toc-depth=3 \
		-o $(SGSAFETY_DIR)/singapore-ai-safety-spec-apple.docx; \
	rm -rf $$TMP
	@echo "[ok]     $(SGSAFETY_DIR)/singapore-ai-safety-spec-apple.docx"

docx-iptrace: diagrams-png
	@echo "[pandoc] ip-traceability (PNG diagrams via tempdir)"
	@set -e; TMP=$$(mktemp -d); \
	rsync -a --exclude='*.aux' --exclude='*.log' --exclude='*.toc' --exclude='*.out' \
	      --exclude='*.docx' \
	      $(SPECS_DIR)/ $$TMP/specs/; \
	rsync -a $(SHARED_DIR)/ $$TMP/shared/; \
	find $$TMP -name '*.tex' -print0 | xargs -0 $(EXPAND_MERMAID); \
	find $$TMP -name '*.tex' -exec sed -i.bak -E \
	  's|(\\includegraphics(\[[^]]*\])?\{[^}]*)\.pdf\}|\1.png}|g' {} +; \
	find $$TMP -name '*.bak' -delete; \
	cd $$TMP/specs/ip-traceability && $(PANDOC) $(IPTRACE_TEX) -f latex -t docx \
		--toc --toc-depth=3 \
		-o $(IPTRACE_DIR)/ip-traceability-spec-apple.docx; \
	rm -rf $$TMP
	@echo "[ok]     $(IPTRACE_DIR)/ip-traceability-spec-apple.docx"

# -----------------------------------------------------------------------------
# Aggregate + housekeeping
# -----------------------------------------------------------------------------
.PHONY: all clean distclean
all: diagrams pdf docx

clean:
	@find $(SPECS_DIR) -type f \( \
		-name '*.aux' -o -name '*.toc' -o -name '*.out' -o -name '*.log' \
		-o -name '*.bbl' -o -name '*.blg' -o -name '*.bcf' -o -name '*.run.xml' \
		-o -name '*.lof' -o -name '*.lot' -o -name '*.idx' -o -name '*.ilg' \
		-o -name '*.ind' -o -name '*.synctex.gz' \) -delete
	@echo "[clean] removed LaTeX aux artefacts"

distclean: clean
	@find $(SPECS_DIR) -type f \( -name '*-apple.pdf' -o -name '*-apple.docx' \) -delete
	@echo "[distclean] removed generated PDFs and DOCX"
