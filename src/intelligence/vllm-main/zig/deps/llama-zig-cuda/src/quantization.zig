//! Quantization Manager - Phase 4 Optimization
//!
//! High-level API for INT8/INT4 quantization:
//! - Calibration workflow (CPU and GPU paths)
//! - Quantized model loading
//! - Dynamic quantization
//! - Per-channel weight quantization
//! - AWQ, GPTQ, and SmoothQuant support
//!
//! ## Thread Safety
//! The manager is **not** thread-safe. All GPU functions synchronize before
//! returning unless documented otherwise.
//!
//! ## Memory Ownership
//! - Host buffers passed to public functions are **not** owned by the manager.
//! - `QuantizedTensor` owns its host allocations and optionally its device pointer
//!   (controlled by `owns_device_ptr`).
//! - The caller must ensure device pointers passed to GPU functions remain valid
//!   for the duration of the call.

const std = @import("std");
const Allocator = std.mem.Allocator;

// C FFI for CUDA quantization
const c = @cImport({
    @cInclude("cuda_kernels.h");
});

/// Thread-local last CUDA error message captured after a failed GPU call.
/// Retrieve with `getLastCudaError()`.
var last_cuda_error: [256]u8 = [_]u8{0} ** 256;
var last_cuda_error_len: usize = 0;

/// Return the last CUDA error message captured by this module.
/// Returns an empty slice if no error has occurred.
pub fn getLastCudaError() []const u8 {
    return last_cuda_error[0..last_cuda_error_len];
}

/// Capture the CUDA error string into the module-local buffer.
fn captureCudaError() void {
    const err_ptr = c.cuda_get_last_error();
    if (err_ptr != null) {
        const err_slice = std.mem.span(err_ptr);
        const copy_len = @min(err_slice.len, last_cuda_error.len);
        @memcpy(last_cuda_error[0..copy_len], err_slice[0..copy_len]);
        last_cuda_error_len = copy_len;
    }
}

/// Call cuda_synchronize and return an error if it fails.
fn gpuSync() !void {
    if (c.cuda_synchronize() != 0) {
        captureCudaError();
        return error.GpuSyncFailed;
    }
}

// ============================================================================
// GPU Capability Queries
// ============================================================================

/// Query whether the GPU has Tensor Cores (SM >= 7.0, Volta+).
pub fn hasTensorCores() bool {
    return c.cuda_has_tensor_cores() != 0;
}

/// Query whether native FP16 arithmetic is supported (SM >= 5.3).
pub fn hasFp16() bool {
    return c.cuda_has_fp16() != 0;
}

/// Query whether INT8 Tensor Core GEMM is supported (SM >= 7.5, Turing+).
pub fn hasInt8Tensor() bool {
    return c.cuda_has_int8_tensor() != 0;
}

/// Return the GPU SM version (e.g. 75 for SM 7.5), or 0 if unavailable.
pub fn getSmVersion() i32 {
    var sm: c_int = 0;
    _ = c.cuda_get_capabilities(&sm, null, null, null, null);
    return @intCast(sm);
}

// ============================================================================
// Quantization Configuration
// ============================================================================

pub const QuantizationMode = enum {
    none,           // FP32/FP16 only
    int8_static,    // INT8 with pre-calibrated scales
    int8_dynamic,   // INT8 with runtime scale computation
    int4_awq,       // INT4 with AWQ (Activation-aware Weight Quantization)
    int4_gptq,      // INT4 with GPTQ (Optimal Brain Quantization)
    smooth_quant,   // SmoothQuant for activations
};

pub const QuantizationConfig = struct {
    /// Quantization mode
    mode: QuantizationMode = .none,
    
    /// Number of calibration samples
    calibration_samples: usize = 128,
    
    /// Group size for weight quantization (AWQ/GPTQ)
    group_size: usize = 128,
    
    /// Use per-channel quantization for weights
    per_channel_weights: bool = true,
    
    /// Use per-token quantization for activations
    per_token_activations: bool = true,
    
    /// Alpha for SmoothQuant (balance between weight/activation difficulty)
    smooth_quant_alpha: f32 = 0.5,
    
    /// Symmetric vs asymmetric quantization
    symmetric: bool = true,
};

// ============================================================================
// Quantization Parameters
// ============================================================================

pub const QuantParams = struct {
    scale: f32,
    zero_point: i32,
    min_val: f32,
    max_val: f32,
};

pub const LayerQuantParams = struct {
    weights: QuantParams,
    activations: QuantParams,
    per_channel: bool,
    
    /// Per-channel scales (if per_channel is true)
    channel_scales: ?[]f32 = null,
    
    /// Smooth scales for SmoothQuant
    smooth_scales: ?[]f32 = null,
};

// ============================================================================
// Quantized Tensor
// ============================================================================

