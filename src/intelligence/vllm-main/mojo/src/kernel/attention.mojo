"""
SIMD-Optimized Self-Attention Kernel for LLM Inference.
Implements scaled dot-product attention with support for Flash Attention optimizations.
"""

from algorithm.functional import vectorize
from math import sqrt, exp
from memory import UnsafePointer
from memory.unsafe_pointer import alloc
from sys.info import simd_width_of

# SIMD width for Float32 operations
comptime SIMD_WIDTH = simd_width_of[DType.float32]()

fn flash_attention[
    o_out: MutOrigin, o_q: Origin, o_k: Origin, o_v: Origin
](
    query: UnsafePointer[Float32, origin=o_q],   # [seq_len, head_dim]
    key: UnsafePointer[Float32, origin=o_k],     # [seq_len, head_dim]
    value: UnsafePointer[Float32, origin=o_v],   # [seq_len, head_dim]
    output: UnsafePointer[Float32, origin=o_out], # [seq_len, head_dim]
    seq_len: Int,
    head_dim: Int,
    scale: Float32
):
    """
    Flash Attention Implementation (Tiled + Online Softmax).

    Optimizes memory bandwidth by computing attention in blocks.
    Replaces: standard O(N^2) implementation.
    """
    # Block sizes (tuning parameters)
    comptime Br = 64  # Row block size
    comptime Bc = 64  # Column block size

    # Initialize output and softmax state (m, l)
    var m = alloc[Float32](seq_len) # Max scores
    var l = alloc[Float32](seq_len) # Sum of exps
    for i in range(seq_len):
        m[i] = -1e9
        l[i] = 0.0
        for j in range(head_dim):
            (output + i * head_dim)[j] = 0.0

    # External loop over column blocks (K, V)
    for j in range(0, seq_len, Bc):
        var j_end = min(j + Bc, seq_len)
        var j_len = j_end - j

        # Internal loop over row blocks (Q, O)
        for i in range(0, seq_len, Br):
            var i_end = min(i + Br, seq_len)
            var i_len = i_end - i

            # For each row in block
            for row in range(i, i_end):
                var q_ptr = query + row * head_dim
                var out_ptr = output + row * head_dim

                var row_max = m[row]
                var row_sum = l[row]

                # Compute scores for this row against current K block
                for col in range(j, j_end):
                    var k_ptr = key + col * head_dim
                    var dot_sum = Float32(0.0)

                    fn dot[width: Int](d: Int) unified {mut}:
                        var qv = q_ptr.load[width=width](d)
                        var kv = k_ptr.load[width=width](d)
                        dot_sum += (qv * kv).reduce_add()
                    vectorize[SIMD_WIDTH](head_dim, dot)

                    var s = dot_sum * scale

                    # Online Softmax update
                    var old_max = row_max
                    if s > row_max:
                        row_max = s
                        var exp_diff = exp(old_max - row_max)
                        row_sum = row_sum * exp_diff + exp(s - row_max)

                        # Rescale existing output
                        fn rescale[width: Int](d: Int) unified {mut}:
                            var val = out_ptr.load[width=width](d)
                            out_ptr.store[width=width](d, val * exp_diff)
                        vectorize[SIMD_WIDTH](head_dim, rescale)
                    else:
                        row_sum += exp(s - row_max)

                    # Accumulate V into output
                    var v_ptr = value + col * head_dim
                    var weight = exp(s - row_max)
                    fn acc_v[width: Int](d: Int) unified {mut}:
                        var v_val = v_ptr.load[width=width](d)
                        var o_val = out_ptr.load[width=width](d)
                        out_ptr.store[width=width](d, o_val + v_val * weight)
                    vectorize[SIMD_WIDTH](head_dim, acc_v)

                m[row] = row_max
                l[row] = row_sum

    # Final normalization by sum(exp)
    for i in range(seq_len):
        var out_ptr = output + i * head_dim
        var inv_l = 1.0 / l[i]
        fn final_norm[width: Int](d: Int) unified {mut}:
            out_ptr.store[width=width](d, out_ptr.load[width=width](d) * inv_l)
        vectorize[SIMD_WIDTH](head_dim, final_norm)

    m.free()
    l.free()
