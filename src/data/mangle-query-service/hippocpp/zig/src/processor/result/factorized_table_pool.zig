//! Pool for reusing factorized tables.

const std = @import("std");
const table_mod = @import("factorized_table.zig");
const schema_mod = @import("factorized_table_schema.zig");

pub const FactorizedTablePool = struct {
    allocator: std.mem.Allocator,
    available: std.ArrayList(*table_mod.FactorizedTable),

    pub fn init(allocator: std.mem.Allocator) FactorizedTablePool {
        return .{
            .allocator = allocator,
            .available = std.ArrayList(*table_mod.FactorizedTable).init(allocator),
        };
    }

    pub fn deinit(self: *FactorizedTablePool) void {
        for (self.available.items) |table| {
            table.deinit();
            self.allocator.destroy(table);
        }
        self.available.deinit();
    }

    pub fn acquire(self: *FactorizedTablePool, schema: schema_mod.FactorizedTableSchema) !*table_mod.FactorizedTable {
        if (self.available.items.len > 0) {
            return self.available.pop();
        }
        const table = try self.allocator.create(table_mod.FactorizedTable);
        table.* = try table_mod.FactorizedTable.init(self.allocator, schema);
        return table;
    }

    pub fn release(self: *FactorizedTablePool, table: *table_mod.FactorizedTable) !void {
        try self.available.append(table);
    }
};

test "factorized table pool acquire release" {
    const allocator = std.testing.allocator;

    var pool = FactorizedTablePool.init(allocator);
    defer pool.deinit();

    var schema = schema_mod.FactorizedTableSchema.init(allocator);
    defer schema.deinit();
    try schema.addColumn(.{ .name = "v", .column_type = .int64 });

    const table = try pool.acquire(schema);
    try pool.release(table);
    try std.testing.expectEqual(@as(usize, 1), pool.available.items.len);
}
