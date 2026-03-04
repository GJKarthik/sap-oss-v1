//! Test Helper - Testing utilities and fixtures
//!
//! Purpose:
//! Provides test utilities, assertions, mock objects,
//! and test fixtures for unit and integration testing.

const std = @import("std");

// ============================================================================
// Test Assertions
// ============================================================================

pub fn expectApproxEqual(expected: f64, actual: f64, tolerance: f64) !void {
    const diff = @abs(expected - actual);
    if (diff > tolerance) {
        std.debug.print("Expected ~{d}, got {d} (diff: {d}, tolerance: {d})\n", .{ expected, actual, diff, tolerance });
        return error.TestExpectedApproxEqual;
    }
}

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Expected '{s}' to contain '{s}'\n", .{ haystack, needle });
        return error.TestExpectedContains;
    }
}

pub fn expectStartsWith(str: []const u8, prefix: []const u8) !void {
    if (!std.mem.startsWith(u8, str, prefix)) {
        std.debug.print("Expected '{s}' to start with '{s}'\n", .{ str, prefix });
        return error.TestExpectedStartsWith;
    }
}

pub fn expectEndsWith(str: []const u8, suffix: []const u8) !void {
    if (!std.mem.endsWith(u8, str, suffix)) {
        std.debug.print("Expected '{s}' to end with '{s}'\n", .{ str, suffix });
        return error.TestExpectedEndsWith;
    }
}

pub fn expectBetween(comptime T: type, value: T, min: T, max: T) !void {
    if (value < min or value > max) {
        return error.TestExpectedBetween;
    }
}

pub fn expectLen(comptime T: type, slice: []const T, expected_len: usize) !void {
    if (slice.len != expected_len) {
        std.debug.print("Expected length {d}, got {d}\n", .{ expected_len, slice.len });
        return error.TestExpectedLen;
    }
}

// ============================================================================
// Test Context
// ============================================================================

pub const TestContext = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    start_time: i128 = 0,
    assertions_passed: u32 = 0,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) TestContext {
        return .{
            .allocator = allocator,
            .name = name,
            .start_time = std.time.nanoTimestamp(),
        };
    }
    
    pub fn pass(self: *TestContext) void {
        self.assertions_passed += 1;
    }
    
    pub fn elapsedMs(self: *const TestContext) u64 {
        return @intCast(@divFloor(std.time.nanoTimestamp() - self.start_time, 1_000_000));
    }
};

// ============================================================================
// Mock Value
// ============================================================================

pub const MockValue = union(enum) {
    null_val: void,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string_val: []const u8,
    
    pub fn eql(self: MockValue, other: MockValue) bool {
        return switch (self) {
            .null_val => other == .null_val,
            .bool_val => |v| other == .bool_val and other.bool_val == v,
            .int_val => |v| other == .int_val and other.int_val == v,
            .float_val => |v| other == .float_val and other.float_val == v,
            .string_val => |v| other == .string_val and std.mem.eql(u8, other.string_val, v),
        };
    }
};

// ============================================================================
// Mock Row
// ============================================================================

pub const MockRow = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(MockValue),
    
    pub fn init(allocator: std.mem.Allocator) MockRow {
        return .{
            .allocator = allocator,
            .values = std.ArrayList(MockValue).init(allocator),
        };
    }
    
    pub fn deinit(self: *MockRow) void {
        self.values.deinit();
    }
    
    pub fn addInt(self: *MockRow, val: i64) !void {
        try self.values.append(MockValue{ .int_val = val });
    }
    
    pub fn addString(self: *MockRow, val: []const u8) !void {
        try self.values.append(MockValue{ .string_val = val });
    }
    
    pub fn addBool(self: *MockRow, val: bool) !void {
        try self.values.append(MockValue{ .bool_val = val });
    }
    
    pub fn addNull(self: *MockRow) !void {
        try self.values.append(MockValue{ .null_val = {} });
    }
    
    pub fn get(self: *const MockRow, idx: usize) ?MockValue {
        if (idx >= self.values.items.len) return null;
        return self.values.items[idx];
    }
};

// ============================================================================
// Mock Table
// ============================================================================

pub const MockTable = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    columns: std.ArrayList([]const u8),
    rows: std.ArrayList(MockRow),
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) MockTable {
        return .{
            .allocator = allocator,
            .name = name,
            .columns = std.ArrayList([]const u8).init(allocator),
            .rows = std.ArrayList(MockRow).init(allocator),
        };
    }
    
    pub fn deinit(self: *MockTable) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit();
        self.columns.deinit();
    }
    
    pub fn addColumn(self: *MockTable, name: []const u8) !void {
        try self.columns.append(name);
    }
    
    pub fn addRow(self: *MockTable) !*MockRow {
        var row = MockRow.init(self.allocator);
        try self.rows.append(row);
        return &self.rows.items[self.rows.items.len - 1];
    }
    
    pub fn numColumns(self: *const MockTable) usize {
        return self.columns.items.len;
    }
    
    pub fn numRows(self: *const MockTable) usize {
        return self.rows.items.len;
    }
};

