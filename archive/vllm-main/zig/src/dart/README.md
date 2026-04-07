# Lean-DART: Speculative Decoding for NVIDIA T4

A Zig/Mojo implementation of DART (Diffusion-based Auto-Regressive Token) speculative decoding,
optimized for the NVIDIA T4's 16GB VRAM constraint and INT8 Tensor Cores.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         LEAN-DART INFERENCE                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────┐     ┌─────────────────┐     ┌───────────────────┐ │
│  │ Target Model│     │   DART Draft    │     │   N-Gram Trie     │ │
│  │ (INT8 AWQ)  │     │   Head (INT8)   │     │   (2-gram/CPU)    │ │
│  │  ~7-8 GB    │     │   ~200 MB       │     │   ~2-4 GB RAM     │ │
│  └──────┬──────┘     └────────┬────────┘     └────────┬──────────┘ │
│         │                     │                       │            │
│         │    ┌────────────────┴───────────────────────┘            │
│         │    │                                                      │
│         ▼    ▼                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Speculation Pipeline                      │   │
│  │  1. Draft head predicts K candidates (parallel, GPU)        │   │
│  │  2. Trie lookup scores continuity (CPU, <1μs latency)       │   │
│  │  3. Tree pruning merges scores                              │   │
│  │  4. Target model verifies (single batched forward)          │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## File Structure

```
dart/
├── ngram_trie.zig      # Memory-efficient 2-gram trie (CPU)
├── draft_tree.zig      # Draft token tree builder with pruning
├── dart_engine.zig     # Main inference orchestration
└── README.md           # This file

../../../mojo/src/dart/
└── dart_head.mojo      # DART draft head (GPU, INT8 Tensor Cores)
```

## Key Differences from Original DART

| Component | Original DART | Lean-DART (T4) |
|-----------|---------------|----------------|
| N-gram model | 3-gram, 1.3B nodes, ~100 GB RAM | **2-gram, context-built, 0–4 GB** |
| Draft positions K | 6–8 | **4** (T4 bandwidth-optimal) |
| Max tree nodes | ~60–80 | **25** |
| Model precision | FP16/BF16 | **INT8** (target) + FP16 (head) |
| Expected speedup | 2.5–3.3x | **1.5–2.2x** |

## Components

### 1. NGramTrie (`ngram_trie.zig`)

Memory-efficient n-gram trie for draft token tree pruning.

