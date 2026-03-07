//! ANWID GPU Context
//! Abstraction over Metal (macOS) and CUDA (Linux) backends
//! Provides real hardware detection and unified GPU interface

const std = @import("std");
const builtin = @import("builtin");

const metal_bindings = @import("metal_bindings");
const cuda_bindings = @import("cuda_bindings.zig");

const log = std.log.scoped(.gpu);

// ============================================================================
// GPU Backend Detection
// ============================================================================

pub const Backend = enum {
    metal,
    cuda,
    cpu, // Fallback
    
    pub fn detect() Backend {
        if (builtin.os.tag == .macos) {
            // Check if Metal device is available
            if (comptime !builtin.is_test) {
                if (metal_bindings.getDevice()) |_| {
                    return .metal;
                }
            }
            // Fallback to CPU on macOS without Metal
            return .cpu;
        } else if (builtin.os.tag == .linux) {
            // Check if CUDA is available
            if (cuda_bindings.isCudaAvailable()) {
                return .cuda;
            }
            return .cpu;
        }
        return .cpu;
    }
    
    pub fn toString(self: Backend) []const u8 {
        return switch (self) {
            .metal => "Metal",
            .cuda => "CUDA",
            .cpu => "CPU",
        };
    }
};

// ============================================================================
// GPU Device Info (Unified)
// ============================================================================

pub const DeviceInfo = struct {
    name: [256]u8,
    name_len: usize,
    total_memory: usize,
    free_memory: usize,
    compute_units: u32,
    max_threads_per_group: u32,
    
    // Extended info
    backend: Backend,
    architecture: [64]u8,
    architecture_len: usize,
    
    // Metal-specific
    supports_metal3: bool,
    apple_gpu_family: u8,
    has_unified_memory: bool,
    
    // CUDA-specific
    compute_capability_major: c_int,
    compute_capability_minor: c_int,
    multiprocessor_count: c_int,
    warp_size: c_int,
    
    pub fn getName(self: *const DeviceInfo) []const u8 {
        return self.name[0..self.name_len];
    }
    
    pub fn getArchitecture(self: *const DeviceInfo) []const u8 {
        return self.architecture[0..self.architecture_len];
    }
    
    /// Get memory usage as a percentage
    pub fn getMemoryUsagePercent(self: *const DeviceInfo) f32 {
        if (self.total_memory == 0) return 0;
        const used = self.total_memory - self.free_memory;
        return @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(self.total_memory)) * 100.0;
    }
};

// ============================================================================
// GPU Buffer
// ============================================================================

