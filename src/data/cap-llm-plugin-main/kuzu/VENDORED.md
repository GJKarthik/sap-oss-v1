# Vendored: KùzuDB Source Tree

## What is this directory?

This directory contains a **vendored copy** of the [KùzuDB](https://github.com/kuzudb/kuzu)
embedded graph database source tree.  It is used by `cap-llm-plugin` for:

| Consumer | Purpose |
|----------|---------|
| `mcp-server/src/kuzu-store.ts` | TypeScript graph-RAG store (component co-usage, RAG context enrichment) |
| `kuzu/mojo/kuzu_ffi.mojo` | Mojo FFI wrapper for high-performance Cypher queries from streaming pipelines |

## Version

The vendored tree corresponds to **KùzuDB 0.11.3** (the final bundled-extensions release
before the project was archived; see the upstream [README](./README.md)).

> [!NOTE]
> The upstream project has been archived at https://github.com/kuzudb/kuzu.
> No further releases are expected.  Security patches must be applied manually.

## Why vendored instead of a package dependency?

1. **Mojo FFI** — the `kuzu/mojo/kuzu_ffi.mojo` bindings require access to the C headers
   inside `src/include/`.  The npm package (`kuzu`) does not ship these headers.
2. **Build reproducibility** — the WASM/native addon shipped by the npm package is
   pre-built for specific Node.js ABI versions.  Vendoring the source allows building
   against the exact Node.js ABI used in the production container.
3. **Extension availability** — 0.11.3 bundles the `vector`, `fts`, `algo` extensions
   inline; older npm releases require a remote extension server.

## How to upgrade

```bash
# 1. Remove the current vendored tree
rm -rf kuzu/

# 2. Clone the desired tag
git clone --depth 1 --branch v<NEW_VERSION> https://github.com/kuzudb/kuzu kuzu/

# 3. Remove the upstream .git directory to avoid submodule confusion
rm -rf kuzu/.git

# 4. Update the version recorded in this file (above)

# 5. Re-run the Mojo FFI build (see Dockerfile MOJO_VERSION build-arg)
```

## How to remove

If the graph-RAG features are no longer needed:

1. Delete this directory: `rm -rf kuzu/`
2. Remove `mcp-server/src/kuzu-store.ts` and its test.
3. Remove the `kuzu_index` / `kuzu_query` tools from `mcp-server/src/server.ts`.
4. Remove the `kuzu` entry from `mcp-server/package.json` dependencies.
5. Remove `kuzu_index` and `kuzu_query` from the agent's `agent_can_use` set in
   `agent/cap_llm_agent.py`.

## Security considerations

- KùzuDB is an **embedded** database; it does not expose a network port.
- Cypher queries in `kuzu-store.ts` use parameterised calls where possible.
  Any dynamic query construction must be audited for injection risk.
- The vendored C++ source is not compiled at runtime; only the pre-built
  `mcp-server/node_modules/kuzu/kuzujs.node` native addon is loaded.
- Monitor the [KùzuDB advisory page](https://github.com/kuzudb/kuzu/security/advisories)
  for CVEs and apply patches manually since no automated updates will arrive.
