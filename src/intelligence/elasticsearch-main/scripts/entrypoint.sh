#!/bin/bash
set -e

# Default to MCP server
SERVICE=${SERVICE:-mcp}

case $SERVICE in
    mcp)
        echo "Starting MCP Server on port ${MCP_PORT:-9120}..."
        exec python -m mcp_server.server --port ${MCP_PORT:-9120}
        ;;
    openai)
        echo "Starting OpenAI Server on port ${OPENAI_PORT:-9201}..."
        exec uvicorn sap_openai_server.server:app --host 0.0.0.0 --port ${OPENAI_PORT:-9201}
        ;;
    both)
        echo "Starting MCP Server on port ${MCP_PORT:-9120}..."
        python -m mcp_server.server --port ${MCP_PORT:-9120} &
        
        echo "Starting OpenAI Server on port ${OPENAI_PORT:-9201}..."
        exec uvicorn sap_openai_server.server:app --host 0.0.0.0 --port ${OPENAI_PORT:-9201}
        ;;
    *)
        echo "Unknown service: $SERVICE"
        echo "Valid options: mcp, openai, both"
        exit 1
        ;;
esac