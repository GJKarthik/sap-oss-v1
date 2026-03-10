# Changelog — @ui5/genui-governance

All notable changes to this library are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [0.2.0] — 2025-03-10

### Added
- **Jest tests** (`governance.service.spec.ts`) — 16 unit tests covering:
  - `requiresConfirmation()` — global policy list, ordinary actions, blocked-action short-circuit, role-specific `requireConfirmation` rules.
  - `isBlocked()` — globally blocked actions, non-blocked actions, role-specific denials, role-isolation (denied for different role is not blocked).
  - Pending action lifecycle — create, confirm, reject, confirm-throws-on-missing.
  - `configure()` — override blocked list, override userId propagated to `ConfirmationResult`.
- **OWASP checklist** (`docs/security/owasp-checklist.md`) — A01–A10 review with 35 pass, 10 review items, 0 blockers documented.

---

## [0.1.0] — Initial release

### Added
- `GovernanceService` — action confirmation workflow with pending action queue and policy enforcement.
- `PolicyConfig` — `requireConfirmation`, `blockedActions`, `confirmationTimeout`, and `roleRules`.
- `PendingAction`, `ConfirmationResult`, `AffectedData` types.
- Default policy covering SAP-typical high-risk actions (`create_purchase_order`, `delete_record`, etc.).
- Role-based rules via `RoleRule[]` (allowed, denied, requireConfirmation per role).
- Audit log integration via `AuditService`.
- `GenUiGovernanceModule` exporting `GovernanceService` and `AuditService`.
