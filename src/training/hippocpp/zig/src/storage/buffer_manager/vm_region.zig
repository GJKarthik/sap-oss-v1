//! VM Region - Virtual Memory Management
//!
//! Converted from: kuzu/src/storage/buffer_manager/vm_region.cpp
//!
//! Purpose:
//! Manages virtual memory regions for memory-mapped I/O.
//! Provides efficient large memory allocation using OS virtual memory.

const std = @import("std");
const builtin = @import("builtin");

/// Memory protection flags
pub const Protection = enum(u32) {
    NONE = 0,
    READ = 1,
    WRITE = 2,
    READ_WRITE = 3,
    EXEC = 4,
    READ_EXEC = 5,
};

/// VM region state
pub const RegionState = enum {
    UNMAPPED,
    MAPPED,
    COMMITTED,
    RELEASED,
};

/// Virtual memory region
pub const VMRegion = struct {
    allocator: std.mem.Allocator,
    base_address: ?[*]u8,
    size: u64,
    page_size: u64,
    state: RegionState,
    protection: Protection,
    committed_pages: u64,
    
    const Self = @This();
    
    /// System page size (typically 4KB)
    pub const DEFAULT_PAGE_SIZE: u64 = 4096;
    
    pub fn init(allocator: std.mem.Allocator, size: u64) Self {
        return .{
            .allocator = allocator,
            .base_address = null,
            .size = alignToPageSize(size),
            .page_size = DEFAULT_PAGE_SIZE,
            .state = .UNMAPPED,
            .protection = .NONE,
            .committed_pages = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.state != .UNMAPPED and self.state != .RELEASED) {
            self.release();
        }
    }
    
    /// Reserve virtual address space
    pub fn reserve(self: *Self) !void {
        if (self.state != .UNMAPPED) {
            return error.AlreadyMapped;
        }
        
        // Use allocator for now (real impl would use mmap/VirtualAlloc)
        const mem = try self.allocator.alloc(u8, self.size);
        self.base_address = mem.ptr;
        self.state = .MAPPED;
        self.protection = .READ_WRITE;
    }
    
    /// Commit pages (make them usable)
    pub fn commit(self: *Self, offset: u64, length: u64) !void {
        if (self.state == .UNMAPPED) {
            return error.NotMapped;
        }
        
        const aligned_length = alignToPageSize(length);
        _ = offset;
        
        // In real implementation: mprotect/VirtualAlloc to commit
        self.committed_pages += aligned_length / self.page_size;
        self.state = .COMMITTED;
    }
    
    /// Decommit pages (release physical memory but keep reservation)
    pub fn decommit(self: *Self, offset: u64, length: u64) void {
        if (self.state != .COMMITTED) return;
        
        _ = offset;
        const aligned_length = alignToPageSize(length);
        
        if (self.committed_pages >= aligned_length / self.page_size) {
            self.committed_pages -= aligned_length / self.page_size;
        }
    }
    
    /// Release all virtual memory
    pub fn release(self: *Self) void {
        if (self.base_address) |addr| {
            self.allocator.free(addr[0..self.size]);
            self.base_address = null;
        }
        self.state = .RELEASED;
        self.committed_pages = 0;
    }
    
    /// Get pointer at offset
    pub fn getPointer(self: *Self, offset: u64) ?[*]u8 {
        if (self.base_address == null) return null;
        if (offset >= self.size) return null;
        return self.base_address.? + offset;
    }
    
    /// Get slice at offset
    pub fn getSlice(self: *Self, offset: u64, length: u64) ?[]u8 {
        const ptr = self.getPointer(offset) orelse return null;
        if (offset + length > self.size) return null;
        return ptr[0..length];
    }
    
    /// Get committed memory size
    pub fn getCommittedSize(self: *const Self) u64 {
        return self.committed_pages * self.page_size;
    }
    
    /// Get reserved size
    pub fn getReservedSize(self: *const Self) u64 {
        return self.size;
    }
    
    /// Align size to page boundary
    fn alignToPageSize(size: u64) u64 {
        const page_size = DEFAULT_PAGE_SIZE;
        return (size + page_size - 1) & ~(page_size - 1);
    }
};

/// VM region pool - manages multiple regions
pub const VMRegionPool = struct {
    allocator: std.mem.Allocator,
    regions: std.ArrayList(VMRegion),
    total_reserved: u64,
    total_committed: u64,
    max_size: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, max_size: u64) Self {
        return .{
            .allocator = allocator,
            .regions = .{},
            .total_reserved = 0,
            .total_committed = 0,
            .max_size = max_size,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.regions.items) |*region| {
            region.deinit();
        }
        self.regions.deinit(self.allocator);
    }
    
    /// Allocate a new region
    pub fn allocateRegion(self: *Self, size: u64) !*VMRegion {
        if (self.total_reserved + size > self.max_size) {
            return error.OutOfMemory;
        }
        
        var region = VMRegion.init(self.allocator, size);
        try region.reserve();
        
        try self.regions.append(self.allocator, region);
        self.total_reserved += region.getReservedSize();
        
        return &self.regions.items[self.regions.items.len - 1];
    }
    
    /// Get statistics
    pub fn getStats(self: *const Self) struct {
        num_regions: usize,
        total_reserved: u64,
        total_committed: u64,
    } {
        var committed: u64 = 0;
        for (self.regions.items) |region| {
            committed += region.getCommittedSize();
        }
        
        return .{
            .num_regions = self.regions.items.len,
            .total_reserved = self.total_reserved,
            .total_committed = committed,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "vm region init" {
    const allocator = std.testing.allocator;
    
    var region = VMRegion.init(allocator, 8192);
    defer region.deinit(std.testing.allocator);
    
    try std.testing.expectEqual(RegionState.UNMAPPED, region.state);
    try std.testing.expect(region.size >= 8192);
}

test "vm region reserve and commit" {
    const allocator = std.testing.allocator;
    
    var region = VMRegion.init(allocator, 16384);
    defer region.deinit(std.testing.allocator);
    
    try region.reserve();
    try std.testing.expectEqual(RegionState.MAPPED, region.state);
    try std.testing.expect(region.base_address != null);
    
    try region.commit(0, 4096);
    try std.testing.expectEqual(RegionState.COMMITTED, region.state);
}

test "vm region get pointer" {
    const allocator = std.testing.allocator;
    
    var region = VMRegion.init(allocator, 4096);
    defer region.deinit(std.testing.allocator);
    
    try region.reserve();
    
    const ptr = region.getPointer(0);
    try std.testing.expect(ptr != null);
    
    const slice = region.getSlice(0, 100);
    try std.testing.expect(slice != null);
    try std.testing.expectEqual(@as(usize, 100), slice.?.len);
}

test "vm region pool" {
    const allocator = std.testing.allocator;
    
    var pool = VMRegionPool.init(allocator, 1024 * 1024);
    defer pool.deinit(std.testing.allocator);
    
    const region = try pool.allocateRegion(4096);
    try std.testing.expect(region.base_address != null);
    
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.num_regions);
}