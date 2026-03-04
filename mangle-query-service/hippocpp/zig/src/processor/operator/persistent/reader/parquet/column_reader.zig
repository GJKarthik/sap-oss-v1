//! Base Parquet column reader interfaces.

const std = @import("std");

pub const ColumnChunk = struct {
    name: []const u8,
    value_count: u64,
};

pub const ColumnReader = struct {
    chunk: ColumnChunk,

    pub fn init(name: []const u8, value_count: u64) ColumnReader {
        return .{ .chunk = .{ .name = name, .value_count = value_count } };
    }

    pub fn remaining(self: *const ColumnReader, consumed: u64) u64 {
        return self.chunk.value_count -| consumed;
    }
};
