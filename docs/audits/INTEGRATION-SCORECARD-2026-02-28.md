# Integration Scorecard (2026-02-28)

## Overall Integration Rating

**8.1 / 10**

This score reflects cross-service integration quality across the 13-service set: protocol consistency, runtime wiring, health/discovery, resilience, and integration test maturity.

## Category Breakdown

| Category | Score | Notes |
|---|---:|---|
| Protocol + Contract Alignment | 8.8 | Strong MCP usage plus a defined gRPC contract for Mangle Query Service. |
| Runtime Connectivity | 7.8 | Several edges are real (vLLM, Elasticsearch, AI Core), but some service handlers are still placeholders. |
| Service Discovery + Health | 8.0 | Health endpoints are broadly present, but registry coverage is partial and mostly static. |
| Resilience + Guardrails | 9.1 | Good request validation, clamping, and safer health/readiness behavior across services. |
| Integration Test Maturity | 6.8 | Good unit coverage in places, but limited true cross-service end-to-end verification. |

## Key Integration Edges

| Integration Edge | Score | Status |
|---|---:|---|
| `ai-sdk-js` ↔ `vllm` | 8.9 | Real OpenAI-compatible calls + local compose examples. |
| `ai-sdk-js` ↔ `elasticsearch` | 8.8 | Real vector/semantic search path implemented. |
| `data-cleaning-copilot` ↔ `odata-vocabularies` | 8.7 | Direct file-based vocabulary consumption with dedicated tests. |
| `mangle-query-service` ↔ `elasticsearch` | 8.4 | Runtime predicate/server wiring present. |
| `cap-llm-plugin` ↔ `mangle-query-service` | 6.9 | Contract exists, but CAP MCP `mangle_query` path is local fact lookup today. |
| `world-monitor` ↔ service mesh | 7.0 | Static registry/health tooling exists, but only partial service coverage. |
| `langchain`/`genai-toolkit` ↔ HANA paths | 7.0 | Multiple handlers explicitly marked placeholder/connect-to-HANA. |

## Evidence Anchors

- CAP MCP local `mangle_query` fact lookup: `cap-llm-plugin-main/mcp-server/src/server.ts`
- AI SDK MCP orchestration + mangle tool are local/placeholder:
  - `ai-sdk-js-main/packages/mcp-server/src/server.ts`
- World Monitor static service registry:
  - `world-monitor-main/mcp_server/server.py`
- LangChain MCP placeholder vector/RAG handlers:
  - `langchain-integration-for-sap-hana-cloud-main/mcp_server/server.py`
- GenAI Toolkit placeholder vector/RAG handlers:
  - `generative-ai-toolkit-for-sap-hana-cloud-main/mcp_server/server.py`
- Data Cleaning MCP placeholder quality/anomaly handlers:
  - `data-cleaning-copilot-main/mcp_server/server.py`
- Mangle Query Service gRPC contract + MCP heuristic fallback:
  - `mangle-query-service/client/typescript/query.proto`
  - `mangle-query-service/internal/predicates/mcp_classify.go`
  - `mangle-query-service/internal/predicates/mcp_test.go`
- Strong real runtime paths:
  - `vllm-main/mcp_server/server.py`
  - `elasticsearch-main/mcp_server/server.py`
  - `data-cleaning-copilot-main/definition/odata/test_odata_integration.py`
