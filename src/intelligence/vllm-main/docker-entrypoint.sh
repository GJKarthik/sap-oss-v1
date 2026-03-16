#!/bin/bash
set -e

# Docker entrypoint script for ai-core-privatellm
# Direct GGUF inference with built-in Zig LLM engine
# Supports SAP AI Core with S3 model storage

echo "=== Starting ai-core-privatellm (Direct GGUF Inference) ==="
echo "Gateway Port: ${PORT:-8080}"
echo "Model Path: ${MODEL_PATH:-/app/models}"
echo "GGUF File: ${GGUF_PATH:-}"
echo "SafeTensors Index: ${SAFETENSORS_INDEX_PATH:-}"

GATEWAY_BIN="${GATEWAY_BIN:-./bin/openai-gateway}"
if [ ! -x "$GATEWAY_BIN" ] && [ -x "./zig/zig-out/bin/openai-gateway" ]; then
    GATEWAY_BIN="./zig/zig-out/bin/openai-gateway"
fi

cleanup() {
    echo "Shutting down gateway..."
    kill "${GATEWAY_PID:-}" 2>/dev/null || true
    wait "${GATEWAY_PID:-}" 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

# Download model from S3 if configured via AI Core artifact
MODEL_DIR="${MODEL_PATH:-/app/models}"
mkdir -p "$MODEL_DIR"
SAFETENSORS_INDEX_PATH="${SAFETENSORS_INDEX_PATH:-}"

# Check if model is mounted via AI Core (S3 artifact mount)
if [ -d "/mnt/models" ] && [ -n "$(ls -A /mnt/models 2>/dev/null)" ]; then
    echo "Model mounted from AI Core artifact..."
    # Find first .gguf file
    GGUF_FILE=$(find /mnt/models -name "*.gguf" -type f | head -1)
    if [ -n "$GGUF_FILE" ]; then
        export GGUF_PATH="$GGUF_FILE"
        echo "Found model: $GGUF_PATH"
    else
        INDEX_FILE=$(find /mnt/models -name "model.safetensors.index.json" -type f | head -1)
        if [ -n "$INDEX_FILE" ]; then
            export SAFETENSORS_INDEX_PATH="$INDEX_FILE"
            export MODEL_PATH="$(dirname "$INDEX_FILE")"
            MODEL_DIR="$MODEL_PATH"
            echo "Found SafeTensors model directory: $MODEL_PATH"
        fi
    fi
fi

# Fallback: check MODEL_PATH directory
if [ -z "$GGUF_PATH" ] && [ -z "$SAFETENSORS_INDEX_PATH" ] && [ -d "$MODEL_DIR" ]; then
    GGUF_FILE=$(find "$MODEL_DIR" -name "*.gguf" -type f | head -1)
    if [ -n "$GGUF_FILE" ]; then
        export GGUF_PATH="$GGUF_FILE"
        echo "Found model in MODEL_PATH: $GGUF_PATH"
    else
        INDEX_FILE=$(find "$MODEL_DIR" -name "model.safetensors.index.json" -type f | head -1)
        if [ -n "$INDEX_FILE" ]; then
            export SAFETENSORS_INDEX_PATH="$INDEX_FILE"
            export MODEL_PATH="$(dirname "$INDEX_FILE")"
            MODEL_DIR="$MODEL_PATH"
            echo "Found SafeTensors model directory in MODEL_PATH: $MODEL_PATH"
        fi
    fi
fi

# Verify model exists
if [ -n "$GGUF_PATH" ] && [ -f "$GGUF_PATH" ]; then
    echo "Loading GGUF model: $GGUF_PATH"
    echo "Model size: $(du -h "$GGUF_PATH" | cut -f1)"
elif [ -n "$SAFETENSORS_INDEX_PATH" ] && [ -f "$SAFETENSORS_INDEX_PATH" ]; then
    echo "Validated SafeTensors model directory: ${MODEL_PATH}"
    echo "Index file: $SAFETENSORS_INDEX_PATH"
    echo "Direct TOON inference remains disabled until sharded SafeTensors loading is implemented"
else
    echo "ERROR: No supported model artifact found!"
    echo "Expected: Set GGUF_PATH, set MODEL_PATH to a SafeTensors model directory, or mount model to /mnt/models"
    echo "Available paths checked:"
    echo "  - /mnt/models/*.gguf"
    echo "  - /mnt/models/model.safetensors.index.json"
    echo "  - ${MODEL_DIR}/*.gguf"
    echo "  - ${MODEL_DIR}/model.safetensors.index.json"
    ls -la /mnt/models 2>/dev/null || echo "  /mnt/models not mounted"
    ls -la "$MODEL_DIR" 2>/dev/null || echo "  $MODEL_DIR empty"
    exit 1
fi

# Start the Zig gateway with direct GGUF inference
echo "Starting Zig gateway on port ${PORT:-8080}..."
"$GATEWAY_BIN" &
GATEWAY_PID=$!

# Wait for gateway to be ready
echo "Waiting for gateway to be ready..."
RETRY_COUNT=0
until curl -sf http://localhost:${PORT:-8080}/health > /dev/null 2>&1; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge 30 ]; then
        echo "Warning: gateway health check timeout after 30s"
        break
    fi
    sleep 1
done

echo "=== Gateway Started ==="
echo "Gateway available at http://0.0.0.0:${PORT:-8080}"
if [ -n "$GGUF_PATH" ]; then
    echo "Model: $GGUF_PATH"
elif [ -n "$SAFETENSORS_INDEX_PATH" ]; then
    echo "Model directory: $MODEL_PATH"
    echo "Index: $SAFETENSORS_INDEX_PATH"
fi
echo ""
echo "OpenAI-compatible endpoints:"
echo "  POST /v1/chat/completions"
echo "  POST /v1/completions"
echo "  POST /v1/embeddings"
echo "  GET  /v1/models"
echo "  GET  /health"
echo "  GET  /metrics"
echo ""

wait $GATEWAY_PID
