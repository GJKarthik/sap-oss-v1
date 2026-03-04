//! Disk Manager - File I/O operations
//!
//! Purpose:
//! Handles low-level file operations for the database,
//! including page reads/writes, file allocation, and management.

const std = @import("std");

// ============================================================================
// File Info
// ============================================================================

pub const FileInfo = struct {
    file_id: u32,
    path: []const u8,
    size: u64,
    num_pages: u64,
    created_at: i64,
    modified_at: i64,
};

// ============================================================================
// File Handle
// ============================================================================

pub const FileHandle = struct {
    file_id: u32,
    file: ?std.fs.File,
    path: []const u8,
    page_size: usize,
    
    pub fn init(file_id: u32, path: []const u8, page_size: usize) FileHandle {
        return .{
            .file_id = file_id,
            .file = null,
            .path = path,
            .page_size = page_size,
        };
    }
    
    pub fn open(self: *FileHandle) !void {
        self.file = try std.fs.cwd().openFile(self.path, .{ .mode = .read_write });
    }
    
    pub fn create(self: *FileHandle) !void {
        self.file = try std.fs.cwd().createFile(self.path, .{ .read = true });
    }
    
    pub fn close(self: *FileHandle) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
    }
    
    pub fn isOpen(self: *const FileHandle) bool {
        return self.file != null;
    }
    
    pub fn getSize(self: *FileHandle) !u64 {
        if (self.file) |f| {
            const stat = try f.stat();
            return stat.size;
        }
        return 0;
    }
    
    pub fn readPage(self: *FileHandle, page_id: u64, buffer: []u8) !void {
        if (self.file) |f| {
            const offset = page_id * self.page_size;
            try f.seekTo(offset);
            const bytes_read = try f.read(buffer);
            if (bytes_read < buffer.len) {
                // Zero-fill remainder
                @memset(buffer[bytes_read..], 0);
            }
        }
    }
    
    pub fn writePage(self: *FileHandle, page_id: u64, data: []const u8) !void {
        if (self.file) |f| {
            const offset = page_id * self.page_size;
            try f.seekTo(offset);
            _ = try f.write(data);
        }
    }
    
    pub fn sync(self: *FileHandle) !void {
        if (self.file) |f| {
            try f.sync();
        }
    }
};

// ============================================================================
// Disk Manager
// ============================================================================

pub const DiskManager = struct {
    allocator: std.mem.Allocator,
    page_size: usize,
    database_path: []const u8,
    
    // File handles
    files: std.AutoHashMap(u32, FileHandle),
    next_file_id: u32 = 1,
    
    // Statistics
    pages_read: u64 = 0,
    pages_written: u64 = 0,
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, database_path: []const u8, page_size: usize) DiskManager {
        return .{
            .allocator = allocator,
            .page_size = page_size,
            .database_path = database_path,
            .files = std.AutoHashMap(u32, FileHandle).init(allocator),
        };
    }
    
    pub fn deinit(self: *DiskManager) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            var handle = entry.value_ptr;
            handle.close();
        }
        self.files.deinit();
    }
    
    /// Create a new file
    pub fn createFile(self: *DiskManager, filename: []const u8) !u32 {
        const file_id = self.next_file_id;
        self.next_file_id += 1;
        
        var handle = FileHandle.init(file_id, filename, self.page_size);
        try handle.create();
        try self.files.put(file_id, handle);
        
        return file_id;
    }
    
    /// Open an existing file
    pub fn openFile(self: *DiskManager, filename: []const u8) !u32 {
        const file_id = self.next_file_id;
        self.next_file_id += 1;
        
        var handle = FileHandle.init(file_id, filename, self.page_size);
        try handle.open();
        try self.files.put(file_id, handle);
        
        return file_id;
    }
    
    /// Close a file
    pub fn closeFile(self: *DiskManager, file_id: u32) void {
        if (self.files.getPtr(file_id)) |handle| {
            handle.close();
            _ = self.files.remove(file_id);
        }
    }
    
    /// Read a page from a file
    pub fn readPage(self: *DiskManager, file_id: u32, page_id: u64, buffer: []u8) !void {
        if (self.files.getPtr(file_id)) |handle| {
            try handle.readPage(page_id, buffer);
            self.pages_read += 1;
            self.bytes_read += buffer.len;
        } else {
            return error.FileNotFound;
        }
    }
    
    /// Write a page to a file
    pub fn writePage(self: *DiskManager, file_id: u32, page_id: u64, data: []const u8) !void {
        if (self.files.getPtr(file_id)) |handle| {
            try handle.writePage(page_id, data);
            self.pages_written += 1;
            self.bytes_written += data.len;
        } else {
            return error.FileNotFound;
        }
    }
    
    /// Sync a file to disk
    pub fn syncFile(self: *DiskManager, file_id: u32) !void {
        if (self.files.getPtr(file_id)) |handle| {
            try handle.sync();
        }
    }
    
    /// Sync all files
    pub fn syncAll(self: *DiskManager) !void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            try entry.value_ptr.sync();
        }
    }
    
    /// Get file size
    pub fn getFileSize(self: *DiskManager, file_id: u32) !u64 {
        if (self.files.getPtr(file_id)) |handle| {
            return handle.getSize();
        }
        return error.FileNotFound;
    }
    
    /// Get file info
    pub fn getFileInfo(self: *DiskManager, file_id: u32) !FileInfo {
        if (self.files.get(file_id)) |handle| {
            const size = try self.getFileSize(file_id);
            return FileInfo{
                .file_id = file_id,
                .path = handle.path,
                .size = size,
                .num_pages = @divFloor(size, self.page_size),
                .created_at = 0,
                .modified_at = std.time.timestamp(),
            };
        }
        return error.FileNotFound;
    }
    
    /// Allocate a new page in a file
    pub fn allocatePage(self: *DiskManager, file_id: u32) !u64 {
        const size = try self.getFileSize(file_id);
        const page_id = @divFloor(size, self.page_size);
        
        // Write empty page to extend file
        var empty_page: [4096]u8 = undefined;
        @memset(&empty_page, 0);
        try self.writePage(file_id, page_id, empty_page[0..self.page_size]);
        
        return page_id;
    }
    
    /// Get statistics
    pub fn getStats(self: *const DiskManager) DiskStats {
        return .{
            .pages_read = self.pages_read,
            .pages_written = self.pages_written,
            .bytes_read = self.bytes_read,
            .bytes_written = self.bytes_written,
            .open_files = self.files.count(),
        };
    }
};

