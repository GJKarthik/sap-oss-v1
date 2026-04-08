//! GPU Memory Pool - Phase 1 Optimization
//!
//! Pre-allocated memory pools to avoid cudaMalloc overhead during inference.
//! Reduces allocation latency from ~100μs to <1μs.

const std = @import("std");
const Allocator = std.mem.Allocator;

// C FFI for CUDA memory
const c = @cImport({
    @cInclude("cuda_kernels.h");
});

// ============================================================================
// Memory Pool Configuration
// ============================================================================

pub const PoolConfig = struct {
    /// Total pool size in bytes (default: 2GB)
    total_size: usize = 2 * 1024 * 1024 * 1024,
    
    /// Minimum allocation granularity (default: 256 bytes for alignment)
    min_alloc_size: usize = 256,
    
    /// Maximum number of concurrent allocations
    max_allocations: usize = 1024,
    
    /// Pre-allocate common sizes for KV cache
    kv_cache_prealloc: bool = true,
    
    /// KV cache size per layer (for 7B model with 4096 context)
    kv_cache_size_per_layer: usize = 32 * 4096 * 128 * 2, // 32 heads * seq * head_dim * 2 (K+V)
    
    /// Number of layers to pre-allocate KV cache for
    num_layers: usize = 32,
};

// ============================================================================
// Memory Block
// ============================================================================

const MemoryBlock = struct {
    ptr: ?*anyopaque,
    size: usize,
    offset: usize,
    in_use: bool,
    
    pub fn init(ptr: ?*anyopaque, size: usize, offset: usize) MemoryBlock {
        return .{
            .ptr = ptr,
            .size = size,
            .offset = offset,
            .in_use = false,
        };
    }
};

// ============================================================================
// GPU Memory Pool
// ============================================================================

