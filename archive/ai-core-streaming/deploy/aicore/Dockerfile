# SAP AI Core Streaming - OpenAI-Compatible Server
# KServe InferenceService for SAP BTP AI Core deployment
#
# Exposes:
#   - /v1/chat/completions
#   - /v1/completions  
#   - /v1/embeddings
#   - /v1/models
#   - /health (KServe health check)

FROM python:3.11-slim

LABEL org.opencontainers.image.title="SAP AI Core Streaming - OpenAI API"
LABEL org.opencontainers.image.description="OpenAI-compatible API server with smart routing for SAP AI Core"
LABEL org.opencontainers.image.vendor="SAP"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r aicore && useradd -r -g aicore aicore

# Set working directory
WORKDIR /app

# Copy requirements first for better caching
COPY requirements-openai.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy OpenAI server module
COPY openai/ ./openai/

# Copy Mangle governance rules
COPY mangle/ ./mangle/

# Copy mesh routing configuration
COPY mesh/ ./mesh/

# Set ownership
RUN chown -R aicore:aicore /app

# Switch to non-root user
USER aicore

# Environment variables
ENV PORT=8080
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# AI Core environment (set at runtime)
# ENV AI_CORE_URL=https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com
# ENV AI_CORE_CLIENT_ID=<your-client-id>
# ENV AI_CORE_CLIENT_SECRET=<your-client-secret>
# ENV AI_CORE_RESOURCE_GROUP=default

# Expose port
EXPOSE 8080

# Health check (KServe compatible)
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Run the OpenAI-compatible server
CMD ["python", "-m", "uvicorn", "openai.server:app", "--host", "0.0.0.0", "--port", "8080"]