pub const DiskStats = struct {
    pages_read: u64,
    pages_written: u64,
    bytes_read: u64,
    bytes_written: u64,
    open_files: usize,
};

// ============================================================================
// Page Allocator
// ============================================================================

pub const PageAllocator = struct {
    disk_manager: *DiskManager,
    file_id: u32,
    next_page_id: u64 = 0,
    free_pages: std.ArrayList(u64),
    
    pub fn init(allocator: std.mem.Allocator, disk_manager: *DiskManager, file_id: u32) PageAllocator {
        return .{
            .disk_manager = disk_manager,
            .file_id = file_id,
            .free_pages = std.ArrayList(u64).init(allocator),
        };
    }
    
    pub fn deinit(self: *PageAllocator) void {
        self.free_pages.deinit();
    }
    
    pub fn allocate(self: *PageAllocator) !u64 {
        // First check free list
        if (self.free_pages.items.len > 0) {
            return self.free_pages.pop();
        }
        
        // Allocate new page
        const page_id = try self.disk_manager.allocatePage(self.file_id);
        self.next_page_id = page_id + 1;
        return page_id;
    }
    
    pub fn deallocate(self: *PageAllocator, page_id: u64) !void {
        try self.free_pages.append(page_id);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "file handle init" {
    var handle = FileHandle.init(1, "test.db", 4096);
    try std.testing.expectEqual(@as(u32, 1), handle.file_id);
    try std.testing.expect(!handle.isOpen());
}

test "disk manager init" {
    const allocator = std.testing.allocator;
    
    var dm = DiskManager.init(allocator, "/tmp/test", 4096);
    defer dm.deinit();
    
    try std.testing.expectEqual(@as(usize, 4096), dm.page_size);
    try std.testing.expectEqual(@as(u32, 1), dm.next_file_id);
}

test "disk manager stats" {
    const allocator = std.testing.allocator;
    
    var dm = DiskManager.init(allocator, "/tmp/test", 4096);
    defer dm.deinit();
    
    const stats = dm.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.pages_read);
    try std.testing.expectEqual(@as(u64, 0), stats.pages_written);
}

test "page allocator" {
    const allocator = std.testing.allocator;
    
    var dm = DiskManager.init(allocator, "/tmp/test", 4096);
    defer dm.deinit();
    
    var pa = PageAllocator.init(allocator, &dm, 1);
    defer pa.deinit();
    
    // Test free list
    try pa.deallocate(10);
    try pa.deallocate(20);
    
    const p1 = try pa.allocate();
    try std.testing.expectEqual(@as(u64, 20), p1);
    
    const p2 = try pa.allocate();
    try std.testing.expectEqual(@as(u64, 10), p2);
}