/**
 * MiniMax2.5 Model-Specific CUDA Kernels
 *
 * Optimizations for MiniMax2.5 architecture:
 * - Lightning Attention (linear attention with gating)
 * - Mixture of Experts (MoE) routing with load balancing
 * - Fused expert computation (gate * SwiGLU)
 * - Expert-parallel execution
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cmath>
#include <cfloat>

// ============================================================================
// Constants for MiniMax2.5
// ============================================================================

#define BLOCK_SIZE 256
#define WARP_SIZE 32
#define NUM_WARPS (BLOCK_SIZE / WARP_SIZE)
#define MINIMAX_NUM_EXPERTS 8
#define MINIMAX_TOP_K 2
#define MINIMAX_HEAD_DIM 128

// ============================================================================
// Lightning Attention Kernel
// ============================================================================

/**
 * Lightning Attention Forward Pass
 * 
 * Linear attention with gating: O(N*d²) instead of O(N²*d)
 * Computes: o_t = (q_t * gate_q) @ S_t where S_t = decay * S_{t-1} + k_t * v_t^T
 * 
 * Grid: (batch_size, num_heads)
 * Block: (BLOCK_SIZE)
 */
__global__ void minimax25_lightning_attention_kernel(
    float* __restrict__ output,
    const float* __restrict__ query,
    const float* __restrict__ key,
    const float* __restrict__ value,
    const float* __restrict__ gate_q,
    const float* __restrict__ gate_k,
    const float* __restrict__ decay,
    const int batch_size,
    const int seq_len,
    const int num_heads,
    const int head_dim
) {
    extern __shared__ float smem[];
    
    int batch_idx = blockIdx.x;
    int head_idx = blockIdx.y;
    int tid = threadIdx.x;
    
    // Shared memory for state matrix S_t [head_dim x head_dim]
    float* s_state = smem;
    float* q_gated = smem + head_dim * head_dim;
    float* k_gated = q_gated + head_dim;
    
    // Initialize state to zero
    for (int i = tid; i < head_dim * head_dim; i += BLOCK_SIZE) {
        s_state[i] = 0.0f;
    }
    __syncthreads();
    
    float decay_val = decay[head_idx];
    
    // Process sequence sequentially
    for (int t = 0; t < seq_len; ++t) {
        int offset = ((batch_idx * num_heads + head_idx) * seq_len + t) * head_dim;
        
        // Load and gate query/key
        if (tid < head_dim) {
            q_gated[tid] = query[offset + tid] * gate_q[offset + tid];
            k_gated[tid] = key[offset + tid] * gate_k[offset + tid];
        }
        __syncthreads();
        
        // Update state: S_t = decay * S_{t-1} + k_t * v_t^T
        for (int i = tid; i < head_dim * head_dim; i += BLOCK_SIZE) {
            int row = i / head_dim;
            int col = i % head_dim;
            float v_val = value[offset + col];
            s_state[i] = decay_val * s_state[i] + k_gated[row] * v_val;
        }
        __syncthreads();
        
        // Compute output: o_t = q_t @ S_t
        for (int i = tid; i < head_dim; i += BLOCK_SIZE) {
            float out = 0.0f;
            for (int j = 0; j < head_dim; ++j) {
                out += q_gated[j] * s_state[j * head_dim + i];
            }
            output[offset + i] = out;
        }
        __syncthreads();
    }
}

// ============================================================================
// MoE Routing Kernel
// ============================================================================

/**
 * MoE Expert Routing
 * 
 * Compute router logits and select top-k experts per token.
 * Output: expert_indices[batch*seq, top_k], expert_weights[batch*seq, top_k]
 */
__global__ void minimax25_moe_route_kernel(
    int* __restrict__ expert_indices,
    float* __restrict__ expert_weights,
    const float* __restrict__ hidden_states,
    const float* __restrict__ gate_weight,
    const int batch_size,
    const int seq_len,
    const int hidden_dim,
    const int num_experts
) {
    int token_idx = blockIdx.x * blockDim.x + threadIdx.x;
    int total_tokens = batch_size * seq_len;
    
    if (token_idx >= total_tokens) return;
    
    extern __shared__ float logits[];
    
    // Compute router logits: logits = hidden @ gate_weight
    for (int e = threadIdx.x; e < num_experts; e += blockDim.x) {
        float logit = 0.0f;
        for (int d = 0; d < hidden_dim; ++d) {
            logit += hidden_states[token_idx * hidden_dim + d] * 
                     gate_weight[e * hidden_dim + d];
        }
        logits[e] = logit;
    }
    __syncthreads();
    
    // Softmax over experts
    float max_logit = -FLT_MAX;
    for (int e = threadIdx.x; e < num_experts; e += blockDim.x) {
        max_logit = fmaxf(max_logit, logits[e]);
    }
    
    float sum_exp = 0.0f;
    for (int e = threadIdx.x; e < num_experts; e += blockDim.x) {
        logits[e] = expf(logits[e] - max_logit);
        sum_exp += logits[e];
    }
    
    // Normalize
    for (int e = threadIdx.x; e < num_experts; e += blockDim.x) {
        logits[e] /= (sum_exp + 1e-6f);
    }
    __syncthreads();
    
    // Select top-k experts (simplified: top-2)
    if (threadIdx.x == 0) {
        float top1 = -1.0f, top2 = -1.0f;
        int idx1 = 0, idx2 = 1;
        
        for (int e = 0; e < num_experts; ++e) {
            if (logits[e] > top1) {
                top2 = top1; idx2 = idx1;
                top1 = logits[e]; idx1 = e;
            } else if (logits[e] > top2) {
                top2 = logits[e]; idx2 = e;
            }
        }
        
        expert_indices[token_idx * MINIMAX_TOP_K] = idx1;
        expert_indices[token_idx * MINIMAX_TOP_K + 1] = idx2;
        expert_weights[token_idx * MINIMAX_TOP_K] = top1;
        expert_weights[token_idx * MINIMAX_TOP_K + 1] = top2;
    }
}

