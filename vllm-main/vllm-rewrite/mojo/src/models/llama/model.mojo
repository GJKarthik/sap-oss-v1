"""
LLaMA Model Implementation

Full implementation of the LLaMA model architecture in Mojo.
Supports LLaMA 1, 2, 3, and compatible models (Mistral, Qwen, etc.).
"""

from tensor import Tensor, TensorShape
from algorithm import vectorize, parallelize

from ...layers.attention import MultiHeadAttention, AttentionConfig, KVCache
from ...layers.linear import Linear, LinearConfig, ColumnParallelLinear, RowParallelLinear
from ...layers.linear import QKVParallelLinear, MergedColumnParallelLinear
from ...layers.normalization import RMSNorm
from ...layers.activations import silu_and_mul, ActivationType


# ==============================================
# Model Configuration
# ==============================================

struct LlamaConfig:
    """Configuration for LLaMA models."""
    
    var hidden_size: Int
    var intermediate_size: Int
    var num_hidden_layers: Int
    var num_attention_heads: Int
    var num_key_value_heads: Int  # For GQA
    var vocab_size: Int
    var max_position_embeddings: Int
    var rope_theta: Float32
    var rope_scaling: Float32
    var rms_norm_eps: Float32
    var tie_word_embeddings: Bool
    var use_sliding_window: Bool
    var sliding_window_size: Int
    
    fn __init__(
        inout self,
        hidden_size: Int = 4096,
        intermediate_size: Int = 11008,
        num_hidden_layers: Int = 32,
        num_attention_heads: Int = 32,
        num_key_value_heads: Int = 32,  # Same as heads for MHA, less for GQA
        vocab_size: Int = 32000,
        max_position_embeddings: Int = 4096,
        rope_theta: Float32 = 10000.0,
        rope_scaling: Float32 = 1.0,
        rms_norm_eps: Float32 = 1e-6,
        tie_word_embeddings: Bool = False,
        use_sliding_window: Bool = False,
        sliding_window_size: Int = 4096,
    ):
        self.hidden_size = hidden_size
        self.intermediate_size = intermediate_size
        self.num_hidden_layers = num_hidden_layers
        self.num_attention_heads = num_attention_heads
        self.num_key_value_heads = num_key_value_heads
        self.vocab_size = vocab_size
        self.max_position_embeddings = max_position_embeddings
        self.rope_theta = rope_theta
        self.rope_scaling = rope_scaling
        self.rms_norm_eps = rms_norm_eps
        self.tie_word_embeddings = tie_word_embeddings
        self.use_sliding_window = use_sliding_window
        self.sliding_window_size = sliding_window_size
    
    fn head_dim(self) -> Int:
        return self.hidden_size // self.num_attention_heads
    
    fn is_gqa(self) -> Bool:
        """Check if using Grouped Query Attention."""
        return self.num_key_value_heads < self.num_attention_heads
    
    @staticmethod
    fn llama2_7b() -> LlamaConfig:
        """LLaMA 2 7B configuration."""
        return LlamaConfig(
            hidden_size=4096,
            intermediate_size=11008,
            num_hidden_layers=32,
            num_attention_heads=32,
            num_key_value_heads=32,
            vocab_size=32000,
        )
    
    @staticmethod
    fn llama2_13b() -> LlamaConfig:
        """LLaMA 2 13B configuration."""
        return LlamaConfig(
            hidden_size=5120,
            intermediate_size=13824,
            num_hidden_layers=40,
            num_attention_heads=40,
            num_key_value_heads=40,
            vocab_size=32000,
        )
    
    @staticmethod
    fn llama2_70b() -> LlamaConfig:
        """LLaMA 2 70B configuration with GQA."""
        return LlamaConfig(
            hidden_size=8192,
            intermediate_size=28672,
            num_hidden_layers=80,
            num_attention_heads=64,
            num_key_value_heads=8,  # GQA with 8 KV heads
            vocab_size=32000,
        )
    
    @staticmethod
    fn llama3_8b() -> LlamaConfig:
        """LLaMA 3 8B configuration."""
        return LlamaConfig(
            hidden_size=4096,
            intermediate_size=14336,
            num_hidden_layers=32,
            num_attention_heads=32,
            num_key_value_heads=8,  # GQA
            vocab_size=128256,
            rope_theta=500000.0,
        )
    
    @staticmethod
    fn llama3_70b() -> LlamaConfig:
        """LLaMA 3 70B configuration."""
        return LlamaConfig(
            hidden_size=8192,
            intermediate_size=28672,
            num_hidden_layers=80,
            num_attention_heads=64,
            num_key_value_heads=8,  # GQA
            vocab_size=128256,
            rope_theta=500000.0,
        )


