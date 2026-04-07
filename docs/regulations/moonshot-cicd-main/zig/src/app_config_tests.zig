const std = @import("std");

const app_config = @import("runtime/app_config.zig");

test {
    std.testing.refAllDecls(app_config);
}

