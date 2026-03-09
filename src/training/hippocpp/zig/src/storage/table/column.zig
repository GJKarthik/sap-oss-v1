//! Column Storage - Columnar data storage for tables
//!
//! Purpose:
//! Provides columnar storage with compression, null handling,
//! and efficient vectorized access for database columns.

const std = @import("std");

// ============================================================================
// Column Data Types
// ============================================================================

pub const ColumnDataType = enum {
    BOOL,
    INT8,
    INT16,
    INT32,
    INT64,
    UINT8,
    UINT16,
    UINT32,
    UINT64,
    FLOAT,
    DOUBLE,
    STRING,
    BLOB,
    DATE,
    TIMESTAMP,
    INTERVAL,
    INTERNAL_ID,
    LIST,
    STRUCT,
    
    pub fn byteSize(self: ColumnDataType) usize {
        return switch (self) {
            .BOOL, .INT8, .UINT8 => 1,
            .INT16, .UINT16 => 2,
            .INT32, .UINT32, .FLOAT, .DATE => 4,
            .INT64, .UINT64, .DOUBLE, .TIMESTAMP, .INTERNAL_ID => 8,
            .INTERVAL => 24,
            .STRING, .BLOB, .LIST, .STRUCT => 16,  // offset + length
        };
    }
    
    pub fn isFixedSize(self: ColumnDataType) bool {
        return switch (self) {
            .STRING, .BLOB, .LIST, .STRUCT => false,
            else => true,
        };
    }
};

// ============================================================================
// Column Metadata
// ============================================================================

pub const ColumnMetadata = struct {
    name: []const u8,
    data_type: ColumnDataType,
    nullable: bool,
    column_id: u32,
    table_id: u32,
    default_value: ?[]const u8 = null,
    
    pub fn init(name: []const u8, data_type: ColumnDataType, nullable: bool) ColumnMetadata {
        return .{
            .name = name,
            .data_type = data_type,
            .nullable = nullable,
            .column_id = 0,
            .table_id = 0,
        };
    }
};

// ============================================================================
// Null Bitmap
// ============================================================================

