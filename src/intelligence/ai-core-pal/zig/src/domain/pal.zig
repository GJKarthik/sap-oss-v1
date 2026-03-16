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
            .categories = .{},
            .algorithms = .{},
        };
    }

    pub fn deinit(self: *Catalog) void {
        self.categories.deinit(self.allocator);
        self.algorithms.deinit(self.allocator);
    }

    pub fn load(self: *Catalog) !void {
        try self.loadCatalogFacts();
        try self.discoverSqlFiles();
    }

    fn loadCatalogFacts(self: *Catalog) !void {
        const facts_path = try std.fs.path.join(self.allocator, &.{ self.sdk_path, "facts", "pal_catalog.mg" });
        defer self.allocator.free(facts_path);

        const file = std.fs.openFileAbsolute(facts_path, .{}) catch |err| {
            std.log.warn("Could not open pal_catalog.mg at {s}: {}", .{ facts_path, err });
            try self.loadDefaultCatalog();
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '/' or trimmed[0] == '#') continue;

            if (std.mem.startsWith(u8, trimmed, "pal_category(")) {
                try self.parseCategoryFact(trimmed);
            } else if (std.mem.startsWith(u8, trimmed, "pal_algorithm(")) {
                try self.parseAlgorithmFact(trimmed);
            } else if (std.mem.startsWith(u8, trimmed, "pal_spec_path(")) {
                self.parseSpecPathFact(trimmed);
            }
        }
    }

    fn parseCategoryFact(self: *Catalog, line: []const u8) !void {
        // pal_category("id", "Name", "Description", count).
        var fields: [4][]const u8 = undefined;
        var count: u32 = 0;
        if (extractQuotedFields(line, &fields, &count)) {
            try self.categories.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, fields[0]),
                .name = try self.allocator.dupe(u8, fields[1]),
                .description = try self.allocator.dupe(u8, fields[2]),
                .count = count,
            });
        }
    }

    fn parseAlgorithmFact(self: *Catalog, line: []const u8) !void {
        // pal_algorithm("id", "Name", "category", "module", "procedure", "stability", "version").
        var fields: [7][]const u8 = undefined;
        if (extractAlgorithmFields(line, &fields)) {
            try self.algorithms.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, fields[0]),
                .name = try self.allocator.dupe(u8, fields[1]),
                .category = try self.allocator.dupe(u8, fields[2]),
                .module = try self.allocator.dupe(u8, fields[3]),
                .procedure = try self.allocator.dupe(u8, fields[4]),
                .stability = try self.allocator.dupe(u8, fields[5]),
                .version = try self.allocator.dupe(u8, fields[6]),
            });
        }
    }

    fn parseSpecPathFact(self: *Catalog, line: []const u8) void {
        // pal_spec_path("id", "path").
        var fields: [2][]const u8 = undefined;
        if (extractNQuotedFields(line, &fields, 2)) {
            for (self.algorithms.items) |*alg| {
                if (std.mem.eql(u8, alg.id, fields[0])) {
                    alg.spec_path = self.allocator.dupe(u8, fields[1]) catch null;
                    break;
                }
            }
        }
    }

    fn discoverSqlFiles(self: *Catalog) !void {
        const sql_base = try std.fs.path.join(self.allocator, &.{ self.sdk_path, "sql" });
        defer self.allocator.free(sql_base);

        for (self.algorithms.items) |*alg| {
            // Derive sql path from spec_path: spec/category/name.odps.yaml -> sql/category/name.sql
            if (alg.spec_path) |sp| {
                if (std.mem.indexOf(u8, sp, "spec/")) |idx| {
                    const rest = sp[idx + 5 ..]; // category/name.odps.yaml
                    if (std.mem.indexOf(u8, rest, ".odps.yaml")) |ext_idx| {
                        const stem = rest[0..ext_idx]; // category/name
                        const sql_rel = std.fmt.allocPrint(self.allocator, "sql/{s}.sql", .{stem}) catch continue;
                        alg.sql_path = sql_rel;
                    }
                }
            }
        }
    }

    fn loadDefaultCatalog(self: *Catalog) !void {
        const default_cats = [_]struct { []const u8, []const u8, []const u8, u32 }{
            .{ "association", "Association", "Association rule mining and sequential patterns", 3 },
            .{ "automl", "AutoML", "Automated machine learning and hyperparameter tuning", 2 },
            .{ "classification", "Classification", "Classification algorithms", 17 },
            .{ "clustering", "Clustering", "Unsupervised clustering and anomaly detection", 21 },
            .{ "miscellaneous", "Miscellaneous", "Utility algorithms", 5 },
            .{ "optimization", "Optimization", "Hyperparameter optimization", 1 },
            .{ "preprocessing", "Preprocessing", "Data preprocessing and dimensionality reduction", 17 },
            .{ "recommender_systems", "Recommender Systems", "Collaborative filtering", 4 },
            .{ "regression", "Regression", "Regression algorithms", 11 },
            .{ "statistics", "Statistics", "Statistical tests and distributions", 24 },
            .{ "text", "Text Processing", "NLP, text mining, embeddings, search", 19 },
            .{ "timeseries", "Time Series", "Forecasting and decomposition", 36 },
            .{ "utility", "Utility", "Pipeline execution and massive interface", 2 },
        };
        for (default_cats) |cat| {
            try self.categories.append(self.allocator, .{
                .id = cat[0],
                .name = cat[1],
                .description = cat[2],
                .count = cat[3],
            });
        }
    }

    // ========================================================================
    // Query Methods
    // ========================================================================

    pub fn listCategories(self: *const Catalog, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        const writer = buf.writer(allocator);

        try writer.writeAll("# SAP HANA PAL Algorithm Catalog\n\n");
        try writer.print("**Total algorithms**: {d} across {d} categories\n\n", .{
            self.algorithms.items.len,
            self.categories.items.len,
        });
        try writer.writeAll("| Category | Count | Description |\n|----------|-------|-------------|\n");
        for (self.categories.items) |cat| {
            try writer.print("| **{s}** | {d} | {s} |\n", .{ cat.name, cat.count, cat.description });
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn listByCategory(self: *const Catalog, allocator: std.mem.Allocator, category: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        const writer = buf.writer(allocator);

        try writer.print("# PAL Algorithms — {s}\n\n", .{category});
        try writer.writeAll("| Algorithm | Procedure | Stability |\n|-----------|-----------|----------|\n");
        for (self.algorithms.items) |alg| {
            if (std.mem.eql(u8, alg.category, category)) {
                try writer.print("| {s} | `{s}` | {s} |\n", .{ alg.name, alg.procedure, alg.stability });
            }
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn searchAlgorithms(self: *const Catalog, allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        const writer = buf.writer(allocator);
        var match_count: u32 = 0;

        try writer.print("# Search results for: \"{s}\"\n\n", .{query});
        for (self.algorithms.items) |alg| {
            if (caseContains(alg.name, query) or caseContains(alg.id, query) or
                caseContains(alg.category, query) or caseContains(alg.procedure, query) or
                caseContains(alg.module, query))
            {
                try writer.print("- **{s}** (`{s}`) — {s} | `{s}`\n", .{
                    alg.name, alg.id, alg.category, alg.procedure,
                });
                match_count += 1;
            }
        }
        if (match_count == 0) {
            try writer.writeAll("No matching algorithms found.\n");
        } else {
            try writer.print("\n**{d} algorithm(s) found.**\n", .{match_count});
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn getAlgorithm(self: *const Catalog, id: []const u8) ?*const Algorithm {
        for (self.algorithms.items) |*alg| {
            if (std.mem.eql(u8, alg.id, id)) return alg;
        }
        return null;
    }

    pub fn findByName(self: *const Catalog, name: []const u8) ?*const Algorithm {
        for (self.algorithms.items) |*alg| {
            if (caseContains(alg.name, name)) return alg;
        }
        return null;
    }

    // ========================================================================
    // File Content Readers
    // ========================================================================

    pub fn readSpec(self: *const Catalog, allocator: std.mem.Allocator, alg: *const Algorithm) ![]const u8 {
        const spec_path = alg.spec_path orelse return error.NoSpecPath;
        const full_path = try std.fs.path.join(allocator, &.{ self.sdk_path, spec_path });
        defer allocator.free(full_path);

        const file = try std.fs.openFileAbsolute(full_path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, 512 * 1024);
    }

    pub fn readSql(self: *const Catalog, allocator: std.mem.Allocator, alg: *const Algorithm) ![]const u8 {
        const sql_path = alg.sql_path orelse return error.NoSqlPath;
        const full_path = try std.fs.path.join(allocator, &.{ self.sdk_path, sql_path });
        defer allocator.free(full_path);

        const file = try std.fs.openFileAbsolute(full_path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, 512 * 1024);
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn caseContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn extractQuotedFields(line: []const u8, out: *[4][]const u8, count: *u32) bool {
    var field_idx: usize = 0;
    var i: usize = 0;
    while (i < line.len and field_idx < 3) : (i += 1) {
        if (line[i] == '"') {
            i += 1;
            const start = i;
            while (i < line.len and line[i] != '"') : (i += 1) {}
            out[field_idx] = line[start..i];
            field_idx += 1;
        }
    }
    // Parse trailing integer before )
    while (i < line.len) : (i += 1) {
        if (line[i] >= '0' and line[i] <= '9') {
            const start = i;
            while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
            count.* = std.fmt.parseInt(u32, line[start..i], 10) catch 0;
            return field_idx == 3;
        }
    }
    return false;
}

fn extractAlgorithmFields(line: []const u8, out: *[7][]const u8) bool {
    var field_idx: usize = 0;
    var i: usize = 0;
    while (i < line.len and field_idx < 7) : (i += 1) {
        if (line[i] == '"') {
            i += 1;
            const start = i;
            while (i < line.len and line[i] != '"') : (i += 1) {}
            out[field_idx] = line[start..i];
            field_idx += 1;
        }
    }
    return field_idx == 7;
}

fn extractNQuotedFields(line: []const u8, out: [][]const u8, n: usize) bool {
    var field_idx: usize = 0;
    var i: usize = 0;
    while (i < line.len and field_idx < n) : (i += 1) {
        if (line[i] == '"') {
            i += 1;
            const start = i;
            while (i < line.len and line[i] != '"') : (i += 1) {}
            out[field_idx] = line[start..i];
            field_idx += 1;
        }
    }
    return field_idx == n;
}

// ============================================================================
// Tests
// ============================================================================

/// Build a small in-memory catalog without touching the filesystem.
fn buildTestCatalog(allocator: std.mem.Allocator) !Catalog {
    var cat = Catalog.init(allocator, "/nonexistent");
    // Add categories manually
    try cat.categories.append(allocator, .{
        .id = "clustering",
        .name = "Clustering",
        .description = "Unsupervised clustering",
        .count = 2,
    });
    try cat.categories.append(allocator, .{
        .id = "timeseries",
        .name = "Time Series",
        .description = "Forecasting",
        .count = 1,
    });
    // Add algorithms manually
    try cat.algorithms.append(allocator, .{
        .id = "kmeans",
        .name = "K-Means",
        .category = "clustering",
        .module = "PAL",
        .procedure = "_SYS_AFL.PAL_KMEANS",
        .stability = "stable",
        .version = "2.0",
    });
    try cat.algorithms.append(allocator, .{
        .id = "dbscan",
        .name = "DBSCAN",
        .category = "clustering",
        .module = "PAL",
        .procedure = "_SYS_AFL.PAL_DBSCAN",
        .stability = "stable",
        .version = "1.0",
    });
    try cat.algorithms.append(allocator, .{
        .id = "arima",
        .name = "ARIMA",
        .category = "timeseries",
        .module = "PAL",
        .procedure = "_SYS_AFL.PAL_ARIMA",
        .stability = "stable",
        .version = "1.0",
    });
    return cat;
}

test "catalog getAlgorithm by id" {
    const allocator = std.testing.allocator;
    var cat = try buildTestCatalog(allocator);
    defer cat.deinit();

    const alg = cat.getAlgorithm("kmeans");
    try std.testing.expect(alg != null);
    try std.testing.expectEqualStrings("K-Means", alg.?.name);
    try std.testing.expectEqualStrings("_SYS_AFL.PAL_KMEANS", alg.?.procedure);
}

test "catalog getAlgorithm returns null for unknown id" {
    const allocator = std.testing.allocator;
    var cat = try buildTestCatalog(allocator);
    defer cat.deinit();

    try std.testing.expect(cat.getAlgorithm("nonexistent") == null);
}

test "catalog findByName case-insensitive" {
    const allocator = std.testing.allocator;
    var cat = try buildTestCatalog(allocator);
    defer cat.deinit();

    const alg = cat.findByName("k-means");
    try std.testing.expect(alg != null);
    try std.testing.expectEqualStrings("kmeans", alg.?.id);
}

test "catalog searchAlgorithms finds by category" {
    const allocator = std.testing.allocator;
    var cat = try buildTestCatalog(allocator);
    defer cat.deinit();

    const result = try cat.searchAlgorithms(allocator, "clustering");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "K-Means") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "DBSCAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ARIMA") == null);
}

test "catalog searchAlgorithms no match" {
    const allocator = std.testing.allocator;
    var cat = try buildTestCatalog(allocator);
    defer cat.deinit();

    const result = try cat.searchAlgorithms(allocator, "xgboost");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "No matching algorithms found.") != null);
}

test "catalog listCategories contains all categories" {
    const allocator = std.testing.allocator;
    var cat = try buildTestCatalog(allocator);
    defer cat.deinit();

    const result = try cat.listCategories(allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Clustering") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Time Series") != null);
}

test "catalog listByCategory filters correctly" {
    const allocator = std.testing.allocator;
    var cat = try buildTestCatalog(allocator);
    defer cat.deinit();

    const result = try cat.listByCategory(allocator, "timeseries");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "ARIMA") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "K-Means") == null);
}

test "catalog default catalog loads 13 categories" {
    const allocator = std.testing.allocator;
    var cat = Catalog.init(allocator, "/nonexistent");
    defer cat.deinit();
    try cat.loadDefaultCatalog();

    try std.testing.expectEqual(@as(usize, 13), cat.categories.items.len);
}
