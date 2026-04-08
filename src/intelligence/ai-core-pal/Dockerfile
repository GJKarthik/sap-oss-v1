# MCP Mesh Gateway Service - SAP AI Core Ready
FROM ubuntu:22.04 AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget xz-utils build-essential ca-certificates && \
    wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz && \
    tar -xf zig-linux-x86_64-0.14.0.tar.xz && \
    mv zig-linux-x86_64-0.14.0 /opt/zig && \
    rm -rf zig-linux-x86_64-0.14.0.tar.xz /var/lib/apt/lists/*
ENV PATH="/opt/zig:${PATH}"
WORKDIR /build
ARG ZIG_TARGET=native
COPY zig/ ./zig/
COPY mangle/ ./mangle/
WORKDIR /build/zig
RUN zig build -Doptimize=ReleaseFast -Dtarget=${ZIG_TARGET}

FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN useradd --no-create-home --uid 10001 appuser
WORKDIR /app
COPY --from=builder /build/zig/zig-out/bin/mcp-mesh-gateway /app/mcp-mesh-gateway
COPY --from=builder /build/mangle/ /app/mangle/
RUN chown -R appuser:appuser /app
USER appuser
ENV PORT=8080 CUDA_VISIBLE_DEVICES=0 NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1
EXPOSE 8080 9090
CMD ["/app/mcp-mesh-gateway"]