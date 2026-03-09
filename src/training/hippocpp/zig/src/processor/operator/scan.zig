//! Scan Operators - Table and index scanning
//!
//! Purpose:
//! Provides operators for scanning node tables, relationship tables,
//! and indexes to produce result tuples.

const std = @import("std");

// ============================================================================
// Scan Type
// ============================================================================

pub const ScanType = enum {
    SEQUENTIAL,     // Full table scan
    INDEX,          // Index scan
    CONST,          // Constant values
    EMPTY,          // Empty scan
};

// ============================================================================
// Scan Direction
// ============================================================================

pub const ScanDirection = enum {
    FORWARD,
    BACKWARD,
};

// ============================================================================
// Scan State
// ============================================================================

pub const ScanState = struct {
    current_offset: u64 = 0,
    num_scanned: u64 = 0,
    is_complete: bool = false,
    direction: ScanDirection = .FORWARD,
    
    pub fn reset(self: *ScanState) void {
        self.current_offset = 0;
        self.num_scanned = 0;
        self.is_complete = false;
    }
    
    pub fn advance(self: *ScanState, count: u64) void {
        self.current_offset += count;
        self.num_scanned += count;
    }
    
    pub fn markComplete(self: *ScanState) void {
        self.is_complete = true;
    }
};

// ============================================================================
// Scan Config
// ============================================================================

pub const ScanConfig = struct {
    table_id: u64 = 0,
    column_ids: []const u64 = &[_]u64{},
    scan_type: ScanType = .SEQUENTIAL,
    limit: ?u64 = null,
    batch_size: usize = 2048,
};

// ============================================================================
// Sequential Scan
// ============================================================================

pub const SequentialScan = struct {
    allocator: std.mem.Allocator,
    config: ScanConfig,
    state: ScanState = .{},
    total_rows: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, config: ScanConfig) SequentialScan {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    pub fn deinit(self: *SequentialScan) void {
        _ = self;
    }
    
    pub fn setTotalRows(self: *SequentialScan, total: u64) void {
        self.total_rows = total;
    }
    
    pub fn getNextBatch(self: *SequentialScan) ?ScanBatch {
        if (self.state.is_complete) return null;
        
        const remaining = self.total_rows - self.state.current_offset;
        if (remaining == 0) {
            self.state.markComplete();
            return null;
        }
        
        var batch_size = @min(remaining, self.config.batch_size);
        if (self.config.limit) |limit| {
            const limit_remaining = limit - self.state.num_scanned;
            batch_size = @min(batch_size, limit_remaining);
            if (batch_size == 0) {
                self.state.markComplete();
                return null;
            }
        }
        
        const batch = ScanBatch{
            .start_offset = self.state.current_offset,
            .num_rows = batch_size,
            .table_id = self.config.table_id,
        };
        
        self.state.advance(batch_size);
        
        if (self.state.current_offset >= self.total_rows) {
            self.state.markComplete();
        }
        
        return batch;
    }
    
    pub fn reset(self: *SequentialScan) void {
        self.state.reset();
    }
    
    pub fn isComplete(self: *const SequentialScan) bool {
        return self.state.is_complete;
    }
    
    pub fn getNumScanned(self: *const SequentialScan) u64 {
        return self.state.num_scanned;
    }
};

pub const ScanBatch = struct {
    start_offset: u64,
    num_rows: u64,
    table_id: u64,
};

// ============================================================================
// Index Scan
// ============================================================================

pub const IndexScan = struct {
    allocator: std.mem.Allocator,
    config: ScanConfig,
    state: ScanState = .{},
    
    // Index lookup results
    result_offsets: std.ArrayList(u64),
    
    pub fn init(allocator: std.mem.Allocator, config: ScanConfig) IndexScan {
        return .{
            .allocator = allocator,
            .config = config,
            .result_offsets = .{},
        };
    }
    
    pub fn deinit(self: *IndexScan) void {
        self.result_offsets.deinit(self.allocator);
    }
    
    pub fn addResult(self: *IndexScan, offset: u64) !void {
        try self.result_offsets.append(self.allocator, offset);
    }
    
    pub fn getNextBatch(self: *IndexScan) ?IndexScanBatch {
        if (self.state.is_complete) return null;
        
        const remaining = self.result_offsets.items.len - self.state.current_offset;
        if (remaining == 0) {
            self.state.markComplete();
            return null;
        }
        
        const start: usize = @intCast(self.state.current_offset);
        const batch_size = @min(remaining, self.config.batch_size);
        const end = start + batch_size;
        
        const batch = IndexScanBatch{
            .offsets = self.result_offsets.items[start..end],
            .table_id = self.config.table_id,
        };
        
        self.state.advance(batch_size);
        
        if (self.state.current_offset >= self.result_offsets.items.len) {
            self.state.markComplete();
        }
        
        return batch;
    }
    
    pub fn reset(self: *IndexScan) void {
        self.state.reset();
    }
};

