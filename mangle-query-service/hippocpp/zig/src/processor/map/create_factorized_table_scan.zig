//! Auto-generated map module for logical-to-physical translation.

const plan_mapper = @import("plan_mapper.zig");

pub fn mapSpec() plan_mapper.MapOpSpec {
    return plan_mapper.make(
        "create_factorized_table_scan",
        "processor/result_set.zig",
        true,
        false,
    );
}
