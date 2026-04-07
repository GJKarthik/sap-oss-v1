/**
 * Tensor Parallelism — Multi-GPU Distributed Inference
 *
 * Splits transformer weights across multiple GPUs using NCCL for
 * communication.  Enables serving 70B+ parameter models on clusters
 * of T4/L4 GPUs.
 *
 * Parallelism strategy (Megatron-LM style):
 *   - **Row-parallel**  (QKV projections, gate/up FFN):
 *       Weight [hidden, hidden] sharded along output dim → each GPU
 *       computes a slice → all-reduce to combine.
 *   - **Column-parallel** (output projection, down FFN):
 *       Weight [hidden, hidden] sharded along input dim → each GPU
 *       gets its slice of the input, computes full output → no
 *       communication needed (result is already correct).
 *   - **Attention heads**: Divided evenly across GPUs.
 *
 * Communication pattern per transformer layer:
 *   1. Row-parallel QKV  → all-reduce after attention output projection
 *   2. Row-parallel FFN gate/up → all-reduce after FFN down projection
 *
 * This gives exactly **2 all-reduces per layer**, matching Megatron-LM.
 *
 * Integration:
 *   - Uses existing cublas_sgemm / cuda_rms_norm / cuda_swiglu kernels.
 *   - Uses existing StreamPool infrastructure via dedicated NCCL stream.
 *   - Weight sharding happens at load time (host-side shard & upload).
 *
 * Build: Link with -lnccl in addition to -lcublas.
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <nccl.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// ============================================================================
// Error Handling
// ============================================================================

#define NCCL_CHECK(cmd) do {                                          \
    ncclResult_t r = cmd;                                             \
    if (r != ncclSuccess) {                                           \
        fprintf(stderr, "NCCL error %s:%d '%s'\n",                    \
                __FILE__, __LINE__, ncclGetErrorString(r));           \
        return -1;                                                    \
    }                                                                 \
} while(0)

#define CUDA_TP_CHECK(cmd) do {                                       \
    cudaError_t e = cmd;                                              \
    if (e != cudaSuccess) {                                           \
        fprintf(stderr, "CUDA error %s:%d '%s'\n",                    \
                __FILE__, __LINE__, cudaGetErrorString(e));           \
        return -1;                                                    \
    }                                                                 \
} while(0)

// ============================================================================
// Tensor Parallel State
// ============================================================================

struct TensorParallelState {
    ncclComm_t comm;
    cudaStream_t nccl_stream;   // Dedicated stream for NCCL ops
    cudaStream_t compute_stream; // Compute stream for overlap
    cudaEvent_t  sync_event;    // For compute/comm synchronisation

    int rank;        // This GPU's rank [0, tp_size)
    int tp_size;     // Total number of GPUs in the TP group
    int device_id;   // CUDA device ordinal for this rank

    // Per-layer scratch buffers (allocated once, reused)
    float* d_allreduce_buf;     // [max_hidden_dim] for in-place all-reduce
    float* d_shard_q;           // [shard_hidden]   Q shard
    float* d_shard_k;           // [shard_hidden]   K shard
    float* d_shard_v;           // [shard_hidden]   V shard
    float* d_shard_attn_out;    // [shard_hidden]   attention output shard
    float* d_shard_ffn_gate;    // [shard_hidden]   FFN gate shard
    float* d_shard_ffn_up;      // [shard_hidden]   FFN up shard
    float* d_norm;              // [hidden_dim]     norm scratch
    float* d_hidden;            // [hidden_dim]     hidden state

    int hidden_dim;
    int shard_dim;    // hidden_dim / tp_size
    int num_heads;
    int shard_heads;  // num_heads / tp_size
    int head_dim;
    int vocab_size;

    bool initialized;
};

static TensorParallelState g_tp = {0};

// ============================================================================
// Initialization & Shutdown
// ============================================================================

/**
 * Initialize tensor parallelism.
 *
 * Must be called on each GPU process/thread with its own rank.
 * The NCCL unique ID must be created on rank 0 and broadcast to
 * all ranks (e.g., via MPI_Bcast or shared memory).
 *
 * @param nccl_unique_id  NCCL unique ID bytes (ncclUniqueId.internal).
 * @param rank            This GPU's rank [0, tp_size).
 * @param tp_size         Total number of GPUs.
 * @param hidden_dim      Model hidden dimension (must be divisible by tp_size).
 * @param num_heads       Total number of attention heads (divisible by tp_size).
 * @param head_dim        Dimension per head.
 * @param vocab_size      Vocabulary size.
 * @return 0 on success.
 */
