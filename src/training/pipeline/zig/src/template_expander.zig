const std = @import("std");
const template_parser = @import("template_parser.zig");
const schema_registry = @import("schema_registry.zig");

pub const TrainingPair = struct {
    question: []const u8,
    sql: []const u8,
    domain: []const u8,
    difficulty: []const u8,
    source: []const u8,
};

pub fn expandTemplate(
    allocator: std.mem.Allocator,
    template: template_parser.PromptTemplate,
    param_values: []const []const []const u8,
    max_expansions: usize,
) ![]TrainingPair {
    var pairs: std.ArrayList(TrainingPair) = .empty;
    errdefer pairs.deinit(allocator);

    if (template.params.len == 0) {
        try pairs.append(allocator, .{
            .question = try allocator.dupe(u8, template.template_text),
            .sql = try allocator.dupe(u8, "-- TODO: generate SQL"),
            .domain = try allocator.dupe(u8, template.domain),
            .difficulty = try allocator.dupe(u8, "easy"),
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
        for (0..n_params) |p| {
            const slot = template.params[p];
            try question_buf.appendSlice(allocator, template.template_text[last_end..slot.start_pos]);
            if (indices[p] < param_values[p].len) {
                try question_buf.appendSlice(allocator, param_values[p][indices[p]]);
            }
            last_end = slot.end_pos;
        }
        if (last_end < template.template_text.len) {
            try question_buf.appendSlice(allocator, template.template_text[last_end..]);
        }

        try pairs.append(allocator, .{
            .question = try question_buf.toOwnedSlice(allocator),
            .sql = try allocator.dupe(u8, "-- TODO: generate SQL"),
            .domain = try allocator.dupe(u8, template.domain),
            .difficulty = try allocator.dupe(u8, classifyDifficulty(n_params)),
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

fn classifyDifficulty(param_count: usize) []const u8 {
    if (param_count <= 1) return "easy";
    if (param_count <= 3) return "moderate";
    return "hard";
}

test "expand template with no params" {
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
    defer {
        for (pairs) |p| {
            allocator.free(p.question);
            allocator.free(p.sql);
            allocator.free(p.domain);
            allocator.free(p.difficulty);
            allocator.free(p.source);
        }
        allocator.free(pairs);
    }

    try std.testing.expectEqual(@as(usize, 1), pairs.len);
    try std.testing.expectEqualStrings("Show all bonds", pairs[0].question);
    try std.testing.expectEqualStrings("easy", pairs[0].difficulty);
}

test "expand template with one param" {
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
    defer {
        for (pairs) |p| {
            allocator.free(p.question);
            allocator.free(p.sql);
            allocator.free(p.domain);
            allocator.free(p.difficulty);
            allocator.free(p.source);
        }
        allocator.free(pairs);
    }

    try std.testing.expectEqual(@as(usize, 2), pairs.len);
    try std.testing.expectEqualStrings("Show US bonds", pairs[0].question);
    try std.testing.expectEqualStrings("Show UK bonds", pairs[1].question);
}

