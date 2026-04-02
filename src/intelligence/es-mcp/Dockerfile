# ES MCP Server — Kyma / sap-ai-services edition
#
# Minimal single-stage image; no build toolchain needed because all
# ES + AI Core communication uses Python stdlib urllib.
#
# Build:
#   docker build -t es-mcp:latest .
#
# Run locally (dev, auth disabled):
#   docker run --rm -p 9120:9120 \
#     -e XSUAA_VERIFY_TOKEN=false \
#     -e ES_HOST=http://localhost:9200 \
#     -e ES_PASSWORD=changeme \
#     es-mcp:latest

FROM python:3.11-slim

WORKDIR /app

# Install OS-level runtime deps (curl for HEALTHCHECK, ca-certificates for
# TLS connections to AI Core / XSUAA over HTTPS).
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy and install Python requirements first (layer caching).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy server source.
COPY mcp_server/ ./mcp_server/

# Non-root user for Kyma / distroless best-practice.
RUN useradd --no-create-home --shell /bin/false appuser
USER appuser

# Environment defaults (all overridable at runtime / via ConfigMap / Secret).
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=9120 \
    # ES — defaults to the in-cluster Kyma service DNS name
    ES_HOST="http://elasticsearch-master.sap-ai-services.svc.cluster.local:9200" \
    ES_USERNAME="elastic" \
    ES_PASSWORD="" \
    ES_API_KEY="" \
    # AI Core
    AICORE_CLIENT_ID="" \
    AICORE_CLIENT_SECRET="" \
    AICORE_AUTH_URL="" \
    AICORE_BASE_URL="" \
    AICORE_RESOURCE_GROUP="default" \
    AICORE_EMBEDDING_DEPLOYMENT_ID="" \
    # Auth
    XSUAA_VERIFY_TOKEN="true" \
    XSUAA_PUBLIC_KEY="" \
    MCP_API_KEY="" \
    # Limits
    MCP_MAX_REQUEST_BYTES="1048576" \
    MCP_MAX_SEARCH_SIZE="100" \
    MCP_MAX_KNN_K="100"

EXPOSE 9120

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

CMD ["python", "-m", "mcp_server.server"]