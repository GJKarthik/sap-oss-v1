# Day 11: SAP AI Core Handler Integration

## Date: 2026-03-01

## Objective
Wire `SAPAICoreClient` into completions handler for automatic routing based on model family.

## Deliverables

### 1. aicore_handler.py (360 lines)
Production handler that uses `SAPAICoreClient` for automatic routing.

**Features:**
- `DeploymentResolver`: Maps model IDs to SAP AI Core deployment IDs
  - Queries `/v2/lm/deployments` API
  - Caches resolutions for performance
  - Supports manual override via `set_deployment()`
- `AICoreCompletionsHandler`: OpenAI-compatible chat completions via AI Core
  - Automatic model family detection (Claude, GPT, Gemini, Mistral)
  - Request/response format transformation
  - OAuth2 token management
  - Streaming and non-streaming modes

**Architecture:**
```
Request (OpenAI format)
    ↓
DeploymentResolver → find matching deployment
    ↓
SAPAICoreClient.chat_completion()
    ↓
Model Family Detection:
  - Claude → /invoke + bedrock format
  - GPT   → /chat/completions + OpenAI format
    ↓
Response (normalized to OpenAI format)
```

### 2. test_aicore_handler.py (250 lines)
Integration tests for AI Core handler.

**Test Coverage:**
- Deployment resolution
  - Claude model → correct deployment
  - GPT model → correct deployment
  - Stopped deployments skipped
  - Cache hit behavior
  - Manual override
- Handler functionality
  - Completion creation
  - Error handling (no deployment found)
  - Message conversion
  - Parameter passing (temperature, max_tokens, top_p)
- Live integration tests (skipped by default)

## Key Decisions

### 1. Deployment Resolution Strategy
Instead of hardcoding deployment IDs, the resolver:
1. Queries AI Core deployments API
2. Matches models by name/version/scenario
3. Falls back to first running foundation-models deployment
4. Caches results for performance

### 2. Response Normalization
All responses are normalized to OpenAI format regardless of backend:
- Claude (bedrock) → OpenAI format
- GPT → already OpenAI format
- Other models → OpenAI format

### 3. Handler Lifecycle
Uses async context manager pattern:
```python
async with AICoreCompletionsHandler() as handler:
    response = await handler.create_completion(request)
```

## Files Changed
```
mangle-query-service/
├── openai/
│   └── aicore_handler.py     # NEW: Production AI Core handler
└── tests/
    └── integration/
        └── test_aicore_handler.py  # NEW: Handler tests
```

## Integration Points

### Usage Example
```python
from openai.aicore_handler import AICoreCompletionsHandler
from openai.models import ChatCompletionRequest, ChatMessage

request = ChatCompletionRequest(
    model="claude-3.5-sonnet",
    messages=[ChatMessage(role="user", content="Hello!")],
    temperature=0.7,
)

async with AICoreCompletionsHandler() as handler:
    # Automatic: resolves deployment, transforms format, calls AI Core
    response = await handler.create_completion(request)
    print(response.choices[0].message.content)
```

### With Manual Deployment
```python
async with AICoreCompletionsHandler() as handler:
    # Override deployment for specific model
    handler.set_deployment("my-custom-model", "deployment-xyz")
    response = await handler.create_completion(request)
```

## Test Results
```
tests/integration/test_aicore_handler.py
├── TestDeploymentResolver
│   ├── test_resolve_claude_model ✓
│   ├── test_resolve_gpt_model ✓
│   ├── test_skip_stopped_deployments ✓
│   ├── test_manual_deployment_override ✓
│   └── test_cache_hit ✓
├── TestAICoreCompletionsHandler
│   ├── test_create_completion ✓
│   ├── test_no_deployment_found ✓
│   ├── test_message_conversion ✓
│   └── test_kwargs_passed_correctly ✓
└── TestLiveIntegration (skipped)
```

## Day 10 → Day 11 Progress
| Component | Day 10 | Day 11 |
|-----------|--------|--------|
| aicore_adapter.py | ✅ Created | ✅ Used by handler |
| aicore_handler.py | ❌ | ✅ Created |
| Deployment resolution | ❌ | ✅ Automatic |
| Model detection | ✅ | ✅ Integrated |
| Format transformation | ✅ | ✅ Integrated |
| Tests | 19 | 19 + 9 = 28 |

## Next Steps (Day 12)
1. Wire handler into FastAPI router
2. Add streaming endpoint support
3. Create unified router that selects handler based on provider
4. Performance benchmarking