extern "C" int tp_init(
    const char* nccl_unique_id_bytes,
    int rank,
    int tp_size,
    int hidden_dim,
    int num_heads,
    int head_dim,
    int vocab_size
) {
    if (g_tp.initialized) return 0;

    // Validate divisibility
    if (hidden_dim % tp_size != 0) {
        fprintf(stderr, "tp_init: hidden_dim (%d) not divisible by tp_size (%d)\n",
                hidden_dim, tp_size);
        return CUDA_ERR_INVALID_ARG;
    }
    if (num_heads % tp_size != 0) {
        fprintf(stderr, "tp_init: num_heads (%d) not divisible by tp_size (%d)\n",
                num_heads, tp_size);
        return CUDA_ERR_INVALID_ARG;
    }

    g_tp.rank = rank;
    g_tp.tp_size = tp_size;
    g_tp.device_id = rank; // Convention: rank i → device i
    g_tp.hidden_dim = hidden_dim;
    g_tp.shard_dim = hidden_dim / tp_size;
    g_tp.num_heads = num_heads;
    g_tp.shard_heads = num_heads / tp_size;
    g_tp.head_dim = head_dim;
    g_tp.vocab_size = vocab_size;

    // Set CUDA device
    CUDA_TP_CHECK(cudaSetDevice(g_tp.device_id));

    // Initialise NCCL communicator
    ncclUniqueId id;
    memcpy(&id, nccl_unique_id_bytes, sizeof(ncclUniqueId));
    NCCL_CHECK(ncclCommInitRank(&g_tp.comm, tp_size, id, rank));

    // Create streams and events
    CUDA_TP_CHECK(cudaStreamCreateWithFlags(&g_tp.nccl_stream, cudaStreamNonBlocking));
    CUDA_TP_CHECK(cudaStreamCreateWithFlags(&g_tp.compute_stream, cudaStreamNonBlocking));
    CUDA_TP_CHECK(cudaEventCreateWithFlags(&g_tp.sync_event, cudaEventDisableTiming));

    // Allocate scratch buffers
    int sd = g_tp.shard_dim;
    int hd = hidden_dim;
    CUDA_TP_CHECK(cudaMalloc(&g_tp.d_allreduce_buf, hd * sizeof(float)));
    CUDA_TP_CHECK(cudaMalloc(&g_tp.d_shard_q,       sd * sizeof(float)));
    CUDA_TP_CHECK(cudaMalloc(&g_tp.d_shard_k,       sd * sizeof(float)));
    CUDA_TP_CHECK(cudaMalloc(&g_tp.d_shard_v,       sd * sizeof(float)));
    CUDA_TP_CHECK(cudaMalloc(&g_tp.d_shard_attn_out, sd * sizeof(float)));
    CUDA_TP_CHECK(cudaMalloc(&g_tp.d_shard_ffn_gate, sd * sizeof(float)));
    CUDA_TP_CHECK(cudaMalloc(&g_tp.d_shard_ffn_up,   sd * sizeof(float)));
    CUDA_TP_CHECK(cudaMalloc(&g_tp.d_norm,   hd * sizeof(float)));
    CUDA_TP_CHECK(cudaMalloc(&g_tp.d_hidden, hd * sizeof(float)));

    g_tp.initialized = true;
    return 0;
}

/**
 * Generate a new NCCL unique ID (call on rank 0 only, then broadcast).
 * @param out  Buffer to receive sizeof(ncclUniqueId) bytes.
 */
extern "C" int tp_get_unique_id(char* out) {
    ncclUniqueId id;
    NCCL_CHECK(ncclGetUniqueId(&id));
    memcpy(out, &id, sizeof(ncclUniqueId));
    return 0;
}

