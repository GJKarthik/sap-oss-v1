
//! CUDA Native Bindings
//! This file provides the actual CUDA runtime API bindings
//! Only used in production builds (when linked with -lcudart)

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.cuda_bindings);

// ============================================================================
// CUDA Types
// ============================================================================

pub const CUdevice = c_int;
pub const CUcontext = *anyopaque;
pub const CUmodule = *anyopaque;
pub const CUfunction = *anyopaque;
pub const CUstream = *anyopaque;
pub const CUdeviceptr = u64;
pub const cudaStream_t = *anyopaque;

// ============================================================================
// CUDA Error Codes
// ============================================================================

pub const cudaError_t = enum(c_int) {
    cudaSuccess = 0,
    cudaErrorInvalidValue = 1,
    cudaErrorMemoryAllocation = 2,
    cudaErrorInitializationError = 3,
    cudaErrorCudartUnloading = 4,
    cudaErrorProfilerDisabled = 5,
    cudaErrorInvalidConfiguration = 9,
    cudaErrorInvalidPitchValue = 12,
    cudaErrorInvalidSymbol = 13,
    cudaErrorInvalidDevicePointer = 17,
    cudaErrorInvalidMemcpyDirection = 21,
    cudaErrorInsufficientDriver = 35,
    cudaErrorMissingConfiguration = 52,
    cudaErrorNoDevice = 100,
    cudaErrorInvalidDevice = 101,
    cudaErrorDeviceNotLicensed = 102,
    cudaErrorStartupFailure = 127,
    cudaErrorInvalidKernelImage = 200,
    cudaErrorUnknown = 999,
    _,
    
    pub fn isSuccess(self: cudaError_t) bool {
        return self == .cudaSuccess;
    }
    
    pub fn toString(self: cudaError_t) []const u8 {
        return switch (self) {
            .cudaSuccess => "Success",
            .cudaErrorInvalidValue => "Invalid value",
            .cudaErrorMemoryAllocation => "Memory allocation error",
            .cudaErrorInitializationError => "Initialization error",
            .cudaErrorNoDevice => "No CUDA device available",
            .cudaErrorInvalidDevice => "Invalid device",
            .cudaErrorInsufficientDriver => "Insufficient driver",
            else => "Unknown CUDA error",
        };
    }
};

// ============================================================================
// CUDA Device Properties Structure
// ============================================================================

