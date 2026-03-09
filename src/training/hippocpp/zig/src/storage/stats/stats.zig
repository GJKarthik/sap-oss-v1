//! Statistics Module - HyperLogLog and Column Statistics
//!
//! Purpose:
//! Provides cardinality estimation using HyperLogLog and
//! column statistics for query optimization.

const std = @import("std");

// ============================================================================
// HyperLogLog Cardinality Estimator
// ============================================================================

pub const HyperLogLog = struct {
    allocator: std.mem.Allocator,
    registers: []u8,
    precision: u8,  // Number of bits for register index (4-18)
    num_registers: usize,
    
    const alpha_16 = 0.673;
    const alpha_32 = 0.697;
    const alpha_64 = 0.709;
    
    pub fn init(allocator: std.mem.Allocator, precision: u8) !HyperLogLog {
        const p = @min(@max(precision, 4), 18);
        const m = @as(usize, 1) << @intCast(p);
        
        const registers = try allocator.alloc(u8, m);
        @memset(registers, 0);
        
        return .{
            .allocator = allocator,
            .registers = registers,
            .precision = p,
            .num_registers = m,
        };
    }
    
    pub fn deinit(self: *HyperLogLog) void {
        self.allocator.free(self.registers);
    }
    
    /// Add a value to the HLL
    pub fn add(self: *HyperLogLog, value: u64) void {
        const hash = self.hash64(value);
        const idx = hash >> @intCast(64 - self.precision);
        const w = hash << @intCast(self.precision);
        const rho = self.leadingZeros(w) + 1;
        
        if (self.registers[idx] < rho) {
            self.registers[idx] = rho;
        }
    }
    
    /// Add a string value
    pub fn addString(self: *HyperLogLog, value: []const u8) void {
        self.add(std.hash.Wyhash.hash(0, value));
    }
    
    /// Estimate cardinality
    pub fn estimate(self: *const HyperLogLog) f64 {
        const m: f64 = @floatFromInt(self.num_registers);
        const alpha = self.getAlpha();
        
        // Harmonic mean of 2^(-register[i])
        var sum: f64 = 0.0;
        var zeros: usize = 0;
        
        for (self.registers) |reg| {
            sum += std.math.pow(f64, 2.0, -@as(f64, @floatFromInt(reg)));
            if (reg == 0) zeros += 1;
        }
        
        var estimate_val = alpha * m * m / sum;
        
        // Small range correction
        if (estimate_val <= 2.5 * m) {
            if (zeros > 0) {
                estimate_val = m * @log(@as(f64, m) / @as(f64, @floatFromInt(zeros)));
            }
        }
        
        // Large range correction
        const pow_2_32: f64 = 4294967296.0;
        if (estimate_val > pow_2_32 / 30.0) {
            estimate_val = -pow_2_32 * @log(1.0 - estimate_val / pow_2_32);
        }
        
        return estimate_val;
    }
    
    /// Merge another HLL into this one
    pub fn merge(self: *HyperLogLog, other: *const HyperLogLog) void {
        if (self.num_registers != other.num_registers) return;
        
        for (self.registers, 0..) |*reg, i| {
            reg.* = @max(reg.*, other.registers[i]);
        }
    }
    
    fn hash64(self: *const HyperLogLog, value: u64) u64 {
        _ = self;
        // MurmurHash3 finalizer
        var h = value;
        h ^= h >> 33;
        h *%= 0xff51afd7ed558ccd;
        h ^= h >> 33;
        h *%= 0xc4ceb9fe1a85ec53;
        h ^= h >> 33;
        return h;
    }
    
    fn leadingZeros(self: *const HyperLogLog, value: u64) u8 {
        _ = self;
        if (value == 0) return 64;
        return @intCast(@clz(value));
    }
    
    fn getAlpha(self: *const HyperLogLog) f64 {
        return switch (self.num_registers) {
            16 => alpha_16,
            32 => alpha_32,
            64 => alpha_64,
            else => 0.7213 / (1.0 + 1.079 / @as(f64, @floatFromInt(self.num_registers))),
        };
    }
};

// ============================================================================
// Column Statistics
// ============================================================================

