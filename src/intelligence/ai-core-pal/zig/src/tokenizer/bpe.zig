//! Byte-Pair Encoding (BPE) Tokenizer
//! Compatible with Llama, GPT-2, and similar models
//! Supports loading tokenizer.json from HuggingFace Transformers

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.bpe_tokenizer);

// ============================================================================
// Token Types
// ============================================================================

pub const TokenId = u32;
pub const SpecialTokens = struct {
    pub const PAD: TokenId = 0;
    pub const UNK: TokenId = 1;
    pub const BOS: TokenId = 2;
    pub const EOS: TokenId = 3;
    pub const MASK: TokenId = 4;
};

// ============================================================================
// BPE Tokenizer
// ============================================================================

pub const BpeTokenizer = struct {
    allocator: Allocator,
    
    // Vocabulary: token string -> token ID
    vocab: std.StringHashMap(TokenId),
    // Reverse vocabulary: token ID -> token string
    id_to_token: std.AutoHashMap(TokenId, []const u8),
    
    // BPE merge rules: (token_a, token_b) -> merged_token
    merges: std.AutoHashMap(MergePair, TokenId),
    // Merge priority (lower = higher priority, applied first)
    merge_ranks: std.AutoHashMap(MergePair, u32),
    
    // Special tokens
    unk_token: TokenId,
    bos_token: ?TokenId,
    eos_token: ?TokenId,
    pad_token: ?TokenId,
    
    // Configuration
    vocab_size: usize,
    add_bos: bool,
    add_eos: bool,
    
    // Byte fallback for unknown characters
    byte_fallback: bool,
    
    pub fn init(allocator: Allocator) !*BpeTokenizer {
        const tokenizer = try allocator.create(BpeTokenizer);
        tokenizer.* = .{
            .allocator = allocator,
            .vocab = std.StringHashMap(TokenId).init(allocator),
            .id_to_token = std.AutoHashMap(TokenId, []const u8).init(allocator),
            .merges = std.AutoHashMap(MergePair, TokenId).init(allocator),
            .merge_ranks = std.AutoHashMap(MergePair, u32).init(allocator),
            .unk_token = SpecialTokens.UNK,
            .bos_token = SpecialTokens.BOS,
            .eos_token = SpecialTokens.EOS,
            .pad_token = SpecialTokens.PAD,
            .vocab_size = 0,
            .add_bos = true,
            .add_eos = true,
            .byte_fallback = true,
        };
        return tokenizer;
    }
    
    pub fn deinit(self: *BpeTokenizer) void {
        // Free owned strings in vocab
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
        self.merge_ranks.deinit();
        self.allocator.destroy(self);
    }
    
    /// Load tokenizer from HuggingFace tokenizer.json
    pub fn loadFromJson(self: *BpeTokenizer, json_path: []const u8) !void {
        log.info("Loading tokenizer from: {s}", .{json_path});
        
        const file = try std.fs.cwd().openFile(json_path, .{});
        defer file.close();
        
        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);
        
        _ = try file.readAll(buffer);
        
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, buffer, .{});
        defer parsed.deinit();
        
        try self.parseTokenizerJson(parsed.value);
        
        log.info("Loaded vocab size: {}", .{self.vocab_size});
    }
    
    fn parseTokenizerJson(self: *BpeTokenizer, json: std.json.Value) !void {
        const root = json.object;
        
        // Parse model section
        if (root.get("model")) |model| {
            const model_obj = model.object;
            
            // Parse vocabulary
            if (model_obj.get("vocab")) |vocab| {
                var vocab_it = vocab.object.iterator();
                while (vocab_it.next()) |entry| {
                    const token = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const id: TokenId = @intCast(entry.value_ptr.*.integer);
                    try self.vocab.put(token, id);
                    
                    const token_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                    try self.id_to_token.put(id, token_copy);
                }
                self.vocab_size = self.vocab.count();
            }
            
            // Parse merges
            if (model_obj.get("merges")) |merges| {
                var rank: u32 = 0;
                for (merges.array.items) |merge_item| {
                    const merge_str = merge_item.string;
                    
                    // Parse "token_a token_b" format
                    var parts = std.mem.splitScalar(u8, merge_str, ' ');
                    const first = parts.next() orelse continue;
                    const second = parts.next() orelse continue;
                    
                    const first_id = self.vocab.get(first) orelse continue;
                    const second_id = self.vocab.get(second) orelse continue;
                    
                    const pair = MergePair{ .first = first_id, .second = second_id };
                    
                    // Merged token is first+second concatenated
                    var merged_buf: [256]u8 = undefined;
                    const merged_len = first.len + second.len;
                    @memcpy(merged_buf[0..first.len], first);
                    @memcpy(merged_buf[first.len..merged_len], second);
                    
                    if (self.vocab.get(merged_buf[0..merged_len])) |merged_id| {
                        try self.merges.put(pair, merged_id);
                        try self.merge_ranks.put(pair, rank);
                    }
                    rank += 1;
                }
            }
        }
        
        // Parse added_tokens for special tokens
        if (root.get("added_tokens")) |added_tokens| {
            for (added_tokens.array.items) |token_obj| {
                const obj = token_obj.object;
                const content = obj.get("content").?.string;
                const id: TokenId = @intCast(obj.get("id").?.integer);
                
                if (std.mem.eql(u8, content, "<pad>") or std.mem.eql(u8, content, "[PAD]")) {
                    self.pad_token = id;
                } else if (std.mem.eql(u8, content, "<unk>") or std.mem.eql(u8, content, "[UNK]")) {
                    self.unk_token = id;
                } else if (std.mem.eql(u8, content, "<s>") or std.mem.eql(u8, content, "[CLS]") or std.mem.eql(u8, content, "<bos>")) {
                    self.bos_token = id;
                } else if (std.mem.eql(u8, content, "</s>") or std.mem.eql(u8, content, "[SEP]") or std.mem.eql(u8, content, "<eos>")) {
                    self.eos_token = id;
                }
            }
        }
    }
    
    /// Load vocabulary from simple vocab.txt (one token per line)
    pub fn loadFromVocabFile(self: *BpeTokenizer, vocab_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(vocab_path, .{});
        defer file.close();
        
        var id: TokenId = 0;
        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();
        
        var line_buf: [1024]u8 = undefined;
        while (try in_stream.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            if (line.len == 0) continue;
            
            const token = try self.allocator.dupe(u8, line);
            try self.vocab.put(token, id);
            
            const token_copy = try self.allocator.dupe(u8, line);
            try self.id_to_token.put(id, token_copy);
            
            id += 1;
        }
        
        self.vocab_size = id;
    }
    
    /// Load BPE merges from merges.txt
    pub fn loadMergesFile(self: *BpeTokenizer, merges_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(merges_path, .{});
        defer file.close();
        
        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();
        
        var line_buf: [1024]u8 = undefined;
        var rank: u32 = 0;
        
        // Skip header line "#version: 0.2"
        _ = try in_stream.readUntilDelimiterOrEof(&line_buf, '\n');
        
        while (try in_stream.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            
            var parts = std.mem.splitScalar(u8, line, ' ');
            const first_str = parts.next() orelse continue;
            const second_str = parts.next() orelse continue;
            
            const first_id = self.vocab.get(first_str) orelse continue;
            const second_id = self.vocab.get(second_str) orelse continue;
            
            const pair = MergePair{ .first = first_id, .second = second_id };
            
            // Find merged token
            var merged_buf: [256]u8 = undefined;
            const merged_len = first_str.len + second_str.len;
            @memcpy(merged_buf[0..first_str.len], first_str);
            @memcpy(merged_buf[first_str.len..merged_len], second_str);
            
            if (self.vocab.get(merged_buf[0..merged_len])) |merged_id| {
                try self.merges.put(pair, merged_id);
                try self.merge_ranks.put(pair, rank);
            }
            
            rank += 1;
        }
    }
    
    // =========================================================================
    // Encoding (text -> tokens)
    // =========================================================================
    
    /// Encode text to token IDs
    pub fn encode(self: *BpeTokenizer, text: []const u8) ![]TokenId {
        var tokens = std.ArrayList(TokenId).init(self.allocator);
        defer tokens.deinit();
        
        // Add BOS token
        if (self.add_bos) {
            if (self.bos_token) |bos| {
                try tokens.append(bos);
            }
        }
        
        // Pre-tokenize: split into words
        var words = try self.preTokenize(text);
        defer words.deinit();
        
        // BPE encode each word
        for (words.items) |word| {
            const word_tokens = try self.bpeEncode(word);
            defer self.allocator.free(word_tokens);
            
            for (word_tokens) |t| {
                try tokens.append(t);
            }
        }
        
        // Add EOS token
        if (self.add_eos) {
            if (self.eos_token) |eos| {
                try tokens.append(eos);
            }
        }
        
        return try tokens.toOwnedSlice();
    }
    
    /// Pre-tokenize text into words (GPT-2 style)
    fn preTokenize(self: *BpeTokenizer, text: []const u8) !std.ArrayListUnmanaged([]const u8) {
        var words: std.ArrayListUnmanaged([]const u8) = .{};
        
        var start: usize = 0;
        var i: usize = 0;
        
        while (i < text.len) {
            const c = text[i];
            
            // Split on whitespace, keeping leading space with word
            if (c == ' ' and i > start) {
                // End previous word
                const word = try self.allocator.dupe(u8, text[start..i]);
                try words.append(self.allocator, word);
                start = i;
            } else if (c == '\n' or c == '\r' or c == '\t') {
                // Split on newlines/tabs
                if (i > start) {
                    const word = try self.allocator.dupe(u8, text[start..i]);
                    try words.append(self.allocator, word);
                }
                start = i + 1;
            }
            
            i += 1;
        }
        
        // Add final word
        if (start < text.len) {
            const word = try self.allocator.dupe(u8, text[start..]);
            try words.append(self.allocator, word);
        }
        
        return words;
    }
    
    /// BPE encode a single word
    fn bpeEncode(self: *BpeTokenizer, word: []const u8) ![]TokenId {
        if (word.len == 0) return try self.allocator.alloc(TokenId, 0);
        
        // Initialize: each character is a token
        var token_ids = std.ArrayList(TokenId).init(self.allocator);
        defer token_ids.deinit();
        
        // First try to find the whole word in vocab
        if (self.vocab.get(word)) |id| {
            const result = try self.allocator.alloc(TokenId, 1);
            result[0] = id;
            return result;
        }
        
        // Convert to initial character tokens
        var i: usize = 0;
        while (i < word.len) {
            // Try to find longest matching token
            var best_len: usize = 1;
            var best_id: TokenId = self.unk_token;
            
            var j = @min(word.len, i + 16); // Max token length
            while (j > i) {
                if (self.vocab.get(word[i..j])) |id| {
                    best_len = j - i;
                    best_id = id;
                    break;
                }
                j -= 1;
            }
            
            // If no match and byte_fallback is enabled, use byte tokens
            if (best_id == self.unk_token and self.byte_fallback) {
                // Try single byte token like "<0x48>" for 'H'
                var byte_buf: [8]u8 = undefined;
                const byte_str = std.fmt.bufPrint(&byte_buf, "<0x{X:0>2}>", .{word[i]}) catch "";
                if (self.vocab.get(byte_str)) |id| {
                    best_id = id;
                }
            }
            
            try token_ids.append(best_id);
            i += best_len;
        }
        
        // Apply BPE merges iteratively
        try self.applyMerges(&token_ids);
        
        return try token_ids.toOwnedSlice();
    }
    
    /// Apply BPE merges until no more merges possible
    fn applyMerges(self: *BpeTokenizer, tokens: *std.ArrayList(TokenId)) !void {
        while (tokens.items.len > 1) {
            // Find best merge (lowest rank)
            var best_idx: ?usize = null;
            var best_rank: u32 = std.math.maxInt(u32);
            
            for (0..tokens.items.len - 1) |i| {
                const pair = MergePair{
                    .first = tokens.items[i],
                    .second = tokens.items[i + 1],
                };
                
                if (self.merge_ranks.get(pair)) |rank| {
                    if (rank < best_rank) {
                        best_rank = rank;
                        best_idx = i;
                    }
                }
            }
            
            // No more merges possible
            if (best_idx == null) break;
            
            // Apply the merge
            const idx = best_idx.?;
            const pair = MergePair{
                .first = tokens.items[idx],
                .second = tokens.items[idx + 1],
            };
            
            if (self.merges.get(pair)) |merged_id| {
                tokens.items[idx] = merged_id;
                _ = tokens.orderedRemove(idx + 1);
            } else {
                break;
            }
        }
    }
    
    // =========================================================================
    // Decoding (tokens -> text)
    // =========================================================================
    
    /// Decode token IDs back to text
    pub fn decode(self: *BpeTokenizer, tokens: []const TokenId) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        for (tokens) |token_id| {
            // Skip special tokens in output
            if (self.bos_token) |bos| {
                if (token_id == bos) continue;
            }
            if (self.eos_token) |eos| {
                if (token_id == eos) continue;
            }
            if (self.pad_token) |pad| {
                if (token_id == pad) continue;
            }
            
            if (self.id_to_token.get(token_id)) |token_str| {
                try result.appendSlice(token_str);
            } else {
                // Unknown token - use replacement character
                try result.appendSlice("�");
            }
        }
        
        return try result.toOwnedSlice();
    }
    
    // =========================================================================
    // Utility functions
    // =========================================================================
    
    /// Get vocabulary size
    pub fn getVocabSize(self: *const BpeTokenizer) usize {
        return self.vocab_size;
    }
    
    /// Check if a token ID is a special token
    pub fn isSpecialToken(self: *const BpeTokenizer, token_id: TokenId) bool {
        if (self.bos_token) |bos| {
            if (token_id == bos) return true;
        }
        if (self.eos_token) |eos| {
            if (token_id == eos) return true;
        }
        if (self.pad_token) |pad| {
            if (token_id == pad) return true;
        }
        if (token_id == self.unk_token) return true;
        return false;
    }
    
    /// Get token string for a token ID
    pub fn getTokenString(self: *const BpeTokenizer, token_id: TokenId) ?[]const u8 {
        return self.id_to_token.get(token_id);
    }
    
    /// Get token ID for a token string
    pub fn getTokenId(self: *const BpeTokenizer, token: []const u8) ?TokenId {
        return self.vocab.get(token);
    }
};

