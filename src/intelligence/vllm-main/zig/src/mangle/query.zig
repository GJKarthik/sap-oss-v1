//! Mangle Query Engine — Execute queries against parsed facts and rules
//!
//! Provides:
//!   - Fact injection (add runtime facts like GPU specs)
//!   - Simple query execution (find matching facts)
//!   - Basic unification for rule evaluation
//!
//! This is a self-contained query engine - each service has its own copy.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const parser = @import("parser.zig");
const loader = @import("loader.zig");

// ============================================================================
// Query Engine
// ============================================================================

pub const MangleQueryEngine = struct {
    allocator: Allocator,
    loader: loader.MangleLoader,
    program: ?parser.MangleProgram,
    injected_facts: std.ArrayList(parser.Fact),
    
    pub fn init(allocator: Allocator, mangle_dir: []const u8) MangleQueryEngine {
        return .{
            .allocator = allocator,
            .loader = loader.MangleLoader.init(allocator, mangle_dir),
            .program = null,
            .injected_facts = .{},
        };
    }
    
    pub fn deinit(self: *MangleQueryEngine) void {
        self.loader.deinit();
        if (self.program) |*prog| prog.deinit();
        self.injected_facts.deinit();
    }
    
    /// Load and parse all .mg files from mangle/ directory
    pub fn loadRules(self: *MangleQueryEngine) !usize {
        const file_count = try self.loader.loadAll();
        if (file_count == 0) {
            std.log.warn("No .mg files found in mangle directory", .{});
            return 0;
        }
        
        const content = try self.loader.getAllContent();
        defer self.allocator.free(content);
        
        var p = parser.MangleParser.init(self.allocator, content);
        self.program = try p.parse();
        
        std.log.info("Loaded {d} facts and {d} rules from {d} files", .{
            self.program.?.facts.items.len,
            self.program.?.rules.items.len,
            file_count,
        });
        
        return file_count;
    }
    
    // ========================================================================
    // Fact Injection API
    // ========================================================================
    
    /// Inject a fact at runtime (e.g., gpu_device(0, "T4", 7.5, 16384, 320))
    pub fn injectFact(self: *MangleQueryEngine, name: []const u8, args: []const parser.Term) !void {
        try self.injected_facts.append(.{
            .predicate = .{
                .name = try self.allocator.dupe(u8, name),
                .args = args,
            },
        });
    }
    
    /// Inject GPU device fact from detected hardware
    pub fn injectGpuDevice(
        self: *MangleQueryEngine,
        device_id: i64,
        name: []const u8,
        compute_capability: f64,
        memory_mb: i64,
        tensor_cores: i64,
    ) !void {
        var args = try self.allocator.alloc(parser.Term, 5);
        args[0] = .{ .number_int = device_id };
        args[1] = .{ .constant = try self.allocator.dupe(u8, name) };
        args[2] = .{ .number_float = compute_capability };
        args[3] = .{ .number_int = memory_mb };
        args[4] = .{ .number_int = tensor_cores };
        
        try self.injectFact("gpu_device", args);
    }
    
    /// Inject model loaded fact
    pub fn injectModelLoaded(self: *MangleQueryEngine, model_name: []const u8) !void {
        var args = try self.allocator.alloc(parser.Term, 1);
        args[0] = .{ .constant = try self.allocator.dupe(u8, model_name) };
        try self.injectFact("model_loaded", args);
    }
    
    /// Inject model parameters fact
    pub fn injectModelParams(self: *MangleQueryEngine, model_name: []const u8, params_billions: f64) !void {
        var args = try self.allocator.alloc(parser.Term, 2);
        args[0] = .{ .constant = try self.allocator.dupe(u8, model_name) };
        args[1] = .{ .number_float = params_billions };
        try self.injectFact("model_params_billions", args);
    }
    
    /// Inject GPU memory usage fact
    pub fn injectGpuMemoryUsed(self: *MangleQueryEngine, device_id: i64, used_mb: i64) !void {
        var args = try self.allocator.alloc(parser.Term, 2);
        args[0] = .{ .number_int = device_id };
        args[1] = .{ .number_int = used_mb };
        try self.injectFact("gpu_memory_used", args);
    }
    
    /// Inject GPU feature fact
    pub fn injectGpuFeature(self: *MangleQueryEngine, device_id: i64, feature: []const u8) !void {
        var args = try self.allocator.alloc(parser.Term, 2);
        args[0] = .{ .number_int = device_id };
        args[1] = .{ .constant = try self.allocator.dupe(u8, feature) };
        try self.injectFact("gpu_has_feature", args);
    }
    
    // ========================================================================
    // Query API
    // ========================================================================
    
    /// Find all facts matching a predicate name (including injected)
    pub fn queryFacts(self: *MangleQueryEngine, name: []const u8) []const parser.Fact {
        var matches = std.ArrayList(parser.Fact){};

        // Check injected facts first
        for (self.injected_facts.items) |fact| {
            if (mem.eql(u8, fact.predicate.name, name)) {
                matches.append(fact) catch continue;
            }
        }
        
        // Check program facts
        if (self.program) |*prog| {
            for (prog.facts.items) |fact| {
                if (mem.eql(u8, fact.predicate.name, name)) {
                    matches.append(fact) catch continue;
                }
            }
        }
        
        return matches.toOwnedSlice() catch &[_]parser.Fact{};
    }
    
    /// Query a fact with specific arg values (simple matching)
    pub fn queryFactWithArgs(
        self: *MangleQueryEngine,
        name: []const u8,
        arg_index: usize,
        expected_value: parser.Term,
    ) ?parser.Fact {
        const facts = self.queryFacts(name);
        defer self.allocator.free(facts);
        
        for (facts) |fact| {
            if (arg_index < fact.predicate.args.len) {
                if (termsMatch(fact.predicate.args[arg_index], expected_value)) {
                    return fact;
                }
            }
        }
        return null;
    }
    
    /// Check if a fact exists
    pub fn hasFact(self: *MangleQueryEngine, name: []const u8) bool {
        const facts = self.queryFacts(name);
        defer self.allocator.free(facts);
        return facts.len > 0;
    }
    
    /// Get a single value from a fact (first match, specific arg position)
    pub fn getFactValue(
        self: *MangleQueryEngine,
        name: []const u8,
        arg_index: usize,
    ) ?parser.Term {
        const facts = self.queryFacts(name);
        defer self.allocator.free(facts);
        
        if (facts.len > 0 and arg_index < facts[0].predicate.args.len) {
            return facts[0].predicate.args[arg_index];
        }
        return null;
    }
    
    /// Get an integer value from a fact
    pub fn getFactInt(self: *MangleQueryEngine, name: []const u8, arg_index: usize) ?i64 {
        if (self.getFactValue(name, arg_index)) |term| {
            switch (term) {
                .number_int => |n| return n,
                else => return null,
            }
        }
        return null;
    }
    
    /// Get a float value from a fact
    pub fn getFactFloat(self: *MangleQueryEngine, name: []const u8, arg_index: usize) ?f64 {
        if (self.getFactValue(name, arg_index)) |term| {
            switch (term) {
                .number_float => |n| return n,
                .number_int => |n| return @as(f64, @floatFromInt(n)),
                else => return null,
            }
        }
        return null;
    }
    
    /// Get a string value from a fact
    pub fn getFactString(self: *MangleQueryEngine, name: []const u8, arg_index: usize) ?[]const u8 {
        if (self.getFactValue(name, arg_index)) |term| {
            switch (term) {
                .constant => |s| return s,
                .variable => |s| return s,
                else => return null,
            }
        }
        return null;
    }
    
    // ========================================================================
    // High-Level Query Helpers
    // ========================================================================
    
    /// Get GPU configuration for a device
    pub fn getGpuConfig(self: *MangleQueryEngine, device_id: i64) ?GpuConfig {
        const expected = parser.Term{ .number_int = device_id };
        const fact = self.queryFactWithArgs("gpu_device", 0, expected) orelse return null;
        
        if (fact.predicate.args.len < 5) return null;
        
        return GpuConfig{
            .device_id = device_id,
            .name = switch (fact.predicate.args[1]) {
                .constant => |s| s,
                else => "unknown",
            },
            .compute_capability = switch (fact.predicate.args[2]) {
                .number_float => |f| f,
                else => 0.0,
            },
            .memory_mb = switch (fact.predicate.args[3]) {
                .number_int => |n| n,
                else => 0,
            },
            .tensor_cores = switch (fact.predicate.args[4]) {
                .number_int => |n| n,
                else => 0,
            },
        };
    }
    
    /// Get all loaded models
    pub fn getLoadedModels(self: *MangleQueryEngine) []const []const u8 {
        const facts = self.queryFacts("model_loaded");
        defer self.allocator.free(facts);
        
        var models = std.ArrayList([]const u8){};
        for (facts) |fact| {
            if (fact.predicate.args.len > 0) {
                switch (fact.predicate.args[0]) {
                    .constant => |s| models.append(s) catch continue,
                    else => {},
                }
            }
        }
        return models.toOwnedSlice() catch &[_][]const u8{};
    }
};

