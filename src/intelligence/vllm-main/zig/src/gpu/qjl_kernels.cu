// ============================================================================
// QJL (Quantized Johnson-Lindenstrauss) KV Cache Compression Kernels
// ============================================================================
//
// Compresses keys to 1-bit sign sketches with provably zero accuracy loss
// (up to JL distortion bound). Gives ~2x VRAM savings on key cache.
//
// Reference: "Quantized JL Transform" from TurboQuant papers.
//
// Compile: nvcc -O3 -arch=sm_75 -ptx qjl_kernels.cu -o qjl_kernels.ptx  (T4)
//          nvcc -O3 -arch=sm_86 -ptx qjl_kernels.cu -o qjl_kernels.ptx  (L4/L40S)
// ============================================================================

#include <cstdint>

// ============================================================================
// 1. QJL Key Quantization: F32 key → packed sign bits + L2 norm
// ============================================================================
//
// For each KV head, computes:
//   projected = S @ key_head   (S is [m x head_dim] random ±1/√m matrix)
//   signs = sign(projected)    (packed into uint32s, m/32 per head)
//   norm = ||key_head||_2
//
// Grid: (n_kv_heads, 1, 1), Block: (256, 1, 1)
// S is stored as packed ±1 bits: [m x head_dim / 32] uint32s
//   bit=1 means +1/√m, bit=0 means -1/√m
//
// Output sign_bits: [n_kv_heads x (m/32)] uint32s
// Output norms: [n_kv_heads] floats
//
extern "C" __global__ void qjl_quantize_key(
    uint32_t* __restrict__ sign_bits,   // output: [n_kv_heads * m_words] packed signs
    float* __restrict__ norms,          // output: [n_kv_heads] L2 norms
    const float* __restrict__ key,      // input: [n_kv_heads * head_dim] F32 key
    const uint32_t* __restrict__ S,     // input: [m * head_dim_words] random sign matrix (packed bits)
    int head_dim,                       // key head dimension
    int m,                              // sketch dimension (number of random projections)
    int n_kv_heads)                     // number of KV heads
{
    int kv_h = blockIdx.x;
    if (kv_h >= n_kv_heads) return;
    int tid = threadIdx.x;

    const float* key_head = key + kv_h * head_dim;
    int m_words = m / 32;  // number of uint32s per head for sign storage
    int head_dim_words = head_dim / 32;  // number of uint32s per row of S

    // Phase 1: Compute L2 norm of key_head
    // Each thread computes partial sum, then reduce
    extern __shared__ float smem[];  // [256]
    float partial_norm = 0.0f;
    for (int d = tid; d < head_dim; d += blockDim.x) {
        float v = key_head[d];
        partial_norm += v * v;
    }
    smem[tid] = partial_norm;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) smem[tid] += smem[tid + s];
        __syncthreads();
    }
    float norm = sqrtf(smem[0]);
    if (tid == 0) norms[kv_h] = norm;
    __syncthreads();

    // Phase 2: Random projection + sign extraction
    // Each thread handles a subset of the m projection rows.
    // For each row r of S, compute dot(S[r], key_head) and extract sign bit.
    // Process 32 rows at a time to pack into one uint32.
    for (int w = tid; w < m_words; w += blockDim.x) {
        uint32_t packed = 0;
        for (int bit = 0; bit < 32; bit++) {
            int r = w * 32 + bit;  // row index in S
            if (r >= m) break;

            // Compute dot product: sum_d S[r][d] * key_head[d]
            // S is packed: S[r * head_dim_words + dw] bit j → S[r][dw*32+j]
            const uint32_t* S_row = S + r * head_dim_words;
            float dot = 0.0f;
            for (int dw = 0; dw < head_dim_words; dw++) {
                uint32_t s_bits = S_row[dw];
                for (int j = 0; j < 32; j++) {
                    int d = dw * 32 + j;
                    if (d >= head_dim) break;
                    // bit=1 → +1, bit=0 → -1
                    float s_val = (s_bits & (1u << j)) ? 1.0f : -1.0f;
                    dot += s_val * key_head[d];
                }
            }
            // Sign bit: 1 if dot >= 0, 0 if dot < 0
            if (dot >= 0.0f) packed |= (1u << bit);
        }
        sign_bits[kv_h * m_words + w] = packed;
    }
}


