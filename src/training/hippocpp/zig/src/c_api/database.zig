//! C API database lifecycle bridge.

const std = @import("std");
const main_db = @import("database");

pub const CSystemConfig = extern struct {
    buffer_pool_size: u64,
    max_num_threads: u64,
    enable_compression: bool,
    read_only: bool,
    max_db_size: u64,
};

pub const ManagedDatabase = struct {
    allocator: std.mem.Allocator,
    db: *main_db.Database,
    path: []u8,
};

pub fn defaultSystemConfig() CSystemConfig {
    return .{
        .buffer_pool_size = 256 * 1024 * 1024,
        .max_num_threads = 0,
        .enable_compression = true,
        .read_only = false,
        .max_db_size = 0,
    };
}

pub fn create(allocator: std.mem.Allocator, database_path: [*:0]const u8, config: CSystemConfig) ?*ManagedDatabase {
    const path_span = std.mem.span(database_path);
    var path_copy = allocator.dupe(u8, path_span) catch return null;
    errdefer allocator.free(path_copy);

    const db_ptr = allocator.create(main_db.Database) catch return null;
    errdefer allocator.destroy(db_ptr);

    const threads: u32 = @truncate(@min(config.max_num_threads, std.math.maxInt(u32)));
    db_ptr.* = main_db.Database.init(allocator, .{
        .database_path = path_copy,
        .buffer_pool_size = @intCast(config.buffer_pool_size),
        .max_threads = threads,
        .read_only = config.read_only,
    });
    db_ptr.open() catch {
        db_ptr.deinit();
        return null;
    };

    const managed = allocator.create(ManagedDatabase) catch {
        db_ptr.deinit();
        allocator.destroy(db_ptr);
        return null;
    };
    managed.* = .{
        .allocator = allocator,
        .db = db_ptr,
        .path = path_copy,
    };
    return managed;
}

pub fn destroy(managed: *ManagedDatabase) void {
    managed.db.deinit();
    managed.allocator.destroy(managed.db);
    managed.allocator.free(managed.path);
    managed.allocator.destroy(managed);
}

test "create and destroy managed database" {
    const allocator = std.testing.allocator;
    const config = defaultSystemConfig();

    const managed = create(allocator, ":memory:", config) orelse return error.OutOfMemory;
    try std.testing.expectEqual(main_db.DatabaseState.RUNNING, managed.db.getState());

    destroy(managed);
}
