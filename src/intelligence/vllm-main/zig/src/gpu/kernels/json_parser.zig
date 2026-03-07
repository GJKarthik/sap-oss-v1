//! Private LLM JSON Parser
//! High-performance pattern-based field extraction for OpenAI-compatible
//! chat completion and embedding requests.
//!
//! Architecture:
//!   1. Scans JSON bytes for "content": "..." patterns
//!   2. Escape-aware string extraction returns text bounds per message
//!   3. GPU kernel structs (JsonParserKernel) defined for future CUDA/Metal dispatch
//!
//! Currently uses CPU-based pattern matching with simulated parallel chunks.
//! GPU kernel structs are ready for real dispatch but not yet wired up.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.gpu_json_parser);

// ============================================================================
// GPU JSON Parse Result (GPU-resident structure)
// ============================================================================

/// Result of GPU JSON parsing - stored in GPU memory
/// This structure is designed to be read by subsequent GPU kernels
pub const GpuParseResult = extern struct {
    /// Offset in bytes where the text starts (after opening quote)
    text_start: u32,
    /// Offset in bytes where the text ends (before closing quote)
    text_end: u32,
    /// Status: 0 = success, 1 = pattern not found, 2 = invalid JSON
    status: u32,
    /// Error code for debugging
    error_code: u32,
    /// Number of bytes scanned
    bytes_scanned: u32,
    /// Reserved for alignment
    _reserved: [3]u32,
};

/// Result for multi-message parsing (Chat Completion requests)
pub const MultiMessageParseResult = extern struct {
    /// Number of messages found
    num_messages: u32,
    /// Status: 0 = success
    status: u32,
    /// Individual message bounds (up to 64 messages)
    messages: [64]MessageBounds,
    /// Total content length
    total_content_len: u32,
    _padding: [3]u32,
};

pub const MessageBounds = extern struct {
    role_start: u32,
    role_end: u32,
    content_start: u32,
    content_end: u32,
};

pub const ParseStatus = enum(u32) {
    success = 0,
    pattern_not_found = 1,
    invalid_json = 2,
    buffer_overflow = 3,
    unterminated_string = 4,
};

// ============================================================================
// JSON Parser Configuration
// ============================================================================

pub const ParserConfig = struct {
    /// Maximum JSON payload size (for bounds checking)
    max_payload_size: usize = 16 * 1024 * 1024, // 16MB
    /// Field name to search for (supports multiple patterns)
    target_field: []const u8 = "content",
    /// Alternative field names to try
    alt_fields: []const []const u8 = &[_][]const u8{ "prompt", "input", "text" },
    /// Number of GPU threads per block
    threads_per_block: usize = 256,
    /// Enable escape sequence handling
    handle_escapes: bool = true,
    /// Parse multiple messages (for chat completion)
    multi_message: bool = true,
};

// ============================================================================
// GPU JSON Parser
// ============================================================================

