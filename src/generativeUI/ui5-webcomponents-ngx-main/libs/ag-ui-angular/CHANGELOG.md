# Changelog — @ui5/ag-ui-angular

All notable changes to this library are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [0.2.0] — 2025-03-10

### Added
- **Sequence numbers** — `AgUiEventBase.seq` and `AgUiClientMessageBase.seq` optional fields added to the AG-UI event/message types for per-run monotonic ordering.
- **`SequenceTracker` class** (`ag-ui-events.ts`) — tracks outgoing `seq` stamps and detects incoming gaps; emits a `console.warn` on sequence gaps without dropping events.
- **Outgoing seq stamping** — `AgUiClient.send()` automatically stamps a per-run `seq` number on every outgoing client message.
- **Incoming gap detection** — `AgUiClient.handleEvent()` validates incoming `seq` values and warns on gaps; tracker is reset on `lifecycle.run_started`.
- **Jest tests** (`ag-ui-events.spec.ts`) — 14 unit tests covering `SequenceTracker` (nextOutSeq, trackIncoming, reset, clear) and `parseAgUiEvent` (defaults, type guards, snapshot).
- **Storybook story** (`joule-chat.component.stories.ts`) — 4 stories: Default, WithRouteBadge, WebSocketTransport, ConfidentialData.
- **Production integration** — `JouleChatComponent` integrated into `apps/workspace` `/joule` lazy route with real Python agent backend via `proxy.conf.json`.

### Changed
- `AgUiClient.handleEvent()` — sequence tracker reset wired to `lifecycle.run_started` to correctly handle reconnects.
- `check_governance()` in Python agent (`ui5_ngx_agent.py`) now accepts optional `context` arg and delegates to `_resolve_routing()` for consistent routing logic.

---

## [0.1.0] — Initial release

### Added
- `AgUiClient` Angular service with SSE and WebSocket transport support.
- `JouleChatComponent` — SAP Fiori Joule-style streaming chat shell.
- `AgUiToolRegistry` service for frontend tool registration and invocation.
- `AgUiModule` Angular module bundling all exports.
- SSE transport with automatic reconnection and exponential backoff.
- WebSocket transport with heartbeat ping/pong and exponential backoff.
- Full AG-UI event type definitions (`ag-ui-events.ts`).
- Type guards: `isLifecycleEvent`, `isTextEvent`, `isToolEvent`, `isUiEvent`, `isStateEvent`.
