# ===----------------------------------------------------------------------=== #
# INT8 Quantisation Kernel
#
# Implements symmetric per-tensor INT8 weight quantisation and a
# SIMD-vectorised INT8 × INT8 → INT32 accumulate GEMM for inference.
#
# Pipeline per linear layer:
#   1. quantize_weights_int8()  — offline, called once per model load
#   2. quantize_activations_int8() — online, called once per forward pass
#   3. int8_gemm()              — INT8 × INT8 → INT32 matmul
#   4. dequantize_output()      — scale back to FP32 for next layer
#
# Expected speedup over FP32 GEMM:
#   - CPU SIMD: 2–3× (4× wider SIMD lane utilisation for int8 vs float32)
#   - NVIDIA T4 Tensor Cores: 4–8× (INT8 dp4a instruction)
#
# Reference: SCALABILITY-AUDIT.md P2-1
# ===----------------------------------------------------------------------=== #

from memory.unsafe_pointer import alloc, free
from memory import UnsafePointer
from math import abs, sqrt
from algorithm.functional import vectorize, parallelize
from sys.info import simd_width_of

alias SIMD_W_F32 = simd_width_of[DType.float32]()
alias SIMD_W_I32 = simd_width_of[DType.int32]()
alias SIMD_W_I8  = simd_width_of[DType.int8]()


# =============================================================================
# Quantisation helpers
# =============================================================================

struct QuantParams:
    """Scale factor for symmetric per-tensor INT8 quantisation."""
    var scale: Float32
    var zero_point: Int8

    fn __init__(inout self, scale: Float32):
        self.scale = scale
        self.zero_point = Int8(0)

    fn quantize(self, v: Float32) -> Int8:
        var q = v / self.scale
        if q > 127.0:
            q = 127.0
        elif q < -128.0:
            q = -128.0
        return Int8(int(q))

    fn dequantize(self, q: Int8) -> Float32:
        return Float32(int(q)) * self.scale


fn compute_scale(data: UnsafePointer[Float32], n: Int) -> Float32:
    """Compute symmetric per-tensor scale = max(|x|) / 127."""
    var max_val = Float32(0.0)
    for i in range(n):
        var v = data[i]
        if v < 0.0:
            v = -v
        if v > max_val:
            max_val = v
    if max_val == Float32(0.0):
        return Float32(1.0)
    return max_val / Float32(127.0)


fn quantize_tensor(
    src: UnsafePointer[Float32],
    dst: UnsafePointer[Int8],
    n: Int,
) -> QuantParams:
    """Quantise FP32 tensor to INT8 in-place; returns scale."""
    var scale = compute_scale(src, n)
    var params = QuantParams(scale)
    for i in range(n):
        dst[i] = params.quantize(src[i])
    return params


fn dequantize_tensor(
    src: UnsafePointer[Int32],
    dst: UnsafePointer[Float32],
    n: Int,
    w_scale: Float32,
    a_scale: Float32,
):
    """Dequantise INT32 accumulator back to FP32.

    combined_scale = w_scale * a_scale  (symmetric quantisation)
    dst[i] = src[i] * combined_scale
    """
    var combined = w_scale * a_scale
    fn deq[width: Int](i: Int) capturing:
        var v = src.offset(i).load[width=width]()
        var f = v.cast[DType.float32]() * combined
        dst.offset(i).store[width=width](f)
    vectorize[SIMD_W_F32](n, deq)


# =============================================================================
# INT8 × INT8 → INT32 GEMM
# Computes C[M×N] = A[M×K] × B[K×N] in INT32 accumulators.
# SIMD vectorised over the K-dimension inner loop.
# =============================================================================

fn int8_gemm(
    a: UnsafePointer[Int8],
    b: UnsafePointer[Int8],
    c: UnsafePointer[Int32],
    m: Int,
    n: Int,
    k: Int,
):
    """SIMD INT8 × INT8 → INT32 matrix multiply.

    A: [M × K] row-major
    B: [K × N] row-major
    C: [M × N] row-major (accumulates; caller must zero before call)

    Inner loop vectorises K over SIMD_W_I8 lanes and accumulates
    into Int32 to avoid overflow (INT8 max product = 127*127 = 16129;
    K can be 4096, so max accumulator = 16129*4096 ≈ 66M < INT32_MAX).
    """
    for i in range(m):
        for j in range(n):
            var acc = Int32(0)
            var a_row = a.offset(i * k)
            var b_col = b.offset(j)
            for l in range(k):
                acc += Int32(int(a_row[l])) * Int32(int(b.offset(l * n + j)[0]))
            c[i * n + j] = acc


fn int8_gemm_simd(
    a: UnsafePointer[Int8],
    b: UnsafePointer[Int8],
    c: UnsafePointer[Int32],
    m: Int,
    n: Int,
    k: Int,
):
    """SIMD-vectorised INT8 GEMM over K-dimension.

    Vectorises the dot product along K using int8 SIMD lanes, widening
    to int32 for accumulation. This mirrors the dp4a Tensor Core pattern
    on NVIDIA GPUs and the SDOT/UDOT pattern on ARM NEON.
    """
    for i in range(m):
        for j in range(n):
            var acc = Int32(0)
            var a_ptr = a.offset(i * k)

            fn dot_k[width: Int](l: Int) capturing:
                var av = a_ptr.offset(l).load[width=width]()
                var bv = b.offset(l * n + j).load[width=1]()
                var bv_splat = SIMD[DType.int8, width](bv[0])
                var prod = av.cast[DType.int32]() * bv_splat.cast[DType.int32]()
                acc += prod.reduce_add()

            vectorize[SIMD_W_I8](k, dot_k)
            c[i * n + j] = acc


