# AI Core Private LLM — Pure Zig Docker Build
# No nvcc or CUDA toolkit required at build time
# CUDA kernels compiled to PTX via Zig's LLVM nvptx64 backend
# Supports: T4 (SM75), A100 (SM80), L40S (SM89), H100 (SM90)

# =============================================================================
# Stage 1: Zig compilation (Pure Zig - no C++ dependencies)
# =============================================================================
FROM nvidia/cuda:12.4.0-runtime-ubuntu22.04 AS zig-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.1 with NVPTX backend support
ARG ZIG_VERSION=0.15.1
RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" | \
    tar -xJ -C /opt && \
    mv /opt/zig-x86_64-linux-${ZIG_VERSION} /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /build
COPY zig/ ./zig/

# Build pure Zig gateway (includes CUDA kernels compiled to PTX via LLVM)
# No nvcc required - Zig's LLVM backend targets nvptx64-nvidia-cuda
# GPU_ARCH: sm_75=T4, sm_89=L4, sm_90=H100 (default: sm_75 for Brev T4)
ARG GPU_ARCH=sm_75
RUN cd zig && zig build -Doptimize=ReleaseFast -Dgpu=true -Dgpu_arch=${GPU_ARCH}

# =============================================================================
# Stage 2: Production runtime (NVIDIA GPU optimized)
# =============================================================================
FROM nvidia/cuda:12.4.0-runtime-ubuntu22.04 AS runtime

# OCI / NVIDIA container labels
LABEL org.opencontainers.image.title="SAP AI Core Private LLM"
LABEL org.opencontainers.image.version="2.1.0"
LABEL org.opencontainers.image.description="Pure Zig LLM inference with Flash Attention"
LABEL org.opencontainers.image.vendor="SAP"
LABEL com.nvidia.volumes.needed="nvidia_driver"
LABEL com.nvidia.cuda.version="12.4"

# Architecture labels
LABEL ai.core.kernels="pure-zig-nvptx64"
LABEL ai.core.flash-attention="1.x"
LABEL ai.core.quantization="Q4_K_M,Q8_0"

# Install minimal runtime deps (curl for healthcheck)
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -r -u 1001 -g root -s /usr/sbin/nologin llm

WORKDIR /app

# Copy Zig gateway binary (includes all GPU kernels)
COPY --from=zig-builder /build/zig/zig-out/bin/ /app/bin/

# Copy entrypoint script
COPY docker-entrypoint.sh /app/

# Model cache directory (mount volume for persistent models)
RUN mkdir -p /app/models /app/cache && \
    chown -R llm:root /app && \
    chmod +x /app/docker-entrypoint.sh /app/bin/*

# Switch to non-root user
USER 1001

# Environment configuration
ENV PORT=8080 \
    METRICS_PORT=9090 \
    METRICS_BIND=127.0.0.1 \
    MODEL_PATH=/app/models \
    CACHE_DIR=/app/cache \
    CUDA_VISIBLE_DEVICES=all \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    FLASH_ATTENTION_ENABLED=true \
    KERNEL_BACKEND=pure-zig

EXPOSE 8080 9090

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
    CMD curl -sf http://localhost:${PORT}/health || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
