# SAP OSS ai-core-pal

MCP Server for SAP HANA PAL (Predictive Analysis Library) algorithms with SAP BTP Kyma deployment.

## Features

- **7 MCP Tools** for PAL algorithms
- **SAP HANA Cloud** connectivity via hdbcli/hana-ml
- **Kyma StatefulSet** deployment with persistent storage
- **Health endpoint** for Kubernetes probes

## MCP Tools

| Tool | Description | PAL Algorithm |
|------|-------------|---------------|
| `pal_forecast` | Time series forecasting | Single Exponential Smoothing |
| `pal_anomaly` | Anomaly detection | IQR method |
| `pal_clustering` | Customer segmentation | K-Means |
| `pal_classification` | Classification | Random Forest |
| `pal_regression` | Linear regression | Linear Regression |
| `hana_tables` | Discover PAL-suitable tables | - |
| `mangle_query` | Datalog inference | - |

## Quick Start

### 1. Configure Environment

```bash
cd src/intelligence/ai-core-pal
cp .env.example .env

# Edit .env with your HANA credentials:
# HANA_HOST=your-instance.hana.prod-ap11.hanacloud.ondemand.com
# HANA_USER=AINUCLEUS
# HANA_PASSWORD=your-password
# HANA_SCHEMA=AINUCLEUS
```

### 2. Install Dependencies

```bash
pip install -r requirements.txt
```

### 3. Create Sample Tables (HANA)

Open SAP HANA Database Explorer and run:

```bash
# 1. Create tables
scripts/create_tables.sql

# 2. Populate with sample data
scripts/populate_data.sql
```

### 4. Test HANA Connection

```bash
python -c "from agent.hana_client import test_connection; print(test_connection())"
```

### 5. Run MCP Server Locally

```bash
python -m mcp_server.btp_pal_mcp_server
# Server starts on http://localhost:8084
```

### 6. Test MCP Server

```bash
# Health check
curl http://localhost:8084/health

# List tools
curl -X POST http://localhost:8084/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# Call pal_forecast
curl -X POST http://localhost:8084/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":2,
    "method":"tools/call",
    "params":{
      "name":"pal_forecast",
      "arguments":{
        "table_name":"AINUCLEUS.PAL_TIMESERIES_DATA",
        "value_column":"AMOUNT_USD",
        "date_column":"RECORD_DATE",
        "horizon":6
      }
    }
  }'
```

## Docker Deployment

### Build Image

```bash
docker build -f Dockerfile.python -t ai-core-pal:latest .
```

### Run Container

```bash
docker run -p 8084:8084 --env-file .env ai-core-pal:latest
```

## Kyma Deployment

### Deploy to SAP BTP Kyma

```bash
# 1. Login to your Kyma cluster
kubectl config use-context <your-kyma-context>

# 2. Apply deployment (creates namespace, secret, statefulset, service, apirule)
kubectl apply -f deploy/kyma/ai-core-pal-deployment.yaml

# 3. Verify deployment
kubectl get pods -n sap-ai-services
kubectl logs -n sap-ai-services ai-core-pal-0

# 4. Get external URL
kubectl get apirule -n sap-ai-services ai-core-pal
```

### Update HANA Credentials

Before deploying, update the secret in `deploy/kyma/ai-core-pal-deployment.yaml`:

```yaml
stringData:
  HANA_HOST: "your-instance.hana.prod-ap11.hanacloud.ondemand.com"
  HANA_USER: "your-user"
  HANA_PASSWORD: "your-password"
  HANA_SCHEMA: "your-schema"
```

## Testing

### Run All Tests

```bash
# Set environment first
export HANA_HOST=your-instance.hana...
export HANA_USER=AINUCLEUS
export HANA_PASSWORD=your-password
export HANA_SCHEMA=AINUCLEUS

# Run tests
pytest tests/ -v
```

### Run Specific Tests

```bash
# HANA connection tests
pytest tests/test_hana_connection.py -v

# PAL algorithm tests
pytest tests/test_pal_algorithms.py -v

# MCP server tests (requires running server)
pytest tests/test_mcp_server.py -v
```

## Project Structure

```
src/intelligence/ai-core-pal/
├── agent/
│   ├── __init__.py
│   ├── aicore_pal_agent.py      # PAL agent
│   └── hana_client.py           # HANA Cloud client (NEW)
├── mcp_server/
│   ├── __init__.py
│   ├── btp_pal_mcp_server.py    # MCP server (NEW)
├── scripts/
│   ├── create_tables.sql        # DDL scripts (NEW)
│   └── populate_data.sql        # Sample data (NEW)
├── tests/
│   ├── test_hana_connection.py  # Connection tests (NEW)
│   ├── test_pal_algorithms.py   # PAL tests (NEW)
│   └── test_mcp_server.py       # MCP tests (NEW)
├── deploy/
│   └── kyma/
│       └── ai-core-pal-deployment.yaml  # Complete Kyma deployment (NEW)
├── Dockerfile.python            # Python Dockerfile (NEW)
├── requirements.txt             # Dependencies (NEW)
├── .env.example                 # Environment template (NEW)
└── README.md                    # This file
```

## HANA Cloud Requirements

- SAP HANA Cloud instance with PAL enabled
- Database user with CREATE TABLE, EXECUTE PROCEDURE permissions
- Network access to HANA Cloud endpoint (port 443)

## License

Apache-2.0 - See LICENSE file
