//! Prepared Statement - Parameterized query support
//!
//! Purpose:
//! Provides prepared statement functionality with parameter
//! binding, type checking, and efficient re-execution.

const std = @import("std");

// ============================================================================
// Parameter Types
// ============================================================================

pub const ParameterType = enum(u8) {
    BOOL,
    INT64,
    DOUBLE,
    STRING,
    BLOB,
    DATE,
    TIMESTAMP,
    INTERVAL,
    LIST,
    NULL,
    UNKNOWN,
};

// ============================================================================
// Parameter Value
// ============================================================================

pub const ParameterValue = union(enum) {
    null_val: void,
    bool_val: bool,
    int_val: i64,
    double_val: f64,
    string_val: []const u8,
    blob_val: []const u8,
    
    pub fn getType(self: ParameterValue) ParameterType {
        return switch (self) {
            .null_val => .NULL,
            .bool_val => .BOOL,
            .int_val => .INT64,
            .double_val => .DOUBLE,
            .string_val => .STRING,
            .blob_val => .BLOB,
        };
    }
    
    pub fn isNull(self: ParameterValue) bool {
        return self == .null_val;
    }
};

// ============================================================================
// Parameter Metadata
// ============================================================================

pub const ParameterMetadata = struct {
    index: u32,
    name: ?[]const u8 = null,
    expected_type: ParameterType = .UNKNOWN,
    nullable: bool = true,
    bound: bool = false,
};

// ============================================================================
// Statement State
// ============================================================================

pub const StatementState = enum {
    UNPREPARED,
    PREPARING,
    PREPARED,
    EXECUTING,
    EXECUTED,
    ERROR,
    CLOSED,
};

// ============================================================================
// Prepared Statement
// ============================================================================

