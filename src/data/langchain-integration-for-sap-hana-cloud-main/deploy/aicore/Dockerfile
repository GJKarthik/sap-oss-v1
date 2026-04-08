# LangChain HANA - OpenAI-Compatible Vector Service
# KServe InferenceService for SAP BTP AI Core
#
# Exposes:
#   - /v1/embeddings
#   - /v1/search (similarity search)
#   - /health

FROM python:3.11-slim

LABEL org.opencontainers.image.title="LangChain HANA Vector Service"
LABEL org.opencontainers.image.description="OpenAI-compatible embeddings and vector search with HANA Cloud"
LABEL org.opencontainers.image.vendor="SAP"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r aicore && useradd -r -g aicore aicore

WORKDIR /app

# Project files for pip install
COPY pyproject.toml README.md ./
COPY langchain_hana/ ./langchain_hana/

# Install project
RUN pip install --no-cache-dir .

# Install additional dependencies for OpenAI server
RUN pip install --no-cache-dir \
    fastapi>=0.109.0 \
    uvicorn[standard]>=0.27.0 \
    openai>=1.10.0

# Server source
COPY deploy/aicore/server.py ./server.py

RUN chown -R aicore:aicore /app

USER aicore

ENV PORT=8080
ENV PYTHONUNBUFFERED=1

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["python", "-m", "uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080"]
