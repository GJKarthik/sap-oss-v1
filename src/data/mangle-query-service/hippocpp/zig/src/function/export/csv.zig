//! CSV Export Function - Export query results to CSV format
//!
//! Purpose:
//! Provides CSV export functionality for query results,
//! supporting various options like delimiters, quoting, headers.

const std = @import("std");

// ============================================================================
// CSV Export Configuration
// ============================================================================

pub const CSVConfig = struct {
    delimiter: u8 = ',',
    quote: u8 = '"',
    escape: u8 = '"',
    newline: []const u8 = "\n",
    null_string: []const u8 = "",
    include_header: bool = true,
    quote_always: bool = false,
    encoding: Encoding = .UTF8,
    
    pub const Encoding = enum {
        UTF8,
        ASCII,
        LATIN1,
    };
};

// ============================================================================
// CSV Value Type
// ============================================================================

pub const CSVValue = union(enum) {
    null_value: void,
    bool_value: bool,
    int_value: i64,
    float_value: f64,
    string_value: []const u8,
    
    pub fn fromInt(value: i64) CSVValue {
        return .{ .int_value = value };
    }
    
    pub fn fromFloat(value: f64) CSVValue {
        return .{ .float_value = value };
    }
    
    pub fn fromBool(value: bool) CSVValue {
        return .{ .bool_value = value };
    }
    
    pub fn fromString(value: []const u8) CSVValue {
        return .{ .string_value = value };
    }
    
    pub fn nullValue() CSVValue {
        return .{ .null_value = {} };
    }
};

// ============================================================================
// CSV Writer
// ============================================================================

pub const CSVWriter = struct {
    allocator: std.mem.Allocator,
    config: CSVConfig,
    output: std.ArrayList(u8),
    column_count: usize = 0,
    row_count: usize = 0,
    current_column: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator, config: CSVConfig) CSVWriter {
        return .{
            .allocator = allocator,
            .config = config,
            .output = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *CSVWriter) void {
        self.output.deinit();
    }
    
    /// Write header row
    pub fn writeHeader(self: *CSVWriter, columns: []const []const u8) !void {
        if (!self.config.include_header) return;
        
        self.column_count = columns.len;
        
        for (columns, 0..) |col, i| {
            if (i > 0) {
                try self.output.append(self.config.delimiter);
            }
            try self.writeQuotedString(col);
        }
        try self.output.appendSlice(self.config.newline);
    }
    
    /// Write a single value
    pub fn writeValue(self: *CSVWriter, value: CSVValue) !void {
        if (self.current_column > 0) {
            try self.output.append(self.config.delimiter);
        }
        
        switch (value) {
            .null_value => try self.output.appendSlice(self.config.null_string),
            .bool_value => |b| try self.output.appendSlice(if (b) "true" else "false"),
            .int_value => |i| {
                var buf: [32]u8 = undefined;
                const len = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
                try self.output.appendSlice(buf[0..len]);
            },
            .float_value => |f| {
                var buf: [64]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "0";
                try self.output.appendSlice(slice);
            },
            .string_value => |s| try self.writeQuotedString(s),
        }
        
        self.current_column += 1;
    }
    
    /// End current row
    pub fn endRow(self: *CSVWriter) !void {
        try self.output.appendSlice(self.config.newline);
        self.current_column = 0;
        self.row_count += 1;
    }
    
    /// Write a complete row of values
    pub fn writeRow(self: *CSVWriter, values: []const CSVValue) !void {
        for (values) |value| {
            try self.writeValue(value);
        }
        try self.endRow();
    }
    
    fn writeQuotedString(self: *CSVWriter, s: []const u8) !void {
        const needs_quote = self.config.quote_always or self.needsQuoting(s);
        
        if (needs_quote) {
            try self.output.append(self.config.quote);
            for (s) |c| {
                if (c == self.config.quote) {
                    try self.output.append(self.config.escape);
                }
                try self.output.append(c);
            }
            try self.output.append(self.config.quote);
        } else {
            try self.output.appendSlice(s);
        }
    }
    
    fn needsQuoting(self: *const CSVWriter, s: []const u8) bool {
        for (s) |c| {
            if (c == self.config.delimiter or 
                c == self.config.quote or 
                c == '\n' or 
                c == '\r') {
                return true;
            }
        }
        return false;
    }
    
    /// Get the written CSV as a string
    pub fn getOutput(self: *const CSVWriter) []const u8 {
        return self.output.items;
    }
    
    /// Write output to file
    pub fn writeToFile(self: *const CSVWriter, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(self.output.items);
    }
};

