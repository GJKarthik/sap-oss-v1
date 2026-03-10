# ADR-003: AG-UI Sequence Numbering and Gap Detection

**Status:** Accepted  
**Date:** 2024-03-01  
**Deciders:** GenUI platform team  

---

## Context

SSE streams over HTTP/1.1 through load balancers and reverse proxies can silently drop or reorder events in edge cases (buffer flush failures, mid-stream proxy restarts). The AG-UI protocol spec has an optional `seq` field on events; without tooling to track it, gaps go undetected and the UI may render an inconsistent intermediate state without warning.

## Decision

`SequenceTracker` is added to `@ui5/ag-ui-angular`:

- **Outgoing messages** stamped with a monotonically increasing per-run sequence number via `nextOutSeq(runId)`.
- **Incoming events** validated via `trackIncoming(event)`:
  - Returns `'ok'` if the sequence is contiguous.
  - Returns `'no-seq'` if the server omitted `seq` (backward-compatible; no action taken).
  - Returns `'gap:<expected>:<actual>'` if a gap is detected.
- On gap detection, `AgUiClient` emits `console.warn` with the run ID and gap range. **No automatic reconnect is triggered** — the decision to reconnect belongs to the application layer (excessive reconnects could amplify load on the agent).
- `seq` resets to 1 on each `lifecycle.run_started` event.

The `seq` field is **optional** on both the event and message interfaces to maintain backward compatibility with agents that do not emit it.

## Consequences

- **Positive:** Operators can detect dropped events via browser console or forwarded telemetry, even without server-side logging.
- **Positive:** Zero behaviour change for agents that don't emit `seq`.
- **Negative:** Gap detection is advisory only — the UI does not attempt to recover missing events. A future ADR may address replay/retry if the agent backend supports it.
- **Negative:** Per-run state in `SequenceTracker` must be explicitly cleared via `reset(runId)` or `clear()`; failure to do so in long-lived single-page sessions would cause memory accumulation (mitigated: `AgUiClient` calls `reset` on `run_started`).

## Alternatives Considered

- **Auto-reconnect on gap** — rejected: causes thundering-herd under transient load; gap may be benign (e.g., agent intentionally skipped seq for an internal heartbeat).
- **Reject/drop events after a gap** — rejected: too aggressive; degrades UX for a non-critical observability feature.
