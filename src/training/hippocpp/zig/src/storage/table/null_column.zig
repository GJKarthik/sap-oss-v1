//! Null Column - Null Bitmap Storage
//!
//! Converted from: kuzu/src/storage/table/null_column.cpp
//!
//! Purpose:
//! Stores null information for columns efficiently using bitmaps.
//! One bit per value indicates NULL (1) or non-NULL (0).

const std = @import("std");
const common = @import("common");

const PageIdx = common.PageIdx;

/// Null bitmap for a chunk
pub const NullBitmap = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    num_values: u64,
    num_nulls: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, num_values: u64) !Self {
        const num_bytes = (num_values + 7) / 8;
        const data = try allocator.alloc(u8, num_bytes);
        @memset(data, 0); // All non-null by default
        
        return .{
            .allocator = allocator,
            .data = data,
            .num_values = num_values,
            .num_nulls = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }
    
    /// Set value as NULL
    pub fn setNull(self: *Self, idx: u64) void {
        if (idx >= self.num_values) return;
        
        const byte_idx = idx / 8;
        const bit_idx: u3 = @intCast(idx % 8);
        
        if ((self.data[byte_idx] & (@as(u8, 1) << bit_idx)) == 0) {
            self.data[byte_idx] |= @as(u8, 1) << bit_idx;
            self.num_nulls += 1;
        }
    }
    
    /// Set value as non-NULL
    pub fn setNotNull(self: *Self, idx: u64) void {
        if (idx >= self.num_values) return;
        
        const byte_idx = idx / 8;
        const bit_idx: u3 = @intCast(idx % 8);
        
        if ((self.data[byte_idx] & (@as(u8, 1) << bit_idx)) != 0) {
            self.data[byte_idx] &= ~(@as(u8, 1) << bit_idx);
            self.num_nulls -= 1;
        }
    }
    
    /// Check if value is NULL
    pub fn isNull(self: *const Self, idx: u64) bool {
        if (idx >= self.num_values) return false;
        
        const byte_idx = idx / 8;
        const bit_idx: u3 = @intCast(idx % 8);
        
        return (self.data[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }
    
    /// Get number of nulls
    pub fn getNumNulls(self: *const Self) u64 {
        return self.num_nulls;
    }
    
    /// Check if any nulls exist
    pub fn hasNulls(self: *const Self) bool {
        return self.num_nulls > 0;
    }
    
    /// Check if all values are null
    pub fn allNulls(self: *const Self) bool {
        return self.num_nulls == self.num_values;
    }
    
    /// Get null ratio
    pub fn getNullRatio(self: *const Self) f64 {
        if (self.num_values == 0) return 0;
        return @as(f64, @floatFromInt(self.num_nulls)) / @as(f64, @floatFromInt(self.num_values));
    }
    
    /// Clear all nulls
    pub fn clear(self: *Self) void {
        @memset(self.data, 0);
        self.num_nulls = 0;
    }
    
    /// Copy from another bitmap
    pub fn copyFrom(self: *Self, other: *const NullBitmap, count: u64) void {
        const copy_bytes = @min(self.data.len, other.data.len);
        @memcpy(self.data[0..copy_bytes], other.data[0..copy_bytes]);
        
        // Recount nulls
        self.num_nulls = 0;
        var i: u64 = 0;
        while (i < @min(count, self.num_values)) : (i += 1) {
            if (self.isNull(i)) {
                self.num_nulls += 1;
            }
        }
    }
};

/// Null column chunk
pub const NullColumnChunk = struct {
    allocator: std.mem.Allocator,
    bitmap: NullBitmap,
    page_idx: PageIdx,
    is_dirty: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, num_values: u64) !Self {
        return .{
            .allocator = allocator,
            .bitmap = try NullBitmap.init(allocator, num_values),
            .page_idx = 0,
            .is_dirty = false,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.bitmap.deinit(self.allocator);
    }
    
    pub fn setNull(self: *Self, idx: u64) void {
        self.bitmap.setNull(idx);
        self.is_dirty = true;
    }
    
    pub fn setNotNull(self: *Self, idx: u64) void {
        self.bitmap.setNotNull(idx);
        self.is_dirty = true;
    }
    
    pub fn isNull(self: *const Self, idx: u64) bool {
        return self.bitmap.isNull(idx);
    }
    
    pub fn hasNulls(self: *const Self) bool {
        return self.bitmap.hasNulls();
    }
    
    pub fn getNumNulls(self: *const Self) u64 {
        return self.bitmap.getNumNulls();
    }
};

/// Null column - manages null info for entire column
pub const NullColumn = struct {
    allocator: std.mem.Allocator,
    column_idx: u32,
    chunks: std.ArrayList(NullColumnChunk),
    chunk_capacity: u64,
    
    const Self = @This();
    const DEFAULT_CHUNK_CAPACITY: u64 = 8192;
    
    pub fn init(allocator: std.mem.Allocator, column_idx: u32) Self {
        return .{
            .allocator = allocator,
            .column_idx = column_idx,
            .chunks = .{},
            .chunk_capacity = DEFAULT_CHUNK_CAPACITY,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.chunks.deinit(self.allocator);
    }
    
    /// Add a new chunk
    pub fn addChunk(self: *Self) !*NullColumnChunk {
        const chunk = try NullColumnChunk.init(self.allocator, self.chunk_capacity);
        try self.chunks.append(self.allocator, chunk);
        return &self.chunks.items[self.chunks.items.len - 1];
    }
    
    /// Get chunk by index
    pub fn getChunk(self: *Self, idx: usize) ?*NullColumnChunk {
        if (idx >= self.chunks.items.len) return null;
        return &self.chunks.items[idx];
    }
    
    /// Get total number of nulls across all chunks
    pub fn getTotalNulls(self: *const Self) u64 {
        var total: u64 = 0;
        for (self.chunks.items) |chunk| {
            total += chunk.getNumNulls();
        }
        return total;
    }
    
    /// Check if any chunk has nulls
    pub fn hasAnyNulls(self: *const Self) bool {
        for (self.chunks.items) |chunk| {
            if (chunk.hasNulls()) return true;
        }
        return false;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "null bitmap basic" {
    const allocator = std.testing.allocator;
    
    var bitmap = try NullBitmap.init(allocator, 100);
    defer bitmap.deinit(std.testing.allocator);
    
    try std.testing.expect(!bitmap.hasNulls());
    try std.testing.expect(!bitmap.isNull(0));
    
    bitmap.setNull(5);
    try std.testing.expect(bitmap.isNull(5));
    try std.testing.expect(bitmap.hasNulls());
    try std.testing.expectEqual(@as(u64, 1), bitmap.getNumNulls());
    
    bitmap.setNotNull(5);
    try std.testing.expect(!bitmap.isNull(5));
    try std.testing.expectEqual(@as(u64, 0), bitmap.getNumNulls());
}

test "null bitmap multiple" {
    const allocator = std.testing.allocator;
    
    var bitmap = try NullBitmap.init(allocator, 64);
    defer bitmap.deinit(std.testing.allocator);
    
    bitmap.setNull(0);
    bitmap.setNull(7);
    bitmap.setNull(8);
    bitmap.setNull(63);
    
    try std.testing.expectEqual(@as(u64, 4), bitmap.getNumNulls());
    try std.testing.expect(bitmap.isNull(0));
    try std.testing.expect(bitmap.isNull(7));
    try std.testing.expect(bitmap.isNull(8));
    try std.testing.expect(bitmap.isNull(63));
    try std.testing.expect(!bitmap.isNull(1));
}

test "null column chunk" {
    const allocator = std.testing.allocator;
    
    var chunk = try NullColumnChunk.init(allocator, 100);
    defer chunk.deinit(std.testing.allocator);
    
    chunk.setNull(10);
    chunk.setNull(20);
    
    try std.testing.expect(chunk.isNull(10));
    try std.testing.expect(chunk.isNull(20));
    try std.testing.expect(!chunk.isNull(15));
    try std.testing.expectEqual(@as(u64, 2), chunk.getNumNulls());
}

test "null column" {
    const allocator = std.testing.allocator;
    
    var col = NullColumn.init(allocator, 0);
    defer col.deinit(std.testing.allocator);
    
    const chunk = try col.addChunk();
    chunk.setNull(5);
    
    try std.testing.expectEqual(@as(u64, 1), col.getTotalNulls());
    try std.testing.expect(col.hasAnyNulls());
}