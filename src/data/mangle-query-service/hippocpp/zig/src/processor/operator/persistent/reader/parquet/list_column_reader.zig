//! List Parquet column reader.

const base = @import("column_reader.zig");

pub const ListColumnReader = struct {
    inner: base.ColumnReader,

    pub fn init(value_count: u64) ListColumnReader {
        return .{ .inner = base.ColumnReader.init("list", value_count) };
    }
};
