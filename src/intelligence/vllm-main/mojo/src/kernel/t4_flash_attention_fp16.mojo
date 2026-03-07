"""
Flash Attention V2 Implementation for T4 Tensor Cores (FP16)

Implements memory-efficient attention using FP16 Tensor Cores.
Optimized for T4 GPU (65 TFLOPS FP16, 64KB shared memory per SM).

Key Features:
- Online softmax (numerically stable)
- Tiled computation (fits in shared memory)
- Causal masking support
- Grouped Query Attention (GQA) for Nemotron-Nano-8B

Reference: FlashAttention-2 (Dao et al., 2023)
"""

from memory import LegacyUnsafePointer
comptime UnsafePointer = LegacyUnsafePointer[mut=True, ...]
from memory.unsafe_pointer import alloc
from algorithm.functional import vectorize
from math import exp, sqrt, log
from sys.info import simd_width_of

from .t4_tensor_core import (
    WMMA_M, WMMA_N, WMMA_K,
    WMMAFragmentA_FP16, WMMAFragmentB_FP16, WMMAFragmentC_FP32,
    wmma_mma_fp16, align_up, TC_ALIGNMENT
)

# =============================================================================
# Flash Attention Constants (T4 Optimized)
# =============================================================================

# Block sizes tuned for T4 (64KB shared memory)
# Q block: [Br, d] = [64, 128] = 16KB (FP16)
# K block: [Bc, d] = [64, 128] = 16KB (FP16)
# V block: [Bc, d] = [64, 128] = 16KB (FP16)
# Total: ~48KB, leaves room for accumulator and softmax state
comptime BLOCK_SIZE_Q: Int = 64      # Br: rows of Q to process
comptime BLOCK_SIZE_KV: Int = 64     # Bc: rows of K/V to process
comptime HEAD_DIM: Int = 128         # d: head dimension (Nemotron-Nano-8B)

# SIMD width
comptime SIMD_WIDTH = simd_width_of[DType.float32]()

# Numerical stability
comptime NEG_INF: Float32 = -1e9
comptime LOG_2: Float32 = 0.693147180559945


# =============================================================================
# Softmax State (Online Algorithm)
# =============================================================================

struct SoftmaxState:
    """
    Online softmax state for stable attention computation.
    
    Tracks:
    - m: running maximum of scores (for numerical stability)
    - l: running sum of exp(scores - m)
    """
    var m: UnsafePointer[Float32]   # [Br] max scores per query row
    var l: UnsafePointer[Float32]   # [Br] sum of exp per query row
    var block_size: Int
    
    fn __init__(out self, block_size: Int):
        self.block_size = block_size
        self.m = alloc[Float32](block_size)
        self.l = alloc[Float32](block_size)
        self.reset()
    
    fn reset(mut self):
        """Reset softmax state for new attention computation."""
        for i in range(self.block_size):
            self.m[i] = NEG_INF
            self.l[i] = 0.0
    
    fn update(mut self, row: Int, new_max: Float32, new_sum: Float32):
        """Update softmax state with new block's contribution."""
        var old_m = self.m[row]
        var old_l = self.l[row]
        
        if new_max > old_m:
            # New max is larger, rescale old sum
            var scale = exp(old_m - new_max)
            self.m[row] = new_max
            self.l[row] = old_l * scale + new_sum
        else:
            # Old max is larger, scale new sum
            var scale = exp(new_max - old_m)
            self.l[row] = old_l + new_sum * scale
    
    fn deinit(mut self):
        self.m.free()
        self.l.free()


# =============================================================================
# Flash Attention V2 (Tiled, Online Softmax)
# =============================================================================

