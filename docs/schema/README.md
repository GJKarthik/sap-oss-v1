# Unified Schema Registry

**Version:** 1.2.0
**Last Updated:** 2026-04-19
**Status:** Stable. CI-enforced. Strict-by-default.

Single source of truth for JSON Schemas across the four SAP-OSS Finance
specifications: **Arabic AP Invoice Processing**, **Trial Balance Review**,
**Simula Training Data Generation**, and **AI Regulations & Governance**.

> **What changed in 1.2.0?** Every schema is now strict-by-default
> (`additionalProperties: false`), traceability to MoSCoW roadmap chapters is
> first-class (`common/moscow.yaml` + `RoadmapReference`), the validator has
> migrated off the deprecated `jsonschema.RefResolver`, and a GitHub Actions
> workflow plus pre-commit hooks guard the invariants. See
> [`CHANGELOG.md`](CHANGELOG.md) and [`MIGRATION.md`](MIGRATION.md).

---

## At a glance

| Area | Count | Detail |
|------|-------|--------|
| Domains | 5 | `common`, `arabic`, `tb`, `simula`, `regulations` |
| Schemas | 20 | All Draft-07, all strict-by-default |
| Shared enums | 13 | `common/enums.yaml` |
| Fixtures | 8 | One per primary schema under `tests/fixtures/` |
| pytest tests | 7 | Parametrised across every fixture; runs in CI |
| CI checks | 5 | registry-check, meta-schema, run-fixtures, check-roadmap, lint |

---

## Directory layout

```
docs/schema/
├── README.md                    ← this file
├── CHANGELOG.md                 ← version history
├── MIGRATION.md                 ← upgrade procedures
├── registry.json                ← master index of all schemas
├── validate.py                  ← unified validator CLI
├── requirements.txt             ← pinned Python deps
├── cross-document-addendum.yaml ← cross-spec normalisations
├── .pre-commit-config.yaml      ← local guardrail hooks
│
├── common/
│   ├── base-types.schema.json   ← shared primitives + traceability types
│   ├── enums.yaml               ← consolidated enums (13 sets)
│   └── moscow.yaml              ← MoSCoW milestones per domain  (NEW in 1.2.0)
│
├── arabic/                      ← Arabic AP Invoice domain (4 schemas)
│   ├── invoice.schema.json
│   ├── vat-checklist.schema.json
│   ├── vendor.schema.json
│   └── ocr-result.schema.json
│
├── tb/                          ← Trial Balance domain (6 schemas)
│   ├── tb-extract.schema.json
│   ├── pl-extract.schema.json
│   ├── variance-record.schema.json
│   ├── commentary-draft.schema.json
│   ├── decision-point.schema.json
│   └── entity-params.schema.json
│
├── simula/                      ← Simula Training Data domain (5 schemas)
│   ├── taxonomy.schema.json
│   ├── training-example.schema.json
│   ├── hana-schema-entry.schema.json
│   ├── config.schema.json
│   └── meta-prompt.schema.json
│
├── regulations/                 ← AI Governance domain (4 schemas)
│   ├── regulation.schema.json
│   ├── requirement.schema.json
│   ├── conformance-tool.schema.json
│   └── corpus.schema.json
│
└── tests/
    ├── fixtures/
    │   ├── arabic/{invoice,vendor}.sample.json
    │   ├── tb/{tb-extract,variance-record}.sample.json
    │   ├── simula/{config,taxonomy}.sample.json
    │   └── regulations/{regulation,requirement}.sample.json
    └── integration/
        ├── conftest.py
        └── test_fixtures_validate.py
```

---

## Quickstart

```bash
# 1. Install deps
pip install -r docs/schema/requirements.txt

# 2. Run every check the CI runs
python3 docs/schema/validate.py --all

# 3. Run the pytest integration suite
pytest docs/schema/tests/integration/ -v

# 4. Install pre-commit hooks locally (optional but recommended)
pre-commit install --config docs/schema/.pre-commit-config.yaml
```

Expected output of `--all`:

```
✓ registry-check
✓ run-fixtures (8 fixtures all ✓)
✓ check-roadmap
  - All RoadmapReferences resolve against moscow.yaml.
```

---

## Validator reference

`validate.py` is the single CLI entry point. All sub-commands exit non-zero on
failure and are safe to wire into CI.

