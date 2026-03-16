/**
 * Pipeline Parallelism — Multi-GPU Stage-based Inference
 *
 * Complements tensor parallelism (TP) with pipeline parallelism (PP).
 * Splits transformer layers across GPU stages, enabling 2D parallelism:
 *   - TP within a stage (split weights horizontally)
 *   - PP across stages (split layers vertically)
 *
 * Architecture (GPipe / PipeDream-style):
 *   - Each GPU stage owns a contiguous range of transformer layers
 *   - Micro-batching hides inter-stage communication latency
 *   - Double-buffered activation transfers for compute/comm overlap
 *   - P2P (cudaMemcpyPeer) for inter-stage activation transfer
 *
 * Example: 32-layer model on 4 GPUs × 2 TP = 8 GPUs total
 *   PP Stage 0: layers  0-7  (2 GPUs with TP)
 *   PP Stage 1: layers  8-15 (2 GPUs with TP)
 *   PP Stage 2: layers 16-23 (2 GPUs with TP)
 *   PP Stage 3: layers 24-31 (2 GPUs with TP)
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// ============================================================================
// Error Handling
// ============================================================================

#define PP_CUDA_CHECK(cmd) do {                                               \
    cudaError_t e = cmd;                                                      \
    if (e != cudaSuccess) {                                                   \
        fprintf(stderr, "PP CUDA error %s:%d '%s'\n",                         \
                __FILE__, __LINE__, cudaGetErrorString(e));                   \
        return -1;                                                            \
    }                                                                         \
} while(0)

// ============================================================================
// Constants
// ============================================================================

#define PP_MAX_STAGES     16
#define PP_MAX_MICROBATCH  8

// ============================================================================
// Pipeline Parallel State
// ============================================================================

struct PipelineStage {
    int device_id;                    // CUDA device for this stage
    int first_layer;                  // First transformer layer index
    int num_layers;                   // Number of layers in this stage
    cudaStream_t compute_stream;      // Compute stream for this stage
    cudaStream_t transfer_stream;     // P2P transfer stream
    cudaEvent_t  compute_done;        // Signalled when compute finishes
    cudaEvent_t  transfer_done;       // Signalled when transfer finishes
    float* d_activation_buf[2];       // Double-buffered activation [hidden_dim * max_micro_batch]
    float* d_weights;                 // Layer weights for this stage
    size_t weights_bytes;
    bool   initialized;
};

struct PipelineParallelState {
    PipelineStage stages[PP_MAX_STAGES];
    int pp_size;                      // Number of pipeline stages
    int rank;                         // This process's PP rank (stage index)
    int hidden_dim;
    int max_micro_batch_size;
    int num_micro_batches;            // For schedule (GPipe: pp_size micro-batches)
    bool initialized;
};

static PipelineParallelState g_pp = {0};

// ============================================================================
// Lifecycle
// ============================================================================

extern "C" int pp_init(
    int pp_size, int rank, int hidden_dim,
    int total_layers, int max_micro_batch_size
) {
    if (g_pp.initialized) return 0;
    if (pp_size <= 0 || pp_size > PP_MAX_STAGES) return CUDA_ERR_INVALID_ARG;
    if (total_layers % pp_size != 0) return CUDA_ERR_INVALID_ARG;
    if (rank < 0 || rank >= pp_size) return CUDA_ERR_INVALID_ARG;

    g_pp.pp_size = pp_size;
    g_pp.rank = rank;
    g_pp.hidden_dim = hidden_dim;
    g_pp.max_micro_batch_size = max_micro_batch_size;
    g_pp.num_micro_batches = pp_size; // GPipe default

    int layers_per_stage = total_layers / pp_size;
    size_t act_buf_size = (size_t)hidden_dim * max_micro_batch_size * sizeof(float);

    for (int s = 0; s < pp_size; s++) {
        PipelineStage* st = &g_pp.stages[s];
        st->device_id = s;  // 1 device per stage (or map via config)
        st->first_layer = s * layers_per_stage;
        st->num_layers = layers_per_stage;
        st->initialized = false;

        // Only initialise our own stage fully (others are metadata-only)
        if (s == rank) {
            PP_CUDA_CHECK(cudaSetDevice(st->device_id));
            PP_CUDA_CHECK(cudaStreamCreate(&st->compute_stream));
            PP_CUDA_CHECK(cudaStreamCreate(&st->transfer_stream));
            PP_CUDA_CHECK(cudaEventCreate(&st->compute_done));
            PP_CUDA_CHECK(cudaEventCreate(&st->transfer_done));

            // Double-buffered activation slots
            PP_CUDA_CHECK(cudaMalloc(&st->d_activation_buf[0], act_buf_size));
            PP_CUDA_CHECK(cudaMalloc(&st->d_activation_buf[1], act_buf_size));

            st->d_weights = nullptr;
            st->weights_bytes = 0;
            st->initialized = true;
        }
    }

    // Enable P2P access between adjacent stages
    if (rank > 0) {
        int prev = g_pp.stages[rank - 1].device_id;
        int curr = g_pp.stages[rank].device_id;
        int can_access = 0;
        cudaDeviceCanAccessPeer(&can_access, curr, prev);
        if (can_access) {
            cudaSetDevice(curr);
            cudaDeviceEnablePeerAccess(prev, 0);
        }
    }
    if (rank < pp_size - 1) {
        int next = g_pp.stages[rank + 1].device_id;
        int curr = g_pp.stages[rank].device_id;
        int can_access = 0;
        cudaDeviceCanAccessPeer(&can_access, curr, next);
        if (can_access) {
            cudaSetDevice(curr);
            cudaDeviceEnablePeerAccess(next, 0);
        }
    }

    g_pp.initialized = true;
    return 0;
}

extern "C" void pp_shutdown(void) {
    if (!g_pp.initialized) return;
    PipelineStage* st = &g_pp.stages[g_pp.rank];
    if (st->initialized) {
        cudaSetDevice(st->device_id);
        cudaFree(st->d_activation_buf[0]);
        cudaFree(st->d_activation_buf[1]);
        cudaFree(st->d_weights);
        cudaStreamDestroy(st->compute_stream);
        cudaStreamDestroy(st->transfer_stream);
        cudaEventDestroy(st->compute_done);
        cudaEventDestroy(st->transfer_done);
        st->initialized = false;
    }
    g_pp.initialized = false;
}

// ============================================================================
// Weight Loading — Upload this stage's layer weights to GPU
// ============================================================================

extern "C" int pp_load_stage_weights(
    const float* h_weights, size_t weights_bytes
) {
    if (!g_pp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    PipelineStage* st = &g_pp.stages[g_pp.rank];
    if (!st->initialized) return CUDA_ERR_NOT_INITIALIZED;

    cudaSetDevice(st->device_id);

    // Free previous weights if any
    if (st->d_weights) cudaFree(st->d_weights);

    PP_CUDA_CHECK(cudaMalloc(&st->d_weights, weights_bytes));
    PP_CUDA_CHECK(cudaMemcpy(st->d_weights, h_weights, weights_bytes,
                             cudaMemcpyHostToDevice));
    st->weights_bytes = weights_bytes;
    return 0;
}

// ============================================================================
// Micro-batch Forward — Process one micro-batch through this stage
// ============================================================================

/**
 * Forward pass for a single micro-batch through the layers owned by this stage.
 * Uses double-buffered activations: reads from buf[buf_idx], writes to buf[1-buf_idx].
 *
 * For each layer in the stage:
 *   1. RMS norm
 *   2. GEMM (linear projections)
 *   3. Activation (SwiGLU/ReLU)
 *   4. Residual connection
 *
 * Weight layout per layer:
 *   norm[hidden_dim] + linear[hidden_dim * hidden_dim]
 */
