//! Connection orchestration for main module.

const std = @import("std");
const database_mod = @import("database.zig");

pub const ManagedConnection = struct {
    allocator: std.mem.Allocator,
    database: *database_mod.Database,
    conn: *database_mod.Connection,

    pub fn connect(allocator: std.mem.Allocator, db: *database_mod.Database) !ManagedConnection {
        const conn = try db.connect();
        return .{
            .allocator = allocator,
            .database = db,
            .conn = conn,
        };
    }

    pub fn close(self: *ManagedConnection) void {
        self.conn.close();
    }

    pub fn execute(self: *ManagedConnection, query: []const u8) !database_mod.QueryResult {
        return self.conn.executeQuery(query);
    }
};

test "managed connection execute path" {
    const allocator = std.testing.allocator;
    var db = database_mod.Database.init(allocator, database_mod.DatabaseConfig.inMemory());
    defer db.deinit();
    try db.open();

    var managed = try ManagedConnection.connect(allocator, &db);
    defer managed.close();

    var result = try managed.execute("RETURN 1");
    defer result.deinit();
    try std.testing.expect(result.isSuccess());
}
