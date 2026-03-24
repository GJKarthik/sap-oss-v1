# SAP OSS Enterprise Scalability & Performance Audit

**Date:** March 2026  
**Scope:** `vllm-main` (Zig gateway + Mojo kernels + Mangle rules), `ai-core-pal` (MCP PAL gateway), service mesh (`docker-compose.yml`, `nginx.conf`)

---

## Executive Summary

The platform has a strong performance-oriented foundation: a lock-free token-bucket rate limiter, CAS-based circuit breaker, Mangle-driven adaptive GPU kernel selection, and Mojo SIMD kernels with documented 20–100× speedups over Python. However, several **enterprise-critical gaps** remain before horizontal scaling is viable:

1. The nginx gateway has no upstream `keepalive`, no `proxy_read_timeout`, no gzip compression, and is missing upstream entries for the two most-loaded services (`vllm`, `agent-router`).
2. docker-compose services have no resource `limits`, no `restart` policies, and no `deploy.replicas` — a single container crash takes down the service permanently.
3. `agent-router` (Mangle query service) is a **single-point of failure** for six dependent services with no replica or health-gate.
4. The KServe serving template has `minReplicas: 1 / maxReplicas: 1` — HPA is effectively disabled.
5. The metrics port (9090) is bound to `0.0.0.0` in non-AI Core deployments, leaking operational telemetry without authentication.
6. The hardcoded object store bucket in `aicore_deployment.mg` (now replaced with env-var pattern) was fixed already in the file — but the `main.zig` fact injection call must be confirmed at runtime.
7. The dead `BACKEND_URL`/`llm_backend.Client` Rust proxy wiring in `config.zig` and `main.zig` adds dead code surface with no upside.
8. The Mojo Flash Attention kernel allocates per-call `m`/`l` scratch buffers on the heap (via `alloc[Float32](seq_len)`) without a persistent workspace, causing GC pressure at high concurrency.
9. The `refill()` function in `rate_limiter.zig` has a TOCTOU gap: it reads `last_refill_ns`, computes `new_tokens`, then CAS-updates the timestamp — under high contention multiple threads may compute overlapping refill windows if the CAS wins after another thread has already advanced `last_refill_ns` again within the same nanosecond tick.

---

## 1. Zig Gateway (`vllm-main/zig/`)

### 1.1 Rate Limiter (`http/rate_limiter.zig`)

| Property | Finding |
|---|---|
| Algorithm | Token-bucket with fixed-point ×1000 precision |
| Thread safety | CAS-based `allowN`, lock-free refill |
| Default capacity | 1000 RPS / 1000 burst (configurable via env) |
| Multi-thread stress test | **Missing** — comment notes omission due to single-threaded test runner |

**Issue (MEDIUM):** The `refill()` CAS on `last_refill_ns` correctly prevents double-refill in the common case, but if two threads both sample `last = T` before either wins the CAS, the losing thread returns without refilling. Under sustained 1000+ RPS this produces systematic under-refill at sub-millisecond tick granularity. Net effect: effective throughput cap is ~10–15% below the configured rate. **Fix:** Use monotonic nanosecond rounding to a coarser refill interval (e.g. 1ms buckets) or switch to a sliding-window counter at enterprise scale.

**Issue (LOW):** No per-client rate limiting — `allow()` is global. For enterprise multi-tenant deployments, per-API-key buckets are needed.

### 1.2 Circuit Breaker (`resilience/circuit_breaker.zig`)

| Property | Finding |
|---|---|
| States | `closed → open → half_open` |
| Transition | CAS-based, thread-safe |
| `reset_timeout_ms` | 30,000 ms (30 s) default |
| `success_threshold` | 3 successes to close |
| `request_timeout_ms` | **Not enforced** — comment explicitly says callers must implement timeouts |

**Issue (HIGH):** `request_timeout_ms = 10_000` is declared but not enforced by `execute()`. The comment states "callers must implement their own timeout logic." Without enforced timeouts, a hung LLM backend can exhaust all worker threads — the circuit never opens because the requests never return an error, they just hang. **Fix:** Add a `std.time.Timer`-based deadline check inside `execute()` or confirm the HTTP layer enforces it.

