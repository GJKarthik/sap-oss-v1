//! CUDA Bindings
//!
//! Dual-mode implementation: real CUDA driver API when has_cuda=true (Linux + -Dgpu=true),
//! safe stub defaults otherwise. The application gracefully falls back to CPU when CUDA
//! is unavailable at compile time or runtime.

const std = @import("std");
const builtin = @import("builtin");

pub const CUdevice = i32;
pub const CUcontext = *anyopaque;
pub const CUmodule = *anyopaque;
pub const CUfunction = *anyopaque;
pub const CUdeviceptr = usize;
pub const CUresult = enum(i32) {
    success = 0,
    error_invalid_value = 1,
    error_out_of_memory = 2,
    error_not_initialized = 3,
    error_deinitialized = 4,
    error_no_device = 100,
    _,
};

pub const cublasStatus_t = enum(i32) {
    SUCCESS = 0,
    NOT_INITIALIZED = 1,
    ALLOC_FAILED = 3,
    INVALID_VALUE = 7,
    ARCH_MISMATCH = 8,
    MAPPING_ERROR = 11,
    EXECUTION_FAILED = 13,
    INTERNAL_ERROR = 14,
    NOT_SUPPORTED = 15,
    _,
};

pub const cublasLtHandle_t = *anyopaque;
pub const cublasLtMatmulDesc_t = *anyopaque;
pub const cublasLtMatrixLayout_t = *anyopaque;

// ============================================================================
// High-Level Wrappers (gated on has_cuda)
// ============================================================================

pub fn init() CUresult {
    return cuInit(0);
}

/// Check if CUDA is available by probing the driver API
pub fn isCudaAvailable() bool {
    if (comptime has_cuda) {
        const rc = cuInitForProbe(0);
        return rc == .success;
    }
    return false;
}

const cuInitForProbe = if (has_cuda) cuInitProbeReal else cuInitProbeStub;
fn cuInitProbeReal(flags: u32) CUresult {
    const f = @extern(*const fn (u32) callconv(.c) CUresult, .{ .name = "cuInit" });
    return f(flags);
}
fn cuInitProbeStub(_: u32) CUresult {
    return .error_no_device;
}


/// Get number of CUDA devices (0 in stub mode)
pub fn getDeviceCount() !i32 {
    var count: c_int = 0;
    const rc = cuDeviceGetCount(&count);
    if (rc != .success) return 0;
    return @intCast(count);
}

/// Validate that a CUDA device exists. Does NOT create a context —
/// context creation is owned by CudaBackend.init() via cuCtxCreate.
pub fn setDevice(device_id: i32) !void {
    var device: CUdevice = undefined;
    if (cuDeviceGet(&device, @intCast(device_id)) != .success) return error.CudaError;
}

pub fn getComputeCapability(device_id: i32) !struct { major: i32, minor: i32 } {
    var device: CUdevice = undefined;
    if (cuDeviceGet(&device, @intCast(device_id)) != .success) return .{ .major = 0, .minor = 0 };
    var major: c_int = 0;
    var minor: c_int = 0;
    _ = cuDeviceGetAttribute(&major, .compute_capability_major, device);
    _ = cuDeviceGetAttribute(&minor, .compute_capability_minor, device);
    return .{ .major = @intCast(major), .minor = @intCast(minor) };
}

pub fn malloc(size: usize) !CUdeviceptr {
    var dptr: CUdeviceptr = 0;
    if (cuMemAlloc(&dptr, size) != .success) return error.OutOfMemory;
    return dptr;
}

pub fn free(dptr: CUdeviceptr) void {
    _ = cuMemFree(dptr);
}

pub fn memcpyHostToDevice(dst: CUdeviceptr, src: []const u8) !void {
    if (cuMemcpyHtoD(dst, src.ptr, src.len) != .success) return error.MemcpyFailed;
}

pub fn memcpyDeviceToHost(dst: []u8, src: CUdeviceptr) !void {
    if (cuMemcpyDtoH(dst.ptr, src, dst.len) != .success) return error.MemcpyFailed;
}

pub fn deviceSynchronize() !void {
    if (cuCtxSynchronize() != .success) return error.SyncFailed;
}

pub fn deviceReset() void {
    _ = cuCtxSynchronize();
}

pub fn release(dptr: CUdeviceptr) void {
    _ = cuMemFree(dptr);
}

// ============================================================================
// CUDA Driver API Stubs (for cuda_backend.zig compatibility)
// ============================================================================

pub const CUdevice_attribute = enum(i32) {
    compute_capability_major = 75,
    compute_capability_minor = 76,
    _,
};

/// cuInit — initialize CUDA driver.
pub const cuInit = if (has_cuda) cuInitReal else cuInitStub;
fn cuInitReal(flags: u32) CUresult {
    const f = @extern(*const fn (u32) callconv(.c) CUresult, .{ .name = "cuInit" });
    return f(flags);
}
fn cuInitStub(_: u32) CUresult {
    return .error_no_device;
}

