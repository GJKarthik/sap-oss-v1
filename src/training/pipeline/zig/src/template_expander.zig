const std = @import("std");
const template_parser = @import("template_parser.zig");
const schema_registry = @import("schema_registry.zig");
const sql_builder = @import("hana_sql_builder.zig");

pub const TrainingPair = struct {
    question: []const u8,
    sql: []const u8,
    domain: []const u8,
    difficulty: []const u8,
    source: []const u8,
};

// ---------------------------------------------------------------------------
// SQL generation — derive a QuerySpec from template metadata and filled values
// ---------------------------------------------------------------------------

/// Infer an aggregate function from a slot name / filled value.
fn inferAgg(slot_name: []const u8, value: []const u8) sql_builder.AggFunc {
    const lower_slot = slot_name;
    const lower_val = value;
    if (std.mem.indexOf(u8, lower_slot, "total") != null or
        std.mem.indexOf(u8, lower_val, "total") != null or
        std.mem.indexOf(u8, lower_val, "sum") != null) return .SUM;
    if (std.mem.indexOf(u8, lower_val, "average") != null or
        std.mem.indexOf(u8, lower_val, "avg") != null) return .AVG;
    if (std.mem.indexOf(u8, lower_val, "count") != null or
        std.mem.indexOf(u8, lower_val, "number of") != null) return .COUNT;
    if (std.mem.indexOf(u8, lower_val, "max") != null or
        std.mem.indexOf(u8, lower_val, "highest") != null) return .MAX;
    if (std.mem.indexOf(u8, lower_val, "min") != null or
        std.mem.indexOf(u8, lower_val, "lowest") != null) return .MIN;
    return .NONE;
}

/// Domain→schema mapping (mirrors the banking data assets).
fn schemaForDomain(domain: []const u8) []const u8 {
    if (std.mem.eql(u8, domain, "treasury")) return "STG_TREASURY";
    if (std.mem.eql(u8, domain, "esg")) return "STG_ESG";
    if (std.mem.eql(u8, domain, "performance")) return "STG_PERFORMANCE";
    return "STG_BANKING";
}

/// Category→table heuristic. Falls back to a generic fact table.
fn tableForCategory(category: []const u8, domain: []const u8) []const u8 {
    // Treasury / BCRS
    if (std.mem.indexOf(u8, category, "ISIN") != null or
        std.mem.indexOf(u8, category, "bond") != null or
        std.mem.indexOf(u8, category, "Bond") != null) return "BOND_POSITIONS";
    if (std.mem.indexOf(u8, category, "Basel") != null or
        std.mem.indexOf(u8, category, "BCRS") != null or
        std.mem.indexOf(u8, category, "REM") != null) return "BSI_REM_FACT";
    if (std.mem.indexOf(u8, category, "FX") != null or
        std.mem.indexOf(u8, category, "forex") != null) return "FX_POSITIONS";
    if (std.mem.indexOf(u8, category, "derivative") != null or
        std.mem.indexOf(u8, category, "swap") != null) return "DERIVATIVE_POSITIONS";
    // ESG
    if (std.mem.indexOf(u8, category, "carbon") != null or
        std.mem.indexOf(u8, category, "emission") != null) return "CARBON_EMISSIONS";
    if (std.mem.indexOf(u8, category, "ESG") != null or
        std.mem.indexOf(u8, category, "score") != null) return "ESG_SCORES";
    // Performance / cost
    if (std.mem.indexOf(u8, category, "cost") != null or
        std.mem.indexOf(u8, category, "Cost") != null) return "COST_CENTER_FACT";
    if (std.mem.indexOf(u8, category, "profit") != null or
        std.mem.indexOf(u8, category, "revenue") != null) return "PROFIT_LOSS_FACT";
    // domain fallbacks
    if (std.mem.eql(u8, domain, "treasury")) return "TREASURY_FACT";
    if (std.mem.eql(u8, domain, "esg")) return "ESG_FACT";
    return "BANKING_FACT";
}

