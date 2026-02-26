//! AIPrompt Streaming GPU-Native JSON Parser
//! Pattern-based field extraction for streaming prompt requests.
//!
//! Architecture:
//!   1. Scans JSON bytes for "input": "..." or "prompt": "..." patterns
//!   2. Escape-aware string extraction returns text bounds
//!   3. GPU kernel structs (KernelParams) defined for Metal dispatch
//!
//! CPU-based pattern matching with simulated parallel chunks.
//! GPU dispatch via Metal json_find_key kernel when available.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.gpu_json_parser);

// ============================================================================
// Pattern Constants (UTF-8 byte sequences)
// ============================================================================

/// The pattern we're searching for: "input": "
pub const INPUT_PATTERN = [_]u8{ '"', 'i', 'n', 'p', 'u', 't', '"', ':', ' ', '"' };
pub const INPUT_PATTERN_ALT = [_]u8{ '"', 'i', 'n', 'p', 'u', 't', '"', ':', '"' };

/// Also support "prompt": " for AIPrompt streaming
pub const PROMPT_PATTERN = [_]u8{ '"', 'p', 'r', 'o', 'm', 'p', 't', '"', ':', ' ', '"' };
pub const PROMPT_PATTERN_ALT = [_]u8{ '"', 'p', 'r', 'o', 'm', 'p', 't', '"', ':', '"' };

pub const PATTERN_LEN: usize = INPUT_PATTERN.len;
pub const PATTERN_ALT_LEN: usize = INPUT_PATTERN_ALT.len;

pub const MAX_INPUT_TEXT_LEN: usize = 32 * 1024;

// ============================================================================
// Parse Result Structure (GPU-resident)
// ============================================================================

pub const GpuParseResult = extern struct {
    text_start: u32,
    text_end: u32,
    status: u32,
    error_code: u32,
    bytes_scanned: u32,
    _padding: [3]u32,
};

pub const ParseStatus = enum(u32) {
    not_found = 0,
    found = 1,
    error_malformed = 2,
    error_unterminated = 3,
    error_escape_sequence = 4,
};

// ============================================================================
// GPU Scanner Configuration
// ============================================================================

pub const ScannerConfig = struct {
    threads_per_block: usize = 256,
    bytes_per_thread: usize = 64,
    handle_escapes: bool = true,
    max_scan_bytes: usize = 1024 * 1024,
};

// ============================================================================
// Parallel Pattern Matcher (simulated kernel)
// ============================================================================

pub const PatternMatcher = struct {
    config: ScannerConfig,

    pub fn init(config: ScannerConfig) PatternMatcher {
        return .{ .config = config };
    }

    pub fn findPattern(
        self: *const PatternMatcher,
        data: []const u8,
        pattern: []const u8,
    ) ?usize {
        const total_bytes = @min(data.len, self.config.max_scan_bytes);
        const num_threads = (total_bytes + self.config.bytes_per_thread - 1) / self.config.bytes_per_thread;

        var results: [1024]?usize = undefined;
        const actual_threads = @min(num_threads, results.len);

        for (0..actual_threads) |thread_id| {
            const start = thread_id * self.config.bytes_per_thread;
            const end = @min(start + self.config.bytes_per_thread + pattern.len - 1, total_bytes);

            if (start >= total_bytes) {
                results[thread_id] = null;
                continue;
            }

            results[thread_id] = self.scanChunk(data, pattern, start, end);
        }

        var first_match: ?usize = null;
        for (results[0..actual_threads]) |maybe_pos| {
            if (maybe_pos) |pos| {
                if (first_match == null or pos < first_match.?) {
                    first_match = pos;
                }
            }
        }

        return first_match;
    }

    fn scanChunk(
        self: *const PatternMatcher,
        data: []const u8,
        pattern: []const u8,
        start: usize,
        end: usize,
    ) ?usize {
        _ = self;
        if (end <= start or end > data.len) return null;

        const search_end = if (end >= pattern.len) end - pattern.len + 1 else start;

        var i = start;
        while (i < search_end) : (i += 1) {
            if (i + pattern.len > data.len) break;

            var matched = true;
            for (pattern, 0..) |c, j| {
                if (data[i + j] != c) {
                    matched = false;
                    break;
                }
            }

            if (matched) {
                return i;
            }
        }

        return null;
    }
};