// ============================================================================
// Test Fixture
// ============================================================================

pub const TestFixture = struct {
    allocator: std.mem.Allocator,
    tables: std.StringHashMap(MockTable),
    setup_done: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) TestFixture {
        return .{
            .allocator = allocator,
            .tables = std.StringHashMap(MockTable).init(allocator),
        };
    }
    
    pub fn deinit(self: *TestFixture) void {
        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            var table = entry.value_ptr;
            table.deinit();
        }
        self.tables.deinit();
    }
    
    pub fn createTable(self: *TestFixture, name: []const u8) !*MockTable {
        var table = MockTable.init(self.allocator, name);
        try self.tables.put(name, table);
        return self.tables.getPtr(name).?;
    }
    
    pub fn getTable(self: *TestFixture, name: []const u8) ?*MockTable {
        return self.tables.getPtr(name);
    }
    
    pub fn setup(self: *TestFixture) !void {
        self.setup_done = true;
    }
    
    pub fn teardown(self: *TestFixture) void {
        self.setup_done = false;
    }
};

// ============================================================================
// Test Runner
// ============================================================================

pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    time_ms: u64,
    error_msg: ?[]const u8 = null,
};

pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayList(TestResult),
    
    pub fn init(allocator: std.mem.Allocator) TestRunner {
        return .{
            .allocator = allocator,
            .results = std.ArrayList(TestResult).init(allocator),
        };
    }
    
    pub fn deinit(self: *TestRunner) void {
        self.results.deinit();
    }
    
    pub fn addResult(self: *TestRunner, result: TestResult) !void {
        try self.results.append(result);
    }
    
    pub fn passedCount(self: *const TestRunner) usize {
        var count: usize = 0;
        for (self.results.items) |r| {
            if (r.passed) count += 1;
        }
        return count;
    }
    
    pub fn failedCount(self: *const TestRunner) usize {
        return self.results.items.len - self.passedCount();
    }
    
    pub fn totalCount(self: *const TestRunner) usize {
        return self.results.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "expectApproxEqual" {
    try expectApproxEqual(3.14, 3.14159, 0.01);
    try std.testing.expectError(error.TestExpectedApproxEqual, expectApproxEqual(1.0, 2.0, 0.1));
}

test "expectContains" {
    try expectContains("hello world", "world");
    try std.testing.expectError(error.TestExpectedContains, expectContains("hello", "world"));
}

test "expectStartsWith" {
    try expectStartsWith("hello world", "hello");
    try std.testing.expectError(error.TestExpectedStartsWith, expectStartsWith("hello", "world"));
}

test "mock value equality" {
    const v1 = MockValue{ .int_val = 42 };
    const v2 = MockValue{ .int_val = 42 };
    const v3 = MockValue{ .int_val = 43 };
    
    try std.testing.expect(v1.eql(v2));
    try std.testing.expect(!v1.eql(v3));
}

test "mock row" {
    const allocator = std.testing.allocator;
    
    var row = MockRow.init(allocator);
    defer row.deinit();
    
    try row.addInt(1);
    try row.addString("Alice");
    try row.addBool(true);
    
    try std.testing.expectEqual(@as(i64, 1), row.get(0).?.int_val);
    try std.testing.expectEqualStrings("Alice", row.get(1).?.string_val);
}

test "mock table" {
    const allocator = std.testing.allocator;
    
    var table = MockTable.init(allocator, "users");
    defer table.deinit();
    
    try table.addColumn("id");
    try table.addColumn("name");
    
    var row = try table.addRow();
    try row.addInt(1);
    try row.addString("Alice");
    
    try std.testing.expectEqual(@as(usize, 2), table.numColumns());
    try std.testing.expectEqual(@as(usize, 1), table.numRows());
}

test "test fixture" {
    const allocator = std.testing.allocator;
    
    var fixture = TestFixture.init(allocator);
    defer fixture.deinit();
    
    var table = try fixture.createTable("test");
    try table.addColumn("x");
    
    try std.testing.expect(fixture.getTable("test") != null);
    try std.testing.expect(fixture.getTable("missing") == null);
}

test "test runner" {
    const allocator = std.testing.allocator;
    
    var runner = TestRunner.init(allocator);
    defer runner.deinit();
    
    try runner.addResult(.{ .name = "test1", .passed = true, .time_ms = 10 });
    try runner.addResult(.{ .name = "test2", .passed = false, .time_ms = 5 });
    
    try std.testing.expectEqual(@as(usize, 2), runner.totalCount());
    try std.testing.expectEqual(@as(usize, 1), runner.passedCount());
    try std.testing.expectEqual(@as(usize, 1), runner.failedCount());
}