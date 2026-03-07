//! Limit/Skip Operators - Result set limiting
//!
//! Purpose:
//! Provides operators for LIMIT, SKIP/OFFSET clauses
//! to control result set size.

const std = @import("std");

// ============================================================================
// Limit Operator
// ============================================================================

pub const LimitOperator = struct {
    limit: u64,
    offset: u64 = 0,
    rows_skipped: u64 = 0,
    rows_output: u64 = 0,
    
    pub fn init(limit: u64) LimitOperator {
        return .{ .limit = limit };
    }
    
    pub fn withOffset(limit: u64, offset: u64) LimitOperator {
        return .{ .limit = limit, .offset = offset };
    }
    
    /// Returns true if the row should be output
    pub fn processRow(self: *LimitOperator) bool {
        // Skip rows until offset reached
        if (self.rows_skipped < self.offset) {
            self.rows_skipped += 1;
            return false;
        }
        
        // Check if we've reached limit
        if (self.rows_output >= self.limit) {
            return false;
        }
        
        self.rows_output += 1;
        return true;
    }
    
    pub fn isComplete(self: *const LimitOperator) bool {
        return self.rows_output >= self.limit;
    }
    
    pub fn getRemainingCapacity(self: *const LimitOperator) u64 {
        if (self.rows_output >= self.limit) return 0;
        return self.limit - self.rows_output;
    }
    
    pub fn getStats(self: *const LimitOperator) LimitStats {
        return .{
            .limit = self.limit,
            .offset = self.offset,
            .rows_skipped = self.rows_skipped,
            .rows_output = self.rows_output,
        };
    }
    
    pub fn reset(self: *LimitOperator) void {
        self.rows_skipped = 0;
        self.rows_output = 0;
    }
};

pub const LimitStats = struct {
    limit: u64,
    offset: u64,
    rows_skipped: u64,
    rows_output: u64,
};

// ============================================================================
// Skip Operator (OFFSET only, no LIMIT)
// ============================================================================

pub const SkipOperator = struct {
    offset: u64,
    rows_skipped: u64 = 0,
    rows_output: u64 = 0,
    
    pub fn init(offset: u64) SkipOperator {
        return .{ .offset = offset };
    }
    
    pub fn processRow(self: *SkipOperator) bool {
        if (self.rows_skipped < self.offset) {
            self.rows_skipped += 1;
            return false;
        }
        self.rows_output += 1;
        return true;
    }
    
    pub fn isSkipComplete(self: *const SkipOperator) bool {
        return self.rows_skipped >= self.offset;
    }
    
    pub fn reset(self: *SkipOperator) void {
        self.rows_skipped = 0;
        self.rows_output = 0;
    }
};

// ============================================================================
// Batch Limit (for vectorized processing)
// ============================================================================

pub const BatchLimit = struct {
    limit: u64,
    offset: u64 = 0,
    rows_processed: u64 = 0,
    rows_output: u64 = 0,
    
    pub fn init(limit: u64, offset: u64) BatchLimit {
        return .{ .limit = limit, .offset = offset };
    }
    
    /// Process a batch, returns (start, count) of rows to output from batch
    pub fn processBatch(self: *BatchLimit, batch_size: u64) BatchResult {
        // Rows still to skip
        const skip_remaining = if (self.rows_processed < self.offset)
            self.offset - self.rows_processed
        else
            0;
        
        // Rows we can output
        const output_remaining = if (self.rows_output < self.limit)
            self.limit - self.rows_output
        else
            0;
        
        const start = @min(skip_remaining, batch_size);
        const available = batch_size - start;
        const output_count = @min(available, output_remaining);
        
        self.rows_processed += batch_size;
        self.rows_output += output_count;
        
        return .{
            .start = start,
            .count = output_count,
            .is_complete = self.rows_output >= self.limit,
        };
    }
    
    pub fn isComplete(self: *const BatchLimit) bool {
        return self.rows_output >= self.limit;
    }
};

pub const BatchResult = struct {
    start: u64,
    count: u64,
    is_complete: bool,
};

// ============================================================================
// Sample Operator (random sampling)
// ============================================================================

pub const SampleOperator = struct {
    sample_size: u64,
    sample_rate: f64 = 1.0,
    rows_seen: u64 = 0,
    rows_sampled: u64 = 0,
    prng: std.rand.DefaultPrng,
    
    pub fn init(sample_size: u64) SampleOperator {
        return .{
            .sample_size = sample_size,
            .prng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp())),
        };
    }
    
    pub fn withRate(rate: f64) SampleOperator {
        return .{
            .sample_size = std.math.maxInt(u64),
            .sample_rate = rate,
            .prng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp())),
        };
    }
    
    /// Returns true if row should be sampled
    pub fn shouldSample(self: *SampleOperator) bool {
        self.rows_seen += 1;
        
        // Reservoir sampling approach for exact count
        if (self.rows_sampled < self.sample_size) {
            self.rows_sampled += 1;
            return true;
        }
        
        // Rate-based sampling
        if (self.sample_rate < 1.0) {
            const rand = self.prng.random().float(f64);
            if (rand < self.sample_rate) {
                self.rows_sampled += 1;
                return true;
            }
        }
        
        return false;
    }
    
    pub fn getSampleCount(self: *const SampleOperator) u64 {
        return self.rows_sampled;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "limit operator basic" {
    var limit = LimitOperator.init(3);
    
    try std.testing.expect(limit.processRow());
    try std.testing.expect(limit.processRow());
    try std.testing.expect(limit.processRow());
    try std.testing.expect(!limit.processRow());  // Limit reached
    
    try std.testing.expectEqual(@as(u64, 3), limit.rows_output);
}

test "limit operator with offset" {
    var limit = LimitOperator.withOffset(2, 3);
    
    // First 3 rows skipped
    try std.testing.expect(!limit.processRow());
    try std.testing.expect(!limit.processRow());
    try std.testing.expect(!limit.processRow());
    
    // Next 2 rows output
    try std.testing.expect(limit.processRow());
    try std.testing.expect(limit.processRow());
    
    // Limit reached
    try std.testing.expect(!limit.processRow());
    
    try std.testing.expectEqual(@as(u64, 3), limit.rows_skipped);
    try std.testing.expectEqual(@as(u64, 2), limit.rows_output);
}

test "skip operator" {
    var skip = SkipOperator.init(2);
    
    try std.testing.expect(!skip.processRow());
    try std.testing.expect(!skip.processRow());
    try std.testing.expect(skip.processRow());
    try std.testing.expect(skip.processRow());
    
    try std.testing.expect(skip.isSkipComplete());
}

test "batch limit" {
    var batch = BatchLimit.init(5, 3);
    
    // First batch of 4: skip 3, output 1
    var result = batch.processBatch(4);
    try std.testing.expectEqual(@as(u64, 3), result.start);
    try std.testing.expectEqual(@as(u64, 1), result.count);
    try std.testing.expect(!result.is_complete);
    
    // Second batch of 4: output remaining 4
    result = batch.processBatch(4);
    try std.testing.expectEqual(@as(u64, 0), result.start);
    try std.testing.expectEqual(@as(u64, 4), result.count);
    try std.testing.expect(result.is_complete);
}

test "limit complete check" {
    var limit = LimitOperator.init(1);
    
    try std.testing.expect(!limit.isComplete());
    _ = limit.processRow();
    try std.testing.expect(limit.isComplete());
}