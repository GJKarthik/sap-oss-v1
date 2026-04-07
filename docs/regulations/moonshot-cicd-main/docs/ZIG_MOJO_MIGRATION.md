# Moonshot Zig/Mojo Migration

This document tracks the migration of `moonshot-cicd-main` from Python to Zig + Mojo with parity guarantees.

## Current Runtime Model

- `zig/src/main.zig` is the primary runtime entrypoint.
- `moonshot run <run_id> <test_config_id> <connector>` executes natively in Zig.
- Legacy Python CLI bridge forwarding has been removed from the Zig runtime.
- `mojo/src/ffi_exports.mojo` contains deterministic primitives that can be called from Zig over time.

## Layout

- `zig/`: service runtime, typed domain/config model.
- `mojo/`: FFI-compatible utility primitives and smoke tests.
- `mangle/`: migration metadata and parity rule stubs.
- `scripts/`: migration helpers.

## Commands

Build and test Zig:

```bash
cd zig
zig build
zig build test
```

Show parsed config summary via Zig domain model:

```bash
cd zig
zig build run -- zig-config
```

Run Mojo smoke tests:

```bash
mojo run mojo/tests/smoke.mojo
```

## New Connectors Added

- `ai_core_adapter`
  - Runtime path (today): Python adapter in `src/adapters/connector/ai_core_adapter.py`
  - Zig parity path: request shaping + response parsing in `zig/src/adapters/connector.zig`
  - Auth env vars: `AICORE_AUTH_TOKEN` (preferred), fallback `AICORE_API_KEY`, then `OPENAI_API_KEY`
- `private_llm_adapter`
  - Runtime path (today): Python adapter in `src/adapters/connector/private_llm_adapter.py`
  - Zig parity path: request shaping + response parsing in `zig/src/adapters/connector.zig`
  - Auth env vars: `PRIVATE_LLM_API_KEY` (preferred), fallback `OPENAI_API_KEY`

## Parity Tracker

| Module Area | Status | Runtime Path |
|---|---|---|
| CLI entrypoint (`moonshot run`) | Ported | Zig |
| App metadata loading | Ported | Zig |
| App config model (`common`, connector/metric/module names) | Ported | Zig |
| File format adapters (`json`, `yaml`) | Ported (phase 2) | Zig |
| Local storage adapter core behavior | Ported (phase 2) | Zig |
| S3 adapter path parsing/support checks | Ported (phase 2) | Zig |
| Connector adapters (request shaping/validation/response parsing) | Ported (phase 3 core) | Zig |
| Connector transport (OpenAI/Anthropic/AI Core/Private LLM) | Ported (phase 3.1) | Zig |
| Connector transport (AWS Bedrock/SageMaker SigV4 signing flow) | Ported (phase 3.2) | Zig |
| AppConfig service parity (`get_*_config`, test config path, connector/metric/attack validation branches) | Ported (phase 4) | Zig |
| Task manager orchestration internals (`runTest`, config loading/dispatch) | Ported (phase 4.1) | Zig |
| Scan execution path (`type: scan`) | Ported | Zig |
| Metric adapters | Pending | Python |
| Process-check web app | Ported | Angular/UI5 static app |
| Mojo utility primitives | Ported (initial) | Mojo |

## Next Porting Order

1. Adapter-by-adapter port for metric/prompt-processor.
2. Remove remaining Python dependencies in config loading path.
