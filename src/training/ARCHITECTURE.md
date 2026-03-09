# Architecture Guide

## System Overview

training-main is a platform for generating high-quality Text-to-SQL training data from banking/financial schemas, optimizing language models for SQL generation, and serving them via an OpenAI-compatible API.

## Data Flow

```
┌──────────────┐     ┌──────────────┐     ┌──────────────────┐
│  Excel Files │────▶│  CSV Staging │────▶│  Schema Registry │
│  (data/*.xlsx)│     │  (preconvert)│     │  (schema_extractor│
└──────────────┘     └──────────────┘     │   hierarchy_parser)│
                                          └────────┬─────────┘
                                                   │
                     ┌──────────────┐     ┌────────▼─────────┐
                     │   Prompt     │────▶│ Template Expander │
                     │  Templates   │     │ (cartesian product│
                     │  (data/*.csv)│     │  difficulty class.)│
                     └──────────────┘     └────────┬─────────┘
                                                   │
                     ┌──────────────┐     ┌────────▼─────────┐
                     │ Mangle Rules │────▶│   Validation     │
                     │ (pipeline/   │     │ (schema, SQL,    │
                     │  mangle/*.mg)│     │  domain, coverage)│
                     └──────────────┘     └────────┬─────────┘
                                                   │
                                          ┌────────▼─────────┐
                                          │  Spider/BIRD     │
                                          │  Output Format   │
                                          │  (80/10/10 split)│
                                          └────────┬─────────┘
                                                   │
                     ┌──────────────┐     ┌────────▼─────────┐
                     │  Fine-tune   │────▶│  Quantize (INT8/ │
                     │  LLM on data │     │  INT4 AWQ/W4A16) │
                     └──────────────┘     └────────┬─────────┘
                                                   │
                                          ┌────────▼─────────┐
                                          │  Serve via       │
                                          │  OpenAI-compat   │
                                          │  API (port 8001) │
                                          └──────────────────┘
```

## Component Architecture

### 1. Text-to-SQL Pipeline (`pipeline/`)

A 7-stage data generation pipeline orchestrated by `pipeline/Makefile`:

| Stage | Tool | Input | Output |
|-------|------|-------|--------|
| 1. Preconvert | Python (`openpyxl`) | `data/*.xlsx` | `staging/*.csv` |
| 2. Build | Zig 0.15.1 | Source code | Pipeline binary |
| 3. Extract Schema | Zig | `staging/*.csv` | Schema registry (in-memory) |
| 4. Parse Templates | Zig | `data/prompt_templates.csv` | Parameterized templates |
| 5. Expand | Zig | Templates + Schema | Text-SQL pairs with difficulty |
| 6. Validate | Mangle | Pairs + Rules | Validated pairs |
| 7. Format | Zig | Validated pairs | Spider/BIRD JSONL (train/dev/test) |

**Key design decisions:**
- **Zig for core logic**: Zero-allocation CSV parsing, compile-time safety, no runtime overhead
- **Python for Excel**: `openpyxl` handles `.xlsx` format natively
- **Mangle for validation**: Declarative rules are easier to audit than imperative checks

### 2. Model Optimizer Service (`nvidia-modelopt/`)

```
┌─────────────────────────────────────────────────┐
│                  Angular 18 UI                   │
│  Dashboard │ Chat │ Models │ Jobs                │
│            │      │        │                     │
│  port 4200 │ ──── proxy ──── ▶ port 8001        │
└────────────┴──────┴────────┴─────────────────────┘
                              │
┌─────────────────────────────▼───────────────────┐
│              FastAPI Backend                     │
│                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │
│  │ Auth     │ │ Rate     │ │ Request ID       │ │
│  │ Middleware│ │ Limiter  │ │ + Metrics        │ │
│  └────┬─────┘ └────┬─────┘ └────────┬─────────┘ │
│       └─────────────┴───────────────┘            │
│                     │                            │
│  ┌──────────────────▼──────────────────────────┐ │
│  │              Route Handlers                  │ │
│  │  /health  /gpu/status  /models/*  /jobs/*   │ │
│  │  /v1/chat/completions  /v1/embeddings       │ │
│  │  /v1/models  /metrics                       │ │
│  └──────────────────┬──────────────────────────┘ │
│                     │                            │
│  ┌─────────┐ ┌──────▼─────┐ ┌────────────────┐  │
│  │ Model   │ │ Inference  │ │ Job Executor   │  │
│  │ Registry│ │ Engine     │ │ (Background)   │  │
│  └─────────┘ └────────────┘ └────────────────┘  │
│                                                  │
│  ┌──────────────┐  ┌───────────────────────────┐ │
│  │ SQLite Jobs  │  │ Prometheus Metrics        │ │
│  │ Persistence  │  │ (request_count, latency,  │ │
│  └──────────────┘  │  active_jobs, gpu_memory) │ │
│                    └───────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

**Key design decisions:**
- **OpenAI-compatible API**: Drop-in replacement for OpenAI client libraries
- **Bearer token auth**: Optional, controlled via `MODELOPT_REQUIRE_AUTH`
- **SQLite persistence**: Jobs survive service restarts
- **Structured JSON logging**: Production-ready observability

### 3. HippoCPP Graph Database (`hippocpp/`)

A multi-language port of the [Kuzu](https://kuzudb.com/) embedded graph database:

```
                    ┌─────────────────────────┐
                    │     Zig Core (1,251      │
                    │     source files)        │
                    │                          │
                    │  Parser ──▶ Planner      │
                    │              │           │
                    │         Optimizer        │
                    │              │           │
                    │         Processor        │
                    │              │           │
                    │  Storage ◀── Catalog     │
                    │     │                    │
                    │  Buffer Mgr  Transaction │
                    │  (WAL+MVCC)              │
                    └──────────┬──────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────▼──────┐ ┌──────▼───────┐ ┌──────▼───────┐
     │  Mojo GPU     │ │  Mangle      │ │  Python      │
     │  Acceleration │ │  Datalog     │ │  Bindings    │
     │               │ │              │ │              │
     │  SIMD pages   │ │  MVCC rules  │ │  native_zig  │
     │  Buffer pool  │ │  Page rules  │ │  parity test │
     │  Hash/HNSW    │ │  Schema inv. │ │              │
     │  Expression   │ │  Query opt.  │ │              │
     └───────────────┘ └──────────────┘ └──────────────┘
```

**Key design decisions:**
- **Zig 0.15.1**: Unmanaged `ArrayList`/`HashMap` patterns for explicit memory control
- **Mojo**: GPU-accelerated storage operations via SIMD intrinsics
- **Mangle**: Declarative invariant checking (schema integrity, MVCC correctness)
- **Parity CI**: Differential harness comparing Zig output against upstream Kuzu

## Technology Rationale

| Choice | Why |
|--------|-----|
| **Zig** | Zero-cost abstractions, comptime, no hidden allocations, C ABI compat |
| **Mojo** | Python syntax + GPU acceleration + SIMD, ideal for storage hot paths |
| **Mangle** | Datalog semantics for declarative invariants, easier to verify than code |
| **FastAPI** | Async Python, auto OpenAPI docs, Pydantic validation |
| **Angular 18** | Standalone components, strong typing, enterprise-grade framework |
| **SAP HANA SQL** | Target database for banking/financial workloads |
| **Spider/BIRD** | Standard Text-to-SQL benchmark format for model training |

