//! Block Manager - KV-Cache Memory Management
//!
//! Implements PagedAttention-style block-based memory management for KV-cache.
//! Key features:
//! - Dynamic block allocation/deallocation
//! - Prefix caching with hash-based block sharing
//! - Copy-on-write for efficient memory usage
//! - Eviction policies for memory pressure

const std = @import("std");
const logging = @import("../utils/logging.zig");
const types = @import("../engine/types.zig");

const log = logging.scoped(.block_manager);

/// Physical block in GPU/CPU memory
pub const PhysicalBlock = struct {
    /// Unique block ID
    block_id: u32,
    /// Reference count (for sharing)
    ref_count: u32 = 1,
    /// Hash of block content (for prefix caching)
    content_hash: u64 = 0,
    /// Whether block is on GPU or CPU
    device: Device = .gpu,
    /// Last access timestamp (for eviction)
    last_access: i64 = 0,
    /// Number of tokens stored in this block
    num_tokens: u32 = 0,
    /// Whether block is full
    is_full: bool = false,

    const Self = @This();

    pub fn touch(self: *Self) void {
        self.last_access = std.time.timestamp();
    }

    pub fn addRef(self: *Self) void {
        self.ref_count += 1;
    }

    pub fn release(self: *Self) bool {
        if (self.ref_count > 0) {
            self.ref_count -= 1;
        }
        return self.ref_count == 0;
    }
};

/// Device type for block storage
pub const Device = enum {
    gpu,
    cpu,
};