/// Convert a slot name to a plausible HANA column name (upper-snake-case).
fn slotToColumn(allocator: std.mem.Allocator, slot_name: []const u8) ![]u8 {
    // Strip common prefixes: "select ", "input ", "Select ", "Input "
    const trimmed = blk: {
        for (&[_][]const u8{ "select ", "Select ", "input ", "Input " }) |prefix| {
            if (std.mem.startsWith(u8, slot_name, prefix))
                break :blk slot_name[prefix.len..];
        }
        break :blk slot_name;
    };

    // Map common NL phrases to column names
    if (std.mem.eql(u8, trimmed, "metric") or std.mem.eql(u8, trimmed, "measure"))
        return allocator.dupe(u8, "MTM");
    if (std.mem.eql(u8, trimmed, "country") or std.mem.eql(u8, trimmed, "Country"))
        return allocator.dupe(u8, "COUNTRY");
    if (std.mem.eql(u8, trimmed, "currency") or std.mem.eql(u8, trimmed, "Currency"))
        return allocator.dupe(u8, "CURRENCY");
    if (std.mem.eql(u8, trimmed, "ISIN") or std.mem.eql(u8, trimmed, "isin"))
        return allocator.dupe(u8, "ISIN");
    if (std.mem.eql(u8, trimmed, "date") or std.mem.eql(u8, trimmed, "period"))
        return allocator.dupe(u8, "AS_OF_DATE");
    if (std.mem.eql(u8, trimmed, "product") or std.mem.eql(u8, trimmed, "Product"))
        return allocator.dupe(u8, "PRODUCT_TYPE");
    if (std.mem.eql(u8, trimmed, "segment") or std.mem.eql(u8, trimmed, "Segment"))
        return allocator.dupe(u8, "SEGMENT");
    if (std.mem.eql(u8, trimmed, "region") or std.mem.eql(u8, trimmed, "Region"))
        return allocator.dupe(u8, "REGION");
    if (std.mem.eql(u8, trimmed, "category") or std.mem.eql(u8, trimmed, "Category"))
        return allocator.dupe(u8, "CATEGORY");
    if (std.mem.eql(u8, trimmed, "status") or std.mem.eql(u8, trimmed, "Status"))
        return allocator.dupe(u8, "STATUS");

    // Generic: upper-snake from space-separated words
    var out = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |c, idx| {
        out[idx] = if (c == ' ') '_' else std.ascii.toUpper(c);
    }
    return out;
}

/// Generate real HANA SQL for a template + one set of filled-in slot values.
pub fn generateSqlForTemplate(
    allocator: std.mem.Allocator,
    template: template_parser.PromptTemplate,
    slot_values: []const []const u8, // parallel to template.params
) ![]u8 {
    const schema = schemaForDomain(template.domain);
    const table = tableForCategory(template.category, template.domain);
    const alias = "t";

    // Build SELECT columns from SELECT-type slots
    var select_cols: std.ArrayList(sql_builder.SelectColumn) = .empty;
    defer select_cols.deinit(allocator);

    var where_clauses: std.ArrayList(sql_builder.WhereClause) = .empty;
    defer where_clauses.deinit(allocator);

    // group_by_cols holds col-name dupes for plain SELECT dims; freed in defer
    var group_by_cols: std.ArrayList([]u8) = .empty;
    defer {
        for (group_by_cols.items) |g| allocator.free(g);
        group_by_cols.deinit(allocator);
    }

    // col_names holds per-slot column name strings owned here
    var col_names: std.ArrayList([]u8) = .empty;
    defer {
        for (col_names.items) |cn| allocator.free(cn);
        col_names.deinit(allocator);
    }

    // where_values holds the quoted literal strings for WHERE predicates
    var where_values: std.ArrayList([]u8) = .empty;
    defer {
        for (where_values.items) |v| allocator.free(v);
        where_values.deinit(allocator);
    }

    var has_agg = false;

    for (template.params, 0..) |slot, i| {
        const value = if (i < slot_values.len) slot_values[i] else "";
        const col = try slotToColumn(allocator, slot.name);
        try col_names.append(allocator, col);

        if (slot.slot_type == .SELECT) {
            const agg = inferAgg(slot.name, value);
            if (agg != .NONE) has_agg = true;
            try select_cols.append(allocator, .{
                .table_alias = alias,
                .column = col,
                .agg = agg,
                .alias = null,
            });
            if (agg == .NONE) {
                // plain dimension → candidate for GROUP BY
                try group_by_cols.append(allocator, try allocator.dupe(u8, col));
            }
        } else {
            // INPUT slot → WHERE clause with the concrete quoted value
            const quoted = try std.fmt.allocPrint(allocator, "'{s}'", .{value});
            try where_values.append(allocator, quoted);
            try where_clauses.append(allocator, .{
                .column = col,
                .table_alias = alias,
                .op = .EQ,
                .value = quoted,
            });
        }
    }

    // Ensure we always have at least one SELECT column
    if (select_cols.items.len == 0) {
        try select_cols.append(allocator, .{
            .table_alias = alias,
            .column = "*",
            .agg = .NONE,
            .alias = null,
        });
    }

    // Build GROUP BY strings (alias.col) only when aggregates co-exist with plain dims
    var group_by_slice: []const []const u8 = &.{};
    var gb_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (gb_strings.items) |g| allocator.free(g);
        gb_strings.deinit(allocator);
    }
    if (has_agg and group_by_cols.items.len > 0) {
        for (group_by_cols.items) |g| {
            const full = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ alias, g });
            try gb_strings.append(allocator, full);
        }
        group_by_slice = gb_strings.items;
    }

    const spec = sql_builder.QuerySpec{
        .select = select_cols.items,
        .from_table = table,
        .from_schema = schema,
        .from_alias = alias,
        .joins = &.{},
        .where = where_clauses.items,
        .group_by = group_by_slice,
        .order_by = &.{},
        .limit = 100,
    };

    return sql_builder.buildQuery(allocator, spec);
}

