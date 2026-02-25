"""
Qwen Model Implementation

Full implementation of the Qwen (Tongyi Qianwen) model architecture.
Supports Qwen 1.5, Qwen 2, and Qwen 2.5 variants.

Key features:
- Partial Rotary Position Embedding (applied to portion of head_dim)
- Optional bias in attention
- SwiGLU activation
- GQA for larger models
"""

from tensor import Tensor, TensorShape
from algorithm import vectorize, parallelize

from ...layers.attention import MultiHeadAttention, AttentionConfig, KVCache
from ...layers.linear import Linear, LinearConfig, RowParallelLinear
from ...layers.linear import QKVParallelLinear, MergedColumnParallelLinear
from ...layers.normalization import RMSNorm
from ...layers.activations import silu_and_mul
from ..llama.model import RotaryEmbedding


# ==============================================
# Qwen Configuration
# ==============================================

struct QwenConfig:
    """Configuration for Qwen models."""
    
    var hidden_size: Int
    var intermediate_size: Int
    var num_hidden_layers: Int
    var num_attention_heads: Int
    var num_key_value_heads: Int
    var vocab_size: Int
    var max_position_embeddings: Int
    var rope_theta: Float32
    var rms_norm_eps: Float32
    var tie_word_embeddings: Bool
    
    # Qwen-specific: partial rotary embedding
    var rope_ratio: Float32  # Portion of head_dim to apply RoPE (default 1.0 = full)
    var use_bias: Bool       # Whether to use bias in attention
    var use_sliding_window: Bool
    var sliding_window: Int
    
    fn __init__(
        inout self,
        hidden_size: Int = 4096,
        intermediate_size: Int = 11008,
        num_hidden_layers: Int = 32,
        num_attention_heads: Int = 32,
        num_key_value_heads: Int = 32,
        vocab_size: Int = 151936,  # Qwen uses larger vocab
        max_position_embeddings: Int = 32768,
        rope_theta: Float32 = 1000000.0,  # Qwen uses larger rope_theta
        rms_norm_eps: Float32 = 1e-6,
        tie_word_embeddings: Bool = False,
        rope_ratio: Float32 = 1.0,
        use_bias: Bool = True,
        use_sliding_window: Bool = False,
        sliding_window: Int = 32768,
    ):
        self.hidden_size = hidden_size
        self.intermediate_size = intermediate_size
        self.num_hidden_layers = num_hidden_layers
        self.num_attention_heads = num_attention_heads
        self.num_key_value_heads = num_key_value_heads
        self.vocab_size = vocab_size
        self.max_position_embeddings = max_position_embeddings
        self.rope_theta = rope_theta
        self.rms_norm_eps = rms_norm_eps
        self.tie_word_embeddings = tie_word_embeddings
        self.rope_ratio = rope_ratio
        self.use_bias = use_bias
        self.use_sliding_window = use_sliding_window
        self.sliding_window = sliding_window
    
    fn head_dim(self) -> Int:
        return self.hidden_size // self.num_attention_heads
    
    fn rope_dim(self) -> Int:
        """Dimension to apply RoPE to."""
        return Int(self.head_dim() * self.rope_ratio)
    
    fn is_gqa(self) -> Bool:
        return self.num_key_value_heads < self.num_attention_heads
    
    @staticmethod
    fn qwen2_0_5b() -> QwenConfig:
        """Qwen 2 0.5B configuration."""
        return QwenConfig(
            hidden_size=896,
            intermediate_size=4864,
            num_hidden_layers=24,
            num_attention_heads=14,
            num_key_value_heads=2,
            vocab_size=151936,
            max_position_embeddings=32768,
            rope_theta=1000000.0,
        )
    
    @staticmethod
    fn qwen2_1_5b() -> QwenConfig:
        """Qwen 2 1.5B configuration."""
        return QwenConfig(
            hidden_size=1536,
            intermediate_size=8960,
            num_hidden_layers=28,
            num_attention_heads=12,
            num_key_value_heads=2,
            vocab_size=151936,
            max_position_embeddings=32768,
        )
    
    @staticmethod
    fn qwen2_7b() -> QwenConfig:
        """Qwen 2 7B configuration."""
        return QwenConfig(
            hidden_size=3584,
            intermediate_size=18944,
            num_hidden_layers=28,
            num_attention_heads=28,
            num_key_value_heads=4,
            vocab_size=151936,
            max_position_embeddings=131072,
            rope_theta=1000000.0,
        )
    
    @staticmethod
    fn qwen2_72b() -> QwenConfig:
        """Qwen 2 72B configuration."""
        return QwenConfig(
            hidden_size=8192,
            intermediate_size=29568,
            num_hidden_layers=80,
            num_attention_heads=64,
            num_key_value_heads=8,
            vocab_size=152064,
            max_position_embeddings=131072,
            rope_theta=1000000.0,
        )
    
    @staticmethod
    fn qwen2_5_72b() -> QwenConfig:
        """Qwen 2.5 72B configuration."""
        return QwenConfig.qwen2_72b()


