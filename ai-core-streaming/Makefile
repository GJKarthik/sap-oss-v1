# bdc-pulsar-streaming Makefile
# Full Pulsar protocol implementation with SAP HANA storage

.PHONY: all build test clean install run-broker run-standalone docker docs mangle-gen

# Build configuration
ZIG ?= zig
MOJO ?= mojo
BUILD_MODE ?= Debug
TARGET_DIR := zig/zig-out

# Mangle configuration
MANGLE_DIR := mangle
MANGLE_GEN := zig/src/gen

all: build

# ============================================================================
# Build Commands
# ============================================================================

build: mangle-gen
	cd zig && $(ZIG) build -Doptimize=$(BUILD_MODE)

build-release:
	cd zig && $(ZIG) build -Doptimize=ReleaseFast

build-broker:
	cd zig && $(ZIG) build broker -Doptimize=$(BUILD_MODE)

build-client:
	cd zig && $(ZIG) build client -Doptimize=$(BUILD_MODE)

build-cli:
	cd zig && $(ZIG) build cli -Doptimize=$(BUILD_MODE)

# ============================================================================
# Test Commands
# ============================================================================

test: test-zig test-mojo

test-zig:
	cd zig && $(ZIG) build test

test-mojo:
	cd mojo && $(MOJO) test tests/

test-connectors:
	cd zig && $(ZIG) build test-connectors

test-protocol:
	cd zig && $(ZIG) build test-protocol

test-storage:
	cd zig && $(ZIG) build test-storage

test-integration:
	@echo "Running integration tests..."
	cd zig && $(ZIG) test src/tests/integration_tests.zig

test-main:
	@echo "Running main module tests..."
	cd zig && $(ZIG) test src/main.zig

# ============================================================================
# Run Commands
# ============================================================================

run-broker:
	cd zig && $(ZIG) build run-broker -- --config ../conf/broker.conf

run-standalone:
	cd zig && $(ZIG) build run-standalone -- --config ../conf/standalone.conf

run-proxy:
	cd zig && $(ZIG) build run-proxy -- --config ../conf/proxy.conf

# ============================================================================
# Code Generation
# ============================================================================

mangle-gen:
	@echo "Generating Zig types from Mangle definitions..."
	@mkdir -p $(MANGLE_GEN)
	cd zig && $(ZIG) build generate-types

# ============================================================================
# Docker Commands
# ============================================================================

docker:
	docker build -t bdc-pulsar-streaming:latest .

docker-push:
	docker push $(DOCKER_REGISTRY)/bdc-pulsar-streaming:latest

# ============================================================================
# Documentation
# ============================================================================

docs:
	@echo "Generating documentation..."
	cd docs && mdbook build

# ============================================================================
# Installation
# ============================================================================

install: build-release
	@echo "Installing bdc-pulsar-streaming..."
	install -m 755 $(TARGET_DIR)/bin/pulsar-broker /usr/local/bin/
	install -m 755 $(TARGET_DIR)/bin/pulsar-client /usr/local/bin/
	install -m 755 $(TARGET_DIR)/bin/pulsar-admin /usr/local/bin/

# ============================================================================
# Cleanup
# ============================================================================

clean:
	rm -rf zig/zig-out
	rm -rf zig/zig-cache
	rm -rf zig/.zig-cache
	rm -rf $(MANGLE_GEN)/*.zig
	rm -rf mojo/__pycache__
	rm -rf mojo/.mojo_cache

# ============================================================================
# Development Helpers
# ============================================================================

fmt:
	cd zig && $(ZIG) fmt src/
	cd mojo && $(MOJO) format src/

lint:
	@echo "Running linters..."
	cd zig && $(ZIG) build check

# ============================================================================
# Database Setup (SAP HANA)
# ============================================================================

db-init:
	@echo "Initializing SAP HANA schema..."
	hdbsql -U $(HANA_USER) -i $(HANA_INSTANCE) -d $(HANA_DATABASE) -I scripts/hana_schema.sql

db-migrate:
	@echo "Running database migrations..."
	hdbsql -U $(HANA_USER) -i $(HANA_INSTANCE) -d $(HANA_DATABASE) -I scripts/hana_migrate.sql