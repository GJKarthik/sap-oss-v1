//! DART Speculative Decoding Engine for T4
//! 
//! Orchestrates the full speculative decoding loop:
//! 
//!   ┌─────────────────────────────────────────────────────┐
//!   │                   Each Decoding Step                 │
//!   │                                                      │
//!   │  GPU: Target model forward (prefix only)             │
//!   │       → hidden states layer N-4                      │
//!   │       → DART head: parallel logits for K positions   │
//!   │                                                      │
//!   │  CPU (async): N-gram trie lookup                     │
//!   │               continuity scores for candidates       │
//!   │                                                      │
//!   │  CPU: Tree pruning (combine logit + ngram scores)    │
//!   │       → draft token sequences                        │
//!   │                                                      │
//!   │  GPU: Target model verification                      │
//!   │       (all draft sequences, one forward pass)        │
//!   │       → accept longest matching prefix               │
//!   │       → generate correction token if needed          │
//!   │                                                      │
//!   │  Repeat with extended sequence                       │
//!   └─────────────────────────────────────────────────────┘
//! 
//! T4-specific optimizations:
//!   1. INT8 quantization for target model and DART head
//!   2. Draft length K=4, max_nodes=25 tuned for T4 bandwidth
//!   3. Context-mode trie by default (zero persistent RAM)
//!   4. CPU/GPU pipelining to overlap trie lookup with GPU work

const std = @import("std");
const Allocator = std.mem.Allocator;

const ngram_trie = @import("ngram_trie.zig");
const NGramTrie = ngram_trie.NGramTrie;
const TrieConfig = ngram_trie.TrieConfig;
const TokenProb = ngram_trie.TokenProb;

const draft_tree = @import("draft_tree.zig");
const DraftTreeBuilder = draft_tree.DraftTreeBuilder;
const TreeBuilderConfig = draft_tree.TreeBuilderConfig;
const TreeBuildResult = draft_tree.TreeBuildResult;
const VerificationBatch = draft_tree.VerificationBatch;

/// Configuration for Lean-DART on T4
pub const DARTConfig = struct {
    // Model dimensions (must match target model)
    hidden_size: u32 = 4096,
    vocab_size: u32 = 32000,
    num_layers: u32 = 32,
    target_layer_offset: u32 = 4, // Extract hidden states from layer (N - offset)

    // DART head parameters
    num_draft_positions: u8 = 4, // K=4 optimal for T4 (vs K=6-7 on H20)
    head_hidden_size: u32 = 512, // Compressed head dim
    head_num_heads: u32 = 8,
    head_ffn_multiplier: f32 = 2.0,
    head_candidates: u32 = 5, // Top-k from DART head per position

    // Tree pruning
    alpha: f32 = 0.6, // Logit weight vs ngram weight (lower = more trust in trie)
    max_tree_nodes: u32 = 32, // T4-tuned: slightly larger for 3-gram

    // Trie configuration
    trie_mode: ngram_trie.TrieMode = .context,
    trie_n: u8 = 3, // 3-gram with backoff to 2-gram (was 2-gram only)
    trie_min_count: u32 = 1,
    trie_max_children: u32 = 32,

    // Adaptive draft length
    enable_adaptive_k: bool = true,
    min_draft_positions: u8 = 2, // Floor: never draft fewer than 2
    max_draft_positions: u8 = 6, // Ceiling: up to 6 when acceptance is high
    adaptive_alpha_threshold: f32 = 0.75, // Increase K when α > this
    adaptive_alpha_low: f32 = 0.5, // Decrease K when α < this

    // Generation parameters
    max_new_tokens: u32 = 512,
    eos_token_id: u32 = 2,

    pub fn forLlama8B() DARTConfig {
        return .{
            .hidden_size = 4096,
            .vocab_size = 128256,
            .num_layers = 32,
        };
    }

    pub fn forQwen7B() DARTConfig {
        return .{
            .hidden_size = 3584,
            .vocab_size = 152064,
            .num_layers = 28,
        };
    }
};

