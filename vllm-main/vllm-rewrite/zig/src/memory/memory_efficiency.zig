//! Memory Efficiency Module
//!
//! Provides tools for efficient memory management during inference.
//! Includes tracking, budgets, garbage collection, and analysis.
//!
//! Key Features:
//! - Real-time memory tracking
//! - Budget enforcement
//! - Automatic cache eviction
//! - Memory snapshots
//! - Fragmentation analysis

const std = @import("std");
const gpu = @import("../device/gpu.zig");

// ==============================================
// Memory Tracker
// ==============================================

pub const MemoryTracker = struct {
    allocator: std.mem.Allocator,
    
    // Current allocations
    allocations: std.AutoHashMap(usize, AllocationInfo),
    
    // Statistics
    current_bytes: std.atomic.Value(usize),
    peak_bytes: std.atomic.Value(usize),
    total_allocations: std.atomic.Value(u64),
    total_deallocations: std.atomic.Value(u64),
    
    // Per-category tracking
    category_bytes: std.EnumArray(MemoryCategory, std.atomic.Value(usize)),
    
    // Enabled flag
    enabled: bool,
    
    pub fn init(allocator: std.mem.Allocator, enabled: bool) MemoryTracker {
        var category_bytes = std.EnumArray(MemoryCategory, std.atomic.Value(usize)).initFill(std.atomic.Value(usize).init(0));
        _ = &category_bytes;
        
        return .{
            .allocator = allocator,
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(allocator),
            .current_bytes = std.atomic.Value(usize).init(0),
            .peak_bytes = std.atomic.Value(usize).init(0),
            .total_allocations = std.atomic.Value(u64).init(0),
            .total_deallocations = std.atomic.Value(u64).init(0),
            .category_bytes = std.EnumArray(MemoryCategory, std.atomic.Value(usize)).initFill(std.atomic.Value(usize).init(0)),
            .enabled = enabled,
        };
    }
    
    pub fn deinit(self: *MemoryTracker) void {
        self.allocations.deinit();
    }
    
    pub fn trackAllocation(
        self: *MemoryTracker,
        ptr: usize,
        size: usize,
        category: MemoryCategory,
    ) void {
        if (!self.enabled) return;
        
        const info = AllocationInfo{
            .size = size,
            .category = category,
            .timestamp = std.time.milliTimestamp(),
        };
        
        self.allocations.put(ptr, info) catch {};
        
        // Update stats
        const new_total = self.current_bytes.fetchAdd(size, .monotonic) + size;
        _ = self.total_allocations.fetchAdd(1, .monotonic);
        _ = self.category_bytes.getPtr(category).fetchAdd(size, .monotonic);
        
        // Update peak
        var current_peak = self.peak_bytes.load(.monotonic);
        while (new_total > current_peak) {
            const result = self.peak_bytes.cmpxchgWeak(current_peak, new_total, .monotonic, .monotonic);
            if (result) |old| {
                current_peak = old;
            } else {
                break;
            }
        }
    }
    
    pub fn trackDeallocation(self: *MemoryTracker, ptr: usize) void {
        if (!self.enabled) return;
        
        if (self.allocations.fetchRemove(ptr)) |entry| {
            const info = entry.value;
            _ = self.current_bytes.fetchSub(info.size, .monotonic);
            _ = self.total_deallocations.fetchAdd(1, .monotonic);
            _ = self.category_bytes.getPtr(info.category).fetchSub(info.size, .monotonic);
        }
    }
    
    pub fn getStats(self: *MemoryTracker) MemoryStats {
        return .{
            .current_bytes = self.current_bytes.load(.monotonic),
            .peak_bytes = self.peak_bytes.load(.monotonic),
            .total_allocations = self.total_allocations.load(.monotonic),
            .total_deallocations = self.total_deallocations.load(.monotonic),
            .active_allocations = self.allocations.count(),
        };
    }
    
    pub fn getCategoryBytes(self: *MemoryTracker, category: MemoryCategory) usize {
        return self.category_bytes.get(category).load(.monotonic);
    }
};

pub const AllocationInfo = struct {
    size: usize,
    category: MemoryCategory,
    timestamp: i64,
};

pub const MemoryCategory = enum {
    model_weights,
    kv_cache,
    activations,
    workspace,
    other,
};