/// cuDeviceGetCount — get number of CUDA devices.
pub const cuDeviceGetCount = if (has_cuda) cuDeviceGetCountReal else cuDeviceGetCountStub;
fn cuDeviceGetCountReal(count: *c_int) CUresult {
    const f = @extern(*const fn (*c_int) callconv(.c) CUresult, .{ .name = "cuDeviceGetCount" });
    return f(count);
}
fn cuDeviceGetCountStub(count: *c_int) CUresult {
    count.* = 0;
    return .success;
}

/// cuDeviceGet — get a device handle.
pub const cuDeviceGet = if (has_cuda) cuDeviceGetReal else cuDeviceGetStub;
fn cuDeviceGetReal(device: *CUdevice, ordinal: c_int) CUresult {
    const f = @extern(*const fn (*CUdevice, c_int) callconv(.c) CUresult, .{ .name = "cuDeviceGet" });
    return f(device, ordinal);
}
fn cuDeviceGetStub(device: *CUdevice, _: c_int) CUresult {
    device.* = 0;
    return .error_no_device;
}

/// cuDeviceGetAttribute — query device attribute.
pub const cuDeviceGetAttribute = if (has_cuda) cuDeviceGetAttributeReal else cuDeviceGetAttributeStub;
fn cuDeviceGetAttributeReal(value: *c_int, attrib: CUdevice_attribute, device: CUdevice) CUresult {
    const f = @extern(*const fn (*c_int, CUdevice_attribute, CUdevice) callconv(.c) CUresult, .{ .name = "cuDeviceGetAttribute" });
    return f(value, attrib, device);
}
fn cuDeviceGetAttributeStub(value: *c_int, _: CUdevice_attribute, _: CUdevice) CUresult {
    value.* = 0;
    return .error_no_device;
}

/// CUDA Device Info structure
pub const CudaDeviceInfo = struct {
    name: [256]u8 = [_]u8{0} ** 256,
    name_len: usize = 0,
    device_id: i32 = 0,
    total_global_mem: u64 = 0,
    free_global_mem: u64 = 0,
    total_memory: u64 = 0,
    free_memory: u64 = 0,
    compute_units: u32 = 0,
    max_threads_per_block: i32 = 1024,
    max_threads_per_group: u32 = 1024,
    compute_capability_major: i32 = 0,
    compute_capability_minor: i32 = 0,
    multiprocessor_count: i32 = 0,
    warp_size: i32 = 32,
    unified_addressing: bool = false,
    has_unified_memory: bool = false,
    supports_metal3: bool = false,
    apple_gpu_family: u32 = 0,
    
    pub fn getName(self: *const CudaDeviceInfo) []const u8 {
        return self.name[0..self.name_len];
    }
    
    pub fn getArchitecture(self: *const CudaDeviceInfo) []const u8 {
        return switch (self.compute_capability_major) {
            9 => "Hopper",
            8 => if (self.compute_capability_minor >= 9) "Ada Lovelace" else "Ampere",
            7 => if (self.compute_capability_minor >= 5) "Turing" else "Volta",
            6 => "Pascal",
            else => "Unknown",
        };
    }
    
    pub fn getArchitectureName(self: *const CudaDeviceInfo) []const u8 {
        return self.getArchitecture();
    }
};

// ============================================================================
// CUDA Driver API — Kernel Launch & Module Management
// ============================================================================

// Build option set by build.zig when -Dgpu=true is passed
const has_cuda = blk: {
    if (@import("builtin").os.tag != .linux) break :blk false;
    const opts = @import("cuda_build_options");
    break :blk opts.enable_cuda;
};

/// Load a PTX module from a null-terminated string.
pub const cuModuleLoadData = if (has_cuda) cuModuleLoadDataReal else cuModuleLoadDataStub;

fn cuModuleLoadDataReal(module: *CUmodule, image: [*]const u8) CUresult {
    const f = @extern(*const fn (*CUmodule, [*]const u8) callconv(.c) CUresult, .{ .name = "cuModuleLoadData" });
    return f(module, image);
}
fn cuModuleLoadDataStub(_: *CUmodule, _: [*]const u8) CUresult {
    return .error_no_device;
}

/// Get a kernel function handle from a loaded module.
pub const cuModuleGetFunction = if (has_cuda) cuModuleGetFunctionReal else cuModuleGetFunctionStub;

fn cuModuleGetFunctionReal(func: *CUfunction, module: CUmodule, name: [*:0]const u8) CUresult {
    const f = @extern(*const fn (*CUfunction, CUmodule, [*:0]const u8) callconv(.c) CUresult, .{ .name = "cuModuleGetFunction" });
    return f(func, module, name);
}
fn cuModuleGetFunctionStub(_: *CUfunction, _: CUmodule, _: [*:0]const u8) CUresult {
    return .error_no_device;
}

/// Launch a CUDA kernel.
pub const cuLaunchKernel = if (has_cuda) cuLaunchKernelReal else cuLaunchKernelStub;