fn flash_attention_v2_fp16[
    o_out: MutOrigin,
    o_q: MutOrigin,
    o_k: MutOrigin,
    o_v: MutOrigin
](
    output: UnsafePointer[Float16, origin=o_out],   # [seq_len, head_dim]
    Q: UnsafePointer[Float16, origin=o_q],          # [seq_len, head_dim]
    K: UnsafePointer[Float16, origin=o_k],          # [kv_len, head_dim]
    V: UnsafePointer[Float16, origin=o_v],          # [kv_len, head_dim]
    seq_len: Int,                                    # Query sequence length
    kv_len: Int,                                     # Key/Value sequence length
    head_dim: Int,                                   # Typically 128
    scale: Float32,                                  # 1/sqrt(d)
    causal: Bool = True                             # Apply causal mask
):
    """
    Flash Attention V2 with FP16 Tensor Cores.
    
    Computes: output = softmax(Q @ K^T / sqrt(d)) @ V
    
    Memory-efficient: O(N) memory instead of O(N^2)
    Numerically stable: Uses online softmax
    
    For Nemotron-Nano-8B single head:
    - seq_len: up to 8192
    - head_dim: 128
    - GQA: handled by caller (multiple Q heads share K/V)
    """
    # Initialize output and softmax state
    var state = SoftmaxState(BLOCK_SIZE_Q)
    var acc = alloc[Float32](BLOCK_SIZE_Q * head_dim)  # FP32 accumulator
    
    # Process Q in blocks of BLOCK_SIZE_Q
    for q_start in range(0, seq_len, BLOCK_SIZE_Q):
        var q_end = min(q_start + BLOCK_SIZE_Q, seq_len)
        var q_block_size = q_end - q_start
        
        # Reset accumulator and softmax state for this Q block
        state.reset()
        for i in range(q_block_size * head_dim):
            acc[i] = 0.0
        
        # Determine KV range (causal: only attend to past)
        var kv_end_limit = kv_len if not causal else min(q_end, kv_len)
        
        # Process K/V in blocks of BLOCK_SIZE_KV
        for kv_start in range(0, kv_end_limit, BLOCK_SIZE_KV):
            var kv_block_end = min(kv_start + BLOCK_SIZE_KV, kv_end_limit)
            var kv_block_size = kv_block_end - kv_start
            
            # Compute attention scores for this block
            _compute_attention_block(
                acc, state,
                Q, K, V,
                q_start, q_block_size,
                kv_start, kv_block_size,
                head_dim, scale, causal
            )
        
        # Normalize output by softmax denominator and store
        _normalize_and_store(
            output, acc, state,
            q_start, q_block_size, head_dim
        )
    
    state.deinit()
    acc.free()


fn _compute_attention_block[
    o_q: MutOrigin, o_k: MutOrigin, o_v: MutOrigin
](
    acc: UnsafePointer[Float32],            # [Br, d] accumulator
    mut state: SoftmaxState,               # Softmax state
    Q: UnsafePointer[Float16, origin=o_q],   # Full Q matrix
    K: UnsafePointer[Float16, origin=o_k],   # Full K matrix
    V: UnsafePointer[Float16, origin=o_v],   # Full V matrix
    q_start: Int, q_size: Int,
    kv_start: Int, kv_size: Int,
    head_dim: Int,
    scale: Float32,
    causal: Bool
):
    """
    Compute attention scores and accumulate weighted V for one K/V block.
    
    Steps:
    1. Compute S = Q @ K^T (scores)
    2. Apply causal mask
    3. Update online softmax state
    4. Compute P = softmax(S)
    5. Accumulate P @ V into output
    """
    # Allocate scores buffer
    var scores = alloc[Float32](q_size * kv_size)
    
    # Step 1: Compute Q @ K^T scores
    _compute_qk_scores(
        scores,
        Q, K,
        q_start, q_size,
        kv_start, kv_size,
        head_dim, scale
    )
    
    # Step 2-5: Causal mask + online softmax update + accumulate P @ V.
    # Keep acc/l in the same normalization frame when running max shifts.
    for i in range(q_size):
        var q_pos = q_start + i
        var block_row_max = NEG_INF
        var has_valid = False
        
        for j in range(kv_size):
            var kv_pos = kv_start + j
            var score_idx = i * kv_size + j
            var score = scores[score_idx]
            
            # Causal mask: -inf for future positions
            if causal and kv_pos > q_pos:
                score = NEG_INF
                scores[score_idx] = score
                continue
            
            has_valid = True
            
            # Track block max for this row
            if score > block_row_max:
                block_row_max = score
        
        if not has_valid:
            continue
        
        var old_m = state.m[i]
        var old_l = state.l[i]
        var new_m = block_row_max if block_row_max > old_m else old_m
        var old_scale: Float32 = exp(old_m - new_m) if old_l > 0.0 else 0.0
        
        # Rescale prior accumulator contribution into new max frame
        for d in range(head_dim):
            acc[i * head_dim + d] *= old_scale
        
        var block_l: Float32 = 0.0
        for j in range(kv_size):
            var kv_pos = kv_start + j
            if causal and kv_pos > q_pos:
                continue
            
            var p = exp(scores[i * kv_size + j] - new_m)
            block_l += p
            
            var v_ptr = V + (kv_start + j) * head_dim
            for d in range(head_dim):
                acc[i * head_dim + d] += p * Float32(v_ptr[d])
        
        state.m[i] = new_m
        state.l[i] = old_l * old_scale + block_l
    
    scores.free()