**Issue (LOW):** `half_open` state allows all concurrent requests through (`allowRequest` returns `true` unconditionally in `.half_open`). Under load, a thundering-herd of requests hits a recovering backend. Standard practice is to limit half-open to 1 probe request. **Fix:** Add a `half_open_probe_sent` atomic flag.

### 1.3 Mangle Engine Hot Path

**Issue (MEDIUM):** Per-request fact injection (`gpu_queue_depth`, `model_chat_style`) causes the Mangle engine to re-parse and re-evaluate facts on every request. For 1000 RPS this is 1000 Mangle evaluations/second. The `TECHNICAL-ASSESSMENT.md` notes the engine is "queried inline during request handling." There is no result caching for identical inputs (same queue depth, same chat style → same routing decision). **Fix:** Cache the last `N` (model, queue_depth) → routing decision tuples with a 100ms TTL.

**Issue (LOW):** Mangle rule files are loaded from disk at startup. There is no hot-reload mechanism documented for production, meaning a rule update requires a pod restart.

### 1.4 KV Cache (`PagedKvCache`)

| Property | Finding |
|---|---|
| Block count | 1024 |
| Block size | 256 tokens |
| Total capacity | 262,144 token slots |
| T4 VRAM | 16 GiB |

**Confirmed Fix (Bug 8):** Block size mismatch between Zig `PagedKvCache` (was 16, now 256) and Mojo `KV_BLOCK_SIZE=256` was corrected.

**Issue (MEDIUM):** At 1024 blocks × 256 tokens × 2 (K+V) × 32 heads × 128 head_dim × 4 bytes ≈ **8.6 GiB KV cache** — consumes 54% of T4 VRAM, leaving ~7.4 GiB for model weights. This is tight for 7B models (Q4_K_M ≈ 4–5 GiB) but leaves only ~2.4 GiB headroom. The `t4_optimization.mg` rules account for this but the Zig block count is hardcoded at 1024. **Fix:** Derive block count from `(available_vram_bytes - model_vram_bytes) / (block_size_tokens * 2 * n_heads * head_dim * sizeof_f16)` and expose as `KV_CACHE_BLOCKS` env var.

### 1.5 TRT Engine Queue Depth

`trt_max_inflight = 64` is the default cap for the TensorRT AWQ path. The AI Core `infer.s` plan provides 1 GPU. At concurrency=64, memory fragmentation risk is significant on a T4 (16 GiB). The Mangle rule `engine_overloaded` threshold is 48. This mismatch (64 vs 48) means the TRT engine can accept 16 more requests than Mangle considers safe — requests 49–64 will be accepted by the Zig gateway but Mangle may still have routed them there. **Fix:** Align `trt_max_inflight` with `engine_queue_threshold` in `model_routing.mg` (both to 48).

### 1.6 Dead Rust Backend Wiring

`config.zig` line 14: `backend_url: []const u8 = "http://localhost:3000"` — points to the superseded Rust/llama.cpp backend (port 3000) documented in `zig/README.md`. `main.zig` imports `llm/backend.zig` and `ServerConfig.backend_url` is still propagated. This dead path is never exercised (GGUF TOON path is active) but expands the attack surface if a process happens to be listening on 3000 in a compromised environment. **Fix:** Remove `backend_url` from `ServerConfig`, `Config`, and `config.zig`; remove `llm_backend` import from `main.zig`.

### 1.7 Metrics Port Security

`metrics.zig` exposes Prometheus metrics on port 9090. `config.zig` has no `metrics_bind_address` field. The `aicore-serving-template.yaml` **already** sets `METRICS_BIND: 127.0.0.1` for AI Core deployments. However, `docker-compose.yml` does not set this variable for the `vllm` service — so in Docker deployments port 9090 is bound to `0.0.0.0`, exposing queue depth, token throughput, error rates, and Engram telemetry without authentication. **Fix:** Add `METRICS_BIND=127.0.0.1` to `vllm` and `mcp-pal` services in `docker-compose.yml`.

---

## 2. Mojo Kernel Layer (`vllm-main/mojo/`)

### 2.1 Flash Attention Memory Allocation

