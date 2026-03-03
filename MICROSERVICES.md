# Microservice Architecture

This project follows a microservice architecture integrating model optimization, data quality, and schema services.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     API Gateway (nginx:8000)                         │
│  /api/models → model-optimizer | /api/copilot → data-copilot        │
│  /api/odata → odata-service   | /api/services → discovery           │
└─────────────────────────────────────────────────────────────────────┘
                                    │
         ┌──────────────────────────┼──────────────────────────┐
         ▼                          ▼                          ▼
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│ model-optimizer │      │   data-copilot  │      │  odata-service  │
│    :8001        │      │     :8002       │      │     :8003       │
│                 │      │                 │      │                 │
│ - Quantization  │      │ - AI Checks     │      │ - Vocab Parser  │
│ - Pruning       │ ◄──► │ - Schema Scan   │ ◄──► │ - UI Hints      │
│ - T4 GPU        │      │ - Quality Rules │      │ - Validation    │
└─────────────────┘      └─────────────────┘      └─────────────────┘
         │
         ▼
┌─────────────────┐
│  optimizer-ui   │
│    :4200        │
│ Angular + UI5   │
└─────────────────┘
```

## Microservices

### 1. Model Optimizer Service (`:8001`)
**Location:** `nvidia-modelopt/`

T4 GPU model quantization and optimization.

```bash
# Run standalone
cd nvidia-modelopt
./setup.sh
source venv/bin/activate
uvicorn api.main:app --port 8001

# API Endpoints
GET  /health              # Health check
GET  /models/catalog      # List available models
GET  /models/quant-formats # T4 supported formats
POST /jobs                # Create optimization job
GET  /jobs                # List jobs
GET  /jobs/{id}           # Get job status
GET  /gpu/status          # GPU info
```

### 2. Data Copilot Service (`:8002`)
**Location:** `data-cleaning-copilot-main/`

AI-powered data quality check generation.

```bash
# Run standalone
cd data-cleaning-copilot-main
uv sync
uv run python -m bin.copilot -d rel-stack

# API Endpoints
GET  /health              # Health check
GET  /databases           # Supported databases
POST /checks/generate     # Generate quality checks
GET  /checks/sessions     # List sessions
GET  /agent/versions      # Available agents
POST /schema/analyze      # Analyze schema
```

### 3. OData Service (`:8003`)
**Location:** `odata-vocabularies-main/`

SAP OData vocabulary parsing and semantic hints.

```bash
# Run standalone
cd odata-vocabularies-main
python connectors/python/parser.py

# API Endpoints
GET  /health              # Health check
GET  /vocabularies        # List vocabularies
GET  /vocabularies/{name} # Get vocabulary details
GET  /ui-terms            # UI annotation terms
GET  /validation-terms    # Validation terms
```

### 4. Optimizer UI (`:4200`)
**Location:** `optimizer-ui/`

Angular UI with SAP UI5 Web Components.

```bash
# Development
cd optimizer-ui
npm install
npm start

# Production build
npm run build
```

## Quick Start

### Docker Compose (Recommended)

```bash
# Start all services
docker-compose up -d

# Start specific service
docker-compose up model-optimizer -d

# View logs
docker-compose logs -f model-optimizer

# Stop all
docker-compose down
```

### Environment Variables

Create `.env` file:
```bash
# SAP AI Core (for data-copilot)
AICORE_AUTH_URL=https://...
AICORE_BASE_URL=https://...
AICORE_CLIENT_ID=...
AICORE_CLIENT_SECRET=...
AICORE_RESOURCE_GROUP=...
```

## Service Communication

Services communicate via REST APIs through the API Gateway:

| From | To | Purpose |
|------|-----|---------|
| data-copilot | model-optimizer | Use quantized models for inference |
| data-copilot | odata-service | Get schema semantic hints |
| optimizer-ui | all services | Frontend integration |

## Ports Summary

| Service | Port | Protocol |
|---------|------|----------|
| API Gateway | 8000 | HTTP |
| Model Optimizer | 8001 | HTTP |
| Data Copilot | 8002 | HTTP |
| OData Service | 8003 | HTTP |
| Optimizer UI | 4200 | HTTP |

## Development

### Adding a New Microservice

1. Create service directory with:
   - `api/main.py` - FastAPI application
   - `Dockerfile` - Container definition
   - `requirements.txt` - Dependencies

2. Add to `docker-compose.yml`:
   ```yaml
   new-service:
     build: ./new-service
     ports:
       - "800X:800X"
     networks:
       - platform-network
   ```

3. Add routes to `nginx.conf`:
   ```nginx
   location /api/new-service {
       proxy_pass http://new-service:800X;
   }
   ```

### Health Checks

All services expose `/health` endpoint:
```bash
curl http://localhost:8000/health  # Gateway
curl http://localhost:8001/health  # Model Optimizer
curl http://localhost:8002/health  # Data Copilot
curl http://localhost:8003/health  # OData Service
```

## Integration with Existing Projects

This architecture integrates with:

- **nvidia-modelopt** - Model quantization scripts
- **data-cleaning-copilot-main** - AI check generation
- **odata-vocabularies-main** - Schema parsing
- **ui5-webcomponents-ngx-main** - UI component patterns