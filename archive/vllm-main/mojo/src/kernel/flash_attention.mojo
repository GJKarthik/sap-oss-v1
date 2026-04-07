"""
FlashAttention - Memory-efficient attention with O(N) memory.

Implements tiled attention computation:
- Online softmax for numerical stability
- Blocked K/V access for memory efficiency
- No materialization of full attention matrix
- SIMD-optimized inner loops
"""

from memory import UnsafePointer, memcpy
from memory.unsafe_pointer import alloc
from sys.info import simd_width_of
from algorithm.functional import vectorize, parallelize
from math import sqrt, exp, log


comptime FloatType = DType.float32
comptime SIMD_WIDTH = simd_width_of[FloatType]()

# Supported compute/storage precision pairs
comptime F32 = DType.float32
comptime F16 = DType.float16
comptime BF16 = DType.bfloat16

# Block sizes for tiled attention
comptime BLOCK_M = 64  # Query block size
comptime BLOCK_N = 64  # Key/Value block size
comptime BLOCK_K = 64  # Head dimension block


# =============================================================================
# FlashAttention Structs
# =============================================================================

struct FlashAttentionConfig:
    """Configuration for FlashAttention kernel.

    Supports mixed-precision: `storage_dtype` controls memory layout
    (FP16/BF16 for lower bandwidth), while compute is always FP32 for
    numerical stability.
    """
    var block_m: Int
    var block_n: Int
    var causal: Bool
    var dropout: Float32
    var scale: Float32
    var num_warps: Int
    var storage_dtype: DType  # FP32, FP16, or BF16 for K/V storage

    fn __init__(
        out self,
        head_dim: Int,
        causal: Bool = True,
        dropout: Float32 = 0.0,
        storage_dtype: DType = DType.float32,
    ):
        self.block_m = BLOCK_M
        self.block_n = BLOCK_N
        self.causal = causal
        self.dropout = dropout
        self.scale = 1.0 / sqrt(Float32(head_dim))
        self.num_warps = 4
        self.storage_dtype = storage_dtype


struct OnlineSoftmax:
    """Online softmax for numerically stable computation."""
    var max_val: Float32
    var sum_exp: Float32
    
    fn __init__(out self):
        self.max_val = -Float32.MAX
        self.sum_exp = 0.0

    fn update(mut self, new_max: Float32, new_sum: Float32) -> None:
        """Update running softmax with new block statistics."""
        if new_max > self.max_val:
            # Rescale previous sum
            var scale = exp(self.max_val - new_max)
            self.sum_exp = self.sum_exp * scale + new_sum
            self.max_val = new_max
        else:
            # Add new sum with scaling
            var scale = exp(new_max - self.max_val)
            self.sum_exp += new_sum * scale
    
    fn finalize(self, x: Float32) -> Float32:
        """Apply final softmax normalization."""
        return exp(x - self.max_val) / self.sum_exp


# =============================================================================
# Mixed-Precision Load Helpers
# =============================================================================

fn load_f16_as_f32[width: Int](ptr: UnsafePointer[Scalar[F16]], offset: Int) -> SIMD[F32, width]:
    """Load FP16 values and widen to FP32 for compute."""
    var f16_vals = (ptr + offset).load[width=width]()
    return f16_vals.cast[F32]()


fn load_bf16_as_f32[width: Int](ptr: UnsafePointer[Scalar[BF16]], offset: Int) -> SIMD[F32, width]:
    """Load BF16 values and widen to FP32 for compute."""
    var bf16_vals = (ptr + offset).load[width=width]()
    return bf16_vals.cast[F32]()


fn cast_kv_block_f16[o_dst: MutOrigin, o_src: Origin](
    dst: UnsafePointer[Float32, origin=o_dst],
    src: UnsafePointer[Scalar[F16], origin=o_src],
    count: Int,
):
    """Cast a block of FP16 K/V data to FP32 for attention compute."""

    fn cast_lane[width: Int](i: Int) unified {mut}:
        var f16v = (src + i).load[width=width]()
        (dst + i).store[width=width](0, f16v.cast[F32]())

    vectorize[SIMD_WIDTH](count, cast_lane)


