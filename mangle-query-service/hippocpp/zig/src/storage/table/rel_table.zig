//! Relationship Table - Graph edge storage
//!
//! Purpose:
//! Stores relationships (edges) between nodes with properties.
//! Uses CSR-like format for efficient neighbor traversal.

const std = @import("std");

// ============================================================================
// Relationship Direction
// ============================================================================

pub const RelDirection = enum {
    FWD,      // Source -> Destination
    BWD,      // Destination -> Source
    BOTH,     // Bidirectional
    
    pub fn opposite(self: RelDirection) RelDirection {
        return switch (self) {
            .FWD => .BWD,
            .BWD => .FWD,
            .BOTH => .BOTH,
        };
    }
};

pub const RelMultiplicity = enum {
    ONE_ONE,      // 1:1
    ONE_MANY,     // 1:N
    MANY_ONE,     // N:1
    MANY_MANY,    // N:M
};

// ============================================================================
// Relationship ID
// ============================================================================

pub const RelID = struct {
    src_id: u64,
    dst_id: u64,
    rel_offset: u64,
    
    pub fn init(src: u64, dst: u64, offset: u64) RelID {
        return .{ .src_id = src, .dst_id = dst, .rel_offset = offset };
    }
    
    pub fn hash(self: RelID) u64 {
        return self.src_id ^ (self.dst_id << 32) ^ self.rel_offset;
    }
    
    pub fn eql(self: RelID, other: RelID) bool {
        return self.src_id == other.src_id and 
               self.dst_id == other.dst_id and 
               self.rel_offset == other.rel_offset;
    }
};

// ============================================================================
// Relationship Entry (single edge)
// ============================================================================

pub const RelEntry = struct {
    src_node: u64,
    dst_node: u64,
    rel_id: u64,
    properties_offset: u64 = 0,
    
    pub fn init(src: u64, dst: u64, rel_id: u64) RelEntry {
        return .{
            .src_node = src,
            .dst_node = dst,
            .rel_id = rel_id,
        };
    }
};

// ============================================================================
// CSR (Compressed Sparse Row) Lists
// ============================================================================

pub const CSRList = struct {
    allocator: std.mem.Allocator,
    offsets: std.ArrayList(u64),      // Start offset for each source node
    neighbors: std.ArrayList(u64),    // Destination node IDs
    rel_ids: std.ArrayList(u64),      // Relationship IDs
    
    pub fn init(allocator: std.mem.Allocator) CSRList {
        var csr = CSRList{
            .allocator = allocator,
            .offsets = std.ArrayList(u64).init(allocator),
            .neighbors = std.ArrayList(u64).init(allocator),
            .rel_ids = std.ArrayList(u64).init(allocator),
        };
        csr.offsets.append(0) catch {};
        return csr;
    }
    
    pub fn deinit(self: *CSRList) void {
        self.offsets.deinit();
        self.neighbors.deinit();
        self.rel_ids.deinit();
    }
    
    pub fn numNodes(self: *const CSRList) usize {
        if (self.offsets.items.len == 0) return 0;
        return self.offsets.items.len - 1;
    }
    
    pub fn numEdges(self: *const CSRList) usize {
        return self.neighbors.items.len;
    }
    
    /// Get neighbors of a node
    pub fn getNeighbors(self: *const CSRList, node_id: usize) []const u64 {
        if (node_id >= self.numNodes()) return &[_]u64{};
        
        const start = self.offsets.items[node_id];
        const end = self.offsets.items[node_id + 1];
        
        return self.neighbors.items[@intCast(start)..@intCast(end)];
    }
    
    /// Get relationship IDs for a node's edges
    pub fn getRelIds(self: *const CSRList, node_id: usize) []const u64 {
        if (node_id >= self.numNodes()) return &[_]u64{};
        
        const start = self.offsets.items[node_id];
        const end = self.offsets.items[node_id + 1];
        
        return self.rel_ids.items[@intCast(start)..@intCast(end)];
    }
    
    /// Get degree (number of neighbors)
    pub fn degree(self: *const CSRList, node_id: usize) usize {
        if (node_id >= self.numNodes()) return 0;
        
        const start = self.offsets.items[node_id];
        const end = self.offsets.items[node_id + 1];
        
        return @intCast(end - start);
    }
};

