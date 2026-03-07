# =============================================================================
# FFI Exports Unit Tests - AIPrompt Streaming
# =============================================================================
#
# Tests for the AIPrompt Streaming Mojo FFI exports.
# Covers checksum computation, cosine similarity, batch similarity, and LZ4.
#
# Run with: mojo test mojo/tests/test_ffi_exports.mojo
# =============================================================================

from memory import UnsafePointer
from testing import assert_true, assert_equal
from math import abs

# Import the module under test
from ..src.ffi_exports import (
    mojo_init,
    mojo_shutdown,
    mojo_compute_checksums,
    mojo_cosine_similarity,
    mojo_batch_similarity,
    mojo_compress_lz4,
    mojo_decompress_lz4,
    mojo_process_batch,
)


# =============================================================================
# TEST: Initialization
# =============================================================================

fn test_init_success():
    """Test that initialization returns success."""
    let result = mojo_init()
    assert_equal(result, 0, "Init should return 0 on success")
    mojo_shutdown()


# =============================================================================
# TEST: Checksum Computation
# =============================================================================

fn test_checksums_deterministic():
    """Test that checksums are deterministic for same input."""
    _ = mojo_init()
    
    # Create simple payload
    let payload = "Hello, World!"
    var payloads = UnsafePointer[UInt8].alloc(len(payload))
    for i in range(len(payload)):
        payloads[i] = ord(payload[i])
    
    var offsets = UnsafePointer[Int64].alloc(1)
    offsets[0] = 0
    
    var sizes = UnsafePointer[Int32].alloc(1)
    sizes[0] = Int32(len(payload))
    
    var checksums1 = UnsafePointer[UInt64].alloc(1)
    var checksums2 = UnsafePointer[UInt64].alloc(1)
    
    # Compute checksums twice
    let result1 = mojo_compute_checksums(payloads, offsets, sizes, 1, checksums1)
    let result2 = mojo_compute_checksums(payloads, offsets, sizes, 1, checksums2)
    
    assert_equal(result1, 0, "First checksum should succeed")
    assert_equal(result2, 0, "Second checksum should succeed")
    assert_equal(checksums1[0], checksums2[0], "Checksums should be deterministic")
    
    payloads.free()
    offsets.free()
    sizes.free()
    checksums1.free()
    checksums2.free()
    mojo_shutdown()


fn test_checksums_different_inputs():
    """Test that different inputs produce different checksums."""
    _ = mojo_init()
    
    # Two different payloads
    let payload1 = "Hello"
    let payload2 = "World"
    
    var payloads = UnsafePointer[UInt8].alloc(len(payload1) + len(payload2))
    for i in range(len(payload1)):
        payloads[i] = ord(payload1[i])
    for i in range(len(payload2)):
        payloads[len(payload1) + i] = ord(payload2[i])
    
    var offsets = UnsafePointer[Int64].alloc(2)
    offsets[0] = 0
    offsets[1] = Int64(len(payload1))
    
    var sizes = UnsafePointer[Int32].alloc(2)
    sizes[0] = Int32(len(payload1))
    sizes[1] = Int32(len(payload2))
    
    var checksums = UnsafePointer[UInt64].alloc(2)
    
    let result = mojo_compute_checksums(payloads, offsets, sizes, 2, checksums)
    
    assert_equal(result, 0, "Checksum should succeed")
    assert_true(checksums[0] != checksums[1], "Different inputs should have different checksums")
    
    payloads.free()
    offsets.free()
    sizes.free()
    checksums.free()
    mojo_shutdown()


# =============================================================================
# TEST: Cosine Similarity
# =============================================================================

fn test_cosine_similarity_same_vector():
    """Test that same vector has similarity 1.0."""
    _ = mojo_init()
    
    var vec_a = UnsafePointer[Float32].alloc(3)
    var vec_b = UnsafePointer[Float32].alloc(3)
    
    vec_a[0] = 1.0
    vec_a[1] = 0.0
    vec_a[2] = 0.0
    
    vec_b[0] = 1.0
    vec_b[1] = 0.0
    vec_b[2] = 0.0
    
    let similarity = mojo_cosine_similarity(vec_a, vec_b, 3)
    
    assert_true(abs(similarity - 1.0) < 0.001, "Same vector should have similarity ~1.0")
    
    vec_a.free()
    vec_b.free()
    mojo_shutdown()