pub const PreparedStatement = struct {
    allocator: std.mem.Allocator,
    statement_id: u64,
    
    // Query
    query_text: []const u8,
    state: StatementState = .UNPREPARED,
    
    // Parameters
    parameters: std.ArrayList(ParameterMetadata),
    bound_values: std.AutoHashMap(u32, ParameterValue),
    
    // Named parameter mapping
    named_params: std.StringHashMap(u32),
    
    // Result column info (after preparation)
    result_columns: std.ArrayList(ResultColumnInfo),
    
    // Statistics
    execution_count: u64 = 0,
    total_execution_time_ms: u64 = 0,
    
    // Error
    error_message: ?[]const u8 = null,
    
    pub fn init(allocator: std.mem.Allocator, id: u64, query: []const u8) PreparedStatement {
        return .{
            .allocator = allocator,
            .statement_id = id,
            .query_text = query,
            .parameters = std.ArrayList(ParameterMetadata).init(allocator),
            .bound_values = std.AutoHashMap(u32, ParameterValue).init(allocator),
            .named_params = std.StringHashMap(u32).init(allocator),
            .result_columns = std.ArrayList(ResultColumnInfo).init(allocator),
        };
    }
    
    pub fn deinit(self: *PreparedStatement) void {
        self.parameters.deinit();
        self.bound_values.deinit();
        self.named_params.deinit();
        self.result_columns.deinit();
    }
    
    /// Prepare the statement
    pub fn prepare(self: *PreparedStatement) !void {
        if (self.state != .UNPREPARED) {
            return error.AlreadyPrepared;
        }
        
        self.state = .PREPARING;
        
        // Parse query to find parameters
        try self.parseParameters();
        
        self.state = .PREPARED;
    }
    
    /// Parse parameters from query text
    fn parseParameters(self: *PreparedStatement) !void {
        var param_index: u32 = 0;
        var i: usize = 0;
        
        while (i < self.query_text.len) {
            const c = self.query_text[i];
            
            if (c == '$') {
                // Positional parameter $1, $2, etc.
                const start = i + 1;
                i += 1;
                while (i < self.query_text.len and std.ascii.isDigit(self.query_text[i])) {
                    i += 1;
                }
                if (i > start) {
                    const num_str = self.query_text[start..i];
                    const param_num = std.fmt.parseInt(u32, num_str, 10) catch 0;
                    if (param_num > 0) {
                        try self.addParameter(param_num - 1, null);
                    }
                }
                continue;
            }
            
            if (c == '?') {
                // Unnamed positional parameter
                try self.addParameter(param_index, null);
                param_index += 1;
                i += 1;
                continue;
            }
            
            if (c == ':') {
                // Named parameter :name
                const start = i + 1;
                i += 1;
                while (i < self.query_text.len and (std.ascii.isAlphanumeric(self.query_text[i]) or self.query_text[i] == '_')) {
                    i += 1;
                }
                if (i > start) {
                    const name = self.query_text[start..i];
                    try self.addParameter(param_index, name);
                    try self.named_params.put(name, param_index);
                    param_index += 1;
                }
                continue;
            }
            
            i += 1;
        }
    }
    
    /// Add a parameter
    fn addParameter(self: *PreparedStatement, index: u32, name: ?[]const u8) !void {
        // Ensure we have enough space
        while (self.parameters.items.len <= index) {
            try self.parameters.append(ParameterMetadata{
                .index = @intCast(self.parameters.items.len),
            });
        }
        
        if (name != null) {
            self.parameters.items[index].name = name;
        }
    }
    
    /// Bind a value by index (0-based)
    pub fn bindByIndex(self: *PreparedStatement, index: u32, value: ParameterValue) !void {
        if (self.state != .PREPARED) {
            return error.NotPrepared;
        }
        
        if (index >= self.parameters.items.len) {
            return error.InvalidParameterIndex;
        }
        
        // Type check if expected type is known
        const meta = &self.parameters.items[index];
        if (meta.expected_type != .UNKNOWN and meta.expected_type != value.getType()) {
            if (value.getType() != .NULL or !meta.nullable) {
                return error.TypeMismatch;
            }
        }
        
        try self.bound_values.put(index, value);
        meta.bound = true;
    }
    
    /// Bind a value by name
    pub fn bindByName(self: *PreparedStatement, name: []const u8, value: ParameterValue) !void {
        if (self.named_params.get(name)) |index| {
            try self.bindByIndex(index, value);
        } else {
            return error.UnknownParameter;
        }
    }
    
    /// Bind multiple values
    pub fn bindAll(self: *PreparedStatement, values: []const ParameterValue) !void {
        for (values, 0..) |v, i| {
            try self.bindByIndex(@intCast(i), v);
        }
    }
    
    /// Clear all bound values
    pub fn clearBindings(self: *PreparedStatement) void {
        self.bound_values.clearRetainingCapacity();
        for (self.parameters.items) |*p| {
            p.bound = false;
        }
    }
    
    /// Check if all parameters are bound
    pub fn allBound(self: *const PreparedStatement) bool {
        for (self.parameters.items) |p| {
            if (!p.bound) return false;
        }
        return true;
    }
    
    /// Get number of parameters
    pub fn numParameters(self: *const PreparedStatement) usize {
        return self.parameters.items.len;
    }
    
    /// Get bound value
    pub fn getBoundValue(self: *const PreparedStatement, index: u32) ?ParameterValue {
        return self.bound_values.get(index);
    }
    
    /// Get parameter metadata
    pub fn getParameterMetadata(self: *const PreparedStatement, index: u32) ?ParameterMetadata {
        if (index >= self.parameters.items.len) return null;
        return self.parameters.items[index];
    }
    
    /// Check if statement is prepared
    pub fn isPrepared(self: *const PreparedStatement) bool {
        return self.state == .PREPARED or self.state == .EXECUTED;
    }
    
    /// Reset for re-execution
    pub fn reset(self: *PreparedStatement) void {
        if (self.state == .EXECUTED or self.state == .ERROR) {
            self.state = .PREPARED;
        }
    }
    
    /// Close the statement
    pub fn close(self: *PreparedStatement) void {
        self.clearBindings();
        self.state = .CLOSED;
    }
    
    /// Set error
    pub fn setError(self: *PreparedStatement, message: []const u8) void {
        self.state = .ERROR;
        self.error_message = message;
    }
};

pub const ResultColumnInfo = struct {
    name: []const u8,
    type_id: u8,
};

// ============================================================================
// Prepared Statement Cache
// ============================================================================

