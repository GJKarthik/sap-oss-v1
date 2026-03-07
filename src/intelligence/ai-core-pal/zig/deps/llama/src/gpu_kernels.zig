//! GPU Kernels via CUDA/cuBLAS C FFI
//!
//! Zig bindings to CUDA kernels for GPU-accelerated LLM inference.
//! Falls back to CPU SIMD when CUDA is not available.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// C FFI Declarations
// ============================================================================

const c = @cImport({
    @cInclude("cuda_kernels.h");
});

// ============================================================================
// Device Info
// ============================================================================

pub const DeviceInfo = struct {
    name: [256]u8,
    total_memory: usize,
    free_memory: usize,
    compute_capability_major: i32,
    compute_capability_minor: i32,
    multiprocessor_count: i32,
    max_threads_per_block: i32,
    
    pub fn format(self: *const DeviceInfo, writer: anytype) !void {
        const name_slice = std.mem.sliceTo(&self.name, 0);
        try writer.print("{s} (SM {d}.{d}, {d} SMs, {d:.1} GB)", .{
            name_slice,
            self.compute_capability_major,
            self.compute_capability_minor,
            self.multiprocessor_count,
            @as(f64, @floatFromInt(self.total_memory)) / (1024 * 1024 * 1024),
        });
    }
};

// ============================================================================
// GPU Context
// ============================================================================

pub const GpuContext = struct {
    initialized: bool = false,
    cublas_initialized: bool = false,
    device_info: ?DeviceInfo = null,
    
    // Singleton instance
    var instance: ?GpuContext = null;
    
    pub fn get() *GpuContext {
        if (instance == null) {
            instance = GpuContext{};
        }
        return &instance.?;
    }
    
    pub fn init() !void {
        const ctx = get();
        if (ctx.initialized) return;
        
        const ret = c.cuda_init();
        if (ret != 0) {
            return error.CudaInitFailed;
        }
        
        ctx.initialized = true;
        
        // Get device info
        var info: c.CudaDeviceInfo = undefined;
        if (c.cuda_get_device_info(&info) == 0) {
            ctx.device_info = DeviceInfo{
                .name = info.name,
                .total_memory = info.total_memory,
                .free_memory = info.free_memory,
                .compute_capability_major = info.compute_capability_major,
                .compute_capability_minor = info.compute_capability_minor,
                .multiprocessor_count = info.multiprocessor_count,
                .max_threads_per_block = info.max_threads_per_block,
            };
        }
        
        // Init cuBLAS
        if (c.cublas_init() == 0) {
            ctx.cublas_initialized = true;
        }
    }
    
    pub fn shutdown() void {
        const ctx = get();
        if (!ctx.initialized) return;
        
        c.cublas_shutdown();
        c.cuda_shutdown();
        
        ctx.initialized = false;
        ctx.cublas_initialized = false;
        ctx.device_info = null;
    }
    
    pub fn isAvailable() bool {
        const ctx = get();
        if (!ctx.initialized) {
            init() catch return false;
        }
        return ctx.initialized;
    }
    
    pub fn getDeviceInfo() ?DeviceInfo {
        const ctx = get();
        return ctx.device_info;
    }
};

// ============================================================================
// GPU Memory
// ============================================================================

pub fn GpuBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        
        ptr: ?*anyopaque,
        len: usize,
        
        pub fn alloc(len: usize) !Self {
            const size = len * @sizeOf(T);
            const ptr = c.cuda_malloc(size);
            if (ptr == null) {
                return error.GpuAllocFailed;
            }
            return Self{ .ptr = ptr, .len = len };
        }
        
        pub fn free(self: *Self) void {
            if (self.ptr) |p| {
                c.cuda_free(p);
                self.ptr = null;
            }
        }
        
        pub fn copyFromHost(self: *Self, host_data: []const T) !void {
            if (host_data.len != self.len) return error.SizeMismatch;
            const size = self.len * @sizeOf(T);
            if (c.cuda_memcpy_h2d(self.ptr, host_data.ptr, size) != 0) {
                return error.MemcpyFailed;
            }
        }
        
        pub fn copyToHost(self: *const Self, host_data: []T) !void {
            if (host_data.len != self.len) return error.SizeMismatch;
            const size = self.len * @sizeOf(T);
            if (c.cuda_memcpy_d2h(host_data.ptr, self.ptr, size) != 0) {
                return error.MemcpyFailed;
            }
        }
        
        pub fn zero(self: *Self) !void {
            const size = self.len * @sizeOf(T);
            if (c.cuda_memset(self.ptr, 0, size) != 0) {
                return error.MemsetFailed;
            }
        }
    };
}

