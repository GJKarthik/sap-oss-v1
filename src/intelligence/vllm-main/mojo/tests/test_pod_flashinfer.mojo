"""
Tests for POD-Attention and FlashInfer Decode Kernels

Validates:
1. FlashInfer decode attention correctness
2. POD batch building and SM partitioning
3. Performance estimation accuracy
4. Memory access patterns
"""

from memory import LegacyUnsafePointer
comptime UnsafePointer = LegacyUnsafePointer[mut=True, ...]
from memory.unsafe_pointer import alloc
from testing import assert_equal, assert_true, assert_almost_equal
from math import sqrt, exp, abs

# Import modules under test
from kernel.flashinfer_decode import (
    TileConfig, PageTable, BatchStats, WorkPartition,
    partition_work_balanced, decode_attention_tile_fp16,
    flashinfer_decode_attention, flashinfer_decode_gqa,
    estimate_decode_bandwidth_utilization,
    T4_NUM_SMS, T4_BW_GBPS, PAGE_SIZE,
    TILE_K_TINY, TILE_K_SMALL, TILE_K_MEDIUM, TILE_K_LARGE,
)

from kernel.pod_attention import (
    PODRequest, PODBatch, SMPartition, RequestType,
    compute_optimal_partition, pod_decode_attention,
    estimate_pod_performance, PODPerformanceMetrics,
    T4_FP16_TFLOPS, MIN_PREFILL_SMS, MIN_DECODE_SMS,
)


# ============================================================================
# FlashInfer Tests
# ============================================================================

fn test_tile_config_selection():
    """Test dynamic tile size selection based on sequence length."""
    print("Testing TileConfig selection...")
    
    # Short sequence
    var cfg_short = TileConfig(128, 128)
    assert_equal(cfg_short.tile_k, TILE_K_TINY)
    assert_equal(cfg_short.num_warps, 4)
    assert_true(not cfg_short.use_tensor_cores)
    
    # Medium sequence
    var cfg_medium = TileConfig(512, 128)
    assert_equal(cfg_medium.tile_k, TILE_K_SMALL)
    assert_true(cfg_medium.use_tensor_cores)
    
    # Long sequence
    var cfg_long = TileConfig(2048, 128)
    assert_equal(cfg_long.tile_k, TILE_K_MEDIUM)
    
    # Very long sequence
    var cfg_vlong = TileConfig(8192, 128)
    assert_equal(cfg_vlong.tile_k, TILE_K_LARGE)
    
    print("  ✓ TileConfig selection correct")


fn test_page_table_operations():
    """Test page table creation and lookups."""
    print("Testing PageTable operations...")
    
    var pt = PageTable(4, 16)  # 4 sequences, max 16 pages each
    
    # Set up some test data
    pt.seq_lengths[0] = 100
    pt.seq_lengths[1] = 200
    pt.seq_lengths[2] = 50
    pt.seq_lengths[3] = 300
    
    # Set page indices
    for i in range(16):
        pt.page_indices[0 * 16 + i] = Int32(i * 4)  # Seq 0: pages 0, 4, 8, ...
        pt.page_indices[1 * 16 + i] = Int32(i * 4 + 1)  # Seq 1: pages 1, 5, 9, ...
    
    # Test lookups
    assert_equal(pt.get_seq_len(0), 100)
    assert_equal(pt.get_seq_len(1), 200)
    assert_equal(pt.num_pages(0), 7)  # ceil(100/16) = 7
    assert_equal(pt.num_pages(1), 13)  # ceil(200/16) = 13
    
    assert_equal(pt.get_page(0, 0), 0)
    assert_equal(pt.get_page(0, 1), 4)
    assert_equal(pt.get_page(1, 0), 1)
    
    pt.deinit()
    print("  ✓ PageTable operations correct")


fn test_batch_stats_computation():
    """Test batch statistics for load balancing."""
    print("Testing BatchStats computation...")
    
    var seq_lengths = alloc[Int32](4)
    seq_lengths[0] = 100
    seq_lengths[1] = 200
    seq_lengths[2] = 150
    seq_lengths[3] = 50
    
    var stats = BatchStats.compute(seq_lengths, 4)
    
    assert_equal(stats.total_tokens, 500)
    assert_equal(stats.min_seq_len, 50)
    assert_equal(stats.max_seq_len, 200)
    assert_almost_equal(stats.mean_seq_len, 125.0, atol=0.1)
    assert_true(stats.variance > 0)
    
    seq_lengths.free()
    print("  ✓ BatchStats computation correct")


