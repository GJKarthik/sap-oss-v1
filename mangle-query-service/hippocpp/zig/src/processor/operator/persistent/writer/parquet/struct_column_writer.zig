//! Struct Parquet writer.

const base = @import("column_writer.zig");

pub const StructColumnWriter = struct {
    inner: base.ColumnWriter,

    pub fn init() StructColumnWriter {
        return .{ .inner = base.ColumnWriter.init("struct") };
    }
};
