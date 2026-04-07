const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var schema_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var service_id: []const u8 = "generated_service";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--schema") and i + 1 < args.len) {
            i += 1;
            schema_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--service") and i + 1 < args.len) {
            i += 1;
            service_id = args[i];
        }
    }

    if (schema_path == null or output_path == null) {
        std.debug.print("Usage: codegen --schema <path.mg> --output <path.zig> [--service <id>]\n", .{});
        return;
    }

    try generateConnector(allocator, schema_path.?, output_path.?, service_id);
}

fn generateConnector(
    allocator: std.mem.Allocator,
    schema_path: []const u8,
    output_path: []const u8,
    service_id: []const u8,
) !void {
    const schema_content = try std.fs.cwd().readFileAlloc(allocator, schema_path, 1024 * 1024);
    defer allocator.free(schema_content);

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.print(
        \\//! Auto-generated connector from {s}
        \\//! Service: {s}
        \\//! Generated at: {d}
        \\//!
        \\//! DO NOT EDIT MANUALLY
        \\
        \\const std = @import("std");
        \\
        \\
    , .{
        schema_path,
        service_id,
        std.time.timestamp(),
    });

    var decls = std.ArrayListUnmanaged(DeclInfo){};
    defer {
        for (decls.items) |decl| {
            var fields = decl.fields;
            fields.deinit(allocator);
        }
        decls.deinit(allocator);
    }

    try parseDecls(allocator, schema_content, &decls);

    for (decls.items) |decl| {
        try generateStruct(writer, decl, service_id);
    }

    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    try out_file.writeAll(output.items);

    std.debug.print("Generated {s} with {d} structs\n", .{ output_path, decls.items.len });
}

const FieldInfo = struct {
    name: []const u8,
    zig_type: []const u8,
};

const DeclInfo = struct {
    name: []const u8,
    fields: std.ArrayListUnmanaged(FieldInfo),
};

fn parseDecls(allocator: std.mem.Allocator, content: []const u8, decls: *std.ArrayListUnmanaged(DeclInfo)) !void {
    var pos: usize = 0;
    while (pos < content.len) {
        const decl_start = std.mem.indexOfPos(u8, content, pos, "Decl ") orelse break;
        const name_start = decl_start + 5;
        const paren_start = std.mem.indexOfPos(u8, content, name_start, "(") orelse break;
        const name = std.mem.trim(u8, content[name_start..paren_start], " \t\n\r");

        const paren_end = std.mem.indexOfPos(u8, content, paren_start, ").") orelse break;
        const fields_str = content[paren_start + 1 .. paren_end];

        var decl = DeclInfo{
            .name = name,
            .fields = .{},
        };

        var field_iter = std.mem.splitSequence(u8, fields_str, ",");
        while (field_iter.next()) |field_raw| {
            const field_trimmed = std.mem.trim(u8, field_raw, " \t\n\r");
            if (field_trimmed.len == 0) continue;

            var field_part = field_trimmed;
            if (std.mem.indexOf(u8, field_trimmed, "//")) |comment_start| {
                field_part = std.mem.trim(u8, field_trimmed[0..comment_start], " \t\n\r");
            }

            if (std.mem.indexOf(u8, field_part, ":")) |colon| {
                const field_name = std.mem.trim(u8, field_part[0..colon], " \t\n\r");
                const type_str = std.mem.trim(u8, field_part[colon + 1 ..], " \t\n\r");

                try decl.fields.append(allocator, .{
                    .name = field_name,
                    .zig_type = mangleTypeToZig(type_str),
                });
            }
        }

        try decls.append(allocator, decl);
        pos = paren_end + 2;
    }
}

fn mangleTypeToZig(mangle_type: []const u8) []const u8 {
    if (std.mem.eql(u8, mangle_type, "String")) return "[]const u8";
    if (std.mem.eql(u8, mangle_type, "i32")) return "i32";
    if (std.mem.eql(u8, mangle_type, "i64")) return "i64";
    if (std.mem.eql(u8, mangle_type, "f64")) return "f64";
    return "[]const u8";
}

fn generateStruct(writer: anytype, decl: DeclInfo, service_id: []const u8) !void {
    var pascal_name_buf: [256]u8 = undefined;
    var pascal_len: usize = 0;
    var capitalize_next = true;

    for (decl.name) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            pascal_name_buf[pascal_len] = if (capitalize_next) std.ascii.toUpper(c) else c;
            pascal_len += 1;
            capitalize_next = false;
        }
    }
    const pascal_name = pascal_name_buf[0..pascal_len];

    try writer.print("/// {s}\n", .{decl.name});
    try writer.print("pub const {s} = struct {{\n", .{pascal_name});

    for (decl.fields.items) |field| {
        try writer.print("    {s}: {s},\n", .{ field.name, field.zig_type });
    }

    try writer.print(
        \\
        \\    pub fn default() @This() {{
        \\        return .{{
        \\
    , .{});

    for (decl.fields.items) |field| {
        if (std.mem.eql(u8, field.zig_type, "[]const u8")) {
            const val = if (std.mem.eql(u8, field.name, "service_id")) service_id else "";
            try writer.print("            .{s} = \"{s}\",\n", .{ field.name, val });
        } else if (std.mem.eql(u8, field.zig_type, "i32") or std.mem.eql(u8, field.zig_type, "i64")) {
            try writer.print("            .{s} = 0,\n", .{field.name});
        } else if (std.mem.eql(u8, field.zig_type, "f64")) {
            try writer.print("            .{s} = 0.0,\n", .{field.name});
        }
    }

    try writer.writeAll(
        \\        };
        \\    }
        \\};
        \\
        \\
    );
}
