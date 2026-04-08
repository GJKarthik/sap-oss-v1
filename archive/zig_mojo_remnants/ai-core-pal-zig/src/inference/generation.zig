//! Autoregressive Text Generation
//! Implements token-by-token generation for chat/completion endpoints
//! Supports various sampling strategies: greedy, top-k, top-p (nucleus), temperature

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.generation);

// ============================================================================
// Generation Configuration
// ============================================================================

pub const GenerationConfig = struct {
    /// Maximum new tokens to generate
    max_new_tokens: usize = 256,
    /// Minimum new tokens before allowing EOS
    min_new_tokens: usize = 1,
    
    /// Temperature for softmax (1.0 = neutral, <1 = sharper, >1 = flatter)
    temperature: f32 = 0.7,
    
    /// Top-k sampling (0 = disabled)
    top_k: usize = 50,
    /// Top-p (nucleus) sampling (1.0 = disabled)
    top_p: f32 = 0.9,
    
    /// Repetition penalty (1.0 = disabled)
    repetition_penalty: f32 = 1.1,
    /// Number of tokens to look back for repetition
    repetition_penalty_window: usize = 64,
    
    /// Special token IDs
    eos_token_id: u32 = 2,
    pad_token_id: u32 = 0,
    bos_token_id: u32 = 1,
    
    /// Stop sequences (generation stops if any is produced)
    stop_sequences: []const []const u32 = &.{},
    
    /// Whether to return logprobs
    return_logprobs: bool = false,
    /// Number of top logprobs to return per token
    top_logprobs: usize = 5,
    
    /// Random seed (null = random)
    seed: ?u64 = null,
    
    pub fn greedy() GenerationConfig {
        return .{
            .temperature = 0.0,
            .top_k = 1,
            .top_p = 1.0,
        };
    }
    
    pub fn creative() GenerationConfig {
        return .{
            .temperature = 0.9,
            .top_k = 100,
            .top_p = 0.95,
        };
    }
    
    pub fn balanced() GenerationConfig {
        return .{
            .temperature = 0.7,
            .top_k = 50,
            .top_p = 0.9,
        };
    }
};

// ============================================================================
// Generation Result
// ============================================================================

pub const GenerationResult = struct {
    /// Generated token IDs (includes prompt)
    tokens: []u32,
    /// Number of prompt tokens
    prompt_length: usize,
    /// Number of generated tokens
    generated_length: usize,
    /// Reason generation stopped
    finish_reason: FinishReason,
    /// Total generation time in nanoseconds
    generation_time_ns: i128,
    /// Per-token logprobs (if requested)
    logprobs: ?[]TokenLogprob,
    
    pub fn deinit(self: *GenerationResult, allocator: Allocator) void {
        allocator.free(self.tokens);
        if (self.logprobs) |lp| {
            for (lp) |*item| {
                allocator.free(item.top_tokens);
                allocator.free(item.top_logprobs);
            }
            allocator.free(lp);
        }
    }
};

pub const FinishReason = enum {
    max_length,
    eos_token,
    stop_sequence,
    
    pub fn toString(self: FinishReason) []const u8 {
        return switch (self) {
            .max_length => "length",
            .eos_token => "stop",
            .stop_sequence => "stop",
        };
    }
};

pub const TokenLogprob = struct {
    token: u32,
    logprob: f32,
    top_tokens: []u32,
    top_logprobs: []f32,
};

// ============================================================================
// Autoregressive Generator
// ============================================================================

