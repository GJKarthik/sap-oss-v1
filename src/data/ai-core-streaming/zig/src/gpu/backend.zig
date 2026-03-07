//! GPU Backend for AI Core Streaming
//!
//! Union-based polymorphism for selecting between CUDA, Metal, and
//! CPU-only backends at runtime. Matches privatellm backend pattern.
//!
//! The actual CUDA and Metal backends are in their respective modules;
//! this module provides the selection logic and unified capability reporting.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.gpu_backend);

// ============================================================================
// Backend Types
// ============================================================================

pub const BackendType = enum {
    cuda,
    metal,
    cpu_only,
};

pub const BackendCapabilities = struct {
    name: []const u8,
    gpu_available: bool,
    backend_type: BackendType,
    device_name: []const u8,
    supports_f16: bool,
    supports_int8: bool,
};

// ============================================================================
// GPU Backend
// ============================================================================

pub const GpuBackend = struct {
    allocator: std.mem.Allocator,
    active_backend: BackendType,
    device_name: []const u8,
    gpu_available: bool,

    pub fn init(allocator: std.mem.Allocator) GpuBackend {
        // Detect best available backend at compile time
        const backend_type: BackendType = blk: {
            if (comptime builtin.os.tag == .linux) break :blk .cuda;
            if (comptime builtin.os.tag == .macos) break :blk .metal;
            break :blk .cpu_only;
        };

        const device_name: []const u8 = switch (backend_type) {
            .cuda => "NVIDIA CUDA Device",
            .metal => "Apple GPU",
            .cpu_only => "CPU fallback",
        };

        log.info("GPU backend selected: {s} (device: {s})", .{ @tagName(backend_type), device_name });

        return .{
            .allocator = allocator,
            .active_backend = backend_type,
            .device_name = device_name,
            .gpu_available = false, // honest: set true only when real GPU init succeeds
        };
    }

    pub fn deinit(self: *GpuBackend) void {
        _ = self;
    }

    pub fn capabilities(self: *const GpuBackend) BackendCapabilities {
        return .{
            .name = @tagName(self.active_backend),
            .gpu_available = self.gpu_available,
            .backend_type = self.active_backend,
            .device_name = self.device_name,
            .supports_f16 = self.active_backend != .cpu_only,
            .supports_int8 = self.active_backend == .cuda,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GpuBackend init and deinit" {
    var backend = GpuBackend.init(std.testing.allocator);
    defer backend.deinit();
    // In test mode, GPU should not be available (honest flag)
    try std.testing.expect(!backend.gpu_available);
}

test "GpuBackend capabilities" {
    var backend = GpuBackend.init(std.testing.allocator);
    const caps = backend.capabilities();
    try std.testing.expect(!caps.gpu_available);
    try std.testing.expectEqualStrings(backend.device_name, caps.device_name);
}

test "BackendType enum values" {
    try std.testing.expectEqual(@as(usize, 3), std.meta.fields(BackendType).len);
}

