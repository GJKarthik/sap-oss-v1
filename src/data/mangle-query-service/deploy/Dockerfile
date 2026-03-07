# Dockerfile for Mangle Query Service with HANA Integration
#
# Build:
#   docker build -t mangle-query-service -f deploy/Dockerfile .
#
# Run:
#   docker run -p 8080:8080 -p 9090:9090 -p 9150:9150 \
#     -e HANA_HOST=... -e HANA_USER=... -e HANA_PASSWORD=... \
#     mangle-query-service

FROM python:3.11-slim as builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir --user -r requirements.txt

# Install additional packages for HANA integration
RUN pip install --no-cache-dir --user \
    langchain-hana \
    hdbcli \
    opentelemetry-api \
    opentelemetry-sdk \
    opentelemetry-exporter-otlp \
    prometheus-client \
    httpx

# Production image
FROM python:3.11-slim

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy Python packages from builder
COPY --from=builder /root/.local /root/.local

# Add local bin to PATH
ENV PATH=/root/.local/bin:$PATH

# Copy application code
COPY . .

# Create directories for data persistence
RUN mkdir -p /app/data/models /app/data/cache /app/logs

# Environment variables with defaults
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080 \
    MCP_PORT=9150 \
    METRICS_PORT=9090 \
    LOG_LEVEL=INFO \
    # HANA Connection (override at runtime)
    HANA_HOST="" \
    HANA_PORT=443 \
    HANA_USER="" \
    HANA_PASSWORD="" \
    HANA_ENCRYPT=true \
    # Cache Settings
    HANA_CACHE_MAX_SIZE=10000 \
    HANA_CACHE_TTL_SECONDS=3600 \
    SEMANTIC_SIMILARITY_THRESHOLD=0.92 \
    # Speculative Execution
    SPECULATIVE_PATHS=2 \
    SPECULATION_TIMEOUT_SECONDS=5.0 \
    # Circuit Breaker
    HANA_CB_FAILURE_THRESHOLD=5 \
    HANA_CB_RECOVERY_TIMEOUT=30.0 \
    # Observability
    OTEL_ENABLED=true \
    METRICS_ENABLED=true

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

# Expose ports
EXPOSE ${PORT} ${MCP_PORT} ${METRICS_PORT}

# Run the service
CMD ["python", "-m", "cmd.server.main"]