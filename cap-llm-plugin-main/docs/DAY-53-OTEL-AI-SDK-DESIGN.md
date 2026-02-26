# Day 53 — OTel Instrumentation Design: ai-sdk-js HTTP Client

## Problem

`@sap-ai-sdk/core`'s `executeRequest()` function is the single outbound HTTP call point for **all** AI Core requests (embeddings, chat completions, harmonized orchestration, similarity search preprocessing, etc.). Currently there are no traces on the wire — we can see spans within the CAP plugin layer, but the actual HTTP round-trip to AI Core is a black box.

## Goal

Add an OpenTelemetry span that wraps every `executeRequest()` call with:

- Span name following the OpenTelemetry HTTP semantic conventions: `HTTP POST`
- Attributes covering deployment URL, resource group, endpoint path, HTTP method, status code
- `traceparent` header injection so the AI Core service can continue the trace
- Graceful no-op when `@opentelemetry/api` is not installed

## Source Analysis

**File:** `packages/core/src/http-client.ts` (ai-sdk-js v2.7.0)

```typescript
export async function executeRequest(
  endpointOptions: EndpointOptions,   // { url, apiVersion?, resourceGroup? }
  data: any,
  requestConfig?: CustomRequestConfig,
  destination?: HttpDestinationOrFetchOptions
): Promise<HttpResponse>
```

`CustomRequestConfig` extends `HttpRequestConfig` from `@sap-cloud-sdk/http-client` and includes a **`middleware`** array:

```typescript
export type CustomRequestConfig = Pick<HttpRequestConfig,
  | 'headers' | 'params' | 'middleware' | 'maxContentLength'
  | 'proxy' | 'httpAgent' | 'httpsAgent' | 'parameterEncoder'
> & { signal?: AbortSignal } & Record<string, any>;
```

The `middleware` property is passed directly into `executeHttpRequest()`. Each middleware is a function with the signature:

```typescript
type Middleware = (next: HttpRequestOptions) => Promise<HttpResponse>;
// where HttpRequestOptions wraps { destination, requestConfig }
```

## Chosen Approach: Middleware Injection (No Fork)

Rather than forking `ai-sdk-js`, we inject an OTel middleware via `CustomRequestConfig.middleware` when calling any method that ultimately calls `executeRequest()`. This is fully supported by the SDK.

**Why not fork?**
- Forking creates a maintenance burden across SDK version upgrades
- The `middleware` array is the documented extensibility point
- This approach works without any changes to upstream `ai-sdk-js`

**Injection point in cap-llm-plugin:**
All three methods that use `executeRequest()` go through our plugin wrapper. We add the middleware at the `OrchestrationClient` / `OrchestrationEmbeddingClient` constructor level via `requestConfig` overrides.

## Implementation

### New file: `src/telemetry/ai-sdk-middleware.ts`

```
createOtelMiddleware(spanName?, attributes?) → Middleware
```

The middleware:
1. Starts a child span using the active context (so it nests under the CAP-layer parent span)
2. Sets HTTP semantic attributes
3. Injects `traceparent` / `tracestate` headers into the outgoing request
4. Awaits the inner request, records response status code
5. Records exception + sets ERROR on failure
6. Ends span in `finally`

### Integration in `srv/cap-llm-plugin.ts`

`getEmbeddingWithConfig`, `getChatCompletionWithConfig`, and `getHarmonizedChatCompletion` pass `requestConfig` to the SDK clients. We augment `requestConfig.middleware` with the OTel middleware before passing to the SDK constructor.

## Span Schema

| Attribute | Value | Source |
|-----------|-------|--------|
| `http.method` | `POST` | always (ai-sdk default) |
| `http.url` | full resolved URL | `destination.url + endpointPath` |
| `http.status_code` | e.g. `200`, `429` | `response.status` |
| `ai_core.resource_group` | e.g. `default` | `endpointOptions.resourceGroup` |
| `ai_core.endpoint` | e.g. `/chat/completions` | `endpointOptions.url` |
| `ai_core.api_version` | e.g. `2024-02-01` | `endpointOptions.apiVersion` |

Events:
- `ai_core.request_sent` — immediately before `next()`
- `ai_core.response_received` — on success, with `http.status_code`

## W3C Trace Context Propagation

OTel's `propagation.inject()` writes `traceparent` and `tracestate` into the outgoing headers object. AI Core (if instrumented on the server side) can then extract the parent span context and continue the distributed trace.

```
Browser → CAP (span A)
           └── cap-llm-plugin.getEmbeddingWithConfig (span B)
                └── HTTP POST /deployments/.../embeddings (span C)  ← this layer
                     └── [AI Core internal spans, if instrumented]
```

## PR Design (for upstream ai-sdk-js)

If the SDK maintainers want to absorb OTel natively, the minimal upstream change is:

```typescript
// packages/core/src/http-client.ts

import { context, trace, propagation, SpanStatusCode } from '@opentelemetry/api';

export async function executeRequest(...): Promise<HttpResponse> {
  const tracer = trace.getTracer('@sap-ai-sdk/core');
  const span = tracer.startSpan(`HTTP POST ${url}`, {
    kind: SpanKind.CLIENT,
    attributes: {
      'http.method': 'POST',
      'ai_core.endpoint': url,
      'ai_core.resource_group': resourceGroup,
    }
  });

  const ctx = trace.setSpan(context.active(), span);
  return context.with(ctx, async () => {
    // inject traceparent into mergedRequestConfig.headers
    propagation.inject(context.active(), mergedRequestConfig.headers);
    try {
      const response = await executeHttpRequest(...);
      span.setAttribute('http.status_code', response.status);
      span.setStatus({ code: SpanStatusCode.OK });
      return response;
    } catch (error) {
      span.recordException(error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
      throw error;
    } finally {
      span.end();
    }
  });
}
```

This requires `@opentelemetry/api` as an optional peer dependency of `@sap-ai-sdk/core`, mirroring the pattern we established in `cap-llm-plugin`.

## Files Changed (this project)

| File | Change |
|------|--------|
| `src/telemetry/ai-sdk-middleware.ts` | New — OTel middleware factory |
| `src/index.ts` | Export `createOtelMiddleware` |
| `srv/cap-llm-plugin.ts` | Inject middleware into SDK client calls |
| `tests/unit/ai-sdk-middleware.test.js` | 30+ unit tests |
| `docs/DAY-53-OTEL-AI-SDK-DESIGN.md` | This document |
