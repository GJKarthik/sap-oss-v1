# OData Vocabularies Universal Dictionary
# Production Dockerfile with multi-stage build

# Stage 1: Builder
FROM python:3.11-slim as builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt* pyproject.toml* ./

# Create virtual environment and install dependencies
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    if [ -f requirements.txt ]; then pip install --no-cache-dir -r requirements.txt; fi && \
    pip install --no-cache-dir aiohttp pytest


# Stage 2: Production
FROM python:3.11-slim as production

# Set labels
LABEL org.opencontainers.image.title="OData Vocabularies Universal Dictionary"
LABEL org.opencontainers.image.description="MCP Server for SAP OData vocabulary operations"
LABEL org.opencontainers.image.version="3.0.0"
LABEL org.opencontainers.image.vendor="SAP"

# Create non-root user for security
RUN groupadd -r odata && useradd -r -g odata odata

WORKDIR /app

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy application code
COPY --chown=odata:odata . .

# Create necessary directories
RUN mkdir -p _audit_logs _embeddings && \
    chown -R odata:odata _audit_logs _embeddings

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MCP_PORT=9150 \
    MCP_HOST=0.0.0.0 \
    LOG_LEVEL=INFO

# Switch to non-root user
USER odata

# Expose MCP server port
EXPOSE 9150

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:9150/health')" || exit 1

# Default command
CMD ["python", "-m", "mcp_server.server"]


# Stage 3: Development
FROM production as development

USER root

# Install development dependencies
RUN pip install --no-cache-dir \
    pytest \
    pytest-cov \
    pytest-asyncio \
    ruff \
    mypy \
    black

USER odata

# Override command for development
CMD ["python", "-m", "mcp_server.server", "--debug"]