pub const MemoryStats = struct {
    current_bytes: usize,
    peak_bytes: usize,
    total_allocations: u64,
    total_deallocations: u64,
    active_allocations: usize,
    
    pub fn print(self: MemoryStats) void {
        const mb = 1024 * 1024;
        std.debug.print("\n═══════════════════════════════════\n", .{});
        std.debug.print("         MEMORY STATISTICS          \n", .{});
        std.debug.print("═══════════════════════════════════\n", .{});
        std.debug.print("Current:     {d:.2} MB\n", .{@as(f64, @floatFromInt(self.current_bytes)) / mb});
        std.debug.print("Peak:        {d:.2} MB\n", .{@as(f64, @floatFromInt(self.peak_bytes)) / mb});
        std.debug.print("Allocations: {d}\n", .{self.total_allocations});
        std.debug.print("Frees:       {d}\n", .{self.total_deallocations});
        std.debug.print("Active:      {d}\n", .{self.active_allocations});
    }
};

// ==============================================
// Memory Budget
// ==============================================

pub const MemoryBudget = struct {
    total_budget: usize,
    reserved: usize,
    
    // Per-category limits
    category_limits: std.EnumArray(MemoryCategory, usize),
    category_used: std.EnumArray(MemoryCategory, std.atomic.Value(usize)),
    
    // Callbacks
    on_budget_exceeded: ?*const fn (category: MemoryCategory, requested: usize, available: usize) void,
    
    pub fn init(total_budget: usize) MemoryBudget {
        // Default allocation: 60% weights, 30% KV, 5% activations, 5% other
        var limits = std.EnumArray(MemoryCategory, usize).initUndefined();
        limits.set(.model_weights, total_budget * 60 / 100);
        limits.set(.kv_cache, total_budget * 30 / 100);
        limits.set(.activations, total_budget * 5 / 100);
        limits.set(.workspace, total_budget * 3 / 100);
        limits.set(.other, total_budget * 2 / 100);
        
        return .{
            .total_budget = total_budget,
            .reserved = 0,
            .category_limits = limits,
            .category_used = std.EnumArray(MemoryCategory, std.atomic.Value(usize)).initFill(std.atomic.Value(usize).init(0)),
            .on_budget_exceeded = null,
        };
    }
    
    pub fn canAllocate(self: *MemoryBudget, size: usize, category: MemoryCategory) bool {
        const current = self.category_used.get(category).load(.monotonic);
        const limit = self.category_limits.get(category);
        return current + size <= limit;
    }
    
    pub fn reserve(self: *MemoryBudget, size: usize, category: MemoryCategory) !void {
        if (!self.canAllocate(size, category)) {
            if (self.on_budget_exceeded) |callback| {
                const available = self.category_limits.get(category) - self.category_used.get(category).load(.monotonic);
                callback(category, size, available);
            }
            return error.BudgetExceeded;
        }
        
        _ = self.category_used.getPtr(category).fetchAdd(size, .monotonic);
        self.reserved += size;
    }
    
    pub fn release(self: *MemoryBudget, size: usize, category: MemoryCategory) void {
        _ = self.category_used.getPtr(category).fetchSub(size, .monotonic);
        self.reserved -= @min(self.reserved, size);
    }
    
    pub fn getUtilization(self: *MemoryBudget, category: MemoryCategory) f32 {
        const used = self.category_used.get(category).load(.monotonic);
        const limit = self.category_limits.get(category);
        if (limit == 0) return 0;
        return @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(limit));
    }
    
    pub fn getTotalUtilization(self: *MemoryBudget) f32 {
        var total_used: usize = 0;
        inline for (std.meta.fields(MemoryCategory)) |field| {
            const cat = @as(MemoryCategory, @enumFromInt(field.value));
            total_used += self.category_used.get(cat).load(.monotonic);
        }
        return @as(f32, @floatFromInt(total_used)) / @as(f32, @floatFromInt(self.total_budget));
    }
};

// ==============================================
// Garbage Collector
// ==============================================

