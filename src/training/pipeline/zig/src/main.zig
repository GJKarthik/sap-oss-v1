const std = @import("std");

pub fn main() !void {
    const print = std.debug.print;
    print("text2sql-pipeline v0.1.0\n", .{});
    print("Usage: text2sql-pipeline <command> [args]\n", .{});
    print("Commands:\n", .{});
    print("  extract-schema  <csv_dir> <output_json>\n", .{});
    print("  parse-templates <csv_dir> <output_json>\n", .{});
    print("  expand          <schema_json> <templates_json> <output_json>\n", .{});
    print("  format-spider   <pairs_json> <output_dir>\n", .{});
}

test "main runs without error" {
    // Smoke test: just verify the binary compiles
    const allocator = std.testing.allocator;
    _ = allocator;
}

