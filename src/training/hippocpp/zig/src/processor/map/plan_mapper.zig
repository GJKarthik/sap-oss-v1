//! Plan mapper core for translating logical plan nodes to physical operator specs.

const std = @import("std");

pub const MapOpSpec = struct {
    name: []const u8,
    target_module: []const u8,
    supports_parallel: bool,
    produces_sink: bool,
};

pub fn make(
    name: []const u8,
    target_module: []const u8,
    supports_parallel: bool,
    produces_sink: bool,
) MapOpSpec {
    return .{
        .name = name,
        .target_module = target_module,
        .supports_parallel = supports_parallel,
        .produces_sink = produces_sink,
    };
}

pub const PlanMapper = struct {
    allocator: std.mem.Allocator,
    specs: std.ArrayList(MapOpSpec),

    pub fn init(allocator: std.mem.Allocator) PlanMapper {
        return .{
            .allocator = allocator,
            .specs = .{},
        };
    }

    pub fn deinit(self: *PlanMapper) void {
        self.specs.deinit(self.allocator);
    }

    pub fn register(self: *PlanMapper, spec: MapOpSpec) !void {
        try self.specs.append(self.allocator, spec);
    }

    pub fn find(self: *const PlanMapper, name: []const u8) ?MapOpSpec {
        for (self.specs.items) |spec| {
            if (std.mem.eql(u8, spec.name, name)) return spec;
        }
        return null;
    }
};

test "plan mapper register and lookup" {
    const allocator = std.testing.allocator;
    var mapper = PlanMapper.init(allocator);
    defer mapper.deinit(std.testing.allocator);

    const spec = make("map_projection", "processor/operator/projection.zig", true, false);
    try mapper.register(spec);

    const found = mapper.find("map_projection");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("processor/operator/projection.zig", found.?.target_module);
}
