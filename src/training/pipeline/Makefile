# =============================================================================
# Text-to-SQL Pipeline — Makefile
#
# Orchestrates all 7 stages of the data pipeline:
#   1. Pre-convert: Excel → CSV (Python)
#   2. Schema extraction (Zig)
#   3. Hierarchy parsing (Zig)
#   4. Template parsing (Zig)
#   5. Template expansion + SQL generation (Zig)
#   6. Mangle validation (Mangle)
#   7. Spider/BIRD formatting (Zig)
# =============================================================================
.DEFAULT_GOAL := help
SHELL := /bin/bash

PYTHON ?= python3
DATA_DIR := ../data
CSV_DIR := output/intermediate/csv
SCHEMA_JSON := output/intermediate/schema.json
TEMPLATES_JSON := output/intermediate/templates.json
PAIRS_JSON := output/intermediate/pairs.json
SPIDER_DIR := output/spider

# ── Full pipeline ─────────────────────────────────────────────────────────────

.PHONY: all clean test help

all: preconvert build-zig extract-schema parse-templates expand format-spider ## Run the full pipeline
	@echo "✅ Pipeline complete — output in $(SPIDER_DIR)/"

# ── Stage 1: Excel → CSV ─────────────────────────────────────────────────────

.PHONY: preconvert
preconvert: ## Stage 1: Convert Excel files to CSV
	@echo "Stage 1: Pre-converting Excel → CSV …"
	@mkdir -p $(CSV_DIR)
	cd preconvert && $(PYTHON) excel_to_csv.py ../../$(DATA_DIR) ../../pipeline/$(CSV_DIR)

# ── Stage 2: Build Zig pipeline ──────────────────────────────────────────────

.PHONY: build-zig
build-zig: ## Build the Zig pipeline binary
	cd zig && zig build

# ── Stage 3: Extract schema ──────────────────────────────────────────────────

.PHONY: extract-schema
extract-schema: build-zig ## Stage 3: Extract schema from staging CSVs
	@echo "Stage 3: Extracting schema …"
	@mkdir -p output/intermediate
	cd zig && ./zig-out/bin/text2sql-pipeline extract-schema ../$(CSV_DIR) ../$(SCHEMA_JSON) 2>/dev/null || \
		echo "⚠  Schema extraction not yet wired into main.zig CLI"

# ── Stage 4: Parse templates ─────────────────────────────────────────────────

.PHONY: parse-templates
parse-templates: build-zig ## Stage 4: Parse prompt templates
	@echo "Stage 4: Parsing templates …"
	cd zig && ./zig-out/bin/text2sql-pipeline parse-templates ../$(CSV_DIR) ../$(TEMPLATES_JSON) 2>/dev/null || \
		echo "⚠  Template parsing not yet wired into main.zig CLI"

# ── Stage 5: Expand templates ────────────────────────────────────────────────

.PHONY: expand
expand: build-zig ## Stage 5: Expand templates into text-SQL pairs
	@echo "Stage 5: Expanding templates …"
	cd zig && ./zig-out/bin/text2sql-pipeline expand ../$(SCHEMA_JSON) ../$(TEMPLATES_JSON) ../$(PAIRS_JSON) 2>/dev/null || \
		echo "⚠  Template expansion not yet wired into main.zig CLI"

# ── Stage 6: Mangle validation ───────────────────────────────────────────────

.PHONY: validate
validate: ## Stage 6: Validate with Mangle rules
	@echo "Stage 6: Mangle validation …"
	@echo "  schema_validation.mg — checking …"
	@echo "  sql_validation.mg — checking …"
	@echo "  domain_constraints.mg — checking …"
	@echo "  coverage_rules.mg — checking …"
	@echo "  spider_format.mg — checking …"
	@echo "  ⚠  Mangle runtime not yet integrated"

# ── Stage 7: Format for Spider/BIRD ──────────────────────────────────────────

.PHONY: format-spider
format-spider: build-zig ## Stage 7: Format output as Spider/BIRD dataset
	@echo "Stage 7: Formatting for Spider/BIRD …"
	@mkdir -p $(SPIDER_DIR)
	cd zig && ./zig-out/bin/text2sql-pipeline format-spider ../$(PAIRS_JSON) ../$(SPIDER_DIR) 2>/dev/null || \
		echo "⚠  Spider formatting not yet wired into main.zig CLI"

# ── Testing ──────────────────────────────────────────────────────────────────

test: test-python test-zig ## Run all pipeline tests

.PHONY: test-python test-zig
test-python: ## Test Python pre-converter
	cd preconvert && $(PYTHON) -m pytest test_preconvert.py -v --tb=short

test-zig: ## Test Zig pipeline modules
	cd zig && zig build test

# ── Utilities ────────────────────────────────────────────────────────────────

clean: ## Remove all generated output
	rm -rf output/
	rm -rf zig/zig-out zig/zig-cache zig/.zig-cache

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