// ============================================================================
// Relationship Table Schema
// ============================================================================

pub const RelTableSchema = struct {
    table_id: u64,
    name: []const u8,
    src_table_id: u64,
    dst_table_id: u64,
    direction: RelDirection,
    multiplicity: RelMultiplicity,
    properties: std.ArrayList(PropertyDef),
    
    pub const PropertyDef = struct {
        name: []const u8,
        data_type: DataType,
        nullable: bool,
        
        pub const DataType = enum {
            INT64,
            DOUBLE,
            STRING,
            BOOL,
            DATE,
            TIMESTAMP,
        };
    };
    
    pub fn init(allocator: std.mem.Allocator, table_id: u64, name: []const u8, src_id: u64, dst_id: u64) RelTableSchema {
        return .{
            .table_id = table_id,
            .name = name,
            .src_table_id = src_id,
            .dst_table_id = dst_id,
            .direction = .FWD,
            .multiplicity = .MANY_MANY,
            .properties = std.ArrayList(PropertyDef).init(allocator),
        };
    }
    
    pub fn deinit(self: *RelTableSchema) void {
        self.properties.deinit();
    }
    
    pub fn addProperty(self: *RelTableSchema, name: []const u8, data_type: PropertyDef.DataType, nullable: bool) !void {
        try self.properties.append(.{
            .name = name,
            .data_type = data_type,
            .nullable = nullable,
        });
    }
};

// ============================================================================
// Relationship Table
// ============================================================================

