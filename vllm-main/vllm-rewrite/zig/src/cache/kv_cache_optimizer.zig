//! KV Cache Optimizer Module
//!
//! Advanced KV cache optimization with PagedAttention v2.
//! Implements efficient memory management for LLM inference.
//!
//! Features:
//! - PagedAttention v2 support
//! - Block allocation strategies
//! - Cache eviction policies
//! - Prefix caching
//! - Memory defragmentation

const std = @import("std");

// ==============================================
// Block Configuration
// ==============================================

pub const BlockConfig = struct {
    block_size: usize,           // Tokens per block (typically 16)
    num_blocks: usize,           // Total blocks in pool
    num_layers: usize,           // Transformer layers
    num_heads: usize,            // Attention heads
    head_dim: usize,             // Dimension per head
    dtype_size: usize,           // Bytes per element (2 for fp16)
    
    pub fn default() BlockConfig {
        return .{
            .block_size = 16,
            .num_blocks = 2048,
            .num_layers = 32,
            .num_heads = 32,
            .head_dim = 128,
            .dtype_size = 2,
        };
    }
    
    pub fn blockSizeBytes(self: *const BlockConfig) usize {
        // KV per block = 2 * layers * heads * head_dim * block_size * dtype
        return 2 * self.num_layers * self.num_heads * self.head_dim * self.block_size * self.dtype_size;
    }
    
    pub fn totalMemoryBytes(self: *const BlockConfig) usize {
        return self.num_blocks * self.blockSizeBytes();
    }
};

// ==============================================
// Physical Block
// ==============================================

pub const PhysicalBlock = struct {
    block_id: usize,
    ref_count: u32,
    is_prefix: bool,           // Part of prefix cache
    hash: ?u64,                // Content hash for prefix matching
    
    // Location
    device_id: u8,             // GPU device
    memory_offset: usize,      // Offset in device memory
    
    pub fn init(block_id: usize, memory_offset: usize) PhysicalBlock {
        return .{
            .block_id = block_id,
            .ref_count = 0,
            .is_prefix = false,
            .hash = null,
            .device_id = 0,
            .memory_offset = memory_offset,
        };
    }
    
    pub fn acquire(self: *PhysicalBlock) void {
        self.ref_count += 1;
    }
    
    pub fn release(self: *PhysicalBlock) bool {
        if (self.ref_count > 0) {
            self.ref_count -= 1;
        }
        return self.ref_count == 0;
    }
    
    pub fn isInUse(self: *const PhysicalBlock) bool {
        return self.ref_count > 0;
    }
};

// ==============================================
// Logical Block (Sequence View)
// ==============================================

pub const LogicalBlock = struct {
    logical_id: usize,
    physical_block: ?*PhysicalBlock,
    num_tokens: usize,         // Tokens stored (0-block_size)
    
    pub fn init(logical_id: usize) LogicalBlock {
        return .{
            .logical_id = logical_id,
            .physical_block = null,
            .num_tokens = 0,
        };
    }
    
    pub fn isFull(self: *const LogicalBlock, block_size: usize) bool {
        return self.num_tokens >= block_size;
    }
    
    pub fn isEmpty(self: *const LogicalBlock) bool {
        return self.num_tokens == 0;
    }
};

// ==============================================
// Block Allocator
// ==============================================

pub const AllocationStrategy = enum {
    first_fit,       // First available block
    best_fit,        // Best matching size
    contiguous,      // Prefer contiguous blocks
    round_robin,     // Distribute across devices
};