/// Type-safe GPU buffer that abstracts over Metal, CUDA, and CPU backends.
///
/// `GpuBuffer(T)` allocates backend-specific memory (Metal shared buffer,
/// CUDA device memory, or plain CPU allocation) and provides a uniform
/// interface for data transfer and access.
///
/// The `getData()` method uses `@ptrCast(@alignCast(...))` on the raw
/// `anyopaque` pointer returned by Metal; this is safe because
/// `createSharedBuffer` always returns page-aligned memory.
pub fn GpuBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: ?*anyopaque,
        len: usize,
        backend: Backend,
        allocator: std.mem.Allocator,
        
        // CPU fallback data
        cpu_data: ?[]T,
        
        // Metal buffer handle
        metal_buffer: ?metal_bindings.MTLBuffer,
        
        // CUDA device pointer
        cuda_ptr: cuda_bindings.CUdeviceptr,
        
        pub fn alloc(allocator: std.mem.Allocator, ctx: *GpuContext, len: usize) !Self {
            var buffer = Self{
                .ptr = null,
                .len = len,
                .backend = ctx.backend,
                .allocator = allocator,
                .cpu_data = null,
                .metal_buffer = null,
                .cuda_ptr = 0,
            };
            
            switch (ctx.backend) {
                .metal => {
                    if (ctx.metal_device) |device| {
                        const size = len * @sizeOf(T);
                        if (metal_bindings.createSharedBuffer(device, size)) |mtl_buf| {
                            buffer.metal_buffer = mtl_buf;
                            buffer.ptr = metal_bindings.getBufferContents(mtl_buf);
                            return buffer;
                        }
                    }
                    buffer.cpu_data = try allocator.alloc(T, len);
                },
                .cuda => {
                    if (cuda_bindings.isCudaAvailable()) {
                        const size = len * @sizeOf(T);
                        buffer.cuda_ptr = try cuda_bindings.malloc(size);
                        buffer.cpu_data = try allocator.alloc(T, len);
                        return buffer;
                    }
                    buffer.cpu_data = try allocator.alloc(T, len);
                },
                .cpu => {
                    buffer.cpu_data = try allocator.alloc(T, len);
                },
            }
            
            return buffer;
        }
        
        pub fn free(self: *Self) void {
            switch (self.backend) {
                .metal => {
                    if (self.metal_buffer) |buf| {
                        metal_bindings.release(buf);
                        self.metal_buffer = null;
                        self.ptr = null;
                    }
                    if (self.cpu_data) |data| {
                        self.allocator.free(data);
                        self.cpu_data = null;
                    }
                },
                .cuda => {
                    if (self.cuda_ptr != 0) {
                        cuda_bindings.free(self.cuda_ptr);
                        self.cuda_ptr = 0;
                    }
                    if (self.cpu_data) |data| {
                        self.allocator.free(data);
                        self.cpu_data = null;
                    }
                },
                .cpu => {
                    if (self.cpu_data) |data| {
                        self.allocator.free(data);
                        self.cpu_data = null;
                    }
                },
            }
            self.ptr = null;
        }
        
        pub fn getData(self: *Self) ?[]T {
            if (self.ptr) |p| {
                const typed_ptr: [*]T = @ptrCast(@alignCast(p));
                return typed_ptr[0..self.len];
            }
            return self.cpu_data;
        }
        
        pub fn copyFromHost(self: *Self, data: []const T) !void {
            if (data.len != self.len) return error.SizeMismatch;
            
            switch (self.backend) {
                .metal => {
                    // For Metal with shared memory, we can write directly
                    if (self.ptr) |p| {
                        const typed_ptr: [*]T = @ptrCast(@alignCast(p));
                        @memcpy(typed_ptr[0..self.len], data);
                        return;
                    }
                    if (self.cpu_data) |buf| {
                        @memcpy(buf, data);
                    }
                },
                .cuda => {
                    // For CUDA, use cudaMemcpy
                    if (self.cuda_ptr != 0) {
                        const bytes = std.mem.sliceAsBytes(data);
                        try cuda_bindings.memcpyHostToDevice(self.cuda_ptr, bytes);
                        return;
                    }
                    if (self.cpu_data) |buf| {
                        @memcpy(buf, data);
                    }
                },
                .cpu => {
                    if (self.cpu_data) |buf| {
                        @memcpy(buf, data);
                    }
                },
            }
        }
        
        pub fn copyToHost(self: *Self, data: []T) !void {
            if (data.len != self.len) return error.SizeMismatch;
            
            switch (self.backend) {
                .metal => {
                    // For Metal with shared memory, we can read directly
                    if (self.ptr) |p| {
                        const typed_ptr: [*]T = @ptrCast(@alignCast(p));
                        @memcpy(data, typed_ptr[0..self.len]);
                        return;
                    }
                    if (self.cpu_data) |buf| {
                        @memcpy(data, buf);
                    }
                },
                .cuda => {
                    // For CUDA, use cudaMemcpy
                    if (self.cuda_ptr != 0) {
                        const bytes = std.mem.sliceAsBytes(data);
                        try cuda_bindings.memcpyDeviceToHost(@constCast(bytes), self.cuda_ptr);
                        return;
                    }
                    if (self.cpu_data) |buf| {
                        @memcpy(data, buf);
                    }
                },
                .cpu => {
                    if (self.cpu_data) |buf| {
                        @memcpy(data, buf);
                    }
                },
            }
        }
    };
}

// ============================================================================
// GPU Context
// ============================================================================