pub const GarbageCollector = struct {
    allocator: std.mem.Allocator,
    
    // Eviction policy
    policy: EvictionPolicy,
    
    // LRU tracking
    lru_order: std.ArrayList(CacheEntry),
    
    // Thresholds
    gc_threshold: f32,  // Trigger GC when usage > threshold
    target_usage: f32,  // Target usage after GC
    
    // Stats
    gc_runs: u64,
    bytes_evicted: u64,
    
    pub fn init(allocator: std.mem.Allocator, policy: EvictionPolicy) GarbageCollector {
        return .{
            .allocator = allocator,
            .policy = policy,
            .lru_order = std.ArrayList(CacheEntry).init(allocator),
            .gc_threshold = 0.9,
            .target_usage = 0.7,
            .gc_runs = 0,
            .bytes_evicted = 0,
        };
    }
    
    pub fn deinit(self: *GarbageCollector) void {
        self.lru_order.deinit();
    }
    
    pub fn shouldRunGC(self: *GarbageCollector, current_usage: f32) bool {
        return current_usage > self.gc_threshold;
    }
    
    pub fn runGC(self: *GarbageCollector, budget: *MemoryBudget) usize {
        const current_usage = budget.getTotalUtilization();
        if (!self.shouldRunGC(current_usage)) return 0;
        
        self.gc_runs += 1;
        var evicted: usize = 0;
        
        switch (self.policy) {
            .lru => evicted = self.evictLRU(budget),
            .lfu => evicted = self.evictLFU(budget),
            .fifo => evicted = self.evictFIFO(budget),
        }
        
        self.bytes_evicted += evicted;
        return evicted;
    }
    
    fn evictLRU(self: *GarbageCollector, budget: *MemoryBudget) usize {
        var evicted: usize = 0;
        const target = @as(usize, @intFromFloat(@as(f32, @floatFromInt(budget.total_budget)) * self.target_usage));
        var current = @as(usize, @intFromFloat(@as(f32, @floatFromInt(budget.total_budget)) * budget.getTotalUtilization()));
        
        while (current > target and self.lru_order.items.len > 0) {
            const entry = self.lru_order.orderedRemove(0);
            budget.release(entry.size, entry.category);
            evicted += entry.size;
            current -= entry.size;
        }
        
        return evicted;
    }
    
    fn evictLFU(self: *GarbageCollector, budget: *MemoryBudget) usize {
        _ = budget;
        // Sort by access count, evict least frequently used
        std.sort.pdq(CacheEntry, self.lru_order.items, {}, struct {
            fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
                return a.access_count < b.access_count;
            }
        }.lessThan);
        
        // Similar to LRU but sorted by frequency
        return 0;
    }
    
    fn evictFIFO(self: *GarbageCollector, budget: *MemoryBudget) usize {
        _ = budget;
        // Already in insertion order, same as LRU
        return 0;
    }
    
    pub fn addEntry(self: *GarbageCollector, entry: CacheEntry) void {
        self.lru_order.append(entry) catch {};
    }
    
    pub fn touchEntry(self: *GarbageCollector, id: u64) void {
        for (self.lru_order.items) |*entry| {
            if (entry.id == id) {
                entry.access_count += 1;
                entry.last_access = std.time.milliTimestamp();
                break;
            }
        }
    }
};

pub const EvictionPolicy = enum {
    lru,   // Least Recently Used
    lfu,   // Least Frequently Used
    fifo,  // First In First Out
};

pub const CacheEntry = struct {
    id: u64,
    size: usize,
    category: MemoryCategory,
    access_count: u64,
    last_access: i64,
};

// ==============================================
// Memory Snapshot
// ==============================================

pub const MemorySnapshot = struct {
    timestamp: i64,
    total_bytes: usize,
    category_breakdown: std.EnumArray(MemoryCategory, usize),
    top_allocations: [10]TopAllocation,
    top_count: usize,
    
    pub fn capture(tracker: *MemoryTracker) MemorySnapshot {
        var snapshot = MemorySnapshot{
            .timestamp = std.time.milliTimestamp(),
            .total_bytes = tracker.current_bytes.load(.monotonic),
            .category_breakdown = std.EnumArray(MemoryCategory, usize).initUndefined(),
            .top_allocations = undefined,
            .top_count = 0,
        };
        
        // Get category breakdown
        inline for (std.meta.fields(MemoryCategory)) |field| {
            const cat = @as(MemoryCategory, @enumFromInt(field.value));
            snapshot.category_breakdown.set(cat, tracker.getCategoryBytes(cat));
        }
        
        return snapshot;
    }
    
    pub fn print(self: MemorySnapshot) void {
        const mb = 1024 * 1024;
        std.debug.print("\n═══════════════════════════════════\n", .{});
        std.debug.print("         MEMORY SNAPSHOT            \n", .{});
        std.debug.print("═══════════════════════════════════\n", .{});
        std.debug.print("Timestamp: {d}\n", .{self.timestamp});
        std.debug.print("Total:     {d:.2} MB\n\n", .{@as(f64, @floatFromInt(self.total_bytes)) / mb});
        
        std.debug.print("Category Breakdown:\n", .{});
        inline for (std.meta.fields(MemoryCategory)) |field| {
            const cat = @as(MemoryCategory, @enumFromInt(field.value));
            const bytes = self.category_breakdown.get(cat);
            std.debug.print("  {s}: {d:.2} MB\n", .{ field.name, @as(f64, @floatFromInt(bytes)) / mb });
        }
    }
};

