# ===----------------------------------------------------------------------=== #
# Kernel Benchmark Suite
#
# Establishes performance baselines for GEMM, Flash Attention, and
# tokenizer kernels before implementing INT8 Tensor Core path (P2-1)
# and Flash Attention v2 (P2-2).
#
# Usage:
#   mojo test tests/bench_kernels.mojo
#   mojo run tests/bench_kernels.mojo
# ===----------------------------------------------------------------------=== #

from memory import UnsafePointer
from memory.unsafe_pointer import alloc, free
from time import now
from math import sqrt
from sys.info import simd_width_of
from algorithm.functional import vectorize, parallelize


# =============================================================================
# Benchmark Harness (reuses pattern from test_performance.mojo)
# =============================================================================

struct BenchResult:
    var name: String
    var iterations: Int
    var total_time_ms: Float64
    var avg_time_ms: Float64
    var min_time_ms: Float64
    var max_time_ms: Float64
    var gflops: Float64

    fn __init__(inout self, name: String):
        self.name = name
        self.iterations = 0
        self.total_time_ms = 0.0
        self.avg_time_ms = 0.0
        self.min_time_ms = 1e18
        self.max_time_ms = 0.0
        self.gflops = 0.0

    fn report(self):
        print("=== " + self.name + " ===")
        print("  iterations : " + String(self.iterations))
        print("  avg_time   : " + String(self.avg_time_ms) + " ms")
        print("  min_time   : " + String(self.min_time_ms) + " ms")
        print("  max_time   : " + String(self.max_time_ms) + " ms")
        if self.gflops > 0.0:
            print("  GFLOP/s    : " + String(self.gflops))
        print()


fn bench[F: fn() -> None](
    name: String,
    iterations: Int,
    flops_per_iter: Float64 = 0.0,
    warmup: Int = 3,
) -> BenchResult:
    var result = BenchResult(name)
    result.iterations = iterations

    for _ in range(warmup):
        F()

    for _ in range(iterations):
        var t0 = now()
        F()
        var t1 = now()
        var ms = Float64(t1 - t0) / 1_000_000.0
        result.total_time_ms += ms
        if ms < result.min_time_ms:
            result.min_time_ms = ms
        if ms > result.max_time_ms:
            result.max_time_ms = ms

    result.avg_time_ms = result.total_time_ms / Float64(iterations)
    if flops_per_iter > 0.0 and result.avg_time_ms > 0.0:
        result.gflops = flops_per_iter / (result.avg_time_ms * 1e6)
    return result


# =============================================================================
# GEMM (Matrix Multiplication) Benchmarks
# FLOPs for M×K × K×N GEMM = 2×M×K×N
# =============================================================================

fn naive_matmul(
    a: UnsafePointer[Float32],
    b: UnsafePointer[Float32],
    c: UnsafePointer[Float32],
    m: Int, n: Int, k: Int,
):
    for i in range(m):
        for j in range(n):
            var acc = Float32(0.0)
            for l in range(k):
                acc += a[i * k + l] * b[l * n + j]
            c[i * n + j] = acc


comptime SIMD_W = simd_width_of[DType.float32]()


fn simd_matmul_row(
    a: UnsafePointer[Float32],
    b: UnsafePointer[Float32],
    c: UnsafePointer[Float32],
    m: Int, n: Int, k: Int,
):
    """SIMD-vectorised GEMM: vectorise over k-dimension per (i,j) pair."""
    for i in range(m):
        for j in range(n):
            var acc = Float32(0.0)
            fn dot_simd[width: Int](l: Int) unified {mut}:
                var av = a.offset(i * k + l).load[width=width]()
                var bv = b.offset(l * n + j).load[width=width]()
                acc += (av * bv).reduce_add()
            vectorize[SIMD_W](k, dot_simd)
            c[i * n + j] = acc


fn bench_gemm_128():
    alias M = 128
    alias K = 128
    alias N = 128
    var a = alloc[Float32](M * K)
    var b = alloc[Float32](K * N)
    var c = alloc[Float32](M * N)
    for i in range(M * K): a[i] = Float32(i % 7) * 0.01
    for i in range(K * N): b[i] = Float32(i % 11) * 0.01
    simd_matmul_row(a, b, c, M, N, K)
    a.free(); b.free(); c.free()


fn bench_gemm_512():
    alias M = 512
    alias K = 512
    alias N = 512
    var a = alloc[Float32](M * K)
    var b = alloc[Float32](K * N)
    var c = alloc[Float32](M * N)
    for i in range(M * K): a[i] = Float32(i % 7) * 0.01
    for i in range(K * N): b[i] = Float32(i % 11) * 0.01
    simd_matmul_row(a, b, c, M, N, K)
    a.free(); b.free(); c.free()


