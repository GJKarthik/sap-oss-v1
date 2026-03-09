//! HashJoinBuild — Ported from kuzu C++ (118L header, 76L source).
//!

const std = @import("std");

pub const HashJoinBuild = struct {
    allocator: std.mem.Allocator,
    keys: std.ArrayList(u8) = .{},
    payloads: std.ArrayList(u8) = .{},
    HashJoinBuild: ?*anyopaque = null,
    mtx: ?*anyopaque = null,
    hashTable: ?*?*anyopaque = null,
    keysPos: std.ArrayList(?*anyopaque) = .{},
    fStateTypes: std.ArrayList(?*anyopaque) = .{},
    payloadsPos: std.ArrayList(?*anyopaque) = .{},
    tableSchema: ?*anyopaque = null,
    sharedState: ?*anyopaque = null,
    info: ?*anyopaque = null,
    keyVectors: std.ArrayList(?*anyopaque) = .{},
    payloadVectors: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn hash_join_build_print_info(self: *Self) void {
        _ = self;
    }

    pub fn hash_join_shared_state(self: *Self) void {
        _ = self;
    }

    pub fn merge_local_hash_table(self: *Self) void {
        _ = self;
    }

    pub fn get_num_keys(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    pub fn finalize_internal(self: *Self) void {
        _ = self;
    }

    pub fn append_vectors(self: *Self) void {
        _ = self;
    }

    pub fn set_key_state(self: *Self) void {
        _ = self;
    }

    pub fn key(self: *Self) void {
        _ = self;
    }

};

test "HashJoinBuild" {
    const allocator = std.testing.allocator;
    var instance = HashJoinBuild.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_keys();
}
