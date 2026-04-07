/**
 * DART Head FFI Header
 * 
 * C-compatible interface for the DART draft head implemented in Mojo.
 * Include this header in Zig via @cImport to call DART head functions.
 * 
 * Build:
 *   mojo build src/dart/dart_ffi.mojo --emit shared-lib -o libdart_head.dylib
 *   
 * Link:
 *   zig build-exe main.zig -I../include -L. -ldart_head
 */

#ifndef DART_FFI_H
#define DART_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Types
 * ============================================================================ */

/** Opaque handle to a DART head instance */
typedef void* DartHeadHandle;

/** C-compatible configuration struct */
typedef struct DartHeadConfigFFI {
    int32_t hidden_size;          /**< Target model hidden dim (e.g., 4096) */
    int32_t vocab_size;           /**< Vocabulary size (e.g., 32000) */
    int32_t num_draft_positions;  /**< K - draft positions (4 for T4) */
    int32_t head_hidden_size;     /**< Compressed head dim (512 recommended) */
    int32_t num_heads;            /**< Attention heads (8) */
    int32_t ffn_multiplier_x100;  /**< FFN multiplier * 100 (200 for 2.0) */
    int32_t use_int8;             /**< Enable INT8 quantization (1/0) */
    int32_t _padding;             /**< Alignment padding */
} DartHeadConfigFFI;

/* ============================================================================
 * Lifecycle Functions
 * ============================================================================ */

/**
 * Create a new DART head instance.
 * 
 * @param config Pointer to configuration struct
 * @return Handle to the instance (0 on failure)
 */
DartHeadHandle dart_head_create(const DartHeadConfigFFI* config);

/**
 * Destroy a DART head instance and free memory.
 * 
 * @param handle Handle returned by dart_head_create
 */
void dart_head_destroy(DartHeadHandle handle);

/* ============================================================================
 * Inference Functions
 * ============================================================================ */

/**
 * Run DART head forward pass.
 * 
 * Predicts K draft tokens in parallel from target model hidden states.
 * 
 * @param handle Instance handle
 * @param hidden_states Input tensor [batch, prefix_len, hidden_size] FP16
 * @param batch_size Batch dimension
 * @param prefix_len Sequence length (number of prefix tokens)
 * @param output_logits Output tensor [batch, K, vocab_size] FP16 (pre-allocated)
 * @return 0 on success, -1 on error
 */
int32_t dart_head_forward(
    DartHeadHandle handle,
    const void* hidden_states,  /* _Float16* */
    int32_t batch_size,
    int32_t prefix_len,
    void* output_logits         /* _Float16* */
);

/**
 * Extract top-k candidate tokens from logits.
 * 
 * @param handle Instance handle
 * @param logits Input tensor [batch, K, vocab_size] FP16
 * @param batch_size Batch dimension
 * @param K Number of draft positions
 * @param n_candidates Number of candidates per position (typically 5)
 * @param out_ids Output token IDs [batch, K, n_candidates] U32 (pre-allocated)
 * @param out_log_probs Output log probabilities [batch, K, n_candidates] F32 (pre-allocated)
 * @return 0 on success, -1 on error
 */
int32_t dart_head_get_top_k(
    DartHeadHandle handle,
    const void* logits,         /* _Float16* */
    int32_t batch_size,
    int32_t K,
    int32_t n_candidates,
    uint32_t* out_ids,
    float* out_log_probs
);

/* ============================================================================
 * Configuration and Status
 * ============================================================================ */

/**
 * Get configuration of a DART head instance.
 * 
 * @param handle Instance handle
 * @param out_config Pointer to config struct to fill
 * @return 0 on success, -1 on error
 */
int32_t dart_head_get_config(
    DartHeadHandle handle,
    DartHeadConfigFFI* out_config
);

/**
 * Get memory usage of a DART head instance.
 * 
 * @param handle Instance handle
 * @return Memory usage in MB, or -1.0 on error
 */
float dart_head_memory_usage_mb(DartHeadHandle handle);

/* ============================================================================
 * Weight Loading
 * ============================================================================ */

/**
 * Load weights from a binary buffer.
 * 
 * Weight format (sequential):
 *   - input_proj: [hidden_size, head_hidden_size] INT8
 *   - wq, wk, wv, wo: [head_hidden_size, head_hidden_size] INT8 each
 *   - ffn_w1: [head_hidden_size, ffn_dim] INT8
 *   - ffn_w2: [ffn_dim, head_hidden_size] INT8
 *   - lm_head: [head_hidden_size, vocab_size] INT8
 *   - mask_tokens: [K, head_hidden_size] FP16
 *   - norm weights/biases: [head_hidden_size] FP16 each (4 tensors)
 *   - scales: 8 x float (one per INT8 tensor)
 * 
 * @param handle Instance handle
 * @param weight_data Pointer to weight buffer
 * @param data_size Size of buffer in bytes
 * @return 0 on success, -1 on error
 */
int32_t dart_head_load_weights(
    DartHeadHandle handle,
    const uint8_t* weight_data,
    int64_t data_size
);

/* ============================================================================
 * Default Configurations
 * ============================================================================ */

/** Default configuration for LLaMA-3.1-8B on T4 */
static inline DartHeadConfigFFI dart_config_llama_8b(void) {
    DartHeadConfigFFI config = {
        .hidden_size = 4096,
        .vocab_size = 128256,
        .num_draft_positions = 4,
        .head_hidden_size = 512,
        .num_heads = 8,
        .ffn_multiplier_x100 = 200,
        .use_int8 = 1,
        ._padding = 0
    };
    return config;
}

/** Default configuration for Qwen2.5-7B on T4 */
static inline DartHeadConfigFFI dart_config_qwen_7b(void) {
    DartHeadConfigFFI config = {
        .hidden_size = 3584,
        .vocab_size = 152064,
        .num_draft_positions = 4,
        .head_hidden_size = 512,
        .num_heads = 8,
        .ffn_multiplier_x100 = 200,
        .use_int8 = 1,
        ._padding = 0
    };
    return config;
}

/** Default configuration for generic 7B model on T4 */
static inline DartHeadConfigFFI dart_config_default(void) {
    DartHeadConfigFFI config = {
        .hidden_size = 4096,
        .vocab_size = 32000,
        .num_draft_positions = 4,
        .head_hidden_size = 512,
        .num_heads = 8,
        .ffn_multiplier_x100 = 200,
        .use_int8 = 1,
        ._padding = 0
    };
    return config;
}

#ifdef __cplusplus
}
#endif

#endif /* DART_FFI_H */
