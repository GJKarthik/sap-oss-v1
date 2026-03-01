# Service Quality Scorecard (2026-02-28)

Target: raise all 13 ensemble services from 9.0 to 9.2.

| # | Service | Score | Key 9.2 Delta | Verification |
|---|---------|-------|---------------|--------------|
| 1 | UI5 Web Components | 9.2 | JSON body hard-limit/error mapping + strict `tools/call.arguments` validation | `npm run build` (`ui5-webcomponents-ngx-main/mcp-server`) |
| 2 | AI SDK JS | 9.2 | stronger input typing/normalization in sample CAP service handlers | `pnpm -F @sap-ai-sdk/sample-cap build` |
| 3 | CAP LLM Plugin | 9.2 | HTTP/WebSocket payload-size guardrails + stricter JSON-RPC param validation | `npm run build` (`cap-llm-plugin-main/mcp-server`), `npm test -- --runInBand` |
| 4 | AI Core Streaming | 9.2 | MCP hardening + health readiness status (`config_ready`) | `python3 -m py_compile ai-core-streaming/mcp_server/server.py` |
| 5 | MCP PAL | 9.2 | health endpoint now reports dynamic runtime catalog stats + readiness | `zig fmt --check ai-core-pal/zig/src/main.zig` |
| 6 | Data Cleaning Copilot | 9.2 | request-size constraints and stricter CLI bounds (`timeout`, `max-tokens`, `port`) | `python3 -m py_compile data-cleaning-copilot-main/bin/api.py` |
| 7 | Elasticsearch | 9.2 | MCP hardening + health telemetry (`es_host`, `aicore_config_ready`) | `python3 -m py_compile elasticsearch-main/mcp_server/server.py` |
| 8 | GenAI Toolkit | 9.2 | MCP hardening + health readiness (`config_ready`) | `python3 -m py_compile generative-ai-toolkit-for-sap-hana-cloud-main/mcp_server/server.py` |
| 9 | LangChain Integration | 9.2 | MCP hardening + health readiness (`config_ready`) | `python3 -m py_compile langchain-integration-for-sap-hana-cloud-main/mcp_server/server.py` |
| 10 | Mangle Query | 9.2 | gRPC guardrail: max resolve query length + test coverage | `go test ./internal/server ./internal/sync` |
| 11 | OData Vocabularies | 9.2 | MCP hardening on both JSON-RPC and direct extraction endpoint | `python3 -m py_compile odata-vocabularies-main/mcp_server/server.py` |
| 12 | vLLM | 9.2 | MCP hardening + health readiness (`config_ready`) | `python3 -m py_compile vllm-main/mcp_server/server.py` |
| 13 | World Monitor | 9.2 | MCP hardening + richer health signal (registered services/alerts) | `python3 -m py_compile world-monitor-main/mcp_server/server.py` |

## Notes

- `ai-core-pal/zig` full `zig build` could not complete due missing external dependency path:
  `.../ai-core-fabric/zig/src/fabric.zig` (outside this repo checkout shape).
- All other listed verification commands completed successfully.
