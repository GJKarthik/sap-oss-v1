"""
Speculative Decoding - Accelerate inference using draft models.

Implements:
- Draft model generates N tokens speculatively
- Target model verifies in parallel
- Rejection sampling for quality guarantee
- Medusa-style multi-head speculation
"""

from memory import memset_zero, memcpy
from sys.info import simdwidthof
from algorithm import vectorize, parallelize
from math import sqrt, exp, log, max as math_max
from random import random_float64


alias FloatType = DType.float32
alias SIMD_WIDTH = simdwidthof[FloatType]()


# =============================================================================
# Speculative Decoding Configuration
# =============================================================================

struct SpeculativeConfig:
    """Configuration for speculative decoding."""
    var num_speculative_tokens: Int  # Number of tokens to speculate
    var temperature: Float32
    var top_p: Float32
    var draft_temperature: Float32  # Usually lower for deterministic drafts
    var max_verify_batch: Int  # Max tokens to verify in one pass
    
    fn __init__(inout self, num_speculative: Int = 4):
        self.num_speculative_tokens = num_speculative
        self.temperature = 0.7
        self.top_p = 0.9
        self.draft_temperature = 0.3
        self.max_verify_batch = 16


# =============================================================================
# Token Sampling Utilities
# =============================================================================

fn sample_token(
    logits: UnsafePointer[Float32],
    vocab_size: Int,
    temperature: Float32,
    top_p: Float32,
) -> Int:
    """Sample a token from logits using temperature and top-p sampling."""
    # Guard against invalid vocab size
    if vocab_size <= 0:
        return 0
    
    if temperature <= 0.0:
        # Greedy sampling
        var max_idx = 0
        var max_val = logits[0]
        for i in range(1, vocab_size):
            if logits[i] > max_val:
                max_val = logits[i]
                max_idx = i
        return max_idx
    
    # Apply temperature
    var scaled_logits = UnsafePointer[Float32].alloc(vocab_size)
    for i in range(vocab_size):
        scaled_logits[i] = logits[i] / temperature
    
    # Compute softmax
    var max_logit = scaled_logits[0]
    for i in range(1, vocab_size):
        max_logit = math_max(max_logit, scaled_logits[i])
    
    var sum_exp = Float32(0.0)
    for i in range(vocab_size):
        scaled_logits[i] = exp(scaled_logits[i] - max_logit)
        sum_exp += scaled_logits[i]
    
    for i in range(vocab_size):
        scaled_logits[i] /= sum_exp
    
    # Top-p filtering (nucleus sampling)
    # Sort and accumulate probability
    var sorted_indices = UnsafePointer[Int].alloc(vocab_size)
    var sorted_probs = UnsafePointer[Float32].alloc(vocab_size)
    
    for i in range(vocab_size):
        sorted_indices[i] = i
        sorted_probs[i] = scaled_logits[i]
    
    # High-performance quicksort for vocab sorting
    fn quicksort(low: Int, high: Int):
        if low < high:
            # Partition
            var pivot = sorted_probs[high]
            var i = low - 1
            for j in range(low, high):
                if sorted_probs[j] > pivot:
                    i += 1
                    # Swap probs
                    var tmp_p = sorted_probs[i]
                    sorted_probs[i] = sorted_probs[j]
                    sorted_probs[j] = tmp_p
                    # Swap indices
                    var tmp_idx = sorted_indices[i]
                    sorted_indices[i] = sorted_indices[j]
                    sorted_indices[j] = tmp_idx
            
            # Final swap with pivot
            var tmp_p = sorted_probs[i + 1]
            sorted_probs[i + 1] = sorted_probs[high]
            sorted_probs[high] = tmp_p
            var tmp_idx = sorted_indices[i + 1]
            sorted_indices[i + 1] = sorted_indices[high]
            sorted_indices[high] = tmp_idx
            
            var p = i + 1
            quicksort(low, p - 1)
            quicksort(p + 1, high)

    quicksort(0, vocab_size - 1)
    
    # Find cutoff for top-p
    var cumsum = Float32(0.0)
    var cutoff_idx = vocab_size
    for i in range(vocab_size):
        cumsum += sorted_probs[i]
        if cumsum >= top_p:
            cutoff_idx = i + 1
            break
    
    # Renormalize and sample
    var renorm_sum = Float32(0.0)
    for i in range(cutoff_idx):
        renorm_sum += sorted_probs[i]
    
    var rand_val = Float32(random_float64())
    cumsum = 0.0
    var sampled_idx = sorted_indices[0]
    
    for i in range(cutoff_idx):
        cumsum += sorted_probs[i] / renorm_sum
        if cumsum >= rand_val:
            sampled_idx = sorted_indices[i]
            break
    
    scaled_logits.free()
    sorted_indices.free()
    sorted_probs.free()
    
    return sampled_idx