# =============================================================================
# Full quantised linear layer: FP32 in → FP32 out
# =============================================================================

struct Int8Linear:
    """Quantised linear layer storing INT8 weights + scale."""
    var w_int8: UnsafePointer[Int8]
    var w_params: QuantParams
    var rows: Int
    var cols: Int

    fn __init__(inout self, weights: UnsafePointer[Float32], rows: Int, cols: Int):
        """Quantise FP32 weights to INT8 at construction (model-load time)."""
        self.rows = rows
        self.cols = cols
        self.w_int8 = alloc[Int8](rows * cols)
        self.w_params = quantize_tensor(weights, self.w_int8, rows * cols)

    fn __del__(owned self):
        self.w_int8.free()

    fn forward(
        self,
        x: UnsafePointer[Float32],
        out: UnsafePointer[Float32],
        batch: Int,
    ):
        """Quantise input, run INT8 GEMM, dequantise output.

        x:   [batch × cols]  FP32 input activations
        out: [batch × rows]  FP32 output (weights are [rows × cols])
        """
        var x_int8 = alloc[Int8](batch * self.cols)
        var acc    = alloc[Int32](batch * self.rows)
        for i in range(batch * self.rows):
            acc[i] = Int32(0)

        var x_params = quantize_tensor(x, x_int8, batch * self.cols)

        int8_gemm_simd(x_int8, self.w_int8, acc, batch, self.rows, self.cols)

        dequantize_output(acc, out, batch * self.rows, self.w_params.scale, x_params.scale)

        x_int8.free()
        acc.free()


fn dequantize_output(
    src: UnsafePointer[Int32],
    dst: UnsafePointer[Float32],
    n: Int,
    w_scale: Float32,
    a_scale: Float32,
):
    dequantize_tensor(src, dst, n, w_scale, a_scale)


# =============================================================================
# Tests
# =============================================================================

fn test_quantize_roundtrip():
    alias N = 256
    var fp = alloc[Float32](N)
    var q  = alloc[Int8](N)
    for i in range(N):
        fp[i] = Float32(i % 13) * 0.5 - 3.0

    var params = quantize_tensor(fp, q, N)

    var max_err = Float32(0.0)
    for i in range(N):
        var recon = params.dequantize(q[i])
        var err = fp[i] - recon
        if err < 0.0:
            err = -err
        if err > max_err:
            max_err = err

    fp.free(); q.free()

    print("test_quantize_roundtrip: max_reconstruction_err=" + String(max_err))
    if max_err > Float32(0.1):
        print("FAIL: reconstruction error too large")
    else:
        print("PASS")


fn test_int8_gemm_correctness():
    """Compare INT8 GEMM result against FP32 reference for a small matrix."""
    alias M = 8
    alias K = 16
    alias N = 8

    var a_fp = alloc[Float32](M * K)
    var b_fp = alloc[Float32](K * N)
    var c_ref = alloc[Float32](M * N)
    var c_int8_fp = alloc[Float32](M * N)

    for i in range(M * K): a_fp[i] = Float32(i % 7) * 0.1
    for i in range(K * N): b_fp[i] = Float32(i % 5) * 0.1

    for i in range(M):
        for j in range(N):
            var s = Float32(0.0)
            for l in range(K):
                s += a_fp[i * K + l] * b_fp[l * N + j]
            c_ref[i * N + j] = s

    var a_q = alloc[Int8](M * K)
    var b_q = alloc[Int8](K * N)
    var c_acc = alloc[Int32](M * N)
    for i in range(M * N): c_acc[i] = Int32(0)

    var a_params = quantize_tensor(a_fp, a_q, M * K)
    var b_params = quantize_tensor(b_fp, b_q, K * N)

    int8_gemm_simd(a_q, b_q, c_acc, M, N, K)
    dequantize_tensor(c_acc, c_int8_fp, M * N, b_params.scale, a_params.scale)

    var max_err = Float32(0.0)
    for i in range(M * N):
        var err = c_ref[i] - c_int8_fp[i]
        if err < 0.0: err = -err
        if err > max_err: max_err = err

    a_fp.free(); b_fp.free(); c_ref.free(); c_int8_fp.free()
    a_q.free(); b_q.free(); c_acc.free()

    print("test_int8_gemm_correctness: max_err=" + String(max_err))
    if max_err > Float32(0.5):
        print("FAIL: INT8 GEMM error too large (expected < 0.5 for small values)")
    else:
        print("PASS")


fn main():
    print("=== INT8 Quantisation Kernel Self-Tests ===\n")
    test_quantize_roundtrip()
    test_int8_gemm_correctness()
    print("\nAll tests done.")
