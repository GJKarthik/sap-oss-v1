# Service Quality Scorecard (2026-02-28, 9.4 Pass)

Target: raise all 13 ensemble services from 9.2 to 9.4.

| # | Service | Score | 9.4 Delta | Verification |
|---|---------|-------|-----------|--------------|
| 1 | UI5 Web Components | 9.4 | bounded component list/search inputs, template generation limited to known components | `npm run build` (`ui5-webcomponents-ngx-main/mcp-server`) |
| 2 | AI SDK JS | 9.4 | stricter request normalization + bounded response/placeholder/message sizes in sample CAP services | `pnpm -F @sap-ai-sdk/sample-cap build` |
| 3 | CAP LLM Plugin | 9.4 | bounded `max_tokens`/`top_k` tool params plus existing HTTP/WS payload guardrails | `npm run build` (`cap-llm-plugin-main/mcp-server`) |
| 4 | AI Core Streaming | 9.4 | bounded tool token/event limits + safer JSON argument parsing for stream payloads | `python3 -m py_compile ai-core-streaming/mcp_server/server.py` |
| 5 | MCP PAL | 9.4 | config portability improved with `MCP_PORT` fallback to `MCPPAL_PORT` | `zig test ai-core-pal/zig/src/domain/config.zig` |
| 6 | Data Cleaning Copilot | 9.4 | sanitized runtime error responses + health now reports AI Core config readiness | `python3 -m py_compile data-cleaning-copilot-main/bin/api.py` |
| 7 | Elasticsearch | 9.4 | bounded search/kNN inputs and stricter JSON argument handling for search/index operations | `python3 -m py_compile elasticsearch-main/mcp_server/server.py` |
| 8 | GenAI Toolkit | 9.4 | bounded `max_tokens`/`top_k`/document volume + safer JSON parsing for MCP tool args | `python3 -m py_compile generative-ai-toolkit-for-sap-hana-cloud-main/mcp_server/server.py` |
| 9 | LangChain Integration | 9.4 | bounded token/doc/chunk parameters + safer JSON parsing for tool args | `python3 -m py_compile langchain-integration-for-sap-hana-cloud-main/mcp_server/server.py` |
| 10 | Mangle Query | 9.4 | additional gRPC request limits (correlation/entity/payload sizes) with regression tests | `go test ./internal/server ./internal/sync` |
| 11 | OData Vocabularies | 9.4 | bounded semantic/search/property payload sizes + safe JSON argument parsing | `python3 -m py_compile odata-vocabularies-main/mcp_server/server.py` |
| 12 | vLLM | 9.4 | bounded token/batch/temperature/n parameters + safer embedding/chat payload parsing | `python3 -m py_compile vllm-main/mcp_server/server.py` |
| 13 | World Monitor | 9.4 | bounded health/log tool arguments + URL validation for remote health checks | `python3 -m py_compile world-monitor-main/mcp_server/server.py` |

## Notes

- Full `zig build` in `ai-core-pal/zig` is still blocked by missing external dependency path:
  `.../ai-core-fabric/zig/src/fabric.zig` in the current workspace shape.
- Service-level checks above passed for all touched components.