// ============================================================================
// Merge Pair
// ============================================================================

pub const MergePair = struct {
    first: TokenId,
    second: TokenId,
    
    pub fn hash(self: MergePair) u64 {
        return @as(u64, self.first) << 32 | @as(u64, self.second);
    }
};

// ============================================================================
// Simple Whitespace Tokenizer (fallback)
// ============================================================================

pub const SimpleTokenizer = struct {
    allocator: Allocator,
    vocab: std.StringHashMap(TokenId),
    id_to_token: std.AutoHashMap(TokenId, []const u8),
    next_id: TokenId,
    
    pub fn init(allocator: Allocator) !*SimpleTokenizer {
        const tok = try allocator.create(SimpleTokenizer);
        tok.* = .{
            .allocator = allocator,
            .vocab = std.StringHashMap(TokenId).init(allocator),
            .id_to_token = std.AutoHashMap(TokenId, []const u8).init(allocator),
            .next_id = 256, // Reserve 0-255 for bytes
        };
        
        // Add byte tokens
        for (0..256) |byte| {
            var buf: [1]u8 = .{@intCast(byte)};
            const token = try allocator.dupe(u8, &buf);
            try tok.vocab.put(token, @intCast(byte));
            
            const token_copy = try allocator.dupe(u8, &buf);
            try tok.id_to_token.put(@intCast(byte), token_copy);
        }
        
        return tok;
    }
    
    pub fn deinit(self: *SimpleTokenizer) void {
        var it = self.vocab.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.vocab.deinit();
        
        var id_it = self.id_to_token.iterator();
        while (id_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.id_to_token.deinit();
        
        self.allocator.destroy(self);
    }
    
    /// Encode text to bytes
    pub fn encode(self: *SimpleTokenizer, text: []const u8) ![]TokenId {
        const tokens = try self.allocator.alloc(TokenId, text.len);
        for (text, 0..) |c, i| {
            tokens[i] = @intCast(c);
        }
        return tokens;
    }
    
    /// Decode tokens to text
    pub fn decode(self: *SimpleTokenizer, tokens: []const TokenId) ![]u8 {
        const text = try self.allocator.alloc(u8, tokens.len);
        for (tokens, 0..) |t, i| {
            text[i] = @intCast(t & 0xFF);
        }
        return text;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BpeTokenizer init/deinit" {
    const allocator = std.testing.allocator;
    const tok = try BpeTokenizer.init(allocator);
    defer tok.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), tok.vocab_size);
}

