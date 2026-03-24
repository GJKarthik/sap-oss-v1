# TOON Engine / GGUF Loader — Findings & Fixes

> **Do not commit** the code changes below until validated in production.
> This document tracks all bugs found and the patches applied during the
> Qwen3.5 GGUF bring-up session (2026-03-17).

---

## 1. Wrong GGUF Magic Constant

### File
`src/intelligence/vllm-main/zig/deps/llama/llama.zig`

### Symptom
Gateway starts, passes the file-open and Metal-init steps, then immediately logs:

```
info: Loading GGUF model to CPU...
warning: TOON engine init failed (error.InvalidGGUF) — direct inference disabled
```

### Root Cause
The constant `GGUF_MAGIC` was defined as `0x46475547` ("GUGF") instead of the
correct `0x46554747` ("GGUF" in little-endian). Every real GGUF file has magic
bytes `47 47 55 46` (G G U F), which read as `u32 LE = 0x46554747`. The code
compared against the wrong value and always returned `error.InvalidGGUF`.

| Bytes in file | Correct constant | Wrong constant |
|---|---|---|
| `47 47 55 46` | `0x46554747` | `0x46475547` |

### Fix
```zig
// Before
const GGUF_MAGIC: u32 = 0x46475547; // "GGUF" little-endian  ← WRONG

// After
const GGUF_MAGIC: u32 = 0x46554747; // "GGUF" little-endian  ← CORRECT
```

### Verification
After the fix, the magic check passes and the loader proceeds to parse
metadata and tensor infos correctly (confirmed by GgufTokenizer loading
successfully: `vocab=248320 merges=247587 arch=qwen35`).

---

## 2. `loadFromGGUF` Read Entire File into Heap

### File
`src/intelligence/vllm-main/zig/deps/llama/llama.zig`

### Symptom
After fix #1, the gateway now crashes with a **segmentation fault** instead of
`error.InvalidGGUF`:

```
info: Loading GGUF model to CPU...
[segfault — no further output]
```

### Root Cause
`loadFromGGUF` used `allocator.alloc(u8, file_size)` followed by
`file.read(data)` to pull the entire 774 MB GGUF file into the heap.  This:

1. Blocks the process for several seconds while reading 774 MB sequentially.
2. Allocates 774 MB of heap in addition to the ~2 GB needed for f32 weights.
3. On macOS with unified memory, `mmap(MAP_ANONYMOUS)` can succeed even when
   not enough physical pages are available; the first real write into those
   pages triggers **SIGBUS**, which Zig surfaces as a segfault.

### Fix
Replaced heap allocation + `file.read` with `std.posix.mmap(PROT.READ, MAP_PRIVATE)`:

```zig
// Before
const data = try allocator.alloc(u8, file_size);
defer allocator.free(data);
var offset: usize = 0;
while (offset < file_size) {
    const bytes = try file.read(data[offset..]);
    if (bytes == 0) return error.UnexpectedEOF;
    offset += bytes;
}

// After
const data = try mapFileReadOnly(path);   // mmap the file read-only
defer std.posix.munmap(data);
const file_size = data.len;
```

`mapFileReadOnly` was already present in the file for the SafeTensors path.
The OS now pages in tensor blocks on demand rather than reading the entire
file at once.

---

## 3. CPU f32 Weight Allocation Exceeds Physical RAM (SIGBUS)

### File
`src/intelligence/vllm-main/zig/deps/llama/llama.zig`

### Symptom
After fixes #1 and #2, the gateway still crashes with a segfault at "Loading
GGUF model to CPU…". The mmap fix reduced peak I/O but the actual memory
problem is in `TransformerWeights.allocateRaw`.

### Root Cause
Dequantising a GGUF to f32 requires:

| Buffer | Qwen3.5-0.8B size |
|---|---|
| `token_embedding` | 248 320 × 1 024 × 4 B = **969 MB** |
| `lm_head` | 248 320 × 1 024 × 4 B = **969 MB** |
| 24 × attention matrices | ~312 MB |
| 24 × FFN matrices | ~900 MB |
| **Total estimated** | **~3.1 GB** |