/**
 * @return Size in bytes of the NCCL unique ID (for callers to allocate).
 */
extern "C" int tp_unique_id_size(void) {
    return (int)sizeof(ncclUniqueId);
}

extern "C" void tp_shutdown(void) {
    if (!g_tp.initialized) return;

    if (g_tp.d_allreduce_buf)  cudaFree(g_tp.d_allreduce_buf);
    if (g_tp.d_shard_q)        cudaFree(g_tp.d_shard_q);
    if (g_tp.d_shard_k)        cudaFree(g_tp.d_shard_k);
    if (g_tp.d_shard_v)        cudaFree(g_tp.d_shard_v);
    if (g_tp.d_shard_attn_out) cudaFree(g_tp.d_shard_attn_out);
    if (g_tp.d_shard_ffn_gate) cudaFree(g_tp.d_shard_ffn_gate);
    if (g_tp.d_shard_ffn_up)   cudaFree(g_tp.d_shard_ffn_up);
    if (g_tp.d_norm)           cudaFree(g_tp.d_norm);
    if (g_tp.d_hidden)         cudaFree(g_tp.d_hidden);

    if (g_tp.sync_event)       cudaEventDestroy(g_tp.sync_event);
    if (g_tp.compute_stream)   cudaStreamDestroy(g_tp.compute_stream);
    if (g_tp.nccl_stream)      cudaStreamDestroy(g_tp.nccl_stream);
    if (g_tp.comm)             ncclCommDestroy(g_tp.comm);

    memset(&g_tp, 0, sizeof(g_tp));
}

// ============================================================================
// Communication Primitives
// ============================================================================

/**
 * In-place all-reduce (sum) on the given buffer.
 * Runs on the dedicated NCCL stream; caller must synchronise as needed.
 *
 * @param buf   Device pointer to reduce. Modified in place.
 * @param count Number of float elements.
 * @return 0 on success.
 */
extern "C" int tp_allreduce(float* buf, int count) {
    if (!g_tp.initialized) return -1;
    NCCL_CHECK(ncclAllReduce(
        buf, buf, count, ncclFloat, ncclSum, g_tp.comm, g_tp.nccl_stream));
    return 0;
}

/**
 * All-reduce and synchronise: blocks until the reduction is complete.
 */
extern "C" int tp_allreduce_sync(float* buf, int count) {
    if (tp_allreduce(buf, count) != 0) return -1;
    CUDA_TP_CHECK(cudaStreamSynchronize(g_tp.nccl_stream));
    return 0;
}

/**
 * All-gather: each rank contributes `send_count` elements;
 * `recv_buf` receives tp_size * send_count elements.
 */
extern "C" int tp_allgather(
    float* recv_buf, const float* send_buf, int send_count
) {
    if (!g_tp.initialized) return -1;
    NCCL_CHECK(ncclAllGather(
        send_buf, recv_buf, send_count, ncclFloat, g_tp.comm, g_tp.nccl_stream));
    return 0;
}

/**
 * Insert a CUDA event on the NCCL stream that the compute stream
 * will wait on.  Call after issuing an all-reduce, before launching
 * dependent compute kernels on the compute stream.
 */
extern "C" int tp_sync_comm_to_compute(void) {
    if (!g_tp.initialized) return -1;
    CUDA_TP_CHECK(cudaEventRecord(g_tp.sync_event, g_tp.nccl_stream));
    CUDA_TP_CHECK(cudaStreamWaitEvent(g_tp.compute_stream, g_tp.sync_event, 0));
    return 0;
}

/**
 * Make the NCCL stream wait for the compute stream.
 * Call before issuing an all-reduce that depends on compute results.
 */
extern "C" int tp_sync_compute_to_comm(void) {
    if (!g_tp.initialized) return -1;
    CUDA_TP_CHECK(cudaEventRecord(g_tp.sync_event, g_tp.compute_stream));
    CUDA_TP_CHECK(cudaStreamWaitEvent(g_tp.nccl_stream, g_tp.sync_event, 0));
    return 0;
}

// ============================================================================
// Weight Sharding (Host-Side Utilities)
// ============================================================================

