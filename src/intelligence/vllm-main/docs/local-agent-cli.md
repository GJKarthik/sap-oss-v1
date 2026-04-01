# Local Agent CLI

This document records the safe reuse boundary for `claw-code` ideas and the
minimal local CLI shape for `vllm-main`.

## Why this exists

`vllm-main` already has the important server surface:

- `POST /v1/chat/completions`
- `POST /v1/embeddings`
- `GET /v1/models`
- `GET /health`
- `GET /ready`
- `GET /metrics`

The right next layer is not another runtime. It is a thin client that speaks to
the existing OpenAI-compatible gateway.

## `claw-code` Audit

Audit date: April 1, 2026.

What the current public main branch appears to be:

- A Python-first clean-room rewrite / porting workspace
- A small `src/` tree centered on `commands.py`, `main.py`, `models.py`,
  `port_manifest.py`, `query_engine.py`, `task.py`, and `tools.py`
- Documentation focused on harness engineering and porting workflow, not model
  inference

Public sources checked:

- <https://github.com/instructkr/claw-code>
- <https://raw.githubusercontent.com/instructkr/claw-code/main/README.md>

Licensing status from the public main branch:

- `LICENSE` was not present at `main/LICENSE`
- `LICENSE.md` was not present at `main/LICENSE.md`
- `COPYING` was not present at `main/COPYING`

Because of that, treat the repository as **reference-only for architecture
ideas** unless a clear license is published.

## Safe Reuse Map

Safe to reuse as ideas only:

- CLI subcommand layout
- Session/transcript persistence shape
- Separation between command parsing, task state, and tool registry
- SSE / streaming response handling patterns
- Lightweight local workflow ergonomics

Do not copy directly:

- Source code
- Ported command/tool implementations
- Any code or artifacts whose licensing remains unclear

Not relevant to current runtime bottlenecks:

- Anything in `claw-code` related to harness UX or orchestration
- It does not help GGUF loading, Metal kernels, KV cache, or quantized decode

## Minimal CLI Design For `vllm-main`

Implementation artifact:

- [local_agent_cli.py](/Users/user/Documents/sap-oss/src/intelligence/vllm-main/scripts/local_agent_cli.py)

Design goals:

- No new inference runtime
- No extra Python dependencies
- Speak directly to the existing gateway
- Preserve small-session local usage
- Support both one-shot and REPL workflows

Current command surface:

- `health`: `GET /health`
- `models`: `GET /v1/models`
- `metrics`: `GET /metrics`
- `embed`: `POST /v1/embeddings`
- `chat`: one-shot `POST /v1/chat/completions`
- `repl`: session-backed interactive chat loop

Session behavior:

- Stored under `.agent_sessions/`
- Default session name: `default`
- `--ephemeral` skips session reads/writes
- `--reset` clears the session before the request

Streaming behavior:

- Uses SSE against `POST /v1/chat/completions`
- Extracts `choices[].delta.content`
- Falls back to non-stream JSON parsing when streaming is disabled

Environment variables:

- `PRIVATE_LLM_BASE_URL`
- `PRIVATE_LLM_MODEL`
- `PRIVATE_LLM_API_KEY`
- `PRIVATE_LLM_SESSION`

## Why this is the right size

This gives the repo a usable local operator shell without dragging the server
toward agent-framework complexity. It also keeps the reuse boundary clean:

- inference and transport stay in `zig/`
- the CLI stays a thin wrapper in `scripts/`
- `claw-code` remains an architectural reference, not a dependency

## Next Useful CLI Steps

If this script becomes part of normal workflow, the next additions should be:

1. `ready` command for `GET /ready`
2. structured JSON output mode for all commands
3. tool-call display once the gateway emits tool-call responses
4. transcript trimming / token-budget controls
5. a small shell wrapper or Make target for common local startup + REPL flow
