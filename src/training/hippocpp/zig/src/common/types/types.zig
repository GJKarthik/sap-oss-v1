//! Core Type System
//!
//! Defines all fundamental type aliases, enums, and structs used throughout
//! the database engine. Ported from kuzu/src/include/common/types/types.h.

const std = @import("std");

// ============================================================================
// Type Aliases (matching C++ using declarations)
// ============================================================================

pub const sel_t = u64;
pub const INVALID_SEL: sel_t = std.math.maxInt(u64);

pub const hash_t = u64;

pub const page_idx_t = u32;
pub const frame_idx_t = page_idx_t;
pub const page_offset_t = u32;
pub const INVALID_PAGE_IDX: page_idx_t = std.math.maxInt(u32);

pub const file_idx_t = u32;
pub const INVALID_FILE_IDX: file_idx_t = std.math.maxInt(u32);

pub const page_group_idx_t = u32;
pub const frame_group_idx_t = page_group_idx_t;

pub const column_id_t = u32;
pub const property_id_t = u32;
pub const INVALID_COLUMN_ID: column_id_t = std.math.maxInt(u32);
pub const ROW_IDX_COLUMN_ID: column_id_t = INVALID_COLUMN_ID - 1;

pub const idx_t = u32;
pub const INVALID_IDX: idx_t = std.math.maxInt(u32);

pub const block_idx_t = u64;
pub const INVALID_BLOCK_IDX: block_idx_t = std.math.maxInt(u64);

pub const struct_field_idx_t = u16;
pub const union_field_idx_t = struct_field_idx_t;
pub const INVALID_STRUCT_FIELD_IDX: struct_field_idx_t = std.math.maxInt(u16);

pub const row_idx_t = u64;
pub const INVALID_ROW_IDX: row_idx_t = std.math.maxInt(u64);

pub const UNDEFINED_CAST_COST: u32 = std.math.maxInt(u32);

pub const node_group_idx_t = u64;
pub const INVALID_NODE_GROUP_IDX: node_group_idx_t = std.math.maxInt(u64);

pub const partition_idx_t = u64;
pub const INVALID_PARTITION_IDX: partition_idx_t = std.math.maxInt(u64);

pub const length_t = u64;
pub const INVALID_LENGTH: length_t = std.math.maxInt(u64);

pub const list_size_t = u32;
pub const sequence_id_t = u64;

pub const oid_t = u64;
pub const INVALID_OID: oid_t = std.math.maxInt(u64);

pub const transaction_t = u64;
pub const INVALID_TRANSACTION: transaction_t = std.math.maxInt(u64);

pub const executor_id_t = u64;

pub const table_id_t = oid_t;
pub const INVALID_TABLE_ID: table_id_t = INVALID_OID;

pub const offset_t = u64;
pub const INVALID_OFFSET: offset_t = std.math.maxInt(u64);

pub const cardinality_t = u64;
pub const INVALID_LIMIT: offset_t = std.math.maxInt(u64);

// ============================================================================
// Internal ID
// ============================================================================

pub const internalID_t = struct {
    offset: offset_t,
    tableID: table_id_t,

    const Self = @This();

    pub fn init(off: offset_t, tid: table_id_t) Self {
        return .{ .offset = off, .tableID = tid };
    }

    pub fn invalid() Self {
        return .{ .offset = INVALID_OFFSET, .tableID = INVALID_TABLE_ID };
    }

    pub fn eql(self: Self, other: Self) bool {
        return self.offset == other.offset and self.tableID == other.tableID;
    }

    pub fn lessThan(self: Self, other: Self) bool {
        if (self.tableID < other.tableID) return true;
        if (self.tableID > other.tableID) return false;
        return self.offset < other.offset;
    }

    pub fn greaterThan(self: Self, other: Self) bool {
        return other.lessThan(self);
    }

    pub fn lessOrEqual(self: Self, other: Self) bool {
        return !self.greaterThan(other);
    }

    pub fn greaterOrEqual(self: Self, other: Self) bool {
        return !self.lessThan(other);
    }
};

