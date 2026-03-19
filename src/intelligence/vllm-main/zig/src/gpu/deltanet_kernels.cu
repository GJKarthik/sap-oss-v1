#include <cuda_fp16.h>

// ============================================================================
// 0. Q4_0 GEMV: y[M] = W_q4[M×K] @ x[K]
// ============================================================================
// Grid: (ceil(M/8), 1), Block: (256, 1) — 8 warps per block, 1 warp per row.
// Shared memory: K * sizeof(float) for x[] cache.
// Q4_0 block: 18 bytes = 2 (f16 scale) + 16 (32 nibbles packed).
// Vectorized: loads 16 data bytes via 4×uint32 instead of scalar byte loads.
extern "C" __global__ void q4_gemv(
    float* __restrict__ y,
    const unsigned char* __restrict__ W,
    const float* __restrict__ x,
    int M,
    int K)
{
    extern __shared__ float x_smem[];

    // Cooperative load of x[] into shared memory using float4 (128-bit) loads
    const int K4 = K >> 2;
    float4* x_smem4 = reinterpret_cast<float4*>(x_smem);
    const float4* x4 = reinterpret_cast<const float4*>(x);
    for (int i = threadIdx.x; i < K4; i += blockDim.x) {
        x_smem4[i] = __ldg(&x4[i]);
    }
    // Handle remaining elements (K not multiple of 4)
    for (int i = K4 * 4 + threadIdx.x; i < K; i += blockDim.x) {
        x_smem[i] = __ldg(&x[i]);
    }
    __syncthreads();

    int lane = threadIdx.x & 31;
    int warp_id = threadIdx.x >> 5;
    int row = blockIdx.x * 8 + warp_id;
    if (row >= M) return;

    int n_blocks = K >> 5;
    int row_stride = n_blocks * 18;
    const unsigned char* W_row = W + (long long)row * row_stride;

    float acc = 0.0f;

    for (int b = lane; b < n_blocks; b += 32) {
        const unsigned char* block = W_row + b * 18;

        // Load f16 scale via read-only cache
        float scale = __half2float(__ldg(reinterpret_cast<const __half*>(block)));

        int x_base = b << 5;
        const unsigned char* data = block + 2;

        // Process 16 data bytes with unrolled loop, using __ldg for read-only cache
        #pragma unroll
        for (int j = 0; j < 16; j++) {
            unsigned int byte_val = __ldg(&data[j]);
            acc += (float)((int)(byte_val & 0xF) - 8) * scale * x_smem[x_base + j];
            acc += (float)((int)(byte_val >> 4) - 8) * scale * x_smem[x_base + j + 16];
        }
    }

    // Warp shuffle butterfly reduction
    for (int offset = 16; offset > 0; offset >>= 1) {
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
    }

    if (lane == 0) {
        y[row] = acc;
    }
}

// DeltaNet kernels for Qwen3.5 hybrid architecture
// Compile: nvcc -ptx -arch=sm_75 -o deltanet_kernels.ptx deltanet_kernels.cu
//
// Kernels for Gated DeltaNet linear attention:
// 1. deltanet_conv1d: depthwise conv1d with state shift (autoregressive)
// 2. deltanet_l2norm: per-head L2 normalization for Q and K
// 3. deltanet_gates: compute alpha (decay) and beta (update) gates
// 4. deltanet_recurrent: core recurrent state update + readout
// 5. deltanet_output_gate: y = rms_norm(y) * silu(gate)
// 6. partial_rope: apply RoPE to only first rope_dim elements per head
// 7. split_q_gate: split fused Q+gate into separate Q and gate buffers

