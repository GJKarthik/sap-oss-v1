//! BPE Tokenizer for PrivateLLM
//!
//! Self-contained byte-level BPE tokenizer supporting encoding (text → token IDs)
//! and decoding (token IDs → text). Loads vocabulary from a simple vocab file
//! (one token per line, line number = token ID).

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Token Types & Special Tokens
// ============================================================================

pub const TokenId = u32;

pub const PAD: TokenId = 0;
pub const UNK: TokenId = 1;
pub const BOS: TokenId = 2;
pub const EOS: TokenId = 3;

// ============================================================================
// Tokenizer
// ============================================================================

pub const Tokenizer = struct {
    allocator: Allocator,
    /// token string → token ID
    vocab: std.StringHashMap(TokenId),
    /// token ID → token string
    id_to_token: std.AutoHashMap(TokenId, []const u8),
    /// BPE merge pairs: (first_id, second_id) → merged_id, ordered by rank
    merges: std.AutoHashMap(MergePair, MergeResult),
    next_id: TokenId,

    const MergePair = struct { first: TokenId, second: TokenId };
    const MergeResult = struct { merged_id: TokenId, rank: u32 };

    pub fn init(allocator: Allocator) Tokenizer {
        return .{
            .allocator = allocator,
            .vocab = std.StringHashMap(TokenId).init(allocator),
            .id_to_token = std.AutoHashMap(TokenId, []const u8).init(allocator),
            .merges = std.AutoHashMap(MergePair, MergeResult).init(allocator),
            .next_id = 4, // reserve 0-3 for special tokens
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        var vocab_it = self.vocab.iterator();
        while (vocab_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.vocab.deinit();

        var id_it = self.id_to_token.iterator();
        while (id_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.id_to_token.deinit();

        self.merges.deinit();
    }

    /// Return the number of tokens in the vocabulary (including special tokens).
    pub fn vocabSize(self: *const Tokenizer) usize {
        return @intCast(self.next_id);
    }

    /// Manually add a token with a specific ID.
    pub fn addToken(self: *Tokenizer, text: []const u8, id: TokenId) !void {
        const key = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(key);
        const val = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(val);

        try self.vocab.put(key, id);
        try self.id_to_token.put(id, val);

        if (id >= self.next_id) {
            self.next_id = id + 1;
        }
    }

    /// Add a BPE merge rule: first + second → merged token at given rank.
    /// Lower rank = higher priority (applied first during encoding).
    /// The merged token is auto-created in the vocabulary if absent.
    pub fn addMerge(self: *Tokenizer, first: []const u8, second: []const u8, rank: u32) !void {
        const first_id = self.vocab.get(first) orelse return error.TokenNotFound;
        const second_id = self.vocab.get(second) orelse return error.TokenNotFound;
        var merged_buf: [256]u8 = undefined;
        const merged_len = first.len + second.len;
        if (merged_len > merged_buf.len) return error.Overflow;
        @memcpy(merged_buf[0..first.len], first);
        @memcpy(merged_buf[first.len..merged_len], second);
        const merged_id = self.vocab.get(merged_buf[0..merged_len]) orelse blk: {
            const id = self.next_id;
            try self.addToken(merged_buf[0..merged_len], id);
            break :blk id;
        };
        const pair = MergePair{ .first = first_id, .second = second_id };
        try self.merges.put(pair, MergeResult{ .merged_id = merged_id, .rank = rank });
    }


    /// Load vocabulary from a file (one token per line, line number = token ID starting at 0).
    pub fn loadVocab(self: *Tokenizer, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        const reader = buf_reader.reader();

        var id: TokenId = 0;
        var line_buf: [1024]u8 = undefined;
        while (true) {
            const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    id += 1;
                    continue;
                },
                else => return err,
            };
            if (line == null) break;
            const l = line.?;
            if (l.len == 0) {
                id += 1;
                continue;
            }

            const key = try self.allocator.dupe(u8, l);
            errdefer self.allocator.free(key);
            const val = try self.allocator.dupe(u8, l);
            errdefer self.allocator.free(val);

            try self.vocab.put(key, id);
            try self.id_to_token.put(id, val);
            id += 1;
        }
        if (id > self.next_id) {
            self.next_id = id;
        }
    }

    /// Load BPE merge rules from a merges.txt file (HuggingFace format).
    /// Format: one "first second" pair per line; rank = line order.
    /// Lines starting with '#' are treated as comments/headers.
    pub fn loadMergesFile(self: *Tokenizer, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var buf_reader = std.io.bufferedReader(file.reader());
        const reader = buf_reader.reader();
        var line_buf: [1024]u8 = undefined;
        var rank: u32 = 0;
        while (true) {
            const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    rank += 1;
                    continue;
                },
                else => return err,
            };
            if (line == null) break;
            const l = line.?;
            if (l.len == 0 or l[0] == '#') continue;
            var parts = std.mem.splitScalar(u8, l, ' ');
            const first = parts.next() orelse continue;
            const second = parts.next() orelse continue;
            self.addMerge(first, second, rank) catch {};
            rank += 1;
        }
    }


    /// Encode text into a sequence of token IDs.
    /// When BPE merges are loaded, uses character-level tokenisation followed
    /// by iterative pair merging (real BPE).  Otherwise falls back to greedy
    /// longest-match with byte fallback for unknown characters.
    pub fn encode(self: *Tokenizer, text: []const u8) ![]TokenId {
        var tokens: std.ArrayListUnmanaged(TokenId) = .{};
        errdefer tokens.deinit();

        if (self.merges.count() > 0) {
            // ---- BPE mode: character-level init + iterative merging ----
            for (0..text.len) |idx| {
                if (self.vocab.get(text[idx .. idx + 1])) |id| {
                    try tokens.append(id);
                } else {
                    var byte_buf: [8]u8 = undefined;
                    const byte_str = std.fmt.bufPrint(&byte_buf, "<0x{X:0>2}>", .{text[idx]}) catch {
                        try tokens.append(UNK);
                        continue;
                    };
                    if (self.vocab.get(byte_str)) |id| {
                        try tokens.append(id);
                    } else {
                        try tokens.append(UNK);
                    }
                }
            }
            self.applyMerges(&tokens);
        } else {
            // ---- Greedy longest-match mode (no merges loaded) ----
            var i: usize = 0;
            while (i < text.len) {
                var best_len: usize = 0;
                var best_id: TokenId = UNK;
                var j: usize = @min(text.len, i + 32);
                while (j > i) : (j -= 1) {
                    if (self.vocab.get(text[i..j])) |id| {
                        best_len = j - i;
                        best_id = id;
                        break;
                    }
                }
                if (best_len > 0) {
                    try tokens.append(best_id);
                    i += best_len;
                    continue;
                }
                var byte_buf: [8]u8 = undefined;
                const byte_str = std.fmt.bufPrint(&byte_buf, "<0x{X:0>2}>", .{text[i]}) catch {
                    try tokens.append(UNK);
                    i += 1;
                    continue;
                };
                if (self.vocab.get(byte_str)) |id| {
                    try tokens.append(id);
                } else {
                    try tokens.append(UNK);
                }
                i += 1;
            }
        }

        return tokens.toOwnedSlice();
    }

    /// Apply BPE merges iteratively until no more merges are possible.
    /// Each round finds the highest-priority (lowest rank) adjacent pair
    /// and replaces it with the merged token.
    fn applyMerges(self: *const Tokenizer, tokens: *std.ArrayListUnmanaged(TokenId)) void {
        while (tokens.items.len > 1) {
            var best_idx: ?usize = null;
            var best_rank: u32 = std.math.maxInt(u32);
            for (0..tokens.items.len - 1) |i| {
                const pair = MergePair{
                    .first = tokens.items[i],
                    .second = tokens.items[i + 1],
                };
                if (self.merges.get(pair)) |result| {
                    if (result.rank < best_rank) {
                        best_rank = result.rank;
                        best_idx = i;
                    }
                }
            }
            if (best_idx == null) break;
            const idx = best_idx.?;
            const pair = MergePair{
                .first = tokens.items[idx],
                .second = tokens.items[idx + 1],
            };
            tokens.items[idx] = self.merges.get(pair).?.merged_id;
            _ = tokens.orderedRemove(idx + 1);
        }
    }

    /// Decode a sequence of token IDs back into text.
    pub fn decode(self: *Tokenizer, ids: []const TokenId) ![]u8 {
        var result: std.ArrayListUnmanaged(u8) = .{};
        errdefer result.deinit();

        for (ids) |id| {
            // Skip PAD tokens in output
            if (id == PAD) continue;

            if (self.id_to_token.get(id)) |token_str| {
                // Check for byte-fallback tokens like <0x41>
                if (token_str.len == 6 and token_str[0] == '<' and token_str[1] == '0' and token_str[2] == 'x' and token_str[5] == '>') {
                    const byte_val = std.fmt.parseInt(u8, token_str[3..5], 16) catch {
                        try result.appendSlice(token_str);
                        continue;
                    };
                    try result.append(byte_val);
                } else {
                    try result.appendSlice(token_str);
                }
            } else {
                // Unknown token ID → replacement character
                try result.appendSlice("\xEF\xBF\xBD"); // U+FFFD
            }
        }

        return result.toOwnedSlice();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "init and deinit" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    try std.testing.expectEqual(@as(usize, 4), tok.vocabSize()); // 4 reserved special tokens
}

