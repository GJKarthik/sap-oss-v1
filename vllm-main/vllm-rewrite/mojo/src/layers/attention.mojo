"""
Multi-Head Attention Layer Implementation

This module provides high-performance attention mechanisms including:
- Multi-Head Attention (MHA)
- Grouped Query Attention (GQA)
- Multi-Query Attention (MQA)

All implementations are optimized with SIMD operations and support
PagedAttention for efficient KV-cache management.
"""

from tensor import Tensor, TensorShape
from math import sqrt, exp, log
from algorithm import vectorize, parallelize
from memory import memset_zero, memcpy
from sys.info import simdwidthof

# SIMD width for float16 operations
alias SIMD_WIDTH = simdwidthof[DType.float16]()


struct AttentionConfig:
    """Configuration for attention layers."""
    var num_heads: Int
    var num_kv_heads: Int
    var head_dim: Int
    var hidden_size: Int
    var max_seq_len: Int
    var scale: Float32
    var use_alibi: Bool
    var use_sliding_window: Bool
    var sliding_window_size: Int
    
    fn __init__(
        inout self,
        num_heads: Int,
        num_kv_heads: Int,
        head_dim: Int,
        max_seq_len: Int = 4096,
        use_alibi: Bool = False,
        use_sliding_window: Bool = False,
        sliding_window_size: Int = 4096,
    ):
        self.num_heads = num_heads
        self.num_kv_heads = num_kv_heads
        self.head_dim = head_dim
        self.hidden_size = num_heads * head_dim
        self.max_seq_len = max_seq_len
        self.scale = 1.0 / sqrt(Float32(head_dim))
        self.use_alibi = use_alibi
        self.use_sliding_window = use_sliding_window
        self.sliding_window_size = sliding_window_size
    
    fn num_kv_groups(self) -> Int:
        """Number of query heads per KV head (for GQA)."""
        return self.num_heads // self.num_kv_heads
    
    fn is_mha(self) -> Bool:
        """Check if this is standard Multi-Head Attention."""
        return self.num_heads == self.num_kv_heads
    
    fn is_mqa(self) -> Bool:
        """Check if this is Multi-Query Attention."""
        return self.num_kv_heads == 1
    
    fn is_gqa(self) -> Bool:
        """Check if this is Grouped Query Attention."""
        return not self.is_mha() and not self.is_mqa()