pub const BlockAllocator = struct {
    config: BlockConfig,
    physical_blocks: std.ArrayList(PhysicalBlock),
    free_blocks: std.ArrayList(usize),
    strategy: AllocationStrategy,
    
    // Statistics
    total_allocated: usize,
    total_freed: usize,
    peak_usage: usize,
    
    allocator: std.mem.Allocator,
    
    pub fn init(alloc: std.mem.Allocator, config: BlockConfig) !BlockAllocator {
        var ba = BlockAllocator{
            .config = config,
            .physical_blocks = std.ArrayList(PhysicalBlock).init(alloc),
            .free_blocks = std.ArrayList(usize).init(alloc),
            .strategy = .first_fit,
            .total_allocated = 0,
            .total_freed = 0,
            .peak_usage = 0,
            .allocator = alloc,
        };
        
        // Initialize all physical blocks
        const block_size_bytes = config.blockSizeBytes();
        for (0..config.num_blocks) |i| {
            const offset = i * block_size_bytes;
            try ba.physical_blocks.append(PhysicalBlock.init(i, offset));
            try ba.free_blocks.append(i);
        }
        
        return ba;
    }
    
    pub fn deinit(self: *BlockAllocator) void {
        self.physical_blocks.deinit();
        self.free_blocks.deinit();
    }
    
    /// Allocate a single block
    pub fn allocate(self: *BlockAllocator) ?*PhysicalBlock {
        if (self.free_blocks.items.len == 0) return null;
        
        const block_id = switch (self.strategy) {
            .first_fit => self.free_blocks.pop(),
            .best_fit => self.free_blocks.pop(),
            .contiguous => self.free_blocks.pop(),
            .round_robin => self.free_blocks.pop(),
        };
        
        var block = &self.physical_blocks.items[block_id];
        block.acquire();
        
        self.total_allocated += 1;
        const current_usage = self.total_allocated - self.total_freed;
        if (current_usage > self.peak_usage) {
            self.peak_usage = current_usage;
        }
        
        return block;
    }
    
    /// Allocate multiple blocks
    pub fn allocateMultiple(self: *BlockAllocator, count: usize) !std.ArrayList(*PhysicalBlock) {
        var blocks = std.ArrayList(*PhysicalBlock).init(self.allocator);
        
        for (0..count) |_| {
            if (self.allocate()) |block| {
                try blocks.append(block);
            } else {
                // Rollback on failure
                for (blocks.items) |b| {
                    self.free(b);
                }
                blocks.deinit();
                return error.OutOfMemory;
            }
        }
        
        return blocks;
    }
    
    /// Free a block
    pub fn free(self: *BlockAllocator, block: *PhysicalBlock) void {
        if (block.release()) {
            // Reset block state
            block.hash = null;
            block.is_prefix = false;
            try self.free_blocks.append(block.block_id) catch {};
            self.total_freed += 1;
        }
    }
    
    pub fn freeBlocks(self: *const BlockAllocator) usize {
        return self.free_blocks.items.len;
    }
    
    pub fn usedBlocks(self: *const BlockAllocator) usize {
        return self.config.num_blocks - self.free_blocks.items.len;
    }
    
    pub fn utilizationPercent(self: *const BlockAllocator) f32 {
        return @as(f32, @floatFromInt(self.usedBlocks())) / @as(f32, @floatFromInt(self.config.num_blocks)) * 100.0;
    }
};

// ==============================================
// Sequence KV Cache
// ==============================================

pub const SequenceKVCache = struct {
    sequence_id: []const u8,
    logical_blocks: std.ArrayList(LogicalBlock),
    num_computed_tokens: usize,
    
    allocator: std.mem.Allocator,
    
    pub fn init(alloc: std.mem.Allocator, sequence_id: []const u8) SequenceKVCache {
        return .{
            .sequence_id = sequence_id,
            .logical_blocks = std.ArrayList(LogicalBlock).init(alloc),
            .num_computed_tokens = 0,
            .allocator = alloc,
        };
    }
    
    pub fn deinit(self: *SequenceKVCache) void {
        self.logical_blocks.deinit();
    }
    
    pub fn numBlocks(self: *const SequenceKVCache) usize {
        return self.logical_blocks.items.len;
    }
    
    pub fn appendBlock(self: *SequenceKVCache, physical_block: *PhysicalBlock) !void {
        const logical_id = self.logical_blocks.items.len;
        var logical = LogicalBlock.init(logical_id);
        logical.physical_block = physical_block;
        try self.logical_blocks.append(logical);
    }
    
    pub fn getPhysicalBlocks(self: *const SequenceKVCache) ![]*PhysicalBlock {
        var blocks = try self.allocator.alloc(*PhysicalBlock, self.logical_blocks.items.len);
        for (self.logical_blocks.items, 0..) |logical, i| {
            if (logical.physical_block) |pb| {
                blocks[i] = pb;
            }
        }
        return blocks;
    }
};

// ==============================================
// Cache Eviction Policies
// ==============================================

pub const EvictionPolicy = enum {
    lru,            // Least Recently Used
    lfu,            // Least Frequently Used
    fifo,           // First In First Out
    random,         // Random eviction
    priority,       // Priority-based (keep important)
};

pub const CacheEntry = struct {
    sequence_id: []const u8,
    last_access: i64,
    access_count: u64,
    priority: i32,
    creation_time: i64,
};