test "addToken" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    try tok.addToken("hello", 10);
    try tok.addToken("world", 11);

    try std.testing.expectEqual(@as(usize, 12), tok.vocabSize());
    try std.testing.expectEqual(@as(?TokenId, 10), tok.vocab.get("hello"));
    try std.testing.expectEqual(@as(?TokenId, 11), tok.vocab.get("world"));
    try std.testing.expectEqualStrings("hello", tok.id_to_token.get(10).?);
}

test "encode and decode roundtrip" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    try tok.addToken("he", 10);
    try tok.addToken("llo", 11);
    try tok.addToken(" ", 12);
    try tok.addToken("world", 13);

    const ids = try tok.encode("hello world");
    defer std.testing.allocator.free(ids);

    try std.testing.expectEqual(@as(usize, 4), ids.len);
    try std.testing.expectEqual(@as(TokenId, 10), ids[0]); // "he"
    try std.testing.expectEqual(@as(TokenId, 11), ids[1]); // "llo"
    try std.testing.expectEqual(@as(TokenId, 12), ids[2]); // " "
    try std.testing.expectEqual(@as(TokenId, 13), ids[3]); // "world"

    const text = try tok.decode(ids);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("hello world", text);
}

test "byte fallback for unknown characters" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    // Add byte-fallback tokens for ASCII range we'll test
    try tok.addToken("<0x48>", 100); // 'H' = 0x48
    try tok.addToken("<0x69>", 101); // 'i' = 0x69

    const ids = try tok.encode("Hi");
    defer std.testing.allocator.free(ids);

    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(@as(TokenId, 100), ids[0]);
    try std.testing.expectEqual(@as(TokenId, 101), ids[1]);

    // Decode should reconstruct the original bytes
    const text = try tok.decode(ids);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("Hi", text);
}

