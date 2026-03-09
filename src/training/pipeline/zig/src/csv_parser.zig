const std = @import("std");

pub const CsvRow = struct {
    fields: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CsvRow) void {
        for (self.fields) |f| {
            self.allocator.free(f);
        }
        self.allocator.free(self.fields);
    }
};

pub const CsvParser = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) CsvParser {
        return .{ .allocator = allocator, .data = data, .pos = 0 };
    }

    pub fn nextRow(self: *CsvParser) !?CsvRow {
        if (self.pos >= self.data.len) return null;
        var fields: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (fields.items) |f| self.allocator.free(f);
            fields.deinit(self.allocator);
        }

        while (self.pos < self.data.len) {
            const field = try self.parseField();
            try fields.append(self.allocator, field);

            if (self.pos >= self.data.len) break;
            if (self.data[self.pos] == '\n') {
                self.pos += 1;
                break;
            }
            if (self.data[self.pos] == '\r') {
                self.pos += 1;
                if (self.pos < self.data.len and self.data[self.pos] == '\n') {
                    self.pos += 1;
                }
                break;
            }
            if (self.data[self.pos] == ',') {
                self.pos += 1;
            }
        }

        return CsvRow{
            .fields = try fields.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    fn parseField(self: *CsvParser) ![]const u8 {
        if (self.pos >= self.data.len) return try self.allocator.dupe(u8, "");

        if (self.data[self.pos] == '"') {
            return self.parseQuotedField();
        }
        return self.parseUnquotedField();
    }

    fn parseQuotedField(self: *CsvParser) ![]const u8 {
        self.pos += 1; // skip opening quote
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        while (self.pos < self.data.len) {
            if (self.data[self.pos] == '"') {
                if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '"') {
                    try result.append(self.allocator, '"');
                    self.pos += 2;
                } else {
                    self.pos += 1; // skip closing quote
                    break;
                }
            } else {
                try result.append(self.allocator, self.data[self.pos]);
                self.pos += 1;
            }
        }
        return try result.toOwnedSlice(self.allocator);
    }

    fn parseUnquotedField(self: *CsvParser) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.data.len and
            self.data[self.pos] != ',' and
            self.data[self.pos] != '\n' and
            self.data[self.pos] != '\r')
        {
            self.pos += 1;
        }
        return try self.allocator.dupe(u8, self.data[start..self.pos]);
    }
};

test "parse simple csv row" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "hello,world,42\n");
    var row = (try parser.nextRow()).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(usize, 3), row.fields.len);
    try std.testing.expectEqualStrings("hello", row.fields[0]);
    try std.testing.expectEqualStrings("world", row.fields[1]);
    try std.testing.expectEqualStrings("42", row.fields[2]);
}

test "parse quoted field with comma" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "\"hello, world\",42\n");
    var row = (try parser.nextRow()).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(usize, 2), row.fields.len);
    try std.testing.expectEqualStrings("hello, world", row.fields[0]);
}

test "parse quoted field with escaped quote" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "\"say \"\"hi\"\"\",done\n");
    var row = (try parser.nextRow()).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("say \"hi\"", row.fields[0]);
}

test "parse multiple rows" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "a,b\nc,d\n");
    var row1 = (try parser.nextRow()).?;
    defer row1.deinit();
    var row2 = (try parser.nextRow()).?;
    defer row2.deinit();
    try std.testing.expectEqualStrings("a", row1.fields[0]);
    try std.testing.expectEqualStrings("c", row2.fields[0]);
    const row3 = try parser.nextRow();
    try std.testing.expect(row3 == null);
}

test "parse multiline quoted field" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "\"line1\nline2\",val\n");
    var row = (try parser.nextRow()).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("line1\nline2", row.fields[0]);
    try std.testing.expectEqualStrings("val", row.fields[1]);
}