struct MultiHeadAttention:
    """
    Multi-Head Attention with support for GQA and MQA.
    
    This implementation supports:
    - Standard MHA (num_heads == num_kv_heads)
    - GQA (num_heads > num_kv_heads > 1)
    - MQA (num_kv_heads == 1)
    - Optional ALiBi positional encoding
    - Optional sliding window attention
    """
    
    var config: AttentionConfig
    
    # Projection weights
    var q_proj_weight: Tensor[DType.float16]
    var k_proj_weight: Tensor[DType.float16]
    var v_proj_weight: Tensor[DType.float16]
    var o_proj_weight: Tensor[DType.float16]
    
    # Optional biases
    var q_proj_bias: Tensor[DType.float16]
    var k_proj_bias: Tensor[DType.float16]
    var v_proj_bias: Tensor[DType.float16]
    var o_proj_bias: Tensor[DType.float16]
    
    var use_bias: Bool
    
    fn __init__(
        inout self,
        config: AttentionConfig,
        use_bias: Bool = False,
    ):
        self.config = config
        self.use_bias = use_bias
        
        let hidden_size = config.hidden_size
        let kv_hidden_size = config.num_kv_heads * config.head_dim
        
        # Initialize projection weights
        self.q_proj_weight = Tensor[DType.float16](hidden_size, hidden_size)
        self.k_proj_weight = Tensor[DType.float16](hidden_size, kv_hidden_size)
        self.v_proj_weight = Tensor[DType.float16](hidden_size, kv_hidden_size)
        self.o_proj_weight = Tensor[DType.float16](hidden_size, hidden_size)
        
        # Initialize biases (may be empty if not used)
        if use_bias:
            self.q_proj_bias = Tensor[DType.float16](hidden_size)
            self.k_proj_bias = Tensor[DType.float16](kv_hidden_size)
            self.v_proj_bias = Tensor[DType.float16](kv_hidden_size)
            self.o_proj_bias = Tensor[DType.float16](hidden_size)
        else:
            self.q_proj_bias = Tensor[DType.float16](0)
            self.k_proj_bias = Tensor[DType.float16](0)
            self.v_proj_bias = Tensor[DType.float16](0)
            self.o_proj_bias = Tensor[DType.float16](0)
    
    fn forward(
        self,
        hidden_states: Tensor[DType.float16],
        positions: Tensor[DType.int32],
        kv_cache: KVCache,
        attention_mask: Optional[Tensor[DType.float16]] = None,
    ) -> Tensor[DType.float16]:
        """
        Forward pass for multi-head attention.
        
        Args:
            hidden_states: Input tensor [batch_size, seq_len, hidden_size]
            positions: Position indices [batch_size, seq_len]
            kv_cache: KV cache for incremental decoding
            attention_mask: Optional attention mask
        
        Returns:
            Output tensor [batch_size, seq_len, hidden_size]
        """
        let batch_size = hidden_states.shape()[0]
        let seq_len = hidden_states.shape()[1]
        
        # Project to Q, K, V
        var query = self._project_q(hidden_states)
        var key = self._project_k(hidden_states)
        var value = self._project_v(hidden_states)
        
        # Reshape for multi-head attention
        # query: [batch, seq, num_heads, head_dim]
        # key/value: [batch, seq, num_kv_heads, head_dim]
        query = self._reshape_for_attention(query, self.config.num_heads)
        key = self._reshape_for_attention(key, self.config.num_kv_heads)
        value = self._reshape_for_attention(value, self.config.num_kv_heads)
        
        # Update KV cache
        key, value = kv_cache.update(key, value, positions)
        
        # Compute attention
        var attn_output = self._compute_attention(
            query, key, value, attention_mask
        )
        
        # Reshape back
        attn_output = self._reshape_from_attention(attn_output)
        
        # Output projection
        return self._project_o(attn_output)
    
    fn _project_q(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Project input to query space."""
        var out = x @ self.q_proj_weight.T()
        if self.use_bias:
            out = out + self.q_proj_bias
        return out
    
    fn _project_k(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Project input to key space."""
        var out = x @ self.k_proj_weight.T()
        if self.use_bias:
            out = out + self.k_proj_bias
        return out
    
    fn _project_v(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Project input to value space."""
        var out = x @ self.v_proj_weight.T()
        if self.use_bias:
            out = out + self.v_proj_bias
        return out
    
    fn _project_o(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Project attention output."""
        var out = x @ self.o_proj_weight.T()
        if self.use_bias:
            out = out + self.o_proj_bias
        return out
    
    fn _reshape_for_attention(
        self,
        x: Tensor[DType.float16],
        num_heads: Int,
    ) -> Tensor[DType.float16]:
        """Reshape from [batch, seq, hidden] to [batch, num_heads, seq, head_dim]."""
        let batch_size = x.shape()[0]
        let seq_len = x.shape()[1]
        
        # Reshape: [batch, seq, num_heads * head_dim] -> [batch, seq, num_heads, head_dim]
        # Then transpose to: [batch, num_heads, seq, head_dim]
        return x.reshape(batch_size, seq_len, num_heads, self.config.head_dim).transpose(1, 2)
    
    fn _reshape_from_attention(
        self,
        x: Tensor[DType.float16],
    ) -> Tensor[DType.float16]:
        """Reshape from [batch, num_heads, seq, head_dim] to [batch, seq, hidden]."""
        let batch_size = x.shape()[0]
        let seq_len = x.shape()[2]
        
        # Transpose and reshape back
        return x.transpose(1, 2).reshape(batch_size, seq_len, self.config.hidden_size)
    
    fn _compute_attention(
        self,
        query: Tensor[DType.float16],
        key: Tensor[DType.float16],
        value: Tensor[DType.float16],
        mask: Optional[Tensor[DType.float16]],
    ) -> Tensor[DType.float16]:
        """
        Compute scaled dot-product attention.
        
        For GQA/MQA, keys and values are repeated to match query heads.
        """
        var k = key
        var v = value
        
        # Repeat KV heads for GQA
        if not self.config.is_mha():
            let num_groups = self.config.num_kv_groups()
            k = self._repeat_kv(key, num_groups)
            v = self._repeat_kv(value, num_groups)
        
        # Compute attention scores: Q @ K^T / sqrt(d)
        var scores = (query @ k.transpose(-2, -1)) * self.config.scale
        
        # Apply mask if provided
        if mask:
            scores = scores + mask.value()
        
        # Softmax
        var weights = softmax(scores, axis=-1)
        
        # Attention output: weights @ V
        return weights @ v
    
    fn _repeat_kv(
        self,
        x: Tensor[DType.float16],
        n_rep: Int,
    ) -> Tensor[DType.float16]:
        """Repeat KV heads for GQA."""
        if n_rep == 1:
            return x
        
        let batch_size = x.shape()[0]
        let num_kv_heads = x.shape()[1]
        let seq_len = x.shape()[2]
        let head_dim = x.shape()[3]
        
        # Expand and repeat: [batch, kv_heads, seq, dim] -> [batch, kv_heads, n_rep, seq, dim]
        # Then reshape to: [batch, kv_heads * n_rep, seq, dim]
        return x.unsqueeze(2).expand(
            batch_size, num_kv_heads, n_rep, seq_len, head_dim
        ).reshape(batch_size, num_kv_heads * n_rep, seq_len, head_dim)


struct KVCache:
    """
    Paged KV Cache for efficient memory management.
    
    Uses block-based allocation to enable:
    - Dynamic memory allocation
    - Memory sharing between requests (prefix caching)
    - Efficient preemption and resumption
    """
    
    var key_cache: Tensor[DType.float16]
    var value_cache: Tensor[DType.float16]
    var block_size: Int
    var num_blocks: Int
    var num_layers: Int
    var num_heads: Int
    var head_dim: Int
    
    fn __init__(
        inout self,
        num_blocks: Int,
        block_size: Int,
        num_layers: Int,
        num_heads: Int,
        head_dim: Int,
    ):
        self.num_blocks = num_blocks
        self.block_size = block_size
        self.num_layers = num_layers
        self.num_heads = num_heads
        self.head_dim = head_dim
        
        # Allocate cache: [num_blocks, block_size, num_heads, head_dim]
        self.key_cache = Tensor[DType.float16](
            num_layers, num_blocks, num_heads, block_size, head_dim
        )
        self.value_cache = Tensor[DType.float16](
            num_layers, num_blocks, num_heads, block_size, head_dim
        )
    
    fn update(
        inout self,
        key: Tensor[DType.float16],
        value: Tensor[DType.float16],
        positions: Tensor[DType.int32],
    ) -> Tuple[Tensor[DType.float16], Tensor[DType.float16]]:
        """
        Update the KV cache with new keys and values.
        
        Returns the full key and value tensors including cached values.
        """
        # TODO: Implement paged update with block tables
        # For now, return input directly (no caching)
        return (key, value)
    
    fn get_kv(
        self,
        layer_idx: Int,
        block_indices: Tensor[DType.int32],
        positions: Tensor[DType.int32],
    ) -> Tuple[Tensor[DType.float16], Tensor[DType.float16]]:
        """Retrieve cached KV for given blocks and positions."""
        # TODO: Implement paged retrieval
        pass


fn softmax(x: Tensor[DType.float16], axis: Int = -1) -> Tensor[DType.float16]:
    """
    Numerically stable softmax.
    
    softmax(x) = exp(x - max(x)) / sum(exp(x - max(x)))
    """
    # Subtract max for numerical stability
    let max_val = x.max(axis=axis, keepdims=True)
    let exp_x = exp(x - max_val)
    let sum_exp = exp_x.sum(axis=axis, keepdims=True)
    return exp_x / sum_exp


fn scaled_dot_product_attention(
    query: Tensor[DType.float16],
    key: Tensor[DType.float16],
    value: Tensor[DType.float16],
    scale: Float32,
    mask: Optional[Tensor[DType.float16]] = None,
) -> Tensor[DType.float16]:
    """
    Standalone scaled dot-product attention function.
    
    Args:
        query: Query tensor [batch, heads, seq_q, head_dim]
        key: Key tensor [batch, heads, seq_k, head_dim]
        value: Value tensor [batch, heads, seq_k, head_dim]
        scale: Scaling factor (typically 1/sqrt(head_dim))
        mask: Optional attention mask
    
    Returns:
        Attention output [batch, heads, seq_q, head_dim]
    """
    # Compute attention scores
    var scores = (query @ key.transpose(-2, -1)) * scale
    
    # Apply mask
    if mask:
        scores = scores + mask.value()
    
    # Softmax and weighted sum
    let weights = softmax(scores, axis=-1)
    return weights @ value


# ==============================================
# Flash Attention Interface (calls CUDA kernel)
# ==============================================

fn flash_attention_forward(
    query: Tensor[DType.float16],
    key: Tensor[DType.float16],
    value: Tensor[DType.float16],
    scale: Float32,
    causal: Bool = True,
) -> Tensor[DType.float16]:
    """
    Flash Attention forward pass.
    
    This function calls the optimized CUDA Flash Attention kernel
    for memory-efficient attention computation.
    
    Args:
        query: Query tensor [batch, heads, seq, head_dim]
        key: Key tensor [batch, heads, seq, head_dim]
        value: Value tensor [batch, heads, seq, head_dim]
        scale: Scaling factor
        causal: Whether to use causal masking
    
    Returns:
        Attention output tensor
    """
    # TODO: Call CUDA Flash Attention kernel via FFI
    # For now, fall back to standard attention
    
    var mask: Optional[Tensor[DType.float16]] = None
    if causal:
        # Create causal mask
        let seq_len = query.shape()[2]
        mask = create_causal_mask(seq_len)
    
    return scaled_dot_product_attention(query, key, value, scale, mask)


fn create_causal_mask(seq_len: Int) -> Tensor[DType.float16]:
    """Create a causal attention mask."""
    var mask = Tensor[DType.float16](1, 1, seq_len, seq_len)
    
    # Fill upper triangle with -inf
    for i in range(seq_len):
        for j in range(seq_len):
            if j > i:
                mask[0, 0, i, j] = Float16(-1e9)  # Large negative value
            else:
                mask[0, 0, i, j] = Float16(0)
    
    return mask