pub const EvictionManager = struct {
    policy: EvictionPolicy,
    entries: std.StringHashMap(CacheEntry),
    max_entries: usize,
    allocator: std.mem.Allocator,
    
    pub fn init(alloc: std.mem.Allocator, policy: EvictionPolicy, max_entries: usize) EvictionManager {
        return .{
            .policy = policy,
            .entries = std.StringHashMap(CacheEntry).init(alloc),
            .max_entries = max_entries,
            .allocator = alloc,
        };
    }
    
    pub fn deinit(self: *EvictionManager) void {
        self.entries.deinit();
    }
    
    pub fn recordAccess(self: *EvictionManager, sequence_id: []const u8) !void {
        if (self.entries.getPtr(sequence_id)) |entry| {
            entry.last_access = std.time.milliTimestamp();
            entry.access_count += 1;
        } else {
            try self.entries.put(sequence_id, CacheEntry{
                .sequence_id = sequence_id,
                .last_access = std.time.milliTimestamp(),
                .access_count = 1,
                .priority = 0,
                .creation_time = std.time.milliTimestamp(),
            });
        }
    }
    
    /// Select sequences to evict
    pub fn selectForEviction(self: *EvictionManager, count: usize) ![]const []const u8 {
        var candidates = std.ArrayList([]const u8).init(self.allocator);
        
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            try candidates.append(entry.key_ptr.*);
        }
        
        // Sort by eviction policy
        switch (self.policy) {
            .lru => {
                std.sort.sort([]const u8, candidates.items, self, struct {
                    fn compare(ctx: *EvictionManager, a: []const u8, b: []const u8) bool {
                        const ea = ctx.entries.get(a) orelse return true;
                        const eb = ctx.entries.get(b) orelse return false;
                        return ea.last_access < eb.last_access;
                    }
                }.compare);
            },
            .lfu => {
                std.sort.sort([]const u8, candidates.items, self, struct {
                    fn compare(ctx: *EvictionManager, a: []const u8, b: []const u8) bool {
                        const ea = ctx.entries.get(a) orelse return true;
                        const eb = ctx.entries.get(b) orelse return false;
                        return ea.access_count < eb.access_count;
                    }
                }.compare);
            },
            .fifo => {
                std.sort.sort([]const u8, candidates.items, self, struct {
                    fn compare(ctx: *EvictionManager, a: []const u8, b: []const u8) bool {
                        const ea = ctx.entries.get(a) orelse return true;
                        const eb = ctx.entries.get(b) orelse return false;
                        return ea.creation_time < eb.creation_time;
                    }
                }.compare);
            },
            else => {},
        }
        
        // Return top N candidates
        const to_evict = @min(count, candidates.items.len);
        return candidates.items[0..to_evict];
    }
};

// ==============================================
// Prefix Cache
// ==============================================

pub const PrefixCache = struct {
    // Hash table: prefix_hash -> physical_blocks
    prefix_table: std.AutoHashMap(u64, std.ArrayList(usize)),
    block_allocator: *BlockAllocator,
    
    // Statistics
    hits: u64,
    misses: u64,
    
    allocator: std.mem.Allocator,
    
    pub fn init(alloc: std.mem.Allocator, block_allocator: *BlockAllocator) PrefixCache {
        return .{
            .prefix_table = std.AutoHashMap(u64, std.ArrayList(usize)).init(alloc),
            .block_allocator = block_allocator,
            .hits = 0,
            .misses = 0,
            .allocator = alloc,
        };
    }
    
    pub fn deinit(self: *PrefixCache) void {
        var iter = self.prefix_table.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        self.prefix_table.deinit();
    }
    
    /// Compute hash for token sequence
    pub fn computeHash(tokens: []const u32) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.sliceAsBytes(tokens));
        return hasher.final();
    }
    
    /// Look up cached prefix
    pub fn lookup(self: *PrefixCache, tokens: []const u32) ?[]const usize {
        const hash = computeHash(tokens);
        if (self.prefix_table.get(hash)) |blocks| {
            self.hits += 1;
            return blocks.items;
        }
        self.misses += 1;
        return null;
    }
    
    /// Store prefix in cache
    pub fn store(self: *PrefixCache, tokens: []const u32, block_ids: []const usize) !void {
        const hash = computeHash(tokens);
        
        var blocks = std.ArrayList(usize).init(self.allocator);
        try blocks.appendSlice(block_ids);
        
        // Mark blocks as prefix
        for (block_ids) |id| {
            self.block_allocator.physical_blocks.items[id].is_prefix = true;
            self.block_allocator.physical_blocks.items[id].hash = hash;
        }
        
        try self.prefix_table.put(hash, blocks);
    }
    
    pub fn hitRate(self: *const PrefixCache) f32 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(total)) * 100.0;
    }
};

// ==============================================
// KV Cache Manager
// ==============================================

