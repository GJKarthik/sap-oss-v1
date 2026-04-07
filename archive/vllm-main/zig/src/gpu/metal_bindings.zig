//! Metal Native Bindings
//! Provides Metal framework bindings via Objective-C runtime
//! Only used in production builds (when linked with -framework Metal)

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.metal_bindings);

// ============================================================================
// Metal Opaque Types
// ============================================================================

pub const MTLDevice = *anyopaque;
pub const MTLCommandQueue = *anyopaque;
pub const MTLBuffer = *anyopaque;
pub const MTLLibrary = *anyopaque;
pub const MTLFunction = *anyopaque;
pub const MTLComputePipelineState = *anyopaque;
pub const MTLCommandBuffer = *anyopaque;
pub const MTLComputeCommandEncoder = *anyopaque;
pub const MTLBlitCommandEncoder = *anyopaque;
pub const NSString = *anyopaque;
pub const NSError = *anyopaque;
pub const NSArray = *anyopaque;

// ============================================================================
// Objective-C Runtime Types
// ============================================================================

pub const SEL = *anyopaque;
pub const Class = *anyopaque;
pub const id = *anyopaque;
pub const BOOL = i8;
pub const NSUInteger = usize;
pub const NSInteger = isize;

// ============================================================================
// Metal Resource Options
// ============================================================================

pub const MTLResourceStorageModeShared: u64 = 0;
pub const MTLResourceStorageModeManaged: u64 = 1 << 4;
pub const MTLResourceStorageModePrivate: u64 = 2 << 4;
pub const MTLResourceCPUCacheModeDefaultCache: u64 = 0;
pub const MTLResourceHazardTrackingModeDefault: u64 = 0;

// ============================================================================
// External Function Declarations
// ============================================================================

extern "c" fn MTLCreateSystemDefaultDevice() ?MTLDevice;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "c" fn objc_msgSend() void;

// ============================================================================
// Objective-C Message Send Wrappers
// ============================================================================

fn msgSend_id(target: anytype, sel: SEL) ?id {
    const FnType = *const fn (@TypeOf(target), SEL) callconv(.c) ?id;
    const func: FnType = @ptrCast(&objc_msgSend);
    return func(target, sel);
}

fn msgSend_u64(target: anytype, sel: SEL) u64 {
    const FnType = *const fn (@TypeOf(target), SEL) callconv(.c) u64;
    const func: FnType = @ptrCast(&objc_msgSend);
    return func(target, sel);
}

// ============================================================================
// Metal Device Functions
// ============================================================================

pub fn getDevice() ?MTLDevice {
    if (comptime builtin.os.tag != .macos) return null;
    if (comptime builtin.is_test) return null;
    return MTLCreateSystemDefaultDevice();
}

// ============================================================================
// Command Queue Functions
// ============================================================================

pub fn createCommandQueue(device: MTLDevice) ?MTLCommandQueue {
    if (comptime builtin.os.tag != .macos) return null;
    const sel = sel_registerName("newCommandQueue");
    return msgSend_id(device, sel);
}

