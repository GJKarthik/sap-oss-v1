# SAP AI SDK JS - OpenAI-Compatible Server
# KServe InferenceService for SAP BTP AI Core deployment
#
# Exposes:
#   - /v1/chat/completions
#   - /v1/completions  
#   - /v1/embeddings
#   - /v1/models
#   - /health

FROM node:20-slim

LABEL org.opencontainers.image.title="SAP AI SDK JS - OpenAI Server"
LABEL org.opencontainers.image.description="OpenAI-compatible API proxy for SAP AI Core"
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

# Install pnpm
RUN corepack enable && corepack prepare pnpm@latest --activate

# Copy package files
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/openai-server/package.json ./packages/openai-server/
COPY packages/core/package.json ./packages/core/
COPY packages/foundation-models/package.json ./packages/foundation-models/
COPY packages/ai-api/package.json ./packages/ai-api/
COPY packages/types/package.json ./packages/types/

# Install dependencies
RUN pnpm install --frozen-lockfile --prod

# Copy source code
COPY packages/openai-server/ ./packages/openai-server/
COPY packages/core/ ./packages/core/
COPY packages/foundation-models/ ./packages/foundation-models/
COPY packages/ai-api/ ./packages/ai-api/
COPY packages/types/ ./packages/types/

# Copy Mangle governance rules
COPY mangle/ ./mangle/

# Build TypeScript
RUN pnpm --filter @sap-ai-sdk/openai-server build

# Set ownership
RUN chown -R aicore:aicore /app

# Switch to non-root user
USER aicore

# Environment variables
ENV PORT=8080
ENV NODE_ENV=production

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Run the OpenAI server
CMD ["node", "packages/openai-server/dist/cli.js", "--port", "8080"]