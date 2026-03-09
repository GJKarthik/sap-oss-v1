//! Arrow Array Interface - Apache Arrow integration
//!
//! Purpose:
//! Provides Arrow-compatible array types for zero-copy data exchange
//! with external systems (Python, R, etc.)

const std = @import("std");

// ============================================================================
// Arrow Data Types
// ============================================================================

pub const ArrowType = enum(u8) {
    NA = 0,
    BOOL = 1,
    UINT8 = 2,
    INT8 = 3,
    UINT16 = 4,
    INT16 = 5,
    UINT32 = 6,
    INT32 = 7,
    UINT64 = 8,
    INT64 = 9,
    HALF_FLOAT = 10,
    FLOAT = 11,
    DOUBLE = 12,
    STRING = 13,
    BINARY = 14,
    FIXED_SIZE_BINARY = 15,
    DATE32 = 16,
    DATE64 = 17,
    TIMESTAMP = 18,
    TIME32 = 19,
    TIME64 = 20,
    INTERVAL_MONTHS = 21,
    INTERVAL_DAY_TIME = 22,
    DECIMAL128 = 23,
    DECIMAL256 = 24,
    LIST = 25,
    STRUCT = 26,
    SPARSE_UNION = 27,
    DENSE_UNION = 28,
    DICTIONARY = 29,
    MAP = 30,
    EXTENSION = 31,
    FIXED_SIZE_LIST = 32,
    DURATION = 33,
    LARGE_STRING = 34,
    LARGE_BINARY = 35,
    LARGE_LIST = 36,
    
    pub fn byteWidth(self: ArrowType) ?usize {
        return switch (self) {
            .BOOL => 1,
            .INT8, .UINT8 => 1,
            .INT16, .UINT16, .HALF_FLOAT => 2,
            .INT32, .UINT32, .FLOAT, .DATE32, .TIME32 => 4,
            .INT64, .UINT64, .DOUBLE, .DATE64, .TIME64, .TIMESTAMP, .DURATION => 8,
            .DECIMAL128 => 16,
            .DECIMAL256 => 32,
            else => null,
        };
    }
};

// ============================================================================
// Arrow Buffer
// ============================================================================

pub const ArrowBuffer = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    capacity: usize,
    size: usize,
    
    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) !ArrowBuffer {
        const capacity = @max(initial_capacity, 64);
        const data = try allocator.alloc(u8, capacity);
        @memset(data, 0);
        
        return .{
            .allocator = allocator,
            .data = data,
            .capacity = capacity,
            .size = 0,
        };
    }
    
    pub fn deinit(self: *ArrowBuffer) void {
        self.allocator.free(self.data);
    }
    
    pub fn reserve(self: *ArrowBuffer, additional: usize) !void {
        const required = self.size + additional;
        if (required > self.capacity) {
            const new_cap = @max(self.capacity * 2, required);
            const new_data = try self.allocator.realloc(self.data, new_cap);
            self.data = new_data;
            self.capacity = new_cap;
        }
    }
    
    pub fn append(self: *ArrowBuffer, bytes: []const u8) !void {
        try self.reserve(bytes.len);
        @memcpy(self.data[self.size..][0..bytes.len], bytes);
        self.size += bytes.len;
    }
    
    pub fn appendValue(self: *ArrowBuffer, comptime T: type, value: T) !void {
        try self.append(std.mem.asBytes(&value));
    }
    
    pub fn getSlice(self: *const ArrowBuffer) []const u8 {
        return self.data[0..self.size];
    }
};

// ============================================================================
// Arrow Validity Bitmap
// ============================================================================

