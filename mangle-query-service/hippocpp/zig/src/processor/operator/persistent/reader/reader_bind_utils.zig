//! Reader option parsing utilities.

const std = @import("std");
const types = @import("../persistent_types.zig");

pub fn parseDelimiter(text: []const u8) !u8 {
    if (text.len != 1) return error.InvalidDelimiter;
    return text[0];
}

pub fn parseHeaderFlag(text: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "yes") or std.ascii.eqlIgnoreCase(text, "1")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(text, "false") or std.ascii.eqlIgnoreCase(text, "no") or std.ascii.eqlIgnoreCase(text, "0")) {
        return false;
    }
    return error.InvalidBoolean;
}

pub fn applyOption(options: *types.ReaderOptions, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "delimiter")) {
        options.delimiter = try parseDelimiter(value);
    } else if (std.mem.eql(u8, key, "header")) {
        options.has_header = try parseHeaderFlag(value);
    } else {
        return error.UnknownOption;
    }
}
