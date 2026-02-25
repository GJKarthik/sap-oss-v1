"""
Sampling Module

High-performance sampling algorithms for text generation.
Supports:
- Greedy decoding
- Temperature sampling
- Top-k sampling
- Top-p (nucleus) sampling
- Repetition penalty
- Beam search
"""

from tensor import Tensor, TensorShape
from math import exp, log
from algorithm import vectorize, parallelize, sort
from random import random_float64
from sys.info import simdwidthof

alias SIMD_WIDTH = simdwidthof[DType.float32]()


# ==============================================
# Sampling Parameters
# ==============================================

struct SamplingParams:
    """Parameters for controlling text generation sampling."""
    
    var temperature: Float32
    var top_p: Float32
    var top_k: Int
    var min_p: Float32
    var repetition_penalty: Float32
    var presence_penalty: Float32
    var frequency_penalty: Float32
    var seed: Int
    var max_tokens: Int
    var stop_token_ids: List[Int]
    var ignore_eos: Bool
    var skip_special_tokens: Bool
    
    fn __init__(
        inout self,
        temperature: Float32 = 1.0,
        top_p: Float32 = 1.0,
        top_k: Int = -1,
        min_p: Float32 = 0.0,
        repetition_penalty: Float32 = 1.0,
        presence_penalty: Float32 = 0.0,
        frequency_penalty: Float32 = 0.0,
        seed: Int = -1,
        max_tokens: Int = 256,
        ignore_eos: Bool = False,
        skip_special_tokens: Bool = True,
    ):
        self.temperature = temperature
        self.top_p = top_p
        self.top_k = top_k
        self.min_p = min_p
        self.repetition_penalty = repetition_penalty
        self.presence_penalty = presence_penalty
        self.frequency_penalty = frequency_penalty
        self.seed = seed
        self.max_tokens = max_tokens
        self.stop_token_ids = List[Int]()
        self.ignore_eos = ignore_eos
        self.skip_special_tokens = skip_special_tokens
    
    fn is_greedy(self) -> Bool:
        """Check if using greedy decoding."""
        return self.temperature == 0.0 or (self.top_k == 1)
    
    fn needs_sampling(self) -> Bool:
        """Check if sampling is needed (not greedy)."""
        return not self.is_greedy()
    
    @staticmethod
    fn greedy() -> SamplingParams:
        """Create params for greedy decoding."""
        return SamplingParams(temperature=0.0)
    
    @staticmethod
    fn default() -> SamplingParams:
        """Create default sampling params."""
        return SamplingParams()
    
    @staticmethod
    fn creative() -> SamplingParams:
        """Create params for creative/diverse generation."""
        return SamplingParams(
            temperature=0.8,
            top_p=0.95,
            top_k=50,
        )
    
    @staticmethod
    fn deterministic() -> SamplingParams:
        """Create params for deterministic generation."""
        return SamplingParams(
            temperature=0.0,
            top_k=1,
        )


# ==============================================
# Sampling Result
# ==============================================

struct SamplingResult:
    """Result of sampling a batch of sequences."""
    
    var next_tokens: Tensor[DType.int32]  # [batch_size]
    var logprobs: Tensor[DType.float32]   # [batch_size]
    var top_logprobs: Tensor[DType.float32]  # [batch_size, top_n]
    var top_tokens: Tensor[DType.int32]   # [batch_size, top_n]
    
    fn __init__(inout self, batch_size: Int, top_n: Int = 0):
        self.next_tokens = Tensor[DType.int32](batch_size)
        self.logprobs = Tensor[DType.float32](batch_size)
        
        if top_n > 0:
            self.top_logprobs = Tensor[DType.float32](batch_size, top_n)
            self.top_tokens = Tensor[DType.int32](batch_size, top_n)
        else:
            self.top_logprobs = Tensor[DType.float32](0)
            self.top_tokens = Tensor[DType.int32](0)


# ==============================================
# Sampler
# ==============================================

