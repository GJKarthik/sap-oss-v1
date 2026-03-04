//! Disk Array - On-Disk Array Structures
//!
//! Converted from: kuzu/src/storage/disk_array.cpp
//!
//! Purpose:
//! Provides persistent array storage with efficient random access.
//! Used for storing column data, indexes, and other array-like structures.

const std = @import("std");
const common = @import("../common/common.zig");

const PageIdx = common.PageIdx;
const INVALID_PAGE_IDX = common.INVALID_PAGE_IDX;
const KUZU_PAGE_SIZE = common.KUZU_PAGE_SIZE;

/// Header for a disk array stored in page 0
pub const DiskArrayHeader = struct {
    num_elements: u64,
    element_size: u32,
    num_pages: u32,
    first_data_page: PageIdx,
    last_data_page: PageIdx,
    
    pub const SIZE: usize = 32;
    
    pub fn elementsPerPage(self: *const DiskArrayHeader) u32 {
        return @intCast((KUZU_PAGE_SIZE - 8) / self.element_size);
    }
};

/// Disk array for persistent storage
pub const DiskArray = struct {
    allocator: std.mem.Allocator,
    
    /// Array header
    header: DiskArrayHeader,
    
    /// In-memory page storage
    pages: std.ArrayList([]align(4096) u8),
    
    const Self = @This();
    
    /// Create a new disk array
    pub fn create(allocator: std.mem.Allocator, element_size: u32) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .header = .{
                .num_elements = 0,
                .element_size = element_size,
                .num_pages = 0,
                .first_data_page = INVALID_PAGE_IDX,
                .last_data_page = INVALID_PAGE_IDX,
            },
            .pages = std.ArrayList([]align(4096) u8).init(allocator),
        };
        return self;
    }
    
    /// Get element at index
    pub fn get(self: *Self, index: u64, buffer: []u8) !void {
        if (index >= self.header.num_elements) {
            return error.IndexOutOfBounds;
        }
        
        const elements_per_page = self.header.elementsPerPage();
        const page_num = index / elements_per_page;
        const offset_in_page = (index % elements_per_page) * self.header.element_size;
        
        if (page_num >= self.pages.items.len) {
            return error.PageNotFound;
        }
        
        const page = self.pages.items[@intCast(page_num)];
        const read_size = @min(buffer.len, self.header.element_size);
        @memcpy(buffer[0..read_size], page[offset_in_page..][0..read_size]);
    }
    
    /// Set element at index
    pub fn set(self: *Self, index: u64, data: []const u8) !void {
        if (index >= self.header.num_elements) {
            return error.IndexOutOfBounds;
        }
        
        const elements_per_page = self.header.elementsPerPage();
        const page_num = index / elements_per_page;
        const offset_in_page = (index % elements_per_page) * self.header.element_size;
        
        if (page_num >= self.pages.items.len) {
            return error.PageNotFound;
        }
        
        const page = self.pages.items[@intCast(page_num)];
        const write_size = @min(data.len, self.header.element_size);
        @memcpy(page[offset_in_page..][0..write_size], data[0..write_size]);
    }
    
    /// Append element to array
    pub fn append(self: *Self, data: []const u8) !u64 {
        const elements_per_page = self.header.elementsPerPage();
        const new_index = self.header.num_elements;
        const page_num = new_index / elements_per_page;
        
        // Allocate new page if needed
        while (page_num >= self.pages.items.len) {
            try self.allocatePage();
        }
        
        self.header.num_elements += 1;
        try self.set(new_index, data);
        return new_index;
    }
    
    /// Get number of elements
    pub fn size(self: *Self) u64 {
        return self.header.num_elements;
    }
    
    /// Resize the array
    pub fn resize(self: *Self, new_size: u64) !void {
        const elements_per_page = self.header.elementsPerPage();
        const pages_needed = (new_size + elements_per_page - 1) / elements_per_page;
        
        while (self.pages.items.len < pages_needed) {
            try self.allocatePage();
        }
        
        self.header.num_elements = new_size;
    }
    
    fn allocatePage(self: *Self) !void {
        const page = try self.allocator.alignedAlloc(u8, 4096, KUZU_PAGE_SIZE);
        @memset(page, 0);
        try self.pages.append(page);
        self.header.num_pages += 1;
        
        if (self.header.first_data_page == INVALID_PAGE_IDX) {
            self.header.first_data_page = 0;
        }
        self.header.last_data_page = @intCast(self.pages.items.len - 1);
    }
    
    pub fn destroy(self: *Self) void {
        for (self.pages.items) |page| {
            self.allocator.free(page);
        }
        self.pages.deinit();
        self.allocator.destroy(self);
    }
};

/// Typed disk array wrapper
pub fn TypedDiskArray(comptime T: type) type {
    return struct {
        inner: *DiskArray,
        allocator: std.mem.Allocator,
        
        const Self = @This();
        
        pub fn create(allocator: std.mem.Allocator) !Self {
            return Self{
                .inner = try DiskArray.create(allocator, @sizeOf(T)),
                .allocator = allocator,
            };
        }
        
        pub fn get(self: *Self, index: u64) !T {
            var buffer: [@sizeOf(T)]u8 = undefined;
            try self.inner.get(index, &buffer);
            return std.mem.bytesAsValue(T, &buffer).*;
        }
        
        pub fn set(self: *Self, index: u64, value: T) !void {
            const bytes = std.mem.asBytes(&value);
            try self.inner.set(index, bytes);
        }
        
        pub fn append(self: *Self, value: T) !u64 {
            const bytes = std.mem.asBytes(&value);
            return self.inner.append(bytes);
        }
        
        pub fn size(self: *Self) u64 {
            return self.inner.size();
        }
        
        pub fn destroy(self: *Self) void {
            self.inner.destroy();
        }
    };
}

// Tests
test "disk array basic operations" {
    const allocator = std.testing.allocator;
    
    const arr = try DiskArray.create(allocator, 8);
    defer arr.destroy();
    
    // Append elements
    const data1 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const data2 = [_]u8{ 9, 10, 11, 12, 13, 14, 15, 16 };
    
    _ = try arr.append(&data1);
    _ = try arr.append(&data2);
    
    try std.testing.expectEqual(@as(u64, 2), arr.size());
    
    // Read back
    var buffer: [8]u8 = undefined;
    try arr.get(0, &buffer);
    try std.testing.expectEqualSlices(u8, &data1, &buffer);
}

test "typed disk array" {
    const allocator = std.testing.allocator;
    
    var arr = try TypedDiskArray(u64).create(allocator);
    defer arr.destroy();
    
    _ = try arr.append(42);
    _ = try arr.append(100);
    
    try std.testing.expectEqual(@as(u64, 42), try arr.get(0));
    try std.testing.expectEqual(@as(u64, 100), try arr.get(1));
}