pub const GpuMemoryPool = struct {
    const Self = @This();
    
    /// Base GPU pointer for entire pool
    base_ptr: ?*anyopaque,
    
    /// Total pool size
    total_size: usize,
    
    /// Current allocation offset
    current_offset: usize,
    
    /// Free list for recycled blocks
    free_blocks: std.ArrayList(MemoryBlock),
    
    /// Active allocations
    active_blocks: std.AutoHashMap(usize, MemoryBlock),
    
    /// Configuration
    config: PoolConfig,
    
    /// Statistics
    stats: PoolStats,
    
    /// Allocator for internal data structures
    allocator: Allocator,
    
    /// Pre-allocated KV cache blocks
    kv_cache_blocks: []?*anyopaque,
    
    pub const PoolStats = struct {
        total_allocations: u64 = 0,
        total_frees: u64 = 0,
        current_used: usize = 0,
        peak_used: usize = 0,
        fragmentation_ratio: f32 = 0.0,
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,
    };
    
    /// Initialize the memory pool
    pub fn init(allocator: Allocator, config: PoolConfig) !Self {
        // Allocate GPU memory pool
        const base_ptr = c.cuda_malloc(config.total_size);
        if (base_ptr == null) {
            return error.GpuMemoryPoolAllocFailed;
        }
        
        var self = Self{
            .base_ptr = base_ptr,
            .total_size = config.total_size,
            .current_offset = 0,
            .free_blocks = std.ArrayList(MemoryBlock).init(allocator),
            .active_blocks = std.AutoHashMap(usize, MemoryBlock).init(allocator),
            .config = config,
            .stats = .{},
            .allocator = allocator,
            .kv_cache_blocks = &.{},
        };
        
        // Pre-allocate KV cache if enabled
        if (config.kv_cache_prealloc) {
            self.kv_cache_blocks = try allocator.alloc(?*anyopaque, config.num_layers * 2);
            for (0..config.num_layers) |layer| {
                // K cache
                self.kv_cache_blocks[layer * 2] = try self.allocInternal(config.kv_cache_size_per_layer / 2);
                // V cache
                self.kv_cache_blocks[layer * 2 + 1] = try self.allocInternal(config.kv_cache_size_per_layer / 2);
            }
        }
        
        return self;
    }
    
    /// Shutdown and free all memory
    pub fn deinit(self: *Self) void {
        if (self.base_ptr) |ptr| {
            c.cuda_free(ptr);
            self.base_ptr = null;
        }
        
        self.free_blocks.deinit();
        self.active_blocks.deinit();
        
        if (self.kv_cache_blocks.len > 0) {
            self.allocator.free(self.kv_cache_blocks);
        }
    }
    
    /// Allocate from pool (internal)
    fn allocInternal(self: *Self, requested_size: usize) !?*anyopaque {
        // Round up to minimum allocation size
        const size = alignSize(requested_size, self.config.min_alloc_size);
        
        // First, check free list for suitable block
        var best_fit_idx: ?usize = null;
        var best_fit_size: usize = std.math.maxInt(usize);
        
        for (self.free_blocks.items, 0..) |block, idx| {
            if (!block.in_use and block.size >= size and block.size < best_fit_size) {
                best_fit_idx = idx;
                best_fit_size = block.size;
            }
        }
        
        // Use best-fit block from free list
        if (best_fit_idx) |idx| {
            var block = &self.free_blocks.items[idx];
            block.in_use = true;
            self.stats.cache_hits += 1;
            self.stats.total_allocations += 1;
            self.stats.current_used += block.size;
            self.stats.peak_used = @max(self.stats.peak_used, self.stats.current_used);
            
            try self.active_blocks.put(@intFromPtr(block.ptr), block.*);
            return block.ptr;
        }
        
        // Allocate from pool end
        if (self.current_offset + size > self.total_size) {
            return error.GpuMemoryPoolExhausted;
        }
        
        const ptr_int = @intFromPtr(self.base_ptr) + self.current_offset;
        const ptr: ?*anyopaque = @ptrFromInt(ptr_int);
        
        const block = MemoryBlock.init(ptr, size, self.current_offset);
        try self.active_blocks.put(ptr_int, block);
        
        self.current_offset += size;
        self.stats.cache_misses += 1;
        self.stats.total_allocations += 1;
        self.stats.current_used += size;
        self.stats.peak_used = @max(self.stats.peak_used, self.stats.current_used);
        
        return ptr;
    }
    
    /// Allocate memory from pool
    pub fn alloc(self: *Self, comptime T: type, count: usize) ![]T {
        const size = @sizeOf(T) * count;
        const ptr = try self.allocInternal(size);
        
        if (ptr) |p| {
            const typed_ptr: [*]T = @ptrCast(@alignCast(p));
            return typed_ptr[0..count];
        }
        return error.GpuAllocFailed;
    }
    
    /// Free memory back to pool (adds to free list)
    pub fn free(self: *Self, ptr: anytype) void {
        const raw_ptr = @as(*anyopaque, @ptrCast(ptr.ptr));
        const ptr_int = @intFromPtr(raw_ptr);
        
        if (self.active_blocks.get(ptr_int)) |block| {
            var free_block = block;
            free_block.in_use = false;
            
            self.free_blocks.append(free_block) catch {};
            _ = self.active_blocks.remove(ptr_int);
            
            self.stats.total_frees += 1;
            self.stats.current_used -= block.size;
        }
    }
    
    /// Get KV cache pointer for a layer
    pub fn getKvCache(self: *Self, layer: usize, is_value: bool) ?*anyopaque {
        if (layer >= self.config.num_layers) return null;
        const idx = layer * 2 + @as(usize, if (is_value) 1 else 0);
        return self.kv_cache_blocks[idx];
    }
    
    /// Reset pool (free all, keep base allocation)
    pub fn reset(self: *Self) void {
        self.free_blocks.clearRetainingCapacity();
        self.active_blocks.clearRetainingCapacity();
        self.current_offset = 0;
        
        // Re-setup KV cache if enabled
        if (self.config.kv_cache_prealloc) {
            var offset: usize = 0;
            for (0..self.config.num_layers) |layer| {
                const kv_size = self.config.kv_cache_size_per_layer / 2;
                const ptr_int = @intFromPtr(self.base_ptr) + offset;
                self.kv_cache_blocks[layer * 2] = @ptrFromInt(ptr_int);
                offset += kv_size;
                
                const ptr_int_v = @intFromPtr(self.base_ptr) + offset;
                self.kv_cache_blocks[layer * 2 + 1] = @ptrFromInt(ptr_int_v);
                offset += kv_size;
            }
            self.current_offset = offset;
        }
        
        self.stats.current_used = self.current_offset;
    }
    
    /// Get pool statistics
    pub fn getStats(self: *const Self) PoolStats {
        return self.stats;
    }
    
    /// Calculate fragmentation ratio
    pub fn getFragmentation(self: *const Self) f32 {
        if (self.free_blocks.items.len == 0) return 0.0;
        
        var free_size: usize = 0;
        for (self.free_blocks.items) |block| {
            if (!block.in_use) free_size += block.size;
        }
        
        const total_allocated = self.current_offset;
        if (total_allocated == 0) return 0.0;
        
        return @as(f32, @floatFromInt(free_size)) / @as(f32, @floatFromInt(total_allocated));
    }
    
    /// Helper: align size to boundary
    fn alignSize(size: usize, alignment: usize) usize {
        return (size + alignment - 1) & ~(alignment - 1);
    }
};

// ============================================================================
// Global Pool Instance
// ============================================================================

var g_pool: ?GpuMemoryPool = null;

pub fn getGlobalPool() !*GpuMemoryPool {
    if (g_pool == null) {
        g_pool = try GpuMemoryPool.init(std.heap.page_allocator, .{});
    }
    return &g_pool.?;
}

pub fn shutdownGlobalPool() void {
    if (g_pool) |*pool| {
        pool.deinit();
        g_pool = null;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "memory pool basic alloc/free" {
    var pool = try GpuMemoryPool.init(std.testing.allocator, .{
        .total_size = 1024 * 1024, // 1MB for testing
        .kv_cache_prealloc = false,
    });
    defer pool.deinit();
    
    // Test allocation
    const data = try pool.alloc(f32, 1024);
    try std.testing.expectEqual(@as(usize, 1024), data.len);
    
    // Free and re-allocate (should hit cache)
    pool.free(data);
    const data2 = try pool.alloc(f32, 1024);
    try std.testing.expectEqual(@as(usize, 1024), data2.len);
    try std.testing.expect(pool.stats.cache_hits > 0);
}