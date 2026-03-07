"""
High-performance tokenizer implementation for LLM inference.

Provides:
- BPE (Byte-Pair Encoding) tokenization
- Token vocabulary management
- Efficient text encoding/decoding
- Special token handling
"""

from memory import memset_zero, memcpy
from collections import Dict
from algorithm import vectorize


alias MAX_TOKEN_LENGTH = 256
alias MAX_VOCAB_SIZE = 128000
alias FloatType = DType.float32


# =============================================================================
# Token Types
# =============================================================================

struct Token:
    """Represents a single token in the vocabulary."""
    var id: Int
    var text: String
    var score: Float32
    var is_special: Bool
    
    fn __init__(inout self, id: Int, text: String, score: Float32 = 0.0, is_special: Bool = False):
        self.id = id
        self.text = text
        self.score = score
        self.is_special = is_special


struct TokenPair:
    """A pair of tokens for BPE merge operations."""
    var left: Int
    var right: Int
    var merged_id: Int
    var score: Float32
    
    fn __init__(inout self, left: Int, right: Int, merged_id: Int, score: Float32):
        self.left = left
        self.right = right
        self.merged_id = merged_id
        self.score = score


# =============================================================================
# Vocabulary
# =============================================================================

struct Vocabulary:
    """Token vocabulary with efficient lookup."""
    var tokens: UnsafePointer[Token]
    var vocab_size: Int
    var bos_token_id: Int
    var eos_token_id: Int
    var pad_token_id: Int
    var unk_token_id: Int
    
    fn __init__(inout self, vocab_size: Int):
        self.tokens = UnsafePointer[Token].alloc(vocab_size)
        self.vocab_size = vocab_size
        self.bos_token_id = 1
        self.eos_token_id = 2
        self.pad_token_id = 0
        self.unk_token_id = 3
    
    fn add_token(inout self, id: Int, text: String, score: Float32 = 0.0, is_special: Bool = False):
        """Add a token to the vocabulary."""
        if id < self.vocab_size:
            self.tokens[id] = Token(id, text, score, is_special)
    
    fn get_token_text(self, id: Int) -> String:
        """Get the text for a token ID."""
        if id >= 0 and id < self.vocab_size:
            return self.tokens[id].text
        return "<unk>"
    
    fn is_special_token(self, id: Int) -> Bool:
        """Check if a token is a special token."""
        if id >= 0 and id < self.vocab_size:
            return self.tokens[id].is_special
        return False
    
    fn __del__(owned self):
        self.tokens.free()


# =============================================================================
# BPE Tokenizer
# =============================================================================

struct BPETokenizer:
    """Byte-Pair Encoding tokenizer for LLM text processing."""
    var vocab: Vocabulary
    var merges: UnsafePointer[TokenPair]
    var num_merges: Int
    var max_merges: Int
    
    fn __init__(inout self, vocab_size: Int, max_merges: Int = 100000):
        self.vocab = Vocabulary(vocab_size)
        self.merges = UnsafePointer[TokenPair].alloc(max_merges)
        self.num_merges = 0
        self.max_merges = max_merges
        
        # Initialize with basic special tokens
        self.vocab.add_token(0, "<pad>", 0.0, True)
        self.vocab.add_token(1, "<s>", 0.0, True)      # BOS
        self.vocab.add_token(2, "</s>", 0.0, True)     # EOS
        self.vocab.add_token(3, "<unk>", 0.0, True)    # Unknown
    
    fn add_merge(inout self, left: Int, right: Int, merged_id: Int, score: Float32):
        """Add a BPE merge rule."""
        if self.num_merges < self.max_merges:
            self.merges[self.num_merges] = TokenPair(left, right, merged_id, score)
            self.num_merges += 1
    
    fn encode_single_token(self, char: UInt8) -> Int:
        """Encode a single byte as a token."""
        # For basic byte-level BPE, bytes 0-255 map to tokens
        return int(char) + 256  # Offset by special tokens
    
    fn decode_single_token(self, token_id: Int) -> UInt8:
        """Decode a single token to a byte."""
        if token_id >= 256:
            return UInt8(token_id - 256)
        return 0
    
    fn __del__(owned self):
        self.merges.free()