pub const nodeID_t = internalID_t;
pub const relID_t = internalID_t;

// ============================================================================
// Entry Types (for columnar storage)
// ============================================================================

pub const overflow_value_t = struct {
    numElements: u64 = 0,
    value: ?[*]u8 = null,
};

pub const list_entry_t = struct {
    offset: offset_t = INVALID_OFFSET,
    size: list_size_t = std.math.maxInt(u32),

    pub fn init(off: offset_t, sz: list_size_t) list_entry_t {
        return .{ .offset = off, .size = sz };
    }
};

pub const struct_entry_t = struct {
    pos: i64 = 0,
};

pub const map_entry_t = struct {
    entry: list_entry_t = .{},
};

pub const union_entry_t = struct {
    entry: struct_entry_t = .{},
};

// ============================================================================
// Logical Type ID Enum
// ============================================================================

pub const LogicalTypeID = enum(u8) {
    ANY = 0,
    NODE = 10,
    REL = 11,
    RECURSIVE_REL = 12,
    SERIAL = 13,
    BOOL = 22,
    INT64 = 23,
    INT32 = 24,
    INT16 = 25,
    INT8 = 26,
    UINT64 = 27,
    UINT32 = 28,
    UINT16 = 29,
    UINT8 = 30,
    INT128 = 31,
    DOUBLE = 32,
    FLOAT = 33,
    DATE = 34,
    TIMESTAMP = 35,
    TIMESTAMP_SEC = 36,
    TIMESTAMP_MS = 37,
    TIMESTAMP_NS = 38,
    TIMESTAMP_TZ = 39,
    INTERVAL = 40,
    DECIMAL = 41,
    INTERNAL_ID = 42,
    UINT128 = 43,
    STRING = 50,
    BLOB = 51,
    LIST = 52,
    ARRAY = 53,
    STRUCT = 54,
    MAP = 55,
    UNION = 56,
    POINTER = 58,
    UUID = 59,

    pub fn toString(self: LogicalTypeID) []const u8 {
        return switch (self) {
            .ANY => "ANY",
            .NODE => "NODE",
            .REL => "REL",
            .RECURSIVE_REL => "RECURSIVE_REL",
            .SERIAL => "SERIAL",
            .BOOL => "BOOL",
            .INT64 => "INT64",
            .INT32 => "INT32",
            .INT16 => "INT16",
            .INT8 => "INT8",
            .UINT64 => "UINT64",
            .UINT32 => "UINT32",
            .UINT16 => "UINT16",
            .UINT8 => "UINT8",
            .INT128 => "INT128",
            .DOUBLE => "DOUBLE",
            .FLOAT => "FLOAT",
            .DATE => "DATE",
            .TIMESTAMP => "TIMESTAMP",
            .TIMESTAMP_SEC => "TIMESTAMP_SEC",
            .TIMESTAMP_MS => "TIMESTAMP_MS",
            .TIMESTAMP_NS => "TIMESTAMP_NS",
            .TIMESTAMP_TZ => "TIMESTAMP_TZ",
            .INTERVAL => "INTERVAL",
            .DECIMAL => "DECIMAL",
            .INTERNAL_ID => "INTERNAL_ID",
            .UINT128 => "UINT128",
            .STRING => "STRING",
            .BLOB => "BLOB",
            .LIST => "LIST",
            .ARRAY => "ARRAY",
            .STRUCT => "STRUCT",
            .MAP => "MAP",
            .UNION => "UNION",
            .POINTER => "POINTER",
            .UUID => "UUID",
        };
    }

    pub fn isNested(self: LogicalTypeID) bool {
        return switch (self) {
            .LIST, .ARRAY, .STRUCT, .MAP, .UNION, .NODE, .REL, .RECURSIVE_REL => true,
            else => false,
        };
    }

    pub fn isIntegral(self: LogicalTypeID) bool {
        return switch (self) {
            .INT8, .INT16, .INT32, .INT64, .INT128, .UINT8, .UINT16, .UINT32, .UINT64, .UINT128, .SERIAL => true,
            else => false,
        };
    }

    pub fn isUnsigned(self: LogicalTypeID) bool {
        return switch (self) {
            .UINT8, .UINT16, .UINT32, .UINT64, .UINT128 => true,
            else => false,
        };
    }

    pub fn isFloatingPoint(self: LogicalTypeID) bool {
        return self == .FLOAT or self == .DOUBLE;
    }

    pub fn isNumerical(self: LogicalTypeID) bool {
        return self.isIntegral() or self.isFloatingPoint() or self == .DECIMAL;
    }

    pub fn isDate(self: LogicalTypeID) bool {
        return self == .DATE;
    }

    pub fn isTimestamp(self: LogicalTypeID) bool {
        return switch (self) {
            .TIMESTAMP, .TIMESTAMP_SEC, .TIMESTAMP_MS, .TIMESTAMP_NS, .TIMESTAMP_TZ => true,
            else => false,
        };
    }
};

