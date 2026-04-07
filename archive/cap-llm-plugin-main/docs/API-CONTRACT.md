# CAP LLM Plugin — API Contract Design

This document describes the typed API contract for the cap-llm-plugin CDS service.
The contract is defined in `srv/llm-service.cds` and serves as the single source of
truth for both backend implementation and frontend client generation.

---

## Endpoints Inventory

| # | Action | Category | Input | Output |
|---|--------|----------|-------|--------|
| 1 | `getEmbeddingWithConfig` | Embedding | `EmbeddingConfig`, input text | SDK embedding response |
| 2 | `getChatCompletionWithConfig` | Chat | `ChatConfig`, messages array | SDK chat completion response |
| 3 | `getRagResponse` | RAG Pipeline | input, table, columns, configs, context | `{ completion, additionalContents }` |
| 4 | `similaritySearch` | Search | table, columns, embedding vector, algo, topK | `SimilaritySearchResult[]` |
| 5 | `getAnonymizedData` | Anonymization | entity name, sequence IDs | Anonymized rows |
| 6 | `getHarmonizedChatCompletion` | Orchestration | client config, completion config, flags | Response / content / usage / reason |
| 7 | `getContentFilters` | Orchestration | type, filter config | Filter object |

> **Note:** Legacy methods (`getEmbedding`, `getChatCompletion`, `getRagResponse` without config)
> are deprecated and excluded from the contract.

---

## Shared Types

### EmbeddingConfig

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `modelName` | `String` | Yes | SDK model name (e.g., `"text-embedding-ada-002"`) |
| `resourceGroup` | `String` | Yes | AI Core resource group |
| `destinationName` | `String` | No | BTP destination name |
| `deploymentUrl` | `String` | No | Deployment URL path |

### ChatConfig

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `modelName` | `String` | Yes | SDK model name (e.g., `"gpt-4o"`) |
| `resourceGroup` | `String` | Yes | AI Core resource group |
| `destinationName` | `String` | No | BTP destination name |
| `deploymentUrl` | `String` | No | Deployment URL path |

### ChatMessage

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `role` | `String` | Yes | Message role: `"system"`, `"user"`, `"assistant"` |
| `content` | `String` | Yes | Message text |

### SimilaritySearchResult

| Field | Type | Description |
|-------|------|-------------|
| `PAGE_CONTENT` | `String` | Text content from the matched document |
| `SCORE` | `Double` | Similarity score |

---

## Error Response Schema

All actions return errors in a consistent structure. Errors are instances of
`CAPLLMPluginError` (or its subclasses) and are serialized as:

```json
{
  "error": {
    "code": "EMBEDDING_CONFIG_INVALID",
    "message": "The config is missing the parameter: \"modelName\".",
    "details": {
      "missingField": "modelName"
    }
  }
}
```

### Error Codes

| Code | Error Class | Thrown By |
|------|-------------|-----------|
| `ENTITY_NOT_FOUND` | `AnonymizationError` | `getAnonymizedData` |
| `SEQUENCE_COLUMN_NOT_FOUND` | `AnonymizationError` | `getAnonymizedData` |
| `INVALID_SEQUENCE_ID` | `AnonymizationError` | `getAnonymizedData` |
| `EMBEDDING_CONFIG_INVALID` | `EmbeddingError` | `getEmbeddingWithConfig` |
| `EMBEDDING_REQUEST_FAILED` | `EmbeddingError` | `getEmbeddingWithConfig` |
| `CHAT_CONFIG_INVALID` | `ChatCompletionError` | `getChatCompletionWithConfig` |
| `CHAT_COMPLETION_REQUEST_FAILED` | `ChatCompletionError` | `getChatCompletionWithConfig` |
| `HARMONIZED_CHAT_FAILED` | `ChatCompletionError` | `getHarmonizedChatCompletion` |
| `UNSUPPORTED_FILTER_TYPE` | `ChatCompletionError` | `getContentFilters` |
| `CONTENT_FILTER_FAILED` | `ChatCompletionError` | `getContentFilters` |
| `INVALID_ALGO_NAME` | `InvalidSimilaritySearchAlgoNameError` | `similaritySearch` |

### Error Class Hierarchy

```
Error
 └─ CAPLLMPluginError          { code, message, details? }
     ├─ AnonymizationError
     ├─ EmbeddingError
     ├─ ChatCompletionError
     └─ SimilaritySearchError
```

---

## Contract-First Workflow

1. **Define** — Edit `srv/llm-service.cds`
2. **Generate OpenAPI** — `cds compile srv/llm-service.cds --to openapi > docs/api/openapi.yaml`
3. **Generate Client** — `openapi-generator-cli generate -i docs/api/openapi.yaml -g typescript-angular -o generated/angular-client`
4. **CI Validation** — Re-generate specs in CI; fail if they differ from committed versions

See Day 37–40 in the roadmap for implementation of steps 2–4.
