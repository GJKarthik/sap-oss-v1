"""
Speculative Decoding Framework

Implementation of speculative decoding for accelerated LLM inference.
Uses a smaller "draft" model to propose tokens that are verified by
the larger "target" model in parallel.

Key features:
- Draft model token generation
- Parallel verification
- Token acceptance/rejection
- Dynamic speculation depth
"""

from tensor import Tensor, TensorShape
from math import exp, log
from random import random_float64


# ==============================================
# Speculative Decoding Config
# ==============================================

struct SpeculativeConfig:
    """Configuration for speculative decoding."""
    
    var num_speculative_tokens: Int
    var draft_model_name: String
    var acceptance_method: String  # "typical", "rejection_sampling", "greedy"
    var max_draft_length: Int
    var min_acceptance_rate: Float32
    var dynamic_depth: Bool  # Adjust speculation depth based on acceptance
    
    fn __init__(
        inout self,
        num_speculative_tokens: Int = 5,
        draft_model_name: String = "",
        acceptance_method: String = "typical",
        max_draft_length: Int = 10,
        min_acceptance_rate: Float32 = 0.5,
        dynamic_depth: Bool = True,
    ):
        self.num_speculative_tokens = num_speculative_tokens
        self.draft_model_name = draft_model_name
        self.acceptance_method = acceptance_method
        self.max_draft_length = max_draft_length
        self.min_acceptance_rate = min_acceptance_rate
        self.dynamic_depth = dynamic_depth


# ==============================================
# Draft Model Output
# ==============================================

struct DraftOutput:
    """Output from draft model speculation."""
    
    var tokens: Tensor[DType.int32]      # Proposed tokens [batch, num_speculative]
    var probs: Tensor[DType.float32]     # Draft probabilities [batch, num_speculative]
    var logprobs: Tensor[DType.float32]  # Draft log probabilities
    var num_proposed: Int                 # Actual number of tokens proposed
    
    fn __init__(inout self, batch_size: Int, num_tokens: Int):
        self.tokens = Tensor[DType.int32](batch_size, num_tokens)
        self.probs = Tensor[DType.float32](batch_size, num_tokens)
        self.logprobs = Tensor[DType.float32](batch_size, num_tokens)
        self.num_proposed = num_tokens


# ==============================================
# Verification Result
# ==============================================

struct VerificationResult:
    """Result of verifying draft tokens against target model."""
    
    var accepted_tokens: Tensor[DType.int32]  # Accepted token IDs [batch, variable]
    var num_accepted: Tensor[DType.int32]     # Number accepted per batch [batch]
    var bonus_token: Tensor[DType.int32]      # Bonus token from rejection [batch]
    var acceptance_rate: Float32               # Overall acceptance rate
    
    fn __init__(inout self, batch_size: Int, max_tokens: Int):
        self.accepted_tokens = Tensor[DType.int32](batch_size, max_tokens)
        self.num_accepted = Tensor[DType.int32](batch_size)
        self.bonus_token = Tensor[DType.int32](batch_size)
        self.acceptance_rate = 0.0


# ==============================================
# Speculative Decoder
# ==============================================