// ============================================================================
// GPU Kernel Operations
// ============================================================================

pub const GpuKernels = struct {
    
    // ---- Matrix Operations ----
    
    /// SGEMM: C = alpha * A @ B + beta * C
    pub fn sgemm(
        C: *anyopaque, A: *const anyopaque, B: *const anyopaque,
        M: usize, N: usize, K: usize,
        alpha: f32, beta: f32
    ) !void {
        if (c.cublas_sgemm(
            @ptrCast(C), @ptrCast(A), @ptrCast(B),
            @intCast(M), @intCast(N), @intCast(K),
            alpha, beta
        ) != 0) {
            return error.SgemmFailed;
        }
    }
    
    /// SGEMV: y = alpha * A @ x + beta * y
    pub fn sgemv(
        y: *anyopaque, A: *const anyopaque, x: *const anyopaque,
        M: usize, K: usize,
        alpha: f32, beta: f32
    ) !void {
        if (c.cublas_sgemv(
            @ptrCast(y), @ptrCast(A), @ptrCast(x),
            @intCast(M), @intCast(K),
            alpha, beta
        ) != 0) {
            return error.SgemvFailed;
        }
    }
    
    /// Batched SGEMM for multi-head attention
    pub fn sgemmBatched(
        C: *anyopaque, A: *const anyopaque, B: *const anyopaque,
        batch_size: usize, M: usize, N: usize, K: usize,
        alpha: f32, beta: f32
    ) !void {
        if (c.cublas_sgemm_batched(
            @ptrCast(C), @ptrCast(A), @ptrCast(B),
            @intCast(batch_size), @intCast(M), @intCast(N), @intCast(K),
            alpha, beta
        ) != 0) {
            return error.SgemmBatchedFailed;
        }
    }
    
    // ---- Activation Functions ----
    
    pub fn silu(dst: *anyopaque, src: *const anyopaque, n: usize) !void {
        if (c.cuda_silu(@ptrCast(dst), @ptrCast(src), @intCast(n)) != 0) {
            return error.SiluFailed;
        }
    }
    
    pub fn siluInplace(data: *anyopaque, n: usize) !void {
        if (c.cuda_silu_inplace(@ptrCast(data), @intCast(n)) != 0) {
            return error.SiluFailed;
        }
    }
    
    pub fn gelu(dst: *anyopaque, src: *const anyopaque, n: usize) !void {
        if (c.cuda_gelu(@ptrCast(dst), @ptrCast(src), @intCast(n)) != 0) {
            return error.GeluFailed;
        }
    }
    
    pub fn relu(dst: *anyopaque, src: *const anyopaque, n: usize) !void {
        if (c.cuda_relu(@ptrCast(dst), @ptrCast(src), @intCast(n)) != 0) {
            return error.ReluFailed;
        }
    }
    
    // ---- Normalization ----
    
    pub fn rmsNorm(
        dst: *anyopaque, src: *const anyopaque, weight: *const anyopaque,
        n: usize, eps: f32
    ) !void {
        if (c.cuda_rms_norm(
            @ptrCast(dst), @ptrCast(src), @ptrCast(weight),
            @intCast(n), eps
        ) != 0) {
            return error.RmsNormFailed;
        }
    }
    
    pub fn softmax(data: *anyopaque, n: usize) !void {
        if (c.cuda_softmax(@ptrCast(data), @intCast(n)) != 0) {
            return error.SoftmaxFailed;
        }
    }
    
    pub fn softmaxBatched(data: *anyopaque, batch_size: usize, n: usize) !void {
        if (c.cuda_softmax_batched(@ptrCast(data), @intCast(batch_size), @intCast(n)) != 0) {
            return error.SoftmaxFailed;
        }
    }
    
    // ---- Element-wise Operations ----
    
    pub fn vecAdd(dst: *anyopaque, a: *const anyopaque, b: *const anyopaque, n: usize) !void {
        if (c.cuda_vec_add(@ptrCast(dst), @ptrCast(a), @ptrCast(b), @intCast(n)) != 0) {
            return error.VecAddFailed;
        }
    }
    
    pub fn vecMul(dst: *anyopaque, a: *const anyopaque, b: *const anyopaque, n: usize) !void {
        if (c.cuda_vec_mul(@ptrCast(dst), @ptrCast(a), @ptrCast(b), @intCast(n)) != 0) {
            return error.VecMulFailed;
        }
    }
    
    pub fn vecScale(dst: *anyopaque, src: *const anyopaque, scale: f32, n: usize) !void {
        if (c.cuda_vec_scale(@ptrCast(dst), @ptrCast(src), scale, @intCast(n)) != 0) {
            return error.VecScaleFailed;
        }
    }
    
    pub fn vecFma(dst: *anyopaque, a: *const anyopaque, b: *const anyopaque, c_ptr: *const anyopaque, n: usize) !void {
        if (c.cuda_vec_fma(@ptrCast(dst), @ptrCast(a), @ptrCast(b), @ptrCast(c_ptr), @intCast(n)) != 0) {
            return error.VecFmaFailed;
        }
    }
    
    pub fn swiglu(dst: *anyopaque, gate: *const anyopaque, up: *const anyopaque, n: usize) !void {
        if (c.cuda_swiglu(@ptrCast(dst), @ptrCast(gate), @ptrCast(up), @intCast(n)) != 0) {
            return error.SwigluFailed;
        }
    }
    
    // ---- Reductions ----
    
    pub fn sum(result: *f32, data: *const anyopaque, n: usize) !void {
        if (c.cuda_sum(result, @ptrCast(data), @intCast(n)) != 0) {
            return error.SumFailed;
        }
    }
    
    pub fn max(result: *f32, data: *const anyopaque, n: usize) !void {
        if (c.cuda_max(result, @ptrCast(data), @intCast(n)) != 0) {
            return error.MaxFailed;
        }
    }
    
    pub fn dot(result: *f32, a: *const anyopaque, b: *const anyopaque, n: usize) !void {
        if (c.cuda_dot(result, @ptrCast(a), @ptrCast(b), @intCast(n)) != 0) {
            return error.DotFailed;
        }
    }
    
    // ---- Attention ----
    
    pub fn rope(
        q: *anyopaque, k: *anyopaque,
        pos: usize, head_dim: usize, base_freq: f32,
        batch_size: usize
    ) !void {
        if (c.cuda_rope(
            @ptrCast(q), @ptrCast(k),
            @intCast(pos), @intCast(head_dim), base_freq,
            @intCast(batch_size)
        ) != 0) {
            return error.RopeFailed;
        }
    }
    
    pub fn attention(
        output: *anyopaque,
        Q: *const anyopaque, K: *const anyopaque, V: *const anyopaque,
        batch_size: usize, seq_len: usize, head_dim: usize, num_heads: usize,
        scale: f32, causal: bool
    ) !void {
        if (c.cuda_attention(
            @ptrCast(output),
            @ptrCast(Q), @ptrCast(K), @ptrCast(V),
            @intCast(batch_size), @intCast(seq_len),
            @intCast(head_dim), @intCast(num_heads),
            scale, if (causal) 1 else 0
        ) != 0) {
            return error.AttentionFailed;
        }
    }
    
    // ---- Quantization ----
    
    pub fn dequantQ8_0(dst: *anyopaque, src: *const anyopaque, num_blocks: usize) !void {
        if (c.cuda_dequant_q8_0(@ptrCast(dst), src, @intCast(num_blocks)) != 0) {
            return error.DequantFailed;
        }
    }
    
    pub fn dequantQ4_0(dst: *anyopaque, src: *const anyopaque, num_blocks: usize) !void {
        if (c.cuda_dequant_q4_0(@ptrCast(dst), src, @intCast(num_blocks)) != 0) {
            return error.DequantFailed;
        }
    }
    
    // ---- Synchronization ----
    
    pub fn synchronize() !void {
        if (c.cuda_synchronize() != 0) {
            return error.SyncFailed;
        }
    }
    
    pub fn getLastError() []const u8 {
        const err = c.cuda_get_last_error();
        return std.mem.span(err);
    }
};

// ============================================================================
// Unified Kernel Dispatcher
// ============================================================================

/// Automatically dispatches to GPU if available, otherwise CPU
pub const KernelDispatcher = struct {
    use_gpu: bool,
    
    pub fn init() KernelDispatcher {
        const use_gpu = GpuContext.isAvailable();
        if (use_gpu) {
            std.log.info("GPU kernels enabled: {s}", .{
                if (GpuContext.getDeviceInfo()) |info|
                    std.mem.sliceTo(&info.name, 0)
                else
                    "Unknown"
            });
        } else {
            std.log.info("GPU not available, using CPU SIMD kernels", .{});
        }
        return .{ .use_gpu = use_gpu };
    }
    
    pub fn usingGpu(self: *const KernelDispatcher) bool {
        return self.use_gpu;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "gpu availability check" {
    // This test just checks the FFI compiles correctly
    // Actual GPU tests require CUDA hardware
    const available = GpuContext.isAvailable();
    _ = available;
}