fn cast_kv_block_bf16[o_dst: MutOrigin, o_src: Origin](
    dst: UnsafePointer[Float32, origin=o_dst],
    src: UnsafePointer[Scalar[BF16], origin=o_src],
    count: Int,
):
    """Cast a block of BF16 K/V data to FP32 for attention compute."""

    fn cast_lane[width: Int](i: Int) unified {mut}:
        var bf16v = (src + i).load[width=width]()
        (dst + i).store[width=width](0, bf16v.cast[F32]())

    vectorize[SIMD_WIDTH](count, cast_lane)


fn store_f32_as_f16[o_dst: MutOrigin, o_src: Origin](
    dst: UnsafePointer[Scalar[F16], origin=o_dst],
    src: UnsafePointer[Float32, origin=o_src],
    count: Int,
):
    """Narrow FP32 results back to FP16 for storage."""

    fn narrow_lane[width: Int](i: Int) unified {mut}:
        var f32v = (src + i).load[width=width]()
        (dst + i).store[width=width](0, f32v.cast[F16]())

    vectorize[SIMD_WIDTH](count, narrow_lane)


fn store_f32_as_bf16[o_dst: MutOrigin, o_src: Origin](
    dst: UnsafePointer[Scalar[BF16], origin=o_dst],
    src: UnsafePointer[Float32, origin=o_src],
    count: Int,
):
    """Narrow FP32 results back to BF16 for storage."""

    fn narrow_lane[width: Int](i: Int) unified {mut}:
        var f32v = (src + i).load[width=width]()
        (dst + i).store[width=width](0, f32v.cast[BF16]())

    vectorize[SIMD_WIDTH](count, narrow_lane)


# =============================================================================
# FlashAttention Forward Pass
# =============================================================================

fn flash_attention_forward[o_q: Origin, o_k: Origin, o_v: Origin, o_o: MutOrigin](
    Q: UnsafePointer[Float32, origin=o_q],    # [batch, seq_q, num_heads, head_dim]
    K: UnsafePointer[Float32, origin=o_k],    # [batch, seq_kv, num_heads, head_dim]
    V: UnsafePointer[Float32, origin=o_v],    # [batch, seq_kv, num_heads, head_dim]
    O: UnsafePointer[Float32, origin=o_o],    # [batch, seq_q, num_heads, head_dim] output
    batch_size: Int,
    seq_q: Int,
    seq_kv: Int,
    num_heads: Int,
    head_dim: Int,
    config: FlashAttentionConfig,
):
    """
    Flash Attention forward pass with tiled computation.

    Memory complexity: O(N) instead of O(N²)
    Compute pattern: Process K,V in blocks, accumulate to output.
    Parallelized over batch × head dimension.
    """
    var scale = config.scale
    var block_m = config.block_m
    var block_n = config.block_n
    var total_work = batch_size * num_heads

    # Parallelize across batch × head
    @parameter
    fn process_batch_head(work_idx: Int):
        var b = work_idx // num_heads
        var h = work_idx % num_heads

        # Base offsets for this batch and head
        var q_base = b * seq_q * num_heads * head_dim + h * head_dim
        var k_base = b * seq_kv * num_heads * head_dim + h * head_dim
        var v_base = b * seq_kv * num_heads * head_dim + h * head_dim
        var o_base = b * seq_q * num_heads * head_dim + h * head_dim

        # Pre-allocate accumulators at max block size (hoisted out of loops)
        var O_acc = alloc[Float32](block_m * head_dim)
        var l_acc = alloc[Float32](block_m)
        var m_acc = alloc[Float32](block_m)
        var S = alloc[Float32](block_m * block_n)

        # Process query blocks
        for m_block in range(0, seq_q, block_m):
            var m_end = min(m_block + block_m, seq_q)
            var m_size = m_end - m_block

            # Zero/init accumulators for this query block
            for i in range(m_size * head_dim):
                O_acc[i] = 0.0
            for i in range(m_size):
                l_acc[i] = 0.0
                m_acc[i] = -Float32.MAX

            # Process K,V blocks
            var n_end_block = seq_kv if not config.causal else min(m_end, seq_kv)

            for n_block in range(0, n_end_block, block_n):
                var n_end = min(n_block + block_n, n_end_block)
                var n_size = n_end - n_block

                _compute_attention_scores(
                    Q, K, S,
                    q_base, k_base,
                    m_block, n_block,
                    m_size, n_size,
                    head_dim, num_heads,
                    scale
                )

                # Apply causal mask
                if config.causal:
                    for i in range(m_size):
                        var q_idx = m_block + i
                        for j in range(n_size):
                            var k_idx = n_block + j
                            if k_idx > q_idx:
                                S[i * n_size + j] = -Float32.MAX

                _update_online_softmax(
                    S, O_acc, l_acc, m_acc,
                    V, v_base,
                    n_block, n_size, m_size,
                    head_dim, num_heads
                )

            # Write output with final softmax normalization (SIMD over head_dim)
            comptime SOFTMAX_EPS: Float32 = 1e-10
            for i in range(m_size):
                var q_idx = m_block + i
                var l_val = l_acc[i]
                var inv_l = Float32(1.0) / l_val if l_val > SOFTMAX_EPS else Float32(0.0)
                var src = O_acc + i * head_dim
                var dst = O + o_base + q_idx * num_heads * head_dim

                fn write_out[width: Int](d: Int) unified {mut}:
                    var v = (src + d).load[width=width]()
                    (dst + d).store[width=width](0, v * inv_l)

                vectorize[SIMD_WIDTH](head_dim, write_out)

        O_acc.free()
        l_acc.free()
        m_acc.free()
        S.free()

    parallelize[process_batch_head](total_work)


