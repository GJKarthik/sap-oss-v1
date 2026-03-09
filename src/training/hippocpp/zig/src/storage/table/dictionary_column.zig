//! Dictionary Column - String Dictionary Encoding
//!
//! Converted from: kuzu/src/storage/table/dictionary_column.cpp
//!
//! Purpose:
//! Implements dictionary encoding for string columns.
//! Stores unique strings once and references them by ID.

const std = @import("std");
const common = @import("common");

/// Dictionary entry
pub const DictionaryEntry = struct {
    id: u32,
    offset: u64,
    length: u32,
};

/// String dictionary - maps strings to IDs
pub const StringDictionary = struct {
    allocator: std.mem.Allocator,
    string_to_id: std.StringHashMap(u32),
    id_to_string: std.ArrayList([]const u8),
    data: std.ArrayList(u8),
    next_id: u32,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .string_to_id = .{},
            .id_to_string = .{},
            .data = .{},
            .next_id = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.string_to_id.deinit(self.allocator);
        for (self.id_to_string.items) |s| {
            self.allocator.free(s);
        }
        self.id_to_string.deinit(self.allocator);
        self.data.deinit(self.allocator);
    }
    
    /// Insert string, return ID (reuses existing if present)
    pub fn insert(self: *Self, str: []const u8) !u32 {
        if (self.string_to_id.get(str)) |existing_id| {
            return existing_id;
        }
        
        // New string
        const id = self.next_id;
        self.next_id += 1;
        
        // Copy and store
        const owned = try self.allocator.dupe(u8, str);
        try self.id_to_string.append(self.allocator, owned);
        try self.string_to_id.put(owned, id);
        
        return id;
    }
    
    /// Lookup string by ID
    pub fn lookup(self: *const Self, id: u32) ?[]const u8 {
        if (id >= self.id_to_string.items.len) return null;
        return self.id_to_string.items[id];
    }
    
    /// Get ID for string (if exists)
    pub fn getId(self: *const Self, str: []const u8) ?u32 {
        return self.string_to_id.get(str);
    }
    
    /// Get number of unique strings
    pub fn getNumStrings(self: *const Self) u32 {
        return self.next_id;
    }
    
    /// Get total size in bytes
    pub fn getTotalSize(self: *const Self) u64 {
        var total: u64 = 0;
        for (self.id_to_string.items) |s| {
            total += s.len;
        }
        return total;
    }
};

/// Dictionary chunk - stores dictionary-encoded column data
pub const DictionaryChunk = struct {
    allocator: std.mem.Allocator,
    dictionary: StringDictionary,
    encoded_values: std.ArrayList(u32),
    null_mask: std.ArrayList(bool),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .dictionary = StringDictionary.init(allocator),
            .encoded_values = .{},
            .null_mask = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.dictionary.deinit(self.allocator);
        self.encoded_values.deinit(self.allocator);
        self.null_mask.deinit(self.allocator);
    }
    
    /// Append a string value
    pub fn append(self: *Self, value: ?[]const u8) !void {
        if (value) |v| {
            const id = try self.dictionary.insert(v);
            try self.encoded_values.append(self.allocator, id);
            try self.null_mask.append(self.allocator, false);
        } else {
            try self.encoded_values.append(self.allocator, 0);
            try self.null_mask.append(self.allocator, true);
        }
    }
    
    /// Get value at index
    pub fn get(self: *const Self, idx: u64) ?[]const u8 {
        if (idx >= self.encoded_values.items.len) return null;
        if (self.null_mask.items[idx]) return null;
        
        const id = self.encoded_values.items[idx];
        return self.dictionary.lookup(id);
    }
    
    /// Get number of values
    pub fn getNumValues(self: *const Self) u64 {
        return self.encoded_values.items.len;
    }
    
    /// Get compression ratio
    pub fn getCompressionRatio(self: *const Self) f64 {
        const encoded_size = self.encoded_values.items.len * 4;
        const dict_size = self.dictionary.getTotalSize();
        const total_compressed = encoded_size + dict_size;
        
        // Estimate original size
        var original: u64 = 0;
        for (self.encoded_values.items, 0..) |id, i| {
            if (!self.null_mask.items[i]) {
                if (self.dictionary.lookup(id)) |s| {
                    original += s.len;
                }
            }
        }
        
        if (total_compressed == 0) return 1.0;
        return @as(f64, @floatFromInt(original)) / @as(f64, @floatFromInt(total_compressed));
    }
};

/// Dictionary column - full column with dictionary encoding
pub const DictionaryColumn = struct {
    allocator: std.mem.Allocator,
    column_idx: u32,
    chunks: std.ArrayList(DictionaryChunk),
    chunk_size: u64,
    
    const Self = @This();
    const DEFAULT_CHUNK_SIZE: u64 = 8192;
    
    pub fn init(allocator: std.mem.Allocator, column_idx: u32) Self {
        return .{
            .allocator = allocator,
            .column_idx = column_idx,
            .chunks = .{},
            .chunk_size = DEFAULT_CHUNK_SIZE,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.chunks.deinit(self.allocator);
    }
    
    /// Add a new chunk
    pub fn addChunk(self: *Self) !*DictionaryChunk {
        try self.chunks.append(self.allocator, DictionaryChunk.init(self.allocator);
        return &self.chunks.items[self.chunks.items.len - 1];
    }
    
    /// Get chunk by index
    pub fn getChunk(self: *Self, idx: usize) ?*DictionaryChunk {
        if (idx >= self.chunks.items.len) return null;
        return &self.chunks.items[idx];
    }
    
    /// Get number of chunks
    pub fn getNumChunks(self: *const Self) usize {
        return self.chunks.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "string dictionary" {
    const allocator = std.testing.allocator;
    
    var dict = StringDictionary.init(allocator);
    defer dict.deinit(std.testing.allocator);
    
    const id1 = try dict.insert("hello");
    const id2 = try dict.insert("world");
    const id3 = try dict.insert("hello"); // Duplicate
    
    try std.testing.expectEqual(@as(u32, 0), id1);
    try std.testing.expectEqual(@as(u32, 1), id2);
    try std.testing.expectEqual(@as(u32, 0), id3); // Same as id1
    
    try std.testing.expectEqualStrings("hello", dict.lookup(0).?);
    try std.testing.expectEqualStrings("world", dict.lookup(1).?);
}

test "dictionary chunk" {
    const allocator = std.testing.allocator;
    
    var chunk = DictionaryChunk.init(allocator);
    defer chunk.deinit(std.testing.allocator);
    
    try chunk.append(std.testing.allocator, "alice");
    try chunk.append(std.testing.allocator, "bob");
    try chunk.append(std.testing.allocator, "alice");
    try chunk.append(std.testing.allocator, null);
    
    try std.testing.expectEqual(@as(u64, 4), chunk.getNumValues());
    try std.testing.expectEqualStrings("alice", chunk.get(0).?);
    try std.testing.expectEqualStrings("bob", chunk.get(1).?);
    try std.testing.expectEqualStrings("alice", chunk.get(2).?);
    try std.testing.expect(chunk.get(3) == null);
}

test "dictionary column" {
    const allocator = std.testing.allocator;
    
    var col = DictionaryColumn.init(allocator, 0);
    defer col.deinit(std.testing.allocator);
    
    const chunk = try col.addChunk();
    try chunk.append(std.testing.allocator, "test");
    
    try std.testing.expectEqual(@as(usize, 1), col.getNumChunks());
}