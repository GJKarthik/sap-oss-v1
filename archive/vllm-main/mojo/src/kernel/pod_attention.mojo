"""
POD-Attention: Prefill-Or-Decode Fused Attention Kernel for T4 GPU

Implements the POD-Attention algorithm from ASPLOS 2025:
- Processes both prefill and decode requests in a single kernel call
- Utilizes both compute (prefill) and memory bandwidth (decode) simultaneously
- Dynamically partitions SMs between workloads based on batch composition
- Achieves up to 42% P99 latency reduction on hybrid batches

Key insight: Prefill is compute-bound, decode is memory-bound. Running them
on separate SMs allows both to proceed at near-optimal throughput.

Reference: "POD-Attention: Efficient Prefill-or-Decode Attention" (ASPLOS 2025)

Optimized for NVIDIA T4:
- 40 SMs to partition between prefill and decode
- 320 GB/s GDDR6 (decode bound)
- 65 TFLOPS FP16 / 130 TOPS INT8 (prefill bound)
"""

from memory import LegacyUnsafePointer
comptime UnsafePointer = LegacyUnsafePointer[mut=True, ...]
from memory.unsafe_pointer import alloc
from algorithm.functional import vectorize
from math import sqrt, exp, max as math_max, min as math_min, ceil
from sys.info import simd_width_of

# ============================================================================
# T4 Hardware Constants
# ============================================================================

alias T4_NUM_SMS: Int = 40
alias T4_WARP_SIZE: Int = 32
alias T4_SHMEM_SIZE: Int = 49152   # 48 KB
alias T4_FP16_TFLOPS: Float32 = 65.0
alias T4_BW_GBPS: Float32 = 320.0

# POD Scheduling Constants
alias MIN_PREFILL_SMS: Int = 4     # Minimum SMs reserved for prefill
alias MIN_DECODE_SMS: Int = 4      # Minimum SMs reserved for decode
alias PAGE_SIZE: Int = 16          # Tokens per KV cache page


# ============================================================================
# Request Classification
# ============================================================================

@value
struct RequestType:
    """Request type enumeration."""
    alias PREFILL: Int = 0
    alias DECODE: Int = 1


struct PODRequest:
    """
    A request in a POD batch.
    
    Contains metadata to classify as prefill or decode and
    track resource requirements.
    """
    var request_id: Int
    var request_type: Int           # RequestType.PREFILL or RequestType.DECODE
    var prompt_len: Int             # Number of prompt tokens (prefill)
    var generated_len: Int          # Tokens generated so far
    var max_new_tokens: Int         # Maximum new tokens to generate
    var kv_slot_id: Int             # Slot in KV cache
    var priority: Int               # Scheduling priority (higher = more urgent)
    
    fn __init__(out self, request_id: Int, prompt_len: Int, generated_len: Int, max_new_tokens: Int, kv_slot_id: Int):
        self.request_id = request_id
        self.prompt_len = prompt_len
        self.generated_len = generated_len
        self.max_new_tokens = max_new_tokens
        self.kv_slot_id = kv_slot_id
        self.priority = 5  # Default priority
        
        # Classify: if no tokens generated yet, it's prefill
        if generated_len == 0:
            self.request_type = RequestType.PREFILL
        else:
            self.request_type = RequestType.DECODE
    
    fn is_prefill(self) -> Bool:
        return self.request_type == RequestType.PREFILL
    
    fn is_decode(self) -> Bool:
        return self.request_type == RequestType.DECODE
    
    fn context_len(self) -> Int:
        """Total context length (prompt + generated)."""
        return self.prompt_len + self.generated_len
    
    fn prefill_tokens(self) -> Int:
        """Tokens to process in prefill phase."""
        if self.is_prefill():
            return self.prompt_len
        return 0
    
    fn compute_flops(self, num_heads: Int, head_dim: Int, num_layers: Int) -> Float32:
        """Estimate compute FLOPs for this request."""
        var seq_len = self.prefill_tokens() if self.is_prefill() else 1
        var ctx_len = self.context_len()
        
        # Attention: 2 * seq_len * ctx_len * head_dim * num_heads * num_layers
        # (Q@K^T + softmax@V, both directions)
        var attn_flops = 2.0 * Float32(seq_len) * Float32(ctx_len) * Float32(head_dim) * Float32(num_heads) * Float32(num_layers)
        
        return attn_flops
    
    fn memory_bytes(self, num_heads: Int, head_dim: Int) -> Int:
        """Estimate memory bytes accessed for this request."""
        var ctx_len = self.context_len()
        # KV cache read: ctx_len * num_heads * head_dim * 2 (K+V) * 2 (FP16)
        return ctx_len * num_heads * head_dim * 2 * 2


