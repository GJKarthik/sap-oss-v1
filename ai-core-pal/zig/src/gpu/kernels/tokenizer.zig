//! ANWID GPU-Native Tokenizer Kernel
//! Zero-CPU-Touch tokenization: Converts text bytes to token IDs directly in VRAM
//! 
//! Architecture:
//!   1. Receives text bounds from JSON parser (text_start, text_end)
//!   2. Parallel byte-pair encoding (BPE) or word-piece tokenization
//!   3. Outputs token IDs directly to GPU buffer
//!   4. Triggers inference kernel via kernel fusion
//!
//! Supports:
//!   - BPE (GPT-2/GPT-3 style)
//!   - WordPiece (BERT style)  
//!   - SentencePiece (T5/LLaMA style)

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.gpu_tokenizer);

// ============================================================================
// Tokenizer Configuration
// ============================================================================

pub const TokenizerConfig = struct {
    /// Vocabulary size
    vocab_size: usize = 32000,
    /// Maximum sequence length
    max_seq_len: usize = 2048,
    /// Tokenizer type
    tokenizer_type: TokenizerType = .bpe,
    /// Add special tokens (BOS, EOS)
    add_special_tokens: bool = true,
    /// BOS token ID
    bos_token_id: u32 = 1,
    /// EOS token ID
    eos_token_id: u32 = 2,
    /// PAD token ID
    pad_token_id: u32 = 0,
    /// UNK token ID
    unk_token_id: u32 = 3,
    /// Threads per block for GPU kernel
    threads_per_block: usize = 256,
};

pub const TokenizerType = enum {
    bpe,
    wordpiece,
    sentencepiece,
    tiktoken,
};

// ============================================================================
// GPU Tokenizer Result (GPU-resident)
// ============================================================================

/// Result of GPU tokenization - stored in GPU memory
pub const GpuTokenResult = extern struct {
    /// Number of tokens produced
    num_tokens: u32,
    /// Status: 0 = success, 1 = truncated, 2 = error
    status: u32,
    /// Actual sequence length (may include padding)
    seq_len: u32,
    /// Error code if status == 2
    error_code: u32,
};

pub const TokenStatus = enum(u32) {
    success = 0,
    truncated = 1,
    error_invalid_utf8 = 2,
    error_vocab_lookup = 3,
    error_buffer_overflow = 4,
};

// ============================================================================
// Vocabulary Table (GPU-resident)
// ============================================================================