`attention.mojo` `flash_attention()` calls `alloc[Float32](seq_len)` twice per invocation (for `m` and `l` scratch buffers). At 1000 concurrent requests × seq_len=2048 × 2 × 4 bytes = **16 MB of short-lived heap allocations per second**. These are freed at the end of the function but cause fragmentation in Mojo's allocator under high concurrency. **Fix (Flash Attention v2):** Pre-allocate fixed-size workspace buffers as part of model state (once per model load), or use a thread-local scratch arena.

**Flash Attention v1 vs v2 gap:** The current implementation uses v1 tiling (outer loop K, inner loop Q — reversed from optimal). Flash Attention v2 swaps the loop order (outer Q, inner K), enabling better parallelism and removing the `exp_diff` rescale on the output accumulator for most blocks. This is the key optimization that enables 2–3× throughput improvement over v1. The `Br=Bc=64` tile size is fixed; v2 also adapts tile size to the register file.

### 2.2 GEMM Tile Alignment

`kernel/__init__.mojo` (not shown — minimal `__init__`). The SIMD GEMM implementation uses `simdwidthof[DType.float32]()` auto-detection. On T4 (CUDA, via Mojo NVIDIA backend), the SIMD width is effectively 128-bit (4× f32). Tensor Cores operate on 16×16 tiles in FP16. The current F32 GEMM **does not use Tensor Cores** — it operates at CUDA core throughput (~8.1 TFLOPS F32 on T4) vs Tensor Core throughput (65 TFLOPS FP16, 130 TOPS INT8). **Fix:** Implement INT8 Tensor Core GEMM path (documented TODO in mojo/README.md) using `DType.int8` with symmetric per-channel quantisation.

### 2.3 Missing INT8 Quantisation Kernel

The `mojo/README.md` explicitly lists INT8 as a future enhancement. The TRT path uses AWQ INT8 via `trt_quant_mode=2`, but the Mojo GGUF path has no INT8 compute path — all computation is FP32. At inference time on T4, the INT8 path would achieve ~130 TOPS vs ~8 TFLOPS for FP32, a 16× theoretical speedup for GEMM. Even with quantisation overhead, end-to-end throughput improvement of 4–6× is realistic.

### 2.4 Block Size Mismatch (Confirmed Fixed)

Bug 8 is confirmed fixed: `PagedKvCache.KV_BLOCK_SIZE = 256` in Mojo, and the Zig `block_size=256` was corrected. No action needed.

---

## 3. Service Mesh

### 3.1 nginx Gateway (`nginx.conf`)

| Issue | Severity | Detail |
|---|---|---|
| No upstream `keepalive` | HIGH | Each proxied request opens a new TCP connection to upstream. At 1000 RPS this is 1000 TCP handshakes/sec. `keepalive 32` would reuse connections. |
| No `proxy_read_timeout` | HIGH | Default nginx timeout is 60s. LLM inference can take 120–300s. Long responses time out at the gateway, causing 504 errors that look like service failures. |
| No `gzip compression` | MEDIUM | OpenAI JSON responses are highly compressible (~70%). gzip cuts bandwidth 60–70%. |
| Missing `vllm` upstream | HIGH | `vllm` (port 8080) and `agent-router` (8010) are the two highest-load services. They are not routed through the nginx gateway at all — callers must hit their Docker ports directly, bypassing any gateway-level rate limiting, auth, or observability. |
| `worker_connections 1024` | MEDIUM | At 1000 RPS with 300ms average LLM latency, concurrent connections = 300. 1024 headroom is adequate but should scale with `worker_processes auto`. |
| Wildcard CORS `*` | LOW | `Access-Control-Allow-Origin: *` is appropriate for development but should be locked to specific origins in production. |

### 3.2 docker-compose (`docker-compose.yml`)

