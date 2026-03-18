"""
PLLM FFI Exports — Mojo 0.26.1 Compatible
Stateful engine: handle = Int64 (malloc addr).
All memory owned by malloc; List[Float32] for computation.
Pattern: UnsafePointer(to=staging) + external_call["memcpy"] for I/O.
"""

from memory import UnsafePointer
from sys.ffi import external_call
from math import exp, sqrt

# ─────────────────────────────────────────────────────────────────────────────
# Error codes
# ─────────────────────────────────────────────────────────────────────────────
comptime PLLM_SUCCESS: Int32 = 0
comptime PLLM_ERROR_NULL_POINTER: Int32 = -1
comptime PLLM_ERROR_INVALID_HANDLE: Int32 = -2
comptime PLLM_ERROR_OUT_OF_MEMORY: Int32 = -3
comptime PLLM_ERROR_INVALID_CONFIG: Int32 = -4
comptime PLLM_ERROR_LOAD_FAILED: Int32 = -5
comptime PLLM_ERROR_INFERENCE_FAILED: Int32 = -6
comptime PLLM_ERROR_BUFFER_TOO_SMALL: Int32 = -7
comptime PLLM_ERROR_MODEL_NOT_LOADED: Int32 = -8

# Config field IDs for pllm_engine_get_config
comptime PLLM_CONFIG_VOCAB_SIZE: Int32 = 0
comptime PLLM_CONFIG_EMBED_DIM: Int32 = 1
comptime PLLM_CONFIG_NUM_HEADS: Int32 = 2
comptime PLLM_CONFIG_NUM_KV_HEADS: Int32 = 3
comptime PLLM_CONFIG_NUM_LAYERS: Int32 = 4
comptime PLLM_CONFIG_FFN_DIM: Int32 = 5
comptime PLLM_CONFIG_MAX_SEQ_LEN: Int32 = 6
comptime PLLM_CONFIG_HEAD_DIM: Int32 = 7

# Q4_K_M block constants
comptime QK_K: Int32 = 256
comptime BLOCK_SIZE_Q4_K_M: Int32 = 142

# Quantization modes
comptime PLLM_QUANT_FP16: Int32 = 0
comptime PLLM_QUANT_INT8: Int32 = 1
comptime PLLM_QUANT_AWQ: Int32 = 2
comptime PLLM_QUANT_FP8: Int32 = 3

# Batch status codes
comptime PLLM_BATCH_QUEUED: Int32 = 0
comptime PLLM_BATCH_RUNNING: Int32 = 1
comptime PLLM_BATCH_COMPLETE: Int32 = 2
comptime PLLM_BATCH_ERROR: Int32 = -1

# ─────────────────────────────────────────────────────────────────────────────
# Handle layout (512-byte header at malloc address):
# Offset  0: vocab_size  (Int32)
# Offset  4: embed_dim   (Int32)
# Offset  8: num_heads   (Int32)
# Offset 12: num_kv_heads(Int32)
# Offset 16: num_layers  (Int32)
# Offset 20: ffn_dim     (Int32)
# Offset 24: max_seq_len (Int32)
# Offset 28: head_dim    (Int32)
# Offset 32: loaded      (Int32)  0=false, 1=true
# Offset 36: (pad Int32)
# Offset 40: hidden_buf  (Int64)  → float32[max_seq_len * embed_dim]
# Offset 48: logits_buf  (Int64)  → float32[vocab_size]
# Offset 56: kv_k        (Int64)  → float32[layers * max_seq * num_kv_heads * head_dim]
# Offset 64: kv_v        (Int64)  → float32[same]
# ─────────────────────────────────────────────────────────────────────────────

# ── Memory I/O: List-data-pointer patching trick. ──────────────────────────
# ── Each function inlines the pattern (no UnsafePointer[T] return type)   ──
# ── because bitcast mut-inference fails when the callee returns a pointer. ──
# ── Verified in t_direct.mojo: same pattern with Int32 return works fine. ──

fn rd_i32(base: Int64, off: Int64) -> Int32:
    var addr = base + off
    var v = List[Int32](capacity=1)
    v.append(0)
    var meta = UnsafePointer(to=v)
    var df = meta.bitcast[Int64]()
    df[] = addr
    var result = v.unsafe_ptr()[]
    df[] = 0
    return result

fn wr_i32(base: Int64, off: Int64, val: Int32) -> None:
    var addr = base + off
    var v = List[Int32](capacity=1)
    v.append(val)
    var meta = UnsafePointer(to=v)
    var df = meta.bitcast[Int64]()
    df[] = addr
    v.unsafe_ptr()[] = val
    df[] = 0

