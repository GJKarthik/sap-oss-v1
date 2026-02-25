//! Model Registry
//!
//! Provides a centralized registry for model configurations and factories.
//! Supports automatic model detection from HuggingFace config files.
//!
//! Features:
//! - Model architecture detection
//! - Config parsing from JSON
//! - Factory pattern for model instantiation
//! - Model capability queries

const std = @import("std");
const json = std.json;
const log = @import("../utils/logging.zig");

// ==============================================
// Model Architecture Enum
// ==============================================

/// Supported model architectures
pub const ModelArchitecture = enum {
    llama,
    mistral,
    qwen,
    phi,
    gemma,
    falcon,
    mpt,
    gpt2,
    gpt_neox,
    bloom,
    opt,
    command_r,
    deepseek,
    internlm,
    yi,
    unknown,
    
    pub fn fromString(arch_name: []const u8) ModelArchitecture {
        const arch_map = std.StaticStringMap(ModelArchitecture).initComptime(.{
            .{ "LlamaForCausalLM", .llama },
            .{ "LLaMAForCausalLM", .llama },
            .{ "MistralForCausalLM", .mistral },
            .{ "Qwen2ForCausalLM", .qwen },
            .{ "QWenLMHeadModel", .qwen },
            .{ "PhiForCausalLM", .phi },
            .{ "Phi3ForCausalLM", .phi },
            .{ "GemmaForCausalLM", .gemma },
            .{ "Gemma2ForCausalLM", .gemma },
            .{ "FalconForCausalLM", .falcon },
            .{ "MPTForCausalLM", .mpt },
            .{ "GPT2LMHeadModel", .gpt2 },
            .{ "GPTNeoXForCausalLM", .gpt_neox },
            .{ "BloomForCausalLM", .bloom },
            .{ "OPTForCausalLM", .opt },
            .{ "CohereForCausalLM", .command_r },
            .{ "DeepseekForCausalLM", .deepseek },
            .{ "InternLMForCausalLM", .internlm },
            .{ "YiForCausalLM", .yi },
        });
        
        return arch_map.get(arch_name) orelse .unknown;
    }
    
    pub fn toString(self: ModelArchitecture) []const u8 {
        return switch (self) {
            .llama => "LLaMA",
            .mistral => "Mistral",
            .qwen => "Qwen",
            .phi => "Phi",
            .gemma => "Gemma",
            .falcon => "Falcon",
            .mpt => "MPT",
            .gpt2 => "GPT-2",
            .gpt_neox => "GPT-NeoX",
            .bloom => "BLOOM",
            .opt => "OPT",
            .command_r => "Command-R",
            .deepseek => "DeepSeek",
            .internlm => "InternLM",
            .yi => "Yi",
            .unknown => "Unknown",
        };
    }
};

// ==============================================
// Model Configuration
// ==============================================

/// Universal model configuration parsed from HuggingFace config.json
pub const ModelConfig = struct {
    // Architecture
    architecture: ModelArchitecture = .unknown,
    model_type: []const u8 = "",
    
    // Dimensions
    hidden_size: u32 = 4096,
    intermediate_size: u32 = 11008,
    num_hidden_layers: u32 = 32,
    num_attention_heads: u32 = 32,
    num_key_value_heads: u32 = 32,  // For GQA/MQA
    head_dim: ?u32 = null,  // Explicit head dim (Gemma)
    
    // Vocabulary
    vocab_size: u32 = 32000,
    max_position_embeddings: u32 = 4096,
    
    // RoPE
    rope_theta: f32 = 10000.0,
    rope_scaling: ?RopeScaling = null,
    partial_rotary_factor: f32 = 1.0,
    
    // Normalization
    rms_norm_eps: f32 = 1e-5,
    layer_norm_eps: f32 = 1e-5,
    use_rms_norm: bool = true,
    
    // Attention
    use_sliding_window: bool = false,
    sliding_window: u32 = 4096,
    attn_logit_softcapping: f32 = 0.0,
    final_logit_softcapping: f32 = 0.0,
    
    // Misc
    tie_word_embeddings: bool = false,
    use_bias: bool = false,
    qk_layernorm: bool = false,
    
    /// Compute head dimension
    pub fn getHeadDim(self: ModelConfig) u32 {
        if (self.head_dim) |hd| return hd;
        return self.hidden_size / self.num_attention_heads;
    }
    
    /// Check if using grouped query attention
    pub fn isGQA(self: ModelConfig) bool {
        return self.num_key_value_heads < self.num_attention_heads and
            self.num_key_value_heads > 1;
    }
    
    /// Check if using multi-query attention
    pub fn isMQA(self: ModelConfig) bool {
        return self.num_key_value_heads == 1;
    }
    
    /// Estimate parameter count
    pub fn estimateParams(self: ModelConfig) u64 {
        var params: u64 = 0;
        
        // Embedding
        params += @as(u64, self.vocab_size) * self.hidden_size;
        
        // Per layer
        const head_dim = self.getHeadDim();
        const qkv_size = self.num_attention_heads * head_dim +
            2 * self.num_key_value_heads * head_dim;
        
        for (0..self.num_hidden_layers) |_| {
            // Attention
            params += @as(u64, self.hidden_size) * qkv_size;
            params += @as(u64, self.num_attention_heads) * head_dim * self.hidden_size;
            
            // MLP
            params += @as(u64, self.hidden_size) * self.intermediate_size * 3;
            
            // Norms
            params += self.hidden_size * 2;
        }
        
        // Output (if not tied)
        if (!self.tie_word_embeddings) {
            params += @as(u64, self.vocab_size) * self.hidden_size;
        }
        
        return params;
    }
};

