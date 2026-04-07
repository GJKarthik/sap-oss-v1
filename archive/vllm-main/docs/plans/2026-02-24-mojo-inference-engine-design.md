# Mojo Inference Engine - Design Document

**Date:** 2026-02-24
**Status:** Approved
**Goal:** Remove llama.cpp, replace with Mojo runtime library for standalone inference
**E2E Target:** "What is the capital of France?" -> "Paris" via TinyLlama 1.1B Q4_K_M

---

## Architecture

```
Client (POST /v1/chat/completions)
    |
    v
ZIG LAYER (HTTP + GGUF + Tokenization)
    main.zig ---- HTTP server (port 8080), OpenAI API
    |               Auth, rate limiting, metrics, circuit breaker
    |
    |-- gguf_loader ---- Parse GGUF headers, extract tensor metadata, mmap weights
    |-- gguf_tokenizer - BPE tokenization (pure Zig, already exists)
    |-- ffi/mojo_inference_bridge.zig
    |       dlopen("libprivatellm_kernels.{so,dylib}")
    |       C FFI calls to Mojo forward pass
    |
    v  C FFI (extern "C")
MOJO LAYER (Full Forward Pass + Sampling)
    libprivatellm_kernels.so / .dylib
    |
    |-- embedding_lookup (vocab x hidden_dim, dequant Q4_K)
    |-- 22x transformer layers:
    |     rms_norm -> QKV projection -> RoPE -> GQA attention -> output proj
    |     rms_norm -> SwiGLU FFN (gate + up + down)
    |     residual connections
    |-- final rms_norm
    |-- lm_head projection -> logits[32000]
    |-- sampling (greedy / temperature / top-p)
```

**Key principle:** Zig owns HTTP + GGUF parsing + tokenization. Mojo owns the entire forward pass + sampling. Boundary: token IDs in, token IDs out.

---

## FFI Contract

```c
// Lifecycle
int         pllm_init(void);
void        pllm_shutdown(void);

// Model management
void*       pllm_model_load(
                const void* weights_ptr,        // mmap'd GGUF tensor bytes
                size_t weights_len,
                const char* config_json,        // {"hidden_dim":2048,"n_heads":32,...}
                size_t config_len
            );
void        pllm_model_free(void* model_handle);

// KV Cache
void*       pllm_kv_cache_create(void* model_handle, int max_seq_len);
void        pllm_kv_cache_clear(void* cache_handle);
void        pllm_kv_cache_free(void* cache_handle);

// Forward pass
int         pllm_forward(
                void* model_handle,
                void* cache_handle,
                const int* token_ids,           // Input tokens
                int n_tokens,                   // Count
                int start_pos,                  // KV cache position
                float* logits_out,              // Output: [vocab_size] floats
                int logits_capacity
            );

// Sampling
int         pllm_sample(
                const float* logits,
                int vocab_size,
                float temperature,
                float top_p,
                float repetition_penalty,
                const int* prev_tokens,
                int n_prev_tokens
            );

// Info
int         pllm_version(void);
const char* pllm_device_info(void);
```

---

## TinyLlama 1.1B Model Spec

- Architecture: LLaMA
- Layers: 22
- Hidden dim: 2048
- Attention heads: 32
- KV heads: 4 (Grouped Query Attention, 8:1 ratio)
- FFN dim: 5632
- Vocab: 32000
- Context: 2048
- Quantization: Q4_K_M (~700MB)
- Norm: RMS Norm (eps=1e-5)
- Activation: SiLU (SwiGLU FFN)
- Position encoding: RoPE (base=10000)

---

## Mojo Source Layout

```
mojo/src/
  lib.mojo              # FFI exports (extern "C" pllm_* functions)
  model.mojo            # LlamaModel struct, weight interpretation from raw pointer
  forward.mojo          # Forward pass orchestration (prefill + decode)
  config.mojo           # Model config parsing from JSON string
  sampling.mojo         # Temperature, top-p, repetition penalty, greedy
  kv_cache.mojo         # KV cache (pre-allocated, position-indexed)
  layers/
    attention.mojo      # GQA: Q/K/V projection, RoPE, scaled dot-product, output proj
    ffn.mojo            # SwiGLU: gate_proj, up_proj, silu, element-wise mul, down_proj
    norm.mojo           # RMS normalization (SIMD vectorized)
    embedding.mojo      # Token embedding lookup with Q4_K dequant
  kernels/
    matmul.mojo         # Tiled SIMD matmul (cache-line-aware blocking)
    rope.mojo           # Rotary position embeddings (paired sin/cos)
    softmax.mojo        # Numerically stable softmax
    silu.mojo           # SiLU activation (x * sigmoid(x))
    dequant.mojo        # Q4_K_M block dequantization
  tests/
    test_forward.mojo   # Forward pass unit tests
    test_kernels.mojo   # Kernel correctness tests
    test_e2e.mojo       # Standalone E2E: load model, generate, check output
build.sh                # mojo build -> libprivatellm_kernels.{so,dylib}
```

---

## Zig Changes

### New files