pub const GpuJsonParser = struct {
    allocator: std.mem.Allocator,
    config: ParserConfig,
    
    // Pre-compiled pattern (for the main field)
    pattern: []const u8,
    pattern_len: usize,
    
    // Statistics
    parse_count: std.atomic.Value(u64),
    total_bytes_scanned: std.atomic.Value(u64),
    cache_hits: std.atomic.Value(u64),
    pattern_match_failures: std.atomic.Value(u64),
    total_parse_time_ns: std.atomic.Value(u64),
    messages_parsed: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator, config: ParserConfig) !*GpuJsonParser {
        const parser = try allocator.create(GpuJsonParser);
        
        // Pre-compile the pattern: "field": "
        const pattern = try std.fmt.allocPrint(allocator, "\"{s}\": \"", .{config.target_field});
        
        parser.* = .{
            .allocator = allocator,
            .config = config,
            .pattern = pattern,
            .pattern_len = pattern.len,
            .parse_count = std.atomic.Value(u64).init(0),
            .total_bytes_scanned = std.atomic.Value(u64).init(0),
            .cache_hits = std.atomic.Value(u64).init(0),
            .pattern_match_failures = std.atomic.Value(u64).init(0),
            .total_parse_time_ns = std.atomic.Value(u64).init(0),
            .messages_parsed = std.atomic.Value(u64).init(0),
        };
        
        log.info("GPU JSON Parser initialized for field: \"{s}\"", .{config.target_field});
        
        return parser;
    }
    
    pub fn deinit(self: *GpuJsonParser) void {
        self.allocator.free(self.pattern);
        self.allocator.destroy(self);
    }
    
    /// Parse JSON bytes to find the target field value
    pub fn parse(self: *GpuJsonParser, json_bytes: []const u8) GpuParseResult {
        const start_time = std.time.nanoTimestamp();
        defer {
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
            _ = self.total_parse_time_ns.fetchAdd(elapsed, .monotonic);
            _ = self.parse_count.fetchAdd(1, .monotonic);
            _ = self.total_bytes_scanned.fetchAdd(json_bytes.len, .monotonic);
        }
        
        // Bounds check
        if (json_bytes.len > self.config.max_payload_size) {
            return GpuParseResult{
                .text_start = 0,
                .text_end = 0,
                .status = @intFromEnum(ParseStatus.buffer_overflow),
                .error_code = 1,
                .bytes_scanned = @intCast(json_bytes.len),
                ._reserved = .{ 0, 0, 0 },
            };
        }
        
        // Try main pattern first
        if (self.findPattern(json_bytes, self.pattern)) |result| {
            return result;
        }
        
        // Try alternative field names
        for (self.config.alt_fields) |alt_field| {
            var pattern_buf: [128]u8 = undefined;
            const alt_pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\": \"", .{alt_field}) catch continue;
            
            if (self.findPattern(json_bytes, alt_pattern)) |result| {
                return result;
            }
            
            // Try without space after colon
            const alt_pattern_no_space = std.fmt.bufPrint(&pattern_buf, "\"{s}\":\"", .{alt_field}) catch continue;
            if (self.findPattern(json_bytes, alt_pattern_no_space)) |result| {
                return result;
            }
        }
        
        // Also try main pattern without space
        var pattern_no_space_buf: [128]u8 = undefined;
        const pattern_no_space = std.fmt.bufPrint(&pattern_no_space_buf, "\"{s}\":\"", .{self.config.target_field}) catch {
            _ = self.pattern_match_failures.fetchAdd(1, .monotonic);
            return GpuParseResult{
                .text_start = 0,
                .text_end = 0,
                .status = @intFromEnum(ParseStatus.pattern_not_found),
                .error_code = 2,
                .bytes_scanned = @intCast(json_bytes.len),
                ._reserved = .{ 0, 0, 0 },
            };
        };
        
        if (self.findPattern(json_bytes, pattern_no_space)) |result| {
            return result;
        }
        
        _ = self.pattern_match_failures.fetchAdd(1, .monotonic);
        return GpuParseResult{
            .text_start = 0,
            .text_end = 0,
            .status = @intFromEnum(ParseStatus.pattern_not_found),
            .error_code = 2,
            .bytes_scanned = @intCast(json_bytes.len),
            ._reserved = .{ 0, 0, 0 },
        };
    }
    
    /// Parse all messages in a chat completion request.
    /// Scopes extraction to the "messages" array and extracts both role and content bounds.
    pub fn parseMessages(self: *GpuJsonParser, json_bytes: []const u8) MultiMessageParseResult {
        const start_time = std.time.nanoTimestamp();
        defer {
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
            _ = self.total_parse_time_ns.fetchAdd(elapsed, .monotonic);
            _ = self.parse_count.fetchAdd(1, .monotonic);
            _ = self.total_bytes_scanned.fetchAdd(json_bytes.len, .monotonic);
        }
        
        var result = MultiMessageParseResult{
            .num_messages = 0,
            .status = 0,
            .messages = undefined,
            .total_content_len = 0,
            ._padding = .{ 0, 0, 0 },
        };
        
        // Initialize messages array
        for (&result.messages) |*msg| {
            msg.* = MessageBounds{
                .role_start = 0,
                .role_end = 0,
                .content_start = 0,
                .content_end = 0,
            };
        }
        
        // Scope search to "messages" array if present
        const messages_key = "\"messages\"";
        const search_region = if (std.mem.indexOf(u8, json_bytes, messages_key)) |key_pos| blk: {
            // Find the opening '[' after "messages"
            var i = key_pos + messages_key.len;
            while (i < json_bytes.len and json_bytes[i] != '[') : (i += 1) {}
            if (i < json_bytes.len) break :blk json_bytes[i..];
            break :blk json_bytes;
        } else json_bytes;
        
        // Walk through objects looking for {role, content} pairs
        const role_patterns = [_][]const u8{ "\"role\": \"", "\"role\":\"" };
        const content_patterns = [_][]const u8{ "\"content\": \"", "\"content\":\"" };
        
        var search_start: usize = 0;
        
        while (result.num_messages < 64) {
            // Find next "role" field
            var role_pos: ?usize = null;
            var role_pat_len: usize = 0;
            for (role_patterns) |rpat| {
                if (std.mem.indexOfPos(u8, search_region, search_start, rpat)) |pos| {
                    if (role_pos == null or pos < role_pos.?) {
                        role_pos = pos;
                        role_pat_len = rpat.len;
                    }
                }
            }
            
            if (role_pos == null) break;
            
            const role_text_start = role_pos.? + role_pat_len;
            const role_text_end = findClosingQuote(search_region, role_text_start);
            
            // Find the paired "content" field after this role
            var content_found = false;
            for (content_patterns) |cpat| {
                if (std.mem.indexOfPos(u8, search_region, role_text_end, cpat)) |cpos| {
                    const text_start = cpos + cpat.len;
                    const text_end = findClosingQuote(search_region, text_start);
                    
                    // Calculate offset into original json_bytes
                    const base_offset = @intFromPtr(search_region.ptr) - @intFromPtr(json_bytes.ptr);
                    result.messages[result.num_messages] = .{
                        .role_start = @intCast(base_offset + role_text_start),
                        .role_end = @intCast(base_offset + role_text_end),
                        .content_start = @intCast(base_offset + text_start),
                        .content_end = @intCast(base_offset + text_end),
                    };
                    result.total_content_len += @intCast(text_end - text_start);
                    result.num_messages += 1;
                    
                    search_start = text_end + 1;
                    content_found = true;
                    break;
                }
            }
            
            if (!content_found) {
                search_start = role_text_end + 1;
            }
        }
        
        _ = self.messages_parsed.fetchAdd(result.num_messages, .monotonic);
        
        return result;
    }
    
    /// Walk forward from `start` to find the closing (unescaped) quote.
    fn findClosingQuote(data: []const u8, start: usize) usize {
        var i = start;
        var in_escape = false;
        while (i < data.len) {
            const c = data[i];
            if (in_escape) {
                in_escape = false;
                i += 1;
                continue;
            }
            if (c == '\\') {
                in_escape = true;
                i += 1;
                continue;
            }
            if (c == '"') return i;
            i += 1;
        }
        return i;
    }
    
    fn findPattern(self: *GpuJsonParser, json_bytes: []const u8, pattern: []const u8) ?GpuParseResult {
        const match_pos = std.mem.indexOf(u8, json_bytes, pattern);
        
        if (match_pos) |pos| {
            const text_start = pos + pattern.len;
            
            // Find the closing quote, handling escapes
            var text_end = text_start;
            var in_escape = false;
            
            while (text_end < json_bytes.len) {
                const c = json_bytes[text_end];
                
                if (in_escape) {
                    in_escape = false;
                    text_end += 1;
                    continue;
                }
                
                if (c == '\\' and self.config.handle_escapes) {
                    in_escape = true;
                    text_end += 1;
                    continue;
                }
                
                if (c == '"') {
                    return GpuParseResult{
                        .text_start = @intCast(text_start),
                        .text_end = @intCast(text_end),
                        .status = @intFromEnum(ParseStatus.success),
                        .error_code = 0,
                        .bytes_scanned = @intCast(json_bytes.len),
                        ._reserved = .{ 0, 0, 0 },
                    };
                }
                
                text_end += 1;
            }
            
            return GpuParseResult{
                .text_start = @intCast(text_start),
                .text_end = @intCast(text_end),
                .status = @intFromEnum(ParseStatus.unterminated_string),
                .error_code = 3,
                .bytes_scanned = @intCast(json_bytes.len),
                ._reserved = .{ 0, 0, 0 },
            };
        }
        
        return null;
    }
    
    /// Extract the text content from the original bytes using parse result
    pub fn extractText(self: *const GpuJsonParser, json_bytes: []const u8, result: GpuParseResult) ?[]const u8 {
        _ = self;
        if (result.status != @intFromEnum(ParseStatus.success)) {
            return null;
        }
        
        if (result.text_start >= json_bytes.len or result.text_end > json_bytes.len) {
            return null;
        }
        
        return json_bytes[result.text_start..result.text_end];
    }
    
    /// Get parser statistics
    pub fn getStats(self: *const GpuJsonParser) ParserStats {
        const count = self.parse_count.load(.acquire);
        const time = self.total_parse_time_ns.load(.acquire);
        
        return .{
            .parse_count = count,
            .total_bytes_scanned = self.total_bytes_scanned.load(.acquire),
            .cache_hits = self.cache_hits.load(.acquire),
            .pattern_match_failures = self.pattern_match_failures.load(.acquire),
            .total_parse_time_ns = time,
            .avg_parse_time_ns = if (count > 0) time / count else 0,
            .messages_parsed = self.messages_parsed.load(.acquire),
        };
    }
};