/// RoPE scaling configuration
pub const RopeScaling = struct {
    type: []const u8 = "linear",
    factor: f32 = 1.0,
    original_max_position_embeddings: u32 = 4096,
};

// ==============================================
// Config Parser
// ==============================================

/// Parse model configuration from HuggingFace config.json
pub fn parseConfig(allocator: std.mem.Allocator, json_data: []const u8) !ModelConfig {
    var config = ModelConfig{};
    
    var parsed = try json.parseFromSlice(json.Value, allocator, json_data, .{});
    defer parsed.deinit();
    
    const root = parsed.value.object;
    
    // Architecture detection
    if (root.get("architectures")) |archs| {
        if (archs.array.items.len > 0) {
            const arch_str = archs.array.items[0].string;
            config.architecture = ModelArchitecture.fromString(arch_str);
        }
    }
    
    // Model type
    if (root.get("model_type")) |mt| {
        config.model_type = mt.string;
    }
    
    // Dimensions
    if (root.get("hidden_size")) |v| config.hidden_size = @intCast(v.integer);
    if (root.get("intermediate_size")) |v| config.intermediate_size = @intCast(v.integer);
    if (root.get("num_hidden_layers")) |v| config.num_hidden_layers = @intCast(v.integer);
    if (root.get("num_attention_heads")) |v| config.num_attention_heads = @intCast(v.integer);
    
    // GQA/MQA
    if (root.get("num_key_value_heads")) |v| {
        config.num_key_value_heads = @intCast(v.integer);
    } else {
        config.num_key_value_heads = config.num_attention_heads;
    }
    
    // Head dim (Gemma)
    if (root.get("head_dim")) |v| {
        config.head_dim = @intCast(v.integer);
    }
    
    // Vocabulary
    if (root.get("vocab_size")) |v| config.vocab_size = @intCast(v.integer);
    if (root.get("max_position_embeddings")) |v| config.max_position_embeddings = @intCast(v.integer);
    
    // RoPE
    if (root.get("rope_theta")) |v| {
        config.rope_theta = switch (v) {
            .float => @floatCast(v.float),
            .integer => @floatFromInt(v.integer),
            else => 10000.0,
        };
    }
    
    if (root.get("partial_rotary_factor")) |v| {
        config.partial_rotary_factor = @floatCast(v.float);
    }
    
    // Normalization
    if (root.get("rms_norm_eps")) |v| {
        config.rms_norm_eps = @floatCast(v.float);
    }
    if (root.get("layer_norm_eps")) |v| {
        config.layer_norm_eps = @floatCast(v.float);
    }
    
    // Sliding window
    if (root.get("sliding_window")) |v| {
        if (v != .null) {
            config.use_sliding_window = true;
            config.sliding_window = @intCast(v.integer);
        }
    }
    
    // Gemma 2 softcapping
    if (root.get("attn_logit_softcapping")) |v| {
        config.attn_logit_softcapping = @floatCast(v.float);
    }
    if (root.get("final_logit_softcapping")) |v| {
        config.final_logit_softcapping = @floatCast(v.float);
    }
    
    // Misc
    if (root.get("tie_word_embeddings")) |v| {
        config.tie_word_embeddings = v.bool;
    }
    if (root.get("use_bias")) |v| {
        config.use_bias = v.bool;
    }
    if (root.get("qk_layernorm")) |v| {
        config.qk_layernorm = v.bool;
    }
    
    return config;
}

// ==============================================
// Model Registry
// ==============================================

/// Model capabilities
pub const ModelCapabilities = struct {
    supports_gqa: bool = false,
    supports_sliding_window: bool = false,
    supports_logit_softcapping: bool = false,
    supports_speculative: bool = true,
    supports_prefix_caching: bool = true,
    supports_quantization: bool = true,
    max_batch_size: u32 = 256,
    max_context_length: u32 = 0,  // 0 = use model's max
};

