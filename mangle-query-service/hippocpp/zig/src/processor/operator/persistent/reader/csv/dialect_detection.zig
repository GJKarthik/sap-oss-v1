//! CSV dialect detection.

const std = @import("std");

pub const Dialect = struct {
    delimiter: u8,
    quote: u8,
};

pub fn detect(sample: []const u8) Dialect {
    const comma = std.mem.count(u8, sample, ",");
    const tab = std.mem.count(u8, sample, "\t");
    const pipe = std.mem.count(u8, sample, "|");

    var delimiter: u8 = ',';
    if (tab > comma and tab >= pipe) delimiter = '\t';
    if (pipe > comma and pipe > tab) delimiter = '|';

    return .{ .delimiter = delimiter, .quote = '"' };
}