/**
 * Shard a weight matrix for row-parallel linear.
 *
 * Full weight: [in_dim, out_dim]   (row-major)
 * Shard:       [in_dim, out_dim / tp_size]
 *
 * Each rank gets columns [rank * shard_cols, (rank+1) * shard_cols).
 *
 * @param d_shard      Device output [in_dim, shard_cols].
 * @param h_full       Host input [in_dim, out_dim].
 * @param in_dim       Number of input rows.
 * @param out_dim      Full output dimension.
 * @return 0 on success.
 */
extern "C" int tp_shard_weight_row_parallel(
    float* d_shard,
    const float* h_full,
    int in_dim,
    int out_dim
) {
    if (!g_tp.initialized) return -1;
    int shard_cols = out_dim / g_tp.tp_size;
    int col_offset = g_tp.rank * shard_cols;

    // Copy row-by-row (each row is contiguous but we take a column slice)
    for (int row = 0; row < in_dim; row++) {
        CUDA_TP_CHECK(cudaMemcpy(
            d_shard + row * shard_cols,
            h_full + row * out_dim + col_offset,
            shard_cols * sizeof(float),
            cudaMemcpyHostToDevice));
    }
    return 0;
}

/**
 * Shard a weight matrix for column-parallel linear.
 *
 * Full weight: [in_dim, out_dim]   (row-major)
 * Shard:       [in_dim / tp_size, out_dim]
 *
 * Each rank gets rows [rank * shard_rows, (rank+1) * shard_rows).
 *
 * @param d_shard      Device output [shard_rows, out_dim].
 * @param h_full       Host input [in_dim, out_dim].
 * @param in_dim       Full input dimension.
 * @param out_dim      Output dimension.
 * @return 0 on success.
 */
extern "C" int tp_shard_weight_col_parallel(
    float* d_shard,
    const float* h_full,
    int in_dim,
    int out_dim
) {
    if (!g_tp.initialized) return -1;
    int shard_rows = in_dim / g_tp.tp_size;
    int row_offset = g_tp.rank * shard_rows;

    CUDA_TP_CHECK(cudaMemcpy(
        d_shard,
        h_full + (size_t)row_offset * out_dim,
        (size_t)shard_rows * out_dim * sizeof(float),
        cudaMemcpyHostToDevice));
    return 0;
}

/**
 * Shard a 1-D vector (e.g., bias, norm weight) into tp_size equal parts.
 *
 * @param d_shard  Device output [dim / tp_size].
 * @param h_full   Host input [dim].
 * @param dim      Full dimension.
 */
extern "C" int tp_shard_vector(float* d_shard, const float* h_full, int dim) {
    if (!g_tp.initialized) return -1;
    int shard = dim / g_tp.tp_size;
    int offset = g_tp.rank * shard;
    CUDA_TP_CHECK(cudaMemcpy(
        d_shard, h_full + offset, shard * sizeof(float),
        cudaMemcpyHostToDevice));
    return 0;
}

// ============================================================================
// Row-Parallel Linear
// ============================================================================

/**
 * Row-parallel linear: y = x @ W_shard
 *
 * Each GPU holds W_shard [in_dim, shard_out] (columns of full W).
 * Result y_shard [M, shard_out] is a partial result that must be
 * all-reduced across ranks to get the full output.
 *
 * @param y_shard   Device output [M, shard_out].
 * @param x         Device input  [M, in_dim]  (replicated on all ranks).
 * @param w_shard   Device weight [in_dim, shard_out].
 * @param M         Batch / token count.
 * @param in_dim    Input dimension.
 * @param shard_out Output dimension of this shard.
 */
extern "C" int tp_row_parallel_linear(
    float* y_shard,
    const float* x,
    const float* w_shard,
    int M, int in_dim, int shard_out
) {
    return cublas_sgemm(y_shard, x, w_shard, M, shard_out, in_dim, 1.0f, 0.0f);
}

// ============================================================================
// Column-Parallel Linear
// ============================================================================