| Command | Purpose |
|---------|---------|
| `--registry-check` | Every schema in `registry.json` parses and declares `$schema`/`$id`. |
| `--registry-status` | Human-readable status dump of every domain. |
| `--validate-schema <path>` | Validate one schema file against the meta-schema (including strict-by-default enforcement). |
| `--domain <name> --schema <file> --file <data>` | Validate one data file against one schema. |
| `--run-fixtures` | Walks `tests/fixtures/` and validates every `*.sample.json` against its stem-matched schema. |
| `--check-roadmap` | Verifies every `RoadmapReference` in fixtures resolves against `common/moscow.yaml`. |
| `--all` | Runs `--registry-check`, `--run-fixtures`, and `--check-roadmap`. |
| `--json` | Emit results as JSON (composable with any of the above). |

### Examples

```bash
# Validate one invoice payload
python3 docs/schema/validate.py \
  --domain arabic \
  --schema invoice.schema.json \
  --file docs/arabic/structured/invoices/invoice-001.json

# Full CI gate (what the workflow runs)
python3 docs/schema/validate.py --all

# Machine-readable output
python3 docs/schema/validate.py --all --json | jq .
```

---

## Traceability to the LaTeX roadmaps

Every machine-readable artifact can be linked back to the MoSCoW roadmap
chapters introduced in the four LaTeX specs (PR #61). The link is declarative:

```yaml
# common/moscow.yaml (excerpt)
regulations:
  - { id: M01, priority: Must, title: "Freeze corpus v1.0", ... }
  - { id: S01, priority: Should, title: "Close REG-INTG-AP-001 Arabic integrity", ... }
  # ...
```

Artifacts reference milestones via the shared `RoadmapReference` definition in
`common/base-types.schema.json`:

```json
"roadmap": {
  "domain": "regulations",
  "milestones": ["M02", "S01"],
  "priority": "Must",
  "requirement_ids": ["REG-MGF-2.1.2-002"],
  "roadmap_chapter": "Regulations Spec, Chapter 7"
}
```

CI runs `--check-roadmap` on every PR. Any `roadmap.milestones[*]` that does
not exist in `moscow.yaml` fails the build.

The canonical worked example is **REG-MGF-2.1.2-002** (see
`tests/fixtures/regulations/requirement.sample.json`): status `partial`,
`status_marker: "*"`, with a `flip_trigger` pointing to Arabic S01
(`REG-INTG-AP-001`), the milestone whose completion will flip the status to
`compliant`.

---

## Schema standards

### Naming conventions

| Type | Convention | Example |
|------|------------|---------|
| Schema files | `kebab-case.schema.json` | `invoice.schema.json` |
| Fixture files | `<schema-stem>.sample.json` | `invoice.sample.json` |
| Enum files | `kebab-case.yaml` | `moscow.yaml` |
| `$id` URIs | `https://sap-oss.github.io/schema/<domain>/<stem>.schema.json` | — |

### Required metadata

Every schema must include:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://sap-oss.github.io/schema/<domain>/<stem>.schema.json",
  "title": "Human-readable title",
  "description": "Purpose and usage",
  "type": "object",
  "additionalProperties": false
}
```

The meta-schema check (`validate.py --validate-schema`) enforces that every
object-with-properties has an explicit `additionalProperties`.

### Strict-by-default

As of 1.2.0, every object-with-properties declares `additionalProperties: false`,
**including nested map-value schemas** (`additionalProperties: { ... }` maps).
Undeclared fields are rejected at validation time.

If you genuinely need an open-ended extension field, prefix it with `x_` and
declare it on the schema. Do not flip `additionalProperties` back to `true`.

### Versioning

See [`MIGRATION.md`](MIGRATION.md) for the full policy. Summary:

- **MAJOR** — breaking schema changes; new `$id` version suffix.
- **MINOR** — additive or strictness-preserving.
- **PATCH** — docs/tests/tooling only.

---

## Fixture contribution guide

Every primary schema should have at least one fixture under
`tests/fixtures/<domain>/<schema-stem>.sample.json`. The fixtures have two
jobs:

1. **Document intended usage** — a realistic payload that a new contributor can
   read and understand without running the validator.
2. **Lock in invariants** — exercise edge cases and any traceability fields
   (`roadmap`, `flip_trigger`, `reproducibility`, …).

### Adding a fixture

```bash
# 1. Create the fixture alongside its schema
touch docs/schema/tests/fixtures/<domain>/<stem>.sample.json

# 2. Validate against the schema
python3 docs/schema/validate.py \
  --domain <domain> \
  --schema <stem>.schema.json \
  --file docs/schema/tests/fixtures/<domain>/<stem>.sample.json

