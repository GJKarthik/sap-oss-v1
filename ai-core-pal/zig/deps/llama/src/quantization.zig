//! Quantization Manager - Phase 4 Optimization
//!
//! High-level API for INT8/INT4 quantization:
//! - Calibration workflow
//! - Quantized model loading
//! - Dynamic quantization
//! - AWQ and SmoothQuant support

const std = @import("std");
const Allocator = std.mem.Allocator;

// C FFI for CUDA quantization
const c = @cImport({
    @cInclude("cuda_kernels.h");
});

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
    
    /// GPU device pointer
    device_ptr: ?*anyopaque = null,
    
    allocator: Allocator,
    
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
    
    pub fn deinit(self: *Self) void {
        if (self.data_int8) |d| self.allocator.free(d);
        if (self.data_int4) |d| self.allocator.free(d);
        if (self.group_scales) |s| self.allocator.free(s);
        if (self.group_zeros) |z| self.allocator.free(z);
        self.allocator.free(self.shape);
        
        if (self.device_ptr) |ptr| {
            _ = c.cuda_free(ptr);
        }
    }
    
    /// Get total number of elements
    pub fn numElements(self: *const Self) usize {
        var total: usize = 1;
        for (self.shape) |dim| {
            total *= dim;
        }
        return total;
    }
    
    /// Allocate INT8 storage
    pub fn allocateInt8(self: *Self) !void {
        const n = self.numElements();
        self.data_int8 = try self.allocator.alloc(i8, n);
    }
    
    /// Allocate INT4 storage (packed)
    pub fn allocateInt4(self: *Self) !void {
        const n = self.numElements();
        // 2 INT4 values packed into 1 INT8
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
    
    samples_collected: usize,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, config: QuantizationConfig) Self {
        return .{
            .config = config,
            .layer_params = std.AutoHashMap(usize, LayerQuantParams).init(allocator),
            .activation_mins = std.AutoHashMap(usize, f32).init(allocator),
            .activation_maxs = std.AutoHashMap(usize, f32).init(allocator),
            .samples_collected = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.layer_params.deinit();
        self.activation_mins.deinit();
        self.activation_maxs.deinit();
    }
    
    /// Record activation statistics for calibration
    pub fn recordActivations(
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
    
    /// Calibrate a layer using CUDA
    pub fn calibrateLayer(
        self: *Self,
        layer_idx: usize,
        weights_ptr: *anyopaque,
        weights_size: usize,
        activations_ptr: *anyopaque,
        activations_size: usize,
    ) !void {
        _ = self;
        const result = c.calibrate_layer(
            @intCast(layer_idx),
            @ptrCast(weights_ptr),
            @intCast(weights_size),
            @ptrCast(activations_ptr),
            @intCast(activations_size),
        );
        
        if (result != 0) {
            return error.CalibrationFailed;
        }
    }
    
    /// Finalize calibration and compute scales
    pub fn finalize(self: *Self) !void {
        var it = self.activation_mins.iterator();
        while (it.next()) |entry| {
            const layer_idx = entry.key_ptr.*;
            const min_val = entry.value_ptr.*;
            const max_val = self.activation_maxs.get(layer_idx) orelse 0;
            
            const abs_max = @max(@abs(min_val), @abs(max_val));
            const scale = abs_max / 127.0;
            
            const params = LayerQuantParams{
                .weights = .{ .scale = scale, .zero_point = 0, .min_val = min_val, .max_val = max_val },
                .activations = .{ .scale = scale, .zero_point = 0, .min_val = min_val, .max_val = max_val },
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
    
    /// Quantize a weight tensor
    pub fn quantizeWeights(
        self: *Self,
        layer_idx: usize,
        weights: []const f32,
        shape: []const usize,
    ) !*QuantizedTensor {
        // Find min/max
        var min_val: f32 = std.math.floatMax(f32);
        var max_val: f32 = -std.math.floatMax(f32);
        
        for (weights) |val| {
            min_val = @min(min_val, val);
            max_val = @max(max_val, val);
        }
        
        const abs_max = @max(@abs(min_val), @abs(max_val));
        const scale = if (abs_max > 0) abs_max / 127.0 else 1.0;
        
        const params = QuantParams{
            .scale = scale,
            .zero_point = 0,
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
        
        // Quantize
        for (weights, 0..) |val, i| {
            const scaled = val / scale;
            var quantized = @as(i32, @intFromFloat(@round(scaled)));
            quantized = @max(-128, @min(127, quantized));
            tensor.data_int8.?[i] = @intCast(quantized);
        }
        
        try self.quantized_weights.put(layer_idx, tensor);
        return self.quantized_weights.getPtr(layer_idx).?;
    }
    
    /// Quantize weights using CUDA (GPU)
    pub fn quantizeWeightsGpu(
        self: *Self,
        layer_idx: usize,
        weights_gpu: *anyopaque,
        output_gpu: *anyopaque,
        n: usize,
        scale: f32,
    ) !void {
        const result = c.quantize_fp32_to_int8(
            @ptrCast(output_gpu),
            @ptrCast(weights_gpu),
            scale,
            0, // zero_point
            @intCast(n),
        );
        
        if (result != 0) {
            return error.QuantizationFailed;
        }
        
        _ = self;
        _ = layer_idx;
    }
    
    /// Apply SmoothQuant transformation
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
            return error.SmoothQuantFailed;
        }
        
        _ = self;
        _ = layer_idx;
    }
    
    /// Perform INT8 GEMM
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
            return error.Int8GemmFailed;
        }
        
        _ = self;
    }
    
    /// Dynamic quantization (runtime)
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
            return error.DynamicQuantizeFailed;
        }
        
        _ = self;
    }
    
    /// Get compression statistics
    pub fn getStats(self: *const Self) QuantizationStats {
        return self.stats;
    }
    
    /// Compute compression ratio
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

pub fn getGlobalQuantManager() !*QuantizationManager {
    if (g_quant_manager == null) {
        g_quant_manager = QuantizationManager.init(std.heap.page_allocator, .{
            .mode = .int8_static,
        });
    }
    return &g_quant_manager.?;
}

pub fn shutdownGlobalQuantManager() void {
    if (g_quant_manager) |*qm| {
        qm.deinit();
        g_quant_manager = null;
    }
    c.int8_quantization_shutdown();
}