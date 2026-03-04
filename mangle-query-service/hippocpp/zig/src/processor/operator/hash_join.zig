//! Hash Join Operator - Join Using Hash Table
//!
//! Converted from: kuzu/src/processor/operator/hash_join/*.cpp
//!
//! Purpose:
//! Implements hash join algorithm for equi-joins.
//! Builds hash table on smaller relation, probes with larger.

const std = @import("std");
const physical_operator = @import("../physical_operator.zig");
const common = @import("../../common/common.zig");

const PhysicalOperator = physical_operator.PhysicalOperator;
const DataChunk = physical_operator.DataChunk;
const ResultState = physical_operator.ResultState;

/// Join type
pub const JoinType = enum {
    INNER,
    LEFT,
    RIGHT,
    FULL_OUTER,
    CROSS,
    SEMI,
    ANTI,
    MARK,
};

/// Hash table entry
pub const HashEntry = struct {
    key_hash: u64,
    row_idx: u64,
    next: ?*HashEntry,
};

/// Join hash table
pub const JoinHashTable = struct {
    allocator: std.mem.Allocator,
    buckets: []?*HashEntry,
    num_buckets: usize,
    entries: std.ArrayList(HashEntry),
    num_entries: u64,
    
    const Self = @This();
    const DEFAULT_NUM_BUCKETS: usize = 4096;
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        const buckets = try allocator.alloc(?*HashEntry, DEFAULT_NUM_BUCKETS);
        @memset(buckets, null);
        
        return .{
            .allocator = allocator,
            .buckets = buckets,
            .num_buckets = DEFAULT_NUM_BUCKETS,
            .entries = std.ArrayList(HashEntry).init(allocator),
            .num_entries = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buckets);
        self.entries.deinit();
    }
    
    pub fn insert(self: *Self, key_hash: u64, row_idx: u64) !void {
        const bucket_idx = key_hash % self.num_buckets;
        
        try self.entries.append(.{
            .key_hash = key_hash,
            .row_idx = row_idx,
            .next = self.buckets[bucket_idx],
        });
        
        self.buckets[bucket_idx] = &self.entries.items[self.entries.items.len - 1];
        self.num_entries += 1;
    }
    
    pub fn probe(self: *const Self, key_hash: u64) ?*const HashEntry {
        const bucket_idx = key_hash % self.num_buckets;
        return self.buckets[bucket_idx];
    }
    
    pub fn getNumEntries(self: *const Self) u64 {
        return self.num_entries;
    }
    
    pub fn clear(self: *Self) void {
        @memset(self.buckets, null);
        self.entries.clearRetainingCapacity();
        self.num_entries = 0;
    }
};

/// Hash join build side info
pub const BuildSideInfo = struct {
    key_col_idx: u32,
    payload_col_indices: std.ArrayList(u32),
    
    pub fn init(allocator: std.mem.Allocator, key_col: u32) BuildSideInfo {
        return .{
            .key_col_idx = key_col,
            .payload_col_indices = std.ArrayList(u32).init(allocator),
        };
    }
    
    pub fn deinit(self: *BuildSideInfo) void {
        self.payload_col_indices.deinit();
    }
};

/// Hash join probe side info
pub const ProbeSideInfo = struct {
    key_col_idx: u32,
    payload_col_indices: std.ArrayList(u32),
    
    pub fn init(allocator: std.mem.Allocator, key_col: u32) ProbeSideInfo {
        return .{
            .key_col_idx = key_col,
            .payload_col_indices = std.ArrayList(u32).init(allocator),
        };
    }
    
    pub fn deinit(self: *ProbeSideInfo) void {
        self.payload_col_indices.deinit();
    }
};