// ---------------------------------------------------------------------------
// Difficulty — semantic scoring based on SQL structure
// ---------------------------------------------------------------------------

pub const SqlComplexity = struct {
    join_count: usize,
    agg_count: usize,
    where_count: usize,
    has_group_by: bool,
    param_count: usize,
};

pub fn scoreSqlComplexity(template: template_parser.PromptTemplate) SqlComplexity {
    var agg_count: usize = 0;
    var where_count: usize = 0;
    for (template.params) |slot| {
        if (slot.slot_type == .SELECT) {
            // Assume SELECT slots with measure-like names will become aggregates
            if (std.mem.indexOf(u8, slot.name, "metric") != null or
                std.mem.indexOf(u8, slot.name, "measure") != null or
                std.mem.indexOf(u8, slot.name, "total") != null or
                std.mem.indexOf(u8, slot.name, "count") != null) agg_count += 1;
        } else {
            where_count += 1;
        }
    }
    return .{
        .join_count = 0, // single-table templates have no explicit joins
        .agg_count = agg_count,
        .where_count = where_count,
        .has_group_by = agg_count > 0 and (template.params.len - where_count) > 0,
        .param_count = template.params.len,
    };
}

/// SQL-semantic difficulty: considers aggregates, WHERE predicates, joins, subqueries.
pub fn classifyDifficulty(complexity: SqlComplexity) []const u8 {
    const score: usize =
        complexity.join_count * 3 +
        complexity.agg_count * 2 +
        complexity.where_count +
        (if (complexity.has_group_by) @as(usize, 2) else 0);

    if (score == 0 and complexity.param_count <= 1) return "easy";
    if (score <= 3) return "moderate";
    if (score <= 6) return "hard";
    return "extra_hard";
}

// ---------------------------------------------------------------------------
// Template expansion
// ---------------------------------------------------------------------------

