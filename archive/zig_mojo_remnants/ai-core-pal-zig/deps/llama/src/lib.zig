//! Llama.zig - A Zig implementation of llama.cpp
//!
//! This library provides efficient LLM inference with:
//! - Native ARM64/x86_64 support
//! - SIMD-optimized compute kernels
//! - Metal/CUDA/Vulkan backends
//! - OpenAI-compatible API server
//!
//! ## Mangle-Driven Design
//!
//! The library uses Mangle (.mg) files for declarative specifications:
//! - `mangle/tensor_types.mg` - Data type definitions
//! - `mangle/gguf_format.mg` - GGUF file format spec
//! - `mangle/model_arch.mg` - Model architectures
//! - `mangle/codegen.mg` - Zig code generation rules
//!
//! This allows:
//! - Single source of truth for specifications
//! - Easy addition of new model architectures
//! - Automatic code generation at build time

const std = @import("std");

// Core modules
pub const tensor = @import("tensor.zig");
pub const kernels = @import("kernels.zig");
pub const mangle = @import("mangle_client.zig");
pub const model = @import("model.zig");
pub const sampler = @import("sampler.zig");

// Re-export main types
pub const Tensor = tensor.Tensor;
pub const Shape = tensor.Shape;
pub const DataType = tensor.DataType;

// Re-export kernel functions
pub const vecAdd = kernels.vecAdd;
pub const vecMul = kernels.vecMul;
pub const vecDot = kernels.vecDot;
pub const vecSilu = kernels.vecSilu;
pub const vecGelu = kernels.vecGelu;
pub const softmax = kernels.softmax;
pub const rmsNorm = kernels.rmsNorm;
pub const layerNorm = kernels.layerNorm;
pub const matmul = kernels.matmul;
pub const matvec = kernels.matvec;
pub const rope = kernels.rope;
pub const swiglu = kernels.swiglu;

// Re-export model types
pub const Model = model.Model;
pub const ModelConfig = model.ModelConfig;
pub const ModelWeights = model.ModelWeights;
pub const LayerWeights = model.LayerWeights;
pub const KVCache = model.KVCache;
pub const Architecture = model.Architecture;

// Re-export sampler types
pub const Sampler = sampler.Sampler;
pub const SamplerConfig = sampler.SamplerConfig;
pub const sampleGreedy = sampler.sampleGreedy;

// Mangle client for runtime queries
pub const MangleClient = mangle.Client;
pub const MangleConfig = mangle.Config;

// Re-export Mangle data structures
pub const DataTypeInfo = mangle.DataTypeInfo;
pub const ArchInfo = mangle.ArchInfo;
pub const ModelConfigInfo = mangle.ModelConfigInfo;
pub const TensorPatternInfo = mangle.TensorPatternInfo;

// Version info
pub const version = "0.1.0";
pub const gguf_version = 3;

/// Initialize a Mangle client with default configuration
pub fn initMangleClient(allocator: std.mem.Allocator) MangleClient {
    return MangleClient.init(allocator, .{
        .use_embedded = true,
    });
}

/// Get model configuration by name (convenience function)
pub fn getModelConfig(name: []const u8) ?ModelConfigInfo {
    var client = MangleClient.init(undefined, .{ .use_embedded = true });
    return client.getModelConfig(name);
}

/// Get data type info by name (convenience function)
pub fn getDataTypeInfo(name: []const u8) ?DataTypeInfo {
    var client = MangleClient.init(undefined, .{ .use_embedded = true });
    return client.getDataType(name);
}

test {
    std.testing.refAllDecls(@This());
}

test "library basic functionality" {
    const allocator = std.testing.allocator;

    // Test tensor creation
    var t = try Tensor.init(allocator, Shape.init2D(32, 64), .F32, "test_tensor");
    defer t.deinit();

    try std.testing.expectEqual(@as(usize, 32 * 64), t.numel());

    // Test Mangle client
    const phi2_config = getModelConfig("phi-2");
    try std.testing.expect(phi2_config != null);
    try std.testing.expectEqual(@as(u32, 2560), phi2_config.?.dim);

    // Test data type info
    const q4k = getDataTypeInfo("Q4_K");
    try std.testing.expect(q4k != null);
    try std.testing.expectEqual(@as(usize, 144), q4k.?.block_size);
}