# ============================================================================
# POD Batch
# ============================================================================

struct PODBatch:
    """
    A batch containing both prefill and decode requests.
    """
    var requests: UnsafePointer[PODRequest]
    var num_requests: Int
    var max_requests: Int
    
    # Precomputed indices for fast access
    var prefill_indices: UnsafePointer[Int]
    var decode_indices: UnsafePointer[Int]
    var num_prefill: Int
    var num_decode: Int
    
    # Aggregate statistics
    var total_prefill_tokens: Int
    var total_decode_tokens: Int
    var total_kv_tokens: Int
    
    fn __init__(out self, max_requests: Int):
        self.max_requests = max_requests
        self.num_requests = 0
        self.requests = alloc[PODRequest](max_requests)
        self.prefill_indices = alloc[Int](max_requests)
        self.decode_indices = alloc[Int](max_requests)
        self.num_prefill = 0
        self.num_decode = 0
        self.total_prefill_tokens = 0
        self.total_decode_tokens = 0
        self.total_kv_tokens = 0
    
    fn add_request(mut self, req: PODRequest) -> Bool:
        """Add a request to the batch. Returns False if batch is full."""
        if self.num_requests >= self.max_requests:
            return False
        
        self.requests[self.num_requests] = req
        
        if req.is_prefill():
            self.prefill_indices[self.num_prefill] = self.num_requests
            self.num_prefill += 1
            self.total_prefill_tokens += req.prefill_tokens()
        else:
            self.decode_indices[self.num_decode] = self.num_requests
            self.num_decode += 1
            self.total_decode_tokens += 1
        
        self.total_kv_tokens += req.context_len()
        self.num_requests += 1
        return True
    
    fn get_prefill_request(self, idx: Int) -> PODRequest:
        """Get prefill request by index in prefill list."""
        return self.requests[self.prefill_indices[idx]]
    
    fn get_decode_request(self, idx: Int) -> PODRequest:
        """Get decode request by index in decode list."""
        return self.requests[self.decode_indices[idx]]
    
    fn deinit(mut self):
        self.requests.free()
        self.prefill_indices.free()
        self.decode_indices.free()


# ============================================================================
# SM Partition Calculator
# ============================================================================

struct SMPartition:
    """Partition of T4's 40 SMs between prefill and decode workloads."""
    var prefill_sms: Int
    var decode_sms: Int
    var prefill_start_sm: Int
    var decode_start_sm: Int
    
    fn __init__(out self, prefill_sms: Int, decode_sms: Int):
        self.prefill_sms = prefill_sms
        self.decode_sms = decode_sms
        self.prefill_start_sm = 0
        self.decode_start_sm = prefill_sms


