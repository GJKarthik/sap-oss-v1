//! Transaction - MVCC Transaction Management
//!
//! Converted from: kuzu/src/transaction/transaction.cpp
//!
//! Purpose:
//! Manages database transactions with MVCC (Multi-Version Concurrency Control).
//! Provides transaction isolation, commit, and rollback operations.

const std = @import("std");
const common = @import("../common/common.zig");

const TableID = common.TableID;

/// Transaction ID type
pub const TransactionID = u64;
pub const INVALID_TX_ID: TransactionID = std.math.maxInt(TransactionID);

/// Transaction state
pub const TransactionState = enum {
    ACTIVE,
    COMMITTED,
    ABORTED,
    ROLLED_BACK,
};

/// Transaction type
pub const TransactionType = enum {
    READ_ONLY,
    WRITE,
};

/// Transaction - Represents a database transaction
pub const Transaction = struct {
    allocator: std.mem.Allocator,
    tx_id: TransactionID,
    start_timestamp: u64,
    commit_timestamp: u64,
    state: TransactionState,
    tx_type: TransactionType,
    modified_tables: std.ArrayList(TableID),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, tx_id: TransactionID, tx_type: TransactionType) Self {
        return Self{
            .allocator = allocator,
            .tx_id = tx_id,
            .start_timestamp = @intCast(std.time.timestamp()),
            .commit_timestamp = 0,
            .state = .ACTIVE,
            .tx_type = tx_type,
            .modified_tables = std.ArrayList(TableID).init(allocator),
        };
    }
    
    pub fn isActive(self: *const Self) bool {
        return self.state == .ACTIVE;
    }
    
    pub fn isReadOnly(self: *const Self) bool {
        return self.tx_type == .READ_ONLY;
    }
    
    pub fn addModifiedTable(self: *Self, table_id: TableID) !void {
        for (self.modified_tables.items) |id| {
            if (id == table_id) return;
        }
        try self.modified_tables.append(table_id);
    }
    
    pub fn deinit(self: *Self) void {
        self.modified_tables.deinit();
    }
};

/// Transaction context for a connection
pub const TransactionContext = struct {
    allocator: std.mem.Allocator,
    current_tx: ?*Transaction,
    auto_commit: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .current_tx = null,
            .auto_commit = true,
        };
    }
    
    pub fn beginTransaction(self: *Self, tx_type: TransactionType) !*Transaction {
        if (self.current_tx != null) {
            return error.TransactionAlreadyActive;
        }
        
        const tx = try self.allocator.create(Transaction);
        tx.* = Transaction.init(self.allocator, 0, tx_type); // TODO: proper tx_id
        self.current_tx = tx;
        return tx;
    }
    
    pub fn commit(self: *Self) !void {
        if (self.current_tx) |tx| {
            tx.commit_timestamp = @intCast(std.time.timestamp());
            tx.state = .COMMITTED;
            tx.deinit();
            self.allocator.destroy(tx);
            self.current_tx = null;
        }
    }
    
    pub fn rollback(self: *Self) !void {
        if (self.current_tx) |tx| {
            tx.state = .ROLLED_BACK;
            tx.deinit();
            self.allocator.destroy(tx);
            self.current_tx = null;
        }
    }
    
    pub fn hasActiveTransaction(self: *const Self) bool {
        if (self.current_tx) |tx| {
            return tx.isActive();
        }
        return false;
    }
    
    pub fn deinit(self: *Self) void {
        if (self.current_tx) |tx| {
            tx.deinit();
            self.allocator.destroy(tx);
            self.current_tx = null;
        }
    }
};

/// Transaction Manager - Global transaction coordination
pub const TransactionManager = struct {
    allocator: std.mem.Allocator,
    next_tx_id: TransactionID,
    active_transactions: std.ArrayList(*Transaction),
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .next_tx_id = 1,
            .active_transactions = std.ArrayList(*Transaction).init(allocator),
            .mutex = .{},
        };
        return self;
    }
    
    pub fn beginTransaction(self: *Self, tx_type: TransactionType) !*Transaction {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const tx_id = self.next_tx_id;
        self.next_tx_id += 1;
        
        const tx = try self.allocator.create(Transaction);
        tx.* = Transaction.init(self.allocator, tx_id, tx_type);
        
        try self.active_transactions.append(tx);
        return tx;
    }
    
    pub fn commitTransaction(self: *Self, tx: *Transaction) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        tx.commit_timestamp = @intCast(std.time.timestamp());
        tx.state = .COMMITTED;
        
        // Remove from active list
        for (self.active_transactions.items, 0..) |active_tx, i| {
            if (active_tx == tx) {
                _ = self.active_transactions.orderedRemove(i);
                break;
            }
        }
    }
    
    pub fn rollbackTransaction(self: *Self, tx: *Transaction) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        tx.state = .ROLLED_BACK;
        
        // Remove from active list
        for (self.active_transactions.items, 0..) |active_tx, i| {
            if (active_tx == tx) {
                _ = self.active_transactions.orderedRemove(i);
                break;
            }
        }
    }
    
    pub fn destroy(self: *Self) void {
        for (self.active_transactions.items) |tx| {
            tx.deinit();
            self.allocator.destroy(tx);
        }
        self.active_transactions.deinit();
        self.allocator.destroy(self);
    }
};