struct SpeculativeDecoder:
    """
    Speculative decoding engine.
    
    Algorithm:
    1. Draft model generates K candidate tokens autoregressively
    2. Target model evaluates all K+1 positions in parallel
    3. Verify draft tokens match target distribution
    4. Accept matching tokens, sample from residual for first rejection
    """
    
    var config: SpeculativeConfig
    var vocab_size: Int
    var current_depth: Int  # Current speculation depth (may be dynamic)
    var stats: SpeculativeStats
    
    fn __init__(inout self, config: SpeculativeConfig, vocab_size: Int):
        self.config = config
        self.vocab_size = vocab_size
        self.current_depth = config.num_speculative_tokens
        self.stats = SpeculativeStats()
    
    fn verify_tokens(
        self,
        draft_output: DraftOutput,
        target_logits: Tensor[DType.float32],  # [batch, num_spec+1, vocab]
    ) -> VerificationResult:
        """
        Verify draft tokens against target model logits.
        
        Args:
            draft_output: Tokens and probs from draft model
            target_logits: Logits from target model for all positions
        
        Returns:
            VerificationResult with accepted tokens and bonus token
        """
        let batch_size = draft_output.tokens.shape()[0]
        let num_proposed = draft_output.num_proposed
        
        var result = VerificationResult(batch_size, num_proposed + 1)
        
        for b in range(batch_size):
            let (accepted, bonus) = self._verify_batch(
                draft_output.tokens[b, :],
                draft_output.probs[b, :],
                target_logits[b, :, :],
                num_proposed,
            )
            
            # Store results
            for i in range(accepted.shape()[0]):
                result.accepted_tokens.store(b, i, accepted[i])
            result.num_accepted.store(b, Int32(accepted.shape()[0]))
            result.bonus_token.store(b, bonus)
        
        # Calculate acceptance rate
        var total_accepted = 0
        for b in range(batch_size):
            total_accepted += result.num_accepted[b].cast[DType.int64]()
        result.acceptance_rate = Float32(total_accepted) / Float32(batch_size * num_proposed)
        
        return result
    
    fn _verify_batch(
        self,
        draft_tokens: Tensor[DType.int32],
        draft_probs: Tensor[DType.float32],
        target_logits: Tensor[DType.float32],
        num_proposed: Int,
    ) -> Tuple[Tensor[DType.int32], Int32]:
        """
        Verify tokens for a single batch element.
        
        Returns (accepted_tokens, bonus_token).
        """
        var accepted = List[Int32]()
        var bonus_token: Int32 = -1
        
        for i in range(num_proposed):
            let draft_token = draft_tokens[i].cast[DType.int64]()
            let draft_prob = draft_probs[i]
            
            # Get target probability for this position
            let target_probs = self._softmax(target_logits[i, :])
            let target_prob = target_probs[draft_token]
            
            # Acceptance criterion
            let accept = self._acceptance_check(draft_prob, target_prob)
            
            if accept:
                accepted.append(Int32(draft_token))
            else:
                # Rejection: sample from residual distribution
                bonus_token = self._sample_residual(
                    target_probs, draft_prob, draft_token
                )
                break
        
        # If all accepted, sample bonus from target distribution at position K+1
        if len(accepted) == num_proposed:
            let final_probs = self._softmax(target_logits[num_proposed, :])
            bonus_token = self._sample_from_probs(final_probs)
        
        # Convert to tensor
        var accepted_tensor = Tensor[DType.int32](len(accepted))
        for i in range(len(accepted)):
            accepted_tensor.store(i, accepted[i])
        
        return (accepted_tensor, bonus_token)
    
    fn _acceptance_check(
        self,
        draft_prob: Float32,
        target_prob: Float32,
    ) -> Bool:
        """
        Check if draft token should be accepted.
        
        Uses rejection sampling: accept with probability min(1, target/draft).
        """
        if self.config.acceptance_method == "greedy":
            # Always accept if target prob >= draft prob
            return target_prob >= draft_prob
        else:
            # Rejection sampling
            let acceptance_prob = min(1.0, target_prob / (draft_prob + 1e-10))
            let u = random_float64().cast[DType.float32]()
            return u < acceptance_prob
    
    fn _sample_residual(
        self,
        target_probs: Tensor[DType.float32],
        draft_prob: Float32,
        draft_token: Int,
    ) -> Int32:
        """
        Sample from residual distribution after rejection.
        
        residual(x) = max(0, target(x) - draft(x)) / Z
        """
        var residual_probs = Tensor[DType.float32](self.vocab_size)
        var total: Float32 = 0.0
        
        for i in range(self.vocab_size):
            let target_p = target_probs[i]
            let draft_p = draft_prob if i == draft_token else Float32(0.0)
            let residual = max(0.0, target_p - draft_p)
            residual_probs.store(i, residual)
            total += residual
        
        # Normalize
        if total > 0:
            for i in range(self.vocab_size):
                residual_probs.store(i, residual_probs[i] / total)
        else:
            # Fallback to target distribution
            return self._sample_from_probs(target_probs)
        
        return self._sample_from_probs(residual_probs)
    
    fn _sample_from_probs(self, probs: Tensor[DType.float32]) -> Int32:
        """Sample token from probability distribution."""
        let u = random_float64().cast[DType.float32]()
        var cumsum: Float32 = 0.0
        
        for i in range(self.vocab_size):
            cumsum += probs[i]
            if u < cumsum:
                return Int32(i)
        
        return Int32(self.vocab_size - 1)
    
    fn _softmax(self, logits: Tensor[DType.float32]) -> Tensor[DType.float32]:
        """Compute softmax."""
        var max_val = logits[0]
        for i in range(1, self.vocab_size):
            if logits[i] > max_val:
                max_val = logits[i]
        
        var result = Tensor[DType.float32](self.vocab_size)
        var sum_exp: Float32 = 0.0
        
        for i in range(self.vocab_size):
            let exp_val = exp(logits[i] - max_val)
            result.store(i, exp_val)
            sum_exp += exp_val
        
        for i in range(self.vocab_size):
            result.store(i, result[i] / sum_exp)
        
        return result
    
    fn update_depth(inout self, acceptance_rate: Float32):
        """
        Dynamically adjust speculation depth based on acceptance rate.
        
        Higher acceptance → try more speculative tokens
        Lower acceptance → use fewer speculative tokens
        """
        if not self.config.dynamic_depth:
            return
        
        if acceptance_rate > 0.8:
            # High acceptance - increase depth
            self.current_depth = min(
                self.current_depth + 1,
                self.config.max_draft_length
            )
        elif acceptance_rate < 0.4:
            # Low acceptance - decrease depth
            self.current_depth = max(self.current_depth - 1, 1)
        
        self.stats.depth_updates += 1
    
    fn get_current_depth(self) -> Int:
        """Get current speculation depth."""
        return self.current_depth