pub const ColumnStats = struct {
    allocator: std.mem.Allocator,
    
    // Cardinality
    num_rows: u64 = 0,
    num_nulls: u64 = 0,
    distinct_count: ?u64 = null,
    hll: ?HyperLogLog = null,
    
    // Range statistics
    has_min_max: bool = false,
    min_int: i64 = std.math.maxInt(i64),
    max_int: i64 = std.math.minInt(i64),
    min_float: f64 = std.math.inf(f64),
    max_float: f64 = -std.math.inf(f64),
    
    // Size statistics
    total_size_bytes: u64 = 0,
    avg_size_bytes: f64 = 0.0,
    
    pub fn init(allocator: std.mem.Allocator) ColumnStats {
        return .{ .allocator = allocator };
    }
    
    pub fn initWithHLL(allocator: std.mem.Allocator, hll_precision: u8) !ColumnStats {
        return .{
            .allocator = allocator,
            .hll = try HyperLogLog.init(allocator, hll_precision),
        };
    }
    
    pub fn deinit(self: *ColumnStats) void {
        if (self.hll) |*h| {
            h.deinit();
        }
    }
    
    pub fn addInteger(self: *ColumnStats, value: i64) void {
        self.num_rows += 1;
        self.has_min_max = true;
        self.min_int = @min(self.min_int, value);
        self.max_int = @max(self.max_int, value);
        
        if (self.hll) |*h| {
            h.add(@bitCast(value));
        }
    }
    
    pub fn addFloat(self: *ColumnStats, value: f64) void {
        self.num_rows += 1;
        self.has_min_max = true;
        self.min_float = @min(self.min_float, value);
        self.max_float = @max(self.max_float, value);
        
        if (self.hll) |*h| {
            h.add(@bitCast(value));
        }
    }
    
    pub fn addString(self: *ColumnStats, value: []const u8) void {
        self.num_rows += 1;
        self.total_size_bytes += value.len;
        
        if (self.hll) |*h| {
            h.addString(value);
        }
    }
    
    pub fn addNull(self: *ColumnStats) void {
        self.num_rows += 1;
        self.num_nulls += 1;
    }
    
    pub fn estimateCardinality(self: *const ColumnStats) u64 {
        if (self.distinct_count) |dc| return dc;
        if (self.hll) |*h| return @intFromFloat(h.estimate());
        return self.num_rows;
    }
    
    pub fn nullRatio(self: *const ColumnStats) f64 {
        if (self.num_rows == 0) return 0.0;
        return @as(f64, @floatFromInt(self.num_nulls)) / @as(f64, @floatFromInt(self.num_rows));
    }
    
    pub fn selectivity(self: *const ColumnStats) f64 {
        if (self.num_rows == 0) return 1.0;
        const card = self.estimateCardinality();
        return @as(f64, @floatFromInt(card)) / @as(f64, @floatFromInt(self.num_rows));
    }
    
    pub fn merge(self: *ColumnStats, other: *const ColumnStats) void {
        self.num_rows += other.num_rows;
        self.num_nulls += other.num_nulls;
        self.total_size_bytes += other.total_size_bytes;
        
        if (other.has_min_max) {
            self.has_min_max = true;
            self.min_int = @min(self.min_int, other.min_int);
            self.max_int = @max(self.max_int, other.max_int);
            self.min_float = @min(self.min_float, other.min_float);
            self.max_float = @max(self.max_float, other.max_float);
        }
        
        if (self.hll) |*h| {
            if (other.hll) |*oh| {
                h.merge(oh);
            }
        }
    }
};

// ============================================================================
// Table Statistics
// ============================================================================

pub const TableStats = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    num_rows: u64 = 0,
    num_columns: usize = 0,
    total_size_bytes: u64 = 0,
    column_stats: std.StringHashMap(ColumnStats),
    
    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) TableStats {
        return .{
            .allocator = allocator,
            .table_name = table_name,
            .column_stats = .{},
        };
    }
    
    pub fn deinit(self: *TableStats) void {
        var iter = self.column_stats.valueIterator();
        while (iter.next()) |stats| {
            stats.deinit();
        }
        self.column_stats.deinit(self.allocator);
    }
    
    pub fn getColumnStats(self: *TableStats, column_name: []const u8) ?*ColumnStats {
        return self.column_stats.getPtr(column_name);
    }
    
    pub fn addColumnStats(self: *TableStats, column_name: []const u8, stats: ColumnStats) !void {
        try self.column_stats.put(column_name, stats);
        self.num_columns = self.column_stats.count();
    }
};

// ============================================================================
// Statistics Manager
// ============================================================================

pub const StatsManager = struct {
    allocator: std.mem.Allocator,
    table_stats: std.StringHashMap(TableStats),
    auto_update: bool = true,
    sample_rate: f64 = 0.1,
    
    pub fn init(allocator: std.mem.Allocator) StatsManager {
        return .{
            .allocator = allocator,
            .table_stats = .{},
        };
    }
    
    pub fn deinit(self: *StatsManager) void {
        var iter = self.table_stats.valueIterator();
        while (iter.next()) |stats| {
            stats.deinit();
        }
        self.table_stats.deinit(self.allocator);
    }
    
    pub fn getTableStats(self: *StatsManager, table_name: []const u8) ?*TableStats {
        return self.table_stats.getPtr(table_name);
    }
    
    pub fn createTableStats(self: *StatsManager, table_name: []const u8) !*TableStats {
        const entry = try self.table_stats.getOrPut(table_name);
        if (!entry.found_existing) {
            entry.value_ptr.* = TableStats.init(self.allocator, table_name);
        }
        return entry.value_ptr;
    }
};

// ============================================================================
// Histogram for Range Selectivity
// ============================================================================