fn test_cosine_similarity_orthogonal():
    """Test that orthogonal vectors have similarity 0.0."""
    _ = mojo_init()
    
    var vec_a = UnsafePointer[Float32].alloc(3)
    var vec_b = UnsafePointer[Float32].alloc(3)
    
    vec_a[0] = 1.0
    vec_a[1] = 0.0
    vec_a[2] = 0.0
    
    vec_b[0] = 0.0
    vec_b[1] = 1.0
    vec_b[2] = 0.0
    
    let similarity = mojo_cosine_similarity(vec_a, vec_b, 3)
    
    assert_true(abs(similarity) < 0.001, "Orthogonal vectors should have similarity ~0.0")
    
    vec_a.free()
    vec_b.free()
    mojo_shutdown()


fn test_cosine_similarity_opposite():
    """Test that opposite vectors have similarity -1.0."""
    _ = mojo_init()
    
    var vec_a = UnsafePointer[Float32].alloc(3)
    var vec_b = UnsafePointer[Float32].alloc(3)
    
    vec_a[0] = 1.0
    vec_a[1] = 0.0
    vec_a[2] = 0.0
    
    vec_b[0] = -1.0
    vec_b[1] = 0.0
    vec_b[2] = 0.0
    
    let similarity = mojo_cosine_similarity(vec_a, vec_b, 3)
    
    assert_true(abs(similarity + 1.0) < 0.001, "Opposite vectors should have similarity ~-1.0")
    
    vec_a.free()
    vec_b.free()
    mojo_shutdown()


# =============================================================================
# TEST: Batch Similarity
# =============================================================================

fn test_batch_similarity():
    """Test batch similarity computation."""
    _ = mojo_init()
    
    let dim = 4
    
    # Query vector
    var query = UnsafePointer[Float32].alloc(dim)
    query[0] = 1.0
    query[1] = 0.0
    query[2] = 0.0
    query[3] = 0.0
    
    # 3 vectors to compare against
    var vectors = UnsafePointer[Float32].alloc(dim * 3)
    
    # Vector 0: same as query
    vectors[0] = 1.0
    vectors[1] = 0.0
    vectors[2] = 0.0
    vectors[3] = 0.0
    
    # Vector 1: orthogonal
    vectors[4] = 0.0
    vectors[5] = 1.0
    vectors[6] = 0.0
    vectors[7] = 0.0
    
    # Vector 2: partially similar
    vectors[8] = 0.707
    vectors[9] = 0.707
    vectors[10] = 0.0
    vectors[11] = 0.0
    
    var scores = UnsafePointer[Float32].alloc(3)
    
    let result = mojo_batch_similarity(query, vectors, 3, dim, scores)
    
    assert_equal(result, 0, "Batch similarity should succeed")
    assert_true(abs(scores[0] - 1.0) < 0.001, "Same vector should score ~1.0")
    assert_true(abs(scores[1]) < 0.001, "Orthogonal should score ~0.0")
    assert_true(scores[2] > 0.5 and scores[2] < 0.8, "Partial should score ~0.707")
    
    query.free()
    vectors.free()
    scores.free()
    mojo_shutdown()


# =============================================================================
# TEST: LZ4 Compression/Decompression
# =============================================================================

