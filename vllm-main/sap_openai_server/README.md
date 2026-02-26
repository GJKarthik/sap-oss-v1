# SAP OpenAI-Compatible Server for vLLM

An OpenAI-compatible HTTP server that routes to SAP AI Core. Can be used as a drop-in replacement for vLLM's OpenAI-compatible server endpoint.

## Features

- **Full OpenAI API Compatibility** - Works with any OpenAI client SDK
- **SAP AI Core Integration** - Routes to Claude 3.5 Sonnet and other models
- **Anthropic ↔ OpenAI Translation** - Automatic format conversion
- **Streaming Support** - Server-Sent Events (SSE) for real-time responses
- **Mangle Proxy Config** - For endpoint mapping and management

## Quick Start

```bash
# Install dependencies
pip3 install fastapi uvicorn pydantic

# Set environment variables (or copy .env)
export AICORE_CLIENT_ID=your-client-id
export AICORE_CLIENT_SECRET=your-client-secret
export AICORE_AUTH_URL=https://xxx.authentication.xxx.hana.ondemand.com/oauth/token
export AICORE_BASE_URL=https://api.ai.xxx.aws.ml.hana.ondemand.com
export AICORE_RESOURCE_GROUP=default
export AICORE_CHAT_DEPLOYMENT_ID=dca062058f34402b

# Start the server
cd vllm-main/sap_openai_server
uvicorn server:app --port 8000
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/v1/models` | GET | List available models |
| `/v1/models/{id}` | GET | Get model details |
| `/v1/chat/completions` | POST | Chat completions (streaming supported) |
| `/v1/embeddings` | POST | Generate embeddings |
| `/v1/completions` | POST | Legacy completions |

## Usage Examples

### curl

```bash
# Health check
curl http://localhost:8000/health

# List models
curl http://localhost:8000/v1/models

# Chat completion
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-3.5-sonnet", "messages": [{"role": "user", "content": "Hello!"}]}'

# Streaming chat completion
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-3.5-sonnet", "messages": [{"role": "user", "content": "Hello!"}], "stream": true}'
```

### Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="any"  # API key is optional if not configured
)

response = client.chat.completions.create(
    model="claude-3.5-sonnet",
    messages=[{"role": "user", "content": "Hello!"}]
)

print(response.choices[0].message.content)
```

### Python (Native)

```python
import requests

response = requests.post(
    "http://localhost:8000/v1/chat/completions",
    json={
        "model": "dca062058f34402b",
        "messages": [{"role": "user", "content": "Hello!"}]
    }
)

print(response.json()["choices"][0]["message"]["content"])
```

## Available Models

The server lists all available SAP AI Core deployments:

```
- dca062058f34402b (anthropic--claude-3.5-sonnet) [RUNNING]
- d2484b1bdc9da5a8 (unknown) [RUNNING]
- d7ed16e4c7ef5820 (unknown) [RUNNING]
- dad832898d0c2a86 (unknown) [RUNNING]
- d12a53e4781f4484 (unknown) [RUNNING]
- d2ac294eb74b7eef (unknown) [RUNNING]
```

## Mangle Proxy Configuration

The included `proxy.mg` file provides:
- Endpoint mappings for all OpenAI routes
- Model aliases (gpt-4 → Claude 3.5 Sonnet)
- Request/response transformation rules
- Rate limiting configuration
- Caching rules

Load with mangle-query-service:
```bash
mangle-query-service --rules proxy.mg
```

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `AICORE_CLIENT_ID` | SAP AI Core client ID | Yes |
| `AICORE_CLIENT_SECRET` | SAP AI Core client secret | Yes |
| `AICORE_AUTH_URL` | OAuth token URL | Yes |
| `AICORE_BASE_URL` | AI Core API base URL | Yes |
| `AICORE_RESOURCE_GROUP` | Resource group (default: "default") | No |
| `AICORE_CHAT_DEPLOYMENT_ID` | Default chat deployment ID | No |
| `AICORE_EMBEDDING_DEPLOYMENT_ID` | Default embedding deployment ID | No |

## Files

```
sap_openai_server/
├── __init__.py    # Package exports
├── server.py      # FastAPI server with all endpoints
├── proxy.mg       # Mangle proxy configuration
├── .env           # Environment variables (credentials)
└── README.md      # This file
```

## Test Results

```
✅ Health check: {"status":"healthy","service":"sap-openai-server-vllm"}
✅ List models: 7 deployments (Claude 3.5 Sonnet available)
✅ Chat completion: "Hi there friend!"
✅ Token usage: prompt_tokens=14, completion_tokens=7, total_tokens=21
```

## License

Apache 2.0