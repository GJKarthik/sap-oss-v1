# Cline Agent Examples Gallery

This directory contains working, minimal examples of `.clinerules` configurations for various use cases. Each example is designed to be copied and adapted for new projects or domains.

## 📁 Directory Structure

```
docs/examples/clinerules/
├── README.md                           # This file
├── minimal/
│   ├── development-agent.clinerules   # Minimum viable development agent
│   └── runtime-monitor.clinerules     # Minimum viable runtime monitor
├── domain-specific/
│   ├── api-service.clinerules         # REST API service pattern
│   ├── ml-pipeline.clinerules         # Machine learning pipeline pattern
│   ├── frontend-app.clinerules        # Frontend application pattern
│   └── data-processor.clinerules      # Data processing service pattern
├── governance/
│   ├── regulatory-wrapper.clinerules  # Regulatory compliance pattern
│   └── audit-enabled.clinerules       # Full audit trail pattern
└── templates/
    ├── TEMPLATE-development.clinerules # Copy-paste template
    └── TEMPLATE-runtime-monitor.clinerules
```

## 🚀 Quick Start

### 1. Copy the Minimal Template

```bash
# For a new development agent
cp docs/examples/clinerules/minimal/development-agent.clinerules src/your-domain/.clinerules

# For a runtime monitor
cp docs/examples/clinerules/minimal/runtime-monitor.clinerules src/your-domain/.clinerules.runtime-monitor
```

### 2. Customize Required Sections

Replace placeholders in the template:
- `<DOMAIN_NAME>` → Your domain name (e.g., "Invoice Processing")
- `<DOMAIN_PATH>` → Your source path (e.g., "src/invoicing")
- `<SPEC_PATH>` → Related spec path (e.g., "docs/latex/specs/invoicing")
- `<SCHEMA_PATH>` → Related schema path (e.g., "docs/schema/invoicing")

### 3. Run Validation

```bash
# Validate your new rule pack
make test-clinerules-path PATH=src/your-domain/.clinerules
```

## 📋 Examples by Use Case

### Minimal Development Agent
**File:** `minimal/development-agent.clinerules`

The absolute minimum viable `.clinerules` file that passes validation. Use this when:
- Starting a new domain
- Prototyping quickly
- Learning the format

**Contains:**
- Purpose and mission statements
- Source of truth references
- Read-first file list
- Basic definition of done
- Minimal engineering rules

### Minimal Runtime Monitor
**File:** `minimal/runtime-monitor.clinerules`

The minimum viable runtime monitoring agent. Use this when:
- Adding basic health monitoring
- Starting observability journey
- Simple alert requirements

**Contains:**
- Health/unhealthy criteria
- Basic alert conditions
- Simple escalation path

### API Service Pattern
**File:** `domain-specific/api-service.clinerules`

Comprehensive pattern for REST API services. Use this when:
- Building new API endpoints
- Migrating existing APIs
- API-first development

**Contains:**
- OpenAPI contract references
- Request/response validation
- Rate limiting rules
- Authentication requirements
- Error handling patterns

### ML Pipeline Pattern
**File:** `domain-specific/ml-pipeline.clinerules`

Pattern for machine learning pipelines. Use this when:
- Training models
- Building inference services
- MLOps workflows

**Contains:**
- Model versioning rules
- Training data lineage
- Evaluation metrics thresholds
- Model deployment gates

### Frontend Application Pattern
**File:** `domain-specific/frontend-app.clinerules`

Pattern for frontend applications (Angular, React, etc.). Use this when:
- Building SPAs
- Component libraries
- Micro-frontends

**Contains:**
- Build configuration rules
- Asset path conventions
- Compression requirements
- Browser compatibility

### Regulatory Wrapper Pattern
**File:** `governance/regulatory-wrapper.clinerules`

Pattern for regulatory compliance. Use this when:
- Building governed services
- Audit requirements exist
- Identity attribution required

**Contains:**
- Deny-by-default enforcement
- Identity envelope requirements
- Audit trail configuration
- Compliance evidence rules

## 🎯 Choosing the Right Example

| Your Situation | Recommended Example |
|----------------|---------------------|
| Just getting started | `minimal/development-agent.clinerules` |
| Need monitoring | `minimal/runtime-monitor.clinerules` |
| Building REST APIs | `domain-specific/api-service.clinerules` |
| ML/AI workloads | `domain-specific/ml-pipeline.clinerules` |
| Frontend SPA | `domain-specific/frontend-app.clinerules` |
| Compliance required | `governance/regulatory-wrapper.clinerules` |
| Full governance | `governance/audit-enabled.clinerules` |

## 📝 Example Anatomy

Every example follows this structure:

```markdown
# =============================================================================
# <Domain> Development/Runtime-Monitor Agent Rules
# Path: <path>
# =============================================================================

Purpose
- What this agent does

Mission  
- What this agent is trying to achieve

Source Of Truth
- Normative references (specs, schemas)
- Implementation paths

Read First On Every Task
1. Step-by-step reading order

Current Repo Reality You Must Assume
- Known state of the codebase
- Important assumptions

Known Issue Registry
- <ID>: Issue description
  - symptom: ...
  - impact: ...
  - prevention: ...

Definition Of Done
- Completion criteria

Non-Negotiable Engineering Rules
1. Rule one
2. Rule two

Contract Rules (if applicable)
- Schema references
- Validation requirements

Integration Rules (if applicable)
- Cross-service dependencies

Pre-Change Checklist
- [ ] Item one
- [ ] Item two

Post-Change Smoke Tests
- Commands to verify

Completion Standard
- Final acceptance criteria

# VERSION HISTORY
| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | YYYY-MM-DD | Initial version |
```

## 🔧 Validation

All examples are validated in CI:

```bash
# Validate all examples
make test-clinerules-examples

# Validate specific example
python scripts/clinerules/validate_example.py docs/examples/clinerules/minimal/development-agent.clinerules
```

## 📚 Related Documentation

- [Full Specification](../../latex/specs/clinerules-agents/clinerules-agents-spec.tex)
- [Architecture Chapter](../../latex/specs/clinerules-agents/chapters/03-agent-rule-pack-architecture.tex)
- [Validation Standards](../../latex/specs/clinerules-agents/chapters/06-validation.tex)
- [Test Coverage Standards](../../latex/specs/clinerules-agents/chapters/07a-test-coverage-standards.tex)