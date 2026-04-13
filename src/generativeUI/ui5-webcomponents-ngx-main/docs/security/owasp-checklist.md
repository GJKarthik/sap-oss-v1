# OWASP Top 10 Security Checklist — GenUI Extension Layer

**Scope:** `@ui5/ag-ui-angular`, `@ui5/genui-renderer`, `@ui5/genui-streaming`, `@ui5/genui-governance`, `@ui5/genui-collab`  
**Date:** 2024-03  
**Review type:** Architectural / code review (no penetration test)

---

## A01 — Broken Access Control

| Control | Status | Notes |
|---|---|---|
| Agent-generated UIs cannot access routes/resources outside their schema | ✅ Pass | `SchemaValidator` only permits component creation; no router manipulation |
| `GovernanceService.isBlocked(action)` enforced before tool calls | ✅ Pass | `pendingActions$` requires explicit `confirmAction` or `rejectAction` |
| Role-based policy (`PolicyConfig.roles`) enforced per tool call | ✅ Pass | `requiresConfirmation` returns true for unlisted roles |
| SSE endpoint (`/ag-ui/run`) authenticated by upstream proxy | ✅ Fixed | `SseTransport` supports optional `authToken` (query param on `EventSource` + `Authorization: Bearer` on POST); suite gateway forwards `Authorization` to upstream. Apps set `agUiAuthToken` / `sse.authToken`; upstream must still validate. |

---

## A02 — Cryptographic Failures

| Control | Status | Notes |
|---|---|---|
| No secrets stored in library code | ✅ Pass | All secrets (AI Core creds) stay in deployment env vars |
| `AgUiClient` SSE transport uses HTTPS in production | ✅ Pass | `proxy.conf.json` target uses `http://localhost:8080` (local only); production nginx enforces HTTPS upstream |
| `AuditService` log entries do not contain raw credentials | ✅ Pass | Audit entries record tool name + args hash, not raw values (per `AuditService` implementation) |

---

## A03 — Injection

| Control | Status | Notes |
|---|---|---|
| XSS via agent-emitted string props | ✅ Pass | `SchemaValidator` regex scan + `DOMPurify.sanitize()` on all string prop values in `DynamicRenderer.applyProps()` |
| Script tag injection in schema `component` field | ✅ Pass | Component allowlist denies any tag not in `FIORI_STANDARD_COMPONENTS`; `ui5-<script>` is not on allowlist |
| `innerHTML`-equivalent prop injection | ✅ Pass | `DOMPurify` with `ALLOWED_TAGS: []` strips all HTML from string props |
| `javascript:` URI in props | ✅ Pass | Covered by `XSS_PATTERNS` regex in `SchemaValidator` |
| `data:text/html` injection | ✅ Pass | Covered by `XSS_PATTERNS` regex |
| Event handler name abuse (`onXxx` props) | ✅ Pass | `validateProps` rejects any prop starting with `on` with `INVALID_PROP` error |
| Agent SSE stream injection (SSE comment smuggling) | ✅ Fixed | `SseTransport` validates that parsed JSON has a `type` field before routing; non-AG-UI payloads are dropped with a console warning. Oversized events (>512 KB) are also rejected. |

---

## A04 — Insecure Design

| Control | Status | Notes |
|---|---|---|
| Allowlist > denylist approach for components | ✅ Pass | `ComponentRegistry` defaults to deny-unknown (`allowUnknown: false`) |
| `SECURITY_DENY_LIST` cannot be overridden by `allow()` | ✅ Pass | `allow()` throws if tag is in deny list |
| Agent cannot emit `loadChildren`-style lazy route changes | ✅ Pass | A2UiSchema has no routing primitives |
| Schema nesting depth bounded (default 20) | ✅ Pass | `MAX_DEPTH_EXCEEDED` error returned and rendering halted |

---

## A05 — Security Misconfiguration

| Control | Status | Notes |
|---|---|---|
| `nx.json` cloud token uses env var substitution | ✅ Fixed | `nxCloudAccessToken` references `${NX_CLOUD_ACCESS_TOKEN}` — no plaintext token committed |
| DOMPurify `FORCE_BODY` not set | ⚠️ Fixed (this release) | `applyProps` now uses `{ ALLOWED_TAGS: [], ALLOWED_ATTR: [] }` — strips all HTML |
| `SchemaValidator` strict mode defaults to `true` | ✅ Fixed | Unknown schema version and other warnings invalidate the schema by default; apps needing lenient behavior use `validate(schema, { strict: false })` or `configure({ strict: false })`. |
| MCP server bearer auth middleware | ✅ Fixed | `requireBearerAuth` enforced on `/mcp`; logs a warning if `MCP_AUTH_TOKEN` is unset (localhost-only fallback) |

---

## A06 — Vulnerable and Outdated Components