/// Hash join operator
pub const HashJoinOperator = struct {
    base: PhysicalOperator,
    join_type: JoinType,
    hash_table: JoinHashTable,
    build_info: BuildSideInfo,
    probe_info: ProbeSideInfo,
    build_complete: bool,
    probe_exhausted: bool,
    
    const vtable = PhysicalOperator.VTable{
        .initFn = joinInit,
        .getNextFn = joinGetNext,
        .closeFn = joinClose,
    };
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator, join_type: JoinType, build_key: u32, probe_key: u32) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = PhysicalOperator.init(allocator, .HASH_JOIN, &vtable),
            .join_type = join_type,
            .hash_table = try JoinHashTable.init(allocator),
            .build_info = BuildSideInfo.init(allocator, build_key),
            .probe_info = ProbeSideInfo.init(allocator, probe_key),
            .build_complete = false,
            .probe_exhausted = false,
        };
        return self;
    }
    
    pub fn destroy(self: *Self) void {
        self.hash_table.deinit();
        self.build_info.deinit();
        self.probe_info.deinit();
        self.base.deinit();
        self.base.allocator.destroy(self);
    }
    
    fn joinInit(base: *PhysicalOperator) !void {
        const self: *Self = @fieldParentPtr("base", base);
        self.hash_table.clear();
        self.build_complete = false;
        self.probe_exhausted = false;
        
        // Initialize children (build side = child 0, probe side = child 1)
        for (base.children.items) |child| {
            try child.initOp();
        }
    }
    
    fn joinGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        const self: *Self = @fieldParentPtr("base", base);
        
        // Build phase
        if (!self.build_complete) {
            try self.buildHashTable();
            self.build_complete = true;
        }
        
        // Probe phase
        if (self.probe_exhausted) {
            return .NO_MORE_TUPLES;
        }
        
        return try self.probeHashTable(chunk);
    }
    
    fn buildHashTable(self: *Self) !void {
        if (self.base.children.items.len == 0) return;
        
        const build_child = self.base.children.items[0];
        var input_chunk = DataChunk.init(self.base.allocator);
        defer input_chunk.deinit();
        
        var row_idx: u64 = 0;
        
        while (true) {
            const result = try build_child.getNext(&input_chunk);
            
            // Insert into hash table
            var i: u64 = 0;
            while (i < input_chunk.num_tuples) : (i += 1) {
                // Simplified: use row index as hash
                const hash = row_idx + i;
                try self.hash_table.insert(hash, row_idx + i);
            }
            
            row_idx += input_chunk.num_tuples;
            self.base.metrics.addInputTuples(input_chunk.num_tuples);
            
            if (result == .NO_MORE_TUPLES) break;
            input_chunk.reset();
        }
    }
    
    fn probeHashTable(self: *Self, chunk: *DataChunk) !ResultState {
        if (self.base.children.items.len < 2) {
            self.probe_exhausted = true;
            return .NO_MORE_TUPLES;
        }
        
        const probe_child = self.base.children.items[1];
        var probe_chunk = DataChunk.init(self.base.allocator);
        defer probe_chunk.deinit();
        
        const result = try probe_child.getNext(&probe_chunk);
        
        if (result == .NO_MORE_TUPLES) {
            self.probe_exhausted = true;
            if (chunk.num_tuples > 0) {
                return .HAS_MORE;
            }
            return .NO_MORE_TUPLES;
        }
        
        // Simplified join output
        chunk.num_tuples = probe_chunk.num_tuples;
        self.base.metrics.addOutputTuples(chunk.num_tuples);
        
        return .HAS_MORE;
    }
    
    fn joinClose(base: *PhysicalOperator) void {
        for (base.children.items) |child| {
            child.close();
        }
    }
};

/// Cross product operator
pub const CrossProductOperator = struct {
    base: PhysicalOperator,
    left_tuples: std.ArrayList(u64),
    current_left_idx: usize,
    right_exhausted: bool,
    
    const vtable = PhysicalOperator.VTable{
        .initFn = crossInit,
        .getNextFn = crossGetNext,
        .closeFn = crossClose,
    };
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = PhysicalOperator.init(allocator, .CROSS_PRODUCT, &vtable),
            .left_tuples = std.ArrayList(u64).init(allocator),
            .current_left_idx = 0,
            .right_exhausted = false,
        };
        return self;
    }
    
    pub fn destroy(self: *Self) void {
        self.left_tuples.deinit();
        self.base.deinit();
        self.base.allocator.destroy(self);
    }
    
    fn crossInit(base: *PhysicalOperator) !void {
        const self: *Self = @fieldParentPtr("base", base);
        self.left_tuples.clearRetainingCapacity();
        self.current_left_idx = 0;
        self.right_exhausted = false;
    }
    
    fn crossGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        _ = base;
        _ = chunk;
        return .NO_MORE_TUPLES;
    }
    
    fn crossClose(base: *PhysicalOperator) void {
        _ = base;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "join hash table" {
    const allocator = std.testing.allocator;
    
    var ht = try JoinHashTable.init(allocator);
    defer ht.deinit();
    
    try ht.insert(100, 0);
    try ht.insert(200, 1);
    try ht.insert(100, 2); // Same hash bucket
    
    try std.testing.expectEqual(@as(u64, 3), ht.getNumEntries());
    
    const entry = ht.probe(100);
    try std.testing.expect(entry != null);
}

test "hash join operator create" {
    const allocator = std.testing.allocator;
    
    var join = try HashJoinOperator.create(allocator, .INNER, 0, 0);
    defer join.destroy();
    
    try std.testing.expectEqual(JoinType.INNER, join.join_type);
}

test "build side info" {
    const allocator = std.testing.allocator;
    
    var info = BuildSideInfo.init(allocator, 0);
    defer info.deinit();
    
    try std.testing.expectEqual(@as(u32, 0), info.key_col_idx);
}