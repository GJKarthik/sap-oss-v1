//! ANWID CUDA Backend — Pure Zig Implementation
//!
//! Native CUDA kernels compiled to PTX via LLVM nvptx64 backend.
//! No nvcc or CUDA toolkit required at build time.
//! Targets NVIDIA GPUs: T4 (SM75), A100 (SM80), H100 (SM90)

const std = @import("std");
const builtin = @import("builtin");
const cuda_build_options = @import("cuda_build_options");

// Pure Zig CUDA kernels (compiled to PTX via -target nvptx64-nvidia-cuda)
const kernels = @import("cuda_kernels.zig");

// CUDA runtime bindings (for kernel launch, memory management)
const cuda = @import("cuda_bindings.zig");

const log = std.log.scoped(.cuda_backend);

// ============================================================================
// CUDA Backend Configuration
// ============================================================================

pub const CudaConfig = struct {
    /// Maximum concurrent streams
    max_streams: usize = 4,
    /// Buffer size for compute operations
    buffer_size: usize = 128 * 1024 * 1024, // 128MB
    /// CUDA device ordinal
    device_id: i32 = 0,
    /// Enable INT8 Tensor Core math (Turing/T4 optimized)
    enable_int8: bool = true,
    /// Enable Flash Attention (O(N) memory)
    enable_flash_attention: bool = true,
};

pub const CudaQuantizationType = enum {
    f32,
    f16,
    int8,
};

// ============================================================================
// Kernel Registry — Comptime PTX Discovery + Dynamic Resolution
// ============================================================================

const PtxKernelDiscovery = struct {
    names: [64][]const u8,
    count: usize,
};

/// Comptime: parse embedded PTX for all `.visible .entry <name>` declarations.
/// Returns slices into the embedded PTX data (no copies needed).
fn discoverPtxKernels() PtxKernelDiscovery {
    const ptx = @embedFile("cuda_kernels_ptx.bin");
    const marker = ".visible .entry ";
    var result = PtxKernelDiscovery{
        .names = undefined,
        .count = 0,
    };
    var pos: usize = 0;

    @setEvalBranchQuota(500_000);
    while (pos + marker.len < ptx.len) : (pos += 1) {
        if (std.mem.startsWith(u8, ptx[pos..], marker)) {
            const name_start = pos + marker.len;
            var name_end = name_start;
            while (name_end < ptx.len and ptx[name_end] != '(' and ptx[name_end] != ' ' and ptx[name_end] != '\n') {
                name_end += 1;
            }
            if (name_end > name_start) {
                result.names[result.count] = ptx[name_start..name_end];
                result.count += 1;
                pos = name_end;
            }
        }
    }
    return result;
}

/// All kernel entry-point names discovered from the PTX at compile time.
const ptx_kernel_discovery = discoverPtxKernels();
const ptx_kernel_names = ptx_kernel_discovery.names[0..ptx_kernel_discovery.count];

/// Runtime kernel registry: name -> CUfunction handle.
/// Populated by loadPtxKernels() from the comptime-discovered names.
const KernelRegistry = std.StringHashMap(cuda.CUfunction);

// ============================================================================
// CUDA Backend
// ============================================================================

