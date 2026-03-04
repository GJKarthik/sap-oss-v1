//! Pattern Matcher - Cypher Pattern Matching
//!
//! Converted from: kuzu/src/binder/pattern/*.cpp
//!
//! Purpose:
//! Matches Cypher patterns against graph data.
//! Supports node patterns, edge patterns, and paths.

const std = @import("std");
const graph_mod = @import("graph.zig");

const InternalID = graph_mod.InternalID;
const GraphEntry = graph_mod.GraphEntry;
const Path = graph_mod.Path;
const PropertyValue = graph_mod.PropertyValue;

/// Pattern element type
pub const PatternElementType = enum {
    NODE,
    EDGE,
    PATH,
};

/// Direction for edge patterns
pub const Direction = enum {
    FORWARD,   // ->
    BACKWARD,  // <-
    BOTH,      // --
};

/// Node pattern
pub const NodePattern = struct {
    variable: ?[]const u8,
    labels: std.ArrayList([]const u8),
    properties: std.StringHashMap(PropertyValue),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .variable = null,
            .labels = std.ArrayList([]const u8).init(allocator),
            .properties = std.StringHashMap(PropertyValue).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.labels.deinit();
        self.properties.deinit();
    }
    
    pub fn setVariable(self: *Self, name: []const u8) void {
        self.variable = name;
    }
    
    pub fn addLabel(self: *Self, label: []const u8) !void {
        try self.labels.append(label);
    }
    
    pub fn addProperty(self: *Self, name: []const u8, value: PropertyValue) !void {
        try self.properties.put(name, value);
    }
    
    /// Check if a graph entry matches this pattern
    pub fn matches(self: *const Self, entry: *const GraphEntry) bool {
        // Check labels
        for (self.labels.items) |label| {
            if (!std.mem.eql(u8, entry.label, label)) {
                return false;
            }
        }
        
        // Check properties
        var iter = self.properties.iterator();
        while (iter.next()) |kv| {
            const entry_val = entry.properties.get(kv.key_ptr.*);
            if (entry_val == null) return false;
            // Simplified property comparison
        }
        
        return true;
    }
};

/// Edge pattern
pub const EdgePattern = struct {
    variable: ?[]const u8,
    types: std.ArrayList([]const u8),
    direction: Direction,
    min_length: u32,
    max_length: u32,
    properties: std.StringHashMap(PropertyValue),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, direction: Direction) Self {
        return .{
            .variable = null,
            .types = std.ArrayList([]const u8).init(allocator),
            .direction = direction,
            .min_length = 1,
            .max_length = 1,
            .properties = std.StringHashMap(PropertyValue).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.types.deinit();
        self.properties.deinit();
    }
    
    pub fn setVariable(self: *Self, name: []const u8) void {
        self.variable = name;
    }
    
    pub fn addType(self: *Self, rel_type: []const u8) !void {
        try self.types.append(rel_type);
    }
    
    pub fn setLengthRange(self: *Self, min: u32, max: u32) void {
        self.min_length = min;
        self.max_length = max;
    }
    
    pub fn isVariableLength(self: *const Self) bool {
        return self.min_length != self.max_length or self.max_length != 1;
    }
};

/// Pattern element - either node or edge
pub const PatternElement = union(PatternElementType) {
    NODE: NodePattern,
    EDGE: EdgePattern,
    PATH: PathPattern,
};

/// Path pattern - sequence of node/edge patterns
pub const PathPattern = struct {
    variable: ?[]const u8,
    elements: std.ArrayList(PatternElement),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .variable = null,
            .elements = std.ArrayList(PatternElement).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.elements.items) |*elem| {
            switch (elem.*) {
                .NODE => |*n| n.deinit(),
                .EDGE => |*e| e.deinit(),
                .PATH => |*p| p.deinit(),
            }
        }
        self.elements.deinit();
    }
    
    pub fn addNode(self: *Self, node: NodePattern) !void {
        try self.elements.append(.{ .NODE = node });
    }
    
    pub fn addEdge(self: *Self, edge: EdgePattern) !void {
        try self.elements.append(.{ .EDGE = edge });
    }
    
    pub fn getLength(self: *const Self) usize {
        var count: usize = 0;
        for (self.elements.items) |elem| {
            if (elem == .EDGE) count += 1;
        }
        return count;
    }
};

