//! Data Chunk - Vectorized batch data container
//!
//! Purpose:
//! Provides columnar data chunks for vectorized query execution.
//! A DataChunk contains multiple ValueVectors representing columns.

const std = @import("std");

// ============================================================================
// Selection Vector
// ============================================================================

pub const SelectionVector = struct {
    allocator: std.mem.Allocator,
    indices: []u32,
    size: usize,
    owned: bool,
    
    pub const DEFAULT_VECTOR_SIZE: usize = 2048;
    
    pub fn init(allocator: std.mem.Allocator, size: usize) !SelectionVector {
        const indices = try allocator.alloc(u32, size);
        // Initialize to identity mapping
        for (indices, 0..) |*idx, i| {
            idx.* = @intCast(i);
        }
        return .{
            .allocator = allocator,
            .indices = indices,
            .size = size,
            .owned = true,
        };
    }
    
    pub fn deinit(self: *SelectionVector) void {
        if (self.owned) {
            self.allocator.free(self.indices);
        }
    }
    
    pub fn get(self: *const SelectionVector, idx: usize) u32 {
        return self.indices[idx];
    }
    
    pub fn set(self: *SelectionVector, idx: usize, value: u32) void {
        self.indices[idx] = value;
    }
    
    pub fn setAll(self: *SelectionVector, values: []const u32) void {
        const len = @min(values.len, self.indices.len);
        @memcpy(self.indices[0..len], values[0..len]);
        self.size = len;
    }
};

// ============================================================================
// Null Mask
// ============================================================================

