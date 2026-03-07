//! Free Space Manager - Space Reclamation
//!
//! Converted from: kuzu/src/storage/free_space_manager.cpp
//!
//! Purpose:
//! Tracks and manages free space within database files.
//! Enables efficient space reuse after deletions.

const std = @import("std");
const common = @import("../common/common.zig");

const PageIdx = common.PageIdx;
const INVALID_PAGE_IDX = common.INVALID_PAGE_IDX;
const KUZU_PAGE_SIZE = common.KUZU_PAGE_SIZE;

/// Free page entry
pub const FreePageEntry = struct {
    page_idx: PageIdx,
    size_class: u8,  // For variable-size allocations
    freed_at_checkpoint: u64,
};

/// Free space manager
pub const FreeSpaceManager = struct {
    allocator: std.mem.Allocator,
    
    /// Free pages available for reuse
    free_pages: std.ArrayList(FreePageEntry),
    
    /// Pages freed in current transaction (not yet committed)
    pending_free: std.ArrayList(FreePageEntry),
    
    /// Current checkpoint ID
    checkpoint_id: u64,
    
    /// Statistics
    total_free_pages: usize,
    total_reclaimed: usize,
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .free_pages = std.ArrayList(FreePageEntry).init(allocator),
            .pending_free = std.ArrayList(FreePageEntry).init(allocator),
            .checkpoint_id = 0,
            .total_free_pages = 0,
            .total_reclaimed = 0,
            .mutex = .{},
        };
    }
    
    /// Mark a page as free (pending until checkpoint)
    pub fn freePage(self: *Self, page_idx: PageIdx) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.pending_free.append(.{
            .page_idx = page_idx,
            .size_class = 0,
            .freed_at_checkpoint = self.checkpoint_id,
        });
    }
    
    /// Allocate a free page (returns INVALID_PAGE_IDX if none available)
    pub fn allocatePage(self: *Self) PageIdx {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.free_pages.items.len > 0) {
            const entry = self.free_pages.pop();
            self.total_reclaimed += 1;
            return entry.page_idx;
        }
        return INVALID_PAGE_IDX;
    }
    
    /// Commit pending frees (called at checkpoint)
    pub fn commitCheckpoint(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Move pending frees to available free list
        for (self.pending_free.items) |entry| {
            try self.free_pages.append(entry);
        }
        self.total_free_pages += self.pending_free.items.len;
        self.pending_free.clearRetainingCapacity();
        self.checkpoint_id += 1;
    }
    
    /// Rollback pending frees (called on transaction abort)
    pub fn rollback(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.pending_free.clearRetainingCapacity();
    }
    
    /// Get statistics
    pub fn getStats(self: *Self) struct { free: usize, pending: usize, reclaimed: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return .{
            .free = self.free_pages.items.len,
            .pending = self.pending_free.items.len,
            .reclaimed = self.total_reclaimed,
        };
    }
    
    /// Check if we have free pages available
    pub fn hasFreePages(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.free_pages.items.len > 0;
    }
    
    pub fn deinit(self: *Self) void {
        self.free_pages.deinit();
        self.pending_free.deinit();
    }
};

// Tests
test "free space manager basic operations" {
    const allocator = std.testing.allocator;
    
    var fsm = FreeSpaceManager.init(allocator);
    defer fsm.deinit();
    
    // Free some pages
    try fsm.freePage(10);
    try fsm.freePage(20);
    try fsm.freePage(30);
    
    // Pages are pending until checkpoint
    try std.testing.expect(!fsm.hasFreePages());
    
    // Commit checkpoint
    try fsm.commitCheckpoint();
    
    // Now pages are available
    try std.testing.expect(fsm.hasFreePages());
    
    // Allocate a page
    const page = fsm.allocatePage();
    try std.testing.expect(page != INVALID_PAGE_IDX);
}