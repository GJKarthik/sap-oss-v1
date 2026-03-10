const std = @import("std");
const schema_extractor = @import("schema_extractor.zig");
const schema_registry = @import("schema_registry.zig");
const template_parser = @import("template_parser.zig");
const template_expander = @import("template_expander.zig");
const spider_formatter = @import("spider_formatter.zig");
const json_emitter = @import("json_emitter.zig");

const VERSION = "0.1.0";

fn printUsage() void {
    const print = std.debug.print;
    print("text2sql-pipeline v{s}\n", .{VERSION});
    print("Usage: text2sql-pipeline <command> [args]\n\n", .{});
    print("Commands:\n", .{});
    print("  extract-schema  <staging_csv> <output_json>\n", .{});
    print("  parse-templates <templates_csv> <domain> <output_json>\n", .{});
    print("  expand          <templates_json> <output_pairs_json> [max_expansions]\n", .{});
    print("  format-spider   <pairs_json> <output_dir> [db_id]\n", .{});
    print("\nExample (full pipeline):\n", .{});
    print("  text2sql-pipeline extract-schema staging/schema.csv output/schema.json\n", .{});
    print("  text2sql-pipeline parse-templates data/templates.csv treasury output/templates.json\n", .{});
    print("  text2sql-pipeline expand output/templates.json output/pairs.json 500\n", .{});
    print("  text2sql-pipeline format-spider output/pairs.json output/spider banking_db\n", .{});
}

// ---------------------------------------------------------------------------
// Command handlers
// ---------------------------------------------------------------------------

fn cmdExtractSchema(allocator: std.mem.Allocator, args: [][]u8) !void {
    if (args.len < 2) {
        std.debug.print("extract-schema: expected <staging_csv> <output_json>\n", .{});
        return error.InvalidArgs;
    }
    const csv_path = args[0];
    const out_path = args[1];

    const csv_data = try std.fs.cwd().readFileAlloc(allocator, csv_path, 256 * 1024 * 1024);
    defer allocator.free(csv_data);

    var registry = schema_registry.SchemaRegistry.init(allocator);
    defer registry.deinit();

    try schema_extractor.extractFromStagingCsv(allocator, csv_data, &registry);

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try json_emitter.emitSchemaJson(&registry, out_file.writer());

    std.debug.print("extract-schema: {d} tables written to {s}\n", .{ registry.tableCount(), out_path });
}

fn cmdParseTemplates(allocator: std.mem.Allocator, args: [][]u8) !void {
    if (args.len < 3) {
        std.debug.print("parse-templates: expected <templates_csv> <domain> <output_json>\n", .{});
        return error.InvalidArgs;
    }
    const csv_path = args[0];
    const domain = args[1];
    const out_path = args[2];

    const csv_data = try std.fs.cwd().readFileAlloc(allocator, csv_path, 64 * 1024 * 1024);
    defer allocator.free(csv_data);

    const templates = try template_parser.parseTemplatesCsv(allocator, csv_data, domain);
    defer {
        for (templates) |t| {
            allocator.free(t.domain);
            allocator.free(t.category);
            allocator.free(t.product);
            allocator.free(t.template_text);
            allocator.free(t.example_text);
            for (t.params) |p| allocator.free(p.name);
            allocator.free(t.params);
        }
        allocator.free(templates);
    }

    // Emit JSON array of templates
    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    const w = out_file.writer();
    try w.writeAll("[");
    for (templates, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"domain\":\"");
        try writeJsonEscapedMain(w, t.domain);
        try w.writeAll("\",\"category\":\"");
        try writeJsonEscapedMain(w, t.category);
        try w.writeAll("\",\"product\":\"");
        try writeJsonEscapedMain(w, t.product);
        try w.writeAll("\",\"template\":\"");
        try writeJsonEscapedMain(w, t.template_text);
        try w.writeAll("\",\"param_count\":");
        try w.print("{d}", .{t.params.len});
        try w.writeAll("}");
    }
    try w.writeAll("]");

    std.debug.print("parse-templates: {d} templates written to {s}\n", .{ templates.len, out_path });
}