fn _compute_attention_scores[o_q: Origin, o_k: Origin, o_s: MutOrigin](
    Q: UnsafePointer[Float32, origin=o_q],
    K: UnsafePointer[Float32, origin=o_k],
    S: UnsafePointer[Float32, origin=o_s],
    q_base: Int,
    k_base: Int,
    m_block: Int,
    n_block: Int,
    m_size: Int,
    n_size: Int,
    head_dim: Int,
    num_heads: Int,
    scale: Float32,
):
    """Compute S = Q @ K^T * scale using SIMD."""
    for i in range(m_size):
        var q_idx = m_block + i
        
        for j in range(n_size):
            var k_idx = n_block + j
            var dot = Float32(0.0)
            
            # SIMD dot product
            fn dot_simd[width: Int](d: Int) unified {mut}:
                var q_vec = (Q + q_base + q_idx * num_heads * head_dim + d).load[width=width]()
                var k_vec = (K + k_base + k_idx * num_heads * head_dim + d).load[width=width]()
                dot += (q_vec * k_vec).reduce_add()

            vectorize[SIMD_WIDTH](head_dim, dot_simd)
            
            S[i * n_size + j] = dot * scale


fn _update_online_softmax[o_s: MutOrigin, o_oa: MutOrigin, o_la: MutOrigin, o_ma: MutOrigin, o_v: Origin](
    S: UnsafePointer[Float32, origin=o_s],
    O_acc: UnsafePointer[Float32, origin=o_oa],
    l_acc: UnsafePointer[Float32, origin=o_la],
    m_acc: UnsafePointer[Float32, origin=o_ma],
    V: UnsafePointer[Float32, origin=o_v],
    v_base: Int,
    n_block: Int,
    n_size: Int,
    m_size: Int,
    head_dim: Int,
    num_heads: Int,
):
    """Update output accumulator with online softmax."""
    # Guard against empty block - prevents uninitialized memory access
    if n_size <= 0:
        return
    
    for i in range(m_size):
        var s_row = S + i * n_size

        # Find max in current block (SIMD reduction)
        var block_max = s_row[0]
        for j in range(1, n_size):
            block_max = max(block_max, s_row[j])

        # Compute exp and sum for current block (vectorized where possible)
        var block_sum = Float32(0.0)

        fn exp_sum[width: Int](j: Int) unified {mut}:
            var v = (s_row + j).load[width=width]()
            var e = exp(v - block_max)
            (s_row + j).store[width=width](0, e)
            block_sum += e.reduce_add()

        vectorize[SIMD_WIDTH](n_size, exp_sum)

        # Update running max and rescale
        var m_prev = m_acc[i]
        var m_new = max(m_prev, block_max)

        var scale_prev = exp(m_prev - m_new)
        var scale_new = exp(block_max - m_new)

        l_acc[i] = l_acc[i] * scale_prev + block_sum * scale_new

        # Rescale previous O accumulator (SIMD over head_dim)
        var o_row = O_acc + i * head_dim

        fn rescale_o[width: Int](d: Int) unified {mut}:
            var ov = (o_row + d).load[width=width]()
            (o_row + d).store[width=width](0, ov * scale_prev)

        vectorize[SIMD_WIDTH](head_dim, rescale_o)

        # Add V contribution (SIMD over head_dim for each KV position)
        for j in range(n_size):
            var v_idx = n_block + j
            var s_val = s_row[j] * scale_new

            fn acc_v[width: Int](d: Int) unified {mut}:
                var v_val = (V + v_base + v_idx * num_heads * head_dim + d).load[width=width]()
                var ov = (o_row + d).load[width=width]()
                (o_row + d).store[width=width](0, ov + v_val * s_val)

            vectorize[SIMD_WIDTH](head_dim, acc_v)

        m_acc[i] = m_new