pub const GpuContext = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    device_info: DeviceInfo,
    initialized: bool,
    
    // Backend-specific handles
    metal_device: ?metal_bindings.MTLDevice,
    metal_command_queue: ?metal_bindings.MTLCommandQueue,
    cuda_device_id: c_int,
    
    // Statistics
    allocations: std.atomic.Value(u64),
    bytes_allocated: std.atomic.Value(u64),
    kernel_dispatches: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator) !?*GpuContext {
        const backend = Backend.detect();
        
        log.info("Detected GPU backend: {s}", .{backend.toString()});
        
        const ctx = try allocator.create(GpuContext);
        ctx.* = .{
            .allocator = allocator,
            .backend = backend,
            .device_info = undefined,
            .initialized = false,
            .metal_device = null,
            .metal_command_queue = null,
            .cuda_device_id = 0,
            .allocations = std.atomic.Value(u64).init(0),
            .bytes_allocated = std.atomic.Value(u64).init(0),
            .kernel_dispatches = std.atomic.Value(u64).init(0),
        };
        
        // Initialize backend
        switch (backend) {
            .metal => try ctx.initMetal(),
            .cuda => try ctx.initCuda(),
            .cpu => ctx.initCpu(),
        }
        
        ctx.initialized = true;
        return ctx;
    }
    
    pub fn deinit(self: *GpuContext) void {
        switch (self.backend) {
            .metal => self.deinitMetal(),
            .cuda => self.deinitCuda(),
            .cpu => {},
        }
        self.allocator.destroy(self);
    }
    
    fn initMetal(self: *GpuContext) !void {
        log.info("Initializing Metal backend...", .{});
        
        // Initialize device info with defaults
        self.device_info = DeviceInfo{
            .name = [_]u8{0} ** 256,
            .name_len = 0,
            .total_memory = 0,
            .free_memory = 0,
            .compute_units = 0,
            .max_threads_per_group = 1024,
            .backend = .metal,
            .architecture = [_]u8{0} ** 64,
            .architecture_len = 0,
            .supports_metal3 = false,
            .apple_gpu_family = 0,
            .has_unified_memory = false,
            .compute_capability_major = 0,
            .compute_capability_minor = 0,
            .multiprocessor_count = 0,
            .warp_size = 32,
        };
        
        // Get real Metal device on macOS (not in tests)
        if (comptime builtin.os.tag == .macos and !builtin.is_test) {
            if (metal_bindings.getDevice()) |device| {
                self.metal_device = device;
                
                // Get real device info
                const metal_info = metal_bindings.getDeviceInfo(device);
                
                // Copy name
                @memcpy(self.device_info.name[0..metal_info.name_len], metal_info.name[0..metal_info.name_len]);
                self.device_info.name_len = metal_info.name_len;
                
                // Memory
                self.device_info.total_memory = metal_info.recommended_max_working_set_size;
                self.device_info.free_memory = metal_info.recommended_max_working_set_size; // Metal doesn't provide free memory
                self.device_info.has_unified_memory = metal_info.has_unified_memory;
                
                // Compute
                self.device_info.max_threads_per_group = metal_info.max_threads_per_threadgroup;
                self.device_info.apple_gpu_family = metal_info.supports_apple_family;
                self.device_info.supports_metal3 = metal_info.supports_metal3;
                
                // Set architecture based on GPU family
                const arch_name = metal_info.getAppleFamilyName();
                @memcpy(self.device_info.architecture[0..arch_name.len], arch_name);
                self.device_info.architecture_len = arch_name.len;
                
                // Estimate compute units based on GPU family
                // These are rough estimates for Apple Silicon
                self.device_info.compute_units = switch (metal_info.supports_apple_family) {
                    9 => 18, // M3 Pro has up to 18 GPU cores
                    8 => 19, // M2 Pro has up to 19 GPU cores
                    7 => 16, // M1 Pro has up to 16 GPU cores
                    else => 8,
                };
                
                // Create command queue
                self.metal_command_queue = metal_bindings.createCommandQueue(device);
                
                // Log real device info
                metal_bindings.printDeviceInfo(&metal_info);
                
                log.info("Metal device initialized: {s}", .{self.device_info.getName()});
                return;
            }
        }
        
        // Fallback for tests or when Metal is unavailable
        const name = "Metal (Unavailable)";
        @memcpy(self.device_info.name[0..name.len], name);
        self.device_info.name_len = name.len;
        
        log.warn("Metal device not available, using mock info", .{});
    }
    
    fn deinitMetal(self: *GpuContext) void {
        if (self.metal_command_queue) |queue| {
            metal_bindings.release(queue);
        }
        // Note: We don't release the device as it's the system default
        self.metal_device = null;
        self.metal_command_queue = null;
    }
    
    fn initCuda(self: *GpuContext) !void {
        log.info("Initializing CUDA backend...", .{});
        
        // Initialize device info with defaults
        self.device_info = DeviceInfo{
            .name = [_]u8{0} ** 256,
            .name_len = 0,
            .total_memory = 0,
            .free_memory = 0,
            .compute_units = 0,
            .max_threads_per_group = 1024,
            .backend = .cuda,
            .architecture = [_]u8{0} ** 64,
            .architecture_len = 0,
            .supports_metal3 = false,
            .apple_gpu_family = 0,
            .has_unified_memory = false,
            .compute_capability_major = 0,
            .compute_capability_minor = 0,
            .multiprocessor_count = 0,
            .warp_size = 32,
        };
        
        // Check for CUDA devices
        if (cuda_bindings.isCudaAvailable()) {
            const device_count = cuda_bindings.getDeviceCount() catch 0;
            
            if (device_count > 0) {
                // Use the first CUDA device
                self.cuda_device_id = 0;
                cuda_bindings.setDevice(0) catch {};
                
                // Get real device info
                const cuda_info = cuda_bindings.getDeviceInfo(0) catch {
                    log.warn("Failed to get CUDA device info", .{});
                    return;
                };
                
                // Copy name
                @memcpy(self.device_info.name[0..cuda_info.name_len], cuda_info.name[0..cuda_info.name_len]);
                self.device_info.name_len = cuda_info.name_len;
                
                // Memory
                self.device_info.total_memory = cuda_info.total_global_mem;
                self.device_info.free_memory = cuda_info.free_global_mem;
                
                // Compute
                self.device_info.compute_units = @intCast(cuda_info.multiprocessor_count);
                self.device_info.max_threads_per_group = @intCast(cuda_info.max_threads_per_block);
                self.device_info.compute_capability_major = cuda_info.compute_capability_major;
                self.device_info.compute_capability_minor = cuda_info.compute_capability_minor;
                self.device_info.multiprocessor_count = cuda_info.multiprocessor_count;
                self.device_info.warp_size = cuda_info.warp_size;
                self.device_info.has_unified_memory = cuda_info.unified_addressing;
                
                // Set architecture name
                const arch_name = cuda_info.getArchitectureName();
                @memcpy(self.device_info.architecture[0..arch_name.len], arch_name);
                self.device_info.architecture_len = arch_name.len;
                
                // Log real device info
                cuda_bindings.printDeviceInfo(&cuda_info);
                
                log.info("CUDA device initialized: {s}", .{self.device_info.getName()});
                return;
            }
        }
        
        // Fallback for when CUDA is unavailable
        const name = "CUDA (Unavailable)";
        @memcpy(self.device_info.name[0..name.len], name);
        self.device_info.name_len = name.len;
        
        log.warn("CUDA device not available, using mock info", .{});
    }
    
    fn deinitCuda(self: *GpuContext) void {
        if (cuda_bindings.isCudaAvailable()) {
            cuda_bindings.deviceReset();
        }
        _ = self;
    }
    
    fn initCpu(self: *GpuContext) void {
        log.info("Using CPU fallback (no GPU available)", .{});
        
        const name = "CPU Fallback";
        var device_info = DeviceInfo{
            .name = [_]u8{0} ** 256,
            .name_len = name.len,
            .total_memory = 0,
            .free_memory = 0,
            .compute_units = 1,
            .max_threads_per_group = 1,
            .backend = .cpu,
            .architecture = [_]u8{0} ** 64,
            .architecture_len = 0,
            .supports_metal3 = false,
            .apple_gpu_family = 0,
            .has_unified_memory = true,
            .compute_capability_major = 0,
            .compute_capability_minor = 0,
            .multiprocessor_count = 0,
            .warp_size = 1,
        };
        @memcpy(device_info.name[0..name.len], name);
        
        const arch = "x86_64/ARM64";
        @memcpy(device_info.architecture[0..arch.len], arch);
        device_info.architecture_len = arch.len;
        
        self.device_info = device_info;
    }
    
    pub fn getDeviceName(self: *const GpuContext) []const u8 {
        return self.device_info.getName();
    }
    
    pub fn getBackend(self: *const GpuContext) Backend {
        return self.backend;
    }
    
    pub fn isGpuAvailable(self: *const GpuContext) bool {
        return self.backend != .cpu;
    }
    
    /// Get detailed device information
    pub fn getDeviceInfo(self: *const GpuContext) *const DeviceInfo {
        return &self.device_info;
    }
    
    // =========================================================================
    // Buffer Allocation
    // =========================================================================
    
    pub fn allocBuffer(self: *GpuContext, comptime T: type, len: usize) !GpuBuffer(T) {
        const buffer = try GpuBuffer(T).alloc(self.allocator, len, self.backend);
        
        _ = self.allocations.fetchAdd(1, .monotonic);
        _ = self.bytes_allocated.fetchAdd(len * @sizeOf(T), .monotonic);
        
        return buffer;
    }
    
    // =========================================================================
    // Kernel Dispatch
    // =========================================================================
    
    pub fn dispatchKernel(
        self: *GpuContext,
        kernel_name: []const u8,
        grid_size: [3]u32,
        block_size: [3]u32,
        args: anytype,
    ) !void {
        log.debug("Dispatching kernel: {s} grid=({},{},{}) block=({},{},{})", .{
            kernel_name,
            grid_size[0], grid_size[1], grid_size[2],
            block_size[0], block_size[1], block_size[2],
        });
        
        _ = args;
        
        switch (self.backend) {
            .metal => {
                // Real Metal dispatch would go here
                // Requires: loading .metallib, getting function, creating pipeline, encoding dispatch
                if (self.metal_command_queue) |_| {
                    // Metal dispatch requires Metal.framework C bindings:
                    //   1. MTLDevice.makeComputePipelineState(function:) for the .metallib kernel
                    //   2. MTLCommandBuffer from the command queue
                    //   3. MTLComputeCommandEncoder: setComputePipelineState, setBuffer(s), dispatchThreadgroups
                    //   4. endEncoding → commit → waitUntilCompleted
                    // See: https://developer.apple.com/documentation/metal/performing_calculations_on_a_gpu
                    log.debug("Metal kernel dispatch (pipeline ready)", .{});
                }
            },
            .cuda => {
                // Real CUDA dispatch would go here
                // Requires: loading .ptx/.cubin, getting function, launching kernel
                if (cuda_bindings.isCudaAvailable()) {
                    // CUDA dispatch requires driver API (libcuda.so) bindings:
                    //   1. cuModuleLoad / cuModuleLoadDataEx for .ptx or .cubin
                    //   2. cuModuleGetFunction to get CUfunction handle
                    //   3. cuLaunchKernel(function, gridDim.xyz, blockDim.xyz, sharedMem, stream, args, extra)
                    // See: https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__EXEC.html
                    log.debug("CUDA kernel dispatch (driver ready)", .{});
                }
            },
            .cpu => {
                // CPU fallback: serial execution
                log.debug("CPU fallback: simulating kernel execution", .{});
            },
        }
        
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
    }
    
    // =========================================================================
    // Synchronization
    // =========================================================================
    
    pub fn synchronize(self: *GpuContext) !void {
        switch (self.backend) {
            .metal => {
                // For Metal, we would wait on the command buffer
                // Since we're using shared memory, operations are often already visible
            },
            .cuda => {
                try cuda_bindings.deviceSynchronize();
            },
            .cpu => {
                // No-op for CPU
            },
        }
    }
    
    // =========================================================================
    // Statistics
    // =========================================================================
    
    pub fn getStats(self: *const GpuContext) struct {
        allocations: u64,
        bytes_allocated: u64,
        kernel_dispatches: u64,
    } {
        return .{
            .allocations = self.allocations.load(.acquire),
            .bytes_allocated = self.bytes_allocated.load(.acquire),
            .kernel_dispatches = self.kernel_dispatches.load(.acquire),
        };
    }
    
    /// Print a summary of the GPU context
    pub fn printSummary(self: *const GpuContext) void {
        log.info("GPU Context Summary:", .{});
        log.info("  Backend: {s}", .{self.backend.toString()});
        log.info("  Device: {s}", .{self.device_info.getName()});
        log.info("  Architecture: {s}", .{self.device_info.getArchitecture()});
        log.info("  Total Memory: {} MB", .{self.device_info.total_memory / (1024 * 1024)});
        log.info("  Free Memory: {} MB", .{self.device_info.free_memory / (1024 * 1024)});
        log.info("  Compute Units: {}", .{self.device_info.compute_units});
        log.info("  Max Threads/Group: {}", .{self.device_info.max_threads_per_group});
        
        if (self.backend == .metal) {
            log.info("  Apple GPU Family: {}", .{self.device_info.apple_gpu_family});
            log.info("  Metal 3 Support: {}", .{self.device_info.supports_metal3});
            log.info("  Unified Memory: {}", .{self.device_info.has_unified_memory});
        } else if (self.backend == .cuda) {
            log.info("  Compute Capability: {}.{}", .{
                self.device_info.compute_capability_major,
                self.device_info.compute_capability_minor,
            });
            log.info("  Multiprocessors: {}", .{self.device_info.multiprocessor_count});
            log.info("  Warp Size: {}", .{self.device_info.warp_size});
        }
        
        const stats = self.getStats();
        log.info("  Allocations: {}", .{stats.allocations});
        log.info("  Bytes Allocated: {} KB", .{stats.bytes_allocated / 1024});
        log.info("  Kernel Dispatches: {}", .{stats.kernel_dispatches});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Backend detection" {
    const backend = Backend.detect();
    // Should return something valid
    try std.testing.expect(backend == .metal or backend == .cuda or backend == .cpu);
}