/// GPU configuration from facts
pub const GpuConfig = struct {
    device_id: i64,
    name: []const u8,
    compute_capability: f64,
    memory_mb: i64,
    tensor_cores: i64,
};

// ============================================================================
// Unification Helpers
// ============================================================================

fn termsMatch(a: parser.Term, b: parser.Term) bool {
    // Variables match anything
    if (a == .variable or b == .variable) return true;
    
    // Same type comparison
    return switch (a) {
        .constant => |ac| switch (b) {
            .constant => |bc| mem.eql(u8, ac, bc),
            else => false,
        },
        .number_int => |ai| switch (b) {
            .number_int => |bi| ai == bi,
            else => false,
        },
        .number_float => |af| switch (b) {
            .number_float => |bf| af == bf,
            else => false,
        },
        .variable => true,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "engine init" {
    const allocator = std.testing.allocator;
    var engine = MangleQueryEngine.init(allocator, "mangle");
    defer engine.deinit();
    
    try std.testing.expect(engine.program == null);
}

test "fact injection" {
    const allocator = std.testing.allocator;
    var engine = MangleQueryEngine.init(allocator, "mangle");
    defer engine.deinit();
    
    try engine.injectGpuDevice(0, "T4", 7.5, 16384, 320);
    
    const config = engine.getGpuConfig(0);
    try std.testing.expect(config != null);
    try std.testing.expectEqualStrings("T4", config.?.name);
}