# ==============================================
# Rotary Position Embedding (RoPE)
# ==============================================

struct RotaryEmbedding:
    """
    Rotary Position Embedding (RoPE).
    
    Encodes position information directly into Q and K vectors.
    """
    
    var dim: Int
    var max_seq_len: Int
    var base: Float32
    var cos_cached: Tensor[DType.float16]
    var sin_cached: Tensor[DType.float16]
    
    fn __init__(
        inout self,
        dim: Int,
        max_seq_len: Int = 4096,
        base: Float32 = 10000.0,
    ):
        self.dim = dim
        self.max_seq_len = max_seq_len
        self.base = base
        
        # Pre-compute cos and sin values
        self.cos_cached = Tensor[DType.float16](max_seq_len, dim // 2)
        self.sin_cached = Tensor[DType.float16](max_seq_len, dim // 2)
        
        self._compute_cache()
    
    fn _compute_cache(inout self):
        """Pre-compute cos and sin values for all positions."""
        let half_dim = self.dim // 2
        
        for pos in range(self.max_seq_len):
            for i in range(half_dim):
                let freq = 1.0 / pow(self.base, Float32(2 * i) / Float32(self.dim))
                let angle = Float32(pos) * freq
                self.cos_cached.store(pos, i, cos(angle).cast[DType.float16]())
                self.sin_cached.store(pos, i, sin(angle).cast[DType.float16]())
    
    fn forward(
        self,
        q: Tensor[DType.float16],
        k: Tensor[DType.float16],
        positions: Tensor[DType.int32],
    ) -> Tuple[Tensor[DType.float16], Tensor[DType.float16]]:
        """
        Apply rotary embedding to Q and K tensors.
        
        Args:
            q: Query tensor [batch, seq, heads, head_dim]
            k: Key tensor [batch, seq, kv_heads, head_dim]
            positions: Position indices [batch, seq]
        
        Returns:
            Rotated (q, k) tensors
        """
        let batch_size = q.shape()[0]
        let seq_len = q.shape()[1]
        
        var q_rot = Tensor[DType.float16](q.shape())
        var k_rot = Tensor[DType.float16](k.shape())
        
        # Apply rotation
        for b in range(batch_size):
            for s in range(seq_len):
                let pos = positions[b, s].cast[DType.int64]()
                self._apply_rotary(q, q_rot, b, s, pos)
                self._apply_rotary(k, k_rot, b, s, pos)
        
        return (q_rot, k_rot)
    
    fn _apply_rotary(
        self,
        x: Tensor[DType.float16],
        out: Tensor[DType.float16],
        batch: Int,
        seq: Int,
        pos: Int,
    ):
        """Apply rotary embedding to a single position."""
        let num_heads = x.shape()[2]
        let head_dim = x.shape()[3]
        let half_dim = head_dim // 2
        
        for h in range(num_heads):
            for i in range(half_dim):
                let cos_val = self.cos_cached[pos, i]
                let sin_val = self.sin_cached[pos, i]
                
                let x0 = x[batch, seq, h, i]
                let x1 = x[batch, seq, h, i + half_dim]
                
                # Rotation formula
                out.store(batch, seq, h, i, x0 * cos_val - x1 * sin_val)
                out.store(batch, seq, h, i + half_dim, x0 * sin_val + x1 * cos_val)


# ==============================================
# LLaMA MLP (Feed-Forward Network)
# ==============================================

struct LlamaMLP:
    """
    LLaMA MLP (SwiGLU variant).
    
    output = down_proj(silu(gate_proj(x)) * up_proj(x))
    """
    
    var config: LlamaConfig
    var gate_up_proj: MergedColumnParallelLinear
    var down_proj: RowParallelLinear
    var tp_size: Int
    
    fn __init__(inout self, config: LlamaConfig, tp_size: Int = 1):
        self.config = config
        self.tp_size = tp_size
        
        # Merged gate and up projections
        self.gate_up_proj = MergedColumnParallelLinear(
            config.hidden_size,
            config.intermediate_size,
            tp_size,
        )
        
        # Down projection
        let down_config = LinearConfig(
            config.intermediate_size,
            config.hidden_size,
            bias=False,
        )
        self.down_proj = RowParallelLinear(down_config, tp_size)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """
        Forward pass.
        
        Args:
            x: Input tensor [batch, seq, hidden]
        
        Returns:
            Output tensor [batch, seq, hidden]
        """
        # Fused gate and up projection
        let (gate, up) = self.gate_up_proj.forward(x)
        
        # SiLU activation and multiplication
        let intermediate = silu_and_mul(up, gate)
        
        # Down projection
        return self.down_proj.forward(intermediate)


# ==============================================
# LLaMA Attention
# ==============================================

struct LlamaAttention:
    """
    LLaMA attention with RoPE and KV-cache support.
    """
    
    var config: LlamaConfig
    var qkv_proj: QKVParallelLinear
    var o_proj: RowParallelLinear
    var rotary_emb: RotaryEmbedding
    var tp_size: Int
    var tp_rank: Int
    
    fn __init__(
        inout self,
        config: LlamaConfig,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.tp_size = tp_size
        self.tp_rank = tp_rank
        
        let head_dim = config.head_dim()
        let local_heads = config.num_attention_heads // tp_size
        let local_kv_heads = config.num_key_value_heads // tp_size
        
        # QKV projection
        self.qkv_proj = QKVParallelLinear(
            config.hidden_size,
            local_heads,
            local_kv_heads,
            head_dim,
            bias=False,
        )
        
        # Output projection
        let o_config = LinearConfig(
            config.num_attention_heads * head_dim,
            config.hidden_size,
            bias=False,
        )
        self.o_proj = RowParallelLinear(o_config, tp_size)
        
        # Rotary embedding
        self.rotary_emb = RotaryEmbedding(
            head_dim,
            config.max_position_embeddings,
            config.rope_theta,
        )
    
    fn forward(
        self,
        hidden_states: Tensor[DType.float16],
        positions: Tensor[DType.int32],
        kv_cache: KVCache,
    ) -> Tensor[DType.float16]:
        """
        Forward pass with KV-cache.
        
        Args:
            hidden_states: Input [batch, seq, hidden]
            positions: Position indices [batch, seq]
            kv_cache: KV cache for this layer
        
        Returns:
            Output tensor [batch, seq, hidden]
        """
        let batch_size = hidden_states.shape()[0]
        let seq_len = hidden_states.shape()[1]
        let head_dim = self.config.head_dim()
        
        # QKV projection
        let (q, k, v) = self.qkv_proj.forward(hidden_states)
        
        # Reshape for attention
        let local_heads = self.config.num_attention_heads // self.tp_size
        let local_kv_heads = self.config.num_key_value_heads // self.tp_size
        
        var q_reshaped = q.reshape(batch_size, seq_len, local_heads, head_dim)
        var k_reshaped = k.reshape(batch_size, seq_len, local_kv_heads, head_dim)
        var v_reshaped = v.reshape(batch_size, seq_len, local_kv_heads, head_dim)
        
        # Apply rotary embedding
        let (q_rot, k_rot) = self.rotary_emb.forward(q_reshaped, k_reshaped, positions)
        
        # Update KV cache
        kv_cache.update(k_rot, v_reshaped, positions)
        
        # Get full K, V from cache
        let (k_full, v_full) = kv_cache.get()
        
        # Compute attention
        let attn_output = self._compute_attention(q_rot, k_full, v_full)
        
        # Output projection
        let output = attn_output.reshape(batch_size, seq_len, -1)
        return self.o_proj.forward(output)
    
    fn _compute_attention(
        self,
        q: Tensor[DType.float16],
        k: Tensor[DType.float16],
        v: Tensor[DType.float16],
    ) -> Tensor[DType.float16]:
        """Compute scaled dot-product attention."""
        let head_dim = self.config.head_dim()
        let scale = 1.0 / sqrt(Float32(head_dim))
        
        # Q @ K^T
        let scores = q @ k.transpose(-2, -1) * scale
        
        # Softmax
        let attn_weights = softmax(scores, axis=-1)
        
        # Attention @ V
        return attn_weights @ v


# ==============================================
# LLaMA Decoder Layer
# ==============================================

struct LlamaDecoderLayer:
    """Single LLaMA decoder layer."""
    
    var config: LlamaConfig
    var layer_idx: Int
    var self_attn: LlamaAttention
    var mlp: LlamaMLP
    var input_layernorm: RMSNorm
    var post_attention_layernorm: RMSNorm
    
    fn __init__(
        inout self,
        config: LlamaConfig,
        layer_idx: Int,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.layer_idx = layer_idx
        
        self.self_attn = LlamaAttention(config, tp_size, tp_rank)
        self.mlp = LlamaMLP(config, tp_size)
        self.input_layernorm = RMSNorm(config.hidden_size, config.rms_norm_eps)
        self.post_attention_layernorm = RMSNorm(config.hidden_size, config.rms_norm_eps)
    
    fn forward(
        self,
        hidden_states: Tensor[DType.float16],
        positions: Tensor[DType.int32],
        kv_cache: KVCache,
    ) -> Tensor[DType.float16]:
        """
        Forward pass.
        
        Args:
            hidden_states: Input [batch, seq, hidden]
            positions: Position indices
            kv_cache: KV cache for this layer
        
        Returns:
            Output tensor [batch, seq, hidden]
        """
        # Self-attention with residual
        let normed = self.input_layernorm.forward(hidden_states)
        let attn_output = self.self_attn.forward(normed, positions, kv_cache)
        var hidden = hidden_states + attn_output
        
        # MLP with residual
        let normed_mlp = self.post_attention_layernorm.forward(hidden)
        let mlp_output = self.mlp.forward(normed_mlp)
        hidden = hidden + mlp_output
        
        return hidden


# ==============================================
# LLaMA Model
# ==============================================

struct LlamaModel:
    """
    Full LLaMA model.
    
    Consists of:
    - Token embedding
    - N decoder layers
    - Final RMSNorm
    - LM head (optional, can share embedding weights)
    """
    
    var config: LlamaConfig
    var embed_tokens: Tensor[DType.float16]  # Embedding weights
    var layers: List[LlamaDecoderLayer]
    var norm: RMSNorm
    var lm_head: Linear
    var tp_size: Int
    var tp_rank: Int
    
    fn __init__(
        inout self,
        config: LlamaConfig,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.tp_size = tp_size
        self.tp_rank = tp_rank
        
        # Token embedding
        self.embed_tokens = Tensor[DType.float16](config.vocab_size, config.hidden_size)
        
        # Decoder layers
        self.layers = List[LlamaDecoderLayer]()
        for i in range(config.num_hidden_layers):
            self.layers.append(LlamaDecoderLayer(config, i, tp_size, tp_rank))
        
        # Final norm
        self.norm = RMSNorm(config.hidden_size, config.rms_norm_eps)
        
        # LM head
        let lm_config = LinearConfig(
            config.hidden_size,
            config.vocab_size,
            bias=False,
        )
        self.lm_head = Linear(lm_config)
    
    fn forward(
        self,
        input_ids: Tensor[DType.int32],
        positions: Tensor[DType.int32],
        kv_caches: List[KVCache],
    ) -> Tensor[DType.float16]:
        """
        Forward pass.
        
        Args:
            input_ids: Token IDs [batch, seq]
            positions: Position indices [batch, seq]
            kv_caches: List of KV caches for each layer
        
        Returns:
            Logits tensor [batch, seq, vocab_size]
        """
        let batch_size = input_ids.shape()[0]
        let seq_len = input_ids.shape()[1]
        
        # Token embedding lookup
        var hidden_states = self._embed(input_ids)
        
        # Decoder layers
        for i in range(self.config.num_hidden_layers):
            hidden_states = self.layers[i].forward(
                hidden_states,
                positions,
                kv_caches[i],
            )
        
        # Final norm
        hidden_states = self.norm.forward(hidden_states)
        
        # LM head
        let logits = self.lm_head.forward(hidden_states)
        
        return logits
    
    fn _embed(self, input_ids: Tensor[DType.int32]) -> Tensor[DType.float16]:
        """Lookup token embeddings."""
        let batch_size = input_ids.shape()[0]
        let seq_len = input_ids.shape()[1]
        
        var embeddings = Tensor[DType.float16](batch_size, seq_len, self.config.hidden_size)
        
        for b in range(batch_size):
            for s in range(seq_len):
                let token_id = input_ids[b, s].cast[DType.int64]()
                for h in range(self.config.hidden_size):
                    embeddings.store(b, s, h, self.embed_tokens[token_id, h])
        
        return embeddings
    
    fn sample_next_token(
        self,
        logits: Tensor[DType.float16],
        temperature: Float32 = 1.0,
        top_p: Float32 = 1.0,
        top_k: Int = -1,
    ) -> Tensor[DType.int32]:
        """
        Sample next token from logits.
        
        Args:
            logits: Logits [batch, 1, vocab] (last position)
            temperature: Sampling temperature
            top_p: Nucleus sampling probability
            top_k: Top-k sampling (-1 for no limit)
        
        Returns:
            Sampled token IDs [batch]
        """
        let batch_size = logits.shape()[0]
        var next_tokens = Tensor[DType.int32](batch_size)
        
        for b in range(batch_size):
            # Get logits for last position
            let token_logits = logits[b, -1, :]
            
            # Apply temperature
            var scaled_logits = token_logits / temperature
            
            # Convert to probabilities
            let probs = softmax(scaled_logits)
            
            # Sample (argmax for greedy, or categorical for sampling)
            let sampled = argmax(probs)
            next_tokens.store(b, sampled.cast[DType.int32]())
        
        return next_tokens
    
    fn num_parameters(self) -> Int:
        """Calculate total number of parameters."""
        var params = 0
        
        # Embedding
        params += self.config.vocab_size * self.config.hidden_size
        
        # Each decoder layer
        let head_dim = self.config.head_dim()
        let qkv_size = (
            self.config.num_attention_heads * head_dim +
            2 * self.config.num_key_value_heads * head_dim
        )
        
        for _ in range(self.config.num_hidden_layers):
            # QKV projection
            params += self.config.hidden_size * qkv_size
            # Output projection
            params += self.config.num_attention_heads * head_dim * self.config.hidden_size
            # MLP
            params += self.config.hidden_size * self.config.intermediate_size * 3
            # LayerNorms (2 per layer)
            params += 2 * self.config.hidden_size
        
        # Final norm
        params += self.config.hidden_size
        
        # LM head (unless tied)
        if not self.config.tie_word_embeddings:
            params += self.config.hidden_size * self.config.vocab_size
        
        return params