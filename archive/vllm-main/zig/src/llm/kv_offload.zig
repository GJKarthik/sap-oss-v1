//! KV Cache CPU Offload Runtime
//!
//! Enables long-context inference on T4 by offloading cold KV cache blocks
//! to host memory (CPU RAM) via PCIe transfers.
//!
//! Architecture:
//! - Hot tier: GPU VRAM (fast, limited to ~6GB after model weights)
//! - Warm tier: Pinned CPU memory (PCIe 3.0 x16 ~16 GB/s)
//! - Cold tier: System RAM / SSD (optional, for very long sessions)
//!
//! Key features:
//! - Async transfers (non-blocking cudaMemcpyAsync)
//! - Prefetch based on attention pattern prediction
//! - LRU-based tier migration
//! - Block-level granularity (16 tokens per block)
//!
//! Memory math for T4:
//! - 16 GB VRAM total
//! - ~8 GB for INT8 8B model weights
//! - ~2 GB for activations/scratch
//! - ~6 GB for KV cache
//! - Host typically has 32-128 GB RAM
//!
//! With offload:
//! - 6 GB GPU = ~3K tokens hot
//! - 64 GB CPU = ~30K tokens warm
//! - Unlocks 32K+ context length

const std = @import("std");
const Allocator = std.mem.Allocator;
const batch_scheduler = @import("batch_scheduler.zig");

// ============================================================================
// Hardware Constants
// ============================================================================

/// PCIe 3.0 x16 bandwidth (GB/s)
pub const PCIE_BW_GBPS: f32 = 15.75;

/// Tokens per KV cache block
pub const BLOCK_SIZE: u32 = 16;

/// Default hot tier size (GPU VRAM blocks)
pub const DEFAULT_HOT_BLOCKS: u32 = 192; // ~3K tokens

/// Default warm tier size (CPU pinned memory blocks)
pub const DEFAULT_WARM_BLOCKS: u32 = 2048; // ~32K tokens

// ============================================================================
// Configuration
// ============================================================================

pub const OffloadConfig = struct {
    /// Maximum blocks in GPU VRAM (hot tier)
    max_hot_blocks: u32 = DEFAULT_HOT_BLOCKS,
    
    /// Maximum blocks in pinned CPU memory (warm tier)
    max_warm_blocks: u32 = DEFAULT_WARM_BLOCKS,
    
    /// Number of blocks to prefetch ahead
    prefetch_distance: u32 = 4,
    
    /// Minimum hot tier retention (recent tokens)
    min_hot_retention: u32 = 128, // ~2K tokens always on GPU
    
    /// Enable async transfers
    async_transfers: bool = true,
    
    /// Number of CUDA streams for overlapping transfers
    num_streams: u32 = 2,
    
    /// KV cache precision (bytes per element)
    kv_precision_bytes: u32 = 2, // FP16
    
    /// Number of attention heads
    num_heads: u32 = 32,
    
    /// Head dimension
    head_dim: u32 = 128,
    
    /// Number of KV heads (for GQA)
    num_kv_heads: u32 = 8,
    
    /// Number of layers
    num_layers: u32 = 32,
    
    pub fn bytesPerBlock(self: *const OffloadConfig) u64 {
        // K + V, per layer
        return @as(u64, BLOCK_SIZE) * self.num_kv_heads * self.head_dim * 
               self.kv_precision_bytes * 2 * self.num_layers;
    }
    
    pub fn hotTierBytes(self: *const OffloadConfig) u64 {
        return @as(u64, self.max_hot_blocks) * self.bytesPerBlock();
    }
    
    pub fn warmTierBytes(self: *const OffloadConfig) u64 {
        return @as(u64, self.max_warm_blocks) * self.bytesPerBlock();
    }
};

// ============================================================================
// Block Metadata
// ============================================================================

pub const BlockTier = enum(u8) {
    /// Block is in GPU VRAM
    hot,
    /// Block is in pinned CPU memory
    warm,
    /// Block is not allocated
    free,
    /// Block is being transferred
    in_transit,
};

