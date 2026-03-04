//! Struct Parquet column reader.

const base = @import("column_reader.zig");

pub const StructColumnReader = struct {
    inner: base.ColumnReader,

    pub fn init(value_count: u64) StructColumnReader {
        return .{ .inner = base.ColumnReader.init("struct", value_count) };
    }
};