struct Sampler:
    """
    High-performance sampler for LLM token generation.
    """
    
    var vocab_size: Int
    var seed: Int
    
    fn __init__(inout self, vocab_size: Int, seed: Int = 42):
        self.vocab_size = vocab_size
        self.seed = seed
    
    fn sample(
        self,
        logits: Tensor[DType.float32],
        params: SamplingParams,
    ) -> SamplingResult:
        """
        Sample next tokens from logits.
        
        Args:
            logits: Logits tensor [batch_size, vocab_size]
            params: Sampling parameters
        
        Returns:
            SamplingResult with sampled tokens
        """
        let batch_size = logits.shape()[0]
        var result = SamplingResult(batch_size)
        
        for b in range(batch_size):
            let batch_logits = logits[b, :]
            
            if params.is_greedy():
                # Greedy decoding
                let (token, logprob) = self._greedy_sample(batch_logits)
                result.next_tokens.store(b, token)
                result.logprobs.store(b, logprob)
            else:
                # Sampling with temperature, top-k, top-p
                let (token, logprob) = self._sample_with_params(batch_logits, params)
                result.next_tokens.store(b, token)
                result.logprobs.store(b, logprob)
        
        return result
    
    fn _greedy_sample(
        self,
        logits: Tensor[DType.float32],
    ) -> Tuple[Int32, Float32]:
        """Greedy decoding - select token with highest logit."""
        var max_idx = 0
        var max_val = logits[0]
        
        for i in range(1, self.vocab_size):
            if logits[i] > max_val:
                max_val = logits[i]
                max_idx = i
        
        # Compute log probability
        let logprob = self._compute_logprob(logits, max_idx)
        
        return (Int32(max_idx), logprob)
    
    fn _sample_with_params(
        self,
        logits: Tensor[DType.float32],
        params: SamplingParams,
    ) -> Tuple[Int32, Float32]:
        """Sample with temperature, top-k, and top-p."""
        var processed_logits = logits
        
        # Apply temperature
        if params.temperature != 1.0 and params.temperature > 0:
            processed_logits = self._apply_temperature(processed_logits, params.temperature)
        
        # Apply top-k
        if params.top_k > 0 and params.top_k < self.vocab_size:
            processed_logits = self._apply_top_k(processed_logits, params.top_k)
        
        # Apply top-p (nucleus)
        if params.top_p < 1.0:
            processed_logits = self._apply_top_p(processed_logits, params.top_p)
        
        # Apply min-p
        if params.min_p > 0.0:
            processed_logits = self._apply_min_p(processed_logits, params.min_p)
        
        # Convert to probabilities
        let probs = self._softmax(processed_logits)
        
        # Sample from distribution
        let sampled_idx = self._categorical_sample(probs)
        
        # Compute log probability from original logits
        let logprob = self._compute_logprob(logits, sampled_idx)
        
        return (Int32(sampled_idx), logprob)
    
    fn _apply_temperature(
        self,
        logits: Tensor[DType.float32],
        temperature: Float32,
    ) -> Tensor[DType.float32]:
        """Scale logits by temperature."""
        var result = Tensor[DType.float32](logits.shape())
        
        @parameter
        fn scale[width: Int](i: Int):
            let vals = logits.load[width=width](i)
            result.store[width=width](i, vals / temperature)
        
        vectorize[scale, SIMD_WIDTH](self.vocab_size)
        
        return result
    
    fn _apply_top_k(
        self,
        logits: Tensor[DType.float32],
        k: Int,
    ) -> Tensor[DType.float32]:
        """Keep only top-k logits, set others to -inf."""
        # Find k-th largest value
        var sorted_values = List[Float32]()
        for i in range(self.vocab_size):
            sorted_values.append(logits[i])
        
        # Sort descending
        sort(sorted_values, reverse=True)
        let threshold = sorted_values[k - 1]
        
        # Mask values below threshold
        var result = Tensor[DType.float32](logits.shape())
        for i in range(self.vocab_size):
            if logits[i] >= threshold:
                result.store(i, logits[i])
            else:
                result.store(i, Float32.min)
        
        return result
    
    fn _apply_top_p(
        self,
        logits: Tensor[DType.float32],
        p: Float32,
    ) -> Tensor[DType.float32]:
        """Keep tokens until cumulative probability exceeds p."""
        # Convert to probabilities
        let probs = self._softmax(logits)
        
        # Sort by probability descending
        var indexed_probs = List[Tuple[Int, Float32]]()
        for i in range(self.vocab_size):
            indexed_probs.append((i, probs[i]))
        
        # Sort by probability (descending)
        sort(indexed_probs, key=lambda x: -x[1])
        
        # Find cutoff
        var cumsum: Float32 = 0.0
        var cutoff_idx = self.vocab_size
        for i in range(self.vocab_size):
            cumsum += indexed_probs[i][1]
            if cumsum >= p:
                cutoff_idx = i + 1
                break
        
        # Create mask
        var result = Tensor[DType.float32](logits.shape())
        for i in range(self.vocab_size):
            result.store(i, Float32.min)
        
        for i in range(cutoff_idx):
            let idx = indexed_probs[i][0]
            result.store(idx, logits[idx])
        
        return result
    
    fn _apply_min_p(
        self,
        logits: Tensor[DType.float32],
        min_p: Float32,
    ) -> Tensor[DType.float32]:
        """Keep tokens with probability >= min_p * max_prob."""
        let probs = self._softmax(logits)
        
        # Find max probability
        var max_prob: Float32 = 0.0
        for i in range(self.vocab_size):
            if probs[i] > max_prob:
                max_prob = probs[i]
        
        let threshold = min_p * max_prob
        
        # Mask low probability tokens
        var result = Tensor[DType.float32](logits.shape())
        for i in range(self.vocab_size):
            if probs[i] >= threshold:
                result.store(i, logits[i])
            else:
                result.store(i, Float32.min)
        
        return result
    
    fn _softmax(self, logits: Tensor[DType.float32]) -> Tensor[DType.float32]:
        """Compute softmax probabilities."""
        # Find max for numerical stability
        var max_val = logits[0]
        for i in range(1, self.vocab_size):
            if logits[i] > max_val:
                max_val = logits[i]
        
        # Compute exp(logits - max)
        var result = Tensor[DType.float32](logits.shape())
        var sum_exp: Float32 = 0.0
        
        for i in range(self.vocab_size):
            let exp_val = exp(logits[i] - max_val)
            result.store(i, exp_val)
            sum_exp += exp_val
        
        # Normalize
        for i in range(self.vocab_size):
            result.store(i, result[i] / sum_exp)
        
        return result
    
    fn _categorical_sample(self, probs: Tensor[DType.float32]) -> Int:
        """Sample from categorical distribution."""
        let u = random_float64().cast[DType.float32]()
        
        var cumsum: Float32 = 0.0
        for i in range(self.vocab_size):
            cumsum += probs[i]
            if u < cumsum:
                return i
        
        return self.vocab_size - 1
    
    fn _compute_logprob(
        self,
        logits: Tensor[DType.float32],
        idx: Int,
    ) -> Float32:
        """Compute log probability for a specific token."""
        let probs = self._softmax(logits)
        return log(probs[idx])