fn cuLaunchKernelReal(
    func: CUfunction,
    grid_x: u32, grid_y: u32, grid_z: u32,
    block_x: u32, block_y: u32, block_z: u32,
    shared_mem_bytes: u32,
    stream: ?*anyopaque,
    kernel_params: [*]?*anyopaque,
    extra: ?[*]?*anyopaque,
) CUresult {
    const f = @extern(*const fn (CUfunction, u32, u32, u32, u32, u32, u32, u32, ?*anyopaque, [*]?*anyopaque, ?[*]?*anyopaque) callconv(.c) CUresult, .{ .name = "cuLaunchKernel" });
    return f(func, grid_x, grid_y, grid_z, block_x, block_y, block_z, shared_mem_bytes, stream, kernel_params, extra);
}
fn cuLaunchKernelStub(
    _: CUfunction, _: u32, _: u32, _: u32,
    _: u32, _: u32, _: u32, _: u32,
    _: ?*anyopaque, _: [*]?*anyopaque, _: ?[*]?*anyopaque,
) CUresult {
    return .error_no_device;
}

/// cuDevicePrimaryCtxRetain — retain the primary context on a device (shared, avoids double contexts).
pub const cuDevicePrimaryCtxRetain = if (has_cuda) cuDevicePrimaryCtxRetainReal else cuDevicePrimaryCtxRetainStub;
fn cuDevicePrimaryCtxRetainReal(ctx: *CUcontext, device: CUdevice) CUresult {
    const f = @extern(*const fn (*CUcontext, CUdevice) callconv(.c) CUresult, .{ .name = "cuDevicePrimaryCtxRetain" });
    return f(ctx, device);
}
fn cuDevicePrimaryCtxRetainStub(_: *CUcontext, _: CUdevice) CUresult {
    return .error_no_device;
}

/// cuDevicePrimaryCtxRelease — release the primary context on a device.
pub const cuDevicePrimaryCtxRelease = if (has_cuda) cuDevicePrimaryCtxReleaseReal else cuDevicePrimaryCtxReleaseStub;
fn cuDevicePrimaryCtxReleaseReal(device: CUdevice) CUresult {
    const f = @extern(*const fn (CUdevice) callconv(.c) CUresult, .{ .name = "cuDevicePrimaryCtxRelease" });
    return f(device);
}
fn cuDevicePrimaryCtxReleaseStub(_: CUdevice) CUresult {
    return .error_no_device;
}

/// cuCtxSetCurrent — set the current CUDA context for this thread.
pub const cuCtxSetCurrent = if (has_cuda) cuCtxSetCurrentReal else cuCtxSetCurrentStub;
fn cuCtxSetCurrentReal(ctx: CUcontext) CUresult {
    const f = @extern(*const fn (CUcontext) callconv(.c) CUresult, .{ .name = "cuCtxSetCurrent" });
    return f(ctx);
}
fn cuCtxSetCurrentStub(_: CUcontext) CUresult {
    return .error_no_device;
}

/// cuDeviceGetName — get the name of a device.
pub const cuDeviceGetName = if (has_cuda) cuDeviceGetNameReal else cuDeviceGetNameStub;
fn cuDeviceGetNameReal(name: [*]u8, len: c_int, device: CUdevice) CUresult {
    const f = @extern(*const fn ([*]u8, c_int, CUdevice) callconv(.c) CUresult, .{ .name = "cuDeviceGetName" });
    return f(name, len, device);
}
fn cuDeviceGetNameStub(_: [*]u8, _: c_int, _: CUdevice) CUresult {
    return .error_no_device;
}

/// cuDeviceTotalMem_v2 — get total memory on a device.
pub const cuDeviceTotalMem = if (has_cuda) cuDeviceTotalMemReal else cuDeviceTotalMemStub;
fn cuDeviceTotalMemReal(bytes: *usize, device: CUdevice) CUresult {
    const f = @extern(*const fn (*usize, CUdevice) callconv(.c) CUresult, .{ .name = "cuDeviceTotalMem_v2" });
    return f(bytes, device);
}
fn cuDeviceTotalMemStub(bytes: *usize, _: CUdevice) CUresult {
    bytes.* = 0;
    return .error_no_device;
}

/// cuMemGetInfo_v2 — get free and total memory for the current context.
pub const cuMemGetInfo = if (has_cuda) cuMemGetInfoReal else cuMemGetInfoStub;
fn cuMemGetInfoReal(free_bytes: *usize, total_bytes: *usize) CUresult {
    const f = @extern(*const fn (*usize, *usize) callconv(.c) CUresult, .{ .name = "cuMemGetInfo_v2" });
    return f(free_bytes, total_bytes);
}
fn cuMemGetInfoStub(free_bytes: *usize, total_bytes: *usize) CUresult {
    free_bytes.* = 0;
    total_bytes.* = 0;
    return .error_no_device;
}

/// Create a CUDA context on the given device.
pub const cuCtxCreate = if (has_cuda) cuCtxCreateReal else cuCtxCreateStub;

fn cuCtxCreateReal(ctx: *CUcontext, flags: u32, device: CUdevice) CUresult {
    const f = @extern(*const fn (*CUcontext, u32, CUdevice) callconv(.c) CUresult, .{ .name = "cuCtxCreate_v2" });
    return f(ctx, flags, device);
}
fn cuCtxCreateStub(_: *CUcontext, _: u32, _: CUdevice) CUresult {
    return .error_no_device;
}

/// Destroy a CUDA context.
pub const cuCtxDestroy = if (has_cuda) cuCtxDestroyReal else cuCtxDestroyStub;

