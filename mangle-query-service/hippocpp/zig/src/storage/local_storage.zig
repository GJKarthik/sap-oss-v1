//! Local Storage - Storage abstraction layer
//!
//! Purpose:
//! Provides a unified storage interface that coordinates
//! buffer pool, disk manager, and storage operations.

const std = @import("std");

// ============================================================================
// Storage Type
// ============================================================================

pub const StorageType = enum {
    IN_MEMORY,
    LOCAL_DISK,
    REMOTE,
};

// ============================================================================
// Storage Config
// ============================================================================

pub const StorageConfig = struct {
    storage_type: StorageType = .LOCAL_DISK,
    page_size: usize = 4096,
    buffer_pool_size: usize = 256 * 1024 * 1024,  // 256MB
    wal_enabled: bool = true,
    compression_enabled: bool = true,
    max_file_size: u64 = 0,  // 0 = unlimited
};

// ============================================================================
// Storage Statistics
// ============================================================================

pub const StorageStats = struct {
    total_size: u64 = 0,
    used_size: u64 = 0,
    num_tables: u32 = 0,
    num_indexes: u32 = 0,
    pages_in_memory: usize = 0,
    pages_on_disk: u64 = 0,
    read_count: u64 = 0,
    write_count: u64 = 0,
};

// ============================================================================
// Table Storage Info
// ============================================================================

pub const TableStorageInfo = struct {
    table_id: u64,
    name: []const u8,
    file_id: u32,
    num_pages: u64,
    num_rows: u64,
    size_bytes: u64,
};

// ============================================================================
// Local Storage
// ============================================================================

pub const LocalStorage = struct {
    allocator: std.mem.Allocator,
    config: StorageConfig,
    database_path: []const u8,
    
    // Table tracking
    tables: std.AutoHashMap(u64, TableStorageInfo),
    next_table_id: u64 = 1,
    
    // Statistics
    stats: StorageStats = .{},
    
    // State
    initialized: bool = false,
    read_only: bool = false,
    
    pub fn init(allocator: std.mem.Allocator, database_path: []const u8, config: StorageConfig) LocalStorage {
        return .{
            .allocator = allocator,
            .config = config,
            .database_path = database_path,
            .tables = std.AutoHashMap(u64, TableStorageInfo).init(allocator),
        };
    }
    
    pub fn deinit(self: *LocalStorage) void {
        self.tables.deinit();
    }
    
    /// Initialize the storage system
    pub fn initialize(self: *LocalStorage) !void {
        if (self.initialized) return;
        
        // In full implementation:
        // - Initialize disk manager
        // - Initialize buffer pool
        // - Load catalog
        // - Initialize WAL
        
        self.initialized = true;
    }
    
    /// Shutdown the storage system
    pub fn shutdown(self: *LocalStorage) !void {
        if (!self.initialized) return;
        
        // In full implementation:
        // - Flush all dirty pages
        // - Checkpoint
        // - Close WAL
        // - Close all files
        
        self.initialized = false;
    }
    
    /// Create a new table
    pub fn createTable(self: *LocalStorage, name: []const u8) !u64 {
        if (!self.initialized) return error.StorageNotInitialized;
        
        const table_id = self.next_table_id;
        self.next_table_id += 1;
        
        const info = TableStorageInfo{
            .table_id = table_id,
            .name = name,
            .file_id = 0,  // Would be allocated by disk manager
            .num_pages = 0,
            .num_rows = 0,
            .size_bytes = 0,
        };
        
        try self.tables.put(table_id, info);
        self.stats.num_tables += 1;
        
        return table_id;
    }
    
    /// Drop a table
    pub fn dropTable(self: *LocalStorage, table_id: u64) !void {
        if (!self.initialized) return error.StorageNotInitialized;
        
        if (self.tables.contains(table_id)) {
            // In full implementation: deallocate pages, remove files
            _ = self.tables.remove(table_id);
            self.stats.num_tables -= 1;
        }
    }
    
    /// Get table info
    pub fn getTableInfo(self: *const LocalStorage, table_id: u64) ?TableStorageInfo {
        return self.tables.get(table_id);
    }
    
    /// Read a page
    pub fn readPage(self: *LocalStorage, table_id: u64, page_id: u64, buffer: []u8) !void {
        _ = table_id;
        _ = page_id;
        
        // In full implementation: use buffer pool and disk manager
        @memset(buffer, 0);
        self.stats.read_count += 1;
    }
    
    /// Write a page
    pub fn writePage(self: *LocalStorage, table_id: u64, page_id: u64, data: []const u8) !void {
        if (self.read_only) return error.ReadOnlyStorage;
        
        _ = table_id;
        _ = page_id;
        _ = data;
        
        // In full implementation: use buffer pool
        self.stats.write_count += 1;
    }
    
    /// Allocate a new page for a table
    pub fn allocatePage(self: *LocalStorage, table_id: u64) !u64 {
        if (self.read_only) return error.ReadOnlyStorage;
        
        if (self.tables.getPtr(table_id)) |info| {
            const page_id = info.num_pages;
            info.num_pages += 1;
            info.size_bytes += self.config.page_size;
            self.stats.pages_on_disk += 1;
            return page_id;
        }
        return error.TableNotFound;
    }
    
    /// Flush all pending writes
    pub fn flush(self: *LocalStorage) !void {
        // In full implementation: flush buffer pool
        _ = self;
    }
    
    /// Checkpoint the database
    pub fn checkpoint(self: *LocalStorage) !void {
        if (self.read_only) return error.ReadOnlyStorage;
        
        // In full implementation: full checkpoint
        try self.flush();
    }
    
    /// Get storage statistics
    pub fn getStats(self: *const LocalStorage) StorageStats {
        return self.stats;
    }
    
    /// Check if storage is initialized
    pub fn isInitialized(self: *const LocalStorage) bool {
        return self.initialized;
    }
    
    /// Check if storage is read-only
    pub fn isReadOnly(self: *const LocalStorage) bool {
        return self.read_only;
    }
    
    /// Set read-only mode
    pub fn setReadOnly(self: *LocalStorage, read_only: bool) void {
        self.read_only = read_only;
    }
    
    /// Get used space
    pub fn getUsedSpace(self: *const LocalStorage) u64 {
        var total: u64 = 0;
        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            total += entry.value_ptr.size_bytes;
        }
        return total;
    }
    
    /// Get table count
    pub fn getTableCount(self: *const LocalStorage) u32 {
        return @intCast(self.tables.count());
    }
};