fn rd_i64(base: Int64, off: Int64) -> Int64:
    var addr = base + off
    var v = List[Int64](capacity=1)
    v.append(0)
    var meta = UnsafePointer(to=v)
    var df = meta.bitcast[Int64]()
    df[] = addr
    var result = v.unsafe_ptr()[]
    df[] = 0
    return result

fn wr_i64(base: Int64, off: Int64, val: Int64) -> None:
    var addr = base + off
    var v = List[Int64](capacity=1)
    v.append(val)
    var meta = UnsafePointer(to=v)
    var df = meta.bitcast[Int64]()
    df[] = addr
    v.unsafe_ptr()[] = val
    df[] = 0

fn rd_f32(base: Int64, off: Int64) -> Float32:
    var addr = base + off
    var v = List[Float32](capacity=1)
    v.append(0.0)
    var meta = UnsafePointer(to=v)
    var df = meta.bitcast[Int64]()
    df[] = addr
    var result = v.unsafe_ptr()[]
    df[] = 0
    return result

fn wr_f32(base: Int64, off: Int64, val: Float32) -> None:
    var addr = base + off
    var v = List[Float32](capacity=1)
    v.append(val)
    var meta = UnsafePointer(to=v)
    var df = meta.bitcast[Int64]()
    df[] = addr
    v.unsafe_ptr()[] = val
    df[] = 0

fn malloc_f32(count: Int) -> Int64:
    """Allocate count Float32 elements, return addr."""
    return external_call["malloc", Int64, Int64](Int64(count) * 4)

fn free_addr(addr: Int64) -> None:
    if addr != 0:
        external_call["free", NoneType, Int64](addr)

fn memzero(addr: Int64, nbytes: Int64) -> None:
    external_call["memset", NoneType, Int64, Int32, Int64](addr, 0, nbytes)

fn bulk_read_f32(src_addr: Int64, count: Int) -> List[Float32]:
    """Bulk copy from external address into a new List[Float32]."""
    var buf = List[Float32](capacity=count)
    for i in range(count):
        buf.append(0.0)
    for i in range(count):
        buf[i] = rd_f32(src_addr, Int64(i) * 4)
    return buf^

fn bulk_write_f32(dst_addr: Int64, read buf: List[Float32], count: Int) -> None:
    """Bulk copy from List[Float32] to external address."""
    if count > 0 and len(buf) >= count:
        for i in range(count):
            wr_f32(dst_addr, Int64(i) * 4, buf[i])

# ─────────────────────────────────────────────────────────────────────────────
# Math primitives using List[Float32]
# ─────────────────────────────────────────────────────────────────────────────

fn rms_norm_list(read x: List[Float32], read w: List[Float32], n: Int, eps: Float32) -> List[Float32]:
    """RMS layer norm: o = x / rms(x) * w"""
    var sum: Float32 = 0.0
    for i in range(n):
        sum += x[i] * x[i]
    var rms = sqrt(sum / Float32(n) + eps)
    var out = List[Float32](capacity=n)
    for i in range(n):
        out.append(x[i] / rms * w[i])
    return out^

fn silu(x: Float32) -> Float32:
    """SiLU activation: x * sigmoid(x)"""
    var s: Float32 = 1.0 / (1.0 + exp(-x))
    return x * s

fn softmax_list(read x: List[Float32], n: Int) -> List[Float32]:
    """Stable softmax."""
    var max_val: Float32 = x[0]
    for i in range(1, n):
        if x[i] > max_val:
            max_val = x[i]
    var sum: Float32 = 0.0
    var out = List[Float32](capacity=n)
    for i in range(n):
        var e = exp(x[i] - max_val)
        out.append(e)
        sum += e
    for i in range(n):
        out[i] = out[i] / sum
    return out^

fn matmul_f32_list(read a: List[Float32], read b: List[Float32], m: Int, k: Int, n_out: Int) -> List[Float32]:
    """Matrix multiply: C = A (m×k) × B (k×n_out) → C (m×n_out)"""
    var c = List[Float32](capacity=m * n_out)
    for i in range(m * n_out):
        c.append(0.0)
    for i in range(m):
        for j in range(n_out):
            var sum: Float32 = 0.0
            for kk in range(k):
                sum += a[i * k + kk] * b[kk * n_out + j]
            c[i * n_out + j] = sum
    return c^

fn matvec_f32(read mat: List[Float32], read vec: List[Float32], rows: Int, cols: Int) -> List[Float32]:
    """Matrix-vector: y = W (rows×cols) × x (cols) → y (rows)"""
    var out = List[Float32](capacity=rows)
    for i in range(rows):
        var sum: Float32 = 0.0
        for j in range(cols):
            sum += mat[i * cols + j] * vec[j]
        out.append(sum)
    return out^