pub const PreparedStatementCache = struct {
    allocator: std.mem.Allocator,
    statements: std.StringHashMap(*PreparedStatement),
    next_id: u64 = 1,
    max_size: usize = 100,
    
    pub fn init(allocator: std.mem.Allocator) PreparedStatementCache {
        return .{
            .allocator = allocator,
            .statements = std.StringHashMap(*PreparedStatement).init(allocator),
        };
    }
    
    pub fn deinit(self: *PreparedStatementCache) void {
        var iter = self.statements.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.statements.deinit();
    }
    
    /// Get or create a prepared statement
    pub fn getOrCreate(self: *PreparedStatementCache, query: []const u8) !*PreparedStatement {
        if (self.statements.get(query)) |stmt| {
            return stmt;
        }
        
        // Create new statement
        const stmt = try self.allocator.create(PreparedStatement);
        stmt.* = PreparedStatement.init(self.allocator, self.next_id, query);
        self.next_id += 1;
        
        try stmt.prepare();
        try self.statements.put(query, stmt);
        
        return stmt;
    }
    
    /// Remove a statement
    pub fn remove(self: *PreparedStatementCache, query: []const u8) void {
        if (self.statements.fetchRemove(query)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
    }
    
    /// Clear all statements
    pub fn clear(self: *PreparedStatementCache) void {
        var iter = self.statements.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.statements.clearRetainingCapacity();
    }
    
    /// Get cache size
    pub fn size(self: *const PreparedStatementCache) usize {
        return self.statements.count();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "prepared statement basic" {
    const allocator = std.testing.allocator;
    
    var stmt = PreparedStatement.init(allocator, 1, "SELECT * FROM users WHERE id = ?");
    defer stmt.deinit();
    
    try stmt.prepare();
    try std.testing.expect(stmt.isPrepared());
    try std.testing.expectEqual(@as(usize, 1), stmt.numParameters());
}

test "prepared statement bind" {
    const allocator = std.testing.allocator;
    
    var stmt = PreparedStatement.init(allocator, 1, "SELECT * FROM users WHERE id = ? AND name = ?");
    defer stmt.deinit();
    
    try stmt.prepare();
    
    try stmt.bindByIndex(0, ParameterValue{ .int_val = 42 });
    try stmt.bindByIndex(1, ParameterValue{ .string_val = "Alice" });
    
    try std.testing.expect(stmt.allBound());
    
    const val = stmt.getBoundValue(0);
    try std.testing.expect(val != null);
}

test "prepared statement named params" {
    const allocator = std.testing.allocator;
    
    var stmt = PreparedStatement.init(allocator, 1, "SELECT * FROM users WHERE name = :name");
    defer stmt.deinit();
    
    try stmt.prepare();
    try std.testing.expectEqual(@as(usize, 1), stmt.numParameters());
    
    try stmt.bindByName("name", ParameterValue{ .string_val = "Bob" });
    try std.testing.expect(stmt.allBound());
}

test "prepared statement cache" {
    const allocator = std.testing.allocator;
    
    var cache = PreparedStatementCache.init(allocator);
    defer cache.deinit();
    
    const stmt1 = try cache.getOrCreate("SELECT 1");
    try std.testing.expect(stmt1.isPrepared());
    
    const stmt2 = try cache.getOrCreate("SELECT 1");
    try std.testing.expectEqual(stmt1, stmt2);  // Same pointer
    
    try std.testing.expectEqual(@as(usize, 1), cache.size());
}

test "parameter value types" {
    const int_val = ParameterValue{ .int_val = 100 };
    try std.testing.expectEqual(ParameterType.INT64, int_val.getType());
    try std.testing.expect(!int_val.isNull());
    
    const null_val = ParameterValue{ .null_val = {} };
    try std.testing.expectEqual(ParameterType.NULL, null_val.getType());
    try std.testing.expect(null_val.isNull());
}

test "clear bindings" {
    const allocator = std.testing.allocator;
    
    var stmt = PreparedStatement.init(allocator, 1, "SELECT ? + ?");
    defer stmt.deinit();
    
    try stmt.prepare();
    try stmt.bindByIndex(0, ParameterValue{ .int_val = 1 });
    try stmt.bindByIndex(1, ParameterValue{ .int_val = 2 });
    try std.testing.expect(stmt.allBound());
    
    stmt.clearBindings();
    try std.testing.expect(!stmt.allBound());
}