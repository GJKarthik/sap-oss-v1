//! Buffer Pool - Page buffer management
//!
//! Purpose:
//! Manages a pool of memory pages with LRU eviction,
//! pin/unpin semantics, and dirty page tracking.

const std = @import("std");

// ============================================================================
// Page State
// ============================================================================

pub const PageState = enum(u8) {
    INVALID,
    CLEAN,
    DIRTY,
    EVICTING,
};

// ============================================================================
// Buffer Frame
// ============================================================================

pub const BufferFrame = struct {
    page_id: u64 = std.math.maxInt(u64),
    file_id: u32 = 0,
    frame_id: u32,
    state: PageState = .INVALID,
    pin_count: u32 = 0,
    dirty: bool = false,
    data: []u8,
    
    // LRU tracking
    access_count: u64 = 0,
    last_access: i64 = 0,
    
    pub fn init(frame_id: u32, data: []u8) BufferFrame {
        return .{
            .frame_id = frame_id,
            .data = data,
        };
    }
    
    pub fn pin(self: *BufferFrame) void {
        self.pin_count += 1;
        self.access_count += 1;
        self.last_access = std.time.timestamp();
    }
    
    pub fn unpin(self: *BufferFrame) void {
        if (self.pin_count > 0) {
            self.pin_count -= 1;
        }
    }
    
    pub fn markDirty(self: *BufferFrame) void {
        self.dirty = true;
        self.state = .DIRTY;
    }
    
    pub fn isPinned(self: *const BufferFrame) bool {
        return self.pin_count > 0;
    }
    
    pub fn isDirty(self: *const BufferFrame) bool {
        return self.dirty;
    }
    
    pub fn reset(self: *BufferFrame) void {
        self.page_id = std.math.maxInt(u64);
        self.file_id = 0;
        self.state = .INVALID;
        self.pin_count = 0;
        self.dirty = false;
        self.access_count = 0;
        @memset(self.data, 0);
    }
};

// ============================================================================
// Page Handle
// ============================================================================

pub const PageHandle = struct {
    frame: *BufferFrame,
    pool: *BufferPool,
    valid: bool = true,
    
    pub fn getData(self: *const PageHandle) []u8 {
        return self.frame.data;
    }
    
    pub fn getPageId(self: *const PageHandle) u64 {
        return self.frame.page_id;
    }
    
    pub fn markDirty(self: *PageHandle) void {
        self.frame.markDirty();
    }
    
    pub fn release(self: *PageHandle) void {
        if (self.valid) {
            self.pool.unpinPage(self.frame.page_id);
            self.valid = false;
        }
    }
};

// ============================================================================
// Buffer Pool
// ============================================================================

pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    page_size: usize,
    num_frames: usize,
    
    // Frame storage
    frames: []BufferFrame,
    page_data: []u8,
    
    // Page mapping
    page_table: std.AutoHashMap(u64, u32),
    
    // Free list
    free_frames: std.ArrayList(u32),
    
    // Statistics
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, page_size: usize, num_frames: usize) !BufferPool {
        // Allocate page data
        const total_size = page_size * num_frames;
        const page_data = try allocator.alloc(u8, total_size);
        @memset(page_data, 0);
        
        // Create frames
        var frames = try allocator.alloc(BufferFrame, num_frames);
        for (frames, 0..) |*frame, i| {
            const start = i * page_size;
            const end = start + page_size;
            frame.* = BufferFrame.init(@intCast(i), page_data[start..end]);
        }
        
        // Initialize free list
        var free_frames = std.ArrayList(u32).init(allocator);
        var i: u32 = 0;
        while (i < num_frames) : (i += 1) {
            try free_frames.append(i);
        }
        
        return .{
            .allocator = allocator,
            .page_size = page_size,
            .num_frames = num_frames,
            .frames = frames,
            .page_data = page_data,
            .page_table = std.AutoHashMap(u64, u32).init(allocator),
            .free_frames = free_frames,
        };
    }
    
    pub fn deinit(self: *BufferPool) void {
        self.allocator.free(self.frames);
        self.allocator.free(self.page_data);
        self.page_table.deinit();
        self.free_frames.deinit();
    }
    
    /// Pin a page in the buffer pool
    pub fn pinPage(self: *BufferPool, page_id: u64) !PageHandle {
        // Check if page is already in pool
        if (self.page_table.get(page_id)) |frame_id| {
            self.hits += 1;
            var frame = &self.frames[frame_id];
            frame.pin();
            return PageHandle{ .frame = frame, .pool = self };
        }
        
        self.misses += 1;
        
        // Need to load page - get a free frame
        const frame_id = try self.getVictimFrame();
        var frame = &self.frames[frame_id];
        
        // If frame has a page, remove from page table
        if (frame.state != .INVALID) {
            _ = self.page_table.remove(frame.page_id);
        }
        
        // Initialize frame for new page
        frame.reset();
        frame.page_id = page_id;
        frame.state = .CLEAN;
        frame.pin();
        
        try self.page_table.put(page_id, frame_id);
        
        return PageHandle{ .frame = frame, .pool = self };
    }
    
    /// Unpin a page
    pub fn unpinPage(self: *BufferPool, page_id: u64) void {
        if (self.page_table.get(page_id)) |frame_id| {
            self.frames[frame_id].unpin();
        }
    }
    
    /// Flush a specific page
    pub fn flushPage(self: *BufferPool, page_id: u64) !void {
        if (self.page_table.get(page_id)) |frame_id| {
            var frame = &self.frames[frame_id];
            if (frame.dirty) {
                // In real impl: write to disk
                frame.dirty = false;
                frame.state = .CLEAN;
            }
        }
    }
    
    /// Flush all dirty pages
    pub fn flushAll(self: *BufferPool) !void {
        for (self.frames) |*frame| {
            if (frame.dirty) {
                // In real impl: write to disk
                frame.dirty = false;
                frame.state = .CLEAN;
            }
        }
    }
    
    /// Get a victim frame using LRU policy
    fn getVictimFrame(self: *BufferPool) !u32 {
        // First try free list
        if (self.free_frames.items.len > 0) {
            return self.free_frames.pop();
        }
        
        // Find unpinned frame with oldest access
        var victim: ?u32 = null;
        var oldest_access: i64 = std.math.maxInt(i64);
        
        for (self.frames, 0..) |*frame, i| {
            if (!frame.isPinned() and frame.last_access < oldest_access) {
                oldest_access = frame.last_access;
                victim = @intCast(i);
            }
        }
        
        if (victim) |v| {
            // Flush if dirty
            if (self.frames[v].dirty) {
                try self.flushPage(self.frames[v].page_id);
            }
            self.evictions += 1;
            return v;
        }
        
        return error.NoAvailableFrame;
    }
    
    /// Get buffer pool statistics
    pub fn getStats(self: *const BufferPool) BufferPoolStats {
        var pinned: usize = 0;
        var dirty: usize = 0;
        
        for (self.frames) |frame| {
            if (frame.isPinned()) pinned += 1;
            if (frame.isDirty()) dirty += 1;
        }
        
        return .{
            .total_frames = self.num_frames,
            .used_frames = self.page_table.count(),
            .pinned_frames = pinned,
            .dirty_frames = dirty,
            .hits = self.hits,
            .misses = self.misses,
            .evictions = self.evictions,
            .hit_rate = if (self.hits + self.misses > 0)
                @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(self.hits + self.misses))
            else
                0,
        };
    }
};

pub const BufferPoolStats = struct {
    total_frames: usize,
    used_frames: usize,
    pinned_frames: usize,
    dirty_frames: usize,
    hits: u64,
    misses: u64,
    evictions: u64,
    hit_rate: f64,
};

// ============================================================================
// Tests
// ============================================================================

test "buffer frame" {
    var data: [4096]u8 = undefined;
    var frame = BufferFrame.init(0, &data);
    
    try std.testing.expect(!frame.isPinned());
    
    frame.pin();
    try std.testing.expect(frame.isPinned());
    try std.testing.expectEqual(@as(u32, 1), frame.pin_count);
    
    frame.unpin();
    try std.testing.expect(!frame.isPinned());
}

test "buffer pool init" {
    const allocator = std.testing.allocator;
    
    var pool = try BufferPool.init(allocator, 4096, 10);
    defer pool.deinit();
    
    try std.testing.expectEqual(@as(usize, 10), pool.num_frames);
    try std.testing.expectEqual(@as(usize, 4096), pool.page_size);
}

test "buffer pool pin unpin" {
    const allocator = std.testing.allocator;
    
    var pool = try BufferPool.init(allocator, 4096, 10);
    defer pool.deinit();
    
    var handle = try pool.pinPage(100);
    try std.testing.expectEqual(@as(u64, 100), handle.getPageId());
    
    handle.release();
    
    // Pin same page again - should hit
    var handle2 = try pool.pinPage(100);
    handle2.release();
    
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
}

test "buffer pool dirty page" {
    const allocator = std.testing.allocator;
    
    var pool = try BufferPool.init(allocator, 4096, 10);
    defer pool.deinit();
    
    var handle = try pool.pinPage(100);
    handle.markDirty();
    
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.dirty_frames);
    
    handle.release();
}

test "buffer pool eviction" {
    const allocator = std.testing.allocator;
    
    var pool = try BufferPool.init(allocator, 4096, 3);
    defer pool.deinit();
    
    // Fill pool
    var h1 = try pool.pinPage(1);
    h1.release();
    var h2 = try pool.pinPage(2);
    h2.release();
    var h3 = try pool.pinPage(3);
    h3.release();
    
    // This should trigger eviction
    var h4 = try pool.pinPage(4);
    h4.release();
    
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.evictions);
}