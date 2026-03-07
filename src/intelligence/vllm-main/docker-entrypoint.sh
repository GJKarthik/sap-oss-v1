#!/bin/bash
set -e

# Docker entrypoint script for ai-core-privatellm
# Direct GGUF inference with built-in Zig LLM engine
# Supports SAP AI Core with S3 model storage

echo "=== Starting ai-core-privatellm (Direct GGUF Inference) ==="
echo "Gateway Port: ${PORT:-8080}"
echo "Model Path: ${MODEL_PATH:-/app/models}"
echo "GGUF File: ${GGUF_PATH:-}"

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

# Check if model is mounted via AI Core (S3 artifact mount)
if [ -d "/mnt/models" ] && [ -n "$(ls -A /mnt/models 2>/dev/null)" ]; then
    echo "Model mounted from AI Core artifact..."
    # Find first .gguf file
    GGUF_FILE=$(find /mnt/models -name "*.gguf" -type f | head -1)
    if [ -n "$GGUF_FILE" ]; then
        export GGUF_PATH="$GGUF_FILE"
        echo "Found model: $GGUF_PATH"
    fi
fi

# Fallback: check MODEL_PATH directory
if [ -z "$GGUF_PATH" ] && [ -d "$MODEL_DIR" ]; then
    GGUF_FILE=$(find "$MODEL_DIR" -name "*.gguf" -type f | head -1)
    if [ -n "$GGUF_FILE" ]; then
        export GGUF_PATH="$GGUF_FILE"
        echo "Found model in MODEL_PATH: $GGUF_PATH"
    fi
fi

# Verify model exists
if [ -z "$GGUF_PATH" ] || [ ! -f "$GGUF_PATH" ]; then
    echo "ERROR: No GGUF model found!"
    echo "Expected: Set GGUF_PATH env var or mount model to /mnt/models"
    echo "Available paths checked:"
    echo "  - /mnt/models/*.gguf"
    echo "  - ${MODEL_DIR}/*.gguf"
    ls -la /mnt/models 2>/dev/null || echo "  /mnt/models not mounted"
    ls -la "$MODEL_DIR" 2>/dev/null || echo "  $MODEL_DIR empty"
    exit 1
fi

echo "Loading model: $GGUF_PATH"
echo "Model size: $(du -h "$GGUF_PATH" | cut -f1)"

# Start the Zig gateway with direct GGUF inference
echo "Starting Zig gateway on port ${PORT:-8080}..."
./bin/openai-gateway &
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
echo "Model: $GGUF_PATH"
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
