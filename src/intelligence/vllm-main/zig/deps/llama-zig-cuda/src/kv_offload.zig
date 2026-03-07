//! KV Cache Offloading — Multi-Tier Memory Manager
//!
//! Manages KV cache pages across two memory tiers:
//! - **Tier 0 (GPU HBM)**: Fast, limited capacity — active sequences
//! - **Tier 1 (CPU DDR)**: Slower, large capacity — inactive/preempted sequences
//!
//! When GPU memory pressure exceeds a threshold, the least-recently-used
//! KV pages are offloaded to CPU. When a sequence resumes, its pages
//! are prefetched back to GPU asynchronously.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.kv_offload);

const c = @cImport({
    @cInclude("cuda_kernels.h");
});

pub const MemoryTier = enum {
    gpu_hbm, // Tier 0: GPU High-Bandwidth Memory
    cpu_ddr, // Tier 1: CPU DDR (host pinned memory)
};

pub const PageLocation = struct {
    tier: MemoryTier,
    gpu_ptr: ?*anyopaque = null, // Non-null when on GPU
    cpu_buf: ?[]u8 = null, // Non-null when on CPU
    sequence_id: i32,
    page_id: i32,
    last_access_ns: i128, // For LRU eviction
    dirty: bool = false, // Modified since last sync
};

pub const OffloadConfig = struct {
    gpu_memory_threshold: f32 = 0.85, // Offload when GPU usage > 85%
    max_cpu_pages: usize = 16384, // Max pages in CPU tier
    page_size_bytes: usize = 262144, // 256KB per page (layers * heads * head_dim * sizeof(f32))
    prefetch_ahead: usize = 2, // Prefetch N pages ahead on reload
};

