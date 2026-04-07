"""
SIMD-accelerated operations for LLM inference.

Provides high-performance vectorized operations:
- Vector addition, multiplication, scaling
- Dot products
- Element-wise operations
- Reduction operations (sum, max, min)
"""

from sys.info import simdwidthof
from algorithm import vectorize, parallelize
from memory import memset_zero, memcpy
from math import exp, sqrt, rsqrt, tanh


alias FloatType = DType.float32
alias IntType = DType.int32
alias simd_width = simdwidthof[FloatType]()


# =============================================================================
# Vector Operations
# =============================================================================

@always_inline
fn simd_add[
    dtype: DType, width: Int
](a: SIMD[dtype, width], b: SIMD[dtype, width]) -> SIMD[dtype, width]:
    """SIMD vector addition."""
    return a + b


@always_inline
fn simd_mul[
    dtype: DType, width: Int
](a: SIMD[dtype, width], b: SIMD[dtype, width]) -> SIMD[dtype, width]:
    """SIMD vector multiplication."""
    return a * b


@always_inline
fn simd_scale[
    dtype: DType, width: Int
](v: SIMD[dtype, width], scalar: Scalar[dtype]) -> SIMD[dtype, width]:
    """Scale a SIMD vector by a scalar."""
    return v * scalar


@always_inline
fn simd_fma[
    dtype: DType, width: Int
](a: SIMD[dtype, width], b: SIMD[dtype, width], c: SIMD[dtype, width]) -> SIMD[dtype, width]:
    """Fused multiply-add: a * b + c"""
    return a * b + c


# =============================================================================
# Dot Product Operations
# =============================================================================

fn dot_product_simd(
    a: UnsafePointer[Scalar[FloatType]],
    b: UnsafePointer[Scalar[FloatType]],
    size: Int
) -> Scalar[FloatType]:
    """
    Compute dot product using SIMD vectorization.
    
    Args:
        a: First vector pointer
        b: Second vector pointer
        size: Vector length
    
    Returns:
        Scalar dot product result
    """
    var result: Scalar[FloatType] = 0

    @parameter
    fn compute_dot[width: Int](i: Int):
        var va = a.load[width=width](i)
        var vb = b.load[width=width](i)
        result += (va * vb).reduce_add()

    vectorize[compute_dot, simd_width](size)

    return result


fn dot_product_parallel(
    a: UnsafePointer[Scalar[FloatType]],
    b: UnsafePointer[Scalar[FloatType]],
    size: Int,
    num_workers: Int = 4
) -> Scalar[FloatType]:
    """
    Parallel dot product computation.
    
    Args:
        a: First vector pointer
        b: Second vector pointer  
        size: Vector length
        num_workers: Number of parallel workers
    
    Returns:
        Scalar dot product result
    """
    var partial_results = UnsafePointer[Scalar[FloatType]].alloc(num_workers)
    memset_zero(partial_results, num_workers)
    
    var chunk_size = size // num_workers
    
    @parameter
    fn compute_chunk(worker_id: Int):
        var start = worker_id * chunk_size
        var end = start + chunk_size if worker_id < num_workers - 1 else size
        var local_sum: Scalar[FloatType] = 0

        @parameter
        fn inner_dot[width: Int](i: Int):
            var va = (a + start + i).load[width=width]()
            var vb = (b + start + i).load[width=width]()
            local_sum += (va * vb).reduce_add()

        vectorize[inner_dot, simd_width](end - start)
        partial_results[worker_id] = local_sum
    
    parallelize[compute_chunk](num_workers, num_workers)
    
    var total: Scalar[FloatType] = 0
    for i in range(num_workers):
        total += partial_results[i]
    
    partial_results.free()
    return total


# =============================================================================
# Element-wise Operations
# =============================================================================

fn elementwise_exp(
    input: UnsafePointer[Scalar[FloatType]],
    output: UnsafePointer[Scalar[FloatType]],
    size: Int
):
    """
    Compute element-wise exponential using SIMD.
    
    Args:
        input: Input vector pointer
        output: Output vector pointer
        size: Vector length
    """
    @parameter
    fn compute_exp[width: Int](i: Int):
        var v = input.load[width=width](i)
        output.store[width=width](i, exp(v))
    
    vectorize[compute_exp, simd_width](size)


fn elementwise_tanh(
    input: UnsafePointer[Scalar[FloatType]],
    output: UnsafePointer[Scalar[FloatType]],
    size: Int
):
    """
    Compute element-wise tanh using SIMD.
    
    Args:
        input: Input vector pointer
        output: Output vector pointer
        size: Vector length
    """
    @parameter
    fn compute_tanh[width: Int](i: Int):
        var v = input.load[width=width](i)
        output.store[width=width](i, tanh(v))
    
    vectorize[compute_tanh, simd_width](size)