// ============================================================================
// Physical Type ID Enum
// ============================================================================

pub const PhysicalTypeID = enum(u8) {
    ANY = 0,
    BOOL = 1,
    INT64 = 2,
    INT32 = 3,
    INT16 = 4,
    INT8 = 5,
    UINT64 = 6,
    UINT32 = 7,
    UINT16 = 8,
    UINT8 = 9,
    INT128 = 10,
    DOUBLE = 11,
    FLOAT = 12,
    INTERVAL = 13,
    INTERNAL_ID = 14,
    ALP_EXCEPTION_FLOAT = 15,
    ALP_EXCEPTION_DOUBLE = 16,
    UINT128 = 17,
    STRING = 20,
    LIST = 22,
    ARRAY = 23,
    STRUCT = 24,
    POINTER = 25,

    pub fn toString(self: PhysicalTypeID) []const u8 {
        return switch (self) {
            .ANY => "ANY",
            .BOOL => "BOOL",
            .INT64 => "INT64",
            .INT32 => "INT32",
            .INT16 => "INT16",
            .INT8 => "INT8",
            .UINT64 => "UINT64",
            .UINT32 => "UINT32",
            .UINT16 => "UINT16",
            .UINT8 => "UINT8",
            .INT128 => "INT128",
            .DOUBLE => "DOUBLE",
            .FLOAT => "FLOAT",
            .INTERVAL => "INTERVAL",
            .INTERNAL_ID => "INTERNAL_ID",
            .ALP_EXCEPTION_FLOAT => "ALP_EXCEPTION_FLOAT",
            .ALP_EXCEPTION_DOUBLE => "ALP_EXCEPTION_DOUBLE",
            .UINT128 => "UINT128",
            .STRING => "STRING",
            .LIST => "LIST",
            .ARRAY => "ARRAY",
            .STRUCT => "STRUCT",
            .POINTER => "POINTER",
        };
    }

    pub fn getFixedTypeSize(self: PhysicalTypeID) u32 {
        return switch (self) {
            .BOOL => 1,
            .INT8, .UINT8 => 1,
            .INT16, .UINT16 => 2,
            .INT32, .UINT32, .FLOAT => 4,
            .INT64, .UINT64, .DOUBLE => 8,
            .INT128, .UINT128, .INTERVAL, .INTERNAL_ID => 16,
            .POINTER => 8,
            else => 0,
        };
    }
};

// ============================================================================
// Logical Type ID -> Physical Type ID mapping
// ============================================================================

