//! BDC AIPrompt Streaming - Data Classification
//! Automatic classification of message payloads using bdc-intelligence-fabric rules

const std = @import("std");

const log = std.log.scoped(.classification);

// ============================================================================
// Classification Levels
// ============================================================================

pub const ClassificationLevel = enum {
    /// Public data - no restrictions
    public,
    /// Internal data - company internal
    internal,
    /// Confidential data - restricted access
    confidential,
    /// Restricted data - highly sensitive (PII, financial)
    restricted,

    pub fn toString(self: ClassificationLevel) []const u8 {
        return switch (self) {
            .public => "public",
            .internal => "internal",
            .confidential => "confidential",
            .restricted => "restricted",
        };
    }

    pub fn fromString(s: []const u8) ClassificationLevel {
        if (std.mem.eql(u8, s, "public")) return .public;
        if (std.mem.eql(u8, s, "internal")) return .internal;
        if (std.mem.eql(u8, s, "confidential")) return .confidential;
        if (std.mem.eql(u8, s, "restricted")) return .restricted;
        return .public;
    }

    /// Get retention days for classification level
    pub fn getRetentionDays(self: ClassificationLevel) u32 {
        return switch (self) {
            .public => 365,
            .internal => 730,
            .confidential => 1825,
            .restricted => 2555,
        };
    }

    /// Check if encryption is required
    pub fn requiresEncryption(self: ClassificationLevel) bool {
        return switch (self) {
            .public => false,
            .internal => false,
            .confidential => true,
            .restricted => true,
        };
    }

    /// Check if audit logging is required
    pub fn requiresAuditLogging(self: ClassificationLevel) bool {
        return switch (self) {
            .public => false,
            .internal => false,
            .confidential => false,
            .restricted => true,
        };
    }
};

// ============================================================================
// Classification Rules (from bdc-intelligence-fabric)
// ============================================================================

pub const ClassificationRule = struct {
    rule_id: []const u8,
    pattern: []const u8,
    classification: ClassificationLevel,
    priority: u32,
    compiled_pattern: ?*anyopaque,

    pub fn init(rule_id: []const u8, pattern: []const u8, classification: ClassificationLevel, priority: u32) ClassificationRule {
        return .{
            .rule_id = rule_id,
            .pattern = pattern,
            .classification = classification,
            .priority = priority,
            .compiled_pattern = null,
        };
    }
};

// ============================================================================
// Classification Result
// ============================================================================

pub const ClassificationResult = struct {
    /// Determined classification level
    level: ClassificationLevel,
    /// Matched rules
    matched_rules: []const []const u8,
    /// Confidence score (0.0 - 1.0)
    confidence: f32,
    /// Detected sensitive patterns
    detected_patterns: []DetectedPattern,
    /// Processing time in microseconds
    processing_time_us: u64,
};

pub const DetectedPattern = struct {
    pattern_type: PatternType,
    location: Location,
    masked_value: []const u8,
};

pub const PatternType = enum {
    email,
    phone,
    ssn,
    credit_card,
    ip_address,
    api_key,
    password,
    internal_keyword,
    confidential_keyword,
    custom,
};

pub const Location = struct {
    start: usize,
    end: usize,
};

// ============================================================================
// Data Classifier
// ============================================================================

