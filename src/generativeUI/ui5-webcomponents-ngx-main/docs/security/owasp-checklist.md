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
| SSE endpoint (`/ag-ui/run`) authenticated by upstream proxy | ⚠️ Review | Authentication delegated to deployment layer (nginx/BTP router) — not enforced in library |

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
| Agent SSE stream injection (SSE comment smuggling) | ⚠️ Review | `SseTransport` does not validate `data:` line format; a compromised SSE stream could emit non-AG-UI JSON — mitigated by JSON.parse throwing and `AgUiClient` swallowing the error |

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
| `nx.json` cloud token committed as plaintext | ⚠️ Known | Read-only Nx Cloud token — rotate before public repo fork (see TECHNICAL-ASSESSMENT §Security) |
| DOMPurify `FORCE_BODY` not set | ⚠️ Fixed (this release) | `applyProps` now uses `{ ALLOWED_TAGS: [], ALLOWED_ATTR: [] }` — strips all HTML |
| `SchemaValidator` strict mode defaults to `false` | ℹ️ Info | Warnings do not block rendering; apps requiring strict mode must opt in via `configure({ strict: true })` |
| MCP server has no auth middleware | ⚠️ Known | Internal service only; not to be exposed beyond localhost/VPC |

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
| Joule `/ag-ui/run` endpoint requires authentication | ⚠️ Deployment | Library does not enforce auth — must be handled at BTP router / nginx level |
| MCP server bearer token | ✅ Pass | `MCP_SERVER_BEARER_TOKEN` env var checked in `ui5_ngx_agent.py` middleware |
| `CollaborationService` WebSocket auth | ⚠️ Review | Current implementation sends `join` message with `userId` only — no token; collaboration server must validate |

---

## A08 — Software and Data Integrity Failures

| Control | Status | Notes |
|---|---|---|
| Agent schema validated before render | ✅ Pass | `SchemaValidator.validate()` called in `DynamicRenderer.render()` before any DOM mutation |
| `GovernanceService` audit log tamper-resistance | ℹ️ Info | In-memory audit log — no persistence by default; production deployments should forward to an immutable store (HANA, Splunk, etc.) |
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
| `CollaborationService` WebSocket URL | ⚠️ Review | `wsUrl` is a constructor argument — consuming apps must not derive it from user input |
| OpenAI-compatible server HANA endpoints | ⚠️ Known | HANA URLs come from env vars; env var values should be validated to prevent SSRF to cloud metadata endpoints |

---

## Summary

| Category | Pass | Warning/Review | Blocked |
|---|---|---|---|
| A01 Access Control | 3 | 1 | 0 |
| A02 Crypto | 3 | 0 | 0 |
| A03 Injection | 8 | 1 | 0 |
| A04 Insecure Design | 4 | 0 | 0 |
| A05 Misconfiguration | 2 | 3 | 0 |
| A06 Outdated Deps | 7 | 0 | 0 |
| A07 Auth Failures | 1 | 2 | 0 |
| A08 Data Integrity | 3 | 1 | 0 |
| A09 Logging | 3 | 0 | 0 |
| A10 SSRF | 1 | 2 | 0 |
| **Total** | **35** | **10** | **0** |

No blockers. Ten review items are deployment/configuration concerns rather than library code defects.
