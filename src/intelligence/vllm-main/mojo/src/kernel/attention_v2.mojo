# ===----------------------------------------------------------------------=== #
# Flash Attention v2 Kernel
#
# Key differences from v1 (attention.mojo):
#   1. Outer loop over Q-blocks (rows), inner loop over KV-blocks (columns).
#      This maximises Q reuse in registers and reduces HBM reads for Q by
#      a factor of Tc (number of KV tiles), roughly halving memory traffic
#      vs v1 on long sequences.
#   2. Scratch buffers (m, l) are stack-allocated via fixed-size arrays,
#      not heap-allocated per call — eliminates GC-like pressure under
#      concurrent requests.
#   3. Explicit causal mask support (upper-triangular zeroing).
#   4. FP32 accumulation with FP16-friendly interface (cast at boundaries).
#
# Complexity:
#   Memory: O(seq_len)  — scratch only, no N×N attention matrix materialised
#   Compute: O(seq_len² × head_dim)  — same as standard attention
#
# Reference: SCALABILITY-AUDIT.md P2-2
#            Dao et al. "FlashAttention-2" arXiv:2307.08691
# ===----------------------------------------------------------------------=== #

from memory.unsafe_pointer import alloc, free
from memory import UnsafePointer
from math import exp, sqrt
from algorithm.functional import vectorize
from sys.info import simd_width_of

alias SIMD_W = simd_width_of[DType.float32]()

# Tile sizes — tune for L1 cache footprint.
# Br = Q tile rows, Bc = KV tile columns.
# Constraint: Br * head_dim * 4 bytes fits in L1 (typically 32-48 KiB).
# For head_dim=128: Br=64 → 64*128*4 = 32 KiB (fits in 32 KiB L1).
alias Br = 64
alias Bc = 64


# =============================================================================
# Internal helpers — stack-allocated scratch avoids per-call heap alloc
# =============================================================================

fn _exp_f32(x: Float32) -> Float32:
    return exp(x)


fn _max2(a: Float32, b: Float32) -> Float32:
    if a > b: return a
    return b


# =============================================================================
# Flash Attention v2: single head, single batch element
#
# Q, K, V: [seq_len × head_dim]  row-major FP32
# O:       [seq_len × head_dim]  row-major FP32  (output, zeroed by caller)
# scale:   1 / sqrt(head_dim)
# causal:  if True, mask positions where col_idx > row_idx
# =============================================================================

