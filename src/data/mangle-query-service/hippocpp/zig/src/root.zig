//! Kuzu-Zig - Embedded Graph Database Engine
//!
//! A high-performance embedded graph database written in Zig,
//! providing Cypher query support for property graphs.
//!
//! ## Features
//! - Full Cypher query support with MATCH, CREATE, MERGE, DELETE
//! - ACID transactions with MVCC
//! - Property graph model with node and relationship tables
//! - Graph algorithms (shortest path, variable-length paths)
//! - C-compatible API for FFI bindings
//!
//! ## Quick Start
//! ```zig
//! const kuzu = @import("kuzu-zig");
//!
//! var db = try kuzu.Database.init(allocator, .{});
//! defer db.deinit();
//!
//! var conn = try db.connect();
//! defer conn.close();
//!
//! var result = try conn.query("MATCH (n) RETURN n LIMIT 10");
//! defer result.deinit();
//! ```

const std = @import("std");

// ============================================================================
// Version Information
// ============================================================================

pub const version = "1.0.0";
pub const version_major = 1;
pub const version_minor = 0;
pub const version_patch = 0;

// ============================================================================
// Common Types
// ============================================================================

pub const common = struct {
    pub const exception = @import("common/exception.zig");
    pub const enums = @import("common/enums.zig");
    pub const constants = @import("common/constants.zig");
    pub const value = @import("common/value.zig");
    pub const data_chunk = @import("common/data_chunk.zig");
    pub const serializer = @import("common/serializer.zig");
    pub const file_system = @import("common/file_system.zig");
    pub const profiler = @import("common/profiler.zig");
    pub const logger = @import("common/logger.zig");
    
    pub const types = struct {
        pub const date_time = @import("common/types/date_time.zig");
        pub const blob = @import("common/types/blob.zig");
    };
    
    pub const arrow = @import("common/arrow/arrow.zig");
};

// Re-export commonly used types
pub const Value = common.value.Value;
pub const DataChunk = common.data_chunk.DataChunk;
pub const LogLevel = common.logger.LogLevel;
pub const Logger = common.logger.Logger;
pub const Timer = common.profiler.Timer;

// ============================================================================
// Catalog
// ============================================================================

pub const catalog = @import("catalog/catalog.zig");

pub const Catalog = catalog.Catalog;
pub const TableSchema = catalog.TableSchema;

// ============================================================================
// Query Processing
// ============================================================================

pub const parser = @import("parser/parser.zig");
pub const binder = @import("binder/binder.zig");
pub const planner = @import("planner/planner.zig");
pub const optimizer = @import("optimizer/optimizer.zig");
pub const processor = @import("processor/processor.zig");
pub const evaluator = @import("evaluator/evaluator.zig");

pub const Parser = parser.Parser;
pub const Binder = binder.Binder;
pub const Planner = planner.Planner;
pub const Optimizer = optimizer.Optimizer;
pub const Processor = processor.Processor;

// ============================================================================
// Functions
// ============================================================================

pub const function = struct {
    pub const core = @import("function/function.zig");
    pub const comparison = @import("function/comparison.zig");
    
    pub const aggregate = struct {
        pub const count = @import("function/aggregate/count.zig");
        pub const sum = @import("function/aggregate/sum.zig");
        pub const avg = @import("function/aggregate/avg.zig");
        pub const min_max = @import("function/aggregate/min_max.zig");
        pub const collect = @import("function/aggregate/collect.zig");
    };
    
    pub const string = @import("function/string/string.zig");
    pub const list = @import("function/list/list.zig");
    pub const cast = @import("function/cast/cast.zig");
    
    pub const gds = struct {
        pub const core = @import("function/gds/gds.zig");
        pub const shortest_path = @import("function/gds/shortest_path.zig");
        pub const var_path = @import("function/gds/var_path.zig");
        pub const rec_joins = @import("function/gds/rec_joins.zig");
    };
    
    pub const csv = @import("function/export/csv.zig");
};

// ============================================================================
// Storage
// ============================================================================