fn get_token_probability(
    logits: UnsafePointer[Float32],
    token: Int,
    vocab_size: Int,
    temperature: Float32,
) -> Float32:
    """Get probability of a specific token."""
    # Guard against null pointer or invalid parameters
    if not logits or vocab_size <= 0 or token < 0 or token >= vocab_size:
        return 0.0
    
    # Apply temperature and softmax
    var max_logit = logits[0]
    for i in range(1, vocab_size):
        max_logit = math_max(max_logit, logits[i])
    
    var sum_exp = Float32(0.0)
    for i in range(vocab_size):
        sum_exp += exp((logits[i] - max_logit) / temperature)
    
    var token_prob = exp((logits[token] - max_logit) / temperature) / sum_exp
    return token_prob


# =============================================================================
# Speculative Decoding Core
# =============================================================================

struct SpeculativeDecoder:
    """
    Speculative decoding with draft and target models.
    
    Draft model generates N tokens quickly, target model verifies in parallel.
    """
    var config: SpeculativeConfig
    var vocab_size: Int
    var accepted_tokens: Int
    var total_speculated: Int
    var total_verified: Int
    
    fn __init__(inout self, config: SpeculativeConfig, vocab_size: Int):
        self.config = config
        self.vocab_size = vocab_size
        self.accepted_tokens = 0
        self.total_speculated = 0
        self.total_verified = 0
    
    fn speculative_decode_step(
        inout self,
        draft_logits_fn: fn(tokens: UnsafePointer[Int], num_tokens: Int) -> UnsafePointer[Float32],
        target_logits_fn: fn(tokens: UnsafePointer[Int], num_tokens: Int) -> UnsafePointer[Float32],
        input_tokens: UnsafePointer[Int],
        num_input_tokens: Int,
        output_tokens: UnsafePointer[Int],
    ) -> Int:
        """
        Perform one speculative decoding step.
        
        Returns number of tokens generated.
        """
        var n_spec = self.config.num_speculative_tokens
        
        # Step 1: Draft model generates N speculative tokens
        var draft_tokens = UnsafePointer[Int].alloc(n_spec)
        var draft_probs = UnsafePointer[Float32].alloc(n_spec)
        
        # Build context for draft
        var draft_context = UnsafePointer[Int].alloc(num_input_tokens + n_spec)
        for i in range(num_input_tokens):
            draft_context[i] = input_tokens[i]
        
        # Generate speculative tokens one by one
        for s in range(n_spec):
            var context_len = num_input_tokens + s
            var logits = draft_logits_fn(draft_context, context_len)
            
            var token = sample_token(
                logits,
                self.vocab_size,
                self.config.draft_temperature,
                self.config.top_p
            )
            
            draft_tokens[s] = token
            draft_probs[s] = get_token_probability(
                logits, token, self.vocab_size, self.config.draft_temperature
            )
            draft_context[context_len] = token
        
        self.total_speculated += n_spec
        
        # Step 2: Target model verifies all speculative tokens in parallel
        # Get target logits for all positions at once
        var target_context = UnsafePointer[Int].alloc(num_input_tokens + n_spec)
        for i in range(num_input_tokens):
            target_context[i] = input_tokens[i]
        for s in range(n_spec):
            target_context[num_input_tokens + s] = draft_tokens[s]
        
        var target_logits = target_logits_fn(target_context, num_input_tokens + n_spec)
        
        # Step 3: Rejection sampling - accept or reject each token
        var num_accepted = 0
        
        for s in range(n_spec):
            var target_prob = get_token_probability(
                target_logits + s * self.vocab_size,
                draft_tokens[s],
                self.vocab_size,
                self.config.temperature
            )
            
            # Rejection sampling: accept with probability min(1, p_target/p_draft)
            var acceptance_prob = target_prob / (draft_probs[s] + 1e-10)
            var rand_val = Float32(random_float64())
            
            if rand_val < acceptance_prob:
                output_tokens[num_accepted] = draft_tokens[s]
                num_accepted += 1
            else:
                # Rejection: sample from adjusted distribution
                # p_adjusted = max(0, p_target - p_draft)
                var adjusted_logits = UnsafePointer[Float32].alloc(self.vocab_size)
                var pos_logits = target_logits + s * self.vocab_size
                
                # Get draft logits for this position (need fresh call for correct context)
                var draft_logits_for_pos = draft_logits_fn(draft_context, num_input_tokens + s)
                
                for v in range(self.vocab_size):
                    var p_t = get_token_probability(
                        pos_logits, v, self.vocab_size, self.config.temperature
                    )
                    var p_d = get_token_probability(
                        draft_logits_for_pos,
                        v, self.vocab_size, self.config.draft_temperature
                    )
                    adjusted_logits[v] = log(math_max(p_t - p_d, 1e-10))
                
                var resampled = sample_token(
                    adjusted_logits,
                    self.vocab_size,
                    1.0,  # No temperature, already in prob space
                    1.0   # No top-p truncation
                )
                output_tokens[num_accepted] = resampled
                num_accepted += 1
                adjusted_logits.free()
                break  # Stop accepting after first rejection
        
        self.accepted_tokens += num_accepted
        self.total_verified += n_spec
        
        # Clean up
        draft_tokens.free()
        draft_probs.free()
        draft_context.free()
        target_context.free()
        
        return num_accepted
    
    fn acceptance_rate(self) -> Float32:
        """Get the current acceptance rate."""
        if self.total_speculated == 0:
            return 0.0
        return Float32(self.accepted_tokens) / Float32(self.total_speculated)
    
    fn speedup_factor(self) -> Float32:
        """
        Estimate speedup from speculative decoding.
        
        Assumes target model is N times slower than draft.
        """
        var acc_rate = self.acceptance_rate()
        var n = Float32(self.config.num_speculative_tokens)
        
        # Expected tokens per target forward pass
        var expected_tokens = 1.0 + acc_rate * n
        return expected_tokens