// ============================================================================
// 1. Depthwise Conv1d (autoregressive single-token)
// ============================================================================
// State: [conv_kernel-1][channels] — sliding window of past inputs
// Weight: [conv_kernel][channels] — per-channel 1D kernel
// Input: new_input[channels] — current token's projected values
// Output: conv_out[channels] — convolved output
//
// Operation per channel c:
//   conv_out[c] = sum_{k=0}^{K-1} weight[k][c] * state_or_input[k][c]
//   where state_or_input = [state[0..K-2][c], new_input[c]]
//   Then shift state left and store new_input at end.
extern "C" __global__ void deltanet_conv1d(
    float* __restrict__ conv_out,        // [channels]
    float* __restrict__ conv_state,      // [(K-1) × channels]
    const float* __restrict__ new_input, // [channels]
    const float* __restrict__ weight,    // [K × channels]
    int channels, int kernel_size)
{
    int c = blockIdx.x * blockDim.x + threadIdx.x;
    if (c >= channels) return;

    const int K = kernel_size;
    float acc = 0.0f;

    // Cache input (conv_out and new_input may alias)
    float input_val = new_input[c];

    // Accumulate over kernel window: state[0..K-2] + new_input
    // Weight layout from GGUF: [channels × K] where ne[0]=K (fastest), ne[1]=channels
    // Access as weight[c * K + k]
    for (int k = 0; k < K - 1; k++) {
        acc += conv_state[k * channels + c] * weight[c * K + k];
    }
    acc += input_val * weight[c * K + (K - 1)];

    // SiLU activation: silu(x) = x * sigmoid(x)
    conv_out[c] = acc * (1.0f / (1.0f + expf(-acc)));

    // Shift state left: state[k] = state[k+1], then state[K-2] = new_input
    for (int k = 0; k < K - 2; k++) {
        conv_state[k * channels + c] = conv_state[(k + 1) * channels + c];
    }
    conv_state[(K - 2) * channels + c] = input_val;
}

// ============================================================================
// 2. Per-head L2 Normalization
// ============================================================================
// Normalizes each head's vector to unit length.
// For Q: scale by 1/sqrt(head_dim) after normalization.
// For K: just normalize to unit length.
//
// Input: x[num_heads × head_dim]
// Output: out[num_heads × head_dim] = x / ||x||_2 * scale
extern "C" __global__ void deltanet_l2norm(
    float* __restrict__ out,
    const float* __restrict__ x,
    int head_dim, int num_heads, float scale)
{
    int h = blockIdx.x;
    if (h >= num_heads) return;

    // Each block handles one head. Use shared memory for reduction.
    extern __shared__ float sdata[];

    float local_sum = 0.0f;
    for (int d = threadIdx.x; d < head_dim; d += blockDim.x) {
        float val = x[h * head_dim + d];
        local_sum += val * val;
    }
    sdata[threadIdx.x] = local_sum;
    __syncthreads();

    // Warp reduction
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (threadIdx.x < s) sdata[threadIdx.x] += sdata[threadIdx.x + s];
        __syncthreads();
    }

    float norm = rsqrtf(sdata[0] + 1e-12f) * scale;

    for (int d = threadIdx.x; d < head_dim; d += blockDim.x) {
        out[h * head_dim + d] = x[h * head_dim + d] * norm;
    }
}

// ============================================================================
// 3. DeltaNet Gate Computation
// ============================================================================
// Computes decay (alpha) and update (beta) gates from projections.
//
// alpha[h] = exp(-exp(A_log[h]) * softplus(alpha_proj[h] + dt_bias[h]))
// beta[h] = sigmoid(beta_proj[h])
//
// alpha_proj and beta_proj are pre-computed via GEMV (W_alpha @ x, W_beta @ x)
extern "C" __global__ void deltanet_gates(
    float* __restrict__ alpha_out,      // [num_heads]
    float* __restrict__ beta_out,       // [num_heads]
    const float* __restrict__ alpha_proj, // [num_heads] from W_alpha @ x
    const float* __restrict__ beta_proj,  // [num_heads] from W_beta @ x
    const float* __restrict__ A_log,      // [num_heads] learned parameter
    const float* __restrict__ dt_bias,    // [num_heads] learned bias
    int num_heads)
{
    int h = blockIdx.x * blockDim.x + threadIdx.x;
    if (h >= num_heads) return;

    // Alpha (decay): exp(A * softplus(proj + bias))
    // GGUF stores A = -exp(A_log) (already negated+exponentiated by converter)
    float A = A_log[h];  // actually A = -exp(A_log), a negative value
    float dt = alpha_proj[h] + dt_bias[h];
    float sp = (dt > 20.0f) ? dt : logf(1.0f + expf(dt));  // softplus
    float alpha = expf(A * sp);
    alpha_out[h] = alpha;

    // Beta (update): sigmoid(proj)
    float b = beta_proj[h];
    beta_out[h] = 1.0f / (1.0f + expf(-b));
}