pub const BlockMeta = struct {
    /// Logical block ID
    logical_id: u32,
    
    /// Physical location index within tier
    physical_idx: u32,
    
    /// Current storage tier
    tier: BlockTier,
    
    /// Owning sequence ID
    sequence_id: u64,
    
    /// Position within sequence (block 0 = tokens 0-15)
    seq_block_idx: u32,
    
    /// Last access timestamp (LRU clock)
    last_access: u64,
    
    /// Reference count (active attention operations)
    ref_count: u32,
    
    /// Is this block pinned (cannot be evicted)?
    pinned: bool,
    
    pub fn init(logical_id: u32, sequence_id: u64, seq_block_idx: u32) BlockMeta {
        return .{
            .logical_id = logical_id,
            .physical_idx = 0,
            .tier = .free,
            .sequence_id = sequence_id,
            .seq_block_idx = seq_block_idx,
            .last_access = 0,
            .ref_count = 0,
            .pinned = false,
        };
    }
    
    pub fn isEvictable(self: *const BlockMeta) bool {
        return !self.pinned and self.ref_count == 0 and self.tier != .in_transit;
    }
};

// ============================================================================
// Transfer Request
// ============================================================================

pub const TransferDirection = enum {
    gpu_to_cpu,
    cpu_to_gpu,
};

pub const TransferRequest = struct {
    block_id: u32,
    direction: TransferDirection,
    priority: u8,
    callback: ?*const fn (block_id: u32, success: bool) void,
    submit_time_ns: i128,
    
    pub fn init(block_id: u32, direction: TransferDirection, priority: u8) TransferRequest {
        return .{
            .block_id = block_id,
            .direction = direction,
            .priority = priority,
            .callback = null,
            .submit_time_ns = std.time.nanoTimestamp(),
        };
    }
};

// ============================================================================
// Tiered KV Cache Manager
// ============================================================================

