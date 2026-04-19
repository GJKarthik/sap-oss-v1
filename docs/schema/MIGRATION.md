# Schema Registry — Migration Guide

This document captures the upgrade procedure between registry versions. It is the
counterpart of [`CHANGELOG.md`](CHANGELOG.md): the changelog says **what**
changed, this guide says **how to adopt** the change without breaking downstream
consumers.

---

## Compatibility matrix

| Registry version | Python | `jsonschema` | `referencing` | Notes |
|------------------|--------|--------------|---------------|-------|
| 1.2.0            | ≥ 3.9  | ≥ 4.18       | ≥ 0.30        | CI runs on 3.11. `referencing` is preferred; legacy `RefResolver` path retained as fallback. |
| 1.1.0            | ≥ 3.8  | ≥ 4.0        | —             | Uses deprecated `RefResolver` directly. |
| 1.0.0            | ≥ 3.8  | ≥ 4.0        | —             | Initial unified registry. |

Install the pinned toolchain for the current version with:

```bash
pip install -r docs/schema/requirements.txt
```

---

## 1.1.0 → 1.2.0

> **Risk classification: MEDIUM.** The strict-by-default validation change
> (`additionalProperties: false`) will reject data that was silently accepted
> under 1.1.0. Everything else is additive.

### Breaking changes

**1. `additionalProperties: false` is now enforced across every schema.**

Previously, many schemas omitted `additionalProperties`, which defaults to
`true` under Draft-07. Any document that relied on that laxity — typically by
carrying ad-hoc extension fields — will now fail validation.

- **Action:** Run `python3 docs/schema/validate.py --all` against your existing
  data. Any failures with `Additional properties are not allowed ('<field>' was
  unexpected)` indicate fields that need to be either:
  - removed from the document, or
  - declared in the schema under a new `x_*` prefix (recommended for
    domain-specific extensions), or
  - promoted to a first-class field in the schema (open a PR).

- **Escape hatch:** If you must keep an undeclared field temporarily, add it to
  the schema as an optional property. Do **not** set `additionalProperties: true`
  on the schema — the meta-schema check will fail in CI.

**2. `regulations/requirement.schema.json` — `status` enum expanded.**

The enum now includes `compliant` (terminal status post-flip) and the
`status_marker` enum now includes `**`. This is additive for producers and
requires consumers to handle the two new tokens.

- **Action:** Update any Python code that exhaustively switches on
  `requirement_status` to include `compliant` and `**`. If you use the Python
  `match` statement, add the new arms explicitly.

**3. Inner `additionalProperties` map-value schemas are now strict.**

- `tb/entity-params.schema.json` — `variance_bands.*` previously accepted
  arbitrary sigma field names. Now only `warn_sigma` and `error_sigma` are
  accepted.
- `regulations/corpus.schema.json` — `coverage_summary.by_regulation.*`
  previously accepted arbitrary per-regulation fields. Now only `total`,
  `covered_sections`, and `uncovered_sections` are accepted.

- **Action:** Rename any ad-hoc sigma fields to `warn_sigma` / `error_sigma`
  (or extend the schema via a PR if you genuinely need more bands).

### Additions you can adopt incrementally

**4. MoSCoW traceability (`roadmap` / `RoadmapReference`).**

New optional `roadmap` fields on `regulations/requirement.schema.json` and
`simula/config.schema.json` link records to milestones in
`common/moscow.yaml`.

- **Action:** Start populating `roadmap` on new records. Existing records
  without a `roadmap` field continue to validate. CI enforces that every
  `roadmap.milestones[*]` exists in `moscow.yaml`, so invalid references are
  caught at PR time.

Example:

```json
"roadmap": {
  "domain": "regulations",
  "milestones": ["M02", "S01"],
  "priority": "Must",
  "requirement_ids": ["REG-MGF-2.1.2-002"],
  "roadmap_chapter": "Regulations Spec, Chapter 7"
}
```

**5. `flip_trigger` on regulation requirements.**

Captures the path from `partial` to `compliant`:

```json
"flip_trigger": {
  "domain": "arabic",
  "milestone_id": "S01",
  "ticket": "REG-INTG-AP-001",
  "from_status": "partial",
  "to_status": "compliant"
}
```

