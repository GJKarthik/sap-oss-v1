# Schema Integration Guide

This document explains the relationship between the JSON schemas in `docs/schema/` and the training code in `src/training/`.

## Overview

```
docs/schema/                    ← JSON Schema definitions (specification)
├── simula/
│   ├── training-example.schema.json  ← Full/strict schema
│   ├── config.schema.json
│   └── ...
└── common/
    ├── base-types.schema.json
    └── enums.yaml

src/training/                   ← Training code (implementation)
├── data/                       ← Training data files
│   ├── massive_semantic/
│   │   ├── train.jsonl
│   │   └── ...
│   └── specialist_training/
├── schema_pipeline/            ← Data generation pipeline
│   ├── schema_validator.py     ← Validates data against schemas
│   └── ...
└── pipeline/                   ← Core pipeline code
```

## Schema Formats

### 1. Simple/Flexible Format (Current Production)

The current training data uses a simpler format optimized for fine-tuning:

```json
{
  "question": "What is the net turnover year to date?",
  "sql": "SELECT NET_TURNOVER FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN WHERE PERIOD = 'YTD'",
  "domain": "performance",
  "type": "aggregate",
  "term": "revenue",
  "context": "analytics_ui",
  "system_prompt": "You are a financial performance analytics assistant..."
}
```

**Required fields**: `question`, `sql`
**Optional fields**: `domain`, `type`, `term`, `context`, `system_prompt`

### 2. Strict/Full Format (Research/Audit)

The `docs/schema/simula/training-example.schema.json` defines a richer format for research and audit:

```json
{
  "id": "sim-001",
  "question": "What is the net turnover year to date?",
  "sql": "SELECT NET_TURNOVER FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN WHERE PERIOD = 'YTD'",
  "complexity_score": 0.25,
  "complexity_level": "EASY",
  "critic_passed": true,
  "taxonomy_path": ["query_type/select", "time_granularity/YTD"],
  "generation_metadata": { ... },
  "quality_signals": { ... }
}
```

## Validation

### Validate Training Data

```bash
# From src/training directory
cd src/training

# Simple validation (flexible schema)
python -m schema_pipeline.schema_validator --all

# Strict validation (full schema from docs/schema)
python -m schema_pipeline.schema_validator --all --strict

# Validate specific file
python -m schema_pipeline.schema_validator --file data/massive_semantic/train.jsonl

# JSON output for CI
python -m schema_pipeline.schema_validator --all --json-output
```

### Validate Schemas Themselves

```bash
# From project root
python docs/schema/validate.py --registry-check
python docs/schema/validate.py --validate-all
```

## CI Integration

The `.github/workflows/schema-validation.yml` workflow:

1. **validate-schemas**: Checks all schema files in `docs/schema/`
2. **validate-training-data**: Validates training data against schemas
3. **validate-fixtures**: Validates test fixtures

## Migration Path

### Current State → Strict Schema

If you want to migrate training data to the strict format:

1. Add required fields to each record:
   - `id`: Generate unique ID (e.g., `sim-{uuid}`)
   - `complexity_score`: Compute from SQL complexity
   - `critic_passed`: Add critic evaluation

2. Map fields:
   - `type` → `complexity_level` (EASY/MEDIUM/HARD)
   - Add `taxonomy_path` based on domain/type

3. Run validation:
   ```bash
   python -m schema_pipeline.schema_validator --all --strict
   ```

## Key Files

| File | Purpose |
|------|---------|
| `docs/schema/simula/training-example.schema.json` | Strict training example schema |
| `src/training/schema_pipeline/schema_validator.py` | Validation module |
| `docs/schema/validate.py` | Schema registry validator |
| `docs/schema/requirements.txt` | Python dependencies |

## Adding New Fields

1. Update the schema in `docs/schema/simula/training-example.schema.json`
2. Update `SIMPLE_TRAINING_EXAMPLE_SCHEMA` in `schema_validator.py` (if needed)
3. Update this documentation
4. Run validation to verify backward compatibility

## Troubleshooting

### "jsonschema not installed"
```bash
pip install -r docs/schema/requirements.txt
```

### "Strict schema not found"
Ensure you're running from the project root or `src/training` directory.

### Schema path issues
The validator automatically detects the project root. If paths are wrong, check:
- `PROJECT_ROOT` in `schema_validator.py`
- Run from `src/training` directory