#!/bin/bash
# =============================================================================
# Build Script for Private LLM Mojo Shared Library
#
# Compiles the Mojo inference engine to a shared library (.so/.dylib)
# that can be loaded by Zig via dlopen.
#
# Usage:
#   ./build.sh              # Build release
#   ./build.sh debug        # Build debug
#   ./build.sh clean        # Clean build artifacts
#   ./build.sh test         # Run tests
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
LIB_DIR="${SCRIPT_DIR}/lib"

# Output library name
if [[ "$(uname)" == "Darwin" ]]; then
    LIB_NAME="libpllm.dylib"
    LIB_EXT="dylib"
else
    LIB_NAME="libpllm.so"
    LIB_EXT="so"
fi

# Build mode
BUILD_MODE="${1:-release}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# =============================================================================
# Check Prerequisites
# =============================================================================

check_mojo() {
    if ! command -v mojo &> /dev/null; then
        log_error "Mojo compiler not found in PATH"
        log_info "Install Mojo from: https://www.modular.com/mojo"
        exit 1
    fi
    
    local version=$(mojo --version 2>&1 | head -1)
    log_info "Found Mojo: $version"
}

# =============================================================================
# Clean
# =============================================================================

clean() {
    log_info "Cleaning build artifacts..."
    rm -rf "${BUILD_DIR}"
    rm -rf "${LIB_DIR}"
    rm -f "${SCRIPT_DIR}"/*.o
    rm -f "${SCRIPT_DIR}"/*.${LIB_EXT}
    log_info "Clean complete"
}

# =============================================================================
# Build Shared Library
# =============================================================================

build_lib() {
    log_info "Building libpllm shared library (${BUILD_MODE})..."
    
    mkdir -p "${BUILD_DIR}"
    mkdir -p "${LIB_DIR}"
    
    # Mojo build flags
    local FLAGS=""
    if [[ "${BUILD_MODE}" == "debug" ]]; then
        FLAGS="--no-optimization"
    else
        FLAGS="--optimization-level 3"
    fi
    
    # Main source file that exports FFI functions
    local MAIN_SRC="${SCRIPT_DIR}/src/ffi/exports.mojo"
    
    if [[ ! -f "${MAIN_SRC}" ]]; then
        log_error "Source file not found: ${MAIN_SRC}"
        exit 1
    fi
    
    log_info "Compiling ${MAIN_SRC}..."
    
    # Compile to shared library
    # Note: Mojo's shared library compilation syntax may vary
    cd "${SCRIPT_DIR}"
    
    # Build shared library directly from exports (skip package step)
    mojo build \
        --emit shared-lib \
        -o "${LIB_DIR}/${LIB_NAME}" \
        ${FLAGS} \
        -I src \
        src/ffi/exports.mojo
    
    if [[ -f "${LIB_DIR}/${LIB_NAME}" ]]; then
        log_info "Successfully built: ${LIB_DIR}/${LIB_NAME}"
        
        # Show library info
        if [[ "$(uname)" == "Darwin" ]]; then
            otool -L "${LIB_DIR}/${LIB_NAME}" | head -10
        else
            ldd "${LIB_DIR}/${LIB_NAME}" | head -10
        fi
        
        # Show exported symbols
        log_info "Exported symbols:"
        if [[ "$(uname)" == "Darwin" ]]; then
            nm -g "${LIB_DIR}/${LIB_NAME}" | grep "pllm_" | head -20
        else
            nm -D "${LIB_DIR}/${LIB_NAME}" | grep "pllm_" | head -20
        fi
    else
        log_error "Build failed: ${LIB_DIR}/${LIB_NAME} not created"
        exit 1
    fi
}

# =============================================================================
# Run Tests
# =============================================================================

run_tests() {
    log_info "Running Mojo tests..."
    
    cd "${SCRIPT_DIR}"
    
    # Test Q4_K_M dequantization
    if [[ -f "tests/test_q4_k_m.mojo" ]]; then
        log_info "Running test_q4_k_m.mojo..."
        mojo run tests/test_q4_k_m.mojo
    fi
    
    # Test backend
    if [[ -f "tests/test_backend.mojo" ]]; then
        log_info "Running test_backend.mojo..."
        mojo run tests/test_backend.mojo
    fi
    
    # Test integration
    if [[ -f "tests/test_integration.mojo" ]]; then
        log_info "Running test_integration.mojo..."
        mojo run tests/test_integration.mojo
    fi
    
    log_info "All tests completed"
}

# =============================================================================
# Generate Header File
# =============================================================================

generate_header() {
    log_info "Generating C header file..."
    
    mkdir -p "${LIB_DIR}/include"
    
    cat > "${LIB_DIR}/include/pllm.h" << 'EOF'
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
EOF

    log_info "Generated: ${LIB_DIR}/include/pllm.h"
}

# =============================================================================
# Main
# =============================================================================

main() {
    case "${BUILD_MODE}" in
        clean)
            clean
            ;;
        test)
            check_mojo
            run_tests
            ;;
        debug|release)
            check_mojo
            build_lib
            generate_header
            log_info "Build complete!"
            log_info "Library: ${LIB_DIR}/${LIB_NAME}"
            log_info "Header:  ${LIB_DIR}/include/pllm.h"
            ;;
        *)
            echo "Usage: $0 [release|debug|clean|test]"
            exit 1
            ;;
    esac
}

main