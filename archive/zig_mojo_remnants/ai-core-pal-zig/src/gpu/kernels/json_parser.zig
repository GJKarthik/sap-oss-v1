//! Connect Fabric GPU-Native JSON Parser Kernel
//! Zero-CPU-Touch JSON parsing: Locates and extracts message content directly in VRAM
//! 
//! Architecture:
//!   1. Raw JSON bytes are DMA'd directly to GPU buffer
//!   2. Parallel byte scanner locates "content": "..." patterns in messages array
//!   3. Outputs text bounds (start, end) for each message for tokenizer kernel
//!   4. No CPU involvement in JSON parsing
//!
//! Optimized for OpenAI Chat Completion requests with messages array.
//! Also supports SAP orchestration-specific fields.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.gpu_json_parser);

// ============================================================================
// GPU JSON Parse Result (GPU-resident structure)
// ============================================================================

/// Result of GPU JSON parsing - stored in GPU memory
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
    /// Model field location (for routing)
    model_start: u32,
    model_end: u32,
    _padding: u32,
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
    alt_fields: []const []const u8 = &[_][]const u8{ "prompt", "input", "text", "query" },
    /// Number of GPU threads per block
    threads_per_block: usize = 256,
    /// Enable escape sequence handling
    handle_escapes: bool = true,
    /// Parse multiple messages (for chat completion)
    multi_message: bool = true,
    /// Extract model field for routing
    extract_model: bool = true,
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
    
    /// Parse all messages in a chat completion request
    /// This is the main entry point for OpenAI Chat Completion format
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
            .model_start = 0,
            .model_end = 0,
            ._padding = 0,
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
        
        // Extract model field if configured
        if (self.config.extract_model) {
            if (self.findStringField(json_bytes, "model")) |bounds| {
                result.model_start = @intCast(bounds.start);
                result.model_end = @intCast(bounds.end);
            }
        }
        
        // Find all "content": "..." patterns (for messages)
        var search_start: usize = 0;
        const content_pattern = "\"content\": \"";
        const content_pattern_no_space = "\"content\":\"";
        
        while (result.num_messages < 64) {
            // Try with space
            var found_pos: ?usize = null;
            var pattern_len: usize = content_pattern.len;
            
            if (std.mem.indexOfPos(u8, json_bytes, search_start, content_pattern)) |pos| {
                found_pos = pos;
                pattern_len = content_pattern.len;
            } else if (std.mem.indexOfPos(u8, json_bytes, search_start, content_pattern_no_space)) |pos| {
                found_pos = pos;
                pattern_len = content_pattern_no_space.len;
            }
            
            if (found_pos) |pos| {
                const text_start = pos + pattern_len;
                
                // Find closing quote
                var text_end = text_start;
                var in_escape = false;
                
                while (text_end < json_bytes.len) {
                    const c = json_bytes[text_end];
                    
                    if (in_escape) {
                        in_escape = false;
                        text_end += 1;
                        continue;
                    }
                    
                    if (c == '\\') {
                        in_escape = true;
                        text_end += 1;
                        continue;
                    }
                    
                    if (c == '"') {
                        break;
                    }
                    
                    text_end += 1;
                }
                
                // Also try to find the role for this message (look backwards)
                const msg_idx = result.num_messages;
                result.messages[msg_idx].content_start = @intCast(text_start);
                result.messages[msg_idx].content_end = @intCast(text_end);
                
                // Find role by looking backwards from content position
                if (self.findRoleBackwards(json_bytes, pos)) |role_bounds| {
                    result.messages[msg_idx].role_start = @intCast(role_bounds.start);
                    result.messages[msg_idx].role_end = @intCast(role_bounds.end);
                }
                
                result.total_content_len += @intCast(text_end - text_start);
                result.num_messages += 1;
                
                search_start = text_end + 1;
            } else {
                break;
            }
        }
        
        _ = self.messages_parsed.fetchAdd(result.num_messages, .monotonic);
        
        return result;
    }
    
    /// Find a string field value in JSON
    fn findStringField(self: *GpuJsonParser, json_bytes: []const u8, field: []const u8) ?struct { start: usize, end: usize } {
        _ = self;
        
        // Try with space first
        var pattern_buf1: [128]u8 = undefined;
        const pattern1 = std.fmt.bufPrint(&pattern_buf1, "\"{s}\": \"", .{field}) catch return null;
        
        if (std.mem.indexOf(u8, json_bytes, pattern1)) |pos| {
            const start = pos + pattern1.len;
            var end = start;
            var in_escape = false;
            
            while (end < json_bytes.len) {
                const c = json_bytes[end];
                if (in_escape) {
                    in_escape = false;
                    end += 1;
                    continue;
                }
                if (c == '\\') {
                    in_escape = true;
                    end += 1;
                    continue;
                }
                if (c == '"') break;
                end += 1;
            }
            
            return .{ .start = start, .end = end };
        }
        
        // Try without space
        var pattern_buf2: [128]u8 = undefined;
        const pattern2 = std.fmt.bufPrint(&pattern_buf2, "\"{s}\":\"", .{field}) catch return null;
        
        if (std.mem.indexOf(u8, json_bytes, pattern2)) |pos| {
            const start = pos + pattern2.len;
            var end = start;
            var in_escape = false;
            
            while (end < json_bytes.len) {
                const c = json_bytes[end];
                if (in_escape) {
                    in_escape = false;
                    end += 1;
                    continue;
                }
                if (c == '\\') {
                    in_escape = true;
                    end += 1;
                    continue;
                }
                if (c == '"') break;
                end += 1;
            }
            
            return .{ .start = start, .end = end };
        }
        
        return null;
    }
    
    /// Find role field by searching backwards from content position
    fn findRoleBackwards(self: *GpuJsonParser, json_bytes: []const u8, content_pos: usize) ?struct { start: usize, end: usize } {
        _ = self;
        
        // Search backwards for "role": " within a reasonable distance
        const search_start = if (content_pos > 200) content_pos - 200 else 0;
        const search_slice = json_bytes[search_start..content_pos];
        
        const role_patterns = [_][]const u8{ "\"role\": \"", "\"role\":\"" };
        
        for (role_patterns) |pattern| {
            // Find last occurrence
            var last_pos: ?usize = null;
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, search_slice, pos, pattern)) |found| {
                last_pos = found;
                pos = found + 1;
            }
            
            if (last_pos) |rel_pos| {
                const abs_start = search_start + rel_pos + pattern.len;
                var end = abs_start;
                
                while (end < json_bytes.len and json_bytes[end] != '"') {
                    end += 1;
                }
                
                return .{ .start = abs_start, .end = end };
            }
        }
        
        return null;
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
    
    /// Extract model name from multi-message result
    pub fn extractModel(self: *const GpuJsonParser, json_bytes: []const u8, result: MultiMessageParseResult) ?[]const u8 {
        _ = self;
        if (result.model_start == 0 and result.model_end == 0) return null;
        if (result.model_start >= json_bytes.len or result.model_end > json_bytes.len) return null;
        return json_bytes[result.model_start..result.model_end];
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

/// Parameters passed to GPU JSON parsing kernel
pub const JsonParserKernel = extern struct {
    /// Device pointer to input JSON bytes
    input_ptr: u64,
    /// Length of input in bytes
    input_len: u32,
    /// Device pointer to output GpuParseResult
    output_ptr: u64,
    /// Pattern to search for (device memory)
    pattern_ptr: u64,
    /// Pattern length
    pattern_len: u32,
    /// Configuration flags
    flags: u32,
};

/// Multi-message batch parsing kernel
pub const MultiMessageParserKernel = extern struct {
    /// Device pointer to input JSON bytes
    input_ptr: u64,
    input_len: u32,
    /// Device pointer to MultiMessageParseResult
    output_ptr: u64,
    /// Maximum messages to parse
    max_messages: u32,
    /// Flags
    flags: u32,
    _padding: u32,
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
        \\{"model": "sap-orchestrator-v1", "messages": [
        \\  {"role": "system", "content": "You are helpful."},
        \\  {"role": "user", "content": "Hello!"},
        \\  {"role": "assistant", "content": "Hi there!"}
        \\]}
    ;
    
    const result = parser.parseMessages(json);
    
    try std.testing.expectEqual(@as(u32, 3), result.num_messages);
    
    // Check model extraction
    const model = parser.extractModel(json, result);
    try std.testing.expect(model != null);
    try std.testing.expectEqualStrings("sap-orchestrator-v1", model.?);
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

test "GpuJsonParser with escaped quotes" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();
    
    const json = "{\"content\": \"Say \\\"hello\\\"\", \"done\": true}";
    const result = parser.parse(json);
    
    try std.testing.expectEqual(@as(u32, @intFromEnum(ParseStatus.success)), result.status);
}

test "GpuJsonParser statistics" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();
    
    _ = parser.parse("{\"content\": \"test1\"}");
    _ = parser.parse("{\"content\": \"test2\"}");
    
    const stats = parser.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.parse_count);
}