//! Extension Manager - Dynamic extension loading and management
//!
//! Purpose:
//! Provides framework for loading, managing, and unloading extensions
//! that add functionality like new functions, storage backends, etc.

const std = @import("std");

// ============================================================================
// Extension Types
// ============================================================================

pub const ExtensionType = enum {
    FUNCTION,      // Adds new functions
    STORAGE,       // Adds storage backend
    FILE_SYSTEM,   // Adds file system support
    SCANNER,       // Adds data scanner
    EXPORT,        // Adds export format
    OPTIMIZER,     // Adds optimizer rules
    ALGORITHM,     // Adds graph algorithms
    AUTH,          // Adds authentication
    UNKNOWN,
};

pub const ExtensionState = enum {
    NOT_LOADED,
    LOADING,
    LOADED,
    ERROR,
    UNLOADING,
};

// ============================================================================
// Extension Info
// ============================================================================

pub const ExtensionInfo = struct {
    name: []const u8,
    version: Version,
    description: []const u8,
    author: []const u8,
    extension_type: ExtensionType,
    dependencies: std.ArrayList([]const u8),
    
    pub const Version = struct {
        major: u16,
        minor: u16,
        patch: u16,
        
        pub fn format(self: Version, allocator: std.mem.Allocator) ![]const u8 {
            return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        }
        
        pub fn isCompatible(self: Version, other: Version) bool {
            return self.major == other.major;
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) ExtensionInfo {
        return .{
            .name = name,
            .version = .{ .major = 1, .minor = 0, .patch = 0 },
            .description = "",
            .author = "",
            .extension_type = .UNKNOWN,
            .dependencies = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *ExtensionInfo) void {
        self.dependencies.deinit();
    }
};

// ============================================================================
// Extension Interface
// ============================================================================

pub const ExtensionVTable = struct {
    load: *const fn (*Extension) anyerror!void,
    unload: *const fn (*Extension) void,
    get_info: *const fn (*const Extension) ExtensionInfo,
};

pub const Extension = struct {
    allocator: std.mem.Allocator,
    info: ExtensionInfo,
    state: ExtensionState = .NOT_LOADED,
    vtable: ?*const ExtensionVTable = null,
    user_data: ?*anyopaque = null,
    load_time: i64 = 0,
    error_message: ?[]const u8 = null,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) Extension {
        return .{
            .allocator = allocator,
            .info = ExtensionInfo.init(allocator, name),
        };
    }
    
    pub fn deinit(self: *Extension) void {
        self.info.deinit();
    }
    
    pub fn load(self: *Extension) !void {
        if (self.state == .LOADED) return;
        
        self.state = .LOADING;
        
        if (self.vtable) |vt| {
            try vt.load(self);
        }
        
        self.state = .LOADED;
        self.load_time = std.time.timestamp();
    }
    
    pub fn unload(self: *Extension) void {
        if (self.state != .LOADED) return;
        
        self.state = .UNLOADING;
        
        if (self.vtable) |vt| {
            vt.unload(self);
        }
        
        self.state = .NOT_LOADED;
    }
    
    pub fn isLoaded(self: *const Extension) bool {
        return self.state == .LOADED;
    }
};

// ============================================================================
// Extension Registry
// ============================================================================

pub const ExtensionRegistry = struct {
    allocator: std.mem.Allocator,
    extensions: std.StringHashMap(Extension),
    search_paths: std.ArrayList([]const u8),
    
    pub fn init(allocator: std.mem.Allocator) ExtensionRegistry {
        return .{
            .allocator = allocator,
            .extensions = std.StringHashMap(Extension).init(allocator),
            .search_paths = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *ExtensionRegistry) void {
        var iter = self.extensions.valueIterator();
        while (iter.next()) |ext| {
            ext.deinit();
        }
        self.extensions.deinit();
        self.search_paths.deinit();
    }
    
    pub fn addSearchPath(self: *ExtensionRegistry, path: []const u8) !void {
        try self.search_paths.append(path);
    }
    
    pub fn register(self: *ExtensionRegistry, extension: Extension) !void {
        try self.extensions.put(extension.info.name, extension);
    }
    
    pub fn get(self: *ExtensionRegistry, name: []const u8) ?*Extension {
        return self.extensions.getPtr(name);
    }
    
    pub fn unregister(self: *ExtensionRegistry, name: []const u8) bool {
        if (self.extensions.getPtr(name)) |ext| {
            ext.unload();
            ext.deinit();
        }
        return self.extensions.remove(name);
    }
    
    pub fn listLoaded(self: *const ExtensionRegistry, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var result = std.ArrayList([]const u8).init(allocator);
        errdefer result.deinit();
        
        var iter = self.extensions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.state == .LOADED) {
                try result.append(entry.key_ptr.*);
            }
        }
        
        return result;
    }
};

// ============================================================================
// Extension Manager
// ============================================================================