# ==============================================
# Repetition Penalty
# ==============================================

fn apply_repetition_penalty(
    logits: Tensor[DType.float32],
    token_ids: Tensor[DType.int32],
    penalty: Float32,
) -> Tensor[DType.float32]:
    """
    Apply repetition penalty to logits.
    
    Penalizes tokens that have appeared in the context.
    """
    var result = logits
    
    let num_tokens = token_ids.num_elements()
    
    for i in range(num_tokens):
        let token_id = token_ids[i].cast[DType.int64]()
        let score = result[token_id]
        
        # Apply penalty
        if score > 0:
            result.store(token_id, score / penalty)
        else:
            result.store(token_id, score * penalty)
    
    return result


fn apply_presence_penalty(
    logits: Tensor[DType.float32],
    token_ids: Tensor[DType.int32],
    penalty: Float32,
) -> Tensor[DType.float32]:
    """
    Apply presence penalty to logits.
    
    Subtracts a flat penalty for tokens that have appeared.
    """
    var result = logits
    
    # Track which tokens have appeared
    var appeared = Tensor[DType.bool](logits.shape()[0])
    
    let num_tokens = token_ids.num_elements()
    for i in range(num_tokens):
        let token_id = token_ids[i].cast[DType.int64]()
        appeared.store(token_id, True)
    
    # Apply penalty
    for i in range(logits.shape()[0]):
        if appeared[i]:
            result.store(i, result[i] - penalty)
    
    return result