pub const QuantizedTensor = struct {
    const Self = @This();
    
    /// Quantized data (INT8)
    data_int8: ?[]i8 = null,
    
    /// Quantized data (INT4, packed as INT8)
    data_int4: ?[]i8 = null,
    
    /// Original shape
    shape: []usize,
    
    /// Quantization parameters
    params: QuantParams,
    
    /// Per-group scales (for AWQ/GPTQ)
    group_scales: ?[]f32 = null,
    group_zeros: ?[]i8 = null,
    group_size: usize,
    
    /// GPU device pointer (INT8 data on device).
    device_ptr: ?*anyopaque = null,
    
    /// If true, `deinit` will call `cuda_free` on `device_ptr`.
    /// Set to false when the device pointer is owned externally.
    owns_device_ptr: bool = true,
    
    allocator: Allocator,
    
    /// Create a new QuantizedTensor with the given shape and parameters.
    /// The caller must subsequently call `allocateInt8` or `allocateInt4`
    /// to allocate storage.
    ///
    /// `shape` is copied; the caller retains ownership of the original.
    pub fn init(
        allocator: Allocator,
        shape: []const usize,
        params: QuantParams,
        group_size: usize,
    ) !Self {
        const owned_shape = try allocator.alloc(usize, shape.len);
        @memcpy(owned_shape, shape);
        
        return .{
            .shape = owned_shape,
            .params = params,
            .group_size = group_size,
            .allocator = allocator,
        };
    }
    
    /// Create a view that references an externally-owned device pointer.
    /// The returned tensor will NOT free the device pointer on deinit.
    pub fn initDeviceView(
        allocator: Allocator,
        shape: []const usize,
        params: QuantParams,
        group_size: usize,
        dev_ptr: *anyopaque,
    ) !Self {
        var t = try init(allocator, shape, params, group_size);
        t.device_ptr = dev_ptr;
        t.owns_device_ptr = false;
        return t;
    }
    
    /// Free all owned resources. Safe to call multiple times.
    pub fn deinit(self: *Self) void {
        if (self.data_int8) |d| self.allocator.free(d);
        if (self.data_int4) |d| self.allocator.free(d);
        if (self.group_scales) |s| self.allocator.free(s);
        if (self.group_zeros) |z| self.allocator.free(z);
        self.allocator.free(self.shape);
        
        if (self.device_ptr) |ptr| {
            if (self.owns_device_ptr) {
                c.cuda_free(ptr);
            }
        }
        self.data_int8 = null;
        self.data_int4 = null;
        self.group_scales = null;
        self.group_zeros = null;
        self.device_ptr = null;
    }
    
    /// Get total number of elements across all dimensions.
    pub fn numElements(self: *const Self) usize {
        var total: usize = 1;
        for (self.shape) |dim| {
            total *= dim;
        }
        return total;
    }
    
    /// Allocate host-side INT8 storage for `numElements()` values.
    pub fn allocateInt8(self: *Self) !void {
        const n = self.numElements();
        self.data_int8 = try self.allocator.alloc(i8, n);
    }
    
    /// Allocate host-side INT4 storage (packed: 2 values per byte).
    pub fn allocateInt4(self: *Self) !void {
        const n = self.numElements();
        self.data_int4 = try self.allocator.alloc(i8, (n + 1) / 2);
    }
};

// ============================================================================
// Calibration Manager
// ============================================================================