fn compute_optimal_partition(
    batch: PODBatch,
    num_heads: Int,
    head_dim: Int,
    num_layers: Int,
) -> SMPartition:
    """
    Compute optimal SM partition based on workload balance.
    
    Strategy:
    1. Estimate compute time for prefill (FLOPs / TFLOPS)
    2. Estimate memory time for decode (bytes / bandwidth)
    3. Allocate SMs proportionally to balance completion times
    
    Goal: Both prefill and decode complete at the same time.
    """
    if batch.num_prefill == 0:
        # All decode: give all SMs to decode
        return SMPartition(0, T4_NUM_SMS)
    
    if batch.num_decode == 0:
        # All prefill: give all SMs to prefill
        return SMPartition(T4_NUM_SMS, 0)
    
    # Estimate prefill compute time (on all T4 SMs)
    var total_prefill_flops: Float32 = 0.0
    for i in range(batch.num_prefill):
        var req = batch.get_prefill_request(i)
        total_prefill_flops += req.compute_flops(num_heads, head_dim, num_layers)
    
    # Time = FLOPs / (TFLOPS * 1e12) in seconds
    var prefill_time_full = total_prefill_flops / (T4_FP16_TFLOPS * 1e12)
    
    # Estimate decode memory time (on all T4 bandwidth)
    var total_decode_bytes: Int = 0
    for i in range(batch.num_decode):
        var req = batch.get_decode_request(i)
        total_decode_bytes += req.memory_bytes(num_heads, head_dim)
    
    # Time = bytes / (GB/s * 1e9) in seconds
    var decode_time_full = Float32(total_decode_bytes) / (T4_BW_GBPS * 1e9)
    
    # Ratio of prefill to decode time
    # More prefill time → allocate more SMs to prefill
    var total_time = prefill_time_full + decode_time_full
    if total_time == 0:
        return SMPartition(T4_NUM_SMS // 2, T4_NUM_SMS // 2)
    
    var prefill_fraction = prefill_time_full / total_time
    
    # Convert to SM counts with minimums
    var prefill_sms = Int(Float32(T4_NUM_SMS) * prefill_fraction)
    prefill_sms = max_int(MIN_PREFILL_SMS, min_int(prefill_sms, T4_NUM_SMS - MIN_DECODE_SMS))
    var decode_sms = T4_NUM_SMS - prefill_sms
    
    return SMPartition(prefill_sms, decode_sms)


# ============================================================================
# Prefill Attention Kernel (Compute-Bound)
# ============================================================================

fn pod_prefill_attention[
    o_q: MutOrigin, o_k: MutOrigin, o_v: MutOrigin, o_out: MutOrigin, o_k_cache: MutOrigin, o_v_cache: MutOrigin
](
    Q: UnsafePointer[Float16, origin=o_q],           # [seq_len, num_heads, head_dim]
    K: UnsafePointer[Float16, origin=o_k],           # [seq_len, num_heads, head_dim]
    V: UnsafePointer[Float16, origin=o_v],           # [seq_len, num_heads, head_dim]
    output: UnsafePointer[Float16, origin=o_out],    # [seq_len, num_heads, head_dim]
    K_cache: UnsafePointer[Float16, origin=o_k_cache], # KV cache to append to
    V_cache: UnsafePointer[Float16, origin=o_v_cache],
    seq_len: Int,
    num_heads: Int,
    head_dim: Int,
    kv_slot_id: Int,
    cache_offset: Int,  # Where to write in KV cache
):
    """
    Prefill attention with KV cache write.
    
    Compute-bound path optimized for:
    - Tiled GEMM for Q @ K^T
    - Fused softmax
    - Tiled GEMM for attn @ V
    - Coalesced KV cache writes
    """
    var scale = 1.0 / sqrt(Float32(head_dim))
    
    # Tile sizes for T4 SHMEM (48KB)
    alias TILE_Q: Int = 64
    alias TILE_K: Int = 64
    
    # Process each head independently
    for h in range(num_heads):
        # For each query tile
        var q_tiles = (seq_len + TILE_Q - 1) // TILE_Q
        
        for qt in range(q_tiles):
            var q_start = qt * TILE_Q
            var q_end = min_int(q_start + TILE_Q, seq_len)
            var q_len = q_end - q_start
            
            # Allocate attention scores and output accumulators
            var scores = alloc[Float32](q_len * seq_len)
            var max_scores = alloc[Float32](q_len)
            var sum_scores = alloc[Float32](q_len)
            var output_acc = alloc[Float32](q_len * head_dim)
            
            # Initialize
            for i in range(q_len):
                max_scores[i] = -1e30
                sum_scores[i] = 0.0
            for i in range(q_len * head_dim):
                output_acc[i] = 0.0
            
            # Compute Q @ K^T for all K tiles
            var k_tiles = (seq_len + TILE_K - 1) // TILE_K
            
            for kt in range(k_tiles):
                var k_start = kt * TILE_K
                var k_end = min_int(k_start + TILE_K, seq_len)
                var k_len = k_end - k_start
                
                # Compute dot products
                for qi in range(q_len):
                    for ki in range(k_len):
                        var dot: Float32 = 0.0
                        var q_offset = (q_start + qi) * num_heads * head_dim + h * head_dim
                        var k_offset = (k_start + ki) * num_heads * head_dim + h * head_dim
                        
                        for d in range(head_dim):
                            dot += Float32(Q[q_offset + d]) * Float32(K[k_offset + d])
                        
                        # Apply causal mask: q can only attend to k if k_pos <= q_pos
                        var q_pos = q_start + qi
                        var k_pos = k_start + ki
                        if k_pos <= q_pos:
                            scores[qi * seq_len + k_start + ki] = dot * scale
                        else:
                            scores[qi * seq_len + k_start + ki] = -1e30
                
                # Update running max
                for qi in range(q_len):
                    for ki in range(k_len):
                        var s = scores[qi * seq_len + k_start + ki]
                        if s > max_scores[qi]:
                            max_scores[qi] = s
            
            # Compute softmax and accumulate output
            for qi in range(q_len):
                var local_sum: Float32 = 0.0
                
                # Compute exp and sum
                for ki in range(seq_len):
                    var s = scores[qi * seq_len + ki]
                    var exp_s = exp(s - max_scores[qi])
                    scores[qi * seq_len + ki] = exp_s
                    local_sum += exp_s
                
                sum_scores[qi] = local_sum
                
                # Compute weighted sum of V
                if local_sum > 0:
                    var inv_sum = 1.0 / local_sum
                    for ki in range(seq_len):
                        var weight = scores[qi * seq_len + ki] * inv_sum
                        var v_offset = ki * num_heads * head_dim + h * head_dim
                        
                        for d in range(head_dim):
                            output_acc[qi * head_dim + d] += weight * Float32(V[v_offset + d])
            
            # Write output
            for qi in range(q_len):
                var out_offset = (q_start + qi) * num_heads * head_dim + h * head_dim
                for d in range(head_dim):
                    output[out_offset + d] = Float16(output_acc[qi * head_dim + d])
            
            scores.free()
            max_scores.free()
            sum_scores.free()
            output_acc.free()
    
    # Write KV to cache
    for i in range(seq_len):
        var src_offset = i * num_heads * head_dim
        var dst_offset = (cache_offset + i) * num_heads * head_dim
        for j in range(num_heads * head_dim):
            K_cache[dst_offset + j] = K[src_offset + j]
            V_cache[dst_offset + j] = V[src_offset + j]


# ============================================================================
# Decode Attention Kernel (Memory-Bound)
# ============================================================================

fn pod_decode_attention[
    o_q: MutOrigin, o_k_cache: MutOrigin, o_v_cache: MutOrigin, o_out: MutOrigin
](
    Q: UnsafePointer[Float16, origin=o_q],              # [1, num_heads, head_dim]
    K_cache: UnsafePointer[Float16, origin=o_k_cache], # [max_seq, num_heads, head_dim]
    V_cache: UnsafePointer[Float16, origin=o_v_cache], # [max_seq, num_heads, head_dim]
    output: UnsafePointer[Float16, origin=o_out],      # [1, num_heads, head_dim]
    seq_len: Int,  # Current context length
    num_heads: Int,
    head_dim: Int,
    cache_offset: Int,  # Start of this sequence's KV in cache
):
    """
    Decode attention for a single query token.
    
    Memory-bound path optimized for:
    - Sequential KV cache reads (maximize bandwidth)
    - Minimal compute per byte
    - Online softmax to avoid second pass
    """
    var scale = 1.0 / sqrt(Float32(head_dim))
    
    for h in range(num_heads):
        var q_offset = h * head_dim
        
        # Online softmax state
        var running_max: Float32 = -1e30
        var running_sum: Float32 = 0.0
        var output_acc = alloc[Float32](head_dim)
        for d in range(head_dim):
            output_acc[d] = 0.0
        
        # Stream through KV cache
        for pos in range(seq_len):
            var kv_offset = (cache_offset + pos) * num_heads * head_dim + h * head_dim
            
            # Compute attention score
            var dot: Float32 = 0.0
            for d in range(head_dim):
                dot += Float32(Q[q_offset + d]) * Float32(K_cache[kv_offset + d])
            var score = dot * scale
            
            # Online softmax update
            if score > running_max:
                var scale_factor = exp(running_max - score)
                running_sum *= scale_factor
                for d in range(head_dim):
                    output_acc[d] *= scale_factor
                running_max = score
            
            var exp_score = exp(score - running_max)
            running_sum += exp_score
            
            # Accumulate weighted V
            for d in range(head_dim):
                output_acc[d] += exp_score * Float32(V_cache[kv_offset + d])
        
        # Normalize and write output
        if running_sum > 0:
            var inv_sum = 1.0 / running_sum
            for d in range(head_dim):
                output[q_offset + d] = Float16(output_acc[d] * inv_sum)
        else:
            for d in range(head_dim):
                output[q_offset + d] = Float16(0.0)
        
        output_acc.free()


# ============================================================================
# POD Fused Kernel Entry Point
# ============================================================================

struct PODKernelConfig:
    """Configuration for POD kernel execution."""
    var partition: SMPartition
    var tile_size_prefill: Int
    var tile_size_decode: Int
    var use_tensor_cores: Bool
    
    fn __init__(out self, partition: SMPartition):
        self.partition = partition
        self.tile_size_prefill = 64
        self.tile_size_decode = 128
        self.use_tensor_cores = True


fn pod_attention_fused[
    o_q: MutOrigin, o_k: MutOrigin, o_v: MutOrigin, 
    o_out: MutOrigin, o_k_cache: MutOrigin, o_v_cache: MutOrigin
](
    # Prefill inputs (may be empty)
    Q_prefill: UnsafePointer[Float16, origin=o_q],
    K_prefill: UnsafePointer[Float16, origin=o_k],
    V_prefill: UnsafePointer[Float16, origin=o_v],
    output_prefill: UnsafePointer[Float16, origin=o_out],
    
    # Decode inputs
    Q_decode: UnsafePointer[Float16, origin=o_q],
    output_decode: UnsafePointer[Float16, origin=o_out],
    
    # Shared KV cache
    K_cache: UnsafePointer[Float16, origin=o_k_cache],
    V_cache: UnsafePointer[Float16, origin=o_v_cache],
    
    # Batch metadata
    batch: PODBatch,
    
    # Model config
    num_heads: Int,
    head_dim: Int,
    num_layers: Int,
    max_seq_len: Int,
):
    """
    POD-Attention fused kernel.
    
    Executes prefill and decode attention in a single dispatch:
    1. Compute optimal SM partition
    2. Launch prefill work on prefill SMs
    3. Launch decode work on decode SMs
    4. Synchronize and return
    
    In a real GPU implementation, steps 2-3 would be concurrent.
    This reference implementation serializes for correctness verification.
    """
    # Compute SM partition
    var partition = compute_optimal_partition(batch, num_heads, head_dim, num_layers)
    var config = PODKernelConfig(partition)
    
    # Process prefill requests
    var prefill_output_offset: Int = 0
    var prefill_input_offset: Int = 0
    
    for i in range(batch.num_prefill):
        var req = batch.get_prefill_request(i)
        var seq_len = req.prefill_tokens()
        var cache_offset = req.kv_slot_id * max_seq_len
        
        pod_prefill_attention(
            Q_prefill + prefill_input_offset * num_heads * head_dim,
            K_prefill + prefill_input_offset * num_heads * head_dim,
            V_prefill + prefill_input_offset * num_heads * head_dim,
            output_prefill + prefill_output_offset * num_heads * head_dim,
            K_cache,
            V_cache,
            seq_len,
            num_heads,
            head_dim,
            req.kv_slot_id,
            cache_offset,
        )
        
        prefill_input_offset += seq_len
        prefill_output_offset += seq_len
    
    # Process decode requests
    for i in range(batch.num_decode):
        var req = batch.get_decode_request(i)
        var ctx_len = req.context_len()
        var cache_offset = req.kv_slot_id * max_seq_len
        
        pod_decode_attention(
            Q_decode + i * num_heads * head_dim,
            K_cache,
            V_cache,
            output_decode + i * num_heads * head_dim,
            ctx_len,
            num_heads,
            head_dim,
            cache_offset,
        )


# ============================================================================
# Performance Estimation
# ============================================================================

struct PODPerformanceMetrics:
    """Performance metrics for POD execution."""
    var prefill_utilization: Float32   # Compute utilization (0-100%)
    var decode_utilization: Float32    # Bandwidth utilization (0-100%)
    var overall_efficiency: Float32    # Combined efficiency
    var prefill_latency_ms: Float32
    var decode_latency_ms: Float32
    var total_latency_ms: Float32
    var speedup_vs_sequential: Float32
    
    fn __init__(out self):
        self.prefill_utilization = 0.0
        self.decode_utilization = 0.0
        self.overall_efficiency = 0.0
        self.prefill_latency_ms = 0.0
        self.decode_latency_ms = 0.0
        self.total_latency_ms = 0.0
        self.speedup_vs_sequential = 1.0


fn estimate_pod_performance(
    batch: PODBatch,
    partition: SMPartition,
    num_heads: Int,
    head_dim: Int,
    num_layers: Int,
) -> PODPerformanceMetrics:
    """
    Estimate performance metrics for a POD batch.
    """
    var metrics = PODPerformanceMetrics()
    
    # Estimate prefill time
    var total_prefill_flops: Float32 = 0.0
    for i in range(batch.num_prefill):
        var req = batch.get_prefill_request(i)
        total_prefill_flops += req.compute_flops(num_heads, head_dim, num_layers)
    
    # Prefill TFLOPS scaled by SM fraction
    var prefill_tflops = T4_FP16_TFLOPS * Float32(partition.prefill_sms) / Float32(T4_NUM_SMS)
    if prefill_tflops > 0:
        metrics.prefill_latency_ms = (total_prefill_flops / (prefill_tflops * 1e12)) * 1000.0
        metrics.prefill_utilization = (total_prefill_flops / (prefill_tflops * 1e12 * metrics.prefill_latency_ms / 1000.0)) * 100.0
    
    # Estimate decode time
    var total_decode_bytes: Int = 0
    for i in range(batch.num_decode):
        var req = batch.get_decode_request(i)
        total_decode_bytes += req.memory_bytes(num_heads, head_dim)
    
    # Decode bandwidth scaled by SM fraction (memory controllers are shared, but compute is partitioned)
    var decode_bw = T4_BW_GBPS  # Full bandwidth available to decode
    if decode_bw > 0:
        metrics.decode_latency_ms = (Float32(total_decode_bytes) / (decode_bw * 1e9)) * 1000.0
        if metrics.decode_latency_ms > 0:
            metrics.decode_utilization = (Float32(total_decode_bytes) / (decode_bw * 1e9 * metrics.decode_latency_ms / 1000.0)) * 100.0
    
    # POD benefit: prefill and decode run concurrently
    # Total time = max(prefill_time, decode_time) instead of sum
    metrics.total_latency_ms = max_float(metrics.prefill_latency_ms, metrics.decode_latency_ms)
    
    # Sequential time would be sum
    var sequential_time = metrics.prefill_latency_ms + metrics.decode_latency_ms
    if metrics.total_latency_ms > 0:
        metrics.speedup_vs_sequential = sequential_time / metrics.total_latency_ms
    
    # Overall efficiency
    metrics.overall_efficiency = (metrics.prefill_utilization + metrics.decode_utilization) / 2.0
    
    return metrics


# ============================================================================
# Helper Functions
# ============================================================================

fn min_int(a: Int, b: Int) -> Int:
    if a < b:
        return a
    return b

fn max_int(a: Int, b: Int) -> Int:
    if a > b:
        return a
    return b

fn max_float(a: Float32, b: Float32) -> Float32:
    if a > b:
        return a
    return b