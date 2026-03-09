//! Exception - Error handling and exception types
//!
//! Purpose:
//! Provides structured error types and exception handling
//! for the database system with context information.

const std = @import("std");

// ============================================================================
// Error Categories
// ============================================================================

pub const ErrorCategory = enum {
    INTERNAL,           // Internal system errors
    BINDER,             // Binding/semantic errors
    PARSER,             // Parse errors
    CATALOG,            // Catalog errors
    STORAGE,            // Storage/IO errors
    TRANSACTION,        // Transaction errors
    CONSTRAINT,         // Constraint violations
    TYPE,               // Type errors
    OVERFLOW,           // Numeric overflow
    OUT_OF_MEMORY,      // Memory allocation errors
    INTERRUPT,          // User interrupt
    CONNECTION,         // Connection errors
    RUNTIME,            // Runtime errors
};

// ============================================================================
// Error Codes
// ============================================================================

pub const ErrorCode = enum(u32) {
    // Internal (1xxx)
    INTERNAL_ERROR = 1000,
    NOT_IMPLEMENTED = 1001,
    ASSERTION_FAILURE = 1002,
    
    // Parser (2xxx)
    SYNTAX_ERROR = 2000,
    UNEXPECTED_TOKEN = 2001,
    INVALID_LITERAL = 2002,
    UNCLOSED_STRING = 2003,
    
    // Binder (3xxx)
    UNKNOWN_TABLE = 3000,
    UNKNOWN_COLUMN = 3001,
    AMBIGUOUS_COLUMN = 3002,
    UNKNOWN_FUNCTION = 3003,
    INVALID_TYPE = 3004,
    PARAMETER_TYPE_MISMATCH = 3005,
    AGGREGATE_IN_WHERE = 3006,
    
    // Catalog (4xxx)
    TABLE_EXISTS = 4000,
    TABLE_NOT_FOUND = 4001,
    COLUMN_NOT_FOUND = 4002,
    INDEX_EXISTS = 4003,
    INDEX_NOT_FOUND = 4004,
    
    // Storage (5xxx)
    IO_ERROR = 5000,
    CORRUPTED_DATA = 5001,
    PAGE_NOT_FOUND = 5002,
    CHECKSUM_MISMATCH = 5003,
    WAL_ERROR = 5004,
    
    // Transaction (6xxx)
    TRANSACTION_CONFLICT = 6000,
    DEADLOCK = 6001,
    SERIALIZATION_FAILURE = 6002,
    LOCK_TIMEOUT = 6003,
    
    // Constraint (7xxx)
    PRIMARY_KEY_VIOLATION = 7000,
    FOREIGN_KEY_VIOLATION = 7001,
    UNIQUE_VIOLATION = 7002,
    NOT_NULL_VIOLATION = 7003,
    CHECK_VIOLATION = 7004,
    
    // Type (8xxx)
    TYPE_MISMATCH = 8000,
    INVALID_CAST = 8001,
    DIVISION_BY_ZERO = 8002,
    NUMERIC_OVERFLOW = 8003,
    STRING_TOO_LONG = 8004,
    
    // Runtime (9xxx)
    RUNTIME_ERROR = 9000,
    EVALUATION_ERROR = 9001,
    FUNCTION_ERROR = 9002,
};

// ============================================================================
// Source Location
// ============================================================================

pub const SourceLocation = struct {
    line: u32 = 0,
    column: u32 = 0,
    offset: u32 = 0,
    length: u32 = 0,
    source: ?[]const u8 = null,
    
    pub fn init(line: u32, column: u32) SourceLocation {
        return .{ .line = line, .column = column };
    }
    
    pub fn format(self: *const SourceLocation, writer: anytype) !void {
        if (self.line > 0) {
            try writer.print("line {d}", .{self.line});
            if (self.column > 0) {
                try writer.print(", column {d}", .{self.column});
            }
        }
    }
};

// ============================================================================
// Database Exception
// ============================================================================

