//! ANWID Multi-Model Router
//! Routes requests to different GPU kernels or NIM models based on model ID
//! Supports Mangle rule-based routing and homogeneous batch formation

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.model_router);

// ============================================================================
// Model Types
// ============================================================================

pub const ModelType = enum {
    /// Local embedding model (GPU/CPU)
    embedding_local,
    /// Local LLM inference (GPU)
    llm_local,
    /// NVIDIA NIM embedding API
    nim_embedding,
    /// NVIDIA NIM LLM API
    nim_llm,
    /// CPU fallback
    cpu_fallback,
};

pub const ModelConfig = struct {
    model_id: []const u8,
    model_type: ModelType,
    endpoint: ?[]const u8 = null, // For NIM models
    max_batch_size: usize = 64,
    max_sequence_length: usize = 512,
    embedding_dim: usize = 768,
    priority: u8 = 100, // Lower = higher priority
    enabled: bool = true,
};

// ============================================================================
// Routing Rules
// ============================================================================

pub const RoutingRule = struct {
    /// Pattern to match model_id (prefix match)
    pattern: []const u8,
    /// Target model type
    target: ModelType,
    /// Weight for load balancing (0-100)
    weight: u8 = 100,
    /// Fallback model if primary fails
    fallback: ?ModelType = null,
};

// ============================================================================
// Model Router
// ============================================================================

pub const ModelRouter = struct {
    allocator: std.mem.Allocator,
    
    // Registered models
    models: std.StringHashMap(ModelConfig),
    
    // Routing rules (evaluated in order)
    rules: std.ArrayList(RoutingRule),
    
    // Default model type
    default_model: ModelType,
    
    // Statistics per model type
    requests_per_type: [@typeInfo(ModelType).@"enum".fields.len]std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator) !*ModelRouter {
        const router = try allocator.create(ModelRouter);
        
        router.* = .{
            .allocator = allocator,
            .models = std.StringHashMap(ModelConfig).init(allocator),
            .rules = std.ArrayList(RoutingRule).init(allocator),
            .default_model = .embedding_local,
            .requests_per_type = undefined,
        };
        
        // Initialize counters
        for (&router.requests_per_type) |*counter| {
            counter.* = std.atomic.Value(u64).init(0);
        }
        
        log.info("Model Router initialized", .{});
        return router;
    }
    
    pub fn deinit(self: *ModelRouter) void {
        self.models.deinit();
        self.rules.deinit();
        self.allocator.destroy(self);
        log.info("Model Router destroyed", .{});
    }
    
    /// Register a model
    pub fn registerModel(self: *ModelRouter, config: ModelConfig) !void {
        try self.models.put(config.model_id, config);
        log.info("Registered model: {s} (type: {})", .{ config.model_id, config.model_type });
    }
    
    /// Add a routing rule
    pub fn addRule(self: *ModelRouter, rule: RoutingRule) !void {
        try self.rules.append(rule);
        log.info("Added routing rule: '{s}' → {}", .{ rule.pattern, rule.target });
    }
    
    /// Set default model type
    pub fn setDefault(self: *ModelRouter, model_type: ModelType) void {
        self.default_model = model_type;
        log.info("Default model set to: {}", .{model_type});
    }
    
    /// Route a request to the appropriate model type
    pub fn route(self: *ModelRouter, model_id: []const u8) RouteResult {
        // Check if model is directly registered
        if (self.models.get(model_id)) |config| {
            if (config.enabled) {
                self.recordRequest(config.model_type);
                return .{
                    .model_type = config.model_type,
                    .config = config,
                    .matched_rule = null,
                };
            }
        }
        
        // Evaluate routing rules
        for (self.rules.items) |rule| {
            if (std.mem.startsWith(u8, model_id, rule.pattern)) {
                self.recordRequest(rule.target);
                return .{
                    .model_type = rule.target,
                    .config = null,
                    .matched_rule = rule.pattern,
                };
            }
        }
        
        // Use default
        self.recordRequest(self.default_model);
        return .{
            .model_type = self.default_model,
            .config = null,
            .matched_rule = null,
        };
    }
    
    /// Get fallback model type
    pub fn getFallback(self: *ModelRouter, model_type: ModelType) ModelType {
        // Check rules for fallback
        for (self.rules.items) |rule| {
            if (rule.target == model_type and rule.fallback != null) {
                return rule.fallback.?;
            }
        }
        
        // Default fallback chain
        return switch (model_type) {
            .embedding_local => .cpu_fallback,
            .llm_local => .nim_llm,
            .nim_embedding => .embedding_local,
            .nim_llm => .cpu_fallback,
            .cpu_fallback => .cpu_fallback,
        };
    }
    
    fn recordRequest(self: *ModelRouter, model_type: ModelType) void {
        _ = self.requests_per_type[@intFromEnum(model_type)].fetchAdd(1, .monotonic);
    }
    
    /// Get routing statistics
    pub fn getStats(self: *const ModelRouter) RouterStats {
        var stats: RouterStats = .{
            .total_requests = 0,
            .requests_by_type = undefined,
            .registered_models = self.models.count(),
            .routing_rules = self.rules.items.len,
        };
        
        for (self.requests_per_type, 0..) |*counter, i| {
            const count = counter.load(.acquire);
            stats.requests_by_type[i] = count;
            stats.total_requests += count;
        }
        
        return stats;
    }
};