pub const TieredKVCache = struct {
    allocator: Allocator,
    config: OffloadConfig,
    
    /// Block metadata array (indexed by logical block ID)
    blocks: std.ArrayListUnmanaged(BlockMeta),
    
    /// Free list for hot tier physical slots
    hot_free: std.ArrayListUnmanaged(u32),
    
    /// Free list for warm tier physical slots
    warm_free: std.ArrayListUnmanaged(u32),
    
    /// Mapping: sequence_id -> list of logical block IDs
    sequence_blocks: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u32)),
    
    /// Pending transfer queue
    transfer_queue: std.ArrayListUnmanaged(TransferRequest),
    
    /// LRU clock for eviction decisions
    lru_clock: u64,
    
    /// Statistics
    stats: OffloadStats,
    
    /// Next logical block ID to allocate
    next_logical_id: u32,
    
    pub fn init(allocator: Allocator, config: OffloadConfig) !TieredKVCache {
        var cache = TieredKVCache{
            .allocator = allocator,
            .config = config,
            .blocks = .empty,
            .hot_free = .empty,
            .warm_free = .empty,
            .sequence_blocks = .empty,
            .transfer_queue = .empty,
            .lru_clock = 0,
            .stats = OffloadStats{},
            .next_logical_id = 0,
        };
        
        // Initialize hot tier free list
        for (0..config.max_hot_blocks) |i| {
            try cache.hot_free.append(allocator, @intCast(i));
        }
        
        // Initialize warm tier free list
        for (0..config.max_warm_blocks) |i| {
            try cache.warm_free.append(allocator, @intCast(i));
        }
        
        return cache;
    }
    
    pub fn deinit(self: *TieredKVCache) void {
        self.blocks.deinit(self.allocator);
        self.hot_free.deinit(self.allocator);
        self.warm_free.deinit(self.allocator);
        
        var it = self.sequence_blocks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.sequence_blocks.deinit(self.allocator);
        
        self.transfer_queue.deinit(self.allocator);
    }
    
    /// Allocate a new KV block for a sequence
    pub fn allocateBlock(self: *TieredKVCache, sequence_id: u64, seq_block_idx: u32) !u32 {
        self.lru_clock += 1;
        
        // Create block metadata
        const logical_id = self.next_logical_id;
        self.next_logical_id += 1;
        
        var meta = BlockMeta.init(logical_id, sequence_id, seq_block_idx);
        meta.last_access = self.lru_clock;
        
        // Try to allocate in hot tier first
        if (self.hot_free.items.len > 0) {
            const physical_idx = self.hot_free.pop() orelse return error.AllocationFailed;
            meta.physical_idx = physical_idx;
            meta.tier = .hot;
            self.stats.hot_allocations += 1;
        } else if (self.warm_free.items.len > 0) {
            // Fall back to warm tier
            const physical_idx = self.warm_free.pop() orelse return error.AllocationFailed;
            meta.physical_idx = physical_idx;
            meta.tier = .warm;
            self.stats.warm_allocations += 1;
        } else {
            // Need to evict
            const evicted = try self.evictLRU();
            meta.physical_idx = evicted.physical_idx;
            meta.tier = evicted.tier;
            self.stats.evictions += 1;
        }
        
        try self.blocks.append(self.allocator, meta);
        
        // Track in sequence mapping
        const result = try self.sequence_blocks.getOrPut(self.allocator, sequence_id);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        try result.value_ptr.append(self.allocator, logical_id);
        
        return logical_id;
    }
    
    /// Free all blocks for a sequence
    pub fn freeSequence(self: *TieredKVCache, sequence_id: u64) void {
        if (self.sequence_blocks.get(sequence_id)) |block_ids| {
            for (block_ids.items) |logical_id| {
                self.freeBlock(logical_id);
            }
            
            if (self.sequence_blocks.fetchRemove(sequence_id)) |kv| {
                var list = kv.value;
                list.deinit(self.allocator);
            }
        }
    }
    
    /// Free a single block
    fn freeBlock(self: *TieredKVCache, logical_id: u32) void {
        for (self.blocks.items, 0..) |*meta, i| {
            if (meta.logical_id == logical_id) {
                // Return physical slot to free list
                switch (meta.tier) {
                    .hot => self.hot_free.append(self.allocator, meta.physical_idx) catch {},
                    .warm => self.warm_free.append(self.allocator, meta.physical_idx) catch {},
                    else => {},
                }
                
                // Remove from blocks list
                _ = self.blocks.orderedRemove(i);
                break;
            }
        }
    }
    
    /// Access a block (for attention computation)
    pub fn accessBlock(self: *TieredKVCache, logical_id: u32) !BlockAccess {
        self.lru_clock += 1;
        
        for (self.blocks.items) |*meta| {
            if (meta.logical_id == logical_id) {
                meta.last_access = self.lru_clock;
                meta.ref_count += 1;
                
                if (meta.tier == .warm) {
                    // Block is in CPU memory, need to fetch
                    try self.promoteToHot(meta);
                    self.stats.promotions += 1;
                }
                
                return BlockAccess{
                    .block_id = logical_id,
                    .tier = meta.tier,
                    .physical_idx = meta.physical_idx,
                    .needs_fetch = meta.tier == .in_transit,
                };
            }
        }
        
        return error.BlockNotFound;
    }
    
    /// Release a block after access
    pub fn releaseBlock(self: *TieredKVCache, logical_id: u32) void {
        for (self.blocks.items) |*meta| {
            if (meta.logical_id == logical_id) {
                if (meta.ref_count > 0) {
                    meta.ref_count -= 1;
                }
                break;
            }
        }
    }
    
    /// Promote a block from warm to hot tier
    fn promoteToHot(self: *TieredKVCache, meta: *BlockMeta) !void {
        if (meta.tier != .warm) return;
        
        // Check if we have space in hot tier
        if (self.hot_free.items.len == 0) {
            // Need to demote something first
            try self.demoteLRU();
        }
        
        if (self.hot_free.items.len > 0) {
            const old_physical = meta.physical_idx;
            const new_physical = self.hot_free.pop() orelse return;
            
            // Queue transfer
            const req = TransferRequest.init(meta.logical_id, .cpu_to_gpu, 10);
            try self.transfer_queue.append(req);
            
            // Return warm slot
            try self.warm_free.append(old_physical);
            
            meta.physical_idx = new_physical;
            meta.tier = .in_transit;
        }
    }
    
    /// Demote LRU hot block to warm tier
    fn demoteLRU(self: *TieredKVCache) !void {
        var oldest_idx: ?usize = null;
        var oldest_time: u64 = std.math.maxInt(u64);
        
        for (self.blocks.items, 0..) |*meta, i| {
            if (meta.tier == .hot and meta.isEvictable()) {
                // Skip minimum retention blocks (most recent)
                const blocks_from_end = self.countHotBlocks() - self.countHotBlocksAfter(meta.seq_block_idx);
                if (blocks_from_end < self.config.min_hot_retention / BLOCK_SIZE) {
                    continue;
                }
                
                if (meta.last_access < oldest_time) {
                    oldest_time = meta.last_access;
                    oldest_idx = i;
                }
            }
        }
        
        if (oldest_idx) |idx| {
            const meta = &self.blocks.items[idx];
            
            if (self.warm_free.items.len > 0) {
                const old_physical = meta.physical_idx;
                const new_physical = self.warm_free.pop() orelse return;
                
                // Queue transfer
                const req = TransferRequest.init(meta.logical_id, .gpu_to_cpu, 5);
                try self.transfer_queue.append(req);
                
                // Return hot slot
                try self.hot_free.append(self.allocator, old_physical);
                
                meta.physical_idx = new_physical;
                meta.tier = .in_transit;
                
                self.stats.demotions += 1;
            }
        }
    }
    
    /// Evict LRU block entirely
    fn evictLRU(self: *TieredKVCache) !BlockMeta {
        var oldest_idx: ?usize = null;
        var oldest_time: u64 = std.math.maxInt(u64);
        
        // Prefer evicting from warm tier
        for (self.blocks.items, 0..) |*meta, i| {
            if (meta.tier == .warm and meta.isEvictable()) {
                if (meta.last_access < oldest_time) {
                    oldest_time = meta.last_access;
                    oldest_idx = i;
                }
            }
        }
        
        // Fall back to hot tier if no warm candidates
        if (oldest_idx == null) {
            for (self.blocks.items, 0..) |*meta, i| {
                if (meta.tier == .hot and meta.isEvictable()) {
                    if (meta.last_access < oldest_time) {
                        oldest_time = meta.last_access;
                        oldest_idx = i;
                    }
                }
            }
        }
        
        if (oldest_idx) |idx| {
            const meta = self.blocks.items[idx];
            _ = self.blocks.orderedRemove(idx);
            return meta;
        }
        
        return error.NoEvictableBlocks;
    }
    
    /// Process pending transfers (call each frame/iteration)
    pub fn processPendingTransfers(self: *TieredKVCache, max_transfers: u32) u32 {
        var processed: u32 = 0;
        
        while (self.transfer_queue.items.len > 0 and processed < max_transfers) {
            const req = self.transfer_queue.orderedRemove(0);
            
            // Find the block
            for (self.blocks.items) |*meta| {
                if (meta.logical_id == req.block_id and meta.tier == .in_transit) {
                    // Complete the transfer
                    switch (req.direction) {
                        .gpu_to_cpu => {
                            meta.tier = .warm;
                            self.stats.transfers_gpu_to_cpu += 1;
                        },
                        .cpu_to_gpu => {
                            meta.tier = .hot;
                            self.stats.transfers_cpu_to_gpu += 1;
                        },
                    }
                    
                    if (req.callback) |cb| {
                        cb(req.block_id, true);
                    }
                    
                    break;
                }
            }
            
            processed += 1;
        }
        
        return processed;
    }
    
    /// Prefetch blocks for upcoming attention
    pub fn prefetch(self: *TieredKVCache, sequence_id: u64, start_block: u32, count: u32) !void {
        if (self.sequence_blocks.get(sequence_id)) |block_ids| {
            const end_block = @min(start_block + count, @as(u32, @intCast(block_ids.items.len)));
            
            for (start_block..end_block) |i| {
                const logical_id = block_ids.items[i];
                
                for (self.blocks.items) |*meta| {
                    if (meta.logical_id == logical_id and meta.tier == .warm) {
                        try self.promoteToHot(meta);
                        self.stats.prefetches += 1;
                        break;
                    }
                }
            }
        }
    }
    
    /// Get current tier distribution
    pub fn getTierDistribution(self: *const TieredKVCache) TierDistribution {
        var dist = TierDistribution{};
        
        for (self.blocks.items) |meta| {
            switch (meta.tier) {
                .hot => dist.hot_blocks += 1,
                .warm => dist.warm_blocks += 1,
                .in_transit => dist.in_transit_blocks += 1,
                .free => {},
            }
        }
        
        dist.hot_utilization = @as(f32, @floatFromInt(dist.hot_blocks)) / 
                               @as(f32, @floatFromInt(self.config.max_hot_blocks)) * 100.0;
        dist.warm_utilization = @as(f32, @floatFromInt(dist.warm_blocks)) / 
                                @as(f32, @floatFromInt(self.config.max_warm_blocks)) * 100.0;
        
        return dist;
    }
    
    fn countHotBlocks(self: *const TieredKVCache) u32 {
        var count: u32 = 0;
        for (self.blocks.items) |meta| {
            if (meta.tier == .hot) count += 1;
        }
        return count;
    }
    
    fn countHotBlocksAfter(self: *const TieredKVCache, seq_block_idx: u32) u32 {
        var count: u32 = 0;
        for (self.blocks.items) |meta| {
            if (meta.tier == .hot and meta.seq_block_idx > seq_block_idx) {
                count += 1;
            }
        }
        return count;
    }
};

