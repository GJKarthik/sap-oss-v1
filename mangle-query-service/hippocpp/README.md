# HippoCPP - Graph Database Engine

A multi-language implementation of the Kuzu embedded graph database, converted from C++ to:
- **Zig** - High-performance systems implementation
- **Mojo** - GPU-accelerated operations with Python interoperability
- **Mangle** - Declarative Datalog representation for schema, rules, and invariants

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
├── mojo/                   # Mojo implementation
│   ├── src/
│   │   └── hippocpp/
│   └── tests/
├── mangle/                 # Datalog specifications
│   ├── standard/          # Core definitions
│   ├── storage/           # Storage semantics
│   ├── catalog/           # Catalog rules
│   └── transaction/       # MVCC rules
└── README.md
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

Optional backend knobs:

- `HIPPOCPP_SEMANTIC_BACKEND` (default: `hippocpp.native_zig`)
- `HIPPOCPP_ALLOW_KUZU_FALLBACK=1` to allow temporary fallback to `kuzu`
- `HIPPOCPP_ZIG_BIN` to override the Zig executable
- `HIPPOCPP_ZIG_ENGINE_SOURCE` to override the Zig engine source path

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