fn cuCtxDestroyReal(ctx: CUcontext) CUresult {
    const f = @extern(*const fn (CUcontext) callconv(.c) CUresult, .{ .name = "cuCtxDestroy" });
    return f(ctx);
}
fn cuCtxDestroyStub(_: CUcontext) CUresult {
    return .error_no_device;
}

/// Synchronize the current CUDA context.
pub const cuCtxSynchronize = if (has_cuda) cuCtxSynchronizeReal else cuCtxSynchronizeStub;

fn cuCtxSynchronizeReal() CUresult {
    const f = @extern(*const fn () callconv(.c) CUresult, .{ .name = "cuCtxSynchronize" });
    return f();
}
fn cuCtxSynchronizeStub() CUresult {
    return .error_no_device;
}

/// Allocate device memory.
pub const cuMemAlloc = if (has_cuda) cuMemAllocReal else cuMemAllocStub;

fn cuMemAllocReal(dptr: *CUdeviceptr, size: usize) CUresult {
    const f = @extern(*const fn (*CUdeviceptr, usize) callconv(.c) CUresult, .{ .name = "cuMemAlloc_v2" });
    return f(dptr, size);
}
fn cuMemAllocStub(_: *CUdeviceptr, _: usize) CUresult {
    return .error_no_device;
}

/// Set device memory to a 32-bit value (used for zeroing buffers).
pub const cuMemsetD32 = if (has_cuda) cuMemsetD32Real else cuMemsetD32Stub;

fn cuMemsetD32Real(dptr: CUdeviceptr, value: u32, count: usize) CUresult {
    const f = @extern(*const fn (CUdeviceptr, u32, usize) callconv(.c) CUresult, .{ .name = "cuMemsetD32_v2" });
    return f(dptr, value, count);
}
fn cuMemsetD32Stub(_: CUdeviceptr, _: u32, _: usize) CUresult {
    return .error_no_device;
}

/// Free device memory.
pub const cuMemFree = if (has_cuda) cuMemFreeReal else cuMemFreeStub;

fn cuMemFreeReal(dptr: CUdeviceptr) CUresult {
    const f = @extern(*const fn (CUdeviceptr) callconv(.c) CUresult, .{ .name = "cuMemFree_v2" });
    return f(dptr);
}
fn cuMemFreeStub(_: CUdeviceptr) CUresult {
    return .error_no_device;
}

/// Allocate pinned (page-locked) host memory for async DMA transfers.
pub const cuMemAllocHost = if (has_cuda) cuMemAllocHostReal else cuMemAllocHostStub;

fn cuMemAllocHostReal(pp: *?*anyopaque, byte_count: usize) CUresult {
    const f = @extern(*const fn (*?*anyopaque, usize) callconv(.c) CUresult, .{ .name = "cuMemAllocHost_v2" });
    return f(pp, byte_count);
}
fn cuMemAllocHostStub(_: *?*anyopaque, _: usize) CUresult {
    return .error_no_device;
}

/// Free pinned host memory allocated by cuMemAllocHost.
pub const cuMemFreeHost = if (has_cuda) cuMemFreeHostReal else cuMemFreeHostStub;

fn cuMemFreeHostReal(p: *anyopaque) CUresult {
    const f = @extern(*const fn (*anyopaque) callconv(.c) CUresult, .{ .name = "cuMemFreeHost" });
    return f(p);
}
fn cuMemFreeHostStub(_: *anyopaque) CUresult {
    return .error_no_device;
}

/// Copy data from host to device.
pub const cuMemcpyHtoD = if (has_cuda) cuMemcpyHtoDReal else cuMemcpyHtoDStub;

fn cuMemcpyHtoDReal(dst: CUdeviceptr, src: [*]const u8, size: usize) CUresult {
    const f = @extern(*const fn (CUdeviceptr, [*]const u8, usize) callconv(.c) CUresult, .{ .name = "cuMemcpyHtoD_v2" });
    return f(dst, src, size);
}
fn cuMemcpyHtoDStub(_: CUdeviceptr, _: [*]const u8, _: usize) CUresult {
    return .error_no_device;
}

/// Copy data from device to host.
pub const cuMemcpyDtoH = if (has_cuda) cuMemcpyDtoHReal else cuMemcpyDtoHStub;

fn cuMemcpyDtoHReal(dst: [*]u8, src: CUdeviceptr, size: usize) CUresult {
    const f = @extern(*const fn ([*]u8, CUdeviceptr, usize) callconv(.c) CUresult, .{ .name = "cuMemcpyDtoH_v2" });
    return f(dst, src, size);
}
fn cuMemcpyDtoHStub(_: [*]u8, _: CUdeviceptr, _: usize) CUresult {
    return .error_no_device;
}

/// Copy data from device to device.
pub const cuMemcpyDtoD = if (has_cuda) cuMemcpyDtoDReal else cuMemcpyDtoDStub;