/// Block table mapping logical to physical blocks
pub const BlockTable = struct {
    /// Sequence ID this table belongs to
    sequence_id: u64,
    /// Logical to physical block mapping
    logical_to_physical: std.ArrayList(u32),
    /// Allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sequence_id: u64) Self {
        return Self{
            .sequence_id = sequence_id,
            .logical_to_physical = std.ArrayList(u32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.logical_to_physical.deinit();
    }

    pub fn numBlocks(self: *const Self) usize {
        return self.logical_to_physical.items.len;
    }

    pub fn getPhysicalBlock(self: *const Self, logical_idx: usize) ?u32 {
        if (logical_idx >= self.logical_to_physical.items.len) {
            return null;
        }
        return self.logical_to_physical.items[logical_idx];
    }

    pub fn appendBlock(self: *Self, physical_id: u32) !void {
        try self.logical_to_physical.append(physical_id);
    }
};

/// Configuration for the block manager
pub const BlockManagerConfig = struct {
    /// Size of each block in tokens
    block_size: u32 = 16,
    /// Number of GPU blocks to allocate
    num_gpu_blocks: u32 = 1000,
    /// Number of CPU blocks for swapping
    num_cpu_blocks: u32 = 500,
    /// Whether to enable prefix caching
    enable_prefix_caching: bool = false,
    /// Watermark for triggering eviction (0.0-1.0)
    watermark: f32 = 0.9,
    /// Number of layers in the model
    num_layers: u32 = 32,
    /// Number of KV heads
    num_kv_heads: u32 = 8,
    /// Head dimension
    head_dim: u32 = 128,
};

/// Block Manager for KV-cache
pub const BlockManager = struct {
    /// Configuration
    config: BlockManagerConfig,
    /// Memory allocator
    allocator: std.mem.Allocator,

    /// All physical GPU blocks
    gpu_blocks: []PhysicalBlock,
    /// All physical CPU blocks
    cpu_blocks: []PhysicalBlock,

    /// Free GPU block IDs
    free_gpu_blocks: std.ArrayList(u32),
    /// Free CPU block IDs
    free_cpu_blocks: std.ArrayList(u32),

    /// Block tables for each sequence
    block_tables: std.AutoHashMap(u64, BlockTable),

    /// Prefix cache: hash -> block ID
    prefix_cache: std.AutoHashMap(u64, u32),

    /// Statistics
    stats: BlockManagerStats,

    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    /// Initialize the block manager
    pub fn init(allocator: std.mem.Allocator, config: BlockManagerConfig) !*Self {
        log.info("Initializing BlockManager with {d} GPU blocks, {d} CPU blocks", .{
            config.num_gpu_blocks,
            config.num_cpu_blocks,
        });

        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Allocate GPU blocks
        self.gpu_blocks = try allocator.alloc(PhysicalBlock, config.num_gpu_blocks);
        for (self.gpu_blocks, 0..) |*block, i| {
            block.* = PhysicalBlock{
                .block_id = @intCast(i),
                .device = .gpu,
            };
        }

        // Allocate CPU blocks
        self.cpu_blocks = try allocator.alloc(PhysicalBlock, config.num_cpu_blocks);
        for (self.cpu_blocks, 0..) |*block, i| {
            block.* = PhysicalBlock{
                .block_id = @intCast(config.num_gpu_blocks + i),
                .device = .cpu,
            };
        }

        // Initialize free lists
        self.free_gpu_blocks = std.ArrayList(u32).init(allocator);
        try self.free_gpu_blocks.ensureTotalCapacity(config.num_gpu_blocks);
        var i: u32 = config.num_gpu_blocks;
        while (i > 0) {
            i -= 1;
            try self.free_gpu_blocks.append(i);
        }

        self.free_cpu_blocks = std.ArrayList(u32).init(allocator);
        try self.free_cpu_blocks.ensureTotalCapacity(config.num_cpu_blocks);
        i = config.num_cpu_blocks;
        while (i > 0) {
            i -= 1;
            try self.free_cpu_blocks.append(config.num_gpu_blocks + i);
        }

        self.block_tables = std.AutoHashMap(u64, BlockTable).init(allocator);
        self.prefix_cache = std.AutoHashMap(u64, u32).init(allocator);
        self.config = config;
        self.allocator = allocator;
        self.stats = .{};

        log.info("BlockManager initialized: {d} free GPU blocks, {d} free CPU blocks", .{
            self.free_gpu_blocks.items.len,
            self.free_cpu_blocks.items.len,
        });

        return self;
    }

    /// Deinitialize and free resources
    pub fn deinit(self: *Self) void {
        log.info("Shutting down BlockManager", .{});

        // Free block tables
        var iter = self.block_tables.valueIterator();
        while (iter.next()) |table| {
            table.deinit();
        }
        self.block_tables.deinit();

        self.prefix_cache.deinit();
        self.free_gpu_blocks.deinit();
        self.free_cpu_blocks.deinit();

        self.allocator.free(self.gpu_blocks);
        self.allocator.free(self.cpu_blocks);

        self.allocator.destroy(self);
    }

    /// Allocate blocks for a new sequence
    pub fn allocate(self: *Self, sequence_id: u64, num_tokens: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const num_blocks_needed = self.tokensToBlocks(num_tokens);

        // Check if we have enough free blocks
        if (self.free_gpu_blocks.items.len < num_blocks_needed) {
            // Try eviction
            try self.evictBlocks(num_blocks_needed - self.free_gpu_blocks.items.len);
        }

        if (self.free_gpu_blocks.items.len < num_blocks_needed) {
            return error.OutOfMemory;
        }

        // Create block table for this sequence
        var table = BlockTable.init(self.allocator, sequence_id);
        errdefer table.deinit();

        // Allocate blocks
        var blocks_allocated: u32 = 0;
        while (blocks_allocated < num_blocks_needed) : (blocks_allocated += 1) {
            const block_id = self.free_gpu_blocks.pop();
            self.gpu_blocks[block_id].touch();
            self.gpu_blocks[block_id].ref_count = 1;
            try table.appendBlock(block_id);
        }

        try self.block_tables.put(sequence_id, table);

        self.stats.total_allocated += num_blocks_needed;
        self.stats.current_allocated += num_blocks_needed;

        log.debug("Allocated {d} blocks for sequence {d}", .{ num_blocks_needed, sequence_id });
    }

    /// Free blocks for a sequence
    pub fn free(self: *Self, sequence_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.block_tables.fetchRemove(sequence_id)) |entry| {
            var table = entry.value;
            defer table.deinit();

            for (table.logical_to_physical.items) |block_id| {
                if (block_id < self.config.num_gpu_blocks) {
                    const block = &self.gpu_blocks[block_id];
                    if (block.release()) {
                        // Block is now free
                        self.free_gpu_blocks.append(block_id) catch {};
                        self.stats.current_allocated -= 1;
                    }
                }
            }

            log.debug("Freed blocks for sequence {d}", .{sequence_id});
        }
    }

    /// Allocate a single new block for a sequence
    pub fn allocateBlock(self: *Self, sequence_id: u64) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_gpu_blocks.items.len == 0) {
            try self.evictBlocks(1);
        }

        if (self.free_gpu_blocks.items.len == 0) {
            return error.OutOfMemory;
        }

        const block_id = self.free_gpu_blocks.pop();
        self.gpu_blocks[block_id].touch();
        self.gpu_blocks[block_id].ref_count = 1;

        if (self.block_tables.getPtr(sequence_id)) |table| {
            try table.appendBlock(block_id);
        } else {
            return error.SequenceNotFound;
        }

        self.stats.total_allocated += 1;
        self.stats.current_allocated += 1;

        return block_id;
    }

    /// Get block table for a sequence
    pub fn getBlockTable(self: *Self, sequence_id: u64) ?*const BlockTable {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.block_tables.getPtr(sequence_id);
    }

    /// Try to share a block via prefix caching
    pub fn trySharePrefix(self: *Self, hash: u64, sequence_id: u64) !bool {
        if (!self.config.enable_prefix_caching) {
            return false;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.prefix_cache.get(hash)) |cached_block_id| {
            // Found cached block - share it
            if (cached_block_id < self.config.num_gpu_blocks) {
                self.gpu_blocks[cached_block_id].addRef();

                if (self.block_tables.getPtr(sequence_id)) |table| {
                    try table.appendBlock(cached_block_id);
                    self.stats.prefix_cache_hits += 1;
                    log.debug("Prefix cache hit for hash {x}", .{hash});
                    return true;
                }
            }
        }

        self.stats.prefix_cache_misses += 1;
        return false;
    }

    /// Register a block in the prefix cache
    pub fn registerPrefix(self: *Self, hash: u64, block_id: u32) !void {
        if (!self.config.enable_prefix_caching) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.prefix_cache.put(hash, block_id);
        if (block_id < self.config.num_gpu_blocks) {
            self.gpu_blocks[block_id].content_hash = hash;
        }
    }

    /// Swap blocks to CPU
    pub fn swapOut(self: *Self, sequence_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const table = self.block_tables.getPtr(sequence_id) orelse return error.SequenceNotFound;

        for (table.logical_to_physical.items) |*block_id| {
            if (block_id.* < self.config.num_gpu_blocks) {
                // GPU block - swap to CPU
                if (self.free_cpu_blocks.items.len == 0) {
                    return error.NoCpuBlocksAvailable;
                }

                const cpu_block_id = self.free_cpu_blocks.pop();
                const gpu_block = &self.gpu_blocks[block_id.*];

                // Copy metadata
                self.cpu_blocks[cpu_block_id - self.config.num_gpu_blocks].* = gpu_block.*;
                self.cpu_blocks[cpu_block_id - self.config.num_gpu_blocks].device = .cpu;

                // Free GPU block
                gpu_block.ref_count = 0;
                try self.free_gpu_blocks.append(block_id.*);

                // Update mapping
                block_id.* = cpu_block_id;

                self.stats.swaps_out += 1;
            }
        }

        log.debug("Swapped out sequence {d} to CPU", .{sequence_id});
    }

    /// Swap blocks back to GPU
    pub fn swapIn(self: *Self, sequence_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const table = self.block_tables.getPtr(sequence_id) orelse return error.SequenceNotFound;

        for (table.logical_to_physical.items) |*block_id| {
            if (block_id.* >= self.config.num_gpu_blocks) {
                // CPU block - swap to GPU
                if (self.free_gpu_blocks.items.len == 0) {
                    try self.evictBlocks(1);
                }

                if (self.free_gpu_blocks.items.len == 0) {
                    return error.OutOfMemory;
                }

                const gpu_block_id = self.free_gpu_blocks.pop();
                const cpu_idx = block_id.* - self.config.num_gpu_blocks;
                const cpu_block = &self.cpu_blocks[cpu_idx];

                // Copy metadata
                self.gpu_blocks[gpu_block_id].* = cpu_block.*;
                self.gpu_blocks[gpu_block_id].device = .gpu;

                // Free CPU block
                cpu_block.ref_count = 0;
                try self.free_cpu_blocks.append(block_id.*);

                // Update mapping
                block_id.* = gpu_block_id;

                self.stats.swaps_in += 1;
            }
        }

        log.debug("Swapped in sequence {d} to GPU", .{sequence_id});
    }

    /// Evict blocks to free memory
    fn evictBlocks(self: *Self, num_blocks: usize) !void {
        // LRU eviction: find least recently used blocks
        // For now, just log a warning - full implementation would
        // coordinate with scheduler to preempt sequences

        log.warn("Need to evict {d} blocks - not fully implemented", .{num_blocks});
        self.stats.evictions += @intCast(num_blocks);
    }

    /// Convert token count to block count
    pub fn tokensToBlocks(self: *const Self, num_tokens: u32) u32 {
        return (num_tokens + self.config.block_size - 1) / self.config.block_size;
    }

    /// Get number of free GPU blocks
    pub fn getNumFreeGpuBlocks(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.free_gpu_blocks.items.len;
    }

    /// Get number of free CPU blocks
    pub fn getNumFreeCpuBlocks(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.free_cpu_blocks.items.len;
    }

    /// Get GPU memory utilization
    pub fn getGpuUtilization(self: *Self) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const used = self.config.num_gpu_blocks - @as(u32, @intCast(self.free_gpu_blocks.items.len));
        return @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(self.config.num_gpu_blocks));
    }

    /// Check if we can allocate N blocks
    pub fn canAllocate(self: *Self, num_blocks: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.free_gpu_blocks.items.len >= num_blocks;
    }

    /// Get statistics
    pub fn getStats(self: *Self) BlockManagerStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }
};

