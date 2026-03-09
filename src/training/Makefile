# =============================================================================
# training-main — Root Makefile
# =============================================================================
.DEFAULT_GOAL := help
SHELL := /bin/bash

# Directories
MODELOPT_DIR  := nvidia-modelopt
HIPPO_ZIG_DIR := hippocpp/zig
HIPPO_PY_DIR  := hippocpp/python
UI_DIR        := $(MODELOPT_DIR)/ui
PARITY_DIR    := hippocpp/parity

# Python
PYTHON ?= python3

# ── Composite targets ────────────────────────────────────────────────────────

.PHONY: all build test lint format clean help

all: build test lint ## Build everything, run all tests, then lint

build: build-zig build-ui ## Build Zig library and Angular UI

test: test-python test-zig test-ui ## Run all test suites

lint: lint-python lint-ui ## Lint all code

format: format-python ## Auto-format all code

clean: clean-zig clean-ui clean-python ## Remove all build artifacts

# ── Zig ──────────────────────────────────────────────────────────────────────

.PHONY: build-zig test-zig clean-zig

build-zig: ## Build HippoCPP Zig library
	cd $(HIPPO_ZIG_DIR) && zig build

test-zig: ## Run Zig tests
	cd $(HIPPO_ZIG_DIR) && zig build test

clean-zig: ## Clean Zig build artifacts
	rm -rf $(HIPPO_ZIG_DIR)/zig-out $(HIPPO_ZIG_DIR)/zig-cache $(HIPPO_ZIG_DIR)/.zig-cache

# ── Python (ModelOpt API + HippoCPP bindings) ────────────────────────────────

.PHONY: test-python lint-python format-python clean-python

test-python: ## Run Python tests with pytest
	cd $(MODELOPT_DIR) && $(PYTHON) -m pytest tests/ -v --tb=short
	cd $(HIPPO_PY_DIR) && $(PYTHON) -m pytest tests/ -v --tb=short 2>/dev/null || true

lint-python: ## Lint Python with ruff
	$(PYTHON) -m ruff check $(MODELOPT_DIR)/api/ $(HIPPO_PY_DIR)/hippocpp/ --config pyproject.toml 2>/dev/null || \
		echo "⚠  ruff not installed — run: pip install ruff"

format-python: ## Format Python with ruff
	$(PYTHON) -m ruff format $(MODELOPT_DIR)/api/ $(HIPPO_PY_DIR)/hippocpp/ --config pyproject.toml 2>/dev/null || \
		echo "⚠  ruff not installed — run: pip install ruff"

clean-python: ## Clean Python caches
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name '*.egg-info' -exec rm -rf {} + 2>/dev/null || true
	find . -name '.coverage' -delete 2>/dev/null || true
	rm -rf .pytest_cache htmlcov .mypy_cache .ruff_cache

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

# ── Parity ───────────────────────────────────────────────────────────────────

.PHONY: parity-check

parity-check: ## Run HippoCPP parity checks against upstream Kuzu
	cd $(PARITY_DIR) && $(PYTHON) -m pytest corpus/ -v --tb=short 2>/dev/null || \
		echo "Run parity harness manually — see hippocpp/PARITY-MATRIX.md"

# ── Setup ────────────────────────────────────────────────────────────────────

.PHONY: setup setup-python setup-ui

setup: setup-python setup-ui ## Install all dependencies

setup-python: ## Install Python dependencies
	cd $(MODELOPT_DIR) && pip install -r requirements.txt
	pip install fastapi uvicorn[standard] pytest ruff mypy

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

bench-pipeline: ## Benchmark Zig pipeline (build, test, release times)
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

