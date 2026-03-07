//! Constants - Database-wide constants and configuration values
//!
//! Purpose:
//! Centralized constants for sizes, limits, and configuration
//! used throughout the database system.

const std = @import("std");

// ============================================================================
// Version Information
// ============================================================================

pub const VERSION_MAJOR: u32 = 1;
pub const VERSION_MINOR: u32 = 0;
pub const VERSION_PATCH: u32 = 0;
pub const VERSION_STRING = "1.0.0";

// ============================================================================
// Page Sizes
// ============================================================================

pub const PAGE_SIZE: usize = 4096;                      // 4KB pages
pub const PAGE_SIZE_LOG2: u32 = 12;                     // log2(4096)
pub const LARGE_PAGE_SIZE: usize = 256 * 1024;          // 256KB
pub const DEFAULT_VECTOR_CAPACITY: usize = 2048;        // Default vector size

// ============================================================================
// Buffer Pool Configuration
// ============================================================================

pub const DEFAULT_BUFFER_POOL_SIZE: usize = 256 * 1024 * 1024;  // 256MB
pub const MIN_BUFFER_POOL_SIZE: usize = 64 * 1024 * 1024;       // 64MB
pub const MAX_BUFFER_POOL_SIZE: usize = 1024 * 1024 * 1024 * 1024;  // 1TB

pub const BUFFER_POOL_CLOCK_SWEEP_INTERVAL: u32 = 100;
pub const BUFFER_POOL_EVICTION_THRESHOLD: f32 = 0.9;

// ============================================================================
// Node Group Configuration
// ============================================================================

pub const NODE_GROUP_SIZE: u64 = 2048;                  // Nodes per group
pub const NODE_GROUP_SIZE_LOG2: u32 = 11;               // log2(2048)
pub const INVALID_NODE_GROUP_IDX: u64 = std.math.maxInt(u64);

// ============================================================================
// Data Chunk Configuration
// ============================================================================

pub const DEFAULT_CHUNK_SIZE: usize = 2048;             // Rows per chunk
pub const MAX_CHUNK_SIZE: usize = 65536;                // Maximum chunk size
pub const MIN_CHUNK_SIZE: usize = 64;                   // Minimum chunk size

// ============================================================================
// String and Blob Limits
// ============================================================================

pub const SHORT_STRING_LENGTH: usize = 12;              // Inline short strings
pub const MAX_STRING_LENGTH: usize = 256 * 1024 * 1024; // 256MB
pub const MAX_BLOB_SIZE: usize = 4 * 1024 * 1024 * 1024; // 4GB

pub const DEFAULT_STRING_BUFFER_SIZE: usize = 4096;

// ============================================================================
// Transaction Configuration
// ============================================================================

pub const MAX_CONCURRENT_TRANSACTIONS: u32 = 1024;
pub const TRANSACTION_TIMEOUT_MS: u64 = 30_000;         // 30 seconds
pub const LOCK_TIMEOUT_MS: u64 = 10_000;                // 10 seconds
pub const DEADLOCK_CHECK_INTERVAL_MS: u64 = 100;        // 100ms

pub const INVALID_TRANSACTION_ID: u64 = 0;

// ============================================================================
// WAL Configuration
// ============================================================================

pub const WAL_BUFFER_SIZE: usize = 16 * 1024 * 1024;    // 16MB
pub const WAL_SEGMENT_SIZE: usize = 64 * 1024 * 1024;   // 64MB
pub const WAL_SYNC_INTERVAL_MS: u64 = 1000;             // 1 second

pub const INVALID_LSN: u64 = 0;

// ============================================================================
// Checkpoint Configuration
// ============================================================================

pub const CHECKPOINT_INTERVAL_MS: u64 = 60_000;         // 1 minute
pub const CHECKPOINT_WAL_THRESHOLD: usize = 100 * 1024 * 1024;  // 100MB
pub const CHECKPOINT_DIRTY_PAGE_THRESHOLD: usize = 10_000;

// ============================================================================
// Index Configuration
// ============================================================================

pub const HASH_INDEX_HEADER_SIZE: usize = 64;
pub const HASH_INDEX_SLOT_SIZE: usize = 16;
pub const HASH_INDEX_OVERFLOW_CAPACITY: usize = 8;
pub const HASH_INDEX_INITIAL_BUCKETS: usize = 1024;
pub const HASH_INDEX_LOAD_FACTOR: f32 = 0.75;

pub const BTREE_NODE_SIZE: usize = PAGE_SIZE;
pub const BTREE_MAX_KEY_SIZE: usize = 1024;
pub const BTREE_MIN_FILL_FACTOR: f32 = 0.5;

// ============================================================================
// Query Processing Configuration
// ============================================================================

pub const MAX_QUERY_DEPTH: u32 = 100;                   // Max subquery depth
pub const MAX_EXPRESSION_DEPTH: u32 = 500;              // Max expression nesting
pub const MAX_COLUMNS_PER_TABLE: u32 = 1000;
pub const MAX_TABLES_PER_QUERY: u32 = 64;
pub const MAX_JOINS_PER_QUERY: u32 = 32;

pub const DEFAULT_RESULT_SET_SIZE: usize = 10_000;
pub const MAX_RESULT_SET_SIZE: usize = 1_000_000;