# ==============================================
# Speculative Statistics
# ==============================================

struct SpeculativeStats:
    """Statistics for speculative decoding."""
    
    var total_proposed: Int
    var total_accepted: Int
    var total_bonus: Int
    var depth_updates: Int
    var batches_processed: Int
    
    fn __init__(inout self):
        self.total_proposed = 0
        self.total_accepted = 0
        self.total_bonus = 0
        self.depth_updates = 0
        self.batches_processed = 0
    
    fn acceptance_rate(self) -> Float32:
        if self.total_proposed == 0:
            return 0.0
        return Float32(self.total_accepted) / Float32(self.total_proposed)
    
    fn avg_accepted_per_batch(self) -> Float32:
        if self.batches_processed == 0:
            return 0.0
        return Float32(self.total_accepted + self.total_bonus) / Float32(self.batches_processed)


# ==============================================
# Draft Model Interface
# ==============================================

trait DraftModel:
    """Interface for draft models used in speculative decoding."""
    
    fn generate_draft(
        self,
        input_ids: Tensor[DType.int32],
        positions: Tensor[DType.int32],
        num_tokens: Int,
    ) -> DraftOutput:
        """Generate draft tokens autoregressively."""
        ...
    
    fn vocab_size(self) -> Int:
        """Get vocabulary size."""
        ...


# ==============================================
# Target Model Interface
# ==============================================

trait TargetModel:
    """Interface for target models in speculative decoding."""
    
    fn forward_parallel(
        self,
        input_ids: Tensor[DType.int32],  # [batch, seq + num_spec]
        positions: Tensor[DType.int32],
    ) -> Tensor[DType.float32]:
        """
        Parallel forward pass for verification.
        
        Computes logits for all positions in one pass.
        """
        ...


# ==============================================
# Speculative Decoding Engine
# ==============================================

struct SpeculativeEngine:
    """
    Full speculative decoding engine.
    
    Coordinates draft generation and target verification.
    """
    
    var config: SpeculativeConfig
    var decoder: SpeculativeDecoder
    var vocab_size: Int
    
    fn __init__(inout self, config: SpeculativeConfig, vocab_size: Int):
        self.config = config
        self.vocab_size = vocab_size
        self.decoder = SpeculativeDecoder(config, vocab_size)
    
    fn speculative_step(
        inout self,
        draft_output: DraftOutput,
        target_logits: Tensor[DType.float32],
    ) -> Tuple[Tensor[DType.int32], Int]:
        """
        Perform one speculative decoding step.
        
        Args:
            draft_output: Tokens from draft model
            target_logits: Logits from target model
        
        Returns:
            (output_tokens, num_tokens) tuple
        """
        # Verify draft tokens
        let result = self.decoder.verify_tokens(draft_output, target_logits)
        
        # Update statistics
        self.decoder.stats.total_proposed += draft_output.num_proposed
        
        # Collect output tokens
        let batch_size = draft_output.tokens.shape()[0]
        let max_output = draft_output.num_proposed + 1
        
        var output_tokens = Tensor[DType.int32](batch_size, max_output)
        var total_tokens = 0
        
        for b in range(batch_size):
            let num_accepted = result.num_accepted[b].cast[DType.int64]()
            
            # Copy accepted tokens
            for i in range(num_accepted):
                output_tokens.store(b, i, result.accepted_tokens[b, i])
            
            # Add bonus token
            output_tokens.store(b, num_accepted, result.bonus_token[b])
            
            total_tokens += Int(num_accepted) + 1
            self.decoder.stats.total_accepted += Int(num_accepted)
            self.decoder.stats.total_bonus += 1
        
        self.decoder.stats.batches_processed += batch_size
        
        # Update speculation depth
        self.decoder.update_depth(result.acceptance_rate)
        
        return (output_tokens, total_tokens // batch_size)
    
    fn get_stats(self) -> SpeculativeStats:
        """Get speculation statistics."""
        return self.decoder.stats
    
    fn get_current_depth(self) -> Int:
        """Get current speculation depth."""
        return self.decoder.get_current_depth()