//! Hybrid Drafter: Auto-Select DART Head vs QuantSpec
//!
//! Automatically selects the best drafting strategy based on:
//!   - Model size (3B vs 7B+)
//!   - Available VRAM
//!   - Task type (code, chat, RAG)
//!
//! Selection Logic:
//!   8B model detected → DART head (default)
//!   3B model detected → QuantSpec (higher acceptance rates)
//!   Mixed workload    → Dynamic switching

const std = @import("std");
const Allocator = std.mem.Allocator;

const quantspec = @import("quantspec_drafter.zig");
const QuantSpecDrafter = quantspec.QuantSpecDrafter;
const QuantSpecConfig = quantspec.QuantSpecConfig;
const ModelSizeTier = quantspec.ModelSizeTier;

const heterospec = @import("heterospec_tree.zig");
const HeteroSpecTree = heterospec.HeteroSpecTree;
const HeteroSpecConfig = heterospec.HeteroSpecConfig;

/// Draft strategy
pub const DraftStrategy = enum {
    dart_head,      // Lightweight head, best for 7B+ models
    quantspec,      // 4-bit quantized copy, best for 3B models
    heterospec,     // Entropy-adaptive tree, works with either
    
    pub fn label(self: DraftStrategy) []const u8 {
        return switch (self) {
            .dart_head => "DART Head (lightweight, 7B+)",
            .quantspec => "QuantSpec (4-bit copy, 3B)",
            .heterospec => "HeteroSpec (entropy-adaptive)",
        };
    }
};

/// Hardware constraints
pub const HardwareProfile = struct {
    /// Total VRAM in GB
    total_vram_gb: f32 = 16.0,
    
    /// Currently used VRAM in GB
    used_vram_gb: f32 = 0.0,
    
    /// Whether INT4 quantization is supported
    supports_int4: bool = true,
    
    /// Whether FP8 is supported (Ampere+)
    supports_fp8: bool = false,
    
    /// Memory bandwidth in GB/s
    memory_bandwidth_gbs: f32 = 320.0,
    
    /// Tensor core TOPS at INT8
    int8_tops: f32 = 130.0,
    
    /// Create T4 profile
    pub fn t4() HardwareProfile {
        return .{
            .total_vram_gb = 16.0,
            .supports_int4 = true,
            .supports_fp8 = false,
            .memory_bandwidth_gbs = 320.0,
            .int8_tops = 130.0,
        };
    }
    
    /// Create A10 profile
    pub fn a10() HardwareProfile {
        return .{
            .total_vram_gb = 24.0,
            .supports_int4 = true,
            .supports_fp8 = false,
            .memory_bandwidth_gbs = 600.0,
            .int8_tops = 250.0,
        };
    }
    
    /// Available VRAM
    pub fn availableVRAM(self: HardwareProfile) f32 {
        return self.total_vram_gb - self.used_vram_gb;
    }
};

/// Model profile
pub const ModelProfile = struct {
    /// Model name for identification
    name: []const u8,
    
    /// Parameter count in billions
    param_count_billions: f32,
    
    /// Vocabulary size
    vocab_size: u32 = 32000,
    
    /// Hidden dimension
    hidden_size: u32 = 4096,
    
    /// Number of layers
    num_layers: u32 = 32,
    
    /// Get size tier
    pub fn sizeTier(self: ModelProfile) ModelSizeTier {
        return ModelSizeTier.fromParams(self.param_count_billions);
    }
    
    /// Predefined profiles
    pub fn llama3_8b() ModelProfile {
        return .{
            .name = "Llama-3.1-8B",
            .param_count_billions = 8.0,
            .vocab_size = 128256,
            .hidden_size = 4096,
            .num_layers = 32,
        };
    }
    
    pub fn phi3_mini() ModelProfile {
        return .{
            .name = "Phi-3.5-mini-3B",
            .param_count_billions = 3.0,
            .vocab_size = 32064,
            .hidden_size = 3072,
            .num_layers = 32,
        };
    }
    
    pub fn qwen25_3b() ModelProfile {
        return .{
            .name = "Qwen2.5-3B",
            .param_count_billions = 3.0,
            .vocab_size = 151936,
            .hidden_size = 2048,
            .num_layers = 36,
        };
    }
};

/// Hybrid drafter configuration
pub const HybridConfig = struct {
    /// Minimum VRAM buffer to keep free (GB)
    vram_buffer_gb: f32 = 2.0,
    
    /// Whether to allow dynamic strategy switching
    allow_dynamic_switching: bool = true,
    
    /// Minimum acceptance rate before considering strategy switch
    min_acceptance_rate: f32 = 0.4,
    
    /// Number of steps between strategy evaluations
    evaluation_interval: u32 = 100,
    
    /// Default strategy if auto-detection fails
    default_strategy: DraftStrategy = .dart_head,
    
    pub fn default() HybridConfig {
        return .{};
    }
};

/// Strategy selection result
pub const StrategySelection = struct {
    strategy: DraftStrategy,
    reason: []const u8,
    estimated_speedup: f32,
    fits_in_vram: bool,
};