/// Get capabilities for a model architecture
pub fn getCapabilities(arch: ModelArchitecture) ModelCapabilities {
    return switch (arch) {
        .llama => .{
            .supports_gqa = true,
            .max_context_length = 131072,  // LLaMA 3.1
        },
        .mistral => .{
            .supports_gqa = true,
            .supports_sliding_window = true,
            .max_context_length = 32768,
        },
        .qwen => .{
            .supports_gqa = true,
            .max_context_length = 131072,
        },
        .phi => .{
            .supports_gqa = true,
            .max_context_length = 131072,
        },
        .gemma => .{
            .supports_gqa = true,
            .supports_sliding_window = true,
            .supports_logit_softcapping = true,
            .max_context_length = 8192,
        },
        else => .{},
    };
}

/// Model Registry for managing model configurations
pub const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    configs: std.StringHashMap(ModelConfig),
    
    pub fn init(allocator: std.mem.Allocator) ModelRegistry {
        return ModelRegistry{
            .allocator = allocator,
            .configs = std.StringHashMap(ModelConfig).init(allocator),
        };
    }
    
    pub fn deinit(self: *ModelRegistry) void {
        self.configs.deinit();
    }
    
    /// Register a model configuration
    pub fn register(self: *ModelRegistry, name: []const u8, config: ModelConfig) !void {
        try self.configs.put(name, config);
        log.info("Registered model: {s} ({s})", .{ name, config.architecture.toString() });
    }
    
    /// Load model from HuggingFace path
    pub fn loadFromPath(self: *ModelRegistry, model_path: []const u8) !ModelConfig {
        // Read config.json
        const config_path = try std.fs.path.join(self.allocator, &.{ model_path, "config.json" });
        defer self.allocator.free(config_path);
        
        const file = try std.fs.cwd().openFile(config_path, .{});
        defer file.close();
        
        const file_size = try file.getEndPos();
        const json_data = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(json_data);
        
        _ = try file.readAll(json_data);
        
        const config = try parseConfig(self.allocator, json_data);
        
        log.info("Loaded model config: {s}", .{config.architecture.toString()});
        log.info("  hidden_size: {d}", .{config.hidden_size});
        log.info("  num_layers: {d}", .{config.num_hidden_layers});
        log.info("  num_heads: {d}/{d}", .{ config.num_attention_heads, config.num_key_value_heads });
        log.info("  estimated_params: {d}B", .{config.estimateParams() / 1_000_000_000});
        
        return config;
    }
    
    /// Get a registered model
    pub fn get(self: *ModelRegistry, name: []const u8) ?ModelConfig {
        return self.configs.get(name);
    }
    
    /// List all registered models
    pub fn list(self: *ModelRegistry) []const []const u8 {
        var names = std.ArrayList([]const u8).init(self.allocator);
        var it = self.configs.keyIterator();
        while (it.next()) |key| {
            names.append(key.*) catch continue;
        }
        return names.toOwnedSlice() catch &[_][]const u8{};
    }
};

// ==============================================
// Tests
// ==============================================

test "ModelArchitecture fromString" {
    try std.testing.expectEqual(ModelArchitecture.llama, ModelArchitecture.fromString("LlamaForCausalLM"));
    try std.testing.expectEqual(ModelArchitecture.gemma, ModelArchitecture.fromString("Gemma2ForCausalLM"));
    try std.testing.expectEqual(ModelArchitecture.unknown, ModelArchitecture.fromString("UnknownModel"));
}

test "ModelConfig estimateParams" {
    const config = ModelConfig{
        .hidden_size = 4096,
        .intermediate_size = 11008,
        .num_hidden_layers = 32,
        .num_attention_heads = 32,
        .num_key_value_heads = 32,
        .vocab_size = 32000,
    };
    
    const params = config.estimateParams();
    // LLaMA 7B should be around 7B params
    try std.testing.expect(params > 6_000_000_000);
    try std.testing.expect(params < 8_000_000_000);
}

test "parseConfig" {
    const allocator = std.testing.allocator;
    
    const json_str =
        \\{
        \\  "architectures": ["LlamaForCausalLM"],
        \\  "hidden_size": 4096,
        \\  "intermediate_size": 11008,
        \\  "num_hidden_layers": 32,
        \\  "num_attention_heads": 32,
        \\  "num_key_value_heads": 8,
        \\  "vocab_size": 32000,
        \\  "rope_theta": 10000.0
        \\}
    ;
    
    const config = try parseConfig(allocator, json_str);
    
    try std.testing.expectEqual(ModelArchitecture.llama, config.architecture);
    try std.testing.expectEqual(@as(u32, 4096), config.hidden_size);
    try std.testing.expectEqual(@as(u32, 8), config.num_key_value_heads);
    try std.testing.expect(config.isGQA());
}