//! UUID Parquet column reader.

const base = @import("column_reader.zig");

pub const UuidColumnReader = struct {
    inner: base.ColumnReader,

    pub fn init(value_count: u64) UuidColumnReader {
        return .{ .inner = base.ColumnReader.init("uuid", value_count) };
    }
};