// ============================================================================
// CSV Reader (for import)
// ============================================================================

pub const CSVReader = struct {
    allocator: std.mem.Allocator,
    config: CSVConfig,
    data: []const u8,
    position: usize = 0,
    line_number: usize = 1,
    
    pub fn init(allocator: std.mem.Allocator, data: []const u8, config: CSVConfig) CSVReader {
        return .{
            .allocator = allocator,
            .config = config,
            .data = data,
        };
    }
    
    /// Read header row
    pub fn readHeader(self: *CSVReader) !std.ArrayList([]const u8) {
        return try self.readRow();
    }
    
    /// Read a single row
    pub fn readRow(self: *CSVReader) !std.ArrayList([]const u8) {
        var fields = std.ArrayList([]const u8).init(self.allocator);
        errdefer fields.deinit();
        
        while (!self.isAtEnd()) {
            const field = try self.readField();
            try fields.append(field);
            
            if (self.isAtEnd()) break;
            
            const c = self.peek();
            if (c == '\n' or c == '\r') {
                self.skipNewline();
                self.line_number += 1;
                break;
            }
            
            if (c == self.config.delimiter) {
                self.advance();
            }
        }
        
        return fields;
    }
    
    fn readField(self: *CSVReader) ![]const u8 {
        if (self.isAtEnd()) return "";
        
        if (self.peek() == self.config.quote) {
            return try self.readQuotedField();
        }
        
        return self.readUnquotedField();
    }
    
    fn readQuotedField(self: *CSVReader) ![]const u8 {
        self.advance(); // Skip opening quote
        
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();
        
        while (!self.isAtEnd()) {
            const c = self.advance();
            
            if (c == self.config.quote) {
                if (!self.isAtEnd() and self.peek() == self.config.quote) {
                    // Escaped quote
                    self.advance();
                    try result.append(self.config.quote);
                } else {
                    // End of quoted field
                    break;
                }
            } else {
                try result.append(c);
            }
        }
        
        return result.toOwnedSlice();
    }
    
    fn readUnquotedField(self: *CSVReader) []const u8 {
        const start = self.position;
        
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == self.config.delimiter or c == '\n' or c == '\r') {
                break;
            }
            self.advance();
        }
        
        return self.data[start..self.position];
    }
    
    fn isAtEnd(self: *const CSVReader) bool {
        return self.position >= self.data.len;
    }
    
    fn peek(self: *const CSVReader) u8 {
        if (self.isAtEnd()) return 0;
        return self.data[self.position];
    }
    
    fn advance(self: *CSVReader) u8 {
        if (self.isAtEnd()) return 0;
        const c = self.data[self.position];
        self.position += 1;
        return c;
    }
    
    fn skipNewline(self: *CSVReader) void {
        if (self.peek() == '\r') self.advance();
        if (self.peek() == '\n') self.advance();
    }
    
    /// Check if there are more rows
    pub fn hasMoreRows(self: *const CSVReader) bool {
        return !self.isAtEnd();
    }
};

// ============================================================================
// CSV Table Export
// ============================================================================