pub const cudaDeviceProp = extern struct {
    name: [256]u8 = [_]u8{0} ** 256,
    uuid: [16]u8 = [_]u8{0} ** 16,
    luid: [8]u8 = [_]u8{0} ** 8,
    luidDeviceNodeMask: c_uint = 0,
    totalGlobalMem: usize = 0,
    sharedMemPerBlock: usize = 0,
    regsPerBlock: c_int = 0,
    warpSize: c_int = 0,
    memPitch: usize = 0,
    maxThreadsPerBlock: c_int = 0,
    maxThreadsDim: [3]c_int = [_]c_int{0} ** 3,
    maxGridSize: [3]c_int = [_]c_int{0} ** 3,
    clockRate: c_int = 0,
    totalConstMem: usize = 0,
    major: c_int = 0,
    minor: c_int = 0,
    textureAlignment: usize = 0,
    texturePitchAlignment: usize = 0,
    deviceOverlap: c_int = 0,
    multiProcessorCount: c_int = 0,
    kernelExecTimeoutEnabled: c_int = 0,
    integrated: c_int = 0,
    canMapHostMemory: c_int = 0,
    computeMode: c_int = 0,
    maxTexture1D: c_int = 0,
    maxTexture1DMipmap: c_int = 0,
    maxTexture1DLinear: c_int = 0,
    maxTexture2D: [2]c_int = [_]c_int{0} ** 2,
    maxTexture2DMipmap: [2]c_int = [_]c_int{0} ** 2,
    maxTexture2DLinear: [3]c_int = [_]c_int{0} ** 3,
    maxTexture2DGather: [2]c_int = [_]c_int{0} ** 2,
    maxTexture3D: [3]c_int = [_]c_int{0} ** 3,
    maxTexture3DAlt: [3]c_int = [_]c_int{0} ** 3,
    maxTextureCubemap: c_int = 0,
    maxTexture1DLayered: [2]c_int = [_]c_int{0} ** 2,
    maxTexture2DLayered: [3]c_int = [_]c_int{0} ** 3,
    maxTextureCubemapLayered: [2]c_int = [_]c_int{0} ** 2,
    maxSurface1D: c_int = 0,
    maxSurface2D: [2]c_int = [_]c_int{0} ** 2,
    maxSurface3D: [3]c_int = [_]c_int{0} ** 3,
    maxSurface1DLayered: [2]c_int = [_]c_int{0} ** 2,
    maxSurface2DLayered: [3]c_int = [_]c_int{0} ** 3,
    maxSurfaceCubemap: c_int = 0,
    maxSurfaceCubemapLayered: [2]c_int = [_]c_int{0} ** 2,
    surfaceAlignment: usize = 0,
    concurrentKernels: c_int = 0,
    ECCEnabled: c_int = 0,
    pciBusID: c_int = 0,
    pciDeviceID: c_int = 0,
    pciDomainID: c_int = 0,
    tccDriver: c_int = 0,
    asyncEngineCount: c_int = 0,
    unifiedAddressing: c_int = 0,
    memoryClockRate: c_int = 0,
    memoryBusWidth: c_int = 0,
    l2CacheSize: c_int = 0,
    persistingL2CacheMaxSize: c_int = 0,
    maxThreadsPerMultiProcessor: c_int = 0,
    streamPrioritiesSupported: c_int = 0,
    globalL1CacheSupported: c_int = 0,
    localL1CacheSupported: c_int = 0,
    sharedMemPerMultiprocessor: usize = 0,
    regsPerMultiprocessor: c_int = 0,
    managedMemory: c_int = 0,
    isMultiGpuBoard: c_int = 0,
    multiGpuBoardGroupID: c_int = 0,
    hostNativeAtomicSupported: c_int = 0,
    singleToDoublePrecisionPerfRatio: c_int = 0,
    pageableMemoryAccess: c_int = 0,
    concurrentManagedAccess: c_int = 0,
    computePreemptionSupported: c_int = 0,
    canUseHostPointerForRegisteredMem: c_int = 0,
    cooperativeLaunch: c_int = 0,
    cooperativeMultiDeviceLaunch: c_int = 0,
    sharedMemPerBlockOptin: usize = 0,
    pageableMemoryAccessUsesHostPageTables: c_int = 0,
    directManagedMemAccessFromHost: c_int = 0,
    maxBlocksPerMultiProcessor: c_int = 0,
    accessPolicyMaxWindowSize: c_int = 0,
    reservedSharedMemPerBlock: usize = 0,
    hostRegisterSupported: c_int = 0,
    sparseCudaArraySupported: c_int = 0,
    hostRegisterReadOnlySupported: c_int = 0,
    timelineSemaphoreInteropSupported: c_int = 0,
    memoryPoolsSupported: c_int = 0,
    gpuDirectRDMASupported: c_int = 0,
    gpuDirectRDMAFlushWritesOptions: c_uint = 0,
    gpuDirectRDMAWritesOrdering: c_int = 0,
    memoryPoolSupportedHandleTypes: c_uint = 0,
    deferredMappingCudaArraySupported: c_int = 0,
    ipcEventSupported: c_int = 0,
    clusterLaunch: c_int = 0,
    unifiedFunctionPointers: c_int = 0,
    reserved2: [2]c_int = [_]c_int{0} ** 2,
    reserved1: [1]c_int = [_]c_int{0} ** 1,
    reserved: [60]c_int = [_]c_int{0} ** 60,
};

// ============================================================================
// CUDA Memory Info
// ============================================================================

pub const CudaMemInfo = struct {
    free: usize,
    total: usize,
};

// ============================================================================
// External CUDA Runtime API Declarations
// ============================================================================

// Only declare externals on Linux where CUDA is typically available
const cuda_available = builtin.os.tag == .linux and !builtin.is_test;

