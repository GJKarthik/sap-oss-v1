//! Page Manager - Page Allocation and Management
//!
//! Converted from: kuzu/src/storage/page_manager.cpp
//!
//! Purpose:
//! Manages page allocation, deallocation, and tracking within the database file.
//! Handles free page lists, page versioning for MVCC, and checkpoint coordination.
//!
//! Architecture:
//! ```
//! PageManager
//!   ├── file_handle: *FileHandle
//!   ├── num_pages: u64
//!   ├── free_pages: ArrayList(PageIdx)
//!   ├── pending_free: ArrayList(PageIdx)    // Pages to free on checkpoint
//!   ├── allocated_pages: HashSet(PageIdx)   // Currently allocated
//!   └── mutex: Mutex
//! ```

const std = @import("std");
const common = @import("../common/common.zig");
const file_handle = @import("file_handle.zig");

const PageIdx = common.PageIdx;
const INVALID_PAGE_IDX = common.INVALID_PAGE_IDX;
const StorageConstants = common.StorageConstants;

/// Page state for tracking
pub const PageState = enum {
    FREE,
    ALLOCATED,
    DIRTY,
    PENDING_FREE,
};

/// Page metadata
pub const PageMetadata = struct {
    page_idx: PageIdx,
    state: PageState,
    version: u64,
    last_modified: i64,
    
    pub fn init(page_idx: PageIdx) PageMetadata {
        return .{
            .page_idx = page_idx,
            .state = .FREE,
            .version = 0,
            .last_modified = 0,
        };
    }
};

/// Page Manager - Manages page allocation within a file
pub const PageManager = struct {
    allocator: std.mem.Allocator,
    
    /// File handle for the data file
    fh: *file_handle.FileHandle,
    
    /// Total number of pages in the file
    num_pages: u64,
    
    /// List of free pages available for allocation
    free_pages: std.ArrayList(PageIdx),
    
    /// Pages pending to be freed on next checkpoint
    pending_free: std.ArrayList(PageIdx),
    
    /// Set of currently allocated pages
    allocated_pages: std.AutoHashMap(PageIdx, PageMetadata),
    
    /// Current version number (incremented on checkpoint)
    current_version: u64,
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    /// Create a new page manager
    pub fn create(allocator: std.mem.Allocator, fh: *file_handle.FileHandle) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .fh = fh,
            .num_pages = fh.getNumPages(),
            .free_pages = .empty,
            .pending_free = .empty,
            .allocated_pages = std.AutoHashMap(PageIdx, PageMetadata).init(allocator),
            .current_version = 0,
            .mutex = .{},
        };
        return self;
    }
    
    /// Allocate a new page
    pub fn allocatePage(self: *Self) !PageIdx {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var page_idx: PageIdx = undefined;
        
        // Try to reuse a free page first
        if (self.free_pages.items.len > 0) {
            page_idx = self.free_pages.items[self.free_pages.items.len - 1];
            self.free_pages.items.len -= 1;
        } else {
            // Allocate a new page at the end of the file
            page_idx = self.num_pages;
            self.num_pages += 1;
            
            // Extend the file
            try self.fh.extend(self.num_pages * StorageConstants.PAGE_SIZE);
        }
        
        // Track the allocated page
        try self.allocated_pages.put(page_idx, PageMetadata{
            .page_idx = page_idx,
            .state = .ALLOCATED,
            .version = self.current_version,
            .last_modified = std.time.timestamp(),
        });
        
        return page_idx;
    }
    
    /// Allocate multiple pages
    pub fn allocatePages(self: *Self, count: usize) ![]PageIdx {
        const pages = try self.allocator.alloc(PageIdx, count);
        errdefer self.allocator.free(pages);
        
        for (pages, 0..) |*page, i| {
            page.* = try self.allocatePage();
            errdefer {
                // Free already allocated pages on error
                for (pages[0..i]) |p| {
                    self.freePage(p);
                }
            }
        }
        
        return pages;
    }
    
    /// Free a page (marks for freeing on next checkpoint)
    pub fn freePage(self: *Self, page_idx: PageIdx) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.allocated_pages.getPtr(page_idx)) |metadata| {
            metadata.state = .PENDING_FREE;
            self.pending_free.append(self.allocator, page_idx) catch {};
        }
    }
    
    /// Free multiple pages
    pub fn freePages(self: *Self, pages: []const PageIdx) void {
        for (pages) |page_idx| {
            self.freePage(page_idx);
        }
    }
    
    /// Check if a page is allocated
    pub fn isAllocated(self: *Self, page_idx: PageIdx) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.allocated_pages.get(page_idx)) |metadata| {
            return metadata.state == .ALLOCATED or metadata.state == .DIRTY;
        }
        return false;
    }
    
    /// Mark a page as dirty
    pub fn markDirty(self: *Self, page_idx: PageIdx) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.allocated_pages.getPtr(page_idx)) |metadata| {
            if (metadata.state == .ALLOCATED) {
                metadata.state = .DIRTY;
                metadata.last_modified = std.time.timestamp();
            }
        }
    }
    
    /// Get page metadata
    pub fn getPageMetadata(self: *Self, page_idx: PageIdx) ?PageMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.allocated_pages.get(page_idx);
    }
    
    /// Finalize checkpoint - commit pending frees
    pub fn finalizeCheckpoint(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Move pending free pages to the free list
        for (self.pending_free.items) |page_idx| {
            _ = self.allocated_pages.remove(page_idx);
            try self.free_pages.append(self.allocator, page_idx);
        }
        self.pending_free.clearRetainingCapacity();
        
        // Clear dirty flags
        var iter = self.allocated_pages.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.state == .DIRTY) {
                entry.value_ptr.state = .ALLOCATED;
            }
        }
        
        // Increment version
        self.current_version += 1;
    }
    
    /// Rollback checkpoint - restore pending frees
    pub fn rollbackCheckpoint(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Restore pending free pages to allocated state
        for (self.pending_free.items) |page_idx| {
            if (self.allocated_pages.getPtr(page_idx)) |metadata| {
                metadata.state = .ALLOCATED;
            }
        }
        self.pending_free.clearRetainingCapacity();
    }
    
    /// Get statistics
    pub fn getStats(self: *Self) PageManagerStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var num_allocated: u64 = 0;
        var num_dirty: u64 = 0;
        var num_pending_free: u64 = 0;
        
        var iter = self.allocated_pages.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.state) {
                .ALLOCATED => num_allocated += 1,
                .DIRTY => {
                    num_allocated += 1;
                    num_dirty += 1;
                },
                .PENDING_FREE => num_pending_free += 1,
                .FREE => {},
            }
        }
        
        return .{
            .total_pages = self.num_pages,
            .free_pages = @intCast(self.free_pages.items.len),
            .allocated_pages = num_allocated,
            .dirty_pages = num_dirty,
            .pending_free_pages = num_pending_free,
            .current_version = self.current_version,
        };
    }
    
    /// Get number of pages
    pub fn getNumPages(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.num_pages;
    }
    
    /// Destroy the page manager
    pub fn destroy(self: *Self) void {
        self.free_pages.deinit(self.allocator);
        self.pending_free.deinit(self.allocator);
        self.allocated_pages.deinit();
        self.allocator.destroy(self);
    }
};