pub fn getPhysicalType(logical_id: LogicalTypeID) PhysicalTypeID {
    return switch (logical_id) {
        .ANY => .ANY,
        .BOOL => .BOOL,
        .INT64, .SERIAL => .INT64,
        .INT32 => .INT32,
        .INT16 => .INT16,
        .INT8 => .INT8,
        .UINT64 => .UINT64,
        .UINT32 => .UINT32,
        .UINT16 => .UINT16,
        .UINT8 => .UINT8,
        .INT128 => .INT128,
        .UINT128 => .UINT128,
        .DOUBLE => .DOUBLE,
        .FLOAT => .FLOAT,
        .DATE, .TIMESTAMP, .TIMESTAMP_SEC, .TIMESTAMP_MS, .TIMESTAMP_NS, .TIMESTAMP_TZ => .INT64,
        .INTERVAL => .INTERVAL,
        .DECIMAL => .INT128, // default; actual depends on precision
        .INTERNAL_ID => .INTERNAL_ID,
        .STRING, .BLOB, .UUID => .STRING,
        .LIST, .MAP => .LIST,
        .ARRAY => .ARRAY,
        .STRUCT, .UNION, .NODE, .REL, .RECURSIVE_REL => .STRUCT,
        .POINTER => .POINTER,
    };
}

// ============================================================================
// Logical Type
// ============================================================================

pub const TypeCategory = enum(u8) {
    INTERNAL = 0,
    UDT = 1,
};

pub const StructField = struct {
    name: []const u8,
    type_id: LogicalTypeID,
    physical_type: PhysicalTypeID,

    pub fn init(name: []const u8, type_id: LogicalTypeID) StructField {
        return .{
            .name = name,
            .type_id = type_id,
            .physical_type = getPhysicalType(type_id),
        };
    }

    pub fn eql(self: StructField, other: StructField) bool {
        return std.mem.eql(u8, self.name, other.name) and self.type_id == other.type_id;
    }
};

