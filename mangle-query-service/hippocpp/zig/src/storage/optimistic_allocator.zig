//! Optimistic Allocator - Lock-Free Page Allocation
//!
//! Converted from: kuzu/src/storage/optimistic_allocator.cpp
//!
//! Purpose:
//! Provides optimistic (lock-free) page allocation for concurrent
//! transactions. Uses compare-and-swap for thread-safe allocation.

const std = @import("std");
const common = @import("../common/common.zig");

const PageIdx = common.PageIdx;

/// Allocation state
pub const AllocationState = enum {
    FREE,
    ALLOCATED,
    PENDING,
    COMMITTED,
};

/// Allocation entry
pub const AllocationEntry = struct {
    page_idx: PageIdx,
    state: std.atomic.Value(u32),
    txn_id: u64,
    version: u64,
    
    pub fn init(page_idx: PageIdx) AllocationEntry {
        return .{
            .page_idx = page_idx,
            .state = std.atomic.Value(u32).init(@intFromEnum(AllocationState.FREE)),
            .txn_id = 0,
            .version = 0,
        };
    }
    
    pub fn getState(self: *const AllocationEntry) AllocationState {
        return @enumFromInt(self.state.load(.acquire));
    }
    
    pub fn tryAllocate(self: *AllocationEntry, txn_id: u64) bool {
        const free: u32 = @intFromEnum(AllocationState.FREE);
        const pending: u32 = @intFromEnum(AllocationState.PENDING);
        
        const result = self.state.cmpxchgStrong(free, pending, .acq_rel, .acquire);
        if (result == null) {
            self.txn_id = txn_id;
            return true;
        }
        return false;
    }
    
    pub fn commit(self: *AllocationEntry) void {
        self.state.store(@intFromEnum(AllocationState.COMMITTED), .release);
        self.version += 1;
    }
    
    pub fn free(self: *AllocationEntry) void {
        self.state.store(@intFromEnum(AllocationState.FREE), .release);
        self.txn_id = 0;
    }
};

/// Free list entry
pub const FreeListEntry = struct {
    page_idx: PageIdx,
    next: ?*FreeListEntry,
};

/// Lock-free free list
pub const LockFreeFreeList = struct {
    head: std.atomic.Value(?*FreeListEntry),
    allocator: std.mem.Allocator,
    size: std.atomic.Value(u64),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .head = std.atomic.Value(?*FreeListEntry).init(null),
            .allocator = allocator,
            .size = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Free all entries
        var current = self.head.load(.acquire);
        while (current) |entry| {
            const next = entry.next;
            self.allocator.destroy(entry);
            current = next;
        }
    }
    
    /// Push a page to the free list
    pub fn push(self: *Self, page_idx: PageIdx) !void {
        const entry = try self.allocator.create(FreeListEntry);
        entry.page_idx = page_idx;
        
        while (true) {
            const old_head = self.head.load(.acquire);
            entry.next = old_head;
            
            const result = self.head.cmpxchgWeak(old_head, entry, .acq_rel, .acquire);
            if (result == null) {
                _ = self.size.fetchAdd(1, .release);
                return;
            }
        }
    }
    
    /// Pop a page from the free list
    pub fn pop(self: *Self) ?PageIdx {
        while (true) {
            const old_head = self.head.load(.acquire) orelse return null;
            const new_head = old_head.next;
            
            const result = self.head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire);
            if (result == null) {
                const page_idx = old_head.page_idx;
                self.allocator.destroy(old_head);
                _ = self.size.fetchSub(1, .release);
                return page_idx;
            }
        }
    }
    
    /// Get size
    pub fn getSize(self: *const Self) u64 {
        return self.size.load(.acquire);
    }
    
    /// Check if empty
    pub fn isEmpty(self: *const Self) bool {
        return self.head.load(.acquire) == null;
    }
};

