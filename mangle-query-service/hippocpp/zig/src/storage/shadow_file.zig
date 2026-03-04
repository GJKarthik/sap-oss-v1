//! Shadow File - Atomic Page Updates
//!
//! Converted from: kuzu/src/storage/shadow_file.cpp
//!
//! Purpose:
//! Provides atomic page updates using shadow paging technique.
//! Maintains a shadow copy of dirty pages that can be either committed
//! or rolled back atomically.
//!
//! Architecture:
//! ```
//! ShadowFile
//!   ├── original_pages: HashMap(PageIdx, ShadowPage)
//!   ├── shadow_pages: HashMap(PageIdx, ShadowPage)
//!   └── dirty_pages: HashSet(PageIdx)
//! ```

const std = @import("std");
const common = @import("../common/common.zig");
const file_handle = @import("file_handle.zig");

const PageIdx = common.PageIdx;
const StorageConstants = common.StorageConstants;
const KUZU_PAGE_SIZE = common.KUZU_PAGE_SIZE;

/// Shadow page state
pub const ShadowPageState = enum {
    CLEAN,
    DIRTY,
    COMMITTED,
};

/// Shadow page entry
pub const ShadowPage = struct {
    page_idx: PageIdx,
    state: ShadowPageState,
    original_data: ?[]u8,
    shadow_data: []u8,
    
    pub fn init(allocator: std.mem.Allocator, page_idx: PageIdx) !ShadowPage {
        const shadow_data = try allocator.alloc(u8, KUZU_PAGE_SIZE);
        @memset(shadow_data, 0);
        
        return .{
            .page_idx = page_idx,
            .state = .CLEAN,
            .original_data = null,
            .shadow_data = shadow_data,
        };
    }
    
    pub fn deinit(self: *ShadowPage, allocator: std.mem.Allocator) void {
        if (self.original_data) |data| {
            allocator.free(data);
        }
        allocator.free(self.shadow_data);
    }
};

