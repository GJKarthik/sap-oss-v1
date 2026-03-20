# LangChain HANA - Vector Service

OpenAI-compatible embeddings and vector search service using HANA Cloud.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/embeddings` | POST | Generate embeddings (OpenAI format) |
| `/v1/search` | POST | Similarity search in HANA Vector |
| `/v1/models` | GET | List embedding models |
| `/health` | GET | Health check |

## Quick Start

```bash
# Build
cd src/data/langchain-integration-for-sap-hana-cloud-main
docker build -f deploy/aicore/Dockerfile -t your-registry/langchain-hana-vector:latest .

# Create HANA secret
ai-core-sdk secret create hana-credentials \
  --from-literal=user=<user> --from-literal=password=<password>

# Deploy
ai-core-sdk deployment create \
  --scenario-id langchain-hana-vector \
  --parameter HANA_HOST=<host>.hana.ondemand.com
```

## Usage

```python
from openai import OpenAI

client = OpenAI(base_url="https://<url>/v1", api_key="<token>")

# Generate embeddings
response = client.embeddings.create(
    model="text-embedding-ada-002",
    input="Hello world"
)