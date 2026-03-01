# Day 56 — Streaming Chat Completion: Design Document

## Problem Statement

The existing `getChatCompletionWithConfig` / `getHarmonizedChatCompletion` actions
return a complete JSON response only after the full model generation finishes.
For long responses this means the Angular UI blocks for several seconds with no
feedback. Streaming delivers tokens progressively as the model generates them.

---

## SDK API Analysis

### `OrchestrationClient.stream()`

```typescript
async stream(
  request?: ChatCompletionRequest,
  signal?: AbortSignal,          // for client-side cancel
  options?: StreamOptions,
  requestConfig?: CustomRequestConfig
): Promise<OrchestrationStreamResponse<OrchestrationStreamChunkResponse>>
```

**Iteration pattern:**
```typescript
const response = await client.stream(request, abortController.signal);
for await (const chunk of response.stream) {
  const delta = chunk.getDeltaContent();   // string | undefined
  if (delta) process(delta);
}
// After loop: response.getContent(), response.getTokenUsage() available
```

**Convenience:**
```typescript
for await (const text of response.stream.toContentStream()) {
  // yields non-empty delta strings only
}
```

**Constraints identified:**
- Not compatible with `OrchestrationModuleConfigList` (fallback config lists)
- `signal` is wired to an internal `AbortController` — passing an `AbortSignal`
  is the correct way for the caller to cancel
- `response._openStream` is `true` until all chunks consumed; `getContent()` /
  `getTokenUsage()` return `undefined` while the stream is open

---

## Approach Evaluation: CDS Action vs Raw Express SSE

### Option A — CDS Action returning chunked response

CDS actions map to HTTP POST. There is **no native CDS SSE type** — CDS does
not define a `streaming` return type in CDS 7/8. Returning a `Readable` stream
from a CDS action handler is not part of the supported contract and can
silently buffer.

**Verdict: Not viable.** CDS actions are request/response, not
request/stream.

### Option B — Raw Express middleware registered in `cds.on("bootstrap")`

CDS exposes the underlying Express app via `cds.on("bootstrap", app => ...)`.
A plain Express route (e.g. `POST /stream/chat`) can:
1. Write `Content-Type: text/event-stream` headers
2. Call `res.write()` for each SSE `data:` frame
3. Call `res.end()` when the stream closes or errors

This bypasses CDS routing entirely and is the established pattern in the
community for adding SSE / WebSocket routes alongside CDS services.

**Verdict: Viable and clean.** No CDS contract changes needed.

### Option C — CDS action with `req.http.res` (raw response access)

Inside a `cds.on("action")` handler, `req.http.res` gives access to the raw
Express `Response` object. It is possible to:
1. Write SSE headers to `req.http.res` manually
2. Iterate the stream and call `req.http.res.write()`
3. Return nothing from the CDS handler (suppress normal response)

This keeps the method inside `cap-llm-plugin.ts` alongside the other actions
and appears in the existing CDS service contract.

**Verdict: Viable, chosen as primary approach.** Keeps streaming inside the
CDS service boundary, preserves the single-service pattern, and allows OTel
spans to be applied uniformly.

---

## Decision: Option C — CDS Action with `req.http.res` SSE

### Rationale

| Factor | Option B (Express route) | Option C (CDS action + `req.http.res`) |
|---|---|---|
| Service contract | Not in CDS / OpenAPI | Appears in `llm-service.cds` |
| Error handling | Custom Express middleware | Unified CDS error interceptors |
| OTel tracing | Separate span setup | Existing `getTracer()` pattern |
| Angular client | Manual `EventSource` URL | Typed action URL from OpenAPI |
| Auth / CSRF | Must duplicate CDS middleware | Inherited from CDS middleware stack |
| Test strategy | Express supertest | Existing `jest.doMock` pattern |

A hybrid fallback: if `req.http` is unavailable (unit test context), the
method falls back to accumulating and returning the full response string.
This keeps the existing test harness working.

---

## Streaming Protocol: Server-Sent Events (SSE)

SSE is preferred over WebSockets because:
- Unidirectional (server → client) — fits chat generation perfectly
- Native browser support via `EventSource`
- Works over standard HTTP/1.1 (no upgrade required)
- Proxies and SAP BTP Application Router handle it correctly

### Event format

```
Content-Type: text/event-stream
Cache-Control: no-cache
X-Accel-Buffering: no       ← disables nginx buffering
Connection: keep-alive

data: {"delta":"The ","index":0}\n\n
data: {"delta":"answer","index":0}\n\n
data: {"delta":" is","index":0}\n\n
data: [DONE]\n\n
```

Final `[DONE]` sentinel signals stream completion to the Angular client.
Error events:
```
event: error\n
data: {"code":"CHAT_STREAM_FAILED","message":"..."}\n\n
```

### Frame payload schema

```typescript
interface StreamDeltaFrame {
  delta: string;      // token delta from getDeltaContent()
  index: number;      // choice index (always 0 for single-choice)
}

interface StreamDoneFrame {
  finishReason: string | undefined;   // "stop" | "length" | ...
  totalTokens: number | undefined;
}
```

---

## New CDS Service Action

Add to `llm-service.cds`:

```cds
/** Stream chat completion tokens via SSE (text/event-stream). */
action streamChatCompletion(
  clientConfig         : String  not null, // JSON-serialized OrchestrationModuleConfig
  chatCompletionConfig : String  not null, // JSON-serialized ChatCompletionRequest
  abortOnFilterViolation : Boolean default true
) returns String; // ignored — response delivered via SSE
```

---

## Implementation Sketch: `streamChatCompletion()`

