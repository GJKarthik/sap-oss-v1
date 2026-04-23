# Spec-Drift Audit System

> **Prevents specification drift between LaTeX specifications, JSON schemas, and implementation code.**

## Overview

The spec-drift auditor is an automated system that monitors the repository for synchronization between:

- **LaTeX Specifications** (`docs/latex/specs/`) - Normative business and technical requirements
- **JSON Schemas** (`docs/schema/`) - Data contracts and validation rules  
- **Implementation Code** (`src/`) - Runtime behavior

When any of these artifacts change, the auditor ensures related artifacts are also updated to maintain consistency.

## Quick Start

```bash
# Run a full audit
make audit-spec-drift

# Check specific domain
make audit-spec-drift-domain DOMAIN=simula

# Quick check on local changes
make audit-spec-drift-quick

# Install pre-commit hook
make audit-install-hook
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        SPEC-DRIFT AUDIT SYSTEM                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │
│  │   LaTeX      │    │    JSON      │    │    Python    │                   │
│  │   Specs      │◄──►│   Schemas    │◄──►│    Code      │                   │
│  └──────────────┘    └──────────────┘    └──────────────┘                   │
│         │                  │                    │                           │
│         └──────────────────┼────────────────────┘                           │
│                            │                                                │
│                            ▼                                                │
│              ┌────────────────────────────┐                                 │
│              │  spec-code-mapping.yaml    │  ◄── Traceability Registry     │
│              └────────────────────────────┘                                 │
│                            │                                                │
│                            ▼                                                │
│              ┌────────────────────────────┐                                 │
│              │     audit.py               │  ◄── Drift Detection Engine    │
│              └────────────────────────────┘                                 │
│                            │                                                │
│              ┌─────────────┼─────────────┐                                  │
│              ▼             ▼             ▼                                  │
│      ┌───────────┐  ┌───────────┐  ┌───────────┐                           │
│      │ Pre-commit│  │  CI/CD    │  │  Manual   │                           │
│      │   Hook    │  │ Workflow  │  │  Review   │                           │
│      └───────────┘  └───────────┘  └───────────┘                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `.clinerules.spec-drift-auditor` | Agent rules defining drift detection behavior |
| `docs/schema/spec-code-mapping.yaml` | Maps relationships between specs, schemas, and code |
| `docs/schema/drift-exceptions.yaml` | Approved exceptions to drift rules |
| `scripts/spec-drift/audit.py` | Main audit script implementation |
| `scripts/spec-drift/pre-commit-hook.sh` | Git pre-commit hook |
| `.github/workflows/spec-drift-audit.yml` | CI/CD workflow for automated checks |

## Drift Types

| Code | Description | Severity Range |
|------|-------------|----------------|
| `DRIFT-001` | Schema-Spec Drift - Schema field changed without spec update | HIGH/MEDIUM |
| `DRIFT-002` | Code-Schema Drift - Code references non-existent schema fields | CRITICAL/HIGH |
| `DRIFT-003` | Code-Spec Drift - Code behavior contradicts spec requirement | CRITICAL/HIGH |
| `DRIFT-004` | Version Drift - Version numbers out of sync | HIGH/MEDIUM |
| `DRIFT-005` | Cross-Domain Drift - Shared enum changed without updating consumers | CRITICAL/HIGH |
| `DRIFT-006` | Threshold Drift - Code uses different threshold than spec | HIGH/MEDIUM |
| `DRIFT-007` | State Machine Drift - Workflow states differ between code and spec | CRITICAL/HIGH |
| `DRIFT-008` | API Contract Drift - API differs from spec documentation | CRITICAL/HIGH |

## Usage

### Command Line

```bash
# Full audit (all domains)
python3 scripts/spec-drift/audit.py --mode full

# PR mode (compares branches)
python3 scripts/spec-drift/audit.py --mode pr --base-ref main --head-ref feature-branch

# Pre-commit mode (specific files)
python3 scripts/spec-drift/audit.py --mode pre-commit --changed-files file1.py file2.tex

# Specific domain
python3 scripts/spec-drift/audit.py --mode full --domain simula

# Output formats
python3 scripts/spec-drift/audit.py --mode full --output-format json
python3 scripts/spec-drift/audit.py --mode full --output-format yaml
python3 scripts/spec-drift/audit.py --mode full --output-format github-actions
```

### Make Targets

```bash
# Full audit
make audit-spec-drift

# Specific domain
make audit-spec-drift-domain DOMAIN=simula

# Quick check on changes
make audit-spec-drift-quick

# JSON output
make audit-spec-drift-json

# YAML output  
make audit-spec-drift-yaml

# CI mode (fails on blocking)
make audit-spec-drift-ci

# Install pre-commit hook
make audit-install-hook

# Validate mapping registry
make audit-check-mapping

# List available domains
make audit-list-domains

