#!/bin/bash
# ===----------------------------------------------------------------------=== #
# Start Arabic Financial Model Server
# Convenience wrapper around start_server.sh for Gemma 4 Arabic GGUF
# ===----------------------------------------------------------------------=== #

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
MODELS_DIR="$PROJECT_DIR/models"
ARABIC_MODEL_DIR="$MODELS_DIR/gemma4-arabic-finance"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Find GGUF file in the model directory
find_gguf() {
    local gguf_file
    gguf_file=$(find "$ARABIC_MODEL_DIR" -name "*.gguf" -type f 2>/dev/null | head -1)
    if [ -z "$gguf_file" ]; then
        echo -e "${RED}[ERROR]${NC} No GGUF file found in $ARABIC_MODEL_DIR"
        echo ""
        echo "Export the model first:"
        echo "  python src/training/nvidia-modelopt/scripts/export_gemma4_gguf.py \\"
        echo "    --adapter-dir ./outputs/gemma4-arabic"
        exit 1
    fi
    echo "$gguf_file"
}

# Print configuration
print_config() {
    local gguf_file="$1"
    echo ""
    echo -e "${CYAN}========================================"
    echo "  Gemma 4 Arabic Financial Model"
    echo "========================================${NC}"
    echo ""
    echo -e "  Model:        ${GREEN}$(basename "$gguf_file")${NC}"
    echo -e "  Context:      ${GREEN}8192${NC} tokens"
    echo -e "  Directory:    $ARABIC_MODEL_DIR"
    echo -e "  Gateway port: ${GREEN}${GATEWAY_PORT:-8080}${NC}"
    echo ""
    echo -e "${CYAN}  Arabic test prompt:${NC}"
    echo -e "  ${YELLOW}ما هو إجمالي الإيرادات للربع الأول؟${NC}"
    echo ""
    echo -e "  curl http://localhost:${GATEWAY_PORT:-8080}/v1/chat/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo '    -d '"'"'{'
    echo '      "model": "gemma4-arabic-finance",'
    echo '      "messages": [{'
    echo '        "role": "system",'
    echo '        "content": "أنت مساعد تحليلات مالية متخصص في SQL"'
    echo '      }, {'
    echo '        "role": "user",'
    echo '        "content": "ما هو إجمالي الإيرادات للربع الأول؟"'
    echo '      }]'
    echo "    }'"
    echo ""
}

# --- Main ---

case "${1:-start}" in
    start)
        GGUF_FILE=$(find_gguf)
        print_config "$GGUF_FILE"

        # Set environment for start_server.sh
        export MODEL_PATH="$GGUF_FILE"
        export CONTEXT_SIZE=8192
        export GPU_LAYERS=${GPU_LAYERS:-99}

        echo -e "${GREEN}[INFO]${NC} Starting server with Gemma 4 Arabic model..."
        exec "$SCRIPT_DIR/start_server.sh" start
        ;;

    --dry-run|dry-run)
        GGUF_FILE=$(find "$ARABIC_MODEL_DIR" -name "*.gguf" -type f 2>/dev/null | head -1)
        if [ -z "$GGUF_FILE" ]; then
            GGUF_FILE="$ARABIC_MODEL_DIR/gemma4-arabic-finance-Q4_K_M.gguf (not yet exported)"
        fi
        print_config "$GGUF_FILE"
        echo -e "${YELLOW}[DRY RUN]${NC} Would start with:"
        echo "  MODEL_PATH=$GGUF_FILE"
        echo "  CONTEXT_SIZE=8192"
        echo "  GPU_LAYERS=${GPU_LAYERS:-99}"
        echo "  GATEWAY_PORT=${GATEWAY_PORT:-8080}"
        echo ""
        ;;

    stop)
        exec "$SCRIPT_DIR/start_server.sh" stop
        ;;

    status)
        exec "$SCRIPT_DIR/start_server.sh" status
        ;;

    *)
        echo "Usage: $0 {start|stop|status|--dry-run}"
        echo ""
        echo "Starts the llama.cpp + OpenAI gateway with the Gemma 4 Arabic GGUF model."
        echo ""
        echo "Environment Variables:"
        echo "  GATEWAY_PORT   OpenAI gateway port (default: 8080)"
        echo "  GPU_LAYERS     GPU layers to offload (default: 99)"
        exit 1
        ;;
esac