pub const Generator = struct {
    allocator: Allocator,
    config: GenerationConfig,
    prng: std.Random.DefaultPrng,
    
    // Inference callback - called for each forward pass
    // Returns logits for all vocab tokens given current sequence
    inference_fn: ?*const fn (tokens: []const u32, user_data: ?*anyopaque) anyerror![]f32,
    inference_user_data: ?*anyopaque,
    
    // Statistics
    tokens_generated: std.atomic.Value(u64),
    total_time_ns: std.atomic.Value(i128),
    
    pub fn init(allocator: Allocator, config: GenerationConfig) !*Generator {
        const gen = try allocator.create(Generator);
        
        const seed = config.seed orelse blk: {
            var buf: [8]u8 = undefined;
            std.crypto.random.bytes(&buf);
            break :blk std.mem.readInt(u64, &buf, .little);
        };
        
        gen.* = .{
            .allocator = allocator,
            .config = config,
            .prng = std.Random.DefaultPrng.init(seed),
            .inference_fn = null,
            .inference_user_data = null,
            .tokens_generated = std.atomic.Value(u64).init(0),
            .total_time_ns = std.atomic.Value(i128).init(0),
        };
        
        return gen;
    }
    
    pub fn deinit(self: *Generator) void {
        self.allocator.destroy(self);
    }
    
    /// Set the inference callback function
    pub fn setInferenceCallback(
        self: *Generator,
        callback: *const fn ([]const u32, ?*anyopaque) anyerror![]f32,
        user_data: ?*anyopaque,
    ) void {
        self.inference_fn = callback;
        self.inference_user_data = user_data;
    }
    
    /// Generate tokens autoregressively
    pub fn generate(self: *Generator, prompt_tokens: []const u32) !GenerationResult {
        const start_time = std.time.nanoTimestamp();
        
        // Initialize output buffer
        const max_total = prompt_tokens.len + self.config.max_new_tokens;
        var tokens = try self.allocator.alloc(u32, max_total);
        @memcpy(tokens[0..prompt_tokens.len], prompt_tokens);
        
        var current_len = prompt_tokens.len;
        var generated_count: usize = 0;
        var finish_reason: FinishReason = .max_length;
        
        // Optional logprobs storage
        var logprobs: ?std.ArrayListUnmanaged(TokenLogprob) = null;
        if (self.config.return_logprobs) {
            logprobs = .{};
        }
        
        // Generation loop
        while (generated_count < self.config.max_new_tokens) {
            // Get logits from model
            const logits = try self.runInference(tokens[0..current_len]);
            defer self.allocator.free(logits);
            
            // Apply repetition penalty
            self.applyRepetitionPenalty(logits, tokens[0..current_len]);
            
            // Apply temperature
            if (self.config.temperature > 0) {
                self.applyTemperature(logits);
            }
            
            // Convert to probabilities
            const probs = try self.softmax(logits);
            defer self.allocator.free(probs);
            
            // Sample next token
            const next_token = try self.sample(probs, logits);
            
            // Store logprob if requested
            if (logprobs) |*lp| {
                const token_logprob = try self.getTokenLogprob(next_token, probs, logits);
                try lp.append(self.allocator, token_logprob);
            }
            
            // Append token
            tokens[current_len] = next_token;
            current_len += 1;
            generated_count += 1;
            
            // Check stopping conditions
            if (generated_count >= self.config.min_new_tokens) {
                // EOS token
                if (next_token == self.config.eos_token_id) {
                    finish_reason = .eos_token;
                    break;
                }
                
                // Stop sequences
                if (self.checkStopSequence(tokens[0..current_len])) {
                    finish_reason = .stop_sequence;
                    break;
                }
            }
        }
        
        // Shrink buffer to actual size
        const final_tokens = try self.allocator.realloc(tokens, current_len);
        
        const elapsed = std.time.nanoTimestamp() - start_time;
        _ = self.tokens_generated.fetchAdd(generated_count, .monotonic);
        
        return GenerationResult{
            .tokens = final_tokens,
            .prompt_length = prompt_tokens.len,
            .generated_length = generated_count,
            .finish_reason = finish_reason,
            .generation_time_ns = elapsed,
            .logprobs = if (logprobs) |*lp| try lp.toOwnedSlice(self.allocator) else null,
        };
    }
    
    /// Run inference to get logits (uses callback or mock)
    fn runInference(self: *Generator, tokens: []const u32) ![]f32 {
        if (self.inference_fn) |callback| {
            return try callback(tokens, self.inference_user_data);
        }
        
        // Mock inference: generate random logits based on token patterns
        return try self.mockInference(tokens);
    }
    
    /// Mock inference for testing (generates plausible logits)
    fn mockInference(self: *Generator, tokens: []const u32) ![]f32 {
        const vocab_size: usize = 32000; // Typical LLM vocab size
        var logits = try self.allocator.alloc(f32, vocab_size);
        
        // Initialize with small random values
        var random = self.prng.random();
        for (logits) |*l| {
            l.* = random.floatNorm(f32) * 0.1;
        }
        
        // Boost likelihood of common tokens based on context
        if (tokens.len > 0) {
            const last_token = tokens[tokens.len - 1];
            
            // Simple pattern: boost tokens near the last one
            const range_start = @max(0, @as(i64, @intCast(last_token)) - 100);
            const range_end = @min(vocab_size, last_token + 100);
            
            for (@intCast(range_start)..range_end) |i| {
                logits[i] += 2.0;
            }
            
            // Boost EOS after some tokens
            if (tokens.len > 20) {
                logits[self.config.eos_token_id] += @as(f32, @floatFromInt(tokens.len - 20)) * 0.1;
            }
        }
        
        return logits;
    }
    
    /// Apply repetition penalty to logits
    fn applyRepetitionPenalty(self: *Generator, logits: []f32, tokens: []const u32) void {
        if (self.config.repetition_penalty == 1.0) return;
        
        const window_start = if (tokens.len > self.config.repetition_penalty_window)
            tokens.len - self.config.repetition_penalty_window
        else
            0;
        
        for (tokens[window_start..]) |token| {
            if (token < logits.len) {
                if (logits[token] > 0) {
                    logits[token] /= self.config.repetition_penalty;
                } else {
                    logits[token] *= self.config.repetition_penalty;
                }
            }
        }
    }
    
    /// Apply temperature scaling
    fn applyTemperature(self: *Generator, logits: []f32) void {
        if (self.config.temperature == 1.0) return;
        
        const inv_temp = 1.0 / self.config.temperature;
        for (logits) |*l| {
            l.* *= inv_temp;
        }
    }
    
    /// Convert logits to probabilities via softmax
    fn softmax(self: *Generator, logits: []const f32) ![]f32 {
        var probs = try self.allocator.alloc(f32, logits.len);
        
        // Find max for numerical stability
        var max_logit: f32 = logits[0];
        for (logits[1..]) |l| {
            max_logit = @max(max_logit, l);
        }
        
        // Compute exp and sum
        var sum: f32 = 0;
        for (logits, 0..) |l, i| {
            probs[i] = @exp(l - max_logit);
            sum += probs[i];
        }
        
        // Normalize
        const inv_sum = 1.0 / sum;
        for (probs) |*p| {
            p.* *= inv_sum;
        }
        
        return probs;
    }
    
    /// Sample next token using configured strategy
    fn sample(self: *Generator, probs: []f32, logits: []const f32) !u32 {
        _ = logits;
        
        // Greedy: pick highest probability
        if (self.config.temperature == 0 or self.config.top_k == 1) {
            return self.argmax(probs);
        }
        
        // Apply top-k filtering
        const filtered_probs = try self.allocator.dupe(f32, probs);
        defer self.allocator.free(filtered_probs);
        
        if (self.config.top_k > 0 and self.config.top_k < probs.len) {
            self.applyTopK(filtered_probs);
        }
        
        // Apply top-p (nucleus) filtering
        if (self.config.top_p < 1.0) {
            self.applyTopP(filtered_probs);
        }
        
        // Renormalize
        var sum: f32 = 0;
        for (filtered_probs) |p| sum += p;
        if (sum > 0) {
            const inv_sum = 1.0 / sum;
            for (filtered_probs) |*p| p.* *= inv_sum;
        }
        
        // Sample from distribution
        return self.sampleFromDist(filtered_probs);
    }
    
    /// Find index of maximum value
    fn argmax(self: *Generator, probs: []const f32) u32 {
        _ = self;
        var max_idx: usize = 0;
        var max_val: f32 = probs[0];
        
        for (probs[1..], 1..) |p, i| {
            if (p > max_val) {
                max_val = p;
                max_idx = i;
            }
        }
        
        return @intCast(max_idx);
    }
    
    /// Apply top-k filtering (keep only top k tokens)
    fn applyTopK(self: *Generator, probs: []f32) void {
        // Find k-th largest value
        var values: std.ArrayListUnmanaged(f32) = .{};
        defer values.deinit(self.allocator);
        
        for (probs) |p| {
            values.append(self.allocator, p) catch continue;
        }
        
        // Sort descending
        std.mem.sort(f32, values.items, {}, struct {
            fn cmp(_: void, a: f32, b: f32) bool {
                return a > b;
            }
        }.cmp);
        
        if (values.items.len > self.config.top_k) {
            const threshold = values.items[self.config.top_k];
            for (probs) |*p| {
                if (p.* < threshold) p.* = 0;
            }
        }
    }
    
    /// Apply top-p (nucleus) filtering
    fn applyTopP(self: *Generator, probs: []f32) void {
        // Get sorted indices by probability
        const IndexProb = struct { idx: usize, prob: f32 };
        var sorted: std.ArrayListUnmanaged(IndexProb) = .{};
        defer sorted.deinit(self.allocator);
        
        for (probs, 0..) |p, i| {
            sorted.append(self.allocator, .{ .idx = i, .prob = p }) catch continue;
        }
        
        std.mem.sort(IndexProb, sorted.items, {}, struct {
            fn cmp(_: void, a: IndexProb, b: IndexProb) bool {
                return a.prob > b.prob;
            }
        }.cmp);
        
        // Keep tokens until cumulative prob exceeds top_p
        var cumsum: f32 = 0;
        var cutoff_idx: usize = sorted.items.len;
        
        for (sorted.items, 0..) |item, i| {
            cumsum += item.prob;
            if (cumsum > self.config.top_p) {
                cutoff_idx = i + 1; // Include this token
                break;
            }
        }
        
        // Zero out tokens below cutoff
        for (sorted.items[cutoff_idx..]) |item| {
            probs[item.idx] = 0;
        }
    }
    
    /// Sample from probability distribution
    fn sampleFromDist(self: *Generator, probs: []const f32) u32 {
        var random = self.prng.random();
        const r = random.float(f32);
        
        var cumsum: f32 = 0;
        for (probs, 0..) |p, i| {
            cumsum += p;
            if (r <= cumsum) {
                return @intCast(i);
            }
        }
        
        // Fallback to last valid token
        return @intCast(probs.len - 1);
    }
    
    /// Check if sequence ends with any stop sequence
    fn checkStopSequence(self: *Generator, tokens: []const u32) bool {
        for (self.config.stop_sequences) |stop_seq| {
            if (tokens.len >= stop_seq.len) {
                const suffix = tokens[tokens.len - stop_seq.len ..];
                if (std.mem.eql(u32, suffix, stop_seq)) {
                    return true;
                }
            }
        }
        return false;
    }
    
    /// Get logprob info for a token
    fn getTokenLogprob(self: *Generator, token: u32, probs: []const f32, logits: []const f32) !TokenLogprob {
        _ = logits;
        
        const logprob = if (token < probs.len and probs[token] > 0)
            @log(probs[token])
        else
            -std.math.inf(f32);
        
        // Get top N tokens
        const n = @min(self.config.top_logprobs, probs.len);
        var top_tokens = try self.allocator.alloc(u32, n);
        var top_logprobs = try self.allocator.alloc(f32, n);
        
        // Simple: find top N (not most efficient but correct)
        var used = try self.allocator.alloc(bool, probs.len);
        defer self.allocator.free(used);
        @memset(used, false);
        
        for (0..n) |i| {
            var best_idx: usize = 0;
            var best_prob: f32 = -1;
            
            for (probs, 0..) |p, j| {
                if (!used[j] and p > best_prob) {
                    best_prob = p;
                    best_idx = j;
                }
            }
            
            top_tokens[i] = @intCast(best_idx);
            top_logprobs[i] = if (best_prob > 0) @log(best_prob) else -std.math.inf(f32);
            used[best_idx] = true;
        }
        
        return TokenLogprob{
            .token = token,
            .logprob = logprob,
            .top_tokens = top_tokens,
            .top_logprobs = top_logprobs,
        };
    }
    
    /// Get generation statistics
    pub fn getStats(self: *const Generator) GeneratorStats {
        return .{
            .tokens_generated = self.tokens_generated.load(.monotonic),
            .total_time_ns = @intCast(self.total_time_ns.load(.monotonic)),
        };
    }
};