pub const LogicalType = struct {
    type_id: LogicalTypeID,
    physical_type: PhysicalTypeID,
    category: TypeCategory = .INTERNAL,
    /// For DECIMAL: precision
    precision: u32 = 0,
    /// For DECIMAL: scale
    scale: u32 = 0,
    /// For ARRAY: num_elements
    num_elements: u64 = 0,
    /// For LIST/ARRAY: child type ID
    child_type: LogicalTypeID = .ANY,
    /// For STRUCT/NODE/REL/UNION: fields (max 64 for stack allocation)
    fields: [64]StructField = undefined,
    num_fields: u16 = 0,

    const Self = @This();

    pub fn init(type_id: LogicalTypeID) Self {
        return .{
            .type_id = type_id,
            .physical_type = getPhysicalType(type_id),
        };
    }

    // Factory methods matching C++ static methods
    pub fn ANY() Self { return init(.ANY); }
    pub fn BOOL() Self { return init(.BOOL); }
    pub fn INT8() Self { return init(.INT8); }
    pub fn INT16() Self { return init(.INT16); }
    pub fn INT32() Self { return init(.INT32); }
    pub fn INT64() Self { return init(.INT64); }
    pub fn INT128() Self { return init(.INT128); }
    pub fn UINT8() Self { return init(.UINT8); }
    pub fn UINT16() Self { return init(.UINT16); }
    pub fn UINT32() Self { return init(.UINT32); }
    pub fn UINT64() Self { return init(.UINT64); }
    pub fn UINT128() Self { return init(.UINT128); }
    pub fn FLOAT() Self { return init(.FLOAT); }
    pub fn DOUBLE() Self { return init(.DOUBLE); }
    pub fn DATE() Self { return init(.DATE); }
    pub fn TIMESTAMP() Self { return init(.TIMESTAMP); }
    pub fn TIMESTAMP_NS() Self { return init(.TIMESTAMP_NS); }
    pub fn TIMESTAMP_MS() Self { return init(.TIMESTAMP_MS); }
    pub fn TIMESTAMP_SEC() Self { return init(.TIMESTAMP_SEC); }
    pub fn TIMESTAMP_TZ() Self { return init(.TIMESTAMP_TZ); }
    pub fn INTERVAL() Self { return init(.INTERVAL); }
    pub fn INTERNAL_ID() Self { return init(.INTERNAL_ID); }
    pub fn SERIAL() Self { return init(.SERIAL); }
    pub fn STRING() Self { return init(.STRING); }
    pub fn BLOB() Self { return init(.BLOB); }
    pub fn UUID() Self { return init(.UUID); }
    pub fn POINTER() Self { return init(.POINTER); }


    pub fn DECIMAL(prec: u32, scl: u32) Self {
        var t = init(.DECIMAL);
        t.precision = prec;
        t.scale = scl;
        // Precision determines physical type
        if (prec <= 4) {
            t.physical_type = .INT16;
        } else if (prec <= 9) {
            t.physical_type = .INT32;
        } else if (prec <= 18) {
            t.physical_type = .INT64;
        } else {
            t.physical_type = .INT128;
        }
        return t;
    }

    pub fn LIST(child: LogicalTypeID) Self {
        var t = init(.LIST);
        t.child_type = child;
        return t;
    }

    pub fn ARRAY(child: LogicalTypeID, num: u64) Self {
        var t = init(.ARRAY);
        t.child_type = child;
        t.num_elements = num;
        return t;
    }

    pub fn MAP(key: LogicalTypeID, value: LogicalTypeID) Self {
        // MAP is stored as LIST of STRUCT{key, value}
        var t = init(.MAP);
        t.child_type = key; // simplified; real impl uses struct child
        t.fields[0] = StructField.init("key", key);
        t.fields[1] = StructField.init("value", value);
        t.num_fields = 2;
        return t;
    }

    pub fn STRUCT(field_list: []const StructField) Self {
        var t = init(.STRUCT);
        const n = @min(field_list.len, 64);
        for (0..n) |i| {
            t.fields[i] = field_list[i];
        }
        t.num_fields = @intCast(n);
        return t;
    }

    pub fn eql(self: Self, other: Self) bool {
        if (self.type_id != other.type_id) return false;
        if (self.type_id == .DECIMAL) {
            return self.precision == other.precision and self.scale == other.scale;
        }
        if (self.type_id == .LIST or self.type_id == .ARRAY) {
            if (self.child_type != other.child_type) return false;
            if (self.type_id == .ARRAY and self.num_elements != other.num_elements) return false;
        }
        if (self.type_id == .STRUCT or self.type_id == .MAP or self.type_id == .UNION) {
            if (self.num_fields != other.num_fields) return false;
            for (0..self.num_fields) |i| {
                if (!self.fields[i].eql(other.fields[i])) return false;
            }
        }
        return true;
    }

    pub fn containsAny(self: Self) bool {
        if (self.type_id == .ANY) return true;
        if (self.type_id == .LIST or self.type_id == .ARRAY) {
            return self.child_type == .ANY;
        }
        if (self.num_fields > 0) {
            for (0..self.num_fields) |i| {
                if (self.fields[i].type_id == .ANY) return true;
            }
        }
        return false;
    }

    pub fn getLogicalTypeID(self: Self) LogicalTypeID {
        return self.type_id;
    }

    pub fn getPhysicalType2(self: Self) PhysicalTypeID {
        return self.physical_type;
    }

    pub fn isInternalType(self: Self) bool {
        return self.category == .INTERNAL;
    }

    pub fn toString(self: Self) []const u8 {
        return self.type_id.toString();
    }

    pub fn getRowLayoutSize(self: Self) u32 {
        return self.physical_type.getFixedTypeSize();
    }
};

pub const FileVersionType = enum(u8) {
    ORIGINAL = 0,
    WAL_VERSION = 1,
};

// ============================================================================
// Tests
// ============================================================================

test "type aliases" {
    try std.testing.expect(INVALID_PAGE_IDX == std.math.maxInt(u32));
    try std.testing.expect(INVALID_TABLE_ID == std.math.maxInt(u64));
    try std.testing.expect(INVALID_OFFSET == std.math.maxInt(u64));
    try std.testing.expect(INVALID_SEL == std.math.maxInt(u64));
}

test "internalID_t" {
    const id1 = internalID_t.init(10, 1);
    const id2 = internalID_t.init(20, 1);
    const id3 = internalID_t.init(10, 2);

    try std.testing.expect(id1.eql(id1));
    try std.testing.expect(!id1.eql(id2));
    try std.testing.expect(id1.lessThan(id2));
    try std.testing.expect(id1.lessThan(id3));
    try std.testing.expect(id2.greaterThan(id1));

    const inv = internalID_t.invalid();
    try std.testing.expect(inv.offset == INVALID_OFFSET);
}