fn cuMemcpyDtoDReal(dst: CUdeviceptr, src: CUdeviceptr, size: usize) CUresult {
    const f = @extern(*const fn (CUdeviceptr, CUdeviceptr, usize) callconv(.c) CUresult, .{ .name = "cuMemcpyDtoD_v2" });
    return f(dst, src, size);
}
fn cuMemcpyDtoDStub(_: CUdeviceptr, _: CUdeviceptr, _: usize) CUresult {
    return .error_no_device;
}

/// Async copy data from device to device on a stream (capturable by CUDA Graphs).
pub const cuMemcpyDtoDAsync = if (has_cuda) cuMemcpyDtoDAsyncReal else cuMemcpyDtoDAsyncStub;

fn cuMemcpyDtoDAsyncReal(dst: CUdeviceptr, src: CUdeviceptr, size: usize, stream: CUstream) CUresult {
    const f = @extern(*const fn (CUdeviceptr, CUdeviceptr, usize, CUstream) callconv(.c) CUresult, .{ .name = "cuMemcpyDtoDAsync_v2" });
    return f(dst, src, size, stream);
}
fn cuMemcpyDtoDAsyncStub(_: CUdeviceptr, _: CUdeviceptr, _: usize, _: CUstream) CUresult {
    return .error_no_device;
}

// ============================================================================
// CUDA Streams
// ============================================================================

pub const CUstream = ?*anyopaque;

/// Create a CUDA stream.
pub const cuStreamCreate = if (has_cuda) cuStreamCreateReal else cuStreamCreateStub;
fn cuStreamCreateReal(stream: *CUstream, flags: u32) CUresult {
    const f = @extern(*const fn (*CUstream, u32) callconv(.c) CUresult, .{ .name = "cuStreamCreate" });
    return f(stream, flags);
}
fn cuStreamCreateStub(_: *CUstream, _: u32) CUresult {
    return .error_no_device;
}

/// Destroy a CUDA stream.
pub const cuStreamDestroy = if (has_cuda) cuStreamDestroyReal else cuStreamDestroyStub;
fn cuStreamDestroyReal(stream: CUstream) CUresult {
    const f = @extern(*const fn (CUstream) callconv(.c) CUresult, .{ .name = "cuStreamDestroy_v2" });
    return f(stream);
}
fn cuStreamDestroyStub(_: CUstream) CUresult {
    return .error_no_device;
}

/// Synchronize a stream.
pub const cuStreamSynchronize = if (has_cuda) cuStreamSynchronizeReal else cuStreamSynchronizeStub;
fn cuStreamSynchronizeReal(stream: CUstream) CUresult {
    const f = @extern(*const fn (CUstream) callconv(.c) CUresult, .{ .name = "cuStreamSynchronize" });
    return f(stream);
}
fn cuStreamSynchronizeStub(_: CUstream) CUresult {
    return .error_no_device;
}

// ============================================================================
// Async Host-to-Device Transfer (on stream)
// ============================================================================

/// Async copy from host (pinned) to device on a specific stream.
/// Source MUST be page-locked (pinned) memory for truly async behavior.
pub const cuMemcpyHtoDAsync = if (has_cuda) cuMemcpyHtoDAsyncReal else cuMemcpyHtoDAsyncStub;

fn cuMemcpyHtoDAsyncReal(dst: CUdeviceptr, src: [*]const u8, size: usize, stream: CUstream) CUresult {
    const f = @extern(*const fn (CUdeviceptr, [*]const u8, usize, CUstream) callconv(.c) CUresult, .{ .name = "cuMemcpyHtoDAsync_v2" });
    return f(dst, src, size, stream);
}
fn cuMemcpyHtoDAsyncStub(_: CUdeviceptr, _: [*]const u8, _: usize, _: CUstream) CUresult {
    return .error_no_device;
}

// ============================================================================
// CUDA Events (for inter-stream synchronization)
// ============================================================================

pub const CUevent = ?*anyopaque;

/// Create an event. flags=0 for default, 0x1 for CU_EVENT_BLOCKING_SYNC,
/// 0x2 for CU_EVENT_DISABLE_TIMING (lower overhead).
pub const cuEventCreate = if (has_cuda) cuEventCreateReal else cuEventCreateStub;
fn cuEventCreateReal(event: *CUevent, flags: u32) CUresult {
    const f = @extern(*const fn (*CUevent, u32) callconv(.c) CUresult, .{ .name = "cuEventCreate" });
    return f(event, flags);
}
fn cuEventCreateStub(_: *CUevent, _: u32) CUresult {
    return .error_no_device;
}

/// Destroy an event.
pub const cuEventDestroy = if (has_cuda) cuEventDestroyReal else cuEventDestroyStub;
fn cuEventDestroyReal(event: CUevent) CUresult {
    const f = @extern(*const fn (CUevent) callconv(.c) CUresult, .{ .name = "cuEventDestroy_v2" });
    return f(event);
}
fn cuEventDestroyStub(_: CUevent) CUresult {
    return .error_no_device;
}

/// Record an event on a stream. The event is "signaled" when all preceding
/// operations on the stream complete.
pub const cuEventRecord = if (has_cuda) cuEventRecordReal else cuEventRecordStub;
fn cuEventRecordReal(event: CUevent, stream: CUstream) CUresult {
    const f = @extern(*const fn (CUevent, CUstream) callconv(.c) CUresult, .{ .name = "cuEventRecord" });
    return f(event, stream);
}
fn cuEventRecordStub(_: CUevent, _: CUstream) CUresult {
    return .error_no_device;
}

