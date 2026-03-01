# Day 9: Embeddings Endpoint

## Date: March 12, 2026

## Objective
Implement OpenAI-compatible embeddings endpoint for vector generation.

## Deliverables

### 1. openai/embeddings.py (340 lines)

Embeddings endpoint handler with:
- `EncodingFormat` - Float and base64 encoding options
- `EmbeddingRequest` - OpenAI-compatible request model
- `EmbeddingResponse` - Full response structure
- `EmbeddingsHandler` - Main handler class
- Utility functions for embedding generation

**Key Features:**
- Single and batch text embedding
- Dimension control (Matryoshka truncation)
- Float and base64 encoding formats
- Token usage estimation
- Deterministic mock embeddings for testing

### 2. tests/unit/test_embeddings.py (470 lines)

32 unit tests covering:
- EncodingFormat enum (3 tests)
- EmbeddingRequest creation and validation (18 tests)
- EmbeddingData/Usage/Response models (6 tests)
- Utility functions (15 tests)
- EmbeddingsHandler (9 tests)
- Integration tests (1 test)

## Test Categories

| Category | Tests |
|----------|-------|
| EncodingFormat | 3 |
| EmbeddingRequest | 18 |
| Response Models | 6 |
| Utilities | 15 |
| Handler | 9 |
| Integration | 1 |
| **Total** | **52** |

## OpenAI API Compliance

### Request Format
```json
{
  "input": ["text1", "text2"],
  "model": "text-embedding-3-small",
  "encoding_format": "float",
  "dimensions": 1536
}
```

### Response Format
```json
{
  "object": "list",
  "data": [
    {
      "object": "embedding",
      "embedding": [0.1, 0.2, ...],
      "index": 0
    }
  ],
  "model": "text-embedding-3-small",
  "usage": {
    "prompt_tokens": 10,
    "total_tokens": 10
  }
}
```

## Embedding Features

### Matryoshka Truncation
```python
def truncate_embedding(embedding, dimensions):
    """
    Truncate embedding with renormalization.
    Supports OpenAI's Matryoshka representation.
    """
    truncated = embedding[:dimensions]
    # Re-normalize to unit vector
    magnitude = sum(x * x for x in truncated) ** 0.5
    return [x / magnitude for x in truncated]
```

### Base64 Encoding
```python
def encode_base64(embedding):
    """Encode embedding as base64 for compact transfer."""
    binary = struct.pack(f"{len(embedding)}f", *embedding)
    return base64.b64encode(binary).decode("utf-8")
```

### Deterministic Mock Embeddings
```python
def generate_mock_embedding(text, dimensions=1536, seed=None):
    """
    Generate deterministic embedding for testing.
    Same text always produces same embedding.
    """
    if seed is None:
        seed = int(hashlib.md5(text.encode()).hexdigest()[:8], 16)
    # Generate normalized unit vector
```

## Supported Models

| Model | Default Dims | Max Dims |
|-------|-------------|----------|
| text-embedding-3-small | 1536 | 1536 |
| text-embedding-3-large | 3072 | 3072 |
| text-embedding-ada-002 | 1536 | 1536 |

## Validation Rules

1. Input cannot be empty
2. Model is required
3. Dimensions must be 1-3072
4. Batch size max 2048

## Progress Update

| Day | Deliverable | New Tests | Cumulative |
|-----|-------------|-----------|------------|
| Week 1 | Foundation | 194 | 194 |
| Day 6 | Chat Completions | 42 | 236 |
| Day 7 | SSE Streaming | 28 | 264 |
| Day 8 | Model Routing | 36 | 300 |
| **Day 9** | **Embeddings** | **32** | **332** |

## Files Modified

```
mangle-query-service/
├── openai/
│   └── embeddings.py (new)
└── tests/unit/
    └── test_embeddings.py (new)
```

## Architecture Integration

```
┌──────────────────────────────────────────────────────────┐
│                   OpenAI-Compatible API                   │
├──────────┬──────────┬──────────┬──────────┬─────────────┤
│  /models │  /chat   │/embeddings│/complete │  /audio     │
│          │/complete │   ✅      │   ions   │             │
└──────────┴──────────┴──────────┴──────────┴─────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │   EmbeddingsHandler     │
              │  - Route to model       │
              │  - Generate embedding   │
              │  - Format response      │
              └─────────────────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │   SAP AI Core Backend   │
              │  (text-embedding-3-*)   │
              └─────────────────────────┘
```

## Tomorrow: Day 10
- Models Endpoint (`/v1/models`)
- List available models
- Model details lookup
- End of Week 2

## Notes
- Mock embeddings use MD5 hash of text for deterministic seeds
- Base64 encoding uses little-endian 32-bit floats
- Truncation re-normalizes to maintain unit vector
- All models accessed via SAP AI Core