pub const Histogram = struct {
    allocator: std.mem.Allocator,
    buckets: std.ArrayList(Bucket),
    num_buckets: usize,
    
    pub const Bucket = struct {
        lower_bound: i64,
        upper_bound: i64,
        count: u64,
        distinct_count: u64,
    };
    
    pub fn init(allocator: std.mem.Allocator, num_buckets: usize) Histogram {
        return .{
            .allocator = allocator,
            .buckets = .{},
            .num_buckets = num_buckets,
        };
    }
    
    pub fn deinit(self: *Histogram) void {
        self.buckets.deinit(self.allocator);
    }
    
    /// Build equi-depth histogram from sorted values
    pub fn buildFromSorted(self: *Histogram, values: []const i64) !void {
        if (values.len == 0) return;
        
        const bucket_size = (values.len + self.num_buckets - 1) / self.num_buckets;
        
        var i: usize = 0;
        while (i < values.len) {
            const end = @min(i + bucket_size, values.len);
            const bucket = Bucket{
                .lower_bound = values[i],
                .upper_bound = values[end - 1],
                .count = end - i,
                .distinct_count = self.countDistinct(values[i..end]),
            };
            try self.buckets.append(self.allocator, bucket);
            i = end;
        }
    }
    
    fn countDistinct(self: *const Histogram, values: []const i64) u64 {
        _ = self;
        if (values.len == 0) return 0;
        var count: u64 = 1;
        var prev = values[0];
        for (values[1..]) |v| {
            if (v != prev) {
                count += 1;
                prev = v;
            }
        }
        return count;
    }
    
    /// Estimate selectivity for range [low, high]
    pub fn rangeSelectivity(self: *const Histogram, low: i64, high: i64, total_rows: u64) f64 {
        if (total_rows == 0 or self.buckets.items.len == 0) return 1.0;
        
        var selected: u64 = 0;
        
        for (self.buckets.items) |bucket| {
            // Fully outside
            if (bucket.upper_bound < low or bucket.lower_bound > high) continue;
            
            // Fully inside
            if (bucket.lower_bound >= low and bucket.upper_bound <= high) {
                selected += bucket.count;
                continue;
            }
            
            // Partial overlap - linear interpolation
            const bucket_range = bucket.upper_bound - bucket.lower_bound + 1;
            const overlap_low = @max(bucket.lower_bound, low);
            const overlap_high = @min(bucket.upper_bound, high);
            const overlap_range = overlap_high - overlap_low + 1;
            
            if (bucket_range > 0) {
                const fraction = @as(f64, @floatFromInt(overlap_range)) / @as(f64, @floatFromInt(bucket_range));
                selected += @intFromFloat(fraction * @as(f64, @floatFromInt(bucket.count)));
            }
        }
        
        return @as(f64, @floatFromInt(selected)) / @as(f64, @floatFromInt(total_rows));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "hyperloglog basic" {
    const allocator = std.testing.allocator;
    
    var hll = try HyperLogLog.init(allocator, 14);
    defer hll.deinit();
    
    // Add 1000 distinct values
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        hll.add(i);
    }
    
    const estimate = hll.estimate();
    // HLL should be within ~3% for p=14
    try std.testing.expect(estimate > 900 and estimate < 1100);
}

test "hyperloglog merge" {
    const allocator = std.testing.allocator;
    
    var hll1 = try HyperLogLog.init(allocator, 10);
    defer hll1.deinit();
    
    var hll2 = try HyperLogLog.init(allocator, 10);
    defer hll2.deinit();
    
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        hll1.add(i);
    }
    while (i < 1000) : (i += 1) {
        hll2.add(i);
    }
    
    hll1.merge(&hll2);
    
    const estimate = hll1.estimate();
    try std.testing.expect(estimate > 800 and estimate < 1200);
}

test "column stats" {
    const allocator = std.testing.allocator;
    
    var stats = try ColumnStats.initWithHLL(allocator, 10);
    defer stats.deinit();
    
    stats.addInteger(10);
    stats.addInteger(20);
    stats.addInteger(30);
    stats.addNull();
    
    try std.testing.expectEqual(@as(u64, 4), stats.num_rows);
    try std.testing.expectEqual(@as(u64, 1), stats.num_nulls);
    try std.testing.expectEqual(@as(i64, 10), stats.min_int);
    try std.testing.expectEqual(@as(i64, 30), stats.max_int);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), stats.nullRatio(), 0.01);
}

test "histogram range selectivity" {
    const allocator = std.testing.allocator;
    
    var hist = Histogram.init(allocator, 4);
    defer hist.deinit();
    
    const values = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try hist.buildFromSorted(&values);
    
    try std.testing.expectEqual(@as(usize, 4), hist.buckets.items.len);
    
    // Full range
    const sel_full = hist.rangeSelectivity(1, 8, 8);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sel_full, 0.01);
    
    // Half range
    const sel_half = hist.rangeSelectivity(1, 4, 8);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), sel_half, 0.1);
}