fn test_lz4_roundtrip():
    """Test LZ4 compression and decompression roundtrip."""
    _ = mojo_init()
    
    let input_data = "Hello, this is a test message for LZ4 compression!"
    
    var input = UnsafePointer[UInt8].alloc(len(input_data))
    for i in range(len(input_data)):
        input[i] = ord(input_data[i])
    
    var compressed = UnsafePointer[UInt8].alloc(len(input_data) + 100)
    var decompressed = UnsafePointer[UInt8].alloc(len(input_data) + 100)
    
    # Compress
    let compressed_size = mojo_compress_lz4(input, Int32(len(input_data)), compressed, Int32(len(input_data) + 100))
    
    assert_true(compressed_size > 0, "Compression should produce output")
    
    # Decompress
    let decompressed_size = mojo_decompress_lz4(compressed, compressed_size, decompressed, Int32(len(input_data) + 100))
    
    assert_equal(decompressed_size, Int32(len(input_data)), "Decompressed size should match original")
    
    # Verify content
    for i in range(len(input_data)):
        assert_equal(decompressed[i], input[i], "Decompressed content should match original")
    
    input.free()
    compressed.free()
    decompressed.free()
    mojo_shutdown()


fn test_lz4_compress_small_buffer_error():
    """Test that compression fails with small output buffer."""
    _ = mojo_init()
    
    let input_data = "Test data"
    
    var input = UnsafePointer[UInt8].alloc(len(input_data))
    for i in range(len(input_data)):
        input[i] = ord(input_data[i])
    
    var compressed = UnsafePointer[UInt8].alloc(5)  # Too small (need input_size + 4)
    
    let result = mojo_compress_lz4(input, Int32(len(input_data)), compressed, 5)
    
    assert_equal(result, -2, "Should return -2 for buffer too small")
    
    input.free()
    compressed.free()
    mojo_shutdown()


fn test_lz4_decompress_invalid_input():
    """Test that decompression fails with invalid input."""
    _ = mojo_init()
    
    var input = UnsafePointer[UInt8].alloc(2)  # Too short for header
    var output = UnsafePointer[UInt8].alloc(100)
    
    let result = mojo_decompress_lz4(input, 2, output, 100)
    
    assert_equal(result, -2, "Should return -2 for invalid input size")
    
    input.free()
    output.free()
    mojo_shutdown()


# =============================================================================
# TEST: Batch Processing
# =============================================================================

fn test_process_batch_empty():
    """Test that empty batch returns 0."""
    _ = mojo_init()
    
    var payloads = UnsafePointer[UInt8].alloc(1)
    var offsets = UnsafePointer[Int64].alloc(1)
    var sizes = UnsafePointer[Int32].alloc(1)
    var output = UnsafePointer[UInt8].alloc(100)
    
    let result = mojo_process_batch(payloads, offsets, sizes, 0, output, 100)
    
    assert_equal(result, 0, "Empty batch should return 0")
    
    payloads.free()
    offsets.free()
    sizes.free()
    output.free()
    mojo_shutdown()


# =============================================================================
# Main Test Runner
# =============================================================================

fn main():
    print("=" * 60)
    print("AIPrompt Streaming - FFI Exports Tests")
    print("=" * 60)
    
    print("\n[TEST] Initialization...")
    test_init_success()
    print("  ✓ test_init_success")
    
    print("\n[TEST] Checksum Computation...")
    test_checksums_deterministic()
    print("  ✓ test_checksums_deterministic")
    
    test_checksums_different_inputs()
    print("  ✓ test_checksums_different_inputs")
    
    print("\n[TEST] Cosine Similarity...")
    test_cosine_similarity_same_vector()
    print("  ✓ test_cosine_similarity_same_vector")
    
    test_cosine_similarity_orthogonal()
    print("  ✓ test_cosine_similarity_orthogonal")
    
    test_cosine_similarity_opposite()
    print("  ✓ test_cosine_similarity_opposite")
    
    print("\n[TEST] Batch Similarity...")
    test_batch_similarity()
    print("  ✓ test_batch_similarity")
    
    print("\n[TEST] LZ4 Compression...")
    test_lz4_roundtrip()
    print("  ✓ test_lz4_roundtrip")
    
    test_lz4_compress_small_buffer_error()
    print("  ✓ test_lz4_compress_small_buffer_error")
    
    test_lz4_decompress_invalid_input()
    print("  ✓ test_lz4_decompress_invalid_input")
    
    print("\n[TEST] Batch Processing...")
    test_process_batch_empty()
    print("  ✓ test_process_batch_empty")
    
    print("\n" + "=" * 60)
    print("All tests passed! ✓")
    print("=" * 60)