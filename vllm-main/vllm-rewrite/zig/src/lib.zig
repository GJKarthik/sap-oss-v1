//! vLLM Zig Library - FFI Exports
//!
//! This module exports C-compatible functions for interoperability with:
//! - Mojo model layer
//! - Python bindings (optional)
//! - CUDA kernels

const std = @import("std");

// Re-export public modules
pub const engine = @import("engine/engine_core.zig");
pub const types = @import("engine/types.zig");
pub const config = @import("utils/config.zig");
pub const logging = @import("utils/logging.zig");

// Type aliases for convenience
pub const EngineCore = engine.EngineCore;
pub const EngineState = engine.EngineState;
pub const EngineStats = engine.EngineStats;
pub const Request = types.Request;
pub const RequestState = types.RequestState;
pub const SamplingParams = types.SamplingParams;
pub const RequestOutput = types.RequestOutput;
pub const EngineConfig = config.EngineConfig;

/// Global allocator for C interop
var global_allocator: std.mem.Allocator = std.heap.c_allocator;

/// Global engine instance (for C API)
var global_engine: ?*EngineCore = null;

// ============================================
// C-Compatible FFI Exports
// ============================================

/// Error codes for C API
pub const VllmError = enum(c_int) {
    success = 0,
    invalid_argument = -1,
    out_of_memory = -2,
    engine_not_initialized = -3,
    engine_error = -4,
    request_not_found = -5,
    invalid_config = -6,
    model_load_failed = -7,
};

/// Opaque handle types for C
pub const VllmEngine = opaque {};
pub const VllmRequest = opaque {};

/// Initialize the vLLM engine
export fn vllm_init(model_path: [*:0]const u8, tensor_parallel_size: c_int) VllmError {
    const path_slice = std.mem.span(model_path);

    const engine_config = EngineConfig{
        .model_path = path_slice,
        .tensor_parallel_size = if (tensor_parallel_size > 0) @intCast(tensor_parallel_size) else 1,
    };

    global_engine = EngineCore.init(global_allocator, engine_config) catch |err| {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .engine_error,
        };
    };

    return .success;
}

/// Shutdown the vLLM engine
export fn vllm_shutdown() VllmError {
    if (global_engine) |eng| {
        eng.deinit();
        global_engine = null;
        return .success;
    }
    return .engine_not_initialized;
}

/// Add a request to the engine
export fn vllm_add_request(
    prompt_tokens: [*]const u32,
    num_tokens: usize,
    max_tokens: c_int,
    temperature: f32,
    top_p: f32,
    request_id_out: [*]u8,
) VllmError {
    const eng = global_engine orelse return .engine_not_initialized;

    const params = SamplingParams{
        .max_tokens = if (max_tokens > 0) @intCast(max_tokens) else 256,
        .temperature = temperature,
        .top_p = top_p,
    };

    const token_slice = prompt_tokens[0..num_tokens];

    const request_id = eng.addRequest(null, token_slice, params) catch |err| {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .engine_error,
        };
    };

    // Copy request ID to output buffer
    @memcpy(request_id_out[0..36], &request_id);

    return .success;
}

/// Abort a request
export fn vllm_abort_request(request_id: [*]const u8) VllmError {
    const eng = global_engine orelse return .engine_not_initialized;

    var id: types.RequestId = undefined;
    @memcpy(&id, request_id[0..36]);

    eng.abortRequest(id) catch |err| {
        return switch (err) {
            error.RequestNotFound => .request_not_found,
            else => .engine_error,
        };
    };

    return .success;
}

/// Execute one step of the engine
export fn vllm_step() VllmError {
    const eng = global_engine orelse return .engine_not_initialized;

    _ = eng.step() catch {
        return .engine_error;
    };

    return .success;
}

/// Get the number of unfinished requests
export fn vllm_get_num_unfinished() c_int {
    const eng = global_engine orelse return -1;
    return @intCast(eng.getNumUnfinishedRequests());
}

/// Check if engine has unfinished requests
export fn vllm_has_unfinished() c_int {
    const eng = global_engine orelse return -1;
    return if (eng.hasUnfinishedRequests()) 1 else 0;
}

/// Get engine state
export fn vllm_get_state() c_int {
    const eng = global_engine orelse return -1;
    return @intCast(@intFromEnum(eng.getState()));
}

/// Get engine statistics
export fn vllm_get_stats(
    total_requests: *u64,
    total_tokens: *u64,
    running_requests: *u32,
    pending_requests: *u32,
) VllmError {
    const eng = global_engine orelse return .engine_not_initialized;

    const stats = eng.getStats();
    total_requests.* = stats.total_requests;
    total_tokens.* = stats.total_tokens;
    running_requests.* = stats.running_requests;
    pending_requests.* = stats.pending_requests;

    return .success;
}

// ============================================
// Mojo FFI Interface
// ============================================

/// Callback function type for model forward pass
pub const ModelForwardFn = *const fn (
    input_ids: [*]const u32,
    positions: [*]const u32,
    batch_size: usize,
    seq_len: usize,
    kv_cache: *anyopaque,
    output_logits: [*]f16,
) void;

/// Register the Mojo model forward function
var mojo_forward_fn: ?ModelForwardFn = null;

export fn vllm_register_model_forward(forward_fn: ModelForwardFn) void {
    mojo_forward_fn = forward_fn;
}

/// Call the registered Mojo forward function
pub fn callMojoForward(
    input_ids: []const u32,
    positions: []const u32,
    batch_size: usize,
    seq_len: usize,
    kv_cache: *anyopaque,
    output_logits: []f16,
) bool {
    if (mojo_forward_fn) |forward| {
        forward(
            input_ids.ptr,
            positions.ptr,
            batch_size,
            seq_len,
            kv_cache,
            output_logits.ptr,
        );
        return true;
    }
    return false;
}

// ============================================
// Version Information
// ============================================

/// Get library version
export fn vllm_version() [*:0]const u8 {
    return "0.1.0";
}

/// Get Zig version
export fn vllm_zig_version() [*:0]const u8 {
    return @import("builtin").zig_version_string;
}

// ============================================
// Tests
// ============================================

test "FFI error codes" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(VllmError.success));
    try std.testing.expectEqual(@as(c_int, -1), @intFromEnum(VllmError.invalid_argument));
}

test "version strings" {
    const ver = vllm_version();
    try std.testing.expect(ver[0] == '0');
}