fn _compute_qk_scores[o_q: MutOrigin, o_k: MutOrigin](
    scores: UnsafePointer[Float32],
    Q: UnsafePointer[Float16, origin=o_q],
    K: UnsafePointer[Float16, origin=o_k],
    q_start: Int, q_size: Int,
    kv_start: Int, kv_size: Int,
    head_dim: Int,
    scale: Float32
):
    """
    Compute scaled dot-product scores: S[i,j] = Q[q_start+i] · K[kv_start+j] * scale

    Bug 6 fix: replaces the scalar stub with a tiled WMMA implementation that
    uses T4 FP16 Tensor Cores (16x16x16 tiles) for the full-tile inner loop,
    and falls back to scalar FP32 accumulation only for boundary fragments.

    Tensor Core math:
        A[m, k]  = Q tile [WMMA_M × WMMA_K] loaded row-major (ld = head_dim)
        B[k, n]  = K tile [WMMA_K × WMMA_N] loaded col-major (ld = head_dim)
                   → effectively K^T, giving A·B = Q·K^T as desired
        C[m, n] += A·B  (FP32 accumulator)
    """
    var q_full_tiles  = q_size  // WMMA_M
    var kv_full_tiles = kv_size // WMMA_N
    var dk_full_tiles = head_dim // WMMA_K  # head_dim always multiple of 16 (64/96/128)

    # ── Full 16×16 WMMA tiles ──────────────────────────────────────────────────
    for qi in range(q_full_tiles):
        for ki in range(kv_full_tiles):
            var acc = WMMAFragmentC_FP32()
            acc.fill_zero()

            for dk in range(dk_full_tiles):
                var frag_a = WMMAFragmentA_FP16()
                var frag_b = WMMAFragmentB_FP16()

                # Q tile: rows [q_start+qi*M … +M), cols [dk*K … +K)
                var q_tile = Q + (q_start + qi * WMMA_M) * head_dim + dk * WMMA_K
                frag_a.load_row_major(q_tile, head_dim)

                # K tile: rows [kv_start+ki*N … +N), cols [dk*K … +K)
                # load_col_major with ld=head_dim gives fragment B = K^T tile
                var k_tile = K + (kv_start + ki * WMMA_N) * head_dim + dk * WMMA_K
                frag_b.load_col_major(k_tile, head_dim)

                wmma_mma_fp16(acc, frag_a, frag_b)

            # Write tile, applying scale
            var scores_tile = scores + qi * WMMA_M * kv_size + ki * WMMA_N
            for ti in range(WMMA_M):
                for tj in range(WMMA_N):
                    scores_tile[ti * kv_size + tj] = acc.data[ti * WMMA_N + tj] * scale

    # ── Scalar boundary: remainder q rows (below full-tile boundary) ──────────
    var q_rem_start = q_full_tiles * WMMA_M
    for i in range(q_rem_start, q_size):
        var q_ptr = Q + (q_start + i) * head_dim
        for j in range(kv_size):
            var k_ptr = K + (kv_start + j) * head_dim
            var dot: Float32 = 0.0
            for d in range(head_dim):
                dot += Float32(q_ptr[d]) * Float32(k_ptr[d])
            scores[i * kv_size + j] = dot * scale

    # ── Scalar boundary: remainder kv columns for the WMMA-covered q rows ─────
    var kv_rem_start = kv_full_tiles * WMMA_N
    for i in range(q_full_tiles * WMMA_M):
        var q_ptr = Q + (q_start + i) * head_dim
        for j in range(kv_rem_start, kv_size):
            var k_ptr = K + (kv_start + j) * head_dim
            var dot: Float32 = 0.0
            for d in range(head_dim):
                dot += Float32(q_ptr[d]) * Float32(k_ptr[d])
            scores[i * kv_size + j] = dot * scale


