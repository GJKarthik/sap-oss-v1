//! String Parquet writer.

const base = @import("column_writer.zig");

pub const StringColumnWriter = struct {
    inner: base.ColumnWriter,

    pub fn init() StringColumnWriter {
        return .{ .inner = base.ColumnWriter.init("string") };
    }
};
