//! HippoCPP - Embedded Graph Database Engine
//!
//! A high-performance graph database implementation in Zig,
//! converted from the Kuzu C++ codebase.
//!
//! Features:
//! - Columnar storage with compression
//! - MVCC transaction support
//! - Write-ahead logging (WAL)
//! - Buffer manager with page eviction
//! - HNSW vector index
//! - Cypher query language

const std = @import("std");

// Core modules
pub const common = @import("common/common.zig");
pub const storage = @import("storage/storage.zig");
pub const buffer_manager = @import("buffer_manager/buffer_manager.zig");
pub const catalog = @import("catalog/catalog.zig");
pub const transaction = @import("transaction/transaction.zig");

// Query processing
pub const parser = @import("parser/parser.zig");
pub const binder = @import("binder/binder.zig");
pub const planner = @import("planner/planner.zig");
pub const optimizer = @import("optimizer/optimizer.zig");
pub const processor = @import("processor/processor.zig");

// Constants
pub const KUZU_PAGE_SIZE: usize = 4096;
pub const KUZU_STORAGE_VERSION: u64 = 1;
pub const KUZU_CATALOG_VERSION: u64 = 1;

/// Database configuration options
pub const DatabaseConfig = struct {
    /// Path to the database directory
    database_path: []const u8,
    /// Size of the buffer pool in bytes
    buffer_pool_size: usize = 256 * 1024 * 1024, // 256MB
    /// Maximum number of threads
    max_threads: u32 = 4,
    /// Enable compression
    enable_compression: bool = true,
    /// Enable WAL checksums
    enable_checksums: bool = true,
    /// Read-only mode
    read_only: bool = false,
    /// In-memory mode
    in_memory: bool = false,

    pub fn inMemory() DatabaseConfig {
        return .{
            .database_path = ":memory:",
            .in_memory = true,
        };
    }
};

/// Main database handle
pub const Database = struct {
    allocator: std.mem.Allocator,
    config: DatabaseConfig,
    storage_manager: ?*storage.StorageManager,
    buffer_mgr: ?*buffer_manager.BufferManager,
    catalog_instance: ?*catalog.Catalog,
    initialized: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: DatabaseConfig) !Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .storage_manager = null,
            .buffer_mgr = null,
            .catalog_instance = null,
            .initialized = false,
        };
    }

    pub fn open(self: *Self) !void {
        if (self.initialized) return;

        // Initialize buffer manager
        self.buffer_mgr = try buffer_manager.BufferManager.create(
            self.allocator,
            self.config.buffer_pool_size,
        );

        // Initialize storage manager
        self.storage_manager = try storage.StorageManager.create(
            self.allocator,
            self.config,
            self.buffer_mgr.?,
        );

        // Initialize catalog
        self.catalog_instance = try catalog.Catalog.create(
            self.allocator,
            self.storage_manager.?,
        );

        self.initialized = true;
    }

    pub fn close(self: *Self) void {
        if (!self.initialized) return;

        if (self.catalog_instance) |cat| {
            cat.destroy();
            self.catalog_instance = null;
        }

        if (self.storage_manager) |sm| {
            sm.destroy();
            self.storage_manager = null;
        }

        if (self.buffer_mgr) |bm| {
            bm.destroy();
            self.buffer_mgr = null;
        }

        self.initialized = false;
    }

    pub fn deinit(self: *Self) void {
        self.close();
    }
};

/// Connection to a database
pub const Connection = struct {
    database: *Database,
    allocator: std.mem.Allocator,
    transaction_context: ?*transaction.TransactionContext,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, database: *Database) Self {
        return Self{
            .database = database,
            .allocator = allocator,
            .transaction_context = null,
        };
    }

    pub fn execute(self: *Self, query: []const u8) !QueryResult {
        _ = self;
        _ = query;
        // TODO: Implement query execution pipeline
        return QueryResult{};
    }

    pub fn deinit(self: *Self) void {
        if (self.transaction_context) |tx| {
            tx.rollback() catch {};
            self.transaction_context = null;
        }
    }
};

/// Query result container
pub const QueryResult = struct {
    columns: [][]const u8 = &[_][]const u8{},
    rows: [][]common.Value = &[_][]common.Value{},
    has_more: bool = false,

    pub fn getNumColumns(self: *const QueryResult) usize {
        return self.columns.len;
    }

    pub fn getNumRows(self: *const QueryResult) usize {
        return self.rows.len;
    }
};

// ============================================================================
// Public API
// ============================================================================

/// Create a new database
pub fn createDatabase(allocator: std.mem.Allocator, path: []const u8) !*Database {
    const db = try allocator.create(Database);
    db.* = try Database.init(allocator, .{ .database_path = path });
    return db;
}

/// Create an in-memory database
pub fn createInMemoryDatabase(allocator: std.mem.Allocator) !*Database {
    const db = try allocator.create(Database);
    db.* = try Database.init(allocator, DatabaseConfig.inMemory());
    return db;
}

/// Create a connection to a database
pub fn createConnection(allocator: std.mem.Allocator, db: *Database) Connection {
    return Connection.init(allocator, db);
}

// ============================================================================
// Tests
// ============================================================================

test "database creation" {
    const allocator = std.testing.allocator;

    var db = try Database.init(allocator, DatabaseConfig.inMemory());
    defer db.deinit();

    try std.testing.expect(!db.initialized);
}

test "database config defaults" {
    const config = DatabaseConfig{ .database_path = "/tmp/test" };

    try std.testing.expectEqual(@as(usize, 256 * 1024 * 1024), config.buffer_pool_size);
    try std.testing.expectEqual(@as(u32, 4), config.max_threads);
    try std.testing.expect(config.enable_compression);
    try std.testing.expect(config.enable_checksums);
    try std.testing.expect(!config.read_only);
}

pub fn main() !void {
    std.debug.print("HippoCPP Graph Database Engine v0.1.0\n", .{});
    std.debug.print("Usage: hippocpp <database_path>\n", .{});
}