/// Hybrid Drafter
pub const HybridDrafter = struct {
    allocator: Allocator,
    config: HybridConfig,
    hardware: HardwareProfile,
    model: ?ModelProfile,
    
    /// Current active strategy
    current_strategy: DraftStrategy,
    
    /// Strategy components (lazily initialized)
    quantspec_drafter: ?QuantSpecDrafter,
    heterospec_tree: ?HeteroSpecTree,
    
    /// Statistics
    stats: HybridStats,
    
    const Self = @This();
    
    pub const HybridStats = struct {
        dart_head_steps: u64 = 0,
        quantspec_steps: u64 = 0,
        heterospec_steps: u64 = 0,
        strategy_switches: u64 = 0,
        total_tokens_generated: u64 = 0,
        
        pub fn strategyDistribution(self: HybridStats) struct { dart: f64, quant: f64, hetero: f64 } {
            const total = self.dart_head_steps + self.quantspec_steps + self.heterospec_steps;
            if (total == 0) return .{ .dart = 0, .quant = 0, .hetero = 0 };
            return .{
                .dart = @as(f64, @floatFromInt(self.dart_head_steps)) / @as(f64, @floatFromInt(total)),
                .quant = @as(f64, @floatFromInt(self.quantspec_steps)) / @as(f64, @floatFromInt(total)),
                .hetero = @as(f64, @floatFromInt(self.heterospec_steps)) / @as(f64, @floatFromInt(total)),
            };
        }
    };
    
    pub fn init(allocator: Allocator, config: HybridConfig, hardware: HardwareProfile) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .hardware = hardware,
            .model = null,
            .current_strategy = config.default_strategy,
            .quantspec_drafter = null,
            .heterospec_tree = null,
            .stats = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        // QuantSpecDrafter and HeteroSpecTree don't need explicit cleanup
        _ = self;
    }
    
    /// Set the model profile and auto-select strategy
    pub fn setModel(self: *Self, model: ModelProfile) StrategySelection {
        self.model = model;
        return self.autoSelectStrategy();
    }
    
    /// Auto-select the best strategy based on model and hardware
    pub fn autoSelectStrategy(self: *Self) StrategySelection {
        const model = self.model orelse {
            return .{
                .strategy = self.config.default_strategy,
                .reason = "No model profile set, using default",
                .estimated_speedup = 1.5,
                .fits_in_vram = true,
            };
        };
        
        const tier = model.sizeTier();
        const available_vram = self.hardware.availableVRAM() - self.config.vram_buffer_gb;
        
        // Check QuantSpec feasibility
        const quantspec_config = QuantSpecConfig.default();
        const quantspec_vram = quantspec_config.estimateVRAM(model.param_count_billions);
        const quantspec_fits = quantspec_vram <= available_vram;
        
        // Decision logic
        if (tier == .small and quantspec_fits and self.hardware.supports_int4) {
            // Small model + enough VRAM → QuantSpec
            self.current_strategy = .quantspec;
            self.initQuantSpec();
            return .{
                .strategy = .quantspec,
                .reason = "Small model (3B), QuantSpec provides higher acceptance rates",
                .estimated_speedup = 2.2,
                .fits_in_vram = true,
            };
        } else if (tier == .medium or tier == .large) {
            // Medium/large model → DART head
            self.current_strategy = .dart_head;
            return .{
                .strategy = .dart_head,
                .reason = "Large model (7B+), DART head is more VRAM-efficient",
                .estimated_speedup = 1.8,
                .fits_in_vram = true,
            };
        } else {
            // Fallback
            self.current_strategy = .dart_head;
            return .{
                .strategy = .dart_head,
                .reason = "QuantSpec would not fit in VRAM, using DART head",
                .estimated_speedup = 1.5,
                .fits_in_vram = !quantspec_fits,
            };
        }
    }
    
    /// Initialize QuantSpec drafter
    fn initQuantSpec(self: *Self) void {
        if (self.quantspec_drafter == null) {
            self.quantspec_drafter = QuantSpecDrafter.init(
                self.allocator,
                QuantSpecConfig.default(),
            );
        }
    }
    
    /// Initialize HeteroSpec tree
    fn initHeteroSpec(self: *Self) void {
        if (self.heterospec_tree == null) {
            self.heterospec_tree = HeteroSpecTree.init(
                self.allocator,
                HeteroSpecConfig.default(),
            );
        }
    }
    
    /// Record a step with the current strategy
    pub fn recordStep(self: *Self, tokens_generated: u32) void {
        switch (self.current_strategy) {
            .dart_head => self.stats.dart_head_steps += 1,
            .quantspec => self.stats.quantspec_steps += 1,
            .heterospec => self.stats.heterospec_steps += 1,
        }
        self.stats.total_tokens_generated += tokens_generated;
    }
    
    /// Switch strategy (for dynamic adaptation)
    pub fn switchStrategy(self: *Self, new_strategy: DraftStrategy) void {
        if (self.current_strategy != new_strategy) {
            self.current_strategy = new_strategy;
            self.stats.strategy_switches += 1;
            
            // Initialize components as needed
            switch (new_strategy) {
                .quantspec => self.initQuantSpec(),
                .heterospec => self.initHeteroSpec(),
                .dart_head => {},
            }
        }
    }
    
    /// Get current strategy
    pub fn getCurrentStrategy(self: *const Self) DraftStrategy {
        return self.current_strategy;
    }
    
    /// Get statistics
    pub fn getStats(self: *const Self) HybridStats {
        return self.stats;
    }
    
    /// Reset statistics
    pub fn resetStats(self: *Self) void {
        self.stats = .{};
    }
    
    /// Get recommendation for a given model size and VRAM
    pub fn recommend(param_count_billions: f32, available_vram_gb: f32) StrategySelection {
        const tier = ModelSizeTier.fromParams(param_count_billions);
        const quantspec_config = QuantSpecConfig.default();
        const quantspec_vram = quantspec_config.estimateVRAM(param_count_billions);
        const quantspec_fits = quantspec_vram <= available_vram_gb;
        
        if (tier == .small and quantspec_fits) {
            return .{
                .strategy = .quantspec,
                .reason = "Recommended for 3B models with sufficient VRAM",
                .estimated_speedup = 2.2,
                .fits_in_vram = true,
            };
        } else {
            return .{
                .strategy = .dart_head,
                .reason = "Recommended for 7B+ models or limited VRAM",
                .estimated_speedup = 1.8,
                .fits_in_vram = true,
            };
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DraftStrategy labels" {
    try std.testing.expect(DraftStrategy.dart_head.label().len > 0);
    try std.testing.expect(DraftStrategy.quantspec.label().len > 0);
    try std.testing.expect(DraftStrategy.heterospec.label().len > 0);
}

test "HardwareProfile T4" {
    const t4 = HardwareProfile.t4();
    try std.testing.expectEqual(@as(f32, 16.0), t4.total_vram_gb);
    try std.testing.expect(!t4.supports_fp8);
    try std.testing.expect(t4.supports_int4);
}

test "HardwareProfile available VRAM" {
    var hw = HardwareProfile.t4();
    hw.used_vram_gb = 10.0;
    try std.testing.expectEqual(@as(f32, 6.0), hw.availableVRAM());
}

test "ModelProfile size tier" {
    const llama8b = ModelProfile.llama3_8b();
    try std.testing.expectEqual(ModelSizeTier.large, llama8b.sizeTier());
    
    const phi3 = ModelProfile.phi3_mini();
    try std.testing.expectEqual(ModelSizeTier.small, phi3.sizeTier());
}

test "HybridDrafter initialization" {
    const allocator = std.testing.allocator;
    var drafter = HybridDrafter.init(
        allocator,
        HybridConfig.default(),
        HardwareProfile.t4(),
    );
    defer drafter.deinit();
    
    try std.testing.expectEqual(DraftStrategy.dart_head, drafter.getCurrentStrategy());
}

test "HybridDrafter auto-select for 3B model" {
    const allocator = std.testing.allocator;
    var drafter = HybridDrafter.init(
        allocator,
        HybridConfig.default(),
        HardwareProfile.t4(),
    );
    defer drafter.deinit();
    
    const selection = drafter.setModel(ModelProfile.phi3_mini());
    try std.testing.expectEqual(DraftStrategy.quantspec, selection.strategy);
    try std.testing.expect(selection.fits_in_vram);
}

test "HybridDrafter auto-select for 8B model" {
    const allocator = std.testing.allocator;
    var drafter = HybridDrafter.init(
        allocator,
        HybridConfig.default(),
        HardwareProfile.t4(),
    );
    defer drafter.deinit();
    
    const selection = drafter.setModel(ModelProfile.llama3_8b());
    try std.testing.expectEqual(DraftStrategy.dart_head, selection.strategy);
}

test "HybridDrafter strategy switch" {
    const allocator = std.testing.allocator;
    var drafter = HybridDrafter.init(
        allocator,
        HybridConfig.default(),
        HardwareProfile.t4(),
    );
    defer drafter.deinit();
    
    drafter.switchStrategy(.heterospec);
    try std.testing.expectEqual(DraftStrategy.heterospec, drafter.getCurrentStrategy());
    try std.testing.expectEqual(@as(u64, 1), drafter.stats.strategy_switches);
}

test "HybridDrafter recommend" {
    // 3B model recommendation
    const small_rec = HybridDrafter.recommend(3.0, 16.0);
    try std.testing.expectEqual(DraftStrategy.quantspec, small_rec.strategy);
    
    // 8B model recommendation
    const large_rec = HybridDrafter.recommend(8.0, 16.0);
    try std.testing.expectEqual(DraftStrategy.dart_head, large_rec.strategy);
}

test "HybridStats distribution" {
    var stats = HybridDrafter.HybridStats{
        .dart_head_steps = 50,
        .quantspec_steps = 30,
        .heterospec_steps = 20,
    };
    
    const dist = stats.strategyDistribution();
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), dist.dart, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), dist.quant, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), dist.hetero, 0.01);
}