```typescript
async streamChatCompletion(params: StreamChatParams, req?: any): Promise<string> {
  const span = getTracer().startSpan("cap-llm-plugin.streamChatCompletion");

  const httpRes = req?.http?.res as import("http").ServerResponse | undefined;
  const isStreaming = !!httpRes;

  if (isStreaming) {
    httpRes.setHeader("Content-Type",  "text/event-stream");
    httpRes.setHeader("Cache-Control", "no-cache");
    httpRes.setHeader("X-Accel-Buffering", "no");
    httpRes.setHeader("Connection",    "keep-alive");
    httpRes.flushHeaders();
  }

  const controller = new AbortController();
  // Wire client disconnect → abort
  if (isStreaming) {
    httpRes.on("close", () => controller.abort());
  }

  const clientConfig  = JSON.parse(params.clientConfig);
  const requestConfig = JSON.parse(params.chatCompletionConfig);
  const client = new OrchestrationClient(clientConfig);

  try {
    const streamResponse = await client.stream(
      requestConfig,
      controller.signal,
      undefined,
      { middleware: [createOtelMiddleware({ endpoint: "/chat/completions" })] }
    );

    let fullContent = "";

    for await (const chunk of streamResponse.stream) {
      const delta = chunk.getDeltaContent();
      if (!delta) continue;
      fullContent += delta;

      if (isStreaming) {
        const frame = JSON.stringify({ delta, index: 0 });
        httpRes.write(`data: ${frame}\n\n`);
      }
    }

    const doneFrame = JSON.stringify({
      finishReason: streamResponse.getFinishReason(),
      totalTokens:  streamResponse.getTokenUsage()?.total_tokens,
    });

    if (isStreaming) {
      httpRes.write(`data: ${doneFrame}\n\n`);
      httpRes.write("data: [DONE]\n\n");
      httpRes.end();
    }

    span.setStatus({ code: SpanStatusCode.OK });
    return isStreaming ? "" : fullContent;

  } catch (err) {
    if (isStreaming) {
      const errFrame = JSON.stringify({
        code: "CHAT_STREAM_FAILED",
        message: (err as Error).message,
      });
      httpRes.write(`event: error\ndata: ${errFrame}\n\n`);
      httpRes.end();
    }
    span.recordException(err as Error);
    span.setStatus({ code: SpanStatusCode.ERROR });
    throw err;
  } finally {
    span.end();
  }
}
```

---

## Angular Client Design

```typescript
// StreamingChatService — uses native EventSource (or fetch ReadableStream)
streamChat(request: StreamChatRequest): Observable<string> {
  return new Observable<string>(subscriber => {
    const ctrl = new AbortController();

    fetch("/odata/v4/CAPLLMPluginService/streamChatCompletion", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ clientConfig: "...", chatCompletionConfig: "..." }),
      signal: ctrl.signal,
    }).then(async res => {
      const reader = res.body!.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });

        const lines = buffer.split("\n\n");
        buffer = lines.pop()!;

        for (const line of lines) {
          if (!line.startsWith("data:")) continue;
          const payload = line.slice(5).trim();
          if (payload === "[DONE]") { subscriber.complete(); return; }
          const frame = JSON.parse(payload);
          if (frame.delta) subscriber.next(frame.delta);
          if (frame.code) subscriber.error(new Error(frame.message));
        }
      }
      subscriber.complete();
    }).catch(err => subscriber.error(err));

    return () => ctrl.abort();
  });
}
```

**Alternative for Angular 16+:** Use `HttpClient` with `{ responseType: "text",
observe: "events" }` and intercept `DownloadProgressEvent` — but the `fetch`
approach above is simpler and works in all Angular versions.

---

## OTel Span Plan for Streaming

| Span | Attributes | Events |
|---|---|---|
| `cap-llm-plugin.streamChatCompletion` | `llm.chat.model`, `llm.resource_group` | `stream_started`, `stream_completed` |
| `HTTP POST /chat/completions` | (same as Day 53 middleware) | `ai_core.request_sent`, `ai_core.response_received` |

`stream_completed` event carries `total_tokens` and `finish_reason` attributes.

---

## AbortController / Cancel Flow

```
Angular user clicks "Stop"
  → ctrl.abort()
  → fetch throws AbortError
  → Observable subscriber.error() / complete()

Server side:
  httpRes "close" event fires
  → controller.abort()
  → for-await loop receives AbortError on next iteration
  → catch block: writes SSE error frame, ends response
  → span ends with ERROR status
```

---

## Test Strategy (Day 57)

Unit tests will mock `OrchestrationClient.stream()` to return a fake
`AsyncIterable<OrchestrationStreamChunkResponse>`, then assert:

1. SSE headers written (`Content-Type: text/event-stream`)
2. `res.write()` called once per non-empty delta
3. `[DONE]` sentinel written after all chunks
4. `span.end()` called exactly once
5. Abort path: `res.end()` called, error SSE frame written, span ERROR status
6. Non-streaming path (no `req.http.res`): returns full accumulated string

---

## File Plan

| File | Change |
|---|---|
| `srv/llm-service.cds` | Add `streamChatCompletion` action |
| `srv/cap-llm-plugin.ts` | Implement `streamChatCompletion()` |
| `examples/angular-demo/streaming-chat.service.ts` | `StreamingChatService` using `fetch` + `ReadableStream` |
| `examples/angular-demo/streaming-chat.component.ts` | `StreamingChatComponent` rendering tokens progressively |
| `tests/unit/stream-chat.test.js` | Unit tests (Day 57) |
| `tests/e2e/stream-chat.e2e.test.js` | E2E tests (Day 59) |