pub const DataClassifier = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(ClassificationRule),
    enabled: bool,

    // Built-in patterns
    email_pattern: []const u8 = "(?i)\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}\\b",
    ssn_pattern: []const u8 = "\\b\\d{3}-\\d{2}-\\d{4}\\b",
    credit_card_pattern: []const u8 = "\\b(?:\\d[ -]*?){13,16}\\b",
    phone_pattern: []const u8 = "\\b(?:\\+?\\d{1,3}[-.]?)?\\(?\\d{3}\\)?[-.]?\\d{3}[-.]?\\d{4}\\b",
    ip_pattern: []const u8 = "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b",
    api_key_pattern: []const u8 = "(?i)(api[_-]?key|apikey|secret[_-]?key)\\s*[=:]\\s*['\"]?[A-Za-z0-9_-]{20,}",

    // Statistics
    total_classifications: std.atomic.Value(u64),
    restricted_count: std.atomic.Value(u64),
    confidential_count: std.atomic.Value(u64),
    internal_count: std.atomic.Value(u64),
    public_count: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator) DataClassifier {
        var classifier = DataClassifier{
            .allocator = allocator,
            .rules = .{},
            .enabled = true,
            .total_classifications = std.atomic.Value(u64).init(0),
            .restricted_count = std.atomic.Value(u64).init(0),
            .confidential_count = std.atomic.Value(u64).init(0),
            .internal_count = std.atomic.Value(u64).init(0),
            .public_count = std.atomic.Value(u64).init(0),
        };

        // Load default rules
        classifier.loadDefaultRules() catch {};

        return classifier;
    }

    pub fn deinit(self: *DataClassifier) void {
        self.rules.deinit(self.allocator);
    }

    /// Load default classification rules (mirroring bdc-intelligence-fabric)
    fn loadDefaultRules(self: *DataClassifier) !void {
        // Email addresses -> restricted
        try self.rules.append(self.allocator, ClassificationRule.init(
            "rule-email",
            self.email_pattern,
            .restricted,
            10,
        ));

        // SSN -> restricted
        try self.rules.append(self.allocator, ClassificationRule.init(
            "rule-ssn",
            self.ssn_pattern,
            .restricted,
            10,
        ));

        // Credit card -> restricted
        try self.rules.append(self.allocator, ClassificationRule.init(
            "rule-credit-card",
            self.credit_card_pattern,
            .restricted,
            10,
        ));

        // API keys -> restricted
        try self.rules.append(self.allocator, ClassificationRule.init(
            "rule-api-key",
            self.api_key_pattern,
            .restricted,
            10,
        ));

        // Internal keywords -> internal
        try self.rules.append(self.allocator, ClassificationRule.init(
            "rule-internal",
            "(?i)(internal|proprietary)",
            .internal,
            5,
        ));

        // Confidential keywords -> confidential
        try self.rules.append(self.allocator, ClassificationRule.init(
            "rule-confidential",
            "(?i)(confidential|secret|private)",
            .confidential,
            7,
        ));

        log.info("Loaded {} default classification rules", .{self.rules.items.len});
    }

    /// Add custom classification rule
    pub fn addRule(self: *DataClassifier, rule: ClassificationRule) !void {
        try self.rules.append(self.allocator, rule);
    }

    /// Classify message payload
    pub fn classify(self: *DataClassifier, payload: []const u8) ClassificationResult {
        const start_time = std.time.microTimestamp();

        if (!self.enabled or payload.len == 0) {
            return .{
                .level = .public,
                .matched_rules = &[_][]const u8{},
                .confidence = 1.0,
                .detected_patterns = &[_]DetectedPattern{},
                .processing_time_us = 0,
            };
        }

        var highest_level = ClassificationLevel.public;
        var highest_priority: u32 = 0;
        var matched: std.ArrayList([]const u8) = .{};
        var patterns: std.ArrayList(DetectedPattern) = .{};

        // Simple pattern matching (in production: use compiled regex)
        for (self.rules.items) |rule| {
            if (self.simplePatternMatch(payload, rule.pattern)) {
                matched.append(self.allocator, rule.rule_id) catch {};

                if (rule.priority > highest_priority or
                    (@intFromEnum(rule.classification) > @intFromEnum(highest_level)))
                {
                    highest_level = rule.classification;
                    highest_priority = rule.priority;
                }
            }
        }

        // Check for specific sensitive patterns
        self.detectSensitivePatterns(payload, &patterns);

        // Upgrade classification if sensitive data found
        if (patterns.items.len > 0) {
            for (patterns.items) |pattern| {
                if (pattern.pattern_type == .ssn or
                    pattern.pattern_type == .credit_card or
                    pattern.pattern_type == .api_key)
                {
                    highest_level = .restricted;
                    break;
                }
            }
        }

        _ = self.total_classifications.fetchAdd(1, .monotonic);

        switch (highest_level) {
            .restricted => _ = self.restricted_count.fetchAdd(1, .monotonic),
            .confidential => _ = self.confidential_count.fetchAdd(1, .monotonic),
            .internal => _ = self.internal_count.fetchAdd(1, .monotonic),
            .public => _ = self.public_count.fetchAdd(1, .monotonic),
        }

        const processing_time = @as(u64, @intCast(std.time.microTimestamp() - start_time));

        return .{
            .level = highest_level,
            .matched_rules = matched.toOwnedSlice(self.allocator) catch &[_][]const u8{},
            .confidence = if (matched.items.len > 0) 0.9 else 0.5,
            .detected_patterns = patterns.toOwnedSlice(self.allocator) catch &[_]DetectedPattern{},
            .processing_time_us = processing_time,
        };
    }

    /// Simple pattern matching (case-insensitive substring)
    fn simplePatternMatch(self: *DataClassifier, text: []const u8, pattern: []const u8) bool {
        _ = self;

        // Remove regex markers for simple matching
        const clean_pattern = if (std.mem.startsWith(u8, pattern, "(?i)"))
            pattern[4..]
        else
            pattern;

        // Strip outer parens if present
        const inner = if (clean_pattern.len >= 2 and clean_pattern[0] == '(' and clean_pattern[clean_pattern.len - 1] == ')')
            clean_pattern[1 .. clean_pattern.len - 1]
        else
            clean_pattern;

        // Build lowercase text
        var lower_text: std.ArrayList(u8) = .{};
        defer lower_text.deinit(std.heap.page_allocator);

        for (text) |c| {
            lower_text.append(std.heap.page_allocator, std.ascii.toLower(c)) catch return false;
        }

        // Split on '|' and check each alternative
        var start: usize = 0;
        while (start <= inner.len) {
            const end = std.mem.indexOfScalarPos(u8, inner, start, '|') orelse inner.len;
            const alt = inner[start..end];

            // Build lowercase alternative, stripping regex metacharacters
            var lower_alt: std.ArrayList(u8) = .{};
            defer lower_alt.deinit(std.heap.page_allocator);

            for (alt) |c| {
                if (c != '\\' and c != '(' and c != ')' and c != '[' and c != ']') {
                    lower_alt.append(std.heap.page_allocator, std.ascii.toLower(c)) catch return false;
                }
            }

            if (lower_alt.items.len > 0) {
                if (std.mem.indexOf(u8, lower_text.items, lower_alt.items) != null) {
                    return true;
                }
            }

            if (end >= inner.len) break;
            start = end + 1;
        }

        return false;
    }

    /// Detect specific sensitive patterns
    fn detectSensitivePatterns(self: *DataClassifier, text: []const u8, patterns: *std.ArrayList(DetectedPattern)) void {
        // Detect SSN pattern (xxx-xx-xxxx)
        var i: usize = 0;
        while (i + 10 < text.len) : (i += 1) {
            if (isDigitStatic(text[i]) and
                isDigitStatic(text[i + 1]) and
                isDigitStatic(text[i + 2]) and
                text[i + 3] == '-' and
                isDigitStatic(text[i + 4]) and
                isDigitStatic(text[i + 5]) and
                text[i + 6] == '-' and
                isDigitStatic(text[i + 7]) and
                isDigitStatic(text[i + 8]) and
                isDigitStatic(text[i + 9]) and
                isDigitStatic(text[i + 10]))
            {
                patterns.append(self.allocator, .{
                    .pattern_type = .ssn,
                    .location = .{ .start = i, .end = i + 11 },
                    .masked_value = "***-**-****",
                }) catch {};
            }
        }

        // Detect email pattern (simple check for @)
        i = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '@') {
                // Find boundaries
                var start = i;
                while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) {
                    start -= 1;
                }
                var end = i;
                while (end < text.len and !std.ascii.isWhitespace(text[end])) {
                    end += 1;
                }
                if (end > start + 3) {
                    patterns.append(self.allocator, .{
                        .pattern_type = .email,
                        .location = .{ .start = start, .end = end },
                        .masked_value = "***@***.***",
                    }) catch {};
                }
            }
        }
    }

    fn isDigitStatic(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    /// Get classifier statistics
    pub fn getStats(self: *DataClassifier) ClassifierStats {
        return .{
            .total_classifications = self.total_classifications.load(.monotonic),
            .restricted_count = self.restricted_count.load(.monotonic),
            .confidential_count = self.confidential_count.load(.monotonic),
            .internal_count = self.internal_count.load(.monotonic),
            .public_count = self.public_count.load(.monotonic),
            .rule_count = self.rules.items.len,
        };
    }
};

