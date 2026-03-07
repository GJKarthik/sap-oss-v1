//! GGUF BPE Tokenizer
//!
//! Loads vocabulary, scores, and merge rules directly from a GGUF file's
//! metadata arrays (`tokenizer.ggml.tokens`, `tokenizer.ggml.scores`,
//! `tokenizer.ggml.merges`) and implements greedy BPE encode/decode.
//!
//! Works generically with any GGUF model (LLaMA, Mistral, Phi, Gemma, Qwen).
//! Falls back gracefully if merge rules are absent (vocab-only lookup).
//!
//! Also auto-detects the chat template style and model architecture from GGUF
//! metadata so the inference engine can format prompts correctly without
//! hardcoding model-specific templates.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.gguf_tokenizer);

// ============================================================================
// GGUF constants (duplicated here so this file is self-contained)
// ============================================================================

const GGUF_MAGIC: u32 = 0x46554747; // "GGUF"

// GGUF value type tags
const VTYPE_UINT8: u32 = 0;
const VTYPE_INT8: u32 = 1;
const VTYPE_UINT16: u32 = 2;
const VTYPE_INT16: u32 = 3;
const VTYPE_UINT32: u32 = 4;
const VTYPE_INT32: u32 = 5;
const VTYPE_FLOAT32: u32 = 6;
const VTYPE_BOOL: u32 = 7;
const VTYPE_STRING: u32 = 8;
const VTYPE_ARRAY: u32 = 9;
const VTYPE_UINT64: u32 = 10;
const VTYPE_INT64: u32 = 11;
const VTYPE_FLOAT64: u32 = 12;

// Well-known special token strings used for chat template detection.
// Stored as constants so vocab-scan uses exact-match.
const TOK_IM_START = "<" ++ "|im_start|" ++ ">";
const TOK_IM_END = "<" ++ "|im_end|" ++ ">";
const TOK_ENDOFTEXT = "<" ++ "|endoftext|" ++ ">";
const TOK_EOT_ID = "<" ++ "|eot_id|" ++ ">";
const TOK_START_HEADER = "<" ++ "|start_header_id|" ++ ">";
const TOK_END_HEADER = "<" ++ "|end_header_id|" ++ ">";
const TOK_BEGIN_OF_TEXT = "<" ++ "|begin_of_text|" ++ ">";

// ============================================================================
// Public types
// ============================================================================

/// A BPE merge pair: two token IDs that merge into `result`.
pub const MergePair = struct {
    left: u32,
    right: u32,
    result: u32,
    score: f32,
};

/// Chat template style auto-detected from GGUF metadata.
/// Used by the inference engine to format prompts correctly for each model family.
pub const ChatTemplateStyle = enum {
    chatml,   // Qwen, Yi, OpenChat — im_start/im_end
    llama3,   // LLaMA-3 — start_header_id/end_header_id/eot_id
    zephyr,   // Zephyr/old-Mistral — system/user/assistant tags with </s>
    mistral,  // Mistral-Instruct — [INST] / [/INST]
    generic,  // Unknown model — plain text, no special framing

    pub fn name(self: ChatTemplateStyle) []const u8 {
        return switch (self) {
            .chatml => "chatml",
            .llama3 => "llama3",
            .zephyr => "zephyr",
            .mistral => "mistral",
            .generic => "generic",
        };
    }
};

