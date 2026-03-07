//! Transaction operator helpers.

const std = @import("std");

pub const TxState = enum {
    idle,
    active,
    committed,
    rolled_back,
};

pub const TransactionOperator = struct {
    state: TxState = .idle,

    pub fn begin(self: *TransactionOperator) !void {
        if (self.state == .active) return error.TransactionAlreadyActive;
        self.state = .active;
    }

    pub fn commit(self: *TransactionOperator) !void {
        if (self.state != .active) return error.NoActiveTransaction;
        self.state = .committed;
    }

    pub fn rollback(self: *TransactionOperator) !void {
        if (self.state != .active) return error.NoActiveTransaction;
        self.state = .rolled_back;
    }
};

test "transaction operator lifecycle" {
    var tx = TransactionOperator{};
    try tx.begin();
    try tx.commit();
    try std.testing.expectEqual(TxState.committed, tx.state);
}