// ============================================================================
// GPU JSON Parser
// ============================================================================

pub const GpuJsonParser = struct {
    allocator: std.mem.Allocator,
    config: ScannerConfig,
    matcher: PatternMatcher,

    parse_count: std.atomic.Value(u64),
    total_bytes_scanned: std.atomic.Value(u64),
    total_parse_time_ns: std.atomic.Value(u64),
    pattern_match_failures: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: ScannerConfig) !*GpuJsonParser {
        const parser = try allocator.create(GpuJsonParser);

        parser.* = .{
            .allocator = allocator,
            .config = config,
            .matcher = PatternMatcher.init(config),
            .parse_count = std.atomic.Value(u64).init(0),
            .total_bytes_scanned = std.atomic.Value(u64).init(0),
            .total_parse_time_ns = std.atomic.Value(u64).init(0),
            .pattern_match_failures = std.atomic.Value(u64).init(0),
        };

        log.info("GPU JSON Parser initialized:", .{});
        log.info("  Max scan: {} KB", .{config.max_scan_bytes / 1024});

        return parser;
    }

    pub fn deinit(self: *GpuJsonParser) void {
        self.allocator.destroy(self);
    }

    /// Parse JSON bytes to extract "input" or "prompt" field value
    pub fn parseInputField(self: *GpuJsonParser, raw_bytes: []const u8) !GpuParseResult {
        const start_time = std.time.nanoTimestamp();
        defer {
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
            _ = self.total_parse_time_ns.fetchAdd(elapsed, .monotonic);
            _ = self.parse_count.fetchAdd(1, .monotonic);
            _ = self.total_bytes_scanned.fetchAdd(raw_bytes.len, .monotonic);
        }

        // Try "input": " pattern first
        var pattern_pos: ?usize = self.matcher.findPattern(raw_bytes, &INPUT_PATTERN);
        if (pattern_pos) |pos| {
            return self.extractStringValue(raw_bytes, pos + PATTERN_LEN);
        }

        // Try "input":" (no space)
        pattern_pos = self.matcher.findPattern(raw_bytes, &INPUT_PATTERN_ALT);
        if (pattern_pos) |pos| {
            return self.extractStringValue(raw_bytes, pos + PATTERN_ALT_LEN);
        }

        // Try "prompt": " pattern
        pattern_pos = self.matcher.findPattern(raw_bytes, &PROMPT_PATTERN);
        if (pattern_pos) |pos| {
            return self.extractStringValue(raw_bytes, pos + PROMPT_PATTERN.len);
        }

        // Try "prompt":" (no space)
        pattern_pos = self.matcher.findPattern(raw_bytes, &PROMPT_PATTERN_ALT);
        if (pattern_pos) |pos| {
            return self.extractStringValue(raw_bytes, pos + PROMPT_PATTERN_ALT.len);
        }

        _ = self.pattern_match_failures.fetchAdd(1, .monotonic);
        return GpuParseResult{
            .text_start = 0,
            .text_end = 0,
            .status = @intFromEnum(ParseStatus.not_found),
            .error_code = 0,
            .bytes_scanned = @intCast(raw_bytes.len),
            ._padding = .{ 0, 0, 0 },
        };
    }

    fn extractStringValue(self: *GpuJsonParser, data: []const u8, start: usize) GpuParseResult {
        if (start >= data.len) {
            return GpuParseResult{
                .text_start = 0,
                .text_end = 0,
                .status = @intFromEnum(ParseStatus.error_malformed),
                .error_code = 1,
                .bytes_scanned = @intCast(data.len),
                ._padding = .{ 0, 0, 0 },
            };
        }

        var pos = start;
        var in_escape = false;

        while (pos < data.len and pos - start < MAX_INPUT_TEXT_LEN) : (pos += 1) {
            const c = data[pos];

            if (in_escape) {
                in_escape = false;
                continue;
            }

            if (c == '\\' and self.config.handle_escapes) {
                in_escape = true;
                continue;
            }

            if (c == '"') {
                return GpuParseResult{
                    .text_start = @intCast(start),
                    .text_end = @intCast(pos),
                    .status = @intFromEnum(ParseStatus.found),
                    .error_code = 0,
                    .bytes_scanned = @intCast(pos + 1),
                    ._padding = .{ 0, 0, 0 },
                };
            }
        }

        return GpuParseResult{
            .text_start = @intCast(start),
            .text_end = 0,
            .status = @intFromEnum(ParseStatus.error_unterminated),
            .error_code = 2,
            .bytes_scanned = @intCast(pos),
            ._padding = .{ 0, 0, 0 },
        };
    }

    pub fn getExtractedText(self: *const GpuJsonParser, raw_bytes: []const u8, result: GpuParseResult) ?[]const u8 {
        _ = self;
        if (result.status != @intFromEnum(ParseStatus.found)) return null;
        if (result.text_start >= raw_bytes.len or result.text_end > raw_bytes.len) return null;
        return raw_bytes[result.text_start..result.text_end];
    }

    pub fn getStats(self: *const GpuJsonParser) ParserStats {
        const count = self.parse_count.load(.acquire);
        const time = self.total_parse_time_ns.load(.acquire);
        return .{
            .parse_count = count,
            .total_bytes_scanned = self.total_bytes_scanned.load(.acquire),
            .total_parse_time_ns = time,
            .avg_parse_time_ns = if (count > 0) time / count else 0,
            .pattern_match_failures = self.pattern_match_failures.load(.acquire),
        };
    }
};