/// Shadow File - Manages shadow pages for atomic updates
pub const ShadowFile = struct {
    allocator: std.mem.Allocator,
    
    /// File handle for the main data file
    data_fh: ?*file_handle.FileHandle,
    
    /// Shadow pages indexed by page index
    shadow_pages: std.AutoHashMap(PageIdx, ShadowPage),
    
    /// Set of dirty page indices
    dirty_pages: std.AutoHashMap(PageIdx, void),
    
    /// Path to shadow file (for persistent mode)
    shadow_path: []const u8,
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    /// Create a new shadow file
    pub fn create(allocator: std.mem.Allocator, data_fh: ?*file_handle.FileHandle, path: []const u8) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .data_fh = data_fh,
            .shadow_pages = std.AutoHashMap(PageIdx, ShadowPage).init(allocator),
            .dirty_pages = std.AutoHashMap(PageIdx, void).init(allocator),
            .shadow_path = try allocator.dupe(u8, path),
            .mutex = .{},
        };
        return self;
    }
    
    /// Get or create a shadow page for writing
    pub fn getShadowPage(self: *Self, page_idx: PageIdx) !*ShadowPage {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if shadow page already exists
        if (self.shadow_pages.getPtr(page_idx)) |page| {
            return page;
        }
        
        // Create new shadow page
        var shadow_page = try ShadowPage.init(self.allocator, page_idx);
        
        // Copy original data from main file if it exists
        if (self.data_fh) |fh| {
            if (page_idx < fh.getNumPages()) {
                shadow_page.original_data = try self.allocator.alloc(u8, KUZU_PAGE_SIZE);
                try fh.readPage(page_idx, shadow_page.original_data.?);
                @memcpy(shadow_page.shadow_data, shadow_page.original_data.?);
            }
        }
        
        try self.shadow_pages.put(page_idx, shadow_page);
        return self.shadow_pages.getPtr(page_idx).?;
    }
    
    /// Read from shadow page (or original if not shadowed)
    pub fn readPage(self: *Self, page_idx: PageIdx, buffer: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (buffer.len != KUZU_PAGE_SIZE) return error.InvalidBufferSize;
        
        // Check shadow first
        if (self.shadow_pages.get(page_idx)) |page| {
            @memcpy(buffer, page.shadow_data);
            return;
        }
        
        // Fall back to main file
        if (self.data_fh) |fh| {
            try fh.readPage(page_idx, buffer);
        } else {
            @memset(buffer, 0);
        }
    }
    
    /// Write to shadow page
    pub fn writePage(self: *Self, page_idx: PageIdx, buffer: []const u8) !void {
        if (buffer.len != KUZU_PAGE_SIZE) return error.InvalidBufferSize;
        
        const page = try self.getShadowPage(page_idx);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        @memcpy(page.shadow_data, buffer);
        page.state = .DIRTY;
        try self.dirty_pages.put(page_idx, {});
    }
    
    /// Commit all shadow pages to the main file
    pub fn commit(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.data_fh == null) return;
        
        // Write all dirty pages to main file
        var iter = self.dirty_pages.iterator();
        while (iter.next()) |entry| {
            const page_idx = entry.key_ptr.*;
            if (self.shadow_pages.getPtr(page_idx)) |page| {
                try self.data_fh.?.writePage(page_idx, page.shadow_data);
                page.state = .COMMITTED;
                
                // Update original data to match
                if (page.original_data) |orig| {
                    @memcpy(orig, page.shadow_data);
                }
            }
        }
        
        // Sync to disk
        try self.data_fh.?.sync();
        
        // Clear dirty set
        self.dirty_pages.clearRetainingCapacity();
    }
    
    /// Rollback all shadow pages to their original state
    pub fn rollback(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Restore original data to shadow pages
        var iter = self.dirty_pages.iterator();
        while (iter.next()) |entry| {
            const page_idx = entry.key_ptr.*;
            if (self.shadow_pages.getPtr(page_idx)) |page| {
                if (page.original_data) |orig| {
                    @memcpy(page.shadow_data, orig);
                } else {
                    @memset(page.shadow_data, 0);
                }
                page.state = .CLEAN;
            }
        }
        
        // Clear dirty set
        self.dirty_pages.clearRetainingCapacity();
    }
    
    /// Check if a page is dirty
    pub fn isDirty(self: *Self, page_idx: PageIdx) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dirty_pages.contains(page_idx);
    }
    
    /// Get number of dirty pages
    pub fn getNumDirtyPages(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dirty_pages.count();
    }
    
    /// Clear all shadow pages
    pub fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iter = self.shadow_pages.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.shadow_pages.clearRetainingCapacity();
        self.dirty_pages.clearRetainingCapacity();
    }
    
    /// Destroy the shadow file
    pub fn destroy(self: *Self) void {
        self.clear();
        self.shadow_pages.deinit();
        self.dirty_pages.deinit();
        
        if (self.shadow_path.len > 0) {
            self.allocator.free(self.shadow_path);
        }
        
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "shadow file basic operations" {
    const allocator = std.testing.allocator;
    
    // Create in-memory file handle
    const fh = try file_handle.FileHandle.createInMemory(allocator);
    defer {
        fh.close();
        allocator.destroy(fh);
    }
    
    // Write initial data to file
    var initial_data: [KUZU_PAGE_SIZE]u8 = undefined;
    @memset(&initial_data, 0xAA);
    try fh.writePage(0, &initial_data);
    
    // Create shadow file
    const shadow = try ShadowFile.create(allocator, fh, "");
    defer shadow.destroy();
    
    // Read through shadow (should get original)
    var read_buf: [KUZU_PAGE_SIZE]u8 = undefined;
    try shadow.readPage(0, &read_buf);
    try std.testing.expectEqualSlices(u8, &initial_data, &read_buf);
    
    // Write new data through shadow
    var new_data: [KUZU_PAGE_SIZE]u8 = undefined;
    @memset(&new_data, 0xBB);
    try shadow.writePage(0, &new_data);
    
    // Read through shadow (should get new data)
    try shadow.readPage(0, &read_buf);
    try std.testing.expectEqualSlices(u8, &new_data, &read_buf);
    
    // Original file should still have old data
    try fh.readPage(0, &read_buf);
    try std.testing.expectEqualSlices(u8, &initial_data, &read_buf);
}

test "shadow file commit" {
    const allocator = std.testing.allocator;
    
    const fh = try file_handle.FileHandle.createInMemory(allocator);
    defer {
        fh.close();
        allocator.destroy(fh);
    }
    
    var initial_data: [KUZU_PAGE_SIZE]u8 = undefined;
    @memset(&initial_data, 0xAA);
    try fh.writePage(0, &initial_data);
    
    const shadow = try ShadowFile.create(allocator, fh, "");
    defer shadow.destroy();
    
    // Write through shadow
    var new_data: [KUZU_PAGE_SIZE]u8 = undefined;
    @memset(&new_data, 0xBB);
    try shadow.writePage(0, &new_data);
    
    // Commit
    try shadow.commit();
    
    // Original file should now have new data
    var read_buf: [KUZU_PAGE_SIZE]u8 = undefined;
    try fh.readPage(0, &read_buf);
    try std.testing.expectEqualSlices(u8, &new_data, &read_buf);
}

test "shadow file rollback" {
    const allocator = std.testing.allocator;
    
    const fh = try file_handle.FileHandle.createInMemory(allocator);
    defer {
        fh.close();
        allocator.destroy(fh);
    }
    
    var initial_data: [KUZU_PAGE_SIZE]u8 = undefined;
    @memset(&initial_data, 0xAA);
    try fh.writePage(0, &initial_data);
    
    const shadow = try ShadowFile.create(allocator, fh, "");
    defer shadow.destroy();
    
    // Write through shadow
    var new_data: [KUZU_PAGE_SIZE]u8 = undefined;
    @memset(&new_data, 0xBB);
    try shadow.writePage(0, &new_data);
    
    // Rollback
    shadow.rollback();
    
    // Shadow should have original data again
    var read_buf: [KUZU_PAGE_SIZE]u8 = undefined;
    try shadow.readPage(0, &read_buf);
    try std.testing.expectEqualSlices(u8, &initial_data, &read_buf);
}