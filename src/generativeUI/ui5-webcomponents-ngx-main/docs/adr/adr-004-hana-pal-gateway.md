# ADR 004: HANA connectivity modes, PAL surfaces, and gateway paths

## Status

Accepted

## Context

The generative UI stack talks to SAP HANA and PAL-related capabilities from two places:

1. **Training API** (`training-webcomponents-ngx` FastAPI) uses **hdbcli + SQLAlchemy** when `DATABASE_URL` / `HANA_*` point at HANA Cloud. RAG and PAL catalog/execute flows run in-process against that connection (see `hana_config.py`, `rag.py`, `pal.py`, routes under `/pal/*` on the training server).
2. **Python agent / MCP** (Joule, tools) often use **OAuth + REST SQL** (`HANA_BASE_URL`, `HANA_AUTH_URL`, `HANA_CLIENT_ID`, `HANA_CLIENT_SECRET`) as documented in [deploy.md](../runbooks/deploy.md).

Both are valid on BTP. They serve different runtimes: the training console needs durable DB access for jobs and embeddings; the agent may use REST SQL for tool calls without shipping hdbcli in every process.

## Decision

- **Document the split** in this ADR and the deploy runbook; do not assume a single `HANA_*` schema covers every service.
- **Credentials**: use BTP **service bindings** (HANA Cloud), **Credential Store**, or CF **user-provided** vars; never embed secrets in the Angular bundle.
- **PAL HTTP path**: the **suite gateway** exposes PAL at **`/api/v1/ui5/pal/*`** (upstream `AI_CORE_PAL_UPSTREAM` in `gateway/nginx.conf.template`). The **training API** exposes a **first-party PAL facade** at **`/pal/*`** on the same host as the training app (not under `/api/v1/ui5/pal`). UI or tools that sit behind the gateway should call whichever path the deployment maps: gateway PAL for AI Core PAL proxy, training `/pal/*` for in-process catalog/execute when the browser targets the training API directly.
- **Readiness**: training **`GET /capabilities`** reports optional **`PAL_UPSTREAM_URL`** reachability when operators set it to mirror the gateway PAL upstream for observability.

## Consequences

- Operators configure `DATABASE_URL` / `HANA_*` for the training API and separate REST SQL vars for the agent as needed.
- Adding `PAL_UPSTREAM_URL` on the training API is optional; without it, `pal_route` in `/capabilities` is `unconfigured` even if the gateway routes PAL correctly.