pub const NullBitmap = struct {
    allocator: std.mem.Allocator,
    bits: []u64,
    capacity: usize,
    null_count: usize = 0,
    
    const BITS_PER_WORD: usize = 64;
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !NullBitmap {
        const num_words = (capacity + BITS_PER_WORD - 1) / BITS_PER_WORD;
        const bits = try allocator.alloc(u64, @max(num_words, 1));
        @memset(bits, 0);  // All valid initially
        
        return .{
            .allocator = allocator,
            .bits = bits,
            .capacity = capacity,
        };
    }
    
    pub fn deinit(self: *NullBitmap) void {
        self.allocator.free(self.bits);
    }
    
    pub fn setNull(self: *NullBitmap, idx: usize) void {
        const word_idx = idx / BITS_PER_WORD;
        const bit_idx: u6 = @intCast(idx % BITS_PER_WORD);
        
        if ((self.bits[word_idx] & (@as(u64, 1) << bit_idx)) == 0) {
            self.bits[word_idx] |= @as(u64, 1) << bit_idx;
            self.null_count += 1;
        }
    }
    
    pub fn setValid(self: *NullBitmap, idx: usize) void {
        const word_idx = idx / BITS_PER_WORD;
        const bit_idx: u6 = @intCast(idx % BITS_PER_WORD);
        
        if ((self.bits[word_idx] & (@as(u64, 1) << bit_idx)) != 0) {
            self.bits[word_idx] &= ~(@as(u64, 1) << bit_idx);
            self.null_count -= 1;
        }
    }
    
    pub fn isNull(self: *const NullBitmap, idx: usize) bool {
        const word_idx = idx / BITS_PER_WORD;
        const bit_idx: u6 = @intCast(idx % BITS_PER_WORD);
        return (self.bits[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }
    
    pub fn hasNulls(self: *const NullBitmap) bool {
        return self.null_count > 0;
    }
    
    pub fn reset(self: *NullBitmap) void {
        @memset(self.bits, 0);
        self.null_count = 0;
    }
};

// ============================================================================
// Column Chunk (Fixed-size data segment)
// ============================================================================

pub const ColumnChunk = struct {
    allocator: std.mem.Allocator,
    metadata: ColumnMetadata,
    data: []u8,
    null_bitmap: NullBitmap,
    capacity: usize,
    count: usize = 0,
    
    pub const DEFAULT_CHUNK_SIZE: usize = 2048;
    
    pub fn init(allocator: std.mem.Allocator, metadata: ColumnMetadata, capacity: usize) !ColumnChunk {
        const elem_size = metadata.data_type.byteSize();
        const data = try allocator.alloc(u8, elem_size * capacity);
        @memset(data, 0);
        
        return .{
            .allocator = allocator,
            .metadata = metadata,
            .data = data,
            .null_bitmap = try NullBitmap.init(allocator, capacity),
            .capacity = capacity,
        };
    }
    
    pub fn deinit(self: *ColumnChunk) void {
        self.null_bitmap.deinit();
        self.allocator.free(self.data);
    }
    
    // Value accessors
    pub fn setInt64(self: *ColumnChunk, idx: usize, value: i64) void {
        const offset = idx * 8;
        std.mem.writeInt(i64, self.data[offset..][0..8], value, .little);
        self.null_bitmap.setValid(idx);
        self.count = @max(self.count, idx + 1);
    }
    
    pub fn getInt64(self: *const ColumnChunk, idx: usize) ?i64 {
        if (self.null_bitmap.isNull(idx)) return null;
        const offset = idx * 8;
        return std.mem.readInt(i64, self.data[offset..][0..8], .little);
    }
    
    pub fn setInt32(self: *ColumnChunk, idx: usize, value: i32) void {
        const offset = idx * 4;
        std.mem.writeInt(i32, self.data[offset..][0..4], value, .little);
        self.null_bitmap.setValid(idx);
        self.count = @max(self.count, idx + 1);
    }
    
    pub fn getInt32(self: *const ColumnChunk, idx: usize) ?i32 {
        if (self.null_bitmap.isNull(idx)) return null;
        const offset = idx * 4;
        return std.mem.readInt(i32, self.data[offset..][0..4], .little);
    }
    
    pub fn setDouble(self: *ColumnChunk, idx: usize, value: f64) void {
        const offset = idx * 8;
        @memcpy(self.data[offset..][0..8], std.mem.asBytes(&value));
        self.null_bitmap.setValid(idx);
        self.count = @max(self.count, idx + 1);
    }
    
    pub fn getDouble(self: *const ColumnChunk, idx: usize) ?f64 {
        if (self.null_bitmap.isNull(idx)) return null;
        const offset = idx * 8;
        return std.mem.bytesToValue(f64, self.data[offset..][0..8]);
    }
    
    pub fn setBool(self: *ColumnChunk, idx: usize, value: bool) void {
        self.data[idx] = if (value) 1 else 0;
        self.null_bitmap.setValid(idx);
        self.count = @max(self.count, idx + 1);
    }
    
    pub fn getBool(self: *const ColumnChunk, idx: usize) ?bool {
        if (self.null_bitmap.isNull(idx)) return null;
        return self.data[idx] != 0;
    }
    
    pub fn setNull(self: *ColumnChunk, idx: usize) void {
        self.null_bitmap.setNull(idx);
        self.count = @max(self.count, idx + 1);
    }
    
    pub fn isNull(self: *const ColumnChunk, idx: usize) bool {
        return self.null_bitmap.isNull(idx);
    }
    
    pub fn reset(self: *ColumnChunk) void {
        self.null_bitmap.reset();
        self.count = 0;
    }
    
    pub fn isFull(self: *const ColumnChunk) bool {
        return self.count >= self.capacity;
    }
};

// ============================================================================
// Column (Collection of chunks)
// ============================================================================

pub const Column = struct {
    allocator: std.mem.Allocator,
    metadata: ColumnMetadata,
    chunks: std.ArrayList(ColumnChunk),
    chunk_capacity: usize,
    total_count: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator, metadata: ColumnMetadata, chunk_capacity: usize) Column {
        return .{
            .allocator = allocator,
            .metadata = metadata,
            .chunks = .{},
            .chunk_capacity = chunk_capacity,
        };
    }
    
    pub fn deinit(self: *Column) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.chunks.deinit(self.allocator);
    }
    
    /// Get or create chunk for appending
    pub fn getAppendChunk(self: *Column) !*ColumnChunk {
        if (self.chunks.items.len == 0 or self.chunks.items[self.chunks.items.len - 1].isFull()) {
            const chunk = try ColumnChunk.init(self.allocator, self.metadata, self.chunk_capacity);
            try self.chunks.append(self.allocator, chunk);
        }
        return &self.chunks.items[self.chunks.items.len - 1];
    }
    
    /// Append an int64 value
    pub fn appendInt64(self: *Column, value: i64) !void {
        var chunk = try self.getAppendChunk();
        chunk.setInt64(chunk.count, value);
        self.total_count += 1;
    }
    
    /// Append a null value
    pub fn appendNull(self: *Column) !void {
        var chunk = try self.getAppendChunk();
        chunk.setNull(chunk.count);
        chunk.count += 1;
        self.total_count += 1;
    }
    
    /// Get value at global index
    pub fn getInt64(self: *const Column, idx: usize) ?i64 {
        const chunk_idx = idx / self.chunk_capacity;
        const local_idx = idx % self.chunk_capacity;
        
        if (chunk_idx >= self.chunks.items.len) return null;
        return self.chunks.items[chunk_idx].getInt64(local_idx);
    }
    
    /// Get chunk by index
    pub fn getChunk(self: *Column, idx: usize) ?*ColumnChunk {
        if (idx >= self.chunks.items.len) return null;
        return &self.chunks.items[idx];
    }
    
    pub fn numChunks(self: *const Column) usize {
        return self.chunks.items.len;
    }
};