// ============================================================================
// 4. DeltaNet Recurrent State Update + Readout  [OPTIMIZED]
// ============================================================================
// State layout: S[h][d1][d2] (original row-major, d1 is outer).
// Each thread owns one d2 column. Threads stride over d2 values.
//
// Optimizations vs. naive:
//  - K and Q loaded into shared memory once per block (eliminates repeated
//    global reads of k_h[d1] and q_h[d1] across all d2 threads)
//  - 3 passes over d1 fused into 2: decay+retrieve in pass1, write+readout
//    fused in pass2 (was 3 separate loops = 3× S[][] traffic)
//
// Grid: (num_v_heads, 1)  Block: min(D, 256) threads
// Shared memory: 2*D*sizeof(float) for K and Q
extern "C" __global__ void deltanet_recurrent(
    float* __restrict__ y_out,       // [num_v_heads × D]
    float* __restrict__ S,           // [num_v_heads × D × D]  layout: S[h][d1][d2]
    const float* __restrict__ q,     // [num_kv_heads × D]
    const float* __restrict__ k,     // [num_kv_heads × D]
    const float* __restrict__ v,     // [num_v_heads × D]
    const float* __restrict__ alpha, // [num_v_heads]
    const float* __restrict__ beta,  // [num_v_heads]
    int D,
    int num_kv_heads)
{
    int h     = blockIdx.x;
    int num_v = gridDim.x;
    int kv_h  = h * num_kv_heads / num_v;

    float a = alpha[h];
    float b = beta[h];

    // Shared memory: k_smem[D] | q_smem[D]
    extern __shared__ float smem[];
    float* k_smem = smem;
    float* q_smem = smem + D;

    const float* k_h = k + kv_h * D;
    const float* q_h = q + kv_h * D;
    for (int i = threadIdx.x; i < D; i += blockDim.x) {
        k_smem[i] = k_h[i];
        q_smem[i] = q_h[i];
    }
    __syncthreads();

    float* S_h       = S + (size_t)h * D * D;
    const float* v_h = v + h * D;
    float* y_h       = y_out + h * D;

    // Each thread handles one d2
    for (int d2 = threadIdx.x; d2 < D; d2 += blockDim.x) {

        // Pass 1: decay all S[d1][d2] in-place, accumulate kv_mem
        float kv_mem = 0.0f;
        for (int d1 = 0; d1 < D; d1++) {
            float s = S_h[d1 * D + d2] * a;
            S_h[d1 * D + d2] = s;
            kv_mem += s * k_smem[d1];
        }

        // Delta
        float delta = (v_h[d2] - kv_mem) * b;

        // Pass 2: write delta + readout (fused — 1 pass instead of 2)
        float y_val = 0.0f;
        for (int d1 = 0; d1 < D; d1++) {
            float s = S_h[d1 * D + d2] + k_smem[d1] * delta;
            S_h[d1 * D + d2] = s;
            y_val += s * q_smem[d1];
        }
        y_h[d2] = y_val;
    }
}

