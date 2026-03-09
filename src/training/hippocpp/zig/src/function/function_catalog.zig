//! Function Catalog - Built-in Functions Registry
//!
//! Converted from: kuzu/src/function/*.cpp
//!
//! Purpose:
//! Manages built-in scalar and aggregate functions.
//! Provides function resolution and type inference.

const std = @import("std");
const common = @import("common");

const LogicalType = common.LogicalType;

/// Function type category
pub const FunctionType = enum {
    SCALAR,
    AGGREGATE,
    TABLE,
};

/// Function signature
pub const FunctionSignature = struct {
    param_types: []const LogicalType,
    return_type: LogicalType,
    variadic: bool,
    
    pub fn init(params: []const LogicalType, ret: LogicalType) FunctionSignature {
        return .{
            .param_types = params,
            .return_type = ret,
            .variadic = false,
        };
    }
    
    pub fn variadic_init(params: []const LogicalType, ret: LogicalType) FunctionSignature {
        return .{
            .param_types = params,
            .return_type = ret,
            .variadic = true,
        };
    }
};

/// Function definition
pub const FunctionDef = struct {
    name: []const u8,
    func_type: FunctionType,
    signatures: []const FunctionSignature,
    description: []const u8,
    
    pub fn scalar(name: []const u8, sigs: []const FunctionSignature, desc: []const u8) FunctionDef {
        return .{
            .name = name,
            .func_type = .SCALAR,
            .signatures = sigs,
            .description = desc,
        };
    }
    
    pub fn aggregate(name: []const u8, sigs: []const FunctionSignature, desc: []const u8) FunctionDef {
        return .{
            .name = name,
            .func_type = .AGGREGATE,
            .signatures = sigs,
            .description = desc,
        };
    }
};

