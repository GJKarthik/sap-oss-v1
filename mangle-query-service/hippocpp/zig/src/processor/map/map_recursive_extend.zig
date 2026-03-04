//! Auto-generated map module for logical-to-physical translation.

const plan_mapper = @import("plan_mapper.zig");

pub fn mapSpec() plan_mapper.MapOpSpec {
    return plan_mapper.make(
        "map_recursive_extend",
        "processor/operator/extend/recursive_extend.zig",
        true,
        false,
    );
}