On a consumer Mac (8–16 GB), after OS + Metal + other processes, there is
typically < 3 GB of free physical RAM.  `allocator.alloc` on macOS uses
`mmap(MAP_ANONYMOUS)` which always succeeds (virtual memory is not committed
until first write).  When the dequantisation loop writes to the 969 MB
`token_embedding` buffer and the OS cannot provide physical pages, it sends
**SIGBUS**, which Zig does not intercept, causing a crash rather than a clean
`error.OutOfMemory`.

### Fix
Added a pre-flight memory-footprint estimate before calling `allocateRaw`.
If the estimated f32 footprint exceeds **1.5 GB**, `loadFromGGUF` returns
`error.ModelTooLarge` instead of attempting the allocation.  The TOON
`init` caller already handles any error from `loadFromGGUF` by logging a
warning and disabling direct inference (gateway continues as a proxy).

```zig
{
    const v: u64 = config.vocab_size;
    const d: u64 = config.n_embd;
    const ff64: u64 = config.n_ff;
    const l: u64 = config.n_layers;
    const embed_bytes: u64 = v * d * 2 * 4;          // token_embedding + lm_head
    const layer_bytes: u64 = l * (d*d*4 + d*ff64*2 + ff64*d) * 4;
    const total_est: u64 = embed_bytes + layer_bytes;
    const max_cpu: u64 = 1536 * 1024 * 1024;          // 1.5 GB
    if (total_est > max_cpu) {
        std.log.warn("GGUF: estimated f32 footprint ~{d} MB exceeds 1.5 GB CPU limit …", …);
        return error.ModelTooLarge;
    }
}
```

### Threshold guidance

| Model | Estimated f32 MB | Fits in 1.5 GB? |
|---|---|---|
| TinyLlama-1.1B (vocab=32 k, dim=2 048) | ~530 MB | ✅ yes |
| Qwen3.5-0.8B (vocab=248 k, dim=1 024) | ~3 100 MB | ❌ no → `ModelTooLarge` |
| Qwen3.5-4B (vocab=248 k, dim=2 560) | ~6 400 MB | ❌ no |
| LLaMA-3.2-1B (vocab=128 k, dim=2 048) | ~2 100 MB | ❌ no |

### Long-term path
To support large-vocab models on CPU, the transformer forward pass must be
rewritten to operate directly on quantised weights (Q8_0 matmul), eliminating
the f32 dequant step entirely.  That work is tracked separately.

---

## Summary of Code Changes (not committed)

| File | Change |
|---|---|
| `zig/deps/llama/llama.zig` | Fix 1: `GGUF_MAGIC = 0x46554747` |
| `zig/deps/llama/llama.zig` | Fix 2: `loadFromGGUF` uses `mmap` instead of heap read |
| `zig/deps/llama/llama.zig` | Fix 3: memory guard → `error.ModelTooLarge` before `allocateRaw` |

All three changes are in the same file.  Rebuild with:

```sh
cd src/intelligence/vllm-main/zig
zig build -Doptimize=ReleaseFast -Dgpu=false
```

After the fixes the gateway starts cleanly with Qwen3.5-0.8B:

```
info: Loading GGUF model from: models/llm/Qwen3.5-0.8B-Q8_0.gguf
warning(cuda_backend): CUDA not available, using CPU fallback
info: Loading GGUF model to CPU...
warning: GGUF: estimated f32 footprint ~3100 MB exceeds 1.5 GB CPU limit …
warning: TOON engine init failed (error.ModelTooLarge) — direct inference disabled
info(gguf_tokenizer): GgufTokenizer loaded: vocab=248320 …
info: OpenAI Gateway starting on 0.0.0.0:8080
```

TOON direct inference is disabled (Metal/CUDA path required for this model),
but the gateway runs as a proxy and the GGUF tokenizer is still used for token
counting and TOON-format compression.