/// Built-in function definitions
pub const BuiltInFunctions = struct {
    // Arithmetic functions
    pub const ABS = FunctionDef.scalar("ABS", &.{
        FunctionSignature.init(&.{.INT32}, .INT32),
        FunctionSignature.init(&.{.INT64}, .INT64),
        FunctionSignature.init(&.{.FLOAT}, .FLOAT),
        FunctionSignature.init(&.{.DOUBLE}, .DOUBLE),
    }, "Returns absolute value");
    
    pub const CEIL = FunctionDef.scalar("CEIL", &.{
        FunctionSignature.init(&.{.DOUBLE}, .DOUBLE),
    }, "Rounds up to nearest integer");
    
    pub const FLOOR = FunctionDef.scalar("FLOOR", &.{
        FunctionSignature.init(&.{.DOUBLE}, .DOUBLE),
    }, "Rounds down to nearest integer");
    
    pub const ROUND = FunctionDef.scalar("ROUND", &.{
        FunctionSignature.init(&.{.DOUBLE}, .DOUBLE),
        FunctionSignature.init(&.{ .DOUBLE, .INT32 }, .DOUBLE),
    }, "Rounds to specified precision");
    
    pub const SQRT = FunctionDef.scalar("SQRT", &.{
        FunctionSignature.init(&.{.DOUBLE}, .DOUBLE),
    }, "Returns square root");
    
    pub const POWER = FunctionDef.scalar("POWER", &.{
        FunctionSignature.init(&.{ .DOUBLE, .DOUBLE }, .DOUBLE),
    }, "Returns x raised to power y");
    
    // String functions
    pub const LENGTH = FunctionDef.scalar("LENGTH", &.{
        FunctionSignature.init(&.{.STRING}, .INT64),
    }, "Returns string length");
    
    pub const LOWER = FunctionDef.scalar("LOWER", &.{
        FunctionSignature.init(&.{.STRING}, .STRING),
    }, "Converts to lowercase");
    
    pub const UPPER = FunctionDef.scalar("UPPER", &.{
        FunctionSignature.init(&.{.STRING}, .STRING),
    }, "Converts to uppercase");
    
    pub const TRIM = FunctionDef.scalar("TRIM", &.{
        FunctionSignature.init(&.{.STRING}, .STRING),
    }, "Removes leading/trailing whitespace");
    
    pub const LTRIM = FunctionDef.scalar("LTRIM", &.{
        FunctionSignature.init(&.{.STRING}, .STRING),
    }, "Removes leading whitespace");
    
    pub const RTRIM = FunctionDef.scalar("RTRIM", &.{
        FunctionSignature.init(&.{.STRING}, .STRING),
    }, "Removes trailing whitespace");
    
    pub const SUBSTRING = FunctionDef.scalar("SUBSTRING", &.{
        FunctionSignature.init(&.{ .STRING, .INT64, .INT64 }, .STRING),
    }, "Extracts substring");
    
    pub const CONCAT = FunctionDef.scalar("CONCAT", &.{
        FunctionSignature.variadic_init(&.{.STRING}, .STRING),
    }, "Concatenates strings");
    
    pub const REPLACE = FunctionDef.scalar("REPLACE", &.{
        FunctionSignature.init(&.{ .STRING, .STRING, .STRING }, .STRING),
    }, "Replaces occurrences");
    
    // Aggregate functions
    pub const COUNT = FunctionDef.aggregate("COUNT", &.{
        FunctionSignature.init(&.{.ANY}, .INT64),
    }, "Counts rows");
    
    pub const COUNT_STAR = FunctionDef.aggregate("COUNT_STAR", &.{
        FunctionSignature.init(&.{}, .INT64),
    }, "Counts all rows");
    
    pub const SUM = FunctionDef.aggregate("SUM", &.{
        FunctionSignature.init(&.{.INT32}, .INT64),
        FunctionSignature.init(&.{.INT64}, .INT64),
        FunctionSignature.init(&.{.FLOAT}, .DOUBLE),
        FunctionSignature.init(&.{.DOUBLE}, .DOUBLE),
    }, "Sums values");
    
    pub const AVG = FunctionDef.aggregate("AVG", &.{
        FunctionSignature.init(&.{.INT32}, .DOUBLE),
        FunctionSignature.init(&.{.INT64}, .DOUBLE),
        FunctionSignature.init(&.{.FLOAT}, .DOUBLE),
        FunctionSignature.init(&.{.DOUBLE}, .DOUBLE),
    }, "Computes average");
    
    pub const MIN = FunctionDef.aggregate("MIN", &.{
        FunctionSignature.init(&.{.INT32}, .INT32),
        FunctionSignature.init(&.{.INT64}, .INT64),
        FunctionSignature.init(&.{.FLOAT}, .FLOAT),
        FunctionSignature.init(&.{.DOUBLE}, .DOUBLE),
        FunctionSignature.init(&.{.STRING}, .STRING),
    }, "Returns minimum value");
    
    pub const MAX = FunctionDef.aggregate("MAX", &.{
        FunctionSignature.init(&.{.INT32}, .INT32),
        FunctionSignature.init(&.{.INT64}, .INT64),
        FunctionSignature.init(&.{.FLOAT}, .FLOAT),
        FunctionSignature.init(&.{.DOUBLE}, .DOUBLE),
        FunctionSignature.init(&.{.STRING}, .STRING),
    }, "Returns maximum value");
    
    // Date/Time functions
    pub const NOW = FunctionDef.scalar("NOW", &.{
        FunctionSignature.init(&.{}, .TIMESTAMP),
    }, "Returns current timestamp");
    
    pub const DATE = FunctionDef.scalar("DATE", &.{
        FunctionSignature.init(&.{.STRING}, .DATE),
    }, "Parses date from string");
    
    // Comparison functions
    pub const COALESCE = FunctionDef.scalar("COALESCE", &.{
        FunctionSignature.variadic_init(&.{.ANY}, .ANY),
    }, "Returns first non-null value");
    
    pub const NULLIF = FunctionDef.scalar("NULLIF", &.{
        FunctionSignature.init(&.{ .ANY, .ANY }, .ANY),
    }, "Returns null if arguments equal");
};

