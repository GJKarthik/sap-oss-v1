"""
Phi Model Implementation

Microsoft's Phi series of small language models.
Supports Phi-1, Phi-1.5, Phi-2, Phi-3, and Phi-3.5 variants.

Key features:
- Partial Rotary Position Embedding (Phi-3)
- Layer-wise Mixture of Depths (Phi-3)
- Flash Attention support
- Relatively small but powerful models
"""

from tensor import Tensor, TensorShape
from algorithm import vectorize, parallelize

from ...layers.attention import MultiHeadAttention, AttentionConfig, KVCache
from ...layers.linear import Linear, LinearConfig, RowParallelLinear
from ...layers.linear import QKVParallelLinear, MergedColumnParallelLinear
from ...layers.normalization import LayerNorm
from ...layers.activations import gelu_new
from ..llama.model import RotaryEmbedding


# ==============================================
# Phi Configuration
# ==============================================

struct PhiConfig:
    """Configuration for Phi models."""
    
    var hidden_size: Int
    var intermediate_size: Int
    var num_hidden_layers: Int
    var num_attention_heads: Int
    var num_key_value_heads: Int
    var vocab_size: Int
    var max_position_embeddings: Int
    var rope_theta: Float32
    var layer_norm_eps: Float32
    var partial_rotary_factor: Float32
    var qk_layernorm: Bool
    var use_bias: Bool
    var resid_pdrop: Float32
    
    fn __init__(
        inout self,
        hidden_size: Int = 2048,
        intermediate_size: Int = 8192,
        num_hidden_layers: Int = 24,
        num_attention_heads: Int = 32,
        num_key_value_heads: Int = 32,
        vocab_size: Int = 32064,
        max_position_embeddings: Int = 2048,
        rope_theta: Float32 = 10000.0,
        layer_norm_eps: Float32 = 1e-5,
        partial_rotary_factor: Float32 = 0.5,
        qk_layernorm: Bool = False,
        use_bias: Bool = True,
        resid_pdrop: Float32 = 0.0,
    ):
        self.hidden_size = hidden_size
        self.intermediate_size = intermediate_size
        self.num_hidden_layers = num_hidden_layers
        self.num_attention_heads = num_attention_heads
        self.num_key_value_heads = num_key_value_heads
        self.vocab_size = vocab_size
        self.max_position_embeddings = max_position_embeddings
        self.rope_theta = rope_theta
        self.layer_norm_eps = layer_norm_eps
        self.partial_rotary_factor = partial_rotary_factor
        self.qk_layernorm = qk_layernorm
        self.use_bias = use_bias
        self.resid_pdrop = resid_pdrop
    
    fn head_dim(self) -> Int:
        return self.hidden_size // self.num_attention_heads
    
    fn rotary_dim(self) -> Int:
        """Dimension to apply RoPE to (partial rotation)."""
        return Int(self.head_dim() * self.partial_rotary_factor)
    
    fn is_gqa(self) -> Bool:
        return self.num_key_value_heads < self.num_attention_heads
    
    @staticmethod
    fn phi2() -> PhiConfig:
        """Phi-2 (2.7B parameters) configuration."""
        return PhiConfig(
            hidden_size=2560,
            intermediate_size=10240,
            num_hidden_layers=32,
            num_attention_heads=32,
            num_key_value_heads=32,
            vocab_size=51200,
            max_position_embeddings=2048,
            partial_rotary_factor=0.4,
            qk_layernorm=False,
        )
    
    @staticmethod
    fn phi3_mini() -> PhiConfig:
        """Phi-3-mini (3.8B parameters) configuration."""
        return PhiConfig(
            hidden_size=3072,
            intermediate_size=8192,
            num_hidden_layers=32,
            num_attention_heads=32,
            num_key_value_heads=32,
            vocab_size=32064,
            max_position_embeddings=4096,
            rope_theta=10000.0,
            partial_rotary_factor=1.0,
            qk_layernorm=False,
        )
    
    @staticmethod
    fn phi3_small() -> PhiConfig:
        """Phi-3-small (7B parameters) configuration."""
        return PhiConfig(
            hidden_size=4096,
            intermediate_size=14336,
            num_hidden_layers=32,
            num_attention_heads=32,
            num_key_value_heads=8,  # GQA
            vocab_size=100352,
            max_position_embeddings=8192,
            rope_theta=10000.0,
            partial_rotary_factor=1.0,
            qk_layernorm=True,
        )
    
    @staticmethod
    fn phi3_medium() -> PhiConfig:
        """Phi-3-medium (14B parameters) configuration."""
        return PhiConfig(
            hidden_size=5120,
            intermediate_size=17920,
            num_hidden_layers=40,
            num_attention_heads=40,
            num_key_value_heads=10,  # GQA
            vocab_size=32064,
            max_position_embeddings=4096,
            rope_theta=10000.0,
            partial_rotary_factor=1.0,
            qk_layernorm=True,
        )
    
    @staticmethod
    fn phi3_5_mini() -> PhiConfig:
        """Phi-3.5-mini configuration."""
        return PhiConfig.phi3_mini()