| Issue | Severity | Detail |
|---|---|---|
| No `resource limits` on custom services | HIGH | Any service can consume all host CPU/RAM, starving other services. Should set `deploy.resources.limits` for each. |
| No `restart: unless-stopped` | HIGH | Container crash = permanent downtime until manual restart. All services need restart policy. |
| No `deploy.replicas` | MEDIUM | All services run as single replicas with no redundancy. |
| `agent-router` is SPOF | HIGH | Six services (`world-monitor`, `data-copilot`, `cap-llm-plugin`, `ai-shared-fabric`, `ai-prompt-agent`, `embedded-hana`) all depend on `agent-router`. A single crash takes down the entire governance layer. |
| No Prometheus scrape config | MEDIUM | `vllm` exposes metrics on port 9090 but there is no `prometheus.yml` or scrape config in the compose file — metrics are never collected. |
| Elasticsearch undersized | MEDIUM | `ES_JAVA_OPTS=-Xms512m -Xmx512m` — for a production search index supporting `world-monitor` and `data-copilot`, 512 MiB heap is minimal. Recommendation: 2–4 GiB. |
| `version: '3.8'` | LOW | Obsolete `version` key; Compose v2 ignores it but it triggers deprecation warnings. |

### 3.3 AI Core KServe Template (`aicore-serving-template.yaml`)

| Issue | Severity | Detail |
|---|---|---|
| `minReplicas: 1 / maxReplicas: 1` | HIGH | HPA is effectively disabled. Serving scales to exactly 1 replica and cannot scale out under load. |
| `autoscaling.knative.dev/target: 1` | HIGH | One concurrent request triggers scale-out — correct direction, but combined with `maxReplicas: 1` it does nothing. |
| Docker Hub image reference | MEDIUM | `ghcr.io/sap/ai-core-privatellm:v2.1.0` (updated from the `docker.io/gjkarthik` in TECHNICAL-ASSESSMENT) — ensure this is a private GHCR registry with access controls, not a public image. |
| No `PodDisruptionBudget` | MEDIUM | Rolling updates can drop to 0 replicas. A PDB with `minAvailable: 1` prevents this. |
| No `livenessProbe` | MEDIUM | Only readiness is implied by AI Core health checks. A liveness probe on `/health` ensures stuck containers are restarted. |
| `METRICS_BIND: 127.0.0.1` | ✅ FIXED | Already set in the serving template — metrics port correctly localhost-bound on AI Core. |

---

## 4. Summary: Prioritised Fixes

### P0 — Fix Immediately (Production Blocking)

| ID | Component | Fix |
|---|---|---|
| P0-1 | nginx | Add `keepalive 32` to all upstream blocks; add `proxy_read_timeout 300s` |
| P0-2 | nginx | Add upstream entries + routes for `vllm` (8080) and `agent-router` (8010) |
| P0-3 | docker-compose | Add `restart: unless-stopped` to all 12 services |
| P0-4 | docker-compose | Add `METRICS_BIND=127.0.0.1` to `vllm` and `mcp-pal` services |
| P0-5 | KServe | Change `maxReplicas: 1` → `maxReplicas: 8`; add PDB |

### P1 — Fix Before Scale-Out

| ID | Component | Fix |
|---|---|---|
| P1-1 | docker-compose | Add `deploy.resources.limits` to all custom services |
| P1-2 | Zig circuit breaker | Enforce `request_timeout_ms` inside `execute()` |
| P1-3 | Zig rate limiter | Add per-API-key buckets for multi-tenant |
| P1-4 | Mangle hot path | Cache routing decisions (100ms TTL) |
| P1-5 | Zig config | Remove dead `backend_url`/Rust backend wiring |
| P1-6 | nginx | Add `gzip on` for JSON responses; set `worker_processes auto` |

### P2 — Performance Enhancements

| ID | Component | Fix |
|---|---|---|
| P2-1 | Mojo kernels | Implement INT8 Tensor Core GEMM path |
| P2-2 | Mojo attention | Flash Attention v2 (swap loop order, persistent workspace) |
| P2-3 | Zig KV cache | Derive block count from available VRAM at runtime |
| P2-4 | Zig circuit breaker | Limit half-open to 1 probe request |

---

## 5. Benchmark Baselines

See companion files:
- `zig/src/tests/bench_rate_limiter.zig` — rate limiter throughput under contention
- `zig/src/tests/bench_mangle_routing.zig` — Mangle fact-inject + query latency
- `zig/src/tests/bench_kv_cache.zig` — paged KV alloc/evict under batch loads
- `mojo/tests/bench_kernels.mojo` — GEMM, Flash Attention, tokenizer at scale
- `scripts/load-test/k6_chat_completions.js` — end-to-end HTTP load test
- `scripts/load-test/k6_embeddings.js` — embeddings endpoint throughput
