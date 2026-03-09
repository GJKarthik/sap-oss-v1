# Technical Assessment: vllm-main (ai-core-privatellm)

**Repository path:** `src/intelligence/vllm-main`
**Assessment date:** 9 March 2026
**Assessed by:** Cascade (AI Code Assistant)

---

## 1. Overview

`vllm-main` implements a self-hosted LLM inference service marketed internally as **AI Core Private LLM**. Its primary purpose is to run quantised GGUF models entirely on-premise — without sending data to any external API — and expose them through an OpenAI-compatible HTTP interface on port 8080. A Prometheus metrics endpoint is exposed on port 9090.

The service is built in **pure Zig** (the inference gateway and all production HTTP paths) with supplementary high-performance kernels written in **Mojo MAX**. Deployment targets are SAP BTP AI Core (NVIDIA T4 GPU) and local Docker environments. Configuration and routing logic are expressed in **Mangle** rules, which are loaded at runtime into an embedded Mangle reasoning engine that also injects GPU telemetry as dynamic facts.

---

## 2. Repository Layout

The repository has three primary source trees. `zig/src/` contains the gateway — `main.zig` and `config.zig` at the root, then subdirectories for the inference pipeline (`llm/`), GPU backends (`gpu/`, 43 files), HTTP middleware (`http/`), the TOON parser and inference engine (`toon/`), the Engram speculative-draft engine (`dart/`), the embedded Mangle engine (`mangle/`), resilience primitives (`resilience/`), OpenAI wire types (`transport/`), SAP AI Core integration (`sap/`), and Apple Metal shader loading (`metal/`). `mojo/src/` contains the kernel library (~2,000 lines) organised into `simd/`, `kernel/`, `tokenizer/`, and `inference/` subdirectories. `mangle/` holds all Mangle rule files across five directories: `a2a/` for Agent-to-Agent protocol facts and rules, `domain/` for routing, batching, quantisation, T4 optimisation, AI Core deployment, model zoo, context, and DSPy module rules, `connectors/` for HANA vector, HuggingFace, object store, LLM gateway, and integration wiring, `standard/` for base predicate declarations, and `toon/` for TOON serialisation rules.

At the repository root, `Dockerfile` performs a two-stage build (a `zig-builder` stage followed by an `nvidia/cuda:12.4.0-runtime-ubuntu22.04` runtime stage). `docker-entrypoint.sh` handles model discovery and readiness checking at container startup. `aicore-serving-template.yaml` is the Kubernetes `ServingTemplate` used to register the service on SAP AI Core. `models/inventory.json` is a curated model registry. `docs/` contains `TOON_SPEC.md` and `TOONSPY.md`. `deploy/` holds the AI Core-specific Dockerfile, entrypoint, and serving template alongside a scaling guide. The `Makefile` covers build, test, model management, and AI Core deploy targets. `CHANGELOG.md` records versions from v2.0.0 through v2.2.0 and beyond.

---

## 3. Primary Purpose and Scope

The service addresses a single well-scoped problem: running open-weight LLMs locally in an enterprise environment where data residency requirements prohibit sending prompts to cloud LLM APIs. All inference is local and no prompt data leaves the container. The HTTP interface is OpenAI-compatible, making the service a drop-in replacement for `gpt-3.5-turbo` callers. It ships with a `ServingTemplate` and Mangle-generated deployment configuration for managed Kubernetes on SAP BTP AI Core. Models are distributed as quantised GGUF files stored in SAP Object Store and mounted as AI Core artifacts at container startup.

---

## 4. Core Architecture