fn apply_frequency_penalty(
    logits: Tensor[DType.float32],
    token_ids: Tensor[DType.int32],
    penalty: Float32,
) -> Tensor[DType.float32]:
    """
    Apply frequency penalty to logits.
    
    Penalty proportional to token frequency in context.
    """
    var result = logits
    
    # Count token frequencies
    var counts = Tensor[DType.int32](logits.shape()[0])
    
    let num_tokens = token_ids.num_elements()
    for i in range(num_tokens):
        let token_id = token_ids[i].cast[DType.int64]()
        counts.store(token_id, counts[token_id] + 1)
    
    # Apply penalty
    for i in range(logits.shape()[0]):
        let count = counts[i].cast[DType.float32]()
        if count > 0:
            result.store(i, result[i] - penalty * count)
    
    return result


# ==============================================
# Beam Search
# ==============================================

struct BeamHypothesis:
    """A single hypothesis in beam search."""
    var tokens: List[Int32]
    var score: Float32
    var is_done: Bool
    
    fn __init__(inout self):
        self.tokens = List[Int32]()
        self.score = 0.0
        self.is_done = False
    
    fn length(self) -> Int:
        return len(self.tokens)


struct BeamSearchSampler:
    """
    Beam search decoding.
    
    Maintains multiple hypotheses and selects best ones at each step.
    """
    
    var vocab_size: Int
    var beam_width: Int
    var length_penalty: Float32
    var early_stopping: Bool
    
    fn __init__(
        inout self,
        vocab_size: Int,
        beam_width: Int = 4,
        length_penalty: Float32 = 1.0,
        early_stopping: Bool = False,
    ):
        self.vocab_size = vocab_size
        self.beam_width = beam_width
        self.length_penalty = length_penalty
        self.early_stopping = early_stopping
    
    fn step(
        inout self,
        logits: Tensor[DType.float32],
        hypotheses: List[BeamHypothesis],
    ) -> List[BeamHypothesis]:
        """
        Perform one step of beam search.
        
        Args:
            logits: Logits for current step [beam_width, vocab_size]
            hypotheses: Current beam hypotheses
        
        Returns:
            Updated hypotheses
        """
        # Compute log probabilities
        var all_candidates = List[Tuple[Int, Int, Float32]]()
        
        for beam_idx in range(len(hypotheses)):
            if hypotheses[beam_idx].is_done:
                all_candidates.append((beam_idx, -1, hypotheses[beam_idx].score))
                continue
            
            let beam_logits = logits[beam_idx, :]
            let probs = self._log_softmax(beam_logits)
            
            for token_idx in range(self.vocab_size):
                let score = hypotheses[beam_idx].score + probs[token_idx]
                all_candidates.append((beam_idx, token_idx, score))
        
        # Sort by score and keep top beam_width
        sort(all_candidates, key=lambda x: -x[2])
        
        var new_hypotheses = List[BeamHypothesis]()
        for i in range(min(self.beam_width, len(all_candidates))):
            let (beam_idx, token_idx, score) = all_candidates[i]
            
            var hyp = BeamHypothesis()
            hyp.tokens = hypotheses[beam_idx].tokens.copy()
            if token_idx >= 0:
                hyp.tokens.append(Int32(token_idx))
            hyp.score = score
            hyp.is_done = hypotheses[beam_idx].is_done
            
            new_hypotheses.append(hyp)
        
        return new_hypotheses
    
    fn _log_softmax(self, logits: Tensor[DType.float32]) -> Tensor[DType.float32]:
        """Compute log softmax."""
        var max_val = logits[0]
        for i in range(1, self.vocab_size):
            if logits[i] > max_val:
                max_val = logits[i]
        
        var sum_exp: Float32 = 0.0
        for i in range(self.vocab_size):
            sum_exp += exp(logits[i] - max_val)
        
        let log_sum_exp = log(sum_exp) + max_val
        
        var result = Tensor[DType.float32](self.vocab_size)
        for i in range(self.vocab_size):
            result.store(i, logits[i] - log_sum_exp)
        
        return result
    
    fn finalize(
        self,
        hypotheses: List[BeamHypothesis],
    ) -> List[BeamHypothesis]:
        """
        Finalize beam search and return sorted hypotheses.
        
        Applies length penalty to final scores.
        """
        var scored = List[BeamHypothesis]()
        
        for hyp in hypotheses:
            var adjusted_hyp = hyp
            # Apply length penalty
            let length_factor = pow(Float32(hyp.length()), self.length_penalty)
            adjusted_hyp.score = hyp.score / length_factor
            scored.append(adjusted_hyp)
        
        # Sort by adjusted score
        sort(scored, key=lambda x: -x.score)
        
        return scored