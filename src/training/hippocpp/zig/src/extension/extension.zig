//! Extension - Plugin/Extension System
//!
//! Converted from: kuzu/src/extension/*.cpp
//!
//! Purpose:
//! Provides extension/plugin mechanism for adding custom functions,
//! data types, and storage backends.

const std = @import("std");
const common = @import("common");
const function_mod = @import("function_catalog");

const LogicalType = common.LogicalType;
const FunctionDef = function_mod.FunctionDef;
const FunctionCatalog = function_mod.FunctionCatalog;

/// Extension version info
pub const ExtensionVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
    
    pub fn init(major: u32, minor: u32, patch: u32) ExtensionVersion {
        return .{ .major = major, .minor = minor, .patch = patch };
    }
    
    pub fn compatible(self: *const ExtensionVersion, other: *const ExtensionVersion) bool {
        return self.major == other.major and self.minor >= other.minor;
    }
};

/// Extension type
pub const ExtensionType = enum {
    FUNCTION,
    DATA_TYPE,
    STORAGE,
    INDEX,
    OPTIMIZER,
};

/// Extension metadata
pub const ExtensionMetadata = struct {
    name: []const u8,
    description: []const u8,
    version: ExtensionVersion,
    author: []const u8,
    extension_type: ExtensionType,
    
    pub fn init(name: []const u8, desc: []const u8, ext_type: ExtensionType) ExtensionMetadata {
        return .{
            .name = name,
            .description = desc,
            .version = ExtensionVersion.init(1, 0, 0),
            .author = "",
            .extension_type = ext_type,
        };
    }
};

/// Extension interface
pub const Extension = struct {
    metadata: ExtensionMetadata,
    loaded: bool,
    init_fn: ?*const fn (*Extension) anyerror!void,
    cleanup_fn: ?*const fn (*Extension) void,
    user_data: ?*anyopaque,
    
    const Self = @This();
    
    pub fn init(metadata: ExtensionMetadata) Self {
        return .{
            .metadata = metadata,
            .loaded = false,
            .init_fn = null,
            .cleanup_fn = null,
            .user_data = null,
        };
    }
    
    pub fn load(self: *Self) !void {
        if (self.init_fn) |initFn| {
            try initFn(self);
        }
        self.loaded = true;
    }
    
    pub fn unload(self: *Self) void {
        if (self.cleanup_fn) |cleanupFn| {
            cleanupFn(self);
        }
        self.loaded = false;
    }
    
    pub fn isLoaded(self: *const Self) bool {
        return self.loaded;
    }
};

/// Function extension - adds custom functions
pub const FunctionExtension = struct {
    base: Extension,
    functions: std.ArrayList(FunctionDef),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, desc: []const u8) Self {
        return .{
            .base = Extension.init(ExtensionMetadata.init(name, desc, .FUNCTION)),
            .functions = .{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.functions.deinit(self.allocator);
    }
    
    pub fn addFunction(self: *Self, func: FunctionDef) !void {
        try self.functions.append(self.allocator, func);
    }
    
    pub fn registerAll(self: *Self, catalog: *FunctionCatalog) !void {
        for (self.functions.items) |func| {
            try catalog.functions.put(func.name, func);
        }
    }
};

/// Extension registry
pub const ExtensionRegistry = struct {
    allocator: std.mem.Allocator,
    extensions: std.StringHashMap(*Extension),
    load_path: ?[]const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .extensions = .{},
            .load_path = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Unload all extensions
        var iter = self.extensions.valueIterator();
        while (iter.next()) |ext| {
            ext.*.unload();
        }
        self.extensions.deinit(self.allocator);
    }
    
    pub fn setLoadPath(self: *Self, path: []const u8) void {
        self.load_path = path;
    }
    
    pub fn register(self: *Self, ext: *Extension) !void {
        try self.extensions.put(ext.metadata.name, ext);
    }
    
    pub fn unregister(self: *Self, name: []const u8) bool {
        if (self.extensions.fetchRemove(name)) |kv| {
            kv.value.unload();
            return true;
        }
        return false;
    }
    
    pub fn get(self: *const Self, name: []const u8) ?*Extension {
        return self.extensions.get(name);
    }
    
    pub fn isLoaded(self: *const Self, name: []const u8) bool {
        if (self.get(name)) |ext| {
            return ext.isLoaded();
        }
        return false;
    }
    
    pub fn loadExtension(self: *Self, name: []const u8) !void {
        if (self.get(name)) |ext| {
            try ext.load();
        }
    }
    
    pub fn unloadExtension(self: *Self, name: []const u8) void {
        if (self.get(name)) |ext| {
            ext.unload();
        }
    }
    
    pub fn getLoadedCount(self: *const Self) usize {
        var count: usize = 0;
        var iter = self.extensions.valueIterator();
        while (iter.next()) |ext| {
            if (ext.*.isLoaded()) count += 1;
        }
        return count;
    }
};

/// Built-in extension for extra math functions
pub const MathExtension = struct {
    func_ext: FunctionExtension,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        var ext = FunctionExtension.init(allocator, "math", "Additional mathematical functions");
        
        // Add extra math functions would go here
        _ = &ext;
        
        return .{ .func_ext = ext };
    }
    
    pub fn deinit(self: *Self) void {
        self.func_ext.deinit(self.allocator);
    }
};

/// Built-in extension for JSON functions
pub const JsonExtension = struct {
    func_ext: FunctionExtension,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        const ext = FunctionExtension.init(allocator, "json", "JSON parsing and manipulation functions");
        return .{ .func_ext = ext };
    }
    
    pub fn deinit(self: *Self) void {
        self.func_ext.deinit(self.allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "extension version" {
    const v1 = ExtensionVersion.init(1, 2, 3);
    try std.testing.expectEqual(@as(u32, 1), v1.major);
    try std.testing.expectEqual(@as(u32, 2), v1.minor);
    
    const v2 = ExtensionVersion.init(1, 3, 0);
    try std.testing.expect(v2.compatible(&v1));
}

test "extension metadata" {
    const meta = ExtensionMetadata.init("test_ext", "Test extension", .FUNCTION);
    try std.testing.expect(std.mem.eql(u8, "test_ext", meta.name));
}

test "extension" {
    const meta = ExtensionMetadata.init("test", "Test", .FUNCTION);
    var ext = Extension.init(meta);
    
    try std.testing.expect(!ext.isLoaded());
    try ext.load();
    try std.testing.expect(ext.isLoaded());
    ext.unload();
    try std.testing.expect(!ext.isLoaded());
}

test "extension registry" {
    const allocator = std.testing.allocator;
    
    var registry = ExtensionRegistry.init(allocator);
    defer registry.deinit(std.testing.allocator);
    
    try std.testing.expectEqual(@as(usize, 0), registry.getLoadedCount());
}

test "function extension" {
    const allocator = std.testing.allocator;
    
    var ext = FunctionExtension.init(allocator, "custom", "Custom functions");
    defer ext.deinit(std.testing.allocator);
    
    try std.testing.expect(std.mem.eql(u8, "custom", ext.base.metadata.name));
}