pub const ValidityBitmap = struct {
    allocator: std.mem.Allocator,
    bits: std.ArrayList(u8),
    null_count: usize = 0,
    length: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator) ValidityBitmap {
        return .{
            .allocator = allocator,
            .bits = .{},
        };
    }
    
    pub fn deinit(self: *ValidityBitmap) void {
        self.bits.deinit(self.allocator);
    }
    
    pub fn appendValid(self: *ValidityBitmap) !void {
        try self.appendBit(true);
    }
    
    pub fn appendNull(self: *ValidityBitmap) !void {
        try self.appendBit(false);
        self.null_count += 1;
    }
    
    fn appendBit(self: *ValidityBitmap, valid: bool) !void {
        const byte_idx = self.length / 8;
        const bit_idx: u3 = @intCast(self.length % 8);
        
        if (byte_idx >= self.bits.items.len) {
            try self.bits.append(self.allocator, 0);
        }
        
        if (valid) {
            self.bits.items[byte_idx] |= @as(u8, 1) << bit_idx;
        }
        
        self.length += 1;
    }
    
    pub fn isValid(self: *const ValidityBitmap, index: usize) bool {
        if (index >= self.length) return false;
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(index % 8);
        return (self.bits.items[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }
    
    pub fn hasNulls(self: *const ValidityBitmap) bool {
        return self.null_count > 0;
    }
};

// ============================================================================
// Arrow Array
// ============================================================================

pub const ArrowArray = struct {
    allocator: std.mem.Allocator,
    arrow_type: ArrowType,
    length: usize,
    null_count: usize,
    
    // Buffers
    validity: ValidityBitmap,
    data_buffer: ArrowBuffer,
    offsets_buffer: ?ArrowBuffer,
    
    pub fn init(allocator: std.mem.Allocator, arrow_type: ArrowType) !ArrowArray {
        return .{
            .allocator = allocator,
            .arrow_type = arrow_type,
            .length = 0,
            .null_count = 0,
            .validity = ValidityBitmap.init(allocator),
            .data_buffer = try ArrowBuffer.init(allocator, 1024),
            .offsets_buffer = if (arrow_type == .STRING or arrow_type == .BINARY or arrow_type == .LIST)
                try ArrowBuffer.init(allocator, 256)
            else
                null,
        };
    }
    
    pub fn deinit(self: *ArrowArray) void {
        self.validity.deinit();
        self.data_buffer.deinit();
        if (self.offsets_buffer) |*buf| {
            buf.deinit();
        }
    }
    
    pub fn appendInt64(self: *ArrowArray, value: i64) !void {
        try self.validity.appendValid();
        try self.data_buffer.appendValue(i64, value);
        self.length += 1;
    }
    
    pub fn appendInt32(self: *ArrowArray, value: i32) !void {
        try self.validity.appendValid();
        try self.data_buffer.appendValue(i32, value);
        self.length += 1;
    }
    
    pub fn appendFloat64(self: *ArrowArray, value: f64) !void {
        try self.validity.appendValid();
        try self.data_buffer.appendValue(f64, value);
        self.length += 1;
    }
    
    pub fn appendString(self: *ArrowArray, value: []const u8) !void {
        var offsets = &(self.offsets_buffer orelse return error.InvalidArrayType);
        
        // Write current offset
        const offset: i32 = @intCast(self.data_buffer.size);
        try offsets.appendValue(i32, offset);
        
        // Write string data
        try self.data_buffer.append(value);
        
        try self.validity.appendValid();
        self.length += 1;
    }
    
    pub fn appendNull(self: *ArrowArray) !void {
        try self.validity.appendNull();
        
        // Append zero bytes for the value
        if (self.arrow_type.byteWidth()) |width| {
            var i: usize = 0;
            while (i < width) : (i += 1) {
                try self.data_buffer.append(&[_]u8{0});
            }
        }
        
        self.null_count += 1;
        self.length += 1;
    }
    
    pub fn getInt64(self: *const ArrowArray, index: usize) ?i64 {
        if (index >= self.length) return null;
        if (!self.validity.isValid(index)) return null;
        
        const offset = index * 8;
        if (offset + 8 > self.data_buffer.size) return null;
        
        return std.mem.bytesToValue(i64, self.data_buffer.data[offset..][0..8]);
    }
    
    pub fn getFloat64(self: *const ArrowArray, index: usize) ?f64 {
        if (index >= self.length) return null;
        if (!self.validity.isValid(index)) return null;
        
        const offset = index * 8;
        if (offset + 8 > self.data_buffer.size) return null;
        
        return std.mem.bytesToValue(f64, self.data_buffer.data[offset..][0..8]);
    }
    
    pub fn isNull(self: *const ArrowArray, index: usize) bool {
        return !self.validity.isValid(index);
    }
};

// ============================================================================
// Arrow Record Batch
// ============================================================================

pub const RecordBatch = struct {
    allocator: std.mem.Allocator,
    schema: Schema,
    columns: std.ArrayList(ArrowArray),
    num_rows: usize,
    
    pub fn init(allocator: std.mem.Allocator, schema: Schema) RecordBatch {
        return .{
            .allocator = allocator,
            .schema = schema,
            .columns = .{},
            .num_rows = 0,
        };
    }
    
    pub fn deinit(self: *RecordBatch) void {
        for (self.columns.items) |*col| {
            col.deinit();
        }
        self.columns.deinit(self.allocator);
        self.schema.deinit();
    }
    
    pub fn addColumn(self: *RecordBatch, column: ArrowArray) !void {
        if (self.columns.items.len > 0 and column.length != self.num_rows) {
            return error.ColumnLengthMismatch;
        }
        try self.columns.append(self.allocator, column);
        if (self.num_rows == 0) {
            self.num_rows = column.length;
        }
    }
    
    pub fn getColumn(self: *RecordBatch, index: usize) ?*ArrowArray {
        if (index >= self.columns.items.len) return null;
        return &self.columns.items[index];
    }
    
    pub fn numColumns(self: *const RecordBatch) usize {
        return self.columns.items.len;
    }
};

// ============================================================================
// Arrow Schema
// ============================================================================

pub const Field = struct {
    name: []const u8,
    arrow_type: ArrowType,
    nullable: bool,
};

pub const Schema = struct {
    allocator: std.mem.Allocator,
    fields: std.ArrayList(Field),
    
    pub fn init(allocator: std.mem.Allocator) Schema {
        return .{
            .allocator = allocator,
            .fields = .{},
        };
    }
    
    pub fn deinit(self: *Schema) void {
        self.fields.deinit(self.allocator);
    }
    
    pub fn addField(self: *Schema, name: []const u8, arrow_type: ArrowType, nullable: bool) !void {
        try self.fields.append(self.allocator, .{
            .name = name,
            .arrow_type = arrow_type,
            .nullable = nullable,
        });
    }
    
    pub fn numFields(self: *const Schema) usize {
        return self.fields.items.len;
    }
    
    pub fn getField(self: *const Schema, index: usize) ?Field {
        if (index >= self.fields.items.len) return null;
        return self.fields.items[index];
    }
};

// ============================================================================
// Arrow C Data Interface (for FFI)
// ============================================================================

/// ArrowSchema as per Arrow C Data Interface
pub const ArrowSchemaFFI = extern struct {
    format: [*c]const u8,
    name: [*c]const u8,
    metadata: [*c]const u8,
    flags: i64,
    n_children: i64,
    children: [*c][*c]ArrowSchemaFFI,
    dictionary: [*c]ArrowSchemaFFI,
    release: ?*const fn (*ArrowSchemaFFI) callconv(.C) void,
    private_data: ?*anyopaque,
};

/// ArrowArray as per Arrow C Data Interface
pub const ArrowArrayFFI = extern struct {
    length: i64,
    null_count: i64,
    offset: i64,
    n_buffers: i64,
    n_children: i64,
    buffers: [*c]?*anyopaque,
    children: [*c][*c]ArrowArrayFFI,
    dictionary: [*c]ArrowArrayFFI,
    release: ?*const fn (*ArrowArrayFFI) callconv(.C) void,
    private_data: ?*anyopaque,
};

// ============================================================================
// Tests
// ============================================================================

test "arrow buffer" {
    const allocator = std.testing.allocator;
    
    var buf = try ArrowBuffer.init(allocator, 64);
    defer buf.deinit();
    
    try buf.appendValue(i64, 42);
    try buf.appendValue(i64, 100);
    
    try std.testing.expectEqual(@as(usize, 16), buf.size);
}

test "validity bitmap" {
    const allocator = std.testing.allocator;
    
    var bitmap = ValidityBitmap.init(allocator);
    defer bitmap.deinit();
    
    try bitmap.appendValid();
    try bitmap.appendNull();
    try bitmap.appendValid();
    
    try std.testing.expect(bitmap.isValid(0));
    try std.testing.expect(!bitmap.isValid(1));
    try std.testing.expect(bitmap.isValid(2));
    try std.testing.expectEqual(@as(usize, 1), bitmap.null_count);
}

test "arrow array int64" {
    const allocator = std.testing.allocator;
    
    var arr = try ArrowArray.init(allocator, .INT64);
    defer arr.deinit();
    
    try arr.appendInt64(10);
    try arr.appendInt64(20);
    try arr.appendNull();
    try arr.appendInt64(40);
    
    try std.testing.expectEqual(@as(usize, 4), arr.length);
    try std.testing.expectEqual(@as(usize, 1), arr.null_count);
    try std.testing.expectEqual(@as(?i64, 10), arr.getInt64(0));
    try std.testing.expectEqual(@as(?i64, 20), arr.getInt64(1));
    try std.testing.expect(arr.isNull(2));
    try std.testing.expectEqual(@as(?i64, 40), arr.getInt64(3));
}

test "schema and record batch" {
    const allocator = std.testing.allocator;
    
    var schema = Schema.init(allocator);
    try schema.addField("id", .INT64, false);
    try schema.addField("value", .DOUBLE, true);
    
    var batch = RecordBatch.init(allocator, schema);
    defer batch.deinit();
    
    var col1 = try ArrowArray.init(allocator, .INT64);
    try col1.appendInt64(1);
    try col1.appendInt64(2);
    
    var col2 = try ArrowArray.init(allocator, .DOUBLE);
    try col2.appendFloat64(1.5);
    try col2.appendFloat64(2.5);
    
    try batch.addColumn(col1);
    try batch.addColumn(col2);
    
    try std.testing.expectEqual(@as(usize, 2), batch.numColumns());
    try std.testing.expectEqual(@as(usize, 2), batch.num_rows);
}