pub const storage = struct {
    pub const disk_manager = @import("storage/disk_manager.zig");
    pub const local_storage = @import("storage/local_storage.zig");
    pub const checkpointer = @import("storage/checkpointer.zig");
    
    pub const buffer_manager = struct {
        pub const buffer_pool = @import("storage/buffer_manager/buffer_pool.zig");
    };
    
    pub const table = struct {
        pub const column = @import("storage/table/column.zig");
        pub const rel_table = @import("storage/table/rel_table.zig");
        pub const node_group = @import("storage/table/node_group.zig");
    };
    
    pub const index = struct {
        pub const hash_index = @import("storage/index/hash_index.zig");
    };
    
    pub const wal = struct {
        pub const wal_record = @import("storage/wal/wal_record.zig");
    };
    
    pub const compression = @import("storage/compression/compression.zig");
    pub const stats = @import("storage/stats/stats.zig");
};

pub const BufferPool = storage.buffer_manager.buffer_pool.BufferPool;
pub const DiskManager = storage.disk_manager.DiskManager;
pub const LocalStorage = storage.local_storage.LocalStorage;

// ============================================================================
// Transaction
// ============================================================================

pub const transaction = @import("transaction/transaction_manager.zig");

pub const TransactionManager = transaction.TransactionManager;
pub const Transaction = transaction.Transaction;

// ============================================================================
// Extension
// ============================================================================

pub const extension = @import("extension/extension_manager.zig");

pub const ExtensionManager = extension.ExtensionManager;

// ============================================================================
// Main Database Interface
// ============================================================================

pub const main = struct {
    pub const database = @import("main/database.zig");
    pub const connection = @import("main/connection.zig");
    pub const client_context = @import("main/client_context.zig");
    pub const query_result = @import("main/query_result.zig");
    pub const arrow_query_result = @import("main/query_result/arrow_query_result.zig");
    pub const materialized_query_result = @import("main/query_result/materialized_query_result.zig");
    pub const prepared_statement = @import("main/prepared_statement.zig");
    pub const prepared_statement_manager = @import("main/prepared_statement_manager.zig");
    pub const storage_driver = @import("main/storage_driver.zig");
    pub const version = @import("main/version.zig");
    pub const api = @import("main/api.zig");
};

pub const Database = main.database.Database;
pub const DatabaseConfig = main.database.DatabaseConfig;
pub const Connection = main.database.Connection;
pub const ClientContext = main.client_context.ClientContext;
pub const QueryResult = main.query_result.QueryResult;
pub const PreparedStatement = main.prepared_statement.PreparedStatement;
pub const PreparedStatementManager = main.prepared_statement_manager.PreparedStatementManager;
pub const StorageDriver = main.storage_driver.StorageDriver;

// ============================================================================
// Testing Utilities
// ============================================================================

pub const testing = struct {
    pub const test_helper = @import("testing/test_helper.zig");
    pub const benchmark = @import("testing/benchmark.zig");
};

// ============================================================================
// C API
// ============================================================================

pub const c_api = main.api;

// Re-export C API types
pub const KuzuDatabase = c_api.KuzuDatabase;
pub const KuzuConnection = c_api.KuzuConnection;
pub const KuzuQueryResult = c_api.KuzuQueryResult;
pub const KuzuState = c_api.KuzuState;

// ============================================================================
// Helper Functions
// ============================================================================

/// Create an in-memory database
pub fn createInMemoryDatabase(allocator: std.mem.Allocator) !*Database {
    return main.database.DatabaseFactory.createInMemory(allocator);
}

/// Create a persistent database
pub fn createDatabase(allocator: std.mem.Allocator, path: []const u8) !*Database {
    return main.database.DatabaseFactory.createPersistent(allocator, path);
}

// ============================================================================
// Tests
// ============================================================================

test "version info" {
    try std.testing.expectEqualStrings("1.0.0", version);
    try std.testing.expectEqual(@as(u32, 1), version_major);
}

test "module imports" {
    // Verify all modules can be imported
    _ = common.exception;
    _ = common.enums;
    _ = catalog;
    _ = parser;
    _ = storage.disk_manager;
    _ = main.database;
}
