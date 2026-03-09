//! Buffer Manager - Memory Page Management
//!
//! Converted from: kuzu/src/storage/buffer_manager/buffer_manager.cpp
//!
//! Purpose:
//! Manages the buffer pool for caching database pages in memory.
//! Implements page pinning, eviction policies, and dirty page tracking.
//!
//! Architecture:
//! ```
//! BufferManager
//!   ├── buffer_pool: []BufferFrame
//!   ├── page_table: HashMap(PageKey, FrameIdx)
//!   ├── free_frames: ArrayList(FrameIdx)
//!   ├── eviction_policy: EvictionPolicy
//!   └── stats: BufferStats
//! ```

const std = @import("std");
const common = @import("common");

const PageIdx = common.PageIdx;
const INVALID_PAGE_IDX = common.INVALID_PAGE_IDX;
const StorageConstants = common.StorageConstants;
const KUZU_PAGE_SIZE = common.KUZU_PAGE_SIZE;

/// Frame index type
pub const FrameIdx = u32;
pub const INVALID_FRAME_IDX: FrameIdx = std.math.maxInt(FrameIdx);

/// Key for page table lookup
pub const PageKey = struct {
    file_id: u64,
    page_idx: PageIdx,
    
    pub fn hash(self: PageKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.file_id));
        h.update(std.mem.asBytes(&self.page_idx));
        return h.final();
    }
    
    pub fn eql(a: PageKey, b: PageKey) bool {
        return a.file_id == b.file_id and a.page_idx == b.page_idx;
    }
};

/// Frame state
pub const FrameState = enum {
    FREE,
    LOADING,
    LOADED,
    EVICTING,
};