pub const NullMask = struct {
    allocator: std.mem.Allocator,
    bits: []u64,
    capacity: usize,
    has_nulls: bool = false,
    
    const BITS_PER_WORD: usize = 64;
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !NullMask {
        const num_words = (capacity + BITS_PER_WORD - 1) / BITS_PER_WORD;
        const bits = try allocator.alloc(u64, num_words);
        @memset(bits, 0);
        return .{
            .allocator = allocator,
            .bits = bits,
            .capacity = capacity,
        };
    }
    
    pub fn deinit(self: *NullMask) void {
        self.allocator.free(self.bits);
    }
    
    pub fn setNull(self: *NullMask, idx: usize) void {
        const word_idx = idx / BITS_PER_WORD;
        const bit_idx: u6 = @intCast(idx % BITS_PER_WORD);
        self.bits[word_idx] |= @as(u64, 1) << bit_idx;
        self.has_nulls = true;
    }
    
    pub fn setValid(self: *NullMask, idx: usize) void {
        const word_idx = idx / BITS_PER_WORD;
        const bit_idx: u6 = @intCast(idx % BITS_PER_WORD);
        self.bits[word_idx] &= ~(@as(u64, 1) << bit_idx);
    }
    
    pub fn isNull(self: *const NullMask, idx: usize) bool {
        const word_idx = idx / BITS_PER_WORD;
        const bit_idx: u6 = @intCast(idx % BITS_PER_WORD);
        return (self.bits[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }
    
    pub fn isValid(self: *const NullMask, idx: usize) bool {
        return !self.isNull(idx);
    }
    
    pub fn reset(self: *NullMask) void {
        @memset(self.bits, 0);
        self.has_nulls = false;
    }
    
    pub fn countNulls(self: *const NullMask, count: usize) usize {
        var nulls: usize = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (self.isNull(i)) nulls += 1;
        }
        return nulls;
    }
};

// ============================================================================
// Value Vector - Single column of values
// ============================================================================

pub const ValueVector = struct {
    allocator: std.mem.Allocator,
    data_type: DataType,
    data: []u8,
    null_mask: NullMask,
    capacity: usize,
    count: usize = 0,
    
    pub const DataType = enum {
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
        LIST,
        STRUCT,
        INTERNAL_ID,
        
        pub fn byteSize(self: DataType) usize {
            return switch (self) {
                .BOOL, .INT8, .UINT8 => 1,
                .INT16, .UINT16 => 2,
                .INT32, .UINT32, .FLOAT => 4,
                .INT64, .UINT64, .DOUBLE, .INTERNAL_ID => 8,
                .STRING => 16,  // pointer + length
                .LIST, .STRUCT => 16,
            };
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, data_type: DataType, capacity: usize) !ValueVector {
        const byte_size = data_type.byteSize() * capacity;
        const data = try allocator.alloc(u8, byte_size);
        @memset(data, 0);
        
        return .{
            .allocator = allocator,
            .data_type = data_type,
            .data = data,
            .null_mask = try NullMask.init(allocator, capacity),
            .capacity = capacity,
        };
    }
    
    pub fn deinit(self: *ValueVector) void {
        self.null_mask.deinit();
        self.allocator.free(self.data);
    }
    
    pub fn setInt64(self: *ValueVector, idx: usize, value: i64) void {
        const offset = idx * 8;
        std.mem.writeInt(i64, self.data[offset..][0..8], value, .little);
        self.null_mask.setValid(idx);
        self.count = @max(self.count, idx + 1);
    }
    
    pub fn getInt64(self: *const ValueVector, idx: usize) ?i64 {
        if (self.null_mask.isNull(idx)) return null;
        const offset = idx * 8;
        return std.mem.readInt(i64, self.data[offset..][0..8], .little);
    }
    
    pub fn setDouble(self: *ValueVector, idx: usize, value: f64) void {
        const offset = idx * 8;
        @memcpy(self.data[offset..][0..8], std.mem.asBytes(&value));
        self.null_mask.setValid(idx);
        self.count = @max(self.count, idx + 1);
    }
    
    pub fn getDouble(self: *const ValueVector, idx: usize) ?f64 {
        if (self.null_mask.isNull(idx)) return null;
        const offset = idx * 8;
        return std.mem.bytesToValue(f64, self.data[offset..][0..8]);
    }
    
    pub fn setBool(self: *ValueVector, idx: usize, value: bool) void {
        self.data[idx] = if (value) 1 else 0;
        self.null_mask.setValid(idx);
        self.count = @max(self.count, idx + 1);
    }
    
    pub fn getBool(self: *const ValueVector, idx: usize) ?bool {
        if (self.null_mask.isNull(idx)) return null;
        return self.data[idx] != 0;
    }
    
    pub fn setNull(self: *ValueVector, idx: usize) void {
        self.null_mask.setNull(idx);
        self.count = @max(self.count, idx + 1);
    }
    
    pub fn isNull(self: *const ValueVector, idx: usize) bool {
        return self.null_mask.isNull(idx);
    }
    
    pub fn reset(self: *ValueVector) void {
        self.null_mask.reset();
        self.count = 0;
    }
    
    pub fn getDataPtr(self: *ValueVector, comptime T: type, idx: usize) *T {
        const offset = idx * @sizeOf(T);
        return @ptrCast(@alignCast(self.data[offset..].ptr));
    }
};

// ============================================================================
// Data Chunk - Collection of ValueVectors
// ============================================================================

pub const DataChunk = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayList(ValueVector),
    selection: ?SelectionVector,
    count: usize = 0,
    capacity: usize,
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) DataChunk {
        return .{
            .allocator = allocator,
            .columns = .{},
            .selection = null,
            .capacity = capacity,
        };
    }
    
    pub fn deinit(self: *DataChunk) void {
        for (self.columns.items) |*col| {
            col.deinit();
        }
        self.columns.deinit(self.allocator);
        if (self.selection) |*sel| {
            sel.deinit();
        }
    }
    
    pub fn addColumn(self: *DataChunk, data_type: ValueVector.DataType) !*ValueVector {
        const vec = try ValueVector.init(self.allocator, data_type, self.capacity);
        try self.columns.append(self.allocator, vec);
        return &self.columns.items[self.columns.items.len - 1];
    }
    
    pub fn getColumn(self: *DataChunk, idx: usize) ?*ValueVector {
        if (idx >= self.columns.items.len) return null;
        return &self.columns.items[idx];
    }
    
    pub fn numColumns(self: *const DataChunk) usize {
        return self.columns.items.len;
    }
    
    pub fn setCount(self: *DataChunk, count: usize) void {
        self.count = count;
        for (self.columns.items) |*col| {
            col.count = count;
        }
    }
    
    pub fn reset(self: *DataChunk) void {
        self.count = 0;
        for (self.columns.items) |*col| {
            col.reset();
        }
        if (self.selection) |*sel| {
            sel.size = 0;
        }
    }
    
    pub fn slice(self: *DataChunk, start: usize, len: usize) !DataChunk {
        var result = DataChunk.init(self.allocator, len);
        errdefer result.deinit();
        
        for (self.columns.items) |*src_col| {
            _ = try result.addColumn(src_col.data_type);
        }
        
        // Copy data for the slice
        for (result.columns.items, 0..) |*dst_col, col_idx| {
            const src_col = &self.columns.items[col_idx];
            const elem_size = src_col.data_type.byteSize();
            
            const src_start = start * elem_size;
            const src_end = (start + len) * elem_size;
            const dst_len = len * elem_size;
            
            if (src_end <= src_col.data.len) {
                @memcpy(dst_col.data[0..dst_len], src_col.data[src_start..src_end]);
            }
            
            // Copy null mask
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (src_col.null_mask.isNull(start + i)) {
                    dst_col.null_mask.setNull(i);
                }
            }
        }
        
        result.count = len;
        return result;
    }
};

