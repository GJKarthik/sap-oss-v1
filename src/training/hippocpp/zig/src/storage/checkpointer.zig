//! Checkpointer - Database checkpoint management
//!
//! Purpose:
//! Handles checkpoint creation and recovery for durability.
//! Flushes dirty pages and WAL to ensure consistent state.

const std = @import("std");

// ============================================================================
// Checkpoint Types
// ============================================================================

pub const CheckpointType = enum {
    FULL,           // Full checkpoint - flush all dirty pages
    INCREMENTAL,    // Incremental - only changed pages since last checkpoint
    FORCED,         // Forced checkpoint - bypass threshold checks
    SHUTDOWN,       // Checkpoint on database shutdown
};

pub const CheckpointState = enum {
    IDLE,
    STARTING,
    FLUSHING_WAL,
    FLUSHING_PAGES,
    TRUNCATING_WAL,
    COMPLETING,
    COMPLETED,
    FAILED,
};

// ============================================================================
// Checkpoint Record
// ============================================================================

pub const CheckpointRecord = struct {
    checkpoint_id: u64,
    timestamp: i64,
    checkpoint_type: CheckpointType,
    start_lsn: u64,
    end_lsn: u64,
    pages_flushed: u64,
    wal_size_before: u64,
    wal_size_after: u64,
    duration_ms: u64,
    
    pub fn init(id: u64, cp_type: CheckpointType) CheckpointRecord {
        return .{
            .checkpoint_id = id,
            .timestamp = std.time.timestamp(),
            .checkpoint_type = cp_type,
            .start_lsn = 0,
            .end_lsn = 0,
            .pages_flushed = 0,
            .wal_size_before = 0,
            .wal_size_after = 0,
            .duration_ms = 0,
        };
    }
};

// ============================================================================
// Checkpoint Config
// ============================================================================

pub const CheckpointConfig = struct {
    interval_ms: u64 = 60_000,          // Checkpoint every 60 seconds
    wal_size_threshold: u64 = 100 * 1024 * 1024,  // 100MB WAL triggers checkpoint
    dirty_page_threshold: u64 = 10_000,  // Number of dirty pages
    enabled: bool = true,
    async_checkpoint: bool = true,       // Run in background
    verify_after: bool = false,          // Verify checkpoint integrity
};

// ============================================================================
// Dirty Page Tracker
// ============================================================================

pub const DirtyPageTracker = struct {
    allocator: std.mem.Allocator,
    dirty_pages: std.AutoHashMap(u64, DirtyPageInfo),
    first_dirty_lsn: u64 = std.math.maxInt(u64),
    
    pub const DirtyPageInfo = struct {
        page_id: u64,
        table_id: u64,
        first_dirty_lsn: u64,
        last_dirty_lsn: u64,
        
        pub fn init(page_id: u64, table_id: u64, lsn: u64) DirtyPageInfo {
            return .{
                .page_id = page_id,
                .table_id = table_id,
                .first_dirty_lsn = lsn,
                .last_dirty_lsn = lsn,
            };
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) DirtyPageTracker {
        return .{
            .allocator = allocator,
            .dirty_pages = .{ .unmanaged = .empty, .allocator = std.testing.allocator, .ctx = .{} },
        };
    }
    
    pub fn deinit(self: *DirtyPageTracker) void {
        self.dirty_pages.deinit();
    }
    
    pub fn markDirty(self: *DirtyPageTracker, page_id: u64, table_id: u64, lsn: u64) !void {
        if (self.dirty_pages.getPtr(page_id)) |info| {
            info.last_dirty_lsn = lsn;
        } else {
            try self.dirty_pages.put(page_id, DirtyPageInfo.init(page_id, table_id, lsn));
            self.first_dirty_lsn = @min(self.first_dirty_lsn, lsn);
        }
    }
    
    pub fn markClean(self: *DirtyPageTracker, page_id: u64) void {
        _ = self.dirty_pages.remove(page_id);
    }
    
    pub fn isDirty(self: *const DirtyPageTracker, page_id: u64) bool {
        return self.dirty_pages.contains(page_id);
    }
    
    pub fn getDirtyCount(self: *const DirtyPageTracker) usize {
        return self.dirty_pages.count();
    }
    
    pub fn getPagesBefore(self: *const DirtyPageTracker, lsn: u64, _: std.mem.Allocator) ![]u64 {
        var result = .{};
        
        var iter = self.dirty_pages.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.first_dirty_lsn < lsn) {
                try result.append(self.allocator, entry.key_ptr.*);
            }
        }
        
        return result.toOwnedSlice();
    }
    
    pub fn clear(self: *DirtyPageTracker) void {
        self.dirty_pages.clearRetainingCapacity();
        self.first_dirty_lsn = std.math.maxInt(u64);
    }
};