pub const ExtensionManager = struct {
    allocator: std.mem.Allocator,
    registry: ExtensionRegistry,
    auto_load: bool = true,
    
    // Built-in extensions
    builtin: std.StringHashMap(ExtensionFactory),
    
    pub const ExtensionFactory = *const fn (std.mem.Allocator) Extension;
    
    pub fn init(allocator: std.mem.Allocator) ExtensionManager {
        var manager = ExtensionManager{
            .allocator = allocator,
            .registry = ExtensionRegistry.init(allocator),
            .builtin = std.StringHashMap(ExtensionFactory).init(allocator),
        };
        
        // Register built-in extensions
        manager.registerBuiltins() catch {};
        
        return manager;
    }
    
    pub fn deinit(self: *ExtensionManager) void {
        self.registry.deinit();
        self.builtin.deinit();
    }
    
    fn registerBuiltins(self: *ExtensionManager) !void {
        try self.builtin.put("json", createJsonExtension);
        try self.builtin.put("parquet", createParquetExtension);
        try self.builtin.put("httpfs", createHttpFsExtension);
    }
    
    /// Load extension by name
    pub fn loadExtension(self: *ExtensionManager, name: []const u8) !void {
        // Check if already loaded
        if (self.registry.get(name)) |ext| {
            if (ext.isLoaded()) return;
            try ext.load();
            return;
        }
        
        // Check built-ins
        if (self.builtin.get(name)) |factory| {
            var ext = factory(self.allocator);
            try ext.load();
            try self.registry.register(ext);
            return;
        }
        
        // Try to find in search paths
        return error.ExtensionNotFound;
    }
    
    /// Unload extension
    pub fn unloadExtension(self: *ExtensionManager, name: []const u8) !void {
        if (self.registry.get(name)) |ext| {
            ext.unload();
        }
    }
    
    /// Get extension
    pub fn getExtension(self: *ExtensionManager, name: []const u8) ?*Extension {
        return self.registry.get(name);
    }
    
    /// List all extensions
    pub fn listExtensions(self: *const ExtensionManager, allocator: std.mem.Allocator) !std.ArrayList(ExtensionInfo) {
        var result = std.ArrayList(ExtensionInfo).init(allocator);
        errdefer result.deinit();
        
        var iter = self.registry.extensions.valueIterator();
        while (iter.next()) |ext| {
            try result.append(ext.info);
        }
        
        return result;
    }
};

// ============================================================================
// Built-in Extension Factories
// ============================================================================

fn createJsonExtension(allocator: std.mem.Allocator) Extension {
    var ext = Extension.init(allocator, "json");
    ext.info.version = .{ .major = 1, .minor = 0, .patch = 0 };
    ext.info.description = "JSON file support";
    ext.info.extension_type = .SCANNER;
    return ext;
}

fn createParquetExtension(allocator: std.mem.Allocator) Extension {
    var ext = Extension.init(allocator, "parquet");
    ext.info.version = .{ .major = 1, .minor = 0, .patch = 0 };
    ext.info.description = "Parquet file support";
    ext.info.extension_type = .SCANNER;
    return ext;
}

fn createHttpFsExtension(allocator: std.mem.Allocator) Extension {
    var ext = Extension.init(allocator, "httpfs");
    ext.info.version = .{ .major = 1, .minor = 0, .patch = 0 };
    ext.info.description = "HTTP/HTTPS file system";
    ext.info.extension_type = .FILE_SYSTEM;
    return ext;
}

// ============================================================================
// Function Extension Helper
// ============================================================================

pub const FunctionExtension = struct {
    base: Extension,
    functions: std.StringHashMap(FunctionDef),
    
    pub const FunctionDef = struct {
        name: []const u8,
        arg_types: std.ArrayList([]const u8),
        return_type: []const u8,
        impl: ?*anyopaque = null,
    };
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) FunctionExtension {
        var ext = FunctionExtension{
            .base = Extension.init(allocator, name),
            .functions = std.StringHashMap(FunctionDef).init(allocator),
        };
        ext.base.info.extension_type = .FUNCTION;
        return ext;
    }
    
    pub fn deinit(self: *FunctionExtension) void {
        var iter = self.functions.valueIterator();
        while (iter.next()) |func| {
            func.arg_types.deinit();
        }
        self.functions.deinit();
        self.base.deinit();
    }
    
    pub fn registerFunction(self: *FunctionExtension, name: []const u8, return_type: []const u8) !*FunctionDef {
        const entry = try self.functions.getOrPut(name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .name = name,
                .arg_types = std.ArrayList([]const u8).init(self.base.allocator),
                .return_type = return_type,
            };
        }
        return entry.value_ptr;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "extension info version" {
    const allocator = std.testing.allocator;
    
    const version = ExtensionInfo.Version{ .major = 1, .minor = 2, .patch = 3 };
    const str = try version.format(allocator);
    defer allocator.free(str);
    
    try std.testing.expectEqualStrings("1.2.3", str);
}

test "extension lifecycle" {
    const allocator = std.testing.allocator;
    
    var ext = Extension.init(allocator, "test");
    defer ext.deinit();
    
    try std.testing.expectEqual(ExtensionState.NOT_LOADED, ext.state);
    
    try ext.load();
    try std.testing.expectEqual(ExtensionState.LOADED, ext.state);
    try std.testing.expect(ext.isLoaded());
    
    ext.unload();
    try std.testing.expectEqual(ExtensionState.NOT_LOADED, ext.state);
}

test "extension registry" {
    const allocator = std.testing.allocator;
    
    var registry = ExtensionRegistry.init(allocator);
    defer registry.deinit();
    
    var ext = Extension.init(allocator, "myext");
    try registry.register(ext);
    
    const found = registry.get("myext");
    try std.testing.expect(found != null);
}

test "extension manager builtins" {
    const allocator = std.testing.allocator;
    
    var manager = ExtensionManager.init(allocator);
    defer manager.deinit();
    
    // Built-in extensions should be available
    try std.testing.expect(manager.builtin.get("json") != null);
    try std.testing.expect(manager.builtin.get("parquet") != null);
}

test "function extension" {
    const allocator = std.testing.allocator;
    
    var func_ext = FunctionExtension.init(allocator, "my_functions");
    defer func_ext.deinit();
    
    const func = try func_ext.registerFunction("my_add", "INT64");
    try func.arg_types.append("INT64");
    try func.arg_types.append("INT64");
    
    try std.testing.expectEqual(@as(usize, 2), func.arg_types.items.len);
}