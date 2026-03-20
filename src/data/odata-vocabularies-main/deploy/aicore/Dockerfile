# OData Vocabularies - OpenAI-Compatible Vocabulary Assistant
# KServe InferenceService for SAP BTP AI Core
#
# Exposes:
#   - /v1/chat/completions (vocabulary Q&A)
#   - /health

FROM python:3.11-slim

LABEL org.opencontainers.image.title="OData Vocabularies Assistant"
LABEL org.opencontainers.image.description="OpenAI-compatible chat for OData annotation guidance"
LABEL org.opencontainers.image.vendor="SAP"
LABEL org.opencontainers.image.version="1.0.0"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r aicore && useradd -r -g aicore aicore

WORKDIR /app

# Install dependencies
RUN pip install --no-cache-dir \
    fastapi>=0.109.0 \
    uvicorn[standard]>=0.27.0 \
    openai>=1.10.0 \
    pydantic>=2.5.0

# Copy vocabularies
COPY vocabularies/ ./vocabularies/

# Copy MCP server
COPY mcp_server/ ./mcp_server/

# Copy OpenAI server
COPY deploy/aicore/server.py ./server.py

RUN chown -R aicore:aicore /app

USER aicore

ENV PORT=8080
ENV PYTHONUNBUFFERED=1

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["python", "-m", "uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080"]