/// Page manager statistics
pub const PageManagerStats = struct {
    total_pages: u64,
    free_pages: u64,
    allocated_pages: u64,
    dirty_pages: u64,
    pending_free_pages: u64,
    current_version: u64,
};

// ============================================================================
// Tests
// ============================================================================

test "page manager allocation" {
    const allocator = std.testing.allocator;
    
    // Create a mock file handle
    var fh = try file_handle.FileHandle.createInMemory(allocator);
    defer {
        fh.close();
        allocator.destroy(fh);
    }
    
    const pm = try PageManager.create(allocator, fh);
    defer pm.destroy();
    
    // Allocate pages
    const page1 = try pm.allocatePage();
    const page2 = try pm.allocatePage();
    const page3 = try pm.allocatePage();
    
    try std.testing.expect(pm.isAllocated(page1));
    try std.testing.expect(pm.isAllocated(page2));
    try std.testing.expect(pm.isAllocated(page3));
    
    // Free a page
    pm.freePage(page2);
    
    // Finalize checkpoint
    try pm.finalizeCheckpoint();
    
    // Page 2 should now be free
    try std.testing.expect(!pm.isAllocated(page2));
    
    // Allocate again - should reuse page 2
    const page4 = try pm.allocatePage();
    try std.testing.expectEqual(page2, page4);
}

test "page manager stats" {
    const allocator = std.testing.allocator;
    
    var fh = try file_handle.FileHandle.createInMemory(allocator);
    defer {
        fh.close();
        allocator.destroy(fh);
    }
    
    const pm = try PageManager.create(allocator, fh);
    defer pm.destroy();
    
    // Allocate some pages
    _ = try pm.allocatePage();
    _ = try pm.allocatePage();
    const page3 = try pm.allocatePage();
    
    // Mark one as dirty
    pm.markDirty(page3);
    
    const stats = pm.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.total_pages);
    try std.testing.expectEqual(@as(u64, 3), stats.allocated_pages);
    try std.testing.expectEqual(@as(u64, 1), stats.dirty_pages);
}