# =============================================================================
# Fused RoPE + Attention
# =============================================================================

fn apply_rotary_embedding_fused[o_q: MutOrigin, o_k: MutOrigin, o_cos: Origin, o_sin: Origin](
    Q: UnsafePointer[Float32, origin=o_q],
    K: UnsafePointer[Float32, origin=o_k],
    cos: UnsafePointer[Float32, origin=o_cos],  # [seq_len, head_dim/2]
    sin: UnsafePointer[Float32, origin=o_sin],  # [seq_len, head_dim/2]
    seq_len: Int,
    num_heads: Int,
    head_dim: Int,
):
    """
    Apply Rotary Position Embedding to Q and K in-place.
    Fused for better memory access pattern.
    """
    var half_dim = head_dim // 2
    
    for pos in range(seq_len):
        for h in range(num_heads):
            var base = pos * num_heads * head_dim + h * head_dim
            
            # Apply rotation to first half and second half pairs
            fn apply_rope[width: Int](d: Int) unified {mut}:
                # Load Q values
                var q1 = (Q + base + d).load[width=width]()
                var q2 = (Q + base + d + half_dim).load[width=width]()

                # Load cos/sin for this position
                var c = (cos + pos * half_dim + d).load[width=width]()
                var s = (sin + pos * half_dim + d).load[width=width]()

                # Apply rotation: (q1*c - q2*s, q1*s + q2*c)
                var q1_new = q1 * c - q2 * s
                var q2_new = q1 * s + q2 * c

                # Store back
                (Q + base + d).store[width=width](0, q1_new)
                (Q + base + d + half_dim).store[width=width](0, q2_new)

                # Same for K
                var k1 = (K + base + d).load[width=width]()
                var k2 = (K + base + d + half_dim).load[width=width]()

                var k1_new = k1 * c - k2 * s
                var k2_new = k1 * s + k2 * c

                (K + base + d).store[width=width](0, k1_new)
                (K + base + d + half_dim).store[width=width](0, k2_new)

            vectorize[SIMD_WIDTH](half_dim, apply_rope)


# =============================================================================
# Grouped Query Attention (GQA)
# =============================================================================