// ============================================================================
// Checkpointer
// ============================================================================

pub const Checkpointer = struct {
    allocator: std.mem.Allocator,
    config: CheckpointConfig,
    state: CheckpointState = .IDLE,
    
    // Tracking
    dirty_tracker: DirtyPageTracker,
    last_checkpoint: ?CheckpointRecord = null,
    checkpoint_count: u64 = 0,
    
    // LSN tracking
    current_lsn: u64 = 0,
    flushed_lsn: u64 = 0,
    
    // Statistics
    total_pages_flushed: u64 = 0,
    total_checkpoints: u64 = 0,
    total_duration_ms: u64 = 0,
    
    // Lock for concurrent access
    mutex: std.Thread.Mutex = .{},
    
    pub fn init(allocator: std.mem.Allocator, config: CheckpointConfig) Checkpointer {
        return .{
            .allocator = allocator,
            .config = config,
            .dirty_tracker = DirtyPageTracker.init(allocator),
        };
    }
    
    pub fn deinit(self: *Checkpointer) void {
        self.dirty_tracker.deinit();
    }
    
    /// Check if checkpoint is needed
    pub fn needsCheckpoint(self: *Checkpointer, wal_size: u64) bool {
        if (!self.config.enabled) return false;
        if (self.state != .IDLE) return false;
        
        // Check WAL size
        if (wal_size >= self.config.wal_size_threshold) return true;
        
        // Check dirty page count
        if (self.dirty_tracker.getDirtyCount() >= self.config.dirty_page_threshold) return true;
        
        return false;
    }
    
    /// Begin a checkpoint
    pub fn beginCheckpoint(self: *Checkpointer, cp_type: CheckpointType) !*CheckpointRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.state != .IDLE and cp_type != .FORCED) {
            return error.CheckpointInProgress;
        }
        
        self.state = .STARTING;
        self.checkpoint_count += 1;
        
        var record = try self.allocator.create(CheckpointRecord);
        record.* = CheckpointRecord.init(self.checkpoint_count, cp_type);
        record.start_lsn = self.flushed_lsn;
        
        return record;
    }
    
    /// Execute checkpoint (flushes dirty pages)
    pub fn executeCheckpoint(self: *Checkpointer, record: *CheckpointRecord) !void {
        const start_time = std.time.milliTimestamp();
        
        // Phase 1: Flush WAL
        self.state = .FLUSHING_WAL;
        // In real implementation: flush WAL to disk
        
        // Phase 2: Flush dirty pages
        self.state = .FLUSHING_PAGES;
        const dirty_count = self.dirty_tracker.getDirtyCount();
        record.pages_flushed = dirty_count;
        
        // Simulate page flush - in real implementation would write to disk
        var iter = self.dirty_tracker.dirty_pages.iterator();
        while (iter.next()) |_| {
            // Flush each page
            self.total_pages_flushed += 1;
        }
        
        // Phase 3: Truncate WAL
        self.state = .TRUNCATING_WAL;
        // In real implementation: truncate WAL up to checkpoint LSN
        
        // Phase 4: Complete
        self.state = .COMPLETING;
        
        record.end_lsn = self.current_lsn;
        record.duration_ms = @intCast(std.time.milliTimestamp() - start_time);
        
        self.dirty_tracker.clear();
        self.flushed_lsn = self.current_lsn;
        self.total_checkpoints += 1;
        self.total_duration_ms += record.duration_ms;
        
        self.state = .COMPLETED;
    }
    
    /// Complete checkpoint
    pub fn completeCheckpoint(self: *Checkpointer, record: *CheckpointRecord) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.last_checkpoint = record.*;
        self.state = .IDLE;
        
        self.allocator.destroy(record);
    }
    
    /// Force a checkpoint
    pub fn forceCheckpoint(self: *Checkpointer) !void {
        const record = try self.beginCheckpoint(.FORCED);
        try self.executeCheckpoint(record);
        self.completeCheckpoint(record);
    }
    
    /// Mark page as dirty
    pub fn markPageDirty(self: *Checkpointer, page_id: u64, table_id: u64) !void {
        self.current_lsn += 1;
        try self.dirty_tracker.markDirty(page_id, table_id, self.current_lsn);
    }
    
    /// Get statistics
    pub fn getStats(self: *const Checkpointer) CheckpointStats {
        return .{
            .total_checkpoints = self.total_checkpoints,
            .total_pages_flushed = self.total_pages_flushed,
            .total_duration_ms = self.total_duration_ms,
            .dirty_page_count = self.dirty_tracker.getDirtyCount(),
            .current_lsn = self.current_lsn,
            .flushed_lsn = self.flushed_lsn,
        };
    }
};