// ============================================================================
// 5. Output Gating: y = rms_norm(y) * silu(gate)
// ============================================================================
// Applied after DeltaNet readout:
//   y = rms_norm(y, ssm_norm_weight) * (gate * sigmoid(gate))
// Then output projection is a separate GEMV.
//
// y: [inner_size] — DeltaNet readout (num_v_heads × head_dim)
// gate: [inner_size] — from W_gate @ x
// norm_weight: [head_dim] or [inner_size] — RMSNorm weight
//   norm_stride=0 → shared across heads (weight size = head_dim), index as norm_w[d]
//   norm_stride=head_dim → per-head weights (weight size = inner_size), index as norm_w[h*head_dim+d]
extern "C" __global__ void deltanet_output_gate(
    float* __restrict__ out,           // [inner_size]
    const float* __restrict__ y,       // [inner_size]
    const float* __restrict__ gate,    // [inner_size]
    const float* __restrict__ norm_w,  // [head_dim] or [inner_size] RMSNorm weight
    int head_dim, int num_heads, float eps, int norm_stride)
{
    // Each block handles one head
    int h = blockIdx.x;
    if (h >= num_heads) return;

    extern __shared__ float sdata[];

    const float* y_h = y + h * head_dim;
    const float* gate_h = gate + h * head_dim;
    float* out_h = out + h * head_dim;
    const float* nw_h = norm_w + h * norm_stride;  // norm_stride=0 → shared, =head_dim → per-head

    // Compute RMS of y_h
    float ss = 0.0f;
    for (int d = threadIdx.x; d < head_dim; d += blockDim.x) {
        float val = y_h[d];
        ss += val * val;
    }
    sdata[threadIdx.x] = ss;
    __syncthreads();

    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (threadIdx.x < s) sdata[threadIdx.x] += sdata[threadIdx.x + s];
        __syncthreads();
    }

    float rms = rsqrtf(sdata[0] / (float)head_dim + eps);

    // Apply: out = rms_norm(y) * norm_weight * silu(gate)
    for (int d = threadIdx.x; d < head_dim; d += blockDim.x) {
        float normed = y_h[d] * rms * nw_h[d];
        float g = gate_h[d];
        float silu_g = g / (1.0f + expf(-g));  // silu = x * sigmoid(x)
        out_h[d] = normed * silu_g;
    }
}

// ============================================================================
// 6. Partial RoPE: apply RoPE to only first rope_dim elements per head
// ============================================================================
// For Qwen3.5 attention layers: head_dim=256 but rope_dim=64.
// Only the first 64 elements of each head get RoPE, rest pass through.
// NeoX/IMROPE half-split: rotate pairs (x[i], x[i + half]).
extern "C" __global__ void partial_rope_q(
    float* __restrict__ q,  // [n_heads × head_dim]
    int pos, int head_dim, int rope_dim, float freq_base, int n_heads)
{
    int h = blockIdx.x;
    if (h >= n_heads) return;

    float* q_h = q + h * head_dim;
    int half = rope_dim / 2;

    // NeoX-style: pairs are (x[i], x[i + half]) for i = 0..half-1
    for (int i = threadIdx.x; i < half; i += blockDim.x) {
        float freq = 1.0f / powf(freq_base, (float)(2 * i) / (float)rope_dim);
        float angle = (float)pos * freq;
        float cos_val = cosf(angle);
        float sin_val = sinf(angle);

        float q0 = q_h[i];
        float q1 = q_h[i + half];
        q_h[i]        = q0 * cos_val - q1 * sin_val;
        q_h[i + half] = q0 * sin_val + q1 * cos_val;
    }
}

