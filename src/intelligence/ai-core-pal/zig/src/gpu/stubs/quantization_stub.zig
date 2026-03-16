//! Quantization Stub — used when -Dgpu=false (the default).
//! Provides no-op / error-returning versions of all quantization exports.

const std = @import("std");

pub const QuantConfig = struct {
    bits: u8 = 8,
    group_size: u32 = 128,
};

pub fn quantizeWeights(
    allocator: std.mem.Allocator,
    weights: []const f32,
    config: QuantConfig,
) error{GpuNotEnabled}![]u8 {
    _ = allocator;
    _ = weights;
    _ = config;
    return error.GpuNotEnabled;
}