extern "c" fn cudaGetDeviceCount(count: *c_int) cudaError_t;
extern "c" fn cudaGetDeviceProperties(prop: *cudaDeviceProp, device: c_int) cudaError_t;
extern "c" fn cudaSetDevice(device: c_int) cudaError_t;
extern "c" fn cudaGetDevice(device: *c_int) cudaError_t;
extern "c" fn cudaDeviceReset() cudaError_t;
extern "c" fn cudaDeviceSynchronize() cudaError_t;
extern "c" fn cudaMemGetInfo(free: *usize, total: *usize) cudaError_t;
extern "c" fn cudaMalloc(devPtr: *CUdeviceptr, size: usize) cudaError_t;
extern "c" fn cudaFree(devPtr: CUdeviceptr) cudaError_t;
extern "c" fn cudaMemcpy(dst: *anyopaque, src: *const anyopaque, count: usize, kind: cudaMemcpyKind) cudaError_t;
extern "c" fn cudaMemcpyAsync(dst: *anyopaque, src: *const anyopaque, count: usize, kind: cudaMemcpyKind, stream: cudaStream_t) cudaError_t;
extern "c" fn cudaStreamCreate(pStream: *cudaStream_t) cudaError_t;
extern "c" fn cudaStreamDestroy(stream: cudaStream_t) cudaError_t;
extern "c" fn cudaStreamSynchronize(stream: cudaStream_t) cudaError_t;
extern "c" fn cudaGetErrorString(err: cudaError_t) [*:0]const u8;
extern "c" fn cudaDriverGetVersion(driverVersion: *c_int) cudaError_t;
extern "c" fn cudaRuntimeGetVersion(runtimeVersion: *c_int) cudaError_t;

pub const cudaMemcpyKind = enum(c_int) {
    cudaMemcpyHostToHost = 0,
    cudaMemcpyHostToDevice = 1,
    cudaMemcpyDeviceToHost = 2,
    cudaMemcpyDeviceToDevice = 3,
    cudaMemcpyDefault = 4,
};

// ============================================================================
// High-Level Device Information Structure
// ============================================================================

pub const CudaDeviceInfo = struct {
    name: [256]u8 = [_]u8{0} ** 256,
    name_len: usize = 0,
    
    // Device identification
    device_id: c_int = 0,
    pci_bus_id: c_int = 0,
    pci_device_id: c_int = 0,
    pci_domain_id: c_int = 0,
    
    // Memory
    total_global_mem: usize = 0,
    free_global_mem: usize = 0,
    shared_mem_per_block: usize = 0,
    shared_mem_per_multiprocessor: usize = 0,
    l2_cache_size: c_int = 0,
    
    // Compute capability
    compute_capability_major: c_int = 0,
    compute_capability_minor: c_int = 0,
    
    // Processing units
    multiprocessor_count: c_int = 0,
    max_threads_per_block: c_int = 0,
    max_threads_per_multiprocessor: c_int = 0,
    warp_size: c_int = 0,
    
    // Clocks
    clock_rate_khz: c_int = 0,
    memory_clock_rate_khz: c_int = 0,
    memory_bus_width: c_int = 0,
    
    // Features
    concurrent_kernels: bool = false,
    ecc_enabled: bool = false,
    unified_addressing: bool = false,
    managed_memory: bool = false,
    cooperative_launch: bool = false,
    
    // Driver info
    driver_version: c_int = 0,
    runtime_version: c_int = 0,
    
    pub fn getName(self: *const CudaDeviceInfo) []const u8 {
        return self.name[0..self.name_len];
    }
    
    pub fn getComputeCapability(self: *const CudaDeviceInfo) f32 {
        return @as(f32, @floatFromInt(self.compute_capability_major)) + 
               @as(f32, @floatFromInt(self.compute_capability_minor)) / 10.0;
    }
    
    pub fn getArchitectureName(self: *const CudaDeviceInfo) []const u8 {
        return switch (self.compute_capability_major) {
            9 => "Hopper",
            8 => if (self.compute_capability_minor >= 9) "Ada Lovelace" else "Ampere",
            7 => if (self.compute_capability_minor >= 5) "Turing" else "Volta",
            6 => "Pascal",
            5 => "Maxwell",
            else => "Unknown",
        };
    }
    
    /// Calculate theoretical TFLOPS (FP32)
    pub fn getTheoreticalTflops(self: *const CudaDeviceInfo) f32 {
        // CUDA cores per SM varies by architecture
        const cores_per_sm: c_int = switch (self.compute_capability_major) {
            9 => 128, // Hopper
            8 => 128, // Ampere/Ada
            7 => if (self.compute_capability_minor >= 5) @as(c_int, 64) else @as(c_int, 64), // Turing/Volta
            6 => 64,  // Pascal
            else => 32,
        };
        
        const total_cores = self.multiprocessor_count * cores_per_sm;
        const clock_ghz = @as(f32, @floatFromInt(self.clock_rate_khz)) / 1_000_000.0;
        
        // TFLOPS = cores * clock * 2 (FMA) / 1000
        return @as(f32, @floatFromInt(total_cores)) * clock_ghz * 2.0 / 1000.0;
    }
};

