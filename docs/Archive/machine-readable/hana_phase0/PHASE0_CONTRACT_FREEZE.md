# Phase 0 Baseline and Contract Freeze

Generated at: 2026-03-03T04:40:29.672623+00:00

## Frozen Contract Status

- Status: `frozen`
- Source root: `/Users/user/Documents/sap-oss/docs/Archive/machine-readable`
- Contract manifest: `phase0_contract_freeze.json`

## Baseline Metrics

- Total records: `102695`
- Total tables: `5`
- Total sources: `5`
- Quality issues: `258`
- Mandatory coverage: `47.15%`
- ODPS valid: `True`

## Issue Breakdown

- placeholder_cleared: `251`
- missing_unique_id_replaced: `5`
- datatype_score_to_decimal: `2`

## HANA Preparation Outputs

- `phase0_field_catalog.csv`
- `phase0_field_catalog.json`
- `phase0_hana_domains.yaml`
- `phase0_target_schemas.yaml`
- `phase0_schema_skeleton.sql`

## Target Schemas

- `FINSIGHT_CORE` - normalized onboarding data model
- `FINSIGHT_RAG` - chunk + embedding retrieval model
- `FINSIGHT_GOV` - quality and ODPS governance evidence
- `FINSIGHT_GRAPH` - lineage/semantic graph model

## Notes

- Field typing in `phase0_field_catalog` is intentionally conservative and profile-driven.
- Exact physical table DDL, constraints, and indexes are Phase 1 deliverables.
