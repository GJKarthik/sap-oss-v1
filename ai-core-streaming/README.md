# BDC AI Prompt Streaming

Streaming AI prompt processing service with SAP HANA integration and XSUAA authentication.

## Features

- **Streaming Responses**: Server-Sent Events (SSE) for real-time AI responses
- **HANA Integration**: Direct connection to SAP HANA for context retrieval
- **XSUAA Authentication**: SAP BTP security integration
- **Schema Registry**: Dynamic schema validation
- **Horizontal Scaling**: Kubernetes HPA support

## Architecture

```
┌─────────────────────────────────────────────┐
│            HTTP Request (SSE)               │
└─────────────────┬───────────────────────────┘
                  │
┌─────────────────▼───────────────────────────┐
│           XSUAA Auth Middleware             │
└─────────────────┬───────────────────────────┘
                  │
┌─────────────────▼───────────────────────────┐
│           Schema Validation                  │
└─────────────────┬───────────────────────────┘
                  │
     ┌────────────┴────────────┐
     │                         │
┌────▼────┐             ┌──────▼──────┐
│  HANA   │             │  LLM API    │
│ Context │             │  (Stream)   │
└─────────┘             └─────────────┘
```

## Quick Start

```bash
# Build
cd zig && zig build -Doptimize=ReleaseFast

# Run tests
zig test src/auth/xsuaa.zig
zig test src/hana/hana_db.zig
zig test src/schema/registry.zig
zig test src/tests/integration_tests.zig
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/prompt` | Submit prompt for streaming response |
| GET | `/api/v1/prompt/{id}` | Get prompt status |
| GET | `/health` | Health check |
| GET | `/ready` | Readiness check |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8081 | Service port |
| `HANA_HOST` | - | SAP HANA hostname |
| `HANA_PORT` | 443 | SAP HANA port |
| `XSUAA_URL` | - | XSUAA service URL |
| `XSUAA_CLIENT_ID` | - | OAuth client ID |
| `LLM_ENDPOINT` | - | LLM API endpoint |

## Kubernetes Deployment

```bash
# Deploy with HPA
kubectl apply -f deploy/k8s/hpa.yaml
kubectl apply -f deploy/k8s/pdb.yaml