pub const RouteResult = struct {
    model_type: ModelType,
    config: ?ModelConfig,
    matched_rule: ?[]const u8,
};

pub const RouterStats = struct {
    total_requests: u64,
    requests_by_type: [@typeInfo(ModelType).@"enum".fields.len]u64,
    registered_models: usize,
    routing_rules: usize,
};

// ============================================================================
// Batch Formation for Homogeneous Batching
// ============================================================================

pub const BatchRequest = struct {
    id: u64,
    model_id: []const u8,
    model_type: ModelType,
    tokens: []const u32,
    timestamp_ns: i64,
};

pub const HomogeneousBatcher = struct {
    allocator: std.mem.Allocator,
    router: *ModelRouter,
    
    // Queues per model type
    queues: [@typeInfo(ModelType).@"enum".fields.len]std.ArrayList(BatchRequest),
    
    // Configuration
    max_batch_size: usize,
    max_wait_ns: i64,
    
    pub fn init(allocator: std.mem.Allocator, router: *ModelRouter, max_batch_size: usize, max_wait_ns: i64) !*HomogeneousBatcher {
        const batcher = try allocator.create(HomogeneousBatcher);
        
        batcher.* = .{
            .allocator = allocator,
            .router = router,
            .queues = undefined,
            .max_batch_size = max_batch_size,
            .max_wait_ns = max_wait_ns,
        };
        
        for (&batcher.queues) |*queue| {
            queue.* = std.ArrayList(BatchRequest).init(allocator);
        }
        
        return batcher;
    }
    
    pub fn deinit(self: *HomogeneousBatcher) void {
        for (&self.queues) |*queue| {
            queue.deinit();
        }
        self.allocator.destroy(self);
    }
    
    /// Add a request to the appropriate queue
    pub fn enqueue(self: *HomogeneousBatcher, request: BatchRequest) !void {
        const queue_idx = @intFromEnum(request.model_type);
        try self.queues[queue_idx].append(request);
    }
    
    /// Get next ready batch (if any)
    pub fn getNextBatch(self: *HomogeneousBatcher) ?HomogeneousBatch {
        const now = std.time.nanoTimestamp();
        
        for (&self.queues, 0..) |*queue, type_idx| {
            if (queue.items.len == 0) continue;
            
            const oldest = queue.items[0].timestamp_ns;
            const waited = now - oldest;
            
            // Batch is ready if full or timeout reached
            if (queue.items.len >= self.max_batch_size or waited >= self.max_wait_ns) {
                const batch_size = @min(queue.items.len, self.max_batch_size);
                const requests = self.allocator.alloc(BatchRequest, batch_size) catch continue;
                
                @memcpy(requests, queue.items[0..batch_size]);
                
                // Remove from queue
                for (0..batch_size) |_| {
                    _ = queue.orderedRemove(0);
                }
                
                return .{
                    .model_type = @enumFromInt(type_idx),
                    .requests = requests,
                    .allocator = self.allocator,
                };
            }
        }
        
        return null;
    }
};

pub const HomogeneousBatch = struct {
    model_type: ModelType,
    requests: []BatchRequest,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *HomogeneousBatch) void {
        self.allocator.free(self.requests);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ModelRouter basic routing" {
    const router = try ModelRouter.init(std.testing.allocator);
    defer router.deinit();
    
    try router.registerModel(.{
        .model_id = "text-embedding-ada-002",
        .model_type = .nim_embedding,
    });
    
    const result = router.route("text-embedding-ada-002");
    try std.testing.expectEqual(ModelType.nim_embedding, result.model_type);
}

test "ModelRouter rule-based routing" {
    const router = try ModelRouter.init(std.testing.allocator);
    defer router.deinit();
    
    try router.addRule(.{
        .pattern = "gpt-",
        .target = .nim_llm,
    });
    
    const result = router.route("gpt-4-turbo");
    try std.testing.expectEqual(ModelType.nim_llm, result.model_type);
}

test "ModelRouter default fallback" {
    const router = try ModelRouter.init(std.testing.allocator);
    defer router.deinit();
    
    const result = router.route("unknown-model");
    try std.testing.expectEqual(ModelType.embedding_local, result.model_type);
}