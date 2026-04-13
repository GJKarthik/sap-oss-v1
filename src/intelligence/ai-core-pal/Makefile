# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
#
# SAP OSS ai-core-pal - Build and Deployment Makefile
#
# Usage:
#   make build         - Build Docker image
#   make push          - Push to registry
#   make deploy        - Deploy to Kyma
#   make test          - Run tests
#   make run           - Run locally
#

# Configuration
IMAGE_NAME := ai-core-pal
IMAGE_TAG := latest
REGISTRY := ghcr.io/gjkarthik
NAMESPACE := sap-ai-services
PORT := 8084

# Full image path
IMAGE := $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: all build push deploy run test clean help

all: build

# ============================================================================
# Docker Build & Push
# ============================================================================

## Build Docker image
build:
	@echo "Building $(IMAGE)..."
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE)
	@echo "Build complete: $(IMAGE)"

## Push to container registry
push: build
	@echo "Pushing $(IMAGE)..."
	docker push $(IMAGE)
	@echo "Push complete"

## Build and push in one command
release: push

# ============================================================================
# Local Development
# ============================================================================

## Install dependencies
install:
	pip install -r requirements.txt

## Run MCP server locally
run:
	python -m mcp_server.btp_pal_mcp_server

## Run with Docker
run-docker:
	docker run --rm -p $(PORT):$(PORT) --env-file .env $(IMAGE_NAME):$(IMAGE_TAG)

## Test HANA connection
test-hana:
	python -c "from agent.hana_client import test_connection; import json; print(json.dumps(test_connection(), indent=2))"

## Run all tests
test:
	pytest tests/ -v

## Run connection tests only
test-connection:
	pytest tests/test_hana_connection.py -v

## Run PAL algorithm tests
test-pal:
	pytest tests/test_pal_algorithms.py -v

## Run MCP server tests (requires running server)
test-mcp:
	pytest tests/test_mcp_server.py -v

# ============================================================================
# Kyma Deployment
# ============================================================================

## Deploy to Kyma cluster
deploy:
	@echo "Deploying to Kyma namespace $(NAMESPACE)..."
	kubectl apply -f deploy/kyma/ai-core-pal-deployment.yaml
	@echo "Waiting for pod to be ready..."
	kubectl wait --for=condition=ready pod -l app=ai-core-pal -n $(NAMESPACE) --timeout=120s
	@echo "Deployment complete"
	@$(MAKE) status

## Check deployment status
status:
	@echo "=== Deployment Status ==="
	kubectl get pods -n $(NAMESPACE) -l app=ai-core-pal
	@echo ""
	@echo "=== Service ==="
	kubectl get svc -n $(NAMESPACE) ai-core-pal
	@echo ""
	@echo "=== APIRule ==="
	kubectl get apirule -n $(NAMESPACE) ai-core-pal

## View logs
logs:
	kubectl logs -n $(NAMESPACE) ai-core-pal-0 -f

## Delete deployment
undeploy:
	kubectl delete -f deploy/kyma/ai-core-pal-deployment.yaml --ignore-not-found

## Restart pods
restart:
	kubectl rollout restart statefulset/ai-core-pal -n $(NAMESPACE)

## Port forward for local testing
port-forward:
	@echo "Forwarding port $(PORT) to ai-core-pal..."
	kubectl port-forward -n $(NAMESPACE) svc/ai-core-pal $(PORT):$(PORT)

# ============================================================================
# HANA Setup
# ============================================================================

## Show SQL scripts to run in HANA
show-sql:
	@echo "=== Step 1: Run in HANA Database Explorer ==="
	@echo ""
	@cat scripts/create_tables.sql
	@echo ""
	@echo "=== Step 2: Populate Data ==="
	@echo ""
	@cat scripts/populate_data.sql

# ============================================================================
# Utilities
# ============================================================================

## Health check (local)
health:
	curl -s http://localhost:$(PORT)/health | jq .

## Health check (Kyma)
health-kyma:
	@URL=$$(kubectl get apirule -n $(NAMESPACE) ai-core-pal -o jsonpath='{.spec.host}'); \
	echo "Checking https://$$URL/health"; \
	curl -s "https://$$URL/health" | jq .

## Clean up
clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE) 2>/dev/null || true
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true

## Show help
help:
	@echo "SAP OSS ai-core-pal - Build and Deployment"
	@echo ""
	@echo "Docker:"
	@echo "  make build        - Build Docker image"
	@echo "  make push         - Push to registry"
	@echo "  make release      - Build and push"
	@echo ""
	@echo "Local Development:"
	@echo "  make install      - Install dependencies"
	@echo "  make run          - Run MCP server locally"
	@echo "  make run-docker   - Run with Docker"
	@echo "  make test         - Run all tests"
	@echo "  make test-hana    - Test HANA connection"
	@echo ""
	@echo "Kyma Deployment:"
	@echo "  make deploy       - Deploy to Kyma"
	@echo "  make status       - Check deployment status"
	@echo "  make logs         - View pod logs"
	@echo "  make undeploy     - Delete deployment"
	@echo "  make port-forward - Forward port for testing"
	@echo ""
	@echo "Configuration:"
	@echo "  IMAGE:     $(IMAGE)"
	@echo "  NAMESPACE: $(NAMESPACE)"
	@echo "  PORT:      $(PORT)"