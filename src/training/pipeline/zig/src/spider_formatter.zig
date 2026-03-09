const std = @import("std");
const template_expander = @import("template_expander.zig");

pub const SpiderEntry = struct {
    db_id: []const u8,
    question: []const u8,
    query: []const u8,
};

pub const SplitResult = struct {
    train: []SpiderEntry,
    dev: []SpiderEntry,
    test_set: []SpiderEntry,
};

/// Converts training pairs to Spider-format entries with 80/10/10 split.
pub fn formatForSpider(
    allocator: std.mem.Allocator,
    pairs: []const template_expander.TrainingPair,
    db_id: []const u8,
) !SplitResult {
    var entries: std.ArrayList(SpiderEntry) = .empty;
    defer entries.deinit(allocator);

    for (pairs) |pair| {
        try entries.append(allocator, .{
            .db_id = try allocator.dupe(u8, db_id),
            .question = try allocator.dupe(u8, pair.question),
            .query = try allocator.dupe(u8, pair.sql),
        });
    }

    const all = try entries.toOwnedSlice(allocator);
    const n = all.len;
    const train_end = (n * 8) / 10;
    const dev_end = train_end + (n * 1) / 10;
    // Ensure we always have at least one item in each split when possible
    const actual_dev_end = if (dev_end == train_end and n > train_end) train_end + 1 else dev_end;

    return SplitResult{
        .train = all[0..train_end],
        .dev = all[train_end..actual_dev_end],
        .test_set = all[actual_dev_end..],
    };
}

/// Emit a slice of SpiderEntry as JSON Lines (one JSON object per line).
pub fn emitJsonLines(entries: []const SpiderEntry, writer: anytype) !void {
    for (entries) |e| {
        try writer.writeAll("{\"db_id\":\"");
        try writeEscaped(writer, e.db_id);
        try writer.writeAll("\",\"question\":\"");
        try writeEscaped(writer, e.question);
        try writer.writeAll("\",\"query\":\"");
        try writeEscaped(writer, e.query);
        try writer.writeAll("\"}\n");
    }
}

fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

test "format pairs for spider with split" {
    const allocator = std.testing.allocator;

    var pairs: [10]template_expander.TrainingPair = undefined;
    for (&pairs, 0..) |*p, i| {
        var buf: [32]u8 = undefined;
        const q = try std.fmt.bufPrint(&buf, "question {d}", .{i});
        p.* = .{
            .question = try allocator.dupe(u8, q),
            .sql = try allocator.dupe(u8, "SELECT 1"),
            .domain = "test",
            .difficulty = "easy",
            .source = "test",
        };
    }
    defer for (&pairs) |*p| {
        allocator.free(p.question);
        allocator.free(p.sql);
    };

    const result = try formatForSpider(allocator, &pairs, "banking_db");
    defer {
        // Free all entries (they share the same underlying slice)
        const all_start = result.train.ptr;
        const total = result.train.len + result.dev.len + result.test_set.len;
        for (all_start[0..total]) |e| {
            allocator.free(e.db_id);
            allocator.free(e.question);
            allocator.free(e.query);
        }
        allocator.free(all_start[0..total]);
    }

    // 80/10/10 split of 10 items = 8/1/1
    try std.testing.expectEqual(@as(usize, 8), result.train.len);
    try std.testing.expectEqual(@as(usize, 1), result.dev.len);
    try std.testing.expectEqual(@as(usize, 1), result.test_set.len);
}

test "emit json lines" {
    const allocator = std.testing.allocator;
    const entries = [_]SpiderEntry{
        .{ .db_id = "db1", .question = "What is X?", .query = "SELECT X FROM T" },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try emitJsonLines(&entries, buf.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"db_id\":\"db1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"question\":\"What is X?\"") != null);
}