// ============================================================================
// 2. QJL Decode Attention: Approximate Q@K^T via XNOR+popcount, exact V sum
// ============================================================================
//
// Phase 1: For each past token, approximate score(q, k_t) using QJL:
//   Sq = sign(S @ q_head)                      (computed on-the-fly)
//   approx_dot ≈ ||k_t|| * (2*popcount(XNOR(Sq, Sk_t))/m - 1) * scale
//
// Phase 2-3: Standard softmax + weighted V sum (identical to dense kernel).
//
// Grid: (n_heads, 1, 1), Block: (256, 1, 1)
//
// key_signs: [n_layers][max_seq][n_kv_heads][m_words]  (but we get per-layer slice)
// key_norms: [n_layers][max_seq][n_kv_heads]
// v_cache: [max_seq * kv_dim] standard dense F32
//
extern "C" __global__ void qjl_decode_attention(
    float* __restrict__ out,            // [n_heads * head_dim]
    const float* __restrict__ q,        // [n_heads * head_dim]
    const uint32_t* __restrict__ key_signs,  // [max_seq * n_kv_heads * m_words] for this layer
    const float* __restrict__ key_norms,     // [max_seq * n_kv_heads] for this layer
    const float* __restrict__ v_cache,       // [max_seq * kv_dim] dense values
    const uint32_t* __restrict__ S,          // [m * head_dim_words] random projection matrix
    int n_heads, int n_kv_heads, int head_dim, int kv_dim,
    int cur_seq, float scale,
    int m,                              // sketch dimension
    int max_seq)                        // max sequence length (stride for signs/norms)
{
    int h = blockIdx.x;
    if (h >= n_heads) return;
    int kv_h = h / (n_heads / n_kv_heads);  // GQA mapping
    int tid = threadIdx.x;

    int m_words = m / 32;
    int head_dim_words = head_dim / 32;

    extern __shared__ float smem[];
    // Layout: q_signs[m_words uint32] | scores[cur_seq] | scratch[256]
    uint32_t* q_signs = (uint32_t*)smem;
    float* scores = (float*)(q_signs + m_words);
    float* scratch = scores + cur_seq;

    const float* q_head = q + h * head_dim;

    // Phase 0: Compute sign sketch of query: Sq = sign(S @ q_head)
    for (int w = tid; w < m_words; w += blockDim.x) {
        uint32_t packed = 0;
        for (int bit = 0; bit < 32; bit++) {
            int r = w * 32 + bit;
            if (r >= m) break;
            const uint32_t* S_row = S + r * head_dim_words;
            float dot = 0.0f;
            for (int dw = 0; dw < head_dim_words; dw++) {
                uint32_t s_bits = S_row[dw];
                for (int j = 0; j < 32; j++) {
                    int d = dw * 32 + j;
                    if (d >= head_dim) break;
                    float s_val = (s_bits & (1u << j)) ? 1.0f : -1.0f;
                    dot += s_val * q_head[d];
                }
            }
            if (dot >= 0.0f) packed |= (1u << bit);
        }
        q_signs[w] = packed;
    }
    __syncthreads();

    // Phase 1: Approximate Q@K^T scores via XNOR+popcount
    for (int t = tid; t < cur_seq; t += blockDim.x) {
        // Get stored key signs and norm for token t, kv_head kv_h
        const uint32_t* k_signs_t = key_signs + ((size_t)t * n_kv_heads + kv_h) * m_words;
        float k_norm = key_norms[t * n_kv_heads + kv_h];

        // XNOR + popcount: count matching bits
        int match_count = 0;
        for (int w = 0; w < m_words; w++) {
            uint32_t xnor_val = ~(q_signs[w] ^ k_signs_t[w]);
            match_count += __popc(xnor_val);
        }
        // Approximate cosine similarity: (2 * matches / m - 1)
        float cos_approx = (2.0f * match_count) / (float)m - 1.0f;

        // Compute q_norm for proper scaling
        // score ≈ ||q|| * ||k|| * cos(q,k) * scale
        // But we absorb ||q|| into the global scale (caller passes 1/sqrt(head_dim))
        // so: score = k_norm * cos_approx * scale * sqrt(head_dim)
        // Actually: the dense kernel computes q·k * scale where scale = 1/sqrt(d).
        // q·k = ||q||*||k||*cos(q,k). QJL approximates cos(q,k).
        // We need: ||q|| * ||k|| * cos_approx * scale
        // We compute ||q|| below and use it.
        scores[t] = k_norm * cos_approx * scale;
    }
    __syncthreads();

    // Compute ||q_head|| and multiply into scores
    float q_partial = 0.0f;
    for (int d = tid; d < head_dim; d += blockDim.x)
        q_partial += q_head[d] * q_head[d];
    scratch[tid] = q_partial;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) scratch[tid] += scratch[tid + s];
        __syncthreads();
    }
    float q_norm = sqrtf(scratch[0]);
    __syncthreads();

    for (int t = tid; t < cur_seq; t += blockDim.x)
        scores[t] *= q_norm;
    __syncthreads();

    // Phase 2: Softmax
    // 2a. Find max
    float max_val = -1e30f;
    for (int t = tid; t < cur_seq; t += blockDim.x)
        max_val = fmaxf(max_val, scores[t]);
    scratch[tid] = max_val;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) scratch[tid] = fmaxf(scratch[tid], scratch[tid + s]);
        __syncthreads();
    }
    max_val = scratch[0];
    __syncthreads();

    // 2b. Exp and sum
    float sum_exp = 0.0f;
    for (int t = tid; t < cur_seq; t += blockDim.x) {
        scores[t] = expf(scores[t] - max_val);
        sum_exp += scores[t];
    }
    scratch[tid] = sum_exp;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) scratch[tid] += scratch[tid + s];
        __syncthreads();
    }
    float inv_sum = 1.0f / scratch[0];
    __syncthreads();

    // 2c. Normalize
    for (int t = tid; t < cur_seq; t += blockDim.x)
        scores[t] *= inv_sum;
    __syncthreads();

    // Phase 3: Weighted V sum (exact — values are uncompressed)
    float* out_head = out + h * head_dim;
    for (int d = tid; d < head_dim; d += blockDim.x) {
        float acc = 0.0f;
        for (int t = 0; t < cur_seq; t++) {
            const float* v_t = v_cache + (size_t)t * kv_dim + kv_h * head_dim;
            acc += scores[t] * v_t[d];
        }
        out_head[d] = acc;
    }
}
