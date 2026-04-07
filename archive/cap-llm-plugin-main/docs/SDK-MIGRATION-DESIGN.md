# SDK Migration Design — Days 22–25

## Overview

Replace manual CDS destination HTTP calls in `getEmbeddingWithConfig()` and `getChatCompletionWithConfig()` with `@sap-ai-sdk/orchestration` clients. This eliminates custom model routing, URL construction, and payload formatting.

## Current Architecture (Pre-Migration)

```
EmbeddingConfig { destinationName, resourceGroup, deploymentUrl, modelName, apiVersion? }
     │
     ▼
cds.connect.to(destinationName) → destService.send({ query: URL, data, headers })
     │
     ▼
Manual URL: POST {deploymentUrl}/embeddings?api-version={apiVersion}
Manual headers: { "AI-Resource-Group": resourceGroup }
Manual model validation: supportedModels.gptEmbeddingModels.has(modelName)
```

## Target Architecture (Post-Migration)

```
OrchestrationEmbeddingClient(embeddingModuleConfig)
     │
     ▼
client.embed({ input: "text" })  ← SDK handles URL, auth, headers, model routing
     │
     ▼
OrchestrationEmbeddingResponse.getEmbeddings() → EmbeddingData[]
```

## Mapping: EmbeddingConfig → SDK Types

| Current (EmbeddingConfig) | SDK Type                                               | Notes                       |
| ------------------------- | ------------------------------------------------------ | --------------------------- |
| `modelName`               | `EmbeddingModelDetails.name` (type: `EmbeddingModel`)  | SDK validates model support |
| `deploymentUrl`           | Not needed — SDK resolves via AI Core                  |                             |
| `destinationName`         | Not needed — SDK uses AI Core destination binding      |                             |
| `resourceGroup`           | `ResourceGroupConfig.resourceGroup` (optional 2nd arg) |                             |
| `apiVersion`              | Not needed — SDK manages API versioning                |                             |

### Embedding Migration (Day 22)

```typescript
// BEFORE (current):
async getEmbeddingWithConfig(config: EmbeddingConfig, input: unknown) {
  // 30+ lines: validate model, build URL, connect to dest, send HTTP
  const destService = await cds.connect.to(config.destinationName);
  const response = await destService.send({ query: url, data: { input }, headers });
  return response;
}

// AFTER (SDK):
async getEmbeddingWithConfig(config: EmbeddingConfig, input: string | string[]) {
  const client = new OrchestrationEmbeddingClient(
    { embeddings: { model: { name: config.modelName as EmbeddingModel } } },
    { resourceGroup: config.resourceGroup }
  );
  const response = await client.embed({ input });
  return response;  // OrchestrationEmbeddingResponse
}
```

**Key decisions:**

- Return the full `OrchestrationEmbeddingResponse` (callers use `.getEmbeddings()`)
- `destinationName`, `deploymentUrl`, `apiVersion` become no-ops (kept in interface for backward compat)
- Remove `supportedModels.gptEmbeddingModels` — SDK validates model names via `EmbeddingModel` type

## Mapping: ChatConfig → SDK Types

| Current (ChatConfig) | SDK Type                                   | Notes         |
| -------------------- | ------------------------------------------ | ------------- |
| `modelName`          | `LlmModelDetails.name` (type: `ChatModel`) | SDK validates |
| `deploymentUrl`      | Not needed                                 |               |
| `destinationName`    | Not needed                                 |               |
| `resourceGroup`      | `ResourceGroupConfig.resourceGroup`        |               |
| `apiVersion`         | Not needed                                 |               |

### Chat Migration (Day 23)

```typescript
// BEFORE (current):
async getChatCompletionWithConfig(config: ChatConfig, payload: unknown) {
  // 40+ lines: validate model, build URL per model tag (gpt/gemini/claude), HTTP call
  const modelTagUrlMapping = { gpt: "...", gemini: "...", claude: "..." };
  const destService = await cds.connect.to(config.destinationName);
  return await destService.send({ query: modelTagUrlMapping[tag], data: payload, headers });
}

// AFTER (SDK):
async getChatCompletionWithConfig(config: ChatConfig, payload: unknown) {
  const client = new OrchestrationClient(
    {
      promptTemplating: {
        model: { name: config.modelName as ChatModel }
      }
    },
    { resourceGroup: config.resourceGroup }
  );
  const request: ChatCompletionRequest = {
    messages: (payload as any).messages ?? [],
    messagesHistory: (payload as any).messagesHistory
  };
  return await client.chatCompletion(request);
}
```

**Key decisions:**

- Remove `buildChatPayload()` (Day 24) — SDK handles GPT/Gemini/Claude payload differences internally
- Remove `supportedModels` constant entirely (Day 25) — SDK's `ChatModel`/`EmbeddingModel` types enforce valid models
- Remove model tag URL mapping — SDK routes to correct endpoint based on model name

## RAG Pipeline Simplification (Day 24)

```typescript
// BEFORE: embed → parse model-specific result → similaritySearch → buildChatPayload → chatCompletion
// AFTER:  embed → getEmbeddings()[0].embedding → similaritySearch → chatCompletion (SDK builds payload)
```

The `getRagResponseWithConfig()` method simplifies because:

1. No model-specific embedding result parsing (SDK normalizes via `getEmbeddings()`)
2. No `buildChatPayload()` needed (SDK handles model-specific payloads)
3. Simpler error surface (SDK throws typed errors)

## Backward Compatibility Strategy

- `EmbeddingConfig` and `ChatConfig` interfaces keep all fields (no breaking change)
- `destinationName`, `deploymentUrl`, `apiVersion` marked as `@deprecated` in JSDoc
- Deprecated `getEmbedding()`, `getChatCompletion()`, `getRagResponse()` remain unchanged (they delegate to `legacy.js`)
- Tests updated to mock SDK clients instead of raw HTTP/CDS destination calls

## Risk Mitigation

| Risk                                                             | Mitigation                                                                         |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| SDK requires AI Core service binding                             | Document prerequisite; existing destination-based approach stays in legacy methods |
| Model name mismatch (current names vs SDK `EmbeddingModel` type) | Map current names → SDK names if needed; SDK accepts `string` at runtime           |
| Breaking change for consumers passing raw `deploymentUrl`        | Keep fields optional; log deprecation warning if provided                          |
