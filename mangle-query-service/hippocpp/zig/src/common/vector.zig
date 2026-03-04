//! Vector - Column-oriented data vectors
//!
//! Purpose:
//! Provides vectorized column storage for efficient
//! batch processing of query results.

const std = @import("std");

// ============================================================================
// Vector Type
// ============================================================================

pub const VectorType = enum {
    FLAT,           // All values stored
    CONSTANT,       // Single value repeated
    DICTIONARY,     // Dictionary encoded
    SEQUENCE,       // Sequential values
};

// ============================================================================
// Validity Mask
// ============================================================================

pub const ValidityMask = struct {
    bits: []u64,
    allocator: std.mem.Allocator,
    size: usize,
    
    pub fn init(allocator: std.mem.Allocator, size: usize) !ValidityMask {
        const num_words = (size + 63) / 64;
        const bits = try allocator.alloc(u64, num_words);
        // All valid by default
        @memset(bits, std.math.maxInt(u64));
        
        return .{
            .bits = bits,
            .allocator = allocator,
            .size = size,
        };
    }
    
    pub fn deinit(self: *ValidityMask) void {
        self.allocator.free(self.bits);
    }
    
    pub fn setValid(self: *ValidityMask, idx: usize) void {
        if (idx >= self.size) return;
        const word = idx / 64;
        const bit = @as(u6, @intCast(idx % 64));
        self.bits[word] |= @as(u64, 1) << bit;
    }
    
    pub fn setInvalid(self: *ValidityMask, idx: usize) void {
        if (idx >= self.size) return;
        const word = idx / 64;
        const bit = @as(u6, @intCast(idx % 64));
        self.bits[word] &= ~(@as(u64, 1) << bit);
    }
    
    pub fn isValid(self: *const ValidityMask, idx: usize) bool {
        if (idx >= self.size) return false;
        const word = idx / 64;
        const bit = @as(u6, @intCast(idx % 64));
        return (self.bits[word] & (@as(u64, 1) << bit)) != 0;
    }
    
    pub fn countValid(self: *const ValidityMask) usize {
        var count: usize = 0;
        for (self.bits) |word| {
            count += @popCount(word);
        }
        return @min(count, self.size);
    }
    
    pub fn setAllValid(self: *ValidityMask) void {
        @memset(self.bits, std.math.maxInt(u64));
    }
    
    pub fn setAllInvalid(self: *ValidityMask) void {
        @memset(self.bits, 0);
    }
};

// ============================================================================
// Int64 Vector
// ============================================================================

pub const Int64Vector = struct {
    allocator: std.mem.Allocator,
    data: []i64,
    validity: ValidityMask,
    count: usize,
    capacity: usize,
    vector_type: VectorType = .FLAT,
    constant_value: ?i64 = null,
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Int64Vector {
        const data = try allocator.alloc(i64, capacity);
        @memset(data, 0);
        
        return .{
            .allocator = allocator,
            .data = data,
            .validity = try ValidityMask.init(allocator, capacity),
            .count = 0,
            .capacity = capacity,
        };
    }
    
    pub fn deinit(self: *Int64Vector) void {
        self.allocator.free(self.data);
        self.validity.deinit();
    }
    
    pub fn constant(allocator: std.mem.Allocator, value: i64, count: usize) !Int64Vector {
        return .{
            .allocator = allocator,
            .data = &[_]i64{},
            .validity = try ValidityMask.init(allocator, 0),
            .count = count,
            .capacity = 0,
            .vector_type = .CONSTANT,
            .constant_value = value,
        };
    }
    
    pub fn append(self: *Int64Vector, value: i64) !void {
        if (self.count >= self.capacity) return error.VectorFull;
        self.data[self.count] = value;
        self.validity.setValid(self.count);
        self.count += 1;
    }
    
    pub fn appendNull(self: *Int64Vector) !void {
        if (self.count >= self.capacity) return error.VectorFull;
        self.data[self.count] = 0;
        self.validity.setInvalid(self.count);
        self.count += 1;
    }
    
    pub fn get(self: *const Int64Vector, idx: usize) ?i64 {
        if (self.vector_type == .CONSTANT) {
            return self.constant_value;
        }
        if (idx >= self.count) return null;
        if (!self.validity.isValid(idx)) return null;
        return self.data[idx];
    }
    
    pub fn set(self: *Int64Vector, idx: usize, value: i64) void {
        if (idx >= self.capacity) return;
        self.data[idx] = value;
        self.validity.setValid(idx);
    }
    
    pub fn setNull(self: *Int64Vector, idx: usize) void {
        if (idx >= self.capacity) return;
        self.validity.setInvalid(idx);
    }
    
    pub fn len(self: *const Int64Vector) usize {
        return self.count;
    }
    
    pub fn clear(self: *Int64Vector) void {
        self.count = 0;
    }
    
    pub fn sum(self: *const Int64Vector) i64 {
        if (self.vector_type == .CONSTANT) {
            return (self.constant_value orelse 0) * @as(i64, @intCast(self.count));
        }
        var total: i64 = 0;
        for (0..self.count) |i| {
            if (self.validity.isValid(i)) {
                total += self.data[i];
            }
        }
        return total;
    }
};