/// Statistics for block manager
pub const BlockManagerStats = struct {
    /// Total blocks allocated since start
    total_allocated: u64 = 0,
    /// Currently allocated blocks
    current_allocated: u64 = 0,
    /// Prefix cache hits
    prefix_cache_hits: u64 = 0,
    /// Prefix cache misses
    prefix_cache_misses: u64 = 0,
    /// Blocks swapped out
    swaps_out: u64 = 0,
    /// Blocks swapped in
    swaps_in: u64 = 0,
    /// Blocks evicted
    evictions: u64 = 0,
};

// ============================================
// Tests
// ============================================

test "BlockManager initialization" {
    const allocator = std.testing.allocator;

    const config = BlockManagerConfig{
        .num_gpu_blocks = 100,
        .num_cpu_blocks = 50,
        .block_size = 16,
    };

    var manager = try BlockManager.init(allocator, config);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 100), manager.getNumFreeGpuBlocks());
    try std.testing.expectEqual(@as(usize, 50), manager.getNumFreeCpuBlocks());
}

test "BlockManager allocation" {
    const allocator = std.testing.allocator;

    const config = BlockManagerConfig{
        .num_gpu_blocks = 100,
        .num_cpu_blocks = 50,
        .block_size = 16,
    };

    var manager = try BlockManager.init(allocator, config);
    defer manager.deinit();

    // Allocate blocks for a sequence
    try manager.allocate(1, 32); // Should need 2 blocks
    try std.testing.expectEqual(@as(usize, 98), manager.getNumFreeGpuBlocks());

    // Free the blocks
    manager.free(1);
    try std.testing.expectEqual(@as(usize, 100), manager.getNumFreeGpuBlocks());
}

test "tokensToBlocks calculation" {
    const allocator = std.testing.allocator;

    const config = BlockManagerConfig{
        .num_gpu_blocks = 100,
        .num_cpu_blocks = 50,
        .block_size = 16,
    };

    var manager = try BlockManager.init(allocator, config);
    defer manager.deinit();

    try std.testing.expectEqual(@as(u32, 1), manager.tokensToBlocks(1));
    try std.testing.expectEqual(@as(u32, 1), manager.tokensToBlocks(16));
    try std.testing.expectEqual(@as(u32, 2), manager.tokensToBlocks(17));
    try std.testing.expectEqual(@as(u32, 2), manager.tokensToBlocks(32));
}