pub const DatabaseException = struct {
    allocator: ?std.mem.Allocator,
    category: ErrorCategory,
    code: ErrorCode,
    message: []const u8,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    location: ?SourceLocation = null,
    cause: ?*const DatabaseException = null,
    owned_message: bool = false,
    
    pub fn init(category: ErrorCategory, code: ErrorCode, message: []const u8) DatabaseException {
        return .{
            .allocator = null,
            .category = category,
            .code = code,
            .message = message,
        };
    }
    
    pub fn initOwned(allocator: std.mem.Allocator, category: ErrorCategory, code: ErrorCode, message: []const u8) !DatabaseException {
        return .{
            .allocator = allocator,
            .category = category,
            .code = code,
            .message = try allocator.dupe(u8, message),
            .owned_message = true,
        };
    }
    
    pub fn deinit(self: *DatabaseException) void {
        if (self.allocator) |alloc| {
            if (self.owned_message) {
                alloc.free(self.message);
            }
            if (self.detail) |d| alloc.free(d);
            if (self.hint) |h| alloc.free(h);
        }
    }
    
    pub fn withLocation(self: DatabaseException, loc: SourceLocation) DatabaseException {
        var result = self;
        result.location = loc;
        return result;
    }
    
    pub fn withDetail(self: *DatabaseException, detail: []const u8) !void {
        if (self.allocator) |alloc| {
            self.detail = try alloc.dupe(u8, detail);
        }
    }
    
    pub fn format(self: *const DatabaseException, writer: anytype) !void {
        try writer.print("{s} Error ({d}): {s}", .{
            @tagName(self.category),
            @intFromEnum(self.code),
            self.message,
        });
        
        if (self.location) |loc| {
            try writer.writeAll(" at ");
            try loc.format(writer);
        }
        
        if (self.detail) |d| {
            try writer.print("\nDetail: {s}", .{d});
        }
        
        if (self.hint) |h| {
            try writer.print("\nHint: {s}", .{h});
        }
    }
};

// ============================================================================
// Exception Factory
// ============================================================================

pub const ExceptionFactory = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ExceptionFactory {
        return .{ .allocator = allocator };
    }
    
    // Parser errors
    pub fn syntaxError(self: *ExceptionFactory, msg: []const u8, loc: SourceLocation) !DatabaseException {
        var ex = try DatabaseException.initOwned(self.allocator, .PARSER, .SYNTAX_ERROR, msg);
        ex.location = loc;
        return ex;
    }
    
    pub fn unexpectedToken(self: *ExceptionFactory, expected: []const u8, found: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Expected {s}, found {s}", .{ expected, found });
        return try DatabaseException.initOwned(self.allocator, .PARSER, .UNEXPECTED_TOKEN, msg);
    }
    
    // Binder errors
    pub fn unknownTable(self: *ExceptionFactory, table_name: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Unknown table: {s}", .{table_name});
        return try DatabaseException.initOwned(self.allocator, .BINDER, .UNKNOWN_TABLE, msg);
    }
    
    pub fn unknownColumn(self: *ExceptionFactory, column_name: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Unknown column: {s}", .{column_name});
        return try DatabaseException.initOwned(self.allocator, .BINDER, .UNKNOWN_COLUMN, msg);
    }
    
    pub fn ambiguousColumn(self: *ExceptionFactory, column_name: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Ambiguous column reference: {s}", .{column_name});
        return try DatabaseException.initOwned(self.allocator, .BINDER, .AMBIGUOUS_COLUMN, msg);
    }
    
    // Catalog errors
    pub fn tableExists(self: *ExceptionFactory, table_name: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Table already exists: {s}", .{table_name});
        return try DatabaseException.initOwned(self.allocator, .CATALOG, .TABLE_EXISTS, msg);
    }
    
    pub fn tableNotFound(self: *ExceptionFactory, table_name: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Table not found: {s}", .{table_name});
        return try DatabaseException.initOwned(self.allocator, .CATALOG, .TABLE_NOT_FOUND, msg);
    }
    
    // Transaction errors
    pub fn deadlock(self: *ExceptionFactory) !DatabaseException {
        return try DatabaseException.initOwned(self.allocator, .TRANSACTION, .DEADLOCK, "Deadlock detected");
    }
    
    pub fn serializationFailure(self: *ExceptionFactory) !DatabaseException {
        return try DatabaseException.initOwned(self.allocator, .TRANSACTION, .SERIALIZATION_FAILURE, 
            "Could not serialize access due to concurrent update");
    }
    
    // Constraint errors
    pub fn primaryKeyViolation(self: *ExceptionFactory, table: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Primary key violation in table {s}", .{table});
        return try DatabaseException.initOwned(self.allocator, .CONSTRAINT, .PRIMARY_KEY_VIOLATION, msg);
    }
    
    pub fn notNullViolation(self: *ExceptionFactory, column: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "NULL value in column {s} violates not-null constraint", .{column});
        return try DatabaseException.initOwned(self.allocator, .CONSTRAINT, .NOT_NULL_VIOLATION, msg);
    }
    
    // Type errors
    pub fn typeMismatch(self: *ExceptionFactory, expected: []const u8, found: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Type mismatch: expected {s}, found {s}", .{ expected, found });
        return try DatabaseException.initOwned(self.allocator, .TYPE, .TYPE_MISMATCH, msg);
    }
    
    pub fn divisionByZero(self: *ExceptionFactory) !DatabaseException {
        return try DatabaseException.initOwned(self.allocator, .TYPE, .DIVISION_BY_ZERO, "Division by zero");
    }
    
    // Internal errors
    pub fn internal(self: *ExceptionFactory, msg: []const u8) !DatabaseException {
        return try DatabaseException.initOwned(self.allocator, .INTERNAL, .INTERNAL_ERROR, msg);
    }
    
    pub fn notImplemented(self: *ExceptionFactory, feature: []const u8) !DatabaseException {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Not implemented: {s}", .{feature});
        return try DatabaseException.initOwned(self.allocator, .INTERNAL, .NOT_IMPLEMENTED, msg);
    }
};

