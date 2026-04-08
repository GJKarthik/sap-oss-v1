# ADR-001: AG-UI Transport Layer Choice (SSE over WebSocket as default)

**Status:** Accepted  
**Date:** 2024-03-01  
**Deciders:** GenUI platform team  

---

## Context

The AG-UI protocol requires a bidirectional-ish channel between the Angular frontend and the Python agent backend. Two transports are available in `@ui5/ag-ui-angular`:

- **SSE (Server-Sent Events)** — unidirectional server→client stream over HTTP; client sends messages via separate HTTP POST.
- **WebSocket** — full-duplex TCP channel.

The production deployment target is SAP BTP / Cloud Foundry, where WebSocket support varies by service plan and often requires explicit route configuration in the CF router and nginx reverse proxy. SSE is plain HTTP/1.1 and works everywhere HTTPS is permitted.

## Decision

**Default transport is SSE.** WebSocket remains a supported alternative, selectable via `AgUiModule.forRoot({ transport: 'websocket' })` or the `transport` input on `<joule-chat>`.

The `proxy.conf.json` in `apps/workspace` proxies `/ag-ui/*` to `localhost:8080`, which is the default uvicorn bind port for `ui5_ngx_agent.py`. The nginx production config must forward the same path with `proxy_set_header Connection ''` and `proxy_buffering off` to preserve SSE semantics.

## Consequences

- **Positive:** Zero CF router config changes needed; works with any HTTP/1.1 load balancer.
- **Positive:** SSE is automatically retried by the browser (`EventSource` built-in reconnect); `SseTransport` implements exponential backoff on top.
- **Negative:** SSE is half-duplex; client messages go via POST. This adds one extra round-trip compared to WebSocket but is imperceptible at agent latencies (100ms+).
- **Negative:** SSE connections count against CF application instance connection limits; each active chat tab holds one persistent connection.

## Alternatives Considered

- **WebSocket only** — rejected: CF routing complexity, not universally available on all BTP service plans.
- **Long polling** — rejected: too much overhead, defeats streaming purpose.
