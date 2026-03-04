//! Struct Chunk Data - Nested Struct Column Storage
//!
//! Converted from: kuzu/src/storage/table/struct_chunk_data.cpp
//!
//! Purpose:
//! Stores nested STRUCT type columns. Each struct field becomes
//! a child column chunk with its own data and null bitmap.

const std = @import("std");
const common = @import("../../common/common.zig");

const LogicalType = common.LogicalType;

/// Struct field definition
pub const StructField = struct {
    name: []const u8,
    data_type: LogicalType,
    idx: u32,
    
    pub fn init(name: []const u8, data_type: LogicalType, idx: u32) StructField {
        return .{
            .name = name,
            .data_type = data_type,
            .idx = idx,
        };
    }
};

/// Child chunk data for struct fields
pub const ChildChunkData = struct {
    allocator: std.mem.Allocator,
    field: StructField,
    data: std.ArrayList(u8),
    null_mask: std.ArrayList(bool),
    num_values: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, field: StructField) Self {
        return .{
            .allocator = allocator,
            .field = field,
            .data = std.ArrayList(u8).init(allocator),
            .null_mask = std.ArrayList(bool).init(allocator),
            .num_values = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.data.deinit();
        self.null_mask.deinit();
    }
    
    pub fn appendValue(self: *Self, value: []const u8, is_null: bool) !void {
        try self.data.appendSlice(value);
        try self.null_mask.append(is_null);
        self.num_values += 1;
    }
    
    pub fn getNumValues(self: *const Self) u64 {
        return self.num_values;
    }
    
    pub fn isNull(self: *const Self, idx: u64) bool {
        if (idx >= self.null_mask.items.len) return false;
        return self.null_mask.items[idx];
    }
    
    pub fn clear(self: *Self) void {
        self.data.clearRetainingCapacity();
        self.null_mask.clearRetainingCapacity();
        self.num_values = 0;
    }
};

/// Struct chunk data - stores one chunk of struct values
pub const StructChunkData = struct {
    allocator: std.mem.Allocator,
    field_names: std.ArrayList([]const u8),
    children: std.ArrayList(ChildChunkData),
    struct_null_mask: std.ArrayList(bool),
    num_values: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .field_names = std.ArrayList([]const u8).init(allocator),
            .children = std.ArrayList(ChildChunkData).init(allocator),
            .struct_null_mask = std.ArrayList(bool).init(allocator),
            .num_values = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit();
        self.field_names.deinit();
        self.struct_null_mask.deinit();
    }
    
    /// Add a field to the struct
    pub fn addField(self: *Self, name: []const u8, data_type: LogicalType) !u32 {
        const idx: u32 = @intCast(self.children.items.len);
        const field = StructField.init(name, data_type, idx);
        
        try self.field_names.append(name);
        try self.children.append(ChildChunkData.init(self.allocator, field));
        
        return idx;
    }
    
    /// Get field by name
    pub fn getFieldIdx(self: *const Self, name: []const u8) ?u32 {
        for (self.field_names.items, 0..) |field_name, i| {
            if (std.mem.eql(u8, field_name, name)) {
                return @intCast(i);
            }
        }
        return null;
    }
    
    /// Get child chunk data
    pub fn getChild(self: *Self, idx: u32) ?*ChildChunkData {
        if (idx >= self.children.items.len) return null;
        return &self.children.items[idx];
    }
    
    /// Get number of fields
    pub fn getNumFields(self: *const Self) u32 {
        return @intCast(self.children.items.len);
    }
    
    /// Append a struct value (null mask for entire struct)
    pub fn appendStruct(self: *Self, is_null: bool) !void {
        try self.struct_null_mask.append(is_null);
        self.num_values += 1;
    }
    
    /// Check if struct at index is null
    pub fn isStructNull(self: *const Self, idx: u64) bool {
        if (idx >= self.struct_null_mask.items.len) return false;
        return self.struct_null_mask.items[idx];
    }
    
    /// Get number of struct values
    pub fn getNumValues(self: *const Self) u64 {
        return self.num_values;
    }
    
    /// Clear all data
    pub fn clear(self: *Self) void {
        for (self.children.items) |*child| {
            child.clear();
        }
        self.struct_null_mask.clearRetainingCapacity();
        self.num_values = 0;
    }
};

/// Struct column - full column of struct type
pub const StructColumn = struct {
    allocator: std.mem.Allocator,
    column_idx: u32,
    chunks: std.ArrayList(StructChunkData),
    field_definitions: std.ArrayList(StructField),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, column_idx: u32) Self {
        return .{
            .allocator = allocator,
            .column_idx = column_idx,
            .chunks = std.ArrayList(StructChunkData).init(allocator),
            .field_definitions = std.ArrayList(StructField).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.chunks.deinit();
        self.field_definitions.deinit();
    }
    
    /// Define struct schema
    pub fn defineField(self: *Self, name: []const u8, data_type: LogicalType) !void {
        const idx: u32 = @intCast(self.field_definitions.items.len);
        try self.field_definitions.append(StructField.init(name, data_type, idx));
    }
    
    /// Add a new chunk
    pub fn addChunk(self: *Self) !*StructChunkData {
        var chunk = StructChunkData.init(self.allocator);
        
        // Add all defined fields
        for (self.field_definitions.items) |field| {
            _ = try chunk.addField(field.name, field.data_type);
        }
        
        try self.chunks.append(chunk);
        return &self.chunks.items[self.chunks.items.len - 1];
    }
    
    /// Get chunk by index
    pub fn getChunk(self: *Self, idx: usize) ?*StructChunkData {
        if (idx >= self.chunks.items.len) return null;
        return &self.chunks.items[idx];
    }
    
    /// Get number of chunks
    pub fn getNumChunks(self: *const Self) usize {
        return self.chunks.items.len;
    }
    
    /// Get total number of values
    pub fn getTotalValues(self: *const Self) u64 {
        var total: u64 = 0;
        for (self.chunks.items) |chunk| {
            total += chunk.getNumValues();
        }
        return total;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "child chunk data" {
    const allocator = std.testing.allocator;
    
    const field = StructField.init("name", .STRING, 0);
    var child = ChildChunkData.init(allocator, field);
    defer child.deinit();
    
    try child.appendValue("alice", false);
    try child.appendValue("", true); // null
    
    try std.testing.expectEqual(@as(u64, 2), child.getNumValues());
    try std.testing.expect(!child.isNull(0));
    try std.testing.expect(child.isNull(1));
}

test "struct chunk data" {
    const allocator = std.testing.allocator;
    
    var chunk = StructChunkData.init(allocator);
    defer chunk.deinit();
    
    const name_idx = try chunk.addField("name", .STRING);
    const age_idx = try chunk.addField("age", .INT32);
    
    try std.testing.expectEqual(@as(u32, 0), name_idx);
    try std.testing.expectEqual(@as(u32, 1), age_idx);
    try std.testing.expectEqual(@as(u32, 2), chunk.getNumFields());
    
    try std.testing.expectEqual(@as(u32, 0), chunk.getFieldIdx("name").?);
    try std.testing.expectEqual(@as(u32, 1), chunk.getFieldIdx("age").?);
}

test "struct column" {
    const allocator = std.testing.allocator;
    
    var col = StructColumn.init(allocator, 0);
    defer col.deinit();
    
    try col.defineField("first_name", .STRING);
    try col.defineField("last_name", .STRING);
    
    const chunk = try col.addChunk();
    try chunk.appendStruct(false);
    
    try std.testing.expectEqual(@as(usize, 1), col.getNumChunks());
    try std.testing.expectEqual(@as(u64, 1), chunk.getNumValues());
}