// ============================================================================
// Storage Factory
// ============================================================================

pub const StorageFactory = struct {
    pub fn createInMemory(allocator: std.mem.Allocator) !*LocalStorage {
        const storage = try allocator.create(LocalStorage);
        storage.* = LocalStorage.init(allocator, ":memory:", .{
            .storage_type = .IN_MEMORY,
            .wal_enabled = false,
        });
        try storage.initialize();
        return storage;
    }
    
    pub fn createLocal(allocator: std.mem.Allocator, path: []const u8) !*LocalStorage {
        const storage = try allocator.create(LocalStorage);
        storage.* = LocalStorage.init(allocator, path, .{
            .storage_type = .LOCAL_DISK,
        });
        try storage.initialize();
        return storage;
    }
    
    pub fn destroy(allocator: std.mem.Allocator, storage: *LocalStorage) void {
        storage.shutdown() catch {};
        storage.deinit();
        allocator.destroy(storage);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "storage config defaults" {
    const config = StorageConfig{};
    try std.testing.expectEqual(StorageType.LOCAL_DISK, config.storage_type);
    try std.testing.expectEqual(@as(usize, 4096), config.page_size);
    try std.testing.expect(config.wal_enabled);
}

test "local storage init" {
    const allocator = std.testing.allocator;
    
    var storage = LocalStorage.init(allocator, "/tmp/test", .{});
    defer storage.deinit();
    
    try std.testing.expect(!storage.isInitialized());
    
    try storage.initialize();
    try std.testing.expect(storage.isInitialized());
}

test "local storage create table" {
    const allocator = std.testing.allocator;
    
    var storage = LocalStorage.init(allocator, "/tmp/test", .{});
    defer storage.deinit();
    
    try storage.initialize();
    
    const table_id = try storage.createTable("users");
    try std.testing.expectEqual(@as(u64, 1), table_id);
    try std.testing.expectEqual(@as(u32, 1), storage.getTableCount());
    
    const info = storage.getTableInfo(table_id);
    try std.testing.expect(info != null);
}

test "local storage drop table" {
    const allocator = std.testing.allocator;
    
    var storage = LocalStorage.init(allocator, "/tmp/test", .{});
    defer storage.deinit();
    
    try storage.initialize();
    
    const table_id = try storage.createTable("test");
    try std.testing.expectEqual(@as(u32, 1), storage.getTableCount());
    
    try storage.dropTable(table_id);
    try std.testing.expectEqual(@as(u32, 0), storage.getTableCount());
}

test "local storage read only" {
    const allocator = std.testing.allocator;
    
    var storage = LocalStorage.init(allocator, "/tmp/test", .{});
    defer storage.deinit();
    
    try storage.initialize();
    
    storage.setReadOnly(true);
    try std.testing.expect(storage.isReadOnly());
}