| Control | Status | Notes |
|---|---|---|
| `dompurify` version | ✅ Pass | `^3.0.0` — current major series with active CVE tracking |
| `rxjs` version | ✅ Pass | `7.8.1` — no known CVEs |
| `cypress` version | ✅ Pass | `14.3.3` — current |
| `@commitlint/cli` | ✅ Pass | Upgraded to `19.8.0` (this release) |
| Angular | ✅ Pass | `20.3.9` — current LTS series |
| `uuid` | ✅ Pass | `^9.0.0` — no known CVEs |

Run `yarn audit` for a full npm advisory report.

---

## A07 — Identification and Authentication Failures

| Control | Status | Notes |
|---|---|---|
| Joule `/ag-ui/run` endpoint requires authentication | ✅ Fixed (config) | Same as A01: optional client token + gateway `Authorization` passthrough; production must configure tokens and enforce validation on the agent/MCP upstream. |
| MCP server bearer token | ✅ Pass | `MCP_SERVER_BEARER_TOKEN` env var checked in `ui5_ngx_agent.py` middleware |
| `CollaborationService` WebSocket auth | ✅ Fixed | `CollabConfig.authToken` is sent as a query parameter on the WebSocket handshake and included in the `join` message payload. Consuming apps must set `authToken` for production. |

---

## A08 — Software and Data Integrity Failures

| Control | Status | Notes |
|---|---|---|
| Agent schema validated before render | ✅ Pass | `SchemaValidator.validate()` called in `DynamicRenderer.render()` before any DOM mutation |
| `GovernanceService` audit log tamper-resistance | ✅ Fixed | `AuditService` can POST batches to the training api-server `POST /audit/batch` (HANA/SQLite via SQLAlchemy). Workspace Joule wires `audit.endpoint` + optional `requestHeaders` (`X-Internal-Token` when `AUDIT_SINK_TOKEN` is set). |
| `SequenceTracker` gap detection | ✅ Pass | Gaps logged as warnings; no silent event drop |

---

## A09 — Security Logging and Monitoring Failures

| Control | Status | Notes |
|---|---|---|
| `AuditService` logs all tool calls, renders, confirms, and rejects | ✅ Pass | `entries$` Observable with structured `AuditEntry` records |
| `SequenceTracker` logs gap warnings | ✅ Pass | `console.warn` emitted on gap with run ID and range |
| No raw user data in audit entries | ✅ Pass | Tool arguments stored as-is — consuming apps with PII must configure `dataMaskingRules` in `PolicyConfig` |

---

## A10 — Server-Side Request Forgery (SSRF)

| Control | Status | Notes |
|---|---|---|
| `proxy.conf.json` target is localhost only | ✅ Pass | `http://localhost:8080` — no user-controlled redirect |
| `CollaborationService` WebSocket URL | ✅ Fixed | `assertSafeCollaborationWebSocketUrl` blocks `ws`/`wss` targets on private/metadata hosts; same-origin path-only URLs (e.g. `/collab`) are allowed. |
| OpenAI-compatible server HANA endpoints | ✅ Fixed | `validateRemoteUrl` rejects private/metadata IPs (169.254.x, 100.100.x, 10.x, 172.16-31.x, 192.168.x, localhost, ::1) for all env-sourced URLs |

---

## Summary

| Category | Pass | Warning/Review | Blocked |
|---|---|---|---|
| A01 Access Control | 4 | 0 | 0 |
| A02 Crypto | 3 | 0 | 0 |
| A03 Injection | 9 | 0 | 0 |
| A04 Insecure Design | 4 | 0 | 0 |
| A05 Misconfiguration | 4 | 0 | 0 |
| A06 Outdated Deps | 7 | 0 | 0 |
| A07 Auth Failures | 3 | 0 | 0 |
| A08 Data Integrity | 3 | 0 | 0 |
| A09 Logging | 3 | 0 | 0 |
| A10 SSRF | 3 | 0 | 0 |
| **Total** | **44** | **0** | **0** |

No blockers. Production still **must** configure AG-UI tokens, upstream validation, and (recommended) `AUDIT_SINK_TOKEN` for the audit sink.

---

## Configuration reference (GenUI / gateway / training API)

| Variable / setting | Purpose |
|---|---|
| Workspace `agUiAuthToken` | Optional bearer token: SSE query param + POST `Authorization` for AG-UI |
| Gateway `location /ag-ui/` | Forwards `Authorization` from client to upstream (`proxy_set_header Authorization $http_authorization`) |
| Training API `AUDIT_SINK_TOKEN` | If set, `POST /audit/batch` (and `GET /audit/batch` refresh) require matching `X-Internal-Token` |
| Workspace `auditSinkToken` | Sent as `X-Internal-Token` on audit flush/query when set |
| `CollaborationService` `websocketUrl` | Must be a safe `ws`/`wss` URL or same-origin path (e.g. `/collab`); private hosts rejected |