pub const MetalDeviceInfo = struct {
    name: [256]u8,
    name_len: usize,
    recommended_max_working_set_size: usize,
    has_unified_memory: bool,
    max_threads_per_threadgroup: u32,
    supports_apple_family: u8,
    supports_metal3: bool,

    pub fn getName(self: *const MetalDeviceInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getAppleFamilyName(self: *const MetalDeviceInfo) []const u8 {
        return switch (self.supports_apple_family) {
            9 => "Apple9",
            8 => "Apple8",
            7 => "Apple7",
            6 => "Apple6",
            5 => "Apple5",
            4 => "Apple4",
            3 => "Apple3",
            2 => "Apple2",
            1 => "Apple1",
            else => "AppleGPU",
        };
    }
};

pub fn getDeviceInfo(device: MTLDevice) MetalDeviceInfo {
    var info = MetalDeviceInfo{
        .name = [_]u8{0} ** 256,
        .name_len = 0,
        .recommended_max_working_set_size = 0,
        .has_unified_memory = true,
        .max_threads_per_threadgroup = 1024,
        .supports_apple_family = 0,
        .supports_metal3 = false,
    };

    const fallback_name = "Apple Metal";
    @memcpy(info.name[0..fallback_name.len], fallback_name);
    info.name_len = fallback_name.len;

    if (comptime builtin.os.tag != .macos or builtin.is_test) {
        info.recommended_max_working_set_size = 8 * 1024 * 1024 * 1024;
        return info;
    }

    // Device name: [device name] -> NSString -> UTF8String
    const sel_name = sel_registerName("name");
    if (msgSend_id(device, sel_name)) |ns_name| {
        const sel_utf8 = sel_registerName("UTF8String");
        const Utf8Fn = *const fn (id, SEL) callconv(.c) ?[*:0]const u8;
        const utf8_fn: Utf8Fn = @ptrCast(&objc_msgSend);
        if (utf8_fn(ns_name, sel_utf8)) |cstr| {
            const bytes = std.mem.span(cstr);
            if (bytes.len > 0) {
                const n = @min(bytes.len, info.name.len);
                @memset(info.name[0..], 0);
                @memcpy(info.name[0..n], bytes[0..n]);
                info.name_len = n;
            }
        }
    }

    // recommendedMaxWorkingSetSize (bytes)
    const sel_working_set = sel_registerName("recommendedMaxWorkingSetSize");
    const working_set = msgSend_u64(device, sel_working_set);
    info.recommended_max_working_set_size = if (working_set > 0)
        @intCast(working_set)
    else
        (8 * 1024 * 1024 * 1024);

    // hasUnifiedMemory
    const sel_unified = sel_registerName("hasUnifiedMemory");
    const BoolFn = *const fn (MTLDevice, SEL) callconv(.c) BOOL;
    const bool_fn: BoolFn = @ptrCast(&objc_msgSend);
    info.has_unified_memory = bool_fn(device, sel_unified) != 0;

    // maxThreadsPerThreadgroup (MTLSize)
    const sel_max_threads = sel_registerName("maxThreadsPerThreadgroup");
    const ThreadsFn = *const fn (MTLDevice, SEL) callconv(.c) MTLSize;
    const threads_fn: ThreadsFn = @ptrCast(&objc_msgSend);
    const max_threads = threads_fn(device, sel_max_threads);
    const total_threads = max_threads.width * max_threads.height * max_threads.depth;
    info.max_threads_per_threadgroup = if (total_threads > std.math.maxInt(u32))
        std.math.maxInt(u32)
    else if (total_threads > 0)
        @intCast(total_threads)
    else
        1024;

    // supportsFamily: (highest Apple GPU family supported)
    const sel_supports_family = sel_registerName("supportsFamily:");
    const SupportsFamilyFn = *const fn (MTLDevice, SEL, NSUInteger) callconv(.c) BOOL;
    const supports_family_fn: SupportsFamilyFn = @ptrCast(&objc_msgSend);
    for ([_]usize{ 9, 8, 7, 6, 5, 4, 3, 2, 1 }) |family| {
        if (supports_family_fn(device, sel_supports_family, family) != 0) {
            info.supports_apple_family = @intCast(family);
            break;
        }
    }
    info.supports_metal3 = info.supports_apple_family >= 7;

    return info;
}

pub fn printDeviceInfo(info: *const MetalDeviceInfo) void {
    log.info("Metal Device Info:", .{});
    log.info("  Name: {s}", .{info.getName()});
    log.info("  Recommended Working Set: {} MB", .{info.recommended_max_working_set_size / (1024 * 1024)});
    log.info("  Unified Memory: {}", .{info.has_unified_memory});
    log.info("  Max Threads/Threadgroup: {}", .{info.max_threads_per_threadgroup});
    log.info("  Apple GPU Family: {}", .{info.supports_apple_family});
    log.info("  Metal 3: {}", .{info.supports_metal3});
}

// ============================================================================
// Buffer Functions
// ============================================================================

pub fn createSharedBuffer(device: MTLDevice, size: u64) ?MTLBuffer {
    if (comptime builtin.os.tag != .macos) return null;
    const sel = sel_registerName("newBufferWithLength:options:");
    const FnType = *const fn (MTLDevice, SEL, u64, u64) callconv(.c) ?MTLBuffer;
    const func: FnType = @ptrCast(&objc_msgSend);
    return func(device, sel, size, MTLResourceStorageModeShared);
}

pub fn createBufferWithBytes(device: MTLDevice, data: []const u8, options: u64) ?MTLBuffer {
    if (comptime builtin.os.tag != .macos) return null;
    const sel = sel_registerName("newBufferWithBytes:length:options:");
    const FnType = *const fn (MTLDevice, SEL, [*]const u8, u64, u64) callconv(.c) ?MTLBuffer;
    const func: FnType = @ptrCast(&objc_msgSend);
    return func(device, sel, data.ptr, data.len, options);
}

pub fn getBufferContents(buffer: MTLBuffer) ?*anyopaque {
    if (comptime builtin.os.tag != .macos) return null;
    const sel = sel_registerName("contents");
    const FnType = *const fn (MTLBuffer, SEL) callconv(.c) ?*anyopaque;
    const func: FnType = @ptrCast(&objc_msgSend);
    return func(buffer, sel);
}

pub fn release(obj: anytype) void {
    if (comptime builtin.os.tag != .macos) return;
    if (comptime builtin.is_test) return;
    const sel = sel_registerName("release");
    const FnType = *const fn (@TypeOf(obj), SEL) callconv(.c) void;
    const func: FnType = @ptrCast(&objc_msgSend);
    func(obj, sel);
}

// ============================================================================
// Command Buffer Functions
// ============================================================================

pub fn createCommandBuffer(queue: MTLCommandQueue) ?MTLCommandBuffer {
    if (comptime builtin.os.tag != .macos) return null;
    const sel = sel_registerName("commandBuffer");
    return msgSend_id(queue, sel);
}

pub fn commitCommandBuffer(cmd_buffer: MTLCommandBuffer) void {
    if (comptime builtin.os.tag != .macos) return;
    const sel = sel_registerName("commit");
    const FnType = *const fn (MTLCommandBuffer, SEL) callconv(.c) void;
    const func: FnType = @ptrCast(&objc_msgSend);
    func(cmd_buffer, sel);
}

pub fn waitUntilCompleted(buffer: MTLCommandBuffer) void {
    if (comptime builtin.os.tag != .macos) return;
    const sel = sel_registerName("waitUntilCompleted");
    const FnType = *const fn (MTLCommandBuffer, SEL) callconv(.c) void;
    const func: FnType = @ptrCast(&objc_msgSend);
    func(buffer, sel);
}

// ============================================================================
// Compute Encoder Functions
// ============================================================================

pub fn createComputeCommandEncoder(buffer: MTLCommandBuffer) ?MTLComputeCommandEncoder {
    if (comptime builtin.os.tag != .macos) return null;
    const sel = sel_registerName("computeCommandEncoder");
    return msgSend_id(buffer, sel);
}

pub fn endEncoding(encoder: anytype) void {
    if (comptime builtin.os.tag != .macos) return;
    const sel = sel_registerName("endEncoding");
    const FnType = *const fn (@TypeOf(encoder), SEL) callconv(.c) void;
    const func: FnType = @ptrCast(&objc_msgSend);
    func(encoder, sel);
}

// ============================================================================
// Library Functions
// ============================================================================

pub fn newLibraryWithFile(device: MTLDevice, path: []const u8) ?MTLLibrary {
    if (comptime builtin.os.tag != .macos) return null;

    const sel_alloc = sel_registerName("alloc");
    const sel_initWithBytes = sel_registerName("initWithBytes:length:encoding:");

    const NSStringClass = objc_getClass("NSString") orelse return null;
    const AllocFn = *const fn (@TypeOf(NSStringClass), SEL) callconv(.c) ?NSString;
    const alloc_fn: AllocFn = @ptrCast(&objc_msgSend);
    const ns_str_raw = alloc_fn(NSStringClass, sel_alloc) orelse return null;

    const InitFn = *const fn (NSString, SEL, [*]const u8, u64, u64) callconv(.c) ?NSString;
    const init_fn: InitFn = @ptrCast(&objc_msgSend);
    const ns_path = init_fn(ns_str_raw, sel_initWithBytes, path.ptr, path.len, 4) orelse return null;

    const NSURLClass = objc_getClass("NSURL") orelse return null;
    const sel_fileURL = sel_registerName("fileURLWithPath:");
    const URLFn = *const fn (@TypeOf(NSURLClass), SEL, NSString) callconv(.c) ?*anyopaque;
    const url_fn: URLFn = @ptrCast(&objc_msgSend);
    const ns_url = url_fn(NSURLClass, sel_fileURL, ns_path) orelse return null;

    const sel_lib = sel_registerName("newLibraryWithURL:error:");
    const LibFn = *const fn (MTLDevice, SEL, *anyopaque, ?*?NSError) callconv(.c) ?MTLLibrary;
    const lib_fn: LibFn = @ptrCast(&objc_msgSend);
    var err_ptr: ?NSError = null;
    return lib_fn(device, sel_lib, ns_url, &err_ptr);
}

pub fn newFunctionWithName(library: MTLLibrary, name: []const u8) ?MTLFunction {
    if (comptime builtin.os.tag != .macos) return null;

    const NSStringClass = objc_getClass("NSString") orelse return null;
    const sel_alloc = sel_registerName("alloc");
    const AllocFn = *const fn (@TypeOf(NSStringClass), SEL) callconv(.c) ?NSString;
    const alloc_fn: AllocFn = @ptrCast(&objc_msgSend);
    const ns_str_raw = alloc_fn(NSStringClass, sel_alloc) orelse return null;

    const sel_initWithBytes = sel_registerName("initWithBytes:length:encoding:");
    const InitFn = *const fn (NSString, SEL, [*]const u8, u64, u64) callconv(.c) ?NSString;
    const init_fn: InitFn = @ptrCast(&objc_msgSend);
    const ns_name = init_fn(ns_str_raw, sel_initWithBytes, name.ptr, name.len, 4) orelse return null;

    const sel_func = sel_registerName("newFunctionWithName:");
    const FuncFn = *const fn (MTLLibrary, SEL, NSString) callconv(.c) ?MTLFunction;
    const func_fn: FuncFn = @ptrCast(&objc_msgSend);
    return func_fn(library, sel_func, ns_name);
}

pub fn newComputePipelineStateWithFunction(device: MTLDevice, function: MTLFunction) ?MTLComputePipelineState {
    if (comptime builtin.os.tag != .macos) return null;

    const sel = sel_registerName("newComputePipelineStateWithFunction:error:");
    const FnType = *const fn (MTLDevice, SEL, MTLFunction, ?*?NSError) callconv(.c) ?MTLComputePipelineState;
    const func: FnType = @ptrCast(&objc_msgSend);
    var err_ptr: ?NSError = null;
    return func(device, sel, function, &err_ptr);
}

// ============================================================================
// Pipeline State / Dispatch Functions
// ============================================================================

pub const MTLSize = extern struct {
    width: usize,
    height: usize,
    depth: usize,
};

pub fn setComputePipelineState(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState) void {
    if (comptime builtin.os.tag != .macos) return;
    const sel = sel_registerName("setComputePipelineState:");
    const FnType = *const fn (MTLComputeCommandEncoder, SEL, MTLComputePipelineState) callconv(.c) void;
    const func: FnType = @ptrCast(&objc_msgSend);
    func(encoder, sel, pipeline);
}

pub fn setBuffer(encoder: MTLComputeCommandEncoder, buffer: MTLBuffer, offset: u64, index: u32) void {
    if (comptime builtin.os.tag != .macos) return;
    const sel = sel_registerName("setBuffer:offset:atIndex:");
    const FnType = *const fn (MTLComputeCommandEncoder, SEL, MTLBuffer, u64, u64) callconv(.c) void;
    const func: FnType = @ptrCast(&objc_msgSend);
    func(encoder, sel, buffer, offset, @as(u64, index));
}

pub fn setBytes(encoder: MTLComputeCommandEncoder, ptr: *const anyopaque, len: usize, index: u32) void {
    if (comptime builtin.os.tag != .macos) return;
    const sel = sel_registerName("setBytes:length:atIndex:");
    const FnType = *const fn (MTLComputeCommandEncoder, SEL, *const anyopaque, u64, u64) callconv(.c) void;
    const func: FnType = @ptrCast(&objc_msgSend);
    func(encoder, sel, ptr, @as(u64, len), @as(u64, index));
}

pub fn dispatchThreadgroups(encoder: MTLComputeCommandEncoder, grid: MTLSize, threadgroup: MTLSize) void {
    if (comptime builtin.os.tag != .macos) return;
    const sel = sel_registerName("dispatchThreadgroups:threadsPerThreadgroup:");
    const FnType = *const fn (MTLComputeCommandEncoder, SEL, MTLSize, MTLSize) callconv(.c) void;
    const func: FnType = @ptrCast(&objc_msgSend);
    func(encoder, sel, grid, threadgroup);
}

// ============================================================================
// Tests
// ============================================================================

test "MTLSize structure" {
    const size = MTLSize{ .width = 256, .height = 1, .depth = 1 };
    try std.testing.expectEqual(@as(usize, 256), size.width);
}

test "resource storage mode constants" {
    try std.testing.expectEqual(@as(u64, 0), MTLResourceStorageModeShared);
    try std.testing.expectEqual(@as(u64, 16), MTLResourceStorageModeManaged);
    try std.testing.expectEqual(@as(u64, 32), MTLResourceStorageModePrivate);
}
