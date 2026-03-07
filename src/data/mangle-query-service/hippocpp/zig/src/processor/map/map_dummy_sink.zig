//! Auto-generated map module for logical-to-physical translation.

const plan_mapper = @import("plan_mapper.zig");

pub fn mapSpec() plan_mapper.MapOpSpec {
    return plan_mapper.make(
        "map_dummy_sink",
        "processor/operator/sink_operator.zig",
        false,
        true,
    );
}