pub const CalibrationManager = struct {
    const Self = @This();
    
    config: QuantizationConfig,
    layer_params: std.AutoHashMap(usize, LayerQuantParams),
    
    /// Running min/max for activations
    activation_mins: std.AutoHashMap(usize, f32),
    activation_maxs: std.AutoHashMap(usize, f32),
    
    /// Running min/max for weights
    weight_mins: std.AutoHashMap(usize, f32),
    weight_maxs: std.AutoHashMap(usize, f32),
    
    samples_collected: usize,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, config: QuantizationConfig) Self {
        return .{
            .config = config,
            .layer_params = std.AutoHashMap(usize, LayerQuantParams).init(allocator),
            .activation_mins = std.AutoHashMap(usize, f32).init(allocator),
            .activation_maxs = std.AutoHashMap(usize, f32).init(allocator),
            .weight_mins = std.AutoHashMap(usize, f32).init(allocator),
            .weight_maxs = std.AutoHashMap(usize, f32).init(allocator),
            .samples_collected = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.layer_params.deinit();
        self.activation_mins.deinit();
        self.activation_maxs.deinit();
        self.weight_mins.deinit();
        self.weight_maxs.deinit();
    }
    
    /// Record activation statistics from host-side data for calibration.
    /// For GPU-resident activations, use `calibrateLayer` instead.
    pub fn recordActivationsHost(
        self: *Self,
        layer_idx: usize,
        activations: []const f32,
    ) void {
        var min_val: f32 = std.math.floatMax(f32);
        var max_val: f32 = -std.math.floatMax(f32);
        
        for (activations) |val| {
            min_val = @min(min_val, val);
            max_val = @max(max_val, val);
        }
        
        // Update running min/max
        if (self.activation_mins.get(layer_idx)) |existing_min| {
            self.activation_mins.put(layer_idx, @min(existing_min, min_val)) catch {};
        } else {
            self.activation_mins.put(layer_idx, min_val) catch {};
        }
        
        if (self.activation_maxs.get(layer_idx)) |existing_max| {
            self.activation_maxs.put(layer_idx, @max(existing_max, max_val)) catch {};
        } else {
            self.activation_maxs.put(layer_idx, max_val) catch {};
        }
    }
    
    /// Record activation statistics from host-side data.
    /// Alias kept for backward compatibility; prefer `recordActivationsHost`.
    pub const recordActivations = recordActivationsHost;
    
    /// Record weight statistics from host-side data for calibration.
    /// Tracks per-layer weight min/max used by `finalize` to compute weight scales.
    pub fn recordWeightsHost(
        self: *Self,
        layer_idx: usize,
        weights: []const f32,
    ) void {
        var min_val: f32 = std.math.floatMax(f32);
        var max_val: f32 = -std.math.floatMax(f32);
        
        for (weights) |val| {
            min_val = @min(min_val, val);
            max_val = @max(max_val, val);
        }
        
        if (self.weight_mins.get(layer_idx)) |existing_min| {
            self.weight_mins.put(layer_idx, @min(existing_min, min_val)) catch {};
        } else {
            self.weight_mins.put(layer_idx, min_val) catch {};
        }
        
        if (self.weight_maxs.get(layer_idx)) |existing_max| {
            self.weight_maxs.put(layer_idx, @max(existing_max, max_val)) catch {};
        } else {
            self.weight_maxs.put(layer_idx, max_val) catch {};
        }
    }
    
    /// Calibrate a layer using CUDA (both weights and activations on GPU).
    /// This is the recommended path for GPU-resident data; it computes
    /// min/max for both weights and activations in a single call.
    /// Synchronizes the GPU before returning.
    pub fn calibrateLayer(
        self: *Self,
        layer_idx: usize,
        weights_ptr: *anyopaque,
        weights_size: usize,
        activations_ptr: *anyopaque,
        activations_size: usize,
    ) !void {
        const result = c.calibrate_layer(
            @intCast(layer_idx),
            @ptrCast(weights_ptr),
            @intCast(weights_size),
            @ptrCast(activations_ptr),
            @intCast(activations_size),
        );
        
        if (result != 0) {
            captureCudaError();
            return error.CalibrationFailed;
        }
        
        try gpuSync();
        _ = self;
    }
    
    /// Finalize calibration and compute scales for all recorded layers.
    /// Uses both weight and activation min/max ranges.
    /// For symmetric quantization: scale = abs_max / 127.
    /// For asymmetric quantization: scale = (max - min) / 255, zero_point computed.
    pub fn finalize(self: *Self) !void {
        var it = self.activation_mins.iterator();
        while (it.next()) |entry| {
            const layer_idx = entry.key_ptr.*;
            const act_min = entry.value_ptr.*;
            const act_max = self.activation_maxs.get(layer_idx) orelse 0;
            
            // Compute activation scale
            var act_scale: f32 = undefined;
            var act_zp: i32 = 0;
            if (self.config.symmetric) {
                const abs_max = @max(@abs(act_min), @abs(act_max));
                act_scale = if (abs_max > 0) abs_max / 127.0 else 1.0;
                act_zp = 0;
            } else {
                // Asymmetric: map [min, max] → [0, 255]
                const range = act_max - act_min;
                act_scale = if (range > 0) range / 255.0 else 1.0;
                act_zp = @intFromFloat(@round(-act_min / act_scale));
            }
            
            // Compute weight scale (use weight ranges if available, else fall back to activation)
            const w_min = self.weight_mins.get(layer_idx) orelse act_min;
            const w_max = self.weight_maxs.get(layer_idx) orelse act_max;
            var w_scale: f32 = undefined;
            var w_zp: i32 = 0;
            if (self.config.symmetric) {
                const w_abs_max = @max(@abs(w_min), @abs(w_max));
                w_scale = if (w_abs_max > 0) w_abs_max / 127.0 else 1.0;
                w_zp = 0;
            } else {
                const w_range = w_max - w_min;
                w_scale = if (w_range > 0) w_range / 255.0 else 1.0;
                w_zp = @intFromFloat(@round(-w_min / w_scale));
            }
            
            const params = LayerQuantParams{
                .weights = .{ .scale = w_scale, .zero_point = w_zp, .min_val = w_min, .max_val = w_max },
                .activations = .{ .scale = act_scale, .zero_point = act_zp, .min_val = act_min, .max_val = act_max },
                .per_channel = self.config.per_channel_weights,
            };
            
            try self.layer_params.put(layer_idx, params);
        }
        
        self.samples_collected += 1;
    }
    
    /// Check if calibration is complete
    pub fn isComplete(self: *const Self) bool {
        return self.samples_collected >= self.config.calibration_samples;
    }
};

// ============================================================================
// Quantization Manager
// ============================================================================

