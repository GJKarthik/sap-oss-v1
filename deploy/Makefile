# ============================================================================
# SAP AI Fabric - Deployment Makefile
# ============================================================================
# Quick access to deployment commands
# Usage: make <target>
# ============================================================================

.PHONY: help init tier0 tier1 tier2 tier3 all health rollback clean status \
        build push aicore-deploy aicore-status logs

# Default target
help:
	@echo "╔═══════════════════════════════════════════════════════════════════╗"
	@echo "║           SAP AI Fabric - Deployment Commands                     ║"
	@echo "╚═══════════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "Initialization:"
	@echo "  make init          Copy .env.example to .env and create volumes"
	@echo ""
	@echo "Local Deployment (Docker Compose):"
	@echo "  make tier0         Deploy infrastructure (ES, Redis, Gateway)"
	@echo "  make tier1         Deploy MCP servers"
	@echo "  make tier2         Deploy intelligence layer (vLLM, AI-Core-PAL)"
	@echo "  make tier3         Deploy training services (ModelOpt)"
	@echo "  make all           Deploy all tiers"
	@echo "  make full          Deploy using full-stack compose file"
	@echo ""
	@echo "Management:"
	@echo "  make health        Check health of all services"
	@echo "  make health-watch  Continuously monitor service health"
	@echo "  make status        Show Docker container status"
	@echo "  make logs          Show logs for all services"
	@echo "  make logs-f        Follow logs for all services"
	@echo ""
	@echo "Rollback:"
	@echo "  make rollback-tier3   Stop tier 3 services"
	@echo "  make rollback-tier2   Stop tier 2 services"
	@echo "  make rollback-tier1   Stop tier 1 services"
	@echo "  make rollback-tier0   Stop tier 0 services"
	@echo "  make rollback-all     Stop all services"
	@echo "  make clean            Stop all and remove volumes (DANGER)"
	@echo ""
	@echo "SAP AI Core Deployment:"
	@echo "  make build         Build all Docker images"
	@echo "  make push          Push images to registry"
	@echo "  make aicore-deploy Deploy to SAP AI Core"
	@echo "  make aicore-status Check AI Core deployment status"
	@echo ""
	@echo "Options:"
	@echo "  BUILD=1            Build images before starting"
	@echo "  NO_CACHE=1         Build without cache"
	@echo ""
	@echo "Examples:"
	@echo "  make tier0 BUILD=1        # Build and deploy tier0"
	@echo "  make all NO_CACHE=1       # Full rebuild and deploy"

# ============================================================================
# Initialization
# ============================================================================

init:
	@echo "Initializing deployment environment..."
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env from .env.example"; \
		echo "Please edit .env with your configuration"; \
	else \
		echo ".env already exists"; \
	fi
	@mkdir -p volumes/es-data volumes/redis-data volumes/model-cache volumes/modelopt-outputs
	@echo "Volume directories created"

# ============================================================================
# Local Deployment
# ============================================================================

# Build flags
BUILD_FLAG := $(if $(BUILD),--build,)
NO_CACHE_FLAG := $(if $(NO_CACHE),--no-cache,)

tier0:
	./scripts/deploy.sh tier0 $(BUILD_FLAG) $(NO_CACHE_FLAG)

tier1:
	./scripts/deploy.sh tier1 $(BUILD_FLAG) $(NO_CACHE_FLAG)

tier2:
	./scripts/deploy.sh tier2 $(BUILD_FLAG) $(NO_CACHE_FLAG)

tier3:
	./scripts/deploy.sh tier3 $(BUILD_FLAG) $(NO_CACHE_FLAG)

all:
	./scripts/deploy.sh all $(BUILD_FLAG) $(NO_CACHE_FLAG)

full:
	@echo "Deploying full stack..."
	docker compose -f docker-compose.full.yml --env-file .env up -d $(BUILD_FLAG) $(NO_CACHE_FLAG)

# ============================================================================
# Health & Status
# ============================================================================

health:
	./scripts/health-check.sh

health-watch:
	./scripts/health-check.sh --watch

health-json:
	./scripts/health-check.sh --json

status:
	@echo "Docker Container Status:"
	@docker ps --filter "label=sap.ai.tier" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

logs:
	docker compose -f docker-compose.full.yml logs

logs-f:
	docker compose -f docker-compose.full.yml logs -f

logs-tier0:
	docker compose -f docker-compose.tier0.yml logs

logs-tier1:
	docker compose -f docker-compose.tier1.yml logs

logs-tier2:
	docker compose -f docker-compose.tier2.yml logs

logs-tier3:
	docker compose -f docker-compose.tier3.yml logs

# ============================================================================
# Rollback
# ============================================================================

rollback-tier3:
	./scripts/rollback.sh tier3

rollback-tier2:
	./scripts/rollback.sh tier2

rollback-tier1:
	./scripts/rollback.sh tier1

rollback-tier0:
	./scripts/rollback.sh tier0

rollback-all:
	./scripts/rollback.sh all

clean:
	@echo "WARNING: This will stop all services and remove volumes!"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ]
	./scripts/rollback.sh all --volumes --force

# ============================================================================
# SAP AI Core Deployment
# ============================================================================

build:
	./scripts/aicore-deploy.sh build

push:
	./scripts/aicore-deploy.sh push

aicore-register:
	./scripts/aicore-deploy.sh register

aicore-deploy:
	./scripts/aicore-deploy.sh deploy

aicore-status:
	./scripts/aicore-deploy.sh status

aicore-all:
	./scripts/aicore-deploy.sh all

# ============================================================================
# Development Helpers
# ============================================================================

# Start only infrastructure for local dev
dev-infra: tier0

# Prune unused resources
prune:
	docker system prune -f
	docker volume prune -f

# Show network info
network:
	docker network inspect sap-ai-fabric-network 2>/dev/null || echo "Network not created yet"

# ============================================================================
# Individual Service Management
# ============================================================================

start-redis:
	docker compose -f docker-compose.tier0.yml up -d redis

start-vllm:
	docker compose -f docker-compose.tier2.yml up -d vllm

stop-vllm:
	docker compose -f docker-compose.tier2.yml stop vllm

restart-vllm:
	docker compose -f docker-compose.tier2.yml restart vllm

# ============================================================================
# Validation
# ============================================================================

validate-env:
	@echo "Validating environment configuration..."
	@if [ ! -f .env ]; then echo "ERROR: .env file not found"; exit 1; fi
	@grep -q "AICORE_CLIENT_ID=" .env || echo "WARNING: AICORE_CLIENT_ID not set"
	@grep -q "HANA_HOST=" .env || echo "WARNING: HANA_HOST not set"
	@echo "Environment validation complete"

validate-compose:
	@echo "Validating Docker Compose files..."
	docker compose -f docker-compose.tier0.yml config --quiet
	docker compose -f docker-compose.tier1.yml config --quiet
	docker compose -f docker-compose.tier2.yml config --quiet
	docker compose -f docker-compose.tier3.yml config --quiet
	docker compose -f docker-compose.full.yml config --quiet
	@echo "All compose files are valid"