pub const TableExporter = struct {
    allocator: std.mem.Allocator,
    writer: CSVWriter,
    
    pub fn init(allocator: std.mem.Allocator, config: CSVConfig) TableExporter {
        return .{
            .allocator = allocator,
            .writer = CSVWriter.init(allocator, config),
        };
    }
    
    pub fn deinit(self: *TableExporter) void {
        self.writer.deinit();
    }
    
    /// Export integer column
    pub fn exportIntColumn(self: *TableExporter, name: []const u8, values: []const i64, nulls: ?[]const bool) !void {
        const headers = [_][]const u8{name};
        try self.writer.writeHeader(&headers);
        
        for (values, 0..) |v, i| {
            if (nulls) |n| {
                if (n[i]) {
                    try self.writer.writeValue(CSVValue.nullValue());
                } else {
                    try self.writer.writeValue(CSVValue.fromInt(v));
                }
            } else {
                try self.writer.writeValue(CSVValue.fromInt(v));
            }
            try self.writer.endRow();
        }
    }
    
    pub fn getOutput(self: *const TableExporter) []const u8 {
        return self.writer.getOutput();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "csv writer basic" {
    const allocator = std.testing.allocator;
    
    var writer = CSVWriter.init(allocator, .{});
    defer writer.deinit();
    
    const headers = [_][]const u8{ "id", "name", "value" };
    try writer.writeHeader(&headers);
    
    try writer.writeValue(CSVValue.fromInt(1));
    try writer.writeValue(CSVValue.fromString("Alice"));
    try writer.writeValue(CSVValue.fromFloat(3.14));
    try writer.endRow();
    
    try writer.writeValue(CSVValue.fromInt(2));
    try writer.writeValue(CSVValue.fromString("Bob"));
    try writer.writeValue(CSVValue.nullValue());
    try writer.endRow();
    
    const output = writer.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "id,name,value") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1,Alice,3.14") != null);
}

test "csv writer quoting" {
    const allocator = std.testing.allocator;
    
    var writer = CSVWriter.init(allocator, .{});
    defer writer.deinit();
    
    // String with comma should be quoted
    try writer.writeValue(CSVValue.fromString("hello,world"));
    try writer.endRow();
    
    const output = writer.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"hello,world\"") != null);
}

test "csv reader basic" {
    const allocator = std.testing.allocator;
    
    const csv_data = "id,name\n1,Alice\n2,Bob\n";
    var reader = CSVReader.init(allocator, csv_data, .{});
    
    var header = try reader.readHeader();
    defer header.deinit();
    
    try std.testing.expectEqual(@as(usize, 2), header.items.len);
    try std.testing.expectEqualStrings("id", header.items[0]);
    try std.testing.expectEqualStrings("name", header.items[1]);
    
    var row1 = try reader.readRow();
    defer row1.deinit();
    
    try std.testing.expectEqual(@as(usize, 2), row1.items.len);
    try std.testing.expectEqualStrings("1", row1.items[0]);
    try std.testing.expectEqualStrings("Alice", row1.items[1]);
}

test "csv reader quoted fields" {
    const allocator = std.testing.allocator;
    
    const csv_data = "name\n\"hello,world\"\n\"say \"\"hi\"\"\"\n";
    var reader = CSVReader.init(allocator, csv_data, .{});
    
    var header = try reader.readHeader();
    defer header.deinit();
    
    var row1 = try reader.readRow();
    defer {
        for (row1.items) |item| {
            if (item.len > 0) allocator.free(item);
        }
        row1.deinit();
    }
    
    try std.testing.expectEqualStrings("hello,world", row1.items[0]);
}

test "csv config custom delimiter" {
    const allocator = std.testing.allocator;
    
    var writer = CSVWriter.init(allocator, .{ .delimiter = '\t' });
    defer writer.deinit();
    
    try writer.writeValue(CSVValue.fromInt(1));
    try writer.writeValue(CSVValue.fromInt(2));
    try writer.endRow();
    
    const output = writer.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "1\t2") != null);
}