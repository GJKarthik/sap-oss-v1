# SAP OpenAI-Compatible Server for Elasticsearch

An OpenAI-compatible HTTP server with Elasticsearch integration for vector storage and RAG (Retrieval-Augmented Generation).

## Features

- **Full OpenAI API Compatibility** - Works with any OpenAI client SDK
- **SAP AI Core Integration** - Routes to Claude 3.5 Sonnet and other models
- **Elasticsearch Vector Storage** - Store and search embeddings
- **RAG Support** - Automatic context injection from vector search
- **Chat History Persistence** - Store conversations in Elasticsearch
- **Semantic Search** - Vector similarity search endpoint

## Quick Start

```bash
# Install dependencies
pip3 install fastapi uvicorn pydantic elasticsearch

# Set environment variables (or copy .env)
export AICORE_CLIENT_ID=your-client-id
export AICORE_CLIENT_SECRET=your-client-secret
export AICORE_AUTH_URL=https://xxx.authentication.xxx.hana.ondemand.com/oauth/token
export AICORE_BASE_URL=https://api.ai.xxx.aws.ml.hana.ondemand.com
export AICORE_CHAT_DEPLOYMENT_ID=dca062058f34402b

# Optional: Configure Elasticsearch
export ES_HOST=http://localhost:9200
export ES_INDEX_PREFIX=sap_openai

# Start the server
uvicorn server:app --port 9201
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check (includes ES status) |
| `/v1/models` | GET | List available models |
| `/v1/models/{id}` | GET | Get model details |
| `/v1/chat/completions` | POST | Chat completions (with optional RAG) |
| `/v1/embeddings` | POST | Generate embeddings (with ES storage) |
| `/v1/semantic_search` | POST | Vector similarity search |
| `/v1/completions` | POST | Legacy completions |

## RAG (Retrieval-Augmented Generation)

Enable automatic context retrieval from Elasticsearch:

```python
response = client.chat.completions.create(
    model="claude-4.6-sonnet",
    messages=[{"role": "user", "content": "What is X?"}],
    extra_body={
        "search_context": True,  # Enable RAG
        "context_top_k": 5       # Number of documents to retrieve
    }
)
```

## Store Embeddings in Elasticsearch

```python
# Store embeddings with the API
response = client.embeddings.create(
    model="text-embedding-model",
    input=["Document 1 text", "Document 2 text"],
    extra_body={
        "store_in_es": True,
        "document_ids": ["doc1", "doc2"],
        "metadata": {"source": "manual"}
    }
)
```

## Semantic Search

```bash
curl http://localhost:9201/v1/semantic_search \
  -H "Content-Type: application/json" \
  -d '{"query": "What is Elasticsearch?", "top_k": 5}'
```

## Store Chat History

```python
response = client.chat.completions.create(
    model="claude-3.5-sonnet",
    messages=[{"role": "user", "content": "Hello!"}],
    extra_body={
        "store_in_es": True,
        "conversation_id": "conv-123"
    }
)
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
| `ES_HOST` | Elasticsearch URL | No |
| `ES_USERNAME` | Elasticsearch username | No |
| `ES_PASSWORD` | Elasticsearch password | No |
| `ES_INDEX_PREFIX` | Index name prefix | No |
| `ES_VECTOR_DIMS` | Embedding dimensions | No |

## Elasticsearch Indices

The server creates these indices automatically:

- `{prefix}_vectors` - Vector embeddings with cosine similarity
- `{prefix}_conversations` - Chat history storage

## Elasticsearch API → OpenAI API Compliant Mappings

The server maps Elasticsearch native APIs to **actual OpenAI API spec compliant responses**:

| Elasticsearch API | OpenAI Response Type | Description |
|-------------------|---------------------|-------------|
| `/_search` | `chat.completion` | ES query → OpenAI chat completion |
| `/{index}/_doc` | `embedding` | Document → OpenAI embeddings response |
| `/{index}/_knn_search` | `embedding` | kNN → OpenAI embeddings + search results |
| `/_analyze` | `chat.completion` | Text analysis via LLM |
| `/_cluster/health` | `cluster.health` | Health with OpenAI-style object |
| `/_cat/indices` | `list` | Indices with OpenAI-style list |

### Example: ES /_search → OpenAI chat.completion Response

```bash
# Traditional Elasticsearch match query
curl -X POST http://localhost:9201/_search \
  -H "Content-Type: application/json" \
  -d '{"query": {"match": {"content": "What is machine learning?"}}}'

# Returns actual OpenAI API compliant chat.completion:
{
  "id": "chatcmpl-f4c18819-6d77-45e1-a9fc-b902c006a446",
  "object": "chat.completion",            # OpenAI compliant!
  "created": 1772047993,
  "model": "dca062058f34402b",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "This is a fundamental query where the user is seeking..."
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 26,
    "completion_tokens": 152,
    "total_tokens": 178
  }
}
```

### Example: ES /{index}/_doc → OpenAI embeddings Response

```bash
# Elasticsearch document indexing
curl -X POST http://localhost:9201/my_index/_doc \
  -H "Content-Type: application/json" \
  -d '{"text": "Machine learning is a subset of AI"}'

# Returns actual OpenAI API compliant embeddings:
{
  "object": "list",                       # OpenAI compliant!
  "data": [{
    "object": "embedding",
    "index": 0,
    "embedding": [0.0123, -0.0456, ...]   # 768 dimensions
  }],
  "model": "text-embedding-model",
  "usage": {"prompt_tokens": 7, "total_tokens": 7},
  "elasticsearch": {
    "_index": "my_index",
    "_id": "generated-uuid",
    "result": "created"
  }
}
```

### Example: Index Document with Auto-Embedding

```bash
# POST document with text field → Auto-generates embedding via SAP AI Core
curl -X POST http://localhost:9201/my_index/_doc/doc1 \
  -H "Content-Type: application/json" \
  -d '{"text": "This document will be embedded automatically"}'

# Response
{"_index": "my_index", "_id": "doc1", "result": "created"}
```

### Example: KNN Search with Text Query

```bash
# KNN search with query_text → Generates embedding first
curl -X POST http://localhost:9201/my_index/_knn_search \
  -H "Content-Type: application/json" \
  -d '{
    "query_text": "Find similar documents about AI",
    "knn": {"k": 5}
  }'
```

## Test Results

```
✅ Health: {"status":"healthy","service":"sap-openai-server-elasticsearch"}
✅ Models: 7 deployments (Claude 3.5 Sonnet)
✅ Chat: "Hello! I'm happy to help you with anything related to Elasticsearch..."
✅ Usage: prompt=12, completion=54, total=66 tokens
✅ /_cluster/health: {"status": "not_configured"} (ES not running)
✅ /_search: Returns semantic search or passes to ES
```

## License

Apache 2.0
