//! Common types and utilities for HippoCPP
//!
//! This module contains fundamental types used throughout the database:
//! - Type IDs and type system
//! - Value representation
//! - Internal IDs for nodes and relationships
//! - Error types

const std = @import("std");

// ============================================================================
// Type System
// ============================================================================

/// Physical type IDs for storage
pub const PhysicalTypeID = enum(u8) {
    BOOL = 0,
    INT8 = 1,
    INT16 = 2,
    INT32 = 3,
    INT64 = 4,
    INT128 = 5,
    UINT8 = 6,
    UINT16 = 7,
    UINT32 = 8,
    UINT64 = 9,
    UINT128 = 10,
    FLOAT = 11,
    DOUBLE = 12,
    STRING = 13,
    INTERVAL = 14,
    INTERNAL_ID = 15,
    LIST = 16,
    STRUCT = 17,
    ARRAY = 18,
    POINTER = 19,
};

/// Logical type IDs for the type system
pub const LogicalTypeID = enum(u8) {
    ANY = 0,
    BOOL = 1,
    INT8 = 2,
    INT16 = 3,
    INT32 = 4,
    INT64 = 5,
    INT128 = 6,
    UINT8 = 7,
    UINT16 = 8,
    UINT32 = 9,
    UINT64 = 10,
    FLOAT = 11,
    DOUBLE = 12,
    STRING = 13,
    BLOB = 14,
    DATE = 15,
    TIMESTAMP = 16,
    TIMESTAMP_TZ = 17,
    TIMESTAMP_NS = 18,
    TIMESTAMP_MS = 19,
    TIMESTAMP_SEC = 20,
    INTERVAL = 21,
    UUID = 22,
    INTERNAL_ID = 23,
    LIST = 24,
    ARRAY = 25,
    STRUCT = 26,
    MAP = 27,
    UNION = 28,
    NODE = 29,
    REL = 30,
    RECURSIVE_REL = 31,
    SERIAL = 32,
    DECIMAL = 33,
};

/// Logical type with extra info
pub const LogicalType = struct {
    type_id: LogicalTypeID,
    extra_info: ?*anyopaque = null,

    // Compile-time constant aliases (used as LogicalType.INT64, etc.)
    pub const ANY = LogicalType{ .type_id = .ANY };
    pub const BOOL = LogicalType{ .type_id = .BOOL };
    pub const INT8 = LogicalType{ .type_id = .INT8 };
    pub const INT16 = LogicalType{ .type_id = .INT16 };
    pub const INT32 = LogicalType{ .type_id = .INT32 };
    pub const INT64 = LogicalType{ .type_id = .INT64 };
    pub const INT128 = LogicalType{ .type_id = .INT128 };
    pub const UINT8 = LogicalType{ .type_id = .UINT8 };
    pub const UINT16 = LogicalType{ .type_id = .UINT16 };
    pub const UINT32 = LogicalType{ .type_id = .UINT32 };
    pub const UINT64 = LogicalType{ .type_id = .UINT64 };
    pub const UINT128 = LogicalType{ .type_id = .UINT128 };
    pub const FLOAT = LogicalType{ .type_id = .FLOAT };
    pub const DOUBLE = LogicalType{ .type_id = .DOUBLE };
    pub const STRING = LogicalType{ .type_id = .STRING };
    pub const BLOB = LogicalType{ .type_id = .BLOB };
    pub const DATE = LogicalType{ .type_id = .DATE };
    pub const TIMESTAMP = LogicalType{ .type_id = .TIMESTAMP };
    pub const TIMESTAMP_SEC = LogicalType{ .type_id = .TIMESTAMP_SEC };
    pub const TIMESTAMP_MS = LogicalType{ .type_id = .TIMESTAMP_MS };
    pub const TIMESTAMP_NS = LogicalType{ .type_id = .TIMESTAMP_NS };
    pub const TIMESTAMP_TZ = LogicalType{ .type_id = .TIMESTAMP_TZ };
    pub const INTERVAL = LogicalType{ .type_id = .INTERVAL };
    pub const INTERNAL_ID = LogicalType{ .type_id = .INTERNAL_ID };
    pub const SERIAL = LogicalType{ .type_id = .SERIAL };
    pub const LIST = LogicalType{ .type_id = .LIST };
    pub const MAP = LogicalType{ .type_id = .MAP };
    pub const STRUCT = LogicalType{ .type_id = .STRUCT };
    pub const UNION = LogicalType{ .type_id = .UNION };
    pub const ARRAY = LogicalType{ .type_id = .ARRAY };
    pub const NODE = LogicalType{ .type_id = .NODE };
    pub const REL = LogicalType{ .type_id = .REL };
    pub const RECURSIVE_REL = LogicalType{ .type_id = .RECURSIVE_REL };
    pub const UUID = LogicalType{ .type_id = .UUID };
    pub const POINTER = LogicalType{ .type_id = .POINTER };
    pub const DECIMAL = LogicalType{ .type_id = .DECIMAL };

    // Factory methods
    pub fn boolean() LogicalType { return BOOL; }
    pub fn int64() LogicalType { return INT64; }
    pub fn double() LogicalType { return DOUBLE; }
    pub fn string() LogicalType { return STRING; }
    pub fn internalID() LogicalType { return INTERNAL_ID; }

    pub fn getPhysicalType(self: LogicalType) PhysicalTypeID {
        return switch (self.type_id) {
            .BOOL => .BOOL,
            .INT8 => .INT8,
            .INT16 => .INT16,
            .INT32 => .INT32,
            .INT64, .SERIAL, .TIMESTAMP, .TIMESTAMP_TZ, .TIMESTAMP_NS, .TIMESTAMP_MS, .TIMESTAMP_SEC, .DATE => .INT64,
            .INT128 => .INT128,
            .UINT8 => .UINT8,
            .UINT16 => .UINT16,
            .UINT32 => .UINT32,
            .UINT64 => .UINT64,
            .FLOAT => .FLOAT,
            .DOUBLE, .DECIMAL => .DOUBLE,
            .STRING, .BLOB, .UUID => .STRING,
            .INTERVAL => .INTERVAL,
            .INTERNAL_ID => .INTERNAL_ID,
            .LIST, .MAP => .LIST,
            .STRUCT, .NODE, .REL, .RECURSIVE_REL, .UNION => .STRUCT,
            .ARRAY => .ARRAY,
            .ANY => .POINTER,
        };
    }
};