fn flash_attention_gqa[o_q: Origin, o_k: Origin, o_v: Origin, o_o: MutOrigin](
    Q: UnsafePointer[Float32, origin=o_q],    # [batch, seq_q, num_q_heads, head_dim]
    K: UnsafePointer[Float32, origin=o_k],    # [batch, seq_kv, num_kv_heads, head_dim]
    V: UnsafePointer[Float32, origin=o_v],    # [batch, seq_kv, num_kv_heads, head_dim]
    O: UnsafePointer[Float32, origin=o_o],    # [batch, seq_q, num_q_heads, head_dim] output
    batch_size: Int,
    seq_q: Int,
    seq_kv: Int,
    num_q_heads: Int,
    num_kv_heads: Int,
    head_dim: Int,
    config: FlashAttentionConfig,
):
    """
    FlashAttention with Grouped Query Attention support.

    num_q_heads must be divisible by num_kv_heads.
    Each KV head is shared by (num_q_heads / num_kv_heads) Q heads.
    Parallelized over batch × num_q_heads.
    """
    var heads_per_group = num_q_heads // num_kv_heads
    var total_work = batch_size * num_q_heads

    @parameter
    fn process_gqa_head(work_idx: Int):
        var b = work_idx // num_q_heads
        var q_h = work_idx % num_q_heads
        var kv_h = q_h // heads_per_group

        var q_base = b * seq_q * num_q_heads * head_dim + q_h * head_dim
        var k_base = b * seq_kv * num_kv_heads * head_dim + kv_h * head_dim
        var v_base = b * seq_kv * num_kv_heads * head_dim + kv_h * head_dim
        var o_base = b * seq_q * num_q_heads * head_dim + q_h * head_dim

        _flash_attention_single_head(
            Q, K, V, O,
            q_base, k_base, v_base, o_base,
            seq_q, seq_kv, head_dim,
            num_q_heads, num_kv_heads,
            config
        )

    parallelize[process_gqa_head](total_work)


fn _flash_attention_single_head[o_q: Origin, o_k: Origin, o_v: Origin, o_o: MutOrigin](
    Q: UnsafePointer[Float32, origin=o_q],
    K: UnsafePointer[Float32, origin=o_k],
    V: UnsafePointer[Float32, origin=o_v],
    O: UnsafePointer[Float32, origin=o_o],
    q_base: Int,
    k_base: Int,
    v_base: Int,
    o_base: Int,
    seq_q: Int,
    seq_kv: Int,
    head_dim: Int,
    num_q_heads: Int,
    num_kv_heads: Int,
    config: FlashAttentionConfig,
):
    """Flash attention for a single head pair (SIMD-vectorized)."""
    var scale = config.scale
    var block_m = config.block_m
    var block_n = config.block_n

    for m_block in range(0, seq_q, block_m):
        var m_end = min(m_block + block_m, seq_q)
        var m_size = m_end - m_block

        var O_acc = alloc[Float32](m_size * head_dim)
        var l_acc = alloc[Float32](m_size)
        var m_acc = alloc[Float32](m_size)

        for i in range(m_size * head_dim):
            O_acc[i] = 0.0
        for i in range(m_size):
            l_acc[i] = 0.0
            m_acc[i] = -Float32.MAX

        var n_end_block = seq_kv if not config.causal else min(m_end, seq_kv)

        for n_block in range(0, n_end_block, block_n):
            var n_end = min(n_block + block_n, n_end_block)
            var n_size = n_end - n_block

            var S = alloc[Float32](m_size * n_size)

            # Compute scores using SIMD dot product
            for i in range(m_size):
                var q_idx = m_block + i
                for j in range(n_size):
                    var k_idx = n_block + j
                    var dot = Float32(0.0)

                    fn dot_gqa[width: Int](d: Int) unified {mut}:
                        var q_vec = (Q + q_base + q_idx * num_q_heads * head_dim + d).load[width=width]()
                        var k_vec = (K + k_base + k_idx * num_kv_heads * head_dim + d).load[width=width]()
                        dot += (q_vec * k_vec).reduce_add()

                    vectorize[SIMD_WIDTH](head_dim, dot_gqa)

                    S[i * n_size + j] = dot * scale

                    if config.causal and k_idx > q_idx:
                        S[i * n_size + j] = -Float32.MAX

            # Guard against empty n_size before online softmax update
            if n_size <= 0:
                S.free()
                continue

            # Online softmax update (SIMD-vectorized)
            for i in range(m_size):
                var s_row = S + i * n_size

                var block_max = s_row[0]
                for j in range(1, n_size):
                    block_max = max(block_max, s_row[j])

                var block_sum = Float32(0.0)

                fn gqa_exp_sum[width: Int](j: Int) unified {mut}:
                    var v = (s_row + j).load[width=width]()
                    var e = exp(v - block_max)
                    (s_row + j).store[width=width](0, e)
                    block_sum += e.reduce_add()

                vectorize[SIMD_WIDTH](n_size, gqa_exp_sum)

                var m_prev = m_acc[i]
                var m_new = max(m_prev, block_max)
                var scale_prev = exp(m_prev - m_new)
                var scale_new = exp(block_max - m_new)

                l_acc[i] = l_acc[i] * scale_prev + block_sum * scale_new

                # Rescale previous O (SIMD over head_dim)
                var o_row = O_acc + i * head_dim

                fn gqa_rescale[width: Int](d: Int) unified {mut}:
                    var ov = (o_row + d).load[width=width]()
                    (o_row + d).store[width=width](0, ov * scale_prev)

                vectorize[SIMD_WIDTH](head_dim, gqa_rescale)

                # Add V contribution (SIMD over head_dim)
                for j in range(n_size):
                    var v_idx = n_block + j
                    var s_val = s_row[j] * scale_new

                    fn gqa_acc_v[width: Int](d: Int) unified {mut}:
                        var v_val = (V + v_base + v_idx * num_kv_heads * head_dim + d).load[width=width]()
                        var ov = (o_row + d).load[width=width]()
                        (o_row + d).store[width=width](0, ov + v_val * s_val)

                    vectorize[SIMD_WIDTH](head_dim, gqa_acc_v)

                m_acc[i] = m_new

            S.free()

        # Write output (SIMD over head_dim)
        comptime SOFTMAX_EPS_GQA: Float32 = 1e-10
        for i in range(m_size):
            var q_idx = m_block + i
            var l_val = l_acc[i]
            var inv_l = Float32(1.0) / l_val if l_val > SOFTMAX_EPS_GQA else Float32(0.0)
            var src = O_acc + i * head_dim
            var dst = O + o_base + q_idx * num_q_heads * head_dim

            fn gqa_write[width: Int](d: Int) unified {mut}:
                var v = (src + d).load[width=width]()
                (dst + d).store[width=width](0, v * inv_l)

            vectorize[SIMD_WIDTH](head_dim, gqa_write)

        O_acc.free()
        l_acc.free()
        m_acc.free()


