#!/bin/bash
set -e

# Default to MCP server
SERVICE=${SERVICE:-mcp}
MCP_PORT=${MCP_PORT:-9120}
OPENAI_PORT=${OPENAI_PORT:-9201}
QUERY_PORT=${QUERY_PORT:-8080}
GRPC_PORT=${GRPC_PORT:-50051}
MQS_RULES_DIR=${MQS_RULES_DIR:-/app/rules}

# ---------------------------------------------------------------------------
# Helper: start the Go Mangle gRPC engine in the background if the binary
# is present.  Failures are non-fatal; the Python fallback takes over.
# ---------------------------------------------------------------------------
start_grpc_engine() {
    if command -v mangle-engine > /dev/null 2>&1; then
        echo "Starting Go Mangle gRPC engine on port ${GRPC_PORT}..."
        MQS_RULES_DIR="${MQS_RULES_DIR}" GRPC_PORT="${GRPC_PORT}" mangle-engine &
        GRPC_PID=$!
        echo "Go Mangle engine started (pid=${GRPC_PID})"
    else
        echo "WARNING: mangle-engine binary not found; Python governance fallback will be used."
    fi
}

case $SERVICE in
    mcp)
        start_grpc_engine
        echo "Starting MCP Server on port ${MCP_PORT}..."
        exec python -m mcp_server.server --port ${MCP_PORT}
        ;;
    openai)
        echo "Starting ES OpenAI Server on port ${OPENAI_PORT}..."
        exec uvicorn sap_openai_server.server:app --host 0.0.0.0 --port ${OPENAI_PORT}
        ;;
    query)
        start_grpc_engine
        echo "Starting Mangle Query API on port ${QUERY_PORT}..."
        exec uvicorn cmd.server.main:app --host 0.0.0.0 --port ${QUERY_PORT}
        ;;
    both)
        echo "Starting MCP Server on port ${MCP_PORT}..."
        python -m mcp_server.server --port ${MCP_PORT} &
        echo "Starting ES OpenAI Server on port ${OPENAI_PORT}..."
        exec uvicorn sap_openai_server.server:app --host 0.0.0.0 --port ${OPENAI_PORT}
        ;;
    all)
        start_grpc_engine
        echo "Starting MCP Server on port ${MCP_PORT}..."
        python -m mcp_server.server --port ${MCP_PORT} &
        echo "Starting ES OpenAI Server on port ${OPENAI_PORT}..."
        uvicorn sap_openai_server.server:app --host 0.0.0.0 --port ${OPENAI_PORT} &
        echo "Starting Mangle Query API on port ${QUERY_PORT}..."
        exec uvicorn cmd.server.main:app --host 0.0.0.0 --port ${QUERY_PORT}
        ;;
    *)
        echo "Unknown service: $SERVICE"
        echo "Valid options: mcp, openai, query, both, all"
        exit 1
        ;;
esac