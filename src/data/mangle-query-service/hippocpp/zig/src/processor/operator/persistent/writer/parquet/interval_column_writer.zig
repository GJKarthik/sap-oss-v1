//! Interval Parquet writer.

const base = @import("column_writer.zig");

pub const IntervalColumnWriter = struct {
    inner: base.ColumnWriter,

    pub fn init() IntervalColumnWriter {
        return .{ .inner = base.ColumnWriter.init("interval") };
    }
};
