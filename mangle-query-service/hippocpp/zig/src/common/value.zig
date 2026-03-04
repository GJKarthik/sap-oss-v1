//! Value - Runtime value representation
//!
//! Purpose:
//! Provides a tagged union type for all database values including
//! nested types (lists, structs, maps) and graph-specific types.

const std = @import("std");

// ============================================================================
// Internal ID (Node/Relationship identifier)
// ============================================================================

pub const InternalID = struct {
    table_id: u64,
    offset: u64,
    
    pub fn init(table_id: u64, offset: u64) InternalID {
        return .{ .table_id = table_id, .offset = offset };
    }
    
    pub fn eql(self: InternalID, other: InternalID) bool {
        return self.table_id == other.table_id and self.offset == other.offset;
    }
    
    pub fn hash(self: InternalID) u64 {
        return self.table_id ^ (self.offset << 32) ^ (self.offset >> 32);
    }
    
    pub fn format(self: InternalID, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{d}:{d}", .{ self.table_id, self.offset });
    }
};

// ============================================================================
// Date/Time Types
// ============================================================================

pub const Date = struct {
    days: i32,  // Days since 1970-01-01
    
    pub fn fromYMD(year: i32, month: u8, day: u8) Date {
        // Simplified calculation
        var days: i32 = 0;
        days += (year - 1970) * 365;
        days += @divTrunc(year - 1969, 4);  // Leap years
        const month_days = [_]i32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
        days += month_days[@as(usize, month) - 1];
        days += @as(i32, day) - 1;
        return .{ .days = days };
    }
};

pub const Time = struct {
    micros: i64,  // Microseconds since midnight
    
    pub fn fromHMS(hour: u8, minute: u8, second: u8) Time {
        const micros = @as(i64, hour) * 3600_000_000 + 
                       @as(i64, minute) * 60_000_000 + 
                       @as(i64, second) * 1_000_000;
        return .{ .micros = micros };
    }
};

pub const Timestamp = struct {
    micros: i64,  // Microseconds since 1970-01-01 00:00:00
    
    pub fn now() Timestamp {
        return .{ .micros = std.time.microTimestamp() };
    }
};

pub const Interval = struct {
    months: i32,
    days: i32,
    micros: i64,
};

// ============================================================================
// Value Type Enum
// ============================================================================

pub const ValueType = enum(u8) {
    NULL,
    BOOL,
    INT8,
    INT16,
    INT32,
    INT64,
    INT128,
    UINT8,
    UINT16,
    UINT32,
    UINT64,
    FLOAT,
    DOUBLE,
    STRING,
    BLOB,
    DATE,
    TIME,
    TIMESTAMP,
    INTERVAL,
    UUID,
    INTERNAL_ID,
    LIST,
    STRUCT,
    MAP,
    NODE,
    REL,
    PATH,
};

// ============================================================================
// Value Union Type
// ============================================================================