pub const ParserStats = struct {
    parse_count: u64,
    total_bytes_scanned: u64,
    total_parse_time_ns: u64,
    avg_parse_time_ns: u64,
    pattern_match_failures: u64,
};

// ============================================================================
// GPU Kernel Structures
// ============================================================================

pub const KernelFlags = struct {
    pub const HANDLE_ESCAPES: u32 = 1 << 0;
};

pub const KernelParams = extern struct {
    input_ptr: u64,
    result_ptr: u64,
    pattern_ptr: u64,
    input_len: u32,
    pattern_len: u32,
    flags: u32,
    _padding: u32 = 0,

    pub fn fromParser(
        parser: *const GpuJsonParser,
        dev_input: u64,
        dev_result: u64,
        dev_pattern: u64,
        input_len: u32,
    ) KernelParams {
        var flags: u32 = 0;
        if (parser.config.handle_escapes) flags |= KernelFlags.HANDLE_ESCAPES;
        return .{
            .input_ptr = dev_input,
            .result_ptr = dev_result,
            .pattern_ptr = dev_pattern,
            .input_len = input_len,
            .pattern_len = @intCast(PATTERN_LEN),
            .flags = flags,
        };
    }

    pub fn asBytes(self: *const KernelParams) []const u8 {
        return std.mem.asBytes(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GpuJsonParser basic parsing" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();

    const json_input =
        \\{"model": "streaming", "input": "Hello, world!", "encoding": "float"}
    ;

    const result = try parser.parseInputField(json_input);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ParseStatus.found)), result.status);

    const text = parser.getExtractedText(json_input, result);
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("Hello, world!", text.?);
}

test "GpuJsonParser prompt field" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();

    const json_input =
        \\{"prompt": "Generate inference output."}
    ;

    const result = try parser.parseInputField(json_input);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ParseStatus.found)), result.status);

    const text = parser.getExtractedText(json_input, result);
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("Generate inference output.", text.?);
}

test "GpuJsonParser pattern not found" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();

    const json_input =
        \\{"model": "text-embedding", "text": "Hello"}
    ;

    const result = try parser.parseInputField(json_input);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ParseStatus.not_found)), result.status);
}

test "GpuJsonParser statistics" {
    const parser = try GpuJsonParser.init(std.testing.allocator, .{});
    defer parser.deinit();

    _ = try parser.parseInputField("{\"input\": \"test1\"}");
    _ = try parser.parseInputField("{\"prompt\": \"test2\"}");
    _ = try parser.parseInputField("{\"other\": \"test3\"}");

    const stats = parser.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.parse_count);
    try std.testing.expectEqual(@as(u64, 1), stats.pattern_match_failures);
}
