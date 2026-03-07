#!/bin/bash
# SAP BTP AI Core Entrypoint Script
# Handles model loading from Object Store and starts the LLM server
#
# Environment variables set by AI Core:
#   - AICORE_ARTIFACT_*  : Mounted artifact paths
#   - MODEL_PATH         : Path to models (defaults to /mnt/models)
#   - DEFAULT_MODEL      : Model filename to load
#   - PORT               : Server port (defaults to 8080)

set -e

echo "======================================"
echo "SAP BTP AI Core LLM Server Starting"
echo "======================================"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ""

# ============================================================================
# Detect AI Core environment
# ============================================================================
if [ -n "$AICORE_ARTIFACT_PATH" ]; then
    echo "[INFO] Running in SAP AI Core environment"
    MODEL_PATH="${AICORE_ARTIFACT_PATH}"
else
    echo "[INFO] Running in standalone mode"
    MODEL_PATH="${MODEL_PATH:-/mnt/models}"
fi

# ============================================================================
# Configuration
# ============================================================================
PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"
DEFAULT_MODEL="${DEFAULT_MODEL:-phi-2.Q4_K_M.gguf}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-4096}"
LLAMA_N_GPU_LAYERS="${LLAMA_N_GPU_LAYERS:-99}"
LLAMA_PARALLEL="${LLAMA_PARALLEL:-4}"

echo "[CONFIG] Model Path: ${MODEL_PATH}"
echo "[CONFIG] Default Model: ${DEFAULT_MODEL}"
echo "[CONFIG] Port: ${PORT}"
echo "[CONFIG] Context Size: ${LLAMA_CTX_SIZE}"
echo "[CONFIG] GPU Layers: ${LLAMA_N_GPU_LAYERS}"
echo "[CONFIG] Parallel Requests: ${LLAMA_PARALLEL}"
echo ""

# ============================================================================
# GPU Detection
# ============================================================================
echo "[GPU] Detecting NVIDIA GPU..."
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || true
    echo ""
else
    echo "[WARN] nvidia-smi not found - running in CPU mode"
fi

# ============================================================================
# Model Discovery
# ============================================================================
echo "[MODELS] Searching for models in ${MODEL_PATH}..."

# Find GGUF models
GGUF_FILES=$(find "${MODEL_PATH}" -name "*.gguf" 2>/dev/null || echo "")
if [ -z "$GGUF_FILES" ]; then
    echo "[WARN] No .gguf files found in ${MODEL_PATH}"
    
    # Check if model artifact is in nested directory
    NESTED_GGUF=$(find "${MODEL_PATH}" -type f -name "*.gguf" 2>/dev/null | head -1)
    if [ -n "$NESTED_GGUF" ]; then
        echo "[INFO] Found model at: ${NESTED_GGUF}"
        MODEL_FILE="${NESTED_GGUF}"
    else
        echo "[ERROR] No GGUF model files found. Please ensure models are uploaded to AI Core Object Store."
        echo "[ERROR] Expected path: ${MODEL_PATH}/${DEFAULT_MODEL}"
        exit 1
    fi
else
    echo "[MODELS] Found models:"
    echo "$GGUF_FILES" | head -10
    
    # Select model
    if [ -f "${MODEL_PATH}/${DEFAULT_MODEL}" ]; then
        MODEL_FILE="${MODEL_PATH}/${DEFAULT_MODEL}"
    elif [ -f "${MODEL_PATH}/llm/${DEFAULT_MODEL}" ]; then
        MODEL_FILE="${MODEL_PATH}/llm/${DEFAULT_MODEL}"
    else
        # Use first available model
        MODEL_FILE=$(echo "$GGUF_FILES" | head -1)
    fi
fi

echo ""
echo "[SELECTED] Using model: ${MODEL_FILE}"
echo ""

# ============================================================================
# Start llama.cpp server
# ============================================================================
echo "[START] Launching llama-server..."
echo "======================================"

# Build command arguments
LLAMA_ARGS=(
    "--model" "${MODEL_FILE}"
    "--host" "${HOST}"
    "--port" "${PORT}"
    "--ctx-size" "${LLAMA_CTX_SIZE}"
    "--n-gpu-layers" "${LLAMA_N_GPU_LAYERS}"
    "--parallel" "${LLAMA_PARALLEL}"
)

# Add continuous batching if enabled
if [ "${LLAMA_CONT_BATCHING}" = "true" ]; then
    LLAMA_ARGS+=("--cont-batching")
fi

# Add flash attention for T4 optimization
if [ "${LLAMA_FLASH_ATTENTION}" = "true" ]; then
    LLAMA_ARGS+=("--flash-attn")
fi

# Log the command
echo "[CMD] llama-server ${LLAMA_ARGS[*]}"
echo ""

# Execute llama-server
exec llama-server "${LLAMA_ARGS[@]}"