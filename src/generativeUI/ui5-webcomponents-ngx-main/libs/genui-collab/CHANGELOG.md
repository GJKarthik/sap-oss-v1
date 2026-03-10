# Changelog — @ui5/genui-collab

All notable changes to this library are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [0.2.0] — 2025-03-10

### Added
- **Storybook story** (`collaboration.service.stories.ts`) — illustrative story documenting collaboration session concepts (presence, cursor, state-sync) with usage notes.

### Known Gaps
- WebSocket collaboration server implementation deferred to future milestone.
- Jest tests for `CollaborationService` join/leave/presence flows deferred to future milestone.

---

## [0.1.0] — Initial release

### Added
- `CollaborationService` — real-time multi-user presence, cursor tracking, state synchronisation.
- `CollabMessage` union type covering join, leave, presence, cursor, state, and sync messages.
- `Participant`, `CursorPosition`, `StateChange` types.
- WebSocket-based transport with heartbeat ping/pong.
- Idle timeout detection and automatic away-status.
- `GenUiCollabModule` exporting `CollaborationService`.