# 3. Run the parametrised pytest suite — it auto-discovers the new fixture
pytest docs/schema/tests/integration/ -v
```

The discovery convention is enforced by
`tests/integration/conftest.py`: a file at `tests/fixtures/<domain>/<stem>.sample.json`
is auto-paired with the schema at `<domain>/<stem>.schema.json`. No test file
edits needed.

### Bespoke tests

If a fixture needs assertions beyond "validates against its schema" — e.g.
pinning a specific value like the Simula M06 reproducibility commit — add a
dedicated test to `tests/integration/test_fixtures_validate.py`. See the
existing `test_reg_mgf_2_1_2_002_is_partial_with_flip_trigger` and
`test_simula_config_has_reproducibility_manifest` for the pattern.

---

## External API (stable URIs)

The registry is published at a stable base URI. Every schema is addressable
by its `$id`:

| Artifact | Stable URI |
|----------|------------|
| Base types | `https://sap-oss.github.io/schema/common/base-types.schema.json` |
| Shared enums | `https://sap-oss.github.io/schema/common/enums.yaml` |
| MoSCoW milestones | `https://sap-oss.github.io/schema/common/moscow.yaml` |
| Arabic invoice | `https://sap-oss.github.io/schema/arabic/invoice.schema.json` |
| TB extract | `https://sap-oss.github.io/schema/tb/tb-extract.schema.json` |
| Simula config | `https://sap-oss.github.io/schema/simula/config.schema.json` |
| Regulations requirement | `https://sap-oss.github.io/schema/regulations/requirement.schema.json` |
| Master registry | `https://sap-oss.github.io/schema/registry.json` |

External consumers should pin a registry version (e.g. `1.2.0`) and follow the
MAJOR/MINOR/PATCH rules above.

---

## Related documentation

- [`CHANGELOG.md`](CHANGELOG.md) — version history.
- [`MIGRATION.md`](MIGRATION.md) — upgrade procedures and compatibility matrix.
- [`cross-document-addendum.yaml`](cross-document-addendum.yaml) — cross-spec
  normalisations (field names, units, enums shared between domains).
- [`../latex/specs/ERRATA.md`](../latex/specs/ERRATA.md) — known schema-related
  issues and their resolution status.
- LaTeX specs (one roadmap chapter each):
  - [`../latex/specs/arabic/`](../latex/specs/arabic/) — Arabic AP roadmap (Ch 8).
  - [`../latex/specs/tb/`](../latex/specs/tb/) — TB Review roadmap (Ch 10).
  - [`../latex/specs/simula/`](../latex/specs/simula/) — Simula roadmap (Ch 10).
  - [`../latex/specs/regulations/`](../latex/specs/regulations/) — Regulations roadmap (Ch 7).

---

## CI / guardrails

- **GitHub Actions:** [`.github/workflows/schema-validation.yaml`](../../.github/workflows/schema-validation.yaml)
  runs on every PR that touches `docs/schema/**`. It installs
  `requirements.txt`, runs `--all`, per-schema meta-validation, a `jq` parse
  over every JSON file, and `yamllint` on the YAML configs.
- **Pre-commit:** [`.pre-commit-config.yaml`](./.pre-commit-config.yaml) runs
  the same checks locally before a commit is accepted. Install once with
  `pre-commit install --config docs/schema/.pre-commit-config.yaml`.

---

## FAQ

**Q: Can I add a new schema without a fixture?**
A: No. Every primary schema must ship with at least one fixture — this is what
makes the registry genuinely strict-by-default rather than strict-in-theory.

**Q: Can I turn off `additionalProperties: false` for my schema?**
A: No. The meta-schema check fails in CI. If you need an extension field,
declare it explicitly with an `x_` prefix.

**Q: I need a schema that doesn't fit any of the five domains. What do I do?**
A: Open an issue proposing a new domain. Domains are added via MINOR version
bumps.

**Q: The roadmap check is failing because my milestone isn't in `moscow.yaml`
yet.**
A: Add the milestone to `moscow.yaml` in the same PR. The milestone IDs
(`M01`, `S01`, …) mirror the LaTeX roadmap chapters 1:1.

**Q: I'm on Python 3.8 and can't install `referencing`.**
A: `validate.py` falls back to the legacy `RefResolver` path with the
deprecation warning silenced. You still get correct validation; you just
don't get the new cross-schema `Registry`.