// ============================================================================
// CUDA Device Query Functions
// ============================================================================

/// Check if CUDA is available on this system
pub fn isCudaAvailable() bool {
    if (comptime !cuda_available) return false;
    
    var count: c_int = 0;
    const err = cudaGetDeviceCount(&count);
    return err.isSuccess() and count > 0;
}

/// Get the number of CUDA devices
pub fn getDeviceCount() !c_int {
    if (comptime !cuda_available) return 0;
    
    var count: c_int = 0;
    const err = cudaGetDeviceCount(&count);
    if (!err.isSuccess()) {
        log.err("cudaGetDeviceCount failed: {s}", .{err.toString()});
        return error.CudaError;
    }
    return count;
}

/// Get detailed device information
pub fn getDeviceInfo(device_id: c_int) !CudaDeviceInfo {
    var info = CudaDeviceInfo{};
    
    if (comptime !cuda_available) {
        const fallback = "CPU (CUDA not available)";
        @memcpy(info.name[0..fallback.len], fallback);
        info.name_len = fallback.len;
        return info;
    }
    
    info.device_id = device_id;
    
    // Get device properties
    var props = cudaDeviceProp{};
    var err = cudaGetDeviceProperties(&props, device_id);
    if (!err.isSuccess()) {
        log.err("cudaGetDeviceProperties failed: {s}", .{err.toString()});
        return error.CudaError;
    }
    
    // Copy name
    const name_len = std.mem.indexOfScalar(u8, &props.name, 0) orelse props.name.len;
    @memcpy(info.name[0..name_len], props.name[0..name_len]);
    info.name_len = name_len;
    
    // PCI info
    info.pci_bus_id = props.pciBusID;
    info.pci_device_id = props.pciDeviceID;
    info.pci_domain_id = props.pciDomainID;
    
    // Memory
    info.total_global_mem = props.totalGlobalMem;
    info.shared_mem_per_block = props.sharedMemPerBlock;
    info.shared_mem_per_multiprocessor = props.sharedMemPerMultiprocessor;
    info.l2_cache_size = props.l2CacheSize;
    
    // Compute capability
    info.compute_capability_major = props.major;
    info.compute_capability_minor = props.minor;
    
    // Processing units
    info.multiprocessor_count = props.multiProcessorCount;
    info.max_threads_per_block = props.maxThreadsPerBlock;
    info.max_threads_per_multiprocessor = props.maxThreadsPerMultiProcessor;
    info.warp_size = props.warpSize;
    
    // Clocks
    info.clock_rate_khz = props.clockRate;
    info.memory_clock_rate_khz = props.memoryClockRate;
    info.memory_bus_width = props.memoryBusWidth;
    
    // Features
    info.concurrent_kernels = props.concurrentKernels != 0;
    info.ecc_enabled = props.ECCEnabled != 0;
    info.unified_addressing = props.unifiedAddressing != 0;
    info.managed_memory = props.managedMemory != 0;
    info.cooperative_launch = props.cooperativeLaunch != 0;
    
    // Get memory info (requires setting device first)
    err = cudaSetDevice(device_id);
    if (err.isSuccess()) {
        var free_mem: usize = 0;
        var total_mem: usize = 0;
        err = cudaMemGetInfo(&free_mem, &total_mem);
        if (err.isSuccess()) {
            info.free_global_mem = free_mem;
        }
    }
    
    // Driver/Runtime versions
    _ = cudaDriverGetVersion(&info.driver_version);
    _ = cudaRuntimeGetVersion(&info.runtime_version);
    
    return info;
}

