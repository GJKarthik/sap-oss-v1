# Schema Changelog

All notable changes to the SAP-OSS schema registry are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- MoSCoW traceability fields via `common/moscow.yaml`
  - Priority enums: `Must`, `Should`, `Could`, `Won't`
  - Per-domain milestone IDs (M01-M09 for arabic/tb/simula/regulations)
- `RoadmapTraceability` definition in `common/base-types.schema.json`
  - `roadmap_milestones[]` for linking to milestone IDs
  - `requirement_ids[]` for REG-* traceability
  - `moscow_priority` enum reference
- `worked_example_manifest` definition in `simula/config.schema.json`
  - Tracks M06 reproducibility: git commit, tag, seed, outputs with checksums
- CI workflow `.github/workflows/schema-validation.yml`
  - Validates all schemas on PR/push to main
  - JSON/YAML syntax checking
  - Schema convention enforcement
- Test fixtures directory structure `tests/fixtures/schema/`
- `docs/schema/requirements.txt` for Python dependencies

### Changed
- Migrated `validate.py` from deprecated `RefResolver` to modern `referencing` library
  - Compatible with jsonschema 4.x/5.x
  - Uses `Registry` and `Resource` from referencing package
- Added `additionalProperties: false` to all 20 schemas (root level)
- Added `additionalProperties: false` to nested object definitions across all schemas

### Fixed
- Updated `requirement.schema.json` status enum to include `partial` (was missing)
- Added entity-params.schema.json to tb domain in validator

## [1.0.0] - 2025-11-15

### Added
- Initial schema registry with 20 schemas across 4 domains
- Domains: arabic (4), tb (6), simula (5), regulations (4), common (2)
- `registry.json` central schema catalog
- `validate.py` unified validator (pre-referencing migration)
- `cross-document-addendum.yaml` cross-domain specification

### Schema Files
- **Arabic AP Domain**
  - `invoice.schema.json` - Arabic invoice records
  - `vendor.schema.json` - Vendor master data
  - `ocr-result.schema.json` - OCR extraction output
  - `vat-checklist.schema.json` - VAT compliance checklist

- **TB Review Domain**
  - `tb-extract.schema.json` - Trial balance extract
  - `pl-extract.schema.json` - P&L extract
  - `variance-record.schema.json` - Variance detection records
  - `commentary-draft.schema.json` - AI commentary drafts
  - `decision-point.schema.json` - DP-001 to DP-005 decisions
  - `entity-params.schema.json` - Per-LE parameters

- **Simula Training Domain**
  - `taxonomy.schema.json` - Training taxonomy
  - `training-example.schema.json` - Generated examples
  - `config.schema.json` - Pipeline configuration
  - `meta-prompt.schema.json` - Meta-prompt templates
  - `hana-schema-entry.schema.json` - HANA table definitions

- **Regulations Domain**
  - `regulation.schema.json` - Regulation metadata
  - `requirement.schema.json` - Implementation requirements
  - `conformance-tool.schema.json` - AI Verify/Moonshot tools
  - `corpus.schema.json` - Document corpus

- **Common**
  - `base-types.schema.json` - Shared type definitions
  - `enums.yaml` - Shared enumerations