test "SimpleTokenizer encode/decode" {
    const allocator = std.testing.allocator;
    const tok = try SimpleTokenizer.init(allocator);
    defer tok.deinit();
    
    const text = "Hello";
    const tokens = try tok.encode(text);
    defer allocator.free(tokens);
    
    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqual(@as(TokenId, 'H'), tokens[0]);
    try std.testing.expectEqual(@as(TokenId, 'e'), tokens[1]);
    
    const decoded = try tok.decode(tokens);
    defer allocator.free(decoded);
    
    try std.testing.expectEqualStrings("Hello", decoded);
}

test "BpeTokenizer preTokenize" {
    const allocator = std.testing.allocator;
    const tok = try BpeTokenizer.init(allocator);
    defer tok.deinit();
    
    var words = try tok.preTokenize("Hello World");
    defer {
        for (words.items) |w| allocator.free(w);
        words.deinit(allocator);
    }
    
    try std.testing.expectEqual(@as(usize, 2), words.items.len);
    try std.testing.expectEqualStrings("Hello", words.items[0]);
    try std.testing.expectEqualStrings(" World", words.items[1]);
}

test "MergePair hash" {
    const pair1 = MergePair{ .first = 100, .second = 200 };
    const pair2 = MergePair{ .first = 100, .second = 200 };
    const pair3 = MergePair{ .first = 200, .second = 100 };
    
    try std.testing.expectEqual(pair1.hash(), pair2.hash());
    try std.testing.expect(pair1.hash() != pair3.hash());
}