pub const ClassifierStats = struct {
    total_classifications: u64,
    restricted_count: u64,
    confidential_count: u64,
    internal_count: u64,
    public_count: u64,
    rule_count: usize,
};

// ============================================================================
// Message Classification Decorator
// ============================================================================

pub const ClassifiedMessage = struct {
    /// Original message ID
    message_id: i64,
    /// Classification result
    classification: ClassificationResult,
    /// Whether message was redacted
    redacted: bool,
    /// Redacted payload (if applicable)
    redacted_payload: ?[]const u8,
    /// Original payload hash (for audit)
    payload_hash: [32]u8,

    /// Check if message requires special handling
    pub fn requiresSpecialHandling(self: ClassifiedMessage) bool {
        return self.classification.level == .restricted or
            self.classification.level == .confidential;
    }

    /// Get routing topic based on classification
    pub fn getRoutingTopic(self: ClassifiedMessage, base_topic: []const u8) []const u8 {
        _ = base_topic;
        return switch (self.classification.level) {
            .restricted => "persistent://bdc/classified/restricted",
            .confidential => "persistent://bdc/classified/confidential",
            .internal => "persistent://bdc/classified/internal",
            .public => "persistent://bdc/classified/public",
        };
    }
};

// ============================================================================
// Message Redactor
// ============================================================================

