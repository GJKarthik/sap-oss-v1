//! String Parquet column reader.

const base = @import("column_reader.zig");

pub const StringColumnReader = struct {
    inner: base.ColumnReader,

    pub fn init(value_count: u64) StringColumnReader {
        return .{ .inner = base.ColumnReader.init("string", value_count) };
    }
};
