# =============================================================================
# Text-to-SQL Pipeline — Makefile (Python + SAP HANA Cloud)
#
# Orchestrates all stages of the data pipeline:
#   1. Pre-convert: Excel → CSV (Python)
#   2. Schema extraction (Python)
#   3. Template parsing (Python)
#   4. Template expansion + SQL generation (Python)
#   5. SQL validation (Python)
#   6. Spider/BIRD formatting (Python)
#   7. Upload to HANA Cloud (Python, optional)
# =============================================================================
.DEFAULT_GOAL := help
SHELL := /bin/bash

PYTHON ?= python3
PIPELINE := $(PYTHON) -m pipeline
DATA_DIR := ../data
CSV_DIR := output/intermediate/csv
SCHEMA_JSON := output/intermediate/schema.json
TEMPLATES_JSON := output/intermediate/templates.json
PAIRS_JSON := output/intermediate/pairs.json
SPIDER_DIR := output/spider

# ── Full pipeline ─────────────────────────────────────────────────────────────

.PHONY: all clean test help

all: preconvert extract-schema parse-templates expand format-spider ## Run the full pipeline
	@echo "✅ Pipeline complete — output in $(SPIDER_DIR)/"

# ── Stage 1: Excel → CSV ─────────────────────────────────────────────────────

.PHONY: preconvert
preconvert: ## Stage 1: Convert Excel files to CSV
	@echo "Stage 1: Pre-converting Excel → CSV …"
	@mkdir -p $(CSV_DIR)
	cd preconvert && $(PYTHON) excel_to_csv.py ../../$(DATA_DIR) ../../pipeline/$(CSV_DIR)

# ── Stage 2: Extract schema ──────────────────────────────────────────────────

.PHONY: extract-schema
extract-schema: ## Stage 2: Extract schema from staging CSVs (Python)
	@echo "Stage 2: Extracting schema …"
	@mkdir -p output/intermediate
	cd .. && $(PIPELINE) extract-schema pipeline/$(CSV_DIR)/staging.csv pipeline/$(SCHEMA_JSON)

# ── Stage 3: Parse templates ─────────────────────────────────────────────────

.PHONY: parse-templates
parse-templates: ## Stage 3: Parse prompt templates (Python)
	@echo "Stage 3: Parsing templates …"
	cd .. && $(PIPELINE) parse-templates pipeline/$(CSV_DIR)/templates.csv banking pipeline/$(TEMPLATES_JSON)

# ── Stage 4: Expand templates ────────────────────────────────────────────────

.PHONY: expand
expand: ## Stage 4: Expand templates into text-SQL pairs (Python)
	@echo "Stage 4: Expanding templates …"
	cd .. && $(PIPELINE) expand pipeline/$(CSV_DIR)/templates.csv pipeline/$(PAIRS_JSON) 500

# ── Stage 5: Validate SQL ────────────────────────────────────────────────────

.PHONY: validate
validate: ## Stage 5: Validate generated SQL pairs
	@echo "Stage 5: SQL validation …"
	cd .. && $(PYTHON) schema_pipeline/sql_validator.py pipeline/$(PAIRS_JSON)

# ── Stage 6: Format for Spider/BIRD ──────────────────────────────────────────

.PHONY: format-spider
format-spider: ## Stage 6: Format output as Spider/BIRD dataset (Python)
	@echo "Stage 6: Formatting for Spider/BIRD …"
	@mkdir -p $(SPIDER_DIR)
	cd .. && $(PIPELINE) format-spider pipeline/$(PAIRS_JSON) pipeline/$(SPIDER_DIR)

# ── Stage 7: Upload to HANA Cloud (optional) ─────────────────────────────────

.PHONY: upload
upload: ## Stage 7: Upload training pairs to HANA Cloud
	@echo "Stage 7: Uploading to HANA Cloud …"
	cd .. && $(PIPELINE) upload pipeline/$(PAIRS_JSON)

# ── Testing ──────────────────────────────────────────────────────────────────

test: test-preconvert test-pipeline ## Run all pipeline tests

.PHONY: test-preconvert test-pipeline
test-preconvert: ## Test Python pre-converter
	cd preconvert && $(PYTHON) -m pytest test_preconvert.py -v --tb=short

test-pipeline: ## Test Python pipeline modules
	cd .. && $(PYTHON) -m pytest pipeline/tests/ -v --tb=short

# ── Utilities ────────────────────────────────────────────────────────────────

clean: ## Remove all generated output
	rm -rf output/

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