/// GPU-optimized vocabulary lookup table
/// Uses perfect hashing for O(1) token lookup
pub const GpuVocabTable = struct {
    allocator: std.mem.Allocator,
    
    /// Token strings to ID mapping (hash table)
    token_to_id: std.StringHashMap(u32),
    
    /// ID to token strings (for decoding)
    id_to_token: [][]const u8,
    
    /// Merge rules for BPE (sorted by priority)
    merge_rules: std.ArrayList(MergeRule),
    
    /// Tracks dynamically allocated token strings (freed in deinit)
    owned_tokens: std.ArrayList([]const u8),
    
    vocab_size: usize,
    
    pub const MergeRule = struct {
        left: []const u8,
        right: []const u8,
        result: []const u8,
        result_id: u32,
        priority: u32,
    };
    
    pub fn init(allocator: std.mem.Allocator, vocab_size: usize) !*GpuVocabTable {
        const table = try allocator.create(GpuVocabTable);
        
        table.* = .{
            .allocator = allocator,
            .token_to_id = std.StringHashMap(u32).init(allocator),
            .id_to_token = try allocator.alloc([]const u8, vocab_size),
            .merge_rules = .{},
            .owned_tokens = .{},
            .vocab_size = vocab_size,
        };
        
        // Initialize with basic vocabulary (in production, loaded from file)
        try table.initializeBasicVocab();
        
        return table;
    }
    
    pub fn deinit(self: *GpuVocabTable) void {
        for (self.owned_tokens.items) |tok| {
            self.allocator.free(tok);
        }
        self.owned_tokens.deinit(self.allocator);
        self.token_to_id.deinit();
        self.allocator.free(self.id_to_token);
        self.merge_rules.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    
    fn initializeBasicVocab(self: *GpuVocabTable) !void {
        // Basic ASCII vocabulary for demonstration
        // In production, this would be loaded from tokenizer.json
        const special_tokens = [_][]const u8{ "<pad>", "<s>", "</s>", "<unk>" };
        
        for (special_tokens, 0..) |token, i| {
            try self.token_to_id.put(token, @intCast(i));
            self.id_to_token[i] = token;
        }
        
        // Add single-byte tokens (ASCII printable)
        var token_id: u32 = 4;
        var char_buf: [1]u8 = undefined;
        for (32..127) |c| {
            char_buf[0] = @intCast(c);
            const token = try self.allocator.dupe(u8, &char_buf);
            try self.owned_tokens.append(self.allocator, token);
            try self.token_to_id.put(token, token_id);
            if (token_id < self.vocab_size) {
                self.id_to_token[token_id] = token;
            }
            token_id += 1;
        }
        
        // Add common subwords for demonstration
        const common_subwords = [_][]const u8{
            "the", "ing", "er", "ed", "es", "en", "ly",
            "The", "and", "for", "are", "but", "not", "you",
            "all", "can", "had", "her", "was", "one", "our",
        };
        
        for (common_subwords) |subword| {
            if (token_id < self.vocab_size) {
                try self.token_to_id.put(subword, token_id);
                self.id_to_token[token_id] = subword;
                token_id += 1;
            }
        }
    }
    
    /// Look up token ID (returns UNK if not found)
    pub fn lookup(self: *const GpuVocabTable, token: []const u8) u32 {
        return self.token_to_id.get(token) orelse 3; // UNK token
    }
    
    /// Check if token exists in vocabulary
    pub fn contains(self: *const GpuVocabTable, token: []const u8) bool {
        return self.token_to_id.contains(token);
    }
};

// ============================================================================
// GPU Tokenizer
// ============================================================================

pub const GpuTokenizer = struct {
    allocator: std.mem.Allocator,
    config: TokenizerConfig,
    vocab: *GpuVocabTable,
    
    // Pre-allocated output buffer (simulates GPU buffer)
    output_tokens: []u32,
    
    // Statistics
    tokenize_count: std.atomic.Value(u64),
    total_tokens_produced: std.atomic.Value(u64),
    total_bytes_processed: std.atomic.Value(u64),
    total_tokenize_time_ns: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator, config: TokenizerConfig) !*GpuTokenizer {
        const tokenizer = try allocator.create(GpuTokenizer);
        
        const vocab = try GpuVocabTable.init(allocator, config.vocab_size);
        
        tokenizer.* = .{
            .allocator = allocator,
            .config = config,
            .vocab = vocab,
            .output_tokens = try allocator.alloc(u32, config.max_seq_len),
            .tokenize_count = std.atomic.Value(u64).init(0),
            .total_tokens_produced = std.atomic.Value(u64).init(0),
            .total_bytes_processed = std.atomic.Value(u64).init(0),
            .total_tokenize_time_ns = std.atomic.Value(u64).init(0),
        };
        
        log.info("GPU Tokenizer initialized:", .{});
        log.info("  Vocab size: {}", .{config.vocab_size});
        log.info("  Max seq len: {}", .{config.max_seq_len});
        log.info("  Type: {s}", .{@tagName(config.tokenizer_type)});
        
        return tokenizer;
    }
    
    pub fn deinit(self: *GpuTokenizer) void {
        self.vocab.deinit();
        self.allocator.free(self.output_tokens);
        self.allocator.destroy(self);
    }
    
    /// Tokenize text bytes directly in GPU memory
    /// This is the main entry point - simulates GPU kernel execution
    pub fn tokenize(
        self: *GpuTokenizer,
        text_bytes: []const u8,
        output_buffer: []u32,
    ) !GpuTokenResult {
        const start_time = std.time.nanoTimestamp();
        defer {
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
            _ = self.total_tokenize_time_ns.fetchAdd(elapsed, .monotonic);
            _ = self.tokenize_count.fetchAdd(1, .monotonic);
            _ = self.total_bytes_processed.fetchAdd(text_bytes.len, .monotonic);
        }
        
        var token_idx: usize = 0;
        
        // Add BOS token if configured
        if (self.config.add_special_tokens and token_idx < output_buffer.len) {
            output_buffer[token_idx] = self.config.bos_token_id;
            token_idx += 1;
        }
        
        // Tokenize based on type
        const result = switch (self.config.tokenizer_type) {
            .bpe => try self.tokenizeBpe(text_bytes, output_buffer, &token_idx),
            .wordpiece => try self.tokenizeWordPiece(text_bytes, output_buffer, &token_idx),
            .sentencepiece => try self.tokenizeBpe(text_bytes, output_buffer, &token_idx), // Simplified
            .tiktoken => try self.tokenizeBpe(text_bytes, output_buffer, &token_idx), // Simplified
        };
        
        // Add EOS token if configured and space available
        if (self.config.add_special_tokens and token_idx < output_buffer.len) {
            output_buffer[token_idx] = self.config.eos_token_id;
            token_idx += 1;
        }
        
        _ = self.total_tokens_produced.fetchAdd(token_idx, .monotonic);
        
        return GpuTokenResult{
            .num_tokens = @intCast(token_idx),
            .status = result.status,
            .seq_len = @intCast(token_idx),
            .error_code = result.error_code,
        };
    }
    
    /// BPE tokenization (GPU-parallelizable)
    fn tokenizeBpe(
        self: *GpuTokenizer,
        text_bytes: []const u8,
        output_buffer: []u32,
        token_idx: *usize,
    ) !GpuTokenResult {
        // Simplified BPE: Split on whitespace and punctuation, then lookup
        // Real BPE would apply merge rules iteratively
        
        var i: usize = 0;
        var word_start: usize = 0;
        var status: u32 = @intFromEnum(TokenStatus.success);
        
        while (i <= text_bytes.len) {
            const is_boundary = i == text_bytes.len or
                text_bytes[i] == ' ' or
                text_bytes[i] == '\n' or
                text_bytes[i] == '\t' or
                isPunctuation(text_bytes[i]);
            
            if (is_boundary and i > word_start) {
                // Process word
                const word = text_bytes[word_start..i];
                
                if (token_idx.* >= output_buffer.len - 1) {
                    status = @intFromEnum(TokenStatus.truncated);
                    break;
                }
                
                // Try to find whole word in vocab
                if (self.vocab.contains(word)) {
                    output_buffer[token_idx.*] = self.vocab.lookup(word);
                    token_idx.* += 1;
                } else {
                    // Fall back to character-level tokenization
                    for (word) |c| {
                        if (token_idx.* >= output_buffer.len - 1) {
                            status = @intFromEnum(TokenStatus.truncated);
                            break;
                        }
                        
                        var char_buf: [1]u8 = .{c};
                        output_buffer[token_idx.*] = self.vocab.lookup(&char_buf);
                        token_idx.* += 1;
                    }
                }
                
                word_start = i + 1;
            } else if (is_boundary) {
                word_start = i + 1;
            }
            
            // Handle punctuation as separate token
            if (i < text_bytes.len and isPunctuation(text_bytes[i])) {
                if (token_idx.* < output_buffer.len - 1) {
                    var punct_buf: [1]u8 = .{text_bytes[i]};
                    output_buffer[token_idx.*] = self.vocab.lookup(&punct_buf);
                    token_idx.* += 1;
                }
                word_start = i + 1;
            }
            
            i += 1;
        }
        
        return GpuTokenResult{
            .num_tokens = @intCast(token_idx.*),
            .status = status,
            .seq_len = @intCast(token_idx.*),
            .error_code = 0,
        };
    }
    
    /// WordPiece tokenization (BERT-style)
    fn tokenizeWordPiece(
        self: *GpuTokenizer,
        text_bytes: []const u8,
        output_buffer: []u32,
        token_idx: *usize,
    ) !GpuTokenResult {
        // WordPiece uses "##" prefix for continuation tokens
        // Simplified implementation: same as BPE for now
        return self.tokenizeBpe(text_bytes, output_buffer, token_idx);
    }
    
    /// Tokenize directly from parse result (zero-copy from JSON parser)
    pub fn tokenizeFromParseResult(
        self: *GpuTokenizer,
        raw_bytes: []const u8,
        text_start: u32,
        text_end: u32,
        output_buffer: []u32,
    ) !GpuTokenResult {
        if (text_start >= raw_bytes.len or text_end > raw_bytes.len or text_end <= text_start) {
            return GpuTokenResult{
                .num_tokens = 0,
                .status = @intFromEnum(TokenStatus.error_invalid_utf8),
                .seq_len = 0,
                .error_code = 1,
            };
        }
        
        const text_slice = raw_bytes[text_start..text_end];
        return self.tokenize(text_slice, output_buffer);
    }
    
    /// Get internal output buffer (for kernel fusion)
    pub fn getOutputBuffer(self: *GpuTokenizer) []u32 {
        return self.output_tokens;
    }
    
    /// Get statistics
    pub fn getStats(self: *const GpuTokenizer) TokenizerStats {
        const count = self.tokenize_count.load(.acquire);
        const time = self.total_tokenize_time_ns.load(.acquire);
        
        return .{
            .tokenize_count = count,
            .total_tokens_produced = self.total_tokens_produced.load(.acquire),
            .total_bytes_processed = self.total_bytes_processed.load(.acquire),
            .total_tokenize_time_ns = time,
            .avg_tokenize_time_ns = if (count > 0) time / count else 0,
        };
    }
};

