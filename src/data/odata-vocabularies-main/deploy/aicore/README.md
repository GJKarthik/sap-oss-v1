# OData Vocabularies - Assistant

OpenAI-compatible chat assistant for OData annotation guidance.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Vocabulary Q&A (OpenAI format) |
| `/v1/vocabularies` | GET | List vocabularies |
| `/health` | GET | Health check |

## Quick Start

```bash
# Build
cd src/data/odata-vocabularies-main
docker build -f deploy/aicore/Dockerfile -t your-registry/odata-vocab-assistant:latest .

# Deploy
ai-core-sdk deployment create --scenario-id odata-vocab-assistant
```

## Usage

```python
from openai import OpenAI

client = OpenAI(base_url="https://<url>/v1", api_key="<token>")

response = client.chat.completions.create(
    model="vocab-assistant",
    messages=[{"role": "user", "content": "What annotation should I use for currency?"}]
)
print(response.choices[0].message.content)