test "unknown bytes produce UNK token" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    // No vocab at all — everything should be UNK
    const ids = try tok.encode("ab");
    defer std.testing.allocator.free(ids);

    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(UNK, ids[0]);
    try std.testing.expectEqual(UNK, ids[1]);
}

test "BPE merge full encoding" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    // Add single-character tokens
    try tok.addToken("h", 10);
    try tok.addToken("e", 11);
    try tok.addToken("l", 12);
    try tok.addToken("o", 13);

    // BPE merges in rank order: h+e→he, l+l→ll, he+ll→hell, hell+o→hello
    try tok.addMerge("h", "e", 0); // "he" auto-created as id=14
    try tok.addMerge("l", "l", 1); // "ll" auto-created as id=15
    try tok.addMerge("he", "ll", 2); // "hell" auto-created as id=16
    try tok.addMerge("hell", "o", 3); // "hello" auto-created as id=17

    const ids = try tok.encode("hello");
    defer std.testing.allocator.free(ids);

    // All characters should merge into single "hello" token
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    try std.testing.expectEqual(@as(TokenId, 17), ids[0]);

    // Roundtrip decode
    const text = try tok.decode(ids);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "BPE partial merge" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    try tok.addToken("a", 10);
    try tok.addToken("b", 11);
    try tok.addToken("c", 12);

    // Only merge a+b→ab (rank 0); no merge for ab+c
    try tok.addMerge("a", "b", 0); // "ab" auto-created as id=13

    const ids = try tok.encode("abc");
    defer std.testing.allocator.free(ids);

    // "a"+"b" merge to "ab", "c" stays
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(@as(TokenId, 13), ids[0]); // "ab"
    try std.testing.expectEqual(@as(TokenId, 12), ids[1]); // "c"
}

test "BPE rank priority selects lowest rank first" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    try tok.addToken("a", 10);
    try tok.addToken("b", 11);
    try tok.addToken("c", 12);

    // Two possible merges for "abc": a+b (rank 5) vs b+c (rank 1)
    // BPE should pick b+c first (lower rank = higher priority)
    try tok.addMerge("b", "c", 1); // "bc" = id 13
    try tok.addMerge("a", "b", 5); // "ab" = id 14

    const ids = try tok.encode("abc");
    defer std.testing.allocator.free(ids);

    // b+c merges first → "a" + "bc"
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(@as(TokenId, 10), ids[0]); // "a"
    try std.testing.expectEqual(@as(TokenId, 13), ids[1]); // "bc"
}
