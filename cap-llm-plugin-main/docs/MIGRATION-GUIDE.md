# Migration Guide: v1.x → v2.0

This guide covers breaking changes and migration steps for upgrading from
cap-llm-plugin v1.x (JavaScript, manual HTTP) to v2.0 (TypeScript, SDK-based).

---

## Overview of Changes

| Area                     | v1.x                                                      | v2.0                                   |
| ------------------------ | --------------------------------------------------------- | -------------------------------------- |
| **Language**             | JavaScript                                                | TypeScript (compiled to JS)            |
| **AI Backend**           | Manual CDS destination HTTP calls                         | `@sap-ai-sdk/orchestration` SDK        |
| **Model Routing**        | `supportedModels` + `modelTagUrlMapping`                  | SDK handles internally                 |
| **Payload Construction** | `buildChatPayload()` (GPT/Gemini/Claude)                  | SDK handles internally                 |
| **Type Safety**          | None                                                      | Full `.d.ts` declarations              |
| **Config Fields**        | `destinationName`, `deploymentUrl`, `apiVersion` required | `modelName` + `resourceGroup` required |

---

## Breaking Changes

### 1. Embedding Response Format Changed

**v1.x:** Raw HTTP response with `data[0].embedding`.

```javascript
// v1.x
const resp = await plugin.getEmbeddingWithConfig(config, input);
const vector = resp?.data[0]?.embedding;
```

**v2.0:** SDK response with `.getEmbeddings()` method.

```typescript
// v2.0
const resp = await plugin.getEmbeddingWithConfig(config, input);
const vector = resp.getEmbeddings()[0].embedding;
```

### 2. `buildChatPayload()` Removed

This method no longer exists. The SDK constructs model-specific payloads internally.

**v1.x:** Consumers could call `buildChatPayload()` to construct GPT/Gemini/Claude payloads.

**v2.0:** Pass a unified `{ messages: [...] }` payload to `getChatCompletionWithConfig()`.
The SDK handles all model-specific formatting.

```typescript
// v2.0 — unified message format for all models
const response = await plugin.getChatCompletionWithConfig(chatConfig, {
  messages: [
    { role: "system", content: "You are a helpful assistant." },
    { role: "user", content: "Hello" },
  ],
});
```

### 3. `supportedModels` Constant Removed

The internal `supportedModels` object (containing `gptChatModels`, `geminiChatModels`,
`claudeChatModels`, `gptEmbeddingModels`) has been removed. The SDK validates model
names at runtime.

**Action:** If your code referenced supported model lists for validation,
remove those checks — the SDK will throw descriptive errors for unsupported models.

### 4. Config Object Simplification

**v1.x config fields:**

```json
{
  "destinationName": "AICoreAzureOpenAIDestination",
  "deploymentUrl": "/v2/inference/deployments/abc123",
  "resourceGroup": "default",
  "apiVersion": "2024-02-15-preview",
  "modelName": "gpt-4o"
}
```

**v2.0 required fields:**

```json
{
  "modelName": "gpt-4o",
  "resourceGroup": "default"
}
```

The `destinationName`, `deploymentUrl`, and `apiVersion` fields are still accepted
in the `EmbeddingConfig` / `ChatConfig` types for backward compatibility but are
**no longer used** — the SDK resolves connectivity automatically.

### 5. Chat Completion Response Format Changed

**v1.x:** Raw HTTP response from the model provider.

**v2.0:** SDK `OrchestrationResponse` object with helper methods:

- `.getContent()` — extracted message content
- `.getTokenUsage()` — token usage stats
- `.getFinishReason()` — completion finish reason

---

## Migration Steps

### Step 1: Install the SDK peer dependency

```bash
npm install @sap-ai-sdk/orchestration@latest
```

### Step 2: Bind SAP AI Core service

The SDK needs a bound AI Core service instance (not CDS destinations).

```bash
cf create-service-key <ai-core-instance> <key-name>
cds bind -2 <ai-core-instance>:<key-name>
```

### Step 3: Update config objects

Ensure all config objects have `modelName` and `resourceGroup`:

```json
{
  "cds": {
    "requires": {
      "gen-ai-hub": {
        "embedding": {
          "modelName": "text-embedding-ada-002",
          "resourceGroup": "default"
        },
        "chat": {
          "modelName": "gpt-4o",
          "resourceGroup": "default"
        }
      }
    }
  }
}
```

### Step 4: Update embedding response parsing

```diff
- const vector = resp?.data[0]?.embedding;
+ const vector = resp.getEmbeddings()[0].embedding;
```

### Step 5: Remove `buildChatPayload()` calls

```diff
- const payload = await plugin.buildChatPayload(config, systemPrompt, chatHistory, userQuery);
- const response = await plugin.getChatCompletionWithConfig(config, payload);
+ const response = await plugin.getChatCompletionWithConfig(config, {
+   messages: [
+     { role: "system", content: systemPrompt },
+     ...chatHistory,
+     { role: "user", content: userQuery },
+   ],
+ });
```

### Step 6: Migrate deprecated methods

| Deprecated                   | Replacement                                    |
| ---------------------------- | ---------------------------------------------- |
| `getEmbedding(input)`        | `getEmbeddingWithConfig(config, input)`        |
| `getChatCompletion(payload)` | `getChatCompletionWithConfig(config, payload)` |
| `getRagResponse(...)`        | `getRagResponseWithConfig(...)`                |

### Step 7: Add TypeScript types (optional)

```typescript
import type { EmbeddingConfig, ChatConfig, RagResponse } from "cap-llm-plugin";

const embeddingConfig: EmbeddingConfig = cds.env.requires["gen-ai-hub"]["embedding"];
const chatConfig: ChatConfig = cds.env.requires["gen-ai-hub"]["chat"];
```

---

## Backward Compatibility

- The `EmbeddingConfig` and `ChatConfig` interfaces still accept legacy fields
  (`destinationName`, `deploymentUrl`, `apiVersion`) — they are silently ignored.
- Deprecated methods (`getEmbedding`, `getChatCompletion`, `getRagResponse`) still
  function using environment-based Azure OpenAI configuration.
- The `ChatPayload` union type (`GptChatPayload | GeminiChatPayload | ClaudeChatPayload`)
  is still exported for consumers who may reference it.