/// Statistics for DART inference
pub const DARTStats = struct {
    /// Total decoding steps
    steps: u64 = 0,
    /// Total tokens generated
    total_tokens: u64 = 0,
    /// Tokens accepted from draft (before verification)
    accepted_tokens: u64 = 0,
    /// Tokens rejected (draft mismatch)
    rejected_tokens: u64 = 0,
    /// Current adaptive K value
    current_k: u8 = 4,
    /// Backoff hits (lower-order n-gram used)
    backoff_hits: u64 = 0,
    /// Total draft lengths per step (for average calculation)
    draft_length_sum: u64 = 0,
    /// Maximum draft length accepted in any step
    max_accepted_length: u32 = 0,
    /// Time spent in target model forward (ns)
    target_forward_ns: u64 = 0,
    /// Time spent in DART head forward (ns)
    dart_head_ns: u64 = 0,
    /// Time spent in trie lookup (ns)
    trie_lookup_ns: u64 = 0,
    /// Time spent in tree building (ns)
    tree_build_ns: u64 = 0,
    /// Time spent in verification (ns)
    verification_ns: u64 = 0,

    pub fn acceptanceRate(self: DARTStats) f32 {
        if (self.accepted_tokens + self.rejected_tokens == 0) return 0.0;
        return @as(f32, @floatFromInt(self.accepted_tokens)) /
            @as(f32, @floatFromInt(self.accepted_tokens + self.rejected_tokens));
    }

    pub fn avgAcceptedPerStep(self: DARTStats) f32 {
        if (self.steps == 0) return 0.0;
        return @as(f32, @floatFromInt(self.draft_length_sum)) / @as(f32, @floatFromInt(self.steps));
    }

    pub fn tokensPerSecond(self: DARTStats, total_time_ns: u64) f32 {
        if (total_time_ns == 0) return 0.0;
        return @as(f32, @floatFromInt(self.total_tokens)) * 1e9 / @as(f32, @floatFromInt(total_time_ns));
    }
};

/// Result of verification step
pub const VerifyResult = struct {
    /// Number of draft tokens accepted
    num_accepted: u32,
    /// Correction token from target model (if draft diverged)
    correction_token: ?u32,
    /// Whether generation is complete (EOS reached)
    is_complete: bool,
};

