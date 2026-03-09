# HippoCPP - Graph Database Engine

A multi-language implementation of the [Kuzu](https://kuzudb.com/) embedded graph database, converted from C++ to:
- **Zig** — High-performance systems implementation (1,251 source files, 100% path coverage)
- **Mojo** — GPU-accelerated storage, SIMD page operations, buffer pool management
- **Mangle** — Declarative Datalog rules for MVCC invariants, schema validation, query optimization

## Architecture

```
                    ┌─────────────────────────────┐
                    │        Query Input           │
                    │   (Cypher / Parameters)       │
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │          Parser               │
                    │   (Lexer → AST → Binder)      │
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │          Planner              │
                    │   (Logical → Physical Plan)   │
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │         Optimizer             │
                    │   (Join ordering, Pushdown)   │
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │         Processor             │
                    │   (Execution Engine)           │
                    └──────────────┬───────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
     ┌────────▼──────┐   ┌────────▼──────┐   ┌────────▼──────┐
     │   Catalog     │   │   Storage     │   │  Transaction  │
     │  (Schema,     │   │  (Pages,      │   │  (WAL, MVCC,  │
     │   Tables,     │   │   Columns,    │   │   Checkpoint,  │
     │   Indexes)    │   │   Buffer Mgr) │   │   Rollback)    │
     └───────────────┘   └───────────────┘   └────────────────┘
```

## Project Structure

```
hippocpp/
├── zig/                    # Zig native implementation
│   ├── build.zig          # Zig build system
│   ├── build.zig.zon      # Package dependencies
│   └── src/               # Source code
│       ├── main.zig
│       ├── storage/       # Storage engine
│       ├── buffer_manager/
│       ├── catalog/
│       ├── parser/
│       ├── planner/
│       ├── processor/
│       └── transaction/
├── mojo/                   # Mojo GPU-accelerated implementation
│   ├── mojoproject.toml   # Project config
│   ├── Makefile           # Build/test targets
│   ├── src/hippocpp/      # Package: storage, buffer_manager, table, index
│   ├── catalog.🔥         # Catalog metadata management
│   ├── common.🔥          # Core types (LogicalType, Value, InternalID)
│   ├── expression.🔥      # Expression trees & evaluator
│   ├── graph.🔥           # Graph model & pattern matching
│   └── tests/             # test_storage, test_catalog, test_expression, test_graph
├── mangle/                 # Datalog specifications
│   ├── standard/          # Core definitions (facts, rules, functions, aggregations)
│   ├── storage/           # Page management rules & WAL invariants
│   ├── catalog/           # Schema validation & referential integrity
│   ├── query/             # Query optimization rules
│   ├── transaction/       # MVCC visibility & conflict detection
│   └── tests/             # Rule validation harness
├── python/                 # Python bindings
├── parity/                 # Differential test corpus
└── PARITY-MATRIX.md       # Conversion tracking (735 modules)
```

## Building

### Zig

```bash
cd zig
zig build
zig build test
```

### Mojo

```bash
cd mojo
mojo build src/hippocpp
mojo test tests/
```

## Architecture

HippoCPP implements a complete graph database with:

- **Columnar Storage**: Efficient column-based storage for node and relationship properties
- **MVCC**: Multi-version concurrency control for transaction isolation
- **WAL**: Write-ahead logging for durability and crash recovery
- **Buffer Manager**: Page-based memory management with eviction policies
- **HNSW Index**: Approximate nearest neighbor search for vector similarity
- **Cypher Parser**: Full Cypher query language support

## Parity Workflow

HippoCPP tracks Kuzu in two ways:

1. **Zig/Mojo/Mangle conversion** in this directory.
2. **Upstream mirror parity** at `upstream/kuzu` for exact source fallback.

Use these scripts:

```bash
# Sync exact upstream mirror from ../kuzu into hippocpp/upstream/kuzu
./scripts/sync_from_kuzu.sh

# Recompute the parity matrix report
./scripts/parity_check.sh

# Run parity threshold gates (CI entrypoint)
./scripts/ci_parity_gate.sh
```

Generated artifacts:

- `PARITY-MATRIX.md`: human-readable matrix
- `PARITY-SUMMARY.json`: machine-readable metrics for CI
- `PARITY-DIFF.json`: differential output (when differential commands are configured)

### Differential Harness

The differential harness compares two backend commands over the same corpus.

Command template placeholders:

- `{corpus}`: shell-escaped path to a corpus file
- `{tmpdir}`: shell-escaped temporary directory

Example (when `kuzu` Python package is installed):

```bash
./scripts/ci_parity_gate.sh
```

Default command wrappers used by `ci_parity_gate.sh`:

- Left: `scripts/run_backend_kuzu.sh`
- Right: `scripts/run_backend_hippocpp.sh`

Both wrappers now default to isolated temporary DB roots per invocation
(auto-cleaned on exit) to avoid cross-run file collisions. Set `DB_ROOT`
explicitly if you want persistent database files for debugging.

Quick local setup:

```bash
./scripts/setup_parity_env.sh
source .parity-venv/bin/activate
./scripts/ci_parity_gate.sh
```

`run_backend_hippocpp.sh` supports:

- `HIPPOCPP_BACKEND_MODE=auto` (default; prefers native module, falls back to upstream)
- `HIPPOCPP_BACKEND_MODE=upstream-kuzu` (operational parity fallback)
- `HIPPOCPP_BACKEND_MODE=native-python` (switch once HippoCPP Python module exists; set `HIPPOCPP_PY_MODULE`)

HippoCPP now ships an in-repo Python module at `python/hippocpp` and
`run_backend_hippocpp.sh` automatically injects it into `PYTHONPATH`.
CI parity defaults to `HIPPOCPP_BACKEND_MODE=native-python`.

By default, `python/hippocpp` uses the native Zig execution backend
`hippocpp.native_zig` (implemented via `zig/src/native/mini_engine.zig`).

Current native Zig smoke coverage (see [PARITY-MATRIX.md](PARITY-MATRIX.md) for full details):

| Category | Coverage |
|----------|----------|
| **DDL** | `CREATE NODE TABLE`, `CREATE REL TABLE` (case-insensitive tokens/types) |
| **DML — Create** | Node and relationship `CREATE` with PK constraints |
| **DML — Read** | `MATCH` with `WHERE`, `DISTINCT`, `COUNT(*)`, `COUNT(expr)`, `COUNT(DISTINCT expr)`, `ORDER BY`, `SKIP`/`LIMIT`, property projections, aliases |
| **DML — Update** | `MATCH ... SET` for nodes and relationships with `RETURN`, aggregates, pagination |
| **DML — Delete** | `MATCH ... DELETE`, `DETACH DELETE` for nodes |
| **Expressions** | Comparisons (`=`, `<>`, `<`, `>`, `<=`, `>=`), `IS NULL`/`IS NOT NULL`, `AND`/`OR`/`NOT`, boolean/string/int literals, parameters |
| **Top-level RETURN** | Literals, parameters, `DISTINCT`, multi-term, `ORDER BY`, `SKIP`/`LIMIT`, `COUNT` aggregates |
| **Error parity** | Parser errors, binder errors, missing-property errors, pagination edge cases — all aligned with upstream Kuzu semantics |

Optional backend knobs:

- `HIPPOCPP_SEMANTIC_BACKEND` (default: `hippocpp.native_zig`)
- `HIPPOCPP_ALLOW_KUZU_FALLBACK=1` to allow temporary fallback to `kuzu`
- `HIPPOCPP_ZIG_BIN` to override the Zig executable
- `HIPPOCPP_ZIG_ENGINE_SOURCE` to override the Zig engine source path
- `DB_ROOT` to force a persistent DB directory (otherwise wrapper scripts use ephemeral temp dirs)

To override command templates explicitly:

```bash
export HIPPOCPP_DIFF_LEFT_CMD="bash scripts/run_backend_kuzu.sh {corpus}"
export HIPPOCPP_DIFF_RIGHT_CMD="bash scripts/run_backend_hippocpp.sh {corpus}"
./scripts/ci_parity_gate.sh
```

Corpus and baseline files live under `parity/`:

- `parity/corpus/smoke.json`
- `parity/baseline.json`

## License

Apache-2.0