test "LogicalTypeID" {
    try std.testing.expectEqualStrings("INT64", LogicalTypeID.INT64.toString());
    try std.testing.expect(LogicalTypeID.INT64.isIntegral());
    try std.testing.expect(!LogicalTypeID.INT64.isFloatingPoint());
    try std.testing.expect(LogicalTypeID.DOUBLE.isFloatingPoint());
    try std.testing.expect(LogicalTypeID.DOUBLE.isNumerical());
    try std.testing.expect(LogicalTypeID.LIST.isNested());
    try std.testing.expect(!LogicalTypeID.STRING.isNested());
    try std.testing.expect(LogicalTypeID.UINT32.isUnsigned());
    try std.testing.expect(LogicalTypeID.TIMESTAMP.isTimestamp());
    try std.testing.expect(LogicalTypeID.DATE.isDate());
}

test "PhysicalTypeID sizes" {
    try std.testing.expect(PhysicalTypeID.INT32.getFixedTypeSize() == 4);
    try std.testing.expect(PhysicalTypeID.INT64.getFixedTypeSize() == 8);
    try std.testing.expect(PhysicalTypeID.INT128.getFixedTypeSize() == 16);
    try std.testing.expect(PhysicalTypeID.BOOL.getFixedTypeSize() == 1);
}

test "getPhysicalType mapping" {
    try std.testing.expect(getPhysicalType(.INT64) == .INT64);
    try std.testing.expect(getPhysicalType(.DATE) == .INT64);
    try std.testing.expect(getPhysicalType(.STRING) == .STRING);
    try std.testing.expect(getPhysicalType(.LIST) == .LIST);
    try std.testing.expect(getPhysicalType(.STRUCT) == .STRUCT);
    try std.testing.expect(getPhysicalType(.SERIAL) == .INT64);
    try std.testing.expect(getPhysicalType(.INTERVAL) == .INTERVAL);
}

test "LogicalType factory methods" {
    const i64t = LogicalType.INT64();
    try std.testing.expect(i64t.type_id == .INT64);
    try std.testing.expect(i64t.physical_type == .INT64);

    const dec = LogicalType.DECIMAL(18, 3);
    try std.testing.expect(dec.type_id == .DECIMAL);
    try std.testing.expect(dec.precision == 18);
    try std.testing.expect(dec.scale == 3);
    try std.testing.expect(dec.physical_type == .INT64);

    const small_dec = LogicalType.DECIMAL(4, 2);
    try std.testing.expect(small_dec.physical_type == .INT16);

    const list_t = LogicalType.LIST(.INT32);
    try std.testing.expect(list_t.type_id == .LIST);
    try std.testing.expect(list_t.child_type == .INT32);

    const arr_t = LogicalType.ARRAY(.FLOAT, 100);
    try std.testing.expect(arr_t.num_elements == 100);
}

test "LogicalType equality" {
    const a = LogicalType.INT64();
    const b = LogicalType.INT64();
    const c = LogicalType.STRING();
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));

    const d1 = LogicalType.DECIMAL(18, 3);
    const d2 = LogicalType.DECIMAL(18, 3);
    const d3 = LogicalType.DECIMAL(10, 2);
    try std.testing.expect(d1.eql(d2));
    try std.testing.expect(!d1.eql(d3));
}

test "LogicalType containsAny" {
    try std.testing.expect(LogicalType.ANY().containsAny());
    try std.testing.expect(!LogicalType.INT64().containsAny());
    try std.testing.expect(LogicalType.LIST(.ANY).containsAny());
}

test "list_entry_t" {
    const entry = list_entry_t.init(10, 5);
    try std.testing.expect(entry.offset == 10);
    try std.testing.expect(entry.size == 5);

    const default_entry = list_entry_t{};
    try std.testing.expect(default_entry.offset == INVALID_OFFSET);
}