pub const ParserStats = struct {
    parse_count: u64,
    total_bytes_scanned: u64,
    cache_hits: u64,
    pattern_match_failures: u64,
    total_parse_time_ns: u64,
    avg_parse_time_ns: u64,
    messages_parsed: u64,
};

// ============================================================================
// GPU Kernel Structures (for CUDA/Metal)
// ============================================================================

/// GPU kernel flags (bitfield).
pub const KernelFlags = struct {
    pub const HANDLE_ESCAPES: u32 = 1 << 0;
    pub const MULTI_MESSAGE: u32 = 1 << 1;
};

/// GPU Kernel parameter block for single-field JSON parsing.
/// Fields ordered: u64s first, then u32s — no implicit ABI padding.
/// Layout: 3×u64(24) + 4×u32(16) = 40 bytes, naturally aligned.
pub const JsonParserKernel = extern struct {
    /// Device pointer to input JSON bytes
    input_ptr: u64,
    /// Device pointer to output GpuParseResult
    output_ptr: u64,
    /// Pattern to search for (device memory)
    pattern_ptr: u64,
    /// Length of input in bytes
    input_len: u32,
    /// Pattern length
    pattern_len: u32,
    /// Configuration flags (see KernelFlags)
    flags: u32,
    /// Explicit padding for 8-byte struct alignment
    _padding: u32 = 0,

    /// Populate from parser state and device pointers.
    pub fn fromParser(
        parser: *const GpuJsonParser,
        dev_input: u64,
        dev_output: u64,
        dev_pattern: u64,
        input_len: u32,
    ) JsonParserKernel {
        var flags: u32 = 0;
        if (parser.config.handle_escapes) flags |= KernelFlags.HANDLE_ESCAPES;
        if (parser.config.multi_message) flags |= KernelFlags.MULTI_MESSAGE;
        return .{
            .input_ptr = dev_input,
            .output_ptr = dev_output,
            .pattern_ptr = dev_pattern,
            .input_len = input_len,
            .pattern_len = @intCast(parser.pattern_len),
            .flags = flags,
        };
    }

    /// Raw byte slice for GPU dispatch calls.
    pub fn asBytes(self: *const JsonParserKernel) []const u8 {
        return std.mem.asBytes(self);
    }
};

