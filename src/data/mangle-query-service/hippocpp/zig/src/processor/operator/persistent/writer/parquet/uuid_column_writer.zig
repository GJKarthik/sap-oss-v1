//! UUID Parquet writer.

const base = @import("column_writer.zig");

pub const UuidColumnWriter = struct {
    inner: base.ColumnWriter,

    pub fn init() UuidColumnWriter {
        return .{ .inner = base.ColumnWriter.init("uuid") };
    }
};
