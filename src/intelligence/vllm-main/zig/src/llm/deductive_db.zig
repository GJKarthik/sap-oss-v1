//! Deductive Database for LLM Reasoning
//! 
//! Provides rule-based deduction and fact storage for LLM reasoning chains.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A fact in the deductive database
pub const Fact = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    confidence: f32 = 1.0,
    
    pub fn format(self: Fact, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("({s} {s} {s})", .{ self.subject, self.predicate, self.object });
    }
};

/// Rule for deriving new facts
pub const Rule = struct {
    name: []const u8,
    conditions: []const FactPattern,
    conclusion: FactPattern,
    
    pub const FactPattern = struct {
        subject: ?[]const u8,
        predicate: ?[]const u8,
        object: ?[]const u8,
    };
};

/// Deductive database
pub const DeductiveDB = struct {
    allocator: Allocator,
    facts: std.ArrayList(Fact),
    rules: std.ArrayList(Rule),
    
    pub fn init(allocator: Allocator) DeductiveDB {
        return .{
            .allocator = allocator,
            .facts = .{},
            .rules = .{},
        };
    }
    
    pub fn deinit(self: *DeductiveDB) void {
        self.facts.deinit();
        self.rules.deinit();
    }
    
    /// Add a fact to the database
    pub fn addFact(self: *DeductiveDB, fact: Fact) !void {
        try self.facts.append(fact);
    }
    
    /// Add a rule to the database
    pub fn addRule(self: *DeductiveDB, rule: Rule) !void {
        try self.rules.append(rule);
    }
    
    /// Query facts matching a pattern
    pub fn query(self: *const DeductiveDB, pattern: Rule.FactPattern) ![]Fact {
        var matches = std.ArrayList(Fact){};
        defer matches.deinit();
        
        for (self.facts.items) |fact| {
            if (self.matchesPattern(fact, pattern)) {
                try matches.append(fact);
            }
        }
        
        return try matches.toOwnedSlice();
    }
    
    fn matchesPattern(self: *const DeductiveDB, fact: Fact, pattern: Rule.FactPattern) bool {
        _ = self;
        if (pattern.subject) |s| {
            if (!std.mem.eql(u8, fact.subject, s)) return false;
        }
        if (pattern.predicate) |p| {
            if (!std.mem.eql(u8, fact.predicate, p)) return false;
        }
        if (pattern.object) |o| {
            if (!std.mem.eql(u8, fact.object, o)) return false;
        }
        return true;
    }
    
    /// Run inference to derive new facts
    pub fn runInference(self: *DeductiveDB) !usize {
        var new_facts: usize = 0;
        
        for (self.rules.items) |rule| {
            // Simple forward chaining
            if (self.tryApplyRule(rule)) |fact| {
                try self.addFact(fact);
                new_facts += 1;
            }
        }
        
        return new_facts;
    }
    
    fn tryApplyRule(self: *const DeductiveDB, rule: Rule) ?Fact {
        // Very simple rule application - check if all conditions match
        for (rule.conditions) |condition| {
            var found = false;
            for (self.facts.items) |fact| {
                if (self.matchesPattern(fact, condition)) {
                    found = true;
                    break;
                }
            }
            if (!found) return null;
        }
        
        // All conditions matched, create conclusion fact
        return Fact{
            .subject = rule.conclusion.subject orelse "unknown",
            .predicate = rule.conclusion.predicate orelse "derived",
            .object = rule.conclusion.object orelse "value",
            .confidence = 0.9,
        };
    }
    
    /// Get fact count
    pub fn getFactCount(self: *const DeductiveDB) usize {
        return self.facts.items.len;
    }
    
    /// Get rule count
    pub fn getRuleCount(self: *const DeductiveDB) usize {
        return self.rules.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "deductive db basic operations" {
    const allocator = std.testing.allocator;
    var db = DeductiveDB.init(allocator);
    defer db.deinit();
    
    try db.addFact(.{ .subject = "cat", .predicate = "is_a", .object = "animal" });
    try db.addFact(.{ .subject = "dog", .predicate = "is_a", .object = "animal" });
    
    try std.testing.expectEqual(@as(usize, 2), db.getFactCount());
}

test "deductive db query" {
    const allocator = std.testing.allocator;
    var db = DeductiveDB.init(allocator);
    defer db.deinit();
    
    try db.addFact(.{ .subject = "cat", .predicate = "is_a", .object = "animal" });
    try db.addFact(.{ .subject = "dog", .predicate = "is_a", .object = "animal" });
    try db.addFact(.{ .subject = "car", .predicate = "is_a", .object = "vehicle" });
    
    const matches = try db.query(.{ .subject = null, .predicate = "is_a", .object = "animal" });
    defer allocator.free(matches);
    
    try std.testing.expectEqual(@as(usize, 2), matches.len);
}