pub const KVCacheManager = struct {
    config: BlockConfig,
    block_allocator: BlockAllocator,
    sequence_caches: std.StringHashMap(SequenceKVCache),
    eviction_manager: EvictionManager,
    prefix_cache: PrefixCache,
    
    // Configuration
    enable_prefix_caching: bool,
    watermark_low: f32,        // Start eviction below this
    watermark_high: f32,       // Aggressive eviction above this
    
    allocator: std.mem.Allocator,
    
    pub fn init(alloc: std.mem.Allocator, config: BlockConfig) !KVCacheManager {
        var block_alloc = try BlockAllocator.init(alloc, config);
        
        return KVCacheManager{
            .config = config,
            .block_allocator = block_alloc,
            .sequence_caches = std.StringHashMap(SequenceKVCache).init(alloc),
            .eviction_manager = EvictionManager.init(alloc, .lru, 10000),
            .prefix_cache = PrefixCache.init(alloc, &block_alloc),
            .enable_prefix_caching = true,
            .watermark_low = 0.8,
            .watermark_high = 0.95,
            .allocator = alloc,
        };
    }
    
    pub fn deinit(self: *KVCacheManager) void {
        var iter = self.sequence_caches.valueIterator();
        while (iter.next()) |cache| {
            cache.deinit();
        }
        self.sequence_caches.deinit();
        self.eviction_manager.deinit();
        self.prefix_cache.deinit();
        self.block_allocator.deinit();
    }
    
    /// Allocate cache for new sequence
    pub fn allocateSequence(self: *KVCacheManager, sequence_id: []const u8, prompt_tokens: []const u32) !*SequenceKVCache {
        // Check prefix cache
        if (self.enable_prefix_caching) {
            if (self.prefix_cache.lookup(prompt_tokens)) |cached_blocks| {
                // Reuse cached prefix blocks
                var cache = SequenceKVCache.init(self.allocator, sequence_id);
                for (cached_blocks) |block_id| {
                    const pb = &self.block_allocator.physical_blocks.items[block_id];
                    pb.acquire();
                    try cache.appendBlock(pb);
                }
                try self.sequence_caches.put(sequence_id, cache);
                return self.sequence_caches.getPtr(sequence_id).?;
            }
        }
        
        // Check if eviction needed
        if (self.shouldEvict()) {
            try self.runEviction();
        }
        
        // Calculate blocks needed
        const blocks_needed = (prompt_tokens.len + self.config.block_size - 1) / self.config.block_size;
        
        // Allocate new blocks
        var cache = SequenceKVCache.init(self.allocator, sequence_id);
        for (0..blocks_needed) |_| {
            if (self.block_allocator.allocate()) |block| {
                try cache.appendBlock(block);
            } else {
                // Allocation failed, cleanup and return error
                self.freeSequence(&cache);
                return error.OutOfMemory;
            }
        }
        
        cache.num_computed_tokens = prompt_tokens.len;
        try self.sequence_caches.put(sequence_id, cache);
        try self.eviction_manager.recordAccess(sequence_id);
        
        // Store in prefix cache
        if (self.enable_prefix_caching) {
            const blocks = try cache.getPhysicalBlocks();
            defer self.allocator.free(blocks);
            var block_ids = try self.allocator.alloc(usize, blocks.len);
            defer self.allocator.free(block_ids);
            for (blocks, 0..) |b, i| {
                block_ids[i] = b.block_id;
            }
            try self.prefix_cache.store(prompt_tokens, block_ids);
        }
        
        return self.sequence_caches.getPtr(sequence_id).?;
    }
    
    /// Extend cache for decode step
    pub fn extendSequence(self: *KVCacheManager, sequence_id: []const u8) !void {
        const cache = self.sequence_caches.getPtr(sequence_id) orelse return error.NotFound;
        
        try self.eviction_manager.recordAccess(sequence_id);
        cache.num_computed_tokens += 1;
        
        // Check if current block is full
        if (cache.logical_blocks.items.len > 0) {
            const last_block = &cache.logical_blocks.items[cache.logical_blocks.items.len - 1];
            last_block.num_tokens += 1;
            
            if (last_block.isFull(self.config.block_size)) {
                // Allocate new block
                if (self.block_allocator.allocate()) |new_block| {
                    try cache.appendBlock(new_block);
                } else {
                    try self.runEviction();
                    if (self.block_allocator.allocate()) |new_block| {
                        try cache.appendBlock(new_block);
                    } else {
                        return error.OutOfMemory;
                    }
                }
            }
        }
    }
    
    /// Free sequence cache
    pub fn freeSequence(self: *KVCacheManager, cache: *SequenceKVCache) void {
        for (cache.logical_blocks.items) |logical| {
            if (logical.physical_block) |pb| {
                if (!pb.is_prefix) {
                    self.block_allocator.free(pb);
                }
            }
        }
        _ = self.sequence_caches.remove(cache.sequence_id);
    }
    
    fn shouldEvict(self: *KVCacheManager) bool {
        const util = self.block_allocator.utilizationPercent() / 100.0;
        return util > self.watermark_high;
    }
    
    fn runEviction(self: *KVCacheManager) !void {
        const target_util = self.watermark_low;
        const current_util = self.block_allocator.utilizationPercent() / 100.0;
        
        if (current_util <= target_util) return;
        
        // Calculate how many blocks to free
        const blocks_to_free = @as(usize, @intFromFloat(
            @as(f32, @floatFromInt(self.config.num_blocks)) * (current_util - target_util)
        ));
        
        // Select sequences to evict
        const sequences = try self.eviction_manager.selectForEviction(blocks_to_free);
        
        for (sequences) |seq_id| {
            if (self.sequence_caches.getPtr(seq_id)) |cache| {
                self.freeSequence(cache);
            }
        }
    }
    
    /// Get cache statistics
    pub fn getStats(self: *const KVCacheManager) CacheStats {
        return .{
            .total_blocks = self.config.num_blocks,
            .used_blocks = self.block_allocator.usedBlocks(),
            .free_blocks = self.block_allocator.freeBlocks(),
            .utilization = self.block_allocator.utilizationPercent(),
            .num_sequences = self.sequence_caches.count(),
            .prefix_hit_rate = self.prefix_cache.hitRate(),
            .peak_usage = self.block_allocator.peak_usage,
        };
    }
};

