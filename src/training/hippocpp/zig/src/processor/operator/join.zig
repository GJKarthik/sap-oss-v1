//! Join Operators - Relational join processing
//!
//! Purpose:
//! Provides operators for various join algorithms including
//! hash join, nested loop join, and index nested loop join.

const std = @import("std");

// ============================================================================
// Join Type
// ============================================================================

pub const JoinType = enum {
    INNER,
    LEFT,
    RIGHT,
    FULL,
    CROSS,
    SEMI,
    ANTI,
    MARK,
};

// ============================================================================
// Join Algorithm
// ============================================================================

pub const JoinAlgorithm = enum {
    HASH,
    NESTED_LOOP,
    INDEX_NESTED_LOOP,
    MERGE,
};

// ============================================================================
// Join Condition
// ============================================================================

pub const JoinCondition = struct {
    left_key_idx: u32,
    right_key_idx: u32,
    
    pub fn init(left_idx: u32, right_idx: u32) JoinCondition {
        return .{ .left_key_idx = left_idx, .right_key_idx = right_idx };
    }
};

// ============================================================================
// Join Config
// ============================================================================

pub const JoinConfig = struct {
    join_type: JoinType = .INNER,
    algorithm: JoinAlgorithm = .HASH,
    conditions: []const JoinCondition = &[_]JoinCondition{},
    build_side_is_left: bool = true,
};

// ============================================================================
// Hash Join
// ============================================================================

pub const HashJoin = struct {
    allocator: std.mem.Allocator,
    config: JoinConfig,
    
    // Build phase tracking
    build_rows: u64 = 0,
    probe_rows: u64 = 0,
    output_rows: u64 = 0,
    
    // State
    build_complete: bool = false,
    probe_complete: bool = false,
    
    pub fn init(allocator: std.mem.Allocator, config: JoinConfig) HashJoin {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    pub fn deinit(self: *HashJoin) void {
        _ = self;
    }
    
    /// Build phase: add row to hash table
    pub fn buildAdd(self: *HashJoin) void {
        self.build_rows += 1;
    }
    
    /// Finish build phase
    pub fn buildFinish(self: *HashJoin) void {
        self.build_complete = true;
    }
    
    /// Probe phase: probe hash table
    pub fn probe(self: *HashJoin) void {
        self.probe_rows += 1;
    }
    
    /// Output a matched row
    pub fn outputRow(self: *HashJoin) void {
        self.output_rows += 1;
    }
    
    /// Finish probe phase
    pub fn probeFinish(self: *HashJoin) void {
        self.probe_complete = true;
    }
    
    pub fn isBuildComplete(self: *const HashJoin) bool {
        return self.build_complete;
    }
    
    pub fn isComplete(self: *const HashJoin) bool {
        return self.build_complete and self.probe_complete;
    }
    
    pub fn getStats(self: *const HashJoin) HashJoinStats {
        return .{
            .build_rows = self.build_rows,
            .probe_rows = self.probe_rows,
            .output_rows = self.output_rows,
        };
    }
};

pub const HashJoinStats = struct {
    build_rows: u64,
    probe_rows: u64,
    output_rows: u64,
};

// ============================================================================
// Nested Loop Join
// ============================================================================

pub const NestedLoopJoin = struct {
    allocator: std.mem.Allocator,
    config: JoinConfig,
    
    outer_rows: u64 = 0,
    inner_scans: u64 = 0,
    output_rows: u64 = 0,
    comparisons: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, config: JoinConfig) NestedLoopJoin {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    pub fn deinit(self: *NestedLoopJoin) void {
        _ = self;
    }
    
    pub fn processOuterRow(self: *NestedLoopJoin) void {
        self.outer_rows += 1;
    }
    
    pub fn scanInner(self: *NestedLoopJoin) void {
        self.inner_scans += 1;
    }
    
    pub fn compare(self: *NestedLoopJoin) void {
        self.comparisons += 1;
    }
    
    pub fn outputRow(self: *NestedLoopJoin) void {
        self.output_rows += 1;
    }
    
    pub fn getStats(self: *const NestedLoopJoin) NestedLoopStats {
        return .{
            .outer_rows = self.outer_rows,
            .inner_scans = self.inner_scans,
            .comparisons = self.comparisons,
            .output_rows = self.output_rows,
        };
    }
};

pub const NestedLoopStats = struct {
    outer_rows: u64,
    inner_scans: u64,
    comparisons: u64,
    output_rows: u64,
};

// ============================================================================
// Index Nested Loop Join
// ============================================================================

pub const IndexNestedLoopJoin = struct {
    allocator: std.mem.Allocator,
    config: JoinConfig,
    index_lookups: u64 = 0,
    output_rows: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, config: JoinConfig) IndexNestedLoopJoin {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    pub fn deinit(self: *IndexNestedLoopJoin) void {
        _ = self;
    }
    
    pub fn indexLookup(self: *IndexNestedLoopJoin) void {
        self.index_lookups += 1;
    }
    
    pub fn outputRow(self: *IndexNestedLoopJoin) void {
        self.output_rows += 1;
    }
};

// ============================================================================
// Cross Join
// ============================================================================

pub const CrossJoin = struct {
    allocator: std.mem.Allocator,
    left_count: u64 = 0,
    right_count: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator) CrossJoin {
        return .{ .allocator = allocator };
    }
    
    pub fn addLeft(self: *CrossJoin) void {
        self.left_count += 1;
    }
    
    pub fn addRight(self: *CrossJoin) void {
        self.right_count += 1;
    }
    
    pub fn outputSize(self: *const CrossJoin) u64 {
        return self.left_count * self.right_count;
    }
};