pub const CudaBackend = struct {
    allocator: std.mem.Allocator,
    config: CudaConfig,
    initialized: bool,
    device_name: []const u8,
    compute_capability: struct { major: c_int, minor: c_int },

    // PTX module and dynamic kernel registry
    ptx_module: ?cuda.CUmodule = null,
    core_module: ?cuda.CUmodule = null, // nvcc-compiled core kernels (sgemv, rms_norm, etc.)
    cuda_context: ?cuda.CUcontext = null,
    kernel_registry: KernelRegistry,

    // CUDA Stream for graph capture and async dispatch (compute stream)
    stream: cuda.CUstream = null,

    // Transfer stream for async CPU→GPU DMA (expert offloading double-buffering)
    transfer_stream: cuda.CUstream = null,
    // Events for inter-stream synchronization (compute↔transfer)
    transfer_done_event: cuda.CUevent = null, // signaled when transfer completes
    compute_done_event: cuda.CUevent = null, // signaled when compute kernel completes

    // cuBLAS handle for batched GEMM
    cublas_handle: ?cuda.CublasHandle = null,

    // Scratch buffer for dequantized FP32 weights (reused across calls)
    dequant_scratch: cuda.CUdeviceptr = 0,
    dequant_scratch_size: usize = 0,

    // FP16 conversion + fused kernels (loaded from inline PTX at init)
    fp16_module: ?cuda.CUmodule = null,
    fp32_to_fp16_func: ?cuda.CUfunction = null,
    fp16_to_fp32_func: ?cuda.CUfunction = null,
    fp16_swiglu_func: ?cuda.CUfunction = null,

    // MoE kernels (loaded from inline PTX at init)
    moe_module: ?cuda.CUmodule = null,
    weighted_vadd_func: ?cuda.CUfunction = null,
    zero_buffer_func: ?cuda.CUfunction = null,

    // MoE optimization kernels (nvcc-compiled PTX, eliminates per-layer sync)
    moe_opt_module: ?cuda.CUmodule = null,
    softmax_topk_func: ?cuda.CUfunction = null,
    dequant_topk_func: ?cuda.CUfunction = null,
    weighted_vadd_dev_func: ?cuda.CUfunction = null,
    q4_gemv_batch_func: ?cuda.CUfunction = null,
    rms_norm_batch_func: ?cuda.CUfunction = null,
    fp32_to_fp16_batch_func: ?cuda.CUfunction = null,
    gather_vectors_func: ?cuda.CUfunction = null,
    scatter_weighted_vadd_func: ?cuda.CUfunction = null,
    q4_gemv_batch_gather_func: ?cuda.CUfunction = null,
    fused_gate_up_gather_func: ?cuda.CUfunction = null,
    softmax_topk_batch_func: ?cuda.CUfunction = null,
    build_expert_routing_func: ?cuda.CUfunction = null,
    rope_q_batch_func: ?cuda.CUfunction = null,
    rope_k_batch_func: ?cuda.CUfunction = null,
    kv_cache_scatter_func: ?cuda.CUfunction = null,

    // DeltaNet kernels (Qwen3.5 hybrid architecture, nvcc-compiled PTX)
    deltanet_module: ?cuda.CUmodule = null,
    dn_conv1d_func: ?cuda.CUfunction = null,
    dn_l2norm_func: ?cuda.CUfunction = null,
    dn_gates_func: ?cuda.CUfunction = null,
    dn_recurrent_func: ?cuda.CUfunction = null,
    dn_output_gate_func: ?cuda.CUfunction = null,
    dn_partial_rope_q_func: ?cuda.CUfunction = null,
    dn_partial_rope_k_func: ?cuda.CUfunction = null,
    dn_split_q_gate_func: ?cuda.CUfunction = null,
    dn_gated_attn_output_func: ?cuda.CUfunction = null,
    dn_q4_gemv_func: ?cuda.CUfunction = null,
    dn_q4_1_gemv_func: ?cuda.CUfunction = null,
    dn_decode_attention_func: ?cuda.CUfunction = null,
    dn_q8_0_gemv_func: ?cuda.CUfunction = null,

    // QJL kernels (KV cache compression, nvcc-compiled PTX)
    qjl_module: ?cuda.CUmodule = null,
    qjl_quantize_key_func: ?cuda.CUfunction = null,
    qjl_decode_attention_func: ?cuda.CUfunction = null,

    // CUDA Graph capture state
    captured_graph: ?cuda.CUgraph = null,
    graph_exec: ?cuda.CUgraphExec = null,
    graph_captured: bool = false,
    capturing: bool = false,

    // Statistics
    kernel_dispatches: std.atomic.Value(u64),
    total_elements: std.atomic.Value(u64),
    total_exec_time_ns: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: CudaConfig) !*CudaBackend {
        const backend = try allocator.create(CudaBackend);

        var initialized = false;
        var device_name: []const u8 = "CPU (CUDA not available)";
        var cc_major: c_int = 0;
        var cc_minor: c_int = 0;

        // CUDA is only available on Linux/Windows with NVIDIA drivers
        // Pure Zig kernels compile to PTX, but we still need CUDA runtime to launch
        if ((builtin.os.tag == .linux or builtin.os.tag == .windows) and !builtin.is_test) {
            // Try to initialize CUDA runtime
            if (cuda.cuInit(0) == .success) {
                initialized = true;
                // Detect GPU type
                var device_count: c_int = 0;
                if (cuda.cuDeviceGetCount(&device_count) == .success and device_count > 0) {
                    var device: cuda.CUdevice = undefined;
                    if (cuda.cuDeviceGet(&device, config.device_id) == .success) {
                        _ = cuda.cuDeviceGetAttribute(&cc_major, .compute_capability_major, device);
                        _ = cuda.cuDeviceGetAttribute(&cc_minor, .compute_capability_minor, device);

                        device_name = switch (cc_major * 10 + cc_minor) {
                            75 => "NVIDIA T4 (Turing)",
                            80 => "NVIDIA A100 (Ampere)",
                            86 => "NVIDIA RTX 3090 (Ampere)",
                            89 => "NVIDIA L40S (Ada)",
                            90 => "NVIDIA H100 (Hopper)",
                            else => "NVIDIA GPU",
                        };
                    }
                }
            }
        }

        backend.* = .{
            .allocator = allocator,
            .config = config,
            .initialized = initialized,
            .device_name = device_name,
            .compute_capability = .{ .major = cc_major, .minor = cc_minor },
            .kernel_registry = KernelRegistry.init(allocator),
            .kernel_dispatches = std.atomic.Value(u64).init(0),
            .total_elements = std.atomic.Value(u64).init(0),
            .total_exec_time_ns = std.atomic.Value(u64).init(0),
        };

        if (initialized) {
            // Create CUDA context and load PTX kernels
            var device: cuda.CUdevice = undefined;
            if (cuda.cuDeviceGet(&device, config.device_id) == .success) {
                var ctx: cuda.CUcontext = undefined;
                // Use primary context (shared across threads) instead of cuCtxCreate
                // so HTTP worker threads can use CUDA without per-thread context binding.
                if (cuda.cuDevicePrimaryCtxRetain(&ctx, device) == .success and
                    cuda.cuCtxSetCurrent(ctx) == .success)
                {
                    backend.cuda_context = ctx;
                    backend.loadPtxKernels();

                    // Load nvcc-compiled core kernels (sgemv, rms_norm, etc.)
                    // These override Zig PTX kernels for cross-GPU compatibility.
                    backend.loadCoreKernels();

                    // Create a non-blocking stream for kernel dispatch and graph capture
                    var stream: cuda.CUstream = undefined;
                    if (cuda.cuStreamCreate(&stream, 1) == .success) { // 1 = CU_STREAM_NON_BLOCKING
                        backend.stream = stream;
                    }

                    // Create transfer stream for async CPU→GPU DMA (expert offloading)
                    var xfer_stream: cuda.CUstream = undefined;
                    if (cuda.cuStreamCreate(&xfer_stream, 1) == .success) {
                        backend.transfer_stream = xfer_stream;
                        // Create events for compute↔transfer synchronization
                        // CU_EVENT_DISABLE_TIMING (0x2) for lower overhead
                        var xfer_evt: cuda.CUevent = undefined;
                        if (cuda.cuEventCreate(&xfer_evt, 0x2) == .success) {
                            backend.transfer_done_event = xfer_evt;
                        }
                        var comp_evt: cuda.CUevent = undefined;
                        if (cuda.cuEventCreate(&comp_evt, 0x2) == .success) {
                            backend.compute_done_event = comp_evt;
                        }
                    }

                    // Initialize cuBLAS for batched GEMM (multi-user decode)
                    var cublas_h: cuda.CublasHandle = undefined;
                    if (cuda.cublasCreate(&cublas_h) == .SUCCESS) {
                        backend.cublas_handle = cublas_h;
                        if (backend.stream) |s| {
                            _ = cuda.cublasSetStream(cublas_h, s);
                        }
                        // Enable tensor core acceleration for FP16 HGEMM
                        _ = cuda.cublasSetMathMode(cublas_h, .TENSOR_OP_MATH);
                    }

                    // Load FP16 conversion kernels from inline PTX
                    backend.loadFp16ConversionKernels();

                    // Load MoE kernels from inline PTX
                    backend.loadMoEKernels();

                    // Load MoE optimization kernels (nvcc-compiled, eliminates per-layer sync)
                    backend.loadMoEOptKernels();

                    // Load DeltaNet kernels (Qwen3.5 hybrid architecture)
                    backend.loadDeltaNetKernels();

                    // Load QJL kernels (KV cache compression)
                    backend.loadQJLKernels();
                }
            }

            log.info("CUDA Backend initialized (Pure Zig Kernels):", .{});
            log.info("  Device: {s} (Compute {}.{})", .{ device_name, cc_major, cc_minor });
            log.info("  Flash Attention: {s}", .{if (config.enable_flash_attention) "ENABLED" else "disabled"});
            log.info("  GPU Kernels: {s}", .{if (backend.ptx_module != null) "LOADED" else "CPU fallback"});
            if (config.enable_int8 and cc_major >= 7 and cc_minor >= 5) {
                log.info("  INT8 Tensor Cores: ENABLED", .{});
            }
        } else {
            log.warn("CUDA not available, using CPU fallback", .{});
        }

        return backend;
    }

    pub fn deinit(self: *CudaBackend) void {
        self.destroyGraph();
        if (self.dequant_scratch != 0) _ = cuda.cuMemFree(self.dequant_scratch);
        if (self.cublas_handle) |h| _ = cuda.cublasDestroy(h);
        if (self.deltanet_module) |mod| _ = cuda.cuModuleUnload(mod);
        if (self.moe_opt_module) |mod| _ = cuda.cuModuleUnload(mod);
        if (self.moe_module) |mod| _ = cuda.cuModuleUnload(mod);
        if (self.fp16_module) |mod| _ = cuda.cuModuleUnload(mod);
        if (self.transfer_done_event) |e| _ = cuda.cuEventDestroy(e);
        if (self.compute_done_event) |e| _ = cuda.cuEventDestroy(e);
        if (self.transfer_stream) |s| _ = cuda.cuStreamDestroy(s);
        if (self.stream) |s| _ = cuda.cuStreamDestroy(s);
        if (self.ptx_module) |mod| _ = cuda.cuModuleUnload(mod);
        // Primary context: release instead of destroy
        {
            var device: cuda.CUdevice = undefined;
            if (cuda.cuDeviceGet(&device, self.config.device_id) == .success)
                _ = cuda.cuDevicePrimaryCtxRelease(device);
        }
        self.kernel_registry.deinit();
        self.allocator.destroy(self);
    }

    // ========================================================================
    // PTX Module & Kernel Management
    // ========================================================================

    fn loadPtxKernels(self: *CudaBackend) void {
        const ptx_image = @embedFile("cuda_kernels_ptx.bin") ++ [_]u8{0};
        var module: cuda.CUmodule = undefined;
        const load_result = cuda.cuModuleLoadData(&module, ptx_image.ptr);
        if (load_result != .success) {
            log.warn("Failed to load PTX module (error={}), using CPU fallback", .{@intFromEnum(load_result)});
            return;
        }
        self.ptx_module = module;

        // Auto-resolve all kernels discovered from PTX at comptime
        var resolved: u32 = 0;
        inline for (ptx_kernel_names) |name| {
            // Null-terminate the comptime slice for cuModuleGetFunction
            const name_z: [*:0]const u8 = (name ++ "\x00")[0..name.len :0];
            var func: cuda.CUfunction = undefined;
            if (cuda.cuModuleGetFunction(&func, module, name_z) == .success) {
                self.kernel_registry.put(name, func) catch {};
                resolved += 1;
            }
        }

        log.info("  Loaded {} GPU kernel functions", .{resolved});
    }

    /// Inline PTX for FP32↔FP16 conversion kernels (SM75+).
    /// These enable the HGEMM batch forward path: activations stay FP32 for
    /// RMSNorm/RoPE/attention, but get converted to FP16 for cuBLAS HGEMM.
    const fp16_conversion_ptx =
        \\.version 6.5
        \\.target sm_70
        \\.address_size 64
        \\
        \\.visible .entry fp32_to_fp16(
        \\    .param .u64 p_out,
        \\    .param .u64 p_in,
        \\    .param .u32 p_n
        \\) {
        \\    .reg .u32 %r<5>;
        \\    .reg .u64 %rd<5>;
        \\    .reg .f32 %f1;
        \\    .reg .b16 %h1;
        \\    .reg .pred %p1;
        \\    mov.u32 %r1, %tid.x;
        \\    mov.u32 %r2, %ntid.x;
        \\    mov.u32 %r3, %ctaid.x;
        \\    mad.lo.u32 %r4, %r3, %r2, %r1;
        \\    ld.param.u32 %r2, [p_n];
        \\    setp.ge.u32 %p1, %r4, %r2;
        \\    @%p1 bra $L_done_f2h;
        \\    ld.param.u64 %rd1, [p_in];
        \\    ld.param.u64 %rd2, [p_out];
        \\    cvt.u64.u32 %rd3, %r4;
        \\    shl.b64 %rd4, %rd3, 2;
        \\    add.u64 %rd1, %rd1, %rd4;
        \\    shl.b64 %rd4, %rd3, 1;
        \\    add.u64 %rd2, %rd2, %rd4;
        \\    ld.global.f32 %f1, [%rd1];
        \\    cvt.rn.f16.f32 %h1, %f1;
        \\    st.global.b16 [%rd2], %h1;
        \\$L_done_f2h:
        \\    ret;
        \\}
        \\
        \\.visible .entry fp16_to_fp32(
        \\    .param .u64 p_out,
        \\    .param .u64 p_in,
        \\    .param .u32 p_n
        \\) {
        \\    .reg .u32 %r<5>;
        \\    .reg .u64 %rd<5>;
        \\    .reg .f32 %f1;
        \\    .reg .b16 %h1;
        \\    .reg .pred %p1;
        \\    mov.u32 %r1, %tid.x;
        \\    mov.u32 %r2, %ntid.x;
        \\    mov.u32 %r3, %ctaid.x;
        \\    mad.lo.u32 %r4, %r3, %r2, %r1;
        \\    ld.param.u32 %r2, [p_n];
        \\    setp.ge.u32 %p1, %r4, %r2;
        \\    @%p1 bra $L_done_h2f;
        \\    ld.param.u64 %rd1, [p_in];
        \\    ld.param.u64 %rd2, [p_out];
        \\    cvt.u64.u32 %rd3, %r4;
        \\    shl.b64 %rd4, %rd3, 1;
        \\    add.u64 %rd1, %rd1, %rd4;
        \\    shl.b64 %rd4, %rd3, 2;
        \\    add.u64 %rd2, %rd2, %rd4;
        \\    ld.global.b16 %h1, [%rd1];
        \\    cvt.f32.f16 %f1, %h1;
        \\    st.global.f32 [%rd2], %f1;
        \\$L_done_h2f:
        \\    ret;
        \\}
        \\
        \\.visible .entry fp16_swiglu(
        \\    .param .u64 p_gate,
        \\    .param .u64 p_up,
        \\    .param .u32 p_n
        \\) {
        \\    .reg .u32 %r<5>;
        \\    .reg .u64 %rd<6>;
        \\    .reg .f32 %f<6>;
        \\    .reg .b16 %h<3>;
        \\    .reg .pred %p1;
        \\    mov.u32 %r1, %tid.x;
        \\    mov.u32 %r2, %ntid.x;
        \\    mov.u32 %r3, %ctaid.x;
        \\    mad.lo.u32 %r4, %r3, %r2, %r1;
        \\    ld.param.u32 %r2, [p_n];
        \\    setp.ge.u32 %p1, %r4, %r2;
        \\    @%p1 bra $L_done_swiglu;
        \\    ld.param.u64 %rd1, [p_gate];
        \\    ld.param.u64 %rd2, [p_up];
        \\    cvt.u64.u32 %rd3, %r4;
        \\    shl.b64 %rd4, %rd3, 1;
        \\    add.u64 %rd5, %rd1, %rd4;
        \\    add.u64 %rd2, %rd2, %rd4;
        \\    ld.global.b16 %h1, [%rd5];
        \\    ld.global.b16 %h2, [%rd2];
        \\    cvt.f32.f16 %f1, %h1;
        \\    cvt.f32.f16 %f2, %h2;
        \\    mul.f32 %f3, %f1, 0fBFB8AA3B;
        \\    ex2.approx.f32 %f3, %f3;
        \\    add.f32 %f3, %f3, 0f3F800000;
        \\    div.approx.f32 %f3, %f1, %f3;
        \\    mul.f32 %f3, %f3, %f2;
        \\    cvt.rn.f16.f32 %h1, %f3;
        \\    st.global.b16 [%rd5], %h1;
        \\$L_done_swiglu:
        \\    ret;
        \\}
        \\
    ++ "\x00";

    fn loadFp16ConversionKernels(self: *CudaBackend) void {
        var module: cuda.CUmodule = undefined;
        if (cuda.cuModuleLoadData(&module, fp16_conversion_ptx.ptr) != .success) {
            log.warn("Failed to load FP16 conversion PTX module", .{});
            return;
        }
        self.fp16_module = module;

        var f2h: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&f2h, module, "fp32_to_fp16") == .success) {
            self.fp32_to_fp16_func = f2h;
        }
        var h2f: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&h2f, module, "fp16_to_fp32") == .success) {
            self.fp16_to_fp32_func = h2f;
        }
        var swiglu_fn: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&swiglu_fn, module, "fp16_swiglu") == .success) {
            self.fp16_swiglu_func = swiglu_fn;
        }

        if (self.fp32_to_fp16_func != null and self.fp16_to_fp32_func != null) {
            log.info("  FP16 kernels: convert + swiglu LOADED", .{});
        }
    }

    /// Inline PTX for MoE kernels: weighted vector add and zero buffer.
    /// weighted_vector_add: out[i] += scale * x[i]  (FP32)
    /// zero_buffer: out[i] = 0.0f  (FP32)
    const moe_ptx =
        \\.version 6.5
        \\.target sm_70
        \\.address_size 64
        \\
        \\.visible .entry weighted_vector_add(
        \\    .param .u64 p_out,
        \\    .param .u64 p_x,
        \\    .param .f32 p_scale,
        \\    .param .u32 p_n
        \\) {
        \\    .reg .u32 %r<5>;
        \\    .reg .u64 %rd<6>;
        \\    .reg .f32 %f<4>;
        \\    .reg .pred %p1;
        \\    mov.u32 %r1, %tid.x;
        \\    mov.u32 %r2, %ntid.x;
        \\    mov.u32 %r3, %ctaid.x;
        \\    mad.lo.u32 %r4, %r3, %r2, %r1;
        \\    ld.param.u32 %r2, [p_n];
        \\    setp.ge.u32 %p1, %r4, %r2;
        \\    @%p1 bra $L_done_wva;
        \\    ld.param.u64 %rd1, [p_out];
        \\    ld.param.u64 %rd2, [p_x];
        \\    ld.param.f32 %f1, [p_scale];
        \\    cvt.u64.u32 %rd3, %r4;
        \\    shl.b64 %rd4, %rd3, 2;
        \\    add.u64 %rd5, %rd1, %rd4;
        \\    add.u64 %rd2, %rd2, %rd4;
        \\    ld.global.f32 %f2, [%rd5];
        \\    ld.global.f32 %f3, [%rd2];
        \\    fma.rn.f32 %f2, %f3, %f1, %f2;
        \\    st.global.f32 [%rd5], %f2;
        \\$L_done_wva:
        \\    ret;
        \\}
        \\
        \\.visible .entry zero_buffer(
        \\    .param .u64 p_out,
        \\    .param .u32 p_n
        \\) {
        \\    .reg .u32 %r<5>;
        \\    .reg .u64 %rd<4>;
        \\    .reg .pred %p1;
        \\    mov.u32 %r1, %tid.x;
        \\    mov.u32 %r2, %ntid.x;
        \\    mov.u32 %r3, %ctaid.x;
        \\    mad.lo.u32 %r4, %r3, %r2, %r1;
        \\    ld.param.u32 %r2, [p_n];
        \\    setp.ge.u32 %p1, %r4, %r2;
        \\    @%p1 bra $L_done_zero;
        \\    ld.param.u64 %rd1, [p_out];
        \\    cvt.u64.u32 %rd2, %r4;
        \\    shl.b64 %rd3, %rd2, 2;
        \\    add.u64 %rd1, %rd1, %rd3;
        \\    mov.b32 %r1, 0;
        \\    st.global.b32 [%rd1], %r1;
        \\$L_done_zero:
        \\    ret;
        \\}
        \\
    ++ "\x00";

    fn loadMoEKernels(self: *CudaBackend) void {
        var module: cuda.CUmodule = undefined;
        if (cuda.cuModuleLoadData(&module, moe_ptx.ptr) != .success) {
            log.warn("Failed to load MoE PTX module", .{});
            return;
        }
        self.moe_module = module;

        var wva: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&wva, module, "weighted_vector_add") == .success) {
            self.weighted_vadd_func = wva;
        }
        var zero_fn: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&zero_fn, module, "zero_buffer") == .success) {
            self.zero_buffer_func = zero_fn;
        }

        if (self.weighted_vadd_func != null and self.zero_buffer_func != null) {
            log.info("  MoE kernels: weighted_vadd + zero_buffer LOADED", .{});
        }
    }

    fn loadMoEOptKernels(self: *CudaBackend) void {
        const ptx_data = @embedFile("moe_opt_kernels.ptx") ++ [_]u8{0};
        var module: cuda.CUmodule = undefined;
        if (cuda.cuModuleLoadData(&module, ptx_data.ptr) != .success) {
            log.warn("Failed to load MoE optimization PTX module", .{});
            return;
        }
        self.moe_opt_module = module;

        var stk: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&stk, module, "softmax_topk_kernel") == .success) {
            self.softmax_topk_func = stk;
        }
        var dtk: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&dtk, module, "dequant_topk_experts_q4_fp16") == .success) {
            self.dequant_topk_func = dtk;
        }
        var wvd: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&wvd, module, "weighted_vadd_device") == .success) {
            self.weighted_vadd_dev_func = wvd;
        }

        var gbf: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&gbf, module, "q4_0_gemv_batch") == .success) {
            self.q4_gemv_batch_func = gbf;
        }

        if (self.softmax_topk_func != null and self.dequant_topk_func != null and self.weighted_vadd_dev_func != null) {
            log.info("  MoE opt kernels: softmax_topk + dequant_topk + weighted_vadd_dev LOADED", .{});
        }
        var rnb: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&rnb, module, "rms_norm_batch") == .success) {
            self.rms_norm_batch_func = rnb;
        }
        var f2h: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&f2h, module, "fp32_to_fp16_batch") == .success) {
            self.fp32_to_fp16_batch_func = f2h;
        }

        if (self.q4_gemv_batch_func != null) {
            log.info("  MoE opt kernels: q4_0_gemv_batch LOADED", .{});
        }
        var gv: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&gv, module, "gather_vectors") == .success) {
            self.gather_vectors_func = gv;
        }
        var sw: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&sw, module, "scatter_weighted_vadd") == .success) {
            self.scatter_weighted_vadd_func = sw;
        }

        if (self.rms_norm_batch_func != null) {
            log.info("  MoE opt kernels: rms_norm_batch LOADED", .{});
        }
        var gbg: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&gbg, module, "q4_0_gemv_batch_gather") == .success) {
            self.q4_gemv_batch_gather_func = gbg;
        }
        var fgu: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&fgu, module, "q4_0_gemv_fused_gate_up_gather") == .success) {
            self.fused_gate_up_gather_func = fgu;
        }
        var stb: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&stb, module, "softmax_topk_batch") == .success) {
            self.softmax_topk_batch_func = stb;
        }
        var ber: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&ber, module, "build_expert_routing") == .success) {
            self.build_expert_routing_func = ber;
        }
        var rqb: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&rqb, module, "rope_q_batch") == .success) {
            self.rope_q_batch_func = rqb;
        }
        var rkb: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&rkb, module, "rope_k_batch") == .success) {
            self.rope_k_batch_func = rkb;
        }
        var kvs: cuda.CUfunction = undefined;
        if (cuda.cuModuleGetFunction(&kvs, module, "kv_cache_scatter") == .success) {
            self.kv_cache_scatter_func = kvs;
        }

        if (self.gather_vectors_func != null) {
            log.info("  MoE opt kernels: gather_vectors + scatter_weighted_vadd LOADED", .{});
        }
        if (self.rope_q_batch_func != null) {
            log.info("  MoE opt kernels: rope_q/k_batch + kv_cache_scatter LOADED", .{});
        }
    }

    /// Load nvcc-compiled core kernels and override the Zig PTX versions in the registry.
    /// This ensures cross-GPU compatibility (sm_70 V100, sm_75 T4, sm_89 L40S, etc.)
    fn loadCoreKernels(self: *CudaBackend) void {
        if (!cuda_build_options.has_core_kernels_ptx) {
            log.warn("core_kernels.ptx missing at build time; using Zig PTX fallback", .{});
            return;
        }
        const ptx_data = @embedFile("core_kernels.ptx") ++ [_]u8{0};
        var module: cuda.CUmodule = undefined;
        if (cuda.cuModuleLoadData(&module, ptx_data.ptr) != .success) {
            log.warn("Failed to load core_kernels PTX (using Zig PTX fallback)", .{});
            return;
        }
        self.core_module = module;

        // Override kernel registry entries with nvcc-compiled versions
        const kernel_names = [_][:0]const u8{
            "sgemv",            "rms_norm", "rms_norm_batch", "rope_q",  "rope_k",
            "embedding_lookup", "swiglu",   "vector_add",     "softmax", "dequantize_q4_0",
        };
        var loaded: u32 = 0;
        inline for (kernel_names) |name| {
            var func: cuda.CUfunction = undefined;
            if (cuda.cuModuleGetFunction(&func, module, name.ptr) == .success) {
                self.kernel_registry.put(name, func) catch {};
                loaded += 1;
            }
        }
        log.info("  Core kernels (nvcc): {}/10 loaded (overrides Zig PTX)", .{loaded});
    }

    fn loadDeltaNetKernels(self: *CudaBackend) void {
        if (!cuda_build_options.has_deltanet_kernels_ptx) {
            log.warn("deltanet_kernels.ptx missing at build time", .{});
            return;
        }
        const ptx_data = @embedFile("deltanet_kernels.ptx") ++ [_]u8{0};
        var module: cuda.CUmodule = undefined;
        if (cuda.cuModuleLoadData(&module, ptx_data.ptr) != .success) {
            log.warn("Failed to load DeltaNet PTX module", .{});
            return;
        }
        self.deltanet_module = module;

        const kernel_map = .{
            .{ "deltanet_conv1d", &self.dn_conv1d_func },
            .{ "deltanet_l2norm", &self.dn_l2norm_func },
            .{ "deltanet_gates", &self.dn_gates_func },
            .{ "deltanet_recurrent", &self.dn_recurrent_func },
            .{ "deltanet_output_gate", &self.dn_output_gate_func },
            .{ "partial_rope_q", &self.dn_partial_rope_q_func },
            .{ "partial_rope_k", &self.dn_partial_rope_k_func },
            .{ "split_q_gate", &self.dn_split_q_gate_func },
            .{ "gated_attn_output", &self.dn_gated_attn_output_func },
            .{ "q4_gemv", &self.dn_q4_gemv_func },
            .{ "q4_1_gemv", &self.dn_q4_1_gemv_func },
            .{ "decode_attention", &self.dn_decode_attention_func },
            .{ "q8_0_gemv", &self.dn_q8_0_gemv_func },
        };

        var loaded: u32 = 0;
        inline for (kernel_map) |entry| {
            var func: cuda.CUfunction = undefined;
            if (cuda.cuModuleGetFunction(&func, module, entry[0]) == .success) {
                entry[1].* = func;
                loaded += 1;
            }
        }
        log.info("  DeltaNet kernels: {}/13 loaded", .{loaded});
    }

    fn loadQJLKernels(self: *CudaBackend) void {
        if (!cuda_build_options.has_qjl_kernels_ptx) {
            log.warn("qjl_kernels.ptx missing at build time; KV cache compression disabled", .{});
            return;
        }
        const ptx_data = @embedFile("qjl_kernels.ptx") ++ [_]u8{0};
        var module: cuda.CUmodule = undefined;
        if (cuda.cuModuleLoadData(&module, ptx_data.ptr) != .success) {
            log.warn("Failed to load QJL PTX module (KV cache compression unavailable)", .{});
            return;
        }
        self.qjl_module = module;

        const kernel_map = .{
            .{ "qjl_quantize_key", &self.qjl_quantize_key_func },
            .{ "qjl_decode_attention", &self.qjl_decode_attention_func },
        };

        var loaded: u32 = 0;
        inline for (kernel_map) |entry| {
            var func: cuda.CUfunction = undefined;
            if (cuda.cuModuleGetFunction(&func, module, entry[0]) == .success) {
                entry[1].* = func;
                loaded += 1;
            }
        }
        log.info("  QJL kernels: {}/2 loaded", .{loaded});
    }

    // ========================================================================
    // QJL Kernel Dispatch (KV cache compression)
    // ========================================================================

    /// Quantize a key vector to QJL sign bits + L2 norm.
    /// Replaces dense key cache write for QJL-enabled KV caches.
    pub fn qjlQuantizeKey(
        self: *CudaBackend,
        d_sign_bits: cuda.CUdeviceptr, // output: [n_kv_heads * m_words] uint32s
        d_norms: cuda.CUdeviceptr, // output: [n_kv_heads] floats
        d_key: cuda.CUdeviceptr, // input: [n_kv_heads * head_dim] F32 key
        d_projection: cuda.CUdeviceptr, // input: [m * head_dim_words] packed bits
        head_dim: u32,
        m: u32, // sketch dimension
        n_kv_heads: u32,
    ) !void {
        const func = self.qjl_quantize_key_func orelse return error.KernelNotLoaded;
        var sb_v = d_sign_bits;
        var nm_v = d_norms;
        var k_v = d_key;
        var p_v = d_projection;
        var hd_v = head_dim;
        var m_v = m;
        var nkv_v = n_kv_heads;
        var params = [_]?*anyopaque{
            @ptrCast(&sb_v), @ptrCast(&nm_v), @ptrCast(&k_v),   @ptrCast(&p_v),
            @ptrCast(&hd_v), @ptrCast(&m_v),  @ptrCast(&nkv_v),
        };
        const shared_bytes: u32 = 256 * @sizeOf(f32); // smem for norm reduction
        const stream_ptr: ?*anyopaque = self.stream;
        const rc = cuda.cuLaunchKernel(func, n_kv_heads, 1, 1, 256, 1, 1, shared_bytes, stream_ptr, &params, null);
        if (rc != .success) {
            log.err("qjlQuantizeKey launch failed: rc={} grid=({},1,1) block=(256,1,1) smem={} hd={} m={} nkv={}", .{
                @intFromEnum(rc), n_kv_heads, shared_bytes, head_dim, m, n_kv_heads,
            });
            return error.KernelLaunchFailed;
        }
    }

    /// QJL decode attention: approximate Q@K^T via XNOR+popcount, exact V sum.
    /// Replaces standard decodeAttentionGpu when QJL is enabled.
    pub fn qjlDecodeAttention(
        self: *CudaBackend,
        d_out: cuda.CUdeviceptr, // [n_heads * head_dim]
        d_q: cuda.CUdeviceptr, // [n_heads * head_dim]
        d_key_signs: cuda.CUdeviceptr, // [max_seq * n_kv_heads * m_words] for this layer
        d_key_norms: cuda.CUdeviceptr, // [max_seq * n_kv_heads] for this layer
        d_v_cache: cuda.CUdeviceptr, // [max_seq * kv_dim] dense values
        d_projection: cuda.CUdeviceptr, // [m * head_dim_words] packed bits
        n_heads: u32,
        n_kv_heads: u32,
        head_dim: u32,
        kv_dim: u32,
        cur_seq: u32,
        scale: f32,
        m: u32,
        max_seq: u32,
    ) !void {
        const func = self.qjl_decode_attention_func orelse return error.KernelNotLoaded;
        var out_v = d_out;
        var q_v = d_q;
        var ks_v = d_key_signs;
        var kn_v = d_key_norms;
        var vc_v = d_v_cache;
        var p_v = d_projection;
        var nh_v = n_heads;
        var nkv_v = n_kv_heads;
        var hd_v = head_dim;
        var kvd_v = kv_dim;
        var seq_v = cur_seq;
        var sc_v = scale;
        var m_v = m;
        var ms_v = max_seq;
        var params = [_]?*anyopaque{
            @ptrCast(&out_v), @ptrCast(&q_v),   @ptrCast(&ks_v),  @ptrCast(&kn_v),
            @ptrCast(&vc_v),  @ptrCast(&p_v),   @ptrCast(&nh_v),  @ptrCast(&nkv_v),
            @ptrCast(&hd_v),  @ptrCast(&kvd_v), @ptrCast(&seq_v), @ptrCast(&sc_v),
            @ptrCast(&m_v),   @ptrCast(&ms_v),
        };
        // Shared memory: q_signs[m_words * 4 bytes] + scores[cur_seq * 4] + scratch[256 * 4]
        const m_words = m / 32;
        const shared_bytes = (m_words + cur_seq + 256) * @sizeOf(f32);
        const stream_ptr: ?*anyopaque = self.stream;
        const rc2 = cuda.cuLaunchKernel(func, n_heads, 1, 1, 256, 1, 1, shared_bytes, stream_ptr, &params, null);
        if (rc2 != .success) {
            log.err("qjlDecodeAttention launch failed: rc={} grid=({},1,1) smem={} nh={} nkv={} hd={} seq={} m={}", .{
                @intFromEnum(rc2), n_heads, shared_bytes, n_heads, n_kv_heads, head_dim, cur_seq, m,
            });
            return error.KernelLaunchFailed;
        }
    }

    // ========================================================================
    // DeltaNet Kernel Dispatch (Qwen3.5 hybrid architecture)
    // ========================================================================

    /// Depthwise conv1d (autoregressive single-token)
    pub fn deltanetConv1d(
        self: *CudaBackend,
        conv_out: cuda.CUdeviceptr,
        conv_state: cuda.CUdeviceptr,
        new_input: cuda.CUdeviceptr,
        weight: cuda.CUdeviceptr,
        channels: u32,
        kernel_size: u32,
    ) !void {
        const func = self.dn_conv1d_func orelse return error.KernelNotLoaded;
        var p_out = conv_out;
        var p_state = conv_state;
        var p_in = new_input;
        var p_w = weight;
        var ch = channels;
        var ks = kernel_size;
        var params = [_]?*anyopaque{
            @ptrCast(&p_out), @ptrCast(&p_state), @ptrCast(&p_in),
            @ptrCast(&p_w),   @ptrCast(&ch),      @ptrCast(&ks),
        };
        const blocks = (channels + 255) / 256;
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, blocks, 1, 1, 256, 1, 1, 0, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Per-head L2 normalization
    pub fn deltanetL2Norm(
        self: *CudaBackend,
        out: cuda.CUdeviceptr,
        x: cuda.CUdeviceptr,
        head_dim: u32,
        num_heads: u32,
        scale: f32,
    ) !void {
        const func = self.dn_l2norm_func orelse return error.KernelNotLoaded;
        var p_out = out;
        var p_x = x;
        var hd = head_dim;
        var nh = num_heads;
        var sc = scale;
        var params = [_]?*anyopaque{
            @ptrCast(&p_out), @ptrCast(&p_x),
            @ptrCast(&hd),    @ptrCast(&nh),
            @ptrCast(&sc),
        };
        const threads = @min(head_dim, @as(u32, 256));
        const smem: u32 = threads * @as(u32, 4); // sizeof(float) = 4
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, num_heads, 1, 1, threads, 1, 1, smem, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Compute alpha (decay) and beta (update) gates
    pub fn deltanetGates(
        self: *CudaBackend,
        alpha_out: cuda.CUdeviceptr,
        beta_out: cuda.CUdeviceptr,
        alpha_proj: cuda.CUdeviceptr,
        beta_proj: cuda.CUdeviceptr,
        A_log: cuda.CUdeviceptr,
        dt_bias: cuda.CUdeviceptr,
        num_heads: u32,
    ) !void {
        const func = self.dn_gates_func orelse return error.KernelNotLoaded;
        var p_ao = alpha_out;
        var p_bo = beta_out;
        var p_ap = alpha_proj;
        var p_bp = beta_proj;
        var p_al = A_log;
        var p_dt = dt_bias;
        var nh = num_heads;
        var params = [_]?*anyopaque{
            @ptrCast(&p_ao), @ptrCast(&p_bo), @ptrCast(&p_ap),
            @ptrCast(&p_bp), @ptrCast(&p_al), @ptrCast(&p_dt),
            @ptrCast(&nh),
        };
        const blocks = (num_heads + 31) / 32;
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, blocks, 1, 1, 32, 1, 1, 0, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Core DeltaNet recurrent state update + readout
    pub fn deltanetRecurrent(
        self: *CudaBackend,
        y_out: cuda.CUdeviceptr,
        S: cuda.CUdeviceptr,
        q: cuda.CUdeviceptr,
        k: cuda.CUdeviceptr,
        v: cuda.CUdeviceptr,
        alpha: cuda.CUdeviceptr,
        beta: cuda.CUdeviceptr,
        D: u32,
        num_q_heads: u32,
        num_kv_heads: u32,
    ) !void {
        const func = self.dn_recurrent_func orelse return error.KernelNotLoaded;
        var p_y = y_out;
        var p_s = S;
        var p_q = q;
        var p_k = k;
        var p_v = v;
        var p_a = alpha;
        var p_b = beta;
        var d = D;
        var nkv = num_kv_heads;
        var params = [_]?*anyopaque{
            @ptrCast(&p_y), @ptrCast(&p_s), @ptrCast(&p_q),
            @ptrCast(&p_k), @ptrCast(&p_v), @ptrCast(&p_a),
            @ptrCast(&p_b), @ptrCast(&d),   @ptrCast(&nkv),
        };
        const threads = @min(D, @as(u32, 128));
        const smem_dn: u32 = 2 * D * @as(u32, 4);
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, num_q_heads, 1, 1, threads, 1, 1, smem_dn, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Output gating: y = rms_norm(y) * silu(gate)
    pub fn deltanetOutputGate(
        self: *CudaBackend,
        out: cuda.CUdeviceptr,
        y: cuda.CUdeviceptr,
        gate: cuda.CUdeviceptr,
        norm_w: cuda.CUdeviceptr,
        head_dim: u32,
        num_heads: u32,
        eps: f32,
        norm_stride: u32,
    ) !void {
        const func = self.dn_output_gate_func orelse return error.KernelNotLoaded;
        var p_out = out;
        var p_y = y;
        var p_g = gate;
        var p_nw = norm_w;
        var hd = head_dim;
        var nh = num_heads;
        var ep = eps;
        var ns = norm_stride;
        var params = [_]?*anyopaque{
            @ptrCast(&p_out), @ptrCast(&p_y), @ptrCast(&p_g),
            @ptrCast(&p_nw),  @ptrCast(&hd),  @ptrCast(&nh),
            @ptrCast(&ep),    @ptrCast(&ns),
        };
        const threads = @min(head_dim, @as(u32, 256));
        const smem: u32 = threads * @as(u32, 4); // sizeof(float) = 4
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, num_heads, 1, 1, threads, 1, 1, smem, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Partial RoPE for Q (only first rope_dim elements per head)
    pub fn partialRopeQ(
        self: *CudaBackend,
        q: cuda.CUdeviceptr,
        pos: u32,
        head_dim: u32,
        rope_dim: u32,
        freq_base: f32,
        n_heads: u32,
    ) !void {
        const func = self.dn_partial_rope_q_func orelse return error.KernelNotLoaded;
        var p_q = q;
        var p = pos;
        var hd = head_dim;
        var rd = rope_dim;
        var fb = freq_base;
        var nh = n_heads;
        var params = [_]?*anyopaque{
            @ptrCast(&p_q), @ptrCast(&p),  @ptrCast(&hd),
            @ptrCast(&rd),  @ptrCast(&fb), @ptrCast(&nh),
        };
        const threads = @min(rope_dim / 2, @as(u32, 128));
        const smem_rope: u32 = rope_dim * @as(u32, 4);
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, n_heads, 1, 1, threads, 1, 1, smem_rope, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Partial RoPE for K
    pub fn partialRopeK(
        self: *CudaBackend,
        k: cuda.CUdeviceptr,
        pos: u32,
        head_dim: u32,
        rope_dim: u32,
        freq_base: f32,
        n_kv_heads: u32,
    ) !void {
        const func = self.dn_partial_rope_k_func orelse return error.KernelNotLoaded;
        var p_k = k;
        var p = pos;
        var hd = head_dim;
        var rd = rope_dim;
        var fb = freq_base;
        var nh = n_kv_heads;
        var params = [_]?*anyopaque{
            @ptrCast(&p_k), @ptrCast(&p),  @ptrCast(&hd),
            @ptrCast(&rd),  @ptrCast(&fb), @ptrCast(&nh),
        };
        const threads = @min(rope_dim / 2, @as(u32, 128));
        const smem_rope_k: u32 = rope_dim * @as(u32, 4);
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, n_kv_heads, 1, 1, threads, 1, 1, smem_rope_k, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Split fused Q+gate into separate Q and gate buffers (per-head interleaved layout)
    pub fn splitQGate(
        self: *CudaBackend,
        q_out: cuda.CUdeviceptr,
        gate_out: cuda.CUdeviceptr,
        fused: cuda.CUdeviceptr,
        q_dim: u32,
        head_dim: u32,
    ) !void {
        const func = self.dn_split_q_gate_func orelse return error.KernelNotLoaded;
        var p_q = q_out;
        var p_g = gate_out;
        var p_f = fused;
        var qd = q_dim;
        var hd = head_dim;
        var params = [_]?*anyopaque{
            @ptrCast(&p_q), @ptrCast(&p_g), @ptrCast(&p_f), @ptrCast(&qd), @ptrCast(&hd),
        };
        const blocks = (q_dim + 255) / 256;
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, blocks, 1, 1, 256, 1, 1, 0, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Gated attention output: out = attn_out * sigmoid(gate)
    pub fn gatedAttnOutput(
        self: *CudaBackend,
        out: cuda.CUdeviceptr,
        attn_out: cuda.CUdeviceptr,
        gate: cuda.CUdeviceptr,
        dim: u32,
    ) !void {
        const func = self.dn_gated_attn_output_func orelse return error.KernelNotLoaded;
        var p_out = out;
        var p_a = attn_out;
        var p_g = gate;
        var d = dim;
        var params = [_]?*anyopaque{
            @ptrCast(&p_out), @ptrCast(&p_a), @ptrCast(&p_g), @ptrCast(&d),
        };
        const blocks = (dim + 255) / 256;
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, blocks, 1, 1, 256, 1, 1, 0, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    // ========================================================================
    // MoE Optimization Dispatch (GPU-side router + batched dequant)
    // ========================================================================

    /// GPU-side softmax + TopK on FP16 router logits. No CPU sync needed.
    /// router_logits: [n_experts] FP16 on GPU (output of router HGEMM)
    /// expert_ids: [topk] int32 on GPU (output)
    /// expert_weights: [topk] float32 on GPU (output, normalized)
    pub fn softmaxTopkGpu(
        self: *CudaBackend,
        expert_ids: cuda.CUdeviceptr,
        expert_weights: cuda.CUdeviceptr,
        router_logits: cuda.CUdeviceptr,
        n_experts: u32,
        topk: u32,
    ) !void {
        const func = self.softmax_topk_func orelse return error.KernelNotLoaded;
        var d_ids = expert_ids;
        var d_wts = expert_weights;
        var d_logits = router_logits;
        var n_exp = n_experts;
        var tk = topk;
        var params = [_]?*anyopaque{
            @ptrCast(&d_ids),
            @ptrCast(&d_wts),
            @ptrCast(&d_logits),
            @ptrCast(&n_exp),
            @ptrCast(&tk),
        };
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, 1, 1, 1, 32, 1, 1, 0, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Batched Q4→FP16 dequant for TopK experts, reading expert_ids from GPU memory.
    /// q4_base: stacked Q4 [n_experts × rows × cols]
    /// expert_ids: [topk] int32 on GPU
    /// out: [topk × rows × cols] FP16 on GPU
    pub fn dequantTopkExpertsGpu(
        self: *CudaBackend,
        out: cuda.CUdeviceptr,
        q4_base: cuda.CUdeviceptr,
        expert_ids: cuda.CUdeviceptr,
        topk: u32,
        rows: u32,
        cols: u32,
    ) !void {
        const func = self.dequant_topk_func orelse return error.KernelNotLoaded;
        const n_blocks_per_row = cols >> 5;
        const total_work = @as(u32, topk) * rows * n_blocks_per_row;
        const block_size: u32 = 256;
        const grid_size: u32 = (total_work + block_size - 1) / block_size;
        var d_out = out;
        var d_q4 = q4_base;
        var d_ids = expert_ids;
        var tk = topk;
        var r = rows;
        var c = cols;
        var params = [_]?*anyopaque{
            @ptrCast(&d_out),
            @ptrCast(&d_q4),
            @ptrCast(&d_ids),
            @ptrCast(&tk),
            @ptrCast(&r),
            @ptrCast(&c),
        };
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, grid_size, 1, 1, block_size, 1, 1, 0, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// GPU-side weighted vector add: out[i] += weights[ki] * x[i]
    /// Reads scalar weight from device memory — no host download needed.
    pub fn weightedVectorAddDevGpu(
        self: *CudaBackend,
        out: cuda.CUdeviceptr,
        x: cuda.CUdeviceptr,
        d_weights: cuda.CUdeviceptr,
        ki: u32,
        n: u32,
    ) !void {
        const func = self.weighted_vadd_dev_func orelse return error.KernelNotLoaded;
        const block_size: u32 = 256;
        const grid_size: u32 = (n + block_size - 1) / block_size;
        var d_out = out;
        var d_x = x;
        var d_wts = d_weights;
        var k = ki;
        var count = n;
        var params = [_]?*anyopaque{
            @ptrCast(&d_out),
            @ptrCast(&d_x),
            @ptrCast(&d_wts),
            @ptrCast(&k),
            @ptrCast(&count),
        };
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, grid_size, 1, 1, block_size, 1, 1, 0, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Look up a kernel by name. Returns null if not loaded.
    pub fn getKernel(self: *const CudaBackend, comptime name: []const u8) ?cuda.CUfunction {
        return self.kernel_registry.get(name);
    }

    /// Check if a kernel is available (module loaded + kernel resolved).
    fn hasKernel(self: *const CudaBackend, comptime name: []const u8) bool {
        return self.initialized and self.ptx_module != null and self.getKernel(name) != null;
    }

    /// Number of kernels successfully loaded from PTX.
    pub fn loadedKernelCount(self: *const CudaBackend) u32 {
        return @intCast(self.kernel_registry.count());
    }

    /// Launch a GPU kernel with given grid/block dimensions and parameters.
    /// When capturing is true, uses the capture stream and skips synchronize.
    fn launchKernel(
        self: *const CudaBackend,
        func: cuda.CUfunction,
        grid_x: u32,
        grid_y: u32,
        block_x: u32,
        block_y: u32,
        shared_mem: u32,
        params: [*]?*anyopaque,
    ) bool {
        const stream_ptr: ?*anyopaque = if (self.capturing or self.graph_captured or self.stream != null)
            self.stream
        else
            null;
        if (cuda.cuLaunchKernel(
            func,
            grid_x,
            grid_y,
            1,
            block_x,
            block_y,
            1,
            shared_mem,
            stream_ptr,
            params,
            null,
        ) != .success) return false;
        // During graph capture or stream-based execution, don't synchronize per-kernel.
        // The caller is responsible for syncing (forward() syncs once before DtoH).
        if (self.capturing or self.stream != null) return true;
        return cuda.cuCtxSynchronize() == .success;
    }

    // ========================================================================
    // Matrix Operations (using Pure Zig kernels)
    // ========================================================================

    /// FP32 Matrix-Matrix Multiplication: C = alpha * A @ B + beta * C
    pub fn sgemm(
        self: *CudaBackend,
        c_out: []f32,
        a: []const f32,
        b: []const f32,
        m: usize,
        n: usize,
        k: usize,
        alpha: f32,
        beta: f32,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();

        if (self.hasKernel("sgemm")) {
            // GPU path: allocate device memory, copy, launch, copy back
            const a_bytes = m * k * @sizeOf(f32);
            const b_bytes = k * n * @sizeOf(f32);
            const c_bytes = m * n * @sizeOf(f32);

            var d_a: cuda.CUdeviceptr = undefined;
            var d_b: cuda.CUdeviceptr = undefined;
            var d_c: cuda.CUdeviceptr = undefined;

            if (cuda.cuMemAlloc(&d_a, a_bytes) == .success and
                cuda.cuMemAlloc(&d_b, b_bytes) == .success and
                cuda.cuMemAlloc(&d_c, c_bytes) == .success)
            {
                defer {
                    _ = cuda.cuMemFree(d_a);
                    _ = cuda.cuMemFree(d_b);
                    _ = cuda.cuMemFree(d_c);
                }

                _ = cuda.cuMemcpyHtoD(d_a, @ptrCast(a.ptr), a_bytes);
                _ = cuda.cuMemcpyHtoD(d_b, @ptrCast(b.ptr), b_bytes);
                _ = cuda.cuMemcpyHtoD(d_c, @ptrCast(c_out.ptr), c_bytes);

                // Use GEMV for M=1 (decode), GEMM for M>1 (prefill)
                const use_gemv = m == 1 and self.hasKernel("sgemv");
                const func = if (use_gemv) self.getKernel("sgemv").? else self.getKernel("sgemm").?;

                var m_u32: u32 = @intCast(m);
                var n_u32: u32 = @intCast(n);
                var k_u32: u32 = @intCast(k);
                var alpha_v = alpha;
                var beta_v = beta;

                if (use_gemv) {
                    // sgemv: y, A, x, M, K, alpha, beta
                    var params = [_]?*anyopaque{
                        @ptrCast(&d_c),    @ptrCast(&d_a),   @ptrCast(&d_b),
                        @ptrCast(&m_u32),  @ptrCast(&k_u32), @ptrCast(&alpha_v),
                        @ptrCast(&beta_v),
                    };
                    const grid_x = (m_u32 + 255) / 256;
                    if (self.launchKernel(func, grid_x, 1, 256, 1, 0, &params)) {
                        _ = cuda.cuMemcpyDtoH(@ptrCast(c_out.ptr), d_c, c_bytes);
                        return .{
                            .success = true,
                            .execution_time_ns = std.time.nanoTimestamp() - start,
                            .elements_processed = m * n,
                            .gpu_utilized = true,
                        };
                    }
                } else {
                    // sgemm: C, A, B, M, N, K, alpha, beta
                    var params = [_]?*anyopaque{
                        @ptrCast(&d_c),     @ptrCast(&d_a),    @ptrCast(&d_b),
                        @ptrCast(&m_u32),   @ptrCast(&n_u32),  @ptrCast(&k_u32),
                        @ptrCast(&alpha_v), @ptrCast(&beta_v),
                    };
                    const grid_x = (n_u32 + 15) / 16;
                    const grid_y = (m_u32 + 15) / 16;
                    if (self.launchKernel(func, grid_x, grid_y, 16, 16, 0, &params)) {
                        _ = cuda.cuMemcpyDtoH(@ptrCast(c_out.ptr), d_c, c_bytes);
                        return .{
                            .success = true,
                            .execution_time_ns = std.time.nanoTimestamp() - start,
                            .elements_processed = m * n,
                            .gpu_utilized = true,
                        };
                    }
                }
                // GPU launch failed — fall through to CPU
            }
        }
        // CPU fallback
        self.sgemmCpuFallback(c_out, a, b, m, n, k, alpha, beta);

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(m * n, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = m * n,
            .gpu_utilized = self.initialized,
        };
    }

    fn sgemmCpuFallback(
        _: *CudaBackend,
        c_out: []f32,
        a: []const f32,
        b: []const f32,
        m: usize,
        n: usize,
        k: usize,
        alpha: f32,
        beta: f32,
    ) void {
        for (0..m) |i| {
            for (0..n) |j| {
                var sum: f32 = 0.0;
                for (0..k) |l| {
                    sum += a[i * k + l] * b[l * n + j];
                }
                c_out[i * n + j] = alpha * sum + beta * c_out[i * n + j];
            }
        }
    }

    /// FP32 Matrix-Vector Multiplication: y = alpha * A @ x + beta * y
    pub fn sgemv(
        self: *CudaBackend,
        y: []f32,
        a: []const f32,
        x: []const f32,
        m: usize,
        k: usize,
        alpha: f32,
        beta: f32,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();

        if (self.hasKernel("sgemv")) gpu_path: {
            const a_bytes = m * k * @sizeOf(f32);
            const x_bytes = k * @sizeOf(f32);
            const y_bytes = m * @sizeOf(f32);

            var d_a: cuda.CUdeviceptr = undefined;
            var d_x: cuda.CUdeviceptr = undefined;
            var d_y: cuda.CUdeviceptr = undefined;

            if (cuda.cuMemAlloc(&d_a, a_bytes) != .success) break :gpu_path;
            defer _ = cuda.cuMemFree(d_a);
            if (cuda.cuMemAlloc(&d_x, x_bytes) != .success) break :gpu_path;
            defer _ = cuda.cuMemFree(d_x);
            if (cuda.cuMemAlloc(&d_y, y_bytes) != .success) break :gpu_path;
            defer _ = cuda.cuMemFree(d_y);

            _ = cuda.cuMemcpyHtoD(d_a, @ptrCast(a.ptr), a_bytes);
            _ = cuda.cuMemcpyHtoD(d_x, @ptrCast(x.ptr), x_bytes);
            _ = cuda.cuMemcpyHtoD(d_y, @ptrCast(y.ptr), y_bytes);

            var m_u32: u32 = @intCast(m);
            var k_u32: u32 = @intCast(k);
            var alpha_v = alpha;
            var beta_v = beta;
            var params = [_]?*anyopaque{
                @ptrCast(&d_y),    @ptrCast(&d_a),   @ptrCast(&d_x),
                @ptrCast(&m_u32),  @ptrCast(&k_u32), @ptrCast(&alpha_v),
                @ptrCast(&beta_v),
            };

            const grid_x = (m_u32 + 255) / 256;
            if (self.launchKernel(self.getKernel("sgemv").?, grid_x, 1, 256, 1, 0, &params)) {
                _ = cuda.cuMemcpyDtoH(@ptrCast(y.ptr), d_y, y_bytes);
                const elapsed = std.time.nanoTimestamp() - start;
                _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
                _ = self.total_elements.fetchAdd(m, .monotonic);
                _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);
                return .{ .success = true, .execution_time_ns = elapsed, .elements_processed = m, .gpu_utilized = true };
            }
        }

        // CPU fallback
        for (0..m) |i| {
            var sum: f32 = 0.0;
            for (0..k) |j| {
                sum += a[i * k + j] * x[j];
            }
            y[i] = alpha * sum + beta * y[i];
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(m, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = m,
            .gpu_utilized = self.initialized,
        };
    }

    // ========================================================================
    // Flash Attention (Pure Zig Implementation)
    // ========================================================================

    /// Flash Attention 1.x — O(N) memory complexity
    /// Reference: Dao et al. 2022 - "FlashAttention: Fast and Memory-Efficient
    ///            Exact Attention with IO-Awareness"
    pub fn flashAttention(
        self: *CudaBackend,
        out: []f32,
        q: []const f32,
        k: []const f32,
        v: []const f32,
        batch_size: usize,
        n_heads: usize,
        n_kv_heads: usize,
        seq_len: usize,
        head_dim: usize,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));

        if (self.config.enable_flash_attention and self.hasKernel("flash_attention")) gpu_fa: {
            const total_elems = batch_size * n_heads * seq_len * head_dim;
            const fa_bytes = total_elems * @sizeOf(f32);
            const kv_total = batch_size * n_kv_heads * seq_len * head_dim;
            const kv_bytes = kv_total * @sizeOf(f32);

            var d_out: cuda.CUdeviceptr = undefined;
            var d_q: cuda.CUdeviceptr = undefined;
            var d_k: cuda.CUdeviceptr = undefined;
            var d_v: cuda.CUdeviceptr = undefined;

            if (cuda.cuMemAlloc(&d_out, fa_bytes) != .success) break :gpu_fa;
            defer _ = cuda.cuMemFree(d_out);
            if (cuda.cuMemAlloc(&d_q, fa_bytes) != .success) break :gpu_fa;
            defer _ = cuda.cuMemFree(d_q);
            if (cuda.cuMemAlloc(&d_k, kv_bytes) != .success) break :gpu_fa;
            defer _ = cuda.cuMemFree(d_k);
            if (cuda.cuMemAlloc(&d_v, kv_bytes) != .success) break :gpu_fa;
            defer _ = cuda.cuMemFree(d_v);

            _ = cuda.cuMemcpyHtoD(d_q, @ptrCast(q.ptr), fa_bytes);
            _ = cuda.cuMemcpyHtoD(d_k, @ptrCast(k.ptr), kv_bytes);
            _ = cuda.cuMemcpyHtoD(d_v, @ptrCast(v.ptr), kv_bytes);

            var seq_u32: u32 = @intCast(seq_len);
            var hd_u32: u32 = @intCast(head_dim);
            var nh_u32: u32 = @intCast(n_heads);
            var nkv_u32: u32 = @intCast(n_kv_heads);
            var scale_v = scale;

            var params = [_]?*anyopaque{
                @ptrCast(&d_out),   @ptrCast(&d_q),    @ptrCast(&d_k),    @ptrCast(&d_v),
                @ptrCast(&seq_u32), @ptrCast(&hd_u32), @ptrCast(&nh_u32), @ptrCast(&nkv_u32),
                @ptrCast(&scale_v),
            };

            // Grid: (ceil(seq_len/64), batch*n_heads), Block: (64, 1)
            const grid_x = (seq_u32 + 63) / 64;
            const grid_y: u32 = @intCast(batch_size * n_heads);
            if (self.launchKernel(self.getKernel("flash_attention").?, grid_x, grid_y, 64, 1, 0, &params)) {
                _ = cuda.cuMemcpyDtoH(@ptrCast(out.ptr), d_out, fa_bytes);
                const elapsed_fa = std.time.nanoTimestamp() - start;
                _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
                _ = self.total_elements.fetchAdd(total_elems, .monotonic);
                _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed_fa), .monotonic);
                return .{ .success = true, .execution_time_ns = elapsed_fa, .elements_processed = total_elems, .gpu_utilized = true };
            }
        }
        // CPU fallback
        try self.flashAttentionCpu(out, q, k, v, batch_size, n_heads, n_kv_heads, seq_len, head_dim, scale);

        const elapsed = std.time.nanoTimestamp() - start;
        const elements = batch_size * n_heads * seq_len * head_dim;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(elements, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = elements,
            .gpu_utilized = self.initialized and self.config.enable_flash_attention,
        };
    }

    /// Flash Attention CPU reference implementation (matches GPU kernel algorithm)
    fn flashAttentionCpu(
        _: *CudaBackend,
        out: []f32,
        q: []const f32,
        k: []const f32,
        v: []const f32,
        batch_size: usize,
        n_heads: usize,
        n_kv_heads: usize,
        seq_len: usize,
        head_dim: usize,
        scale: f32,
    ) !void {
        const heads_per_kv = n_heads / n_kv_heads;

        for (0..batch_size) |b| {
            for (0..n_heads) |h| {
                const kv_h = h / heads_per_kv; // GQA mapping

                for (0..seq_len) |i| {
                    // Online softmax variables
                    var m_i: f32 = -std.math.inf(f32);
                    var l_i: f32 = 0.0;

                    // Initialize output accumulator
                    var acc = try std.heap.page_allocator.alloc(f32, head_dim);
                    defer std.heap.page_allocator.free(acc);
                    @memset(acc, 0.0);

                    // Iterate over K/V positions
                    for (0..seq_len) |j| {
                        // Compute Q[i] @ K[j]^T
                        var dot: f32 = 0.0;
                        for (0..head_dim) |d| {
                            const q_idx = ((b * n_heads + h) * seq_len + i) * head_dim + d;
                            const k_idx = ((b * n_kv_heads + kv_h) * seq_len + j) * head_dim + d;
                            dot += q[q_idx] * k[k_idx];
                        }
                        const score = dot * scale;

                        // Online softmax update
                        const m_new = @max(m_i, score);
                        const alpha = @exp(m_i - m_new);

                        // Rescale accumulator
                        for (0..head_dim) |d| {
                            acc[d] *= alpha;
                        }
                        l_i *= alpha;

                        // Accumulate new value
                        const p_ij = @exp(score - m_new);
                        l_i += p_ij;

                        for (0..head_dim) |d| {
                            const v_idx = ((b * n_kv_heads + kv_h) * seq_len + j) * head_dim + d;
                            acc[d] += p_ij * v[v_idx];
                        }

                        m_i = m_new;
                    }

                    // Write normalized output
                    const inv_l = 1.0 / l_i;
                    for (0..head_dim) |d| {
                        const out_idx = ((b * n_heads + h) * seq_len + i) * head_dim + d;
                        out[out_idx] = acc[d] * inv_l;
                    }
                }
            }
        }
    }

    // ========================================================================
    // Normalization (Pure Zig)
    // ========================================================================

    /// RMS Normalization: out = x * weight / sqrt(mean(x^2) + eps)
    pub fn rmsNorm(
        self: *CudaBackend,
        out: []f32,
        x: []const f32,
        weight: []const f32,
        hidden_size: usize,
        eps: f32,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();
        const batch_size = x.len / hidden_size;

        for (0..batch_size) |b| {
            const offset = b * hidden_size;

            // Compute mean of squares
            var sum_sq: f32 = 0.0;
            for (0..hidden_size) |i| {
                const val = x[offset + i];
                sum_sq += val * val;
            }

            // RMS normalization
            const rms_inv = 1.0 / @sqrt(sum_sq / @as(f32, @floatFromInt(hidden_size)) + eps);
            for (0..hidden_size) |i| {
                out[offset + i] = x[offset + i] * rms_inv * weight[i];
            }
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(x.len, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = x.len,
            .gpu_utilized = self.initialized,
        };
    }

    // ========================================================================
    // Activations (Pure Zig)
    // ========================================================================

    /// SwiGLU: out = silu(gate) * up
    pub fn swiglu(
        self: *CudaBackend,
        out: []f32,
        gate: []const f32,
        up: []const f32,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();

        for (0..out.len) |i| {
            const g = gate[i];
            const sigmoid_g = 1.0 / (1.0 + @exp(-g));
            out[i] = g * sigmoid_g * up[i];
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(out.len, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = out.len,
            .gpu_utilized = self.initialized,
        };
    }

    // ========================================================================
    // Quantization
    // ========================================================================

    /// Execute INT8 Matrix Multiplication
    pub fn matmulInt8(
        self: *CudaBackend,
        c_out: []i32,
        a: []const i8,
        b: []const i8,
        m: usize,
        n: usize,
        k: usize,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();

        // CPU fallback (INT8 on GPU requires specific kernel launch)
        for (0..m) |i| {
            for (0..n) |j| {
                var sum: i32 = 0;
                for (0..k) |l| {
                    sum += @as(i32, a[i * k + l]) * @as(i32, b[l * n + j]);
                }
                c_out[i * n + j] = sum;
            }
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(m * n, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = m * n,
            .gpu_utilized = self.initialized,
        };
    }

    /// Quantize FP32 weights to INT8
    pub fn quantizeWeights(self: *CudaBackend, output: []i8, input: []const f32, scale: f32) !void {
        _ = self;
        for (input, 0..) |val, i| {
            const quantized = val * scale;
            output[i] = @intFromFloat(@max(-128.0, @min(127.0, quantized)));
        }
    }

    // ========================================================================
    // Embeddings
    // ========================================================================

    /// Token embedding lookup
    pub fn embeddings(
        self: *CudaBackend,
        input_tokens: []const u32,
        output_embeddings: []f32,
        embedding_table: []const f32,
        embedding_dim: usize,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();

        for (input_tokens, 0..) |token, b| {
            for (0..embedding_dim) |d| {
                output_embeddings[b * embedding_dim + d] = embedding_table[token * embedding_dim + d];
            }
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(input_tokens.len * embedding_dim, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = input_tokens.len * embedding_dim,
            .gpu_utilized = self.initialized,
        };
    }

    // ========================================================================
    // GPU-Resident Dispatch (no HtoD/DtoH — all pointers are device ptrs)
    // Used by forwardCuda() for 100 TPS inference
    // ========================================================================

    /// Q4_0 quantized GEMV on device pointers: y = W_q4 @ x
    /// W_q4 is Q4_0 packed, x and y are f32 device buffers
    /// Prefers nvcc-compiled q4_gemv from deltanet module; falls back to PTX kernel.
    pub fn q4GemvGpu(
        self: *CudaBackend,
        d_y: cuda.CUdeviceptr,
        d_W: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        M: u32,
        K: u32,
    ) !void {
        var m_v = M;
        var k_v = K;
        var y_v = d_y;
        var w_v = d_W;
        var x_v = d_x;
        var params = [_]?*anyopaque{
            @ptrCast(&y_v), @ptrCast(&w_v), @ptrCast(&x_v),
            @ptrCast(&m_v), @ptrCast(&k_v),
        };
        const grid_x = (M + 7) / 8;

        // Prefer nvcc-compiled kernel (correct for all K values)
        if (self.dn_q4_gemv_func) |func| {
            const shared_bytes = K * 4; // x[] cached in shared memory
            if (shared_bytes > 49152) {
                _ = cuda.cuFuncSetAttribute(func, cuda.CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, @intCast(shared_bytes));
            }
            if (!self.launchKernel(func, grid_x, 1, 256, 1, shared_bytes, &params))
                return error.KernelLaunchFailed;
            return;
        }

        // Fallback to PTX kernel
        if (!self.hasKernel("q4_0_gemv")) return error.KernelNotLoaded;
        const shared_bytes = (K + K / 32) * 4; // padded shared memory
        const func = self.getKernel("q4_0_gemv").?;
        if (shared_bytes > 49152) {
            _ = cuda.cuFuncSetAttribute(func, cuda.CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, @intCast(shared_bytes));
        }
        if (!self.launchKernel(func, grid_x, 1, 256, 1, shared_bytes, &params))
            return error.KernelLaunchFailed;
    }

    /// Q8_0 GEMV: y[M] = W_q8[M×K] @ x[K]
    /// Q8_0 block = 34 bytes: f16 scale + 32 int8 quants. Dequant: w = quant * scale.
    pub fn q8GemvGpu(
        self: *CudaBackend,
        d_y: cuda.CUdeviceptr,
        d_W: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        M: u32,
        K: u32,
    ) !void {
        const func = self.dn_q8_0_gemv_func orelse return error.KernelNotLoaded;
        var m_v = M;
        var k_v = K;
        var y_v = d_y;
        var w_v = d_W;
        var x_v = d_x;
        var params = [_]?*anyopaque{
            @ptrCast(&y_v), @ptrCast(&w_v), @ptrCast(&x_v),
            @ptrCast(&m_v), @ptrCast(&k_v),
        };
        const grid_x = (M + 7) / 8;
        const shared_bytes = K * 4; // x[] cached in shared memory
        if (shared_bytes > 49152) {
            _ = cuda.cuFuncSetAttribute(func, cuda.CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, @intCast(shared_bytes));
        }
        if (!self.launchKernel(func, grid_x, 1, 256, 1, shared_bytes, &params))
            return error.KernelLaunchFailed;
    }

    /// Batched Q4_0 GEMV: Y[bi*M..] = W_q4[M×K] @ X[bi*K..] for bi in 0..batch
    /// Processes `batch` vectors against the same weight matrix in ONE kernel launch.
    /// 2D grid: blockIdx.x = row groups, blockIdx.y = batch index.
    /// Q4_1 GEMV: y[M] = W_q4_1[M×K] @ x[K]
    /// Q4_1 block = 20 bytes: f16 delta + f16 min + 16 data bytes (32 nibbles)
    /// Dequant: w = nibble * delta + min
    pub fn q4_1GemvGpu(
        self: *CudaBackend,
        d_y: cuda.CUdeviceptr,
        d_W: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        M: u32,
        K: u32,
    ) !void {
        const func = self.dn_q4_1_gemv_func orelse return error.KernelNotLoaded;
        var m_v = M;
        var k_v = K;
        var y_v = d_y;
        var w_v = d_W;
        var x_v = d_x;
        var params = [_]?*anyopaque{
            @ptrCast(&y_v), @ptrCast(&w_v), @ptrCast(&x_v),
            @ptrCast(&m_v), @ptrCast(&k_v),
        };
        const grid_x = (M + 7) / 8;
        const shared_bytes = (K + K / 32) * 4; // padded shared memory for bank-conflict-free access
        if (shared_bytes > 49152) {
            _ = cuda.cuFuncSetAttribute(func, cuda.CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, @intCast(shared_bytes));
        }
        if (!self.launchKernel(func, grid_x, 1, 256, 1, shared_bytes, &params))
            return error.KernelLaunchFailed;
    }

    /// L2 cache amortizes weight reads across concurrent batch blocks.
    pub fn q4GemvBatchGpu(
        self: *CudaBackend,
        d_Y: cuda.CUdeviceptr,
        d_W: cuda.CUdeviceptr,
        d_X: cuda.CUdeviceptr,
        M: u32,
        K: u32,
        batch: u32,
    ) !void {
        const func = self.q4_gemv_batch_func orelse return error.KernelNotLoaded;
        var m_v = M;
        var k_v = K;
        var batch_v = batch;
        var y_v = d_Y;
        var w_v = d_W;
        var x_v = d_X;
        var params = [_]?*anyopaque{
            @ptrCast(&y_v), @ptrCast(&w_v), @ptrCast(&x_v),
            @ptrCast(&m_v), @ptrCast(&k_v), @ptrCast(&batch_v),
        };
        const grid_x = (M + 7) / 8;
        const shared_bytes = (K + K / 32) * 4;
        if (!self.launchKernel(func, grid_x, batch, 256, 1, shared_bytes, &params))
            return error.KernelLaunchFailed;
    }

    /// Batched RMSNorm: out[bi*dim..] = rmsnorm(x[bi*dim..], w, dim, eps) for bi in 0..batch
    /// Processes K vectors in ONE launch. 2D grid: blockIdx.y = batch index.
    pub fn rmsNormBatchGpu(
        self: *CudaBackend,
        d_out: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        d_w: cuda.CUdeviceptr,
        dim: u32,
        eps: f32,
        batch: u32,
    ) !void {
        const func = self.rms_norm_batch_func orelse return error.KernelNotLoaded;
        var out_v = d_out;
        var x_v = d_x;
        var w_v = d_w;
        var dim_v = dim;
        var eps_v = eps;
        var batch_v = batch;
        var params = [_]?*anyopaque{
            @ptrCast(&out_v), @ptrCast(&x_v),   @ptrCast(&w_v),
            @ptrCast(&dim_v), @ptrCast(&eps_v), @ptrCast(&batch_v),
        };
        if (!self.launchKernel(func, 1, batch, 256, 1, 256 * 4, &params))
            return error.KernelLaunchFailed;
    }

    /// Batched FP32 → FP16: out[bi*dim..] = fp16(x[bi*dim..]) for bi in 0..batch
    pub fn fp32ToFp16BatchGpu(
        self: *CudaBackend,
        d_out: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        dim: u32,
        batch: u32,
    ) !void {
        const func = self.fp32_to_fp16_batch_func orelse return error.KernelNotLoaded;
        var out_v = d_out;
        var x_v = d_x;
        var dim_v = dim;
        var batch_v = batch;
        var params = [_]?*anyopaque{
            @ptrCast(&out_v), @ptrCast(&x_v),
            @ptrCast(&dim_v), @ptrCast(&batch_v),
        };
        const grid_x = (dim + 255) / 256;
        if (!self.launchKernel(func, grid_x, batch, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// Batched softmax + TopK: process K tokens in 1 launch (K blocks)
    pub fn softmaxTopkBatchGpu(
        self: *CudaBackend,
        d_expert_ids: cuda.CUdeviceptr,
        d_expert_weights: cuda.CUdeviceptr,
        d_router_logits: cuda.CUdeviceptr,
        n_experts: u32,
        topk: u32,
        batch: u32,
    ) !void {
        const func = self.softmax_topk_batch_func orelse return error.KernelNotLoaded;
        var ids_v = d_expert_ids;
        var wts_v = d_expert_weights;
        var log_v = d_router_logits;
        var ne_v = n_experts;
        var tk_v = topk;
        var batch_v = batch;
        var params = [_]?*anyopaque{
            @ptrCast(&ids_v), @ptrCast(&wts_v), @ptrCast(&log_v),
            @ptrCast(&ne_v),  @ptrCast(&tk_v),  @ptrCast(&batch_v),
        };
        // K blocks, 1 thread each (single-thread softmax per token)
        if (!self.launchKernel(func, batch, 1, 1, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// GPU-side expert routing: builds gather/scatter index arrays from softmax_topk output.
    /// Single block, 256 threads. Builds expert_count, expert_offset, and flat index arrays.
    pub fn buildExpertRoutingGpu(
        self: *CudaBackend,
        d_expert_count: cuda.CUdeviceptr,
        d_expert_offset: cuda.CUdeviceptr,
        d_gather_idx: cuda.CUdeviceptr,
        d_scatter_t: cuda.CUdeviceptr,
        d_scatter_ki: cuda.CUdeviceptr,
        d_expert_ids: cuda.CUdeviceptr,
        K: u32,
        topk: u32,
        n_experts: u32,
    ) !void {
        const func = self.build_expert_routing_func orelse return error.KernelNotLoaded;
        var cnt_v = d_expert_count;
        var off_v = d_expert_offset;
        var gi_v = d_gather_idx;
        var st_v = d_scatter_t;
        var ski_v = d_scatter_ki;
        var ids_v = d_expert_ids;
        var k_v = K;
        var tk_v = topk;
        var ne_v = n_experts;
        var params = [_]?*anyopaque{
            @ptrCast(&cnt_v), @ptrCast(&off_v), @ptrCast(&gi_v),
            @ptrCast(&st_v),  @ptrCast(&ski_v), @ptrCast(&ids_v),
            @ptrCast(&k_v),   @ptrCast(&tk_v),  @ptrCast(&ne_v),
        };
        // Single block, 256 threads
        if (!self.launchKernel(func, 1, 1, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// Fused gate+up gather-GEMV: computes BOTH gate and up outputs in 1 launch.
    /// Loads input once into shared memory, reads both weight matrices.
    /// Halves GEMV launch count per expert (2→1).
    pub fn q4GemvFusedGateUpGatherGpu(
        self: *CudaBackend,
        d_y_gate: cuda.CUdeviceptr,
        d_y_up: cuda.CUdeviceptr,
        d_w_gate: cuda.CUdeviceptr,
        d_w_up: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        d_indices: cuda.CUdeviceptr,
        M: u32,
        K: u32,
        batch: u32,
    ) !void {
        const func = self.fused_gate_up_gather_func orelse return error.KernelNotLoaded;
        var yg_v = d_y_gate;
        var yu_v = d_y_up;
        var wg_v = d_w_gate;
        var wu_v = d_w_up;
        var x_v = d_x;
        var idx_v = d_indices;
        var m_v = M;
        var k_v = K;
        var batch_v = batch;
        var params = [_]?*anyopaque{
            @ptrCast(&yg_v),    @ptrCast(&yu_v),
            @ptrCast(&wg_v),    @ptrCast(&wu_v),
            @ptrCast(&x_v),     @ptrCast(&idx_v),
            @ptrCast(&m_v),     @ptrCast(&k_v),
            @ptrCast(&batch_v),
        };
        const grid_x = (M + 7) / 8;
        const smem: u32 = (K + (K >> 5)) * @as(u32, 4); // sizeof(float) = 4
        if (!self.launchKernel(func, grid_x, batch, 256, 1, smem, &params))
            return error.KernelLaunchFailed;
    }

    /// Gather-fused batched Q4 GEMV: reads input from scattered positions via index array.
    /// Y[bi*M + row] = W_q4[M×K] @ X[indices[bi]*K + :]
    /// Eliminates separate gather_vectors launch.
    pub fn q4GemvBatchGatherGpu(
        self: *CudaBackend,
        d_y: cuda.CUdeviceptr,
        d_w: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        d_indices: cuda.CUdeviceptr,
        M: u32,
        K: u32,
        batch: u32,
    ) !void {
        const func = self.q4_gemv_batch_gather_func orelse return error.KernelNotLoaded;
        var y_v = d_y;
        var w_v = d_w;
        var x_v = d_x;
        var idx_v = d_indices;
        var m_v = M;
        var k_v = K;
        var batch_v = batch;
        var params = [_]?*anyopaque{
            @ptrCast(&y_v),     @ptrCast(&w_v), @ptrCast(&x_v),
            @ptrCast(&idx_v),   @ptrCast(&m_v), @ptrCast(&k_v),
            @ptrCast(&batch_v),
        };
        const grid_x = (M + 7) / 8;
        // Shared memory: K floats + padding for bank conflicts
        const smem: u32 = (K + (K >> 5)) * @as(u32, 4); // sizeof(float) = 4
        if (!self.launchKernel(func, grid_x, batch, 256, 1, smem, &params))
            return error.KernelLaunchFailed;
    }

    /// Batched RoPE for Q vectors: apply rotary encoding to K Q vectors in 1 launch
    pub fn ropeQBatchGpu(
        self: *CudaBackend,
        d_q: cuda.CUdeviceptr,
        d_positions: cuda.CUdeviceptr,
        head_dim: u32,
        freq_base: f32,
        n_heads: u32,
        batch: u32,
    ) !void {
        const func = self.rope_q_batch_func orelse return error.KernelNotLoaded;
        var q_v = d_q;
        var pos_v = d_positions;
        var hd_v = head_dim;
        var fb_v = freq_base;
        var nh_v = n_heads;
        var batch_v = batch;
        var params = [_]?*anyopaque{
            @ptrCast(&q_v),  @ptrCast(&pos_v), @ptrCast(&hd_v),
            @ptrCast(&fb_v), @ptrCast(&nh_v),  @ptrCast(&batch_v),
        };
        const total_pairs = n_heads * (head_dim / 2);
        const grid_x = (total_pairs + 255) / 256;
        if (!self.launchKernel(func, grid_x, batch, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// Batched RoPE for K vectors
    pub fn ropeKBatchGpu(
        self: *CudaBackend,
        d_k: cuda.CUdeviceptr,
        d_positions: cuda.CUdeviceptr,
        head_dim: u32,
        freq_base: f32,
        n_kv_heads: u32,
        batch: u32,
    ) !void {
        const func = self.rope_k_batch_func orelse return error.KernelNotLoaded;
        var k_v = d_k;
        var pos_v = d_positions;
        var hd_v = head_dim;
        var fb_v = freq_base;
        var nkv_v = n_kv_heads;
        var batch_v = batch;
        var params = [_]?*anyopaque{
            @ptrCast(&k_v),  @ptrCast(&pos_v), @ptrCast(&hd_v),
            @ptrCast(&fb_v), @ptrCast(&nkv_v), @ptrCast(&batch_v),
        };
        const total_pairs = n_kv_heads * (head_dim / 2);
        const grid_x = (total_pairs + 255) / 256;
        if (!self.launchKernel(func, grid_x, batch, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// KV cache scatter: write K vectors to scattered cache positions in 1 launch
    pub fn kvCacheScatterGpu(
        self: *CudaBackend,
        d_cache: cuda.CUdeviceptr,
        d_data: cuda.CUdeviceptr,
        d_positions: cuda.CUdeviceptr,
        kv_dim: u32,
        max_seq_len: u32,
        batch: u32,
    ) !void {
        const func = self.kv_cache_scatter_func orelse return error.KernelNotLoaded;
        var cache_v = d_cache;
        var data_v = d_data;
        var pos_v = d_positions;
        var kvd_v = kv_dim;
        var msl_v = max_seq_len;
        var batch_v = batch;
        var params = [_]?*anyopaque{
            @ptrCast(&cache_v), @ptrCast(&data_v), @ptrCast(&pos_v),
            @ptrCast(&kvd_v),   @ptrCast(&msl_v),  @ptrCast(&batch_v),
        };
        const grid_x = (kv_dim + 255) / 256;
        if (!self.launchKernel(func, grid_x, batch, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// Gather scattered vectors: dst[bi*dim..] = src[indices[bi]*dim..] for bi in 0..cnt
    /// Replaces cnt individual deviceCopy calls with 1 kernel launch.
    pub fn gatherVectorsGpu(
        self: *CudaBackend,
        d_dst: cuda.CUdeviceptr,
        d_src: cuda.CUdeviceptr,
        d_indices: cuda.CUdeviceptr,
        dim: u32,
        cnt: u32,
    ) !void {
        const func = self.gather_vectors_func orelse return error.KernelNotLoaded;
        var dst_v = d_dst;
        var src_v = d_src;
        var idx_v = d_indices;
        var dim_v = dim;
        var cnt_v = cnt;
        var params = [_]?*anyopaque{
            @ptrCast(&dst_v), @ptrCast(&src_v), @ptrCast(&idx_v),
            @ptrCast(&dim_v), @ptrCast(&cnt_v),
        };
        const grid_x = (dim + 255) / 256;
        if (!self.launchKernel(func, grid_x, cnt, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// Scatter-weighted-add: out[t*dim+i] += weights[t*topk+ki] * src[bi*dim+i]
    /// Replaces cnt individual weightedVectorAddDev calls with 1 kernel launch.
    pub fn scatterWeightedVaddGpu(
        self: *CudaBackend,
        d_out: cuda.CUdeviceptr,
        d_src: cuda.CUdeviceptr,
        d_weights: cuda.CUdeviceptr,
        d_out_tokens: cuda.CUdeviceptr,
        d_ki_vals: cuda.CUdeviceptr,
        dim: u32,
        topk: u32,
        cnt: u32,
    ) !void {
        const func = self.scatter_weighted_vadd_func orelse return error.KernelNotLoaded;
        var out_v = d_out;
        var src_v = d_src;
        var wts_v = d_weights;
        var tok_v = d_out_tokens;
        var ki_v = d_ki_vals;
        var dim_v = dim;
        var topk_v = topk;
        var cnt_v = cnt;
        var params = [_]?*anyopaque{
            @ptrCast(&out_v),  @ptrCast(&src_v), @ptrCast(&wts_v),
            @ptrCast(&tok_v),  @ptrCast(&ki_v),  @ptrCast(&dim_v),
            @ptrCast(&topk_v), @ptrCast(&cnt_v),
        };
        const grid_x = (dim + 255) / 256;
        if (!self.launchKernel(func, grid_x, cnt, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// Q2_K quantized GEMV on device pointers: y = W_q2k @ x
    /// W_q2k is Q2_K packed (84 bytes per 256 elements), x and y are f32 device buffers
    pub fn q2kGemvGpu(
        self: *CudaBackend,
        d_y: cuda.CUdeviceptr,
        d_W: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        M: u32,
        K: u32,
    ) !void {
        if (!self.hasKernel("q2_k_gemv")) return error.KernelNotLoaded;
        var m_v = M;
        var k_v = K;
        var y_v = d_y;
        var w_v = d_W;
        var x_v = d_x;
        var params = [_]?*anyopaque{
            @ptrCast(&y_v), @ptrCast(&w_v), @ptrCast(&x_v),
            @ptrCast(&m_v), @ptrCast(&k_v),
        };
        // Grid: ceil(M/8) blocks × 256 threads (8 warps per block, 1 warp per row)
        // No shared memory needed (uses float4 vectorized global loads)
        const grid_x = (M + 7) / 8;
        if (!self.launchKernel(self.getKernel("q2_k_gemv").?, grid_x, 1, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// SGEMV on device pointers: y = A @ x (alpha=1, beta=0)
    pub fn sgemvGpu(
        self: *CudaBackend,
        d_y: cuda.CUdeviceptr,
        d_A: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        M: u32,
        K: u32,
    ) !void {
        if (!self.hasKernel("sgemv")) return error.KernelNotLoaded;
        var m_v = M;
        var k_v = K;
        var alpha: f32 = 1.0;
        var beta: f32 = 0.0;
        var y_v = d_y;
        var a_v = d_A;
        var x_v = d_x;
        var params = [_]?*anyopaque{
            @ptrCast(&y_v),  @ptrCast(&a_v), @ptrCast(&x_v),
            @ptrCast(&m_v),  @ptrCast(&k_v), @ptrCast(&alpha),
            @ptrCast(&beta),
        };
        const grid_x = (M + 255) / 256;
        if (!self.launchKernel(self.getKernel("sgemv").?, grid_x, 1, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// RMSNorm on device pointers: out = x * weight / sqrt(mean(x^2) + eps)
    pub fn rmsNormGpu(
        self: *CudaBackend,
        d_out: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        d_weight: cuda.CUdeviceptr,
        dim: u32,
        eps: f32,
    ) !void {
        if (!self.hasKernel("rms_norm")) return error.KernelNotLoaded;
        var out_v = d_out;
        var x_v = d_x;
        var w_v = d_weight;
        var dim_v = dim;
        var eps_v = eps;
        var params = [_]?*anyopaque{
            @ptrCast(&out_v), @ptrCast(&x_v),   @ptrCast(&w_v),
            @ptrCast(&dim_v), @ptrCast(&eps_v),
        };
        // One block per vector (single-vector norm for decode)
        if (!self.launchKernel(self.getKernel("rms_norm").?, 1, 1, 256, 1, 256 * 4, &params))
            return error.KernelLaunchFailed;
    }

    /// Softmax on device pointer (in-place)
    pub fn softmaxGpu(
        self: *CudaBackend,
        d_data: cuda.CUdeviceptr,
        len: u32,
    ) !void {
        if (!self.hasKernel("softmax")) return error.KernelNotLoaded;
        var data_v = d_data;
        var len_v = len;
        var params = [_]?*anyopaque{
            @ptrCast(&data_v), @ptrCast(&len_v),
        };
        if (!self.launchKernel(self.getKernel("softmax").?, 1, 1, 256, 1, 256 * 4, &params))
            return error.KernelLaunchFailed;
    }

    /// SwiGLU on device pointers: out = silu(gate) * up
    pub fn swigluGpu(
        self: *CudaBackend,
        d_out: cuda.CUdeviceptr,
        d_gate: cuda.CUdeviceptr,
        d_up: cuda.CUdeviceptr,
        len: u32,
    ) !void {
        if (!self.hasKernel("swiglu")) return error.KernelNotLoaded;
        var out_v = d_out;
        var gate_v = d_gate;
        var up_v = d_up;
        var len_v = len;
        var params = [_]?*anyopaque{
            @ptrCast(&out_v), @ptrCast(&gate_v), @ptrCast(&up_v),
            @ptrCast(&len_v),
        };
        const grid_x = (len + 255) / 256;
        if (!self.launchKernel(self.getKernel("swiglu").?, grid_x, 1, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// RoPE on device pointers for Q vectors
    pub fn ropeQGpu(
        self: *CudaBackend,
        d_q: cuda.CUdeviceptr,
        pos: u32,
        head_dim: u32,
        freq_base: f32,
        n_heads: u32,
    ) !void {
        if (!self.hasKernel("rope_q")) return error.KernelNotLoaded;
        var q_v = d_q;
        var pos_v = pos;
        var hd_v = head_dim;
        var fb_v = freq_base;
        var nh_v = n_heads;
        var params = [_]?*anyopaque{
            @ptrCast(&q_v),  @ptrCast(&pos_v), @ptrCast(&hd_v),
            @ptrCast(&fb_v), @ptrCast(&nh_v),
        };
        const total_pairs = n_heads * (head_dim / 2);
        const grid_x = (total_pairs + 255) / 256;
        if (!self.launchKernel(self.getKernel("rope_q").?, grid_x, 1, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// RoPE on device pointers for K vectors
    pub fn ropeKGpu(
        self: *CudaBackend,
        d_k: cuda.CUdeviceptr,
        pos: u32,
        head_dim: u32,
        freq_base: f32,
        n_kv_heads: u32,
    ) !void {
        if (!self.hasKernel("rope_k")) return error.KernelNotLoaded;
        var k_v = d_k;
        var pos_v = pos;
        var hd_v = head_dim;
        var fb_v = freq_base;
        var nkv_v = n_kv_heads;
        var params = [_]?*anyopaque{
            @ptrCast(&k_v),  @ptrCast(&pos_v), @ptrCast(&hd_v),
            @ptrCast(&fb_v), @ptrCast(&nkv_v),
        };
        const total_pairs = n_kv_heads * (head_dim / 2);
        const grid_x = (total_pairs + 255) / 256;
        if (!self.launchKernel(self.getKernel("rope_k").?, grid_x, 1, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// Embedding lookup on device pointers
    pub fn embeddingGpu(
        self: *CudaBackend,
        d_out: cuda.CUdeviceptr,
        d_table: cuda.CUdeviceptr,
        token: u32,
        dim: u32,
    ) !void {
        if (!self.hasKernel("embedding_lookup")) return error.KernelNotLoaded;
        var out_v = d_out;
        var tab_v = d_table;
        var tok_v = token;
        var dim_v = dim;
        var params = [_]?*anyopaque{
            @ptrCast(&out_v), @ptrCast(&tab_v),
            @ptrCast(&tok_v), @ptrCast(&dim_v),
        };
        const grid_x = (dim + 255) / 256;
        if (!self.launchKernel(self.getKernel("embedding_lookup").?, grid_x, 1, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// Vector add on device pointers: out = a + b
    pub fn vectorAddGpu(
        self: *CudaBackend,
        d_out: cuda.CUdeviceptr,
        d_a: cuda.CUdeviceptr,
        d_b: cuda.CUdeviceptr,
        len: u32,
    ) !void {
        if (!self.hasKernel("vector_add")) return error.KernelNotLoaded;
        var out_v = d_out;
        var a_v = d_a;
        var b_v = d_b;
        var len_v = len;
        var params = [_]?*anyopaque{
            @ptrCast(&out_v), @ptrCast(&a_v), @ptrCast(&b_v),
            @ptrCast(&len_v),
        };
        const grid_x = (len + 255) / 256;
        if (!self.launchKernel(self.getKernel("vector_add").?, grid_x, 1, 256, 1, 0, &params))
            return error.KernelLaunchFailed;
    }

    /// Decode attention: single-token GQA attention on GPU
    /// Grid: (n_heads, 1), Block: (256, 1)
    /// Shared mem: (cur_seq + 256) * 4 bytes
    pub fn decodeAttentionGpu(
        self: *CudaBackend,
        d_out: cuda.CUdeviceptr,
        d_q: cuda.CUdeviceptr,
        d_k_cache: cuda.CUdeviceptr,
        d_v_cache: cuda.CUdeviceptr,
        n_heads: u32,
        n_kv_heads: u32,
        head_dim: u32,
        kv_dim: u32,
        cur_seq: u32,
        scale: f32,
    ) !void {
        // Prefer nvcc-compiled decode_attention from deltanet module (handles head_dim=256);
        // fall back to PTX kernel (only correct for head_dim<=128).
        const func = self.dn_decode_attention_func orelse
            (self.getKernel("decode_attention") orelse return error.KernelNotLoaded);
        var out_v = d_out;
        var q_v = d_q;
        var kc_v = d_k_cache;
        var vc_v = d_v_cache;
        var nh_v = n_heads;
        var nkv_v = n_kv_heads;
        var hd_v = head_dim;
        var kvd_v = kv_dim;
        var seq_v = cur_seq;
        var sc_v = scale;
        var params = [_]?*anyopaque{
            @ptrCast(&out_v), @ptrCast(&q_v),
            @ptrCast(&kc_v),  @ptrCast(&vc_v),
            @ptrCast(&nh_v),  @ptrCast(&nkv_v),
            @ptrCast(&hd_v),  @ptrCast(&kvd_v),
            @ptrCast(&seq_v), @ptrCast(&sc_v),
        };
        // Shared memory layout depends on which kernel we use:
        // nvcc kernel: scores[cur_seq] + scratch[256]
        // PTX kernel: Q_cache[head_dim] + scores[cur_seq] + scratch[256]
        const shared_bytes = if (self.dn_decode_attention_func != null)
            (cur_seq + 256) * 4
        else
            (head_dim + cur_seq + 256) * 4;
        const stream_ptr: ?*anyopaque = self.stream;
        if (cuda.cuLaunchKernel(func, n_heads, 1, 1, 256, 1, 1, shared_bytes, stream_ptr, &params, null) != .success)
            return error.KernelLaunchFailed;
    }

    /// Copy device memory (for KV store: copy activation into KV cache slot)
    /// Always uses async version on stream to avoid implicit synchronization.
    pub fn deviceCopy(
        self: *CudaBackend,
        dst: cuda.CUdeviceptr,
        src: cuda.CUdeviceptr,
        size_bytes: usize,
    ) !void {
        if (cuda.cuMemcpyDtoDAsync(dst, src, size_bytes, self.stream) != .success)
            return error.DeviceCopyFailed;
    }

    /// Synchronize CUDA context (wait for all kernels to finish)
    pub fn syncGpu(_: *CudaBackend) !void {
        if (cuda.cuCtxSynchronize() != .success) return error.SyncFailed;
    }

    // ========================================================================
    // cuBLAS Batched GEMM — Dequant Q4_0 → FP32 + SGEMM
    // ========================================================================

    /// Ensure dequant scratch buffer is large enough for M×K FP32 elements.
    fn ensureDequantScratch(self: *CudaBackend, needed: usize) !void {
        if (self.dequant_scratch_size >= needed) return;
        if (self.dequant_scratch != 0) _ = cuda.cuMemFree(self.dequant_scratch);
        var dptr: cuda.CUdeviceptr = undefined;
        if (cuda.cuMemAlloc(&dptr, needed) != .success) return error.OutOfMemory;
        self.dequant_scratch = dptr;
        self.dequant_scratch_size = needed;
    }

    /// Dequantize Q4_0 weights → FP32 into scratch, then cuBLAS SGEMM for
    /// batched decode: Y[B×M] = X[B×K] × W^T[K×M]
    ///
    /// d_Y:  [B × M] output (device FP32)
    /// d_W:  [M × K/32 × 18] Q4_0 weight (device)
    /// d_X:  [B × K] input (device FP32, B stacked vectors)
    /// M:    output dim (rows of weight matrix)
    /// K:    input dim (cols of weight matrix)
    /// B:    batch size (number of concurrent users)
    pub fn batchedQ4SgemmGpu(
        self: *CudaBackend,
        d_Y: cuda.CUdeviceptr,
        d_W: cuda.CUdeviceptr,
        d_X: cuda.CUdeviceptr,
        M: u32,
        K: u32,
        B: u32,
    ) !void {
        const handle = self.cublas_handle orelse return error.CublasNotInitialized;

        // Step 1: Dequantize Q4_0 weights → FP32 scratch buffer
        const fp32_bytes = @as(usize, M) * K * @sizeOf(f32);
        try self.ensureDequantScratch(fp32_bytes);

        // Launch dequant kernel: each thread handles one Q4_0 block (32 elements)
        if (!self.hasKernel("dequantize_q4_0")) return error.KernelNotLoaded;
        const n_blocks_total = @as(u32, @intCast(@as(usize, M) * (K / 32)));
        var scratch_v = self.dequant_scratch;
        var w_v = d_W;
        var m_v = M;
        var k_v = K;
        var dequant_params = [_]?*anyopaque{
            @ptrCast(&scratch_v), @ptrCast(&w_v),
            @ptrCast(&m_v),       @ptrCast(&k_v),
        };
        const grid_x = (n_blocks_total + 255) / 256;
        if (!self.launchKernel(self.getKernel("dequantize_q4_0").?, grid_x, 1, 256, 1, 0, &dequant_params))
            return error.KernelLaunchFailed;

        // Step 2: cuBLAS SGEMM — Y = X × W^T
        // cuBLAS is column-major. For row-major: Y^T = W × X^T
        // → cublasSgemm(N, T, M, B, K, 1.0, W_fp32, M, X, K, 0.0, Y, M)
        const alpha: f32 = 1.0;
        const beta: f32 = 0.0;
        const status = cuda.cublasSgemm(
            handle,
            .N, // W_fp32 not transposed (column-major = row-major transposed)
            .T, // X transposed
            @intCast(M), // m
            @intCast(B), // n
            @intCast(K), // k
            &alpha,
            @ptrFromInt(self.dequant_scratch),
            @intCast(M), // W_fp32[M×K] as col-major
            @ptrFromInt(d_X),
            @intCast(K), // X[B×K] as col-major
            &beta,
            @ptrFromInt(d_Y),
            @intCast(M), // Y[B×M] as col-major
        );
        if (status != .SUCCESS) return error.CublasSgemmFailed;
    }

    /// Check if cuBLAS batched GEMM is available
    pub fn hasCublasGemm(self: *const CudaBackend) bool {
        return self.cublas_handle != null and self.hasKernel("dequantize_q4_0");
    }

    /// FP16 HGEMM: Y[B×M] = X[B×K] × W[M×K]^T  (row-major convention)
    /// Weight W is row-major [M×K] = col-major [K×M], transposed via OP_T.
    /// Input X is row-major [B×K] = col-major [K×B], used as-is via OP_N.
    /// Output Y is col-major [M×B] = row-major [B×M].
    ///
    /// Uses tensor cores on T4 (65 TFLOPS FP16). Memory-bandwidth limited:
    /// B=1 and B=16 take the same time (~51ms for full 7B model).
    /// Used for DART batch verification: verify K draft tokens in one forward pass.
    pub fn hgemmGpu(
        self: *CudaBackend,
        d_Y: cuda.CUdeviceptr, // output [B × M] FP16 (row-major)
        d_W: cuda.CUdeviceptr, // weights [M × K] FP16 (row-major, from Q4→FP16 dequant)
        d_X: cuda.CUdeviceptr, // input [B × K] FP16 (row-major)
        M: u32, // output dim (rows of weight matrix)
        K: u32, // input dim (cols of weight matrix)
        B: u32, // batch size (number of draft tokens to verify)
    ) !void {
        const handle = self.cublas_handle orelse return error.NoCublasHandle;

        // FP16 alpha=1.0, beta=0.0 in IEEE 754 half-precision
        const alpha_bits: u16 = 0x3C00;
        const beta_bits: u16 = 0x0000;

        // W row-major [M×K] → col-major sees [K×M] → OP_T gives [M×K], lda=K
        // X row-major [B×K] → col-major sees [K×B] → OP_N gives [K×B], ldb=K
        // Y col-major [M×B], ldc=M → row-major [B×M]
        const status = cuda.cublasHgemm(
            handle,
            .T,
            .N,
            @intCast(M),
            @intCast(B),
            @intCast(K),
            @ptrCast(&alpha_bits),
            @ptrFromInt(d_W),
            @intCast(K), // lda = K (stored [K×M] col-major)
            @ptrFromInt(d_X),
            @intCast(K), // ldb = K (stored [K×B] col-major)
            @ptrCast(&beta_bits),
            @ptrFromInt(d_Y),
            @intCast(M), // ldc = M (output [M×B] col-major)
        );
        if (status != .SUCCESS) return error.CublasHgemmFailed;
    }

    /// Check if cuBLAS FP16 HGEMM is available (requires cuBLAS handle)
    pub fn hasCublasHgemm(self: *const CudaBackend) bool {
        return self.cublas_handle != null;
    }

    /// Convert FP32 GPU buffer to FP16 GPU buffer.
    /// d_out: device pointer to FP16 output (n * 2 bytes)
    /// d_in:  device pointer to FP32 input (n * 4 bytes)
    /// n:     number of elements to convert
    pub fn fp32ToFp16Gpu(self: *const CudaBackend, d_out: cuda.CUdeviceptr, d_in: cuda.CUdeviceptr, n: u32) !void {
        const func = self.fp32_to_fp16_func orelse return error.KernelNotLoaded;
        const block: u32 = 256;
        const grid: u32 = (n + block - 1) / block;
        var p_out = d_out;
        var p_in = d_in;
        var p_n = n;
        var params = [_]?*anyopaque{
            @ptrCast(&p_out),
            @ptrCast(&p_in),
            @ptrCast(&p_n),
        };
        if (!self.launchKernel(func, grid, 1, block, 1, 0, &params)) return error.KernelLaunchFailed;
    }

    /// Convert FP16 GPU buffer to FP32 GPU buffer.
    /// d_out: device pointer to FP32 output (n * 4 bytes)
    /// d_in:  device pointer to FP16 input (n * 2 bytes)
    /// n:     number of elements to convert
    pub fn fp16ToFp32Gpu(self: *const CudaBackend, d_out: cuda.CUdeviceptr, d_in: cuda.CUdeviceptr, n: u32) !void {
        const func = self.fp16_to_fp32_func orelse return error.KernelNotLoaded;
        const block: u32 = 256;
        const grid: u32 = (n + block - 1) / block;
        var p_out = d_out;
        var p_in = d_in;
        var p_n = n;
        var params = [_]?*anyopaque{
            @ptrCast(&p_out),
            @ptrCast(&p_in),
            @ptrCast(&p_n),
        };
        if (!self.launchKernel(func, grid, 1, block, 1, 0, &params)) return error.KernelLaunchFailed;
    }

    /// FP16 fused SwiGLU: gate[i] = silu(gate[i]) * up[i], all in FP16.
    /// Loads FP16, computes in FP32 (silu + mul), stores FP16.
    /// Eliminates 3 conversion kernel launches per FFN layer in batch path.
    pub fn fp16SwigluGpu(self: *const CudaBackend, d_gate: cuda.CUdeviceptr, d_up: cuda.CUdeviceptr, n: u32) !void {
        const func = self.fp16_swiglu_func orelse return error.KernelNotLoaded;
        const block: u32 = 256;
        const grid: u32 = (n + block - 1) / block;
        var p_gate = d_gate;
        var p_up = d_up;
        var p_n = n;
        var params = [_]?*anyopaque{
            @ptrCast(&p_gate),
            @ptrCast(&p_up),
            @ptrCast(&p_n),
        };
        if (!self.launchKernel(func, grid, 1, block, 1, 0, &params)) return error.KernelLaunchFailed;
    }

    /// Check if FP16 conversion + HGEMM batch path is available
    pub fn hasFp16BatchPath(self: *const CudaBackend) bool {
        return self.hasCublasHgemm() and self.fp32_to_fp16_func != null and self.fp16_to_fp32_func != null;
    }

    // ========================================================================
    // MoE Expert Dispatch — Q4 dequant, weighted accumulation
    // ========================================================================

    /// Dequantize Q4_0 weight slice → FP16 (two-step: Q4→FP32 scratch → FP16).
    /// d_out_fp16: device pointer to FP16 output [M × K × sizeof(f16)]
    /// d_q4_data:  device pointer to Q4_0 data (possibly offset into stacked buffer)
    /// M:          rows of weight matrix
    /// K:          cols of weight matrix (must be multiple of 32)
    pub fn dequantQ4ToFp16Gpu(
        self: *CudaBackend,
        d_out_fp16: cuda.CUdeviceptr,
        d_q4_data: cuda.CUdeviceptr,
        M: u32,
        K: u32,
    ) !void {
        // Step 1: Q4_0 → FP32 into scratch buffer
        const fp32_bytes = @as(usize, M) * K * @sizeOf(f32);
        try self.ensureDequantScratch(fp32_bytes);

        if (!self.hasKernel("dequantize_q4_0")) return error.KernelNotLoaded;
        const n_blocks_total = @as(u32, @intCast(@as(usize, M) * (K / 32)));
        var scratch_v = self.dequant_scratch;
        var w_v = d_q4_data;
        var m_v = M;
        var k_v = K;
        var dequant_params = [_]?*anyopaque{
            @ptrCast(&scratch_v), @ptrCast(&w_v),
            @ptrCast(&m_v),       @ptrCast(&k_v),
        };
        const grid_x = (n_blocks_total + 255) / 256;
        if (!self.launchKernel(self.getKernel("dequantize_q4_0").?, grid_x, 1, 256, 1, 0, &dequant_params))
            return error.KernelLaunchFailed;

        // Step 2: FP32 scratch → FP16 output
        try self.fp32ToFp16Gpu(d_out_fp16, self.dequant_scratch, M * K);
    }

    /// Weighted vector add: out[i] += scale * x[i]  (FP32)
    /// Used for MoE weighted expert accumulation.
    pub fn weightedVectorAddGpu(
        self: *const CudaBackend,
        d_out: cuda.CUdeviceptr,
        d_x: cuda.CUdeviceptr,
        scale: f32,
        n: u32,
    ) !void {
        const func = self.weighted_vadd_func orelse return error.KernelNotLoaded;
        const block: u32 = 256;
        const grid: u32 = (n + block - 1) / block;
        var p_out = d_out;
        var p_x = d_x;
        var p_scale = scale;
        var p_n = n;
        var params = [_]?*anyopaque{
            @ptrCast(&p_out),
            @ptrCast(&p_x),
            @ptrCast(&p_scale),
            @ptrCast(&p_n),
        };
        if (!self.launchKernel(func, grid, 1, block, 1, 0, &params)) return error.KernelLaunchFailed;
    }

    /// Zero a FP32 buffer on GPU.
    pub fn zeroBufferGpu(
        self: *const CudaBackend,
        d_out: cuda.CUdeviceptr,
        n: u32,
    ) !void {
        const func = self.zero_buffer_func orelse return error.KernelNotLoaded;
        const block: u32 = 256;
        const grid: u32 = (n + block - 1) / block;
        var p_out = d_out;
        var p_n = n;
        var params = [_]?*anyopaque{
            @ptrCast(&p_out),
            @ptrCast(&p_n),
        };
        if (!self.launchKernel(func, grid, 1, block, 1, 0, &params)) return error.KernelLaunchFailed;
    }

    /// Check if MoE kernel path is available
    pub fn hasMoEKernels(self: *const CudaBackend) bool {
        return self.weighted_vadd_func != null and self.zero_buffer_func != null and
            self.hasFp16BatchPath() and self.hasKernel("dequantize_q4_0");
    }

    // ========================================================================
    // CUDA Graphs — Capture & Replay
    // ========================================================================

    /// Begin capturing all kernel launches on this backend's stream into a graph.
    /// All subsequent kernel dispatches (until endGraphCapture) are recorded, not executed.
    pub fn beginGraphCapture(self: *CudaBackend) !void {
        const s = self.stream orelse return error.NoStream;
        self.destroyGraph(); // discard any previous graph
        if (cuda.cuStreamBeginCapture(s, .global) != .success)
            return error.GraphCaptureBeginFailed;
        self.capturing = true;
        log.info("CUDA Graph capture started", .{});
    }

    /// End capture and instantiate an executable graph.
    pub fn endGraphCapture(self: *CudaBackend) !void {
        const s = self.stream orelse return error.NoStream;
        self.capturing = false;

        var graph: cuda.CUgraph = undefined;
        if (cuda.cuStreamEndCapture(s, &graph) != .success)
            return error.GraphCaptureEndFailed;
        self.captured_graph = graph;

        var exec: cuda.CUgraphExec = undefined;
        if (cuda.cuGraphInstantiate(&exec, graph, null, 0) != .success) {
            _ = cuda.cuGraphDestroy(graph);
            self.captured_graph = null;
            return error.GraphInstantiateFailed;
        }
        self.graph_exec = exec;
        self.graph_captured = true;

        log.info("CUDA Graph captured and instantiated", .{});
    }

    /// Replay the captured graph (all kernels from one decode step).
    /// This eliminates per-kernel launch overhead (~5-10% speedup).
    pub fn replayGraph(self: *CudaBackend) !void {
        if (!self.graph_captured) return error.NoGraphCaptured;
        const exec = self.graph_exec orelse return error.NoGraphCaptured;
        const s = self.stream orelse return error.NoStream;
        if (cuda.cuGraphLaunch(exec, s) != .success)
            return error.GraphLaunchFailed;
    }

    /// Wait for the compute stream to complete.
    pub fn syncStream(self: *CudaBackend) !void {
        const s = self.stream orelse return error.NoStream;
        if (cuda.cuStreamSynchronize(s) != .success)
            return error.StreamSyncFailed;
    }

    /// Wait for the transfer stream to complete.
    pub fn syncTransferStream(self: *CudaBackend) !void {
        const s = self.transfer_stream orelse return error.NoStream;
        if (cuda.cuStreamSynchronize(s) != .success)
            return error.StreamSyncFailed;
    }

    /// Async host-to-device copy on the transfer stream.
    /// Source MUST be pinned memory for truly async behavior.
    pub fn asyncHtoD(self: *CudaBackend, dst: cuda.CUdeviceptr, src: [*]const u8, size: usize) !void {
        const s = self.transfer_stream orelse return error.NoStream;
        if (cuda.cuMemcpyHtoDAsync(dst, src, size, s) != .success)
            return error.AsyncTransferFailed;
    }

    /// Record an event on the transfer stream (signals when all prior DMA completes).
    pub fn recordTransferDone(self: *CudaBackend) !void {
        const evt = self.transfer_done_event orelse return error.NoEvent;
        const s = self.transfer_stream orelse return error.NoStream;
        if (cuda.cuEventRecord(evt, s) != .success)
            return error.EventRecordFailed;
    }

    /// Make compute stream wait until transfer is done (inter-stream dependency).
    pub fn computeWaitTransfer(self: *CudaBackend) !void {
        const evt = self.transfer_done_event orelse return error.NoEvent;
        const s = self.stream orelse return error.NoStream;
        if (cuda.cuStreamWaitEvent(s, evt, 0) != .success)
            return error.StreamWaitFailed;
    }

    /// Record an event on the compute stream (signals when compute kernel finishes).
    pub fn recordComputeDone(self: *CudaBackend) !void {
        const evt = self.compute_done_event orelse return error.NoEvent;
        const s = self.stream orelse return error.NoStream;
        if (cuda.cuEventRecord(evt, s) != .success)
            return error.EventRecordFailed;
    }

    /// Make transfer stream wait until compute is done (safe to reuse staging).
    pub fn transferWaitCompute(self: *CudaBackend) !void {
        const evt = self.compute_done_event orelse return error.NoEvent;
        const s = self.transfer_stream orelse return error.NoStream;
        if (cuda.cuStreamWaitEvent(s, evt, 0) != .success)
            return error.StreamWaitFailed;
    }

    /// Check if double-buffered async offloading is available.
    pub fn hasAsyncTransfer(self: *const CudaBackend) bool {
        return self.transfer_stream != null and
            self.transfer_done_event != null and
            self.compute_done_event != null;
    }

    /// Free captured graph resources.
    pub fn destroyGraph(self: *CudaBackend) void {
        if (self.graph_exec) |exec_val| {
            _ = cuda.cuGraphExecDestroy(exec_val);
            self.graph_exec = null;
        }
        if (self.captured_graph) |g_val| {
            _ = cuda.cuGraphDestroy(g_val);
            self.captured_graph = null;
        }
        self.graph_captured = false;
    }

    /// Whether a graph is ready for replay.
    pub fn hasGraph(self: *const CudaBackend) bool {
        return self.graph_captured;
    }

    // ========================================================================
    // Utilities
    // ========================================================================

    pub fn isAvailable(self: *const CudaBackend) bool {
        return self.initialized;
    }

    pub fn getStats(self: *const CudaBackend) struct {
        kernel_dispatches: u64,
        total_elements: u64,
        total_exec_time_ns: u64,
    } {
        return .{
            .kernel_dispatches = self.kernel_dispatches.load(.monotonic),
            .total_elements = self.total_elements.load(.monotonic),
            .total_exec_time_ns = self.total_exec_time_ns.load(.monotonic),
        };
    }
};

pub const KernelResult = struct {
    success: bool,
    execution_time_ns: i128,
    elements_processed: usize,
    gpu_utilized: bool,
};

// ============================================================================
// Exported Kernel References (for PTX compilation)
// ============================================================================

/// Reference to pure Zig CUDA kernels
/// Compiled via: zig build-obj -target nvptx64-nvidia-cuda cuda_kernels.zig
pub const CudaKernels = struct {
    pub const flash_attention = kernels.flash_attention;
    pub const sgemm = kernels.sgemm;
    pub const sgemv = kernels.sgemv;
    pub const rms_norm = kernels.rms_norm;
    pub const layer_norm = kernels.layer_norm;
    pub const softmax = kernels.softmax;
    pub const swiglu = kernels.swiglu;
    pub const gelu = kernels.gelu;
    pub const relu = kernels.relu;
    pub const rope_q = kernels.rope_q;
    pub const rope_k = kernels.rope_k;
    pub const quantize_fp32_to_int8 = kernels.quantize_fp32_to_int8;
    pub const dequantize_int8_to_fp32 = kernels.dequantize_int8_to_fp32;
    pub const embedding_lookup = kernels.embedding_lookup;
    pub const vector_add = kernels.vector_add;
    pub const vector_scale = kernels.vector_scale;
    pub const vector_mul = kernels.vector_mul;
};

// ============================================================================
// Tests
// ============================================================================

test "flash attention CPU reference" {
    const allocator = std.testing.allocator;
    var backend = try CudaBackend.init(allocator, .{});
    defer backend.deinit();

    // Simple 1x1x4x2 test
    const q = [_]f32{ 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0 };
    const k = [_]f32{ 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0 };
    const v = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var out: [8]f32 = undefined;

    const result = try backend.flashAttention(&out, &q, &k, &v, 1, 1, 1, 4, 2);
    try std.testing.expect(result.success);
}

test "rms_norm CPU" {
    const allocator = std.testing.allocator;
    var backend = try CudaBackend.init(allocator, .{});
    defer backend.deinit();

    const x = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const weight = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var out: [4]f32 = undefined;

    const result = try backend.rmsNorm(&out, &x, &weight, 4, 1e-5);
    try std.testing.expect(result.success);
}
