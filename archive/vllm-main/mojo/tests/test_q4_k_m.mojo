# ===----------------------------------------------------------------------=== #
# Q4_K_M Dequantization Tests
#
# Tests for GGUF Q4_K_M quantization format compatibility.
# ===----------------------------------------------------------------------=== #

from testing import assert_true, assert_equal
from memory import memset_zero
from math import abs as math_abs

from quantization import (
    QK_K,
    K_SCALE_SIZE,
    BlockQ4K,
    Q4KMTensor,
    dequantize_q4_k_m_block,
    dequantize_q4_k_m,
    dequantize_q4_k_m_simd,
    q4_k_m_matmul,
)
from sys.info import simdwidthof

alias SIMD_WIDTH = simdwidthof[DType.float32]()


# =============================================================================
# Test: Block Structure
# =============================================================================

fn test_block_structure():
    """Test Q4_K_M block structure matches GGUF spec."""
    print("Testing: Q4_K_M block structure...")
    
    # Q4_K_M block should be 144 bytes:
    # - d: 2 bytes (float16)
    # - dmin: 2 bytes (float16)
    # - scales: 12 bytes (6-bit scales packed)
    # - qs: 128 bytes (4-bit values, 256/2)
    var expected_block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2
    assert_equal(expected_block_size, 144)
    
    # QK_K should be 256 (super-block size)
    assert_equal(QK_K, 256)
    
    # K_SCALE_SIZE should be 12 bytes
    assert_equal(K_SCALE_SIZE, 12)
    
    print("✓ Block structure matches GGUF spec")


# =============================================================================
# Test: Single Block Dequantization
# =============================================================================

fn test_single_block_dequantize():
    """Test dequantizing a single Q4_K_M block."""
    print("Testing: Single block dequantization...")
    
    # Create a test block with known values
    var block = BlockQ4K()
    block.d = Float16(1.0)  # Scale = 1.0
    block.dmin = Float16(0.0)  # No offset
    
    # Set all scales to 1 (first 4 bytes have 6-bit values)
    for i in range(12):
        block.scales[i] = 1
    
    # Set quantized values: first byte = 0x21 -> values 1 and 2
    block.qs[0] = 0x21  # lo=1, hi=2
    block.qs[1] = 0x43  # lo=3, hi=4
    for i in range(2, 128):
        block.qs[i] = 0
    
    # Dequantize
    var output = UnsafePointer[Float32].alloc(QK_K)
    memset_zero(output.bitcast[UInt8](), QK_K * 4)
    
    dequantize_q4_k_m_block(block, output)
    
    # Check first few values
    # d * scale * q_val - dmin = 1.0 * 1.0 * q_val - 0 = q_val
    var val0 = output[0]
    var val1 = output[1]
    var val2 = output[2]
    var val3 = output[3]
    
    print("  output[0]=" + str(val0) + " (expected ~1.0)")
    print("  output[1]=" + str(val1) + " (expected ~2.0)")
    print("  output[2]=" + str(val2) + " (expected ~3.0)")
    print("  output[3]=" + str(val3) + " (expected ~4.0)")
    
    # Allow small tolerance for float16 precision
    assert_true(math_abs(val0 - 1.0) < 0.1, "output[0] should be ~1.0")
    assert_true(math_abs(val1 - 2.0) < 0.1, "output[1] should be ~2.0")
    
    output.free()
    print("✓ Single block dequantization passed")


# =============================================================================
# Test: Multi-Block Dequantization
# =============================================================================