// ============================================================================
// Internal IDs
// ============================================================================

/// Table ID type
pub const TableID = u64;
pub const INVALID_TABLE_ID: TableID = std.math.maxInt(TableID);

/// Row/offset type within a table
pub const Offset = u64;
pub const INVALID_OFFSET: Offset = std.math.maxInt(Offset);

/// Page ID type
pub const PageIdx = u64;
pub const INVALID_PAGE_IDX: PageIdx = std.math.maxInt(PageIdx);

/// Internal ID for nodes and relationships
pub const InternalID = struct {
    table_id: TableID,
    offset: Offset,

    pub const INVALID = InternalID{
        .table_id = INVALID_TABLE_ID,
        .offset = INVALID_OFFSET,
    };

    pub fn isValid(self: InternalID) bool {
        return self.table_id != INVALID_TABLE_ID and self.offset != INVALID_OFFSET;
    }

    pub fn eql(self: InternalID, other: InternalID) bool {
        return self.table_id == other.table_id and self.offset == other.offset;
    }
};

// ============================================================================
// Value Representation
// ============================================================================

/// Union type for storing values
pub const Value = union(LogicalTypeID) {
    ANY: void,
    BOOL: bool,
    INT8: i8,
    INT16: i16,
    INT32: i32,
    INT64: i64,
    INT128: i128,
    UINT8: u8,
    UINT16: u16,
    UINT32: u32,
    UINT64: u64,
    FLOAT: f32,
    DOUBLE: f64,
    STRING: []const u8,
    BLOB: []const u8,
    DATE: i64,
    TIMESTAMP: i64,
    TIMESTAMP_TZ: i64,
    TIMESTAMP_NS: i64,
    TIMESTAMP_MS: i64,
    TIMESTAMP_SEC: i64,
    INTERVAL: Interval,
    UUID: [16]u8,
    INTERNAL_ID: InternalID,
    LIST: []Value,
    ARRAY: []Value,
    STRUCT: []StructField,
    MAP: []MapEntry,
    UNION: *Value,
    NODE: NodeValue,
    REL: RelValue,
    RECURSIVE_REL: RecursiveRelValue,
    SERIAL: i64,
    DECIMAL: f64,

    pub fn isNull(self: Value) bool {
        return self == .ANY;
    }

    pub fn getBool(self: Value) ?bool {
        return if (self == .BOOL) self.BOOL else null;
    }

    pub fn getInt64(self: Value) ?i64 {
        return switch (self) {
            .INT64 => |v| v,
            .INT32 => |v| @intCast(v),
            .INT16 => |v| @intCast(v),
            .INT8 => |v| @intCast(v),
            else => null,
        };
    }

    pub fn getDouble(self: Value) ?f64 {
        return switch (self) {
            .DOUBLE => |v| v,
            .FLOAT => |v| @floatCast(v),
            else => null,
        };
    }

    pub fn getString(self: Value) ?[]const u8 {
        return if (self == .STRING) self.STRING else null;
    }
};