- **Action:** For every `partial`/`partial_star` requirement, add a
  `flip_trigger` pointing to the milestone that will produce the evidence
  needed to flip to `compliant`. The canonical worked example is
  `REG-MGF-2.1.2-002` — see `tests/fixtures/regulations/requirement.sample.json`.

**6. Simula `reproducibility` manifest.**

`simula/config.schema.json` now accepts a `reproducibility` block:

```json
"reproducibility": {
  "commit": "b8d40a1",
  "tag": "simula-v1.2-worked-example",
  "seed": 20251115,
  "generated_at": "2026-04-19"
}
```

- **Action:** Pin the M06 reference run. Any config regenerated after M06 must
  either carry the same manifest (to reproduce the run) or bump the tag to a
  new reference.

**7. `hana_spatial_policy` on Simula configs.**

New enum field `hana_spatial_policy: warn | strict | skip` (default `warn`).
Makes the spatial-data validation policy explicit instead of implicit.

- **Action:** Set to `strict` for production data-generation runs.

### Tooling migration

**8. `referencing` replaces `RefResolver`.**

If you embed `validate.py` in another tool, re-read the `_make_validator`
function. It now builds a `referencing.Registry` from every local schema and
constructs the `Draft7Validator` with `registry=...` instead of
`resolver=...`. The fallback path for environments without `referencing` is
guarded and silent.

**9. New validator sub-commands.**

- `python3 docs/schema/validate.py --run-fixtures` — validates every
  `tests/fixtures/**/*.sample.json` against the stem-matched schema.
- `python3 docs/schema/validate.py --check-roadmap` — verifies every
  `RoadmapReference` in fixtures resolves against `common/moscow.yaml`.
- `python3 docs/schema/validate.py --all` — runs all of the above plus
  `--registry-check`. **Wire this into your PR checks.**

**10. CI workflow + pre-commit hooks.**

- `.github/workflows/schema-validation.yaml` runs on every PR touching
  `docs/schema/**`.
- `docs/schema/.pre-commit-config.yaml` provides local hooks. Install with:

```bash
pip install pre-commit
pre-commit install --config docs/schema/.pre-commit-config.yaml
```

### Migration checklist

- [ ] `pip install -r docs/schema/requirements.txt`
- [ ] `python3 docs/schema/validate.py --all` — resolve any
      `Additional properties are not allowed` errors.
- [ ] Update exhaustive `match`/`switch` over `requirement_status` to handle
      `compliant` and `**`.
- [ ] Rename ad-hoc `variance_bands.*` fields to `warn_sigma` / `error_sigma`.
- [ ] (Optional but recommended) Add `roadmap` fields to new requirement and
      config records.
- [ ] (Optional) Add `flip_trigger` to `partial` requirements.
- [ ] (Optional) Add `reproducibility` manifest to Simula configs for the
      M06 reference run.
- [ ] Install the pre-commit hooks locally.

---

## 1.0.0 → 1.1.0

> **Risk classification: LOW.** Purely additive.

### Added schemas

- `tb/entity-params.schema.json`
- `arabic/ocr-result.schema.json`
- `simula/hana-schema-entry.schema.json`
- `simula/meta-prompt.schema.json`
- `regulations/regulation.schema.json`
- `regulations/corpus.schema.json`

### Tooling

- `validate.py` gained `--registry-check`, `--registry-status`,
  `--validate-schema`, and `--domain`/`--schema` targeting.

### Migration checklist

- [ ] No code changes required. Adopt new schemas as their domains need them.

---

## Versioning policy

- **MAJOR** — breaking schema changes. A new `$id` version suffix is introduced
  and the previous version remains resolvable at its versioned path for one
  release cycle.
- **MINOR** — additive or strictness-preserving changes. The `$id` does **not**
  change; consumers pick up the new fields automatically.
- **PATCH** — documentation, test, or tooling changes only; no schema impact.

When in doubt, release MINOR and document the change in `CHANGELOG.md`. Prefer
opt-in strictness (e.g. `"required": ["new_field"]` gated on `"if"`/`"then"`) to
hard breakage.

---

## Deprecation policy

- Deprecated fields are marked with `"deprecated": true` (Draft 2019-09
  vocabulary; Draft-07 uses `"description"` prefixed `DEPRECATED — `) and remain
  valid for one MAJOR version.
- The removal is announced in the `CHANGELOG` one MINOR version before the
  MAJOR bump.
- CI emits a warning (not an error) when a fixture uses a deprecated field.