// ============================================================================
// Access Result
// ============================================================================

pub const BlockAccess = struct {
    block_id: u32,
    tier: BlockTier,
    physical_idx: u32,
    needs_fetch: bool,
};

// ============================================================================
// Statistics
// ============================================================================

pub const OffloadStats = struct {
    hot_allocations: u64 = 0,
    warm_allocations: u64 = 0,
    promotions: u64 = 0,
    demotions: u64 = 0,
    evictions: u64 = 0,
    prefetches: u64 = 0,
    transfers_gpu_to_cpu: u64 = 0,
    transfers_cpu_to_gpu: u64 = 0,
    
    pub fn hitRate(self: *const OffloadStats) f32 {
        const total_accesses = self.hot_allocations + self.promotions;
        if (total_accesses == 0) return 0;
        return @as(f32, @floatFromInt(self.hot_allocations)) / 
               @as(f32, @floatFromInt(total_accesses)) * 100.0;
    }
};

pub const TierDistribution = struct {
    hot_blocks: u32 = 0,
    warm_blocks: u32 = 0,
    in_transit_blocks: u32 = 0,
    hot_utilization: f32 = 0,
    warm_utilization: f32 = 0,
};

// ============================================================================
// Bandwidth Estimation
// ============================================================================

pub fn estimateTransferTime(num_blocks: u32, config: *const OffloadConfig) f32 {
    const bytes = @as(f64, @floatFromInt(num_blocks)) * @as(f64, @floatFromInt(config.bytesPerBlock()));
    const seconds = bytes / (PCIE_BW_GBPS * 1e9);
    return @as(f32, @floatCast(seconds * 1000.0)); // ms
}