/// Optimistic allocator
pub const OptimisticAllocator = struct {
    allocator: std.mem.Allocator,
    free_list: LockFreeFreeList,
    next_page_idx: std.atomic.Value(PageIdx),
    max_pages: PageIdx,
    allocations: std.ArrayList(AllocationEntry),
    total_allocated: std.atomic.Value(u64),
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, max_pages: PageIdx) Self {
        return .{
            .allocator = allocator,
            .free_list = LockFreeFreeList.init(allocator),
            .next_page_idx = std.atomic.Value(PageIdx).init(0),
            .max_pages = max_pages,
            .allocations = std.ArrayList(AllocationEntry).init(allocator),
            .total_allocated = std.atomic.Value(u64).init(0),
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.free_list.deinit();
        self.allocations.deinit();
    }
    
    /// Allocate a page optimistically
    pub fn allocate(self: *Self, txn_id: u64) !PageIdx {
        // Try to get from free list first
        if (self.free_list.pop()) |page_idx| {
            _ = self.total_allocated.fetchAdd(1, .release);
            _ = txn_id;
            return page_idx;
        }
        
        // Allocate new page
        while (true) {
            const current = self.next_page_idx.load(.acquire);
            if (current >= self.max_pages) {
                return error.OutOfPages;
            }
            
            const result = self.next_page_idx.cmpxchgWeak(current, current + 1, .acq_rel, .acquire);
            if (result == null) {
                _ = self.total_allocated.fetchAdd(1, .release);
                return current;
            }
        }
    }
    
    /// Free a page
    pub fn freePage(self: *Self, page_idx: PageIdx) !void {
        try self.free_list.push(page_idx);
        _ = self.total_allocated.fetchSub(1, .release);
    }
    
    /// Get number of allocated pages
    pub fn getNumAllocated(self: *const Self) u64 {
        return self.total_allocated.load(.acquire);
    }
    
    /// Get number of free pages in list
    pub fn getNumFree(self: *const Self) u64 {
        return self.free_list.getSize();
    }
    
    /// Get next page index
    pub fn getNextPageIdx(self: *const Self) PageIdx {
        return self.next_page_idx.load(.acquire);
    }
    
    /// Reserve a range of pages
    pub fn reserveRange(self: *Self, num_pages: u32, txn_id: u64) !PageIdx {
        _ = txn_id;
        
        while (true) {
            const current = self.next_page_idx.load(.acquire);
            const new_idx = current + num_pages;
            
            if (new_idx > self.max_pages) {
                return error.OutOfPages;
            }
            
            const result = self.next_page_idx.cmpxchgWeak(current, new_idx, .acq_rel, .acquire);
            if (result == null) {
                _ = self.total_allocated.fetchAdd(num_pages, .release);
                return current;
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "allocation entry" {
    var entry = AllocationEntry.init(100);
    
    try std.testing.expectEqual(AllocationState.FREE, entry.getState());
    
    try std.testing.expect(entry.tryAllocate(1));
    try std.testing.expectEqual(@as(u64, 1), entry.txn_id);
    
    entry.commit();
    try std.testing.expectEqual(AllocationState.COMMITTED, entry.getState());
    
    entry.free();
    try std.testing.expectEqual(AllocationState.FREE, entry.getState());
}

test "lock free free list" {
    const allocator = std.testing.allocator;
    
    var list = LockFreeFreeList.init(allocator);
    defer list.deinit();
    
    try std.testing.expect(list.isEmpty());
    
    try list.push(10);
    try list.push(20);
    
    try std.testing.expectEqual(@as(u64, 2), list.getSize());
    
    const p1 = list.pop();
    try std.testing.expect(p1 != null);
    
    const p2 = list.pop();
    try std.testing.expect(p2 != null);
    
    const p3 = list.pop();
    try std.testing.expect(p3 == null);
}

test "optimistic allocator" {
    const allocator = std.testing.allocator;
    
    var oa = OptimisticAllocator.init(allocator, 1000);
    defer oa.deinit();
    
    // Allocate pages
    const p1 = try oa.allocate(1);
    const p2 = try oa.allocate(1);
    
    try std.testing.expectEqual(@as(PageIdx, 0), p1);
    try std.testing.expectEqual(@as(PageIdx, 1), p2);
    try std.testing.expectEqual(@as(u64, 2), oa.getNumAllocated());
    
    // Free a page
    try oa.freePage(p1);
    try std.testing.expectEqual(@as(u64, 1), oa.getNumAllocated());
    
    // Next allocation should reuse freed page
    const p3 = try oa.allocate(1);
    try std.testing.expectEqual(@as(PageIdx, 0), p3);
}

test "reserve range" {
    const allocator = std.testing.allocator;
    
    var oa = OptimisticAllocator.init(allocator, 1000);
    defer oa.deinit();
    
    const start = try oa.reserveRange(10, 1);
    try std.testing.expectEqual(@as(PageIdx, 0), start);
    try std.testing.expectEqual(@as(u64, 10), oa.getNumAllocated());
    try std.testing.expectEqual(@as(PageIdx, 10), oa.getNextPageIdx());
}