# Review exceptions
make audit-exceptions-review
```

## Configuration

### spec-code-mapping.yaml

The mapping registry defines relationships between artifacts:

```yaml
domains:
  simula:
    spec_root: docs/latex/specs/simula
    schema_root: docs/schema/simula
    code_root: src/training
    
    artifacts:
      - id: simula-taxonomy
        type: chapter
        spec_path: docs/latex/specs/simula/chapters/05-taxonomy-engine.tex
        related_schemas:
          - docs/schema/simula/taxonomy.schema.json
        related_code:
          - src/training/pipeline/simula_taxonomy_builder.py
        sync_rules:
          - "Taxonomy node structure changes require spec and schema update"
```

### Drift Exceptions

Temporary exceptions can be added to `docs/schema/drift-exceptions.yaml`:

```yaml
exceptions:
  - id: "EXC-001"
    created: "2026-04-21"
    expires: "2026-06-21"
    owner: "team-lead@example.com"
    drift_type: "DRIFT-003"
    file_pattern: "src/training/experiments/.*"
    rationale: |
      Experimental code is not yet production-ready.
    resolution_plan: |
      Formalize or remove before GA.
    tracking_issue: "https://github.com/org/repo/issues/123"
```

## CI/CD Integration

The GitHub Actions workflow automatically runs on:

- **Pull Requests** to `main` or `develop` branches
- **Pushes** to `main` branch
- **Manual trigger** via workflow dispatch

### PR Behavior

1. Audit runs on all changed files
2. Results posted as PR comment
3. Blocking issues prevent merge
4. Non-blocking issues generate warnings

### Main Branch Behavior

1. Full audit runs on every push
2. Critical drift creates GitHub issue
3. Audit logs archived as artifacts

## Severity Levels

| Severity | Blocking | Action Required |
|----------|----------|-----------------|
| **CRITICAL** | Yes | Must fix before merge |
| **HIGH** | Yes (configurable) | Should fix before merge |
| **MEDIUM** | No | Create follow-up issue |
| **LOW** | No | Note in PR description |
| **INFO** | No | Informational only |

## Remediation Workflow

### When Drift is Detected

1. **Review the finding** - Check if the drift is intentional or accidental
2. **Choose remediation path:**

   - **Option A: Update in same PR** (Preferred)
     - Add commits to update related artifacts
     - Re-run audit to verify

   - **Option B: Create follow-up issue**
     - Link issue in PR description
     - Assign owner and milestone
     - Must resolve within one sprint

   - **Option C: Request RFC for spec change**
     - Document rationale for divergence
     - Get spec owner approval
     - Update spec before code ships

   - **Option D: Add drift exception**
     - Only for temporary situations
     - Must have expiration date
     - Reviewed monthly

## Adding New Domains

When adding a new specification domain:

1. Create spec directory: `docs/latex/specs/<domain>/`
2. Create schema directory: `docs/schema/<domain>/`
3. Add domain to `docs/schema/spec-code-mapping.yaml`:

```yaml
domains:
  new-domain:
    spec_root: docs/latex/specs/new-domain
    schema_root: docs/schema/new-domain
    code_root: src/new-domain
    
    artifacts:
      - id: new-domain-spec-main
        type: specification
        path: docs/latex/specs/new-domain/new-domain-spec.tex
```

4. Validate: `make audit-check-mapping`

## Troubleshooting

### "Mapping registry not found"

Ensure `docs/schema/spec-code-mapping.yaml` exists and is valid YAML:

```bash
make audit-check-mapping
```

### "Schema validation failed"

Check schema syntax:

```bash
python3 -c "import json; json.load(open('path/to/schema.json'))"
```

### False Positives

If a finding is incorrect, add an exception or update the mapping registry to reflect the actual relationship.

### Pre-commit Hook Not Running

Verify installation:

```bash
ls -la .git/hooks/pre-commit
```

Reinstall if needed:

```bash
make audit-install-hook
```

## Dependencies

- Python 3.8+
- PyYAML: `pip install pyyaml`
- jsonschema (optional, for schema validation): `pip install jsonschema`

## Contributing

When modifying the audit system:

1. Update `.clinerules.spec-drift-auditor` if adding new drift types
2. Update `docs/schema/spec-code-mapping.yaml` for new domains/artifacts
3. Update this README for documentation changes
4. Test changes with `make audit-spec-drift`

## Related Documentation

- [.clinerules.spec-drift-auditor](../../.clinerules.spec-drift-auditor) - Agent rules
- [spec-code-mapping.yaml](../../docs/schema/spec-code-mapping.yaml) - Traceability registry
- [drift-exceptions.yaml](../../docs/schema/drift-exceptions.yaml) - Exception registry
- [clinerules-agents-spec](../../docs/latex/specs/clinerules-agents/) - Agent specification