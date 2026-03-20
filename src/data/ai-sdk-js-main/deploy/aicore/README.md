# SAP AI SDK JS - OpenAI-Compatible Server

Deploy the SAP AI SDK for JavaScript as an OpenAI-compatible API on SAP BTP AI Core.

## Overview

- **100% OpenAI API compatibility** — Works with any OpenAI client
- **SAP AI SDK integration** — Uses @sap-ai-sdk/foundation-models
- **Streaming support** — SSE for chat completions
- **Multi-model routing** — GPT-4, Claude, and more via AI Core

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completion (streaming) |
| `/v1/completions` | POST | Text completion |
| `/v1/embeddings` | POST | Generate embeddings |
| `/v1/models` | GET | List available models |
| `/health` | GET | Health check |

## Quick Start

### 1. Build Docker Image

```bash
cd src/data/ai-sdk-js-main
docker build -f deploy/aicore/Dockerfile -t your-registry/ai-sdk-js-openai:latest .
docker push your-registry/ai-sdk-js-openai:latest
```

### 2. Create AI Core Secret

```bash
ai-core-sdk secret create ai-core-service-key \
  --from-file=service-key=<path-to-service-key.json>
```

### 3. Deploy

```bash
ai-core-sdk scenario create -f deploy/aicore/serving-template.yaml
ai-core-sdk deployment create \
  --scenario-id ai-sdk-js-openai \
  --executable-id ai-sdk-js-openai-exec
```

## Usage

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://<deployment-url>/v1",
    api_key="<ai-core-token>"
)

response = client.chat.completions.create(
    model="gpt-4",
    messages=[{"role": "user", "content": "Hello!"}]
)
```

## License

Apache-2.0