/// Make a stream wait on an event. All subsequent operations on `stream`
/// will not begin until `event` has been signaled.
/// flags should be 0.
pub const cuStreamWaitEvent = if (has_cuda) cuStreamWaitEventReal else cuStreamWaitEventStub;
fn cuStreamWaitEventReal(stream: CUstream, event: CUevent, flags: u32) CUresult {
    const f = @extern(*const fn (CUstream, CUevent, u32) callconv(.c) CUresult, .{ .name = "cuStreamWaitEvent" });
    return f(stream, event, flags);
}
fn cuStreamWaitEventStub(_: CUstream, _: CUevent, _: u32) CUresult {
    return .error_no_device;
}

// ============================================================================
// CUDA Graphs
// ============================================================================

pub const CUgraph = ?*anyopaque;
pub const CUgraphExec = ?*anyopaque;

pub const CUstreamCaptureMode = enum(i32) {
    global = 0,
    thread_local = 1,
    relaxed = 2,
};

/// Begin graph capture on a stream.
pub const cuStreamBeginCapture = if (has_cuda) cuStreamBeginCaptureReal else cuStreamBeginCaptureStub;
fn cuStreamBeginCaptureReal(stream: CUstream, mode: CUstreamCaptureMode) CUresult {
    const f = @extern(*const fn (CUstream, CUstreamCaptureMode) callconv(.c) CUresult, .{ .name = "cuStreamBeginCapture" });
    return f(stream, mode);
}
fn cuStreamBeginCaptureStub(_: CUstream, _: CUstreamCaptureMode) CUresult {
    return .error_no_device;
}

/// End graph capture and retrieve the graph.
pub const cuStreamEndCapture = if (has_cuda) cuStreamEndCaptureReal else cuStreamEndCaptureStub;
fn cuStreamEndCaptureReal(stream: CUstream, graph: *CUgraph) CUresult {
    const f = @extern(*const fn (CUstream, *CUgraph) callconv(.c) CUresult, .{ .name = "cuStreamEndCapture" });
    return f(stream, graph);
}
fn cuStreamEndCaptureStub(_: CUstream, _: *CUgraph) CUresult {
    return .error_no_device;
}

/// Instantiate an executable graph from a graph.
pub const cuGraphInstantiate = if (has_cuda) cuGraphInstantiateReal else cuGraphInstantiateStub;
fn cuGraphInstantiateReal(exec: *CUgraphExec, graph: CUgraph, _log_buf: ?[*]u8, _buf_sz: usize) CUresult {
    const f = @extern(*const fn (*CUgraphExec, CUgraph, ?[*]u8, usize) callconv(.c) CUresult, .{ .name = "cuGraphInstantiate" });
    return f(exec, graph, _log_buf, _buf_sz);
}
fn cuGraphInstantiateStub(_: *CUgraphExec, _: CUgraph, _: ?[*]u8, _: usize) CUresult {
    return .error_no_device;
}

/// Launch an executable graph on a stream.
pub const cuGraphLaunch = if (has_cuda) cuGraphLaunchReal else cuGraphLaunchStub;
fn cuGraphLaunchReal(exec: CUgraphExec, stream: CUstream) CUresult {
    const f = @extern(*const fn (CUgraphExec, CUstream) callconv(.c) CUresult, .{ .name = "cuGraphLaunch" });
    return f(exec, stream);
}
fn cuGraphLaunchStub(_: CUgraphExec, _: CUstream) CUresult {
    return .error_no_device;
}

/// Destroy a graph.
pub const cuGraphDestroy = if (has_cuda) cuGraphDestroyReal else cuGraphDestroyStub;
fn cuGraphDestroyReal(graph: CUgraph) CUresult {
    const f = @extern(*const fn (CUgraph) callconv(.c) CUresult, .{ .name = "cuGraphDestroy" });
    return f(graph);
}
fn cuGraphDestroyStub(_: CUgraph) CUresult {
    return .error_no_device;
}

/// Destroy an executable graph.
pub const cuGraphExecDestroy = if (has_cuda) cuGraphExecDestroyReal else cuGraphExecDestroyStub;
fn cuGraphExecDestroyReal(exec: CUgraphExec) CUresult {
    const f = @extern(*const fn (CUgraphExec) callconv(.c) CUresult, .{ .name = "cuGraphExecDestroy" });
    return f(exec);
}
fn cuGraphExecDestroyStub(_: CUgraphExec) CUresult {
    return .error_no_device;
}

// ============================================================================
// CUDA Function Attributes
// ============================================================================

/// CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES = 8
pub const CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES: i32 = 8;

/// Set a function attribute (e.g. max dynamic shared memory size).
pub const cuFuncSetAttribute = if (has_cuda) cuFuncSetAttributeReal else cuFuncSetAttributeStub;
fn cuFuncSetAttributeReal(func: CUfunction, attrib: i32, value: i32) CUresult {
    const f = @extern(*const fn (CUfunction, i32, i32) callconv(.c) CUresult, .{ .name = "cuFuncSetAttribute" });
    return f(func, attrib, value);
}
fn cuFuncSetAttributeStub(_: CUfunction, _: i32, _: i32) CUresult {
    return .error_no_device;
}

