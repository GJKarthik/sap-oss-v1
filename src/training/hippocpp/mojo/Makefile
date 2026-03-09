# =============================================================================
# HippoCPP Mojo — Makefile
# =============================================================================
.DEFAULT_GOAL := help
SHELL := /bin/bash

# Directories
SRC_DIR := src
BUILD_DIR := build
MOJO_FILES := catalog.🔥 common.🔥 expression.🔥 graph.🔥

# Mojo compiler
MOJO ?= mojo
MOJO_FLAGS ?= -O3

# ── Composite targets ────────────────────────────────────────────────────────

.PHONY: all build test fmt clean help

all: build test ## Build and run all tests

build: ## Compile the HippoCPP package
	@echo "Building HippoCPP Mojo package..."
	@mkdir -p $(BUILD_DIR)
	$(MOJO) build $(SRC_DIR)/hippocpp/__init__.mojo $(MOJO_FLAGS) -o $(BUILD_DIR)/hippocpp
	@echo "✓ Build complete"

test: ## Run all tests (executes main() from each .🔥 file)
	@echo "Running HippoCPP Mojo tests..."
	@for file in $(MOJO_FILES); do \
		echo "Testing $$file..."; \
		$(MOJO) run $$file || exit 1; \
	done
	@echo "✓ All tests passed"

fmt: ## Format all Mojo files
	@echo "Formatting Mojo files..."
	@for file in $(MOJO_FILES); do \
		echo "Formatting $$file..."; \
		$(MOJO) format $$file || true; \
	done
	@if [ -d "$(SRC_DIR)" ]; then \
		find $(SRC_DIR) -name "*.mojo" -exec $(MOJO) format {} \; || true; \
	fi
	@echo "✓ Formatting complete"

clean: ## Clean build artifacts
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR)
	@find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name .mojo -exec rm -rf {} + 2>/dev/null || true
	@echo "✓ Clean complete"

help: ## Show this help message
	@echo "HippoCPP Mojo — Build targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  MOJO       Mojo compiler command (default: mojo)"
	@echo "  MOJO_FLAGS Compiler flags (default: -O3)"
	@echo ""
	@echo "Examples:"
	@echo "  make build              # Compile the package"
	@echo "  make test               # Run all tests"
	@echo "  make fmt                # Format all Mojo files"
	@echo "  make clean              # Remove build artifacts"
	@echo "  make MOJO_FLAGS='-g'    # Build with debug symbols"

