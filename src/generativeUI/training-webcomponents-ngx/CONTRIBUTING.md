# Contributing to training-console

Thank you for contributing! This document explains how to get the project running locally and what is expected for every contribution.

---

## Prerequisites

| Tool | Version |
|------|---------|
| Node.js | ≥ 20 LTS |
| Yarn | 4 (Corepack) |
| Angular CLI | 20 (via Nx) |
| Python | 3.11+ (for the FastAPI backend) |

Enable Corepack once:

```bash
corepack enable
```

---

## Local Setup

```bash
# 1. Install dependencies
yarn install

# 2. Start the FastAPI training API (port 8001)
cd ../../  # repo root
docker-compose up api-server

# 3. Start the Angular shell dev server (port 4200)
yarn nx serve angular-shell
```

---

## Development Workflow

### Branch Naming

```
feat/<short-description>
fix/<issue-number>-<short-description>
chore/<short-description>
docs/<short-description>
```

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(registry): add deploy confirmation modal
fix(pipeline): handle WebSocket reconnect on 1006 close
test(compare): add history capping spec
```

---

## Testing

```bash
# Unit tests (Jest / Angular TestBed)
yarn nx test angular-shell

# Unit tests in watch mode
yarn nx test angular-shell --watch

# E2E tests (Playwright)
yarn nx e2e angular-shell-e2e

# All checks (lint + test + build)
yarn nx run-many --target=lint,test,build --all
```

Every pull request must:

- Pass all existing unit tests
- Add or update component specs for any changed component logic
- Pass lint with zero warnings (`eslint --max-warnings=0`)

---

## Code Style

- Angular 20 **standalone components** only — no `NgModule`
- Use Angular **Signals** (`signal()`, `computed()`) for reactive state; avoid `BehaviorSubject` in components
- HTTP calls go through `ApiService`; never inject `HttpClient` directly in a component
- Errors must be handled via `ApiService.withResilience()` — do not swallow errors silently
- All public component methods must have a unit test

---

## Pull Request Checklist

- [ ] `yarn nx test angular-shell` passes
- [ ] `yarn nx lint angular-shell` passes with 0 warnings
- [ ] New component spec added/updated
- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] No `console.log` statements left in production code