/// Interval representation
pub const Interval = struct {
    months: i32,
    days: i32,
    micros: i64,
};

/// Struct field
pub const StructField = struct {
    name: []const u8,
    value: Value,
};

/// Map entry
pub const MapEntry = struct {
    key: Value,
    value: Value,
};

/// Node value
pub const NodeValue = struct {
    id: InternalID,
    label: []const u8,
    properties: []StructField,
};

/// Relationship value
pub const RelValue = struct {
    id: InternalID,
    src_id: InternalID,
    dst_id: InternalID,
    label: []const u8,
    properties: []StructField,
};

/// Recursive relationship value
pub const RecursiveRelValue = struct {
    nodes: []NodeValue,
    rels: []RelValue,
};

// ============================================================================
// Constants
// ============================================================================

pub const KUZU_PAGE_SIZE: usize = 4096;
pub const NUM_BYTES_PER_PAGE_IDX: usize = 4;
pub const PAGE_IDX_BITS: usize = NUM_BYTES_PER_PAGE_IDX * 8;

/// Storage constants
pub const StorageConstants = struct {
    pub const PAGE_SIZE: usize = KUZU_PAGE_SIZE;
    pub const DB_HEADER_PAGE_IDX: PageIdx = 0;
    pub const CATALOG_PAGE_IDX: PageIdx = 1;
    pub const MAX_STRING_LENGTH: usize = 4096;
    pub const NODE_GROUP_SIZE: usize = 64 * 1024;
};

// ============================================================================
// UUID
// ============================================================================

pub const UUID = struct {
    bytes: [16]u8,

    pub fn generate(random: std.Random) UUID {
        var uuid: UUID = undefined;
        random.bytes(&uuid.bytes);
        // Set version 4
        uuid.bytes[6] = (uuid.bytes[6] & 0x0f) | 0x40;
        // Set variant
        uuid.bytes[8] = (uuid.bytes[8] & 0x3f) | 0x80;
        return uuid;
    }

    pub fn format(self: UUID, buf: []u8) []const u8 {
        const hex = "0123456789abcdef";
        var i: usize = 0;
        var j: usize = 0;

        while (i < 16) : (i += 1) {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[j] = '-';
                j += 1;
            }
            buf[j] = hex[self.bytes[i] >> 4];
            buf[j + 1] = hex[self.bytes[i] & 0x0f];
            j += 2;
        }

        return buf[0..36];
    }
};

// ============================================================================
// Error Types
// ============================================================================

pub const HippoError = error{
    OutOfMemory,
    InvalidArgument,
    FileNotFound,
    PermissionDenied,
    IOError,
    CorruptedData,
    InvalidState,
    TransactionConflict,
    CheckpointFailed,
    WALCorrupted,
    BufferPoolFull,
    PageNotFound,
    TableNotFound,
    ColumnNotFound,
    IndexNotFound,
    TypeMismatch,
    Overflow,
    DivisionByZero,
    ParseError,
    BindError,
    PlannerError,
    ExecutionError,
};

// ============================================================================
// Tests
// ============================================================================

test "internal id" {
    const id1 = InternalID{ .table_id = 1, .offset = 100 };
    const id2 = InternalID{ .table_id = 1, .offset = 100 };
    const id3 = InternalID{ .table_id = 2, .offset = 100 };

    try std.testing.expect(id1.isValid());
    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
    try std.testing.expect(!InternalID.INVALID.isValid());
}

test "value types" {
    const bool_val = Value{ .BOOL = true };
    const int_val = Value{ .INT64 = 42 };
    const str_val = Value{ .STRING = "hello" };

    try std.testing.expectEqual(true, bool_val.getBool());
    try std.testing.expectEqual(@as(i64, 42), int_val.getInt64());
    try std.testing.expectEqualStrings("hello", str_val.getString().?);
}

test "logical type physical mapping" {
    try std.testing.expectEqual(PhysicalTypeID.BOOL, LogicalType.boolean().getPhysicalType());
    try std.testing.expectEqual(PhysicalTypeID.INT64, LogicalType.int64().getPhysicalType());
    try std.testing.expectEqual(PhysicalTypeID.DOUBLE, LogicalType.double().getPhysicalType());
    try std.testing.expectEqual(PhysicalTypeID.STRING, LogicalType.string().getPhysicalType());
}