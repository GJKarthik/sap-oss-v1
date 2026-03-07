// Q2_K GEMV Microbenchmark for T4
//
// Q2_K super-block layout (84 bytes per 256 elements):
//   [0..15]  : 16 bytes scales (each byte: low nibble = scale, high nibble = min)
//   [16..79] : 64 bytes quants (2-bit packed, 4 per byte)
//   [80..81] : d (f16) — super-block scale
//   [82..83] : dmin (f16) — super-block min
//
// Dequant: val = (scales[group] & 0xF) * d * q2_value - (scales[group] >> 4) * dmin
//
// Comparison: Q4_0 = 18 bytes / 32 elements = 0.5625 B/elem
//             Q2_K = 84 bytes / 256 elements = 0.328 B/elem (42% less)

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

// ============================================================================
// Q2_K block structure
// ============================================================================
#define Q2K_BLOCK_SIZE 256
#define Q2K_BYTES_PER_BLOCK 84

struct block_q2_k {
    uint8_t scales[16];   // 16 groups: low nibble=scale, high nibble=min
    uint8_t qs[64];       // 2-bit quants (256/4 = 64 bytes)
    __half d;             // super-block scale
    __half dmin;          // super-block min
};

// ============================================================================
// Q4_0 baseline kernel (from existing optimized version)
// ============================================================================
#define Q4_BLOCK_SIZE 32
#define Q4_BYTES_PER_BLOCK 18

extern "C" __global__ void q4_0_gemv_baseline(
    float* __restrict__ out,
    const uint8_t* __restrict__ W,
    const float* __restrict__ x,
    int rows, int cols)
{
    // 8 rows per block, 256 threads, 32 threads per row
    const int ROWS_PER_BLOCK = 8;
    const int row_in_block = threadIdx.x / 32;
    const int lane = threadIdx.x % 32;
    const int global_row = blockIdx.x * ROWS_PER_BLOCK + row_in_block;
    if (global_row >= rows) return;

    const int n_blocks_per_row = cols / Q4_BLOCK_SIZE;
    const uint8_t* row_ptr = W + (size_t)global_row * n_blocks_per_row * Q4_BYTES_PER_BLOCK;

    float acc = 0.0f;
    for (int b = lane; b < n_blocks_per_row; b += 32) {
        const uint8_t* bp = row_ptr + b * Q4_BYTES_PER_BLOCK;
        __half scale_h;
        memcpy(&scale_h, bp, 2);
        float scale = __half2float(scale_h);

        const uint8_t* qs = bp + 2;
        float local = 0.0f;
        #pragma unroll
        for (int j = 0; j < 16; j++) {
            uint8_t byte = __ldg(&qs[j]);
            int lo = (byte & 0xF) - 8;
            int hi = (byte >> 4) - 8;
            int idx = b * Q4_BLOCK_SIZE + j * 2;
            local += (float)lo * x[idx] + (float)hi * x[idx + 1];
        }
        acc += scale * local;
    }

    // Warp reduce
    for (int offset = 16; offset > 0; offset >>= 1)
        acc += __shfl_down_sync(0xFFFFFFFF, acc, offset);

    if (lane == 0) atomicAdd(&out[global_row], acc);
}