pub const QuantizationManager = struct {
    const Self = @This();
    
    config: QuantizationConfig,
    calibration: ?CalibrationManager,
    
    /// Quantized weights per layer
    quantized_weights: std.AutoHashMap(usize, QuantizedTensor),
    
    /// Smooth scales for SmoothQuant
    smooth_scales: std.AutoHashMap(usize, []f32),
    
    /// Is the model quantized?
    is_quantized: bool,
    
    allocator: Allocator,
    
    /// Statistics
    stats: QuantizationStats,
    
    pub const QuantizationStats = struct {
        original_size_mb: f32 = 0,
        quantized_size_mb: f32 = 0,
        compression_ratio: f32 = 1.0,
        calibration_time_ms: f32 = 0,
        quantization_time_ms: f32 = 0,
    };
    
    pub fn init(allocator: Allocator, config: QuantizationConfig) Self {
        var calibration: ?CalibrationManager = null;
        if (config.mode != .none and config.mode != .int8_dynamic) {
            calibration = CalibrationManager.init(allocator, config);
        }
        
        return .{
            .config = config,
            .calibration = calibration,
            .quantized_weights = std.AutoHashMap(usize, QuantizedTensor).init(allocator),
            .smooth_scales = std.AutoHashMap(usize, []f32).init(allocator),
            .is_quantized = false,
            .allocator = allocator,
            .stats = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        var it = self.quantized_weights.valueIterator();
        while (it.next()) |tensor| {
            tensor.deinit();
        }
        self.quantized_weights.deinit();
        
        var sit = self.smooth_scales.valueIterator();
        while (sit.next()) |scales| {
            self.allocator.free(scales.*);
        }
        self.smooth_scales.deinit();
        
        if (self.calibration) |*cal| {
            cal.deinit();
        }
    }
    
    /// Quantize a weight tensor (CPU path, host data).
    ///
    /// Supports symmetric and asymmetric quantization based on `config.symmetric`.
    /// If `config.per_channel_weights` is true and shape has >= 2 dims, computes
    /// a separate scale per output channel (first dimension).
    ///
    /// @param layer_idx  Layer index key for storage/retrieval.
    /// @param weights    Host FP32 weight data (row-major).
    /// @param shape      Tensor dimensions.
    /// @return Pointer to the stored QuantizedTensor (owned by manager).
    pub fn quantizeWeights(
        self: *Self,
        layer_idx: usize,
        weights: []const f32,
        shape: []const usize,
    ) !*QuantizedTensor {
        // Find global min/max
        var min_val: f32 = std.math.floatMax(f32);
        var max_val: f32 = -std.math.floatMax(f32);
        
        for (weights) |val| {
            min_val = @min(min_val, val);
            max_val = @max(max_val, val);
        }
        
        // Compute scale and zero-point
        var scale: f32 = undefined;
        var zero_point: i32 = 0;
        if (self.config.symmetric) {
            const abs_max = @max(@abs(min_val), @abs(max_val));
            scale = if (abs_max > 0) abs_max / 127.0 else 1.0;
            zero_point = 0;
        } else {
            // Asymmetric: map [min, max] -> [-128, 127]
            const range = max_val - min_val;
            scale = if (range > 0) range / 255.0 else 1.0;
            zero_point = @intFromFloat(@round(-min_val / scale - 128.0));
        }
        
        const params = QuantParams{
            .scale = scale,
            .zero_point = zero_point,
            .min_val = min_val,
            .max_val = max_val,
        };
        
        var tensor = try QuantizedTensor.init(
            self.allocator,
            shape,
            params,
            self.config.group_size,
        );
        
        try tensor.allocateInt8();
        
        // Per-channel quantization: each output channel (dim 0) gets its own scale
        if (self.config.per_channel_weights and shape.len >= 2) {
            const num_channels = shape[0];
            var channel_size: usize = 1;
            for (shape[1..]) |d| channel_size *= d;
            
            tensor.group_scales = try self.allocator.alloc(f32, num_channels);
            
            for (0..num_channels) |ch| {
                const start = ch * channel_size;
                const end = start + channel_size;
                const ch_data = weights[start..end];
                
                var ch_min: f32 = std.math.floatMax(f32);
                var ch_max: f32 = -std.math.floatMax(f32);
                for (ch_data) |val| {
                    ch_min = @min(ch_min, val);
                    ch_max = @max(ch_max, val);
                }
                
                const ch_abs_max = @max(@abs(ch_min), @abs(ch_max));
                const ch_scale = if (ch_abs_max > 0) ch_abs_max / 127.0 else 1.0;
                tensor.group_scales.?[ch] = ch_scale;
                
                for (ch_data, 0..) |val, j| {
                    const scaled_val = val / ch_scale;
                    var quantized = @as(i32, @intFromFloat(@round(scaled_val)));
                    quantized = @max(-128, @min(127, quantized));
                    tensor.data_int8.?[start + j] = @intCast(quantized);
                }
            }
        } else {
            // Global scale quantization
            for (weights, 0..) |val, i| {
                const scaled_val = if (self.config.symmetric)
                    val / scale
                else
                    val / scale + @as(f32, @floatFromInt(zero_point)) - 128.0;
                var quantized = @as(i32, @intFromFloat(@round(scaled_val)));
                quantized = @max(-128, @min(127, quantized));
                tensor.data_int8.?[i] = @intCast(quantized);
            }
        }
        
        try self.quantized_weights.put(layer_idx, tensor);
        return self.quantized_weights.getPtr(layer_idx).?;
    }
    
    /// Quantize weights on GPU using the CUDA INT8 quantization kernel.
    /// Supports per-channel quantization when `config.per_channel_weights` is true
    /// and `channel_scales_gpu` is provided.
    /// Synchronizes GPU before returning.
    ///
    /// @param layer_idx         Layer index (for bookkeeping).
    /// @param weights_gpu       Device FP32 weights.
    /// @param output_gpu        Device INT8 output (caller-allocated).
    /// @param n                 Total number of elements.
    /// @param scale             Global quantization scale.
    /// @param channel_scales_gpu Optional per-channel scales on device (null for global).
    /// @param num_channels      Number of output channels (ignored if channel_scales_gpu is null).
    /// @param channel_size      Elements per channel (ignored if channel_scales_gpu is null).
    pub fn quantizeWeightsGpu(
        self: *Self,
        layer_idx: usize,
        weights_gpu: *anyopaque,
        output_gpu: *anyopaque,
        n: usize,
        scale: f32,
        channel_scales_gpu: ?*anyopaque,
        num_channels: usize,
        channel_size: usize,
    ) !void {
        if (self.config.per_channel_weights) {
            if (channel_scales_gpu) |scales_ptr| {
                // Per-channel path
                const result = c.quantize_per_channel(
                    @ptrCast(output_gpu),
                    @ptrCast(weights_gpu),
                    @ptrCast(scales_ptr),
                    @intCast(num_channels),
                    @intCast(channel_size),
                );
                if (result != 0) {
                    captureCudaError();
                    return error.QuantizationFailed;
                }
                try gpuSync();
                _ = layer_idx;
                return;
            }
        }
        
        // Global scale path
        const zero_point: c_int = if (self.config.symmetric) 0 else blk: {
            // For asymmetric, caller should provide the zero point;
            // default to 0 if symmetric
            break :blk 0;
        };
        
        const result = c.quantize_fp32_to_int8(
            @ptrCast(output_gpu),
            @ptrCast(weights_gpu),
            scale,
            zero_point,
            @intCast(n),
        );
        
        if (result != 0) {
            captureCudaError();
            return error.QuantizationFailed;
        }
        
        try gpuSync();
        _ = layer_idx;
    }
    
    /// Apply SmoothQuant transformation on GPU.
    /// Computes: x_smoothed = x / smooth_scales, w_smoothed = w * smooth_scales
    /// Synchronizes GPU before returning.
    ///
    /// All pointer arguments are device pointers. Caller retains ownership.
    pub fn applySmoothQuant(
        self: *Self,
        layer_idx: usize,
        x_gpu: *anyopaque,
        w_gpu: *anyopaque,
        x_smoothed_gpu: *anyopaque,
        w_smoothed_gpu: *anyopaque,
        smooth_scales_gpu: *anyopaque,
        batch_size: usize,
        hidden_dim: usize,
    ) !void {
        const result = c.apply_smooth_quant(
            @ptrCast(x_smoothed_gpu),
            @ptrCast(w_smoothed_gpu),
            @ptrCast(x_gpu),
            @ptrCast(w_gpu),
            @ptrCast(smooth_scales_gpu),
            @intCast(batch_size),
            @intCast(hidden_dim),
        );
        
        if (result != 0) {
            captureCudaError();
            return error.SmoothQuantFailed;
        }
        
        try gpuSync();
        _ = self;
        _ = layer_idx;
    }
    
    /// Perform INT8 GEMM on GPU: C = A @ B (INT8 inputs, INT32 accumulator).
    /// Uses cuBLASLt with heuristic algorithm selection for best performance.
    /// Synchronizes GPU before returning.
    ///
    /// @param c_gpu  Device INT32 output [m, n].
    /// @param a_gpu  Device INT8 input A [m, k].
    /// @param b_gpu  Device INT8 input B [k, n].
    pub fn int8Gemm(
        self: *Self,
        c_gpu: *anyopaque,
        a_gpu: *anyopaque,
        b_gpu: *anyopaque,
        m: usize,
        n: usize,
        k: usize,
    ) !void {
        const result = c.int8_gemm(
            @ptrCast(c_gpu),
            @ptrCast(a_gpu),
            @ptrCast(b_gpu),
            @intCast(m),
            @intCast(n),
            @intCast(k),
            1, // alpha
            0, // beta
        );
        
        if (result != 0) {
            captureCudaError();
            return error.Int8GemmFailed;
        }
        
        try gpuSync();
        _ = self;
    }
    
    /// Dynamic quantization (runtime): quantize activations on-the-fly.
    /// Computes per-row scales and INT8 outputs in a single fused kernel.
    /// Synchronizes GPU before returning.
    ///
    /// @param output_gpu  Device INT8 output [batch_size, hidden_dim].
    /// @param scales_gpu  Device FP32 per-row scales [batch_size].
    /// @param input_gpu   Device FP32 input [batch_size, hidden_dim].
    pub fn dynamicQuantize(
        self: *Self,
        output_gpu: *anyopaque,
        scales_gpu: *anyopaque,
        input_gpu: *anyopaque,
        batch_size: usize,
        hidden_dim: usize,
    ) !void {
        const result = c.dynamic_quantize(
            @ptrCast(output_gpu),
            @ptrCast(scales_gpu),
            @ptrCast(input_gpu),
            @intCast(batch_size),
            @intCast(hidden_dim),
        );
        
        if (result != 0) {
            captureCudaError();
            return error.DynamicQuantizeFailed;
        }
        
        try gpuSync();
        _ = self;
    }
    
    /// Quantize weights using GPTQ (Optimal Brain Quantization) on GPU.
    /// Tries the GPU-accelerated path first (`gptq_quantize_block_gpu`);
    /// falls back to the CPU path (`gptq_quantize_block`) on failure.
    /// Synchronizes GPU before returning.
    ///
    /// @param q_weights_gpu  Device INT8 output [rows, cols].
    /// @param scales_gpu     Device FP32 per-group scales.
    /// @param weights_gpu    Device FP32 weights [rows, cols] — used as mutable workspace.
    /// @param h_inv_gpu      Device FP32 inverse Hessian [cols, cols].
    /// @param rows           Number of output rows.
    /// @param cols           Number of columns.
    pub fn quantizeGptq(
        self: *Self,
        q_weights_gpu: *anyopaque,
        scales_gpu: *anyopaque,
        weights_gpu: *anyopaque,
        h_inv_gpu: *anyopaque,
        rows: usize,
        cols: usize,
    ) !void {
        // Prefer GPU-accelerated GPTQ kernel
        const gpu_result = c.gptq_quantize_block_gpu(
            @ptrCast(q_weights_gpu),
            @ptrCast(scales_gpu),
            @ptrCast(weights_gpu),
            @ptrCast(h_inv_gpu),
            @intCast(rows),
            @intCast(cols),
            @intCast(self.config.group_size),
        );
        
        if (gpu_result == 0) {
            try gpuSync();
            return;
        }
        
        // Fallback to CPU path
        const cpu_result = c.gptq_quantize_block(
            @ptrCast(q_weights_gpu),
            @ptrCast(scales_gpu),
            @ptrCast(weights_gpu),
            @ptrCast(h_inv_gpu),
            @intCast(rows),
            @intCast(cols),
            @intCast(self.config.group_size),
        );
        
        if (cpu_result != 0) {
            captureCudaError();
            return error.GptqQuantizeFailed;
        }
        
        try gpuSync();
    }
    
    /// Quantize weights using AWQ (Activation-aware Weight Quantization).
    /// AWQ uses per-group INT4 quantization with activation-aware scaling.
    /// This CPU path computes group scales based on activation importance.
    ///
    /// @param layer_idx           Layer index for storage.
    /// @param weights             Host FP32 weights [rows, cols], row-major.
    /// @param shape               Tensor dimensions.
    /// @param activation_scales   Per-channel importance scores [cols] from calibration.
    /// @return Pointer to stored QuantizedTensor with INT4 data and group scales.
    pub fn quantizeAwq(
        self: *Self,
        layer_idx: usize,
        weights: []const f32,
        shape: []const usize,
        activation_scales: []const f32,
    ) !*QuantizedTensor {
        if (shape.len < 2) return error.QuantizationFailed;
        
        const rows = shape[0];
        const cols = shape[1];
        const group_size = self.config.group_size;
        const num_groups = (cols + group_size - 1) / group_size;
        
        // Compute per-group scales weighted by activation importance
        const total_groups = rows * num_groups;
        var group_scales = try self.allocator.alloc(f32, total_groups);
        var group_zeros = try self.allocator.alloc(i8, total_groups);
        
        for (0..rows) |row| {
            for (0..num_groups) |g| {
                const g_start = g * group_size;
                const g_end = @min(g_start + group_size, cols);
                
                // Find weighted max in this group
                var weighted_max: f32 = 0;
                for (g_start..g_end) |col| {
                    const importance = if (col < activation_scales.len) activation_scales[col] else 1.0;
                    weighted_max = @max(weighted_max, @abs(weights[row * cols + col]) * importance);
                }
                
                // INT4 range: [-8, 7]
                const s = if (weighted_max > 0) weighted_max / 7.0 else 1.0;
                group_scales[row * num_groups + g] = s;
                group_zeros[row * num_groups + g] = 0; // Symmetric
            }
        }
        
        const params = QuantParams{
            .scale = group_scales[0], // Representative (per-group overrides)
            .zero_point = 0,
            .min_val = -std.math.floatMax(f32),
            .max_val = std.math.floatMax(f32),
        };
        
        var tensor = try QuantizedTensor.init(self.allocator, shape, params, group_size);
        try tensor.allocateInt4();
        tensor.group_scales = group_scales;
        tensor.group_zeros = group_zeros;
        
        // Pack INT4 values
        const n = rows * cols;
        for (0..n / 2) |i| {
            const idx0 = i * 2;
            const idx1 = i * 2 + 1;
            
            const row0 = idx0 / cols;
            const col0 = idx0 % cols;
            const grp0 = col0 / group_size;
            const s0 = group_scales[row0 * num_groups + grp0];
            
            const row1 = idx1 / cols;
            const col1 = idx1 % cols;
            const grp1 = col1 / group_size;
            const s1 = group_scales[row1 * num_groups + grp1];
            
            var q0 = @as(i32, @intFromFloat(@round(weights[idx0] / s0)));
            q0 = @max(-8, @min(7, q0));
            var q1 = @as(i32, @intFromFloat(@round(weights[idx1] / s1)));
            q1 = @max(-8, @min(7, q1));
            
            // Pack: low nibble = q0, high nibble = q1
            tensor.data_int4.?[i] = @intCast((@as(i8, @intCast(q1 & 0xF)) << 4) | @as(i8, @intCast(q0 & 0xF)));
        }
        // Handle odd element
        if (n % 2 == 1) {
            const idx = n - 1;
            const row_n = idx / cols;
            const col_n = idx % cols;
            const grp_n = col_n / group_size;
            const s_n = group_scales[row_n * num_groups + grp_n];
            var q_last = @as(i32, @intFromFloat(@round(weights[idx] / s_n)));
            q_last = @max(-8, @min(7, q_last));
            tensor.data_int4.?[n / 2] = @intCast(q_last & 0xF);
        }
        
        try self.quantized_weights.put(layer_idx, tensor);
        return self.quantized_weights.getPtr(layer_idx).?;
    }
    
    /// Return current compression statistics.
    pub fn getStats(self: *const Self) QuantizationStats {
        return self.stats;
    }
    
    /// Recompute and return the compression ratio across all stored quantized tensors.
    pub fn computeCompressionRatio(self: *Self) f32 {
        var original: usize = 0;
        var quantized: usize = 0;
        
        var it = self.quantized_weights.valueIterator();
        while (it.next()) |tensor| {
            const n = tensor.numElements();
            original += n * 4; // FP32 = 4 bytes
            
            if (tensor.data_int8 != null) {
                quantized += n; // INT8 = 1 byte
            } else if (tensor.data_int4 != null) {
                quantized += (n + 1) / 2; // INT4 = 0.5 bytes
            }
        }
        
        if (quantized > 0) {
            self.stats.original_size_mb = @as(f32, @floatFromInt(original)) / (1024 * 1024);
            self.stats.quantized_size_mb = @as(f32, @floatFromInt(quantized)) / (1024 * 1024);
            self.stats.compression_ratio = @as(f32, @floatFromInt(original)) / @as(f32, @floatFromInt(quantized));
        }
        
        return self.stats.compression_ratio;
    }
};

// ============================================================================
// Global Instance
// ============================================================================

var g_quant_manager: ?QuantizationManager = null;
var g_quant_config: QuantizationConfig = .{ .mode = .int8_static };
var g_quant_allocator: Allocator = std.heap.page_allocator;

/// Configure the global quantization manager before first use.
/// Must be called before `getGlobalQuantManager()` to take effect.
/// If called after the manager is already created, it will be
/// shut down and re-created with the new config on next access.
pub fn initGlobalQuantManager(allocator: Allocator, config: QuantizationConfig) void {
    if (g_quant_manager) |*qm| {
        qm.deinit();
        g_quant_manager = null;
    }
    g_quant_config = config;
    g_quant_allocator = allocator;
}

/// Get or create the global QuantizationManager singleton.
/// Uses the config set by `initGlobalQuantManager`, or defaults to
/// `int8_static` with the page allocator.
pub fn getGlobalQuantManager() !*QuantizationManager {
    if (g_quant_manager == null) {
        g_quant_manager = QuantizationManager.init(g_quant_allocator, g_quant_config);
    }
    return &g_quant_manager.?;
}

/// Shut down and destroy the global manager, freeing all resources.
pub fn shutdownGlobalQuantManager() void {
    if (g_quant_manager) |*qm| {
        qm.deinit();
        g_quant_manager = null;
    }
    c.int8_quantization_shutdown();
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "QuantizedTensor: init, numElements, deinit" {
    const shape = [_]usize{ 4, 8 };
    var tensor = try QuantizedTensor.init(testing.allocator, &shape, .{
        .scale = 0.1,
        .zero_point = 0,
        .min_val = -1.0,
        .max_val = 1.0,
    }, 32);
    defer tensor.deinit();

    try testing.expectEqual(@as(usize, 32), tensor.numElements());
    try testing.expectEqual(@as(usize, 2), tensor.shape.len);
    try testing.expect(tensor.owns_device_ptr);
}

test "QuantizedTensor: allocateInt8 and allocateInt4" {
    const shape = [_]usize{10};
    var tensor = try QuantizedTensor.init(testing.allocator, &shape, .{
        .scale = 1.0,
        .zero_point = 0,
        .min_val = 0,
        .max_val = 0,
    }, 32);
    defer tensor.deinit();

    try tensor.allocateInt8();
    try testing.expectEqual(@as(usize, 10), tensor.data_int8.?.len);

    try tensor.allocateInt4();
    try testing.expectEqual(@as(usize, 5), tensor.data_int4.?.len);
}

test "CalibrationManager: record activations and weights, finalize symmetric" {
    var cal = CalibrationManager.init(testing.allocator, .{
        .mode = .int8_static,
        .symmetric = true,
    });
    defer cal.deinit();

    // Record activation data
    const act_data = [_]f32{ -2.0, 0.5, 1.0, 3.0 };
    cal.recordActivationsHost(0, &act_data);

    // Record weight data
    const w_data = [_]f32{ -0.5, 0.25, 0.75, -1.0 };
    cal.recordWeightsHost(0, &w_data);

    try cal.finalize();

    const params = cal.layer_params.get(0).?;

    // Activation: abs_max = 3.0, scale = 3.0 / 127
    try testing.expectApproxEqAbs(@as(f32, 3.0 / 127.0), params.activations.scale, 1e-6);
    try testing.expectEqual(@as(i32, 0), params.activations.zero_point);

    // Weight: abs_max = 1.0, scale = 1.0 / 127
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 127.0), params.weights.scale, 1e-6);
    try testing.expectEqual(@as(i32, 0), params.weights.zero_point);
}

