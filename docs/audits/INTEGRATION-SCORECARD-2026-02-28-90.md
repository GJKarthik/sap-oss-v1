# Integration Scorecard (2026-02-28, Post-Hardening Pass)

## Overall Integration Rating

**9.0 / 10** (up from 8.1)

## What Changed

1. Federated MCP query path added in CAP MCP server
- `mangle_query` now attempts configured remote MCP endpoints (`CAP_LLM_REMOTE_MCP_ENDPOINTS`) before returning unknown.
- Service registry now includes local MCP endpoint and configured remote MCP endpoints.

2. Federated MCP query + orchestration in AI SDK MCP server
- Added remote MCP federation (`AI_SDK_REMOTE_MCP_ENDPOINTS`).
- `orchestration_run` now attempts remote MCP execution (`AI_SDK_ORCHESTRATION_MCP_ENDPOINT` or federated endpoints) and returns `status: federated` on success.
- `mangle_query` now attempts remote MCP endpoints before returning unknown.

3. World Monitor mesh observability upgrade
- Service registry expanded to include the full 13-service mesh.
- Added `refresh_services` tool to actively probe health endpoints and update per-service status/metadata.

4. Mangle Query Service MCP predicate transport fixed
- Predicates now call MCP servers using standard JSON-RPC `tools/call` on `/mcp`.
- Legacy `/mcp/tools/*` path retained as fallback for compatibility.
- Added regression test proving JSON-RPC MCP call path.

## Evidence (Code References)

- CAP federated `mangle_query`:
  - `cap-llm-plugin-main/mcp-server/src/server.ts`
- AI SDK federated orchestration + `mangle_query`:
  - `ai-sdk-js-main/packages/mcp-server/src/server.ts`
- World Monitor 13-service registry + refresh:
  - `world-monitor-main/mcp_server/server.py`
- Mangle predicate MCP JSON-RPC client + fallback:
  - `mangle-query-service/internal/predicates/mcp_client.go`
  - `mangle-query-service/internal/predicates/mcp_classify.go`
  - `mangle-query-service/internal/predicates/mcp_entities.go`
  - `mangle-query-service/internal/predicates/mcp_rerank.go`
  - `mangle-query-service/internal/predicates/mcp_llm.go`
  - `mangle-query-service/internal/predicates/mcp_test.go`

## Verification Commands

- `cd cap-llm-plugin-main/mcp-server && npm run build`
- `cd ai-sdk-js-main/packages/mcp-server && npm run build`
- `cd mangle-query-service && go test ./internal/predicates ./internal/server`
- `python3 -m py_compile world-monitor-main/mcp_server/server.py`

All commands passed.