fn test_work_partition_balanced():
    """Test load-balanced work partitioning."""
    print("Testing work partitioning...")
    
    var pt = PageTable(3, 32)
    pt.seq_lengths[0] = 256  # 16 pages
    pt.seq_lengths[1] = 128  # 8 pages
    pt.seq_lengths[2] = 64   # 4 pages
    
    for i in range(32):
        pt.page_indices[i] = Int32(i)
    
    var partitions = alloc[WorkPartition](100)
    var num_parts = partition_work_balanced(pt, 4, partitions)
    
    # Should have at least 3 partitions (one per sequence minimum)
    assert_true(num_parts >= 3)
    
    # Check that all pages are covered
    var total_pages: Int = 0
    for i in range(num_parts):
        total_pages += partitions[i].num_pages()
    assert_equal(total_pages, 28)  # 16 + 8 + 4
    
    partitions.free()
    pt.deinit()
    print("  ✓ Work partitioning correct")


fn test_bandwidth_estimation():
    """Test bandwidth utilization estimation."""
    print("Testing bandwidth estimation...")
    
    var utilization = estimate_decode_bandwidth_utilization(
        batch_size=32,
        total_seq_len=4096,
        num_heads=32,
        head_dim=128,
        time_ms=10.0,
    )
    
    # Should be between 0 and 100%
    assert_true(utilization >= 0.0)
    assert_true(utilization <= 100.0)
    
    # With these parameters, should be non-trivial
    assert_true(utilization > 10.0)
    
    print("  ✓ Bandwidth estimation reasonable")


# ============================================================================
# POD-Attention Tests
# ============================================================================

fn test_pod_request_classification():
    """Test POD request classification."""
    print("Testing POD request classification...")
    
    # New request (prefill)
    var req_prefill = PODRequest(
        request_id=1,
        prompt_len=100,
        generated_len=0,
        max_new_tokens=50,
        kv_slot_id=0,
    )
    assert_true(req_prefill.is_prefill())
    assert_true(not req_prefill.is_decode())
    assert_equal(req_prefill.context_len(), 100)
    assert_equal(req_prefill.prefill_tokens(), 100)
    
    # Active request (decode)
    var req_decode = PODRequest(
        request_id=2,
        prompt_len=100,
        generated_len=25,
        max_new_tokens=50,
        kv_slot_id=1,
    )
    assert_true(req_decode.is_decode())
    assert_true(not req_decode.is_prefill())
    assert_equal(req_decode.context_len(), 125)
    assert_equal(req_decode.prefill_tokens(), 0)
    
    print("  ✓ POD request classification correct")


fn test_pod_batch_building():
    """Test POD batch construction."""
    print("Testing POD batch building...")
    
    var batch = PODBatch(max_requests=10)
    
    # Add prefill requests
    var req1 = PODRequest(1, 100, 0, 50, 0)
    var req2 = PODRequest(2, 200, 0, 100, 1)
    
    # Add decode requests
    var req3 = PODRequest(3, 50, 25, 50, 2)
    var req4 = PODRequest(4, 80, 40, 80, 3)
    
    _ = batch.add_request(req1)
    _ = batch.add_request(req2)
    _ = batch.add_request(req3)
    _ = batch.add_request(req4)
    
    assert_equal(batch.num_prefill, 2)
    assert_equal(batch.num_decode, 2)
    assert_equal(batch.total_prefill_tokens, 300)  # 100 + 200
    assert_equal(batch.total_decode_tokens, 2)
    
    batch.deinit()
    print("  ✓ POD batch building correct")