/// Set the current CUDA device
pub fn setDevice(device_id: c_int) !void {
    if (comptime !cuda_available) return;
    
    const err = cudaSetDevice(device_id);
    if (!err.isSuccess()) {
        log.err("cudaSetDevice({}) failed: {s}", .{ device_id, err.toString() });
        return error.CudaError;
    }
}

/// Get the current CUDA device
pub fn getCurrentDevice() !c_int {
    if (comptime !cuda_available) return 0;
    
    var device: c_int = 0;
    const err = cudaGetDevice(&device);
    if (!err.isSuccess()) {
        return error.CudaError;
    }
    return device;
}

/// Synchronize the current device
pub fn deviceSynchronize() !void {
    if (comptime !cuda_available) return;
    
    const err = cudaDeviceSynchronize();
    if (!err.isSuccess()) {
        log.err("cudaDeviceSynchronize failed: {s}", .{err.toString()});
        return error.CudaError;
    }
}

/// Reset the current device
pub fn deviceReset() !void {
    if (comptime !cuda_available) return;
    
    const err = cudaDeviceReset();
    if (!err.isSuccess()) {
        log.err("cudaDeviceReset failed: {s}", .{err.toString()});
        return error.CudaError;
    }
}

/// Get memory information for the current device
pub fn getMemInfo() !CudaMemInfo {
    if (comptime !cuda_available) return CudaMemInfo{ .free = 0, .total = 0 };
    
    var free_mem: usize = 0;
    var total_mem: usize = 0;
    const err = cudaMemGetInfo(&free_mem, &total_mem);
    if (!err.isSuccess()) {
        return error.CudaError;
    }
    return CudaMemInfo{ .free = free_mem, .total = total_mem };
}

// ============================================================================
// CUDA Memory Management
// ============================================================================

/// Allocate device memory
pub fn malloc(size: usize) !CUdeviceptr {
    if (comptime !cuda_available) return 0;
    
    var ptr: CUdeviceptr = 0;
    const err = cudaMalloc(&ptr, size);
    if (!err.isSuccess()) {
        log.err("cudaMalloc({}) failed: {s}", .{ size, err.toString() });
        return error.CudaError;
    }
    return ptr;
}

/// Free device memory
pub fn free(ptr: CUdeviceptr) void {
    if (comptime !cuda_available) return;
    
    const err = cudaFree(ptr);
    if (!err.isSuccess()) {
        log.warn("cudaFree failed: {s}", .{err.toString()});
    }
}

/// Copy memory from host to device
pub fn memcpyHostToDevice(dst: CUdeviceptr, src: []const u8) !void {
    if (comptime !cuda_available) return;
    
    const err = cudaMemcpy(@ptrFromInt(dst), src.ptr, src.len, .cudaMemcpyHostToDevice);
    if (!err.isSuccess()) {
        return error.CudaError;
    }
}

/// Copy memory from device to host
pub fn memcpyDeviceToHost(dst: []u8, src: CUdeviceptr) !void {
    if (comptime !cuda_available) return;
    
    const err = cudaMemcpy(dst.ptr, @ptrFromInt(src), dst.len, .cudaMemcpyDeviceToHost);
    if (!err.isSuccess()) {
        return error.CudaError;
    }
}

// ============================================================================
// CUDA Stream Management
// ============================================================================

/// Create a CUDA stream
pub fn createStream() !cudaStream_t {
    if (comptime !cuda_available) return @ptrFromInt(0);
    
    var stream: cudaStream_t = undefined;
    const err = cudaStreamCreate(&stream);
    if (!err.isSuccess()) {
        return error.CudaError;
    }
    return stream;
}

/// Destroy a CUDA stream
pub fn destroyStream(stream: cudaStream_t) void {
    if (comptime !cuda_available) return;
    
    _ = cudaStreamDestroy(stream);
}