// ============================================================================
// Q2_K GEMV kernel — warp-cooperative, 8 rows per block
// ============================================================================
extern "C" __global__ void q2_k_gemv(
    float* __restrict__ out,
    const uint8_t* __restrict__ W,
    const float* __restrict__ x,
    int rows, int cols)
{
    // 8 rows per block, 256 threads, 32 threads (1 warp) per row
    const int ROWS_PER_BLOCK = 8;
    const int row_in_block = threadIdx.x / 32;
    const int lane = threadIdx.x % 32;
    const int global_row = blockIdx.x * ROWS_PER_BLOCK + row_in_block;
    if (global_row >= rows) return;

    const int n_superblocks = cols / Q2K_BLOCK_SIZE;
    const uint8_t* row_ptr = W + (size_t)global_row * n_superblocks * Q2K_BYTES_PER_BLOCK;

    float acc = 0.0f;

    // Each warp (32 threads) cooperates on one row
    // Each super-block has 256 elements = 64 quant bytes
    // 32 threads: each thread handles 2 quant bytes (8 elements) per super-block
    for (int sb = 0; sb < n_superblocks; sb++) {
        const uint8_t* bp = row_ptr + sb * Q2K_BYTES_PER_BLOCK;

        // Load super-block d and dmin (shared across warp via shuffle)
        __half d_h, dmin_h;
        memcpy(&d_h, bp + 80, 2);
        memcpy(&dmin_h, bp + 82, 2);
        float d_val = __half2float(d_h);
        float dmin_val = __half2float(dmin_h);

        // Each thread handles elements [lane*8 .. lane*8+7] within this super-block
        // That's 2 quant bytes (lane*2 and lane*2+1)
        int elem_base = sb * Q2K_BLOCK_SIZE + lane * 8;

        // Which scale group? Each group is 16 elements. lane*8/16 = lane/2
        int group0 = (lane * 8) / 16;      // group for elements 0..3
        int group1 = (lane * 8 + 4) / 16;  // group for elements 4..7

        uint8_t sc0_byte = __ldg(&bp[group0]);
        uint8_t sc1_byte = __ldg(&bp[group1]);
        float sc0 = (float)(sc0_byte & 0xF) * d_val;
        float mn0 = (float)(sc0_byte >> 4) * dmin_val;
        float sc1 = (float)(sc1_byte & 0xF) * d_val;
        float mn1 = (float)(sc1_byte >> 4) * dmin_val;

        // Load 2 quant bytes = 8 elements
        uint8_t qb0 = __ldg(&bp[16 + lane * 2]);
        uint8_t qb1 = __ldg(&bp[16 + lane * 2 + 1]);

        float local = 0.0f;

        // First byte: 4 elements (indices lane*8 + 0..3)
        local += (sc0 * (float)((qb0 >> 0) & 3) - mn0) * x[elem_base + 0];
        local += (sc0 * (float)((qb0 >> 2) & 3) - mn0) * x[elem_base + 1];
        local += (sc0 * (float)((qb0 >> 4) & 3) - mn0) * x[elem_base + 2];
        local += (sc0 * (float)((qb0 >> 6) & 3) - mn0) * x[elem_base + 3];

        // Second byte: 4 elements (indices lane*8 + 4..7)
        local += (sc1 * (float)((qb1 >> 0) & 3) - mn1) * x[elem_base + 4];
        local += (sc1 * (float)((qb1 >> 2) & 3) - mn1) * x[elem_base + 5];
        local += (sc1 * (float)((qb1 >> 4) & 3) - mn1) * x[elem_base + 6];
        local += (sc1 * (float)((qb1 >> 6) & 3) - mn1) * x[elem_base + 7];

        acc += local;
    }

    // Warp reduce
    for (int offset = 16; offset > 0; offset >>= 1)
        acc += __shfl_down_sync(0xFFFFFFFF, acc, offset);

    if (lane == 0) atomicAdd(&out[global_row], acc);
}

// ============================================================================
// Q2_K GEMV v2 — vectorized x[] loads (float4)
// ============================================================================
extern "C" __global__ void q2_k_gemv_v2(
    float* __restrict__ out,
    const uint8_t* __restrict__ W,
    const float* __restrict__ x,
    int rows, int cols)
{
    const int ROWS_PER_BLOCK = 8;
    const int row_in_block = threadIdx.x / 32;
    const int lane = threadIdx.x % 32;
    const int global_row = blockIdx.x * ROWS_PER_BLOCK + row_in_block;
    if (global_row >= rows) return;

    const int n_superblocks = cols / Q2K_BLOCK_SIZE;
    const uint8_t* row_ptr = W + (size_t)global_row * n_superblocks * Q2K_BYTES_PER_BLOCK;

    float acc = 0.0f;

    for (int sb = 0; sb < n_superblocks; sb++) {
        const uint8_t* bp = row_ptr + sb * Q2K_BYTES_PER_BLOCK;

        __half d_h, dmin_h;
        memcpy(&d_h, bp + 80, 2);
        memcpy(&dmin_h, bp + 82, 2);
        float d_val = __half2float(d_h);
        float dmin_val = __half2float(dmin_h);

        int elem_base = sb * Q2K_BLOCK_SIZE + lane * 8;
        int group0 = (lane * 8) / 16;
        int group1 = (lane * 8 + 4) / 16;

        uint8_t sc0_byte = __ldg(&bp[group0]);
        uint8_t sc1_byte = __ldg(&bp[group1]);
        float sc0 = (float)(sc0_byte & 0xF) * d_val;
        float mn0 = (float)(sc0_byte >> 4) * dmin_val;
        float sc1 = (float)(sc1_byte & 0xF) * d_val;
        float mn1 = (float)(sc1_byte >> 4) * dmin_val;

        uint8_t qb0 = __ldg(&bp[16 + lane * 2]);
        uint8_t qb1 = __ldg(&bp[16 + lane * 2 + 1]);

        // Vectorized x[] loads
        float4 x4a = __ldg((const float4*)&x[elem_base]);
        float4 x4b = __ldg((const float4*)&x[elem_base + 4]);

        float local = 0.0f;
        local += (sc0 * (float)((qb0 >> 0) & 3) - mn0) * x4a.x;
        local += (sc0 * (float)((qb0 >> 2) & 3) - mn0) * x4a.y;
        local += (sc0 * (float)((qb0 >> 4) & 3) - mn0) * x4a.z;
        local += (sc0 * (float)((qb0 >> 6) & 3) - mn0) * x4a.w;
        local += (sc1 * (float)((qb1 >> 0) & 3) - mn1) * x4b.x;
        local += (sc1 * (float)((qb1 >> 2) & 3) - mn1) * x4b.y;
        local += (sc1 * (float)((qb1 >> 4) & 3) - mn1) * x4b.z;
        local += (sc1 * (float)((qb1 >> 6) & 3) - mn1) * x4b.w;

        acc += local;
    }

    for (int offset = 16; offset > 0; offset >>= 1)
        acc += __shfl_down_sync(0xFFFFFFFF, acc, offset);

    if (lane == 0) atomicAdd(&out[global_row], acc);
}

