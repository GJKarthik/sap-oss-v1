const std = @import("std");
const csv_parser = @import("csv_parser.zig");

pub const SlotType = enum { SELECT, INPUT };

pub const ParamSlot = struct {
    name: []const u8,
    slot_type: SlotType,
    start_pos: usize,
    end_pos: usize,
};

pub const PromptTemplate = struct {
    domain: []const u8,
    category: []const u8,
    product: []const u8,
    template_text: []const u8,
    example_text: []const u8,
    params: []const ParamSlot,
};

pub fn extractParamSlots(allocator: std.mem.Allocator, template: []const u8) ![]ParamSlot {
    var slots: std.ArrayList(ParamSlot) = .empty;
    errdefer {
        for (slots.items) |s| allocator.free(s.name);
        slots.deinit(allocator);
    }

    var i: usize = 0;
    while (i < template.len) {
        const open_pos = blk: {
            const ob = std.mem.indexOfPos(u8, template, i, "[");
            const oa = std.mem.indexOfPos(u8, template, i, "<");
            if (ob != null and oa != null) break :blk @min(ob.?, oa.?);
            if (ob != null) break :blk ob.?;
            if (oa != null) break :blk oa.?;
            break;
        };

        const close_char: u8 = if (template[open_pos] == '[') ']' else '>';
        const close_pos = std.mem.indexOfPos(u8, template, open_pos + 1, &.{close_char}) orelse break;

        const slot_text = template[open_pos + 1 .. close_pos];
        const slot_type: SlotType = if (std.mem.startsWith(u8, slot_text, "select") or
            std.mem.startsWith(u8, slot_text, "Select"))
            .SELECT
        else
            .INPUT;

        try slots.append(allocator, .{
            .name = try allocator.dupe(u8, slot_text),
            .slot_type = slot_type,
            .start_pos = open_pos,
            .end_pos = close_pos + 1,
        });

        i = close_pos + 1;
    }

    return try slots.toOwnedSlice(allocator);
}

pub fn parseTemplatesCsv(
    allocator: std.mem.Allocator,
    csv_data: []const u8,
    domain: []const u8,
) ![]PromptTemplate {
    var parser = csv_parser.CsvParser.init(allocator, csv_data);
    var templates: std.ArrayList(PromptTemplate) = .empty;
    errdefer templates.deinit(allocator);

    // Skip header
    if (try parser.nextRow()) |row_val| {
        var hdr = row_val;
        hdr.deinit();
    } else return try templates.toOwnedSlice(allocator);

    while (try parser.nextRow()) |row_val| {
        var row = row_val;
        defer row.deinit();
        if (row.fields.len < 4) continue;

        const template_text = row.fields[2];
        if (template_text.len == 0) continue;
        const params = try extractParamSlots(allocator, template_text);

        try templates.append(allocator, .{
            .domain = try allocator.dupe(u8, domain),
            .category = try allocator.dupe(u8, row.fields[0]),
            .product = try allocator.dupe(u8, row.fields[1]),
            .template_text = try allocator.dupe(u8, template_text),
            .example_text = try allocator.dupe(u8, if (row.fields.len > 3) row.fields[3] else ""),
            .params = params,
        });
    }

    return try templates.toOwnedSlice(allocator);
}

test "extract param slots from bracket template" {
    const allocator = std.testing.allocator;
    const slots = try extractParamSlots(
        allocator,
        "Provide total [select metric] for ISIN [input ISIN] in [select country] country.",
    );
    defer {
        for (slots) |s| allocator.free(s.name);
        allocator.free(slots);
    }

    try std.testing.expectEqual(@as(usize, 3), slots.len);
    try std.testing.expectEqualStrings("select metric", slots[0].name);
    try std.testing.expectEqual(SlotType.SELECT, slots[0].slot_type);
    try std.testing.expectEqualStrings("input ISIN", slots[1].name);
    try std.testing.expectEqual(SlotType.INPUT, slots[1].slot_type);
}

test "extract param slots from angle bracket template" {
    const allocator = std.testing.allocator;
    const slots = try extractParamSlots(
        allocator,
        "<select measure> and <select measure> for booking location asean",
    );
    defer {
        for (slots) |s| allocator.free(s.name);
        allocator.free(slots);
    }

    try std.testing.expectEqual(@as(usize, 2), slots.len);
    try std.testing.expectEqualStrings("select measure", slots[0].name);
}

test "parse treasury template csv" {
    const allocator = std.testing.allocator;
    const csv_data =
        \\category,product,Prompt Template,Original_Prompt (Example)
        \\ISIN position,Bonds,Provide total [select metric] for ISIN [input ISIN],Provide total MtM for ISIN US91282CGB19
    ;

    const templates = try parseTemplatesCsv(allocator, csv_data, "treasury");
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

    try std.testing.expectEqual(@as(usize, 1), templates.len);
    try std.testing.expectEqualStrings("treasury", templates[0].domain);
    try std.testing.expectEqualStrings("ISIN position", templates[0].category);
    try std.testing.expectEqual(@as(usize, 2), templates[0].params.len);
}