fn _normalize_and_store[o_out: MutOrigin](
    output: UnsafePointer[Float16, origin=o_out],
    acc: UnsafePointer[Float32],
    state: SoftmaxState,
    q_start: Int, q_size: Int,
    head_dim: Int
):
    """Normalize accumulated output by softmax denominator and convert to FP16."""
    for i in range(q_size):
        var l_inv = 1.0 / state.l[i] if state.l[i] > 0.0 else 0.0
        var out_ptr = output + (q_start + i) * head_dim
        
        for d in range(head_dim):
            var val = acc[i * head_dim + d] * l_inv
            out_ptr[d] = Float16(val)


# =============================================================================
# Grouped Query Attention (GQA)
# =============================================================================

fn gqa_flash_attention[
    o_out: MutOrigin,
    o_q: MutOrigin,
    o_k: MutOrigin,
    o_v: MutOrigin
](
    output: UnsafePointer[Float16, origin=o_out],   # [num_heads, seq_len, head_dim]
    Q: UnsafePointer[Float16, origin=o_q],          # [num_heads, seq_len, head_dim]
    K: UnsafePointer[Float16, origin=o_k],          # [num_kv_heads, kv_len, head_dim]
    V: UnsafePointer[Float16, origin=o_v],          # [num_kv_heads, kv_len, head_dim]
    num_heads: Int,                                  # Number of Q heads (32 for Nemotron)
    num_kv_heads: Int,                              # Number of KV heads (8 for Nemotron)
    seq_len: Int,
    kv_len: Int,
    head_dim: Int,
    causal: Bool = True
):
    """
    Grouped Query Attention with Flash Attention V2.
    
    For Nemotron-Nano-8B:
    - num_heads = 32 (Q heads)
    - num_kv_heads = 8 (KV heads)
    - Ratio = 4 (each KV head shared by 4 Q heads)
    """
    var scale = Float32(1.0 / sqrt(Float32(head_dim)))
    var heads_per_kv = num_heads // num_kv_heads
    
    # Process each query head
    for h in range(num_heads):
        var kv_h = h // heads_per_kv  # Map Q head to KV head
        
        var q_head = Q + h * seq_len * head_dim
        var k_head = K + kv_h * kv_len * head_dim
        var v_head = V + kv_h * kv_len * head_dim
        var out_head = output + h * seq_len * head_dim
        
        flash_attention_v2_fp16(
            out_head, q_head, k_head, v_head,
            seq_len, kv_len, head_dim, scale, causal
        )


# =============================================================================
# PagedKV Cache Integration
# =============================================================================

