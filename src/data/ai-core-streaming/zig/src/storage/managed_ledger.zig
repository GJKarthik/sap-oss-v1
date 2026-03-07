//! BDC AIPrompt Streaming - Managed Ledger Storage
//! Append-only log storage backed by SAP HANA

const std = @import("std");
const hana = @import("hana");

const log = std.log.scoped(.managed_ledger);

// ============================================================================
// Managed Ledger Configuration
// ============================================================================

pub const ManagedLedgerConfig = struct {
    max_entries_per_ledger: u64 = 50000,
    max_ledger_size_bytes: u64 = 256 * 1024 * 1024, // 256MB
    ledger_rollover_time_minutes: u32 = 240, // 4 hours
    write_buffer_size: u32 = 64 * 1024, // 64KB
    flush_interval_ms: u32 = 100,
    retention_time_minutes: i64 = 0, // 0 = infinite
    retention_size_bytes: i64 = 0, // 0 = infinite
};

// ============================================================================
// Position
// ============================================================================

pub const Position = struct {
    ledger_id: i64,
    entry_id: i64,

    pub const earliest: Position = .{ .ledger_id = -1, .entry_id = -1 };
    pub const latest: Position = .{ .ledger_id = std.math.maxInt(i64), .entry_id = std.math.maxInt(i64) };

    pub fn compare(self: Position, other: Position) std.math.Order {
        if (self.ledger_id != other.ledger_id) {
            return std.math.order(self.ledger_id, other.ledger_id);
        }
        return std.math.order(self.entry_id, other.entry_id);
    }

    pub fn next(self: Position) Position {
        return .{
            .ledger_id = self.ledger_id,
            .entry_id = self.entry_id + 1,
        };
    }

    pub fn format(self: Position, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:{}", .{ self.ledger_id, self.entry_id });
    }
};

// ============================================================================
// Entry
// ============================================================================

pub const Entry = struct {
    ledger_id: i64,
    entry_id: i64,
    data: []const u8,
    timestamp: i64,

    pub fn getPosition(self: Entry) Position {
        return .{
            .ledger_id = self.ledger_id,
            .entry_id = self.entry_id,
        };
    }
};

// ============================================================================
// Ledger Info
// ============================================================================

pub const LedgerInfo = struct {
    ledger_id: i64,
    state: LedgerState,
    first_entry_id: i64,
    last_entry_id: i64,
    size: i64,
    entries_count: i64,
    created_at: i64,
    closed_at: ?i64,

    pub fn getEntryCount(self: LedgerInfo) i64 {
        if (self.last_entry_id < 0) return 0;
        return self.last_entry_id - self.first_entry_id + 1;
    }
};

pub const LedgerState = enum {
    Open,
    Closed,
    Offloaded,
    Deleted,
};

// ============================================================================
// Managed Ledger
// ============================================================================

