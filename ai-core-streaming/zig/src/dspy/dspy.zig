// DSPy Self-Improving Pipeline for AI-Core-Streaming
//
// Integration with streaming layer for real-time:
// 1. Quality evaluation
// 2. Training data accumulation
// 3. Online optimization

const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = std.mem.Allocator;

// =============================================================================
// SIGNATURES (imported from fabric)
// =============================================================================

pub const FieldType = enum { string, float, integer, boolean, list };

pub const SignatureField = struct {
    name: []const u8,
    field_type: FieldType,
    description: []const u8,
    required: bool = true,
};

pub const TaskSignature = struct {
    name: []const u8,
    description: []const u8,
    inputs: []const SignatureField,
    outputs: []const SignatureField,
};

pub const QASignature = TaskSignature{
    .name = "QA",
    .description = "Answer questions accurately",
    .inputs = &[_]SignatureField{
        .{ .name = "question", .field_type = .string, .description = "Question" },
    },
    .outputs = &[_]SignatureField{
        .{ .name = "answer", .field_type = .string, .description = "Answer" },
    },
};

// =============================================================================
// STREAMING METRICS
// =============================================================================

pub const StreamingMetricResult = struct {
    name: []const u8,
    score: f64,
    passed: bool,
    timestamp_ns: i128,
};

/// Compute cosine similarity
pub fn cosineSimilarity(a: []const f32, b: []const f32) f64 {
    if (a.len != b.len) return 0.0;
    var dot: f64 = 0.0;
    var norm_a: f64 = 0.0;
    var norm_b: f64 = 0.0;
    for (a, b) |ai, bi| {
        const af: f64 = @floatCast(ai);
        const bf: f64 = @floatCast(bi);
        dot += af * bf;
        norm_a += af * af;
        norm_b += bf * bf;
    }
    if (norm_a == 0.0 or norm_b == 0.0) return 0.0;
    return dot / (math.sqrt(norm_a) * math.sqrt(norm_b));
}

pub const StreamingCorrectnessMetric = struct {
    threshold: f64 = 0.5,

    pub fn evaluate(self: *const StreamingCorrectnessMetric, prediction: []const u8, expected: []const u8) StreamingMetricResult {
        var score: f64 = 0.0;
        if (mem.eql(u8, prediction, expected)) {
            score = 1.0;
        } else if (mem.indexOf(u8, prediction, expected) != null) {
            score = 0.8;
        } else if (mem.indexOf(u8, expected, prediction) != null) {
            score = 0.7;
        }
        return StreamingMetricResult{
            .name = "correctness",
            .score = score,
            .passed = score >= self.threshold,
            .timestamp_ns = std.time.nanoTimestamp(),
        };
    }
};

pub const StreamingSafetyMetric = struct {
    unsafe_patterns: []const []const u8 = &[_][]const u8{ "kill", "hack", "attack" },

    pub fn evaluate(self: *const StreamingSafetyMetric, text: []const u8) StreamingMetricResult {
        var lower_buf: [4096]u8 = undefined;
        const lower_text = std.ascii.lowerString(&lower_buf, text);
        for (self.unsafe_patterns) |pattern| {
            if (mem.indexOf(u8, lower_text, pattern) != null) {
                return StreamingMetricResult{
                    .name = "safety",
                    .score = 0.0,
                    .passed = false,
                    .timestamp_ns = std.time.nanoTimestamp(),
                };
            }
        }
        return StreamingMetricResult{
            .name = "safety",
            .score = 1.0,
            .passed = true,
            .timestamp_ns = std.time.nanoTimestamp(),
        };
    }
};

// =============================================================================
// STREAMING ACCUMULATOR
// =============================================================================

pub const StreamingExample = struct {
    question: []const u8,
    answer: []const u8,
    score: f64,
    timestamp_ns: i128,
};

pub const StreamingAccumulator = struct {
    allocator: Allocator,
    examples: std.ArrayList(StreamingExample),
    max_examples: usize = 1000,
    min_score: f64 = 0.5,
    total_seen: usize = 0,
    total_kept: usize = 0,

    pub fn init(allocator: Allocator) StreamingAccumulator {
        return .{
            .allocator = allocator,
            .examples = std.ArrayList(StreamingExample).init(allocator),
        };
    }

    pub fn deinit(self: *StreamingAccumulator) void {
        self.examples.deinit();
    }

    pub fn add(self: *StreamingAccumulator, question: []const u8, answer: []const u8, score: f64) !void {
        self.total_seen += 1;

        if (score < self.min_score) return;

        const example = StreamingExample{
            .question = question,
            .answer = answer,
            .score = score,
            .timestamp_ns = std.time.nanoTimestamp(),
        };

        if (self.examples.items.len < self.max_examples) {
            try self.examples.append(example);
            self.total_kept += 1;
        } else {
            // Replace lowest scoring example if this is better
            var min_idx: usize = 0;
            var min_score: f64 = self.examples.items[0].score;
            for (self.examples.items, 0..) |ex, i| {
                if (ex.score < min_score) {
                    min_score = ex.score;
                    min_idx = i;
                }
            }
            if (score > min_score) {
                self.examples.items[min_idx] = example;
            }
        }
    }

    pub fn getStats(self: *const StreamingAccumulator) struct { seen: usize, kept: usize, avg_score: f64 } {
        var sum: f64 = 0;
        for (self.examples.items) |ex| {
            sum += ex.score;
        }
        const avg = if (self.examples.items.len > 0) sum / @as(f64, @floatFromInt(self.examples.items.len)) else 0;
        return .{
            .seen = self.total_seen,
            .kept = self.total_kept,
            .avg_score = avg,
        };
    }
};