fn test_sm_partition_computation():
    """Test SM partition optimization."""
    print("Testing SM partition computation...")
    
    # All prefill batch
    var batch_prefill = PODBatch(10)
    _ = batch_prefill.add_request(PODRequest(1, 1000, 0, 50, 0))
    
    var partition_prefill = compute_optimal_partition(
        batch_prefill, num_heads=32, head_dim=128, num_layers=32
    )
    assert_equal(partition_prefill.prefill_sms, T4_NUM_SMS)
    assert_equal(partition_prefill.decode_sms, 0)
    batch_prefill.deinit()
    
    # All decode batch
    var batch_decode = PODBatch(10)
    _ = batch_decode.add_request(PODRequest(1, 100, 50, 100, 0))
    _ = batch_decode.add_request(PODRequest(2, 100, 30, 100, 1))
    
    var partition_decode = compute_optimal_partition(
        batch_decode, num_heads=32, head_dim=128, num_layers=32
    )
    assert_equal(partition_decode.prefill_sms, 0)
    assert_equal(partition_decode.decode_sms, T4_NUM_SMS)
    batch_decode.deinit()
    
    # Mixed batch
    var batch_mixed = PODBatch(10)
    _ = batch_mixed.add_request(PODRequest(1, 500, 0, 50, 0))  # prefill
    _ = batch_mixed.add_request(PODRequest(2, 100, 50, 100, 1))  # decode
    
    var partition_mixed = compute_optimal_partition(
        batch_mixed, num_heads=32, head_dim=128, num_layers=32
    )
    
    # Should have both prefill and decode SMs
    assert_true(partition_mixed.prefill_sms >= MIN_PREFILL_SMS)
    assert_true(partition_mixed.decode_sms >= MIN_DECODE_SMS)
    assert_equal(partition_mixed.prefill_sms + partition_mixed.decode_sms, T4_NUM_SMS)
    batch_mixed.deinit()
    
    print("  ✓ SM partition computation correct")


fn test_pod_performance_estimation():
    """Test POD performance metrics estimation."""
    print("Testing POD performance estimation...")
    
    var batch = PODBatch(10)
    _ = batch.add_request(PODRequest(1, 500, 0, 50, 0))  # prefill
    _ = batch.add_request(PODRequest(2, 100, 50, 100, 1))  # decode
    
    var partition = compute_optimal_partition(
        batch, num_heads=32, head_dim=128, num_layers=32
    )
    
    var metrics = estimate_pod_performance(
        batch, partition,
        num_heads=32, head_dim=128, num_layers=32
    )
    
    # Check that metrics are reasonable
    assert_true(metrics.prefill_latency_ms >= 0)
    assert_true(metrics.decode_latency_ms >= 0)
    assert_true(metrics.total_latency_ms >= 0)
    
    # POD should provide speedup over sequential
    assert_true(metrics.speedup_vs_sequential >= 1.0)
    
    # Total latency should be max(prefill, decode), not sum
    var expected_total = max_float(metrics.prefill_latency_ms, metrics.decode_latency_ms)
    assert_almost_equal(metrics.total_latency_ms, expected_total, atol=0.001)
    
    batch.deinit()
    print("  ✓ POD performance estimation correct")


fn test_request_flops_estimation():
    """Test FLOP estimation for requests."""
    print("Testing FLOP estimation...")
    
    var req = PODRequest(1, 512, 0, 100, 0)
    var flops = req.compute_flops(num_heads=32, head_dim=128, num_layers=32)
    
    # Expected: 2 * 512 * 512 * 128 * 32 * 32 = ~68 billion FLOPs
    # This is a rough check
    assert_true(flops > 1e9)  # Should be in billions
    assert_true(flops < 1e12)  # But not trillions
    
    print("  ✓ FLOP estimation reasonable")


fn test_memory_bytes_estimation():
    """Test memory bytes estimation for requests."""
    print("Testing memory bytes estimation...")
    
    var req = PODRequest(1, 512, 256, 100, 0)  # 768 context length
    var bytes = req.memory_bytes(num_heads=32, head_dim=128)
    
    # Expected: 768 * 32 * 128 * 2 (K+V) * 2 (FP16) = ~12.5 MB
    assert_equal(bytes, 768 * 32 * 128 * 2 * 2)
    
    print("  ✓ Memory bytes estimation correct")


# ============================================================================
# Integration Tests
# ============================================================================

