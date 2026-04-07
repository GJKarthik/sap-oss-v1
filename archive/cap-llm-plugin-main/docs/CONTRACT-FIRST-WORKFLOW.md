# Contract-First Workflow

This document describes the contract-first development workflow used to keep
the CDS service definition, OpenAPI spec, and Angular client in sync.

---

## Artifacts

| Artifact | Path | Purpose |
|----------|------|---------|
| CDS Service Definition | `srv/llm-service.cds` | Source of truth for the API contract |
| OpenAPI 3.0.3 Spec | `docs/api/openapi.yaml` | Machine-readable API spec for client generation |
| Angular Client | `generated/angular-client/` | Typed Angular HTTP service + model interfaces |
| Contract Check Script | `scripts/contract-check.js` | CI drift detection |
| CI Workflow | `.github/workflows/contract-validation.yml` | GitHub Actions pipeline |

---

## Workflow Steps

### 1. Change the API

Edit `srv/llm-service.cds` — add, modify, or remove actions and types.

```bash
# Validate it compiles
npm run cds:validate
```

### 2. Update the OpenAPI Spec

Update `docs/api/openapi.yaml` to match the CDS changes:
- Add/modify paths for new/changed actions
- Add/modify component schemas for new/changed types
- Update request/response bodies

### 3. Update the Angular Client

Update `generated/angular-client/`:
- **`models.ts`** — Add/modify TypeScript interfaces to match OpenAPI schemas
- **`cap-llm-plugin.service.ts`** — Add/modify service methods to match new paths
- **`index.ts`** — Export any new interfaces or classes

### 4. Run the Contract Check

```bash
npm run contract:check
```

This validates:
1. CDS definition compiles without errors
2. Every CDS action has a corresponding OpenAPI path (and vice versa)
3. Angular client files exist
4. Every OpenAPI schema has a matching TypeScript interface in the Angular client

### 5. Run the Full CI Suite

```bash
npm run build && npm run lint && npm test
```

---

## CI Pipeline

The GitHub Actions workflow (`.github/workflows/contract-validation.yml`) runs
automatically on push/PR to `main` when any contract artifact is modified:

| Job | What it checks |
|-----|----------------|
| `validate-cds` | CDS definition compiles via `cdsc toCsn` |
| `validate-openapi` | CDS ↔ OpenAPI ↔ Angular client sync via `contract:check` |
| `build-and-test` | TypeScript build + ESLint + Jest test suite |

The pipeline triggers on changes to:
- `srv/llm-service.cds`
- `docs/api/openapi.yaml`
- `generated/angular-client/**`

---

## NPM Scripts Reference

| Script | Description |
|--------|-------------|
| `npm run cds:validate` | Compile CDS definition to CSN |
| `npm run contract:check` | Full contract drift detection |
| `npm run generate:client` | Reminder to update the Angular client manually |
| `npm run build` | TypeScript compilation |
| `npm run lint` | ESLint check |
| `npm test` | Jest test suite |

---

## Troubleshooting

**"CDS action X missing from OpenAPI spec"**
→ Add the corresponding POST path to `docs/api/openapi.yaml`.

**"OpenAPI path /X has no CDS action"**
→ Either add the action to `srv/llm-service.cds` or remove the stale path from the OpenAPI spec.

**"Schema X missing from Angular models"**
→ Add the matching `export interface X { ... }` to `generated/angular-client/models.ts`.