// ============================================================================
// Q2_K GEMV v3 — shared memory x[] with bank-conflict-free padding
// Same architecture as optimized Q4_0: 8 warps, cooperative x[] load,
// padded smem layout (idx + idx/32), u16 quant loads
// ============================================================================
extern "C" __global__ void q2_k_gemv_v3(
    float* __restrict__ out,
    const uint8_t* __restrict__ W,
    const float* __restrict__ x,
    int rows, int cols)
{
    // Padded shared memory: x[k] stored at index (k + k/32) to avoid bank conflicts
    extern __shared__ float x_smem[];

    const int tid = threadIdx.x;
    const int ROWS_PER_BLOCK = 8;

    // Phase 0: Cooperative load of x[] into padded shared memory
    // All 256 threads participate — each loads cols/256 elements
    for (int idx = tid; idx < cols; idx += 256) {
        int padded = idx + (idx >> 5);  // idx + idx/32
        x_smem[padded] = x[idx];
    }
    __syncthreads();

    // Thread indexing: 8 warps × 32 lanes
    const int lane = tid & 31;
    const int warp_id = tid >> 5;
    const int global_row = blockIdx.x * ROWS_PER_BLOCK + warp_id;
    if (global_row >= rows) return;

    const int n_superblocks = cols / Q2K_BLOCK_SIZE;
    const uint8_t* row_ptr = W + (size_t)global_row * n_superblocks * Q2K_BYTES_PER_BLOCK;

    float acc = 0.0f;

    for (int sb = 0; sb < n_superblocks; sb++) {
        const uint8_t* bp = row_ptr + sb * Q2K_BYTES_PER_BLOCK;

        // Load super-block d and dmin
        __half d_h, dmin_h;
        memcpy(&d_h, bp + 80, 2);
        memcpy(&dmin_h, bp + 82, 2);
        float d_val = __half2float(d_h);
        float dmin_val = __half2float(dmin_h);

        // Each lane handles 8 elements: [lane*8 .. lane*8+7]
        int elem_offset = sb * Q2K_BLOCK_SIZE + lane * 8;
        int group0 = (lane * 8) / 16;       // scale group for elements 0..3
        int group1 = (lane * 8 + 4) / 16;   // scale group for elements 4..7

        // Load scale/min bytes
        uint8_t sc0_byte = __ldg(&bp[group0]);
        uint8_t sc1_byte = __ldg(&bp[group1]);
        float sc0 = __int2float_rn(sc0_byte & 0xF) * d_val;
        float mn0 = __int2float_rn(sc0_byte >> 4) * dmin_val;
        float sc1 = __int2float_rn(sc1_byte & 0xF) * d_val;
        float mn1 = __int2float_rn(sc1_byte >> 4) * dmin_val;

        // Load 2 quant bytes as u16
        uint16_t qpair = *reinterpret_cast<const uint16_t*>(&bp[16 + lane * 2]);
        uint8_t qb0 = qpair & 0xFF;
        uint8_t qb1 = qpair >> 8;

        // Read x[] from padded shared memory
        // Padded index: elem_offset + elem_offset/32
        int x_base = elem_offset + (elem_offset >> 5);

        float local = 0.0f;
        // First 4 elements (from qb0, group0)
        local = fmaf(fmaf(__int2float_rn((qb0 >> 0) & 3), sc0, -mn0), x_smem[x_base + 0], local);
        local = fmaf(fmaf(__int2float_rn((qb0 >> 2) & 3), sc0, -mn0), x_smem[x_base + 1], local);
        local = fmaf(fmaf(__int2float_rn((qb0 >> 4) & 3), sc0, -mn0), x_smem[x_base + 2], local);
        local = fmaf(fmaf(__int2float_rn((qb0 >> 6) & 3), sc0, -mn0), x_smem[x_base + 3], local);
        // Second 4 elements (from qb1, group1) — offset by 4 + padding
        int x_base2 = (elem_offset + 4) + ((elem_offset + 4) >> 5);
        local = fmaf(fmaf(__int2float_rn((qb1 >> 0) & 3), sc1, -mn1), x_smem[x_base2 + 0], local);
        local = fmaf(fmaf(__int2float_rn((qb1 >> 2) & 3), sc1, -mn1), x_smem[x_base2 + 1], local);
        local = fmaf(fmaf(__int2float_rn((qb1 >> 4) & 3), sc1, -mn1), x_smem[x_base2 + 2], local);
        local = fmaf(fmaf(__int2float_rn((qb1 >> 6) & 3), sc1, -mn1), x_smem[x_base2 + 3], local);

        acc += local;
    }

    // Warp shuffle butterfly reduction (matches Q4_0 optimized)
    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1)
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);

    if (lane == 0) out[global_row] = acc;
}