pub const TopAllocation = struct {
    ptr: usize,
    size: usize,
    category: MemoryCategory,
};

// ==============================================
// Fragmentation Analyzer
// ==============================================

pub const FragmentationAnalyzer = struct {
    allocator: std.mem.Allocator,
    
    // Free block tracking
    free_blocks: std.ArrayList(FreeBlock),
    
    pub fn init(allocator: std.mem.Allocator) FragmentationAnalyzer {
        return .{
            .allocator = allocator,
            .free_blocks = std.ArrayList(FreeBlock).init(allocator),
        };
    }
    
    pub fn deinit(self: *FragmentationAnalyzer) void {
        self.free_blocks.deinit();
    }
    
    pub fn addFreeBlock(self: *FragmentationAnalyzer, start: usize, size: usize) void {
        self.free_blocks.append(.{ .start = start, .size = size }) catch {};
    }
    
    pub fn removeFreeBlock(self: *FragmentationAnalyzer, start: usize) void {
        for (self.free_blocks.items, 0..) |block, i| {
            if (block.start == start) {
                _ = self.free_blocks.orderedRemove(i);
                break;
            }
        }
    }
    
    pub fn analyze(self: *FragmentationAnalyzer) FragmentationReport {
        if (self.free_blocks.items.len == 0) {
            return .{
                .total_free = 0,
                .largest_free = 0,
                .fragment_count = 0,
                .fragmentation_ratio = 0,
            };
        }
        
        var total_free: usize = 0;
        var largest_free: usize = 0;
        
        for (self.free_blocks.items) |block| {
            total_free += block.size;
            largest_free = @max(largest_free, block.size);
        }
        
        const ratio = if (total_free > 0)
            1.0 - @as(f32, @floatFromInt(largest_free)) / @as(f32, @floatFromInt(total_free))
        else
            0;
        
        return .{
            .total_free = total_free,
            .largest_free = largest_free,
            .fragment_count = self.free_blocks.items.len,
            .fragmentation_ratio = ratio,
        };
    }
};

pub const FreeBlock = struct {
    start: usize,
    size: usize,
};

pub const FragmentationReport = struct {
    total_free: usize,
    largest_free: usize,
    fragment_count: usize,
    fragmentation_ratio: f32,
    
    pub fn print(self: FragmentationReport) void {
        const mb = 1024 * 1024;
        std.debug.print("\n═══════════════════════════════════\n", .{});
        std.debug.print("      FRAGMENTATION REPORT          \n", .{});
        std.debug.print("═══════════════════════════════════\n", .{});
        std.debug.print("Total Free:   {d:.2} MB\n", .{@as(f64, @floatFromInt(self.total_free)) / mb});
        std.debug.print("Largest Free: {d:.2} MB\n", .{@as(f64, @floatFromInt(self.largest_free)) / mb});
        std.debug.print("Fragments:    {d}\n", .{self.fragment_count});
        std.debug.print("Ratio:        {d:.2}%\n", .{self.fragmentation_ratio * 100});
    }
};

// ==============================================
// Tests
// ==============================================

test "MemoryTracker basic" {
    const allocator = std.testing.allocator;
    var tracker = MemoryTracker.init(allocator, true);
    defer tracker.deinit();
    
    tracker.trackAllocation(0x1000, 1024, .kv_cache);
    var stats = tracker.getStats();
    try std.testing.expectEqual(@as(usize, 1024), stats.current_bytes);
    
    tracker.trackDeallocation(0x1000);
    stats = tracker.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.current_bytes);
}

test "MemoryBudget limits" {
    var budget = MemoryBudget.init(1024 * 1024 * 1024);  // 1GB
    
    // KV cache gets 30% = 300MB
    try std.testing.expect(budget.canAllocate(100 * 1024 * 1024, .kv_cache));
    try std.testing.expect(!budget.canAllocate(400 * 1024 * 1024, .kv_cache));
}

test "GarbageCollector init" {
    const allocator = std.testing.allocator;
    var gc = GarbageCollector.init(allocator, .lru);
    defer gc.deinit();
    
    try std.testing.expect(!gc.shouldRunGC(0.5));
    try std.testing.expect(gc.shouldRunGC(0.95));
}

test "FragmentationAnalyzer" {
    const allocator = std.testing.allocator;
    var analyzer = FragmentationAnalyzer.init(allocator);
    defer analyzer.deinit();
    
    analyzer.addFreeBlock(0, 1000);
    analyzer.addFreeBlock(2000, 500);
    
    const report = analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 1500), report.total_free);
    try std.testing.expectEqual(@as(usize, 1000), report.largest_free);
}