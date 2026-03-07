//! DART++ Combined Engine
//!
//! Integrates FLy + Cacheback + SVIP for maximum speculative decoding performance.
//! Expected speedup: 2.5-2.8x vs autoregressive baseline on T4.
//!
//! Architecture:
//!   1. SVIP: Variable-K drafting (K ∈ [2, 6]) based on confidence
//!   2. Cacheback: LRU n-gram cache with online learning
//!   3. FLy: Entropy-gated loosened verification

const std = @import("std");
const Allocator = std.mem.Allocator;

const fly_verifier = @import("fly_verifier.zig");
const FLyVerifier = fly_verifier.FLyVerifier;
const FLyConfig = fly_verifier.FLyConfig;
const VerifyResult = fly_verifier.VerifyResult;

const cacheback_trie = @import("cacheback_trie.zig");
const CachebackTrie = cacheback_trie.CachebackTrie;
const CachebackConfig = cacheback_trie.CachebackConfig;

const svip_drafter = @import("svip_drafter.zig");
const SVIPDrafter = svip_drafter.SVIPDrafter;
const SVIPConfig = svip_drafter.SVIPConfig;
const DraftResult = svip_drafter.DraftResult;

/// DART++ combined configuration
pub const DARTPlusPlusConfig = struct {
    /// FLy verifier configuration
    fly: FLyConfig = FLyConfig.default(),
    
    /// Cacheback LRU trie configuration
    cacheback: CachebackConfig = CachebackConfig.default(),
    
    /// SVIP variable-K drafter configuration
    svip: SVIPConfig = SVIPConfig.default(),
    
    /// Model hidden size (for DART head)
    hidden_size: u32 = 4096,
    
    /// Vocabulary size
    vocab_size: u32 = 128256,
    
    /// Layer offset for hidden state extraction
    layer_offset: u32 = 4,
    
    /// EOS token ID
    eos_token_id: u32 = 128001,
    
    pub fn default() DARTPlusPlusConfig {
        return .{};
    }
    
    /// Aggressive speed preset
    pub fn aggressive() DARTPlusPlusConfig {
        return .{
            .fly = FLyConfig.aggressive(),
            .cacheback = CachebackConfig.default(),
            .svip = SVIPConfig.aggressive(),
        };
    }
    
    /// Conservative accuracy preset
    pub fn conservative() DARTPlusPlusConfig {
        return .{
            .fly = FLyConfig.conservative(),
            .cacheback = CachebackConfig.default(),
            .svip = SVIPConfig.conservative(),
        };
    }
    
    /// LLaMA-3.1-8B preset
    pub fn forLlama8B() DARTPlusPlusConfig {
        return .{
            .hidden_size = 4096,
            .vocab_size = 128256,
            .eos_token_id = 128001,
        };
    }
    
    /// Qwen2.5-7B preset
    pub fn forQwen7B() DARTPlusPlusConfig {
        return .{
            .hidden_size = 3584,
            .vocab_size = 152064,
            .eos_token_id = 151643,
        };
    }
};

/// DART++ combined statistics
pub const DARTPlusPlusStats = struct {
    // Generation stats
    total_steps: u64 = 0,
    total_tokens_generated: u64 = 0,
    total_tokens_proposed: u64 = 0,
    total_tokens_accepted: u64 = 0,
    total_time_ns: u64 = 0,
    
    // FLy stats
    fly_exact_matches: u64 = 0,
    fly_semantic_matches: u64 = 0,
    fly_rejections: u64 = 0,
    fly_self_corrections: u64 = 0,
    
    // Cacheback stats
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    cache_evictions: u64 = 0,
    
    // SVIP stats
    svip_avg_k: f64 = 0,
    svip_stops_max_k: u64 = 0,
    svip_stops_confidence: u64 = 0,
    svip_stops_entropy: u64 = 0,
    
    // Fallback stats
    fallback_steps: u64 = 0,
    
    pub fn getAcceptanceRate(self: DARTPlusPlusStats) f64 {
        if (self.total_tokens_proposed == 0) return 0;
        return @as(f64, @floatFromInt(self.total_tokens_accepted)) /
               @as(f64, @floatFromInt(self.total_tokens_proposed));
    }
    
    pub fn getAvgAcceptedPerStep(self: DARTPlusPlusStats) f64 {
        if (self.total_steps == 0) return 0;
        return @as(f64, @floatFromInt(self.total_tokens_accepted)) /
               @as(f64, @floatFromInt(self.total_steps));
    }
    
    pub fn getTokensPerSecond(self: DARTPlusPlusStats) f64 {
        if (self.total_time_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.total_tokens_generated)) * 1e9 /
               @as(f64, @floatFromInt(self.total_time_ns));
    }
    
    pub fn getSemanticMatchRate(self: DARTPlusPlusStats) f64 {
        const total = self.fly_exact_matches + self.fly_semantic_matches;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.fly_semantic_matches)) /
               @as(f64, @floatFromInt(total));
    }
};