// ============================================================================
// Q2_K GEMV v4 — tiled shared memory (256 elements per tile = 1 super-block)
// Only ~1KB smem → high occupancy. Matches Q4_0 optimization strategy.
// ============================================================================
extern "C" __global__ void q2_k_gemv_v4(
    float* __restrict__ out,
    const uint8_t* __restrict__ W,
    const float* __restrict__ x,
    int rows, int cols)
{
    // Tiny smem: 256 elements + 8 padding = 264 floats = 1056 bytes
    __shared__ float x_tile[264];  // 256 + 256/32 padding

    const int tid = threadIdx.x;
    const int ROWS_PER_BLOCK = 8;
    const int lane = tid & 31;
    const int warp_id = tid >> 5;
    const int global_row = blockIdx.x * ROWS_PER_BLOCK + warp_id;

    const int n_superblocks = cols / Q2K_BLOCK_SIZE;
    const uint8_t* row_ptr = (global_row < rows) ?
        W + (size_t)global_row * n_superblocks * Q2K_BYTES_PER_BLOCK : W;

    float acc = 0.0f;

    for (int sb = 0; sb < n_superblocks; sb++) {
        // Phase 0: Cooperative load of 256 x[] elements into tiled smem
        // 256 threads, 256 elements → 1 element per thread
        {
            int src_idx = sb * Q2K_BLOCK_SIZE + tid;
            int padded = tid + (tid >> 5);  // bank-conflict-free padding
            x_tile[padded] = x[src_idx];
        }
        __syncthreads();

        if (global_row < rows) {
            const uint8_t* bp = row_ptr + sb * Q2K_BYTES_PER_BLOCK;

            // Load super-block d and dmin
            __half d_h, dmin_h;
            memcpy(&d_h, bp + 80, 2);
            memcpy(&dmin_h, bp + 82, 2);
            float d_val = __half2float(d_h);
            float dmin_val = __half2float(dmin_h);

            // Each lane handles elements [lane*8 .. lane*8+7] within super-block
            int local_base = lane * 8;
            int group0 = local_base / 16;
            int group1 = (local_base + 4) / 16;

            uint8_t sc0_byte = __ldg(&bp[group0]);
            uint8_t sc1_byte = __ldg(&bp[group1]);
            float sc0 = __int2float_rn(sc0_byte & 0xF) * d_val;
            float mn0 = __int2float_rn(sc0_byte >> 4) * dmin_val;
            float sc1 = __int2float_rn(sc1_byte & 0xF) * d_val;
            float mn1 = __int2float_rn(sc1_byte >> 4) * dmin_val;

            // u16 quant load
            uint16_t qpair = *reinterpret_cast<const uint16_t*>(&bp[16 + lane * 2]);
            uint8_t qb0 = qpair & 0xFF;
            uint8_t qb1 = qpair >> 8;

            // Read from tiled smem with padding
            int x_base = local_base + (local_base >> 5);
            int x_base2 = (local_base + 4) + ((local_base + 4) >> 5);

            float local = 0.0f;
            local = fmaf(fmaf(__int2float_rn((qb0 >> 0) & 3), sc0, -mn0), x_tile[x_base + 0], local);
            local = fmaf(fmaf(__int2float_rn((qb0 >> 2) & 3), sc0, -mn0), x_tile[x_base + 1], local);
            local = fmaf(fmaf(__int2float_rn((qb0 >> 4) & 3), sc0, -mn0), x_tile[x_base + 2], local);
            local = fmaf(fmaf(__int2float_rn((qb0 >> 6) & 3), sc0, -mn0), x_tile[x_base + 3], local);
            local = fmaf(fmaf(__int2float_rn((qb1 >> 0) & 3), sc1, -mn1), x_tile[x_base2 + 0], local);
            local = fmaf(fmaf(__int2float_rn((qb1 >> 2) & 3), sc1, -mn1), x_tile[x_base2 + 1], local);
            local = fmaf(fmaf(__int2float_rn((qb1 >> 4) & 3), sc1, -mn1), x_tile[x_base2 + 2], local);
            local = fmaf(fmaf(__int2float_rn((qb1 >> 6) & 3), sc1, -mn1), x_tile[x_base2 + 3], local);

            acc += local;
        }
        __syncthreads();  // ensure all warps done before next tile overwrites smem
    }

    if (global_row >= rows) return;

    // Butterfly warp reduction
    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1)
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);

    if (lane == 0) out[global_row] = acc;
}

// ============================================================================
// Host helpers — manual f16 conversion (device-only intrinsics don't work here)
// ============================================================================