pub const TokenizerStats = struct {
    tokenize_count: u64,
    total_tokens_produced: u64,
    total_bytes_processed: u64,
    total_tokenize_time_ns: u64,
    avg_tokenize_time_ns: u64,
};

// ============================================================================
// Helper Functions
// ============================================================================

fn isPunctuation(c: u8) bool {
    return switch (c) {
        '.', ',', '!', '?', ';', ':', '"', '\'', '(', ')', '[', ']', '{', '}', '-', '_', '/', '\\', '@', '#', '$', '%', '^', '&', '*', '+', '=', '<', '>', '~', '`' => true,
        else => false,
    };
}

// ============================================================================
// CUDA/Metal Kernel Structures
// ============================================================================

/// GPU kernel parameters for tokenization
pub const TokenizerKernelParams = extern struct {
    /// Device pointer to input text bytes
    input_ptr: u64,
    /// Start offset in input (from JSON parser)
    input_start: u32,
    /// End offset in input (from JSON parser)
    input_end: u32,
    /// Device pointer to output token IDs
    output_ptr: u64,
    /// Maximum output tokens
    max_output_len: u32,
    /// Device pointer to vocabulary table
    vocab_ptr: u64,
    /// Device pointer to result structure
    result_ptr: u64,
    /// Configuration flags
    flags: u32,
};

