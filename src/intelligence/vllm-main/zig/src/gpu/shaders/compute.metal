// ANWID Metal Compute Shaders
// GPU kernels for inference workloads on Apple Silicon
// Compile: xcrun -sdk macosx metal -c compute.metal -o compute.air
//          xcrun -sdk macosx metallib compute.air -o compute.metallib

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Constants
// ============================================================================

constant float EPS = 1e-5f;

// ============================================================================
// Vector Operations
// ============================================================================

/// Vector addition: c = a + b
kernel void vector_add(
    device const float* a [[buffer(0)]],
    device const float* b [[buffer(1)]],
    device float* c [[buffer(2)]],
    constant uint& n [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= n) return;
    c[id] = a[id] + b[id];
}

/// Vector scale: b = a * scale
kernel void vector_scale(
    device const float* a [[buffer(0)]],
    device float* b [[buffer(1)]],
    constant float& scale [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    b[id] = a[id] * scale;
}

/// Element-wise multiply: c = a * b
kernel void vector_mul(
    device const float* a [[buffer(0)]],
    device const float* b [[buffer(1)]],
    device float* c [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    c[id] = a[id] * b[id];
}

// ============================================================================
// Embedding Lookup
// ============================================================================

/// Embedding lookup with vocabulary
/// input: token indices (uint32)
/// embedding_table: [vocab_size x embedding_dim]
/// output: [batch_size x embedding_dim]
kernel void embedding_lookup(
    device const uint* input_tokens [[buffer(0)]],
    device const float* embedding_table [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant uint& embedding_dim [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint batch_idx = gid.y;
    uint dim_idx = gid.x;
    
    uint token = input_tokens[batch_idx];
    output[batch_idx * embedding_dim + dim_idx] = embedding_table[token * embedding_dim + dim_idx];
}

// ============================================================================
// Matrix Multiplication
// ============================================================================

/// Simple matrix multiply: C = A @ B
/// A: [M x K], B: [K x N], C: [M x N]
kernel void matmul_naive(
    device const float* A [[buffer(0)]],
    device const float* B [[buffer(1)]],
    device float* C [[buffer(2)]],
    constant uint& M [[buffer(3)]],
    constant uint& N [[buffer(4)]],
    constant uint& K [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint row = gid.y;
    uint col = gid.x;
    
    if (row >= M || col >= N) return;
    
    float sum = 0.0f;
    for (uint k = 0; k < K; k++) {
        sum += A[row * K + k] * B[k * N + col];
    }
    C[row * N + col] = sum;
}

/// Tiled matrix multiply for better cache utilization
/// Uses threadgroup memory for shared data
kernel void matmul_tiled(
    device const float* A [[buffer(0)]],
    device const float* B [[buffer(1)]],
    device float* C [[buffer(2)]],
    constant uint& M [[buffer(3)]],
    constant uint& N [[buffer(4)]],
    constant uint& K [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 tgSize [[threads_per_threadgroup]]
) {
    // Tile size (should match threadgroup size)
    constexpr uint TILE_SIZE = 16;
    
    threadgroup float As[TILE_SIZE][TILE_SIZE];
    threadgroup float Bs[TILE_SIZE][TILE_SIZE];
    
    uint row = gid.y;
    uint col = gid.x;
    
    float sum = 0.0f;
    
    // Loop over tiles
    for (uint t = 0; t < (K + TILE_SIZE - 1) / TILE_SIZE; t++) {
        // Load tile of A into shared memory
        uint aRow = row;
        uint aCol = t * TILE_SIZE + tid.x;
        if (aRow < M && aCol < K) {
            As[tid.y][tid.x] = A[aRow * K + aCol];
        } else {
            As[tid.y][tid.x] = 0.0f;
        }
        
        // Load tile of B into shared memory
        uint bRow = t * TILE_SIZE + tid.y;
        uint bCol = col;
        if (bRow < K && bCol < N) {
            Bs[tid.y][tid.x] = B[bRow * N + bCol];
        } else {
            Bs[tid.y][tid.x] = 0.0f;
        }
        
        threadgroup_barrier(mem_flags::mem_threadgroup);
        
        // Compute partial dot product
        for (uint k = 0; k < TILE_SIZE; k++) {
            sum += As[tid.y][k] * Bs[k][tid.x];
        }
        
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    
    if (row < M && col < N) {
        C[row * N + col] = sum;
    }
}

/// Vector-matrix multiply for GGUF / ggml weight layout.
/// x: [K]
/// W: [N x K] with each output column stored as a contiguous K-length slice
/// out: [N]
kernel void vecmat_f16_colmajor(
    device const float* x [[buffer(0)]],
    device const half* W [[buffer(1)]],
    device float* out [[buffer(2)]],
    constant uint& K [[buffer(3)]],
    constant uint& N [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    const uint out_idx = gid;
    if (out_idx >= N) return;

    const uint base = out_idx * K;
    float sum = 0.0f;
    for (uint k = 0; k < K; k++) {
        sum += x[k] * float(W[base + k]);
    }
    out[out_idx] = sum;
}

inline uint2 get_scale_min_k4(uint j, device const uchar* q) {
    if (j < 4) {
        return uint2(q[j] & 63, q[j + 4] & 63);
    }
    return uint2(
        (q[j + 4] & 0x0F) | ((q[j - 4] >> 6) << 4),
        (q[j + 4] >> 4) | ((q[j] >> 6) << 4)
    );
}

inline float4 unpack_low_nibbles(uchar4 packed) {
    return float4(
        float(packed.x & 0x0F),
        float(packed.y & 0x0F),
        float(packed.z & 0x0F),
        float(packed.w & 0x0F)
    );
}

inline float4 unpack_high_nibbles(uchar4 packed) {
    return float4(
        float(packed.x >> 4),
        float(packed.y >> 4),
        float(packed.z >> 4),
        float(packed.w >> 4)
    );
}

inline float vecmat_q4_k_row_sum(
    device const float* x,
    device const uchar* row_ptr,
    uint K,
    uint tid,
    uint tg_size
) {
    constexpr uint BLOCK_BYTES = 144;
    constexpr uint CHUNK_SIZE = 32;
    const uint chunks_per_row = (K + CHUNK_SIZE - 1) / CHUNK_SIZE;

    float local_sum = 0.0f;
    for (uint chunk = tid; chunk < chunks_per_row; chunk += tg_size) {
        const uint block = chunk / 8;
        const uint sub = chunk % 8;
        device const uchar* block_ptr = row_ptr + block * BLOCK_BYTES;
        const ushort d_bits = ushort(block_ptr[0]) | (ushort(block_ptr[1]) << 8);
        const ushort dmin_bits = ushort(block_ptr[2]) | (ushort(block_ptr[3]) << 8);
        const float d = float(as_type<half>(d_bits));
        const float dmin = float(as_type<half>(dmin_bits));
        device const uchar* scales = block_ptr + 4;
        const uint pair = sub / 2;
        device const uchar* qs = block_ptr + 16 + pair * CHUNK_SIZE;
        const uint base_k = chunk * CHUNK_SIZE;
        const uint chunk_count = min(CHUNK_SIZE, K - base_k);

        float d_chunk = 0.0f;
        float m_chunk = 0.0f;
        if ((sub & 1u) == 0u) {
            const uint2 sm = get_scale_min_k4(pair * 2, scales);
            d_chunk = d * float(sm.x);
            m_chunk = dmin * float(sm.y);
            if (chunk_count == CHUNK_SIZE) {
                const float4 d_vec = float4(d_chunk);
                const float4 m_vec = float4(m_chunk);
                for (uint l = 0; l < CHUNK_SIZE; l += 4) {
                    const uchar4 packed = *(device const uchar4*)(qs + l);
                    const float4 q = unpack_low_nibbles(packed);
                    const float4 xv = *(device const float4*)(x + base_k + l);
                    local_sum += dot(xv, d_vec * q - m_vec);
                }
            } else {
                for (uint l = 0; l < chunk_count; ++l) {
                    const float q = float(qs[l] & 0x0F);
                    local_sum += x[base_k + l] * (d_chunk * q - m_chunk);
                }
            }
        } else {
            const uint2 sm = get_scale_min_k4(pair * 2 + 1, scales);
            d_chunk = d * float(sm.x);
            m_chunk = dmin * float(sm.y);
            if (chunk_count == CHUNK_SIZE) {
                const float4 d_vec = float4(d_chunk);
                const float4 m_vec = float4(m_chunk);
                for (uint l = 0; l < CHUNK_SIZE; l += 4) {
                    const uchar4 packed = *(device const uchar4*)(qs + l);
                    const float4 q = unpack_high_nibbles(packed);
                    const float4 xv = *(device const float4*)(x + base_k + l);
                    local_sum += dot(xv, d_vec * q - m_vec);
                }
            } else {
                for (uint l = 0; l < chunk_count; ++l) {
                    const float q = float(qs[l] >> 4);
                    local_sum += x[base_k + l] * (d_chunk * q - m_chunk);
                }
            }
        }
    }

    return local_sum;
}

/// Vector-matrix multiply for row-major GGUF Q4_K blocks.
/// x: [K]
/// W: [N x K] stored as consecutive GGUF Q4_K rows
/// out: [N]
kernel void vecmat_q4_k(
    device const float* x [[buffer(0)]],
    device const uchar* W [[buffer(1)]],
    device float* out [[buffer(2)]],
    constant uint& K [[buffer(3)]],
    constant uint& N [[buffer(4)]],
    uint tid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint lane [[thread_index_in_simdgroup]],
    uint sg_idx [[simdgroup_index_in_threadgroup]],
    uint simd_size [[threads_per_simdgroup]],
    uint out_idx [[threadgroup_position_in_grid]]
) {
    if (out_idx >= N) return;

    constexpr uint BLOCK_SIZE = 256;
    constexpr uint BLOCK_BYTES = 144;
    const uint blocks_per_row = (K + BLOCK_SIZE - 1) / BLOCK_SIZE;
    device const uchar* row_ptr = W + out_idx * blocks_per_row * BLOCK_BYTES;
    threadgroup float partial_sums[32];

    const float local_sum = vecmat_q4_k_row_sum(x, row_ptr, K, tid, tg_size);

    if (tg_size == simd_size) {
        const float total = simd_sum(local_sum);
        if (tid == 0) {
            out[out_idx] = total;
        }
        return;
    }

    const float sg_sum = simd_sum(local_sum);
    if (lane == 0) {
        partial_sums[sg_idx] = sg_sum;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (sg_idx == 0) {
        const uint num_simdgroups = (tg_size + simd_size - 1) / simd_size;
        float total = (lane < num_simdgroups) ? partial_sums[lane] : 0.0f;
        total = simd_sum(total);
        if (lane == 0) {
            out[out_idx] = total;
        }
    }
}

kernel void vecmat_q4_k_dual(
    device const float* x [[buffer(0)]],
    device const uchar* W1 [[buffer(1)]],
    device float* out1 [[buffer(2)]],
    constant uint& K [[buffer(3)]],
    constant uint& N1 [[buffer(4)]],
    device const uchar* W2 [[buffer(5)]],
    device float* out2 [[buffer(6)]],
    constant uint& N2 [[buffer(7)]],
    uint tid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint out_idx [[threadgroup_position_in_grid]]
) {
    constexpr uint BLOCK_SIZE = 256;
    constexpr uint BLOCK_BYTES = 144;
    const uint blocks_per_row = (K + BLOCK_SIZE - 1) / BLOCK_SIZE;

    if (out_idx < N1) {
        device const uchar* row_ptr = W1 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum(x, row_ptr, K, tid, tg_size));
        if (tid == 0) out1[out_idx] = total;
    }
    if (out_idx < N2) {
        device const uchar* row_ptr = W2 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum(x, row_ptr, K, tid, tg_size));
        if (tid == 0) out2[out_idx] = total;
    }
}

inline float vecmat_q4_k_row_sum_rmsnorm(
    device const float* x,
    device const float* norm_weight,
    float inv_rms,
    device const uchar* row_ptr,
    uint K,
    uint tid,
    uint tg_size
) {
    constexpr uint BLOCK_BYTES = 144;
    constexpr uint CHUNK_SIZE = 32;
    const uint chunks_per_row = (K + CHUNK_SIZE - 1) / CHUNK_SIZE;

    float local_sum = 0.0f;
    for (uint chunk = tid; chunk < chunks_per_row; chunk += tg_size) {
        const uint block = chunk / 8;
        const uint sub = chunk % 8;
        device const uchar* block_ptr = row_ptr + block * BLOCK_BYTES;
        const ushort d_bits = ushort(block_ptr[0]) | (ushort(block_ptr[1]) << 8);
        const ushort dmin_bits = ushort(block_ptr[2]) | (ushort(block_ptr[3]) << 8);
        const float d = float(as_type<half>(d_bits));
        const float dmin = float(as_type<half>(dmin_bits));
        device const uchar* scales = block_ptr + 4;
        const uint pair = sub / 2;
        device const uchar* qs = block_ptr + 16 + pair * CHUNK_SIZE;
        const uint base_k = chunk * CHUNK_SIZE;
        const uint chunk_count = min(CHUNK_SIZE, K - base_k);

        float d_chunk = 0.0f;
        float m_chunk = 0.0f;
        if ((sub & 1u) == 0u) {
            const uint2 sm = get_scale_min_k4(pair * 2, scales);
            d_chunk = d * float(sm.x);
            m_chunk = dmin * float(sm.y);
            for (uint l = 0; l < chunk_count; ++l) {
                const float q = float(qs[l] & 0x0F);
                const float xnorm = x[base_k + l] * norm_weight[base_k + l] * inv_rms;
                local_sum += xnorm * (d_chunk * q - m_chunk);
            }
        } else {
            const uint2 sm = get_scale_min_k4(pair * 2 + 1, scales);
            d_chunk = d * float(sm.x);
            m_chunk = dmin * float(sm.y);
            for (uint l = 0; l < chunk_count; ++l) {
                const float q = float(qs[l] >> 4);
                const float xnorm = x[base_k + l] * norm_weight[base_k + l] * inv_rms;
                local_sum += xnorm * (d_chunk * q - m_chunk);
            }
        }
    }

    return local_sum;
}

kernel void vecmat_q4_k_dual_rmsnorm(
    device const float* x [[buffer(0)]],
    device const float* norm_weight [[buffer(1)]],
    device const uchar* W1 [[buffer(2)]],
    device float* out1 [[buffer(3)]],
    constant uint& K [[buffer(4)]],
    constant uint& N1 [[buffer(5)]],
    device const uchar* W2 [[buffer(6)]],
    device float* out2 [[buffer(7)]],
    constant uint& N2 [[buffer(8)]],
    constant float& inv_rms [[buffer(9)]],
    uint tid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint out_idx [[threadgroup_position_in_grid]]
) {
    constexpr uint BLOCK_SIZE = 256;
    constexpr uint BLOCK_BYTES = 144;
    const uint blocks_per_row = (K + BLOCK_SIZE - 1) / BLOCK_SIZE;

    if (out_idx < N1) {
        device const uchar* row_ptr = W1 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum_rmsnorm(x, norm_weight, inv_rms, row_ptr, K, tid, tg_size));
        if (tid == 0) out1[out_idx] = total;
    }
    if (out_idx < N2) {
        device const uchar* row_ptr = W2 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum_rmsnorm(x, norm_weight, inv_rms, row_ptr, K, tid, tg_size));
        if (tid == 0) out2[out_idx] = total;
    }
}

kernel void vecmat_q4_k_triple(
    device const float* x [[buffer(0)]],
    device const uchar* W1 [[buffer(1)]],
    device float* out1 [[buffer(2)]],
    constant uint& K [[buffer(3)]],
    constant uint& N1 [[buffer(4)]],
    device const uchar* W2 [[buffer(5)]],
    device float* out2 [[buffer(6)]],
    constant uint& N2 [[buffer(7)]],
    device const uchar* W3 [[buffer(8)]],
    device float* out3 [[buffer(9)]],
    constant uint& N3 [[buffer(10)]],
    uint tid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint out_idx [[threadgroup_position_in_grid]]
) {
    constexpr uint BLOCK_SIZE = 256;
    constexpr uint BLOCK_BYTES = 144;
    const uint blocks_per_row = (K + BLOCK_SIZE - 1) / BLOCK_SIZE;

    if (out_idx < N1) {
        device const uchar* row_ptr = W1 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum(x, row_ptr, K, tid, tg_size));
        if (tid == 0) out1[out_idx] = total;
    }
    if (out_idx < N2) {
        device const uchar* row_ptr = W2 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum(x, row_ptr, K, tid, tg_size));
        if (tid == 0) out2[out_idx] = total;
    }
    if (out_idx < N3) {
        device const uchar* row_ptr = W3 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum(x, row_ptr, K, tid, tg_size));
        if (tid == 0) out3[out_idx] = total;
    }
}

kernel void vecmat_q4_k_triple_rmsnorm(
    device const float* x [[buffer(0)]],
    device const float* norm_weight [[buffer(1)]],
    device const uchar* W1 [[buffer(2)]],
    device float* out1 [[buffer(3)]],
    constant uint& K [[buffer(4)]],
    constant uint& N1 [[buffer(5)]],
    device const uchar* W2 [[buffer(6)]],
    device float* out2 [[buffer(7)]],
    constant uint& N2 [[buffer(8)]],
    device const uchar* W3 [[buffer(9)]],
    device float* out3 [[buffer(10)]],
    constant uint& N3 [[buffer(11)]],
    constant float& inv_rms [[buffer(12)]],
    uint tid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint out_idx [[threadgroup_position_in_grid]]
) {
    constexpr uint BLOCK_SIZE = 256;
    constexpr uint BLOCK_BYTES = 144;
    const uint blocks_per_row = (K + BLOCK_SIZE - 1) / BLOCK_SIZE;

    if (out_idx < N1) {
        device const uchar* row_ptr = W1 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum_rmsnorm(x, norm_weight, inv_rms, row_ptr, K, tid, tg_size));
        if (tid == 0) out1[out_idx] = total;
    }
    if (out_idx < N2) {
        device const uchar* row_ptr = W2 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum_rmsnorm(x, norm_weight, inv_rms, row_ptr, K, tid, tg_size));
        if (tid == 0) out2[out_idx] = total;
    }
    if (out_idx < N3) {
        device const uchar* row_ptr = W3 + out_idx * blocks_per_row * BLOCK_BYTES;
        float total = simd_sum(vecmat_q4_k_row_sum_rmsnorm(x, norm_weight, inv_rms, row_ptr, K, tid, tg_size));
        if (tid == 0) out3[out_idx] = total;
    }
}