// ============================================================================
// Result Type with Exception
// ============================================================================

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: DatabaseException,
        
        pub fn isOk(self: @This()) bool {
            return self == .ok;
        }
        
        pub fn isErr(self: @This()) bool {
            return self == .err;
        }
        
        pub fn unwrap(self: @This()) T {
            return switch (self) {
                .ok => |v| v,
                .err => unreachable,
            };
        }
        
        pub fn unwrapErr(self: @This()) DatabaseException {
            return switch (self) {
                .ok => unreachable,
                .err => |e| e,
            };
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "database exception basic" {
    const ex = DatabaseException.init(.PARSER, .SYNTAX_ERROR, "Unexpected token");
    try std.testing.expectEqual(ErrorCategory.PARSER, ex.category);
    try std.testing.expectEqual(ErrorCode.SYNTAX_ERROR, ex.code);
    try std.testing.expectEqualStrings("Unexpected token", ex.message);
}

test "database exception with location" {
    const ex = DatabaseException.init(.PARSER, .SYNTAX_ERROR, "Error")
        .withLocation(SourceLocation.init(10, 5));
    
    try std.testing.expect(ex.location != null);
    try std.testing.expectEqual(@as(u32, 10), ex.location.?.line);
    try std.testing.expectEqual(@as(u32, 5), ex.location.?.column);
}

test "exception factory" {
    const allocator = std.testing.allocator;
    
    var factory = ExceptionFactory.init(allocator);
    
    var ex1 = try factory.unknownTable("users");
    defer ex1.deinit();
    try std.testing.expectEqual(ErrorCode.UNKNOWN_TABLE, ex1.code);
    
    var ex2 = try factory.deadlock();
    defer ex2.deinit();
    try std.testing.expectEqual(ErrorCode.DEADLOCK, ex2.code);
}

test "error codes" {
    try std.testing.expectEqual(@as(u32, 2000), @intFromEnum(ErrorCode.SYNTAX_ERROR));
    try std.testing.expectEqual(@as(u32, 6001), @intFromEnum(ErrorCode.DEADLOCK));
}

test "result type" {
    const IntResult = Result(i32);
    
    const ok_result = IntResult{ .ok = 42 };
    try std.testing.expect(ok_result.isOk());
    try std.testing.expectEqual(@as(i32, 42), ok_result.unwrap());
    
    const err_result = IntResult{ .err = DatabaseException.init(.INTERNAL, .INTERNAL_ERROR, "test") };
    try std.testing.expect(err_result.isErr());
}