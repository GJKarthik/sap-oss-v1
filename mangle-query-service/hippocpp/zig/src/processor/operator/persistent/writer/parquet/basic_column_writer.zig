//! Basic Parquet writer implementation for fixed-width values.

const base = @import("column_writer.zig");

pub const BasicColumnWriter = struct {
    inner: base.ColumnWriter,

    pub fn init(name: []const u8) BasicColumnWriter {
        return .{ .inner = base.ColumnWriter.init(name) };
    }
};