fn bench_gemm_2048():
    alias M = 2048
    alias K = 2048
    alias N = 2048
    var a = alloc[Float32](M * K)
    var b = alloc[Float32](K * N)
    var c = alloc[Float32](M * N)
    for i in range(M * K): a[i] = Float32(i % 7) * 0.01
    for i in range(K * N): b[i] = Float32(i % 11) * 0.01
    simd_matmul_row(a, b, c, M, N, K)
    a.free(); b.free(); c.free()


# =============================================================================
# Flash Attention Benchmarks (v1 — baseline before v2 migration)
# FLOPs ≈ 4 × seq_len² × head_dim (QK dot + softmax + AV accumulate)
# =============================================================================

fn alloc_zero_f32(n: Int) -> UnsafePointer[Float32]:
    var p = alloc[Float32](n)
    for i in range(n): p[i] = Float32(0.0)
    return p


fn flash_attn_v1(
    q: UnsafePointer[Float32],
    k: UnsafePointer[Float32],
    v: UnsafePointer[Float32],
    o: UnsafePointer[Float32],
    seq_len: Int,
    head_dim: Int,
    scale: Float32,
):
    """Flash Attention v1: outer K-blocks, inner Q-blocks."""
    alias Br = 64
    alias Bc = 64
    var m = alloc[Float32](seq_len)
    var l = alloc[Float32](seq_len)
    for i in range(seq_len):
        m[i] = Float32(-1e9)
        l[i] = Float32(0.0)
        for d in range(head_dim):
            o[i * head_dim + d] = Float32(0.0)

    for j in range(0, seq_len, Bc):
        var j_end = min(j + Bc, seq_len)
        for i in range(0, seq_len, Br):
            var i_end = min(i + Br, seq_len)
            for row in range(i, i_end):
                var q_ptr = q.offset(row * head_dim)
                var o_ptr = o.offset(row * head_dim)
                var row_max = m[row]
                var row_sum = l[row]
                for col in range(j, j_end):
                    var k_ptr = k.offset(col * head_dim)
                    var dot_s = Float32(0.0)
                    fn dot[width: Int](d: Int) unified {mut}:
                        var qv = q_ptr.load[width=width](d)
                        var kv = k_ptr.load[width=width](d)
                        dot_s += (qv * kv).reduce_add()
                    vectorize[SIMD_W](head_dim, dot)
                    var s = dot_s * scale
                    var old_max = row_max
                    if s > row_max:
                        row_max = s
                        var exp_diff = math.exp(old_max - row_max)
                        row_sum = row_sum * exp_diff + math.exp(s - row_max)
                        fn rescale[width: Int](d: Int) unified {mut}:
                            var val = o_ptr.load[width=width](d)
                            o_ptr.store[width=width](d, val * exp_diff)
                        vectorize[SIMD_W](head_dim, rescale)
                    else:
                        row_sum += math.exp(s - row_max)
                    var v_ptr = v.offset(col * head_dim)
                    var w = math.exp(s - row_max)
                    fn acc_v[width: Int](d: Int) unified {mut}:
                        var vv = v_ptr.load[width=width](d)
                        var ov = o_ptr.load[width=width](d)
                        o_ptr.store[width=width](d, ov + vv * w)
                    vectorize[SIMD_W](head_dim, acc_v)
                m[row] = row_max
                l[row] = row_sum
    for i in range(seq_len):
        var o_ptr = o.offset(i * head_dim)
        var inv_l = Float32(1.0) / l[i]
        fn norm[width: Int](d: Int) unified {mut}:
            o_ptr.store[width=width](d, o_ptr.load[width=width](d) * inv_l)
        vectorize[SIMD_W](head_dim, norm)
    m.free(); l.free()


fn bench_flash_attn_512():
    alias S = 512
    alias D = 128
    var q = alloc_zero_f32(S * D)
    var k = alloc_zero_f32(S * D)
    var v = alloc_zero_f32(S * D)
    var o = alloc_zero_f32(S * D)
    for i in range(S * D): q[i] = Float32(i % 13) * 0.01
    for i in range(S * D): k[i] = Float32(i % 7) * 0.01
    for i in range(S * D): v[i] = Float32(i % 11) * 0.01
    flash_attn_v1(q, k, v, o, S, D, Float32(1.0) / Float32(math.sqrt(Float64(D))))
    q.free(); k.free(); v.free(); o.free()