pub const RelTable = struct {
    allocator: std.mem.Allocator,
    schema: RelTableSchema,
    
    // CSR storage for forward edges (src -> dst)
    fwd_csr: CSRList,
    // CSR storage for backward edges (dst -> src)
    bwd_csr: CSRList,
    
    // Relationship data
    relationships: std.ArrayList(RelEntry),
    
    // Property storage (columnar)
    property_columns: std.ArrayList(PropertyColumn),
    
    // Statistics
    num_relationships: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, schema: RelTableSchema) RelTable {
        return .{
            .allocator = allocator,
            .schema = schema,
            .fwd_csr = CSRList.init(allocator),
            .bwd_csr = CSRList.init(allocator),
            .relationships = std.ArrayList(RelEntry).init(allocator),
            .property_columns = std.ArrayList(PropertyColumn).init(allocator),
        };
    }
    
    pub fn deinit(self: *RelTable) void {
        self.fwd_csr.deinit();
        self.bwd_csr.deinit();
        self.relationships.deinit();
        for (self.property_columns.items) |*col| {
            col.deinit();
        }
        self.property_columns.deinit();
        self.schema.deinit();
    }
    
    /// Insert a new relationship
    pub fn insertRelationship(self: *RelTable, src_node: u64, dst_node: u64) !u64 {
        const rel_id = self.num_relationships;
        
        try self.relationships.append(RelEntry.init(src_node, dst_node, rel_id));
        
        self.num_relationships += 1;
        
        return rel_id;
    }
    
    /// Get all outgoing neighbors (forward direction)
    pub fn getOutNeighbors(self: *const RelTable, src_node: usize) []const u64 {
        return self.fwd_csr.getNeighbors(src_node);
    }
    
    /// Get all incoming neighbors (backward direction)
    pub fn getInNeighbors(self: *const RelTable, dst_node: usize) []const u64 {
        return self.bwd_csr.getNeighbors(dst_node);
    }
    
    /// Get out-degree
    pub fn outDegree(self: *const RelTable, node: usize) usize {
        return self.fwd_csr.degree(node);
    }
    
    /// Get in-degree
    pub fn inDegree(self: *const RelTable, node: usize) usize {
        return self.bwd_csr.degree(node);
    }
    
    /// Build CSR from edge list
    pub fn buildCSR(self: *RelTable, num_src_nodes: usize, num_dst_nodes: usize) !void {
        // Sort edges by source for forward CSR
        std.mem.sort(RelEntry, self.relationships.items, {}, struct {
            fn lessThan(_: void, a: RelEntry, b: RelEntry) bool {
                return a.src_node < b.src_node;
            }
        }.lessThan);
        
        // Build forward CSR
        self.fwd_csr.offsets.clearRetainingCapacity();
        self.fwd_csr.neighbors.clearRetainingCapacity();
        self.fwd_csr.rel_ids.clearRetainingCapacity();
        
        try self.fwd_csr.offsets.ensureTotalCapacity(num_src_nodes + 1);
        
        var current_src: u64 = 0;
        try self.fwd_csr.offsets.append(0);
        
        for (self.relationships.items) |rel| {
            // Fill gaps for nodes with no outgoing edges
            while (current_src < rel.src_node) {
                try self.fwd_csr.offsets.append(@intCast(self.fwd_csr.neighbors.items.len));
                current_src += 1;
            }
            
            try self.fwd_csr.neighbors.append(rel.dst_node);
            try self.fwd_csr.rel_ids.append(rel.rel_id);
        }
        
        // Fill remaining nodes
        while (current_src < num_src_nodes) {
            try self.fwd_csr.offsets.append(@intCast(self.fwd_csr.neighbors.items.len));
            current_src += 1;
        }
        
        // Build backward CSR (similar process, sorted by dst)
        var bwd_edges = try self.allocator.alloc(RelEntry, self.relationships.items.len);
        defer self.allocator.free(bwd_edges);
        
        @memcpy(bwd_edges, self.relationships.items);
        
        std.mem.sort(RelEntry, bwd_edges, {}, struct {
            fn lessThan(_: void, a: RelEntry, b: RelEntry) bool {
                return a.dst_node < b.dst_node;
            }
        }.lessThan);
        
        self.bwd_csr.offsets.clearRetainingCapacity();
        self.bwd_csr.neighbors.clearRetainingCapacity();
        self.bwd_csr.rel_ids.clearRetainingCapacity();
        
        try self.bwd_csr.offsets.ensureTotalCapacity(num_dst_nodes + 1);
        
        var current_dst: u64 = 0;
        try self.bwd_csr.offsets.append(0);
        
        for (bwd_edges) |rel| {
            while (current_dst < rel.dst_node) {
                try self.bwd_csr.offsets.append(@intCast(self.bwd_csr.neighbors.items.len));
                current_dst += 1;
            }
            
            try self.bwd_csr.neighbors.append(rel.src_node);
            try self.bwd_csr.rel_ids.append(rel.rel_id);
        }
        
        while (current_dst < num_dst_nodes) {
            try self.bwd_csr.offsets.append(@intCast(self.bwd_csr.neighbors.items.len));
            current_dst += 1;
        }
    }
    
    /// Scan relationships with filter
    pub fn scan(self: *const RelTable, src_filter: ?u64, dst_filter: ?u64) RelIterator {
        return RelIterator.init(self, src_filter, dst_filter);
    }
};

// ============================================================================
// Property Column for Relationships
// ============================================================================

pub const PropertyColumn = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    data: std.ArrayList(u8),
    null_mask: std.ArrayList(u64),
    elem_size: usize,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, elem_size: usize) PropertyColumn {
        return .{
            .allocator = allocator,
            .name = name,
            .data = std.ArrayList(u8).init(allocator),
            .null_mask = std.ArrayList(u64).init(allocator),
            .elem_size = elem_size,
        };
    }
    
    pub fn deinit(self: *PropertyColumn) void {
        self.data.deinit();
        self.null_mask.deinit();
    }
};