# =============================================================================
# Medusa-Style Multi-Head Speculation
# =============================================================================

struct MedusaHead:
    """
    Medusa decoding head for parallel token prediction.
    
    Each head predicts tokens at different future positions.
    """
    var hidden_dim: Int
    var vocab_size: Int
    var num_heads: Int  # Number of Medusa heads (future positions)
    var weights: UnsafePointer[Float32]  # [num_heads, hidden_dim, vocab_size]
    
    fn __init__(inout self, hidden_dim: Int, vocab_size: Int, num_heads: Int):
        self.hidden_dim = hidden_dim
        self.vocab_size = vocab_size
        self.num_heads = num_heads
        self.weights = UnsafePointer[Float32].alloc(num_heads * hidden_dim * vocab_size)
    
    fn __del__(owned self):
        self.weights.free()
    
    fn forward(
        self,
        hidden_state: UnsafePointer[Float32],  # [hidden_dim]
        logits: UnsafePointer[Float32],        # [num_heads, vocab_size] output
    ):
        """Compute logits for all Medusa heads."""
        for h in range(self.num_heads):
            var head_weights = self.weights + h * self.hidden_dim * self.vocab_size
            
            for v in range(self.vocab_size):
                var dot = Float32(0.0)
                
                @parameter
                fn dot_simd[width: Int](d: Int):
                    var h_vec = (hidden_state + d).simd_load[width]()
                    var w_vec = (head_weights + v * self.hidden_dim + d).simd_load[width]()
                    dot += (h_vec * w_vec).reduce_add()
                
                vectorize[dot_simd, SIMD_WIDTH](self.hidden_dim)
                logits[h * self.vocab_size + v] = dot


