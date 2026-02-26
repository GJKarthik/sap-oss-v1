# SAP OpenAI-Compatible Server for LangChain HANA Integration

A full OpenAI-compatible HTTP server with LangChain + SAP HANA Cloud vector store integration.

## Features

- **Full OpenAI API Compatibility** - All OpenAI endpoints supported
- **SAP AI Core Integration** - Routes to Claude 3.5 Sonnet and other models
- **HANA Cloud Vector Store** - Native vector storage with REAL_VECTOR type
- **LangChain Integration** - Works with langchain_hana vectorstores
- **Assistants API** - Full Assistants v2 API support
- **Batches API** - Batch processing support

## Quick Start

```bash
# Install dependencies
pip3 install fastapi uvicorn pydantic

# Set environment variables
export AICORE_CLIENT_ID=your-client-id
export AICORE_CLIENT_SECRET=your-client-secret
export AICORE_AUTH_URL=https://xxx.authentication.xxx.hana.ondemand.com/oauth/token
export AICORE_BASE_URL=https://api.ai.xxx.aws.ml.hana.ondemand.com

# Optional: Configure HANA Cloud
export HANA_HOST=xxx.hana.cloud.sap.com
export HANA_PORT=443
export HANA_USER=your-user
export HANA_PASSWORD=your-password

# Start the server
uvicorn sap_openai_server.server:app --port 8200
```

## Full OpenAI API Endpoints

### Core Endpoints
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/models` | GET | List models |
| `/v1/models/{id}` | GET | Get model |
| `/v1/chat/completions` | POST | Chat (with RAG) |
| `/v1/embeddings` | POST | Embeddings |
| `/v1/completions` | POST | Legacy completions |
| `/v1/search` | POST | Semantic search |
| `/v1/files` | GET/POST | File management |
| `/v1/fine-tunes` | GET | List fine-tunes |

### Moderations & Media
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/moderations` | POST | Content moderation |
| `/v1/images/generations` | POST | Image generation |
| `/v1/audio/transcriptions` | POST | Audio transcription |
| `/v1/audio/translations` | POST | Audio translation |
| `/v1/audio/speech` | POST | Text-to-speech |

### Assistants API (v2)
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/assistants` | GET/POST | List/create assistants |
| `/v1/assistants/{id}` | GET/DELETE | Get/delete assistant |
| `/v1/threads` | POST | Create thread |
| `/v1/threads/{id}` | GET/DELETE | Get/delete thread |
| `/v1/threads/{id}/messages` | GET/POST | Messages |
| `/v1/threads/{id}/runs` | GET/POST | Runs |

### Batches API
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/batches` | GET/POST | List/create batches |
| `/v1/batches/{id}` | GET | Get batch |
| `/v1/batches/{id}/cancel` | POST | Cancel batch |

### HANA Vector Store
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/hana/tables` | GET | List vector tables |
| `/v1/hana/vectors` | POST | Store vectors |
| `/v1/hana/search` | POST | Search vectors |

## LangChain Integration

```python
from langchain_hana.vectorstores import HanaDB
from langchain_openai import ChatOpenAI, OpenAIEmbeddings

# Use with local server
llm = ChatOpenAI(
    base_url="http://localhost:8200/v1",
    api_key="any",
    model="claude-3.5-sonnet"
)

embeddings = OpenAIEmbeddings(
    base_url="http://localhost:8200/v1",
    api_key="any"
)

# Use with HanaDB
from hdbcli import dbapi
conn = dbapi.connect(address="xxx.hana.cloud.sap.com", ...)
vectorstore = HanaDB(
    connection=conn,
    embedding=embeddings,
    table_name="my_vectors"
)
```

## Assistants API Usage

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8200/v1", api_key="any")

# Create assistant
assistant = client.beta.assistants.create(
    model="claude-3.5-sonnet",
    name="My Assistant",
    instructions="You are a helpful assistant."
)

# Create thread
thread = client.beta.threads.create()

# Add message
client.beta.threads.messages.create(
    thread_id=thread.id,
    role="user",
    content="Hello!"
)

# Run
run = client.beta.threads.runs.create(
    thread_id=thread.id,
    assistant_id=assistant.id
)
```

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `AICORE_CLIENT_ID` | SAP AI Core client ID | Yes |
| `AICORE_CLIENT_SECRET` | SAP AI Core client secret | Yes |
| `AICORE_AUTH_URL` | OAuth token URL | Yes |
| `AICORE_BASE_URL` | AI Core API base URL | Yes |
| `HANA_HOST` | HANA Cloud host | No |
| `HANA_PORT` | HANA Cloud port | No |
| `HANA_USER` | HANA Cloud user | No |
| `HANA_PASSWORD` | HANA Cloud password | No |

## License

Apache 2.0