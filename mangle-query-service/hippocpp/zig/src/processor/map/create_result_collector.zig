//! Auto-generated map module for logical-to-physical translation.

const plan_mapper = @import("plan_mapper.zig");

pub fn mapSpec() plan_mapper.MapOpSpec {
    return plan_mapper.make(
        "create_result_collector",
        "processor/operator/result_collector.zig",
        true,
        true,
    );
}