pub fn expandTemplate(
    allocator: std.mem.Allocator,
    template: template_parser.PromptTemplate,
    param_values: []const []const []const u8,
    max_expansions: usize,
) ![]TrainingPair {
    var pairs: std.ArrayList(TrainingPair) = .empty;
    errdefer pairs.deinit(allocator);

    const complexity = scoreSqlComplexity(template);
    const difficulty = classifyDifficulty(complexity);

    if (template.params.len == 0) {
        const sql = try generateSqlForTemplate(allocator, template, &.{});
        try pairs.append(allocator, .{
            .question = try allocator.dupe(u8, template.template_text),
            .sql = sql,
            .domain = try allocator.dupe(u8, template.domain),
            .difficulty = try allocator.dupe(u8, difficulty),
            .source = try allocator.dupe(u8, "template_expansion"),
        });
        return try pairs.toOwnedSlice(allocator);
    }

    var count: usize = 0;
    var indices: [16]usize = .{0} ** 16;
    const n_params = @min(template.params.len, param_values.len);

    while (count < max_expansions) {
        var question_buf: std.ArrayList(u8) = .empty;
        errdefer question_buf.deinit(allocator);
        var last_end: usize = 0;

        // Collect current slot values for SQL generation
        var current_values: [16][]const u8 = undefined;
        for (0..n_params) |p| {
            const slot = template.params[p];
            try question_buf.appendSlice(allocator, template.template_text[last_end..slot.start_pos]);
            const val = if (indices[p] < param_values[p].len) param_values[p][indices[p]] else "";
            try question_buf.appendSlice(allocator, val);
            current_values[p] = val;
            last_end = slot.end_pos;
        }
        if (last_end < template.template_text.len) {
            try question_buf.appendSlice(allocator, template.template_text[last_end..]);
        }

        const sql = try generateSqlForTemplate(allocator, template, current_values[0..n_params]);
        try pairs.append(allocator, .{
            .question = try question_buf.toOwnedSlice(allocator),
            .sql = sql,
            .domain = try allocator.dupe(u8, template.domain),
            .difficulty = try allocator.dupe(u8, difficulty),
            .source = try allocator.dupe(u8, "template_expansion"),
        });

        count += 1;

        // Increment indices (odometer-style)
        var carry = true;
        var p_idx: usize = n_params;
        while (p_idx > 0 and carry) {
            p_idx -= 1;
            indices[p_idx] += 1;
            if (indices[p_idx] >= param_values[p_idx].len) {
                indices[p_idx] = 0;
            } else {
                carry = false;
            }
        }
        if (carry) break;
    }

    return try pairs.toOwnedSlice(allocator);
}

fn freePairs(allocator: std.mem.Allocator, pairs: []TrainingPair) void {
    for (pairs) |p| {
        allocator.free(p.question);
        allocator.free(p.sql);
        allocator.free(p.domain);
        allocator.free(p.difficulty);
        allocator.free(p.source);
    }
    allocator.free(pairs);
}

