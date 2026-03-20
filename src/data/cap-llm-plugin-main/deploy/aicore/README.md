# CAP LLM Plugin - RAG-Enhanced OpenAI API

Deploy CAP LLM Plugin as a RAG-enhanced OpenAI-compatible service on SAP AI Core.

## Features

- **RAG context injection** — Automatically retrieves relevant documents from HANA Vector
- **OpenAI API compatible** — Standard /v1/chat/completions endpoint
- **HANA Vector integration** — Similarity search for context augmentation

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | RAG-enhanced chat completion |
| `/v1/embeddings` | POST | Generate embeddings |
| `/health` | GET | Health check |

## Quick Start

### 1. Build & Push

```bash
cd src/data/cap-llm-plugin-main
docker build -f deploy/aicore/Dockerfile -t your-registry/cap-llm-rag:latest .
docker push your-registry/cap-llm-rag:latest
```

### 2. Create Secrets

```bash
# AI Core credentials
ai-core-sdk secret create ai-core-service-key \
  --from-file=service-key=<service-key.json>

# HANA credentials
ai-core-sdk secret create hana-credentials \
  --from-literal=user=<hana-user> \
  --from-literal=password=<hana-password>
```

### 3. Deploy

```bash
ai-core-sdk scenario create -f deploy/aicore/serving-template.yaml
ai-core-sdk deployment create \
  --scenario-id cap-llm-rag \
  --executable-id cap-llm-rag-exec \
  --parameter HANA_HOST=<your-hana-host>.hana.ondemand.com
```

## Usage

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://<deployment-url>/v1",
    api_key="<ai-core-token>"
)

# RAG-enhanced completion - automatically retrieves context
response = client.chat.completions.create(
    model="gpt-4",
    messages=[{"role": "user", "content": "What are SAP's AI capabilities?"}]
)
# Response includes context from HANA Vector documents
```

## License

Apache-2.0