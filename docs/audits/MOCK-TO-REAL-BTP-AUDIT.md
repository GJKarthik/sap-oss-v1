# Mock to Real BTP Connections Audit

> **Date:** February 26, 2026  
> **Status:** In Progress  
> **Scope:** Replace all mock/stub implementations with real BTP connections

---

## Executive Summary

This audit identifies all mock/stub implementations across the codebase and provides a plan to replace them with real BTP service connections (HANA Cloud, AI Core, Object Store).

## Verified BTP Services

| Service | Status | Credentials Tested |
|---------|--------|-------------------|
| **HANA Cloud** | ✅ Working | Vector Engine, COSINE_SIMILARITY |
| **AI Core** | ✅ Working | Claude 3.5 Sonnet, 7 deployments |
| **Object Store** | ✅ Working | S3 bucket operations |

---

## Discovery Results

### ai-sdk-js-main (TypeScript/JavaScript)

#### Critical Mocks to Replace

| File | Mock Type | Replacement Needed | Priority |
|------|-----------|-------------------|----------|
| `packages/vllm/tests/mock-vllm-server.ts` | Full vLLM server mock | Real AI Core connection | P0 |
| `packages/foundation-models/src/azure-openai/*.test.ts` | Azure OpenAI mock responses | Real AI Core embeddings/chat | P1 |
| `packages/document-grounding/src/tests/vector-api.test.ts` | Mock vector API | Real HANA Vector Engine | P0 |
| `packages/langchain/src/orchestration/*.test.ts` | Mock orchestration client | Real AI Core orchestration | P1 |
| `packages/core/src/http-client.test.ts` | Mock HTTP client | Real BTP service calls | P2 |

#### Files with Jest Mocks (30+)

```
packages/prompt-registry/src/tests/prompt-templates-api.test.ts
packages/core/src/openapi-request-builder.test.ts
packages/core/src/http-client.test.ts
packages/core/src/context.test.ts
packages/langchain/src/orchestration/util.test.ts
packages/langchain/src/orchestration/client.test.ts
packages/langchain/src/openai/util.test.ts
packages/langchain/src/openai/chat.test.ts
packages/rpt/src/client.test.ts
packages/foundation-models/src/azure-openai/azure-openai-chat-completion-response.test.ts
packages/foundation-models/src/azure-openai/azure-openai-embedding-response.test.ts
packages/foundation-models/src/azure-openai/azure-openai-embedding-client.test.ts
packages/foundation-models/src/azure-openai/azure-openai-chat-completion-stream-chunk-response.test.ts
packages/foundation-models/src/azure-openai/azure-openai-chat-client.test.ts
packages/foundation-models/src/azure-openai/azure-openai-chat-completion-stream.test.ts
packages/vllm/tests/*.test.ts (10+ files)
packages/document-grounding/src/tests/*.test.ts (3+ files)
packages/orchestration/src/orchestration-stream-response.test.ts
```

### cap-llm-plugin-main (TypeScript)

| File | Mock Type | Replacement Needed | Priority |
|------|-----------|-------------------|----------|
| `tests/*.test.ts` | Mock LLM responses | Real AI Core chat | P1 |
| `src/` service mocks | Mock CAP services | Real BTP integration | P1 |

### langchain-integration-for-sap-hana-cloud-main (Python)

| File | Mock Type | Replacement Needed | Priority |
|------|-----------|-------------------|----------|
| `tests/unit_tests/test_hana_rdf_graph.py` | Mock HANA RDF Graph | Real HANA Knowledge Graph | P0 |
| `tests/unit_tests/test_create_where_clause.py` | Mock SQL generation | Real HANA queries | P1 |

### generative-ai-toolkit-for-sap-hana-cloud-main (Python)

| File | Mock Type | Replacement Needed | Priority |
|------|-----------|-------------------|----------|
| `nutest/testscripts/tools/test_hana_agent_tool.py` | Mock HANA agent tool | Real HANA connection | P1 |

### data-cleaning-copilot-main (Python)