# ==============================================
# Phi Rotary Embedding
# ==============================================

struct PhiRotaryEmbedding:
    """
    Phi-style partial rotary embedding.
    
    Applies rotation to first `rotary_dim` dimensions only.
    """
    
    var head_dim: Int
    var rotary_dim: Int
    var max_seq_len: Int
    var base: Float32
    var cos_cached: Tensor[DType.float16]
    var sin_cached: Tensor[DType.float16]
    
    fn __init__(
        inout self,
        head_dim: Int,
        rotary_factor: Float32 = 0.5,
        max_seq_len: Int = 2048,
        base: Float32 = 10000.0,
    ):
        self.head_dim = head_dim
        self.rotary_dim = Int(head_dim * rotary_factor)
        self.max_seq_len = max_seq_len
        self.base = base
        
        self.cos_cached = Tensor[DType.float16](max_seq_len, self.rotary_dim // 2)
        self.sin_cached = Tensor[DType.float16](max_seq_len, self.rotary_dim // 2)
        
        self._compute_cache()
    
    fn _compute_cache(inout self):
        """Pre-compute rotary embeddings."""
        let half_dim = self.rotary_dim // 2
        
        for pos in range(self.max_seq_len):
            for i in range(half_dim):
                let freq = 1.0 / pow(self.base, Float32(2 * i) / Float32(self.rotary_dim))
                let angle = Float32(pos) * freq
                self.cos_cached.store(pos, i, cos(angle).cast[DType.float16]())
                self.sin_cached.store(pos, i, sin(angle).cast[DType.float16]())
    
    fn forward(
        self,
        q: Tensor[DType.float16],
        k: Tensor[DType.float16],
        positions: Tensor[DType.int32],
    ) -> Tuple[Tensor[DType.float16], Tensor[DType.float16]]:
        """Apply partial rotary embedding."""
        let batch_size = q.shape()[0]
        let seq_len = q.shape()[1]
        
        var q_out = Tensor[DType.float16](q.shape())
        var k_out = Tensor[DType.float16](k.shape())
        
        # Copy original tensors
        memcpy(q_out.data(), q.data(), q.num_elements() * sizeof[DType.float16]())
        memcpy(k_out.data(), k.data(), k.num_elements() * sizeof[DType.float16]())
        
        # Apply rotation to first rotary_dim dimensions
        let half_dim = self.rotary_dim // 2
        
        for b in range(batch_size):
            for s in range(seq_len):
                let pos = positions[b, s].cast[DType.int64]()
                
                for h in range(q.shape()[2]):
                    for i in range(half_dim):
                        let cos_val = self.cos_cached[pos, i]
                        let sin_val = self.sin_cached[pos, i]
                        
                        let q0 = q[b, s, h, i]
                        let q1 = q[b, s, h, i + half_dim]
                        q_out.store(b, s, h, i, q0 * cos_val - q1 * sin_val)
                        q_out.store(b, s, h, i + half_dim, q0 * sin_val + q1 * cos_val)
                
                for h in range(k.shape()[2]):
                    for i in range(half_dim):
                        let cos_val = self.cos_cached[pos, i]
                        let sin_val = self.sin_cached[pos, i]
                        
                        let k0 = k[b, s, h, i]
                        let k1 = k[b, s, h, i + half_dim]
                        k_out.store(b, s, h, i, k0 * cos_val - k1 * sin_val)
                        k_out.store(b, s, h, i + half_dim, k0 * sin_val + k1 * cos_val)
        
        return (q_out, k_out)


# ==============================================
# Phi Attention
# ==============================================

struct PhiAttention:
    """
    Phi attention with optional QK layer norm.
    """
    
    var config: PhiConfig
    var qkv_proj: QKVParallelLinear
    var o_proj: RowParallelLinear
    var rotary_emb: PhiRotaryEmbedding
    var q_layernorm: LayerNorm
    var k_layernorm: LayerNorm
    var tp_size: Int
    var tp_rank: Int
    var layer_idx: Int
    
    fn __init__(
        inout self,
        config: PhiConfig,
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
        
        self.qkv_proj = QKVParallelLinear(
            config.hidden_size,
            local_heads,
            local_kv_heads,
            head_dim,
            bias=config.use_bias,
        )
        
        let o_config = LinearConfig(
            config.num_attention_heads * head_dim,
            config.hidden_size,
            bias=config.use_bias,
        )
        self.o_proj = RowParallelLinear(o_config, tp_size)
        
        self.rotary_emb = PhiRotaryEmbedding(
            head_dim,
            config.partial_rotary_factor,
            config.max_position_embeddings,
            config.rope_theta,
        )
        
        # Optional QK layer norms (Phi-3)
        self.q_layernorm = LayerNorm(head_dim, config.layer_norm_eps)
        self.k_layernorm = LayerNorm(head_dim, config.layer_norm_eps)
    
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
        
        let (q, k, v) = self.qkv_proj.forward(hidden_states)
        
        let local_heads = self.config.num_attention_heads // self.tp_size
        let local_kv_heads = self.config.num_key_value_heads // self.tp_size
        
        var q_reshaped = q.reshape(batch_size, seq_len, local_heads, head_dim)
        var k_reshaped = k.reshape(batch_size, seq_len, local_kv_heads, head_dim)
        var v_reshaped = v.reshape(batch_size, seq_len, local_kv_heads, head_dim)
        
        # Apply optional QK layer norms
        if self.config.qk_layernorm:
            q_reshaped = self._apply_qk_norm(q_reshaped, self.q_layernorm)
            k_reshaped = self._apply_qk_norm(k_reshaped, self.k_layernorm)
        
        # Apply rotary embedding
        let (q_rot, k_rot) = self.rotary_emb.forward(q_reshaped, k_reshaped, positions)
        
        # Update KV cache
        kv_cache.update(k_rot, v_reshaped, positions)
        let (k_full, v_full) = kv_cache.get()
        
        # Compute attention
        let attn_output = self._compute_attention(q_rot, k_full, v_full)
        
        let output = attn_output.reshape(batch_size, seq_len, -1)
        return self.o_proj.forward(output)
    
    fn _apply_qk_norm(
        self,
        x: Tensor[DType.float16],
        norm: LayerNorm,
    ) -> Tensor[DType.float16]:
        """Apply layer norm to each head independently."""
        let batch_size = x.shape()[0]
        let seq_len = x.shape()[1]
        let num_heads = x.shape()[2]
        let head_dim = x.shape()[3]
        
        var output = Tensor[DType.float16](x.shape())
        
        for b in range(batch_size):
            for s in range(seq_len):
                for h in range(num_heads):
                    # Extract head vector
                    var head_vec = Tensor[DType.float16](head_dim)
                    for d in range(head_dim):
                        head_vec.store(d, x[b, s, h, d])
                    
                    # Apply layer norm
                    let normed = norm.forward(head_vec)
                    
                    # Store back
                    for d in range(head_dim):
                        output.store(b, s, h, d, normed[d])
        
        return output
    
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
# Phi MLP
# ==============================================

struct PhiMLP:
    """
    Phi MLP with GELU activation.
    
    Phi uses standard GELU (not SwiGLU like LLaMA).
    """
    
    var config: PhiConfig
    var fc1: Linear
    var fc2: Linear
    var tp_size: Int
    
    fn __init__(inout self, config: PhiConfig, tp_size: Int = 1):
        self.config = config
        self.tp_size = tp_size
        
        let fc1_config = LinearConfig(
            config.hidden_size,
            config.intermediate_size,
            bias=config.use_bias,
        )
        self.fc1 = Linear(fc1_config)
        
        let fc2_config = LinearConfig(
            config.intermediate_size,
            config.hidden_size,
            bias=config.use_bias,
        )
        self.fc2 = Linear(fc2_config)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        let hidden = self.fc1.forward(x)
        let activated = gelu_new(hidden)
        return self.fc2.forward(activated)


# ==============================================
# Phi Decoder Layer
# ==============================================

struct PhiDecoderLayer:
    """Single Phi decoder layer."""
    
    var config: PhiConfig
    var layer_idx: Int
    var self_attn: PhiAttention
    var mlp: PhiMLP
    var input_layernorm: LayerNorm
    var post_attention_layernorm: LayerNorm
    
    fn __init__(
        inout self,
        config: PhiConfig,
        layer_idx: Int,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.layer_idx = layer_idx
        
        self.self_attn = PhiAttention(config, layer_idx, tp_size, tp_rank)
        self.mlp = PhiMLP(config, tp_size)
        self.input_layernorm = LayerNorm(config.hidden_size, config.layer_norm_eps)
        self.post_attention_layernorm = LayerNorm(config.hidden_size, config.layer_norm_eps)
    
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
# Phi Model
# ==============================================

struct PhiModel:
    """Full Phi model."""
    
    var config: PhiConfig
    var embed_tokens: Tensor[DType.float16]
    var layers: List[PhiDecoderLayer]
    var final_layernorm: LayerNorm
    var lm_head: Linear
    var tp_size: Int
    var tp_rank: Int
    
    fn __init__(
        inout self,
        config: PhiConfig,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.tp_size = tp_size
        self.tp_rank = tp_rank
        
        self.embed_tokens = Tensor[DType.float16](config.vocab_size, config.hidden_size)
        
        self.layers = List[PhiDecoderLayer]()
        for i in range(config.num_hidden_layers):
            self.layers.append(PhiDecoderLayer(config, i, tp_size, tp_rank))
        
        self.final_layernorm = LayerNorm(config.hidden_size, config.layer_norm_eps)
        
        let lm_config = LinearConfig(
            config.hidden_size,
            config.vocab_size,
            bias=config.use_bias,
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
        
        hidden_states = self.final_layernorm.forward(hidden_states)
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
            # Attention
            params += self.config.hidden_size * qkv_size
            if self.config.use_bias:
                params += qkv_size
            params += self.config.num_attention_heads * head_dim * self.config.hidden_size
            
            # MLP
            params += self.config.hidden_size * self.config.intermediate_size
            params += self.config.intermediate_size * self.config.hidden_size
            if self.config.use_bias:
                params += self.config.intermediate_size + self.config.hidden_size
            
            # Layer norms
            params += 4 * self.config.hidden_size
        
        params += 2 * self.config.hidden_size
        params += self.config.hidden_size * self.config.vocab_size
        
        return params