pub const GeneratorStats = struct {
    tokens_generated: u64,
    total_time_ns: u64,
    
    pub fn tokensPerSecond(self: GeneratorStats) f64 {
        if (self.total_time_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.tokens_generated)) / 
               (@as(f64, @floatFromInt(self.total_time_ns)) / 1e9);
    }
};

// ============================================================================
// Chat/Completion API Helpers
// ============================================================================

/// Format chat messages into a prompt (Llama style)
pub fn formatChatPrompt(allocator: Allocator, messages: []const ChatMessage) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    const writer = result.writer(allocator);
    
    for (messages) |msg| {
        switch (msg.role) {
            .system => {
                try writer.print("<<SYS>>\n{s}\n<</SYS>>\n\n", .{msg.content});
            },
            .user => {
                try writer.print("[INST] {s} [/INST]\n", .{msg.content});
            },
            .assistant => {
                try writer.print("{s}\n", .{msg.content});
            },
        }
    }
    
    return try result.toOwnedSlice(allocator);
}

pub const ChatMessage = struct {
    role: ChatRole,
    content: []const u8,
};

pub const ChatRole = enum {
    system,
    user,
    assistant,
};

// ============================================================================
// Tests
// ============================================================================

test "Generator init/deinit" {
    const allocator = std.testing.allocator;
    const gen = try Generator.init(allocator, .{});
    defer gen.deinit();
    
    const stats = gen.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.tokens_generated);
}