// ============================================================================
// SwiGLU Expert FFN Kernel
// ============================================================================

/**
 * Fused SwiGLU for MoE FFN
 * 
 * output = down_proj(swiglu(gate_proj(x), up_proj(x)))
 * Fused gate*silu(up) step for efficiency.
 */
__global__ void minimax25_swiglu_expert_kernel(
    float* __restrict__ output,
    const float* __restrict__ input,
    const float* __restrict__ gate_proj_weight,
    const float* __restrict__ up_proj_weight,
    const float* __restrict__ down_proj_weight,
    const int num_tokens,
    const int hidden_dim,
    const int intermediate_dim
) {
    int token_idx = blockIdx.x;
    int tid = threadIdx.x;
    
    extern __shared__ float smem[];
    float* gate_out = smem;
    float* up_out = smem + intermediate_dim;
    
    // Compute gate_proj(x) and up_proj(x) in parallel
    for (int i = tid; i < intermediate_dim; i += blockDim.x) {
        float g = 0.0f, u = 0.0f;
        for (int d = 0; d < hidden_dim; ++d) {
            g += input[token_idx * hidden_dim + d] * gate_proj_weight[i * hidden_dim + d];
            u += input[token_idx * hidden_dim + d] * up_proj_weight[i * hidden_dim + d];
        }
        gate_out[i] = g;
        up_out[i] = u;
    }
    __syncthreads();
    
    // Fused SwiGLU: gate * silu(up)
    for (int i = tid; i < intermediate_dim; i += blockDim.x) {
        float silu_val = up_out[i] / (1.0f + expf(-up_out[i]));
        gate_out[i] = gate_out[i] * silu_val;
    }
    __syncthreads();
    
    // Compute down_proj
    for (int i = tid; i < hidden_dim; i += blockDim.x) {
        float out = 0.0f;
        for (int j = 0; j < intermediate_dim; ++j) {
            out += gate_out[j] * down_proj_weight[i * intermediate_dim + j];
        }
        output[token_idx * hidden_dim + i] = out;
    }
}

// ============================================================================
// Extern C Wrappers
// ============================================================================

extern "C" int minimax25_lightning_attention_forward(
    float* output, const float* query, const float* key, const float* value,
    const float* gate_q, const float* gate_k, const float* decay,
    int batch_size, int seq_len, int num_heads, int head_dim
) {
    dim3 grid(batch_size, num_heads);
    dim3 block(BLOCK_SIZE);
    size_t smem_size = (head_dim * head_dim + 2 * head_dim) * sizeof(float);
    
    minimax25_lightning_attention_kernel<<<grid, block, smem_size>>>(
        output, query, key, value, gate_q, gate_k, decay,
        batch_size, seq_len, num_heads, head_dim
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

extern "C" int minimax25_moe_route(
    int* expert_indices, float* expert_weights,
    const float* hidden_states, const float* gate_weight,
    int batch_size, int seq_len, int hidden_dim,
    int num_experts, int top_k
) {
    int total_tokens = batch_size * seq_len;
    int grid_size = (total_tokens + BLOCK_SIZE - 1) / BLOCK_SIZE;
    size_t smem_size = num_experts * sizeof(float);
    
    minimax25_moe_route_kernel<<<grid_size, BLOCK_SIZE, smem_size>>>(
        expert_indices, expert_weights, hidden_states, gate_weight,
        batch_size, seq_len, hidden_dim, num_experts
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

extern "C" int minimax25_swiglu_expert_forward(
    float* output, const float* input,
    const float* gate_proj_weight, const float* up_proj_weight,
    const float* down_proj_weight,
    int num_tokens, int hidden_dim, int intermediate_dim
) {
    size_t smem_size = 2 * intermediate_dim * sizeof(float);
    
    minimax25_swiglu_expert_kernel<<<num_tokens, BLOCK_SIZE, smem_size>>>(
        output, input, gate_proj_weight, up_proj_weight, down_proj_weight,
        num_tokens, hidden_dim, intermediate_dim
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