/// Function catalog
pub const FunctionCatalog = struct {
    allocator: std.mem.Allocator,
    functions: std.StringHashMap(FunctionDef),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        var catalog = Self{
            .allocator = allocator,
            .functions = .{},
        };
        try catalog.registerBuiltIns();
        return catalog;
    }
    
    pub fn deinit(self: *Self) void {
        self.functions.deinit(self.allocator);
    }
    
    fn registerBuiltIns(self: *Self) !void {
        // Arithmetic
        try self.functions.put("ABS", BuiltInFunctions.ABS);
        try self.functions.put("CEIL", BuiltInFunctions.CEIL);
        try self.functions.put("FLOOR", BuiltInFunctions.FLOOR);
        try self.functions.put("ROUND", BuiltInFunctions.ROUND);
        try self.functions.put("SQRT", BuiltInFunctions.SQRT);
        try self.functions.put("POWER", BuiltInFunctions.POWER);
        
        // String
        try self.functions.put("LENGTH", BuiltInFunctions.LENGTH);
        try self.functions.put("LOWER", BuiltInFunctions.LOWER);
        try self.functions.put("UPPER", BuiltInFunctions.UPPER);
        try self.functions.put("TRIM", BuiltInFunctions.TRIM);
        try self.functions.put("LTRIM", BuiltInFunctions.LTRIM);
        try self.functions.put("RTRIM", BuiltInFunctions.RTRIM);
        try self.functions.put("SUBSTRING", BuiltInFunctions.SUBSTRING);
        try self.functions.put("CONCAT", BuiltInFunctions.CONCAT);
        try self.functions.put("REPLACE", BuiltInFunctions.REPLACE);
        
        // Aggregates
        try self.functions.put("COUNT", BuiltInFunctions.COUNT);
        try self.functions.put("COUNT_STAR", BuiltInFunctions.COUNT_STAR);
        try self.functions.put("SUM", BuiltInFunctions.SUM);
        try self.functions.put("AVG", BuiltInFunctions.AVG);
        try self.functions.put("MIN", BuiltInFunctions.MIN);
        try self.functions.put("MAX", BuiltInFunctions.MAX);
        
        // Date/Time
        try self.functions.put("NOW", BuiltInFunctions.NOW);
        try self.functions.put("DATE", BuiltInFunctions.DATE);
        
        // Comparison
        try self.functions.put("COALESCE", BuiltInFunctions.COALESCE);
        try self.functions.put("NULLIF", BuiltInFunctions.NULLIF);
    }
    
    pub fn getFunction(self: *const Self, name: []const u8) ?FunctionDef {
        return self.functions.get(name);
    }
    
    pub fn hasFunction(self: *const Self, name: []const u8) bool {
        return self.functions.contains(name);
    }
    
    /// Resolve function with argument types
    pub fn resolveFunction(self: *const Self, name: []const u8, arg_types: []const LogicalType) ?FunctionSignature {
        const func = self.getFunction(name) orelse return null;
        
        for (func.signatures) |sig| {
            if (sig.variadic) {
                if (arg_types.len >= sig.param_types.len) {
                    return sig;
                }
            } else if (sig.param_types.len == arg_types.len) {
                var matches = true;
                for (sig.param_types, 0..) |param_type, i| {
                    if (param_type != .ANY and param_type != arg_types[i]) {
                        matches = false;
                        break;
                    }
                }
                if (matches) return sig;
            }
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "function signature" {
    const sig = FunctionSignature.init(&.{ .INT64, .INT64 }, .INT64);
    try std.testing.expectEqual(@as(usize, 2), sig.param_types.len);
    try std.testing.expectEqual(LogicalType.INT64, sig.return_type);
}

test "function def" {
    const def = BuiltInFunctions.ABS;
    try std.testing.expect(std.mem.eql(u8, "ABS", def.name));
    try std.testing.expectEqual(FunctionType.SCALAR, def.func_type);
}

test "function catalog" {
    const allocator = std.testing.allocator;
    
    var catalog = try FunctionCatalog.init(allocator);
    defer catalog.deinit(std.testing.allocator);
    
    try std.testing.expect(catalog.hasFunction("ABS"));
    try std.testing.expect(catalog.hasFunction("COUNT"));
    try std.testing.expect(!catalog.hasFunction("NONEXISTENT"));
    
    const abs = catalog.getFunction("ABS");
    try std.testing.expect(abs != null);
}

test "resolve function" {
    const allocator = std.testing.allocator;
    
    var catalog = try FunctionCatalog.init(allocator);
    defer catalog.deinit(std.testing.allocator);
    
    const sig = catalog.resolveFunction("ABS", &.{.INT64});
    try std.testing.expect(sig != null);
    try std.testing.expectEqual(LogicalType.INT64, sig.?.return_type);
}