# =============================================================================
# PagedAttention for KV Cache
# =============================================================================

struct PagedAttentionConfig:
    """Configuration for paged attention with KV cache."""
    var block_size: Int  # Tokens per block
    var num_blocks: Int
    var head_dim: Int
    var num_heads: Int
    
    fn __init__(out self, block_size: Int, num_blocks: Int, head_dim: Int, num_heads: Int):
        self.block_size = block_size
        self.num_blocks = num_blocks
        self.head_dim = head_dim
        self.num_heads = num_heads


fn paged_attention_forward[o_q: Origin, o_kc: Origin, o_vc: Origin, o_bt: Origin, o_cl: Origin, o_o: MutOrigin](
    Q: UnsafePointer[Float32, origin=o_q],           # [batch, 1, num_heads, head_dim] - single query
    K_cache: UnsafePointer[Float32, origin=o_kc],     # [num_blocks, block_size, num_kv_heads, head_dim]
    V_cache: UnsafePointer[Float32, origin=o_vc],     # [num_blocks, block_size, num_kv_heads, head_dim]
    block_tables: UnsafePointer[Int, origin=o_bt],    # [batch, max_num_blocks] - block indices
    context_lens: UnsafePointer[Int, origin=o_cl],    # [batch] - actual context length per sequence
    O: UnsafePointer[Float32, origin=o_o],           # [batch, 1, num_heads, head_dim] output
    batch_size: Int,
    num_heads: Int,
    num_kv_heads: Int,
    head_dim: Int,
    config: PagedAttentionConfig,
    scale: Float32,
):
    """
    Paged attention for efficient KV cache access.

    Used during decoding phase where we only have one new query token
    but need to attend to all previous K,V stored in paged blocks.
    Parallelized over batch × head.  SIMD-vectorized dot products.
    """
    var heads_per_group = num_heads // num_kv_heads
    var block_size = config.block_size
    var total_work = batch_size * num_heads

    @parameter
    fn process_paged_head(work_idx: Int):
        var b = work_idx // num_heads
        var h = work_idx % num_heads
        var kv_h = h // heads_per_group
        var context_len = context_lens[b]
        var num_context_blocks = (context_len + block_size - 1) // block_size

        var softmax = OnlineSoftmax()
        var O_acc = alloc[Float32](head_dim)
        for d in range(head_dim):
            O_acc[d] = 0.0

        # Iterate over KV cache blocks
        for block_idx in range(num_context_blocks):
            var physical_block = block_tables[b * config.num_blocks + block_idx]

            var start_token = block_idx * block_size
            var end_token = min(start_token + block_size, context_len)
            var num_tokens = end_token - start_token

            # Guard against empty block - skip if no tokens
            if num_tokens <= 0:
                continue

            var scores = alloc[Float32](num_tokens)

            # SIMD-vectorized Q·K dot products
            for t in range(num_tokens):
                var dot = Float32(0.0)
                var q_off = b * num_heads * head_dim + h * head_dim
                var k_off = physical_block * block_size * num_kv_heads * head_dim + t * num_kv_heads * head_dim + kv_h * head_dim

                fn dot_paged[width: Int](d: Int) unified {mut}:
                    var q_vec = (Q + q_off + d).load[width=width]()
                    var k_vec = (K_cache + k_off + d).load[width=width]()
                    dot += (q_vec * k_vec).reduce_add()

                vectorize[SIMD_WIDTH](head_dim, dot_paged)
                scores[t] = dot * scale

            # Find block max and sum
            var block_max = scores[0]
            for t in range(1, num_tokens):
                block_max = max(block_max, scores[t])

            var block_sum = Float32(0.0)

            fn paged_exp_sum[width: Int](t: Int) unified {mut}:
                var sv = (scores + t).load[width=width]()
                var ev = exp(sv - block_max)
                (scores + t).store[width=width](0, ev)
                block_sum += ev.reduce_add()

            vectorize[SIMD_WIDTH](num_tokens, paged_exp_sum)

            # Update online softmax and output
            var m_prev = softmax.max_val
            var m_new = max(m_prev, block_max)
            var scale_prev = exp(m_prev - m_new)
            var scale_new = exp(block_max - m_new)

            softmax.sum_exp = softmax.sum_exp * scale_prev + block_sum * scale_new
            softmax.max_val = m_new

            # Rescale previous O_acc (SIMD over head_dim)
            fn paged_rescale[width: Int](d: Int) unified {mut}:
                var ov = (O_acc + d).load[width=width]()
                (O_acc + d).store[width=width](0, ov * scale_prev)

            vectorize[SIMD_WIDTH](head_dim, paged_rescale)

            # V accumulation (SIMD over head_dim for each token)
            var v_block_base = physical_block * block_size * num_kv_heads * head_dim + kv_h * head_dim
            for t in range(num_tokens):
                var s_val = scores[t] * scale_new
                var v_row = V_cache + v_block_base + t * num_kv_heads * head_dim

                fn paged_acc_v[width: Int](d: Int) unified {mut}:
                    var v_val = (v_row + d).load[width=width]()
                    var ov = (O_acc + d).load[width=width]()
                    (O_acc + d).store[width=width](0, ov + v_val * s_val)

                vectorize[SIMD_WIDTH](head_dim, paged_acc_v)

            scores.free()

        # Write final output (SIMD over head_dim)
        comptime SOFTMAX_EPS_PAGED: Float32 = 1e-10
        var inv_l_paged = Float32(1.0) / softmax.sum_exp if softmax.sum_exp > SOFTMAX_EPS_PAGED else Float32(0.0)
        var dst_paged = O + b * num_heads * head_dim + h * head_dim

        fn paged_write[width: Int](d: Int) unified {mut}:
            var v = (O_acc + d).load[width=width]()
            (dst_paged + d).store[width=width](0, v * inv_l_paged)

        vectorize[SIMD_WIDTH](head_dim, paged_write)

        O_acc.free()

    parallelize[process_paged_head](total_work)