/**
 * Column-parallel linear: y = x_shard @ W_shard
 *
 * Each GPU holds W_shard [shard_in, out_dim] (rows of full W).
 * Input x_shard [M, shard_in] is the local slice of the hidden state
 * (produced by the previous row-parallel layer's shard).
 * Result y [M, out_dim] is the complete output — no communication needed.
 *
 * @param y         Device output [M, out_dim].
 * @param x_shard   Device input  [M, shard_in].
 * @param w_shard   Device weight [shard_in, out_dim].
 * @param M         Batch / token count.
 * @param shard_in  Input dimension of this shard.
 * @param out_dim   Full output dimension.
 */
extern "C" int tp_col_parallel_linear(
    float* y,
    const float* x_shard,
    const float* w_shard,
    int M, int shard_in, int out_dim
) {
    return cublas_sgemm(y, x_shard, w_shard, M, out_dim, shard_in, 1.0f, 0.0f);
}

// ============================================================================
// TP-Aware Transformer Layer (Single Token Decode)
// ============================================================================

/**
 * Sharded weight layout for one transformer layer (per rank):
 *
 *   attn_norm     [hidden_dim]                     — replicated
 *   Wq_shard      [hidden_dim, shard_dim]           — row-parallel
 *   Wk_shard      [hidden_dim, shard_dim]           — row-parallel
 *   Wv_shard      [hidden_dim, shard_dim]           — row-parallel
 *   Wo_shard      [shard_dim,  hidden_dim]           — column-parallel
 *   ffn_norm      [hidden_dim]                      — replicated
 *   Wgate_shard   [hidden_dim, shard_dim]           — row-parallel
 *   Wup_shard     [hidden_dim, shard_dim]           — row-parallel
 *   Wdown_shard   [shard_dim,  hidden_dim]           — column-parallel
 *
 * Stride per layer (floats):
 *   hidden_dim + hidden_dim*shard_dim*3 + shard_dim*hidden_dim
 *   + hidden_dim + hidden_dim*shard_dim*2 + shard_dim*hidden_dim
 */

/**
 * Compute the per-layer weight stride for sharded weights.
 */
extern "C" size_t tp_layer_weight_stride(void) {
    if (!g_tp.initialized) return 0;
    int hd = g_tp.hidden_dim;
    int sd = g_tp.shard_dim;
    // attn_norm + Wq + Wk + Wv (row-par) + Wo (col-par)
    // + ffn_norm + Wgate + Wup (row-par) + Wdown (col-par)
    return (size_t)hd                   // attn_norm
         + (size_t)hd * sd * 3          // Wq, Wk, Wv
         + (size_t)sd * hd              // Wo
         + (size_t)hd                   // ffn_norm
         + (size_t)hd * sd * 2          // Wgate, Wup
         + (size_t)sd * hd;             // Wdown
}

/**
 * Run one transformer layer with tensor parallelism (single-token decode).
 *
 * hidden [hidden_dim] is the full hidden state, replicated on all ranks.
 * After this function, hidden is updated in-place with the layer output,
 * still replicated on all ranks.
 *
 * Communication: 2 all-reduces per layer.
 *
 * @param hidden          Device [hidden_dim], modified in-place.
 * @param layer_weights   Device sharded weights for this layer (see layout).
 * @param position        Sequence position (for RoPE).
 * @return 0 on success.
 */