fn bench_flash_attn_2048():
    alias S = 2048
    alias D = 128
    var q = alloc_zero_f32(S * D)
    var k = alloc_zero_f32(S * D)
    var v = alloc_zero_f32(S * D)
    var o = alloc_zero_f32(S * D)
    for i in range(S * D): q[i] = Float32(i % 13) * 0.01
    for i in range(S * D): k[i] = Float32(i % 7) * 0.01
    for i in range(S * D): v[i] = Float32(i % 11) * 0.01
    flash_attn_v1(q, k, v, o, S, D, Float32(1.0) / Float32(math.sqrt(Float64(D))))
    q.free(); k.free(); v.free(); o.free()


fn bench_flash_attn_8192():
    alias S = 8192
    alias D = 64
    var q = alloc_zero_f32(S * D)
    var k = alloc_zero_f32(S * D)
    var v = alloc_zero_f32(S * D)
    var o = alloc_zero_f32(S * D)
    for i in range(S * D): q[i] = Float32(i % 13) * 0.01
    for i in range(S * D): k[i] = Float32(i % 7) * 0.01
    for i in range(S * D): v[i] = Float32(i % 11) * 0.01
    flash_attn_v1(q, k, v, o, S, D, Float32(1.0) / Float32(math.sqrt(Float64(D))))
    q.free(); k.free(); v.free(); o.free()


# =============================================================================
# Tokenizer Benchmark (BPE encode batch)
# Proxy benchmark using string length as a stand-in for token count
# =============================================================================

fn simple_char_tokenize(text: String, vocab_size: Int) -> Int:
    """Trivial char-level tokenizer proxy for benchmark purposes."""
    var count = 0
    for i in range(len(text)):
        count += ord(text[i]) % vocab_size
    return count


fn bench_tokenizer_batch_1():
    var text = "The quick brown fox jumps over the lazy dog. " * 10
    _ = simple_char_tokenize(text, 32000)


fn bench_tokenizer_batch_64():
    var text = "The quick brown fox jumps over the lazy dog. " * 640
    _ = simple_char_tokenize(text, 32000)


fn bench_tokenizer_batch_256():
    var text = "The quick brown fox jumps over the lazy dog. " * 2560
    _ = simple_char_tokenize(text, 32000)


# =============================================================================
# Main: run all benchmarks and print results
# =============================================================================

fn main():
    print("======================================================")
    print("  SAP OSS Mojo Kernel Benchmark Suite")
    print("  Baseline before INT8 (P2-1) and Flash-Attn-v2 (P2-2)")
    print("======================================================\n")

    # --- GEMM ---
    var g128 = bench[bench_gemm_128](
        "GEMM_128x128x128_FP32",
        iterations=20,
        flops_per_iter=2.0 * 128 * 128 * 128,
    )
    g128.report()

    var g512 = bench[bench_gemm_512](
        "GEMM_512x512x512_FP32",
        iterations=5,
        flops_per_iter=2.0 * 512 * 512 * 512,
    )
    g512.report()

    var g2048 = bench[bench_gemm_2048](
        "GEMM_2048x2048x2048_FP32",
        iterations=2,
        flops_per_iter=2.0 * 2048 * 2048 * 2048,
        warmup=1,
    )
    g2048.report()

    # --- Flash Attention v1 ---
    var fa512 = bench[bench_flash_attn_512](
        "FlashAttn_v1_seq512_dim128",
        iterations=20,
        flops_per_iter=4.0 * 512 * 512 * 128,
    )
    fa512.report()

    var fa2048 = bench[bench_flash_attn_2048](
        "FlashAttn_v1_seq2048_dim128",
        iterations=5,
        flops_per_iter=4.0 * 2048 * 2048 * 128,
    )
    fa2048.report()

    var fa8192 = bench[bench_flash_attn_8192](
        "FlashAttn_v1_seq8192_dim64",
        iterations=2,
        flops_per_iter=4.0 * 8192 * 8192 * 64,
        warmup=1,
    )
    fa8192.report()

    # --- Tokenizer ---
    var tok1 = bench[bench_tokenizer_batch_1](
        "Tokenizer_batch1",
        iterations=1000,
    )
    tok1.report()

    var tok64 = bench[bench_tokenizer_batch_64](
        "Tokenizer_batch64",
        iterations=100,
    )
    tok64.report()

    var tok256 = bench[bench_tokenizer_batch_256](
        "Tokenizer_batch256",
        iterations=20,
    )
    tok256.report()

    print("All benchmarks complete.")
    print("Compare these baselines after implementing INT8 GEMM (P2-1)")
    print("and Flash Attention v2 (P2-2) to measure improvement.\n")