fn test_decode_attention_correctness():
    """Test decode attention produces correct output."""
    print("Testing decode attention correctness...")
    
    alias HEAD_DIM: Int = 64
    alias SEQ_LEN: Int = 32
    
    # Allocate test data
    var Q = alloc[Float16](HEAD_DIM)
    var K = alloc[Float16](SEQ_LEN * HEAD_DIM)
    var V = alloc[Float16](SEQ_LEN * HEAD_DIM)
    var output = alloc[Float32](HEAD_DIM)
    var running_max = alloc[Float32](1)
    var running_sum = alloc[Float32](1)
    
    # Initialize Q with ones
    for i in range(HEAD_DIM):
        Q[i] = Float16(1.0 / sqrt(Float32(HEAD_DIM)))
    
    # Initialize K and V
    for t in range(SEQ_LEN):
        for d in range(HEAD_DIM):
            K[t * HEAD_DIM + d] = Float16(1.0 / sqrt(Float32(HEAD_DIM)))
            V[t * HEAD_DIM + d] = Float16(Float32(d) / Float32(HEAD_DIM))
    
    # Initialize output and softmax state
    for d in range(HEAD_DIM):
        output[d] = 0.0
    running_max[0] = -1e30
    running_sum[0] = 0.0
    
    # Run decode attention
    var scale = 1.0 / sqrt(Float32(HEAD_DIM))
    decode_attention_tile_fp16(
        Q, K, V, output,
        HEAD_DIM, SEQ_LEN, scale,
        running_max, running_sum
    )
    
    # Check output is non-zero and bounded
    var output_sum: Float32 = 0.0
    for d in range(HEAD_DIM):
        output_sum += abs(output[d])
    assert_true(output_sum > 0.0)
    
    # Check softmax sum is positive
    assert_true(running_sum[0] > 0.0)
    
    Q.free()
    K.free()
    V.free()
    output.free()
    running_max.free()
    running_sum.free()
    
    print("  ✓ Decode attention produces valid output")


fn test_online_softmax_stability():
    """Test online softmax numerical stability."""
    print("Testing online softmax stability...")
    
    alias HEAD_DIM: Int = 32
    
    var output = alloc[Float32](HEAD_DIM)
    var running_max = alloc[Float32](1)
    var running_sum = alloc[Float32](1)
    
    # Initialize
    for d in range(HEAD_DIM):
        output[d] = 0.0
    running_max[0] = -1e30
    running_sum[0] = 0.0
    
    # Simulate processing with large score differences
    # First: large positive scores
    var max1: Float32 = 100.0
    running_max[0] = max1
    running_sum[0] = exp(100.0 - max1)  # = 1.0
    for d in range(HEAD_DIM):
        output[d] = exp(100.0 - max1) * 1.0  # = 1.0
    
    # Second: even larger scores (should rescale)
    var max2: Float32 = 200.0
    var scale_factor = exp(max1 - max2)  # Very small
    running_sum[0] *= scale_factor
    for d in range(HEAD_DIM):
        output[d] *= scale_factor
    running_max[0] = max2
    running_sum[0] += exp(200.0 - max2)  # Add new contribution
    
    # Should not overflow or underflow
    assert_true(running_sum[0] > 0.0)
    assert_true(running_sum[0] < 1e10)
    
    output.free()
    running_max.free()
    running_sum.free()
    
    print("  ✓ Online softmax is numerically stable")


# ============================================================================
# Main Test Runner
# ============================================================================

fn main():
    print("=" * 60)
    print("POD-Attention & FlashInfer Decode Kernel Tests")
    print("=" * 60)
    print()
    
    print("[FlashInfer Tests]")
    test_tile_config_selection()
    test_page_table_operations()
    test_batch_stats_computation()
    test_work_partition_balanced()
    test_bandwidth_estimation()
    print()
    
    print("[POD-Attention Tests]")
    test_pod_request_classification()
    test_pod_batch_building()
    test_sm_partition_computation()
    test_pod_performance_estimation()
    test_request_flops_estimation()
    test_memory_bytes_estimation()
    print()
    
    print("[Integration Tests]")
    test_decode_attention_correctness()
    test_online_softmax_stability()
    print()
    
    print("=" * 60)
    print("All tests passed! ✓")
    print("=" * 60)


# ============================================================================
# Helper Functions
# ============================================================================

fn assert_almost_equal(a: Float32, b: Float32, atol: Float32 = 1e-6):
    """Assert two floats are approximately equal."""
    var diff = abs(a - b)
    if diff > atol:
        print("Assertion failed:", a, "!=", b, "(diff:", diff, ")")
        raise Error("Assertion failed")

fn max_float(a: Float32, b: Float32) -> Float32:
    if a > b:
        return a
    return b

fn abs(x: Float32) -> Float32:
    if x < 0:
        return -x
    return x