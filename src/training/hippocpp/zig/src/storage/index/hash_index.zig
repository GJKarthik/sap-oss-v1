//! Hash Index - Primary key and lookup index
//!
//! Purpose:
//! Provides hash-based indexing for O(1) key lookups.
//! Supports both in-memory and persistent storage.

const std = @import("std");

// ============================================================================
// Hash Index Entry
// ============================================================================

pub const IndexEntry = struct {
    key_hash: u64,
    offset: u64,
    next: ?*IndexEntry = null,  // For collision chaining
    
    pub fn init(key_hash: u64, offset: u64) IndexEntry {
        return .{ .key_hash = key_hash, .offset = offset };
    }
};

// ============================================================================
// Hash Slot
// ============================================================================

pub const HashSlot = struct {
    head: ?*IndexEntry = null,
    count: usize = 0,
    
    pub fn insert(self: *HashSlot, entry: *IndexEntry) void {
        entry.next = self.head;
        self.head = entry;
        self.count += 1;
    }
    
    pub fn find(self: *const HashSlot, key_hash: u64) ?*IndexEntry {
        var current = self.head;
        while (current) |entry| {
            if (entry.key_hash == key_hash) return entry;
            current = entry.next;
        }
        return null;
    }
    
    pub fn remove(self: *HashSlot, key_hash: u64) ?*IndexEntry {
        var prev: ?*?*IndexEntry = null;
        var current = &self.head;
        
        while (current.*) |entry| {
            if (entry.key_hash == key_hash) {
                current.* = entry.next;
                self.count -= 1;
                return entry;
            }
            prev = current;
            current = &entry.next;
        }
        // _ = prev;
        return null;
    }
};

// ============================================================================
// Hash Index Configuration
// ============================================================================

pub const HashIndexConfig = struct {
    initial_capacity: usize = 1024,
    load_factor: f64 = 0.75,
    grow_factor: f64 = 2.0,
    allow_duplicates: bool = false,
};

// ============================================================================
// Hash Index
// ============================================================================