fn elementwise_rsqrt(
    input: UnsafePointer[Scalar[FloatType]],
    output: UnsafePointer[Scalar[FloatType]],
    size: Int
):
    """
    Compute element-wise reciprocal square root using SIMD.
    
    Args:
        input: Input vector pointer
        output: Output vector pointer
        size: Vector length
    """
    @parameter
    fn compute_rsqrt[width: Int](i: Int):
        var v = input.load[width=width](i)
        output.store[width=width](i, rsqrt(v))
    
    vectorize[compute_rsqrt, simd_width](size)


# =============================================================================
# Reduction Operations  
# =============================================================================

fn reduce_sum(
    input: UnsafePointer[Scalar[FloatType]],
    size: Int
) -> Scalar[FloatType]:
    """
    Compute sum of all elements using SIMD reduction.
    
    Args:
        input: Input vector pointer
        size: Vector length
    
    Returns:
        Sum of all elements
    """
    var result = SIMD[FloatType, simd_width](0)
    
    @parameter
    fn compute_sum[width: Int](i: Int):
        result += input.load[width=width](i)
    
    vectorize[compute_sum, simd_width](size)
    
    return result.reduce_add()


fn reduce_max(
    input: UnsafePointer[Scalar[FloatType]],
    size: Int
) -> Scalar[FloatType]:
    """
    Find maximum element using SIMD reduction.
    
    Args:
        input: Input vector pointer
        size: Vector length
    
    Returns:
        Maximum element value
    """
    var result = SIMD[FloatType, simd_width](-Float32.MAX)
    
    @parameter
    fn compute_max[width: Int](i: Int):
        var v = input.load[width=width](i)
        result = result.max(v)
    
    vectorize[compute_max, simd_width](size)
    
    return result.reduce_max()


fn reduce_min(
    input: UnsafePointer[Scalar[FloatType]],
    size: Int
) -> Scalar[FloatType]:
    """
    Find minimum element using SIMD reduction.
    
    Args:
        input: Input vector pointer
        size: Vector length
    
    Returns:
        Minimum element value
    """
    var result = SIMD[FloatType, simd_width](Float32.MAX)
    
    @parameter
    fn compute_min[width: Int](i: Int):
        var v = input.load[width=width](i)
        result = result.min(v)
    
    vectorize[compute_min, simd_width](size)
    
    return result.reduce_min()


# =============================================================================
# Vector Normalization
# =============================================================================

fn l2_normalize(
    input: UnsafePointer[Scalar[FloatType]],
    output: UnsafePointer[Scalar[FloatType]],
    size: Int,
    epsilon: Scalar[FloatType] = 1e-8
):
    """
    L2 normalize a vector using SIMD.
    
    Args:
        input: Input vector pointer
        output: Output vector pointer (normalized)
        size: Vector length
    """
    # Compute squared sum
    var squared_sum = SIMD[FloatType, simd_width](0)
    
    @parameter
    fn compute_squared[width: Int](i: Int):
        var v = input.load[width=width](i)
        squared_sum += v * v
    
    vectorize[compute_squared, simd_width](size)
    
    var norm = sqrt(squared_sum.reduce_add())
    var inv_norm = 1.0 / (norm + epsilon)
    
    # Normalize
    @parameter
    fn normalize[width: Int](i: Int):
        var v = input.load[width=width](i)
        output.store[width=width](i, v * inv_norm)
    
    vectorize[normalize, simd_width](size)


fn rms_normalize(
    input: UnsafePointer[Scalar[FloatType]],
    output: UnsafePointer[Scalar[FloatType]],
    size: Int,
    epsilon: Scalar[FloatType] = 1e-6
):
    """
    RMS (Root Mean Square) normalize a vector - used in LLMs.
    
    Args:
        input: Input vector pointer
        output: Output vector pointer (normalized)
        size: Vector length
        epsilon: Small value for numerical stability
    """
    # Compute mean of squares
    var squared_sum = SIMD[FloatType, simd_width](0)
    
    @parameter
    fn compute_squared[width: Int](i: Int):
        var v = input.load[width=width](i)
        squared_sum += v * v
    
    vectorize[compute_squared, simd_width](size)
    
    var rms = sqrt(squared_sum.reduce_add() / size + epsilon)
    var inv_rms = 1.0 / rms
    
    # Normalize
    @parameter
    fn normalize[width: Int](i: Int):
        var v = input.load[width=width](i)
        output.store[width=width](i, v * inv_rms)
    
    vectorize[normalize, simd_width](size)