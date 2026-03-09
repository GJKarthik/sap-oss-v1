//! SET clause mutation support.

const std = @import("std");

pub const SetMutation = struct {
    field: []const u8,
    value: []const u8,
};

pub const SetBatch = struct {
    allocator: std.mem.Allocator,
    mutations: std.ArrayList(SetMutation),

    pub fn init(allocator: std.mem.Allocator) SetBatch {
        return .{ .allocator = allocator, .mutations = .{} };
    }

    pub fn deinit(self: *SetBatch) void {
        self.mutations.deinit(self.allocator);
    }

    pub fn add(self: *SetBatch, field: []const u8, value: []const u8) !void {
        try self.mutations.append(self.allocator, .{ .field = field, .value = value });
    }
};
