# SAP AI Core Streaming - OpenAI-Compatible API

Deploy an OpenAI-compatible API server on SAP BTP AI Core with KServe.

## Overview

This deployment provides:
- **100% OpenAI API compatibility** — Use any OpenAI client library
- **Smart routing** — Routes to AI Core or vLLM based on security classification
- **Streaming support** — Server-Sent Events (SSE) for chat completions
- **Governance integration** — Mangle-based routing rules

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completion (streaming supported) |
| `/v1/completions` | POST | Text completion (legacy) |
| `/v1/embeddings` | POST | Generate embeddings |
| `/v1/models` | GET | List available models |
| `/health` | GET | KServe health check |

## Prerequisites

1. SAP BTP account with AI Core enabled
2. AI Core service instance created
3. Docker registry access (for custom images)
4. AI Core CLI (`ai-core-sdk`) installed

## Quick Start

### 1. Build and Push Docker Image

```bash
# From the ai-core-streaming directory
cd src/data/ai-core-streaming

# Build the OpenAI server image
docker build -f deploy/aicore/Dockerfile -t your-registry/ai-core-streaming-openai:latest .

# Push to your registry
docker push your-registry/ai-core-streaming-openai:latest
```

### 2. Create AI Core Credentials Secret

Create a secret with your AI Core credentials:

```bash
ai-core-sdk secret create ai-core-credentials \
  --from-literal=clientid=<your-client-id> \
  --from-literal=clientsecret=<your-client-secret>
```

### 3. Deploy to AI Core

```bash
# Register the serving template
ai-core-sdk scenario create -f deploy/aicore/serving-template.yaml

# Create a deployment
ai-core-sdk deployment create \
  --scenario-id ai-core-streaming-openai \
  --executable-id ai-core-streaming-openai-exec \
  --resource-group default \
  --parameter AI_CORE_RESOURCE_GROUP=default \
  --parameter LOG_LEVEL=INFO
```

### 4. Get Deployment URL

```bash
ai-core-sdk deployment get <deployment-id>
```

## Usage

### Chat Completion

```bash
curl https://<deployment-url>/v1/chat/completions \
  -H "Authorization: Bearer <ai-core-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello!"}
    ]
  }'
```

### Streaming Chat Completion

```bash
curl https://<deployment-url>/v1/chat/completions \
  -H "Authorization: Bearer <ai-core-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Tell me a story"}],
    "stream": true
  }'
```

### Embeddings

```bash
curl https://<deployment-url>/v1/embeddings \
  -H "Authorization: Bearer <ai-core-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "text-embedding-ada-002",
    "input": "Hello world"
  }'
```

### List Models

```bash
curl https://<deployment-url>/v1/models \
  -H "Authorization: Bearer <ai-core-token>"
```

## Using with OpenAI Python SDK

```python
from openai import OpenAI

# Configure client for AI Core
client = OpenAI(
    base_url="https://<deployment-url>/v1",
    api_key="<ai-core-token>"
)

# Chat completion
response = client.chat.completions.create(
    model="gpt-4",
    messages=[
        {"role": "user", "content": "Hello!"}
    ]
)
print(response.choices[0].message.content)

# Streaming
for chunk in client.chat.completions.create(
    model="gpt-4",
    messages=[{"role": "user", "content": "Tell me a story"}],
    stream=True
):
    print(chunk.choices[0].delta.content or "", end="")
```

## Using with LangChain

```python
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(
    base_url="https://<deployment-url>/v1",
    api_key="<ai-core-token>",
    model="gpt-4"
)

response = llm.invoke("Hello!")
print(response.content)
```

## Smart Routing

The server automatically routes requests based on:

### 1. Security Classification Header
```bash
# Route to vLLM for confidential data
curl ... -H "X-Mesh-Security-Class: confidential"
```

### 2. Service ID Header
```bash
# Route based on calling service
curl ... -H "X-Mesh-Service: data-cleaning-copilot"
```

### 3. Model Selection
```bash
# Explicit model selection
curl ... -d '{"model": "llama-3.1-70b", ...}'  # Routes to vLLM
curl ... -d '{"model": "gpt-4", ...}'           # Routes to AI Core
```

### 4. Content Analysis
Requests containing confidential keywords (customer, salary, ssn, etc.) are automatically routed to vLLM.

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `AI_CORE_URL` | AI Core API endpoint | Auto-injected |
| `AI_CORE_CLIENT_ID` | Client ID | From secret |
| `AI_CORE_CLIENT_SECRET` | Client secret | From secret |
| `AI_CORE_RESOURCE_GROUP` | Resource group | `default` |
| `VLLM_URL` | vLLM endpoint for confidential routing | Empty |
| `PORT` | Server port | `8080` |
| `LOG_LEVEL` | Logging level | `INFO` |

### Scaling Configuration

Edit `serving-template.yaml` to adjust:
- `minReplicas` / `maxReplicas` — Scaling bounds
- `containerConcurrency` — Requests per container
- `timeout` — Request timeout (for long responses)

## Monitoring

### Health Check
```bash
curl https://<deployment-url>/health
# {"status": "healthy", "timestamp": 1234567890.0}
```

### Routing Audit
```bash
curl https://<deployment-url>/v1/routing/audit
# Returns recent routing decisions for debugging
```

### Routing Configuration
```bash
curl https://<deployment-url>/v1/routing/info
# Returns current routing rules
```

## Troubleshooting

### Common Issues

1. **401 Unauthorized**
   - Check AI Core token is valid
   - Verify credentials secret exists

2. **503 Service Unavailable**
   - Deployment may be scaling up
   - Check deployment status: `ai-core-sdk deployment get <id>`

3. **Routing to wrong backend**
   - Check `X-Mesh-Security-Class` header
   - Review content for confidential keywords
   - Check `/v1/routing/audit` for routing decisions

### Logs

```bash
ai-core-sdk deployment logs <deployment-id>
```

## Development

### Local Testing

```bash
# Install dependencies
pip install -r requirements-openai.txt

# Run locally
export AI_CORE_URL=https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com
export AI_CORE_CLIENT_ID=<your-id>
export AI_CORE_CLIENT_SECRET=<your-secret>
export AI_CORE_RESOURCE_GROUP=default

python -m uvicorn openai.server:app --host 0.0.0.0 --port 8080 --reload
```

### API Documentation

When running locally, access Swagger UI at:
- http://localhost:8080/docs

## License

Apache-2.0