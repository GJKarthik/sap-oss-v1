//! Memory Manager - Memory Pool and Allocation
//!
//! Converted from: kuzu/src/storage/buffer_manager/memory_manager.cpp
//!
//! Purpose:
//! Manages memory allocation for the database engine. Provides memory
//! pools, tracking, and limits to prevent OOM conditions.
//!
//! Architecture:
//! ```
//! MemoryManager
//!   ├── totalMemory: u64           // Total available memory
//!   ├── usedMemory: atomic u64     // Currently allocated
//!   ├── memoryPools: []MemoryPool  // Size-class pools
//!   └── spillManager: Spiller      // Overflow to disk
//!
//! Allocation Strategy:
//!   Small (<= 256KB): Pool allocation
//!   Large (> 256KB): Direct allocation
//! ```

const std = @import("std");
const common = @import("../../common/common.zig");

/// Memory size constants
pub const KB: u64 = 1024;
pub const MB: u64 = 1024 * KB;
pub const GB: u64 = 1024 * MB;

/// Default buffer pool size
pub const DEFAULT_BUFFER_POOL_SIZE: u64 = 256 * MB;

/// Small allocation threshold
pub const SMALL_ALLOC_THRESHOLD: u64 = 256 * KB;

/// Memory pool size class
pub const SizeClass = enum(u8) {
    SIZE_64 = 0,      // 64 bytes
    SIZE_256 = 1,     // 256 bytes
    SIZE_1K = 2,      // 1 KB
    SIZE_4K = 3,      // 4 KB
    SIZE_16K = 4,     // 16 KB
    SIZE_64K = 5,     // 64 KB
    SIZE_256K = 6,    // 256 KB
    LARGE = 7,        // > 256 KB
    
    pub fn getSize(self: SizeClass) u64 {
        return switch (self) {
            .SIZE_64 => 64,
            .SIZE_256 => 256,
            .SIZE_1K => KB,
            .SIZE_4K => 4 * KB,
            .SIZE_16K => 16 * KB,
            .SIZE_64K => 64 * KB,
            .SIZE_256K => 256 * KB,
            .LARGE => 0,
        };
    }
    
    pub fn fromSize(size: u64) SizeClass {
        if (size <= 64) return .SIZE_64;
        if (size <= 256) return .SIZE_256;
        if (size <= KB) return .SIZE_1K;
        if (size <= 4 * KB) return .SIZE_4K;
        if (size <= 16 * KB) return .SIZE_16K;
        if (size <= 64 * KB) return .SIZE_64K;
        if (size <= 256 * KB) return .SIZE_256K;
        return .LARGE;
    }
};

/// Memory block header
pub const BlockHeader = struct {
    size: u64,
    size_class: SizeClass,
    is_free: bool,
    next: ?*BlockHeader,
    
    pub fn init(size: u64, size_class: SizeClass) BlockHeader {
        return .{
            .size = size,
            .size_class = size_class,
            .is_free = false,
            .next = null,
        };
    }
};

/// Memory pool for a specific size class
pub const MemoryPool = struct {
    allocator: std.mem.Allocator,
    size_class: SizeClass,
    block_size: u64,
    free_list: ?*BlockHeader,
    allocated_blocks: u64,
    free_blocks: u64,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, size_class: SizeClass) Self {
        return .{
            .allocator = allocator,
            .size_class = size_class,
            .block_size = size_class.getSize(),
            .free_list = null,
            .allocated_blocks = 0,
            .free_blocks = 0,
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Free all blocks in free list
        var current = self.free_list;
        while (current) |block| {
            const next = block.next;
            const total_size = @sizeOf(BlockHeader) + self.block_size;
            const ptr = @as([*]u8, @ptrCast(block));
            self.allocator.free(ptr[0..total_size]);
            current = next;
        }
        self.free_list = null;
    }
    
    pub fn allocate(self: *Self) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Try to get from free list
        if (self.free_list) |block| {
            self.free_list = block.next;
            block.is_free = false;
            block.next = null;
            self.free_blocks -= 1;
            
            const data_ptr = @as([*]u8, @ptrCast(block)) + @sizeOf(BlockHeader);
            return data_ptr[0..self.block_size];
        }
        
        // Allocate new block
        const total_size = @sizeOf(BlockHeader) + self.block_size;
        const memory = try self.allocator.alloc(u8, total_size);
        
        const header: *BlockHeader = @ptrCast(@alignCast(memory.ptr));
        header.* = BlockHeader.init(self.block_size, self.size_class);
        
        self.allocated_blocks += 1;
        
        return memory[@sizeOf(BlockHeader)..];
    }
    
    pub fn deallocate(self: *Self, ptr: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Get header
        const header_ptr = @as([*]u8, @ptrCast(ptr.ptr)) - @sizeOf(BlockHeader);
        const header: *BlockHeader = @ptrCast(@alignCast(header_ptr));
        
        // Add to free list
        header.is_free = true;
        header.next = self.free_list;
        self.free_list = header;
        self.free_blocks += 1;
    }
    
    pub fn getUsedMemory(self: *const Self) u64 {
        return (self.allocated_blocks - self.free_blocks) * self.block_size;
    }
    
    pub fn getTotalMemory(self: *const Self) u64 {
        return self.allocated_blocks * self.block_size;
    }
};

