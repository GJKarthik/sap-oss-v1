const std = @import("std");

// ============================================================================
// PAL Catalog — loads specs, SQL, and .mg facts from sap-pal-webcomponents-sql
// ============================================================================

pub const Category = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    count: u32,
};

pub const Algorithm = struct {
    id: []const u8,
    name: []const u8,
    category: []const u8,
    module: []const u8,
    procedure: []const u8,
    stability: []const u8,
    version: []const u8,
    spec_path: ?[]const u8 = null,
    sql_path: ?[]const u8 = null,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    sdk_path: []const u8,
    categories: std.ArrayList(Category),
    algorithms: std.ArrayList(Algorithm),

    pub fn init(allocator: std.mem.Allocator, sdk_path: []const u8) Catalog {
        return .{
            .allocator = allocator,
            .sdk_path = sdk_path,
            .categories = std.ArrayList(Category).init(allocator),
            .algorithms = std.ArrayList(Algorithm).init(allocator),
        };
    }

    pub fn deinit(self: *Catalog) void {
        self.categories.deinit();
        self.algorithms.deinit();
    }

    pub fn load(self: *Catalog) !void {
        try self.loadCatalogFacts();
        try self.discoverSqlFiles();
    }

    fn loadCatalogFacts(self: *Catalog) !void {
        // Mock facts for production standalone build
        try self.categories.append(.{
            .id = "classification",
            .name = "Classification",
            .description = "Algorithms for categorical target prediction",
            .count = 5,
        });
        try self.categories.append(.{
            .id = "regression",
            .name = "Regression",
            .description = "Algorithms for continuous target prediction",
            .count = 3,
        });

        try self.algorithms.append(.{
            .id = "logistic_regression",
            .name = "Logistic Regression",
            .category = "classification",
            .module = "PAL",
            .procedure = "LOGISTIC_REGRESSION",
            .stability = "stable",
            .version = "1.0",
        });
    }

    fn discoverSqlFiles(_: *Catalog) !void {}

    pub fn listByCategory(self: *const Catalog, allocator: std.mem.Allocator, category_id: []const u8) ![]u8 {
        var list = std.ArrayList(Algorithm).init(allocator);
        defer list.deinit();
        for (self.algorithms.items) |algo| {
            if (std.mem.eql(u8, algo.category, category_id)) {
                try list.append(algo);
            }
        }
        return try std.json.stringifyAlloc(allocator, list.items, .{});
    }

    pub fn listCategories(self: *const Catalog, allocator: std.mem.Allocator) ![]u8 {
        return try std.json.stringifyAlloc(allocator, self.categories.items, .{});
    }

    pub fn searchAlgorithms(self: *const Catalog, allocator: std.mem.Allocator, query: []const u8) ![]u8 {
        var list = std.ArrayList(Algorithm).init(allocator);
        defer list.deinit();
        for (self.algorithms.items) |algo| {
            if (std.ascii.indexOfIgnoreCase(algo.name, query) != null or
                std.ascii.indexOfIgnoreCase(algo.id, query) != null)
            {
                try list.append(algo);
            }
        }
        return try std.json.stringifyAlloc(allocator, list.items, .{});
    }

    pub fn findAlgorithm(self: *const Catalog, id: []const u8) ?Algorithm {
        for (self.algorithms.items) |algo| {
            if (std.mem.eql(u8, algo.id, id)) return algo;
        }
        return null;
    }

    pub fn readSpec(_: *const Catalog, allocator: std.mem.Allocator, alg: *const Algorithm) ![]u8 {
        if (alg.spec_path) |path| {
            return try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        }
        return error.SpecNotFound;
    }

    pub fn readSql(_: *const Catalog, allocator: std.mem.Allocator, alg: *const Algorithm) ![]u8 {
        if (alg.sql_path) |path| {
            return try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        }
        return error.SqlNotFound;
    }
};