struct MedusaDecoder:
    """
    Medusa decoding with multiple prediction heads.
    
    Predicts multiple future tokens in parallel using tree attention.
    """
    var heads: MedusaHead
    var vocab_size: Int
    var tree_candidates: Int  # Number of candidate sequences
    var temperature: Float32
    
    fn __init__(inout self, hidden_dim: Int, vocab_size: Int, num_heads: Int):
        self.heads = MedusaHead(hidden_dim, vocab_size, num_heads)
        self.vocab_size = vocab_size
        self.tree_candidates = 64  # Top-k candidates per head
        self.temperature = 0.7
    
    fn generate_candidates(
        self,
        hidden_state: UnsafePointer[Float32],
        candidates: UnsafePointer[Int],  # [tree_candidates, num_heads] output
        num_candidates: UnsafePointer[Int],  # Output: actual number of candidates
    ):
        """Generate candidate token sequences using Medusa heads."""
        var num_heads = self.heads.num_heads
        
        # Get logits from all heads
        var all_logits = UnsafePointer[Float32].alloc(num_heads * self.vocab_size)
        self.heads.forward(hidden_state, all_logits)
        
        # Get top-k tokens per head
        var top_k_per_head = 4  # Reduce from tree_candidates
        var top_tokens = UnsafePointer[Int].alloc(num_heads * top_k_per_head)
        var top_probs = UnsafePointer[Float32].alloc(num_heads * top_k_per_head)
        
        for h in range(num_heads):
            var head_logits = all_logits + h * self.vocab_size
            
            # Find top-k for this head
            for k in range(top_k_per_head):
                var max_idx = 0
                var max_val = Float32(-1e10)
                
                for v in range(self.vocab_size):
                    var valid = True
                    for prev_k in range(k):
                        if top_tokens[h * top_k_per_head + prev_k] == v:
                            valid = False
                            break
                    
                    if valid and head_logits[v] > max_val:
                        max_val = head_logits[v]
                        max_idx = v
                
                top_tokens[h * top_k_per_head + k] = max_idx
                top_probs[h * top_k_per_head + k] = max_val
        
        # Generate candidate sequences (Cartesian product with pruning)
        var n_cand = 0
        for k0 in range(top_k_per_head):
            for k1 in range(top_k_per_head):
                if n_cand >= self.tree_candidates:
                    break
                
                candidates[n_cand * num_heads + 0] = top_tokens[0 * top_k_per_head + k0]
                if num_heads > 1:
                    candidates[n_cand * num_heads + 1] = top_tokens[1 * top_k_per_head + k1]
                
                # Continue for more heads if needed
                for h in range(2, num_heads):
                    candidates[n_cand * num_heads + h] = top_tokens[h * top_k_per_head + 0]
                
                n_cand += 1
        
        num_candidates[0] = n_cand
        
        all_logits.free()
        top_tokens.free()
        top_probs.free()
    
    fn verify_candidates(
        self,
        target_logits_fn: fn(tokens: UnsafePointer[Int], num_tokens: Int) -> UnsafePointer[Float32],
        input_tokens: UnsafePointer[Int],
        num_input_tokens: Int,
        candidates: UnsafePointer[Int],
        num_candidates: Int,
        accepted_tokens: UnsafePointer[Int],
    ) -> Int:
        """
        Verify candidate sequences using tree attention.
        
        Returns number of accepted tokens from best candidate.
        """
        var num_heads = self.heads.num_heads
        var best_accepted = 0
        var best_candidate = 0
        
        # Verify each candidate
        for c in range(num_candidates):
            var candidate = candidates + c * num_heads
            
            # Build context with this candidate
            var context = UnsafePointer[Int].alloc(num_input_tokens + num_heads)
            for i in range(num_input_tokens):
                context[i] = input_tokens[i]
            for h in range(num_heads):
                context[num_input_tokens + h] = candidate[h]
            
            # Get target logits
            var logits = target_logits_fn(context, num_input_tokens + num_heads)
            
            # Count accepted tokens using greedy verification
            var accepted = 0
            for h in range(num_heads):
                var pos_logits = logits + h * self.vocab_size
                var greedy_token = 0
                var max_logit = pos_logits[0]
                
                for v in range(1, self.vocab_size):
                    if pos_logits[v] > max_logit:
                        max_logit = pos_logits[v]
                        greedy_token = v
                
                if greedy_token == candidate[h]:
                    accepted += 1
                else:
                    break
            
            if accepted > best_accepted:
                best_accepted = accepted
                best_candidate = c
            
            context.free()
        
        # Copy best candidate tokens
        for h in range(best_accepted):
            accepted_tokens[h] = candidates[best_candidate * num_heads + h]
        
        return best_accepted


