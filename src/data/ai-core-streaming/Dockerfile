# BDC Pulsar Streaming - Multi-stage Docker build
# Full Pulsar protocol implementation with SAP HANA storage

# =============================================================================
# Stage 1: Build Zig binaries
# =============================================================================
FROM debian:bookworm-slim AS zig-builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    xz-utils \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig directly from ziglang.org
ARG ZIG_VERSION=0.14.0
RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" | \
    tar -xJ -C /opt && \
    mv /opt/zig-linux-x86_64-${ZIG_VERSION} /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /build

# Copy Zig source
COPY zig/ ./zig/

# Build release binaries
RUN cd zig && zig build -Doptimize=ReleaseFast

# =============================================================================
# Stage 2: Runtime image
# =============================================================================
FROM debian:bookworm-slim AS runtime

# Labels
LABEL org.opencontainers.image.title="BDC Pulsar Streaming"
LABEL org.opencontainers.image.description="Full Pulsar protocol with SAP HANA storage"
LABEL org.opencontainers.image.vendor="SAP"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    libc6 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r pulsar && useradd -r -g pulsar pulsar

# Create directories
RUN mkdir -p /opt/pulsar/bin \
    /opt/pulsar/conf \
    /opt/pulsar/data \
    /opt/pulsar/logs \
    && chown -R pulsar:pulsar /opt/pulsar

WORKDIR /opt/pulsar

# Copy Zig binaries from builder
COPY --from=zig-builder /build/zig/zig-out/bin/* ./bin/

# Copy configuration files
COPY conf/ ./conf/

# Set ownership
RUN chown -R pulsar:pulsar /opt/pulsar

# Switch to non-root user
USER pulsar

# Environment variables
ENV PULSAR_HOME=/opt/pulsar
ENV PULSAR_CONF_DIR=/opt/pulsar/conf
ENV PULSAR_DATA_DIR=/opt/pulsar/data
ENV PULSAR_LOG_DIR=/opt/pulsar/logs
ENV PATH="/opt/pulsar/bin:${PATH}"

# Expose ports
EXPOSE 6650 6651 8080 8443

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Default command
CMD ["bdc-aiprompt-streaming"]