// ============================================================================
// Softmax
// ============================================================================

/// Softmax per row: output[i] = exp(input[i] - max) / sum(exp(input - max))
/// Uses two-pass algorithm for numerical stability
kernel void softmax_row(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& seq_len [[buffer(2)]],
    uint batch_idx [[thread_position_in_grid]]
) {
    uint offset = batch_idx * seq_len;
    
    // Pass 1: Find max
    float max_val = input[offset];
    for (uint i = 1; i < seq_len; i++) {
        max_val = max(max_val, input[offset + i]);
    }
    
    // Pass 2: Compute exp and sum
    float sum = 0.0f;
    for (uint i = 0; i < seq_len; i++) {
        float exp_val = exp(input[offset + i] - max_val);
        output[offset + i] = exp_val;
        sum += exp_val;
    }
    
    // Pass 3: Normalize
    float inv_sum = 1.0f / sum;
    for (uint i = 0; i < seq_len; i++) {
        output[offset + i] *= inv_sum;
    }
}

/// Parallel softmax using threadgroup reduction
kernel void softmax_parallel(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& seq_len [[buffer(2)]],
    uint batch_idx [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]]
) {
    threadgroup float shared_max[256];
    threadgroup float shared_sum[256];
    
    uint offset = batch_idx * seq_len;
    
    // Step 1: Find local max
    float local_max = -INFINITY;
    for (uint i = tid; i < seq_len; i += tg_size) {
        local_max = max(local_max, input[offset + i]);
    }
    shared_max[tid] = local_max;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Reduce to find global max
    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s) {
            shared_max[tid] = max(shared_max[tid], shared_max[tid + s]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float max_val = shared_max[0];
    
    // Step 2: Compute exp and local sum
    float local_sum = 0.0f;
    for (uint i = tid; i < seq_len; i += tg_size) {
        float exp_val = exp(input[offset + i] - max_val);
        output[offset + i] = exp_val;
        local_sum += exp_val;
    }
    shared_sum[tid] = local_sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Reduce to find global sum
    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s) {
            shared_sum[tid] += shared_sum[tid + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float total_sum = shared_sum[0];
    
    // Step 3: Normalize
    float inv_sum = 1.0f / total_sum;
    for (uint i = tid; i < seq_len; i += tg_size) {
        output[offset + i] *= inv_sum;
    }
}

// ============================================================================
// Layer Normalization
// ============================================================================

/// Layer norm: y = (x - mean) / sqrt(var + eps) * gamma + beta
kernel void layer_norm(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    device const float* gamma [[buffer(2)]],
    device const float* beta [[buffer(3)]],
    constant uint& hidden_size [[buffer(4)]],
    uint batch_idx [[thread_position_in_grid]]
) {
    uint offset = batch_idx * hidden_size;
    
    // Compute mean
    float mean = 0.0f;
    for (uint i = 0; i < hidden_size; i++) {
        mean += input[offset + i];
    }
    mean /= float(hidden_size);
    
    // Compute variance
    float var = 0.0f;
    for (uint i = 0; i < hidden_size; i++) {
        float diff = input[offset + i] - mean;
        var += diff * diff;
    }
    var /= float(hidden_size);
    
    // Normalize and scale
    float inv_std = rsqrt(var + EPS);
    for (uint i = 0; i < hidden_size; i++) {
        float normalized = (input[offset + i] - mean) * inv_std;
        output[offset + i] = normalized * gamma[i] + beta[i];
    }
}

/// Layer norm without affine transformation (no gamma/beta)
kernel void layer_norm_simple(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& hidden_size [[buffer(2)]],
    uint batch_idx [[thread_position_in_grid]]
) {
    uint offset = batch_idx * hidden_size;
    
    // Compute mean
    float mean = 0.0f;
    for (uint i = 0; i < hidden_size; i++) {
        mean += input[offset + i];
    }
    mean /= float(hidden_size);
    
    // Compute variance
    float var = 0.0f;
    for (uint i = 0; i < hidden_size; i++) {
        float diff = input[offset + i] - mean;
        var += diff * diff;
    }
    var /= float(hidden_size);
    
    // Normalize
    float inv_std = rsqrt(var + EPS);
    for (uint i = 0; i < hidden_size; i++) {
        output[offset + i] = (input[offset + i] - mean) * inv_std;
    }
}

// ============================================================================
// Cosine Similarity
// ============================================================================

/// Cosine similarity between query and document vectors
/// query: [embedding_dim]
/// documents: [num_docs x embedding_dim]  
/// scores: [num_docs]
kernel void cosine_similarity(
    device const float* query [[buffer(0)]],
    device const float* documents [[buffer(1)]],
    device float* scores [[buffer(2)]],
    constant uint& embedding_dim [[buffer(3)]],
    uint doc_idx [[thread_position_in_grid]]
) {
    float dot = 0.0f;
    float query_norm = 0.0f;
    float doc_norm = 0.0f;
    
    uint doc_offset = doc_idx * embedding_dim;
    
    for (uint i = 0; i < embedding_dim; i++) {
        float q = query[i];
        float d = documents[doc_offset + i];
        dot += q * d;
        query_norm += q * q;
        doc_norm += d * d;
    }
    
    float denom = sqrt(query_norm) * sqrt(doc_norm);
    scores[doc_idx] = (denom > 0.0f) ? (dot / denom) : 0.0f;
}

/// Batch cosine similarity: multiple queries against multiple documents
/// queries: [num_queries x embedding_dim]
/// documents: [num_docs x embedding_dim]
/// scores: [num_queries x num_docs]
kernel void cosine_similarity_batch(
    device const float* queries [[buffer(0)]],
    device const float* documents [[buffer(1)]],
    device float* scores [[buffer(2)]],
    constant uint& embedding_dim [[buffer(3)]],
    constant uint& num_docs [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint query_idx = gid.y;
    uint doc_idx = gid.x;
    
    float dot = 0.0f;
    float query_norm = 0.0f;
    float doc_norm = 0.0f;
    
    uint query_offset = query_idx * embedding_dim;
    uint doc_offset = doc_idx * embedding_dim;
    
    for (uint i = 0; i < embedding_dim; i++) {
        float q = queries[query_offset + i];
        float d = documents[doc_offset + i];
        dot += q * d;
        query_norm += q * q;
        doc_norm += d * d;
    }
    
    float denom = sqrt(query_norm) * sqrt(doc_norm);
    scores[query_idx * num_docs + doc_idx] = (denom > 0.0f) ? (dot / denom) : 0.0f;
}

// ============================================================================
// RMS Normalization (Transformer RMSNorm)
// ============================================================================

/// RMSNorm: output[i] = input[i] / rms(input) * weight[i]
/// rms(x) = sqrt(mean(x^2) + eps)
/// One thread per row (token position).
kernel void rms_norm(
    device const float* input   [[buffer(0)]],
    device const float* weight  [[buffer(1)]],
    device float*       output  [[buffer(2)]],
    constant uint&      hidden  [[buffer(3)]],
    uint3 group_id [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint3 tg_size3 [[threads_per_threadgroup]]
) {
    const uint row = group_id.y;
    const uint tg_size = tg_size3.x;
    const uint offset = row * hidden;
    threadgroup float partial_sums[256];

    float ss = 0.0f;
    for (uint i = tid; i < hidden; i += tg_size) {
        float v = input[offset + i];
        ss += v * v;
    }
    partial_sums[tid] = ss;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = tg_size / 2; stride > 0; stride >>= 1) {
        if (tid < stride) {
            partial_sums[tid] += partial_sums[tid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    const float inv_rms = rsqrt(partial_sums[0] / float(hidden) + EPS);
    for (uint i = tid; i < hidden; i += tg_size) {
        output[offset + i] = input[offset + i] * inv_rms * weight[i];
    }
}

/// RMSNorm without affine weight (used for intermediate normalizations)
kernel void rms_norm_no_weight(
    device const float* input  [[buffer(0)]],
    device float*       output [[buffer(1)]],
    constant uint&      hidden [[buffer(2)]],
    constant float&     eps    [[buffer(3)]],
    uint row [[thread_position_in_grid]]
) {
    uint offset = row * hidden;

    float ss = 0.0f;
    for (uint i = 0; i < hidden; i++) {
        float v = input[offset + i];
        ss += v * v;
    }
    float inv_rms = rsqrt(ss / float(hidden) + eps);

    for (uint i = 0; i < hidden; i++) {
        output[offset + i] = input[offset + i] * inv_rms;
    }
}

// ============================================================================
// SwiGLU (LLaMA FFN gate)
// ============================================================================

/// SwiGLU: output[i] = silu(gate[i]) * up[i]
/// silu(x) = x * sigmoid(x) = x / (1 + exp(-x))
kernel void swiglu(
    device const float* gate   [[buffer(0)]],
    device const float* up     [[buffer(1)]],
    device float*       output [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    float g = gate[id];
    float silu_g = g / (1.0f + exp(-g));
    output[id] = silu_g * up[id];
}

// ============================================================================
// RoPE (Rotary Position Embedding)
// ============================================================================

/// Apply RoPE to Q or K vectors.
/// Each thread handles one head.
/// vec layout: [n_heads * head_dim] contiguous
kernel void rope(
    device float*      vec       [[buffer(0)]],
    constant uint&     head_dim  [[buffer(1)]],
    constant uint&     n_heads   [[buffer(2)]],
    constant uint&     pos       [[buffer(3)]],
    constant float&    base_freq [[buffer(4)]],
    uint head_idx [[thread_position_in_grid]]
) {
    if (head_idx >= n_heads) return;
    uint offset = head_idx * head_dim;

    for (uint i = 0; i < head_dim; i += 2) {
        float freq = 1.0f / pow(base_freq, float(i) / float(head_dim));
        float theta = float(pos) * freq;
        float cos_t = cos(theta);
        float sin_t = sin(theta);
        float v0 = vec[offset + i];
        float v1 = vec[offset + i + 1];
        vec[offset + i]     = v0 * cos_t - v1 * sin_t;
        vec[offset + i + 1] = v0 * sin_t + v1 * cos_t;
    }
}

// ============================================================================
// Vec-Mat Multiply (single-row GEMV: out[N] = x[K] @ W[K*N])
// ============================================================================

/// GEMV: one thread per output element j.
/// W is stored row-major as W[k * N + j].
kernel void gemv(
    device const float* x   [[buffer(0)]],
    device const float* W   [[buffer(1)]],
    device float*       out [[buffer(2)]],
    constant uint&      K   [[buffer(3)]],
    constant uint&      N   [[buffer(4)]],
    uint j [[thread_position_in_grid]]
) {
    if (j >= N) return;
    float sum = 0.0f;
    for (uint k = 0; k < K; k++) {
        sum += x[k] * W[k * N + j];
    }
    out[j] = sum;
}

/// Tiled GEMV using threadgroup memory for better cache utilization.
/// Each threadgroup handles one output element, reducing over K in tiles.
kernel void gemv_tiled(
    device const float* x   [[buffer(0)]],
    device const float* W   [[buffer(1)]],
    device float*       out [[buffer(2)]],
    constant uint&      K   [[buffer(3)]],
    constant uint&      N   [[buffer(4)]],
    uint j          [[thread_position_in_grid]],
    uint tid        [[thread_index_in_threadgroup]],
    uint tg_size    [[threads_per_threadgroup]]
) {
    if (j >= N) return;

    constexpr uint TILE = 256;
    threadgroup float partial[TILE];

    float sum = 0.0f;
    for (uint k = tid; k < K; k += tg_size) {
        sum += x[k] * W[k * N + j];
    }
    partial[tid] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s) partial[tid] += partial[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) out[j] = partial[0];
}

// ============================================================================
// Vector Add (residual connection)
// ============================================================================

/// Element-wise add with accumulation: dst[i] += src[i]
kernel void vec_add_inplace(
    device float*       dst [[buffer(0)]],
    device const float* src [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    dst[id] += src[id];
}

// ============================================================================
// Argmax (greedy sampling)
// ============================================================================

/// Parallel argmax reduction — finds index of maximum value.
/// Each threadgroup reduces locally, then thread 0 does a global CAS loop.
/// best_val_bits stores the best value as bit-reinterpreted uint for atomic CAS.
kernel void argmax(
    device const float*  input         [[buffer(0)]],
    device atomic_uint*  best_idx      [[buffer(1)]],
    device atomic_uint*  best_val_bits [[buffer(2)]],
    constant uint&       n             [[buffer(3)]],
    uint tid     [[thread_index_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint tg_idx  [[threadgroup_position_in_grid]]
) {
    threadgroup float local_max[256];
    threadgroup uint  local_idx[256];

    uint base = tg_idx * tg_size;
    uint i    = base + tid;

    float my_val = -INFINITY;
    uint  my_idx = 0;
    if (i < n) { my_val = input[i]; my_idx = i; }
    local_max[tid] = my_val;
    local_idx[tid] = my_idx;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s && local_max[tid + s] > local_max[tid]) {
            local_max[tid] = local_max[tid + s];
            local_idx[tid] = local_idx[tid + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        uint new_bits = as_type<uint>(local_max[0]);
        uint prev_bits = atomic_load_explicit(best_val_bits, memory_order_relaxed);
        while (as_type<float>(new_bits) > as_type<float>(prev_bits)) {
            if (atomic_compare_exchange_weak_explicit(
                    best_val_bits,
                    &prev_bits,
                    new_bits,
                    memory_order_relaxed,
                    memory_order_relaxed)) {
                atomic_store_explicit(best_idx, local_idx[0], memory_order_relaxed);
                break;
            }
        }
    }
}

// ============================================================================
// ReLU / GELU Activation
// ============================================================================

kernel void relu(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    output[id] = max(input[id], 0.0f);
}

/// GELU activation: 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
kernel void gelu(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    float x = input[id];
    float x3 = x * x * x;
    float inner = 0.7978845608f * (x + 0.044715f * x3);  // sqrt(2/pi) ≈ 0.7978845608
    output[id] = 0.5f * x * (1.0f + tanh(inner));
}

// ============================================================================
// Attention
// ============================================================================

/// Scaled dot-product attention (single head)
/// Q: [seq_len x head_dim]
/// K: [seq_len x head_dim]
/// V: [seq_len x head_dim]
/// output: [seq_len x head_dim]
kernel void attention_single_head(
    device const float* Q [[buffer(0)]],
    device const float* K [[buffer(1)]],
    device const float* V [[buffer(2)]],
    device float* output [[buffer(3)]],
    device float* attn_weights [[buffer(4)]],
    constant uint& seq_len [[buffer(5)]],
    constant uint& head_dim [[buffer(6)]],
    uint query_idx [[thread_position_in_grid]]
) {
    float scale = rsqrt(float(head_dim));
    
    // Compute attention scores: Q[query_idx] @ K^T
    float max_score = -INFINITY;
    for (uint k = 0; k < seq_len; k++) {
        float score = 0.0f;
        for (uint d = 0; d < head_dim; d++) {
            score += Q[query_idx * head_dim + d] * K[k * head_dim + d];
        }
        score *= scale;
        attn_weights[query_idx * seq_len + k] = score;
        max_score = max(max_score, score);
    }
    
    // Softmax
    float sum = 0.0f;
    for (uint k = 0; k < seq_len; k++) {
        float w = exp(attn_weights[query_idx * seq_len + k] - max_score);
        attn_weights[query_idx * seq_len + k] = w;
        sum += w;
    }
    
    float inv_sum = 1.0f / sum;
    for (uint k = 0; k < seq_len; k++) {
        attn_weights[query_idx * seq_len + k] *= inv_sum;
    }
    
    // Weighted sum of V
    for (uint d = 0; d < head_dim; d++) {
        float weighted_sum = 0.0f;
        for (uint k = 0; k < seq_len; k++) {
            weighted_sum += attn_weights[query_idx * seq_len + k] * V[k * head_dim + d];
        }
        output[query_idx * head_dim + d] = weighted_sum;
    }
}