// ============================================================================
// cuBLAS Runtime API (via @extern for runtime resolution)
// ============================================================================

pub const CublasHandle = *anyopaque;
pub const CublasOperation = enum(i32) {
    N = 0, // No transpose
    T = 1, // Transpose
    C = 2, // Conjugate transpose
};

/// cublasCreate_v2 — create a cuBLAS handle.
pub const cublasCreate = if (has_cuda) cublasCreateReal else cublasCreateStub;
fn cublasCreateReal(handle: *CublasHandle) cublasStatus_t {
    const f = @extern(*const fn (*CublasHandle) callconv(.c) cublasStatus_t, .{ .name = "cublasCreate_v2" });
    return f(handle);
}
fn cublasCreateStub(_: *CublasHandle) cublasStatus_t {
    return .NOT_INITIALIZED;
}

/// cublasDestroy_v2 — destroy a cuBLAS handle.
pub const cublasDestroy = if (has_cuda) cublasDestroyReal else cublasDestroyStub;
fn cublasDestroyReal(handle: CublasHandle) cublasStatus_t {
    const f = @extern(*const fn (CublasHandle) callconv(.c) cublasStatus_t, .{ .name = "cublasDestroy_v2" });
    return f(handle);
}
fn cublasDestroyStub(_: CublasHandle) cublasStatus_t {
    return .SUCCESS;
}

/// cublasSetStream_v2 — set the stream for cuBLAS operations.
pub const cublasSetStream = if (has_cuda) cublasSetStreamReal else cublasSetStreamStub;
fn cublasSetStreamReal(handle: CublasHandle, stream: CUstream) cublasStatus_t {
    const f = @extern(*const fn (CublasHandle, CUstream) callconv(.c) cublasStatus_t, .{ .name = "cublasSetStream_v2" });
    return f(handle, stream);
}
fn cublasSetStreamStub(_: CublasHandle, _: CUstream) cublasStatus_t {
    return .NOT_INITIALIZED;
}

/// cublasSgemm_v2 — single-precision GEMM: C = α*op(A)*op(B) + β*C
pub const cublasSgemm = if (has_cuda) cublasSgemmReal else cublasSgemmStub;
fn cublasSgemmReal(
    handle: CublasHandle,
    transa: CublasOperation, transb: CublasOperation,
    m: i32, n: i32, k: i32,
    alpha: *const f32,
    A: *const anyopaque, lda: i32,
    B: *const anyopaque, ldb: i32,
    beta: *const f32,
    C_ptr: *anyopaque, ldc: i32,
) cublasStatus_t {
    const f = @extern(*const fn (
        CublasHandle, CublasOperation, CublasOperation,
        i32, i32, i32, *const f32,
        *const anyopaque, i32, *const anyopaque, i32,
        *const f32, *anyopaque, i32,
    ) callconv(.c) cublasStatus_t, .{ .name = "cublasSgemm_v2" });
    return f(handle, transa, transb, m, n, k, alpha, A, lda, B, ldb, beta, C_ptr, ldc);
}
fn cublasSgemmStub(
    _: CublasHandle, _: CublasOperation, _: CublasOperation,
    _: i32, _: i32, _: i32, _: *const f32,
    _: *const anyopaque, _: i32, _: *const anyopaque, _: i32,
    _: *const f32, _: *anyopaque, _: i32,
) cublasStatus_t {
    return .NOT_INITIALIZED;
}

/// cublasMath_t — math mode for cuBLAS operations.
pub const cublasMath_t = enum(u32) {
    DEFAULT_MATH = 0,
    TENSOR_OP_MATH = 1, // Enable tensor core acceleration
    PEDANTIC_MATH = 2,
    TF32_TENSOR_OP_MATH = 3,
    _,
};

/// cublasSetMathMode — enable/disable tensor core math.
pub const cublasSetMathMode = if (has_cuda) cublasSetMathModeReal else cublasSetMathModeStub;
fn cublasSetMathModeReal(handle: CublasHandle, mode: cublasMath_t) cublasStatus_t {
    const f = @extern(*const fn (CublasHandle, cublasMath_t) callconv(.c) cublasStatus_t, .{ .name = "cublasSetMathMode" });
    return f(handle, mode);
}
fn cublasSetMathModeStub(_: CublasHandle, _: cublasMath_t) cublasStatus_t {
    return .NOT_INITIALIZED;
}