// =============================================================================
// QUALITY TRACKER
// =============================================================================

pub const QualitySnapshot = struct {
    task: []const u8,
    model: []const u8,
    score: f64,
    n_examples: usize,
    timestamp_ns: i128,
};

pub const QualityTracker = struct {
    allocator: Allocator,
    history: std.ArrayList(QualitySnapshot),
    max_history: usize = 100,

    pub fn init(allocator: Allocator) QualityTracker {
        return .{
            .allocator = allocator,
            .history = std.ArrayList(QualitySnapshot).init(allocator),
        };
    }

    pub fn deinit(self: *QualityTracker) void {
        self.history.deinit();
    }

    pub fn record(self: *QualityTracker, task: []const u8, model: []const u8, score: f64, n_examples: usize) !void {
        const snapshot = QualitySnapshot{
            .task = task,
            .model = model,
            .score = score,
            .n_examples = n_examples,
            .timestamp_ns = std.time.nanoTimestamp(),
        };

        if (self.history.items.len >= self.max_history) {
            _ = self.history.orderedRemove(0);
        }
        try self.history.append(snapshot);
    }

    pub fn isImproving(self: *const QualityTracker, task: []const u8, model: []const u8) bool {
        var recent_scores: [5]f64 = undefined;
        var count: usize = 0;

        var i = self.history.items.len;
        while (i > 0 and count < 5) {
            i -= 1;
            const snap = self.history.items[i];
            if (mem.eql(u8, snap.task, task) and mem.eql(u8, snap.model, model)) {
                recent_scores[count] = snap.score;
                count += 1;
            }
        }

        if (count < 2) return true;

        // Simple trend check
        return recent_scores[0] >= recent_scores[count - 1];
    }
};

// =============================================================================
// TRAINING DATA
// =============================================================================

pub const Example = struct {
    question: []const u8,
    answer: []const u8,
    topic: []const u8,
    score: f64,
};

pub const seed_examples = [_]Example{
    .{ .question = "What is the capital of France?", .answer = "Paris", .topic = "geography", .score = 0.9 },
    .{ .question = "What is 2 + 2?", .answer = "4", .topic = "math", .score = 0.9 },
    .{ .question = "What is H2O?", .answer = "Water", .topic = "science", .score = 0.9 },
};

pub const SimilarityPair = struct {
    text1: []const u8,
    text2: []const u8,
    expected: f64,
    relationship: []const u8,
};

pub const similarity_pairs = [_]SimilarityPair{
    .{ .text1 = "The cat sat on the mat", .text2 = "A cat is sitting on a rug", .expected = 0.85, .relationship = "similar" },
    .{ .text1 = "The cat sat on the mat", .text2 = "Quantum physics is complex", .expected = 0.15, .relationship = "unrelated" },
};

// =============================================================================
// TESTS
// =============================================================================

test "streaming correctness metric" {
    const metric = StreamingCorrectnessMetric{};
    const result = metric.evaluate("Paris", "Paris");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.score, 0.0001);
}

test "streaming safety metric" {
    const metric = StreamingSafetyMetric{};
    const result = metric.evaluate("Paris is beautiful");
    try std.testing.expect(result.passed);
}

test "streaming accumulator" {
    var acc = StreamingAccumulator.init(std.testing.allocator);
    defer acc.deinit();

    try acc.add("Q1", "A1", 0.8);
    try acc.add("Q2", "A2", 0.3); // Below threshold
    try acc.add("Q3", "A3", 0.9);

    const stats = acc.getStats();
    try std.testing.expectEqual(@as(usize, 3), stats.seen);
    try std.testing.expectEqual(@as(usize, 2), stats.kept);
}

test "cosine similarity" {
    const a = [_]f32{ 1.0, 0.0 };
    const b = [_]f32{ 1.0, 0.0 };
    const result = cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result, 0.0001);
}