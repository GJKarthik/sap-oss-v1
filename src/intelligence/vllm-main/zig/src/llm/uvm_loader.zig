const std = @import("std");
const Allocator = std.mem.Allocator;

/// UVM configuration
pub const UvmConfig = struct {
    enabled: bool = false,
    /// Hint for prefetching: how many layers to prefetch ahead
    prefetch_layers: u32 = 2,
    /// Whether to use read-mostly hint for model weights
    read_mostly: bool = true,
    /// Percentage of GPU VRAM to use for active working set
    gpu_memory_fraction: f32 = 0.85,
};

/// UVM memory region tracking
pub const UvmRegion = struct {
    base_addr: usize,
    size_bytes: u64,
    is_prefetched: bool,
    device_id: i32,
    layer_index: u32,
};

/// UVM model loader
pub const UvmLoader = struct {
    allocator: Allocator,
    config: UvmConfig,
    regions: std.ArrayListUnmanaged(UvmRegion),
    total_allocated: u64,
    total_prefetched: u64,

    pub fn init(allocator: Allocator, config: UvmConfig) UvmLoader {
        return .{
            .allocator = allocator,
            .config = config,
            .regions = std.ArrayListUnmanaged(UvmRegion){},
            .total_allocated = 0,
            .total_prefetched = 0,
        };
    }

    pub fn deinit(self: *UvmLoader) void {
        self.regions.deinit();
    }

    /// Register a UVM region for a model layer
    pub fn registerRegion(self: *UvmLoader, region: UvmRegion) !void {
        try self.regions.append(region);
        self.total_allocated += region.size_bytes;
        if (region.is_prefetched) {
            self.total_prefetched += region.size_bytes;
        }
    }

    /// Prefetch a layer to GPU
    pub fn prefetchLayer(self: *UvmLoader, layer_idx: u32) void {
        for (self.regions.items) |*region| {
            if (region.layer_index == layer_idx and !region.is_prefetched) {
                region.is_prefetched = true;
                self.total_prefetched += region.size_bytes;
            }
        }
    }

    /// Get total allocated UVM memory
    pub fn totalAllocated(self: *const UvmLoader) u64 {
        return self.total_allocated;
    }

    /// Get total prefetched memory
    pub fn totalPrefetched(self: *const UvmLoader) u64 {
        return self.total_prefetched;
    }

    /// Get region count
    pub fn regionCount(self: *const UvmLoader) usize {
        return self.regions.items.len;
    }

    /// Find region for a specific layer
    pub fn findRegion(self: *const UvmLoader, layer_idx: u32) ?UvmRegion {
        for (self.regions.items) |region| {
            if (region.layer_index == layer_idx) {
                return region;
            }
        }
        return null;
    }
};

// Tests
const testing = std.testing;

test "UvmLoader init creates empty loader" {
    var loader = UvmLoader.init(testing.allocator, .{});
    defer loader.deinit();
    try testing.expectEqual(@as(usize, 0), loader.regionCount());
    try testing.expectEqual(@as(u64, 0), loader.totalAllocated());
}

test "registerRegion adds region and updates totals" {
    var loader = UvmLoader.init(testing.allocator, .{});
    defer loader.deinit();

    const region = UvmRegion{
        .base_addr = 0x1000,
        .size_bytes = 1024,
        .is_prefetched = false,
        .device_id = 0,
        .layer_index = 0,
    };
    try loader.registerRegion(region);

    try testing.expectEqual(@as(usize, 1), loader.regionCount());
    try testing.expectEqual(@as(u64, 1024), loader.totalAllocated());
    try testing.expectEqual(@as(u64, 0), loader.totalPrefetched());
}

test "prefetchLayer updates prefetch tracking" {
    var loader = UvmLoader.init(testing.allocator, .{});
    defer loader.deinit();

    const region = UvmRegion{
        .base_addr = 0x2000,
        .size_bytes = 2048,
        .is_prefetched = false,
        .device_id = 0,
        .layer_index = 1,
    };
    try loader.registerRegion(region);
    loader.prefetchLayer(1);

    try testing.expectEqual(@as(u64, 2048), loader.totalPrefetched());
}

test "findRegion locates correct layer" {
    var loader = UvmLoader.init(testing.allocator, .{});
    defer loader.deinit();

    const region = UvmRegion{
        .base_addr = 0x3000,
        .size_bytes = 4096,
        .is_prefetched = true,
        .device_id = 0,
        .layer_index = 5,
    };
    try loader.registerRegion(region);

    const found = loader.findRegion(5);
    try testing.expect(found != null);
    try testing.expectEqual(@as(u32, 5), found.?.layer_index);
    try testing.expectEqual(@as(u64, 4096), found.?.size_bytes);
}

