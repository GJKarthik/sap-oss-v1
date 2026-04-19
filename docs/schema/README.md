# Unified Schema Registry

**Version:** 1.0  
**Last Updated:** April 2026  
**Purpose:** Single source of truth for JSON Schemas across all domain specifications

This registry addresses the schema divergence identified in the April 2026 specification review:

| Document | Previous Approach | Unified Approach |
|----------|-------------------|------------------|
| Simula | In-memory `SchemaRegistry` | → `docs/schema/simula/` |
| Arabic AP | JSON Schema with local `$ref` | → `docs/schema/arabic/` |
| Trial Balance | Draft-07 in `machine-readable/` | → `docs/schema/tb/` |
| Regulations | Draft-07 with custom validator | → `docs/schema/regulations/` |

---

## Directory Structure

```
docs/schema/
├── README.md                    # This file
├── validate.py                  # Unified validator for all domains
├── registry.json                # Master index of all schemas
│
├── common/                      # Shared definitions
│   ├── enums.yaml               # Consolidated enum values
│   ├── base-types.schema.json   # Common type definitions
│   └── metadata.schema.json     # Shared metadata fields
│
├── arabic/                      # Arabic AP Invoice domain
│   ├── invoice.schema.json      # Main invoice schema
│   ├── vat-checklist.schema.json
│   ├── vendor.schema.json
│   └── enums/
│       ├── countries.yaml
│       └── vat-thresholds.yaml  # Per-country thresholds
│
├── tb/                          # Trial Balance domain
│   ├── tb-extract.schema.json   # TB extract schema
│   ├── pl-extract.schema.json   # P&L extract schema
│   ├── variance-record.schema.json
│   ├── commentary-draft.schema.json
│   └── decision-point.schema.json
│
├── simula/                      # Simula Training Data domain
│   ├── taxonomy.schema.json     # Taxonomy structure
│   ├── training-example.schema.json
│   ├── schema-registry.schema.json
│   └── config.schema.json       # Pipeline configuration
│
└── regulations/                 # AI Governance domain
    ├── regulation.schema.json   # Regulation record
    ├── requirement.schema.json  # Requirement with status
    ├── conformance-tool.schema.json
    └── corpus.schema.json       # Top-level index
```

---

## Usage

### Validation

```bash
# Validate all schemas
python3 docs/schema/validate.py --all

# Validate a specific domain
python3 docs/schema/validate.py --domain arabic

# Validate a single file against its schema
python3 docs/schema/validate.py --file docs/arabic/structured/invoices/invoice-001.json
```

### Schema References

All schemas use JSON Schema Draft-07 with `$ref` pointing to this registry:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://sap-oss.github.io/schema/arabic/invoice.schema.json",
  "$ref": "../common/base-types.schema.json#/definitions/Metadata"
}
```

### In Python Code

```python
from docs.schema import SchemaRegistry

registry = SchemaRegistry()

# Load and validate
schema = registry.get("arabic/invoice")
registry.validate(data, "arabic/invoice")

# List available schemas
registry.list_schemas("tb")  # ['tb-extract', 'pl-extract', ...]
```

---

## Schema Standards

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Schema files | `kebab-case.schema.json` | `invoice.schema.json` |
| Enum files | `kebab-case.yaml` | `vat-thresholds.yaml` |
| `$id` URIs | Domain-prefixed | `https://sap-oss.github.io/schema/arabic/invoice.schema.json` |

### Required Metadata

Every schema must include:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "<canonical URI>",
  "title": "<Human-readable title>",
  "description": "<Purpose and usage>",
  "version": "1.0.0",
  "x-domain": "<arabic|tb|simula|regulations>"
}
```

### Versioning

- Schemas follow SemVer (`MAJOR.MINOR.PATCH`)
- Breaking changes require new `$id` version suffix
- Old versions remain available at versioned paths

---

## Migration Guide

### From Existing Locations

| Old Location | New Location | Action |
|--------------|--------------|--------|
| `docs/tb/machine-readable/training-data/*.yaml` | `docs/schema/tb/` | Converted to JSON Schema |
| LaTeX-embedded schemas | `docs/schema/<domain>/` | Extracted to standalone files |
| In-memory `SchemaRegistry` | `docs/schema/registry.json` | Serialized to file |

### Migration Status

- [x] Registry structure created
- [ ] Arabic schemas extracted (pending)
- [ ] TB schemas converted from YAML (pending)
- [ ] Simula schemas extracted (pending)
- [ ] Regulations schemas consolidated (pending)
- [ ] Unified validator implemented (pending)

---

## Related Documentation

- [ERRATA.md](../latex/specs/ERRATA.md) — Known schema-related issues
- [Arabic AP Spec](../latex/specs/arabic/) — Chapter 2: Data Schema
- [TB Spec](../latex/specs/tb/) — Chapter 2: Data Schema
- [Simula Spec](../latex/specs/simula/) — Chapter 2: Data Schema
- [Regulations Spec](../latex/specs/regulations/) — Schema validation