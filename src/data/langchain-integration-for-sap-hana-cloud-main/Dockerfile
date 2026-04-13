# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
#
# LangChain HANA Integration MCP Server
#
# Build:
#   docker build -t langchain-hana-mcp:1.0.0 .
# Run:
#   docker run -p 9140:9140 langchain-hana-mcp:1.0.0

FROM python:3.11-slim

LABEL org.opencontainers.image.title="langchain-hana-mcp"
LABEL org.opencontainers.image.description="LangChain + HANA Cloud MCP server"
LABEL org.opencontainers.image.vendor="SAP SE"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -u 1000 -g nogroup mcp

WORKDIR /app

# The MCP server is stdlib-first; optional integrations are imported lazily.
COPY mcp_server/ ./mcp_server/

RUN chown -R mcp:nogroup /app

ENV PORT=9140
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

EXPOSE 9140

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f "http://localhost:${PORT}/health" || exit 1

USER mcp

CMD ["python", "mcp_server/server.py"]