/// DART++ Combined Engine
pub const DARTPlusPlusEngine = struct {
    allocator: Allocator,
    config: DARTPlusPlusConfig,
    
    // Components
    fly: FLyVerifier,
    cache: CachebackTrie,
    svip: SVIPDrafter,
    
    // Statistics
    stats: DARTPlusPlusStats,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, config: DARTPlusPlusConfig) !Self {
        return .{
            .allocator = allocator,
            .config = config,
            .fly = try FLyVerifier.init(allocator, config.fly),
            .cache = try CachebackTrie.init(allocator, config.cacheback),
            .svip = SVIPDrafter.init(allocator, config.svip),
            .stats = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.fly.deinit();
        self.cache.deinit();
    }
    
    /// Initialize cache from prompt tokens (cold start)
    pub fn initializeFromPrompt(self: *Self, prompt_tokens: []const u32) !void {
        try self.cache.initializeFromTokens(prompt_tokens);
    }
    
    /// Generate tokens with DART++ speculative decoding
    pub fn generate(
        self: *Self,
        prompt_tokens: []const u32,
        max_new_tokens: usize,
        // Model interface functions
        getDraftLogits: *const fn (hidden: []const f16, k: u32, ctx: ?*anyopaque) []const f32,
        getHiddenStates: *const fn (tokens: []const u32, ctx: ?*anyopaque) []const f16,
        getTargetLogits: *const fn (tokens: []const u32, ctx: ?*anyopaque) []const f32,
        ctx: ?*anyopaque,
    ) ![]u32 {
        var output: std.ArrayListUnmanaged(u32) = .empty;
        defer output.deinit(self.allocator);
        
        // Copy prompt
        try output.appendSlice(self.allocator, prompt_tokens);
        
        // Initialize cache from prompt
        try self.initializeFromPrompt(prompt_tokens);
        
        var tokens_generated: usize = 0;
        self.resetStats();
        
        const start_time = std.time.nanoTimestamp();
        
        while (tokens_generated < max_new_tokens) {
            const current_tokens = output.items;
            
            // Step 1: Get hidden states from target model
            const hidden_states = getHiddenStates(current_tokens, ctx);
            
            // Step 2: SVIP variable-K drafting with cache confidence
            var logits_ptrs: [6][]const f32 = undefined;
            var logits_count: usize = 0;
            
            // Get draft logits for up to max_k positions
            for (0..self.config.svip.max_k) |k| {
                logits_ptrs[k] = getDraftLogits(hidden_states, @intCast(k), ctx);
                logits_count += 1;
            }
            
            var draft_result = try self.svip.generateDraftFromLogits(
                logits_ptrs[0..logits_count],
                &self.cache,
                current_tokens,
            );
            defer draft_result.deinit();
            
            if (draft_result.tokens.len == 0) {
                // Fallback to single token
                const single_token = try self.singleTokenFallback(current_tokens, getTargetLogits, ctx);
                try output.append(self.allocator, single_token);
                tokens_generated += 1;
                self.stats.fallback_steps += 1;
                continue;
            }
            
            // Step 3: Get target model logits for verification
            var verify_input = try self.allocator.alloc(u32, current_tokens.len + draft_result.tokens.len);
            defer self.allocator.free(verify_input);
            
            @memcpy(verify_input[0..current_tokens.len], current_tokens);
            @memcpy(verify_input[current_tokens.len..], draft_result.tokens);
            
            const target_logits = getTargetLogits(verify_input, ctx);
            
            // Step 4: FLy loosened verification
            var verify_result = try self.fly.verify(
                draft_result.tokens,
                target_logits,
                self.config.vocab_size,
                current_tokens.len,
            );
            defer verify_result.deinit();
            
            // Step 5: Accept tokens
            if (verify_result.accepted_count > 0) {
                try output.appendSlice(self.allocator, verify_result.accepted_tokens);
                tokens_generated += verify_result.accepted_count;
                
                // Update cache with accepted tokens (online learning)
                try self.cache.updateFromAccepted(verify_result.accepted_tokens);
            }
            
            // Add bonus token if available
            if (verify_result.bonus_token) |bonus| {
                try output.append(self.allocator, bonus);
                tokens_generated += 1;
            }
            
            // Update stats
            self.stats.total_steps += 1;
            self.stats.total_tokens_proposed += draft_result.k_used;
            self.stats.total_tokens_accepted += @intCast(verify_result.accepted_count);
            self.stats.fly_exact_matches += verify_result.exact_matches;
            self.stats.fly_semantic_matches += verify_result.semantic_matches;
            
            // Check for EOS
            if (output.items.len > 0 and
                output.items[output.items.len - 1] == self.config.eos_token_id)
            {
                break;
            }
        }
        
        const elapsed_ns = std.time.nanoTimestamp() - start_time;
        self.stats.total_time_ns = @intCast(elapsed_ns);
        self.stats.total_tokens_generated = @intCast(tokens_generated);
        
        // Aggregate component stats
        self.aggregateStats();
        
        // Return only generated tokens
        const result = try self.allocator.alloc(u32, output.items.len - prompt_tokens.len);
        @memcpy(result, output.items[prompt_tokens.len..]);
        return result;
    }
    
    /// Single token fallback when drafting fails
    fn singleTokenFallback(
        self: *Self,
        prefix: []const u32,
        getTargetLogits: *const fn (tokens: []const u32, ctx: ?*anyopaque) []const f32,
        ctx: ?*anyopaque,
    ) !u32 {
        const logits = getTargetLogits(prefix, ctx);
        const vocab_size = self.config.vocab_size;
        const last_logits = logits[(prefix.len - 1) * vocab_size .. prefix.len * vocab_size];
        
        // Argmax
        var max_idx: u32 = 0;
        var max_val: f32 = last_logits[0];
        for (last_logits[1..], 1..) |l, i| {
            if (l > max_val) {
                max_val = l;
                max_idx = @intCast(i);
            }
        }
        
        return max_idx;
    }
    
    /// Aggregate stats from components
    fn aggregateStats(self: *Self) void {
        // Cache stats
        const cache_stats = self.cache.getStats();
        self.stats.cache_hits = cache_stats.hits;
        self.stats.cache_misses = cache_stats.misses;
        self.stats.cache_evictions = cache_stats.evictions;
        
        // SVIP stats
        const svip_stats = self.svip.getStats();
        self.stats.svip_avg_k = svip_stats.avgK();
        self.stats.svip_stops_max_k = svip_stats.stops_max_k;
        self.stats.svip_stops_confidence = svip_stats.stops_low_confidence;
        self.stats.svip_stops_entropy = svip_stats.stops_high_entropy;
        
        // FLy stats
        const fly_stats = self.fly.getStats();
        _ = fly_stats;
    }
    
    /// Reset all statistics
    pub fn resetStats(self: *Self) void {
        self.stats = .{};
        self.fly.resetStats();
        self.cache.resetStats();
        self.svip.resetStats();
    }
    
    /// Get combined statistics
    pub fn getStats(self: *const Self) DARTPlusPlusStats {
        return self.stats;
    }
    
    /// Print comprehensive statistics
    pub fn printStats(self: *const Self, writer: anytype) !void {
        const s = self.stats;
        
        try writer.print("\n", .{});
        try writer.print("╔════════════════════════════════════════════════════════════════╗\n", .{});
        try writer.print("║          DART++ (FLy + Cacheback + SVIP) STATISTICS            ║\n", .{});
        try writer.print("╠════════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  GENERATION OVERVIEW                                           ║\n", .{});
        try writer.print("║  Total steps:              {d:>8}                              ║\n", .{s.total_steps});
        try writer.print("║  Tokens generated:         {d:>8}                              ║\n", .{s.total_tokens_generated});
        try writer.print("║  Tokens proposed:          {d:>8}                              ║\n", .{s.total_tokens_proposed});
        try writer.print("║  Tokens accepted:          {d:>8}                              ║\n", .{s.total_tokens_accepted});
        try writer.print("║  Fallback steps:           {d:>8}                              ║\n", .{s.fallback_steps});
        try writer.print("╠════════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  PERFORMANCE METRICS                                           ║\n", .{});
        try writer.print("║  Acceptance rate:          {d:>7.1}%                             ║\n", .{s.getAcceptanceRate() * 100});
        try writer.print("║  Avg accepted/step:        {d:>8.2}                              ║\n", .{s.getAvgAcceptedPerStep()});
        try writer.print("║  Tokens/second:            {d:>8.1}                              ║\n", .{s.getTokensPerSecond()});
        try writer.print("║  Semantic match rate:      {d:>7.1}%                             ║\n", .{s.getSemanticMatchRate() * 100});
        try writer.print("╠════════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  FLy VERIFIER                                                  ║\n", .{});
        try writer.print("║  Exact matches:            {d:>8}                              ║\n", .{s.fly_exact_matches});
        try writer.print("║  Semantic matches:         {d:>8}                              ║\n", .{s.fly_semantic_matches});
        try writer.print("║  Self-corrections:         {d:>8}                              ║\n", .{s.fly_self_corrections});
        try writer.print("╠════════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  CACHEBACK LRU TRIE                                            ║\n", .{});
        try writer.print("║  Cache hits:               {d:>8}                              ║\n", .{s.cache_hits});
        try writer.print("║  Cache misses:             {d:>8}                              ║\n", .{s.cache_misses});
        try writer.print("║  Cache evictions:          {d:>8}                              ║\n", .{s.cache_evictions});
        try writer.print("╠════════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  SVIP DRAFTER                                                  ║\n", .{});
        try writer.print("║  Average K:                {d:>8.2}                              ║\n", .{s.svip_avg_k});
        try writer.print("║  Stops (max K):            {d:>8}                              ║\n", .{s.svip_stops_max_k});
        try writer.print("║  Stops (confidence):       {d:>8}                              ║\n", .{s.svip_stops_confidence});
        try writer.print("║  Stops (entropy):          {d:>8}                              ║\n", .{s.svip_stops_entropy});
        try writer.print("╚════════════════════════════════════════════════════════════════╝\n", .{});
        
        const total_time_ms = @as(f64, @floatFromInt(s.total_time_ns)) / 1e6;
        try writer.print("\nTotal time: {d:.1} ms\n", .{total_time_ms});
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DARTPlusPlusConfig presets" {
    const default_config = DARTPlusPlusConfig.default();
    try std.testing.expectEqual(@as(u32, 4096), default_config.hidden_size);
    
    const aggressive = DARTPlusPlusConfig.aggressive();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), aggressive.fly.high_entropy_threshold, 0.01);
    
    const conservative = DARTPlusPlusConfig.conservative();
    try std.testing.expectEqual(@as(u32, 4), conservative.svip.max_k);
}

test "DARTPlusPlusEngine initialization" {
    const allocator = std.testing.allocator;
    
    var engine = try DARTPlusPlusEngine.init(allocator, DARTPlusPlusConfig.default());
    defer engine.deinit();
    
    const stats = engine.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.total_steps);
}

test "DARTPlusPlusStats calculations" {
    var stats = DARTPlusPlusStats{
        .total_steps = 10,
        .total_tokens_generated = 35,
        .total_tokens_proposed = 40,
        .total_tokens_accepted = 32,
        .total_time_ns = 1_000_000_000, // 1 second
        .fly_exact_matches = 25,
        .fly_semantic_matches = 7,
    };
    
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), stats.getAcceptanceRate(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.2), stats.getAvgAcceptedPerStep(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 35.0), stats.getTokensPerSecond(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.21875), stats.getSemanticMatchRate(), 0.001);
}