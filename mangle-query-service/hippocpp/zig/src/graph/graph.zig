//! Graph - Graph Data Model and Operations
//!
//! Converted from: kuzu/src/graph/*.cpp
//!
//! Purpose:
//! Provides graph abstraction over node/relationship tables.
//! Supports Cypher-style graph queries and traversals.

const std = @import("std");
const common = @import("../common/common.zig");
const catalog = @import("../catalog/catalog.zig");

const LogicalType = common.LogicalType;
const Catalog = catalog.Catalog;

/// Internal node/edge ID
pub const InternalID = struct {
    offset: u64,
    table_id: u64,
    
    pub fn init(table_id: u64, offset: u64) InternalID {
        return .{ .table_id = table_id, .offset = offset };
    }
    
    pub fn isValid(self: *const InternalID) bool {
        return self.offset != std.math.maxInt(u64);
    }
    
    pub fn invalid() InternalID {
        return .{ .table_id = 0, .offset = std.math.maxInt(u64) };
    }
};

/// Node label
pub const NodeLabel = struct {
    name: []const u8,
    table_id: u64,
    properties: std.ArrayList(PropertyDef),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, table_id: u64) Self {
        return .{
            .name = name,
            .table_id = table_id,
            .properties = std.ArrayList(PropertyDef).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.properties.deinit();
    }
    
    pub fn addProperty(self: *Self, prop: PropertyDef) !void {
        try self.properties.append(prop);
    }
};

/// Relationship type
pub const RelType = struct {
    name: []const u8,
    table_id: u64,
    src_label: []const u8,
    dst_label: []const u8,
    properties: std.ArrayList(PropertyDef),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, table_id: u64, src: []const u8, dst: []const u8) Self {
        return .{
            .name = name,
            .table_id = table_id,
            .src_label = src,
            .dst_label = dst,
            .properties = std.ArrayList(PropertyDef).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.properties.deinit();
    }
};

/// Property definition
pub const PropertyDef = struct {
    name: []const u8,
    data_type: LogicalType,
    is_primary_key: bool,
    
    pub fn init(name: []const u8, data_type: LogicalType) PropertyDef {
        return .{
            .name = name,
            .data_type = data_type,
            .is_primary_key = false,
        };
    }
    
    pub fn primary(name: []const u8, data_type: LogicalType) PropertyDef {
        return .{
            .name = name,
            .data_type = data_type,
            .is_primary_key = true,
        };
    }
};