// ============================================================================
// String Column (Variable-length data)
// ============================================================================

pub const StringColumn = struct {
    allocator: std.mem.Allocator,
    metadata: ColumnMetadata,
    offsets: std.ArrayList(u64),
    data: std.ArrayList(u8),
    null_bitmap: NullBitmap,
    count: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator, metadata: ColumnMetadata) !StringColumn {
        var col = StringColumn{
            .allocator = allocator,
            .metadata = metadata,
            .offsets = .{},
            .data = .{},
            .null_bitmap = try NullBitmap.init(allocator, 1024),
        };
        try col.offsets.append(allocator, 0);
        return col;
    }
    
    pub fn deinit(self: *StringColumn) void {
        self.offsets.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.null_bitmap.deinit();
    }
    
    pub fn append(self: *StringColumn, value: []const u8) !void {
        try self.data.appendSlice(self.allocator, value);
        try self.offsets.append(self.allocator, @intCast(self.data.items.len));
        self.null_bitmap.setValid(self.count);
        self.count += 1;
    }
    
    pub fn appendNull(self: *StringColumn) !void {
        try self.offsets.append(self.allocator, @intCast(self.data.items.len));
        self.null_bitmap.setNull(self.count);
        self.count += 1;
    }
    
    pub fn get(self: *const StringColumn, idx: usize) ?[]const u8 {
        if (idx >= self.count) return null;
        if (self.null_bitmap.isNull(idx)) return null;
        
        const start = self.offsets.items[idx];
        const end = self.offsets.items[idx + 1];
        
        return self.data.items[@intCast(start)..@intCast(end)];
    }
    
    pub fn isNull(self: *const StringColumn, idx: usize) bool {
        return self.null_bitmap.isNull(idx);
    }
};

// ============================================================================
// Column Reader
// ============================================================================