# ==============================================
# Qwen Rotary Embedding (with partial rotation)
# ==============================================

struct QwenRotaryEmbedding:
    """
    Qwen-style Rotary Embedding.
    
    Can apply RoPE to only a portion of head_dim (controlled by rope_ratio).
    """
    
    var dim: Int
    var rope_dim: Int  # Actual dimension for rotation
    var max_seq_len: Int
    var base: Float32
    var cos_cached: Tensor[DType.float16]
    var sin_cached: Tensor[DType.float16]
    
    fn __init__(
        inout self,
        dim: Int,
        rope_ratio: Float32 = 1.0,
        max_seq_len: Int = 32768,
        base: Float32 = 1000000.0,
    ):
        self.dim = dim
        self.rope_dim = Int(dim * rope_ratio)
        self.max_seq_len = max_seq_len
        self.base = base
        
        self.cos_cached = Tensor[DType.float16](max_seq_len, self.rope_dim // 2)
        self.sin_cached = Tensor[DType.float16](max_seq_len, self.rope_dim // 2)
        
        self._compute_cache()
    
    fn _compute_cache(inout self):
        """Pre-compute cos and sin values."""
        let half_rope_dim = self.rope_dim // 2
        
        for pos in range(self.max_seq_len):
            for i in range(half_rope_dim):
                let freq = 1.0 / pow(self.base, Float32(2 * i) / Float32(self.rope_dim))
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
        Apply partial rotary embedding.
        
        Only the first rope_dim dimensions are rotated.
        """
        let batch_size = q.shape()[0]
        let seq_len = q.shape()[1]
        let num_heads = q.shape()[2]
        let head_dim = q.shape()[3]
        
        var q_rot = Tensor[DType.float16](q.shape())
        var k_rot = Tensor[DType.float16](k.shape())
        
        # Copy original tensors
        memcpy(q_rot.data(), q.data(), q.num_elements() * sizeof[DType.float16]())
        memcpy(k_rot.data(), k.data(), k.num_elements() * sizeof[DType.float16]())
        
        # Apply rotation only to first rope_dim dimensions
        for b in range(batch_size):
            for s in range(seq_len):
                let pos = positions[b, s].cast[DType.int64]()
                self._apply_partial_rotary(q, q_rot, b, s, pos, num_heads, head_dim)
                self._apply_partial_rotary(k, k_rot, b, s, pos, k.shape()[2], head_dim)
        
        return (q_rot, k_rot)
    
    fn _apply_partial_rotary(
        self,
        x: Tensor[DType.float16],
        out: Tensor[DType.float16],
        batch: Int,
        seq: Int,
        pos: Int,
        num_heads: Int,
        head_dim: Int,
    ):
        """Apply rotary embedding to first rope_dim dimensions."""
        let half_rope_dim = self.rope_dim // 2
        
        for h in range(num_heads):
            for i in range(half_rope_dim):
                let cos_val = self.cos_cached[pos, i]
                let sin_val = self.sin_cached[pos, i]
                
                let x0 = x[batch, seq, h, i]
                let x1 = x[batch, seq, h, i + half_rope_dim]
                
                out.store(batch, seq, h, i, x0 * cos_val - x1 * sin_val)
                out.store(batch, seq, h, i + half_rope_dim, x0 * sin_val + x1 * cos_val)


# ==============================================
# Qwen Attention
# ==============================================

struct QwenAttention:
    """
    Qwen attention with optional bias and partial RoPE.
    """
    
    var config: QwenConfig
    var qkv_proj: QKVParallelLinear
    var o_proj: RowParallelLinear
    var rotary_emb: QwenRotaryEmbedding
    var tp_size: Int
    var tp_rank: Int
    var layer_idx: Int
    
    fn __init__(
        inout self,
        config: QwenConfig,
        layer_idx: Int,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.layer_idx = layer_idx
        self.tp_size = tp_size
        self.tp_rank = tp_rank
        
        let head_dim = config.head_dim()
        let local_heads = config.num_attention_heads // tp_size
        let local_kv_heads = config.num_key_value_heads // tp_size
        
        # QKV with optional bias
        self.qkv_proj = QKVParallelLinear(
            config.hidden_size,
            local_heads,
            local_kv_heads,
            head_dim,
            bias=config.use_bias,
        )
        
        # Output projection with optional bias
        let o_config = LinearConfig(
            config.num_attention_heads * head_dim,
            config.hidden_size,
            bias=config.use_bias,
        )
        self.o_proj = RowParallelLinear(o_config, tp_size)
        
        # Qwen-style rotary embedding
        self.rotary_emb = QwenRotaryEmbedding(
            head_dim,
            config.rope_ratio,
            config.max_position_embeddings,
            config.rope_theta,
        )
    
    fn forward(
        self,
        hidden_states: Tensor[DType.float16],
        positions: Tensor[DType.int32],
        kv_cache: KVCache,
    ) -> Tensor[DType.float16]:
        """Forward pass."""
        let batch_size = hidden_states.shape()[0]
        let seq_len = hidden_states.shape()[1]
        let head_dim = self.config.head_dim()
        
        # QKV projection
        let (q, k, v) = self.qkv_proj.forward(hidden_states)
        
        # Reshape
        let local_heads = self.config.num_attention_heads // self.tp_size
        let local_kv_heads = self.config.num_key_value_heads // self.tp_size
        
        var q_reshaped = q.reshape(batch_size, seq_len, local_heads, head_dim)
        var k_reshaped = k.reshape(batch_size, seq_len, local_kv_heads, head_dim)
        var v_reshaped = v.reshape(batch_size, seq_len, local_kv_heads, head_dim)
        
        # Apply partial rotary embedding
        let (q_rot, k_rot) = self.rotary_emb.forward(q_reshaped, k_reshaped, positions)
        
        # Update KV cache
        kv_cache.update(k_rot, v_reshaped, positions)
        
        # Get full K, V
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
        
        let scores = q @ k.transpose(-2, -1) * scale
        let attn_weights = softmax(scores, axis=-1)
        return attn_weights @ v


# ==============================================
# Qwen MLP
# ==============================================

struct QwenMLP:
    """
    Qwen MLP with SwiGLU activation.
    Same as LLaMA MLP.
    """
    
    var config: QwenConfig
    var gate_up_proj: MergedColumnParallelLinear
    var down_proj: RowParallelLinear
    var tp_size: Int
    
    fn __init__(inout self, config: QwenConfig, tp_size: Int = 1):
        self.config = config
        self.tp_size = tp_size
        
        self.gate_up_proj = MergedColumnParallelLinear(
            config.hidden_size,
            config.intermediate_size,
            tp_size,
        )
        
        let down_config = LinearConfig(
            config.intermediate_size,
            config.hidden_size,
            bias=False,
        )
        self.down_proj = RowParallelLinear(down_config, tp_size)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        let (gate, up) = self.gate_up_proj.forward(x)
        let intermediate = silu_and_mul(up, gate)
        return self.down_proj.forward(intermediate)


# ==============================================
# Qwen Decoder Layer
# ==============================================

struct QwenDecoderLayer:
    """Single Qwen decoder layer."""
    
    var config: QwenConfig
    var layer_idx: Int
    var self_attn: QwenAttention
    var mlp: QwenMLP
    var input_layernorm: RMSNorm
    var post_attention_layernorm: RMSNorm
    
    fn __init__(
        inout self,
        config: QwenConfig,
        layer_idx: Int,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.layer_idx = layer_idx
        
        self.self_attn = QwenAttention(config, layer_idx, tp_size, tp_rank)
        self.mlp = QwenMLP(config, tp_size)
        self.input_layernorm = RMSNorm(config.hidden_size, config.rms_norm_eps)
        self.post_attention_layernorm = RMSNorm(config.hidden_size, config.rms_norm_eps)
    
    fn forward(
        self,
        hidden_states: Tensor[DType.float16],
        positions: Tensor[DType.int32],
        kv_cache: KVCache,
    ) -> Tensor[DType.float16]:
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
# Qwen Model
# ==============================================

struct QwenModel:
    """
    Full Qwen model.
    """
    
    var config: QwenConfig
    var embed_tokens: Tensor[DType.float16]
    var layers: List[QwenDecoderLayer]
    var norm: RMSNorm
    var lm_head: Linear
    var tp_size: Int
    var tp_rank: Int
    
    fn __init__(
        inout self,
        config: QwenConfig,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.tp_size = tp_size
        self.tp_rank = tp_rank
        
        self.embed_tokens = Tensor[DType.float16](config.vocab_size, config.hidden_size)
        
        self.layers = List[QwenDecoderLayer]()
        for i in range(config.num_hidden_layers):
            self.layers.append(QwenDecoderLayer(config, i, tp_size, tp_rank))
        
        self.norm = RMSNorm(config.hidden_size, config.rms_norm_eps)
        
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
        """Forward pass."""
        var hidden_states = self._embed(input_ids)
        
        for i in range(self.config.num_hidden_layers):
            hidden_states = self.layers[i].forward(
                hidden_states,
                positions,
                kv_caches[i],
            )
        
        hidden_states = self.norm.forward(hidden_states)
        return self.lm_head.forward(hidden_states)
    
    fn _embed(self, input_ids: Tensor[DType.int32]) -> Tensor[DType.float16]:
        """Token embedding lookup."""
        let batch_size = input_ids.shape()[0]
        let seq_len = input_ids.shape()[1]
        
        var embeddings = Tensor[DType.float16](batch_size, seq_len, self.config.hidden_size)
        
        for b in range(batch_size):
            for s in range(seq_len):
                let token_id = input_ids[b, s].cast[DType.int64]()
                for h in range(self.config.hidden_size):
                    embeddings.store(b, s, h, self.embed_tokens[token_id, h])
        
        return embeddings
    
    fn num_parameters(self) -> Int:
        """Calculate total parameters."""
        var params = 0
        params += self.config.vocab_size * self.config.hidden_size
        
        let head_dim = self.config.head_dim()
        let qkv_size = (
            self.config.num_attention_heads * head_dim +
            2 * self.config.num_key_value_heads * head_dim
        )
        
        for _ in range(self.config.num_hidden_layers):
            params += self.config.hidden_size * qkv_size
            params += self.config.num_attention_heads * head_dim * self.config.hidden_size
            params += self.config.hidden_size * self.config.intermediate_size * 3
            params += 2 * self.config.hidden_size
        
        params += self.config.hidden_size
        if not self.config.tie_word_embeddings:
            params += self.config.hidden_size * self.config.vocab_size
        
        return params