pub const OffloadManager = struct {
    allocator: Allocator,
    config: OffloadConfig,

    // Page tracking: page_id -> location
    pages: std.AutoHashMap(i32, PageLocation),

    // LRU queue for eviction (ordered by last_access_ns, ascending)
    lru_gpu_pages: std.ArrayListUnmanaged(i32),

    // Statistics
    offloads: u64 = 0,
    reloads: u64 = 0,
    prefetch_hits: u64 = 0,

    pub fn init(allocator: Allocator, config: OffloadConfig) OffloadManager {
        return .{
            .allocator = allocator,
            .config = config,
            .pages = std.AutoHashMap(i32, PageLocation).init(allocator),
            .lru_gpu_pages = .{},
        };
    }

    pub fn deinit(self: *OffloadManager) void {
        // Free all CPU-tier page buffers
        var it = self.pages.valueIterator();
        while (it.next()) |loc| {
            if (loc.cpu_buf) |buf| {
                self.allocator.free(buf);
            }
        }
        self.pages.deinit();
        self.lru_gpu_pages.deinit(self.allocator);
    }

    /// Register a GPU page for offload management
    pub fn trackPage(self: *OffloadManager, page_id: i32, sequence_id: i32, gpu_ptr: *anyopaque) !void {
        try self.pages.put(page_id, .{
            .tier = .gpu_hbm,
            .gpu_ptr = gpu_ptr,
            .cpu_buf = null,
            .sequence_id = sequence_id,
            .page_id = page_id,
            .last_access_ns = std.time.nanoTimestamp(),
        });
        try self.lru_gpu_pages.append(self.allocator, page_id);
    }

    /// Touch a page (update LRU timestamp)
    pub fn touchPage(self: *OffloadManager, page_id: i32) void {
        if (self.pages.getPtr(page_id)) |loc| {
            loc.last_access_ns = std.time.nanoTimestamp();
        }
    }

    /// Check if offloading is needed based on GPU memory pressure
    pub fn shouldOffload(self: *const OffloadManager) bool {
        var stats: c.MemoryStats = undefined;
        c.get_memory_stats(&stats);
        return stats.utilization > self.config.gpu_memory_threshold;
    }

    /// Offload the least-recently-used GPU page to CPU
    pub fn offloadLRU(self: *OffloadManager) !?i32 {
        if (self.lru_gpu_pages.items.len == 0) return null;

        // Find oldest page
        var oldest_idx: usize = 0;
        var oldest_ns: i128 = std.math.maxInt(i128);

        for (self.lru_gpu_pages.items, 0..) |pid, idx| {
            if (self.pages.get(pid)) |loc| {
                if (loc.last_access_ns < oldest_ns) {
                    oldest_ns = loc.last_access_ns;
                    oldest_idx = idx;
                }
            }
        }

        const page_id = self.lru_gpu_pages.items[oldest_idx];
        _ = self.lru_gpu_pages.orderedRemove(oldest_idx);

        try self.offloadPage(page_id);
        return page_id;
    }

    /// Offload a specific page from GPU to CPU
    fn offloadPage(self: *OffloadManager, page_id: i32) !void {
        const loc = self.pages.getPtr(page_id) orelse return;
        if (loc.tier != .gpu_hbm) return; // Already offloaded

        // Allocate CPU buffer if needed
        if (loc.cpu_buf == null) {
            loc.cpu_buf = try self.allocator.alloc(u8, self.config.page_size_bytes);
        }

        // Copy GPU -> CPU
        if (loc.gpu_ptr) |gptr| {
            _ = c.cuda_memcpy_d2h(loc.cpu_buf.?.ptr, gptr, self.config.page_size_bytes);
        }

        // Free GPU memory
        if (loc.gpu_ptr) |gptr| {
            c.cuda_free(gptr);
            loc.gpu_ptr = null;
        }

        loc.tier = .cpu_ddr;
        self.offloads += 1;
        log.debug("Offloaded page {} (seq {}) to CPU", .{ page_id, loc.sequence_id });
    }

    /// Reload a page from CPU back to GPU
    pub fn reloadPage(self: *OffloadManager, page_id: i32) !void {
        const loc = self.pages.getPtr(page_id) orelse return;
        if (loc.tier != .cpu_ddr) return; // Already on GPU

        // Allocate GPU memory
        const gpu_ptr = c.cuda_malloc(self.config.page_size_bytes);
        if (gpu_ptr == null) {
            // GPU full — try offloading another page first
            _ = try self.offloadLRU();
            const retry_ptr = c.cuda_malloc(self.config.page_size_bytes);
            if (retry_ptr == null) return error.GpuMemoryExhausted;
            loc.gpu_ptr = retry_ptr;
        } else {
            loc.gpu_ptr = gpu_ptr;
        }

        // Copy CPU -> GPU
        if (loc.cpu_buf) |cpu| {
            _ = c.cuda_memcpy_h2d(loc.gpu_ptr.?, cpu.ptr, self.config.page_size_bytes);
        }

        loc.tier = .gpu_hbm;
        loc.last_access_ns = std.time.nanoTimestamp();
        try self.lru_gpu_pages.append(self.allocator, page_id);
        self.reloads += 1;
        log.debug("Reloaded page {} (seq {}) to GPU", .{ page_id, loc.sequence_id });
    }

    /// Remove a page (sequence finished)
    pub fn removePage(self: *OffloadManager, page_id: i32) void {
        if (self.pages.fetchRemove(page_id)) |kv| {
            const loc = kv.value;
            if (loc.gpu_ptr) |gptr| c.cuda_free(gptr);
            if (loc.cpu_buf) |buf| self.allocator.free(buf);
        }
        // Remove from LRU
        for (self.lru_gpu_pages.items, 0..) |pid, idx| {
            if (pid == page_id) {
                _ = self.lru_gpu_pages.orderedRemove(idx);
                break;
            }
        }
    }

    /// Get offload statistics
    pub fn getStats(self: *const OffloadManager) struct {
        total_pages: usize,
        gpu_pages: usize,
        cpu_pages: usize,
        offloads: u64,
        reloads: u64,
    } {
        var gpu_count: usize = 0;
        var cpu_count: usize = 0;
        var it = self.pages.valueIterator();
        while (it.next()) |loc| {
            switch (loc.tier) {
                .gpu_hbm => gpu_count += 1,
                .cpu_ddr => cpu_count += 1,
            }
        }
        return .{
            .total_pages = self.pages.count(),
            .gpu_pages = gpu_count,
            .cpu_pages = cpu_count,
            .offloads = self.offloads,
            .reloads = self.reloads,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OffloadManager init/deinit" {
    var mgr = OffloadManager.init(std.testing.allocator, .{});
    defer mgr.deinit();

    try std.testing.expectEqual(@as(u64, 0), mgr.offloads);
    try std.testing.expectEqual(@as(u64, 0), mgr.reloads);
    try std.testing.expectEqual(@as(u64, 0), mgr.prefetch_hits);
    try std.testing.expectEqual(@as(usize, 0), mgr.pages.count());
    try std.testing.expectEqual(@as(usize, 0), mgr.lru_gpu_pages.items.len);
}

test "OffloadManager trackPage and touchPage" {
    var mgr = OffloadManager.init(std.testing.allocator, .{});
    defer mgr.deinit();

    // Use a stack variable as a fake GPU pointer
    var fake_gpu_mem: [64]u8 = undefined;
    const fake_ptr: *anyopaque = @ptrCast(&fake_gpu_mem);

    try mgr.trackPage(42, 1, fake_ptr);

    try std.testing.expectEqual(@as(usize, 1), mgr.pages.count());
    try std.testing.expectEqual(@as(usize, 1), mgr.lru_gpu_pages.items.len);

    const loc = mgr.pages.get(42).?;
    try std.testing.expectEqual(MemoryTier.gpu_hbm, loc.tier);
    try std.testing.expectEqual(@as(i32, 1), loc.sequence_id);
    try std.testing.expectEqual(@as(i32, 42), loc.page_id);
    try std.testing.expect(loc.gpu_ptr != null);
    try std.testing.expect(loc.cpu_buf == null);

    const ts_before = mgr.pages.get(42).?.last_access_ns;
    // Small busy-wait to ensure timestamp advances
    std.Thread.sleep(1_000);
    mgr.touchPage(42);
    const ts_after = mgr.pages.get(42).?.last_access_ns;
    try std.testing.expect(ts_after >= ts_before);
}

test "OffloadManager getStats with mixed tiers" {
    var mgr = OffloadManager.init(std.testing.allocator, .{
        .page_size_bytes = 64, // Small pages for testing
    });
    defer mgr.deinit();

    // Manually insert pages in different tiers to test getStats
    try mgr.pages.put(1, .{
        .tier = .gpu_hbm,
        .gpu_ptr = null,
        .cpu_buf = null,
        .sequence_id = 10,
        .page_id = 1,
        .last_access_ns = 100,
    });
    try mgr.pages.put(2, .{
        .tier = .cpu_ddr,
        .gpu_ptr = null,
        .cpu_buf = null,
        .sequence_id = 20,
        .page_id = 2,
        .last_access_ns = 200,
    });
    try mgr.pages.put(3, .{
        .tier = .gpu_hbm,
        .gpu_ptr = null,
        .cpu_buf = null,
        .sequence_id = 30,
        .page_id = 3,
        .last_access_ns = 300,
    });

    mgr.offloads = 5;
    mgr.reloads = 3;

    const stats = mgr.getStats();
    try std.testing.expectEqual(@as(usize, 3), stats.total_pages);
    try std.testing.expectEqual(@as(usize, 2), stats.gpu_pages);
    try std.testing.expectEqual(@as(usize, 1), stats.cpu_pages);
    try std.testing.expectEqual(@as(u64, 5), stats.offloads);
    try std.testing.expectEqual(@as(u64, 3), stats.reloads);
}

test "OffloadManager removePage cleanup" {
    var mgr = OffloadManager.init(std.testing.allocator, .{
        .page_size_bytes = 64,
    });
    defer mgr.deinit();

    // Insert a page with a CPU buffer that needs freeing
    const cpu_buf = try std.testing.allocator.alloc(u8, 64);
    try mgr.pages.put(99, .{
        .tier = .cpu_ddr,
        .gpu_ptr = null,
        .cpu_buf = cpu_buf,
        .sequence_id = 7,
        .page_id = 99,
        .last_access_ns = 500,
    });
    try mgr.lru_gpu_pages.append(std.testing.allocator, 99);

    try std.testing.expectEqual(@as(usize, 1), mgr.pages.count());
    try std.testing.expectEqual(@as(usize, 1), mgr.lru_gpu_pages.items.len);

    mgr.removePage(99);

    try std.testing.expectEqual(@as(usize, 0), mgr.pages.count());
    try std.testing.expectEqual(@as(usize, 0), mgr.lru_gpu_pages.items.len);

    // Removing a non-existent page should be a no-op
    mgr.removePage(999);
    try std.testing.expectEqual(@as(usize, 0), mgr.pages.count());
}