fn cmdExpand(allocator: std.mem.Allocator, args: [][]u8) !void {
    if (args.len < 2) {
        std.debug.print("expand: expected <templates_csv> <output_pairs_json> [max_expansions]\n", .{});
        return error.InvalidArgs;
    }
    const templates_csv_path = args[0];
    const out_path = args[1];
    const max_expansions: usize = if (args.len >= 3)
        std.fmt.parseInt(usize, args[2], 10) catch 500
    else
        500;

    // templates_csv_path is treated as the raw CSV (domain inferred from filename)
    const csv_data = try std.fs.cwd().readFileAlloc(allocator, templates_csv_path, 64 * 1024 * 1024);
    defer allocator.free(csv_data);

    // Infer domain from filename (e.g. "treasury_templates.csv" → "treasury")
    const basename = std.fs.path.basename(templates_csv_path);
    const domain: []const u8 = blk: {
        if (std.mem.indexOf(u8, basename, "treasury") != null) break :blk "treasury";
        if (std.mem.indexOf(u8, basename, "esg") != null) break :blk "esg";
        if (std.mem.indexOf(u8, basename, "performance") != null) break :blk "performance";
        break :blk "banking";
    };

    const templates = try template_parser.parseTemplatesCsv(allocator, csv_data, domain);
    defer {
        for (templates) |t| {
            allocator.free(t.domain);
            allocator.free(t.category);
            allocator.free(t.product);
            allocator.free(t.template_text);
            allocator.free(t.example_text);
            for (t.params) |p| allocator.free(p.name);
            allocator.free(t.params);
        }
        allocator.free(templates);
    }

    var all_pairs: std.ArrayList(template_expander.TrainingPair) = .empty;
    defer {
        for (all_pairs.items) |p| {
            allocator.free(p.question);
            allocator.free(p.sql);
            allocator.free(p.domain);
            allocator.free(p.difficulty);
            allocator.free(p.source);
        }
        all_pairs.deinit(allocator);
    }

    for (templates) |t| {
        // No param_values from file: expand with empty values so SQL scaffold is generated
        const pairs = try template_expander.expandTemplate(allocator, t, &.{}, max_expansions);
        defer allocator.free(pairs);
        for (pairs) |p| try all_pairs.append(allocator, p);
    }

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    const w = out_file.writer();
    try w.writeAll("[");
    for (all_pairs.items, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"question\":\"");
        try writeJsonEscapedMain(w, p.question);
        try w.writeAll("\",\"sql\":\"");
        try writeJsonEscapedMain(w, p.sql);
        try w.writeAll("\",\"domain\":\"");
        try writeJsonEscapedMain(w, p.domain);
        try w.writeAll("\",\"difficulty\":\"");
        try writeJsonEscapedMain(w, p.difficulty);
        try w.writeAll("\"}");
    }
    try w.writeAll("]");

    std.debug.print("expand: {d} pairs written to {s}\n", .{ all_pairs.items.len, out_path });
}