extern "C" __global__ void partial_rope_k(
    float* __restrict__ k,  // [n_kv_heads × head_dim]
    int pos, int head_dim, int rope_dim, float freq_base, int n_kv_heads)
{
    int h = blockIdx.x;
    if (h >= n_kv_heads) return;

    float* k_h = k + h * head_dim;
    int half = rope_dim / 2;

    // NeoX-style: pairs are (x[i], x[i + half]) for i = 0..half-1
    for (int i = threadIdx.x; i < half; i += blockDim.x) {
        float freq = 1.0f / powf(freq_base, (float)(2 * i) / (float)rope_dim);
        float angle = (float)pos * freq;
        float cos_val = cosf(angle);
        float sin_val = sinf(angle);

        float k0 = k_h[i];
        float k1 = k_h[i + half];
        k_h[i]        = k0 * cos_val - k1 * sin_val;
        k_h[i + half] = k0 * sin_val + k1 * cos_val;
    }
}

// ============================================================================
// 7. Split fused Q+gate into separate Q and gate buffers
// ============================================================================
// Attention layers in Qwen3.5 fuse Q and gate in attn_q weight output.
// HF layout: view(n_heads, head_dim*2) then chunk(2, dim=-1)
// So fused is interleaved per head: [H0_Q(hd), H0_Gate(hd), H1_Q(hd), H1_Gate(hd), ...]
// Input: fused[2 × q_dim], with q_dim = n_heads * head_dim
// Output: q[q_dim], gate[q_dim] (contiguous per-head Q and gate)
extern "C" __global__ void split_q_gate(
    float* __restrict__ q_out,
    float* __restrict__ gate_out,
    const float* __restrict__ fused,
    int q_dim,
    int head_dim)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= q_dim) return;
    int head = i / head_dim;
    int d = i % head_dim;
    int fused_idx = head * (head_dim * 2) + d;
    q_out[i] = fused[fused_idx];
    gate_out[i] = fused[fused_idx + head_dim];
}

// ============================================================================
// 8. Decode Attention (arbitrary head_dim, replaces PTX kernel for head_dim>128)
// ============================================================================
// Single-token GQA decode attention against KV cache.
// Grid: (n_heads, 1), Block: (256, 1)
// Shared: cur_seq * 4 bytes (for softmax scores) + 256 * 4 (reduction scratch)
//
// out[n_heads * head_dim] = softmax(Q @ K^T / scale) @ V
// Handles arbitrary head_dim (including 256 for Qwen3.5).
extern "C" __global__ void decode_attention(
    float* __restrict__ out,        // [n_heads * head_dim]
    const float* __restrict__ q,    // [n_heads * head_dim]
    const float* __restrict__ k_cache, // [max_seq * kv_dim]
    const float* __restrict__ v_cache, // [max_seq * kv_dim]
    int n_heads, int n_kv_heads, int head_dim, int kv_dim,
    int cur_seq, float scale)
{
    int h = blockIdx.x;
    if (h >= n_heads) return;
    int kv_h = h / (n_heads / n_kv_heads);  // GQA mapping
    int tid = threadIdx.x;

    extern __shared__ float smem[];
    // Layout: scores[cur_seq] | scratch[256]
    float* scores = smem;
    float* scratch = smem + cur_seq;

    const float* q_head = q + h * head_dim;

    // Phase 1: Compute Q @ K^T scores
    for (int t = tid; t < cur_seq; t += blockDim.x) {
        const float* k_t = k_cache + (size_t)t * kv_dim + kv_h * head_dim;
        float dot = 0.0f;
        for (int d = 0; d < head_dim; d++)
            dot += q_head[d] * k_t[d];
        scores[t] = dot * scale;
    }
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

    // Phase 3: Weighted V sum — each thread handles a subset of dimensions
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

// ============================================================================
// 9. Gated attention output: out = attn_out * sigmoid(gate)
// ============================================================================
// For attention layers in hybrid models. Reference: attn_output * torch.sigmoid(gate)
extern "C" __global__ void gated_attn_output(
    float* __restrict__ out,
    const float* __restrict__ attn_out,
    const float* __restrict__ gate,
    int dim)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= dim) return;
    float g = gate[i];
    float sig_g = 1.0f / (1.0f + expf(-g));
    out[i] = attn_out[i] * sig_g;
}
