#!/bin/bash
# ===----------------------------------------------------------------------=== #
# Start Local Models Server
# Runs llama.cpp server with GGUF model + OpenAI-compatible gateway
# ===----------------------------------------------------------------------=== #

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
MODELS_DIR="$PROJECT_DIR/models"

# Configuration
LLAMA_PORT=${LLAMA_PORT:-3000}
GATEWAY_PORT=${GATEWAY_PORT:-8080}
MODEL_PATH="${MODEL_PATH:-$MODELS_DIR/llm/phi-2.Q4_K_M.gguf}"
GPU_LAYERS=${GPU_LAYERS:-99}  # For Apple Silicon, offload all layers to GPU
CONTEXT_SIZE=${CONTEXT_SIZE:-4096}
THREADS=${THREADS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if model exists
check_model() {
    if [ ! -f "$MODEL_PATH" ]; then
        print_error "Model not found at: $MODEL_PATH"
        echo ""
        echo "Available models in $MODELS_DIR:"
        find "$MODELS_DIR" -name "*.gguf" -type f 2>/dev/null | head -10
        echo ""
        echo "You can download a model with:"
        echo "  curl -L -o $MODEL_PATH \\"
        echo "    https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/phi-2.Q4_K_M.gguf"
        exit 1
    fi
    print_status "Using model: $MODEL_PATH"
}

# Check if llama-server is installed
check_llama_server() {
    if command -v llama-server &> /dev/null; then
        LLAMA_SERVER="llama-server"
        print_status "Found llama-server (llama.cpp)"
    elif command -v llama-cli &> /dev/null; then
        # llama-cli has server mode in newer versions
        LLAMA_SERVER="llama-cli --server"
        print_status "Found llama-cli with server mode"
    elif [ -f "/opt/homebrew/bin/llama-server" ]; then
        LLAMA_SERVER="/opt/homebrew/bin/llama-server"
        print_status "Found Homebrew llama-server"
    elif [ -f "$HOME/.local/bin/llama-server" ]; then
        LLAMA_SERVER="$HOME/.local/bin/llama-server"
        print_status "Found local llama-server"
    else
        print_warning "llama-server not found. Installing via Homebrew..."
        if command -v brew &> /dev/null; then
            brew install llama.cpp
            LLAMA_SERVER="llama-server"
        else
            print_error "Please install llama.cpp:"
            echo "  brew install llama.cpp"
            echo "  # or build from source: https://github.com/ggerganov/llama.cpp"
            exit 1
        fi
    fi
}

# Check if gateway binary exists
check_gateway() {
    GATEWAY_BIN="$PROJECT_DIR/zig/zig-out/bin/local-models-proxy"
    if [ ! -f "$GATEWAY_BIN" ]; then
        print_warning "Gateway binary not found. Building..."
        cd "$PROJECT_DIR/zig"
        zig build -Doptimize=ReleaseFast
        cd "$SCRIPT_DIR"
    fi
    print_status "Gateway binary: $GATEWAY_BIN"
}

# Start llama.cpp server
start_llama_server() {
    print_status "Starting llama.cpp server on port $LLAMA_PORT..."
    
    # Determine GPU layers based on system
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS with Metal
        print_status "Detected macOS - using Metal GPU acceleration"
        GPU_FLAG="--n-gpu-layers $GPU_LAYERS"
    elif command -v nvidia-smi &> /dev/null; then
        # NVIDIA GPU
        print_status "Detected NVIDIA GPU"
        GPU_FLAG="--n-gpu-layers $GPU_LAYERS"
    else
        # CPU only
        print_status "CPU-only mode"
        GPU_FLAG=""
    fi

    $LLAMA_SERVER \
        --model "$MODEL_PATH" \
        --port $LLAMA_PORT \
        --host 0.0.0.0 \
        --ctx-size $CONTEXT_SIZE \
        --threads $THREADS \
        $GPU_FLAG \
        --log-disable \
        &
    
    LLAMA_PID=$!
    echo $LLAMA_PID > "$PROJECT_DIR/.llama.pid"
    
    # Wait for server to start
    print_status "Waiting for llama.cpp server to start..."
    for i in {1..30}; do
        if curl -s "http://localhost:$LLAMA_PORT/health" > /dev/null 2>&1; then
            print_status "llama.cpp server is ready!"
            return 0
        fi
        sleep 1
    done
    
    print_error "llama.cpp server failed to start"
    kill $LLAMA_PID 2>/dev/null
    exit 1
}

# Start OpenAI gateway
start_gateway() {
    print_status "Starting OpenAI gateway on port $GATEWAY_PORT..."
    
    export BACKEND_URL="http://localhost:$LLAMA_PORT"
    export PORT=$GATEWAY_PORT
    export HOST="0.0.0.0"
    
    $GATEWAY_BIN &
    GATEWAY_PID=$!
    echo $GATEWAY_PID > "$PROJECT_DIR/.gateway.pid"
    
    # Wait for gateway to start
    sleep 2
    if curl -s "http://localhost:$GATEWAY_PORT/health" > /dev/null 2>&1; then
        print_status "OpenAI gateway is ready!"
    else
        print_warning "Gateway may still be starting..."
    fi
}

# Stop servers
stop_servers() {
    print_status "Stopping servers..."
    
    if [ -f "$PROJECT_DIR/.llama.pid" ]; then
        kill $(cat "$PROJECT_DIR/.llama.pid") 2>/dev/null || true
        rm "$PROJECT_DIR/.llama.pid"
    fi
    
    if [ -f "$PROJECT_DIR/.gateway.pid" ]; then
        kill $(cat "$PROJECT_DIR/.gateway.pid") 2>/dev/null || true
        rm "$PROJECT_DIR/.gateway.pid"
    fi
    
    # Kill any remaining processes
    pkill -f "llama-server.*$LLAMA_PORT" 2>/dev/null || true
    pkill -f "local-models-proxy" 2>/dev/null || true
}

# Show status
show_status() {
    echo ""
    echo "========================================"
    echo "  Local Models Server Status"
    echo "========================================"
    echo ""
    echo "  llama.cpp server:  http://localhost:$LLAMA_PORT"
    echo "  OpenAI gateway:    http://localhost:$GATEWAY_PORT"
    echo ""
    echo "  Model: $(basename "$MODEL_PATH")"
    echo "  GPU layers: $GPU_LAYERS"
    echo "  Context size: $CONTEXT_SIZE"
    echo "  Threads: $THREADS"
    echo ""
    echo "========================================"
    echo "  API Endpoints"
    echo "========================================"
    echo ""
    echo "  POST /v1/chat/completions  - Chat completions"
    echo "  POST /v1/completions       - Text completions"
    echo "  POST /v1/embeddings        - Embeddings"
    echo "  GET  /v1/models            - List models"
    echo "  GET  /health               - Health check"
    echo ""
    echo "========================================"
    echo "  Example Usage"
    echo "========================================"
    echo ""
    echo "  curl http://localhost:$GATEWAY_PORT/v1/chat/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{"
    echo '      "model": "phi-2",'
    echo '      "messages": [{"role": "user", "content": "Hello!"}]'
    echo "    }'"
    echo ""
    echo "  Press Ctrl+C to stop servers"
    echo ""
}

# Cleanup on exit
cleanup() {
    echo ""
    print_status "Shutting down..."
    stop_servers
    exit 0
}

trap cleanup SIGINT SIGTERM

# Main
case "${1:-start}" in
    start)
        check_model
        check_llama_server
        check_gateway
        stop_servers
        start_llama_server
        start_gateway
        show_status
        
        # Keep running
        wait
        ;;
        
    stop)
        stop_servers
        print_status "Servers stopped"
        ;;
        
    status)
        if curl -s "http://localhost:$GATEWAY_PORT/health" > /dev/null 2>&1; then
            print_status "Gateway is running"
        else
            print_warning "Gateway is not running"
        fi
        
        if curl -s "http://localhost:$LLAMA_PORT/health" > /dev/null 2>&1; then
            print_status "llama.cpp server is running"
        else
            print_warning "llama.cpp server is not running"
        fi
        ;;
        
    restart)
        stop_servers
        sleep 1
        $0 start
        ;;
        
    *)
        echo "Usage: $0 {start|stop|status|restart}"
        echo ""
        echo "Environment Variables:"
        echo "  MODEL_PATH     Path to GGUF model file"
        echo "  LLAMA_PORT     llama.cpp server port (default: 3000)"
        echo "  GATEWAY_PORT   OpenAI gateway port (default: 8080)"
        echo "  GPU_LAYERS     Number of layers to offload to GPU (default: 99)"
        echo "  CONTEXT_SIZE   Context window size (default: 4096)"
        echo "  THREADS        Number of threads (default: auto)"
        exit 1
        ;;
esac