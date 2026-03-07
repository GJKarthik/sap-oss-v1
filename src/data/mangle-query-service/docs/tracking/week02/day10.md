# Day 10: Multi-Service Integration & Vocabulary Linking

**Date:** 2026-03-01  
**Focus:** Service separation and OData vocabulary integration

## Overview

Day 10 addresses the architectural requirement to run services separately while maintaining semantic integration through the OData vocabulary layer.

## Completed Work

### 1. Streaming Service Client (`connectors/streaming_client.py`)
- HTTP client connecting to `ai-core-streaming` Zig service
- Circuit breaker for resilience (5 failures → open)
- XSUAA token passthrough for SAP BTP authentication
- Streaming and non-streaming chat completions
- Pub/sub support for Pulsar integration

### 2. Service Router (`routing/service_router.py`)
- Routes between `AICORE_DIRECT` and `STREAMING_SERVICE` backends
- AUTO mode for intelligent backend selection
- Fallback on error to direct route
- Streaming request routing to Zig service

### 3. Vocabulary Client (`connectors/vocabulary_client.py`) 
- Connects to `odata-vocabularies-main` for semantic metadata
- Three deployment modes: LOCAL, SERVICE, ELASTICSEARCH
- Entity metadata lookup (ACDOCA, BKPF, KNA1, VBAK)
- Routing policy from `x-llm-policy` annotations
- Data security classification awareness

### 4. Docker Compose (`docker-compose.services.yml`)
- Multi-service deployment configuration
- mangle-query-service (Python :8080)
- ai-core-streaming (Zig :9000)
- Optional: Elasticsearch, Redis

## Architecture

```
                           Client
                             │
                             ↓
┌───────────────────────────────────────────────────────────────┐
│                  mangle-query-service:8080                     │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │              VocabularyClient                             │ │
│  │    ↓↓↓ odata-vocabularies-main (semantic metadata) ↓↓↓   │ │
│  │                                                          │ │
│  │  • EntityMetadata (ACDOCA, BKPF, etc.)                  │ │
│  │  • RoutingPolicy (x-llm-policy)                         │ │
│  │  • DataSecurityClass (confidential → vLLM)              │ │
│  └──────────────────────────────────────────────────────────┘ │
│                             │                                  │
│              ┌──────────────┴──────────────┐                   │
│              ↓                             ↓                   │
│      ServiceRouter                  VocabularyClient           │
│              │                        (policy check)           │
│  ┌───────────┴───────────┐                                    │
│  ↓                       ↓                                    │
│ AICORE_DIRECT     STREAMING_SERVICE                           │
└──────┬───────────────────┬────────────────────────────────────┘
       │                   │
       ↓                   ↓
  SAP AI Core     ai-core-streaming:9000 ──→ SAP AI Core
  (direct)             (Zig)
```

## Production Readiness Assessment

| Component | Status | Notes |
|-----------|--------|-------|
| `streaming_client.py` | ✅ Ready | Circuit breaker, token passthrough |
| `service_router.py` | ✅ Ready | Backend selection, fallback |
| `vocabulary_client.py` | ✅ Ready | 3 deployment modes, caching |
| `docker-compose.services.yml` | ✅ Ready | Health checks, networking |

### Integration Status

| Integration | Status | Mode |
|-------------|--------|------|
| mangle → ai-core-streaming | ✅ Linked | HTTP :9000 |
| mangle → odata-vocabularies | ✅ Linked | LOCAL (same repo) |
| mangle → SAP AI Core | ✅ Linked | Direct or via streaming |
| odata-vocab → routing | ✅ Linked | x-llm-policy rules |

## Key Files Created

```
mangle-query-service/
├── connectors/
│   ├── streaming_client.py    # ai-core-streaming HTTP client
│   └── vocabulary_client.py   # odata-vocabularies integration
├── routing/
│   └── service_router.py      # Backend selection logic
└── docker-compose.services.yml # Multi-service deployment
```

## Usage Examples

### 1. Get Entity Metadata from Vocabulary
```python
from connectors.vocabulary_client import get_vocabulary_client

client = await get_vocabulary_client()
metadata = await client.get_entity_metadata("ACDOCA")
print(metadata.data_security_class)  # "confidential"
print(metadata.routing_policy)        # "hybrid"
```

### 2. Route Based on Vocabulary Policy
```python
from routing.service_router import ServiceRouter

router = ServiceRouter()
# Checks vocabulary → ACDOCA is confidential → prefers vLLM
response = await router.route_completion(request)
```

### 3. Run Multi-Service Stack
```bash
docker-compose -f docker-compose.services.yml up

# Services:
# - mangle-query-service: http://localhost:8080
# - ai-core-streaming:    http://localhost:9000
```

## Environment Variables

```bash
# Streaming service
STREAMING_SERVICE_URL=http://ai-core-streaming:9000
STREAMING_SERVICE_ENABLED=true

# Vocabulary integration
VOCABULARY_DEPLOYMENT=local  # local | service | es
VOCABULARY_PATH=../odata-vocabularies-main

# Backend selection
DEFAULT_BACKEND=auto  # auto | aicore_direct | streaming
PREFER_STREAMING_SERVICE=true
```

## Next Steps (Day 11+)

1. Integration tests for multi-service flow
2. Load testing streaming vs direct performance
3. Vocabulary indexing in Elasticsearch
4. mTLS between services

## Commits

- `945690e41` - Multi-service integration (streaming_client, service_router, docker-compose)
- `b9a9890dd` - Vocabulary client for odata-vocabularies integration
- `a1c9f2621` - Sync changes to main