pub const ManagedLedger = struct {
    allocator: std.mem.Allocator,
    name: []const u8, // Usually the topic name
    config: ManagedLedgerConfig,
    hana_client: *hana.HanaClient,

    // State
    ledgers: std.ArrayListUnmanaged(LedgerInfo),
    current_ledger_id: i64,
    current_entry_id: std.atomic.Value(i64),
    total_size: std.atomic.Value(i64),
    total_entries: std.atomic.Value(i64),

    // Cursors
    cursors: std.StringHashMap(*ManagedCursor),
    cursors_lock: std.Thread.Mutex,

    // Write buffer
    write_buffer: std.ArrayListUnmanaged(PendingEntry),
    write_lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, config: ManagedLedgerConfig, hana_client: *hana.HanaClient) !*ManagedLedger {
        const ml = try allocator.create(ManagedLedger);
        ml.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .config = config,
            .hana_client = hana_client,
            .ledgers = .{},
            .current_ledger_id = 0,
            .current_entry_id = std.atomic.Value(i64).init(-1),
            .total_size = std.atomic.Value(i64).init(0),
            .total_entries = std.atomic.Value(i64).init(0),
            .cursors = std.StringHashMap(*ManagedCursor).init(allocator),
            .cursors_lock = .{},
            .write_buffer = .{},
            .write_lock = .{},
        };

        // Create initial ledger
        try ml.createNewLedger();

        return ml;
    }

    pub fn deinit(self: *ManagedLedger) void {
        // Clean up cursors
        var cursor_iter = self.cursors.iterator();
        while (cursor_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cursors.deinit();

        self.ledgers.deinit(self.allocator);
        self.write_buffer.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    // =========================================================================
    // Write Operations
    // =========================================================================

    /// Add an entry to the ledger
    pub fn addEntry(self: *ManagedLedger, data: []const u8) !Position {
        self.write_lock.lock();
        defer self.write_lock.unlock();

        // Check if we need to roll over to a new ledger
        if (self.shouldRollover(data.len)) {
            try self.rolloverLedger();
        }

        const entry_id = self.current_entry_id.fetchAdd(1, .monotonic) + 1;
        const timestamp = std.time.milliTimestamp();

        const position = Position{
            .ledger_id = self.current_ledger_id,
            .entry_id = entry_id,
        };

        // Add to write buffer
        try self.write_buffer.append(self.allocator, .{
            .position = position,
            .data = try self.allocator.dupe(u8, data),
            .timestamp = timestamp,
        });

        // Update stats
        _ = self.total_size.fetchAdd(@intCast(data.len), .monotonic);
        _ = self.total_entries.fetchAdd(1, .monotonic);

        // Persist to HANA
        try self.persistEntry(position, data, timestamp);

        log.debug("Added entry {any} to ledger {s}", .{ position, self.name });

        return position;
    }

    fn persistEntry(self: *ManagedLedger, position: Position, data: []const u8, timestamp: i64) !void {
        const msg = hana.MessageRecord{
            .topic_name = self.name,
            .partition_id = 0,
            .ledger_id = position.ledger_id,
            .entry_id = position.entry_id,
            .publish_time = timestamp,
            .producer_name = "internal",
            .sequence_id = position.entry_id,
            .payload = data,
            .payload_size = @intCast(data.len),
        };
        try self.hana_client.insertMessage(msg);
    }

    fn shouldRollover(self: *ManagedLedger, incoming_size: usize) bool {
        const current_entries: u64 = @intCast(self.current_entry_id.load(.monotonic) + 1);
        if (current_entries >= self.config.max_entries_per_ledger) {
            return true;
        }

        const current_size: u64 = @intCast(self.total_size.load(.monotonic));
        if (current_size + incoming_size >= self.config.max_ledger_size_bytes) {
            return true;
        }

        return false;
    }

    fn rolloverLedger(self: *ManagedLedger) !void {
        log.info("Rolling over ledger for {s}", .{self.name});

        // Close current ledger
        if (self.ledgers.items.len > 0) {
            var current = &self.ledgers.items[self.ledgers.items.len - 1];
            current.state = .Closed;
            current.closed_at = std.time.milliTimestamp();
            current.last_entry_id = self.current_entry_id.load(.monotonic);

            try self.hana_client.updateLedgerState(current.ledger_id, .Closed);
        }

        // Create new ledger
        try self.createNewLedger();
    }

    fn createNewLedger(self: *ManagedLedger) !void {
        self.current_ledger_id += 1;
        self.current_entry_id.store(-1, .monotonic);

        const now = std.time.milliTimestamp();
        const ledger_info = LedgerInfo{
            .ledger_id = self.current_ledger_id,
            .state = .Open,
            .first_entry_id = 0,
            .last_entry_id = -1,
            .size = 0,
            .entries_count = 0,
            .created_at = now,
            .closed_at = null,
        };

        try self.ledgers.append(self.allocator, ledger_info);

        // Persist to HANA
        try self.hana_client.createLedger(.{
            .ledger_id = self.current_ledger_id,
            .topic_name = self.name,
            .state = .Open,
            .first_entry_id = 0,
            .last_entry_id = -1,
            .size_bytes = 0,
            .entries_count = 0,
            .created_at = now,
        });

        log.info("Created new ledger {} for {s}", .{ self.current_ledger_id, self.name });
    }

    // =========================================================================
    // Read Operations
    // =========================================================================

    /// Read entries starting from a position
    pub fn readEntries(self: *ManagedLedger, start: Position, max_entries: u32) ![]Entry {
        const records = try self.hana_client.getMessages(self.name, start.ledger_id, start.entry_id, max_entries);
        
        var entries = try self.allocator.alloc(Entry, records.len);
        for (records, 0..) |record, i| {
            entries[i] = .{
                .ledger_id = record.ledger_id,
                .entry_id = record.entry_id,
                .data = record.payload, // Note: record owns the memory, we might need to dupe if lifetime is short
                .timestamp = record.publish_time,
            };
        }
        return entries;
    }

    /// Get the last confirmed position
    pub fn getLastConfirmedEntry(self: *ManagedLedger) Position {
        return .{
            .ledger_id = self.current_ledger_id,
            .entry_id = self.current_entry_id.load(.monotonic),
        };
    }

    // =========================================================================
    // Cursor Management
    // =========================================================================

    /// Open or create a cursor
    pub fn openCursor(self: *ManagedLedger, name: []const u8) !*ManagedCursor {
        self.cursors_lock.lock();
        defer self.cursors_lock.unlock();

        if (self.cursors.get(name)) |cursor| {
            return cursor;
        }

        const cursor = try self.allocator.create(ManagedCursor);
        cursor.* = try ManagedCursor.init(self.allocator, name, self);
        try self.cursors.put(try self.allocator.dupe(u8, name), cursor);

        log.info("Opened cursor {s} for {s}", .{ name, self.name });
        return cursor;
    }

    /// Delete a cursor
    pub fn deleteCursor(self: *ManagedLedger, name: []const u8) !void {
        self.cursors_lock.lock();
        defer self.cursors_lock.unlock();

        if (self.cursors.fetchRemove(name)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
            log.info("Deleted cursor {s} from {s}", .{ name, self.name });
        }
    }

    // =========================================================================
    // Stats
    // =========================================================================

    pub fn getStats(self: *ManagedLedger) ManagedLedgerStats {
        return .{
            .name = self.name,
            .ledger_count = @intCast(self.ledgers.items.len),
            .current_ledger_id = self.current_ledger_id,
            .total_entries = @intCast(self.total_entries.load(.monotonic)),
            .total_size = @intCast(self.total_size.load(.monotonic)),
            .cursor_count = @intCast(self.cursors.count()),
        };
    }
};

pub const ManagedLedgerStats = struct {
    name: []const u8,
    ledger_count: u32,
    current_ledger_id: i64,
    total_entries: u64,
    total_size: u64,
    cursor_count: u32,
};

// ============================================================================
// Pending Entry (for write buffer)
// ============================================================================

const PendingEntry = struct {
    position: Position,
    data: []const u8,
    timestamp: i64,
};

// ============================================================================
// Managed Cursor
// ============================================================================

pub const ManagedCursor = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    managed_ledger: *ManagedLedger,

    // Positions
    read_position: Position,
    mark_delete_position: Position,

    // Pending acks
    pending_acks: std.AutoHashMap(Position, i64),
    pending_acks_lock: std.Thread.Mutex,

    // Stats
    messages_consumed: std.atomic.Value(u64),
    messages_acked: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, name: []const u8, managed_ledger: *ManagedLedger) !ManagedCursor {
        // Load cursor position from HANA
        const saved_cursor = try managed_ledger.hana_client.getCursor(name, managed_ledger.name);

        const mark_delete = if (saved_cursor) |c|
            Position{ .ledger_id = c.mark_delete_ledger, .entry_id = c.mark_delete_entry }
        else
            Position.earliest;

        const read_pos = if (saved_cursor) |c|
            Position{ .ledger_id = c.read_ledger, .entry_id = c.read_entry }
        else
            Position.earliest;

        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .managed_ledger = managed_ledger,
            .read_position = read_pos,
            .mark_delete_position = mark_delete,
            .pending_acks = std.AutoHashMap(Position, i64).init(allocator),
            .pending_acks_lock = .{},
            .messages_consumed = std.atomic.Value(u64).init(0),
            .messages_acked = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *ManagedCursor) void {
        self.pending_acks.deinit();
        self.allocator.free(self.name);
    }

    /// Read entries from the cursor position
    pub fn readEntries(self: *ManagedCursor, max_entries: u32) ![]Entry {
        const entries = try self.managed_ledger.readEntries(self.read_position, max_entries);

        if (entries.len > 0) {
            self.read_position = entries[entries.len - 1].getPosition().next();
            _ = self.messages_consumed.fetchAdd(@intCast(entries.len), .monotonic);
        }

        return entries;
    }

    /// Acknowledge a message
    pub fn acknowledge(self: *ManagedCursor, position: Position) !void {
        self.pending_acks_lock.lock();
        defer self.pending_acks_lock.unlock();

        try self.pending_acks.put(position, std.time.milliTimestamp());
        _ = self.messages_acked.fetchAdd(1, .monotonic);

        // Update mark delete if this advances it
        if (position.compare(self.mark_delete_position) == .gt) {
            self.mark_delete_position = position;
            try self.persistCursor();
        }
    }

    /// Acknowledge all messages up to and including the position
    pub fn acknowledgeCumulative(self: *ManagedCursor, position: Position) !void {
        self.mark_delete_position = position;
        try self.persistCursor();
    }

    fn persistCursor(self: *ManagedCursor) !void {
        try self.managed_ledger.hana_client.updateCursor(.{
            .cursor_name = self.name,
            .topic_name = self.managed_ledger.name,
            .mark_delete_ledger = self.mark_delete_position.ledger_id,
            .mark_delete_entry = self.mark_delete_position.entry_id,
            .read_ledger = self.read_position.ledger_id,
            .read_entry = self.read_position.entry_id,
            .pending_ack_count = @intCast(self.pending_acks.count()),
        });
    }

    /// Get the backlog (unacked messages)
    pub fn getBacklog(self: *ManagedCursor) i64 {
        const last_confirmed = self.managed_ledger.getLastConfirmedEntry();

        // Simplified calculation
        if (last_confirmed.ledger_id == self.mark_delete_position.ledger_id) {
            return last_confirmed.entry_id - self.mark_delete_position.entry_id;
        }

        // Cross-ledger calculation would require summing entries
        return 0;
    }

    pub fn getStats(self: *ManagedCursor) CursorStats {
        return .{
            .name = self.name,
            .read_position = self.read_position,
            .mark_delete_position = self.mark_delete_position,
            .pending_ack_count = @intCast(self.pending_acks.count()),
            .messages_consumed = self.messages_consumed.load(.monotonic),
            .messages_acked = self.messages_acked.load(.monotonic),
            .backlog = self.getBacklog(),
        };
    }
};

pub const CursorStats = struct {
    name: []const u8,
    read_position: Position,
    mark_delete_position: Position,
    pending_ack_count: u32,
    messages_consumed: u64,
    messages_acked: u64,
    backlog: i64,
};

// ============================================================================
// Tests
// ============================================================================

test "Position comparison" {
    const p1 = Position{ .ledger_id = 1, .entry_id = 10 };
    const p2 = Position{ .ledger_id = 1, .entry_id = 20 };
    const p3 = Position{ .ledger_id = 2, .entry_id = 5 };

    try std.testing.expectEqual(std.math.Order.lt, p1.compare(p2));
    try std.testing.expectEqual(std.math.Order.lt, p2.compare(p3));
    try std.testing.expectEqual(std.math.Order.gt, p3.compare(p1));
}

test "Position next" {
    const p1 = Position{ .ledger_id = 1, .entry_id = 10 };
    const p2 = p1.next();

    try std.testing.expectEqual(@as(i64, 1), p2.ledger_id);
    try std.testing.expectEqual(@as(i64, 11), p2.entry_id);
}