# =============================================================================
# Text Encoding
# =============================================================================

fn encode_text(
    text: String,
    output_tokens: UnsafePointer[Int],
    max_tokens: Int,
    add_bos: Bool = True,
    add_eos: Bool = False
) -> Int:
    """
    Encode text to token IDs using byte-level tokenization.
    
    Args:
        text: Input text to encode
        output_tokens: Output buffer for token IDs
        max_tokens: Maximum number of tokens to output
        add_bos: Whether to add beginning-of-sequence token
        add_eos: Whether to add end-of-sequence token
    
    Returns:
        Number of tokens produced
    """
    var num_tokens = 0
    
    # Add BOS token
    if add_bos and num_tokens < max_tokens:
        output_tokens[num_tokens] = 1  # BOS token ID
        num_tokens += 1
    
    # Simple byte-level encoding
    var text_bytes = text.as_bytes()
    var text_len = len(text_bytes)
    
    for i in range(text_len):
        if num_tokens >= max_tokens:
            break
        # Map byte to token: bytes 0-255 map to tokens 256-511
        output_tokens[num_tokens] = int(text_bytes[i]) + 256
        num_tokens += 1
    
    # Add EOS token
    if add_eos and num_tokens < max_tokens:
        output_tokens[num_tokens] = 2  # EOS token ID
        num_tokens += 1
    
    return num_tokens


fn decode_tokens(
    tokens: UnsafePointer[Int],
    num_tokens: Int,
    output: UnsafePointer[UInt8],
    max_output_len: Int,
    skip_special: Bool = True
) -> Int:
    """
    Decode token IDs back to text bytes.
    
    Args:
        tokens: Input token IDs
        num_tokens: Number of input tokens
        output: Output buffer for decoded bytes
        max_output_len: Maximum output length
        skip_special: Whether to skip special tokens
    
    Returns:
        Number of bytes produced
    """
    var output_len = 0
    
    for i in range(num_tokens):
        if output_len >= max_output_len:
            break
        
        var token_id = tokens[i]
        
        # Skip special tokens (0-255)
        if skip_special and token_id < 256:
            continue
        
        # Decode byte-level token
        if token_id >= 256 and token_id < 512:
            output[output_len] = UInt8(token_id - 256)
            output_len += 1
    
    return output_len


# =============================================================================
# Batch Encoding
# =============================================================================

struct BatchEncoder:
    """Batch text encoder for efficient multi-sequence processing."""
    var max_seq_len: Int
    var batch_size: Int
    var token_buffer: UnsafePointer[Int]
    var length_buffer: UnsafePointer[Int]
    
    fn __init__(inout self, batch_size: Int, max_seq_len: Int):
        self.max_seq_len = max_seq_len
        self.batch_size = batch_size
        self.token_buffer = UnsafePointer[Int].alloc(batch_size * max_seq_len)
        self.length_buffer = UnsafePointer[Int].alloc(batch_size)
        memset_zero(self.token_buffer, batch_size * max_seq_len)
        memset_zero(self.length_buffer, batch_size)
    
    fn encode_batch(
        inout self,
        texts: List[String],
        add_bos: Bool = True,
        pad_to_max: Bool = True
    ) -> Int:
        """
        Encode a batch of texts.
        
        Args:
            texts: List of input texts
            add_bos: Whether to add BOS tokens
            pad_to_max: Whether to pad all sequences to max_seq_len
        
        Returns:
            Actual batch size processed
        """
        var actual_batch = min(len(texts), self.batch_size)
        var max_len_in_batch = 0
        
        for i in range(actual_batch):
            var output_ptr = self.token_buffer + i * self.max_seq_len
            var num_tokens = encode_text(
                texts[i],
                output_ptr,
                self.max_seq_len,
                add_bos,
                False
            )
            self.length_buffer[i] = num_tokens
            if num_tokens > max_len_in_batch:
                max_len_in_batch = num_tokens
        
        # Pad sequences if requested
        if pad_to_max:
            for i in range(actual_batch):
                var seq_len = self.length_buffer[i]
                var output_ptr = self.token_buffer + i * self.max_seq_len
                for j in range(seq_len, self.max_seq_len):
                    output_ptr[j] = 0  # PAD token
        
        return actual_batch
    
    fn get_tokens(self, batch_idx: Int) -> UnsafePointer[Int]:
        """Get token pointer for a batch item."""
        return self.token_buffer + batch_idx * self.max_seq_len
    
    fn get_length(self, batch_idx: Int) -> Int:
        """Get sequence length for a batch item."""
        return self.length_buffer[batch_idx]
    
    fn __del__(owned self):
        self.token_buffer.free()
        self.length_buffer.free()


