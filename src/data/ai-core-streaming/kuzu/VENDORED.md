# Vendored: KùzuDB Source Tree

## What is this directory?

This directory contains a **vendored copy** of the [KùzuDB](https://github.com/kuzudb/kuzu)
embedded graph database source tree.  It is used by `ai-core-streaming` for:

| Consumer | Purpose |
|----------|---------|
| `mcp_server/graph/kuzu_store.py` | Python graph-RAG store (deployment topology, stream-session context, routing decisions) |
| `kuzu/mojo/kuzu_ffi.mojo` | Mojo FFI wrapper for high-performance Cypher queries from the Zig streaming broker |

## Version

The vendored tree corresponds to **KùzuDB 0.11.3** (the final bundled-extensions release
before the project was archived; see the upstream [README](./README.md)).

> [!NOTE]
> The upstream project has been archived at https://github.com/kuzudb/kuzu.
> No further releases are expected.  Security patches must be applied manually.

## Why vendored instead of a package dependency?

1. **Mojo FFI** — the `kuzu/mojo/kuzu_ffi.mojo` bindings require access to the C headers
   inside `src/include/`.  The `pip install kuzu` package does not ship these headers.
2. **Zig cross-compilation** — the Zig broker (`zig/`) needs to link against KùzuDB's C
   API.  Vendoring the source tree provides deterministic build inputs for `zig build`.
3. **Extension availability** — 0.11.3 bundles the `vector`, `fts`, `algo` extensions
   inline; older pip releases require a remote extension server.

## How to upgrade

```bash
# 1. Remove the current vendored tree
rm -rf kuzu/

# 2. Clone the desired tag
git clone --depth 1 --branch v<NEW_VERSION> https://github.com/kuzudb/kuzu kuzu/

# 3. Remove the upstream .git directory to avoid submodule confusion
rm -rf kuzu/.git

# 4. Update the version recorded in this file (above)

# 5. Rebuild the Zig broker against the new headers
#    cd zig && zig build -Doptimize=ReleaseFast

# 6. Re-run the Mojo FFI build (see Dockerfile MOJO_VERSION build-arg)
```

## How to remove

If the graph-RAG features are no longer needed:

1. Delete this directory: `rm -rf kuzu/`
2. Remove `mcp_server/graph/kuzu_store.py` and its import in `mcp_server/server.py`.
3. Remove the `kuzu_index` / `kuzu_query` tools from `mcp_server/server.py`.
4. Remove `kuzu` from `requirements.txt` (if present).
5. Remove `kuzu_index` and `kuzu_query` from the agent's `agent_can_use` set in
   `agent/aicore_streaming_agent.py`.

## Security considerations

- KùzuDB is an **embedded** database; it does not expose a network port.
- The Python store uses parameterised Cypher queries where possible.
  Any dynamic query construction must be audited for injection risk.
- Monitor the [KùzuDB advisory page](https://github.com/kuzudb/kuzu/security/advisories)
  for CVEs and apply patches manually since no automated updates will arrive.