test "CalibrationManager: finalize asymmetric" {
    var cal = CalibrationManager.init(testing.allocator, .{
        .mode = .int8_static,
        .symmetric = false,
    });
    defer cal.deinit();

    const act_data = [_]f32{ -1.0, 0.0, 2.0, 5.0 };
    cal.recordActivationsHost(0, &act_data);

    try cal.finalize();

    const params = cal.layer_params.get(0).?;
    // range = 5.0 - (-1.0) = 6.0, scale = 6.0 / 255
    try testing.expectApproxEqAbs(@as(f32, 6.0 / 255.0), params.activations.scale, 1e-6);
    // zero_point = round(-(-1.0) / scale) = round(1.0 / (6/255)) = round(42.5) = 43
    try testing.expectEqual(@as(i32, 43), params.activations.zero_point);
}

test "QuantizationManager: quantizeWeights symmetric global" {
    var mgr = QuantizationManager.init(testing.allocator, .{
        .mode = .int8_static,
        .symmetric = true,
        .per_channel_weights = false,
    });
    defer mgr.deinit();

    const weights = [_]f32{ -1.0, 0.0, 0.5, 1.0 };
    const shape = [_]usize{4};

    const tensor = try mgr.quantizeWeights(0, &weights, &shape);

    // scale = 1.0 / 127 ≈ 0.00787
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 127.0), tensor.params.scale, 1e-6);

    // Round-trip check: q = round(val / scale)
    // -1.0 / (1/127) = -127 → -127
    try testing.expectEqual(@as(i8, -127), tensor.data_int8.?[0]);
    // 0.0 → 0
    try testing.expectEqual(@as(i8, 0), tensor.data_int8.?[1]);
    // 0.5 / (1/127) = 63.5 → 64
    try testing.expectEqual(@as(i8, 64), tensor.data_int8.?[2]);
    // 1.0 → 127
    try testing.expectEqual(@as(i8, 127), tensor.data_int8.?[3]);
}

