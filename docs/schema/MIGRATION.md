# Schema Migration Guide

Guide for migrating to new schema versions and adopting new conventions.

## Migration: Adding `additionalProperties: false`

**When**: All schemas updated April 2026  
**Impact**: Strict mode - extra fields now rejected

### What Changed

All 20 schemas now enforce strict field validation:

```json
{
  "type": "object",
  "additionalProperties": false,
  "properties": { ... }
}
```

### Migration Steps

1. **Audit existing data** - Check for undocumented fields:
   ```bash
   python docs/schema/validate.py --domain arabic --schema invoice.schema.json --file your-data.json
   ```

2. **Remove or document extra fields** - Either:
   - Remove undocumented fields from data
   - Request schema extension via PR

3. **Update producers** - Ensure code doesn't emit unknown fields

### Common Issues

| Error | Cause | Fix |
|-------|-------|-----|
| `Additional properties are not allowed` | Extra field in data | Remove field or extend schema |
| `'xyz' is not valid under any of the given schemas` | Nested object has extra field | Check nested definitions |

---

## Migration: MoSCoW Traceability Fields

**When**: Added April 2026  
**Impact**: Optional fields for roadmap alignment

### What Changed

New optional fields available in all schemas via `common/base-types.schema.json`:

```yaml
roadmap_traceability:
  roadmap_milestones: ["M01", "M05"]
  requirement_ids: ["REG-MGF-2.1.1-001"]
  moscow_priority: "Must"
```

### Migration Steps

1. **No breaking changes** - Fields are optional
2. **Adopt gradually** - Add traceability to new records
3. **Reference milestones** - Use IDs from `common/moscow.yaml`

### Milestone ID Reference

| Domain | Milestones |
|--------|------------|
| Arabic AP | M01-M09 (e.g., M01_invoice_schema_v1) |
| TB Review | M01-M09 (e.g., M01_variance_detection_baseline) |
| Simula | M01-M09 (e.g., M06_worked_example_published) |
| Regulations | M01-M09 (e.g., M01_mgf_requirements_mapped) |

---

## Migration: jsonschema 4.x/5.x Compatibility

**When**: validate.py updated April 2026  
**Impact**: Required for users of validation scripts

### What Changed

The validator now uses the modern `referencing` library instead of deprecated `RefResolver`.

### Migration Steps

1. **Update dependencies**:
   ```bash
   pip install -r docs/schema/requirements.txt
   ```

2. **Required packages**:
   - `jsonschema>=4.20.0,<5.0.0`
   - `referencing>=0.31.0`
   - `pyyaml>=6.0.1`

### Compatibility Matrix

| jsonschema | referencing | Status |
|------------|-------------|--------|
| 3.x | N/A | ❌ Not supported |
| 4.17+ | 0.31+ | ✅ Supported |
| 5.x | 0.31+ | ✅ Supported (untested) |

---

## Migration: Test Fixtures

**When**: Added April 2026  
**Impact**: New test resources available

### Directory Structure

```
tests/fixtures/schema/
├── arabic/
│   ├── valid/     # Examples that MUST pass
│   └── invalid/   # Examples that MUST fail
├── tb/
│   ├── valid/
│   └── invalid/
├── simula/
│   └── valid/
└── regulations/
    └── valid/
```

### Using Fixtures

```bash
# Validate a fixture
python docs/schema/validate.py \
  --domain arabic \
  --schema invoice.schema.json \
  --file tests/fixtures/schema/arabic/valid/invoice_minimal.json

# Expect failure for invalid fixtures
python docs/schema/validate.py \
  --domain arabic \
  --schema invoice.schema.json \
  --file tests/fixtures/schema/arabic/invalid/invoice_extra-field.json
# Should exit with code 1
```

---

## Future Migrations

### Planned: JSON Schema Draft 2020-12

No timeline set. When migrating:
- Update `$schema` URI
- Review `$ref` resolution changes
- Test all schemas thoroughly

### Planned: OpenAPI 3.1 Alignment

No timeline set. Changes may include:
- Nullable type handling
- discriminator support
- Example consolidation