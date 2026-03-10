# Changelog — @ui5/genui-streaming

All notable changes to this library are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [0.2.0] — 2025-03-10

### Added
- **Jest tests** (`streaming-ui.service.spec.ts`) — 7 unit tests covering the `StreamingUiService` state machine:
  - `idle` initial state.
  - `idle → streaming` on `run_started`.
  - `streaming → complete` on `run_finished`.
  - `streaming → error` on `run_error`.
  - Reset to `idle` via `clearSession()`.
  - `schema$` emits `null` initially.
  - `schema$` emits schema on `ui_schema_snapshot` custom event.

### Notes
- State machine transitions tested with minimal stub injections (no Angular TestBed required).

---

## [0.1.0] — Initial release

### Added
- `StreamingUiService` — bridges AG-UI lifecycle and custom events with progressive rendering.
- `StreamingState` type: `idle | connecting | streaming | rendering | complete | error`.
- `StreamingSession` object tracking active run, component map, and errors.
- Schema snapshot handling via `ui_schema_snapshot` custom AG-UI event.
- Legacy `ui.component` / `ui.component_update` / `ui.component_remove` event support.
- `GenUiStreamingModule` exporting `StreamingUiService`.