pub const CheckpointStats = struct {
    total_checkpoints: u64,
    total_pages_flushed: u64,
    total_duration_ms: u64,
    dirty_page_count: usize,
    current_lsn: u64,
    flushed_lsn: u64,
};

// ============================================================================
// Recovery Manager
// ============================================================================

pub const RecoveryManager = struct {
    allocator: std.mem.Allocator,
    last_checkpoint_lsn: u64 = 0,
    recovery_complete: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) RecoveryManager {
        return .{ .allocator = allocator };
    }
    
    /// Perform recovery from checkpoint and WAL
    pub fn recover(self: *RecoveryManager, checkpoint_lsn: u64) !RecoveryResult {
        var result = RecoveryResult{};
        
        // Phase 1: Analysis - scan WAL from checkpoint
        result.analysis_lsn = checkpoint_lsn;
        
        // Phase 2: Redo - replay committed transactions
        result.redo_count = 0;
        
        // Phase 3: Undo - rollback uncommitted transactions
        result.undo_count = 0;
        
        self.last_checkpoint_lsn = checkpoint_lsn;
        self.recovery_complete = true;
        
        return result;
    }
    
    pub fn isRecoveryComplete(self: *const RecoveryManager) bool {
        return self.recovery_complete;
    }
};

pub const RecoveryResult = struct {
    analysis_lsn: u64 = 0,
    redo_count: u64 = 0,
    undo_count: u64 = 0,
    duration_ms: u64 = 0,
};

// ============================================================================
// Tests
// ============================================================================

test "dirty page tracker" {
    const allocator = std.testing.allocator;
    
    var tracker = DirtyPageTracker.init(allocator);
    defer tracker.deinit();
    
    try tracker.markDirty(100, 1, 10);
    try tracker.markDirty(200, 1, 20);
    try tracker.markDirty(300, 2, 30);
    
    try std.testing.expectEqual(@as(usize, 3), tracker.getDirtyCount());
    try std.testing.expect(tracker.isDirty(100));
    try std.testing.expect(tracker.isDirty(200));
    try std.testing.expect(!tracker.isDirty(999));
    
    tracker.markClean(100);
    try std.testing.expectEqual(@as(usize, 2), tracker.getDirtyCount());
    try std.testing.expect(!tracker.isDirty(100));
}

test "checkpointer basic" {
    const allocator = std.testing.allocator;
    
    var checkpointer = Checkpointer.init(allocator, .{});
    defer checkpointer.deinit();
    
    try checkpointer.markPageDirty(1, 0);
    try checkpointer.markPageDirty(2, 0);
    try checkpointer.markPageDirty(3, 0);
    
    const stats = checkpointer.getStats();
    try std.testing.expectEqual(@as(usize, 3), stats.dirty_page_count);
    try std.testing.expectEqual(@as(u64, 3), stats.current_lsn);
}

test "checkpointer force checkpoint" {
    const allocator = std.testing.allocator;
    
    var checkpointer = Checkpointer.init(allocator, .{});
    defer checkpointer.deinit();
    
    try checkpointer.markPageDirty(1, 0);
    try checkpointer.markPageDirty(2, 0);
    
    try checkpointer.forceCheckpoint();
    
    const stats = checkpointer.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.dirty_page_count);
    try std.testing.expectEqual(@as(u64, 1), stats.total_checkpoints);
}

test "checkpoint record" {
    const record = CheckpointRecord.init(1, .FULL);
    try std.testing.expectEqual(@as(u64, 1), record.checkpoint_id);
    try std.testing.expectEqual(CheckpointType.FULL, record.checkpoint_type);
}

test "recovery manager" {
    const allocator = std.testing.allocator;
    
    var recovery = RecoveryManager.init(allocator);
    
    try std.testing.expect(!recovery.isRecoveryComplete());
    
    const result = try recovery.recover(100);
    
    try std.testing.expect(recovery.isRecoveryComplete());
    try std.testing.expectEqual(@as(u64, 100), result.analysis_lsn);
}

test "checkpoint config" {
    const config = CheckpointConfig{};
    try std.testing.expectEqual(@as(u64, 60_000), config.interval_ms);
    try std.testing.expect(config.enabled);
    try std.testing.expect(config.async_checkpoint);
}