static inline uint16_t f32_to_f16_bits(float f) {
    uint32_t bits;
    memcpy(&bits, &f, 4);
    uint32_t sign = (bits >> 16) & 0x8000;
    int32_t exp = ((bits >> 23) & 0xFF) - 127 + 15;
    uint32_t mant = (bits >> 13) & 0x3FF;
    if (exp <= 0) return (uint16_t)sign;
    if (exp >= 31) return (uint16_t)(sign | 0x7C00);
    return (uint16_t)(sign | (exp << 10) | mant);
}

static inline float f16_bits_to_f32(uint16_t h) {
    uint32_t sign = (uint32_t)(h & 0x8000) << 16;
    uint32_t exp = (h >> 10) & 0x1F;
    uint32_t mant = h & 0x3FF;
    if (exp == 0) {
        if (mant == 0) { float f; uint32_t z = sign; memcpy(&f, &z, 4); return f; }
        // subnormal
        while (!(mant & 0x400)) { mant <<= 1; exp--; }
        exp++; mant &= ~0x400;
    } else if (exp == 31) {
        uint32_t bits = sign | 0x7F800000 | (mant << 13);
        float f; memcpy(&f, &bits, 4); return f;
    }
    uint32_t bits = sign | ((exp + 127 - 15) << 23) | (mant << 13);
    float f; memcpy(&f, &bits, 4); return f;
}

// Quantize f32 values to Q2_K format for benchmarking
void quantize_q2k(uint8_t* dst, const float* src, int n_elements) {
    int n_blocks = (n_elements + Q2K_BLOCK_SIZE - 1) / Q2K_BLOCK_SIZE;
    for (int b = 0; b < n_blocks; b++) {
        uint8_t* bp = dst + b * Q2K_BYTES_PER_BLOCK;
        const float* sp = src + b * Q2K_BLOCK_SIZE;
        int remaining = (b + 1) * Q2K_BLOCK_SIZE <= n_elements ?
                        Q2K_BLOCK_SIZE : n_elements - b * Q2K_BLOCK_SIZE;

        // Find range per group for scale/min
        float global_max = 0.0f, global_min = 0.0f;
        for (int i = 0; i < remaining; i++) {
            if (sp[i] > global_max) global_max = sp[i];
            if (sp[i] < global_min) global_min = sp[i];
        }

        // Simple quantization: d = max_range / 45 (max scale 15 * max q 3)
        float d_val = global_max / 45.0f;
        float dmin_val = -global_min / 15.0f; // min is subtracted
        if (d_val == 0.0f) d_val = 1e-6f;
        if (dmin_val == 0.0f) dmin_val = 1e-6f;

        // Store d and dmin as f16
        uint16_t d_h = f32_to_f16_bits(d_val);
        uint16_t dmin_h = f32_to_f16_bits(dmin_val);
        memcpy(bp + 80, &d_h, 2);
        memcpy(bp + 82, &dmin_h, 2);

        // Quantize each group of 16
        for (int g = 0; g < 16; g++) {
            float group_max = 0.0f, group_min = 0.0f;
            for (int j = 0; j < 16 && g * 16 + j < remaining; j++) {
                float v = sp[g * 16 + j];
                if (v > group_max) group_max = v;
                if (v < group_min) group_min = v;
            }

            // scale_g: quantized group scale (0-15)
            int sc_g = (int)roundf(group_max / (3.0f * d_val));
            if (sc_g > 15) sc_g = 15; if (sc_g < 0) sc_g = 0;
            // min_g: quantized group min (0-15)
            int mn_g = (int)roundf(-group_min / dmin_val);
            if (mn_g > 15) mn_g = 15; if (mn_g < 0) mn_g = 0;

            bp[g] = (uint8_t)((mn_g << 4) | sc_g);

            float esc = (float)sc_g * d_val;
            float emn = (float)mn_g * dmin_val;

            for (int j = 0; j < 16 && g * 16 + j < remaining; j++) {
                int idx = g * 16 + j;
                float v = sp[idx];
                int q = 0;
                if (esc > 0.0f) {
                    q = (int)roundf((v + emn) / esc);
                    if (q > 3) q = 3; if (q < 0) q = 0;
                }
                int byte_idx = idx / 4;
                int bit_shift = (idx % 4) * 2;
                bp[16 + byte_idx] = (bp[16 + byte_idx] & ~(3 << bit_shift)) | (q << bit_shift);
            }
        }
    }
}

