# SAP AI Fabric - Deployment Guide

## Overview

This deployment guide provides a tiered approach to deploying the SAP AI Fabric microservices architecture. The deployment follows a dependency-aware order to ensure all services start correctly.

## Deployment Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TIER 0: INFRASTRUCTURE                               │
│                         (Must be deployed first)                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  SAP HANA Cloud (External/BTP)  │  SAP AI Core (External/BTP)  │  Redis         │
│  Port: 443                      │  OAuth + Deployments          │  Port: 6379    │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TIER 1: MCP SERVERS                                  │
│                         (Core services)                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  OData Vocabularies MCP  │  LangChain HANA MCP                               │
│  Port: 9150              │  Port: 9160                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TIER 2: INTELLIGENCE LAYER                           │
│                         (Requires MCP servers)                               │
├─────────────────────────────────────────────────────────────────────────────┤
│  AI-Core-PAL (Port: 9881)  │  vLLM Inference (Port: 8080)  │  Gen AI Toolkit │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TIER 3: TRAINING/MODELOPT                            │
│                         (Optional, offline)                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  ModelOpt API (Port: 8001)  │  ModelOpt UI (Port: 8082)                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
deploy/
├── README.md                    # This file
├── .env.example                 # Environment variable template
├── docker-compose.tier0.yml     # Infrastructure services
├── docker-compose.tier1.yml     # MCP servers
├── docker-compose.tier2.yml     # Intelligence layer
├── docker-compose.tier3.yml     # Training services
├── docker-compose.full.yml      # Complete stack deployment
├── scripts/
│   ├── deploy.sh               # Main deployment script
│   ├── health-check.sh         # Health verification script
│   ├── rollback.sh             # Rollback script
│   └── aicore-deploy.sh        # SAP AI Core deployment script
└── kubernetes/
    ├── namespace.yaml
    ├── configmaps/
    └── deployments/
```

## Quick Start

### Prerequisites

1. Docker and Docker Compose installed
2. Access to SAP HANA Cloud instance
3. SAP AI Core service binding credentials
4. (Optional) GPU for vLLM and ModelOpt services

### Step 1: Configure Environment

```bash
# Copy environment template
cp deploy/.env.example deploy/.env

# Edit with your credentials
vi deploy/.env
```

### Step 2: Deploy Infrastructure (Tier 0)

```bash
./deploy/scripts/deploy.sh tier0
# Or manually:
docker-compose -f deploy/docker-compose.tier0.yml up -d
```

### Step 3: Deploy MCP Servers (Tier 1)

```bash
./deploy/scripts/deploy.sh tier1
# Or manually:
docker-compose -f deploy/docker-compose.tier1.yml up -d
```

### Step 4: Deploy Intelligence Layer (Tier 2)

```bash
./deploy/scripts/deploy.sh tier2
# Or manually:
docker-compose -f deploy/docker-compose.tier2.yml up -d
```

### Step 5: Deploy Training Services (Tier 3 - Optional)

```bash
./deploy/scripts/deploy.sh tier3
# Or manually:
docker-compose -f deploy/docker-compose.tier3.yml up -d
```

### Full Stack Deployment

```bash
# Deploy all tiers at once (respects dependencies)
./deploy/scripts/deploy.sh all
```

## Health Checks

Verify each tier is running correctly:

```bash
./deploy/scripts/health-check.sh
```

Or check individual services:

| Service | Health Check URL |
|---------|------------------|
| OData Vocabularies | `curl http://localhost:9150/health` |
| LangChain HANA MCP | `curl http://localhost:9160/health` |
| vLLM | `curl http://localhost:8080/health` |
| AI-Core-PAL | `curl http://localhost:9881/health` |
| ModelOpt API | `curl http://localhost:8001/health` |

## Rollback

To rollback a specific tier:

```bash
./deploy/scripts/rollback.sh tier3  # Stop training services
./deploy/scripts/rollback.sh tier2  # Stop intelligence layer
./deploy/scripts/rollback.sh tier1  # Stop MCP servers
./deploy/scripts/rollback.sh tier0  # Stop infrastructure
./deploy/scripts/rollback.sh all    # Stop everything
```

## SAP AI Core Deployment

For production deployments to SAP AI Core:

```bash
./deploy/scripts/aicore-deploy.sh
```

This script will:
1. Build and push Docker images to your registry
2. Register AI Core scenarios
3. Create configurations
4. Deploy services

## Environment Variables

See `deploy/.env.example` for all required environment variables.

### Required for All Services

| Variable | Description |
|----------|-------------|
| `AICORE_CLIENT_ID` | SAP AI Core OAuth client ID |
| `AICORE_CLIENT_SECRET` | SAP AI Core OAuth client secret |
| `AICORE_AUTH_URL` | SAP AI Core authentication URL |
| `AICORE_BASE_URL` | SAP AI Core API base URL |
| `AICORE_RESOURCE_GROUP` | AI Core resource group (default: `default`) |

### HANA Cloud (for MCP servers)

| Variable | Description |
|----------|-------------|
| `HANA_HOST` | HANA Cloud hostname |
| `HANA_PORT` | HANA Cloud port (default: 443) |
| `HANA_USER` | HANA database user |
| `HANA_PASSWORD` | HANA database password |
| `HANA_SCHEMA` | HANA schema (default: `PAL_STORE`) |

## Troubleshooting

### Service Won't Start

1. Check logs: `docker-compose -f deploy/docker-compose.tierX.yml logs <service>`
2. Verify dependencies are running
3. Check environment variables are set correctly

### GPU Services Fail

1. Ensure NVIDIA Docker runtime is installed
2. Verify GPU drivers: `nvidia-smi`
3. Check CUDA compatibility

### Connection Refused Errors

1. Ensure services are on the same Docker network
2. Check port mappings
3. Verify firewall rules

## License

Apache 2.0 - See LICENSE file for details.