pub const IndexScanBatch = struct {
    offsets: []const u64,
    table_id: u64,
};

// ============================================================================
// Node Table Scan
// ============================================================================

pub const NodeTableScan = struct {
    allocator: std.mem.Allocator,
    table_id: u64,
    state: ScanState = .{},
    num_nodes: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, table_id: u64) NodeTableScan {
        return .{
            .allocator = allocator,
            .table_id = table_id,
        };
    }
    
    pub fn setNumNodes(self: *NodeTableScan, num: u64) void {
        self.num_nodes = num;
    }
    
    pub fn getNextNodeBatch(self: *NodeTableScan, batch_size: usize) ?NodeScanBatch {
        if (self.state.is_complete) return null;
        
        const remaining = self.num_nodes - self.state.current_offset;
        if (remaining == 0) {
            self.state.markComplete();
            return null;
        }
        
        const actual_size = @min(remaining, batch_size);
        
        const batch = NodeScanBatch{
            .table_id = self.table_id,
            .start_offset = self.state.current_offset,
            .count = actual_size,
        };
        
        self.state.advance(actual_size);
        
        return batch;
    }
};

pub const NodeScanBatch = struct {
    table_id: u64,
    start_offset: u64,
    count: u64,
};

// ============================================================================
// Tests
// ============================================================================

test "scan state" {
    var state = ScanState{};
    try std.testing.expect(!state.is_complete);
    
    state.advance(100);
    try std.testing.expectEqual(@as(u64, 100), state.num_scanned);
    
    state.markComplete();
    try std.testing.expect(state.is_complete);
}

test "sequential scan" {
    const allocator = std.testing.allocator;
    
    var scan = SequentialScan.init(allocator, .{
        .table_id = 1,
        .batch_size = 100,
    });
    defer scan.deinit(std.testing.allocator);
    
    scan.setTotalRows(250);
    
    var total_rows: u64 = 0;
    var batch_count: u32 = 0;
    
    while (scan.getNextBatch()) |batch| {
        total_rows += batch.num_rows;
        batch_count += 1;
    }
    
    try std.testing.expectEqual(@as(u64, 250), total_rows);
    try std.testing.expectEqual(@as(u32, 3), batch_count);
    try std.testing.expect(scan.isComplete());
}

test "sequential scan with limit" {
    const allocator = std.testing.allocator;
    
    var scan = SequentialScan.init(allocator, .{
        .table_id = 1,
        .batch_size = 100,
        .limit = 150,
    });
    defer scan.deinit(std.testing.allocator);
    
    scan.setTotalRows(1000);
    
    var total_rows: u64 = 0;
    while (scan.getNextBatch()) |batch| {
        total_rows += batch.num_rows;
    }
    
    try std.testing.expectEqual(@as(u64, 150), total_rows);
}

test "index scan" {
    const allocator = std.testing.allocator;
    
    var scan = IndexScan.init(allocator, .{
        .table_id = 1,
        .batch_size = 10,
    });
    defer scan.deinit(std.testing.allocator);
    
    // Add some results
    try scan.addResult(5);
    try scan.addResult(10);
    try scan.addResult(15);
    
    const batch = scan.getNextBatch();
    try std.testing.expect(batch != null);
    try std.testing.expectEqual(@as(usize, 3), batch.?.offsets.len);
}

test "node table scan" {
    const allocator = std.testing.allocator;
    
    var scan = NodeTableScan.init(allocator, 1);
    scan.setNumNodes(100);
    
    var total: u64 = 0;
    while (scan.getNextNodeBatch(25)) |batch| {
        total += batch.count;
    }
    
    try std.testing.expectEqual(@as(u64, 100), total);
}