/// Pattern matcher
pub const PatternMatcher = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(GraphEntry),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(GraphEntry).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        var iter = self.bindings.valueIterator();
        while (iter.next()) |entry| {
            @constCast(entry).deinit();
        }
        self.bindings.deinit();
    }
    
    pub fn clearBindings(self: *Self) void {
        var iter = self.bindings.valueIterator();
        while (iter.next()) |entry| {
            @constCast(entry).deinit();
        }
        self.bindings.clearRetainingCapacity();
    }
    
    pub fn bind(self: *Self, variable: []const u8, entry: GraphEntry) !void {
        try self.bindings.put(variable, entry);
    }
    
    pub fn getBinding(self: *const Self, variable: []const u8) ?GraphEntry {
        return self.bindings.get(variable);
    }
    
    /// Match a node pattern against an entry
    pub fn matchNode(self: *Self, pattern: *const NodePattern, entry: *const GraphEntry) bool {
        _ = self;
        return pattern.matches(entry);
    }
    
    /// Match a path pattern
    pub fn matchPath(self: *Self, pattern: *const PathPattern, path: *const Path) bool {
        _ = self;
        
        // Check length
        if (path.length() != pattern.getLength()) {
            return false;
        }
        
        // Would iterate through pattern and path elements
        return true;
    }
};

/// Pattern parser - parses Cypher patterns
pub const PatternParser = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Parse a simple node pattern: (n:Label {prop: value})
    pub fn parseNodePattern(self: *Self, input: []const u8) !NodePattern {
        var node = NodePattern.init(self.allocator);
        errdefer node.deinit();
        
        // Very simplified parsing
        if (input.len > 0 and input[0] == '(' and input[input.len - 1] == ')') {
            const inner = input[1 .. input.len - 1];
            
            // Find label (after :)
            if (std.mem.indexOf(u8, inner, ":")) |colon_pos| {
                if (colon_pos > 0) {
                    node.setVariable(inner[0..colon_pos]);
                }
                
                // Find end of label (space or {)
                var label_end = inner.len;
                if (std.mem.indexOf(u8, inner[colon_pos + 1 ..], " ")) |sp| {
                    label_end = colon_pos + 1 + sp;
                }
                if (std.mem.indexOf(u8, inner[colon_pos + 1 ..], "{")) |br| {
                    label_end = @min(label_end, colon_pos + 1 + br);
                }
                
                if (label_end > colon_pos + 1) {
                    try node.addLabel(inner[colon_pos + 1 .. label_end]);
                }
            } else if (inner.len > 0) {
                node.setVariable(inner);
            }
        }
        
        return node;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "node pattern" {
    const allocator = std.testing.allocator;
    
    var pattern = NodePattern.init(allocator);
    defer pattern.deinit();
    
    pattern.setVariable("n");
    try pattern.addLabel("Person");
    
    try std.testing.expect(pattern.variable != null);
    try std.testing.expectEqual(@as(usize, 1), pattern.labels.items.len);
}

test "edge pattern" {
    const allocator = std.testing.allocator;
    
    var pattern = EdgePattern.init(allocator, .FORWARD);
    defer pattern.deinit();
    
    try pattern.addType("KNOWS");
    pattern.setLengthRange(1, 3);
    
    try std.testing.expect(pattern.isVariableLength());
}

test "path pattern" {
    const allocator = std.testing.allocator;
    
    var path_pattern = PathPattern.init(allocator);
    defer path_pattern.deinit();
    
    var node1 = NodePattern.init(allocator);
    try node1.addLabel("Person");
    try path_pattern.addNode(node1);
    
    try std.testing.expectEqual(@as(usize, 1), path_pattern.elements.items.len);
}

test "pattern matcher" {
    const allocator = std.testing.allocator;
    
    var matcher = PatternMatcher.init(allocator);
    defer matcher.deinit();
}

test "pattern parser" {
    const allocator = std.testing.allocator;
    
    var parser = PatternParser.init(allocator);
    
    var node = try parser.parseNodePattern("(n:Person)");
    defer node.deinit();
    
    try std.testing.expect(node.variable != null);
    try std.testing.expectEqual(@as(usize, 1), node.labels.items.len);
}