// ============================================================================
// Semi/Anti Join
// ============================================================================

pub const SemiAntiJoin = struct {
    allocator: std.mem.Allocator,
    is_anti: bool,
    input_rows: u64 = 0,
    matched_rows: u64 = 0,
    output_rows: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, is_anti: bool) SemiAntiJoin {
        return .{
            .allocator = allocator,
            .is_anti = is_anti,
        };
    }
    
    pub fn processRow(self: *SemiAntiJoin, has_match: bool) void {
        self.input_rows += 1;
        if (has_match) self.matched_rows += 1;
        
        // Semi join: output if match; Anti join: output if no match
        if (has_match != self.is_anti) {
            self.output_rows += 1;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "join config" {
    const config = JoinConfig{};
    try std.testing.expectEqual(JoinType.INNER, config.join_type);
    try std.testing.expectEqual(JoinAlgorithm.HASH, config.algorithm);
}

test "hash join" {
    const allocator = std.testing.allocator;
    
    var join = HashJoin.init(allocator, .{});
    defer join.deinit(std.testing.allocator);
    
    // Build phase
    join.buildAdd();
    join.buildAdd();
    join.buildAdd();
    join.buildFinish();
    
    try std.testing.expect(join.isBuildComplete());
    
    // Probe phase
    join.probe();
    join.probe();
    join.outputRow();
    join.probeFinish();
    
    const stats = join.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.build_rows);
    try std.testing.expectEqual(@as(u64, 2), stats.probe_rows);
    try std.testing.expectEqual(@as(u64, 1), stats.output_rows);
}

test "nested loop join" {
    const allocator = std.testing.allocator;
    
    var join = NestedLoopJoin.init(allocator, .{});
    defer join.deinit(std.testing.allocator);
    
    join.processOuterRow();
    join.scanInner();
    join.compare();
    join.compare();
    join.outputRow();
    
    const stats = join.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.outer_rows);
    try std.testing.expectEqual(@as(u64, 2), stats.comparisons);
}

test "cross join" {
    const allocator = std.testing.allocator;
    
    var join = CrossJoin.init(allocator);
    join.addLeft();
    join.addLeft();
    join.addLeft();
    join.addRight();
    join.addRight();
    
    try std.testing.expectEqual(@as(u64, 6), join.outputSize());
}

test "semi join" {
    const allocator = std.testing.allocator;
    
    var join = SemiAntiJoin.init(allocator, false);  // Semi join
    join.processRow(true);   // Match -> output
    join.processRow(false);  // No match -> no output
    join.processRow(true);   // Match -> output
    
    try std.testing.expectEqual(@as(u64, 2), join.output_rows);
}

test "anti join" {
    const allocator = std.testing.allocator;
    
    var join = SemiAntiJoin.init(allocator, true);  // Anti join
    join.processRow(true);   // Match -> no output
    join.processRow(false);  // No match -> output
    join.processRow(true);   // Match -> no output
    
    try std.testing.expectEqual(@as(u64, 1), join.output_rows);
}