test "QuantizationManager: quantizeWeights per-channel" {
    var mgr = QuantizationManager.init(testing.allocator, .{
        .mode = .int8_static,
        .symmetric = true,
        .per_channel_weights = true,
    });
    defer mgr.deinit();

    // 2 channels, 3 elements each
    const weights = [_]f32{
        -1.0, 0.5,  1.0, // channel 0: abs_max = 1.0
        -4.0, 2.0,  0.0, // channel 1: abs_max = 4.0
    };
    const shape = [_]usize{ 2, 3 };

    const tensor = try mgr.quantizeWeights(0, &weights, &shape);

    // Per-channel scales
    try testing.expect(tensor.group_scales != null);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 127.0), tensor.group_scales.?[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 4.0 / 127.0), tensor.group_scales.?[1], 1e-6);

    // Channel 0: -1.0 / (1/127) = -127
    try testing.expectEqual(@as(i8, -127), tensor.data_int8.?[0]);
    // Channel 1: -4.0 / (4/127) = -127
    try testing.expectEqual(@as(i8, -127), tensor.data_int8.?[3]);
    // Channel 1: 2.0 / (4/127) = 63.5 → 64
    try testing.expectEqual(@as(i8, 64), tensor.data_int8.?[4]);
}

test "QuantizationManager: quantizeAwq" {
    var mgr = QuantizationManager.init(testing.allocator, .{
        .mode = .int4_awq,
        .group_size = 2,
    });
    defer mgr.deinit();

    const weights = [_]f32{ 0.7, -0.3, 0.1, 0.5 };
    const shape = [_]usize{ 2, 2 };
    const act_scales = [_]f32{ 1.0, 1.0 };

    const tensor = try mgr.quantizeAwq(0, &weights, &shape, &act_scales);

    try testing.expect(tensor.data_int4 != null);
    try testing.expect(tensor.group_scales != null);
    try testing.expectEqual(@as(usize, 2), tensor.group_scales.?.len);
}

test "QuantizationManager: computeCompressionRatio" {
    var mgr = QuantizationManager.init(testing.allocator, .{
        .mode = .int8_static,
        .per_channel_weights = false,
    });
    defer mgr.deinit();

    const weights = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const shape = [_]usize{4};
    _ = try mgr.quantizeWeights(0, &weights, &shape);

    const ratio = mgr.computeCompressionRatio();
    // 4 elements × 4 bytes FP32 = 16 bytes, quantized = 4 bytes → ratio = 4.0
    try testing.expectApproxEqAbs(@as(f32, 4.0), ratio, 1e-6);
}

test "initGlobalQuantManager: configurable" {
    // Set a custom config
    initGlobalQuantManager(testing.allocator, .{
        .mode = .int8_dynamic,
        .group_size = 64,
    });
    defer shutdownGlobalQuantManager();

    const mgr = try getGlobalQuantManager();
    try testing.expectEqual(QuantizationMode.int8_dynamic, mgr.config.mode);
    try testing.expectEqual(@as(usize, 64), mgr.config.group_size);
}

test "getLastCudaError: empty on startup" {
    const err = getLastCudaError();
    try testing.expectEqual(@as(usize, 0), err.len);
}