# =============================================================================
# Lookahead Decoding
# =============================================================================

struct LookaheadDecoder:
    """
    Lookahead decoding - parallel n-gram speculation.
    
    Uses n-gram cache from draft generations for speculation.
    """
    var window_size: Int  # Lookahead window
    var ngram_size: Int   # N-gram length for matching
    var vocab_size: Int
    var ngram_cache: UnsafePointer[Int]  # Simple n-gram storage
    var cache_size: Int
    var cache_count: Int
    
    fn __init__(inout self, window_size: Int, ngram_size: Int, vocab_size: Int):
        self.window_size = window_size
        self.ngram_size = ngram_size
        self.vocab_size = vocab_size
        self.cache_size = 10000
        self.cache_count = 0
        self.ngram_cache = UnsafePointer[Int].alloc(self.cache_size * (ngram_size + 1))
    
    fn __del__(owned self):
        self.ngram_cache.free()
    
    fn add_ngram(inout self, tokens: UnsafePointer[Int], next_token: Int):
        """Add an n-gram to the cache."""
        if self.cache_count >= self.cache_size:
            return  # Cache full
        
        var entry = self.ngram_cache + self.cache_count * (self.ngram_size + 1)
        for i in range(self.ngram_size):
            entry[i] = tokens[i]
        entry[self.ngram_size] = next_token
        self.cache_count += 1
    
    fn lookup_ngram(self, tokens: UnsafePointer[Int]) -> Int:
        """Look up n-gram in cache. Returns predicted next token or -1."""
        for c in range(self.cache_count):
            var entry = self.ngram_cache + c * (self.ngram_size + 1)
            var match = True
            
            for i in range(self.ngram_size):
                if entry[i] != tokens[i]:
                    match = False
                    break
            
            if match:
                return entry[self.ngram_size]
        
        return -1
    
    fn generate_speculative_from_cache(
        self,
        context: UnsafePointer[Int],
        context_len: Int,
        speculative_tokens: UnsafePointer[Int],
        max_speculative: Int,
    ) -> Int:
        """Generate speculative tokens using n-gram cache."""
        var num_spec = 0
        var current_context = UnsafePointer[Int].alloc(self.ngram_size)
        
        # Initialize with end of context
        for i in range(self.ngram_size):
            current_context[i] = context[context_len - self.ngram_size + i]
        
        while num_spec < max_speculative:
            var predicted = self.lookup_ngram(current_context)
            if predicted < 0:
                break
            
            speculative_tokens[num_spec] = predicted
            num_spec += 1
            
            # Shift context
            for i in range(self.ngram_size - 1):
                current_context[i] = current_context[i + 1]
            current_context[self.ngram_size - 1] = predicted
        
        current_context.free()
        return num_spec