/// Buffer frame - holds a cached page
pub const BufferFrame = struct {
    /// Frame index
    frame_idx: FrameIdx,
    
    /// Page key (file + page index)
    page_key: PageKey,
    
    /// Frame state
    state: FrameState,
    
    /// Pin count (0 = unpinned)
    pin_count: u32,
    
    /// Dirty flag
    dirty: bool,
    
    /// Access count for eviction
    access_count: u64,
    
    /// Last access timestamp
    last_access: i64,
    
    /// Page data
    data: []u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, frame_idx: FrameIdx) !Self {
        const data = try allocator.alloc(u8, KUZU_PAGE_SIZE);
        @memset(data, 0);
        
        return Self{
            .frame_idx = frame_idx,
            .page_key = .{ .file_id = 0, .page_idx = INVALID_PAGE_IDX },
            .state = .FREE,
            .pin_count = 0,
            .dirty = false,
            .access_count = 0,
            .last_access = 0,
            .data = data,
        };
    }
    
    pub fn reset(self: *Self) void {
        self.page_key = .{ .file_id = 0, .page_idx = INVALID_PAGE_IDX };
        self.state = .FREE;
        self.pin_count = 0;
        self.dirty = false;
        self.access_count = 0;
        self.last_access = 0;
        @memset(self.data, 0);
    }
    
    pub fn pin(self: *Self) void {
        self.pin_count += 1;
        self.access_count += 1;
        self.last_access = std.time.timestamp();
    }
    
    pub fn unpin(self: *Self) void {
        if (self.pin_count > 0) {
            self.pin_count -= 1;
        }
    }
    
    pub fn markDirty(self: *Self) void {
        self.dirty = true;
    }
    
    pub fn isPinned(self: *const Self) bool {
        return self.pin_count > 0;
    }
    
    pub fn isEvictable(self: *const Self) bool {
        return self.state == .LOADED and self.pin_count == 0;
    }
    
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Buffer pool statistics
pub const BufferStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    dirty_writes: u64 = 0,
    
    pub fn hitRate(self: *const BufferStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

/// Eviction policy type
pub const EvictionPolicy = enum {
    LRU,      // Least Recently Used
    CLOCK,    // Clock algorithm
    LRU_K,    // LRU-K
};

/// Buffer Manager - Central buffer pool management
pub const BufferManager = struct {
    allocator: std.mem.Allocator,
    
    /// Buffer pool capacity in bytes
    capacity: usize,
    
    /// Number of frames in the pool
    num_frames: usize,
    
    /// Buffer frames
    frames: []BufferFrame,
    
    /// Page table: maps page keys to frame indices
    page_table: std.HashMap(PageKey, FrameIdx, PageKeyContext, std.hash_map.default_max_load_percentage),
    
    /// Free frame list
    free_frames: std.ArrayList(FrameIdx),
    
    /// Eviction policy
    eviction_policy: EvictionPolicy,
    
    /// Clock hand for clock algorithm
    clock_hand: FrameIdx,
    
    /// Statistics
    stats: BufferStats,
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    const PageKeyContext = struct {
        pub fn hash(ctx: @This(), key: PageKey) u64 {
            _ = ctx;
            return key.hash();
        }
        pub fn eql(ctx: @This(), a: PageKey, b: PageKey) bool {
            _ = ctx;
            return a.eql(b);
        }
    };
    
    /// Create a new buffer manager
    pub fn create(allocator: std.mem.Allocator, capacity: usize) !*Self {
        const num_frames = capacity / KUZU_PAGE_SIZE;
        
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        self.allocator = allocator;
        self.capacity = capacity;
        self.num_frames = num_frames;
        self.eviction_policy = .LRU;
        self.clock_hand = 0;
        self.stats = .{};
        self.mutex = .{};
        
        // Allocate frames
        self.frames = try allocator.alloc(BufferFrame, num_frames);
        errdefer allocator.free(self.frames);
        
        for (self.frames, 0..) |*frame, i| {
            frame.* = try BufferFrame.init(allocator, @intCast(i));
        }
        
        // Initialize page table
        self.page_table = .{};
        
        // Initialize free list with all frames
        self.free_frames = .empty;
        for (0..num_frames) |i| {
            try self.free_frames.append(allocator, @intCast(i));
        }
        
        return self;
    }
    
    /// Pin a page (load if not in buffer)
    pub fn pin(self: *Self, file_id: u64, page_idx: PageIdx) !*BufferFrame {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const key = PageKey{ .file_id = file_id, .page_idx = page_idx };
        
        // Check if page is already in buffer
        if (self.page_table.get(key)) |frame_idx| {
            const frame = &self.frames[frame_idx];
            frame.pin();
            self.stats.hits += 1;
            return frame;
        }
        
        // Page not in buffer - need to load
        self.stats.misses += 1;
        
        // Get a free frame (may need to evict)
        const frame_idx = try self.getFreeFrame();
        const frame = &self.frames[frame_idx];
        
        // Set up the frame
        frame.page_key = key;
        frame.state = .LOADING;
        try self.page_table.put(key, frame_idx);
        
        // Mark as loaded and pin
        frame.state = .LOADED;
        frame.pin();
        
        return frame;
    }
    
    /// Unpin a page
    pub fn unpin(self: *Self, frame: *BufferFrame) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        frame.unpin();
    }
    
    /// Get a free frame (evict if necessary)
    fn getFreeFrame(self: *Self) !FrameIdx {
        // Try to get from free list
        if (self.free_frames.items.len > 0) {
            const frame_idx = self.free_frames.items[self.free_frames.items.len - 1];
            self.free_frames.items.len -= 1;
            return frame_idx;
        }
        
        // Need to evict
        return self.evictFrame();
    }
    
    /// Evict a frame using the configured policy
    fn evictFrame(self: *Self) !FrameIdx {
        return switch (self.eviction_policy) {
            .LRU => self.evictLRU(),
            .CLOCK => self.evictClock(),
            .LRU_K => self.evictLRU(), // Simplified
        };
    }
    
    /// LRU eviction
    fn evictLRU(self: *Self) !FrameIdx {
        var oldest_frame: ?FrameIdx = null;
        var oldest_time: i64 = std.math.maxInt(i64);
        
        for (self.frames, 0..) |*frame, i| {
            if (frame.isEvictable()) {
                if (frame.last_access < oldest_time) {
                    oldest_time = frame.last_access;
                    oldest_frame = @intCast(i);
                }
            }
        }
        
        if (oldest_frame) |frame_idx| {
            try self.evictFrameAt(frame_idx);
            return frame_idx;
        }
        
        return error.BufferPoolFull;
    }
    
    /// Clock eviction algorithm
    fn evictClock(self: *Self) !FrameIdx {
        var iterations: usize = 0;
        const max_iterations = self.num_frames * 2;
        
        while (iterations < max_iterations) : (iterations += 1) {
            const frame = &self.frames[self.clock_hand];
            
            if (frame.isEvictable()) {
                if (frame.access_count == 0) {
                    const victim = self.clock_hand;
                    try self.evictFrameAt(victim);
                    self.advanceClockHand();
                    return victim;
                } else {
                    frame.access_count = 0; // Give second chance
                }
            }
            
            self.advanceClockHand();
        }
        
        return error.BufferPoolFull;
    }
    
    fn advanceClockHand(self: *Self) void {
        self.clock_hand = (self.clock_hand + 1) % @as(FrameIdx, @intCast(self.num_frames));
    }
    
    /// Evict a specific frame
    fn evictFrameAt(self: *Self, frame_idx: FrameIdx) !void {
        const frame = &self.frames[frame_idx];
        
        if (!frame.isEvictable()) {
            return error.FrameNotEvictable;
        }
        
        frame.state = .EVICTING;
        
        // Write dirty page if needed
        if (frame.dirty) {
            // Would write to disk here
            self.stats.dirty_writes += 1;
        }
        
        // Remove from page table
        _ = self.page_table.remove(frame.page_key);
        
        // Reset frame
        frame.reset();
        
        self.stats.evictions += 1;
    }
    
    /// Flush all dirty pages
    pub fn flushAll(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.frames) |*frame| {
            if (frame.state == .LOADED and frame.dirty) {
                // Would write to disk here
                frame.dirty = false;
                self.stats.dirty_writes += 1;
            }
        }
    }
    
    /// Get statistics
    pub fn getStats(self: *Self) BufferStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }
    
    /// Get pool utilization
    pub fn getUtilization(self: *Self) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const used = self.num_frames - self.free_frames.items.len;
        return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(self.num_frames));
    }
    
    /// Destroy the buffer manager
    pub fn destroy(self: *Self) void {
        for (self.frames) |*frame| {
            frame.deinit(self.allocator);
        }
        self.allocator.free(self.frames);
        self.page_table.deinit(self.allocator);
        self.free_frames.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "buffer manager creation" {
    const allocator = std.testing.allocator;
    
    const capacity = 4 * KUZU_PAGE_SIZE; // 4 pages
    const bm = try BufferManager.create(allocator, capacity);
    defer bm.destroy();
    
    try std.testing.expectEqual(@as(usize, 4), bm.num_frames);
    try std.testing.expectEqual(@as(usize, 4), bm.free_frames.items.len);
}

test "buffer manager pin/unpin" {
    const allocator = std.testing.allocator;
    
    const bm = try BufferManager.create(allocator, 4 * KUZU_PAGE_SIZE);
    defer bm.destroy();
    
    // Pin a page
    const frame1 = try bm.pin(1, 0);
    try std.testing.expect(frame1.isPinned());
    try std.testing.expectEqual(@as(u32, 1), frame1.pin_count);
    
    // Pin same page again
    const frame1b = try bm.pin(1, 0);
    try std.testing.expectEqual(frame1, frame1b);
    try std.testing.expectEqual(@as(u32, 2), frame1.pin_count);
    
    // Unpin
    bm.unpin(frame1);
    try std.testing.expectEqual(@as(u32, 1), frame1.pin_count);
    
    bm.unpin(frame1);
    try std.testing.expect(!frame1.isPinned());
}

test "buffer manager eviction" {
    const allocator = std.testing.allocator;
    
    const bm = try BufferManager.create(allocator, 2 * KUZU_PAGE_SIZE);
    defer bm.destroy();
    
    // Fill the buffer
    const frame1 = try bm.pin(1, 0);
    bm.unpin(frame1);
    
    const frame2 = try bm.pin(1, 1);
    bm.unpin(frame2);
    
    // This should trigger eviction
    const frame3 = try bm.pin(1, 2);
    bm.unpin(frame3);
    
    try std.testing.expectEqual(@as(u64, 1), bm.stats.evictions);
}