The service is layered. At the top, OpenAI-compatible HTTP clients connect on port 8080 to the Zig HTTP gateway, which hosts the multi-threaded HTTP server, API-key auth, TLS termination, the embedded Mangle engine with runtime fact injection, and the token-bucket rate limiter and circuit breaker. Below the gateway sits the inference dispatch layer, which holds two parallel inference paths — the TOON inference engine (`llama_toon`) for GGUF models and the TRT engine (`mojo_bindings`, AWQ) for TensorRT — along with the batch scheduler and paged KV cache (`PagedKvCache` with 256-token blocks). At the bottom is the kernel and hardware layer, composed of the Mojo MAX kernel library (GEMM, attention, tokenizer, LayerNorm) and the GPU backends (CUDA via Zig LLVM's `nvptx64` PTX path, Apple Metal, and Apple Accelerate BLAS for CPU).

---

## 5. Zig Gateway (`zig/src/main.zig`)

`AppState` is the central server context, owning all subsystems with explicit lifetime management and no garbage collector. Startup proceeds in a fixed sequence. First, `gpu_context.GpuContext.init` probes available devices and falls back to CPU silently if none are found. Next, `PagedKvCache` is allocated with 1024 blocks of 256 tokens each, matching Mojo's `KV_BLOCK_SIZE` constant. The TOON inference engine is then initialised via `ToonInferenceEngine.forT4()`, loading the GGUF model from `GGUF_PATH`; if the path is absent, the engine is disabled gracefully. The Engram speculative-draft engine (`EngramDraftEngine`) is initialised next and, if `ENGRAM_CACHE_PATH` is set, its routing signal state is reloaded from a previous snapshot. The GGUF tokenizer is loaded from the same model file to inject real token IDs into Engram's context window. TLS configuration is read from the environment via `TlsConfig.fromEnv()` and validated; a failure here emits a warning but does not abort startup. The TRT engine is initialised once via `pllm_trt_init_engine` and its handle kept alive for the server lifetime. The Mangle engine is loaded with all `.mg` files, and the model's chat style and architecture are asserted as runtime facts. Finally, the HTTP server is constructed with a `requestHandler` closure over the completed `AppState`.

Key `ServerConfig` fields are all configurable from environment variables or the `Config` struct. `port` defaults to 8080. `trt_max_inflight` caps the TRT engine queue at 64 concurrent requests; `trt_quant_mode` selects AWQ (mode 2) by default. `rate_limit_rps` and `rate_limit_burst` both default to 1000. `toon_enabled` and `use_local_llama` default to `true`, enabling direct GGUF inference via the TOON engine and Engram speculative-draft system.

---

## 6. GGUF Support and Model Loading

`gguf_loader.zig` implements a native GGUF parser without any external C dependency. The `docker-entrypoint.sh` discovers models at container startup by first scanning `/mnt/models` (the AI Core artifact mount point) for `*.gguf` files, falling back to the `MODEL_PATH` environment variable (default `/app/models`) if none are found there. It sets `GGUF_PATH` to the discovered file before launching the Zig gateway, then polls the `/health` endpoint with up to ten three-second retries before declaring the service ready.

`models/inventory.json` catalogues embedding and LLM models with T4-specific configuration (`vram_gb`, `max_context`, `max_concurrent_requests`) for deployment planning.

---

## 7. Dual-Engine Inference (GGUF + TensorRT)

The gateway supports two inference backends selectable at runtime. The GGUF path is handled by `llama_toon.zig`, which loads the model directly using Zig's native GGUF parser. Quantisation (Q4\_K\_M, Q8\_0, or Q3\_K\_M) is negotiated by Mangle's `t4_optimization.mg` rules based on available VRAM. This path is integrated with the Paged KV cache and the Engram speculative-draft engine and is always available regardless of GPU type. The TensorRT path is handled by `mojo_bindings.zig` using a persistent engine handle initialised once at startup via `pllm_trt_init_engine`. It operates in AWQ quantisation mode (mode 2) with paged KV cache, and queue depth is read cheaply from the handle via `pllm_trt_get_inflight_count`. It requires a pre-built `.engine` file and falls back to the GGUF path if initialisation fails.

Engine selection is governed by Mangle's `model_routing.mg`. TensorRT is preferred when the hardware supports it and the live `gpu_queue_depth` fact is below `engine_queue_threshold` (48). Once the TRT queue is saturated, GGUF is selected as a dynamic overflow fallback. Hardware that has no TRT engine file — Apple M, Intel Xeon, or a T4 without a pre-built engine — routes directly to the GGUF path.

---

## 8. Mangle Reasoning Engine

All `.mg` files are loaded from four directories in dependency order: `standard/` → `a2a/` → `toon/` → `domain/`. Because the loader concatenates files into a single program before parsing, predicates from earlier directories are visible to later ones. The engine is queried inline during request handling; runtime facts are asserted before each Mangle query.

### 8.1 Domain rules summary

`a2a/facts.mg` declares the service registry, intent, request/response tracking, and fractal pointer predicates. `a2a/rules.mg` derives routing via `resolve_service_for_intent`, service health from response latency, model selection by specialisation, and prompt enhancement from keyword patterns.

`domain/model_routing.mg` holds model availability, speed and quality ratings, hardware node declarations, TRT/GGUF engine selection rules, and context-length routing. `domain/model_zoo.mg` is the HuggingFace model catalogue — approximately 90 models across 26 families — carrying VRAM footprints and T4 configuration facts. `domain/t4_optimization.mg` performs GPU capability detection, quantisation selection, KV-cache budget calculation, batch-size and context-length derivation, and throughput estimation from injected device facts. `domain/batching_rules.mg` covers continuous batching, SLA tiers (TTFT and generation latency per priority level), priority preemption, paged KV block budgets, speculative decoding pairing, and auto-scaling thresholds. `domain/aicore_deployment.mg` maps internal hardware profiles to AI Core resource plans, derives object store artifact paths and variant labels, derives scaling and context parameters from model size and VRAM, and exposes a single `aicore_deployment_config/3` query that returns a complete deployment record. `domain/context_rules.mg` manages prompt context limits; `domain/quantization_rules.mg` encodes selection constraints for each quantisation level. `domain/dspy_modules.mg` implements ToonSPy prompt generation: Predict, ChainOfThought, and ReAct templates that request TOON-formatted output and drive Mangle-based validation. `domain/aicore_schemas.mg` validates AI Core API responses. `domain/model_store_rules.mg` defines model definitions, GGUF variants, and hardware profile facts.

`toon/rules.mg` implements TOON serialisation and deserialisation, token count estimation, and a streaming parser state machine. `connectors/hana_vector.mg` declares the full HANA Cloud Vector Engine CRUD interface and the RAG document/chunk/query lifecycle. `connectors/integration.mg` provides service-level wiring, tying together the LLM gateway, object store, and HANA vector configuration into a single named service. `connectors/huggingface.mg` provides a HuggingFace model discovery connector; `connectors/object_store.mg` declares SAP Object Store access facts; `connectors/llm.mg` provides generic LLM gateway connector declarations. `standard/facts.mg` and `standard/rules.mg` supply base predicate declarations and fundamental type rules that all other modules build on.

### 8.2 Runtime fact injection

Before serving each chat completion request, `main.zig` asserts transient facts into the Mangle engine. `gpu_queue_depth(engine, depth)` carries the live queue depth and is consumed by the `engine_overloaded/2` predicate in `model_routing.mg`. `model_chat_style(style)` carries an integer enum of the loaded model's chat template (ChatML, Llama 3, Zephyr, Mistral, or generic). `model_loaded(name)` is asserted once at startup. This pattern cleanly separates static configuration expressed in Mangle files from live operational state maintained by the Zig runtime.

---

## 9. TOON Format

TOON (Token Oriented Object Notation) is a custom serialisation format defined in `docs/TOON_SPEC.md` and implemented in `zig/src/toon/`. It uses unquoted keys, `:` separators, and `|`-delimited arrays to reduce token count by 40–60% compared to JSON. A simple object that costs 15 JSON tokens costs 6 in TOON; a typical API response drops from 89 tokens to 24; a configuration object drops from 156 tokens to 38.

TOON is used in three ways within this repository. The TOON inference engine instructs the model to respond in TOON format, directly reducing output token spend. `dspy_modules.mg` generates Predict, ChainOfThought, and ReAct prompts that request TOON-formatted output, with Mangle rules validating the returned fields. `hana_vector.mg` also uses TOON pointer references — `vector_data` fields carry TOON pointer values — for cross-service data navigation within the A2A mesh.

---

## 10. ToonSPy (DSPy-over-TOON)

`docs/TOONSPY.md` and `mangle/domain/dspy_modules.mg` define **ToonSPy**, a declarative AI programming framework that layers DSPy-style signatures onto TOON output and Mangle schema validation. The Predict module is used for signatures with two or fewer output fields. ChainOfThought is selected for three to five output fields and prepends a `reasoning:…` TOON field before the main outputs. ReAct is activated when tools are registered and generates `thought`/`action`/`input` TOON loops for tool-using agents. Module type selection is itself a Mangle rule (`select_module_type/2`), so the choice of module can be adjusted by editing rules without any code changes.

---

## 11. Mojo Kernel Layer (`mojo/`)

The Mojo MAX SDK (≥ 25.1.0) provides approximately 2,000 lines of high-performance CPU/GPU kernels. The integration path with the Zig gateway is via FFI through `mojo_bridge.zig` and `mojo/bindings.zig`, where Mojo kernels are compiled to shared libraries. The SIMD layer auto-detects register width via `simdwidthof` and implements add, dot, normalisation, exp, tanh, and rsqrt. The core kernels cover GEMM in naive, SIMD, and parallel variants, numerically stable softmax, RMS LayerNorm, GeLU, and SiLU. The attention kernels implement scaled dot-product with causal masking, block-wise Flash Attention, Multi-Head Attention with projections, rotary positional embeddings (RoPE), and a KV cache for incremental decoding. The tokenizer implements BPE encoding and decoding in batch mode with greedy, temperature, top-p, and repetition-penalty sampling strategies. The inference module assembles these into a full transformer forward pass with KV caching. Documented speedups over the Python reference are approximately 100× for GEMM, 50× for softmax, 80× for attention, and 20× for tokenisation.

The Mojo README notes that the TRT engine path (`mojo_bindings.zig`) bridges Mojo to TensorRT and is called from `main.zig` for the AWQ engine variant. The Rust backend referenced in `zig/README.md` appears to be an earlier iteration superseded by the pure-Zig inference path.

---

## 12. GPU Backend

`zig/src/gpu/` (43 files) implements GPU execution across three backends. For CUDA, kernels are compiled to PTX via Zig's LLVM `nvptx64` backend during `zig build`; no `nvcc` or CUDA toolkit is required at build time, and the PTX is JIT-compiled by the CUDA driver at first use. The Apple Metal path is implemented in `zig/src/metal/`; Metal shader loading was stabilised in v2.2.0. Apple Accelerate BLAS was also integrated in v2.2.0 to handle CPU matrix operations on macOS without requiring a GPU.

The `Dockerfile` uses a two-stage build: a `zig-builder` stage (compiles PTX) and a `runtime` stage based on `nvidia/cuda:12.4.0-runtime-ubuntu22.04`. The runtime image carries no compiler toolchain; PTX JIT occurs at container startup.

---

## 13. SAP AI Core Deployment

`aicore-serving-template.yaml` registers the service as a `ServingTemplate` on AI Core. It requests the `infer.s` resource plan (1 GPU, 8Gi memory, 4 CPU), references the Docker image `docker.io/gjkarthik/ai-core-privatellm:v1.0-tinyllama`, and mounts the `tinyllamamodel` artifact at `/mnt/models`. Environment variables `MODEL_PATH`, `VLLM_PORT` (8080), and `VLLM_METRICS_PORT` (9090) are set in the container spec.

`mangle/domain/aicore_deployment.mg` derives deployment configuration programmatically: it maps internal hardware profiles to AI Core resource plans, derives object store artifact paths, scaling parameters (min/max replicas), context window sizes, and parallel request limits from model size and VRAM facts. A single Mangle query `aicore_deployment_config(RepoId, HardwareProfile, Config)` returns a complete deployment record. Deployment configs should be generated via `./scripts/generate_aicore_config.sh` rather than hand-edited.

The SAP Object Store bucket `hcp-055af4b0-2344-40d2-88fe-ddc1c4aad6c5` and prefix `ai://default/llm-models/` are hardcoded in `aicore_deployment.mg`.

---

## 14. Resilience and Middleware

The circuit breaker in `zig/src/resilience/circuit_breaker.zig` wraps LLM backend calls under the named instance `"llm-backend"`. The token-bucket rate limiter in `zig/src/http/rate_limiter.zig` enforces the `rate_limit_rps` and `rate_limit_burst` values from `ServerConfig`. TLS support in `zig/src/http/tls.zig` is optional: the configuration is validated at startup and the server continues without it if invalid, emitting a warning. API-key authentication is implemented in `zig/src/http/auth.zig`. Prometheus metrics are exposed on port 9090 via `zig/src/http/metrics.zig`. Distributed tracing is provided by `zig/src/http/otel.zig`. An alternate gRPC interface is available in `zig/src/http/grpc_server.zig`, and Meta Llama Stack protocol compatibility is implemented in `zig/src/http/llama_stack.zig`. Graceful shutdown in `zig/src/resilience/graceful_shutdown.zig` drains in-flight requests before the process exits.

---

## 15. Model Zoo and Inventory

`mangle/domain/model_zoo.mg` catalogues ~90 GGUF models across 26 families (Llama, Mistral, Phi, Qwen, Gemma, DeepSeek, Yi, ChatGLM, InternLM, Command R, StarCoder, Falcon, DBRX, Baichuan, Jamba, OLMo, Nemotron, Granite, SOLAR, MiniCPM, RWKV, MPT, Arctic, Qwen3.5). Each entry includes: HuggingFace repo ID, parameter count, recommended T4 quantisation, GGUF filename, and a human-readable description.

The Qwen3.5 family receives dedicated T4 tuning facts in both `model_zoo.mg` and `model_routing.mg`. The 0.8B variant is served at Q8\_0 quantisation (~0.9 GB VRAM), supports up to 32768 context tokens, and can handle 80 concurrent requests on a T4. The 9B variant is served at Q4\_K\_M (~5 GB VRAM) with an 8192-token context limit and 14 concurrent requests. The 35B variant requires Q3\_K\_M (~13 GB VRAM) and is limited to a 2048-token context with 3 concurrent requests.

---

## 16. Configuration Reference

All runtime behaviour is controlled by environment variables. `HOST` (default `0.0.0.0`) and `PORT` / `VLLM_PORT` (default `8080`) set the HTTP bind address and port. `VLLM_METRICS_PORT` (default `9090`) controls the Prometheus endpoint. `GGUF_PATH` is auto-detected by the entrypoint script from mounted artifacts; `MODEL_PATH` (default `/app/models`) sets the fallback model directory. `BACKEND_URL` (default `http://localhost:3000`) is a legacy environment variable pointing to the now-superseded Rust backend proxy. `API_KEY` is optional; when set it enables API-key authentication on the gateway. `MANGLE_RULES_PATH` overrides the default Mangle rule directory. `TRT_ENGINE_PATH` points to a pre-built TensorRT `.engine` file; if absent, only the GGUF path is active. `TRT_MAX_INFLIGHT` (default `64`) caps the TRT engine queue depth. `RATE_LIMIT_RPS` and `RATE_LIMIT_BURST` (both default `1000`) configure the token-bucket rate limiter. `ENGRAM_CACHE_PATH` enables Engram snapshot persistence across restarts. `STREAMING_ENABLED`, `TOON_ENABLED`, and `USE_LOCAL_LLAMA` all default to `true`. `LOG_LEVEL` defaults to `info`.

---

## 17. Known Bugs Fixed in Codebase History

`main.zig` and `batching_rules.mg` contain inline `Bug N fix:` annotations documenting resolved issues. Bug 1 was the TRT engine being re-initialised on every request; it is now initialised once at startup in `AppState.init` and the persistent handle is reused. Bug 3 was the server mutex being held across slow inference I/O, causing head-of-line blocking for all concurrent requests; the mutex now guards only the scheduler and Engram state. Bug 5 was `next_request_id` being seeded from `nanoTimestamp()`, which caused surprising wrap behaviour; the counter now starts at 1. Bug 7 was `model_memory_working` using an anonymous `DeviceID` parameter (`_`), meaning quantisation was resolved against any device's facts rather than the target device; `DeviceID` was made an explicit parameter throughout the `t4_optimization.mg` rules. Bug 8 was a block-size mismatch: Zig's `PagedKvCache` used `block_size=16` while Mojo's `PagedKVCache.KV_BLOCK_SIZE` is 256, silently corrupting the KV cache; the Zig value was corrected to 256. Bug 10 was the rate limiter being hardcoded at 100 RPS with no override; limits are now read from `ServerConfig` and the environment.

---

## 18. Evaluation of Software (9 March, 2026)

For SAP engineering evaluation, the following items require resolution before production readiness:

(1) **Object store bucket hardcoded in Mangle rule.** `mangle/domain/aicore_deployment.mg` hardcodes the SAP Object Store bucket identifier (`hcp-055af4b0-2344-40d2-88fe-ddc1c4aad6c5`) and the object prefix `ai://default/llm-models/` as ground facts. If the bucket is rotated, renamed, or the service is deployed to a different AI Core tenant or region, this value must be manually edited in the Mangle source. The bucket identifier and prefix should be injected at runtime as Mangle facts from environment variables (for example, `AICORE_OBJECT_STORE_BUCKET` and `AICORE_OBJECT_STORE_PREFIX`) and asserted by the Zig gateway at startup, consistent with how GPU device facts are already injected in `main.zig`.

(2) **`API_KEY` authentication does not cover the metrics port.** `zig/src/http/auth.zig` guards the OpenAI-compatible gateway on port 8080 with an optional API key. The Prometheus metrics endpoint on port 9090 (`zig/src/http/metrics.zig`) is exposed separately and carries no equivalent authentication. On AI Core, the 9090 port is accessible to the managed monitoring stack, but in Docker Swarm and local development deployments the port is published to the host network without restriction. Metrics responses can expose model names, queue depths, throughput figures, and error rates — information useful for fingerprinting the service. Port 9090 should either require the same API key, be bound to `127.0.0.1` in non-AI Core deployments, or be placed behind a network policy that restricts access to the monitoring collector.

(3) **`aicore-serving-template.yaml` references a public Docker Hub image.** The serving template points to `docker.io/gjkarthik/ai-core-privatellm:v1.0-tinyllama` — a personal Docker Hub account. In an enterprise AI Core deployment this image should be pulled from a trusted, access-controlled registry (SAP Container Registry or a BTP-connected private registry) to prevent supply chain substitution, enforce image signing, and guarantee SLA alignment. The image tag `v1.0-tinyllama` is also insufficiently specific for reproducible deployments; a digest-pinned reference should be used in the production serving template.

(4) **TRT engine path acceptance without integrity check.** `main.zig` passes `TRT_ENGINE_PATH` directly to `pllm_trt_init_engine` without verifying a checksum or signature of the engine file. A TensorRT `.engine` file is a compiled binary artefact specific to the target GPU architecture; substituting a maliciously crafted engine file could achieve arbitrary code execution within the container. At minimum, the expected SHA-256 digest of each engine file should be stored alongside the model artifact in the object store and verified before loading.

(5) **Engram speculative-draft snapshot is not integrity-protected.** The `EngramDraftEngine` persists routing signal state to `ENGRAM_CACHE_PATH` and reloads it at startup. The file format and any integrity mechanism are not evident from the source; if the snapshot path is a writable host-mounted volume, a local attacker could corrupt routing signals to degrade inference quality or bias model selection. The snapshot should be loaded from a read-only volume in production, or a HMAC over the file contents should be verified on load.

(6) **Mojo README describes FFI to a Rust backend that no longer exists.** `mojo/README.md` documents the Mojo kernels as being "called via FFI from the Rust backend" and includes a Rust `extern "C"` example. The Rust backend described in `zig/README.md` (port 3000, Axum + llama.cpp) appears to be an earlier architecture superseded by the pure-Zig inference path in v2.0.0. The `BACKEND_URL` environment variable (`http://localhost:3000`) and the `backend` field in `AppState` retain this legacy wiring. The stale documentation and dead code path create confusion about the active inference stack, may cause operators to provision an unnecessary sidecar, and expand the attack surface through an unused listening service. The Rust backend, its documentation references, and the `llm_backend.Client` proxy path should either be formally deprecated with a migration note or removed.
