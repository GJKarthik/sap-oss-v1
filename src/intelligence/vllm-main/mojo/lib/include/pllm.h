/**
 * Private LLM Inference Engine - C API
 * 
 * This header defines the C FFI interface for the Mojo-based
 * LLM inference engine with Q4_K_M quantization support.
 */

#ifndef PLLM_H
#define PLLM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle types */
typedef void* pllm_config_t;
typedef void* pllm_model_t;

/* Error codes */
#define PLLM_SUCCESS              0
#define PLLM_ERROR_NULL_POINTER  -1
#define PLLM_ERROR_INVALID_HANDLE -2
#define PLLM_ERROR_OUT_OF_MEMORY -3
#define PLLM_ERROR_INVALID_CONFIG -4
#define PLLM_ERROR_LOAD_FAILED   -5
#define PLLM_ERROR_INFERENCE_FAILED -6
#define PLLM_ERROR_BUFFER_TOO_SMALL -7

/* =========================================================================
 * Configuration Functions
 * ========================================================================= */

/**
 * Create a model configuration with custom parameters.
 */
pllm_config_t pllm_config_create(
    int vocab_size,
    int embed_dim,
    int num_heads,
    int num_kv_heads,
    int num_layers,
    int ffn_dim,
    int max_seq_len
);

/**
 * Create a configuration for LLaMA 1B model.
 */
pllm_config_t pllm_config_create_llama_1b(void);

/**
 * Create a configuration for Phi-2 model.
 */
pllm_config_t pllm_config_create_phi2(void);

/**
 * Free a configuration handle.
 */
int pllm_config_free(pllm_config_t config);

/* =========================================================================
 * Model Loading Functions
 * ========================================================================= */

/**
 * Create an empty model with the given configuration.
 * Weights must be loaded separately.
 */
pllm_model_t pllm_model_create(pllm_config_t config);

/**
 * Load embedding weights (FP32).
 */
int pllm_model_load_embedding(
    pllm_model_t model,
    const float* data,
    size_t num_bytes
);

/**
 * Load Q4_K_M quantized weights for a single layer.
 */
int pllm_model_load_layer_q4(
    pllm_model_t model,
    int layer_idx,
    const uint8_t* wq_data, size_t wq_bytes,
    const uint8_t* wk_data, size_t wk_bytes,
    const uint8_t* wv_data, size_t wv_bytes,
    const uint8_t* wo_data, size_t wo_bytes,
    const uint8_t* wgate_data, size_t wgate_bytes,
    const uint8_t* wup_data, size_t wup_bytes,
    const uint8_t* wdown_data, size_t wdown_bytes
);

/**
 * Load FP32 layer norm weights.
 */
int pllm_model_load_layer_norm(
    pllm_model_t model,
    int layer_idx,
    const float* ln_attn_data,
    const float* ln_ffn_data,
    int embed_dim
);

/**
 * Load final layer norm and LM head weights.
 */
int pllm_model_load_final(
    pllm_model_t model,
    const float* ln_final_data,
    const float* lm_head_data
);

/**
 * Free a model and all its weights.
 */
int pllm_model_free(pllm_model_t model);

/* =========================================================================
 * Inference Functions
 * ========================================================================= */

/**
 * Generate text tokens.
 * 
 * @param model Model handle
 * @param input_tokens Input token IDs
 * @param input_len Number of input tokens
 * @param output_tokens Output buffer (will contain input + generated)
 * @param output_capacity Size of output buffer
 * @param max_new_tokens Maximum new tokens to generate
 * @param temperature Sampling temperature
 * @param top_p Top-p (nucleus) sampling
 * @param eos_token_id End-of-sequence token ID
 * @return Total number of tokens, or negative error code
 */
int pllm_generate(
    pllm_model_t model,
    const int* input_tokens,
    int input_len,
    int* output_tokens,
    int output_capacity,
    int max_new_tokens,
    float temperature,
    float top_p,
    int eos_token_id
);

/**
 * Run forward pass and return logits (low-level API).
 */
int pllm_forward_single(
    pllm_model_t model,
    const float* input_embeds,
    int seq_len,
    float* output_logits
);

/* =========================================================================
 * Memory and Info Functions
 * ========================================================================= */

/**
 * Get model memory usage in MB.
 */
float pllm_model_memory_mb(pllm_model_t model);

/**
 * Get vocabulary size.
 */
int pllm_get_vocab_size(pllm_model_t model);

/**
 * Get embedding dimension.
 */
int pllm_get_embed_dim(pllm_model_t model);

/**
 * Get number of transformer layers.
 */
int pllm_get_num_layers(pllm_model_t model);

/**
 * Get maximum sequence length.
 */
int pllm_get_max_seq_len(pllm_model_t model);

/* =========================================================================
 * Version Info
 * ========================================================================= */

int pllm_version_major(void);
int pllm_version_minor(void);
int pllm_version_patch(void);

#ifdef __cplusplus
}
#endif

#endif /* PLLM_H */