/// Synchronize a CUDA stream
pub fn streamSynchronize(stream: cudaStream_t) !void {
    if (comptime !cuda_available) return;
    
    const err = cudaStreamSynchronize(stream);
    if (!err.isSuccess()) {
        return error.CudaError;
    }
}

// ============================================================================
// Utility: Print Device Info
// ============================================================================

pub fn printDeviceInfo(info: *const CudaDeviceInfo) void {
    log.info("CUDA Device Information:", .{});
    log.info("  Name: {s}", .{info.getName()});
    log.info("  Architecture: {s}", .{info.getArchitectureName()});
    log.info("  Compute Capability: {}.{}", .{ info.compute_capability_major, info.compute_capability_minor });
    log.info("  Total Memory: {} MB", .{info.total_global_mem / (1024 * 1024)});
    log.info("  Free Memory: {} MB", .{info.free_global_mem / (1024 * 1024)});
    log.info("  Multiprocessors: {}", .{info.multiprocessor_count});
    log.info("  Max Threads/Block: {}", .{info.max_threads_per_block});
    log.info("  Warp Size: {}", .{info.warp_size});
    log.info("  Clock Rate: {} MHz", .{@divTrunc(info.clock_rate_khz, 1000)});
    log.info("  Memory Clock: {} MHz", .{@divTrunc(info.memory_clock_rate_khz, 1000)});
    log.info("  Memory Bus Width: {} bits", .{info.memory_bus_width});
    log.info("  L2 Cache: {} KB", .{@divTrunc(info.l2_cache_size, 1024)});
    log.info("  Theoretical TFLOPS (FP32): {d:.2}", .{info.getTheoreticalTflops()});
    log.info("  ECC: {}", .{info.ecc_enabled});
    log.info("  Unified Addressing: {}", .{info.unified_addressing});
    log.info("  Driver Version: {}.{}", .{ @divTrunc(info.driver_version, 1000), @divTrunc(@mod(info.driver_version, 1000), 10) });
    log.info("  Runtime Version: {}.{}", .{ @divTrunc(info.runtime_version, 1000), @divTrunc(@mod(info.runtime_version, 1000), 10) });
    log.info("  PCI: {x:0>4}:{x:0>2}:{x:0>2}", .{ info.pci_domain_id, info.pci_bus_id, info.pci_device_id });
}

// ============================================================================
// Tests
// ============================================================================

test "CudaDeviceInfo structure" {
    var info = CudaDeviceInfo{};
    const test_name = "Test GPU";
    @memcpy(info.name[0..test_name.len], test_name);
    info.name_len = test_name.len;
    
    try std.testing.expectEqualStrings("Test GPU", info.getName());
}

test "getComputeCapability calculation" {
    var info = CudaDeviceInfo{};
    info.compute_capability_major = 8;
    info.compute_capability_minor = 6;
    
    try std.testing.expectApproxEqAbs(@as(f32, 8.6), info.getComputeCapability(), 0.01);
}

test "getArchitectureName returns correct strings" {
    var info = CudaDeviceInfo{};
    
    info.compute_capability_major = 9;
    try std.testing.expectEqualStrings("Hopper", info.getArchitectureName());
    
    info.compute_capability_major = 8;
    info.compute_capability_minor = 9;
    try std.testing.expectEqualStrings("Ada Lovelace", info.getArchitectureName());
    
    info.compute_capability_major = 8;
    info.compute_capability_minor = 0;
    try std.testing.expectEqualStrings("Ampere", info.getArchitectureName());
    
    info.compute_capability_major = 7;
    info.compute_capability_minor = 5;
    try std.testing.expectEqualStrings("Turing", info.getArchitectureName());
}

test "cudaError_t toString" {
    try std.testing.expectEqualStrings("Success", cudaError_t.cudaSuccess.toString());
    try std.testing.expectEqualStrings("No CUDA device available", cudaError_t.cudaErrorNoDevice.toString());
}

test "isCudaAvailable returns false in tests" {
    // In test mode, CUDA should not be available (we don't link against cudart)
    const available = isCudaAvailable();
    try std.testing.expect(!available);
}