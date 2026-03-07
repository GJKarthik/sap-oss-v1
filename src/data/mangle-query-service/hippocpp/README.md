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

Current native Zig smoke coverage includes:

- `CREATE NODE TABLE ...` and `CREATE REL TABLE ...` (including case-insensitive DDL tokens/types such as `primary key`, `from`/`to`, `int64`)
- Node and relationship `CREATE` patterns
- Node primary-key constraint parity for `CREATE`/`SET` (`PRIMARY KEY` required on node create input, non-null PK, duplicate PK rejection, PK updates via `SET` rejected)
- `MATCH` node scans with projection (`DISTINCT` supported), `WHERE` (including case-insensitive `AND`/`OR`/`NOT`, `<>` inequality, case-insensitive `IS NULL`/`IS NOT NULL`, boolean literals (`true`/`false`), constant comparisons, and comparison operators on either side including property-to-property predicates; `!=` follows current Kuzu parser-error semantics), `COUNT(*)`, `COUNT(expr)`, and `COUNT(DISTINCT expr)` (including grouped forms with count term in any projection position, plus mixed aggregate+scalar projections such as `COUNT(*) AS c, $p`), multi-key `ORDER BY` (`ASC`/`DESC`), and `SKIP`/`LIMIT`
- `MATCH ... SET ...` node updates (including rhs property references), with optional `RETURN` (`DISTINCT` supported), `COUNT(*)`/`COUNT(expr)`/`COUNT(DISTINCT expr)` including grouped forms and count term in any projection position (including mixed aggregate+scalar projections), `ORDER BY`, and `SKIP`/`LIMIT`
- `MATCH` relationship scans with projection (`DISTINCT` supported), `WHERE` (including `AND`/`OR`/`NOT`, `<>` inequality, `IS NULL`/`IS NOT NULL`, constant comparisons, and comparison operators on either side including property-to-property predicates; `!=` follows current Kuzu parser-error semantics), `COUNT(*)`, `COUNT(expr)`, and `COUNT(DISTINCT expr)` (including grouped forms with count term in any projection position and mixed aggregate+scalar projections), multi-key `ORDER BY` (`ASC`/`DESC`), and `SKIP`/`LIMIT`
- `MATCH ...-[r:REL]->... SET ...` relationship updates (including rhs left/right/rel property references), with optional `RETURN` (`DISTINCT` supported), `COUNT(*)`/`COUNT(expr)`/`COUNT(DISTINCT expr)` including grouped forms and count term in any projection position (including mixed aggregate+scalar projections), `ORDER BY`, and `SKIP`/`LIMIT`
- `MATCH ... DELETE ...` deletes for relationships and nodes, including `DETACH DELETE` for nodes
- `MATCH ... CREATE ...` relationship creation with variable-bound node references and `WHERE` filtering
- `RETURN ... AS alias` for property projections in node/relationship `MATCH` and `SET ... RETURN` (including grouped relationship returns)
- `ORDER BY` on projected aliases for node/relationship `MATCH` and `SET ... RETURN`, including grouped relationship outputs
- Top-level `RETURN` literal/parameter expressions with optional aliases, `DISTINCT`, multi-term projection, output `ORDER BY`, and `SKIP`/`LIMIT`, including `BOOL` literals/params and `COUNT` aggregates (e.g., `RETURN 42`, `RETURN $x`, `RETURN true`, `RETURN DISTINCT 1, 'x'`, `RETURN 1 AS a, 2 AS b ORDER BY b DESC`, `RETURN COUNT(*) AS c, 1 AS one`; `COUNT` on `NULL`/`ANY` follows kuzu binder-error semantics; unresolved params default to `NULL` with kuzu-style aliasing such as `$_0_` when the passed parameter map is absent/empty; `COUNT($missing)` follows current kuzu behavior and resolves as a null scalar projection when aliased; pagination clause order matches Kuzu parser behavior across `RETURN` and `MATCH ... RETURN`, including `LIMIT` before `SKIP` parse errors)
- Parameterized `IS NULL` / `IS NOT NULL` predicates aligned with current Kuzu semantics
- Parameterized constant `WHERE` comparison semantics aligned with current Kuzu behavior, including `NOT` and parenthesized `NOT` forms (for example: `$p = 1`, `NOT $p = 1`, `NOT ($p = 1)`), plus bare-parameter predicate typing parity (`WHERE $p` expects `BOOL`; non-`BOOL` parameter types follow Kuzu binder error semantics; unresolved params in the passed parameter map behave as `NULL`)
- Parameter map validation aligned with current Kuzu semantics: extra/unreferenced parameters raise binder-style errors (for example, passing `{\"x\":1}` to `RETURN 1` yields `Parameter x not found.`)
- Projection alias syntax enforces explicit `AS` and returns Kuzu-style parser errors for invalid forms such as `RETURN 1 one` or `RETURN u.id x`
- Top-level `RETURN COUNT(DISTINCT *)` parser errors now align with current Kuzu wording/rule context (`oC_RegularQuery`)
- Pagination edge-case errors align with Kuzu semantics for duplicate `SKIP`/`LIMIT` clauses, non-integer pagination expressions (`Variable ... is not in scope`), and negative values (non-negative runtime error)
- Explicit `GROUP BY` clause syntax currently mirrors Kuzu parser behavior for this migration scope (Kuzu-style parser errors on `... GROUP BY ...` forms instead of accepting/binding them)
- `ORDER BY` unknown-identifier error semantics align with Kuzu binder errors (`Variable ... is not in scope`) for top-level, node/relationship, and grouped outputs
- Missing-property binder semantics align with Kuzu for node/relationship `RETURN`/`WHERE`/`SET`/`ORDER BY` (`Cannot find property ... for ...`) and top-level alias property access now emits Kuzu-style type binder errors (for example `a has data type INT64 but (NODE,REL,STRUCT,ANY) was expected`)
- Grouped output `ORDER BY` compatibility includes constant/literal terms used by Kuzu in aggregate queries (for example `ORDER BY 1`, `ORDER BY 1,2`, `ORDER BY 2 DESC`) without binder errors
- Node/relationship projection `ORDER BY` compatibility accepts constant/literal terms as Kuzu no-op keys (for example `MATCH (u:User) RETURN u.id ORDER BY 1` and `MATCH (a)-[r]->(b) RETURN a.id, b.id ORDER BY 2 DESC`) without binder errors

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
