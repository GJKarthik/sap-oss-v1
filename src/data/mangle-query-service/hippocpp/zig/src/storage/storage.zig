//! Storage Module
//!
//! Re-exports all storage-related types and functions.

pub const storage_manager = @import("storage_manager.zig");
pub const page_manager = @import("page_manager.zig");
pub const file_handle = @import("file_handle.zig");
pub const shadow_file = @import("shadow_file.zig");
pub const database_header = @import("database_header.zig");
pub const wal = @import("wal/wal.zig");

// Re-export main types
pub const StorageManager = storage_manager.StorageManager;
pub const PageManager = page_manager.PageManager;
pub const FileHandle = file_handle.FileHandle;
pub const ShadowFile = shadow_file.ShadowFile;
pub const DatabaseHeader = database_header.DatabaseHeader;
pub const WAL = wal.WAL;