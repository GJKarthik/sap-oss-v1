# BDC Pulsar Streaming - Multi-stage Docker build
# Full Pulsar protocol implementation with SAP HANA storage
#
# Build arguments
#   ZIG_VERSION   — Zig toolchain version (default: 0.14.0)
#   MOJO_VERSION  — Optional Mojo version for SIMD-accelerated FFI path.
#                   Leave unset (default) to use the pure-Zig CPU fallback.
#                   Example: --build-arg MOJO_VERSION=24.5.0

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
# Stage 2 (optional): Build Mojo FFI shared library for SIMD stream processing
# Only executed when MOJO_VERSION is provided; otherwise the pure-Zig CPU
# fallback inside the broker is used automatically.
# =============================================================================
FROM debian:bookworm-slim AS mojo-builder
ARG MOJO_VERSION=""

# Install Mojo only when a version was requested; produce an empty marker
# directory in all cases so the COPY in the runtime stage always succeeds.
RUN mkdir -p /mojo-artifacts
RUN if [ -n "$MOJO_VERSION" ]; then \
      apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && \
      rm -rf /var/lib/apt/lists/* && \
      curl -ssL https://magic.modular.com/install.sh | bash -s -- --no-interactive && \
      /root/.modular/bin/magic global install "mojo==${MOJO_VERSION}" && \
      echo "Mojo ${MOJO_VERSION} installed" ; \
    else \
      echo "MOJO_VERSION not set — skipping Mojo build, broker will use pure-Zig CPU path." ; \
    fi

# Build the shared library when Mojo is present
COPY ffi/ /build/ffi/
RUN if [ -n "$MOJO_VERSION" ] && [ -f /build/ffi/mojo_streaming.mojo ]; then \
      /root/.modular/bin/mojo build /build/ffi/mojo_streaming.mojo \
        --emit-shared-lib -o /mojo-artifacts/libmojo_streaming.so ; \
    fi

# =============================================================================
# Stage 3: Runtime image
# =============================================================================
FROM debian:bookworm-slim AS runtime

# Labels
LABEL org.opencontainers.image.title="BDC Pulsar Streaming"
LABEL org.opencontainers.image.description="Full Pulsar protocol with SAP HANA storage"
LABEL org.opencontainers.image.vendor="SAP"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Install runtime dependencies (including Python for the MCP server)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    libc6 \
    curl \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r pulsar && useradd -r -g pulsar pulsar

# Create directories
RUN mkdir -p /opt/pulsar/bin \
    /opt/pulsar/conf \
    /opt/pulsar/data \
    /opt/pulsar/logs \
    /opt/pulsar/lib \
    /opt/pulsar/mcp_server \
    && chown -R pulsar:pulsar /opt/pulsar

WORKDIR /opt/pulsar

# Copy Zig binaries from builder
COPY --from=zig-builder /build/zig/zig-out/bin/* ./bin/

# Copy Mojo FFI library if it was built (directory will be empty otherwise)
COPY --from=mojo-builder /mojo-artifacts/ ./lib/

# Copy configuration files
COPY conf/ ./conf/

# Copy Python MCP server
COPY mcp_server/ ./mcp_server/
RUN if [ -f ./mcp_server/requirements.txt ]; then \
      pip3 install --no-cache-dir -r ./mcp_server/requirements.txt ; \
    fi

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
# Point the broker's FFI loader at the lib directory.
# When libmojo_streaming.so is absent the broker falls back to the Zig CPU path.
ENV MOJO_LIB_PATH=/opt/pulsar/lib/libmojo_streaming.so

# Expose ports
EXPOSE 6650 6651 8080 8443 9190

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Default command
CMD ["bdc-aiprompt-streaming"]