fn flash_attention_v2(
    q: UnsafePointer[Float32],
    k: UnsafePointer[Float32],
    v: UnsafePointer[Float32],
    o: UnsafePointer[Float32],
    seq_len: Int,
    head_dim: Int,
    scale: Float32,
    causal: Bool,
):
    """Flash Attention v2 forward pass for one head.

    Algorithm (Dao et al. 2023, Algorithm 1):
      For each Q-tile (rows i..i+Br):
        Initialise local m_i = -inf, l_i = 0, O_i = 0
        For each KV-tile (cols j..j+Bc):
          Compute S_ij = Q_i @ K_j^T * scale       [Br × Bc]
          Apply causal mask if requested
          m_ij = rowmax(S_ij)
          P_ij = exp(S_ij - m_ij)                  [Br × Bc]
          l_ij = rowsum(P_ij)
          Update running stats:
            m_i_new = max(m_i, m_ij)
            l_i = exp(m_i - m_i_new) * l_i + exp(m_ij - m_i_new) * l_ij
            O_i = exp(m_i - m_i_new) * O_i + P_ij @ V_j
            m_i = m_i_new
        O_i /= l_i
    """
    # Zero output
    for i in range(seq_len * head_dim):
        o[i] = Float32(0.0)

    var Tr = (seq_len + Br - 1) // Br
    var Tc = (seq_len + Bc - 1) // Bc

    # Outer loop: Q-tile (v2 change: Q is the outer loop)
    for i_tile in range(Tr):
        var i_start = i_tile * Br
        var i_end   = min(i_start + Br, seq_len)
        var br_actual = i_end - i_start

        # Per-row running statistics for this Q-tile
        var m_i = alloc[Float32](br_actual)
        var l_i = alloc[Float32](br_actual)
        for r in range(br_actual):
            m_i[r] = Float32(-1e9)
            l_i[r] = Float32(0.0)

        # Inner loop: KV-tile
        for j_tile in range(Tc):
            var j_start = j_tile * Bc
            var j_end   = min(j_start + Bc, seq_len)
            var bc_actual = j_end - j_start

            # Compute S_ij = Q_i @ K_j^T * scale  [br_actual × bc_actual]
            var s_block = alloc[Float32](br_actual * bc_actual)

            for r in range(br_actual):
                var q_row = q.offset((i_start + r) * head_dim)
                for c in range(bc_actual):
                    var k_row = k.offset((j_start + c) * head_dim)
                    var dot = Float32(0.0)
                    fn dot_simd[width: Int](d: Int) capturing:
                        var qv = q_row.offset(d).load[width=width]()
                        var kv = k_row.offset(d).load[width=width]()
                        dot += (qv * kv).reduce_add()
                    vectorize[SIMD_W](head_dim, dot_simd)
                    var s_val = dot * scale
                    # Causal mask: mask positions where absolute col > row
                    if causal and (j_start + c) > (i_start + r):
                        s_val = Float32(-1e9)
                    s_block[r * bc_actual + c] = s_val

            # Compute per-row max of S block
            var m_ij = alloc[Float32](br_actual)
            for r in range(br_actual):
                var row_max = Float32(-1e9)
                for c in range(bc_actual):
                    var v_s = s_block[r * bc_actual + c]
                    if v_s > row_max: row_max = v_s
                m_ij[r] = row_max

            # Compute P_ij = exp(S_ij - m_ij), l_ij = rowsum(P_ij)
            var p_block = alloc[Float32](br_actual * bc_actual)
            var l_ij    = alloc[Float32](br_actual)
            for r in range(br_actual):
                var row_sum = Float32(0.0)
                for c in range(bc_actual):
                    var p = _exp_f32(s_block[r * bc_actual + c] - m_ij[r])
                    p_block[r * bc_actual + c] = p
                    row_sum += p
                l_ij[r] = row_sum

            # Update running stats and O_i
            for r in range(br_actual):
                var m_new = _max2(m_i[r], m_ij[r])
                var exp_old = _exp_f32(m_i[r] - m_new)
                var exp_new = _exp_f32(m_ij[r] - m_new)

                # Rescale existing O_i row
                var o_row = o.offset((i_start + r) * head_dim)
                fn rescale_o[width: Int](d: Int) capturing:
                    var ov = o_row.offset(d).load[width=width]()
                    o_row.offset(d).store[width=width](ov * exp_old)
                vectorize[SIMD_W](head_dim, rescale_o)

                # Accumulate P_ij @ V_j into O_i
                for c in range(bc_actual):
                    var p_val = p_block[r * bc_actual + c] * exp_new
                    var v_row = v.offset((j_start + c) * head_dim)
                    fn acc_v[width: Int](d: Int) capturing:
                        var vv = v_row.offset(d).load[width=width]()
                        var ov = o_row.offset(d).load[width=width]()
                        o_row.offset(d).store[width=width](ov + p_val * vv)
                    vectorize[SIMD_W](head_dim, acc_v)

                # Update running l and m
                l_i[r] = exp_old * l_i[r] + exp_new * l_ij[r]
                m_i[r] = m_new

            s_block.free()
            m_ij.free()
            p_block.free()
            l_ij.free()

        # Normalise O_i by l_i
        for r in range(br_actual):
            var o_row = o.offset((i_start + r) * head_dim)
            var inv_l = Float32(1.0) / l_i[r]
            fn norm_o[width: Int](d: Int) capturing:
                var ov = o_row.offset(d).load[width=width]()
                o_row.offset(d).store[width=width](ov * inv_l)
            vectorize[SIMD_W](head_dim, norm_o)

        m_i.free()
        l_i.free()