void quantize_q4_0(uint8_t* dst, const float* src, int n_elements) {
    int n_blocks = (n_elements + Q4_BLOCK_SIZE - 1) / Q4_BLOCK_SIZE;
    for (int b = 0; b < n_blocks; b++) {
        uint8_t* bp = dst + b * Q4_BYTES_PER_BLOCK;
        const float* sp = src + b * Q4_BLOCK_SIZE;
        int remaining = (b + 1) * Q4_BLOCK_SIZE <= n_elements ?
                        Q4_BLOCK_SIZE : n_elements - b * Q4_BLOCK_SIZE;

        float amax = 0.0f;
        for (int i = 0; i < remaining; i++) {
            float av = fabsf(sp[i]);
            if (av > amax) amax = av;
        }
        float scale = amax / 7.0f;
        if (scale == 0.0f) scale = 1e-6f;
        uint16_t sh = f32_to_f16_bits(scale);
        memcpy(bp, &sh, 2);

        memset(bp + 2, 0, 16);
        for (int i = 0; i < remaining; i++) {
            int q = (int)roundf(sp[i] / scale) + 8;
            if (q > 15) q = 15; if (q < 0) q = 0;
            if (i % 2 == 0)
                bp[2 + i / 2] |= (q & 0xF);
            else
                bp[2 + i / 2] |= ((q & 0xF) << 4);
        }
    }
}

// CPU reference for correctness
void q2k_gemv_cpu(float* out, const uint8_t* W, const float* x, int rows, int cols) {
    int n_sb = cols / Q2K_BLOCK_SIZE;
    for (int r = 0; r < rows; r++) {
        float acc = 0.0f;
        const uint8_t* rp = W + (size_t)r * n_sb * Q2K_BYTES_PER_BLOCK;
        for (int sb = 0; sb < n_sb; sb++) {
            const uint8_t* bp = rp + sb * Q2K_BYTES_PER_BLOCK;
            uint16_t d_bits, dmin_bits;
            memcpy(&d_bits, bp + 80, 2);
            memcpy(&dmin_bits, bp + 82, 2);
            float d = f16_bits_to_f32(d_bits);
            float dm = f16_bits_to_f32(dmin_bits);
            for (int i = 0; i < Q2K_BLOCK_SIZE; i++) {
                int g = i / 16;
                float sc = (float)(bp[g] & 0xF) * d;
                float mn = (float)(bp[g] >> 4) * dm;
                int bi = i / 4;
                int bs = (i % 4) * 2;
                int q2 = (bp[16 + bi] >> bs) & 3;
                acc += (sc * (float)q2 - mn) * x[sb * Q2K_BLOCK_SIZE + i];
            }
        }
        out[r] = acc;
    }
}