/// Multi-message batch parsing kernel.
/// Fields ordered: u64s first, then u32s — no implicit ABI padding.
/// Layout: 2×u64(16) + 4×u32(16) = 32 bytes, naturally aligned.
pub const MultiMessageParserKernel = extern struct {
    /// Device pointer to input JSON bytes
    input_ptr: u64,
    /// Device pointer to MultiMessageParseResult
    output_ptr: u64,
    /// Length of input in bytes
    input_len: u32,
    /// Maximum messages to parse
    max_messages: u32,
    /// Flags (see KernelFlags)
    flags: u32,
    /// Explicit padding
    _padding: u32 = 0,
};

// ============================================================================
// Tests
// ============================================================================

test "GpuJsonParser basic parsing" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();
    
    const json = "{\"content\": \"Hello world\", \"role\": \"user\"}";
    const result = parser.parse(json);
    
    try std.testing.expectEqual(@as(u32, @intFromEnum(ParseStatus.success)), result.status);
    
    const text = parser.extractText(json, result);
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("Hello world", text.?);
}

test "GpuJsonParser chat completion messages" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();
    
    const json =
        \\{"messages": [
        \\  {"role": "system", "content": "You are helpful."},
        \\  {"role": "user", "content": "Hello!"},
        \\  {"role": "assistant", "content": "Hi there!"}
        \\]}
    ;
    
    const result = parser.parseMessages(json);
    
    try std.testing.expectEqual(@as(u32, 3), result.num_messages);
}