extern "C" int tp_transformer_layer(
    float* hidden,
    const float* layer_weights,
    int position
) {
    if (!g_tp.initialized) return -1;

    int hd = g_tp.hidden_dim;
    int sd = g_tp.shard_dim;

    // Weight sub-pointers
    const float* w_attn_norm = layer_weights;
    const float* w_q  = w_attn_norm + hd;
    const float* w_k  = w_q  + (size_t)hd * sd;
    const float* w_v  = w_k  + (size_t)hd * sd;
    const float* w_o  = w_v  + (size_t)hd * sd;
    const float* w_ffn_norm = w_o + (size_t)sd * hd;
    const float* w_gate = w_ffn_norm + hd;
    const float* w_up   = w_gate + (size_t)hd * sd;
    const float* w_down = w_up   + (size_t)hd * sd;

    // ----------------------------------------------------------------
    // 1. Attention block
    // ----------------------------------------------------------------

    // 1a. RMS Norm (replicated — same on all ranks)
    cuda_rms_norm(g_tp.d_norm, hidden, w_attn_norm, hd, 1e-5f);

    // 1b. Q/K/V projections — row-parallel
    //     Each rank computes norm[1,hd] @ Wq_shard[hd,sd] → q_shard[1,sd]
    cublas_sgemm(g_tp.d_shard_q, g_tp.d_norm, w_q, 1, sd, hd, 1.0f, 0.0f);
    cublas_sgemm(g_tp.d_shard_k, g_tp.d_norm, w_k, 1, sd, hd, 1.0f, 0.0f);
    cublas_sgemm(g_tp.d_shard_v, g_tp.d_norm, w_v, 1, sd, hd, 1.0f, 0.0f);

    // 1c. RoPE on the sharded Q and K
    //     shard_heads = num_heads / tp_size, so shard_dim = shard_heads * head_dim
    cuda_rope(g_tp.d_shard_q, g_tp.d_shard_k, position,
              g_tp.head_dim, 10000.0f, g_tp.shard_heads);

    // 1d. Attention on this rank's heads (simplified: single-token decode)
    //     Q_shard[1, shard_heads, head_dim], K/V from KV cache would go here.
    //     For the TP module we compute Q@K^T per head, softmax, @V.
    //     Using cuda_attention with shard_heads:
    cuda_attention(
        g_tp.d_shard_attn_out,
        g_tp.d_shard_q, g_tp.d_shard_k, g_tp.d_shard_v,
        1, 1, g_tp.head_dim, g_tp.shard_heads,
        1.0f / sqrtf((float)g_tp.head_dim), 1
    );

    // 1e. Output projection — column-parallel
    //     attn_out_shard[1,sd] @ Wo_shard[sd,hd] → partial_hidden[1,hd]
    cublas_sgemm(g_tp.d_allreduce_buf, g_tp.d_shard_attn_out, w_o,
                 1, hd, sd, 1.0f, 0.0f);

    // 1f. All-reduce the partial hidden states across ranks
    tp_sync_compute_to_comm();
    tp_allreduce(g_tp.d_allreduce_buf, hd);
    tp_sync_comm_to_compute();

    // 1g. Residual connection: hidden += allreduce_buf
    cuda_vec_add(hidden, hidden, g_tp.d_allreduce_buf, hd);

    // ----------------------------------------------------------------
    // 2. FFN block (SwiGLU)
    // ----------------------------------------------------------------

    // 2a. RMS Norm (replicated)
    cuda_rms_norm(g_tp.d_norm, hidden, w_ffn_norm, hd, 1e-5f);

    // 2b. Gate and Up projections — row-parallel
    //     norm[1,hd] @ Wgate_shard[hd,sd] → gate_shard[1,sd]
    //     norm[1,hd] @ Wup_shard[hd,sd]   → up_shard[1,sd]
    cublas_sgemm(g_tp.d_shard_ffn_gate, g_tp.d_norm, w_gate,
                 1, sd, hd, 1.0f, 0.0f);
    cublas_sgemm(g_tp.d_shard_ffn_up, g_tp.d_norm, w_up,
                 1, sd, hd, 1.0f, 0.0f);

    // 2c. SwiGLU: silu(gate) * up → gate (in-place)
    cuda_swiglu(g_tp.d_shard_ffn_gate, g_tp.d_shard_ffn_gate,
                g_tp.d_shard_ffn_up, sd);

    // 2d. Down projection — column-parallel
    //     gate_shard[1,sd] @ Wdown_shard[sd,hd] → partial_hidden[1,hd]
    cublas_sgemm(g_tp.d_allreduce_buf, g_tp.d_shard_ffn_gate, w_down,
                 1, hd, sd, 1.0f, 0.0f);

    // 2e. All-reduce
    tp_sync_compute_to_comm();
    tp_allreduce(g_tp.d_allreduce_buf, hd);
    tp_sync_comm_to_compute();

    // 2f. Residual
    cuda_vec_add(hidden, hidden, g_tp.d_allreduce_buf, hd);

    return 0;
}

// ============================================================================
// Full TP Forward Pass
// ============================================================================

