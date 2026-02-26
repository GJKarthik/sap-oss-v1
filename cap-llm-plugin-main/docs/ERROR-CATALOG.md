# CAP LLM Plugin — Error Catalog

Every error code the plugin can throw, with its HTTP status, cause, enriched context fields, and remediation steps.

---

## Error Response Shape

All endpoints return errors in this envelope:

```json
{
  "error": {
    "code": "EMBEDDING_CONFIG_INVALID",
    "message": "The config is missing the parameter: \"modelName\".",
    "target": "modelName",
    "details": { "missingField": "modelName" },
    "innerError": { "code": "SDK_ERROR", "message": "..." }
  }
}
```

| Field | Required | Description |
|---|---|---|
| `code` | ✅ | Machine-readable error code (see table below) |
| `message` | ✅ | Human-readable description |
| `target` | ❌ | The field, parameter, or resource that caused the error |
| `details` | ❌ | Additional structured context (model name, cause, etc.) |
| `innerError` | ❌ | Inner/upstream SDK or DB error |

---

## Error Codes

### Config Validation Errors — HTTP 400

| Code | Thrown By | Cause | `details` Fields | Remediation |
|---|---|---|---|---|
| `EMBEDDING_CONFIG_INVALID` | `getEmbeddingWithConfig` | `modelName` or `resourceGroup` is missing or falsy | `missingField` | Supply the missing config parameter |
| `CHAT_CONFIG_INVALID` | `getChatCompletionWithConfig` | `modelName` or `resourceGroup` is missing or falsy | `missingField` | Supply the missing config parameter |
| `INVALID_SEQUENCE_ID` | `getAnonymizedData` | A sequenceId entry is not a string or number | `index`, `receivedType` | Ensure all sequenceId values are strings or numbers |
| `INVALID_ALGO_NAME` | `similaritySearch` (via `InvalidSimilaritySearchAlgoNameError`) | Algorithm name is not `COSINE_SIMILARITY` or `L2DISTANCE` | — | Use `COSINE_SIMILARITY` or `L2DISTANCE` |
| `UNSUPPORTED_FILTER_TYPE` | `getContentFilters` | `type` is not `"azure"` (case-insensitive) | `type`, `supportedTypes` | Use `type: "azure"` — the only currently supported provider |

### Not Found Errors — HTTP 404

| Code | Thrown By | Cause | `details` Fields | Remediation |
|---|---|---|---|---|
| `ENTITY_NOT_FOUND` | `getAnonymizedData` | CDS entity name not found in registered services | `entityName` | Verify `entityName` is `"<ServiceName>.<EntityName>"` and the service is loaded |
| `SEQUENCE_COLUMN_NOT_FOUND` | `getAnonymizedData` | No column with `@anonymize: 'is_sequence'` found on entity | `entityName` | Add `@anonymize: 'is_sequence'` to one column in the entity definition |

### Upstream / SDK / AI Core Errors — HTTP 500

| Code | Thrown By | Cause | `details` Fields | Remediation |
|---|---|---|---|---|
| `EMBEDDING_REQUEST_FAILED` | `getEmbeddingWithConfig` | `OrchestrationEmbeddingClient.embed()` threw | `modelName`, `resourceGroup`, `deploymentUrl`?, `cause` | Check AI Core connectivity, model deployment status, and credentials |
| `CHAT_COMPLETION_REQUEST_FAILED` | `getChatCompletionWithConfig` | `OrchestrationClient.chatCompletion()` threw | `modelName`, `resourceGroup`, `deploymentUrl`?, `cause` | Check AI Core connectivity, model deployment status, and credentials |
| `HARMONIZED_CHAT_FAILED` | `getHarmonizedChatCompletion` | `OrchestrationClient.chatCompletion()` threw | `cause` | Verify `clientConfig` and `chatCompletionConfig` structure match the SDK schema |
| `CONTENT_FILTER_FAILED` | `getContentFilters` | `buildAzureContentSafetyFilter()` threw | `type`, `cause` | Verify the filter `config` object matches the Azure Content Safety schema |
| `SIMILARITY_SEARCH_FAILED` | `similaritySearch` (wrapped) | HANA DB query failed | `tableName`, `cause` | Check HANA connectivity and that the table/column names exist |
| `ANONYMIZATION_FAILED` | `getAnonymizedData` | DB anonymized view query failed | `entityName`, `cause` | Verify the HANA anonymized view is created and accessible |
| `RAG_PIPELINE_FAILED` | `getRagResponseWithConfig` | Embedding, search, or chat step failed internally | `step`, `cause` | See inner `cause` for which step failed; remediate as per embedding or chat codes above |
| `UNKNOWN` | Any | Unrecognized thrown value (not a CAPLLMPluginError) | — | Inspect server logs for the original error |

---

## SDK Error Mapping

The plugin wraps SAP AI SDK errors at two levels:

### `@sap-ai-sdk/orchestration` → Plugin Error

| SDK Error / Scenario | Plugin Code | HTTP |
|---|---|---|
| `OrchestrationEmbeddingClient` throws (network, auth, rate-limit) | `EMBEDDING_REQUEST_FAILED` | 500 |
| `OrchestrationClient.chatCompletion` throws | `CHAT_COMPLETION_REQUEST_FAILED` or `HARMONIZED_CHAT_FAILED` | 500 |
| `buildAzureContentSafetyFilter` throws | `CONTENT_FILTER_FAILED` | 500 |
| Unsupported filter `type` | `UNSUPPORTED_FILTER_TYPE` | 400 |