// ============================================================================
// Data Chunk Collection
// ============================================================================

pub const DataChunkCollection = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList(DataChunk),
    chunk_capacity: usize,
    total_count: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator, chunk_capacity: usize) DataChunkCollection {
        return .{
            .allocator = allocator,
            .chunks = .{},
            .chunk_capacity = chunk_capacity,
        };
    }
    
    pub fn deinit(self: *DataChunkCollection) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.chunks.deinit(self.allocator);
    }
    
    pub fn append(self: *DataChunkCollection, chunk: DataChunk) !void {
        try self.chunks.append(self.allocator, chunk);
        self.total_count += chunk.count;
    }
    
    pub fn numChunks(self: *const DataChunkCollection) usize {
        return self.chunks.items.len;
    }
    
    pub fn getChunk(self: *DataChunkCollection, idx: usize) ?*DataChunk {
        if (idx >= self.chunks.items.len) return null;
        return &self.chunks.items[idx];
    }
    
    pub fn clear(self: *DataChunkCollection) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.chunks.clearRetainingCapacity();
        self.total_count = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "selection vector" {
    const allocator = std.testing.allocator;
    
    var sel = try SelectionVector.init(allocator, 10);
    defer sel.deinit();
    
    try std.testing.expectEqual(@as(u32, 0), sel.get(0));
    try std.testing.expectEqual(@as(u32, 5), sel.get(5));
    
    sel.set(0, 7);
    try std.testing.expectEqual(@as(u32, 7), sel.get(0));
}

test "null mask" {
    const allocator = std.testing.allocator;
    
    var mask = try NullMask.init(allocator, 100);
    defer mask.deinit();
    
    try std.testing.expect(!mask.has_nulls);
    try std.testing.expect(mask.isValid(0));
    
    mask.setNull(5);
    try std.testing.expect(mask.has_nulls);
    try std.testing.expect(mask.isNull(5));
    try std.testing.expect(mask.isValid(4));
    
    mask.setValid(5);
    try std.testing.expect(mask.isValid(5));
}

test "value vector int64" {
    const allocator = std.testing.allocator;
    
    var vec = try ValueVector.init(allocator, .INT64, 100);
    defer vec.deinit();
    
    vec.setInt64(0, 42);
    vec.setInt64(1, -100);
    vec.setNull(2);
    
    try std.testing.expectEqual(@as(?i64, 42), vec.getInt64(0));
    try std.testing.expectEqual(@as(?i64, -100), vec.getInt64(1));
    try std.testing.expect(vec.isNull(2));
}

test "value vector double" {
    const allocator = std.testing.allocator;
    
    var vec = try ValueVector.init(allocator, .DOUBLE, 100);
    defer vec.deinit();
    
    vec.setDouble(0, 3.14);
    vec.setDouble(1, -2.5);
    
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), vec.getDouble(0).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -2.5), vec.getDouble(1).?, 0.001);
}

test "data chunk" {
    const allocator = std.testing.allocator;
    
    var chunk = DataChunk.init(allocator, 100);
    defer chunk.deinit();
    
    _ = try chunk.addColumn(.INT64);
    _ = try chunk.addColumn(.DOUBLE);

    chunk.getColumn(0).?.setInt64(0, 1);
    chunk.getColumn(0).?.setInt64(1, 2);
    chunk.getColumn(1).?.setDouble(0, 1.5);
    chunk.getColumn(1).?.setDouble(1, 2.5);
    
    chunk.setCount(2);
    
    try std.testing.expectEqual(@as(usize, 2), chunk.numColumns());
    try std.testing.expectEqual(@as(usize, 2), chunk.count);
    try std.testing.expectEqual(@as(?i64, 1), chunk.getColumn(0).?.getInt64(0));
}

test "data chunk collection" {
    const allocator = std.testing.allocator;
    
    var collection = DataChunkCollection.init(allocator, 100);
    defer collection.deinit();
    
    var chunk = DataChunk.init(allocator, 100);
    _ = try chunk.addColumn(.INT64);
    chunk.setCount(50);
    
    try collection.append(chunk);
    
    try std.testing.expectEqual(@as(usize, 1), collection.numChunks());
    try std.testing.expectEqual(@as(usize, 50), collection.total_count);
}