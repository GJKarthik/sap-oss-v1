const std = @import("std");

const connector = @import("adapters/connector.zig");

test {
    std.testing.refAllDecls(connector);
}