pub const Value = union(ValueType) {
    NULL: void,
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
    DATE: Date,
    TIME: Time,
    TIMESTAMP: Timestamp,
    INTERVAL: Interval,
    UUID: [16]u8,
    INTERNAL_ID: InternalID,
    LIST: ListValue,
    STRUCT: StructValue,
    MAP: MapValue,
    NODE: NodeValue,
    REL: RelValue,
    PATH: PathValue,
    
    // ========================================================================
    // Constructors
    // ========================================================================
    
    pub fn null_() Value {
        return .{ .NULL = {} };
    }
    
    pub fn boolean(v: bool) Value {
        return .{ .BOOL = v };
    }
    
    pub fn int64(v: i64) Value {
        return .{ .INT64 = v };
    }
    
    pub fn float64(v: f64) Value {
        return .{ .DOUBLE = v };
    }
    
    pub fn string(s: []const u8) Value {
        return .{ .STRING = s };
    }
    
    pub fn internalId(id: InternalID) Value {
        return .{ .INTERNAL_ID = id };
    }
    
    // ========================================================================
    // Type Checks
    // ========================================================================
    
    pub fn isNull(self: Value) bool {
        return self == .NULL;
    }
    
    pub fn getType(self: Value) ValueType {
        return @as(ValueType, self);
    }
    
    // ========================================================================
    // Value Extraction
    // ========================================================================
    
    pub fn getBool(self: Value) ?bool {
        return switch (self) {
            .BOOL => |v| v,
            else => null,
        };
    }
    
    pub fn getInt64(self: Value) ?i64 {
        return switch (self) {
            .INT8 => |v| @as(i64, v),
            .INT16 => |v| @as(i64, v),
            .INT32 => |v| @as(i64, v),
            .INT64 => |v| v,
            else => null,
        };
    }
    
    pub fn getDouble(self: Value) ?f64 {
        return switch (self) {
            .FLOAT => |v| @as(f64, v),
            .DOUBLE => |v| v,
            else => null,
        };
    }
    
    pub fn getString(self: Value) ?[]const u8 {
        return switch (self) {
            .STRING => |v| v,
            else => null,
        };
    }
    
    pub fn getInternalId(self: Value) ?InternalID {
        return switch (self) {
            .INTERNAL_ID => |v| v,
            else => null,
        };
    }
    
    // ========================================================================
    // Comparison
    // ========================================================================
    
    pub fn eql(self: Value, other: Value) bool {
        if (@as(ValueType, self) != @as(ValueType, other)) return false;
        
        return switch (self) {
            .NULL => true,
            .BOOL => |v| v == other.BOOL,
            .INT64 => |v| v == other.INT64,
            .DOUBLE => |v| v == other.DOUBLE,
            .STRING => |v| std.mem.eql(u8, v, other.STRING),
            .INTERNAL_ID => |v| v.eql(other.INTERNAL_ID),
            else => false,  // Complex types need deep comparison
        };
    }
    
    pub fn lessThan(self: Value, other: Value) bool {
        if (@as(ValueType, self) != @as(ValueType, other)) return false;
        
        return switch (self) {
            .INT64 => |v| v < other.INT64,
            .DOUBLE => |v| v < other.DOUBLE,
            .STRING => |v| std.mem.lessThan(u8, v, other.STRING),
            else => false,
        };
    }
    
    // ========================================================================
    // Hash
    // ========================================================================
    
    pub fn hash(self: Value) u64 {
        return switch (self) {
            .NULL => 0,
            .BOOL => |v| if (v) 1 else 0,
            .INT64 => |v| @bitCast(v),
            .DOUBLE => |v| @bitCast(v),
            .STRING => |v| std.hash.Wyhash.hash(0, v),
            .INTERNAL_ID => |v| v.hash(),
            else => 0,
        };
    }
};

// ============================================================================
// List Value
// ============================================================================

pub const ListValue = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(Value),
    
    pub fn init(allocator: std.mem.Allocator) ListValue {
        return .{
            .allocator = allocator,
            .values = std.ArrayList(Value).init(allocator),
        };
    }
    
    pub fn deinit(self: *ListValue) void {
        self.values.deinit();
    }
    
    pub fn append(self: *ListValue, value: Value) !void {
        try self.values.append(value);
    }
    
    pub fn get(self: *const ListValue, idx: usize) ?Value {
        if (idx >= self.values.items.len) return null;
        return self.values.items[idx];
    }
    
    pub fn len(self: *const ListValue) usize {
        return self.values.items.len;
    }
};

// ============================================================================
// Struct Value
// ============================================================================

pub const StructValue = struct {
    allocator: std.mem.Allocator,
    fields: std.StringHashMap(Value),
    
    pub fn init(allocator: std.mem.Allocator) StructValue {
        return .{
            .allocator = allocator,
            .fields = std.StringHashMap(Value).init(allocator),
        };
    }
    
    pub fn deinit(self: *StructValue) void {
        self.fields.deinit();
    }
    
    pub fn set(self: *StructValue, name: []const u8, value: Value) !void {
        try self.fields.put(name, value);
    }
    
    pub fn get(self: *const StructValue, name: []const u8) ?Value {
        return self.fields.get(name);
    }
};

// ============================================================================
// Map Value
// ============================================================================

pub const MapValue = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(MapEntry),
    
    pub const MapEntry = struct {
        key: Value,
        value: Value,
    };
    
    pub fn init(allocator: std.mem.Allocator) MapValue {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(MapEntry).init(allocator),
        };
    }
    
    pub fn deinit(self: *MapValue) void {
        self.entries.deinit();
    }
    
    pub fn put(self: *MapValue, key: Value, value: Value) !void {
        // Check for existing key
        for (self.entries.items) |*entry| {
            if (entry.key.eql(key)) {
                entry.value = value;
                return;
            }
        }
        try self.entries.append(.{ .key = key, .value = value });
    }
    
    pub fn get(self: *const MapValue, key: Value) ?Value {
        for (self.entries.items) |entry| {
            if (entry.key.eql(key)) return entry.value;
        }
        return null;
    }
};

// ============================================================================
// Node Value (Graph node)
// ============================================================================

pub const NodeValue = struct {
    id: InternalID,
    label: []const u8,
    properties: StructValue,
    
    pub fn init(allocator: std.mem.Allocator, id: InternalID, label: []const u8) NodeValue {
        return .{
            .id = id,
            .label = label,
            .properties = StructValue.init(allocator),
        };
    }
    
    pub fn deinit(self: *NodeValue) void {
        self.properties.deinit();
    }
    
    pub fn setProperty(self: *NodeValue, name: []const u8, value: Value) !void {
        try self.properties.set(name, value);
    }
    
    pub fn getProperty(self: *const NodeValue, name: []const u8) ?Value {
        return self.properties.get(name);
    }
};