test "GenerationConfig presets" {
    const greedy = GenerationConfig.greedy();
    try std.testing.expectEqual(@as(f32, 0.0), greedy.temperature);
    try std.testing.expectEqual(@as(usize, 1), greedy.top_k);
    
    const creative = GenerationConfig.creative();
    try std.testing.expectEqual(@as(f32, 0.9), creative.temperature);
}

test "Generator mock inference" {
    const allocator = std.testing.allocator;
    const gen = try Generator.init(allocator, .{
        .max_new_tokens = 10,
        .seed = 42,
    });
    defer gen.deinit();
    
    const prompt = [_]u32{ 1, 100, 200, 300 };
    var result = try gen.generate(&prompt);
    defer result.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 4), result.prompt_length);
    try std.testing.expect(result.generated_length > 0);
    try std.testing.expect(result.tokens.len > prompt.len);
}

test "Generator greedy sampling" {
    const allocator = std.testing.allocator;
    const gen = try Generator.init(allocator, GenerationConfig.greedy());
    defer gen.deinit();
    
    // Greedy should always pick the same token for same input
    const prompt = [_]u32{ 1, 50 };
    var result1 = try gen.generate(&prompt);
    defer result1.deinit(allocator);
    
    // For greedy, the result should be deterministic
    try std.testing.expect(result1.generated_length > 0);
}

test "formatChatPrompt" {
    const allocator = std.testing.allocator;
    
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "You are helpful." },
        .{ .role = .user, .content = "Hello!" },
    };
    
    const prompt = try formatChatPrompt(allocator, &messages);
    defer allocator.free(prompt);
    
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<<SYS>>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[INST]") != null);
}

test "FinishReason toString" {
    try std.testing.expectEqualStrings("length", FinishReason.max_length.toString());
    try std.testing.expectEqualStrings("stop", FinishReason.eos_token.toString());
}