// ============================================================================
// Main benchmark
// ============================================================================
int main() {
    // Model dimensions: Llama 7B
    const char* names[4] = {"QKV (4096x4096)", "Wo (4096x4096)", "FFN (11008x4096)", "Down (4096x11008)"};
    int all_rows[4] = {4096, 4096, 11008, 4096};
    int all_cols[4] = {4096, 4096, 4096, 11008};

    for (int si = 0; si < 4; si++) {
        int rows = all_rows[si], cols = all_cols[si];
        printf("\n=== %s ===\n", names[si]);

        // Allocate and init host data
        int n_elements = rows * cols;
        float* h_weights = (float*)malloc(n_elements * sizeof(float));
        float* h_x = (float*)malloc(cols * sizeof(float));
        float* h_out_cpu = (float*)calloc(rows, sizeof(float));
        float* h_out_gpu = (float*)calloc(rows, sizeof(float));

        srand(42);
        for (int i = 0; i < n_elements; i++)
            h_weights[i] = ((float)(rand() % 1000) - 500) / 5000.0f;
        for (int i = 0; i < cols; i++)
            h_x[i] = ((float)(rand() % 1000) - 500) / 500.0f;

        // Quantize to Q2_K
        int q2k_sb = (cols + Q2K_BLOCK_SIZE - 1) / Q2K_BLOCK_SIZE;
        size_t q2k_row_bytes = q2k_sb * Q2K_BYTES_PER_BLOCK;
        size_t q2k_total = (size_t)rows * q2k_row_bytes;
        uint8_t* h_q2k = (uint8_t*)calloc(q2k_total, 1);

        // Quantize each row
        for (int r = 0; r < rows; r++)
            quantize_q2k(h_q2k + r * q2k_row_bytes, h_weights + r * cols, cols);

        // Quantize to Q4_0
        int q4_nb = cols / Q4_BLOCK_SIZE;
        size_t q4_row_bytes = q4_nb * Q4_BYTES_PER_BLOCK;
        size_t q4_total = (size_t)rows * q4_row_bytes;
        uint8_t* h_q4 = (uint8_t*)calloc(q4_total, 1);
        for (int r = 0; r < rows; r++)
            quantize_q4_0(h_q4 + r * q4_row_bytes, h_weights + r * cols, cols);

        printf("  Q4_0 size: %.1f MB  Q2_K size: %.1f MB  (%.1f%% of Q4_0)\n",
               (double)q4_total / 1e6, (double)q2k_total / 1e6, 100.0 * (double)q2k_total / (double)q4_total);

        // CPU reference
        q2k_gemv_cpu(h_out_cpu, h_q2k, h_x, rows, cols);

        // GPU allocations
        uint8_t *d_q2k, *d_q4;
        float *d_x, *d_out;
        cudaMalloc(&d_q2k, q2k_total);
        cudaMalloc(&d_q4, q4_total);
        cudaMalloc(&d_x, cols * sizeof(float));
        cudaMalloc(&d_out, rows * sizeof(float));

        cudaMemcpy(d_q2k, h_q2k, q2k_total, cudaMemcpyHostToDevice);
        cudaMemcpy(d_q4, h_q4, q4_total, cudaMemcpyHostToDevice);
        cudaMemcpy(d_x, h_x, cols * sizeof(float), cudaMemcpyHostToDevice);

        int blocks = (rows + 7) / 8;

        // Correctness check: Q2_K v1
        cudaMemset(d_out, 0, rows * sizeof(float));
        q2_k_gemv<<<blocks, 256>>>(d_out, d_q2k, d_x, rows, cols);
        cudaDeviceSynchronize();
        cudaMemcpy(h_out_gpu, d_out, rows * sizeof(float), cudaMemcpyDeviceToHost);

        float max_err = 0.0f;
        for (int r = 0; r < rows; r++) {
            float err = fabsf(h_out_gpu[r] - h_out_cpu[r]);
            float rel = err / (fabsf(h_out_cpu[r]) + 1e-8f);
            if (rel > max_err) max_err = rel;
        }
        printf("  Q2_K v1 correctness: max_rel_err=%.6f %s\n", max_err,
               max_err < 0.01f ? "OK" : "FAIL");

        // Correctness check: Q2_K v2
        cudaMemset(d_out, 0, rows * sizeof(float));
        q2_k_gemv_v2<<<blocks, 256>>>(d_out, d_q2k, d_x, rows, cols);
        cudaDeviceSynchronize();
        cudaMemcpy(h_out_gpu, d_out, rows * sizeof(float), cudaMemcpyDeviceToHost);

        max_err = 0.0f;
        for (int r = 0; r < rows; r++) {
            float err = fabsf(h_out_gpu[r] - h_out_cpu[r]);
            float rel = err / (fabsf(h_out_cpu[r]) + 1e-8f);
            if (rel > max_err) max_err = rel;
        }
        printf("  Q2_K v2 correctness: max_rel_err=%.6f %s\n", max_err,
               max_err < 0.01f ? "OK" : "FAIL");

        // Correctness check: Q2_K v3 (shared memory)
        int smem_bytes = (cols + cols / 32) * sizeof(float);
        memset(h_out_gpu, 0, rows * sizeof(float));
        q2_k_gemv_v3<<<blocks, 256, smem_bytes>>>(d_out, d_q2k, d_x, rows, cols);
        cudaDeviceSynchronize();
        cudaMemcpy(h_out_gpu, d_out, rows * sizeof(float), cudaMemcpyDeviceToHost);

        max_err = 0.0f;
        for (int r = 0; r < rows; r++) {
            float err = fabsf(h_out_gpu[r] - h_out_cpu[r]);
            float rel = err / (fabsf(h_out_cpu[r]) + 1e-8f);
            if (rel > max_err) max_err = rel;
        }
        printf("  Q2_K v3 correctness: max_rel_err=%.6f %s\n", max_err,
               max_err < 0.01f ? "OK" : "FAIL");

        // Correctness check: Q2_K v4 (tiled shared memory)
        q2_k_gemv_v4<<<blocks, 256>>>(d_out, d_q2k, d_x, rows, cols);
        cudaDeviceSynchronize();
        cudaMemcpy(h_out_gpu, d_out, rows * sizeof(float), cudaMemcpyDeviceToHost);

        max_err = 0.0f;
        for (int r = 0; r < rows; r++) {
            float err = fabsf(h_out_gpu[r] - h_out_cpu[r]);
            float rel = err / (fabsf(h_out_cpu[r]) + 1e-8f);
            if (rel > max_err) max_err = rel;
        }
        printf("  Q2_K v4 correctness: max_rel_err=%.6f %s\n", max_err,
               max_err < 0.01f ? "OK" : "FAIL");

        // Warmup
        for (int i = 0; i < 20; i++) {
            cudaMemset(d_out, 0, rows * sizeof(float));
            q4_0_gemv_baseline<<<blocks, 256>>>(d_out, d_q4, d_x, rows, cols);
            cudaMemset(d_out, 0, rows * sizeof(float));
            q2_k_gemv<<<blocks, 256>>>(d_out, d_q2k, d_x, rows, cols);
            cudaMemset(d_out, 0, rows * sizeof(float));
            q2_k_gemv_v2<<<blocks, 256>>>(d_out, d_q2k, d_x, rows, cols);
            q2_k_gemv_v3<<<blocks, 256, smem_bytes>>>(d_out, d_q2k, d_x, rows, cols);
            q2_k_gemv_v4<<<blocks, 256>>>(d_out, d_q2k, d_x, rows, cols);
        }
        cudaDeviceSynchronize();

        int N = 200;
        cudaEvent_t t0, t1;
        cudaEventCreate(&t0); cudaEventCreate(&t1);

        // Benchmark Q4_0
        cudaEventRecord(t0);
        for (int i = 0; i < N; i++) {
            cudaMemset(d_out, 0, rows * sizeof(float));
            q4_0_gemv_baseline<<<blocks, 256>>>(d_out, d_q4, d_x, rows, cols);
        }
        cudaEventRecord(t1); cudaEventSynchronize(t1);
        float ms_q4; cudaEventElapsedTime(&ms_q4, t0, t1); ms_q4 /= N;
        float bw_q4 = (q4_total + cols * 4) / ms_q4 / 1e6;

        // Benchmark Q2_K v1
        cudaEventRecord(t0);
        for (int i = 0; i < N; i++) {
            cudaMemset(d_out, 0, rows * sizeof(float));
            q2_k_gemv<<<blocks, 256>>>(d_out, d_q2k, d_x, rows, cols);
        }
        cudaEventRecord(t1); cudaEventSynchronize(t1);
        float ms_q2v1; cudaEventElapsedTime(&ms_q2v1, t0, t1); ms_q2v1 /= N;
        float bw_q2v1 = (q2k_total + cols * 4) / ms_q2v1 / 1e6;

        // Benchmark Q2_K v2 (float4 loads)
        cudaEventRecord(t0);
        for (int i = 0; i < N; i++) {
            cudaMemset(d_out, 0, rows * sizeof(float));
            q2_k_gemv_v2<<<blocks, 256>>>(d_out, d_q2k, d_x, rows, cols);
        }
        cudaEventRecord(t1); cudaEventSynchronize(t1);
        float ms_q2v2; cudaEventElapsedTime(&ms_q2v2, t0, t1); ms_q2v2 /= N;
        float bw_q2v2 = (q2k_total + cols * 4) / ms_q2v2 / 1e6;

        printf("  Q4_0:    %.3f ms  (%.0f GB/s)\n", ms_q4, bw_q4);
        printf("  Q2_K v1: %.3f ms  (%.0f GB/s)  speedup=%.2fx\n",
               ms_q2v1, bw_q2v1, ms_q4 / ms_q2v1);
        printf("  Q2_K v2: %.3f ms  (%.0f GB/s)  speedup=%.2fx\n",
               ms_q2v2, bw_q2v2, ms_q4 / ms_q2v2);

        // Benchmark Q2_K v3 (shared memory + u16 + FMA)
        cudaEventRecord(t0);
        for (int i = 0; i < N; i++) {
            q2_k_gemv_v3<<<blocks, 256, smem_bytes>>>(d_out, d_q2k, d_x, rows, cols);
        }
        cudaEventRecord(t1); cudaEventSynchronize(t1);
        float ms_q2v3; cudaEventElapsedTime(&ms_q2v3, t0, t1); ms_q2v3 /= N;
        float bw_q2v3 = (q2k_total + cols * 4) / ms_q2v3 / 1e6;
        printf("  Q2_K v3: %.3f ms  (%.0f GB/s)  speedup=%.2fx (full smem)\n",
               ms_q2v3, bw_q2v3, ms_q4 / ms_q2v3);

        // Benchmark Q2_K v4 (tiled shared memory)
        cudaEventRecord(t0);
        for (int i = 0; i < N; i++) {
            q2_k_gemv_v4<<<blocks, 256>>>(d_out, d_q2k, d_x, rows, cols);
        }
        cudaEventRecord(t1); cudaEventSynchronize(t1);
        float ms_q2v4; cudaEventElapsedTime(&ms_q2v4, t0, t1); ms_q2v4 /= N;
        float bw_q2v4 = (q2k_total + cols * 4) / ms_q2v4 / 1e6;
        printf("  Q2_K v4: %.3f ms  (%.0f GB/s)  speedup=%.2fx (tiled smem)\n",
               ms_q2v4, bw_q2v4, ms_q4 / ms_q2v4);

        cudaEventDestroy(t0); cudaEventDestroy(t1);
        cudaFree(d_q2k); cudaFree(d_q4); cudaFree(d_x); cudaFree(d_out);
        free(h_weights); free(h_x); free(h_out_cpu); free(h_out_gpu);
        free(h_q2k); free(h_q4);
    }

    // Estimate total model time savings
    printf("\n=== Model-level estimate (32 layers) ===\n");
    printf("  Q4_0: 7 GEMV/layer × ~0.6ms avg = ~4.2ms/layer × 32 = ~134ms/layer (extrapolated)\n");
    printf("  Q2_K: if 1.5x speedup → ~89ms → 50%% more TPS\n");
    printf("  if 1.7x speedup → ~79ms → 70%% more TPS\n");

    return 0;
}