# =============================================================================
# Token Sampling
# =============================================================================

fn sample_token_greedy(
    logits: UnsafePointer[Scalar[FloatType]],
    vocab_size: Int
) -> Int:
    """
    Sample a token using greedy decoding (argmax).
    
    Args:
        logits: Logit values for each token
        vocab_size: Vocabulary size
    
    Returns:
        Selected token ID
    """
    var max_logit: Scalar[FloatType] = -3.4028235e+38
    var max_id = 0
    
    for i in range(vocab_size):
        if logits[i] > max_logit:
            max_logit = logits[i]
            max_id = i
    
    return max_id


fn apply_temperature(
    logits: UnsafePointer[Scalar[FloatType]],
    vocab_size: Int,
    temperature: Scalar[FloatType]
):
    """
    Apply temperature scaling to logits in-place.
    
    Args:
        logits: Logit values (modified in-place)
        vocab_size: Vocabulary size
        temperature: Temperature value (higher = more random)
    """
    if temperature <= 0:
        return
    
    var inv_temp = 1.0 / temperature
    for i in range(vocab_size):
        logits[i] *= inv_temp


fn apply_top_p(
    logits: UnsafePointer[Scalar[FloatType]],
    vocab_size: Int,
    top_p: Scalar[FloatType]
):
    """
    Apply nucleus (top-p) sampling by zeroing out low-probability tokens.
    
    Args:
        logits: Logit values (modified in-place)
        vocab_size: Vocabulary size
        top_p: Cumulative probability threshold
    """
    from math import exp
    
    # Convert to probabilities with softmax
    var max_logit: Scalar[FloatType] = -3.4028235e+38
    for i in range(vocab_size):
        if logits[i] > max_logit:
            max_logit = logits[i]
    
    var sum_exp: Scalar[FloatType] = 0
    for i in range(vocab_size):
        logits[i] = exp(logits[i] - max_logit)
        sum_exp += logits[i]
    
    for i in range(vocab_size):
        logits[i] /= sum_exp
    
    # Sort indices by probability (simple bubble sort for now)
    var indices = UnsafePointer[Int].alloc(vocab_size)
    for i in range(vocab_size):
        indices[i] = i
    
    # Bubble sort (replace with better sort for production)
    for i in range(vocab_size):
        for j in range(i + 1, vocab_size):
            if logits[indices[j]] > logits[indices[i]]:
                var tmp = indices[i]
                indices[i] = indices[j]
                indices[j] = tmp
    
    # Zero out tokens beyond top_p cumulative probability
    var cumulative: Scalar[FloatType] = 0
    for i in range(vocab_size):
        var idx = indices[i]
        cumulative += logits[idx]
        if cumulative > top_p:
            # Zero remaining
            for j in range(i + 1, vocab_size):
                logits[indices[j]] = 0
            break
    
    indices.free()


fn apply_repetition_penalty(
    logits: UnsafePointer[Scalar[FloatType]],
    vocab_size: Int,
    past_tokens: UnsafePointer[Int],
    num_past: Int,
    penalty: Scalar[FloatType]
):
    """
    Apply repetition penalty to discourage repeated tokens.
    
    Args:
        logits: Logit values (modified in-place)
        vocab_size: Vocabulary size
        past_tokens: Previously generated tokens
        num_past: Number of past tokens
        penalty: Penalty factor (> 1.0 discourages repetition)
    """
    for i in range(num_past):
        var token_id = past_tokens[i]
        if token_id >= 0 and token_id < vocab_size:
            if logits[token_id] > 0:
                logits[token_id] /= penalty
            else:
                logits[token_id] *= penalty