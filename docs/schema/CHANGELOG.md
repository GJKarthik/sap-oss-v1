# Schema Registry — Changelog

All notable changes to `docs/schema/` are documented in this file.

The registry follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **MAJOR** — backward-incompatible schema changes (field removal, type narrowing, stricter enums that reject previously-valid data).
- **MINOR** — backward-compatible additions (new optional fields, new definitions, relaxed constraints).
- **PATCH** — documentation, test, or tooling changes with no effect on accepted data.

---

## [1.2.0] — 2026-04-19

### Theme

**Traceability, strict-by-default, and CI-enforced invariants.** The registry now binds
every machine-readable artifact to the MoSCoW roadmap chapters added to the LaTeX
specs (PR #61), rejects undeclared fields at validation time, and is guarded by a
GitHub Actions workflow plus pre-commit hooks.

### Added

- **MoSCoW milestone registry** — `common/moscow.yaml` is the single source of truth
  for per-domain milestones (`M01..M09`, `S01..S03`, `C01..C02`, `W01..W02`). It
  mirrors the roadmap chapters in the four LaTeX specs and is referenced by every
  `RoadmapReference`.
- **Shared traceability definitions** in `common/base-types.schema.json`:
  - `MoscowPriority` — enum of `Must`, `Should`, `Could`, `Won't`.
  - `MilestoneId` — pattern `^[MSCW]\d{2}$`.
  - `RequirementId` — pattern `^(REG|TB|AP|SIM|GAIC)-[A-Z0-9]+(-[A-Z0-9.]+)*$`.
  - `RoadmapReference` — `{domain, milestones[], priority, requirement_ids[], roadmap_chapter}`.
  - `ReproducibilityManifest` — `{commit, tag, seed, generated_at}` for pinning
    reference runs (Simula M06).
- **`flip_trigger`** on `regulations/requirement.schema.json` — models the
  documented status-flip path (`partial → compliant`) with the triggering domain,
  milestone, and ticket.
- **`reproducibility` + `hana_spatial_policy` + `roadmap`** on
  `simula/config.schema.json` — pins the M06 reference run (commit, tag, seed) and
  makes the spatial-data validation policy explicit.
- **`compliant` status + `**` marker** added to `regulations/requirement.schema.json`
  (via `common/enums.yaml`) so flipped requirements have a terminal status.
- **Test fixtures** — eight canonical `*.sample.json` files under
  `tests/fixtures/{arabic,tb,simula,regulations}/`, one per primary schema, each
  chosen to exercise the new traceability fields (e.g.
  `regulations/requirement.sample.json` pins REG-MGF-2.1.2-002 and its flip to
  compliant on REG-INTG-AP-001).
- **pytest integration suite** at `tests/integration/` — 7 tests (one
  parametrised across all fixtures) that run in CI and as a pre-commit hook.
- **CI workflow** — `.github/workflows/schema-validation.yaml` runs the registry
  check, meta-schema check, fixture validation, roadmap check, and `jq`/yamllint
  on every PR that touches `docs/schema/**`.
- **Pre-commit hooks** — `docs/schema/.pre-commit-config.yaml` runs the same
  checks locally before a commit is accepted.
- **`requirements.txt`** — pinned dependency set (`jsonschema`, `referencing`,
  `pyyaml`, `pytest`) so contributor environments are reproducible.
- **Validator sub-commands** on `validate.py`:
  - `--run-fixtures` — walks `tests/fixtures/` and validates every sample.
  - `--check-roadmap` — verifies every `RoadmapReference` resolves against
    `moscow.yaml`.
  - `--all` — runs registry-check + run-fixtures + check-roadmap.

### Changed

- **Strict-by-default validation.** Every schema with `"type": "object"` and
  `"properties"` now declares `"additionalProperties": false`, including nested
  `additionalProperties` map-value schemas (`tb/entity-params.variance_bands.*`,
  `regulations/corpus.coverage_summary.by_regulation.*`). Undeclared fields are
  now rejected at validation time instead of being silently accepted.
- **Meta-schema** in `validate.py` now enforces the strict-by-default convention:
  it walks every schema tree and fails any object-with-properties that omits
  `additionalProperties`.
- **`referencing` migration.** `validate.py` now builds a `referencing.Registry`
  of every local schema and resolves cross-schema `$ref`s through it, fixing the
  `jsonschema.RefResolver` `DeprecationWarning` emitted under jsonschema ≥ 4.18.
  The legacy `RefResolver` code path is retained as a guarded fallback so older
  toolchains keep working with the warning silenced.
- **Registry version** bumped `1.1.0 → 1.2.0`; `updated` timestamp refreshed.

### Fixed

- `tb/entity-params.schema.json` — the inner `variance_bands.*` schema was
  missing `additionalProperties: false`, allowing arbitrary sigma field names.
- `regulations/corpus.schema.json` — `coverage_summary.by_regulation.*` inner
  schema was missing `additionalProperties: false`, allowing arbitrary
  per-regulation fields.
- `validate.py` — `jsonschema.RefResolver` usage emitted
  `DeprecationWarning: jsonschema.RefResolver is deprecated` under jsonschema
  4.18+. Now uses `referencing.Registry` when available.

### Security

- No known schema-level security issues. The strict-by-default change closes a
  class of "extension-field injection" bugs where downstream consumers might
  trust undeclared fields.

### Upgrade notes

See [`MIGRATION.md`](MIGRATION.md) for the full 1.1.0 → 1.2.0 upgrade procedure.

---

## [1.1.0] — 2026-04-18

### Added

- `tb/entity-params.schema.json` — per-legal-entity parameter file used by the TB
  controls engine (one per LE, path `docs/tb/machine-readable/entity-params/<le-code>.yaml`).
- `arabic/ocr-result.schema.json` — OCR extraction result for the Arabic AP
  pipeline.
- `simula/hana-schema-entry.schema.json` — HANA schema-registry entry for the
  Simula pipeline.
- `simula/meta-prompt.schema.json` — meta-prompt record capturing the prompt
  template and rendered variables used to produce a training example.
- `regulations/regulation.schema.json` and `regulations/corpus.schema.json` —
  top-level regulation record and corpus index for AI governance tracking.

### Changed

- `validate.py` — gained `--registry-check`, `--registry-status`,
  `--domain <name>`, `--schema <name>`, `--validate-schema <path>` options.
- `registry.json` — became the master index of all domains and schemas, replacing
  ad-hoc per-domain tracking.

---

## [1.0.0] — 2026-04-17

### Added

- Initial unified schema registry under `docs/schema/`, consolidating previously
  scattered schemas into five domains: `common`, `arabic`, `tb`, `simula`,
  `regulations`.
- JSON Schema Draft-07 with cross-schema `$ref` resolution.
- Consolidated enums in `common/enums.yaml`.
- `common/base-types.schema.json` with shared primitives (`ISO4217Currency`,
  `CountryCode`, `SHA256`, `Money`, `Metadata`, `DateString`, etc.).
- Unified `validate.py` entry point.

---

## Unreleased

_No pending changes._