pub const ColumnReader = struct {
    column: *const Column,
    current_chunk: usize = 0,
    current_idx: usize = 0,
    
    pub fn init(column: *const Column) ColumnReader {
        return .{ .column = column };
    }
    
    pub fn nextInt64(self: *ColumnReader) ?i64 {
        while (self.current_chunk < self.column.chunks.items.len) {
            const chunk = &self.column.chunks.items[self.current_chunk];
            if (self.current_idx < chunk.count) {
                const value = chunk.getInt64(self.current_idx);
                self.current_idx += 1;
                return value;
            }
            self.current_chunk += 1;
            self.current_idx = 0;
        }
        return null;
    }
    
    pub fn reset(self: *ColumnReader) void {
        self.current_chunk = 0;
        self.current_idx = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "null bitmap" {
    const allocator = std.testing.allocator;
    
    var bitmap = try NullBitmap.init(allocator, 100);
    defer bitmap.deinit();
    
    try std.testing.expect(!bitmap.hasNulls());
    try std.testing.expect(!bitmap.isNull(0));
    
    bitmap.setNull(5);
    try std.testing.expect(bitmap.hasNulls());
    try std.testing.expect(bitmap.isNull(5));
    try std.testing.expectEqual(@as(usize, 1), bitmap.null_count);
    
    bitmap.setValid(5);
    try std.testing.expect(!bitmap.isNull(5));
    try std.testing.expectEqual(@as(usize, 0), bitmap.null_count);
}

test "column chunk int64" {
    const allocator = std.testing.allocator;
    
    const metadata = ColumnMetadata.init("id", .INT64, false);
    var chunk = try ColumnChunk.init(allocator, metadata, 100);
    defer chunk.deinit();
    
    chunk.setInt64(0, 42);
    chunk.setInt64(1, -100);
    chunk.setNull(2);
    
    try std.testing.expectEqual(@as(?i64, 42), chunk.getInt64(0));
    try std.testing.expectEqual(@as(?i64, -100), chunk.getInt64(1));
    try std.testing.expect(chunk.isNull(2));
    try std.testing.expectEqual(@as(usize, 3), chunk.count);
}

test "column chunk double" {
    const allocator = std.testing.allocator;
    
    const metadata = ColumnMetadata.init("value", .DOUBLE, true);
    var chunk = try ColumnChunk.init(allocator, metadata, 100);
    defer chunk.deinit();
    
    chunk.setDouble(0, 3.14);
    chunk.setDouble(1, -2.5);
    
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), chunk.getDouble(0).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -2.5), chunk.getDouble(1).?, 0.001);
}

test "column append" {
    const allocator = std.testing.allocator;
    
    const metadata = ColumnMetadata.init("id", .INT64, false);
    var column = Column.init(allocator, metadata, 10);
    defer column.deinit();
    
    var i: i64 = 0;
    while (i < 25) : (i += 1) {
        try column.appendInt64(i);
    }
    
    try std.testing.expectEqual(@as(usize, 25), column.total_count);
    try std.testing.expectEqual(@as(usize, 3), column.numChunks());  // 10 + 10 + 5
    
    try std.testing.expectEqual(@as(?i64, 0), column.getInt64(0));
    try std.testing.expectEqual(@as(?i64, 15), column.getInt64(15));
}

test "string column" {
    const allocator = std.testing.allocator;
    
    const metadata = ColumnMetadata.init("name", .STRING, true);
    var col = try StringColumn.init(allocator, metadata);
    defer col.deinit();
    
    try col.append("Alice");
    try col.append("Bob");
    try col.appendNull();
    try col.append("Charlie");
    
    try std.testing.expectEqualStrings("Alice", col.get(0).?);
    try std.testing.expectEqualStrings("Bob", col.get(1).?);
    try std.testing.expect(col.isNull(2));
    try std.testing.expectEqualStrings("Charlie", col.get(3).?);
}

test "column reader" {
    const allocator = std.testing.allocator;
    
    const metadata = ColumnMetadata.init("id", .INT64, false);
    var column = Column.init(allocator, metadata, 5);
    defer column.deinit();
    
    var i: i64 = 0;
    while (i < 12) : (i += 1) {
        try column.appendInt64(i * 10);
    }
    
    var reader = ColumnReader.init(&column);
    var count: usize = 0;
    var sum: i64 = 0;
    
    while (reader.nextInt64()) |val| {
        sum += val;
        count += 1;
    }
    
    try std.testing.expectEqual(@as(usize, 12), count);
    try std.testing.expectEqual(@as(i64, 660), sum);  // 0+10+20+...+110 = 660
}

test "column data type" {
    try std.testing.expectEqual(@as(usize, 8), ColumnDataType.INT64.byteSize());
    try std.testing.expectEqual(@as(usize, 4), ColumnDataType.INT32.byteSize());
    try std.testing.expect(ColumnDataType.INT64.isFixedSize());
    try std.testing.expect(!ColumnDataType.STRING.isFixedSize());
}