// ============================================================================
// Float64 Vector
// ============================================================================

pub const Float64Vector = struct {
    allocator: std.mem.Allocator,
    data: []f64,
    validity: ValidityMask,
    count: usize,
    capacity: usize,
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Float64Vector {
        const data = try allocator.alloc(f64, capacity);
        @memset(data, 0);
        
        return .{
            .allocator = allocator,
            .data = data,
            .validity = try ValidityMask.init(allocator, capacity),
            .count = 0,
            .capacity = capacity,
        };
    }
    
    pub fn deinit(self: *Float64Vector) void {
        self.allocator.free(self.data);
        self.validity.deinit();
    }
    
    pub fn append(self: *Float64Vector, value: f64) !void {
        if (self.count >= self.capacity) return error.VectorFull;
        self.data[self.count] = value;
        self.validity.setValid(self.count);
        self.count += 1;
    }
    
    pub fn get(self: *const Float64Vector, idx: usize) ?f64 {
        if (idx >= self.count) return null;
        if (!self.validity.isValid(idx)) return null;
        return self.data[idx];
    }
    
    pub fn len(self: *const Float64Vector) usize {
        return self.count;
    }
};

// ============================================================================
// Bool Vector
// ============================================================================

pub const BoolVector = struct {
    allocator: std.mem.Allocator,
    data: []bool,
    count: usize,
    capacity: usize,
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !BoolVector {
        const data = try allocator.alloc(bool, capacity);
        @memset(data, false);
        
        return .{
            .allocator = allocator,
            .data = data,
            .count = 0,
            .capacity = capacity,
        };
    }
    
    pub fn deinit(self: *BoolVector) void {
        self.allocator.free(self.data);
    }
    
    pub fn append(self: *BoolVector, value: bool) !void {
        if (self.count >= self.capacity) return error.VectorFull;
        self.data[self.count] = value;
        self.count += 1;
    }
    
    pub fn get(self: *const BoolVector, idx: usize) ?bool {
        if (idx >= self.count) return null;
        return self.data[idx];
    }
    
    pub fn countTrue(self: *const BoolVector) usize {
        var count: usize = 0;
        for (self.data[0..self.count]) |v| {
            if (v) count += 1;
        }
        return count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "validity mask" {
    const allocator = std.testing.allocator;
    
    var mask = try ValidityMask.init(allocator, 100);
    defer mask.deinit();
    
    try std.testing.expect(mask.isValid(0));
    
    mask.setInvalid(5);
    try std.testing.expect(!mask.isValid(5));
    try std.testing.expect(mask.isValid(6));
    
    mask.setValid(5);
    try std.testing.expect(mask.isValid(5));
}

test "int64 vector" {
    const allocator = std.testing.allocator;
    
    var vec = try Int64Vector.init(allocator, 10);
    defer vec.deinit();
    
    try vec.append(100);
    try vec.append(200);
    try vec.appendNull();
    try vec.append(300);
    
    try std.testing.expectEqual(@as(usize, 4), vec.len());
    try std.testing.expectEqual(@as(i64, 100), vec.get(0).?);
    try std.testing.expectEqual(@as(i64, 200), vec.get(1).?);
    try std.testing.expect(vec.get(2) == null);  // NULL
    try std.testing.expectEqual(@as(i64, 300), vec.get(3).?);
}

test "int64 vector sum" {
    const allocator = std.testing.allocator;
    
    var vec = try Int64Vector.init(allocator, 10);
    defer vec.deinit();
    
    try vec.append(10);
    try vec.append(20);
    try vec.append(30);
    
    try std.testing.expectEqual(@as(i64, 60), vec.sum());
}

test "float64 vector" {
    const allocator = std.testing.allocator;
    
    var vec = try Float64Vector.init(allocator, 10);
    defer vec.deinit();
    
    try vec.append(1.5);
    try vec.append(2.5);
    
    try std.testing.expectEqual(@as(usize, 2), vec.len());
    try std.testing.expectEqual(@as(f64, 1.5), vec.get(0).?);
}

test "bool vector" {
    const allocator = std.testing.allocator;
    
    var vec = try BoolVector.init(allocator, 10);
    defer vec.deinit();
    
    try vec.append(true);
    try vec.append(false);
    try vec.append(true);
    
    try std.testing.expectEqual(@as(usize, 2), vec.countTrue());
}