pub const HashIndex = struct {
    allocator: std.mem.Allocator,
    config: HashIndexConfig,
    slots: []HashSlot,
    num_slots: usize,
    num_entries: usize = 0,
    entry_pool: std.ArrayList(IndexEntry),
    
    // Statistics
    total_lookups: u64 = 0,
    total_hits: u64 = 0,
    total_collisions: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, config: HashIndexConfig) !HashIndex {
        const slots = try allocator.alloc(HashSlot, config.initial_capacity);
        for (slots) |*slot| {
            slot.* = .{};
        }
        
        return .{
            .allocator = allocator,
            .config = config,
            .slots = slots,
            .num_slots = config.initial_capacity,
            .entry_pool = .{},
        };
    }
    
    pub fn deinit(self: *HashIndex) void {
        self.allocator.free(self.slots);
        self.entry_pool.deinit(self.allocator);
    }
    
    /// Insert a key-offset pair
    pub fn insert(self: *HashIndex, key: anytype, offset: u64) !void {
        const key_hash = self.hashKey(key);
        
        // Check if resize needed
        if (self.shouldResize()) {
            try self.resize();
        }
        
        const slot_idx = key_hash % self.num_slots;
        var slot = &self.slots[slot_idx];
        
        // Check for duplicates if not allowed
        if (!self.config.allow_duplicates) {
            if (slot.find(key_hash) != null) {
                return error.DuplicateKey;
            }
        }
        
        // Track collisions
        if (slot.head != null) {
            self.total_collisions += 1;
        }
        
        // Create entry
        try self.entry_pool.append(self.allocator, IndexEntry.init(key_hash, offset));
        const entry = &self.entry_pool.items[self.entry_pool.items.len - 1];
        
        slot.insert(entry);
        self.num_entries += 1;
    }
    
    /// Lookup offset by key
    pub fn lookup(self: *HashIndex, key: anytype) ?u64 {
        self.total_lookups += 1;
        
        const key_hash = self.hashKey(key);
        const slot_idx = key_hash % self.num_slots;
        const slot = &self.slots[slot_idx];
        
        if (slot.find(key_hash)) |entry| {
            self.total_hits += 1;
            return entry.offset;
        }
        return null;
    }
    
    /// Check if key exists
    pub fn contains(self: *HashIndex, key: anytype) bool {
        return self.lookup(key) != null;
    }
    
    /// Delete entry by key
    pub fn delete(self: *HashIndex, key: anytype) bool {
        const key_hash = self.hashKey(key);
        const slot_idx = key_hash % self.num_slots;
        var slot = &self.slots[slot_idx];
        
        if (slot.remove(key_hash)) |_| {
            self.num_entries -= 1;
            return true;
        }
        return false;
    }
    
    /// Update offset for existing key
    pub fn update(self: *HashIndex, key: anytype, new_offset: u64) bool {
        const key_hash = self.hashKey(key);
        const slot_idx = key_hash % self.num_slots;
        const slot = &self.slots[slot_idx];
        
        if (slot.find(key_hash)) |entry| {
            entry.offset = new_offset;
            return true;
        }
        return false;
    }
    
    fn hashKey(self: *const HashIndex, key: anytype) u64 {
        _ = self;
        const T = @TypeOf(key);
        
        if (T == i64) {
            return @bitCast(key);
        } else if (T == u64) {
            return key;
        } else if (T == []const u8) {
            return std.hash.Wyhash.hash(0, key);
        } else if (@typeInfo(T) == .Int) {
            return @intCast(key);
        } else {
            // Generic hash
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        }
    }
    
    fn shouldResize(self: *const HashIndex) bool {
        const load = @as(f64, @floatFromInt(self.num_entries)) / @as(f64, @floatFromInt(self.num_slots));
        return load > self.config.load_factor;
    }
    
    fn resize(self: *HashIndex) !void {
        const new_size = @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.num_slots)) * self.config.grow_factor));
        
        const new_slots = try self.allocator.alloc(HashSlot, new_size);
        for (new_slots) |*slot| {
            slot.* = .{};
        }
        
        // Rehash all entries
        for (self.entry_pool.items) |*entry| {
            const new_slot_idx = entry.key_hash % new_size;
            entry.next = null;  // Clear old chain
            new_slots[new_slot_idx].insert(entry);
        }
        
        self.allocator.free(self.slots);
        self.slots = new_slots;
        self.num_slots = new_size;
    }
    
    // Statistics
    pub fn loadFactor(self: *const HashIndex) f64 {
        return @as(f64, @floatFromInt(self.num_entries)) / @as(f64, @floatFromInt(self.num_slots));
    }
    
    pub fn hitRate(self: *const HashIndex) f64 {
        if (self.total_lookups == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_hits)) / @as(f64, @floatFromInt(self.total_lookups));
    }
};

// ============================================================================
// In-Memory Hash Index (Optimized)
// ============================================================================

pub const InMemHashIndex = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, u64),
    
    pub fn init(allocator: std.mem.Allocator) InMemHashIndex {
        return .{
            .allocator = allocator,
            .map = .{ .unmanaged = .empty, .allocator = std.testing.allocator, .ctx = .{} },
        };
    }
    
    pub fn deinit(self: *InMemHashIndex) void {
        self.map.deinit();
    }
    
    pub fn insert(self: *InMemHashIndex, key: u64, offset: u64) !void {
        try self.map.put(key, offset);
    }
    
    pub fn lookup(self: *const InMemHashIndex, key: u64) ?u64 {
        return self.map.get(key);
    }
    
    pub fn delete(self: *InMemHashIndex, key: u64) bool {
        return self.map.remove(key);
    }
    
    pub fn count(self: *const InMemHashIndex) usize {
        return self.map.count();
    }
};

// ============================================================================
// String Hash Index
// ============================================================================

pub const StringHashIndex = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(u64),
    
    pub fn init(allocator: std.mem.Allocator) StringHashIndex {
        return .{
            .allocator = allocator,
            .map = .{ .unmanaged = .empty, .allocator = std.testing.allocator, .ctx = .{} },
        };
    }
    
    pub fn deinit(self: *StringHashIndex) void {
        self.map.deinit();
    }
    
    pub fn insert(self: *StringHashIndex, key: []const u8, offset: u64) !void {
        try self.map.put(key, offset);
    }
    
    pub fn lookup(self: *const StringHashIndex, key: []const u8) ?u64 {
        return self.map.get(key);
    }
    
    pub fn delete(self: *StringHashIndex, key: []const u8) bool {
        return self.map.remove(key);
    }
    
    pub fn count(self: *const StringHashIndex) usize {
        return self.map.count();
    }
};

