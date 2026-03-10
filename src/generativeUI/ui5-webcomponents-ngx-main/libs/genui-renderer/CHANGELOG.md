# Changelog — @ui5/genui-renderer

All notable changes to this library are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [0.2.0] — 2025-03-10

### Added
- **`A2UI_SCHEMA_VERSION` constant** (`dynamic-renderer.service.ts`) — exported constant `'1'` identifying the current schema version for forward-compatibility.
- **`A2UiSchema.schemaVersion` field** — optional field for agents to declare the schema version they produced. Renderer warns (never rejects) on unknown versions to stay backward-compatible.
- **`KNOWN_SCHEMA_VERSIONS` set** (`schema-validator.ts`) — drives the version check; easily extended as new versions are introduced.
- **Schema version validation** (`SchemaValidator.validate()`) — emits a `INVALID_SCHEMA` warning when `schemaVersion` is set to an unrecognised value.
- **Jest tests** (`schema-validator.spec.ts`) — 11 unit + snapshot tests covering schema version, security deny list, XSS, max depth, and Fiori floorplan snapshots.
- **Storybook stories** (`genui-outlet.component.stories.ts`) — 4 stories: SingleButton, FormFloorplan, DataTable, NoSchema.
- **`@ui5/genui-renderer/lazy` secondary entry point** — lightweight barrel exporting only `GenUiRendererModule`, `GenUiOutletComponent`, and core types; avoids eager-bundling the full `ComponentRegistry` allowlist.
- **DOMPurify prop sanitisation** (`DynamicRenderer.applyProps()`) — all string prop values now sanitised with `DOMPurify.sanitize({ ALLOWED_TAGS: [], ALLOWED_ATTR: [] })` before DOM write, closing defence-in-depth gap identified in OWASP A03 review.

### Changed
- `SchemaValidator` imports `A2UI_SCHEMA_VERSION` from `dynamic-renderer.service` instead of duplicating the version string.
- `DynamicRenderer.applyProps()` imports and applies `DOMPurify` for string prop values.
- `(element as Record<string, unknown>)` cast updated to `(element as unknown as Record<string, unknown>)` to satisfy TS strict mode.

---

## [0.1.0] — Initial release

### Added
- `ComponentRegistry` with `FIORI_STANDARD_COMPONENTS` allowlist and `SECURITY_DENY_LIST` for file I/O components.
- `SchemaValidator` service with XSS detection, max-depth check, and allowlist enforcement.
- `DynamicRendererService` for runtime Angular component instantiation from A2UI schemas.
- `GenUiOutletComponent` — Angular host component that renders an `A2UiSchema` into the DOM.
- `GenUiRendererModule` exporting all above.
- Jest tests for `ComponentRegistry` security deny list enforcement (p1-d4).