extern "C" int pp_forward_micro_batch(
    float* output, const float* input,
    int micro_batch_size, int buf_idx
) {
    if (!g_pp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    PipelineStage* st = &g_pp.stages[g_pp.rank];
    if (!st->initialized || !st->d_weights) return CUDA_ERR_NOT_INITIALIZED;

    int hd = g_pp.hidden_dim;
    size_t act_bytes = (size_t)hd * micro_batch_size * sizeof(float);

    cudaSetDevice(st->device_id);

    // Copy input to activation buffer
    float* act = st->d_activation_buf[buf_idx];
    PP_CUDA_CHECK(cudaMemcpyAsync(act, input, act_bytes,
                                  cudaMemcpyDeviceToDevice, st->compute_stream));

    // Process each layer in this stage
    const float* w_ptr = st->d_weights;
    size_t layer_stride = (size_t)hd + (size_t)hd * hd; // norm + linear per layer

    for (int l = 0; l < st->num_layers; l++) {
        const float* w_norm = w_ptr + l * layer_stride;
        const float* w_linear = w_norm + hd;

        // RMS norm → temp buf (reuse other activation slot)
        float* temp = st->d_activation_buf[1 - buf_idx];
        cuda_rms_norm(temp, act, w_norm, hd, 1e-5f);

        // Linear: act = temp × w_linear^T + residual
        cublas_sgemm(act, temp, w_linear,
                     micro_batch_size, hd, hd, 1.0f, 0.0f);

        // Residual connection: act += input of this layer
        cuda_vec_add(act, act, temp, hd * micro_batch_size);
    }

    // Copy result to output
    PP_CUDA_CHECK(cudaMemcpyAsync(output, act, act_bytes,
                                  cudaMemcpyDeviceToDevice, st->compute_stream));
    PP_CUDA_CHECK(cudaEventRecord(st->compute_done, st->compute_stream));
    return 0;
}

// ============================================================================
// Inter-stage Transfer — Send activations to next stage via P2P
// ============================================================================

extern "C" int pp_send_activation(
    float* d_dst, const float* d_src,
    int count, int dst_device
) {
    if (!g_pp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    PipelineStage* st = &g_pp.stages[g_pp.rank];

    // Wait for compute to finish before transferring
    PP_CUDA_CHECK(cudaStreamWaitEvent(st->transfer_stream, st->compute_done, 0));

    PP_CUDA_CHECK(cudaMemcpyPeerAsync(
        d_dst, dst_device,
        d_src, st->device_id,
        (size_t)count * sizeof(float),
        st->transfer_stream));

    PP_CUDA_CHECK(cudaEventRecord(st->transfer_done, st->transfer_stream));
    return 0;
}

extern "C" int pp_recv_activation_wait(void) {
    if (!g_pp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    PipelineStage* st = &g_pp.stages[g_pp.rank];
    PP_CUDA_CHECK(cudaStreamWaitEvent(st->compute_stream, st->transfer_done, 0));
    return 0;
}

// ============================================================================
// GPipe Schedule — Full forward pass with micro-batching
// ============================================================================

/**
 * Execute the full GPipe schedule for this stage.
 *
 * GPipe schedule for 4 stages, 4 micro-batches:
 *
 *  Time →  0   1   2   3   4   5   6
 *  GPU 0: μ0  μ1  μ2  μ3
 *  GPU 1:     μ0  μ1  μ2  μ3
 *  GPU 2:         μ0  μ1  μ2  μ3
 *  GPU 3:             μ0  μ1  μ2  μ3
 *
 * Each stage processes micro-batches in sequence, overlapping
 * computation with P2P transfers using double buffering.
 */
extern "C" int pp_gpipe_forward(
    float* output, const float* input,
    int batch_size, int num_micro_batches
) {
    if (!g_pp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    if (num_micro_batches <= 0 || num_micro_batches > PP_MAX_MICROBATCH)
        return CUDA_ERR_INVALID_ARG;

    int hd = g_pp.hidden_dim;
    int micro_batch_size = batch_size / num_micro_batches;
    if (micro_batch_size <= 0) return CUDA_ERR_INVALID_ARG;

    PipelineStage* st = &g_pp.stages[g_pp.rank];

    for (int m = 0; m < num_micro_batches; m++) {
        int buf_idx = m % 2; // Double-buffer index
        const float* mb_input = input + (size_t)m * hd * micro_batch_size;
        float* mb_output = output + (size_t)m * hd * micro_batch_size;

        // If not first stage, wait for activation from previous stage
        if (g_pp.rank > 0) {
            pp_recv_activation_wait();
            mb_input = st->d_activation_buf[buf_idx]; // Use received data
        }

        // Forward through this stage's layers
        int ret = pp_forward_micro_batch(mb_output, mb_input,
                                         micro_batch_size, buf_idx);
        if (ret != 0) return ret;

        // If not last stage, send activation to next stage
        if (g_pp.rank < g_pp.pp_size - 1) {
            PipelineStage* next = &g_pp.stages[g_pp.rank + 1];
            int next_buf = m % 2;
            pp_send_activation(
                next->d_activation_buf[next_buf], mb_output,
                hd * micro_batch_size, next->device_id);
        }
    }

    // Synchronise before returning
    PP_CUDA_CHECK(cudaStreamSynchronize(st->compute_stream));
    return 0;
}

// ============================================================================
// Query Functions
// ============================================================================

extern "C" int pp_get_rank(void)           { return g_pp.rank; }
extern "C" int pp_get_size(void)           { return g_pp.pp_size; }
extern "C" int pp_get_stage_layers(void)   {
    return g_pp.initialized ? g_pp.stages[g_pp.rank].num_layers : 0;
}
extern "C" int pp_get_first_layer(void)    {
    return g_pp.initialized ? g_pp.stages[g_pp.rank].first_layer : 0;
}
extern "C" int pp_is_initialized(void)     { return g_pp.initialized ? 1 : 0; }
extern "C" int pp_get_hidden_dim(void)     { return g_pp.hidden_dim; }
extern "C" int pp_get_num_micro_batches(void) { return g_pp.num_micro_batches; }