// ============================================================================
// Relationship Value
// ============================================================================

pub const RelValue = struct {
    id: InternalID,
    src_id: InternalID,
    dst_id: InternalID,
    label: []const u8,
    properties: StructValue,
    
    pub fn init(allocator: std.mem.Allocator, id: InternalID, src: InternalID, dst: InternalID, label: []const u8) RelValue {
        return .{
            .id = id,
            .src_id = src,
            .dst_id = dst,
            .label = label,
            .properties = StructValue.init(allocator),
        };
    }
    
    pub fn deinit(self: *RelValue) void {
        self.properties.deinit();
    }
};

// ============================================================================
// Path Value (Sequence of nodes and relationships)
// ============================================================================

pub const PathValue = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(InternalID),
    rels: std.ArrayList(InternalID),
    
    pub fn init(allocator: std.mem.Allocator) PathValue {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(InternalID).init(allocator),
            .rels = std.ArrayList(InternalID).init(allocator),
        };
    }
    
    pub fn deinit(self: *PathValue) void {
        self.nodes.deinit();
        self.rels.deinit();
    }
    
    pub fn addNode(self: *PathValue, id: InternalID) !void {
        try self.nodes.append(id);
    }
    
    pub fn addRel(self: *PathValue, id: InternalID) !void {
        try self.rels.append(id);
    }
    
    pub fn length(self: *const PathValue) usize {
        return self.rels.items.len;
    }
};

// ============================================================================
// Value Builder
// ============================================================================

pub const ValueBuilder = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ValueBuilder {
        return .{ .allocator = allocator };
    }
    
    pub fn createList(self: *ValueBuilder) !*ListValue {
        const list = try self.allocator.create(ListValue);
        list.* = ListValue.init(self.allocator);
        return list;
    }
    
    pub fn createStruct(self: *ValueBuilder) !*StructValue {
        const s = try self.allocator.create(StructValue);
        s.* = StructValue.init(self.allocator);
        return s;
    }
    
    pub fn createNode(self: *ValueBuilder, id: InternalID, label: []const u8) !*NodeValue {
        const node = try self.allocator.create(NodeValue);
        node.* = NodeValue.init(self.allocator, id, label);
        return node;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "internal id" {
    const id1 = InternalID.init(1, 100);
    const id2 = InternalID.init(1, 100);
    const id3 = InternalID.init(2, 100);
    
    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
}

test "value primitives" {
    const null_val = Value.null_();
    try std.testing.expect(null_val.isNull());
    
    const bool_val = Value.boolean(true);
    try std.testing.expectEqual(@as(?bool, true), bool_val.getBool());
    
    const int_val = Value.int64(42);
    try std.testing.expectEqual(@as(?i64, 42), int_val.getInt64());
    
    const str_val = Value.string("hello");
    try std.testing.expectEqualStrings("hello", str_val.getString().?);
}

test "value comparison" {
    const v1 = Value.int64(10);
    const v2 = Value.int64(10);
    const v3 = Value.int64(20);
    
    try std.testing.expect(v1.eql(v2));
    try std.testing.expect(!v1.eql(v3));
    try std.testing.expect(v1.lessThan(v3));
}

test "list value" {
    const allocator = std.testing.allocator;
    
    var list = ListValue.init(allocator);
    defer list.deinit();
    
    try list.append(Value.int64(1));
    try list.append(Value.int64(2));
    try list.append(Value.int64(3));
    
    try std.testing.expectEqual(@as(usize, 3), list.len());
    try std.testing.expectEqual(@as(?i64, 2), list.get(1).?.getInt64());
}

test "struct value" {
    const allocator = std.testing.allocator;
    
    var s = StructValue.init(allocator);
    defer s.deinit();
    
    try s.set("name", Value.string("Alice"));
    try s.set("age", Value.int64(30));
    
    try std.testing.expectEqualStrings("Alice", s.get("name").?.getString().?);
    try std.testing.expectEqual(@as(?i64, 30), s.get("age").?.getInt64());
}

test "date" {
    const date = Date.fromYMD(2024, 3, 15);
    try std.testing.expect(date.days > 0);
}

test "node value" {
    const allocator = std.testing.allocator;
    
    var node = NodeValue.init(allocator, InternalID.init(0, 1), "Person");
    defer node.deinit();
    
    try node.setProperty("name", Value.string("Bob"));
    
    try std.testing.expectEqualStrings("Person", node.label);
    try std.testing.expectEqualStrings("Bob", node.getProperty("name").?.getString().?);
}