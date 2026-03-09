# training-main

A multi-component platform for generating **Text-to-SQL training data** from banking/financial schemas on SAP HANA, with an integrated **model optimization microservice** and a **graph database engine** ported from C++ to Zig, Mojo, and Mangle.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        training-main                                │
├──────────────┬──────────────────┬──────────────┬────────────────────┤
│  pipeline/   │  nvidia-modelopt/│  hippocpp/   │  data/             │
│              │                  │              │                    │
│  Excel→CSV   │  FastAPI service │  Zig core    │  Banking Excel     │
│  Schema ext. │  OpenAI compat   │  Mojo GPU    │  NFRP hierarchies  │
│  SQL gen.    │  Angular UI      │  Mangle rules│  Prompt templates  │
│  Validation  │  Quantization    │  Parity CI   │                    │
│  Spider fmt  │  Metrics/Auth    │              │                    │
└──────────────┴──────────────────┴──────────────┴────────────────────┘
```

**Data flow:**

```
Excel files ──→ CSV ──→ Schema Registry ──→ Template Expansion ──→ Text-SQL Pairs
                                                                        │
                                                    Mangle Validation ◄─┘
                                                         │
                                                    Spider/BIRD Format
                                                         │
                                              Fine-tune → Quantize → Serve
```

## Components

| Component | Language | Description |
|-----------|----------|-------------|
| [`pipeline/`](pipeline/) | Zig + Python + Mangle | 7-stage Text-to-SQL data generation pipeline |
| [`nvidia-modelopt/`](nvidia-modelopt/) | Python + TypeScript | Model optimization microservice with Angular UI |
| [`hippocpp/`](hippocpp/) | Zig + Mojo + Mangle | Graph database engine (Kuzu port) |
| [`data/`](data/) | — | Banking data assets (Excel, CSV, templates) |

## Quick Start

### Prerequisites

- **Zig** ≥ 0.15.1
- **Python** ≥ 3.11
- **Node.js** ≥ 18 (for Angular UI)
- **Docker** (optional, for containerized deployment)

### Build & Test Everything

```bash
make setup    # Install Python deps, Node modules
make build    # Build Zig binaries, Angular app
make test     # Run all test suites
make lint     # Lint Python, TypeScript, Zig
```

### Run the Pipeline

```bash
cd pipeline
make all      # Full 7-stage pipeline: preconvert → extract → parse → expand → validate → format
```

### Run the ModelOpt Service

```bash
cd nvidia-modelopt
pip install -r requirements.txt
python -m uvicorn api.main:app --port 8001

# UI (separate terminal)
cd ui && npm install && npm start
# Open http://localhost:4200
```

### Run HippoCPP Tests

```bash
cd hippocpp/zig
zig build test
```

## Project Structure

```
training-main/
├── .github/workflows/     # CI/CD (lint, test, build, parity gate)
├── data/                  # Banking data assets
├── docs/plans/            # Implementation plans
├── hippocpp/              # Graph database engine
│   ├── zig/               # 1,251 Zig source files
│   ├── mojo/              # GPU-accelerated modules
│   ├── mangle/            # Datalog rules & invariants
│   ├── python/            # Python bindings
│   └── parity/            # Differential test corpus
├── nvidia-modelopt/       # Model optimization service
│   ├── api/               # FastAPI backend
│   ├── ui/                # Angular 18 frontend
│   ├── tests/             # 50+ pytest tests
│   └── configs/           # Quantization configs
├── pipeline/              # Text-to-SQL pipeline
│   ├── preconvert/        # Excel → CSV (Python)
│   ├── zig/               # Core pipeline (Zig)
│   └── mangle/            # Validation rules
├── Makefile               # Root build orchestration
├── docker-compose.yml     # Multi-service deployment
├── pyproject.toml         # Python project config
└── .pre-commit-config.yaml
```

## Documentation

- [Architecture Guide](ARCHITECTURE.md) — System design, data flow, technology rationale
- [Contributing Guide](CONTRIBUTING.md) — Dev setup, code style, PR process
- [API Reference](nvidia-modelopt/API.md) — ModelOpt endpoint documentation
- [Security Guide](nvidia-modelopt/SECURITY.md) — Auth, CORS, secrets management
- [HippoCPP README](hippocpp/README.md) — Graph database engine details
- [Parity Matrix](hippocpp/PARITY-MATRIX.md) — Kuzu conversion tracking
- [Pipeline Plan](docs/plans/2026-03-06-text-to-sql-pipeline-implementation.md) — Pipeline design doc

## Testing

| Suite | Command | Tests |
|-------|---------|-------|
| Python API | `cd nvidia-modelopt && pytest` | 50 tests |
| Zig Pipeline | `cd pipeline/zig && zig build test` | 52 tests |
| Zig HippoCPP | `cd hippocpp/zig && zig build test` | 1,251+ modules |
| Angular UI | `cd nvidia-modelopt/ui && ng test` | 44 tests |
| Mangle Rules | `cd hippocpp/mangle && python tests/validate_rules.py` | Rule validation |

## License

Apache-2.0