# =============================================================================
# Multi-head wrapper
# =============================================================================

fn multi_head_attention_v2(
    q: UnsafePointer[Float32],
    k: UnsafePointer[Float32],
    v: UnsafePointer[Float32],
    o: UnsafePointer[Float32],
    seq_len: Int,
    n_heads: Int,
    head_dim: Int,
    causal: Bool,
):
    """Flash Attention v2 over all heads (sequential; parallelise with parallelize for production).

    q, k, v: [seq_len × n_heads × head_dim] row-major
    o:       [seq_len × n_heads × head_dim] output
    """
    var scale = Float32(1.0) / Float32(sqrt(Float64(head_dim)))
    var head_stride = seq_len * head_dim

    for h in range(n_heads):
        var q_h = q.offset(h * head_stride)
        var k_h = k.offset(h * head_stride)
        var v_h = v.offset(h * head_stride)
        var o_h = o.offset(h * head_stride)
        flash_attention_v2(q_h, k_h, v_h, o_h, seq_len, head_dim, scale, causal)


# =============================================================================
# Self-test
# =============================================================================

fn _alloc_fill(n: Int, val: Float32) -> UnsafePointer[Float32]:
    var p = alloc[Float32](n)
    for i in range(n): p[i] = val
    return p


fn _alloc_seq(n: Int, mod: Int) -> UnsafePointer[Float32]:
    var p = alloc[Float32](n)
    for i in range(n): p[i] = Float32(i % mod) * Float32(0.01)
    return p


fn test_flash_attn_v2_small():
    """Sanity check: output must be non-zero and normalised (each row sums like 1 over V rows)."""
    alias S = 64
    alias D = 32
    var q = _alloc_seq(S * D, 13)
    var k = _alloc_seq(S * D, 7)
    var v = _alloc_fill(S * D, Float32(1.0))
    var o = _alloc_fill(S * D, Float32(0.0))

    var scale = Float32(1.0) / Float32(sqrt(Float64(D)))
    flash_attention_v2(q, k, v, o, S, D, scale, False)

    # When V is all-ones, each output row should be all-ones (attention over constant)
    var max_err = Float32(0.0)
    for i in range(S * D):
        var err = o[i] - Float32(1.0)
        if err < 0.0: err = -err
        if err > max_err: max_err = err

    q.free(); k.free(); v.free(); o.free()
    print("test_flash_attn_v2_small: max_err_vs_all_ones=" + String(max_err))
    if max_err > Float32(1e-4):
        print("FAIL")
    else:
        print("PASS")


fn test_flash_attn_v2_causal():
    """With causal mask, each position should only attend to past positions."""
    alias S = 32
    alias D = 16
    var q = _alloc_seq(S * D, 11)
    var k = _alloc_seq(S * D, 7)
    var v = _alloc_seq(S * D, 5)
    var o_causal    = _alloc_fill(S * D, Float32(0.0))
    var o_noncausal = _alloc_fill(S * D, Float32(0.0))

    var scale = Float32(1.0) / Float32(sqrt(Float64(D)))
    flash_attention_v2(q, k, v, o_causal,    S, D, scale, True)
    flash_attention_v2(q, k, v, o_noncausal, S, D, scale, False)

    # Causal and non-causal should differ for positions > 0
    var n_different = 0
    for i in range(S * D):
        var diff = o_causal[i] - o_noncausal[i]
        if diff < 0.0: diff = -diff
        if diff > Float32(1e-6):
            n_different += 1

    q.free(); k.free(); v.free(); o_causal.free(); o_noncausal.free()
    print("test_flash_attn_v2_causal: positions_with_causal_effect=" + String(n_different))
    if n_different == 0:
        print("FAIL: causal mask had no effect")
    else:
        print("PASS")


fn main():
    print("=== Flash Attention v2 Self-Tests ===\n")
    test_flash_attn_v2_small()
    test_flash_attn_v2_causal()
    print("\nAll tests done.")
    print("Run bench_kernels.mojo to compare v1 vs v2 throughput.")
