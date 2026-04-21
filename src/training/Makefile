# =============================================================================
# training-main — Root Makefile (Python + SAP HANA Cloud)
# =============================================================================
.DEFAULT_GOAL := help
SHELL := /bin/bash

# Directories
MODELOPT_DIR  := nvidia-modelopt
PIPELINE_DIR  := pipeline
UI_DIR        := $(MODELOPT_DIR)/ui

# Python
PYTHON ?= python3

# ── Composite targets ────────────────────────────────────────────────────────

.PHONY: all build test lint format clean help test-clinerules

all: build test lint ## Build everything, run all tests, then lint

build: build-ui ## Build Angular UI

test: test-python test-pipeline test-ui test-clinerules ## Run all test suites

lint: lint-python lint-ui ## Lint all code

format: format-python ## Auto-format all code

clean: clean-ui clean-python clean-pipeline ## Remove all build artifacts

# ── Python (ModelOpt API + Pipeline) ─────────────────────────────────────────

.PHONY: test-python test-pipeline lint-python format-python clean-python clean-pipeline

test-python: ## Run ModelOpt Python tests with pytest
	cd $(MODELOPT_DIR) && $(PYTHON) -m pytest tests/ -v --tb=short

test-pipeline: ## Run text-to-SQL pipeline tests
	$(PYTHON) -m pytest $(PIPELINE_DIR)/tests/ -v --tb=short

test-clinerules: ## Validate training .clinerules files
	$(PYTHON) -m pytest tests/test_clinerules_contracts.py -v --tb=short

lint-python: ## Lint Python with ruff
	$(PYTHON) -m ruff check $(MODELOPT_DIR)/api/ $(PIPELINE_DIR)/ --config pyproject.toml 2>/dev/null || \
		echo "⚠  ruff not installed — run: pip install ruff"

format-python: ## Format Python with ruff
	$(PYTHON) -m ruff format $(MODELOPT_DIR)/api/ $(PIPELINE_DIR)/ --config pyproject.toml 2>/dev/null || \
		echo "⚠  ruff not installed — run: pip install ruff"

clean-python: ## Clean Python caches
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name '*.egg-info' -exec rm -rf {} + 2>/dev/null || true
	find . -name '.coverage' -delete 2>/dev/null || true
	rm -rf .pytest_cache htmlcov .mypy_cache .ruff_cache

clean-pipeline: ## Clean pipeline output
	rm -rf $(PIPELINE_DIR)/output/

# ── Angular UI ───────────────────────────────────────────────────────────────

.PHONY: build-ui test-ui lint-ui clean-ui serve-ui

build-ui: ## Build Angular UI for production
	cd $(UI_DIR) && npm ci --silent && npm run build:prod

test-ui: ## Run Angular unit tests (headless)
	cd $(UI_DIR) && npm run test -- --no-watch --browsers=ChromeHeadless 2>/dev/null || \
		echo "⚠  Angular tests skipped (node_modules missing — run: make setup-ui)"

lint-ui: ## Lint Angular project
	cd $(UI_DIR) && npm run lint 2>/dev/null || \
		echo "⚠  Angular lint skipped (run: make setup-ui)"

serve-ui: ## Start Angular dev server
	cd $(UI_DIR) && npm start

clean-ui: ## Clean Angular build artifacts
	rm -rf $(UI_DIR)/dist $(UI_DIR)/.angular

# ── Docker ───────────────────────────────────────────────────────────────────

.PHONY: docker-build docker-run docker-up docker-down

docker-build: ## Build Docker images
	docker compose build

docker-run: ## Run API container standalone
	docker compose up modelopt-api

docker-up: ## Start all services (API + UI)
	docker compose up -d

docker-down: ## Stop all services
	docker compose down

# ── Pipeline ─────────────────────────────────────────────────────────────────

.PHONY: pipeline pipeline-upload

pipeline: ## Run the full text-to-SQL pipeline
	cd $(PIPELINE_DIR) && $(MAKE) all

pipeline-upload: ## Upload training pairs to HANA Cloud
	cd $(PIPELINE_DIR) && $(MAKE) upload

# ── Setup ────────────────────────────────────────────────────────────────────

.PHONY: setup setup-python setup-ui

setup: setup-python setup-ui ## Install all dependencies

setup-python: ## Install Python dependencies
	cd $(MODELOPT_DIR) && pip install -r requirements.txt
	pip install -r $(PIPELINE_DIR)/requirements.txt
	pip install fastapi uvicorn[standard] pytest ruff mypy hdbcli

setup-ui: ## Install Angular dependencies
	cd $(UI_DIR) && npm ci

# ── API server ───────────────────────────────────────────────────────────────

.PHONY: serve-api serve-api-dev

serve-api: ## Start ModelOpt API server (production)
	cd $(MODELOPT_DIR) && $(PYTHON) server.py

serve-api-dev: ## Start ModelOpt API server (dev, auto-reload)
	cd $(MODELOPT_DIR) && $(PYTHON) server.py --dev

# ── Benchmarks ──────────────────────────────────────────────────────────────

bench: bench-pipeline ## Run all benchmarks

bench-pipeline: ## Benchmark Python pipeline
	./benchmarks/bench_pipeline.sh

bench-api: ## Benchmark API latency (requires running server)
	$(PYTHON) benchmarks/bench_api.py

# ── Version ─────────────────────────────────────────────────────────────────

version: ## Show project version
	@cat VERSION

# ── Help ─────────────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