/// Memory statistics
pub const MemoryStats = struct {
    total_allocated: u64,
    total_used: u64,
    peak_used: u64,
    allocation_count: u64,
    deallocation_count: u64,
    pool_hits: u64,
    pool_misses: u64,
    
    pub fn init() MemoryStats {
        return .{
            .total_allocated = 0,
            .total_used = 0,
            .peak_used = 0,
            .allocation_count = 0,
            .deallocation_count = 0,
            .pool_hits = 0,
            .pool_misses = 0,
        };
    }
    
    pub fn updatePeak(self: *MemoryStats) void {
        if (self.total_used > self.peak_used) {
            self.peak_used = self.total_used;
        }
    }
};

/// Memory Manager
pub const MemoryManager = struct {
    allocator: std.mem.Allocator,
    memory_limit: u64,
    used_memory: std.atomic.Value(u64),
    pools: [7]MemoryPool,
    stats: MemoryStats,
    large_allocations: std.AutoHashMap(usize, u64),
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, memory_limit: u64) !*Self {
        const self = try allocator.create(Self);
        
        self.* = .{
            .allocator = allocator,
            .memory_limit = memory_limit,
            .used_memory = std.atomic.Value(u64).init(0),
            .pools = undefined,
            .stats = MemoryStats.init(),
            .large_allocations = std.AutoHashMap(usize, u64).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
        
        // Initialize pools
        self.pools[0] = MemoryPool.init(allocator, .SIZE_64);
        self.pools[1] = MemoryPool.init(allocator, .SIZE_256);
        self.pools[2] = MemoryPool.init(allocator, .SIZE_1K);
        self.pools[3] = MemoryPool.init(allocator, .SIZE_4K);
        self.pools[4] = MemoryPool.init(allocator, .SIZE_16K);
        self.pools[5] = MemoryPool.init(allocator, .SIZE_64K);
        self.pools[6] = MemoryPool.init(allocator, .SIZE_256K);
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        for (&self.pools) |*pool| {
            pool.deinit();
        }
        
        // Free large allocations
        var iter = self.large_allocations.iterator();
        while (iter.next()) |entry| {
            const ptr: [*]u8 = @ptrFromInt(entry.key_ptr.*);
            const size = entry.value_ptr.*;
            self.allocator.free(ptr[0..size]);
        }
        self.large_allocations.deinit();
        
        self.allocator.destroy(self);
    }
    
    /// Allocate memory
    pub fn allocate(self: *Self, size: u64) ![]u8 {
        const size_class = SizeClass.fromSize(size);
        
        // Check memory limit
        const current = self.used_memory.load(.acquire);
        if (current + size > self.memory_limit) {
            return error.OutOfMemory;
        }
        
        var result: []u8 = undefined;
        
        if (size_class != .LARGE) {
            // Pool allocation
            const pool_idx = @intFromEnum(size_class);
            result = try self.pools[pool_idx].allocate();
            
            self.mutex.lock();
            self.stats.pool_hits += 1;
            self.mutex.unlock();
        } else {
            // Large allocation
            result = try self.allocator.alloc(u8, size);
            
            self.mutex.lock();
            try self.large_allocations.put(@intFromPtr(result.ptr), size);
            self.stats.pool_misses += 1;
            self.mutex.unlock();
        }
        
        // Update stats
        _ = self.used_memory.fetchAdd(size, .release);
        
        self.mutex.lock();
        self.stats.allocation_count += 1;
        self.stats.total_used = self.used_memory.load(.acquire);
        self.stats.updatePeak();
        self.mutex.unlock();
        
        return result;
    }
    
    /// Deallocate memory
    pub fn deallocate(self: *Self, ptr: []u8) void {
        const size = ptr.len;
        const size_class = SizeClass.fromSize(size);
        
        if (size_class != .LARGE) {
            // Pool deallocation
            const pool_idx = @intFromEnum(size_class);
            self.pools[pool_idx].deallocate(ptr);
        } else {
            // Large deallocation
            self.mutex.lock();
            _ = self.large_allocations.remove(@intFromPtr(ptr.ptr));
            self.mutex.unlock();
            
            self.allocator.free(ptr);
        }
        
        // Update stats
        _ = self.used_memory.fetchSub(size, .release);
        
        self.mutex.lock();
        self.stats.deallocation_count += 1;
        self.stats.total_used = self.used_memory.load(.acquire);
        self.mutex.unlock();
    }
    
    /// Get current memory usage
    pub fn getUsedMemory(self: *const Self) u64 {
        return self.used_memory.load(.acquire);
    }
    
    /// Get memory limit
    pub fn getMemoryLimit(self: *const Self) u64 {
        return self.memory_limit;
    }
    
    /// Get available memory
    pub fn getAvailableMemory(self: *const Self) u64 {
        const used = self.used_memory.load(.acquire);
        if (used >= self.memory_limit) return 0;
        return self.memory_limit - used;
    }
    
    /// Get memory statistics
    pub fn getStats(self: *const Self) MemoryStats {
        return self.stats;
    }
    
    /// Check if can allocate
    pub fn canAllocate(self: *const Self, size: u64) bool {
        return self.getAvailableMemory() >= size;
    }
    
    /// Set memory limit
    pub fn setMemoryLimit(self: *Self, limit: u64) void {
        self.memory_limit = limit;
    }
};

