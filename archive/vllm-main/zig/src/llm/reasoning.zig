//! Reasoning Model Support
//!
//! Handles reasoning models (o1, DeepSeek-R1) that produce internal thinking tokens
//! wrapped in <think>...</think> tags. Supports toggling whether thinking tokens are
//! returned in the response and tracking thinking vs output token budgets separately.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

pub const ReasoningConfig = struct {
    /// Whether to include <think> tokens in the output
    show_thinking: bool = false,
    /// Maximum number of thinking tokens before forcing output
    max_thinking_tokens: u32 = 4096,
    /// Token ID for <think> start (model-specific)
    think_start_token: u32 = 151643,
    /// Token ID for </think> end
    think_end_token: u32 = 151644,
    /// Whether to budget thinking tokens separately from output tokens
    separate_thinking_budget: bool = true,
};

// ============================================================================
// Reasoning Phase Tracking
// ============================================================================

pub const ReasoningPhase = enum {
    normal,        // Regular output generation
    thinking,      // Inside <think>...</think> block
    transitioning, // Just finished thinking, about to output
};

pub const ReasoningState = struct {
    phase: ReasoningPhase,
    thinking_tokens: u32,
    output_tokens: u32,
    think_depth: u32,

    pub fn init() ReasoningState {
        return .{
            .phase = .normal,
            .thinking_tokens = 0,
            .output_tokens = 0,
            .think_depth = 0,
        };
    }

    pub fn processToken(self: *ReasoningState, token_id: u32, config: *const ReasoningConfig) TokenAction {
        if (token_id == config.think_start_token) {
            self.phase = .thinking;
            self.think_depth += 1;
            return if (config.show_thinking) .emit_as_thinking else .suppress;
        }
        if (token_id == config.think_end_token) {
            if (self.think_depth > 0) self.think_depth -= 1;
            if (self.think_depth == 0) {
                self.phase = .transitioning;
            }
            return if (config.show_thinking) .emit_as_thinking else .suppress;
        }
        if (self.phase == .thinking) {
            self.thinking_tokens += 1;
            if (config.separate_thinking_budget and self.thinking_tokens >= config.max_thinking_tokens) {
                return .force_end_think;
            }
            return if (config.show_thinking) .emit_as_thinking else .suppress;
        }
        self.phase = .normal;
        self.output_tokens += 1;
        return .emit;
    }

    pub fn thinkingBudgetExhausted(self: *const ReasoningState, config: *const ReasoningConfig) bool {
        return config.separate_thinking_budget and self.thinking_tokens >= config.max_thinking_tokens;
    }

    pub fn reset(self: *ReasoningState) void {
        self.phase = .normal;
        self.thinking_tokens = 0;
        self.output_tokens = 0;
        self.think_depth = 0;
    }
};

// ============================================================================
// Token Actions
// ============================================================================

pub const TokenAction = enum {
    emit,              // Include in response
    suppress,          // Don't include (thinking token, hidden)
    force_end_think,   // Force end of thinking phase
    emit_as_thinking,  // Include but mark as thinking content
};

// ============================================================================
// Reasoning Processor
// ============================================================================

pub const ReasoningProcessor = struct {
    allocator: Allocator,
    config: ReasoningConfig,
    states: std.ArrayListUnmanaged(ReasoningState),

    pub fn init(allocator: Allocator, config: ReasoningConfig) ReasoningProcessor {
        return .{
            .allocator = allocator,
            .config = config,
            .states = .empty,
        };
    }

    pub fn deinit(self: *ReasoningProcessor) void {
        self.states.deinit();
    }

    pub fn addSequence(self: *ReasoningProcessor) !usize {
        try self.states.append(ReasoningState.init());
        return self.states.items.len - 1;
    }

    pub fn processToken(self: *ReasoningProcessor, seq_idx: usize, token_id: u32) TokenAction {
        if (seq_idx >= self.states.items.len) return .emit;
        return self.states.items[seq_idx].processToken(token_id, &self.config);
    }

    pub fn thinkingTokenCount(self: *const ReasoningProcessor, seq_idx: usize) u32 {
        if (seq_idx >= self.states.items.len) return 0;
        return self.states.items[seq_idx].thinking_tokens;
    }

    pub fn outputTokenCount(self: *const ReasoningProcessor, seq_idx: usize) u32 {
        if (seq_idx >= self.states.items.len) return 0;
        return self.states.items[seq_idx].output_tokens;
    }

    pub fn stripThinkingTags(text: []const u8) []const u8 {
        if (std.mem.indexOf(u8, text, "<think>")) |start| {
            if (std.mem.indexOf(u8, text[start..], "</think>")) |end_rel| {
                const end = start + end_rel + 8;
                if (end < text.len) {
                    return text[end..];
                }
            }
        }
        return text;
    }

    pub fn anyThinking(self: *const ReasoningProcessor) bool {
        for (self.states.items) |state| {
            if (state.phase == .thinking) return true;
        }
        return false;
    }

    pub fn removeSequence(self: *ReasoningProcessor, seq_idx: usize) void {
        if (seq_idx < self.states.items.len) {
            _ = self.states.orderedRemove(seq_idx);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "reasoning state init" {
    const state = ReasoningState.init();
    try std.testing.expectEqual(ReasoningPhase.normal, state.phase);
    try std.testing.expectEqual(@as(u32, 0), state.thinking_tokens);
    try std.testing.expectEqual(@as(u32, 0), state.output_tokens);
}

test "reasoning state process think tokens" {
    var state = ReasoningState.init();
    const config = ReasoningConfig{ .show_thinking = false };
    const action1 = state.processToken(151643, &config);
    try std.testing.expectEqual(TokenAction.suppress, action1);
    try std.testing.expectEqual(ReasoningPhase.thinking, state.phase);
    const action2 = state.processToken(151644, &config);
    try std.testing.expectEqual(TokenAction.suppress, action2);
}

test "reasoning state thinking budget exhaustion" {
    var state = ReasoningState.init();
    const config = ReasoningConfig{ .max_thinking_tokens = 5, .separate_thinking_budget = true };
    _ = state.processToken(151643, &config);
    for (0..5) |_| {
        _ = state.processToken(999, &config);
    }
    try std.testing.expect(state.thinkingBudgetExhausted(&config));
}

test "reasoning processor multiple sequences" {
    var proc = ReasoningProcessor.init(std.testing.allocator, .{});
    defer proc.deinit();
    const idx1 = try proc.addSequence();
    const idx2 = try proc.addSequence();
    try std.testing.expectEqual(@as(usize, 0), idx1);
    try std.testing.expectEqual(@as(usize, 1), idx2);
    try std.testing.expectEqual(@as(u32, 0), proc.thinkingTokenCount(idx1));
}

test "strip thinking tags" {
    const text = "<think>internal reasoning</think>final answer";
    const stripped = ReasoningProcessor.stripThinkingTags(text);
    try std.testing.expectEqualStrings("final answer", stripped);
}

test "show thinking vs hidden" {
    var state = ReasoningState.init();
    const config_hidden = ReasoningConfig{ .show_thinking = false };
    const config_shown = ReasoningConfig{ .show_thinking = true };
    const action_hidden = state.processToken(151643, &config_hidden);
    var state2 = ReasoningState.init();
    const action_shown = state2.processToken(151643, &config_shown);
    try std.testing.expectEqual(TokenAction.suppress, action_hidden);
    try std.testing.expectEqual(TokenAction.emit_as_thinking, action_shown);
}

