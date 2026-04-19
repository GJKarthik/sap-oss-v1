# Schema Test Fixtures

Test fixtures for validating JSON schemas as promised in cross-document-addendum §6.2.

## Directory Structure

```
tests/fixtures/schema/
├── README.md
├── arabic/
│   ├── valid/       # Valid instances that MUST pass validation
│   └── invalid/     # Invalid instances that MUST fail validation
├── tb/
│   ├── valid/
│   └── invalid/
├── simula/
│   └── valid/
└── regulations/
    └── valid/
```

## Naming Convention

Fixtures follow the pattern: `{schema-name}_{description}.json`

Examples:
- `invoice_minimal.json` - Minimal valid invoice
- `invoice_full.json` - Complete invoice with all optional fields
- `invoice_missing-required.json` - Invalid: missing required fields

## Running Validation

```bash
# Validate all fixtures
python docs/schema/validate.py --validate-all

# Validate specific fixture
python docs/schema/validate.py --domain arabic --schema invoice.schema.json --file tests/fixtures/schema/arabic/valid/invoice_minimal.json
```

## CI Integration

These fixtures are validated automatically via `.github/workflows/schema-validation.yml` on every PR.