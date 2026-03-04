//! List Parquet writer.

const base = @import("column_writer.zig");

pub const ListColumnWriter = struct {
    inner: base.ColumnWriter,

    pub fn init() ListColumnWriter {
        return .{ .inner = base.ColumnWriter.init("list") };
    }
};