/// DART Speculative Decoding Engine
pub const DARTEngine = struct {
    allocator: Allocator,
    config: DARTConfig,

    // Components
    trie: NGramTrie,
    tree_builder: DraftTreeBuilder,

    // Buffers
    candidate_ids_buffer: [][]u32,
    candidate_probs_buffer: [][]f32,
    ngram_scores_buffer: [][]TokenProb,
    hidden_state_buffer: []f32,

    // Batch verification buffer: max_K * vocab_size logits for HGEMM batch path
    batch_logits_buffer: []f32,

    // Statistics
    stats: DARTStats,

    const Self = @This();

    /// Initialize DART engine
    pub fn init(allocator: Allocator, config: DARTConfig) !Self {
        // Initialize trie
        const trie_config = TrieConfig{
            .n = config.trie_n,
            .min_count = config.trie_min_count,
            .max_children = config.trie_max_children,
            .mode = config.trie_mode,
        };
        const trie = try NGramTrie.init(allocator, trie_config);

        // Initialize tree builder
        const tree_config = TreeBuilderConfig{
            .alpha = config.alpha,
            .max_nodes = config.max_tree_nodes,
            .max_candidates_per_pos = config.head_candidates,
        };
        const tree_builder = try DraftTreeBuilder.init(allocator, tree_config);

        // Allocate buffers for K positions, each with head_candidates candidates
        const K = config.num_draft_positions;
        const C = config.head_candidates;

        var candidate_ids = try allocator.alloc([]u32, K);
        var candidate_probs = try allocator.alloc([]f32, K);
        var ngram_scores = try allocator.alloc([]TokenProb, K);

        for (0..K) |i| {
            candidate_ids[i] = try allocator.alloc(u32, C);
            candidate_probs[i] = try allocator.alloc(f32, C);
            ngram_scores[i] = try allocator.alloc(TokenProb, C);
        }

        // Hidden state buffer for one token
        const hidden_buffer = try allocator.alloc(f32, config.hidden_size);

        // Batch logits buffer for HGEMM batch verification path
        // max_draft_positions * vocab_size floats (e.g. 6 * 32000 = 192K floats = 768KB)
        const max_k = if (config.enable_adaptive_k) config.max_draft_positions else config.num_draft_positions;
        const batch_logits = try allocator.alloc(f32, @as(usize, max_k) * config.vocab_size);

        return .{
            .allocator = allocator,
            .config = config,
            .trie = trie,
            .tree_builder = tree_builder,
            .candidate_ids_buffer = candidate_ids,
            .candidate_probs_buffer = candidate_probs,
            .ngram_scores_buffer = ngram_scores,
            .hidden_state_buffer = hidden_buffer,
            .batch_logits_buffer = batch_logits,
            .stats = .{},
        };
    }

    /// Free all resources
    pub fn deinit(self: *Self) void {
        const K = self.config.num_draft_positions;
        for (0..K) |i| {
            self.allocator.free(self.candidate_ids_buffer[i]);
            self.allocator.free(self.candidate_probs_buffer[i]);
            self.allocator.free(self.ngram_scores_buffer[i]);
        }
        self.allocator.free(self.candidate_ids_buffer);
        self.allocator.free(self.candidate_probs_buffer);
        self.allocator.free(self.ngram_scores_buffer);
        self.allocator.free(self.hidden_state_buffer);
        self.allocator.free(self.batch_logits_buffer);

        self.tree_builder.deinit();
        self.trie.deinit();
    }

    /// Reset statistics
    pub fn resetStats(self: *Self) void {
        self.stats = .{};
    }

    // =========================================================================
    // Main Generation Loop
    // =========================================================================

    /// Generate tokens using DART speculative decoding
    /// 
    /// Parameters:
    ///   model: Target LLM model
    ///   prompt_tokens: Tokenized prompt
    ///   max_new_tokens: Maximum tokens to generate
    /// 
    /// Returns: Generated token sequence
    pub fn generate(
        self: *Self,
        model: anytype,
        kv_cache: anytype,
        prompt_tokens: []const u32,
        max_new_tokens: u32,
    ) ![]u32 {
        const start_time = std.time.nanoTimestamp();
        if (prompt_tokens.len == 0) return error.EmptyPrompt;

        // Initialize output buffer
        var output = std.ArrayList(u32){};
        defer output.deinit();
        try output.appendSlice(prompt_tokens);

        // Update context trie from prompt tokens
        if (self.config.trie_mode == .context or self.config.trie_mode == .hybrid) {
            try self.trie.updateFromContext(prompt_tokens);
        }

        self.resetStats();
        self.stats.current_k = self.config.num_draft_positions;

        // Main generation loop
        while (output.items.len - prompt_tokens.len < max_new_tokens) {
            // Get current sequence
            const current_seq = output.items;

            // Step 1: Get hidden states from target model layer N-4
            const hidden_start = std.time.nanoTimestamp();
            const target_logits = try self.getHiddenStates(model, kv_cache, current_seq);
            self.stats.target_forward_ns += @intCast(std.time.nanoTimestamp() - hidden_start);

            // Step 2: DART head forward pass (GPU) -> top-k candidates per position
            const dart_start = std.time.nanoTimestamp();
            try self.dartHeadForward(model, kv_cache, current_seq, target_logits);
            self.stats.dart_head_ns += @intCast(std.time.nanoTimestamp() - dart_start);

            // Step 3: N-gram trie lookup (CPU, can overlap with step 2 in async impl)
            const trie_start = std.time.nanoTimestamp();
            self.lookupNgramScores(current_seq);
            self.stats.trie_lookup_ns += @intCast(std.time.nanoTimestamp() - trie_start);

            // Step 4: Build draft tree
            const tree_start = std.time.nanoTimestamp();
            var tree_result = try self.tree_builder.buildTree(
                self.candidate_ids_buffer,
                self.candidate_probs_buffer,
                self.ngram_scores_buffer,
                current_seq,
            );
            defer tree_result.deinit();
            self.stats.tree_build_ns += @intCast(std.time.nanoTimestamp() - tree_start);

            // Step 5: Get best draft sequence
            const best_draft = DraftTreeBuilder.getBestSequence(&tree_result);

            if (best_draft == null or best_draft.?.len == 0) {
                // Fallback: greedy decode one token
                const next_token = try self.greedyDecodeOne(model, kv_cache, current_seq);
                try output.append(next_token);
                self.stats.total_tokens += 1;

                if (next_token == self.config.eos_token_id) break;
                continue;
            }

            // Step 6: Verify draft with target model
            const verify_start = std.time.nanoTimestamp();
            const verify_result = try self.verifyDraft(model, kv_cache, current_seq, best_draft.?);
            self.stats.verification_ns += @intCast(std.time.nanoTimestamp() - verify_start);

            // Step 7: Accept tokens and update state
            const generated_so_far: usize = output.items.len - prompt_tokens.len;
            const remaining: usize = @as(usize, max_new_tokens) - generated_so_far;
            const accepted_cap: usize = @min(@as(usize, verify_result.num_accepted), remaining);
            const accepted = best_draft.?[0..accepted_cap];
            try output.appendSlice(accepted);

            var emitted_this_step: u32 = @intCast(accepted_cap);
            var emitted_correction = false;
            if (verify_result.correction_token) |correction| {
                if (accepted_cap < remaining) {
                    try output.append(correction);
                    emitted_this_step += 1;
                    emitted_correction = true;
                }
            }

            // Update statistics
            self.stats.steps += 1;
            self.stats.accepted_tokens += @intCast(accepted_cap);
            self.stats.rejected_tokens += @as(u32, @intCast(best_draft.?.len)) - verify_result.num_accepted;
            self.stats.total_tokens += emitted_this_step;
            self.stats.draft_length_sum += @intCast(accepted_cap);
            self.stats.max_accepted_length = @max(self.stats.max_accepted_length, @as(u32, @intCast(accepted_cap)));

            // Adaptive K: adjust draft length based on rolling acceptance rate
            if (self.config.enable_adaptive_k and self.stats.steps > 2) {
                const alpha_now = self.stats.acceptanceRate();
                if (alpha_now > self.config.adaptive_alpha_threshold and
                    self.stats.current_k < self.config.max_draft_positions)
                {
                    self.stats.current_k += 1;
                } else if (alpha_now < self.config.adaptive_alpha_low and
                    self.stats.current_k > self.config.min_draft_positions)
                {
                    self.stats.current_k -= 1;
                }
            }

            // Update context trie with new tokens
            if (self.config.trie_mode == .context) {
                const new_start = if (current_seq.len >= self.config.trie_n)
                    current_seq.len - self.config.trie_n
                else
                    0;
                try self.trie.buildFromTokens(output.items[new_start..]);
            }

            // Check for EOS
            if (verify_result.is_complete) break;
            if (emitted_correction and output.items[output.items.len - 1] == self.config.eos_token_id) break;
        }

        const total_time = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

        // Log final stats
        std.debug.print("\n[DART Engine] Generation complete\n", .{});
        std.debug.print("  Total tokens: {d}\n", .{self.stats.total_tokens});
        std.debug.print("  Steps: {d}\n", .{self.stats.steps});
        std.debug.print("  Acceptance rate: {d:.1}%\n", .{self.stats.acceptanceRate() * 100.0});
        std.debug.print("  Avg accepted/step: {d:.2}\n", .{self.stats.avgAcceptedPerStep()});
        std.debug.print("  Tokens/sec: {d:.1}\n", .{self.stats.tokensPerSecond(total_time)});

        return output.toOwnedSlice();
    }

    // =========================================================================
    // Internal Methods
    // =========================================================================

    fn argmaxToken(logits: []const f32) u32 {
        if (logits.len == 0) return 0;
        var max_idx: usize = 0;
        var max_val = logits[0];
        for (logits[1..], 1..) |v, i| {
            if (v > max_val) {
                max_val = v;
                max_idx = i;
            }
        }
        return @intCast(max_idx);
    }

    /// Synchronize KV cache with `tokens` and return logits for next token.
    fn syncPrefixCache(self: *Self, model: anytype, kv_cache: anytype, tokens: []const u32) []const f32 {
        _ = self;
        if (tokens.len == 0) return &[_]f32{};

        var cached_len: usize = @intCast(kv_cache.getSeqLen());
        if (cached_len > tokens.len) {
            kv_cache.clear();
            cached_len = 0;
        }

        if (cached_len == 0) {
            if (tokens.len > 1) {
                for (tokens[0 .. tokens.len - 1], 0..) |tok, pos| {
                    model.forwardNoLogits(tok, pos, kv_cache);
                }
            }
        } else if (cached_len < tokens.len and tokens.len - cached_len > 1) {
            for (tokens[cached_len .. tokens.len - 1], cached_len..) |tok, pos| {
                model.forwardNoLogits(tok, pos, kv_cache);
            }
        }

        // Recompute logits for the last token to guarantee fresh next-token logits.
        return model.forward(tokens[tokens.len - 1], tokens.len - 1, kv_cache);
    }

    /// Extract hidden states from target model layer N-4 and return next-token logits.
    fn getHiddenStates(self: *Self, model: anytype, kv_cache: anytype, tokens: []const u32) ![]const f32 {
        if (tokens.len == 0) return error.EmptySequence;
        const logits = self.syncPrefixCache(model, kv_cache, tokens);

        const copy_len = @min(self.hidden_state_buffer.len, model.hidden_buf.len);
        @memcpy(self.hidden_state_buffer[0..copy_len], model.hidden_buf[0..copy_len]);
        if (copy_len < self.hidden_state_buffer.len) {
            @memset(self.hidden_state_buffer[copy_len..], 0.0);
        }
        return logits;
    }

    fn fillTopK(self: *Self, logits: []const f32, out_ids: []u32, out_log_probs: []f32) void {
        _ = self;
        @memset(out_ids, 0);
        @memset(out_log_probs, -std.math.inf(f32));

        for (logits, 0..) |logit, idx| {
            var min_slot: usize = 0;
            var min_val = out_log_probs[0];
            for (1..out_log_probs.len) |j| {
                if (out_log_probs[j] < min_val) {
                    min_val = out_log_probs[j];
                    min_slot = j;
                }
            }
            if (logit > min_val) {
                out_log_probs[min_slot] = logit;
                out_ids[min_slot] = @intCast(idx);
            }
        }

        // Sort descending for stable ranking.
        var i: usize = 0;
        while (i < out_log_probs.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < out_log_probs.len) : (j += 1) {
                if (out_log_probs[j] > out_log_probs[i]) {
                    std.mem.swap(f32, &out_log_probs[i], &out_log_probs[j]);
                    std.mem.swap(u32, &out_ids[i], &out_ids[j]);
                }
            }
        }
    }

    /// Run model-driven DART candidate generation for all draft positions.
    /// Uses KV cache save/restore to avoid re-prefilling the entire prompt.
    fn dartHeadForward(
        self: *Self,
        model: anytype,
        kv_cache: anytype,
        current_seq: []const u32,
        target_logits: []const f32,
    ) !void {
        // Use adaptive K if enabled, otherwise use config default
        const K: usize = if (self.config.enable_adaptive_k)
            @min(self.stats.current_k, self.config.num_draft_positions)
        else
            self.config.num_draft_positions;
        if (K == 0) return;
        if (target_logits.len == 0) return;

        // Position 0 candidates: top-k from current next-token logits.
        self.fillTopK(target_logits, self.candidate_ids_buffer[0], self.candidate_probs_buffer[0]);

        if (K == 1) return;

        // Snapshot KV cache, then speculatively extend with top-1 chain.
        // After rollout, restore the cache so main generation isn't affected.
        const snapshot = kv_cache.saveState();

        var next_token = self.candidate_ids_buffer[0][0];
        var k: usize = 1;
        while (k < K) : (k += 1) {
            const logits = model.forward(next_token, current_seq.len + k - 1, kv_cache);
            self.fillTopK(logits, self.candidate_ids_buffer[k], self.candidate_probs_buffer[k]);
            next_token = self.candidate_ids_buffer[k][0];
        }

        // Rollback: discard draft KV entries so they don't pollute the main cache.
        kv_cache.restoreState(snapshot);
    }

    /// Lookup n-gram scores for all candidates
    fn lookupNgramScores(self: *Self, current_seq: []const u32) void {
        const K = self.config.num_draft_positions;
        const C = self.config.head_candidates;

        // Get prefix for each draft position
        const prefix_start = if (current_seq.len >= self.config.trie_n - 1)
            current_seq.len - (self.config.trie_n - 1)
        else
            0;
        const prefix = current_seq[prefix_start..];

        // Lookup continuations for each position
        for (0..K) |k| {
            const results = self.trie.getContinuations(
                prefix,
                self.candidate_ids_buffer[k],
                self.ngram_scores_buffer[k],
            );
            // Results are written to ngram_scores_buffer[k]
            // Fill remaining with zeros
            for (results.len..C) |c| {
                self.ngram_scores_buffer[k][c] = .{ .token_id = 0, .log_prob = 0.0 };
            }
        }
    }

    /// Verify draft sequence with target model.
    /// Dispatches at comptime: if model supports forwardDartBatch (FP16 HGEMM),
    /// uses batch path (1 forward for all K tokens). Otherwise falls back to
    /// sequential save/restore/replay.
    fn verifyDraft(
        self: *Self,
        model: anytype,
        kv_cache: anytype,
        prefix: []const u32,
        draft: []const u32,
    ) !VerifyResult {
        const ModelType = @TypeOf(model);
        const ModelChild = if (@typeInfo(ModelType) == .pointer)
            @typeInfo(ModelType).pointer.child
        else
            ModelType;

        if (comptime @hasDecl(ModelChild, "forwardDartBatch")) {
            return self.verifyDraftBatchHgemm(model, kv_cache, prefix, draft);
        } else {
            return self.verifyDraftSequential(model, kv_cache, prefix, draft);
        }
    }

    /// Batch verification using FP16 HGEMM — processes all K draft tokens in
    /// one batched forward pass (~69ms on T4 for LLaMA-7B regardless of K).
    ///
    /// Flow:
    ///   1. Check draft[0] against base logits (already cached from prefix)
    ///   2. Batch forward all K draft tokens → K sets of logits
    ///   3. CPU acceptance check: batch_logits[i] predicts draft[i+1]
    ///   4. Truncate KV cache to accepted count (no save/restore/replay)
    ///
    /// Performance: replaces K sequential forwards + save/restore/replay
    /// with 1 batch forward + 1 seq_len write.
    fn verifyDraftBatchHgemm(
        self: *Self,
        model: anytype,
        kv_cache: anytype,
        prefix: []const u32,
        draft: []const u32,
    ) !VerifyResult {
        if (prefix.len == 0) return error.EmptyPrefix;
        if (draft.len == 0) return .{ .num_accepted = 0, .correction_token = null, .is_complete = false };

        const K = draft.len;
        const vocab: usize = self.config.vocab_size;

        // Get base logits (from prefix, already cached).
        const base_logits = self.syncPrefixCache(model, kv_cache, prefix);
        var predicted = argmaxToken(base_logits);

        // Check first draft token against base logits.
        if (predicted != draft[0]) {
            return .{ .num_accepted = 0, .correction_token = predicted, .is_complete = false };
        }

        // First draft token accepted. If it's EOS, we're done.
        if (draft[0] == self.config.eos_token_id) {
            return .{ .num_accepted = 1, .correction_token = null, .is_complete = true };
        }

        // Build positions array for batch forward.
        var positions_buf: [16]usize = undefined;
        for (0..K) |i| {
            positions_buf[i] = prefix.len + i;
        }

        // Batch forward all K draft tokens in one HGEMM call.
        // This stores KV entries for all K positions and returns K * vocab logits.
        const batch_logits = self.batch_logits_buffer[0 .. K * vocab];
        try model.forwardDartBatch(draft, positions_buf[0..K], batch_logits);

        // Sequential acceptance check using pre-computed batch logits.
        // batch_logits[(i)*vocab .. (i+1)*vocab] = logits from forwarding draft[i],
        // which predict the token at position prefix.len + i + 1 → check against draft[i+1].
        var num_accepted: u32 = 1; // draft[0] already accepted above
        var correction_token: ?u32 = null;
        var is_complete = false;

        for (1..K) |i| {
            const logits_slice = batch_logits[(i - 1) * vocab .. i * vocab];
            predicted = argmaxToken(logits_slice);

            if (predicted == draft[i]) {
                num_accepted += 1;
                if (draft[i] == self.config.eos_token_id) {
                    is_complete = true;
                    break;
                }
            } else {
                correction_token = predicted;
                break;
            }
        }

        // If all K accepted, correction comes from the last batch logits.
        if (num_accepted == K and !is_complete) {
            const last_logits = batch_logits[(K - 1) * vocab .. K * vocab];
            correction_token = argmaxToken(last_logits);
        }

        // Truncate KV cache: batch forward stored KV for all K positions,
        // but we only want prefix + accepted. Positions beyond accepted
        // are stale but won't be accessed (attention uses seq_len bound).
        kv_cache.restoreState(.{ .saved_seq_len = prefix.len + num_accepted });

        return .{
            .num_accepted = num_accepted,
            .correction_token = correction_token,
            .is_complete = is_complete,
        };
    }

    /// Sequential verification (original path). Uses KV cache save/restore:
    /// snapshots before verification, then restores and replays only accepted
    /// tokens so the main cache stays consistent.
    fn verifyDraftSequential(
        self: *Self,
        model: anytype,
        kv_cache: anytype,
        prefix: []const u32,
        draft: []const u32,
    ) !VerifyResult {
        if (prefix.len == 0) return error.EmptyPrefix;
        var num_accepted: u32 = 0;
        var correction_token: ?u32 = null;
        var is_complete = false;

        // Snapshot the KV cache before verification.
        const snapshot = kv_cache.saveState();

        // Get logits for next token after prefix (already cached).
        var logits = self.syncPrefixCache(model, kv_cache, prefix);
        var predicted = argmaxToken(logits);

        for (draft) |draft_token| {
            if (predicted == draft_token) {
                num_accepted += 1;
                if (draft_token == self.config.eos_token_id) {
                    is_complete = true;
                    break;
                }
                logits = model.forward(draft_token, prefix.len + num_accepted - 1, kv_cache);
                predicted = argmaxToken(logits);
            } else {
                correction_token = predicted;
                break;
            }
        }

        if (num_accepted == draft.len and !is_complete) {
            correction_token = predicted;
        }

        // Restore KV cache to pre-verification state, then replay only accepted tokens.
        kv_cache.restoreState(snapshot);

        if (num_accepted > 0) {
            for (draft[0..num_accepted], 0..) |tok, i| {
                _ = model.forward(tok, prefix.len + i, kv_cache);
            }
        }

        return .{
            .num_accepted = num_accepted,
            .correction_token = correction_token,
            .is_complete = is_complete,
        };
    }

    /// Fallback: greedy decode one token
    fn greedyDecodeOne(self: *Self, model: anytype, kv_cache: anytype, tokens: []const u32) !u32 {
        if (tokens.len == 0) return error.EmptySequence;
        const logits = self.syncPrefixCache(model, kv_cache, tokens);
        return argmaxToken(logits);
    }

    // =========================================================================
    // Utility Methods
    // =========================================================================

    /// Get current statistics
    pub fn getStats(self: *const Self) DARTStats {
        return self.stats;
    }

    /// Print statistics to writer
    pub fn printStats(self: *const Self, writer: anytype) !void {
        const stats = self.stats;
        try writer.print("\n[DART Engine Stats]\n", .{});
        try writer.print("  Steps: {d}\n", .{stats.steps});
        try writer.print("  Total tokens: {d}\n", .{stats.total_tokens});
        try writer.print("  Accepted: {d}, Rejected: {d}\n", .{ stats.accepted_tokens, stats.rejected_tokens });
        try writer.print("  Acceptance rate: {d:.1}%\n", .{stats.acceptanceRate() * 100.0});
        try writer.print("  Avg accepted/step: {d:.2}\n", .{stats.avgAcceptedPerStep()});
        try writer.print("  Max accepted: {d}\n", .{stats.max_accepted_length});
        try writer.print("\nTiming breakdown:\n", .{});
        try writer.print("  Target forward: {d:.2} ms\n", .{@as(f32, @floatFromInt(stats.target_forward_ns)) / 1e6});
        try writer.print("  DART head: {d:.2} ms\n", .{@as(f32, @floatFromInt(stats.dart_head_ns)) / 1e6});
        try writer.print("  Trie lookup: {d:.2} ms\n", .{@as(f32, @floatFromInt(stats.trie_lookup_ns)) / 1e6});
        try writer.print("  Tree build: {d:.2} ms\n", .{@as(f32, @floatFromInt(stats.tree_build_ns)) / 1e6});
        try writer.print("  Verification: {d:.2} ms\n", .{@as(f32, @floatFromInt(stats.verification_ns)) / 1e6});

        // Trie stats
        try writer.print("\n", .{});
        try self.trie.printStats(writer);
    }

    /// Estimate speedup vs baseline autoregressive decoding
    pub fn estimateSpeedup(self: *const Self, baseline_tps: f32, total_time_ns: u64) f32 {
        const dart_tps = self.stats.tokensPerSecond(total_time_ns);
        if (baseline_tps == 0) return 0.0;
        return dart_tps / baseline_tps;
    }

    // =========================================================================
    // Multi-User DART — B users sharing one GPU via weight-sharing HGEMM
    // =========================================================================

    /// Per-user state for multi-user DART scheduling
    pub const UserSession = struct {
        draft_tokens: []const u32,
        prefix_len: usize,
        base_logits: []const f32, // cached base logits from prefix
    };

    /// Multi-user batch verification: collect B users' draft tokens and verify
    /// them all in one forwardMultiUserDartBatch call.
    ///
    /// Each user provides their draft sequence and prefix length.
    /// Returns B VerifyResults, one per user.
    ///
    /// model must expose forwardMultiUserDartBatch(max_users, B, K, tokens, positions, user_ids, kv_caches, out_logits)
    pub fn verifyDraftMultiUser(
        self: *Self,
        model: anytype,
        kv_caches: anytype, // slice of *GpuKVCache
        sessions: []const UserSession,
    ) ![]VerifyResult {
        const B = sessions.len;
        if (B == 0) return &[_]VerifyResult{};

        // Find max draft length across users
        var max_k: usize = 0;
        for (sessions) |s| {
            if (s.draft_tokens.len > max_k) max_k = s.draft_tokens.len;
        }
        if (max_k == 0) {
            var results: [8]VerifyResult = undefined;
            for (0..B) |u| {
                results[u] = .{ .num_accepted = 0, .correction_token = null, .is_complete = false };
            }
            return self.allocator.dupe(VerifyResult, results[0..B]);
        }

        const K = max_k;
        const vocab: usize = self.config.vocab_size;

        // First check draft[0] against base logits for each user
        var first_accepted: [8]bool = .{ false, false, false, false, false, false, false, false };
        var first_correction: [8]?u32 = .{ null, null, null, null, null, null, null, null };

        for (sessions, 0..) |s, u| {
            if (s.draft_tokens.len == 0) continue;
            const predicted = argmaxToken(s.base_logits);
            if (predicted == s.draft_tokens[0]) {
                first_accepted[u] = true;
            } else {
                first_correction[u] = predicted;
            }
        }

        // Build flattened token/position/user_id arrays for batch forward
        // Only include users whose first token was accepted
        const max_total = B * K;
        var tokens_buf: [128]u32 = undefined;
        var positions_buf: [128]usize = undefined;
        var user_ids_buf: [128]u32 = undefined;
        var actual_t: usize = 0;

        for (sessions, 0..) |s, u| {
            if (!first_accepted[u]) continue;
            const draft_k = s.draft_tokens.len;
            for (0..draft_k) |k| {
                if (actual_t >= max_total) break;
                tokens_buf[actual_t] = s.draft_tokens[k];
                positions_buf[actual_t] = s.prefix_len + k;
                user_ids_buf[actual_t] = @intCast(u);
                actual_t += 1;
            }
        }

        if (actual_t > 0) {
            // Ensure batch_logits_buffer is large enough
            const needed = actual_t * vocab;
            if (self.batch_logits_buffer.len < needed) {
                self.allocator.free(self.batch_logits_buffer);
                self.batch_logits_buffer = try self.allocator.alloc(f32, needed);
            }

            // Call the multi-user batch forward
            const batch_logits = self.batch_logits_buffer[0..needed];
            try model.forwardMultiUserDartBatch(
                @intCast(B), @intCast(K),
                tokens_buf[0..actual_t],
                positions_buf[0..actual_t],
                user_ids_buf[0..actual_t],
                kv_caches,
                batch_logits,
            );
        }

        // Parse results per user from batch logits
        var results_buf: [8]VerifyResult = undefined;
        var logit_offset: usize = 0;

        for (sessions, 0..) |s, u| {
            if (!first_accepted[u] or s.draft_tokens.len == 0) {
                results_buf[u] = .{
                    .num_accepted = 0,
                    .correction_token = first_correction[u],
                    .is_complete = false,
                };
                continue;
            }

            const draft_k = s.draft_tokens.len;
            var num_accepted: u32 = 1; // draft[0] accepted above
            var correction_token: ?u32 = null;
            var is_complete = false;

            if (s.draft_tokens[0] == self.config.eos_token_id) {
                results_buf[u] = .{ .num_accepted = 1, .correction_token = null, .is_complete = true };
                logit_offset += draft_k * vocab;
                continue;
            }

            // Check subsequent tokens via batch logits
            for (1..draft_k) |i| {
                const logits_slice = self.batch_logits_buffer[logit_offset + (i - 1) * vocab .. logit_offset + i * vocab];
                const predicted = argmaxToken(logits_slice);
                if (predicted == s.draft_tokens[i]) {
                    num_accepted += 1;
                    if (s.draft_tokens[i] == self.config.eos_token_id) {
                        is_complete = true;
                        break;
                    }
                } else {
                    correction_token = predicted;
                    break;
                }
            }

            if (num_accepted == draft_k and !is_complete) {
                const last_logits = self.batch_logits_buffer[logit_offset + (draft_k - 1) * vocab .. logit_offset + draft_k * vocab];
                correction_token = argmaxToken(last_logits);
            }

            // Truncate this user's KV cache
            kv_caches[u].restoreState(.{ .saved_seq_len = s.prefix_len + num_accepted });

            results_buf[u] = .{
                .num_accepted = num_accepted,
                .correction_token = correction_token,
                .is_complete = is_complete,
            };
            logit_offset += draft_k * vocab;
        }

        return self.allocator.dupe(VerifyResult, results_buf[0..B]);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DARTEngine initialization" {
    const allocator = std.testing.allocator;

    var engine = try DARTEngine.init(allocator, .{
        .num_draft_positions = 4,
        .head_candidates = 5,
    });
    defer engine.deinit();

    // Check buffers allocated correctly
    try std.testing.expectEqual(@as(usize, 4), engine.candidate_ids_buffer.len);
    try std.testing.expectEqual(@as(usize, 5), engine.candidate_ids_buffer[0].len);
}

