# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-06

### Added

#### Repository Foundation
- Root `.gitignore` covering Python, Zig, Node.js, Mojo, and IDE artifacts
- `.editorconfig` for consistent formatting across all languages
- `.env.example` documenting all environment variables
- Organized `data/` directory for banking data assets

#### Security
- CORS hardening with explicit origin allowlisting (replaces `allow_origins=["*"]`)
- Bearer token authentication middleware for ModelOpt API
- Rate limiting (60 req/min) on mutating endpoints
- Migrated API key storage from `localStorage` to `sessionStorage`
- Security documentation (`nvidia-modelopt/SECURITY.md`)

#### Build & CI/CD
- Root `Makefile` with unified `make test`, `make lint`, `make build` targets
- `docker-compose.yml` for multi-service deployment (API + UI + GPU)
- GitHub Actions CI workflow (lint, test, build, parity gate)
- Pre-commit hooks configuration (`.pre-commit-config.yaml`)

#### Testing
- `pyproject.toml` with pytest config, coverage thresholds (≥80%), and markers
- 50 pytest tests for ModelOpt API (jobs, inference, OpenAI compat, embeddings)
- 52 Zig tests for Text-to-SQL pipeline (CSV parsing, schema, SQL gen, formatting)
- 44 Angular unit tests (Dashboard, Chat, Jobs, Models, ApiService, AuthInterceptor)
- HippoCPP parity corpus expansion (5+ corpus files)

#### ModelOpt API
- Real inference engine integration (replaces placeholder mocks)
- Model registry with config file loading
- SQLite-backed job persistence (replaces in-memory dict)
- Prometheus metrics endpoint (`/metrics`)
- Structured JSON logging with `structlog`

#### Frontend
- Angular 18 standalone components with full routing
- ESLint + Prettier configuration
- Dashboard, Chat, Models, Jobs components with spec files
- Proxy configuration for API integration

#### Text-to-SQL Pipeline
- 7-stage pipeline: preconvert → extract → parse → expand → validate → format
- Python Excel pre-converter (`openpyxl`)
- Zig core: RFC 4180 CSV parser, schema registry, hierarchy parser
- Zig core: template parser, HANA SQL builder, template expander, JSON emitter
- Zig core: Spider/BIRD formatter with 80/10/10 train/dev/test split
- Mangle validation rules (schema, SQL, domain, coverage, format)
- Pipeline `Makefile` orchestrating all stages

#### Mojo GPU Implementation
- `mojoproject.toml` and build configuration
- Storage engine with SIMD page copy and parallel I/O
- Buffer manager with clock eviction algorithm
- Table, NodeTable, RelTable, Column types
- HashIndex and HNSWIndex implementations
- Complete catalog (349 lines), expression evaluator (400 lines), graph model (476 lines)
- Common types module (LogicalType, Value, InternalID, PageIdx)
- 30 test functions across 4 test files

#### Mangle Datalog Rules
- MVCC transaction rules (visibility, conflict detection, garbage collection)
- Page management rules (allocation, WAL, integrity invariants)
- Catalog schema rules (referential integrity, DDL validation)
- Query optimization rules (index selection, predicate pushdown, join ordering)
- Rule validation harness (`validate_rules.py`)

#### Documentation
- Root `README.md` with architecture diagrams and quick start
- `ARCHITECTURE.md` with data flow diagrams and technology rationale
- `CONTRIBUTING.md` with code style guides and PR process
- `nvidia-modelopt/API.md` with full endpoint reference and curl examples
- Cleaned up HippoCPP README with architecture diagram and structured coverage table

#### Release Infrastructure
- `VERSION` file (semver)
- `CHANGELOG.md` (this file)
- Performance benchmark suite
- `DEPLOYMENT.md` deployment guide

### HippoCPP Zig Port
- 1,251 Zig source files covering all Kuzu subsystems
- 100% path coverage across 735 upstream C++ modules
- Zig 0.15.1 with unmanaged ArrayList/HashMap patterns
- Differential parity harness with CI gates

[0.1.0]: https://github.com/user/training-main/releases/tag/v0.1.0

