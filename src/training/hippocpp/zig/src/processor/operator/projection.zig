//! Projection Operators - Column selection and transformation
//!
//! Purpose:
//! Provides operators for selecting columns, computing expressions,
//! and transforming result tuples.

const std = @import("std");

// ============================================================================
// Projection Type
// ============================================================================

pub const ProjectionType = enum {
    COLUMN_REF,     // Reference to existing column
    CONSTANT,       // Constant value
    EXPRESSION,     // Computed expression
    ALIAS,          // Column with alias
};

// ============================================================================
// Projection Item
// ============================================================================

pub const ProjectionItem = struct {
    projection_type: ProjectionType,
    source_column: ?u32 = null,
    alias: ?[]const u8 = null,
    constant_value: ?i64 = null,
    
    pub fn columnRef(column_idx: u32) ProjectionItem {
        return .{
            .projection_type = .COLUMN_REF,
            .source_column = column_idx,
        };
    }
    
    pub fn constant(value: i64) ProjectionItem {
        return .{
            .projection_type = .CONSTANT,
            .constant_value = value,
        };
    }
    
    pub fn aliased(column_idx: u32, name: []const u8) ProjectionItem {
        return .{
            .projection_type = .ALIAS,
            .source_column = column_idx,
            .alias = name,
        };
    }
};

// ============================================================================
// Projection Operator
// ============================================================================

pub const ProjectionOperator = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ProjectionItem),
    
    // Statistics
    rows_processed: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator) ProjectionOperator {
        return .{
            .allocator = allocator,
            .items = .{},
        };
    }
    
    pub fn deinit(self: *ProjectionOperator) void {
        self.items.deinit(self.allocator);
    }
    
    pub fn addColumn(self: *ProjectionOperator, column_idx: u32) !void {
        try self.items.append(self.allocator, ProjectionItem.columnRef(column_idx);
    }
    
    pub fn addConstant(self: *ProjectionOperator, value: i64) !void {
        try self.items.append(self.allocator, ProjectionItem.constant(value);
    }
    
    pub fn addAlias(self: *ProjectionOperator, column_idx: u32, name: []const u8) !void {
        try self.items.append(self.allocator, ProjectionItem.aliased(column_idx, name);
    }
    
    pub fn addItem(self: *ProjectionOperator, item: ProjectionItem) !void {
        try self.items.append(self.allocator, item);
    }
    
    /// Project a row, returning selected/computed values
    pub fn project(self: *ProjectionOperator, input: []const i64) ![]i64 {
        self.rows_processed += 1;
        
        const output = try self.allocator.alloc(i64, self.items.items.len);
        
        for (self.items.items, 0..) |item, i| {
            output[i] = switch (item.projection_type) {
                .COLUMN_REF, .ALIAS => blk: {
                    if (item.source_column) |col| {
                        if (col < input.len) break :blk input[col];
                    }
                    break :blk 0;
                },
                .CONSTANT => item.constant_value orelse 0,
                .EXPRESSION => 0,  // Would evaluate expression
            };
        }
        
        return output;
    }
    
    pub fn getOutputWidth(self: *const ProjectionOperator) usize {
        return self.items.items.len;
    }
    
    pub fn getStats(self: *const ProjectionOperator) ProjectionStats {
        return .{
            .rows_processed = self.rows_processed,
            .output_columns = self.items.items.len,
        };
    }
};

pub const ProjectionStats = struct {
    rows_processed: u64,
    output_columns: usize,
};

// ============================================================================
// Star Projection (SELECT *)
// ============================================================================

pub const StarProjection = struct {
    allocator: std.mem.Allocator,
    num_columns: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator, num_columns: usize) StarProjection {
        return .{
            .allocator = allocator,
            .num_columns = num_columns,
        };
    }
    
    pub fn project(self: *StarProjection, input: []const i64) ![]i64 {
        const output = try self.allocator.alloc(i64, self.num_columns);
        const copy_len = @min(input.len, self.num_columns);
        @memcpy(output[0..copy_len], input[0..copy_len]);
        return output;
    }
};

// ============================================================================
// Distinct Projection
// ============================================================================

pub const DistinctProjection = struct {
    allocator: std.mem.Allocator,
    seen_hashes: std.AutoHashMap(u64, void),
    rows_input: u64 = 0,
    rows_output: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator) DistinctProjection {
        return .{
            .allocator = allocator,
            .seen_hashes = .{},
        };
    }
    
    pub fn deinit(self: *DistinctProjection) void {
        self.seen_hashes.deinit(self.allocator);
    }
    
    /// Returns true if row is unique (not seen before)
    pub fn isDistinct(self: *DistinctProjection, row: []const i64) !bool {
        self.rows_input += 1;
        
        // Compute hash of row
        var hash: u64 = 0;
        for (row) |v| {
            hash = hash *% 31 +% @as(u64, @bitCast(v));
        }
        
        if (self.seen_hashes.contains(hash)) {
            return false;
        }
        
        try self.seen_hashes.put(hash, {});
        self.rows_output += 1;
        return true;
    }
    
    pub fn getDistinctCount(self: *const DistinctProjection) usize {
        return self.seen_hashes.count();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "projection item column ref" {
    const item = ProjectionItem.columnRef(5);
    try std.testing.expectEqual(ProjectionType.COLUMN_REF, item.projection_type);
    try std.testing.expectEqual(@as(u32, 5), item.source_column.?);
}

test "projection item constant" {
    const item = ProjectionItem.constant(42);
    try std.testing.expectEqual(ProjectionType.CONSTANT, item.projection_type);
    try std.testing.expectEqual(@as(i64, 42), item.constant_value.?);
}

test "projection operator" {
    const allocator = std.testing.allocator;
    
    var proj = ProjectionOperator.init(allocator);
    defer proj.deinit(std.testing.allocator);
    
    try proj.addColumn(0);
    try proj.addColumn(2);
    try proj.addConstant(100);
    
    const input = [_]i64{ 10, 20, 30, 40 };
    const output = try proj.project(&input);
    defer allocator.free(output);
    
    try std.testing.expectEqual(@as(usize, 3), output.len);
    try std.testing.expectEqual(@as(i64, 10), output[0]);
    try std.testing.expectEqual(@as(i64, 30), output[1]);
    try std.testing.expectEqual(@as(i64, 100), output[2]);
}

test "star projection" {
    const allocator = std.testing.allocator;
    
    var proj = StarProjection.init(allocator, 3);
    const input = [_]i64{ 1, 2, 3 };
    const output = try proj.project(&input);
    defer allocator.free(output);
    
    try std.testing.expectEqual(@as(usize, 3), output.len);
    try std.testing.expectEqual(@as(i64, 1), output[0]);
}

test "distinct projection" {
    const allocator = std.testing.allocator;
    
    var proj = DistinctProjection.init(allocator);
    defer proj.deinit(std.testing.allocator);
    
    try std.testing.expect(try proj.isDistinct(&[_]i64{ 1, 2 }));
    try std.testing.expect(try proj.isDistinct(&[_]i64{ 3, 4 }));
    try std.testing.expect(!try proj.isDistinct(&[_]i64{ 1, 2 }));  // Duplicate
    
    try std.testing.expectEqual(@as(usize, 2), proj.getDistinctCount());
}