test "DARTConfig presets" {
    const llama_config = DARTConfig.forLlama8B();
    try std.testing.expectEqual(@as(u32, 4096), llama_config.hidden_size);
    try std.testing.expectEqual(@as(u32, 128256), llama_config.vocab_size);

    const qwen_config = DARTConfig.forQwen7B();
    try std.testing.expectEqual(@as(u32, 3584), qwen_config.hidden_size);
    try std.testing.expectEqual(@as(u32, 152064), qwen_config.vocab_size);
}

test "DARTStats calculations" {
    var stats = DARTStats{
        .steps = 10,
        .total_tokens = 50,
        .accepted_tokens = 40,
        .rejected_tokens = 10,
        .draft_length_sum = 35,
        .max_accepted_length = 4,
    };

    try std.testing.expectApproxEqAbs(@as(f32, 0.8), stats.acceptanceRate(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), stats.avgAcceptedPerStep(), 0.01);

    // TPS with 1 second (1e9 ns)
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), stats.tokensPerSecond(1_000_000_000), 0.01);
}

test "VerifyResult structure" {
    const result = VerifyResult{
        .num_accepted = 3,
        .correction_token = 100,
        .is_complete = false,
    };

    try std.testing.expectEqual(@as(u32, 3), result.num_accepted);
    try std.testing.expectEqual(@as(?u32, 100), result.correction_token);
    try std.testing.expect(!result.is_complete);
}
