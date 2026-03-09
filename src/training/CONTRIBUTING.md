# Contributing Guide

## Development Setup

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Zig | ≥ 0.15.1 | [ziglang.org/download](https://ziglang.org/download/) |
| Python | ≥ 3.11 | System package manager |
| Node.js | ≥ 18 | [nodejs.org](https://nodejs.org/) |
| Docker | ≥ 24 | [docker.com](https://www.docker.com/) |

### First-Time Setup

```bash
git clone <repo-url> && cd training-main
make setup          # Install all dependencies
make test           # Verify everything works
```

### Per-Component Setup

```bash
# Python (ModelOpt API + Pipeline)
python -m venv .venv && source .venv/bin/activate
pip install -r nvidia-modelopt/requirements.txt
pip install -r pipeline/preconvert/requirements.txt

# Angular UI
cd nvidia-modelopt/ui && npm install

# Zig (no setup needed — just ensure zig is on PATH)
zig version
```

## Code Style

### Python
- **Formatter**: `ruff format`
- **Linter**: `ruff check`
- **Type hints**: Required on all public functions
- **Docstrings**: Google style
- **Line length**: 100 characters

### Zig
- **Formatter**: `zig fmt`
- **Naming**: `camelCase` for functions/variables, `PascalCase` for types
- **Memory**: Use unmanaged `ArrayList`/`HashMap` (Zig 0.15.1 patterns)
- **Errors**: Return error unions, never `@panic` in library code

### TypeScript / Angular
- **Formatter**: Prettier (`.prettierrc`)
- **Linter**: ESLint with `angular-eslint`
- **Components**: Standalone (no NgModules)
- **Style**: Single quotes, 2-space indent, trailing commas

### Mojo
- **Style**: Follow existing `.🔥` / `.mojo` file conventions
- **Docstrings**: Python-style triple-quote
- **Tests**: `fn main()` test runner at bottom of each file

### Mangle
- **Comments**: `//` line comments with section headers
- **Declarations**: `Decl` before first use of each predicate
- **Organization**: One domain per file, base facts at bottom

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `build`, `ci`, `chore`

**Scopes:** `pipeline`, `modelopt`, `hippocpp`, `ui`, `ci`, `docs`

**Examples:**
```
feat(pipeline): add hierarchy parser for NFRP dimensions
fix(modelopt): handle missing GPU gracefully in /gpu/status
test(hippocpp): expand parity corpus with DDL edge cases
docs: add root README with architecture diagram
ci: add Zig test job to GitHub Actions workflow
```

## Pull Request Process

1. **Branch naming**: `<type>/<short-description>` (e.g., `feat/pipeline-validation`)
2. **Before opening PR**:
   ```bash
   make lint           # All linters pass
   make test           # All tests pass
   ```
3. **PR description**: Include what changed, why, and how to test
4. **Review**: At least one approval required
5. **Merge**: Squash merge to `main`

## Testing Requirements

### New Features
- Unit tests required for all new functions/methods
- Integration tests for API endpoints
- Parity corpus entries for HippoCPP changes

### Test Commands

```bash
make test              # Run everything
make test-python       # Python tests only (pytest)
make test-zig          # Zig tests only (zig build test)
make test-ui           # Angular tests only (ng test)
make parity-check      # HippoCPP parity gate
```

### Coverage Targets

| Component | Target | Tool |
|-----------|--------|------|
| Python API | ≥ 80% | `pytest --cov` |
| Angular UI | ≥ 80% | `ng test --code-coverage` |
| Zig | All modules compile + test | `zig build test` |

## Adding a New Pipeline Stage

1. Create `pipeline/zig/src/<stage_name>.zig` with tests
2. Add module to `pipeline/zig/build.zig`
3. Add Makefile target in `pipeline/Makefile`
4. Add Mangle validation rules if applicable
5. Update `pipeline/Makefile` `all` target dependency chain

## Adding a New API Endpoint

1. Add route handler in `nvidia-modelopt/api/main.py` or a new router
2. Add Pydantic models for request/response
3. Add tests in `nvidia-modelopt/tests/`
4. Update `nvidia-modelopt/API.md`
5. Wire auth/rate-limiting dependencies if mutating

## Project Contacts

Open an issue for questions, bugs, or feature requests.