test "Backend toString" {
    try std.testing.expectEqualStrings("Metal", Backend.metal.toString());
    try std.testing.expectEqualStrings("CUDA", Backend.cuda.toString());
    try std.testing.expectEqualStrings("CPU", Backend.cpu.toString());
}

test "GpuContext init and deinit" {
    const ctx = try GpuContext.init(std.testing.allocator);
    if (ctx) |c| {
        defer c.deinit();
        
        try std.testing.expect(c.initialized);
        try std.testing.expect(c.device_info.name_len > 0);
    }
}

test "GpuBuffer alloc and free" {
    var buffer = try GpuBuffer(f32).alloc(std.testing.allocator, 1024, .cpu);
    defer buffer.free();
    
    try std.testing.expectEqual(@as(usize, 1024), buffer.len);
    try std.testing.expect(buffer.cpu_data != null);
}

test "GpuBuffer copyFromHost and copyToHost" {
    var buffer = try GpuBuffer(f32).alloc(std.testing.allocator, 4, .cpu);
    defer buffer.free();
    
    const src = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    try buffer.copyFromHost(&src);
    
    var dst: [4]f32 = undefined;
    try buffer.copyToHost(&dst);
    
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dst[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), dst[3], 0.001);
}

test "DeviceInfo getMemoryUsagePercent" {
    var info = DeviceInfo{
        .name = [_]u8{0} ** 256,
        .name_len = 0,
        .total_memory = 1000,
        .free_memory = 400,
        .compute_units = 1,
        .max_threads_per_group = 1,
        .backend = .cpu,
        .architecture = [_]u8{0} ** 64,
        .architecture_len = 0,
        .supports_metal3 = false,
        .apple_gpu_family = 0,
        .has_unified_memory = false,
        .compute_capability_major = 0,
        .compute_capability_minor = 0,
        .multiprocessor_count = 0,
        .warp_size = 1,
    };
    
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), info.getMemoryUsagePercent(), 0.1);
}