test "GpuJsonParser pattern not found" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{
        .target_field = "nonexistent",
        .alt_fields = &[_][]const u8{},
    });
    defer parser.deinit();
    
    const json = "{\"content\": \"test\"}";
    const result = parser.parse(json);
    
    try std.testing.expectEqual(@as(u32, @intFromEnum(ParseStatus.pattern_not_found)), result.status);
}

test "JsonParserKernel has no implicit padding" {
    // 3×u64(24) + 4×u32(16) = 40 bytes exactly
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(JsonParserKernel));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(JsonParserKernel));
}

test "MultiMessageParserKernel has no implicit padding" {
    // 2×u64(16) + 4×u32(16) = 32 bytes exactly
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(MultiMessageParserKernel));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(MultiMessageParserKernel));
}

test "JsonParserKernel fromParser and asBytes" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();

    const params = JsonParserKernel.fromParser(parser, 0x1000, 0x2000, 0x3000, 512);
    try std.testing.expectEqual(@as(u64, 0x1000), params.input_ptr);
    try std.testing.expectEqual(@as(u64, 0x2000), params.output_ptr);
    try std.testing.expectEqual(@as(u64, 0x3000), params.pattern_ptr);
    try std.testing.expectEqual(@as(u32, 512), params.input_len);
    // Should have both HANDLE_ESCAPES and MULTI_MESSAGE set (defaults)
    try std.testing.expect(params.flags & KernelFlags.HANDLE_ESCAPES != 0);
    try std.testing.expect(params.flags & KernelFlags.MULTI_MESSAGE != 0);

    const bytes = params.asBytes();
    try std.testing.expectEqual(@as(usize, 40), bytes.len);
}

test "GpuJsonParser statistics" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();
    
    _ = parser.parse("{\"content\": \"test1\"}");
    _ = parser.parse("{\"content\": \"test2\"}");
    
    const stats = parser.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.parse_count);
}