/// cublasHgemm — half-precision GEMM using tensor cores: C = α*op(A)*op(B) + β*C
/// All matrices are FP16 (__half). On T4, uses INT8/FP16 tensor cores for ~65 TFLOPS.
pub const cublasHgemm = if (has_cuda) cublasHgemmReal else cublasHgemmStub;
fn cublasHgemmReal(
    handle: CublasHandle,
    transa: CublasOperation, transb: CublasOperation,
    m: i32, n: i32, k: i32,
    alpha: *const anyopaque, // __half*
    A: *const anyopaque, lda: i32,
    B: *const anyopaque, ldb: i32,
    beta: *const anyopaque, // __half*
    C_ptr: *anyopaque, ldc: i32,
) cublasStatus_t {
    const f = @extern(*const fn (
        CublasHandle, CublasOperation, CublasOperation,
        i32, i32, i32, *const anyopaque,
        *const anyopaque, i32, *const anyopaque, i32,
        *const anyopaque, *anyopaque, i32,
    ) callconv(.c) cublasStatus_t, .{ .name = "cublasHgemm" });
    return f(handle, transa, transb, m, n, k, alpha, A, lda, B, ldb, beta, C_ptr, ldc);
}
fn cublasHgemmStub(
    _: CublasHandle, _: CublasOperation, _: CublasOperation,
    _: i32, _: i32, _: i32, _: *const anyopaque,
    _: *const anyopaque, _: i32, _: *const anyopaque, _: i32,
    _: *const anyopaque, _: *anyopaque, _: i32,
) cublasStatus_t {
    return .NOT_INITIALIZED;
}

// ============================================================================
// CUDA Module Management
// ============================================================================

/// Unload a CUDA module.
pub const cuModuleUnload = if (has_cuda) cuModuleUnloadReal else cuModuleUnloadStub;

fn cuModuleUnloadReal(module: CUmodule) CUresult {
    const f = @extern(*const fn (CUmodule) callconv(.c) CUresult, .{ .name = "cuModuleUnload" });
    return f(module);
}
fn cuModuleUnloadStub(_: CUmodule) CUresult {
    return .error_no_device;
}

/// Print device information to log
pub fn printDeviceInfo(info: *const CudaDeviceInfo) void {
    const log = std.log.scoped(.cuda_bindings);
    log.info("CUDA Device Information:", .{});
    log.info("  Name: {s}", .{info.getName()});
    log.info("  Architecture: {s}", .{info.getArchitecture()});
    log.info("  Compute Capability: {}.{}", .{ info.compute_capability_major, info.compute_capability_minor });
    log.info("  Total Memory: {} MB", .{info.total_global_mem / (1024 * 1024)});
    log.info("  Free Memory: {} MB", .{info.free_global_mem / (1024 * 1024)});
    log.info("  Multiprocessors: {}", .{info.multiprocessor_count});
    log.info("  Max Threads/Block: {}", .{info.max_threads_per_block});
    log.info("  Warp Size: {}", .{info.warp_size});
}

/// Get detailed device information from the CUDA driver API
pub fn getDeviceInfo(device_id: i32) !CudaDeviceInfo {
    var info = CudaDeviceInfo{ .device_id = device_id };

    if (comptime !has_cuda) {
        const fallback = "CPU (CUDA not available)";
        @memcpy(info.name[0..fallback.len], fallback);
        info.name_len = fallback.len;
        return info;
    }

    var device: CUdevice = undefined;
    if (cuDeviceGet(&device, @intCast(device_id)) != .success) return error.CudaError;

    // Device name
    if (cuDeviceGetName(&info.name, 256, device) == .success) {
        info.name_len = std.mem.indexOfScalar(u8, &info.name, 0) orelse 256;
    }

    // Memory (cuDeviceTotalMem is context-free; cuMemGetInfo needs a context
    // which CudaBackend creates later, so we skip free memory here)
    var total_mem: usize = 0;
    if (cuDeviceTotalMem(&total_mem, device) == .success) {
        info.total_global_mem = total_mem;
        info.total_memory = total_mem;
        info.free_global_mem = total_mem; // best estimate without context
        info.free_memory = total_mem;
    }

    // Compute capability
    var val: c_int = 0;
    if (cuDeviceGetAttribute(&val, .compute_capability_major, device) == .success)
        info.compute_capability_major = @intCast(val);
    if (cuDeviceGetAttribute(&val, .compute_capability_minor, device) == .success)
        info.compute_capability_minor = @intCast(val);

    // Multiprocessors
    const mp_attr: CUdevice_attribute = @enumFromInt(16); // CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT
    if (cuDeviceGetAttribute(&val, mp_attr, device) == .success)
        info.multiprocessor_count = @intCast(val);
    info.compute_units = @intCast(@max(info.multiprocessor_count, 0));

    // Max threads per block
    const mt_attr: CUdevice_attribute = @enumFromInt(1); // CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK
    if (cuDeviceGetAttribute(&val, mt_attr, device) == .success) {
        info.max_threads_per_block = @intCast(val);
        info.max_threads_per_group = @intCast(@max(val, 0));
    }

    // Warp size
    const ws_attr: CUdevice_attribute = @enumFromInt(10); // CU_DEVICE_ATTRIBUTE_WARP_SIZE
    if (cuDeviceGetAttribute(&val, ws_attr, device) == .success)
        info.warp_size = @intCast(val);

    // Unified addressing
    const ua_attr: CUdevice_attribute = @enumFromInt(41); // CU_DEVICE_ATTRIBUTE_UNIFIED_ADDRESSING
    if (cuDeviceGetAttribute(&val, ua_attr, device) == .success) {
        info.unified_addressing = val != 0;
        info.has_unified_memory = val != 0;
    }

    return info;
}