// ============================================================================
// Relationship Iterator
// ============================================================================

pub const RelIterator = struct {
    table: *const RelTable,
    current_idx: usize = 0,
    src_filter: ?u64,
    dst_filter: ?u64,
    
    pub fn init(table: *const RelTable, src_filter: ?u64, dst_filter: ?u64) RelIterator {
        return .{
            .table = table,
            .src_filter = src_filter,
            .dst_filter = dst_filter,
        };
    }
    
    pub fn next(self: *RelIterator) ?RelEntry {
        while (self.current_idx < self.table.relationships.items.len) {
            const rel = self.table.relationships.items[self.current_idx];
            self.current_idx += 1;
            
            // Apply filters
            if (self.src_filter) |src| {
                if (rel.src_node != src) continue;
            }
            if (self.dst_filter) |dst| {
                if (rel.dst_node != dst) continue;
            }
            
            return rel;
        }
        return null;
    }
    
    pub fn reset(self: *RelIterator) void {
        self.current_idx = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "rel table basic" {
    const allocator = std.testing.allocator;
    
    var schema = RelTableSchema.init(allocator, 0, "KNOWS", 0, 0);
    
    var table = RelTable.init(allocator, schema);
    defer table.deinit();
    
    // Insert some relationships
    _ = try table.insertRelationship(0, 1);
    _ = try table.insertRelationship(0, 2);
    _ = try table.insertRelationship(1, 2);
    
    try std.testing.expectEqual(@as(u64, 3), table.num_relationships);
}

test "rel table csr" {
    const allocator = std.testing.allocator;
    
    var schema = RelTableSchema.init(allocator, 0, "FOLLOWS", 0, 0);
    
    var table = RelTable.init(allocator, schema);
    defer table.deinit();
    
    // Create graph: 0 -> 1, 0 -> 2, 1 -> 2
    _ = try table.insertRelationship(0, 1);
    _ = try table.insertRelationship(0, 2);
    _ = try table.insertRelationship(1, 2);
    
    try table.buildCSR(3, 3);
    
    // Check forward neighbors
    const neighbors_0 = table.getOutNeighbors(0);
    try std.testing.expectEqual(@as(usize, 2), neighbors_0.len);
    
    const neighbors_1 = table.getOutNeighbors(1);
    try std.testing.expectEqual(@as(usize, 1), neighbors_1.len);
    
    // Check degrees
    try std.testing.expectEqual(@as(usize, 2), table.outDegree(0));
    try std.testing.expectEqual(@as(usize, 1), table.outDegree(1));
    try std.testing.expectEqual(@as(usize, 0), table.outDegree(2));
}

test "rel table iterator" {
    const allocator = std.testing.allocator;
    
    var schema = RelTableSchema.init(allocator, 0, "EDGE", 0, 0);
    
    var table = RelTable.init(allocator, schema);
    defer table.deinit();
    
    _ = try table.insertRelationship(0, 1);
    _ = try table.insertRelationship(0, 2);
    _ = try table.insertRelationship(1, 2);
    
    // Scan all
    var iter = table.scan(null, null);
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    
    // Scan filtered by source
    var iter2 = table.scan(0, null);
    count = 0;
    while (iter2.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "csr list" {
    const allocator = std.testing.allocator;
    
    var csr = CSRList.init(allocator);
    defer csr.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), csr.numNodes());
    try std.testing.expectEqual(@as(usize, 0), csr.numEdges());
}

test "rel direction" {
    try std.testing.expectEqual(RelDirection.BWD, RelDirection.FWD.opposite());
    try std.testing.expectEqual(RelDirection.FWD, RelDirection.BWD.opposite());
    try std.testing.expectEqual(RelDirection.BOTH, RelDirection.BOTH.opposite());
}