/**
 * Run a complete tensor-parallel forward pass for single-token decode.
 *
 * Weight layout (per rank, contiguous):
 *   [embed_table_shard (vocab_size * shard_dim),       — NOT used for decode
 *    layer_0 .. layer_N (sharded, see tp_layer_weight_stride),
 *    final_norm (hidden_dim),
 *    lm_head_shard (shard_dim * vocab_size)]            — row-parallel
 *
 * For decode, `input_hidden` is the embedded token [hidden_dim], replicated
 * on all ranks.  Output logits are gathered across ranks.
 *
 * @param output_logits   Device output [vocab_size], valid on all ranks after call.
 * @param input_hidden    Device input  [hidden_dim], replicated.
 * @param weights         Device sharded weights for this rank (see layout).
 * @param num_layers      Number of transformer layers.
 * @param position        Current sequence position (for RoPE).
 * @return 0 on success.
 */
extern "C" int tp_forward_decode(
    float* output_logits,
    const float* input_hidden,
    const float* weights,
    int num_layers,
    int position
) {
    if (!g_tp.initialized) return -1;

    int hd = g_tp.hidden_dim;
    int sd = g_tp.shard_dim;
    int V  = g_tp.vocab_size;

    // Skip embedding table shard (not needed for decode — input_hidden is provided)
    size_t embed_skip = (size_t)V * sd;
    const float* layer_base = weights + embed_skip;

    size_t layer_stride = tp_layer_weight_stride();

    // Copy input hidden state to working buffer
    cudaMemcpyAsync(g_tp.d_hidden, input_hidden, hd * sizeof(float),
                    cudaMemcpyDeviceToDevice, g_tp.compute_stream);

    // Run each layer
    for (int layer = 0; layer < num_layers; layer++) {
        const float* lw = layer_base + (size_t)layer * layer_stride;
        int ret = tp_transformer_layer(g_tp.d_hidden, lw, position);
        if (ret != 0) return ret;
    }

    // Final RMS norm (replicated)
    const float* final_norm = layer_base + (size_t)num_layers * layer_stride;
    cuda_rms_norm(g_tp.d_norm, g_tp.d_hidden, final_norm, hd, 1e-5f);

    // LM head — row-parallel: norm[1,hd] @ lm_head_shard[hd, V_shard]
    //   V is not necessarily divisible by tp_size, so each rank computes
    //   a slice of logits, then we all-gather.
    //   Simplification: replicate lm_head on all ranks and compute full logits.
    //   (For very large vocabs, shard V; for typical 32k–128k vocabs,
    //    replication is more practical.)
    const float* lm_head = final_norm + hd;

    // Each rank computes its shard of the logits:
    //   norm[1, hd] → but we only have shard_dim of the lm_head
    //   lm_head_shard[shard_dim, vocab_size]
    //   We need norm_shard [1, shard_dim] = norm[:, rank*sd:(rank+1)*sd]
    //   Then partial_logits = norm_shard @ lm_head_shard
    //   Then all-reduce to sum partial logits.

    // Extract this rank's slice of the norm output (already full hd)
    // norm_shard = d_norm[rank*sd : (rank+1)*sd]
    float* norm_shard = g_tp.d_norm + (size_t)g_tp.rank * sd;

    // partial_logits = norm_shard[1,sd] @ lm_head_shard[sd,V] → [1,V]
    cublas_sgemm(output_logits, norm_shard, lm_head, 1, V, sd, 1.0f, 0.0f);

    // All-reduce to combine partial logits from all ranks
    tp_sync_compute_to_comm();
    tp_allreduce(output_logits, V);
    tp_sync_comm_to_compute();

    // Synchronise before returning
    CUDA_TP_CHECK(cudaStreamSynchronize(g_tp.compute_stream));

    return 0;
}

// ============================================================================
// Query Functions
// ============================================================================

extern "C" int tp_get_rank(void) { return g_tp.rank; }
extern "C" int tp_get_size(void) { return g_tp.tp_size; }
extern "C" int tp_get_shard_dim(void) { return g_tp.shard_dim; }
extern "C" int tp_get_shard_heads(void) { return g_tp.shard_heads; }
extern "C" int tp_is_initialized(void) { return g_tp.initialized ? 1 : 0; }