test "expand template with no params produces real SQL" {
    const allocator = std.testing.allocator;
    const template = template_parser.PromptTemplate{
        .domain = "test",
        .category = "cat",
        .product = "prod",
        .template_text = "Show all bonds",
        .example_text = "Show all bonds",
        .params = &.{},
    };

    const pairs = try expandTemplate(allocator, template, &.{}, 10);
    defer freePairs(allocator, pairs);

    try std.testing.expectEqual(@as(usize, 1), pairs.len);
    try std.testing.expectEqualStrings("Show all bonds", pairs[0].question);
    // SQL must be real — not the old TODO stub
    try std.testing.expect(!std.mem.eql(u8, pairs[0].sql, "-- TODO: generate SQL"));
    try std.testing.expect(std.mem.indexOf(u8, pairs[0].sql, "SELECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, pairs[0].sql, "FROM") != null);
    // no-param template: difficulty should be "easy"
    try std.testing.expectEqualStrings("easy", pairs[0].difficulty);
}

test "expand template with one param produces real SQL" {
    const allocator = std.testing.allocator;
    const params = [_]template_parser.ParamSlot{
        .{ .name = "select country", .slot_type = .SELECT, .start_pos = 5, .end_pos = 21 },
    };
    const template = template_parser.PromptTemplate{
        .domain = "treasury",
        .category = "cat",
        .product = "prod",
        .template_text = "Show [select country] bonds",
        .example_text = "",
        .params = &params,
    };

    const values = [_][]const []const u8{&.{ "US", "UK" }};
    const pairs = try expandTemplate(allocator, template, &values, 10);
    defer freePairs(allocator, pairs);

    try std.testing.expectEqual(@as(usize, 2), pairs.len);
    try std.testing.expectEqualStrings("Show US bonds", pairs[0].question);
    try std.testing.expectEqualStrings("Show UK bonds", pairs[1].question);
    // Each pair must carry real SQL
    try std.testing.expect(std.mem.indexOf(u8, pairs[0].sql, "SELECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, pairs[0].sql, "STG_TREASURY") != null);
    try std.testing.expect(!std.mem.eql(u8, pairs[0].sql, "-- TODO: generate SQL"));
}

test "generateSqlForTemplate ISIN bond query" {
    const allocator = std.testing.allocator;
    const params = [_]template_parser.ParamSlot{
        .{ .name = "select metric", .slot_type = .SELECT, .start_pos = 0, .end_pos = 1 },
        .{ .name = "input ISIN",   .slot_type = .INPUT,  .start_pos = 2, .end_pos = 3 },
    };
    const template = template_parser.PromptTemplate{
        .domain = "treasury",
        .category = "ISIN position",
        .product = "Bonds",
        .template_text = "[select metric] for ISIN [input ISIN]",
        .example_text = "",
        .params = &params,
    };

    const sql = try generateSqlForTemplate(allocator, template, &.{ "total MTM", "US91282CGB19" });
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "STG_TREASURY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "BOND_POSITIONS") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "WHERE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "US91282CGB19") != null);
}

test "generateSqlForTemplate ESG score query" {
    const allocator = std.testing.allocator;
    const params = [_]template_parser.ParamSlot{
        .{ .name = "select score", .slot_type = .SELECT, .start_pos = 0, .end_pos = 1 },
    };
    const template = template_parser.PromptTemplate{
        .domain = "esg",
        .category = "ESG score",
        .product = "ESG",
        .template_text = "[select score] for portfolio",
        .example_text = "",
        .params = &params,
    };

    const sql = try generateSqlForTemplate(allocator, template, &.{"average score"});
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "STG_ESG") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ESG_SCORES") != null);
}

test "classifyDifficulty easy" {
    const c = SqlComplexity{ .join_count = 0, .agg_count = 0, .where_count = 0, .has_group_by = false, .param_count = 0 };
    try std.testing.expectEqualStrings("easy", classifyDifficulty(c));
}

test "classifyDifficulty moderate" {
    const c = SqlComplexity{ .join_count = 0, .agg_count = 1, .where_count = 0, .has_group_by = false, .param_count = 1 };
    try std.testing.expectEqualStrings("moderate", classifyDifficulty(c));
}

test "classifyDifficulty hard" {
    const c = SqlComplexity{ .join_count = 0, .agg_count = 1, .where_count = 2, .has_group_by = true, .param_count = 4 };
    // score = 0 + 2 + 2 + 2 = 6 → hard
    try std.testing.expectEqualStrings("hard", classifyDifficulty(c));
}

test "classifyDifficulty extra_hard with join" {
    const c = SqlComplexity{ .join_count = 2, .agg_count = 1, .where_count = 1, .has_group_by = true, .param_count = 5 };
    // score = 6 + 2 + 1 + 2 = 11 → extra_hard
    try std.testing.expectEqualStrings("extra_hard", classifyDifficulty(c));
}

test "slotToColumn maps known names" {
    const allocator = std.testing.allocator;
    const col = try slotToColumn(allocator, "select country");
    defer allocator.free(col);
    try std.testing.expectEqualStrings("COUNTRY", col);

    const col2 = try slotToColumn(allocator, "input ISIN");
    defer allocator.free(col2);
    try std.testing.expectEqualStrings("ISIN", col2);

    const col3 = try slotToColumn(allocator, "select metric");
    defer allocator.free(col3);
    try std.testing.expectEqualStrings("MTM", col3);
}

test "sql does not contain TODO stub" {
    const allocator = std.testing.allocator;
    const params = [_]template_parser.ParamSlot{
        .{ .name = "select country", .slot_type = .SELECT, .start_pos = 5, .end_pos = 21 },
        .{ .name = "select metric",  .slot_type = .SELECT, .start_pos = 28, .end_pos = 42 },
    };
    const template = template_parser.PromptTemplate{
        .domain = "treasury",
        .category = "Bond",
        .product = "Bonds",
        .template_text = "Show [select country] [select metric]",
        .example_text = "",
        .params = &params,
    };
    const values = [_][]const []const u8{ &.{"US"}, &.{"MTM"} };
    const pairs = try expandTemplate(allocator, template, &values, 5);
    defer freePairs(allocator, pairs);

    for (pairs) |p| {
        try std.testing.expect(!std.mem.eql(u8, p.sql, "-- TODO: generate SQL"));
        try std.testing.expect(std.mem.indexOf(u8, p.sql, "SELECT") != null);
    }
}