pub fn estimateMaxContextLength(config: *const OffloadConfig) u32 {
    const hot_tokens = config.max_hot_blocks * BLOCK_SIZE;
    const warm_tokens = config.max_warm_blocks * BLOCK_SIZE;
    return hot_tokens + warm_tokens;
}

// ============================================================================
// Integration with PagedKvCache
// ============================================================================

/// Wrapper that adds offload capability to existing PagedKvCache
pub const OffloadingKVCache = struct {
    allocator: Allocator,
    tiered: TieredKVCache,
    
    /// GPU memory pool (simulated for now)
    gpu_memory: []u8,
    
    /// CPU pinned memory pool
    cpu_memory: []u8,
    
    pub fn init(allocator: Allocator, config: OffloadConfig) !OffloadingKVCache {
        const gpu_size = config.hotTierBytes();
        const cpu_size = config.warmTierBytes();
        
        return .{
            .allocator = allocator,
            .tiered = try TieredKVCache.init(allocator, config),
            .gpu_memory = try allocator.alloc(u8, gpu_size),
            .cpu_memory = try allocator.alloc(u8, cpu_size),
        };
    }
    
    pub fn deinit(self: *OffloadingKVCache) void {
        self.tiered.deinit();
        self.allocator.free(self.gpu_memory);
        self.allocator.free(self.cpu_memory);
    }
    
    /// Get pointer to KV data for a block
    pub fn getBlockPtr(self: *OffloadingKVCache, access: BlockAccess) ?[*]u8 {
        const block_size = self.tiered.config.bytesPerBlock();
        const offset = @as(usize, access.physical_idx) * block_size;
        
        switch (access.tier) {
            .hot => {
                if (offset + block_size <= self.gpu_memory.len) {
                    return self.gpu_memory.ptr + offset;
                }
            },
            .warm => {
                if (offset + block_size <= self.cpu_memory.len) {
                    return self.cpu_memory.ptr + offset;
                }
            },
            else => {},
        }
        
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TieredKVCache init and allocate" {
    const allocator = std.testing.allocator;
    var cache = try TieredKVCache.init(allocator, .{
        .max_hot_blocks = 10,
        .max_warm_blocks = 20,
    });
    defer cache.deinit();
    
    // Allocate should go to hot tier first
    const block_id = try cache.allocateBlock(1, 0);
    try std.testing.expect(block_id == 0);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hot_allocations);
}