// ============================================================================
// Primary Key Index
// ============================================================================

pub const PrimaryKeyIndex = struct {
    allocator: std.mem.Allocator,
    index: HashIndex,
    key_type: KeyType,
    table_id: u64,
    
    pub const KeyType = enum {
        INT64,
        UINT64,
        STRING,
    };
    
    pub fn init(allocator: std.mem.Allocator, table_id: u64, key_type: KeyType) !PrimaryKeyIndex {
        return .{
            .allocator = allocator,
            .index = try HashIndex.init(allocator, .{ .allow_duplicates = false }),
            .key_type = key_type,
            .table_id = table_id,
        };
    }
    
    pub fn deinit(self: *PrimaryKeyIndex) void {
        self.index.deinit();
    }
    
    pub fn insertInt64(self: *PrimaryKeyIndex, key: i64, offset: u64) !void {
        try self.index.insert(key, offset);
    }
    
    pub fn lookupInt64(self: *PrimaryKeyIndex, key: i64) ?u64 {
        return self.index.lookup(key);
    }
    
    pub fn insertString(self: *PrimaryKeyIndex, key: []const u8, offset: u64) !void {
        try self.index.insert(key, offset);
    }
    
    pub fn lookupString(self: *PrimaryKeyIndex, key: []const u8) ?u64 {
        return self.index.lookup(key);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "hash index basic" {
    const allocator = std.testing.allocator;
    
    var index = try HashIndex.init(allocator, .{});
    defer index.deinit();
    
    try index.insert(@as(u64, 100), 0);
    try index.insert(@as(u64, 200), 1);
    try index.insert(@as(u64, 300), 2);
    
    try std.testing.expectEqual(@as(?u64, 0), index.lookup(@as(u64, 100)));
    try std.testing.expectEqual(@as(?u64, 1), index.lookup(@as(u64, 200)));
    try std.testing.expectEqual(@as(?u64, 2), index.lookup(@as(u64, 300)));
    try std.testing.expect(index.lookup(@as(u64, 999)) == null);
}

test "hash index delete" {
    const allocator = std.testing.allocator;
    
    var index = try HashIndex.init(allocator, .{});
    defer index.deinit();
    
    try index.insert(@as(u64, 100), 0);
    try std.testing.expect(index.contains(@as(u64, 100)));
    
    try std.testing.expect(index.delete(@as(u64, 100)));
    try std.testing.expect(!index.contains(@as(u64, 100)));
}

test "hash index update" {
    const allocator = std.testing.allocator;
    
    var index = try HashIndex.init(allocator, .{});
    defer index.deinit();
    
    try index.insert(@as(u64, 100), 0);
    try std.testing.expectEqual(@as(?u64, 0), index.lookup(@as(u64, 100)));
    
    try std.testing.expect(index.update(@as(u64, 100), 999));
    try std.testing.expectEqual(@as(?u64, 999), index.lookup(@as(u64, 100)));
}

test "in mem hash index" {
    const allocator = std.testing.allocator;
    
    var index = InMemHashIndex.init(allocator);
    defer index.deinit();
    
    try index.insert(1, 100);
    try index.insert(2, 200);
    
    try std.testing.expectEqual(@as(?u64, 100), index.lookup(1));
    try std.testing.expectEqual(@as(?u64, 200), index.lookup(2));
    try std.testing.expectEqual(@as(usize, 2), index.count());
}

test "string hash index" {
    const allocator = std.testing.allocator;
    
    var index = StringHashIndex.init(allocator);
    defer index.deinit();
    
    try index.insert("alice", 0);
    try index.insert("bob", 1);
    
    try std.testing.expectEqual(@as(?u64, 0), index.lookup("alice"));
    try std.testing.expectEqual(@as(?u64, 1), index.lookup("bob"));
    try std.testing.expect(index.lookup("charlie") == null);
}

test "primary key index" {
    const allocator = std.testing.allocator;
    
    var pk_index = try PrimaryKeyIndex.init(allocator, 0, .INT64);
    defer pk_index.deinit();
    
    try pk_index.insertInt64(1, 0);
    try pk_index.insertInt64(2, 1);
    
    try std.testing.expectEqual(@as(?u64, 0), pk_index.lookupInt64(1));
    try std.testing.expectEqual(@as(?u64, 1), pk_index.lookupInt64(2));
}