/// Graph entry - represents a node or edge in result
pub const GraphEntry = struct {
    id: InternalID,
    entry_type: GraphEntryType,
    label: []const u8,
    properties: std.StringHashMap(PropertyValue),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub const GraphEntryType = enum {
        NODE,
        EDGE,
    };
    
    pub fn initNode(allocator: std.mem.Allocator, id: InternalID, label: []const u8) Self {
        return .{
            .id = id,
            .entry_type = .NODE,
            .label = label,
            .properties = std.StringHashMap(PropertyValue).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn initEdge(allocator: std.mem.Allocator, id: InternalID, label: []const u8) Self {
        return .{
            .id = id,
            .entry_type = .EDGE,
            .label = label,
            .properties = std.StringHashMap(PropertyValue).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.properties.deinit();
    }
    
    pub fn setProperty(self: *Self, name: []const u8, value: PropertyValue) !void {
        try self.properties.put(name, value);
    }
    
    pub fn getProperty(self: *const Self, name: []const u8) ?PropertyValue {
        return self.properties.get(name);
    }
};

/// Property value union
pub const PropertyValue = union(enum) {
    null_val: void,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string_val: []const u8,
    
    pub fn nullValue() PropertyValue {
        return .{ .null_val = {} };
    }
    
    pub fn boolean(val: bool) PropertyValue {
        return .{ .bool_val = val };
    }
    
    pub fn integer(val: i64) PropertyValue {
        return .{ .int_val = val };
    }
    
    pub fn float(val: f64) PropertyValue {
        return .{ .float_val = val };
    }
    
    pub fn string(val: []const u8) PropertyValue {
        return .{ .string_val = val };
    }
};

/// Graph schema
pub const GraphSchema = struct {
    allocator: std.mem.Allocator,
    node_labels: std.StringHashMap(NodeLabel),
    rel_types: std.StringHashMap(RelType),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .node_labels = std.StringHashMap(NodeLabel).init(allocator),
            .rel_types = std.StringHashMap(RelType).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        var label_iter = self.node_labels.valueIterator();
        while (label_iter.next()) |label| {
            @constCast(label).deinit();
        }
        self.node_labels.deinit();
        
        var rel_iter = self.rel_types.valueIterator();
        while (rel_iter.next()) |rel| {
            @constCast(rel).deinit();
        }
        self.rel_types.deinit();
    }
    
    pub fn addNodeLabel(self: *Self, label: NodeLabel) !void {
        try self.node_labels.put(label.name, label);
    }
    
    pub fn addRelType(self: *Self, rel: RelType) !void {
        try self.rel_types.put(rel.name, rel);
    }
    
    pub fn getNodeLabel(self: *const Self, name: []const u8) ?NodeLabel {
        return self.node_labels.get(name);
    }
    
    pub fn getRelType(self: *const Self, name: []const u8) ?RelType {
        return self.rel_types.get(name);
    }
};

/// Graph - main graph interface
pub const Graph = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    schema: GraphSchema,
    next_node_id: u64,
    next_edge_id: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
        return .{
            .allocator = allocator,
            .name = name,
            .schema = GraphSchema.init(allocator),
            .next_node_id = 0,
            .next_edge_id = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.schema.deinit();
    }
    
    /// Create a node label
    pub fn createNodeLabel(self: *Self, name: []const u8) !void {
        const table_id = self.next_node_id;
        self.next_node_id += 1;
        
        var label = NodeLabel.init(self.allocator, name, table_id);
        try self.schema.addNodeLabel(label);
    }
    
    /// Create a relationship type
    pub fn createRelType(self: *Self, name: []const u8, src: []const u8, dst: []const u8) !void {
        const table_id = self.next_edge_id;
        self.next_edge_id += 1;
        
        var rel = RelType.init(self.allocator, name, table_id, src, dst);
        try self.schema.addRelType(rel);
    }
    
    /// Get all node labels
    pub fn getNodeLabels(self: *const Self) []const []const u8 {
        _ = self;
        return &[_][]const u8{};
    }
    
    /// Check if label exists
    pub fn hasNodeLabel(self: *const Self, name: []const u8) bool {
        return self.schema.getNodeLabel(name) != null;
    }
    
    /// Check if rel type exists
    pub fn hasRelType(self: *const Self, name: []const u8) bool {
        return self.schema.getRelType(name) != null;
    }
};

/// Path in graph
pub const Path = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(GraphEntry),
    edges: std.ArrayList(GraphEntry),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(GraphEntry).init(allocator),
            .edges = std.ArrayList(GraphEntry).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.nodes.items) |*n| n.deinit();
        for (self.edges.items) |*e| e.deinit();
        self.nodes.deinit();
        self.edges.deinit();
    }
    
    pub fn addNode(self: *Self, node: GraphEntry) !void {
        try self.nodes.append(node);
    }
    
    pub fn addEdge(self: *Self, edge: GraphEntry) !void {
        try self.edges.append(edge);
    }
    
    pub fn length(self: *const Self) usize {
        return self.edges.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "internal id" {
    const id = InternalID.init(1, 100);
    try std.testing.expectEqual(@as(u64, 1), id.table_id);
    try std.testing.expectEqual(@as(u64, 100), id.offset);
    try std.testing.expect(id.isValid());
    
    const invalid_id = InternalID.invalid();
    try std.testing.expect(!invalid_id.isValid());
}

test "property value" {
    const int_val = PropertyValue.integer(42);
    try std.testing.expectEqual(@as(i64, 42), int_val.int_val);
    
    const str_val = PropertyValue.string("hello");
    try std.testing.expect(std.mem.eql(u8, "hello", str_val.string_val));
}

test "graph entry" {
    const allocator = std.testing.allocator;
    
    const id = InternalID.init(1, 0);
    var entry = GraphEntry.initNode(allocator, id, "Person");
    defer entry.deinit();
    
    try entry.setProperty("name", PropertyValue.string("Alice"));
    const name = entry.getProperty("name");
    try std.testing.expect(name != null);
}

test "graph schema" {
    const allocator = std.testing.allocator;
    
    var schema = GraphSchema.init(allocator);
    defer schema.deinit();
    
    var label = NodeLabel.init(allocator, "Person", 1);
    try label.addProperty(PropertyDef.primary("id", .INT64));
    try schema.addNodeLabel(label);
    
    try std.testing.expect(schema.getNodeLabel("Person") != null);
}

test "graph" {
    const allocator = std.testing.allocator;
    
    var graph = Graph.init(allocator, "test_graph");
    defer graph.deinit();
    
    try graph.createNodeLabel("Person");
    try graph.createNodeLabel("Company");
    try graph.createRelType("WORKS_FOR", "Person", "Company");
    
    try std.testing.expect(graph.hasNodeLabel("Person"));
    try std.testing.expect(graph.hasRelType("WORKS_FOR"));
}

test "path" {
    const allocator = std.testing.allocator;
    
    var path = Path.init(allocator);
    defer path.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), path.length());
}