### HANA DB / CDS → Plugin Error

| DB Scenario | Plugin Code | HTTP |
|---|---|---|
| HANA vector similarity query fails | `SIMILARITY_SEARCH_FAILED` | 500 |
| Anonymized view query fails | `ANONYMIZATION_FAILED` | 500 |
| Entity not in CDS model | `ENTITY_NOT_FOUND` | 404 |
| No `@anonymize: 'is_sequence'` column | `SEQUENCE_COLUMN_NOT_FOUND` | 404 |

### Config Validation → Plugin Error

Config validation runs **before** any SDK call and always returns 400:

| Validation Failure | Plugin Code |
|---|---|
| `config.modelName` missing (embedding) | `EMBEDDING_CONFIG_INVALID` |
| `config.resourceGroup` missing (embedding) | `EMBEDDING_CONFIG_INVALID` |
| `config.modelName` missing (chat) | `CHAT_CONFIG_INVALID` |
| `config.resourceGroup` missing (chat) | `CHAT_CONFIG_INVALID` |
| Invalid algo name | `INVALID_ALGO_NAME` |
| Unsupported filter type | `UNSUPPORTED_FILTER_TYPE` |
| Invalid sequenceId type | `INVALID_SEQUENCE_ID` |

### Legacy Error Mapping Note

`InvalidSimilaritySearchAlgoNameError` (in `srv/errors/`) is a legacy class that stores a **numeric** HTTP status (`400`) in its `.code` field instead of a string error code. `toErrorResponse()` detects it by class name (`err.name === "InvalidSimilaritySearchAlgoNameError"`) and maps it to `INVALID_ALGO_NAME / HTTP 400` before the general duck-type check runs.

---

## Enriched Context Fields Reference

Upstream errors include these fields in `details` to aid debugging:

| Field | Present In | Description |
|---|---|---|
| `modelName` | `EMBEDDING_REQUEST_FAILED`, `CHAT_COMPLETION_REQUEST_FAILED` | The model name from `config.modelName` |
| `resourceGroup` | `EMBEDDING_REQUEST_FAILED`, `CHAT_COMPLETION_REQUEST_FAILED` | The resource group from `config.resourceGroup` |
| `deploymentUrl` | `EMBEDDING_REQUEST_FAILED`, `CHAT_COMPLETION_REQUEST_FAILED` | The deployment URL from `config.deploymentUrl` (omitted if not set) |
| `cause` | All `*_FAILED` codes | The original error message from the SDK or DB |
| `missingField` | `EMBEDDING_CONFIG_INVALID`, `CHAT_CONFIG_INVALID` | The name of the missing config parameter |
| `type` | `UNSUPPORTED_FILTER_TYPE`, `CONTENT_FILTER_FAILED` | The filter type that was passed |
| `supportedTypes` | `UNSUPPORTED_FILTER_TYPE` | Array of currently supported types (`["azure"]`) |
| `entityName` | `ENTITY_NOT_FOUND`, `SEQUENCE_COLUMN_NOT_FOUND`, `ANONYMIZATION_FAILED` | The CDS entity name |
| `algoName` | `INVALID_ALGO_NAME` | The invalid algorithm name that was passed |
| `index` | `INVALID_SEQUENCE_ID` | The index in the sequenceIds array that failed validation |
| `receivedType` | `INVALID_SEQUENCE_ID` | The JS typeof of the invalid value |

---

## Example Error Responses

### 400 — Missing config field

```http
POST /api/embedding
{ "config": {}, "input": "Hello" }

HTTP/1.1 400 Bad Request
{
  "error": {
    "code": "EMBEDDING_CONFIG_INVALID",
    "message": "The config is missing the parameter: \"modelName\".",
    "details": { "missingField": "modelName" }
  }
}
```

### 400 — Unsupported filter type

```http
POST /api/filters
{ "type": "openai", "config": {} }

HTTP/1.1 400 Bad Request
{
  "error": {
    "code": "UNSUPPORTED_FILTER_TYPE",
    "message": "Unsupported type openai. The currently supported type is 'azure'.",
    "details": { "type": "openai", "supportedTypes": ["azure"] }
  }
}
```

### 404 — Entity not found

```http
HTTP/1.1 404 Not Found
{
  "error": {
    "code": "ENTITY_NOT_FOUND",
    "message": "Entity \"MyService.MyEntity\" not found in CDS services.",
    "details": { "entityName": "MyService.MyEntity" }
  }
}
```

### 500 — Upstream AI Core failure (enriched)

```http
HTTP/1.1 500 Internal Server Error
{
  "error": {
    "code": "EMBEDDING_REQUEST_FAILED",
    "message": "Embedding request failed: AI Core returned 503.",
    "details": {
      "modelName": "text-embedding-ada-002",
      "resourceGroup": "default",
      "deploymentUrl": "https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com/v2/inference/deployments/abc123",
      "cause": "AI Core returned 503."
    }
  }
}
```
