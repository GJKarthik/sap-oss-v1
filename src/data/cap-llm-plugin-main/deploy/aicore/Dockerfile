# CAP LLM Plugin - OpenAI-Compatible RAG Server
# KServe InferenceService for SAP BTP AI Core deployment
#
# Exposes:
#   - /v1/chat/completions (with RAG context injection)
#   - /v1/embeddings
#   - /v1/models
#   - /health

FROM node:20-slim

LABEL org.opencontainers.image.title="CAP LLM Plugin - RAG Server"
LABEL org.opencontainers.image.description="OpenAI-compatible RAG service with HANA Vector"
LABEL org.opencontainers.image.vendor="SAP"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r aicore && useradd -r -g aicore aicore

WORKDIR /app

# Copy package files
COPY package.json package-lock.json ./

# Install dependencies
RUN npm ci --only=production

# Copy source
COPY lib/ ./lib/
COPY src/ ./src/
COPY srv/ ./srv/
COPY mcp-server/ ./mcp-server/
COPY mangle/ ./mangle/

# Build if needed
RUN npm run build --if-present

# Set ownership
RUN chown -R aicore:aicore /app

USER aicore

ENV PORT=8080
ENV NODE_ENV=production

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["node", "mcp-server/openai-server.js"]