pub const MessageRedactor = struct {
    allocator: std.mem.Allocator,
    redaction_enabled: bool,

    pub fn init(allocator: std.mem.Allocator) MessageRedactor {
        return .{
            .allocator = allocator,
            .redaction_enabled = true,
        };
    }

    /// Redact sensitive data from payload
    pub fn redact(self: *MessageRedactor, payload: []const u8, patterns: []const DetectedPattern) ![]const u8 {
        if (!self.redaction_enabled or patterns.len == 0) {
            return payload;
        }

        var result = try self.allocator.alloc(u8, payload.len);
        @memcpy(result, payload);

        // Sort patterns by start position (descending) to avoid index issues
        // Then redact each pattern
        for (patterns) |pattern| {
            if (pattern.location.end <= result.len) {
                const mask = switch (pattern.pattern_type) {
                    .email => "[EMAIL REDACTED]",
                    .ssn => "[SSN REDACTED]",
                    .credit_card => "[CARD REDACTED]",
                    .api_key => "[KEY REDACTED]",
                    .phone => "[PHONE REDACTED]",
                    else => "[REDACTED]",
                };

                // Simple replacement (in production: maintain length)
                const len = pattern.location.end - pattern.location.start;
                if (len >= mask.len) {
                    @memcpy(result[pattern.location.start..][0..mask.len], mask);
                    for (result[pattern.location.start + mask.len .. pattern.location.end]) |*c| {
                        c.* = '*';
                    }
                }
            }
        }

        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ClassificationLevel properties" {
    try std.testing.expectEqual(@as(u32, 365), ClassificationLevel.public.getRetentionDays());
    try std.testing.expectEqual(@as(u32, 2555), ClassificationLevel.restricted.getRetentionDays());
    try std.testing.expect(!ClassificationLevel.public.requiresEncryption());
    try std.testing.expect(ClassificationLevel.restricted.requiresEncryption());
}

test "DataClassifier basic" {
    const allocator = std.testing.allocator;

    var classifier = DataClassifier.init(allocator);
    defer classifier.deinit();

    // Test public data
    const result1 = classifier.classify("Hello world");
    defer if (result1.matched_rules.len > 0) allocator.free(result1.matched_rules);
    defer if (result1.detected_patterns.len > 0) allocator.free(result1.detected_patterns);
    try std.testing.expectEqual(ClassificationLevel.public, result1.level);

    // Test internal keyword
    const result2 = classifier.classify("This is internal data");
    defer if (result2.matched_rules.len > 0) allocator.free(result2.matched_rules);
    defer if (result2.detected_patterns.len > 0) allocator.free(result2.detected_patterns);
    try std.testing.expectEqual(ClassificationLevel.internal, result2.level);

    // Test confidential keyword
    const result3 = classifier.classify("This is confidential information");
    defer if (result3.matched_rules.len > 0) allocator.free(result3.matched_rules);
    defer if (result3.detected_patterns.len > 0) allocator.free(result3.detected_patterns);
    try std.testing.expectEqual(ClassificationLevel.confidential, result3.level);
}

test "DataClassifier SSN detection" {
    const allocator = std.testing.allocator;

    var classifier = DataClassifier.init(allocator);
    defer classifier.deinit();

    const result = classifier.classify("My SSN is 123-45-6789");
    defer if (result.matched_rules.len > 0) allocator.free(result.matched_rules);
    defer if (result.detected_patterns.len > 0) allocator.free(result.detected_patterns);
    try std.testing.expectEqual(ClassificationLevel.restricted, result.level);
    try std.testing.expect(result.detected_patterns.len > 0);
}