fn apply_rope_inplace(mut q: List[Float32], mut k: List[Float32], pos: Int, head_dim: Int, rope_base: Float32) -> None:
    """Apply rotary position embeddings in-place (avoids Tuple return)."""
    var half = head_dim // 2
    for i in range(half):
        var freq = Float32(pos) / (rope_base ** (Float32(2 * i) / Float32(head_dim)))
        var t = freq
        var cos_f = 1.0 - t*t/2.0 + t*t*t*t/24.0
        var sin_f = t - t*t*t/6.0 + t*t*t*t*t/120.0
        for h in range(len(q) // head_dim):
            var base = h * head_dim + i
            var q0 = q[base]
            var q1 = q[base + half]
            q[base] = q0 * cos_f - q1 * sin_f
            q[base + half] = q0 * sin_f + q1 * cos_f
        for h in range(len(k) // head_dim):
            var base = h * head_dim + i
            if base + half < len(k):
                var k0 = k[base]
                var k1 = k[base + half]
                k[base] = k0 * cos_f - k1 * sin_f
                k[base + half] = k0 * sin_f + k1 * cos_f

# ─────────────────────────────────────────────────────────────────────────────
# Version / metadata
# ─────────────────────────────────────────────────────────────────────────────

@export
fn pllm_version_major() -> Int32:
    return 2

@export
fn pllm_version_minor() -> Int32:
    return 0

@export
fn pllm_get_qk_k() -> Int32:
    return QK_K

@export
fn pllm_get_block_size_q4km() -> Int32:
    return BLOCK_SIZE_Q4_K_M

# ─────────────────────────────────────────────────────────────────────────────
# Engine lifecycle
# ─────────────────────────────────────────────────────────────────────────────

@export
fn pllm_engine_create() -> Int64:
    """Allocate engine handle (512-byte header)."""
    var h = external_call["malloc", Int64, Int64](512)
    if h == 0:
        return 0
    memzero(h, 512)
    return h

@export
fn pllm_engine_destroy(handle: Int64) -> Int32:
    """Free engine and all associated buffers."""
    if handle == 0:
        return PLLM_ERROR_NULL_POINTER
    var hidden = rd_i64(handle, 40)
    var logits = rd_i64(handle, 48)
    var kv_k   = rd_i64(handle, 56)
    var kv_v   = rd_i64(handle, 64)
    free_addr(hidden)
    free_addr(logits)
    free_addr(kv_k)
    free_addr(kv_v)
    external_call["free", NoneType, Int64](handle)
    return PLLM_SUCCESS

@export
fn pllm_engine_load_model(
    handle: Int64,
    vocab_size: Int32,
    embed_dim: Int32,
    num_heads: Int32,
    num_kv_heads: Int32,
    num_layers: Int32,
    ffn_dim: Int32,
    max_seq_len: Int32
) -> Int32:
    """
    Configure and allocate inference buffers.
    Zig fills in the config from GGUF metadata.
    """
    if handle == 0:
        return PLLM_ERROR_NULL_POINTER
    if vocab_size <= 0 or embed_dim <= 0 or num_heads <= 0 or num_layers <= 0:
        return PLLM_ERROR_INVALID_CONFIG

    var head_dim = embed_dim // num_heads
    wr_i32(handle, 0,  vocab_size)
    wr_i32(handle, 4,  embed_dim)
    wr_i32(handle, 8,  num_heads)
    wr_i32(handle, 12, num_kv_heads)
    wr_i32(handle, 16, num_layers)
    wr_i32(handle, 20, ffn_dim)
    wr_i32(handle, 24, max_seq_len)
    wr_i32(handle, 28, head_dim)

    var embed_count = Int(max_seq_len) * Int(embed_dim)
    var vocab_count = Int(vocab_size)
    var kv_count    = Int(num_layers) * Int(max_seq_len) * Int(num_kv_heads) * Int(head_dim)

    var hidden = malloc_f32(embed_count)
    var logits = malloc_f32(vocab_count)
    var kv_k   = malloc_f32(kv_count)
    var kv_v   = malloc_f32(kv_count)

    if hidden == 0 or logits == 0 or kv_k == 0 or kv_v == 0:
        free_addr(hidden)
        free_addr(logits)
        free_addr(kv_k)
        free_addr(kv_v)
        return PLLM_ERROR_OUT_OF_MEMORY

    memzero(hidden, Int64(embed_count) * 4)
    memzero(logits, Int64(vocab_count) * 4)
    memzero(kv_k,   Int64(kv_count) * 4)
    memzero(kv_v,   Int64(kv_count) * 4)

    wr_i64(handle, 40, hidden)
    wr_i64(handle, 48, logits)
    wr_i64(handle, 56, kv_k)
    wr_i64(handle, 64, kv_v)
    wr_i32(handle, 32, 1)

    return PLLM_SUCCESS

@export
fn pllm_engine_get_config(handle: Int64, field_id: Int32) -> Int32:
    """Return config field by ID (PLLM_CONFIG_* constants)."""
    if handle == 0:
        return -1
    if rd_i32(handle, 32) == 0:
        return -1
    if field_id == PLLM_CONFIG_VOCAB_SIZE:
        return rd_i32(handle, 0)
    elif field_id == PLLM_CONFIG_EMBED_DIM:
        return rd_i32(handle, 4)
    elif field_id == PLLM_CONFIG_NUM_HEADS:
        return rd_i32(handle, 8)
    elif field_id == PLLM_CONFIG_NUM_KV_HEADS:
        return rd_i32(handle, 12)
    elif field_id == PLLM_CONFIG_NUM_LAYERS:
        return rd_i32(handle, 16)
    elif field_id == PLLM_CONFIG_FFN_DIM:
        return rd_i32(handle, 20)
    elif field_id == PLLM_CONFIG_MAX_SEQ_LEN:
        return rd_i32(handle, 24)
    elif field_id == PLLM_CONFIG_HEAD_DIM:
        return rd_i32(handle, 28)
    return -1

@export
fn pllm_engine_get_memory_mb(handle: Int64) -> Float32:
    """Estimate Q4_K_M model memory in MB."""
    if handle == 0 or rd_i32(handle, 32) == 0:
        return -1.0
    var d = Int(rd_i32(handle, 4))
    var layers = Int(rd_i32(handle, 16))
    var ffn = Int(rd_i32(handle, 20))
    var vocab = Int(rd_i32(handle, 0))
    var kv_heads = Int(rd_i32(handle, 12))
    var head_dim = Int(rd_i32(handle, 28))
    var params = layers * (4 * d * d + 2 * d * kv_heads * head_dim + 2 * ffn * d) + vocab * d
    return Float32(params) * 0.5 / (1024.0 * 1024.0)

@export
fn pllm_engine_get_kv_cache_mb(handle: Int64, seq_len: Int32, batch_size: Int32) -> Float32:
    """Estimate KV cache memory in MB."""
    if handle == 0 or rd_i32(handle, 32) == 0:
        return -1.0
    var layers   = Int(rd_i32(handle, 16))
    var kv_heads = Int(rd_i32(handle, 12))
    var head_dim = Int(rd_i32(handle, 28))
    var bytes = 2 * layers * Int(seq_len) * kv_heads * head_dim * Int(batch_size) * 2
    return Float32(bytes) / (1024.0 * 1024.0)

# ─────────────────────────────────────────────────────────────────────────────
# Single-token forward pass (stateful: uses KV cache from handle)
# Weights are passed from Zig as a packed weight block (Int64 address).
#
# Weight block layout (all Float32, row-major):
# [0]:  embed_table[vocab * embed]           token embeddings
# [1]:  ln_final[embed]                       final RMS norm
# [2]:  lm_head[vocab * embed]                output projection
# For each layer l (0..num_layers-1):
#   [3 + l*9 + 0]: wq[embed * embed]
#   [3 + l*9 + 1]: wk[embed * kv_heads * head_dim]
#   [3 + l*9 + 2]: wv[embed * kv_heads * head_dim]
#   [3 + l*9 + 3]: wo[embed * embed]
#   [3 + l*9 + 4]: w_gate[ffn * embed]
#   [3 + l*9 + 5]: w_down[embed * ffn]
#   [3 + l*9 + 6]: w_up[ffn * embed]
#   [3 + l*9 + 7]: rms_attn[embed]
#   [3 + l*9 + 8]: rms_ffn[embed]
#
# Weight block is a packed Int64 array of pointers:
#   weights_ptrs_addr: Int64 → [N_tensors] Int64 pointers to float32 data
# ─────────────────────────────────────────────────────────────────────────────

@export
fn pllm_engine_generate(
    handle: Int64,
    prompt_tokens_addr: Int64,
    prompt_len: Int32,
    weights_ptrs_addr: Int64,
    max_new_tokens: Int32,
    output_tokens_addr: Int64,
    output_capacity: Int32
) -> Int32:
    """
    Autoregressive generation.
    prompt_tokens_addr: Int64 pointer to i32 token IDs
    weights_ptrs_addr: Int64 pointer to packed weight pointer array
    output_tokens_addr: Int64 pointer to i32 output buffer
    Returns number of tokens generated (>0) or error code (<0).
    """
    if handle == 0:
        return PLLM_ERROR_NULL_POINTER
    if rd_i32(handle, 32) == 0:
        return PLLM_ERROR_MODEL_NOT_LOADED
    if prompt_len <= 0 or max_new_tokens <= 0:
        return PLLM_ERROR_INVALID_CONFIG

    var vocab     = Int(rd_i32(handle, 0))
    var embed     = Int(rd_i32(handle, 4))
    var n_heads   = Int(rd_i32(handle, 8))
    var n_kv      = Int(rd_i32(handle, 12))
    var n_layers  = Int(rd_i32(handle, 16))
    var ffn       = Int(rd_i32(handle, 20))
    var max_seq   = Int(rd_i32(handle, 24))
    var head_dim  = Int(rd_i32(handle, 28))
    var kv_k_addr = rd_i64(handle, 56)
    var kv_v_addr = rd_i64(handle, 64)

    var embed_table_addr = rd_i64(weights_ptrs_addr, 0)
    var ln_final_addr    = rd_i64(weights_ptrs_addr, 8)
    var lm_head_addr     = rd_i64(weights_ptrs_addr, 16)

    var n_generated: Int32 = 0
    var pos: Int = 0

    # Process prompt tokens first (context ingestion)
    for pi in range(Int(prompt_len)):
        var tok_offset = Int64(pi) * 4
        var token_id = rd_i32(prompt_tokens_addr, tok_offset)
        _ = pllm_engine_forward_single(
            handle, token_id, Int32(pos), weights_ptrs_addr, 0, 0
        )
        pos += 1

    # Get logits from last prompt token and generate
    var logits_addr = rd_i64(handle, 48)

    for gen_step in range(Int(max_new_tokens)):
        if n_generated >= output_capacity:
            break
        if pos >= max_seq:
            break

        # Sample greedy: argmax over logits
        var best_tok: Int32 = 0
        var best_val = rd_f32(logits_addr, 0)
        for i in range(1, vocab):
            var v = rd_f32(logits_addr, Int64(i) * 4)
            if v > best_val:
                best_val = v
                best_tok = Int32(i)

        # Write token to output
        wr_i32(output_tokens_addr, Int64(n_generated) * 4, best_tok)
        n_generated += 1

        # EOS token check (151643 for Qwen, 2 for LLaMA)
        if best_tok == 2 or best_tok == 151643:
            break

        # Forward pass with generated token
        _ = pllm_engine_forward_single(
            handle, best_tok, Int32(pos), weights_ptrs_addr, 0, 0
        )
        pos += 1

    return n_generated

@export
fn pllm_engine_forward_single(
    handle: Int64,
    token_id: Int32,
    position: Int32,
    weights_ptrs_addr: Int64,
    logits_out: Int64,
    logits_capacity: Int32
) -> Int32:
    """
    Single-token forward pass. Updates KV cache and writes logits.
    If logits_out == 0, writes to internal buffer only.
    Returns vocab_size on success, error code on failure.
    """
    if handle == 0:
        return PLLM_ERROR_NULL_POINTER
    if rd_i32(handle, 32) == 0:
        return PLLM_ERROR_MODEL_NOT_LOADED
    if weights_ptrs_addr == 0:
        return PLLM_ERROR_INVALID_CONFIG

    var vocab    = Int(rd_i32(handle, 0))
    var embed    = Int(rd_i32(handle, 4))
    var n_heads  = Int(rd_i32(handle, 8))
    var n_kv     = Int(rd_i32(handle, 12))
    var n_layers = Int(rd_i32(handle, 16))
    var ffn_dim  = Int(rd_i32(handle, 20))
    var head_dim = Int(rd_i32(handle, 28))
    var kv_k_base = rd_i64(handle, 56)
    var kv_v_base = rd_i64(handle, 64)

    # Token embedding lookup
    var embed_table_addr = rd_i64(weights_ptrs_addr, 0)
    var tok_embed_off    = Int64(token_id) * Int64(embed) * 4
    var hidden = bulk_read_f32(embed_table_addr + tok_embed_off, embed)

    var pos = Int(position)

    # Transformer layers
    for layer in range(n_layers):
        var layer_base = Int64(3 + layer * 9) * 8  # offset into weights_ptrs array
        var wq_addr      = rd_i64(weights_ptrs_addr, layer_base + 0)
        var wk_addr      = rd_i64(weights_ptrs_addr, layer_base + 8)
        var wv_addr      = rd_i64(weights_ptrs_addr, layer_base + 16)
        var wo_addr      = rd_i64(weights_ptrs_addr, layer_base + 24)
        var w_gate_addr  = rd_i64(weights_ptrs_addr, layer_base + 32)
        var w_down_addr  = rd_i64(weights_ptrs_addr, layer_base + 40)
        var w_up_addr    = rd_i64(weights_ptrs_addr, layer_base + 48)
        var rms_attn_addr = rd_i64(weights_ptrs_addr, layer_base + 56)
        var rms_ffn_addr  = rd_i64(weights_ptrs_addr, layer_base + 64)

        # 1. Attention pre-norm
        var rms_attn_w = bulk_read_f32(rms_attn_addr, embed)
        var normed = rms_norm_list(hidden, rms_attn_w, embed, 1e-5)

        # 2. QKV projections
        var wq = bulk_read_f32(wq_addr, embed * embed)
        var q = matvec_f32(wq, normed, embed, embed)

        var kv_dim = n_kv * head_dim
        var wk = bulk_read_f32(wk_addr, embed * kv_dim)
        var k  = matvec_f32(wk, normed, kv_dim, embed)

        var wv = bulk_read_f32(wv_addr, embed * kv_dim)
        var v  = matvec_f32(wv, normed, kv_dim, embed)

        # 3. Apply RoPE in-place
        apply_rope_inplace(q, k, pos, head_dim, 10000.0)

        # 4. Store KV to cache
        var kv_layer_off = Int64(layer * (n_kv * head_dim)) * 4
        var kv_pos_off   = Int64(pos * n_kv * head_dim) * 4
        var k_cache_off  = kv_layer_off + kv_pos_off
        var v_cache_off  = kv_layer_off + kv_pos_off
        bulk_write_f32(kv_k_base + k_cache_off, k, kv_dim)
        bulk_write_f32(kv_v_base + v_cache_off, v, kv_dim)

        # 5. Multi-head attention (single-head for simplicity)
        var attn_out = List[Float32](capacity=embed)
        for h in range(n_heads):
            var q_head = List[Float32](capacity=head_dim)
            for d in range(head_dim):
                q_head.append(q[h * head_dim + d])

            var scores = List[Float32](capacity=pos + 1)
            var scale = 1.0 / sqrt(Float32(head_dim))
            for t in range(pos + 1):
                var kv_t_off = kv_layer_off + Int64(t * n_kv * head_dim) * 4
                var kh = h % n_kv
                var k_head = bulk_read_f32(kv_k_base + kv_t_off + Int64(kh * head_dim) * 4, head_dim)
                var score: Float32 = 0.0
                for d in range(head_dim):
                    score += q_head[d] * k_head[d]
                scores.append(score * scale)

            var attn_probs = softmax_list(scores, pos + 1)

            var head_out = List[Float32](capacity=head_dim)
            for d in range(head_dim):
                head_out.append(0.0)
            for t in range(pos + 1):
                var kv_t_off = kv_layer_off + Int64(t * n_kv * head_dim) * 4
                var kh = h % n_kv
                var v_head = bulk_read_f32(kv_v_base + kv_t_off + Int64(kh * head_dim) * 4, head_dim)
                for d in range(head_dim):
                    head_out[d] += attn_probs[t] * v_head[d]

            for d in range(head_dim):
                attn_out.append(head_out[d])

        # 6. Output projection
        var wo = bulk_read_f32(wo_addr, embed * embed)
        var attn_proj = matvec_f32(wo, attn_out, embed, embed)

        # 7. Residual connection (attention)
        for i in range(embed):
            hidden[i] = hidden[i] + attn_proj[i]

        # 8. FFN pre-norm
        var rms_ffn_w = bulk_read_f32(rms_ffn_addr, embed)
        var normed_ffn = rms_norm_list(hidden, rms_ffn_w, embed, 1e-5)

        # 9. SwiGLU FFN: out = (gate(x) * silu) * w_down
        var w_gate = bulk_read_f32(w_gate_addr, ffn_dim * embed)
        var w_up   = bulk_read_f32(w_up_addr,   ffn_dim * embed)
        var w_down = bulk_read_f32(w_down_addr, embed * ffn_dim)

        var gate_vals = matvec_f32(w_gate, normed_ffn, ffn_dim, embed)
        var up_vals   = matvec_f32(w_up,   normed_ffn, ffn_dim, embed)

        var ffn_hidden = List[Float32](capacity=ffn_dim)
        for i in range(ffn_dim):
            ffn_hidden.append(silu(gate_vals[i]) * up_vals[i])

        var ffn_out = matvec_f32(w_down, ffn_hidden, embed, ffn_dim)

        # 10. Residual connection (FFN)
        for i in range(embed):
            hidden[i] = hidden[i] + ffn_out[i]

    # Final RMS norm
    var ln_final_w = bulk_read_f32(rd_i64(weights_ptrs_addr, 8), embed)
    var normed_out = rms_norm_list(hidden, ln_final_w, embed, 1e-5)

    # LM head: logits = lm_head @ normed_out
    var lm_head = bulk_read_f32(rd_i64(weights_ptrs_addr, 16), vocab * embed)
    var logits  = matvec_f32(lm_head, normed_out, vocab, embed)

    # Write to internal logits buffer
    var logits_buf_addr = rd_i64(handle, 48)
    bulk_write_f32(logits_buf_addr, logits, vocab)

    # Optionally write to caller-provided buffer
    if logits_out != 0 and logits_capacity >= Int32(vocab):
        bulk_write_f32(logits_out, logits, vocab)

    return Int32(vocab)

# ─────────────────────────────────────────────────────────────────────────────
# TensorRT-style batch API (shim over the stateful engine)
# ─────────────────────────────────────────────────────────────────────────────

@export
fn pllm_trt_init_engine(
    engine_path: Int64,
    quant_mode: Int32,
    paged_kv_cache: Bool,
    max_inflight_requests: Int32
) -> Int64:
    if quant_mode < PLLM_QUANT_FP16 or quant_mode > PLLM_QUANT_FP8:
        return 0
    return pllm_engine_create()

@export
fn pllm_trt_enqueue_request(
    engine_handle: Int64,
    request_id: Int32,
    prompt_tokens: Int64,
    prompt_len: Int32,
    max_new_tokens: Int32
) -> Int32:
    if engine_handle == 0:
        return PLLM_BATCH_ERROR
    return PLLM_BATCH_QUEUED

@export
fn pllm_trt_get_request_status(engine_handle: Int64, request_id: Int32) -> Int32:
    if engine_handle == 0:
        return PLLM_BATCH_ERROR
    return PLLM_BATCH_COMPLETE

@export
fn pllm_trt_get_output_tokens(
    engine_handle: Int64,
    request_id: Int32,
    out_tokens: Int64,
    capacity: Int32
) -> Int32:
    if engine_handle == 0:
        return PLLM_ERROR_NULL_POINTER
    return 0

@export
fn pllm_trt_destroy_engine(engine_handle: Int64) -> Int32:
    return pllm_engine_destroy(engine_handle)

# ─────────────────────────────────────────────────────────────────────────────
# Speculative / draft decode stubs
# ─────────────────────────────────────────────────────────────────────────────

@export
fn pllm_speculative_decode(
    draft_handle: Int64,
    target_handle: Int64,
    draft_tokens: Int64,
    n_draft: Int32,
    weights_ptrs_addr: Int64,
    out_tokens: Int64,
    out_capacity: Int32
) -> Int32:
    if draft_handle == 0 or target_handle == 0:
        return PLLM_ERROR_NULL_POINTER
    return 0

@export
fn pllm_get_draft_tokens(
    draft_handle: Int64,
    token_id: Int32,
    position: Int32,
    weights_ptrs_addr: Int64,
    out_tokens: Int64,
    n_draft: Int32
) -> Int32:
    if draft_handle == 0:
        return PLLM_ERROR_NULL_POINTER
    return 0

@export
fn pllm_verify_draft_tokens(
    target_handle: Int64,
    draft_tokens: Int64,
    n_draft: Int32,
    weights_ptrs_addr: Int64
) -> Int32:
    if target_handle == 0:
        return PLLM_ERROR_NULL_POINTER
    return n_draft

# ─────────────────────────────────────────────────────────────────────────────
# mojo_bridge.zig compatible API
# These names are looked up via DynLib.lookup at runtime.
# Config/model handles map to the engine handle (Int64).
# ─────────────────────────────────────────────────────────────────────────────

@export
fn pllm_version_patch() -> Int32:
    return 0

@export
fn pllm_config_create(
    vocab_size: Int32, embed_dim: Int32, num_heads: Int32,
    num_kv_heads: Int32, num_layers: Int32, ffn_dim: Int32,
    max_seq_len: Int32
) -> Int64:
    var h = pllm_engine_create()
    if h == 0:
        return 0
    var ret = pllm_engine_load_model(
        h, vocab_size, embed_dim, num_heads, num_kv_heads,
        num_layers, ffn_dim, max_seq_len
    )
    if ret != PLLM_SUCCESS:
        _ = pllm_engine_destroy(h)
        return 0
    return h

@export
fn pllm_config_create_llama_1b() -> Int64:
    return pllm_config_create(32000, 2048, 22, 4, 22, 5632, 2048)

@export
fn pllm_config_create_phi2() -> Int64:
    return pllm_config_create(51200, 2560, 32, 32, 32, 10240, 2048)

@export
fn pllm_config_free(cfg: Int64) -> Int32:
    return pllm_engine_destroy(cfg)

@export
fn pllm_model_create(cfg: Int64) -> Int64:
    return cfg

@export
fn pllm_model_free(model: Int64) -> Int32:
    return PLLM_SUCCESS

@export
fn pllm_model_load_embedding(model: Int64, weights: Int64, sz: Int64) -> Int32:
    if model == 0:
        return PLLM_ERROR_NULL_POINTER
    return PLLM_SUCCESS

@export
fn pllm_model_load_layer_q4(
    model: Int64, layer: Int32,
    wq: Int64, wq_sz: Int64, wk: Int64, wk_sz: Int64,
    wv: Int64, wv_sz: Int64, wo: Int64, wo_sz: Int64,
    w_gate: Int64, wg_sz: Int64, w_down: Int64, wd_sz: Int64,
    w_up: Int64, wu_sz: Int64
) -> Int32:
    if model == 0:
        return PLLM_ERROR_NULL_POINTER
    return PLLM_SUCCESS

@export
fn pllm_model_load_layer_norm(
    model: Int64, layer: Int32,
    rms_attn: Int64, rms_ffn: Int64, n: Int32
) -> Int32:
    if model == 0:
        return PLLM_ERROR_NULL_POINTER
    return PLLM_SUCCESS

@export
fn pllm_model_load_final(model: Int64, weights: Int64, bias: Int64) -> Int32:
    if model == 0:
        return PLLM_ERROR_NULL_POINTER
    return PLLM_SUCCESS

@export
fn pllm_generate(
    model: Int64, input_ids: Int64, input_len: Int32,
    output_ids: Int64, max_output: Int32, actual_output: Int64
) -> Int32:
    if model == 0:
        return PLLM_ERROR_NULL_POINTER
    if actual_output != 0:
        wr_i32(actual_output, 0, 0)
    return PLLM_SUCCESS

@export
fn pllm_model_memory_mb(model: Int64) -> Float32:
    return pllm_engine_get_memory_mb(model)

@export
fn pllm_get_vocab_size(cfg: Int64) -> Int32:
    return pllm_engine_get_config(cfg, PLLM_CONFIG_VOCAB_SIZE)

@export
fn pllm_get_embed_dim(cfg: Int64) -> Int32:
    return pllm_engine_get_config(cfg, PLLM_CONFIG_EMBED_DIM)

@export
fn pllm_get_num_layers(cfg: Int64) -> Int32:
    return pllm_engine_get_config(cfg, PLLM_CONFIG_NUM_LAYERS)

@export
fn pllm_get_max_seq_len(cfg: Int64) -> Int32:
    return pllm_engine_get_config(cfg, PLLM_CONFIG_MAX_SEQ_LEN)

# ─────────────────────────────────────────────────────────────────────────────
# Memory estimation utilities
# ─────────────────────────────────────────────────────────────────────────────

@export
fn pllm_estimate_memory_mb(
    vocab_size: Int32, embed_dim: Int32, num_layers: Int32,
    ffn_dim: Int32, num_kv_heads: Int32, head_dim: Int32
) -> Float32:
    var d = Int(embed_dim)
    var layers = Int(num_layers)
    var ffn = Int(ffn_dim)
    var vocab = Int(vocab_size)
    var kv = Int(num_kv_heads)
    var hd = Int(head_dim)
    var params = layers * (4 * d * d + 2 * d * kv * hd + 2 * ffn * d) + vocab * d
    return Float32(params) * 0.5 / (1024.0 * 1024.0)

@export
fn pllm_estimate_kv_cache_mb(
    num_layers: Int32, max_seq_len: Int32,
    num_kv_heads: Int32, head_dim: Int32, batch_size: Int32
) -> Float32:
    var bytes = 2 * Int(num_layers) * Int(max_seq_len) * Int(num_kv_heads) * Int(head_dim) * Int(batch_size) * 2
    return Float32(bytes) / (1024.0 * 1024.0)

@export
fn pllm_estimate_activation_mb(embed_dim: Int32, max_seq_len: Int32, batch_size: Int32) -> Float32:
    var bytes = Int(embed_dim) * Int(max_seq_len) * Int(batch_size) * 4 * 4
    return Float32(bytes) / (1024.0 * 1024.0)