**Features:**
- 2-gram default (vs DART's 3-gram) → ~1000x fewer nodes
- Frequency pruning: discards n-grams seen < min_count times
- Top-k children: keeps only most frequent continuations per prefix
- Arena allocation: fast bulk deallocation, cache-friendly layout
- Lookup time: O(n), typically <1μs for 2-gram

**Modes:**
- `context`: Built from prompt at inference time (zero persistent RAM)
- `corpus`: Pre-built from domain corpus (~2-4 GB for focused domains)
- `hybrid`: Merges context + corpus at query time

```zig
const trie = try NGramTrie.init(allocator, .{
    .n = 2,
    .min_count = 1,
    .max_children = 20,
    .mode = .context,
});
defer trie.deinit();

// Update from prompt
try trie.updateFromContext(prompt_tokens);

// Lookup continuations
var buffer: [10]TokenProb = undefined;
const results = trie.getContinuations(&prefix, &candidates, &buffer);
```

### 2. DraftTreeBuilder (`draft_tree.zig`)

Builds and prunes the speculative draft token tree.

**Algorithm:**
1. DART head outputs K parallel logit distributions
2. For each position, take top-n candidates
3. Build tree: position 0 candidates are roots, position i extends i-1
4. Score paths: `combined = alpha * logit + (1 - alpha) * ngram`
5. Prune to max_nodes budget
6. Return flattened sequences for verification

```zig
var builder = try DraftTreeBuilder.init(allocator, .{
    .alpha = 0.7,           // Logit weight
    .max_nodes = 25,        // T4-tuned
    .max_candidates_per_pos = 5,
});
defer builder.deinit();

var result = try builder.buildTree(
    candidate_ids,          // [K, n_candidates]
    candidate_log_probs,    // [K, n_candidates]
    ngram_scores_per_pos,   // [K] TokenProb arrays
    prefix_tokens,
);
defer result.deinit(allocator);

const best_draft = DraftTreeBuilder.getBestSequence(&result);
```

### 3. DARTHead (`dart_head.mojo`)

Lightweight DART draft head for parallel token prediction.

**Architecture:**
1. Project hidden states: 4096 → 512 (INT8 linear)
2. Inject K learnable mask tokens
3. Single transformer layer with draft causal mask
4. Project to vocab logits for K positions

**Memory footprint (~20 MB):**
- input_proj: 4096 × 512 INT8 = 2 MB
- QKV: 3 × 512 × 512 INT8 = 0.75 MB
- FFN: 512 × 1024 × 2 INT8 = 1 MB
- lm_head: 512 × 32000 INT8 = 16 MB

```mojo
var config = DARTHeadConfig()
config.hidden_size = 4096
config.vocab_size = 32000
config.num_draft_positions = 4

var head = DARTHead(config)
head.forward(hidden_states, batch_size, prefix_len, output_logits)
head.get_top_k_candidates(logits, batch_size, K, n_candidates, out_ids, out_probs)
```

### 4. DARTEngine (`dart_engine.zig`)

Main inference orchestration.

```zig
var engine = try DARTEngine.init(allocator, .{
    .hidden_size = 4096,
    .vocab_size = 128256,
    .num_draft_positions = 4,
    .trie_mode = .context,
});
defer engine.deinit();

var kv_cache = try llama.KVCache.init(allocator, model.config);
defer kv_cache.deinit(allocator);

const output = try engine.generate(model, &kv_cache, prompt_tokens, 256);
defer allocator.free(output);

// Print statistics
try engine.printStats(std.io.getStdErr().writer());
```

## T4 VRAM Budget

```
Model: LLaMA-3.1-8B (INT8)         ~8.0 GB
DART head (INT8, head_hidden=512)   ~0.2 GB
KV cache (2K context, FP16)        ~1.5 GB
Activations (peak, FP16)           ~0.8 GB
CUDA overhead                       ~0.5 GB
─────────────────────────────────────────
Total                              ~11.0 GB  (5 GB headroom on 16 GB T4)
```

## Expected Performance

| Task | Baseline (tok/s) | Lean-DART (tok/s) | Speedup |
|------|------------------|-------------------|---------|
| Summarization (high repetition) | ~20 | ~40–45 | **2.0–2.2x** |
| RAG / Document QA | ~20 | ~35–42 | **1.75–2.1x** |
| Multi-turn chat | ~20 | ~30–38 | **1.5–1.9x** |
| Code completion | ~20 | ~32–40 | **1.6–2.0x** |
| Creative writing (low repetition) | ~20 | ~24–28 | **1.2–1.4x** |

## Building

### Zig Components

```bash
cd src/intelligence/ai-core-privatellm/zig
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

### Mojo Components

```bash
cd src/intelligence/ai-core-privatellm/mojo
mojo build src/dart/dart_head.mojo -o dart_head

# Run test
mojo run src/dart/dart_head.mojo
```

## Configuration Presets

```zig
// LLaMA-3.1-8B on T4
const config = DARTConfig.forLlama8B();

// Qwen2.5-7B on T4  
const config = DARTConfig.forQwen7B();

// Custom configuration
const config = DARTConfig{
    .hidden_size = 4096,
    .vocab_size = 32000,
    .num_draft_positions = 4,  // K
    .alpha = 0.7,              // Logit vs ngram weight
    .max_tree_nodes = 25,
    .trie_mode = .context,
};
```

## DART++ Extensions (2025)

The DART++ extensions add three key improvements:

### 1. FLy Verifier (`fly_verifier.zig`)
Entropy-gated acceptance: allows semantic equivalents at high-entropy positions.
- **5 tests passed** ✅

### 2. Cacheback LRU Trie (`cacheback_trie.zig`)
Online learning: cache adapts during generation, not just from prompt.
- 100K entry LRU cache
- **5 tests passed** ✅

### 3. SVIP Variable-K Drafter (`svip_drafter.zig`)
Confidence-gated K selection: K ∈ [2, 6] based on confidence.
- **4 tests passed** ✅

### 4. Combined Engine (`dart_plusplus.zig`)
Integrates FLy + Cacheback + SVIP for maximum performance.
- **3 tests passed** ✅

### 5. Accuracy Benchmark (`accuracy_benchmark.zig`)
Validates ≥99% token match rate vs baseline.
- **3 tests passed** ✅

### Test Summary (Zig 0.15.1)
```
fly_verifier.zig:       5/5 passed
cacheback_trie.zig:     5/5 passed  
svip_drafter.zig:       14/14 passed (with deps)
dart_plusplus.zig:      17/17 passed (with deps)
accuracy_benchmark.zig: 3/3 passed
────────────────────────────────────
Total:                  All tests passed ✅
```

## Medium-Effort Extensions (HeteroSpec + QuantSpec)

### 6. HeteroSpec Adaptive Tree (`heterospec_tree.zig`)
Entropy-adaptive tree breadth expansion:
- **Low entropy (< 0.5)**: K=6, 8 candidates/position → wide tree
- **Med entropy (0.5-1.5)**: K=4, 5 candidates/position → balanced
- **High entropy (> 1.5)**: K=2, 3 candidates/position → narrow tree
- Smoothed entropy tracking with configurable decay
- **6 tests passed** ✅

### 7. QuantSpec Self-Speculative Draft (`quantspec_drafter.zig`)
4-bit quantized copy of target model as drafter:
- Best for small models (3B) where VRAM allows dual models
- Higher acceptance rates than DART head (same architecture)
- Auto-detects model size tier and VRAM constraints
- **7 tests passed** ✅

### 8. Hybrid Drafter (`hybrid_drafter.zig`)
Automatic strategy selection based on model and hardware:
- **8B model detected** → DART head (default)
- **3B model detected** → QuantSpec (higher acceptance)
- Hardware profiles for T4, A10, etc.
- Dynamic strategy switching during generation
- **10 tests passed** ✅

### Full Test Suite Summary
```
heterospec_tree.zig:     6/6 passed
quantspec_drafter.zig:   7/7 passed
hybrid_drafter.zig:      23/23 passed (with deps)
────────────────────────────────────
New modules:             All tests passed ✅
```

## Limitations

1. **Lower trie quality**: 2-gram context trie misses global language statistics.
   Acceptance rates ~5-10% lower than full DART.

2. **K=4 vs K=6-8**: Fewer draft positions = fewer tokens accepted per step.
   Tuned to T4's memory bandwidth.

3. **No FP8**: T4 doesn't support FP8, so verification runs FP16.
   H100/L40S would be ~2x faster on this step.

## References

- DART paper: https://arxiv.org/abs/2601.19278
- N-Gram Trie (EMNLP 2025): https://aclanthology.org/2025.emnlp-main.911
- TensorRT-LLM NGram: https://nvidia.github.io/TensorRT-LLM/advanced/speculative-decoding.html