struct PagedKVBlock:
    """
    A single KV cache block for paged attention.
    
    Block size: 256 tokens (standard for vLLM/TensorRT-LLM)
    Memory per block: 256 * 128 * 2 * 2 = 128KB per head (K + V, FP16)
    """
    var keys: UnsafePointer[Float16]     # [block_size, head_dim]
    var values: UnsafePointer[Float16]   # [block_size, head_dim]
    var block_size: Int
    var head_dim: Int
    var num_tokens: Int                   # Actual tokens stored
    
    fn __init__(out self, block_size: Int, head_dim: Int):
        self.block_size = block_size
        self.head_dim = head_dim
        self.num_tokens = 0
        self.keys = alloc[Float16](block_size * head_dim)
        self.values = alloc[Float16](block_size * head_dim)
    
    fn is_full(self) -> Bool:
        return self.num_tokens >= self.block_size
    
    fn append[o_k: MutOrigin, o_v: MutOrigin](
        mut self,
        k: UnsafePointer[Float16, origin=o_k],
        v: UnsafePointer[Float16, origin=o_v]
    ) -> Bool:
        """Append a single K/V pair. Returns False if block is full."""
        if self.is_full():
            return False
        
        var offset = self.num_tokens * self.head_dim
        for d in range(self.head_dim):
            self.keys[offset + d] = k[d]
            self.values[offset + d] = v[d]
        self.num_tokens += 1
        return True
    
    fn deinit(mut self):
        self.keys.free()
        self.values.free()


comptime KV_BLOCK_SIZE: Int = 256

struct PagedKVCache:
    """
    Paged KV cache for efficient memory management.
    
    Features:
    - 256-token blocks
    - Dynamic allocation
    - Memory-efficient for variable-length sequences
    """
    var blocks: UnsafePointer[PagedKVBlock]
    var num_blocks: Int
    var max_blocks: Int
    var head_dim: Int
    var block_size: Int
    
    fn __init__(out self, max_tokens: Int, head_dim: Int):
        self.head_dim = head_dim
        self.block_size = KV_BLOCK_SIZE
        self.max_blocks = (max_tokens + self.block_size - 1) // self.block_size
        self.num_blocks = 0
        self.blocks = alloc[PagedKVBlock](self.max_blocks)
    
    fn allocate_block(mut self) -> Int:
        """Allocate a new block. Returns block index or -1 if full."""
        if self.num_blocks >= self.max_blocks:
            return -1
        var idx = self.num_blocks
        self.blocks[idx] = PagedKVBlock(self.block_size, self.head_dim)
        self.num_blocks += 1
        return idx
    
    fn total_tokens(self) -> Int:
        """Get total number of cached tokens."""
        var total = 0
        for i in range(self.num_blocks):
            total += self.blocks[i].num_tokens
        return total
    
    fn append[o_k: MutOrigin, o_v: MutOrigin](
        mut self,
        k: UnsafePointer[Float16, origin=o_k],
        v: UnsafePointer[Float16, origin=o_v]
    ) -> Bool:
        """Append one token's K/V vectors, allocating a new block if needed."""
        if self.num_blocks == 0 or self.blocks[self.num_blocks - 1].is_full():
            if self.allocate_block() < 0:
                return False
        return self.blocks[self.num_blocks - 1].append(k, v)
    
    fn deinit(mut self):
        for i in range(self.num_blocks):
            self.blocks[i].deinit()
        self.blocks.free()


# =============================================================================
# Performance Estimation
# =============================================================================

fn estimate_attention_flops(seq_len: Int, kv_len: Int, head_dim: Int, num_heads: Int) -> Int:
    """Estimate FLOPs for multi-head attention."""
    # QK^T: [seq, d] @ [d, kv] → 2 * seq * kv * d ops per head
    var qk_flops = 2 * seq_len * kv_len * head_dim * num_heads
    # Softmax: ~5 ops per element
    var softmax_flops = 5 * seq_len * kv_len * num_heads
    # P @ V: [seq, kv] @ [kv, d] → 2 * seq * kv * d ops per head
    var pv_flops = 2 * seq_len * kv_len * head_dim * num_heads
    return qk_flops + softmax_flops + pv_flops


fn estimate_attention_latency_us(seq_len: Int, kv_len: Int, head_dim: Int, num_heads: Int) -> Float32:
    """Estimate attention latency on T4 (65 TFLOPS FP16)."""
    var flops = estimate_attention_flops(seq_len, kv_len, head_dim, num_heads)
    var tflops: Float32 = 50.0  # Practical T4 FP16 for attention (~75% efficiency)
    var latency_s = Float32(flops) / (tflops * 1e12)
    return latency_s * 1e6  # Microseconds