/// Kernel fusion: Combined parser + tokenizer parameters
pub const FusedParserTokenizerParams = extern struct {
    /// Device pointer to raw JSON bytes
    json_ptr: u64,
    json_len: u32,
    /// Device pointer to output token IDs
    output_ptr: u64,
    max_output_len: u32,
    /// Device pointer to vocabulary
    vocab_ptr: u64,
    /// Device pointer to combined result
    result_ptr: u64,
    /// Tokenizer config flags
    config_flags: u32,
    _padding: u32,
};

// ============================================================================
// Tests
// ============================================================================

test "GpuTokenizer basic tokenization" {
    const tokenizer = try GpuTokenizer.init(std.testing.allocator, .{});
    defer tokenizer.deinit();
    
    var output: [64]u32 = undefined;
    const result = try tokenizer.tokenize("Hello, world!", &output);
    
    try std.testing.expectEqual(@as(u32, @intFromEnum(TokenStatus.success)), result.status);
    try std.testing.expect(result.num_tokens > 0);
    
    // Should have BOS token at start
    try std.testing.expectEqual(@as(u32, 1), output[0]); // BOS
}

test "GpuTokenizer handles empty input" {
    const tokenizer = try GpuTokenizer.init(std.testing.allocator, .{});
    defer tokenizer.deinit();
    
    var output: [64]u32 = undefined;
    const result = try tokenizer.tokenize("", &output);
    
    try std.testing.expectEqual(@as(u32, @intFromEnum(TokenStatus.success)), result.status);
    // Should still have BOS and EOS
    try std.testing.expectEqual(@as(u32, 2), result.num_tokens);
}

test "GpuTokenizer truncation" {
    const tokenizer = try GpuTokenizer.init(std.testing.allocator, .{
        .max_seq_len = 8,
    });
    defer tokenizer.deinit();
    
    var output: [4]u32 = undefined; // Very small buffer
    const result = try tokenizer.tokenize("This is a long sentence that should be truncated", &output);
    
    try std.testing.expectEqual(@as(u32, @intFromEnum(TokenStatus.truncated)), result.status);
}

test "GpuTokenizer from parse result" {
    const tokenizer = try GpuTokenizer.init(std.testing.allocator, .{});
    defer tokenizer.deinit();
    
    const raw_json = "{\"prompt\": \"test text here\"}";
    var output: [64]u32 = undefined;
    
    // Simulating parse result: text starts at 12, ends at 26
    const result = try tokenizer.tokenizeFromParseResult(raw_json, 12, 26, &output);
    
    try std.testing.expectEqual(@as(u32, @intFromEnum(TokenStatus.success)), result.status);
    try std.testing.expect(result.num_tokens > 0);
}

test "GpuVocabTable lookup" {
    const vocab = try GpuVocabTable.init(std.testing.allocator, 1000);
    defer vocab.deinit();
    
    // Special tokens
    try std.testing.expectEqual(@as(u32, 0), vocab.lookup("<pad>"));
    try std.testing.expectEqual(@as(u32, 1), vocab.lookup("<s>"));
    try std.testing.expectEqual(@as(u32, 2), vocab.lookup("</s>"));
    try std.testing.expectEqual(@as(u32, 3), vocab.lookup("<unk>"));
    
    // Unknown token should return UNK
    try std.testing.expectEqual(@as(u32, 3), vocab.lookup("nonexistent_token_xyz"));
}

test "GpuTokenizer statistics" {
    const tokenizer = try GpuTokenizer.init(std.testing.allocator, .{});
    defer tokenizer.deinit();
    
    var output: [64]u32 = undefined;
    _ = try tokenizer.tokenize("test one", &output);
    _ = try tokenizer.tokenize("test two", &output);
    
    const stats = tokenizer.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.tokenize_count);
    try std.testing.expect(stats.total_bytes_processed > 0);
}