fn cmdFormatSpider(allocator: std.mem.Allocator, args: [][]u8) !void {
    if (args.len < 2) {
        std.debug.print("format-spider: expected <pairs_json> <output_dir> [db_id]\n", .{});
        return error.InvalidArgs;
    }
    const pairs_json_path = args[0];
    const out_dir_path = args[1];
    const db_id = if (args.len >= 3) args[2] else "banking_db";

    // Parse the pairs JSON produced by `expand`
    const json_data = try std.fs.cwd().readFileAlloc(allocator, pairs_json_path, 256 * 1024 * 1024);
    defer allocator.free(json_data);

    var pairs: std.ArrayList(template_expander.TrainingPair) = .empty;
    defer {
        for (pairs.items) |p| {
            allocator.free(p.question);
            allocator.free(p.sql);
            allocator.free(p.domain);
            allocator.free(p.difficulty);
            allocator.free(p.source);
        }
        pairs.deinit(allocator);
    }

    // Minimal JSON array parser: extract "question" and "sql" fields per object
    var pos: usize = 0;
    while (pos < json_data.len) {
        // Find next {"question":"
        const q_start_marker = "\"question\":\"";
        const q_pos = std.mem.indexOfPos(u8, json_data, pos, q_start_marker) orelse break;
        const q_val_start = q_pos + q_start_marker.len;
        const q_val_end = std.mem.indexOfPos(u8, json_data, q_val_start, "\"") orelse break;

        const sql_marker = "\"sql\":\"";
        const s_pos = std.mem.indexOfPos(u8, json_data, q_val_end, sql_marker) orelse break;
        const s_val_start = s_pos + sql_marker.len;
        const s_val_end = std.mem.indexOfPos(u8, json_data, s_val_start, "\"") orelse break;

        const domain_marker = "\"domain\":\"";
        const d_pos = std.mem.indexOfPos(u8, json_data, s_val_end, domain_marker) orelse {
            pos = s_val_end + 1;
            continue;
        };
        const d_val_start = d_pos + domain_marker.len;
        const d_val_end = std.mem.indexOfPos(u8, json_data, d_val_start, "\"") orelse break;

        const diff_marker = "\"difficulty\":\"";
        const df_pos = std.mem.indexOfPos(u8, json_data, d_val_end, diff_marker) orelse {
            pos = d_val_end + 1;
            continue;
        };
        const df_val_start = df_pos + diff_marker.len;
        const df_val_end = std.mem.indexOfPos(u8, json_data, df_val_start, "\"") orelse break;

        try pairs.append(allocator, .{
            .question = try allocator.dupe(u8, json_data[q_val_start..q_val_end]),
            .sql = try allocator.dupe(u8, json_data[s_val_start..s_val_end]),
            .domain = try allocator.dupe(u8, json_data[d_val_start..d_val_end]),
            .difficulty = try allocator.dupe(u8, json_data[df_val_start..df_val_end]),
            .source = try allocator.dupe(u8, "template_expansion"),
        });

        pos = df_val_end + 1;
    }

    // Create output directory
    std.fs.cwd().makePath(out_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const split = try spider_formatter.formatForSpider(allocator, pairs.items, db_id);
    // Compute total for deallocation
    const total = split.train.len + split.dev.len + split.test_set.len;
    defer {
        for (split.train.ptr[0..total]) |e| {
            allocator.free(e.db_id);
            allocator.free(e.question);
            allocator.free(e.query);
        }
        allocator.free(split.train.ptr[0..total]);
    }

    // Write train.jsonl
    {
        const train_path = try std.fmt.allocPrint(allocator, "{s}/train.jsonl", .{out_dir_path});
        defer allocator.free(train_path);
        const f = try std.fs.cwd().createFile(train_path, .{});
        defer f.close();
        try spider_formatter.emitJsonLines(split.train, f.writer());
    }
    // Write dev.jsonl
    {
        const dev_path = try std.fmt.allocPrint(allocator, "{s}/dev.jsonl", .{out_dir_path});
        defer allocator.free(dev_path);
        const f = try std.fs.cwd().createFile(dev_path, .{});
        defer f.close();
        try spider_formatter.emitJsonLines(split.dev, f.writer());
    }
    // Write test.jsonl
    {
        const test_path = try std.fmt.allocPrint(allocator, "{s}/test.jsonl", .{out_dir_path});
        defer allocator.free(test_path);
        const f = try std.fs.cwd().createFile(test_path, .{});
        defer f.close();
        try spider_formatter.emitJsonLines(split.test_set, f.writer());
    }

    std.debug.print(
        "format-spider: train={d} dev={d} test={d} → {s}/\n",
        .{ split.train.len, split.dev.len, split.test_set.len, out_dir_path },
    );
}

fn writeJsonEscapedMain(writer: anytype, s: []const u8) !void {
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

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    if (raw_args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const command = raw_args[1];
    const rest = raw_args[2..];

    if (std.mem.eql(u8, command, "extract-schema")) {
        try cmdExtractSchema(allocator, rest);
    } else if (std.mem.eql(u8, command, "parse-templates")) {
        try cmdParseTemplates(allocator, rest);
    } else if (std.mem.eql(u8, command, "expand")) {
        try cmdExpand(allocator, rest);
    } else if (std.mem.eql(u8, command, "format-spider")) {
        try cmdFormatSpider(allocator, rest);
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        std.debug.print("text2sql-pipeline v{s}\n", .{VERSION});
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

test "main compiles and all modules importable" {
    const allocator = std.testing.allocator;
    _ = allocator;
    // Verify all handler modules are reachable at comptime
    _ = schema_extractor;
    _ = schema_registry;
    _ = template_parser;
    _ = template_expander;
    _ = spider_formatter;
    _ = json_emitter;
}

test "writeJsonEscapedMain escapes special chars" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try writeJsonEscapedMain(buf.writer(allocator), "say \"hello\"\nworld");
    try std.testing.expectEqualStrings("say \\\"hello\\\"\\nworld", buf.items);
}