/// Spiller - handles memory overflow to disk
pub const Spiller = struct {
    allocator: std.mem.Allocator,
    spill_directory: []const u8,
    spilled_blocks: std.AutoHashMap(u64, SpilledBlock),
    next_block_id: u64,
    total_spilled: u64,
    
    pub const SpilledBlock = struct {
        block_id: u64,
        size: u64,
        file_path: []const u8,
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, spill_directory: []const u8) Self {
        return .{
            .allocator = allocator,
            .spill_directory = spill_directory,
            .spilled_blocks = std.AutoHashMap(u64, SpilledBlock).init(allocator),
            .next_block_id = 0,
            .total_spilled = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.spilled_blocks.deinit();
    }
    
    pub fn spillToDisk(self: *Self, data: []const u8) !u64 {
        const block_id = self.next_block_id;
        self.next_block_id += 1;
        
        // In real implementation: write to file
        _ = data;
        
        self.total_spilled += data.len;
        
        return block_id;
    }
    
    pub fn loadFromDisk(self: *Self, block_id: u64) ![]u8 {
        _ = self;
        _ = block_id;
        // In real implementation: read from file
        return error.NotImplemented;
    }
    
    pub fn getTotalSpilled(self: *const Self) u64 {
        return self.total_spilled;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "size class" {
    try std.testing.expectEqual(SizeClass.SIZE_64, SizeClass.fromSize(32));
    try std.testing.expectEqual(SizeClass.SIZE_64, SizeClass.fromSize(64));
    try std.testing.expectEqual(SizeClass.SIZE_256, SizeClass.fromSize(100));
    try std.testing.expectEqual(SizeClass.SIZE_4K, SizeClass.fromSize(2000));
    try std.testing.expectEqual(SizeClass.LARGE, SizeClass.fromSize(300 * KB));
}

test "memory pool" {
    const allocator = std.testing.allocator;
    
    var pool = MemoryPool.init(allocator, .SIZE_256);
    defer pool.deinit();
    
    // Allocate
    const block1 = try pool.allocate();
    try std.testing.expectEqual(@as(usize, 256), block1.len);
    
    const block2 = try pool.allocate();
    
    // Deallocate
    pool.deallocate(block1);
    pool.deallocate(block2);
    
    // Should reuse
    const block3 = try pool.allocate();
    try std.testing.expectEqual(@as(usize, 256), block3.len);
    
    pool.deallocate(block3);
}

test "memory manager" {
    const allocator = std.testing.allocator;
    
    var mm = try MemoryManager.init(allocator, 10 * MB);
    defer mm.deinit();
    
    try std.testing.expectEqual(@as(u64, 0), mm.getUsedMemory());
    try std.testing.expectEqual(@as(u64, 10 * MB), mm.getMemoryLimit());
    
    // Small allocation (pool)
    const small = try mm.allocate(100);
    try std.testing.expect(mm.getUsedMemory() > 0);
    
    mm.deallocate(small);
}

test "memory stats" {
    var stats = MemoryStats.init();
    
    stats.total_used = 1000;
    stats.updatePeak();
    try std.testing.expectEqual(@as(u64, 1000), stats.peak_used);
    
    stats.total_used = 500;
    stats.updatePeak();
    try std.testing.expectEqual(@as(u64, 1000), stats.peak_used);
}

test "spiller" {
    const allocator = std.testing.allocator;
    
    var spiller = Spiller.init(allocator, "/tmp");
    defer spiller.deinit();
    
    try std.testing.expectEqual(@as(u64, 0), spiller.getTotalSpilled());
}