| File | Mock Type | Replacement Needed | Priority |
|------|-----------|-------------------|----------|
| `definition/odata/tests/test_database_integration.py` | Mock database | Real HANA Cloud | P1 |

---

## Implementation Plan

### Phase 1: Create Shared BTP Configuration Module

Create a central configuration that all repos can import:

```
shared/btp-config/
├── index.ts          # TypeScript exports
├── config.py         # Python exports
├── types.ts          # TypeScript types
├── hana-client.ts    # HANA connection factory
├── aicore-client.ts  # AI Core connection factory
├── s3-client.ts      # Object Store connection factory
└── .env.example      # Environment template
```

### Phase 2: Replace Critical Mocks (P0)

1. **MockVllmServer → Real AI Core**
   - Replace `packages/vllm/tests/mock-vllm-server.ts` with real AI Core client
   - Use Claude 3.5 Sonnet (deployment: `dca062058f34402b`)

2. **Mock Vector API → Real HANA Vector Engine**
   - Replace `packages/document-grounding/src/tests/vector-api.test.ts`
   - Use real COSINE_SIMILARITY searches

3. **Mock HANA RDF Graph → Real Knowledge Graph**
   - Replace `langchain.../tests/unit_tests/test_hana_rdf_graph.py`
   - Use real SPARQL queries

### Phase 3: Replace Important Mocks (P1)

1. Azure OpenAI mocks → AI Core embeddings/chat
2. Orchestration client mocks → Real orchestration
3. CAP LLM plugin mocks → Real AI Core
4. Database integration mocks → Real HANA

### Phase 4: Optional Mocks (P2)

Some unit test mocks may be kept for:
- Fast CI/CD pipelines (no network calls)
- Testing edge cases and error handling
- Offline development

---

## Environment Variables Required

```bash
# HANA Cloud
HANA_HOST=xxx.hana.prod-ap11.hanacloud.ondemand.com
HANA_PORT=443
HANA_USER=xxx
HANA_PASSWORD=xxx

# AI Core
AICORE_CLIENT_ID=xxx
AICORE_CLIENT_SECRET=xxx
AICORE_AUTH_URL=https://xxx.authentication.xxx.hana.ondemand.com/oauth/token
AICORE_BASE_URL=https://api.ai.xxx.aws.ml.hana.ondemand.com
AICORE_RESOURCE_GROUP=default
AICORE_CHAT_DEPLOYMENT_ID=dca062058f34402b

# Object Store
OBJECT_STORE_ACCESS_KEY=xxx
OBJECT_STORE_SECRET_KEY=xxx
OBJECT_STORE_BUCKET=xxx
OBJECT_STORE_ENDPOINT=https://s3.us-east-1.amazonaws.com
OBJECT_STORE_REGION=us-east-1
```

---

## Files to Create/Modify

### New Files

1. `shared/btp-config/` - Shared configuration module
2. `ai-sdk-js-main/packages/*/tests/integration/` - Integration test directories
3. Test environment setup scripts

### Modified Files

| Original Mock | Replacement | Changes Needed |
|---------------|-------------|----------------|
| `mock-vllm-server.ts` | `real-aicore-client.ts` | Replace mock responses with real API calls |
| `*.test.ts` with jest.mock | Add `*.integration.test.ts` | Create parallel integration tests |
| Python `@patch` decorators | Real HANA connections | Update to use env vars |

---

## Progress Tracking

- [ ] Create shared BTP config module
- [ ] Replace MockVllmServer with real AI Core
- [ ] Replace vector API mocks with real HANA
- [ ] Replace HANA RDF Graph mocks
- [ ] Update all test files with real connections
- [ ] Run full integration test suite
- [ ] Document remaining intentional mocks

---

## Risk Mitigation

1. **Keep unit tests fast**: Create separate integration test suite
2. **CI/CD considerations**: Use test flags to skip real BTP tests
3. **Credential security**: Use environment variables, never commit secrets
4. **Rate limiting**: Add delays between tests if needed

---

*Audit conducted: February 26, 2026*