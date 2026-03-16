//! GPU Kernels Stub — used when -Dgpu=false (the default).
//! Provides no-op / error-returning versions of all gpu_kernels exports
//! so the main binary compiles without CUDA headers.

const std = @import("std");

pub fn generateEmbedding(allocator: std.mem.Allocator, text: []const u8) ![]f32 {
    _ = text;
    _ = allocator;
    return error.GpuNotEnabled;
}