/// Generic GGUF BPE tokenizer loaded from a model file.
pub const GgufTokenizer = struct {
    allocator: Allocator,
    /// token_id -> string slice (owned, allocated from allocator)
    vocab: [][]const u8,
    /// token_id -> BPE score (lower = higher priority merge)
    scores: []f32,
    /// string -> token_id lookup
    token_to_id: std.StringHashMap(u32),
    /// BPE merge rules, sorted by score ascending (lower score = apply first)
    merges: []MergePair,
    /// Merge lookup: (left, right) -> result token id
    merge_map: MergeMap,

    bos_id: u32 = 1,
    eos_id: u32 = 2,
    unk_id: u32 = 0,

    // -- Additional special token IDs detected from vocab --
    im_start_id: ?u32 = null,
    im_end_id: ?u32 = null,
    eot_id: ?u32 = null,        // endoftext or eot_id
    start_header_id: ?u32 = null,

    // -- Model metadata detected from GGUF --
    chat_style: ChatTemplateStyle = .generic,
    /// Architecture string from general.architecture (e.g. "qwen2", "llama")
    model_arch: [64]u8 = [_]u8{0} ** 64,
    model_arch_len: u8 = 0,

    const MergeMap = std.AutoHashMap(u64, u32);

    // =========================================================================
    // Init / deinit
    // =========================================================================

    /// Load tokenizer from a GGUF file at `path`.
    pub fn loadFromGGUF(allocator: Allocator, path: []const u8) !*GgufTokenizer {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const file_size: usize = @intCast(stat.size);
        if (file_size < 24) return error.InvalidGGUF;

        const data = try allocator.alloc(u8, file_size);
        defer allocator.free(data);

        var off: usize = 0;
        while (off < file_size) {
            const n = try file.read(data[off..]);
            if (n == 0) return error.UnexpectedEOF;
            off += n;
        }

        const magic = std.mem.readInt(u32, data[0..4], .little);
        if (magic != GGUF_MAGIC) return error.InvalidGGUF;
        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version < 2 or version > 3) return error.UnsupportedGGUFVersion;
        const n_kv = std.mem.readInt(u64, data[16..24], .little);

        const tok = try allocator.create(GgufTokenizer);
        tok.* = .{
            .allocator = allocator,
            .vocab = &.{},
            .scores = &.{},
            .token_to_id = std.StringHashMap(u32).init(allocator),
            .merges = &.{},
            .merge_map = MergeMap.init(allocator),
        };
        errdefer tok.deinit();

        try tok.parseMetadata(data, 24, n_kv);

        // Detect special token IDs from vocab strings
        for (tok.vocab, 0..) |s, id| {
            const tid: u32 = @intCast(id);
            if (std.mem.eql(u8, s, "<s>") or std.mem.eql(u8, s, "<bos>")) tok.bos_id = tid;
            if (std.mem.eql(u8, s, "</s>") or std.mem.eql(u8, s, "<eos>")) tok.eos_id = tid;
            if (std.mem.eql(u8, s, "<unk>")) tok.unk_id = tid;
            // ChatML tokens
            if (std.mem.eql(u8, s, TOK_IM_START)) tok.im_start_id = tid;
            if (std.mem.eql(u8, s, TOK_IM_END)) tok.im_end_id = tid;
            if (std.mem.eql(u8, s, TOK_ENDOFTEXT)) tok.eot_id = tid;
            // LLaMA-3 tokens
            if (std.mem.eql(u8, s, TOK_EOT_ID)) tok.eot_id = tid;
            if (std.mem.eql(u8, s, TOK_START_HEADER)) tok.start_header_id = tid;
        }

        // Auto-detect chat template style from metadata + vocab
        tok.chat_style = tok.detectChatStyle();

        log.info("GgufTokenizer loaded: vocab={} merges={} arch={s} chat_style={s}", .{
            tok.vocab.len,
            tok.merges.len,
            tok.getModelArch(),
            tok.chat_style.name(),
        });
        return tok;
    }

    pub fn deinit(self: *GgufTokenizer) void {
        for (self.vocab) |s| self.allocator.free(s);
        self.allocator.free(self.vocab);
        self.allocator.free(self.scores);
        self.token_to_id.deinit();
        self.allocator.free(self.merges);
        self.merge_map.deinit();
        self.allocator.destroy(self);
    }

    /// Return the model architecture string (e.g. "qwen2", "llama").
    pub fn getModelArch(self: *const GgufTokenizer) []const u8 {
        if (self.model_arch_len == 0) return "unknown";
        return self.model_arch[0..self.model_arch_len];
    }

    // =========================================================================
    // Chat template detection
    // =========================================================================

    /// Detect chat template style from GGUF metadata and vocab special tokens.
    /// Priority: 1) vocab special tokens, 2) architecture name heuristic.
    fn detectChatStyle(self: *const GgufTokenizer) ChatTemplateStyle {
        // ChatML: has im_start + im_end tokens (Qwen, Yi, OpenChat, etc.)
        if (self.im_start_id != null and self.im_end_id != null) return .chatml;

        // LLaMA-3: has start_header_id + eot_id
        if (self.start_header_id != null and self.eot_id != null) return .llama3;

        // Mistral-Instruct: check vocab for [INST] token
        if (self.token_to_id.get("[INST]") != null) return .mistral;

        // Architecture-based fallback
        const arch = self.getModelArch();
        if (std.mem.startsWith(u8, arch, "qwen")) return .chatml;
        if (std.mem.startsWith(u8, arch, "llama")) return .llama3;
        if (std.mem.startsWith(u8, arch, "mistral")) return .mistral;
        if (std.mem.startsWith(u8, arch, "phi")) return .chatml;
        if (std.mem.startsWith(u8, arch, "gemma")) return .generic;

        return .generic;
    }

    // =========================================================================
    // EOS detection (multi-token aware)
    // =========================================================================

    /// Check whether a token signals end-of-sequence.
    /// Handles model families that use different EOS tokens:
    ///   - standard eos_id (</s>, <eos>)
    ///   - ChatML im_end
    ///   - LLaMA-3 eot_id
    ///   - endoftext
    pub fn isEos(self: *const GgufTokenizer, token: u32) bool {
        if (token == self.eos_id) return true;
        if (self.im_end_id) |id| { if (token == id) return true; }
        if (self.eot_id) |id| { if (token == id) return true; }
        return false;
    }

    // =========================================================================
    // Chat prompt builder (token-ID based, no hardcoded template strings)
    // =========================================================================

    /// Build a complete chat prompt as token IDs using the detected chat template.
    /// Special tokens are inserted as raw IDs; text content is BPE-encoded.
    /// This is the production-grade approach: no template strings, works for any model.
    /// Caller owns the returned slice.
    pub fn buildChatTokens(
        self: *const GgufTokenizer,
        system_text: []const u8,
        user_text: []const u8,
    ) ![]u32 {
        var tokens: std.ArrayListUnmanaged(u32) = .empty;
        errdefer tokens.deinit(self.allocator);

        switch (self.chat_style) {
            .chatml => try self.buildChatML(&tokens, system_text, user_text),
            .llama3 => try self.buildLlama3(&tokens, system_text, user_text),
            .mistral => try self.buildMistral(&tokens, system_text, user_text),
            .zephyr => try self.buildZephyr(&tokens, system_text, user_text),
            .generic => try self.buildGeneric(&tokens, system_text, user_text),
        }

        // Log first few token IDs for debugging tokenization
        if (tokens.items.len >= 6) {
            log.info("buildChatTokens: style={s} n={} first6=[{},{},{},{},{},{}]", .{
                self.chat_style.name(), tokens.items.len,
                tokens.items[0], tokens.items[1], tokens.items[2],
                tokens.items[3], tokens.items[4], tokens.items[5],
            });
        }

        return try tokens.toOwnedSlice(self.allocator);
    }

    // -- ChatML: im_start + "role\n" + content + "\n" + im_end --
    // NOTE: ChatML models (Qwen, Yi, etc.) do NOT prepend BOS.
    // The sequence starts directly with im_start.
    fn buildChatML(self: *const GgufTokenizer, tokens: *std.ArrayListUnmanaged(u32), system: []const u8, user: []const u8) !void {
        const im_s = self.im_start_id orelse self.bos_id;
        const im_e = self.im_end_id orelse self.eos_id;
        // System turn (no BOS for ChatML)
        try tokens.append(self.allocator, im_s);
        try self.appendEncoded(tokens, "system\n");
        try self.appendEncoded(tokens, system);
        try self.appendEncoded(tokens, "\n");
        try tokens.append(self.allocator, im_e);
        try self.appendEncoded(tokens, "\n");
        // User turn
        try tokens.append(self.allocator, im_s);
        try self.appendEncoded(tokens, "user\n");
        try self.appendEncoded(tokens, user);
        try self.appendEncoded(tokens, "\n");
        try tokens.append(self.allocator, im_e);
        try self.appendEncoded(tokens, "\n");
        // Assistant turn (model generates from here)
        try tokens.append(self.allocator, im_s);
        try self.appendEncoded(tokens, "assistant\n");
    }

    // -- LLaMA-3: begin_of_text + header tags + eot_id --
    fn buildLlama3(self: *const GgufTokenizer, tokens: *std.ArrayListUnmanaged(u32), system: []const u8, user: []const u8) !void {
        const sh_s = self.start_header_id orelse self.bos_id;
        const eot = self.eot_id orelse self.eos_id;
        // Look up end_header token
        const sh_e = self.token_to_id.get(TOK_END_HEADER) orelse self.eos_id;
        const bot = self.token_to_id.get(TOK_BEGIN_OF_TEXT) orelse self.bos_id;
        // begin_of_text
        try tokens.append(self.allocator, bot);
        // System
        try tokens.append(self.allocator, sh_s);
        try self.appendEncoded(tokens, "system");
        try tokens.append(self.allocator, sh_e);
        try self.appendEncoded(tokens, "\n\n");
        try self.appendEncoded(tokens, system);
        try tokens.append(self.allocator, eot);
        // User
        try tokens.append(self.allocator, sh_s);
        try self.appendEncoded(tokens, "user");
        try tokens.append(self.allocator, sh_e);
        try self.appendEncoded(tokens, "\n\n");
        try self.appendEncoded(tokens, user);
        try tokens.append(self.allocator, eot);
        // Assistant
        try tokens.append(self.allocator, sh_s);
        try self.appendEncoded(tokens, "assistant");
        try tokens.append(self.allocator, sh_e);
        try self.appendEncoded(tokens, "\n\n");
    }

    // -- Mistral-Instruct: BOS + [INST] system \n\n user [/INST] --
    fn buildMistral(self: *const GgufTokenizer, tokens: *std.ArrayListUnmanaged(u32), system: []const u8, user: []const u8) !void {
        try tokens.append(self.allocator, self.bos_id);
        try self.appendEncoded(tokens, "[INST] ");
        try self.appendEncoded(tokens, system);
        try self.appendEncoded(tokens, "\n\n");
        try self.appendEncoded(tokens, user);
        try self.appendEncoded(tokens, " [/INST]");
    }

    // -- Zephyr: BOS + role tags with </s> separators --
    fn buildZephyr(self: *const GgufTokenizer, tokens: *std.ArrayListUnmanaged(u32), system: []const u8, user: []const u8) !void {
        try tokens.append(self.allocator, self.bos_id);
        try self.appendEncoded(tokens, "system\n");
        try self.appendEncoded(tokens, system);
        try tokens.append(self.allocator, self.eos_id);
        try self.appendEncoded(tokens, "\n");
        try self.appendEncoded(tokens, "user\n");
        try self.appendEncoded(tokens, user);
        try tokens.append(self.allocator, self.eos_id);
        try self.appendEncoded(tokens, "\n");
        try self.appendEncoded(tokens, "assistant\n");
    }

    // -- Generic: plain text, no special tokens --
    fn buildGeneric(self: *const GgufTokenizer, tokens: *std.ArrayListUnmanaged(u32), system: []const u8, user: []const u8) !void {
        try tokens.append(self.allocator, self.bos_id);
        try self.appendEncoded(tokens, "System: ");
        try self.appendEncoded(tokens, system);
        try self.appendEncoded(tokens, "\n\nUser: ");
        try self.appendEncoded(tokens, user);
        try self.appendEncoded(tokens, "\n\nAssistant:");
    }

    /// Encode text via BPE and append the resulting token IDs (without BOS) to `out`.
    fn appendEncoded(self: *const GgufTokenizer, out: *std.ArrayListUnmanaged(u32), text: []const u8) !void {
        const encoded = try self.encodeRaw(text);
        defer self.allocator.free(encoded);
        try out.appendSlice(self.allocator, encoded);
    }

    /// Encode text to token IDs via BPE but WITHOUT prepending BOS.
    /// Handles GPT-2/tiktoken byte-to-unicode mapping automatically:
    /// if the vocab stores bytes as shifted unicode (Qwen, GPT-2, etc.),
    /// each input byte is mapped through the byte-to-unicode table before
    /// vocab lookup.
    pub fn encodeRaw(self: *const GgufTokenizer, text: []const u8) ![]u32 {
        // Convert raw bytes to the vocab's representation.
        // For tiktoken-style tokenizers (Qwen, GPT-4, etc.), bytes like
        // newline (0x0A) and space (0x20) are stored as shifted unicode
        // characters (e.g. 0x0A -> U+010A encoded as 0xC4 0x8A in UTF-8).
        // We detect this by checking if raw "\n" is absent from vocab.
        const use_byte_map = (self.token_to_id.get("\n") == null);

        var mapped = std.ArrayListUnmanaged(u8){};
        defer mapped.deinit(self.allocator);

        if (use_byte_map) {
            // Apply GPT-2 byte-to-unicode mapping
            for (text) |byte| {
                const cp = byteToUnicode(byte);
                // Encode codepoint as UTF-8
                if (cp < 0x80) {
                    try mapped.append(self.allocator, @intCast(cp));
                } else if (cp < 0x800) {
                    try mapped.append(self.allocator, @intCast(0xC0 | (cp >> 6)));
                    try mapped.append(self.allocator, @intCast(0x80 | (cp & 0x3F)));
                }
            }
        } else {
            try mapped.appendSlice(self.allocator, text);
        }

        const src = mapped.items;
        var symbols: std.ArrayListUnmanaged(u32) = .empty;
        errdefer symbols.deinit(self.allocator);

        // Longest-match tokenization against vocab
        var i: usize = 0;
        while (i < src.len) {
            var matched = false;
            var max_len: usize = @min(src.len - i, 32);
            while (max_len > 0) : (max_len -= 1) {
                const substr = src[i .. i + max_len];
                if (self.token_to_id.get(substr)) |id| {
                    try symbols.append(self.allocator, id);
                    i += max_len;
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                try symbols.append(self.allocator, self.unk_id);
                i += 1;
            }
        }

        // BPE merge loop: repeatedly apply highest-priority merge
        if (self.merges.len > 0) {
            var changed = true;
            while (changed) {
                changed = false;
                var j: usize = 1;
                while (j < symbols.items.len) : (j += 1) {
                    const left = symbols.items[j - 1];
                    const right = symbols.items[j];
                    const key = mergeKey(left, right);
                    if (self.merge_map.get(key)) |result| {
                        symbols.items[j - 1] = result;
                        _ = symbols.orderedRemove(j);
                        changed = true;
                        if (j > 1) j -= 1;
                    }
                }
            }
        }

        return try symbols.toOwnedSlice(self.allocator);
    }

    /// GPT-2 byte-to-unicode mapping.
    /// Maps each byte 0x00-0xFF to a unicode codepoint used by tiktoken-style
    /// tokenizers (GPT-2, GPT-4, Qwen, etc.) for vocab storage.
    /// Printable ASCII bytes map to themselves; control chars and 0x80-0xFF
    /// are shifted to U+0100-U+017F.
    fn byteToUnicode(byte: u8) u16 {
        // Printable ranges that map to themselves: '!'..'~', 0xA1..0xAC, 0xAE..0xFF
        if (byte >= '!' and byte <= '~') return @as(u16, byte);
        if (byte >= 0xA1 and byte <= 0xAC) return @as(u16, byte);
        if (byte >= 0xAE) return @as(u16, byte);
        // Everything else (0x00-0x20, 0x7F-0xA0, 0xAD) is shifted to U+0100+
        // The shift is sequential: the N-th unmapped byte maps to 256+N
        const shift_table = comptime blk: {
            var table: [256]u16 = undefined;
            var n: u16 = 0;
            for (0..256) |b| {
                const bb: u8 = @intCast(b);
                if ((bb >= '!' and bb <= '~') or
                    (bb >= 0xA1 and bb <= 0xAC) or
                    (bb >= 0xAE))
                {
                    table[b] = @as(u16, bb);
                } else {
                    table[b] = 256 + n;
                    n += 1;
                }
            }
            break :blk table;
        };
        return shift_table[byte];
    }

    // =========================================================================
    // Encode
    // =========================================================================

    /// Encode UTF-8 text to token IDs using greedy BPE.
    /// Prepends BOS token. Caller owns the returned slice.
    pub fn encode(self: *const GgufTokenizer, text: []const u8) ![]u32 {
        const raw = try self.encodeRaw(text);
        defer self.allocator.free(raw);

        var symbols: std.ArrayListUnmanaged(u32) = .empty;
        errdefer symbols.deinit(self.allocator);
        try symbols.ensureTotalCapacity(self.allocator, raw.len + 1);
        symbols.appendAssumeCapacity(self.bos_id);
        symbols.appendSliceAssumeCapacity(raw);
        return try symbols.toOwnedSlice(self.allocator);
    }

    /// Decode token IDs back to UTF-8 text.
    /// Reverses the GPT-2 byte-to-unicode mapping for tiktoken-style tokenizers.
    /// Skips BOS/EOS/UNK and all special control tokens.
    /// Caller owns the returned slice.
    pub fn decode(self: *const GgufTokenizer, tokens: []const u32) ![]u8 {
        const use_byte_map = (self.token_to_id.get("\n") == null);
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);

        for (tokens) |tok| {
            if (tok == self.bos_id or self.isEos(tok)) continue;
            if (tok >= self.vocab.len) continue;
            const s = self.vocab[tok];
            if (s.len == 0) continue;

            // Skip special control tokens (anything matching <|...|>)
            if (s.len >= 4 and s[0] == '<' and s[1] == '|' and s[s.len - 1] == '>' and s[s.len - 2] == '|') continue;

            // Handle <0xNN> byte tokens (sentencepiece style)
            if (s.len == 6 and std.mem.startsWith(u8, s, "<0x") and s[5] == '>') {
                const byte_val = std.fmt.parseInt(u8, s[3..5], 16) catch {
                    try out.appendSlice(self.allocator, s);
                    continue;
                };
                try out.append(self.allocator, byte_val);
                continue;
            }

            if (use_byte_map) {
                // Reverse GPT-2 byte-to-unicode: decode each UTF-8 codepoint
                // back to its original byte via the reverse mapping table.
                var si: usize = 0;
                while (si < s.len) {
                    const cp_info = decodeUtf8Codepoint(s[si..]);
                    if (cp_info.cp) |cp| {
                        const byte_val = unicodeToByte(cp);
                        if (byte_val) |b| {
                            try out.append(self.allocator, b);
                        } else {
                            // Not in the byte mapping — emit raw UTF-8
                            try out.appendSlice(self.allocator, s[si .. si + cp_info.len]);
                        }
                        si += cp_info.len;
                    } else {
                        // Invalid UTF-8 — emit raw byte
                        try out.append(self.allocator, s[si]);
                        si += 1;
                    }
                }
            } else {
                // Sentencepiece-style: handle space prefixes
                if (s.len >= 3 and s[0] == 0xE2 and s[1] == 0x96 and s[2] == 0x81) {
                    try out.append(self.allocator, ' ');
                    try out.appendSlice(self.allocator, s[3..]);
                } else {
                    try out.appendSlice(self.allocator, s);
                }
            }
        }

        return out.toOwnedSlice(self.allocator);
    }

    const CpInfo = struct { cp: ?u16, len: usize };

    /// Decode one UTF-8 codepoint from the start of `s`.
    fn decodeUtf8Codepoint(s: []const u8) CpInfo {
        if (s.len == 0) return .{ .cp = null, .len = 0 };
        const b0 = s[0];
        if (b0 < 0x80) return .{ .cp = @as(u16, b0), .len = 1 };
        if (b0 >= 0xC0 and b0 < 0xE0 and s.len >= 2) {
            const cp = (@as(u16, b0 & 0x1F) << 6) | @as(u16, s[1] & 0x3F);
            return .{ .cp = cp, .len = 2 };
        }
        if (b0 >= 0xE0 and b0 < 0xF0 and s.len >= 3) {
            const cp = (@as(u16, b0 & 0x0F) << 12) | (@as(u16, s[1] & 0x3F) << 6) | @as(u16, s[2] & 0x3F);
            return .{ .cp = cp, .len = 3 };
        }
        return .{ .cp = null, .len = 1 };
    }

    /// Reverse GPT-2 byte-to-unicode mapping: given a unicode codepoint, return
    /// the original byte value, or null if not in the mapping.
    fn unicodeToByte(cp: u16) ?u8 {
        // Use the same comptime shift_table as byteToUnicode, but build
        // the reverse in a single pass (no nested loops).
        const reverse_table = comptime blk: {
            var table: [512]?u8 = .{null} ** 512;
            var n: u16 = 0; // running counter for shifted bytes
            for (0..256) |b| {
                const bb: u8 = @intCast(b);
                const is_direct = (bb >= '!' and bb <= '~') or
                    (bb >= 0xA1 and bb <= 0xAC) or
                    (bb >= 0xAE);
                if (is_direct) {
                    table[@as(u16, bb)] = bb;
                } else {
                    table[256 + n] = bb;
                    n += 1;
                }
            }
            break :blk table;
        };
        if (cp < reverse_table.len) return reverse_table[cp];
        return null;
    }

    pub fn vocabSize(self: *const GgufTokenizer) u32 {
        return @intCast(self.vocab.len);
    }

    // =========================================================================
    // Internal: GGUF metadata parsing
    // =========================================================================

    fn parseMetadata(self: *GgufTokenizer, data: []const u8, start: usize, n_kv: u64) !void {
        var pos = start;
        var kv: u64 = 0;

        // Temporary storage for arrays we care about
        var tokens_list = std.ArrayListUnmanaged([]const u8){};
        defer {
            if (self.vocab.len == 0) {
                for (tokens_list.items) |s| self.allocator.free(s);
            }
            tokens_list.deinit(self.allocator);
        }
        var scores_list = std.ArrayListUnmanaged(f32){};
        defer scores_list.deinit(self.allocator);
        var merges_list = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (merges_list.items) |s| self.allocator.free(s);
            merges_list.deinit(self.allocator);
        }

        while (kv < n_kv) : (kv += 1) {
            const key_r = try readString(data, pos);
            pos = key_r.new_pos;
            const key = key_r.str;

            if (pos + 4 > data.len) return error.Truncated;
            const vtype = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;

            // -- Scalar string metadata we care about --
            if (vtype == VTYPE_STRING) {
                const val_r = try readString(data, pos);
                pos = val_r.new_pos;

                // general.architecture -> model_arch
                if (std.mem.endsWith(u8, key, "general.architecture")) {
                    const copy_len = @min(val_r.str.len, self.model_arch.len);
                    @memcpy(self.model_arch[0..copy_len], val_r.str[0..copy_len]);
                    self.model_arch_len = @intCast(copy_len);
                }
                // tokenizer.chat_template is available but we detect style
                // from vocab tokens instead (more reliable, works for all quants).
                // We log it for debugging.
                if (std.mem.endsWith(u8, key, "tokenizer.chat_template")) {
                    const preview_len = @min(val_r.str.len, @as(usize, 60));
                    log.info("GGUF chat_template: {s}...", .{val_r.str[0..preview_len]});
                }
                continue;
            }

            const is_tokens = std.mem.endsWith(u8, key, "tokenizer.ggml.tokens");
            const is_scores = std.mem.endsWith(u8, key, "tokenizer.ggml.scores");
            const is_merges = std.mem.endsWith(u8, key, "tokenizer.ggml.merges");

            if (vtype == VTYPE_ARRAY and (is_tokens or is_scores or is_merges)) {
                if (pos + 12 > data.len) return error.Truncated;
                const elem_type = std.mem.readInt(u32, data[pos..][0..4], .little);
                const n_elems = std.mem.readInt(u64, data[pos + 4 ..][0..8], .little);
                pos += 12;

                var ei: u64 = 0;
                while (ei < n_elems) : (ei += 1) {
                    if (is_tokens and elem_type == VTYPE_STRING) {
                        const sr = try readString(data, pos);
                        pos = sr.new_pos;
                        const owned = try self.allocator.dupe(u8, sr.str);
                        try tokens_list.append(self.allocator, owned);
                    } else if (is_scores and elem_type == VTYPE_FLOAT32) {
                        if (pos + 4 > data.len) return error.Truncated;
                        const bits = std.mem.readInt(u32, data[pos..][0..4], .little);
                        const val: f32 = @bitCast(bits);
                        try scores_list.append(self.allocator, val);
                        pos += 4;
                    } else if (is_merges and elem_type == VTYPE_STRING) {
                        const sr = try readString(data, pos);
                        pos = sr.new_pos;
                        const owned = try self.allocator.dupe(u8, sr.str);
                        try merges_list.append(self.allocator, owned);
                    } else {
                        pos = try skipValue(data, pos, elem_type);
                    }
                }
            } else {
                pos = try skipValue(data, pos, vtype);
            }
        }

        // Move tokens into self.vocab
        self.vocab = try tokens_list.toOwnedSlice(self.allocator);

        // Move scores
        self.scores = try scores_list.toOwnedSlice(self.allocator);

        // Build token_to_id map
        for (self.vocab, 0..) |s, id| {
            try self.token_to_id.put(s, @intCast(id));
        }

        // Build merge rules from merges_list (format: "TOKEN_A TOKEN_B")
        var merge_arr = std.ArrayListUnmanaged(MergePair){};
        errdefer merge_arr.deinit(self.allocator);

        for (merges_list.items, 0..) |merge_str, merge_idx| {
            const space = std.mem.indexOf(u8, merge_str, " ") orelse continue;
            const left_str = merge_str[0..space];
            const right_str = merge_str[space + 1 ..];
            const left_id = self.token_to_id.get(left_str) orelse continue;
            const right_id = self.token_to_id.get(right_str) orelse continue;
            // Merged token is left+right concatenated
            const merged_str = try std.mem.concat(self.allocator, u8, &.{ left_str, right_str });
            defer self.allocator.free(merged_str);
            const result_id = self.token_to_id.get(merged_str) orelse continue;
            const score = if (merge_idx < self.scores.len) self.scores[merge_idx] else @as(f32, @floatFromInt(merge_idx));
            try merge_arr.append(self.allocator, .{
                .left = left_id,
                .right = right_id,
                .result = result_id,
                .score = score,
            });
        }

        self.merges = try merge_arr.toOwnedSlice(self.allocator);

        // Build merge_map for O(1) lookup
        for (self.merges) |m| {
            try self.merge_map.put(mergeKey(m.left, m.right), m.result);
        }
    }

    // =========================================================================
    // GGUF low-level helpers (self-contained, no dependency on llama.zig)
    // =========================================================================

    fn readString(data: []const u8, pos: usize) !struct { str: []const u8, new_pos: usize } {
        if (pos + 8 > data.len) return error.Truncated;
        const len: usize = @intCast(std.mem.readInt(u64, data[pos..][0..8], .little));
        const str_start = pos + 8;
        if (str_start + len > data.len) return error.Truncated;
        return .{ .str = data[str_start .. str_start + len], .new_pos = str_start + len };
    }

    fn skipValue(data: []const u8, pos: usize, vtype: u32) !usize {
        var cur = pos;
        switch (vtype) {
            VTYPE_UINT8, VTYPE_INT8, VTYPE_BOOL => cur += 1,
            VTYPE_UINT16, VTYPE_INT16 => cur += 2,
            VTYPE_UINT32, VTYPE_INT32, VTYPE_FLOAT32 => cur += 4,
            VTYPE_STRING => {
                const s = try readString(data, cur);
                cur = s.new_pos;
            },
            VTYPE_ARRAY => {
                if (cur + 12 > data.len) return error.Truncated;
                const elem_type = std.mem.readInt(u32, data[cur..][0..4], .little);
                const n_elems = std.mem.readInt(u64, data[cur + 4 ..][0..8], .little);
                cur += 12;
                var i_arr: u64 = 0;
                while (i_arr < n_elems) : (i_arr += 1) {
                    cur = try skipValue(data, cur, elem_type);
                }
            },
            VTYPE_UINT64, VTYPE_INT64, VTYPE_FLOAT64 => cur += 8,
            else => return error.UnsupportedGGUFType,
        }
        return cur;
    }

    inline fn mergeKey(left: u32, right: u32) u64 {
        return (@as(u64, left) << 32) | @as(u64, right);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GgufTokenizer decode Ġ prefix" {
    const allocator = std.testing.allocator;
    var tok = try allocator.create(GgufTokenizer);
    defer allocator.destroy(tok);

    // Minimal vocab: id 0=<unk>, 1=<s>, 2=</s>, 3="Hello", 4=Ġworld
    const vocab_strs = [_][]const u8{ "<unk>", "<s>", "</s>", "Hello", "\xC4\xA0world" };
    var vocab = try allocator.alloc([]const u8, vocab_strs.len);
    for (vocab_strs, 0..) |s, idx| vocab[idx] = try allocator.dupe(u8, s);
    const scores = try allocator.alloc(f32, vocab_strs.len);
    @memset(scores, 0.0);

    tok.* = .{
        .allocator = allocator,
        .vocab = vocab,
        .scores = scores,
        .token_to_id = std.StringHashMap(u32).init(allocator),
        .merges = &.{},
        .merge_map = GgufTokenizer.MergeMap.init(allocator),
        .bos_id = 1,
        .eos_id = 2,
        .unk_id = 0,
    };
    defer {
        for (tok.vocab) |s| allocator.free(s);
        allocator.free(tok.vocab);
        allocator.free(tok.scores);
        tok.token_to_id.deinit();
        tok.merge_map.deinit();
    }

    const decoded = try tok.decode(&.{ 1, 3, 4, 2 });
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("Hello world", decoded);
}

test "GgufTokenizer decode byte tokens" {
    const allocator = std.testing.allocator;
    var tok = try allocator.create(GgufTokenizer);
    defer allocator.destroy(tok);

    const vocab_strs = [_][]const u8{ "<unk>", "<s>", "</s>", "<0x41>", "<0x42>" };
    var vocab = try allocator.alloc([]const u8, vocab_strs.len);
    for (vocab_strs, 0..) |s, idx| vocab[idx] = try allocator.dupe(u8, s);
    const scores = try allocator.alloc(f32, vocab_strs.len);
    @memset(scores, 0.0);

    tok.* = .{
        .allocator = allocator,
        .vocab = vocab,
        .scores = scores,
        .token_to_id = std.StringHashMap(u32).init(allocator),
        .merges = &.{},
        .merge_map = GgufTokenizer.MergeMap.init(allocator),
        .bos_id = 1,
        .eos_id = 2,
        .unk_id = 0,
    };
    defer {
        for (tok.vocab) |s| allocator.free(s);
        allocator.free(tok.vocab);
        allocator.free(tok.scores);
        tok.token_to_id.deinit();
        tok.merge_map.deinit();
    }

    const decoded = try tok.decode(&.{ 3, 4 });
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("AB", decoded);
}
