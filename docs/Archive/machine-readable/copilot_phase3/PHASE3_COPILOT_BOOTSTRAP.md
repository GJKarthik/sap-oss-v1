# Phase 3 Copilot Integration

Generated at: 2026-03-03T05:05:26.554069+00:00

## Scope

- Copilot database class: `FinSight`
- Data source: `/Users/user/Documents/sap-oss/docs/Archive/machine-readable`
- Schema source: `/Users/user/Documents/sap-oss/docs/Archive/machine-readable/odata_phase2/finsight_schema.edmx`
- Derived checks source: `/Users/user/Documents/sap-oss/docs/Archive/machine-readable/odata_phase2/finsight_derived_checks.json`

## Integration Status

- Tables loaded: `13/13`
- Rule-based checks: `7`
- Phase 2 derived checks: `15`
- Validation smoke test executed: `True`

## Commands

```bash
cd /Users/user/Documents/sap-oss/data-cleaning-copilot-main
uv run python -m bin.copilot -d finsight --data-dir /Users/user/Documents/sap-oss/docs/Archive/machine-readable
```

```bash
cd /Users/user/Documents/sap-oss/data-cleaning-copilot-main
uv run python -m bin.api -d finsight --data-dir /Users/user/Documents/sap-oss/docs/Archive/machine-readable --port 8000
```

## Outputs

- `phase3_validation_report.json`
- `phase3_session_blueprint.json`