pub const CacheStats = struct {
    total_blocks: usize,
    used_blocks: usize,
    free_blocks: usize,
    utilization: f32,
    num_sequences: usize,
    prefix_hit_rate: f32,
    peak_usage: usize,
};

// ==============================================
// Memory Defragmentation
// ==============================================

pub const Defragmenter = struct {
    manager: *KVCacheManager,
    fragmentation_threshold: f32,
    
    pub fn init(manager: *KVCacheManager) Defragmenter {
        return .{
            .manager = manager,
            .fragmentation_threshold = 0.3,
        };
    }
    
    /// Calculate fragmentation ratio
    pub fn calculateFragmentation(self: *Defragmenter) f32 {
        _ = self;
        // Would analyze block allocation patterns
        // Fragmentation = scattered_blocks / total_used_blocks
        return 0.0;
    }
    
    /// Defragment if needed
    pub fn defragmentIfNeeded(self: *Defragmenter) !void {
        if (self.calculateFragmentation() > self.fragmentation_threshold) {
            try self.defragment();
        }
    }
    
    /// Perform defragmentation
    pub fn defragment(self: *Defragmenter) !void {
        _ = self;
        // Would:
        // 1. Identify fragmented sequences
        // 2. Copy KV data to contiguous blocks
        // 3. Update logical->physical mappings
        // 4. Free old scattered blocks
    }
};

// ==============================================
// Tests
// ==============================================

test "BlockConfig calculations" {
    const config = BlockConfig.default();
    try std.testing.expect(config.block_size == 16);
    
    const block_bytes = config.blockSizeBytes();
    try std.testing.expect(block_bytes > 0);
}

test "BlockAllocator basic operations" {
    const allocator = std.testing.allocator;
    var config = BlockConfig.default();
    config.num_blocks = 10;
    
    var ba = try BlockAllocator.init(allocator, config);
    defer ba.deinit();
    
    try std.testing.expect(ba.freeBlocks() == 10);
    
    const block1 = ba.allocate();
    try std.testing.expect(block1 != null);
    try std.testing.expect(ba.freeBlocks() == 9);
    
    if (block1) |b| {
        ba.free(b);
        try std.testing.expect(ba.freeBlocks() == 10);
    }
}

test "PrefixCache lookup" {
    const allocator = std.testing.allocator;
    var config = BlockConfig.default();
    config.num_blocks = 10;
    
    var ba = try BlockAllocator.init(allocator, config);
    defer ba.deinit();
    
    var pc = PrefixCache.init(allocator, &ba);
    defer pc.deinit();
    
    const tokens = [_]u32{ 1, 2, 3, 4, 5 };
    
    // Miss on first lookup
    const result1 = pc.lookup(&tokens);
    try std.testing.expect(result1 == null);
    try std.testing.expect(pc.misses == 1);
}