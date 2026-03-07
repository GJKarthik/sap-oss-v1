# SAP OpenAI-Compatible Server for HANA AI Toolkit

An OpenAI-compatible HTTP server with native SAP HANA Cloud vector store integration for RAG (Retrieval-Augmented Generation).

## Features

- **Full OpenAI API Compatibility** - Works with any OpenAI client SDK
- **SAP AI Core Integration** - Routes to Claude 3.5 Sonnet and other models
- **HANA Cloud Vector Store** - Native vector storage with REAL_VECTOR type
- **Built-in RAG** - Automatic context injection from HANA vectors
- **Semantic Search** - COSINE_SIMILARITY search on HANA Cloud

## Quick Start

```bash
# Install dependencies
pip3 install fastapi uvicorn pydantic

# Set environment variables
export AICORE_CLIENT_ID=your-client-id
export AICORE_CLIENT_SECRET=your-client-secret
export AICORE_AUTH_URL=https://xxx.authentication.xxx.hana.ondemand.com/oauth/token
export AICORE_BASE_URL=https://api.ai.xxx.aws.ml.hana.ondemand.com
export AICORE_CHAT_DEPLOYMENT_ID=dca062058f34402b

# Optional: Configure HANA Cloud
export HANA_HOST=xxx.hana.cloud.sap.com
export HANA_PORT=443
export HANA_USER=your-user
export HANA_PASSWORD=your-password

# Start the server
uvicorn sap_openai_server.server:app --port 8100
```

## Endpoints

### Core OpenAI Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check (includes HANA status) |
| `/v1/models` | GET | List available models |
| `/v1/models/{id}` | GET | Get model details |
| `/v1/chat/completions` | POST | Chat completions (with RAG) |
| `/v1/embeddings` | POST | Generate embeddings |
| `/v1/search` | POST | Semantic search |
| `/v1/files` | GET/POST | File management |
| `/v1/fine-tunes` | GET | List fine-tunes |

### HANA Vector Store Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/hana/tables` | GET | List vector tables |
| `/v1/hana/vectors` | POST | Store vectors in HANA |
| `/v1/hana/search` | POST | Search HANA vectors |
| `/v1/hana/tables/{name}` | DELETE | Delete vector table |

## RAG (Retrieval-Augmented Generation)

Enable automatic context retrieval from HANA Cloud:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8100/v1", api_key="any")

response = client.chat.completions.create(
    model="claude-3.5-sonnet",
    messages=[{"role": "user", "content": "What is machine learning?"}],
    extra_body={
        "search_context": True,     # Enable RAG
        "vector_table": "my_docs",  # HANA vector table
        "context_top_k": 5          # Number of documents
    }
)
```

## Store Documents in HANA

```python
import httpx

# Store documents with embeddings in HANA
response = httpx.post("http://localhost:8100/v1/hana/vectors", json={
    "table_name": "my_docs",
    "documents": [
        "Machine learning is a subset of AI",
        "Deep learning uses neural networks",
        "NLP processes human language"
    ],
    "ids": ["doc1", "doc2", "doc3"]
})
```

## Store Embeddings via OpenAI API

```python
# Generate and store embeddings in HANA
response = client.embeddings.create(
    model="text-embedding",
    input=["Document 1", "Document 2"],
    extra_body={
        "store_in_hana": True,
        "table_name": "my_vectors",
        "document_ids": ["doc1", "doc2"]
    }
)
```

## Search HANA Vectors

```bash
curl http://localhost:8100/v1/hana/search \
  -H "Content-Type: application/json" \
  -d '{
    "query": "What is deep learning?",
    "vector_table": "my_docs",
    "max_rerank": 5
  }'
```

## HANA Cloud SQL

The server uses native HANA Cloud vector operations:

```sql
-- Table structure
CREATE TABLE "my_vectors" (
    "id" VARCHAR(500) PRIMARY KEY,
    "content" NCLOB,
    "embedding" REAL_VECTOR(768)
);

-- Vector search
SELECT TOP 5 "content", 
       COSINE_SIMILARITY("embedding", TO_REAL_VECTOR('[0.1,0.2,...]')) AS score
FROM "my_vectors"
ORDER BY score DESC;
```

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `AICORE_CLIENT_ID` | SAP AI Core client ID | Yes |
| `AICORE_CLIENT_SECRET` | SAP AI Core client secret | Yes |
| `AICORE_AUTH_URL` | OAuth token URL | Yes |
| `AICORE_BASE_URL` | AI Core API base URL | Yes |
| `AICORE_RESOURCE_GROUP` | Resource group | No |
| `AICORE_CHAT_DEPLOYMENT_ID` | Default chat deployment | No |
| `AICORE_EMBEDDING_DEPLOYMENT_ID` | Default embedding deployment | No |
| `HANA_HOST` | HANA Cloud host | No |
| `HANA_PORT` | HANA Cloud port | No |
| `HANA_USER` | HANA Cloud user | No |
| `HANA_PASSWORD` | HANA Cloud password | No |

## Integration with hana_ai

This server integrates with the existing `hana_ai.vectorstore.HANAMLinVectorEngine`:

```python
from hana_ml import ConnectionContext
from hana_ai.vectorstore import HANAMLinVectorEngine

# Create vector engine
conn = ConnectionContext(address="xxx.hana.cloud.sap.com", ...)
engine = HANAMLinVectorEngine(conn, table_name="my_vectors")

# Query similar documents
result = engine.query(input="What is AI?", top_n=5)
```

## License

Apache 2.0