```
zig/src/ffi/mojo_inference_bridge.zig   # dlopen + function pointer table + fallback handling
```

### Rewrite

| File | Change |
|------|--------|
| `main.zig` | Remove `backend_url`, `use_local_llama`, `llm_backend` import. Add `mojo_inference_bridge`. Standalone mode only. |
| `llm/backend.zig` | Gut HTTP proxy client. Replace with Mojo FFI inference calls. |
| `toon/llama_toon.zig` | Remove `@import("llama")`. Use Mojo FFI for inference. Keep TOON formatting. |
| `llm/model_store.zig` | Remove "llama.cpp format" comment. GGUF is just a file format. |
| `config.zig` | Remove `backend_url`. Add `mojo_lib_path`, `gguf_model_path`. |
| `build.zig` | Remove `llama_mod` from deps/llama. Add mojo_inference_bridge module. |
| `deps/llama-zig-cuda/build.zig` | Remove `llama-server`, `llama-cli` targets. |

### Delete

| File/Dir | Reason |
|----------|--------|
| `deps/llama-zig-cuda/src/llama_cpp.zig` | C FFI to llama.h - replaced by Mojo |
| `deps/llama-zig-cuda/csrc/` | C interop stubs |
| `deps/llama/` | Llama SDK shim directory |

### Keep as-is

| File | Reason |
|------|--------|
| `toon/gguf_tokenizer.zig` | Pure Zig, no llama.cpp dep |
| `toon/toon.zig` | TOON format, no llama.cpp dep |
| `deps/llama-zig-cuda/src/model.zig` | Architecture enum, ModelConfig (pure Zig data types) |
| `deps/llama-zig-cuda/mangle/*.mg` | Declarative specs, no llama.cpp dep |
| `deps/llama-zig-cuda/src/mangle_client.zig` | Mangle queries, pure Zig |
| All HTTP infra | server, auth, metrics, rate limiter, circuit breaker |
| `gpu/` directory | Metal/CUDA backends for future Mojo-GPU dispatch |

---

## Scripts/Deploy/Docs Updates

| File | Change |
|------|--------|
| `scripts/start_server.sh` | Remove `check_llama_server()`, `brew install llama.cpp`, `$LLAMA_SERVER`. Add Mojo lib check. |
| `deploy/SCALING.md` | Remove `ghcr.io/ggml-org/llama.cpp:server` Docker refs |
| `Dockerfile` | Remove llama-server stage. Add Mojo build stage. |
| `Makefile` | Add `build-mojo-kernels` target. Update `run` to set `MOJO_LIB_PATH`. |
| `README.md` | "Inference Engine (Mojo SIMD / Metal / CUDA)" |
| `CHANGELOG.md` | Add migration entry |

---

## Cross-Service Integration

**ai-core-fabric:**
- No changes needed. Privatellm remains OpenAI-compatible.
- Fabric's Blackboard can store model health status.
- Fabric's `openai_models.zig` discovers models from privatellm `/v1/models`.

**ai-core-streaming:**
- Topics unchanged: `persistent://ai-core/privatellm/{requests,responses}`
- TOON format output flows unchanged.
- Streaming's `llama_toon.zig` needs same update (remove `@import("llama")`, use Mojo FFI).

---

## E2E Test

```bash
# 1. Build Mojo library
cd mojo && ./build.sh  # -> libprivatellm_kernels.{so,dylib}

# 2. Download model
huggingface-cli download TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF \
  tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf --local-dir models/llm/

# 3. Build & start server
GGUF_MODEL_PATH=models/llm/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf \
MOJO_LIB_PATH=mojo/libprivatellm_kernels.so \
zig build run

# 4. Test
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"tinyllama","messages":[{"role":"user","content":"What is the capital of France?"}]}' \
  | jq -r '.choices[0].message.content'
# Expected: contains "Paris"
```

---

## Execution Phases

### Phase 1: Mojo Kernel Library (the engine)
1. Q4_K_M block dequantization kernel
2. Tiled SIMD matmul (fused dequant-matmul)
3. RMS norm, SiLU, softmax, RoPE kernels
4. GQA attention with KV cache
5. SwiGLU FFN
6. Forward pass orchestration (prefill + decode loop)
7. Sampling (greedy first, then temperature/top-p)
8. FFI exports (extern "C") + build script

### Phase 2: Zig FFI Bridge (the glue)
1. `mojo_inference_bridge.zig` (dlopen, function pointer table, graceful fallback)
2. GGUF weight mmap + metadata extraction -> config JSON for Mojo
3. Wire into main.zig request handler (replace proxy path)

### Phase 3: llama.cpp Removal (the cleanup)
1. Delete `llama_cpp.zig`, `csrc/`, `deps/llama/`
2. Rewrite `main.zig` (standalone, no proxy)
3. Update `build.zig` files
4. Update scripts, deploy configs, docs

### Phase 4: E2E Test (the proof)
1. Download TinyLlama 1.1B Q4_K_M GGUF
2. Build Mojo library
3. Build Zig server
4. Run server, send "What is the capital of France?", assert "Paris"
5. Integration test with ai-core-streaming topics