// ============================================================================
// Graph Configuration
// ============================================================================

pub const MAX_REL_TYPES: u32 = 1024;
pub const MAX_NODE_LABELS: u32 = 1024;
pub const DEFAULT_PATH_LENGTH_LIMIT: u32 = 30;
pub const MAX_PATH_LENGTH: u32 = 1000;

// ============================================================================
// Compression Configuration
// ============================================================================

pub const COMPRESSION_MIN_SIZE: usize = 64;             // Min size to compress
pub const COMPRESSION_BLOCK_SIZE: usize = 64 * 1024;    // 64KB blocks
pub const DICTIONARY_SIZE_THRESHOLD: f32 = 0.3;         // 30% unique values

// ============================================================================
// Memory Limits
// ============================================================================

pub const DEFAULT_MEMORY_LIMIT: usize = 8 * 1024 * 1024 * 1024;   // 8GB
pub const MIN_MEMORY_LIMIT: usize = 128 * 1024 * 1024;            // 128MB
pub const TEMP_DIRECTORY_SIZE_LIMIT: usize = 100 * 1024 * 1024 * 1024;  // 100GB

// ============================================================================
// Invalid/Sentinel Values
// ============================================================================

pub const INVALID_TABLE_ID: u64 = std.math.maxInt(u64);
pub const INVALID_COLUMN_ID: u32 = std.math.maxInt(u32);
pub const INVALID_PAGE_ID: u64 = std.math.maxInt(u64);
pub const INVALID_OFFSET: u64 = std.math.maxInt(u64);
pub const INVALID_ROW_IDX: u64 = std.math.maxInt(u64);

// ============================================================================
// File Extensions
// ============================================================================

pub const DATA_FILE_EXTENSION = ".kuzu";
pub const WAL_FILE_EXTENSION = ".wal";
pub const INDEX_FILE_EXTENSION = ".idx";
pub const CATALOG_FILE_NAME = "catalog.bin";
pub const METADATA_FILE_NAME = "metadata.bin";
pub const STATS_FILE_NAME = "stats.bin";

// ============================================================================
// Helper Functions
// ============================================================================

pub fn alignToPageSize(size: usize) usize {
    return (size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
}

pub fn alignToChunkSize(count: usize) usize {
    return (count + DEFAULT_CHUNK_SIZE - 1) & ~(DEFAULT_CHUNK_SIZE - 1);
}

pub fn pageIdToOffset(page_id: u64) u64 {
    return page_id * PAGE_SIZE;
}

pub fn offsetToPageId(offset: u64) u64 {
    return offset / PAGE_SIZE;
}

pub fn nodeOffsetToGroupIdx(offset: u64) u64 {
    return offset >> NODE_GROUP_SIZE_LOG2;
}

pub fn nodeOffsetToLocalIdx(offset: u64) u64 {
    return offset & (NODE_GROUP_SIZE - 1);
}

pub fn groupIdxAndLocalToOffset(group_idx: u64, local_idx: u64) u64 {
    return (group_idx << NODE_GROUP_SIZE_LOG2) | local_idx;
}

// ============================================================================
// Tests
// ============================================================================

test "page size alignment" {
    try std.testing.expectEqual(@as(usize, 4096), alignToPageSize(1));
    try std.testing.expectEqual(@as(usize, 4096), alignToPageSize(4096));
    try std.testing.expectEqual(@as(usize, 8192), alignToPageSize(4097));
}

test "page id offset conversion" {
    try std.testing.expectEqual(@as(u64, 0), pageIdToOffset(0));
    try std.testing.expectEqual(@as(u64, 4096), pageIdToOffset(1));
    try std.testing.expectEqual(@as(u64, 8192), pageIdToOffset(2));
    
    try std.testing.expectEqual(@as(u64, 0), offsetToPageId(0));
    try std.testing.expectEqual(@as(u64, 1), offsetToPageId(4096));
    try std.testing.expectEqual(@as(u64, 1), offsetToPageId(4100));
}

test "node group calculations" {
    try std.testing.expectEqual(@as(u64, 0), nodeOffsetToGroupIdx(0));
    try std.testing.expectEqual(@as(u64, 0), nodeOffsetToGroupIdx(2047));
    try std.testing.expectEqual(@as(u64, 1), nodeOffsetToGroupIdx(2048));
    
    try std.testing.expectEqual(@as(u64, 0), nodeOffsetToLocalIdx(0));
    try std.testing.expectEqual(@as(u64, 100), nodeOffsetToLocalIdx(100));
    try std.testing.expectEqual(@as(u64, 0), nodeOffsetToLocalIdx(2048));
}

test "group and local to offset" {
    try std.testing.expectEqual(@as(u64, 0), groupIdxAndLocalToOffset(0, 0));
    try std.testing.expectEqual(@as(u64, 2048), groupIdxAndLocalToOffset(1, 0));
    try std.testing.expectEqual(@as(u64, 2148), groupIdxAndLocalToOffset(1, 100));
}

test "constants validity" {
    try std.testing.expectEqual(@as(usize, 4096), PAGE_SIZE);
    try std.testing.expectEqual(@as(u64, 2048), NODE_GROUP_SIZE);
}