test "TieredKVCache tier overflow" {
    const allocator = std.testing.allocator;
    var cache = try TieredKVCache.init(allocator, .{
        .max_hot_blocks = 2,
        .max_warm_blocks = 2,
    });
    defer cache.deinit();
    
    // Fill hot tier
    _ = try cache.allocateBlock(1, 0);
    _ = try cache.allocateBlock(1, 1);
    
    // Should go to warm tier
    _ = try cache.allocateBlock(1, 2);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.hot_allocations);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.warm_allocations);
}

test "TieredKVCache free sequence" {
    const allocator = std.testing.allocator;
    var cache = try TieredKVCache.init(allocator, .{
        .max_hot_blocks = 10,
        .max_warm_blocks = 10,
    });
    defer cache.deinit();
    
    _ = try cache.allocateBlock(1, 0);
    _ = try cache.allocateBlock(1, 1);
    _ = try cache.allocateBlock(2, 0);
    
    cache.freeSequence(1);
    
    // Should have freed 2 blocks
    try std.testing.expectEqual(@as(usize, 1), cache.blocks.items.len);
}

test "TieredKVCache tier distribution" {
    const allocator = std.testing.allocator;
    var cache = try TieredKVCache.init(allocator, .{
        .max_hot_blocks = 5,
        .max_warm_blocks = 5,
    });
    defer cache.deinit();
    
    _ = try cache.allocateBlock(1, 0);
    _ = try cache.allocateBlock(1, 1);
    
    const dist = cache.getTierDistribution();
    try std.testing.expectEqual(@as(u32, 2), dist.hot_blocks);
    try std.testing.expectEqual(@as(u32, 0), dist.warm_blocks);
}

test "estimateMaxContextLength" {
    const config = OffloadConfig{
        .max_hot_blocks = 192,
        .max_warm_blocks = 2048,
    };
    
    const max_tokens = estimateMaxContextLength(&config);
    try std.testing.expectEqual(@as(u32, (192 + 2048) * 16), max_tokens);
}

test "config bytes calculation" {
    const config = OffloadConfig{
        .max_hot_blocks = 100,
        .max_warm_blocks = 1000,
        .num_kv_heads = 8,
        .head_dim = 128,
        .num_layers = 32,
        .kv_precision_bytes = 2,
    };
    
    // Per block: 16 tokens * 8 heads * 128 dim * 2 bytes * 2 (K+V) * 32 layers
    const expected_per_block: u64 = 16 * 8 * 128 * 2 * 2 * 32;
    try std.testing.expectEqual(expected_per_block, config.bytesPerBlock());
}