fn test_multi_block_dequantize():
    """Test dequantizing multiple Q4_K_M blocks."""
    print("Testing: Multi-block dequantization...")
    
    var num_blocks = 4
    var block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2
    var total_bytes = num_blocks * block_size
    var total_elements = num_blocks * QK_K
    
    # Allocate raw block data
    var data = UnsafePointer[UInt8].alloc(total_bytes)
    memset_zero(data.bitcast[UInt8](), total_bytes)
    
    # Initialize each block with a different scale
    for b in range(num_blocks):
        var block_ptr = data + b * block_size
        
        # Set d = block_index + 1 (as float16 bits)
        var d_val = Float16(Float32(b + 1))
        block_ptr.bitcast[UInt16]()[0] = d_val.to_bits()
        
        # Set dmin = 0
        (block_ptr + 2).bitcast[UInt16]()[0] = Float16(0.0).to_bits()
        
        # Set scales to 1
        for i in range(K_SCALE_SIZE):
            (block_ptr + 4 + i)[0] = 1
        
        # Set qs to constant value 0x55 (5 and 5)
        for i in range(QK_K // 2):
            (block_ptr + 4 + K_SCALE_SIZE + i)[0] = 0x55
    
    # Allocate output
    var output = UnsafePointer[Float32].alloc(total_elements)
    memset_zero(output.bitcast[UInt8](), total_elements * 4)
    
    # Dequantize
    dequantize_q4_k_m(data, num_blocks, output)
    
    # Check values from each block
    for b in range(num_blocks):
        var expected_scale = Float32(b + 1)
        var val = output[b * QK_K]  # First element of each block
        # With qs=0x55, q_val=5, scale=1, d=b+1: result = d * scale * q_val = (b+1)*1*5
        var expected = expected_scale * 5.0
        print("  Block " + str(b) + " first value: " + str(val) + " (expected ~" + str(expected) + ")")
        assert_true(math_abs(val - expected) < 0.5, "Block " + str(b) + " dequantization error")
    
    data.free()
    output.free()
    print("✓ Multi-block dequantization passed")


# =============================================================================
# Test: SIMD Dequantization
# =============================================================================

fn test_simd_dequantize():
    """Test SIMD-optimized Q4_K_M dequantization."""
    print("Testing: SIMD dequantization...")
    
    var num_blocks = 8
    var block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2
    var total_bytes = num_blocks * block_size
    var total_elements = num_blocks * QK_K
    
    # Create test data
    var data = UnsafePointer[UInt8].alloc(total_bytes)
    memset_zero(data.bitcast[UInt8](), total_bytes)
    
    for b in range(num_blocks):
        var block_ptr = data + b * block_size
        block_ptr.bitcast[UInt16]()[0] = Float16(1.0).to_bits()
        (block_ptr + 2).bitcast[UInt16]()[0] = Float16(0.0).to_bits()
        for i in range(K_SCALE_SIZE):
            (block_ptr + 4 + i)[0] = 1
        for i in range(QK_K // 2):
            (block_ptr + 4 + K_SCALE_SIZE + i)[0] = UInt8(i % 256)
    
    # Run scalar version
    var output_scalar = UnsafePointer[Float32].alloc(total_elements)
    memset_zero(output_scalar.bitcast[UInt8](), total_elements * 4)
    dequantize_q4_k_m(data, num_blocks, output_scalar)
    
    # Run SIMD version
    var output_simd = UnsafePointer[Float32].alloc(total_elements)
    memset_zero(output_simd.bitcast[UInt8](), total_elements * 4)
    dequantize_q4_k_m_simd[SIMD_WIDTH](data, num_blocks, output_simd)
    
    # Compare results
    var max_diff = Float32(0.0)
    for i in range(total_elements):
        var diff = math_abs(output_scalar[i] - output_simd[i])
        if diff > max_diff:
            max_diff = diff
    
    print("  Max difference between scalar and SIMD: " + str(max_diff))
    assert_true(max_diff < 1e-5, "SIMD and scalar results should match")
    
    data.free()
    output_scalar.free()
    output_simd.free()
    print("✓ SIMD dequantization passed")


# =============================================================================
# Test: Q4KMTensor
# =============================================================================

fn test_q4km_tensor():
    """Test Q4KMTensor helper struct."""
    print("Testing: Q4KMTensor struct...")
    
    var rows = 1024
    var cols = 4096
    var tensor = Q4KMTensor(rows, cols)
    
    # Check dimensions
    assert_equal(tensor.num_elements, rows * cols)
    assert_equal(tensor.shape[0], rows)
    assert_equal(tensor.shape[1], cols)
    
    # Check memory calculation
    var expected_blocks = (rows * cols + QK_K - 1) // QK_K
    assert_equal(tensor.num_blocks, expected_blocks)
    
    var block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2
    var expected_bytes = expected_blocks * block_size
    assert_equal(tensor.memory_bytes(), expected_bytes)
    
    # Check compression ratio (FP32 vs Q4_K_M)
    var fp32_bytes = rows * cols * 4
    var ratio = tensor.compression_ratio()
    print("  Shape: " + str(rows) + "x" + str(cols))
    print("  Num blocks: " + str(tensor.num_blocks))
    print("  Memory: " + str(tensor.memory_bytes()) + " bytes")
    print("  Compression ratio: " + str(ratio) + "x")
    
    # Q4_K_M should achieve ~7x compression vs FP32
    assert_true(ratio > 6.0 and ratio < 8.0, "Compression ratio should be ~7x")
    
    print("✓ Q4KMTensor struct passed")


# =============================================================================
# Test: Matmul with Q4_K_M
# =============================================================================

fn test_q4km_matmul():
    """Test matrix multiplication with Q4_K_M weights."""
    print("Testing: Q4_K_M matmul...")
    
    # Small dimensions for testing
    var M = 2  # Batch size
    var K = 256  # Hidden dim (must be multiple of QK_K for clean blocks)
    var N = 128  # Output dim
    
    # Create activations (FP32)
    var activations = UnsafePointer[Float32].alloc(M * K)
    for i in range(M * K):
        activations[i] = Float32(i % 10) / 10.0
    
    # Create Q4_K_M weights
    var weights = Q4KMTensor(K, N)
    var block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2
    
    # Initialize weights with known pattern
    for b in range(weights.num_blocks):
        var block_ptr = weights.data + b * block_size
        block_ptr.bitcast[UInt16]()[0] = Float16(0.1).to_bits()  # d = 0.1
        (block_ptr + 2).bitcast[UInt16]()[0] = Float16(0.0).to_bits()  # dmin = 0
        for i in range(K_SCALE_SIZE):
            (block_ptr + 4 + i)[0] = 1
        for i in range(QK_K // 2):
            (block_ptr + 4 + K_SCALE_SIZE + i)[0] = 0x11  # q_val = 1 for all
    
    # Allocate output
    var output = UnsafePointer[Float32].alloc(M * N)
    memset_zero(output.bitcast[UInt8](), M * N * 4)
    
    # Run matmul
    q4_k_m_matmul(activations, weights, output, M, K, N)
    
    # Check output is not all zeros
    var sum = Float32(0.0)
    for i in range(M * N):
        sum += math_abs(output[i])
    
    print("  Output sum: " + str(sum))
    assert_true(sum > 0.0, "Output should not be all zeros")
    
    activations.free()
    output.free()
    print("✓ Q4_K_M matmul passed")


# =============================================================================
# Main
# =============================================================================

fn main():
    print("=" * 60)
    print("Q4_K_M Dequantization Tests")
    print("=" * 60)
    print()
    
    test_block_structure()
    test_single_block_dequantize()
    test_multi_block_dequantize()
    test_simd_dequantize()
    test_q4km_tensor()
    test_q4km_matmul()
    
    print()
    print("=" * 60)
    print("All Q4_K_M tests passed! ✓")
    print("=" * 60)