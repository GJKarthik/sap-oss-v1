//! Boolean Parquet writer.

const base = @import("column_writer.zig");

pub const BooleanColumnWriter = struct {
    inner: base.ColumnWriter,

    pub fn init() BooleanColumnWriter {
        return .{ .inner = base.ColumnWriter.init("bool") };
    }
};
