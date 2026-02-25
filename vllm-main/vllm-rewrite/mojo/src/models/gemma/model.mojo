"""
Gemma Model Implementation

Google's Gemma series of open models.
Supports Gemma 1 (2B, 7B) and Gemma 2 (2B, 9B, 27B) variants.

Key features:
- GeGLU activation (GELU-gated linear unit)
- RMSNorm with learned scale
- Multi-Query Attention (MQA) for some variants
- RoPE position encoding
- Soft cap on logits (Gemma 2)
"""

from tensor import Tensor, TensorShape
from algorithm import vectorize, parallelize
from math import tanh

from ...layers.attention import MultiHeadAttention, AttentionConfig, KVCache
from ...layers.linear import Linear, LinearConfig, RowParallelLinear
from ...layers.linear import QKVParallelLinear, MergedColumnParallelLinear
from ...layers.normalization import RMSNorm
from ...layers.activations import gelu
from ..llama.model import RotaryEmbedding


# ==============================================
# Gemma Configuration
# ==============================================

struct GemmaConfig:
    """Configuration for Gemma models."""
    
    var hidden_size: Int
    var intermediate_size: Int
    var num_hidden_layers: Int
    var num_attention_heads: Int
    var num_key_value_heads: Int
    var vocab_size: Int
    var max_position_embeddings: Int
    var rope_theta: Float32
    var rms_norm_eps: Float32
    var head_dim: Int
    
    # Gemma 2 specific
    var query_pre_attn_scalar: Float32
    var attn_logit_softcapping: Float32
    var final_logit_softcapping: Float32
    var use_sliding_window: Bool
    var sliding_window: Int
    
    fn __init__(
        inout self,
        hidden_size: Int = 2048,
        intermediate_size: Int = 16384,
        num_hidden_layers: Int = 18,
        num_attention_heads: Int = 8,
        num_key_value_heads: Int = 1,  # MQA by default
        vocab_size: Int = 256000,
        max_position_embeddings: Int = 8192,
        rope_theta: Float32 = 10000.0,
        rms_norm_eps: Float32 = 1e-6,
        head_dim: Int = 256,
        query_pre_attn_scalar: Float32 = 1.0,
        attn_logit_softcapping: Float32 = 0.0,
        final_logit_softcapping: Float32 = 0.0,
        use_sliding_window: Bool = False,
        sliding_window: Int = 4096,
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
        self.head_dim = head_dim
        self.query_pre_attn_scalar = query_pre_attn_scalar
        self.attn_logit_softcapping = attn_logit_softcapping
        self.final_logit_softcapping = final_logit_softcapping
        self.use_sliding_window = use_sliding_window
        self.sliding_window = sliding_window
    
    fn is_mqa(self) -> Bool:
        """Check if using Multi-Query Attention."""
        return self.num_key_value_heads == 1
    
    fn is_gqa(self) -> Bool:
        """Check if using Grouped Query Attention."""
        return self.num_key_value_heads < self.num_attention_heads and self.num_key_value_heads > 1
    
    fn has_logit_softcapping(self) -> Bool:
        """Check if logit softcapping is enabled (Gemma 2)."""
        return self.attn_logit_softcapping > 0.0 or self.final_logit_softcapping > 0.0
    
    @staticmethod
    fn gemma_2b() -> GemmaConfig:
        """Gemma 1 2B configuration."""
        return GemmaConfig(
            hidden_size=2048,
            intermediate_size=16384,
            num_hidden_layers=18,
            num_attention_heads=8,
            num_key_value_heads=1,  # MQA
            vocab_size=256000,
            max_position_embeddings=8192,
            head_dim=256,
        )
    
    @staticmethod
    fn gemma_7b() -> GemmaConfig:
        """Gemma 1 7B configuration."""
        return GemmaConfig(
            hidden_size=3072,
            intermediate_size=24576,
            num_hidden_layers=28,
            num_attention_heads=16,
            num_key_value_heads=16,  # MHA
            vocab_size=256000,
            max_position_embeddings=8192,
            head_dim=256,
        )
    
    @staticmethod
    fn gemma2_2b() -> GemmaConfig:
        """Gemma 2 2B configuration."""
        return GemmaConfig(
            hidden_size=2304,
            intermediate_size=9216,
            num_hidden_layers=26,
            num_attention_heads=8,
            num_key_value_heads=4,
            vocab_size=256000,
            max_position_embeddings=8192,
            head_dim=256,
            query_pre_attn_scalar=256.0,
            attn_logit_softcapping=50.0,
            final_logit_softcapping=30.0,
            use_sliding_window=True,
            sliding_window=4096,
        )
    
    @staticmethod
    fn gemma2_9b() -> GemmaConfig:
        """Gemma 2 9B configuration."""
        return GemmaConfig(
            hidden_size=3584,
            intermediate_size=14336,
            num_hidden_layers=42,
            num_attention_heads=16,
            num_key_value_heads=8,
            vocab_size=256000,
            max_position_embeddings=8192,
            head_dim=256,
            query_pre_attn_scalar=256.0,
            attn_logit_softcapping=50.0,
            final_logit_softcapping=30.0,
            use_sliding_window=True,
            sliding_window=4096,
        )
    
    @staticmethod
    fn gemma2_27b() -> GemmaConfig:
        """Gemma 2 27B configuration."""
        return GemmaConfig(
            hidden_size=4608,
            intermediate_size=36864,
            num_hidden_layers=46,
            num_attention_heads=32,
            num_key_value_heads=16,
            vocab_size=256000,
            max_position_embeddings=8192,
            head_dim=128,
            query_pre_attn_scalar=144.0,
            attn_logit_softcapping=50.0,
            final_logit_softcapping=30.0,
            use_sliding_window=True,
            sliding_window=4096,
        )


# ==============================================
# GeGLU Activation
# ==============================================

fn geglu(gate: Tensor[DType.float16], up: Tensor[DType.float16]) -> Tensor[DType.float16]:
    """
    GeGLU activation: GELU(gate) * up
    
    Gated variant of GELU used in Gemma models.
    """
    let gelu_gate = gelu(gate)
    return gelu_gate * up


# ==============================================
# Logit Softcapping
# ==============================================

fn softcap(logits: Tensor[DType.float32], cap: Float32) -> Tensor[DType.float32]:
    """
    Apply soft capping to logits: cap * tanh(logits / cap)
    
    Prevents extreme logit values while maintaining gradients.
    Used in Gemma 2 for attention and final logits.
    """
    if cap <= 0.0:
        return logits
    
    var result = Tensor[DType.float32](logits.shape())
    
    for i in range(logits.num_elements()):
        let scaled = logits[i] / cap
        result.store(i, cap * tanh(scaled))
    
    return result


# ==============================================
# Gemma Rotary Embedding
# ==============================================

struct GemmaRotaryEmbedding:
    """Rotary embedding for Gemma models."""
    
    var head_dim: Int
    var max_seq_len: Int
    var base: Float32
    var cos_cached: Tensor[DType.float16]
    var sin_cached: Tensor[DType.float16]
    
    fn __init__(
        inout self,
        head_dim: Int,
        max_seq_len: Int = 8192,
        base: Float32 = 10000.0,
    ):
        self.head_dim = head_dim
        self.max_seq_len = max_seq_len
        self.base = base
        
        self.cos_cached = Tensor[DType.float16](max_seq_len, head_dim // 2)
        self.sin_cached = Tensor[DType.float16](max_seq_len, head_dim // 2)
        
        self._compute_cache()
    
    fn _compute_cache(inout self):
        let half_dim = self.head_dim // 2
        
        for pos in range(self.max_seq_len):
            for i in range(half_dim):
                let freq = 1.0 / pow(self.base, Float32(2 * i) / Float32(self.head_dim))
                let angle = Float32(pos) * freq
                self.cos_cached.store(pos, i, cos(angle).cast[DType.float16]())
                self.sin_cached.store(pos, i, sin(angle).cast[DType.float16]())
    
    fn forward(
        self,
        q: Tensor[DType.float16],
        k: Tensor[DType.float16],
        positions: Tensor[DType.int32],
    ) -> Tuple[Tensor[DType.float16], Tensor[DType.float16]]:
        """Apply rotary embedding to Q and K tensors."""
        let batch_size = q.shape()[0]
        let seq_len = q.shape()[1]
        let half_dim = self.head_dim // 2
        
        var q_out = Tensor[DType.float16](q.shape())
        var k_out = Tensor[DType.float16](k.shape())
        
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
# Gemma Attention
# ==============================================

struct GemmaAttention:
    """Gemma attention with optional logit softcapping."""
    
    var config: GemmaConfig
    var qkv_proj: QKVParallelLinear
    var o_proj: RowParallelLinear
    var rotary_emb: GemmaRotaryEmbedding
    var tp_size: Int
    var tp_rank: Int
    var layer_idx: Int
    
    fn __init__(
        inout self,
        config: GemmaConfig,
        layer_idx: Int,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.layer_idx = layer_idx
        self.tp_size = tp_size
        self.tp_rank = tp_rank
        
        let local_heads = config.num_attention_heads // tp_size
        let local_kv_heads = max(1, config.num_key_value_heads // tp_size)
        
        self.qkv_proj = QKVParallelLinear(
            config.hidden_size,
            local_heads,
            local_kv_heads,
            config.head_dim,
            bias=False,
        )
        
        let o_config = LinearConfig(
            config.num_attention_heads * config.head_dim,
            config.hidden_size,
            bias=False,
        )
        self.o_proj = RowParallelLinear(o_config, tp_size)
        
        self.rotary_emb = GemmaRotaryEmbedding(
            config.head_dim,
            config.max_position_embeddings,
            config.rope_theta,
        )
    
    fn forward(
        self,
        hidden_states: Tensor[DType.float16],
        positions: Tensor[DType.int32],
        kv_cache: KVCache,
    ) -> Tensor[DType.float16]:
        """Forward pass with optional softcapping."""
        let batch_size = hidden_states.shape()[0]
        let seq_len = hidden_states.shape()[1]
        
        let (q, k, v) = self.qkv_proj.forward(hidden_states)
        
        let local_heads = self.config.num_attention_heads // self.tp_size
        let local_kv_heads = max(1, self.config.num_key_value_heads // self.tp_size)
        
        var q_reshaped = q.reshape(batch_size, seq_len, local_heads, self.config.head_dim)
        var k_reshaped = k.reshape(batch_size, seq_len, local_kv_heads, self.config.head_dim)
        var v_reshaped = v.reshape(batch_size, seq_len, local_kv_heads, self.config.head_dim)
        
        # Apply rotary embedding
        let (q_rot, k_rot) = self.rotary_emb.forward(q_reshaped, k_reshaped, positions)
        
        # Update KV cache
        kv_cache.update(k_rot, v_reshaped, positions)
        let (k_full, v_full) = kv_cache.get()
        
        # Compute attention with optional softcapping
        let attn_output = self._compute_attention(q_rot, k_full, v_full)
        
        let output = attn_output.reshape(batch_size, seq_len, -1)
        return self.o_proj.forward(output)
    
    fn _compute_attention(
        self,
        q: Tensor[DType.float16],
        k: Tensor[DType.float16],
        v: Tensor[DType.float16],
    ) -> Tensor[DType.float16]:
        """Compute attention with Gemma-specific scaling and softcapping."""
        # Gemma 2 uses query_pre_attn_scalar instead of sqrt(head_dim)
        let scale = 1.0 / sqrt(self.config.query_pre_attn_scalar)
        
        var scores = q.cast[DType.float32]() @ k.cast[DType.float32]().transpose(-2, -1) * scale
        
        # Apply attention logit softcapping (Gemma 2)
        if self.config.attn_logit_softcapping > 0.0:
            scores = softcap(scores, self.config.attn_logit_softcapping)
        
        let attn_weights = softmax(scores, axis=-1)
        return (attn_weights @ v.cast[DType.float32]()).cast[DType.float16]()


# ==============================================
# Gemma MLP
# ==============================================

struct GemmaMLP:
    """Gemma MLP with GeGLU activation."""
    
    var config: GemmaConfig
    var gate_up_proj: MergedColumnParallelLinear
    var down_proj: RowParallelLinear
    var tp_size: Int
    
    fn __init__(inout self, config: GemmaConfig, tp_size: Int = 1):
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
        let intermediate = geglu(gate, up)
        return self.down_proj.forward(intermediate)


# ==============================================
# Gemma Decoder Layer
# ==============================================

struct GemmaDecoderLayer:
    """Single Gemma decoder layer."""
    
    var config: GemmaConfig
    var layer_idx: Int
    var self_attn: GemmaAttention
    var mlp: GemmaMLP
    var input_layernorm: RMSNorm
    var post_attention_layernorm: RMSNorm
    
    # Gemma 2: alternating sliding window
    var use_sliding_window: Bool
    
    fn __init__(
        inout self,
        config: GemmaConfig,
        layer_idx: Int,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.layer_idx = layer_idx
        
        self.self_attn = GemmaAttention(config, layer_idx, tp_size, tp_rank)
        self.mlp = GemmaMLP(config, tp_size)
        self.input_layernorm = RMSNorm(config.hidden_size, config.rms_norm_eps)
        self.post_attention_layernorm = RMSNorm(config.hidden_size, config.rms_norm_eps)
        
        # Gemma 2: alternating global/local attention
        self.use_sliding_window = config.use_sliding_window and (layer_idx % 2 == 0)
    
    fn forward(
        self,
        hidden_states: Tensor[DType.float16],
        positions: Tensor[DType.int32],
        kv_cache: KVCache,
    ) -> Tensor[DType.float16]:
        # Self-attention with residual (pre-norm)
        let normed = self.input_layernorm.forward(hidden_states)
        let attn_output = self.self_attn.forward(normed, positions, kv_cache)
        var hidden = hidden_states + attn_output
        
        # MLP with residual (post-attention norm)
        let normed_mlp = self.post_attention_layernorm.forward(hidden)
        let mlp_output = self.mlp.forward(normed_mlp)
        hidden = hidden + mlp_output
        
        return hidden


# ==============================================
# Gemma Model
# ==============================================

struct GemmaModel:
    """Full Gemma model."""
    
    var config: GemmaConfig
    var embed_tokens: Tensor[DType.float16]
    var layers: List[GemmaDecoderLayer]
    var norm: RMSNorm
    var tp_size: Int
    var tp_rank: Int
    
    # Gemma ties embeddings by default
    var tie_word_embeddings: Bool
    
    fn __init__(
        inout self,
        config: GemmaConfig,
        tp_size: Int = 1,
        tp_rank: Int = 0,
        tie_word_embeddings: Bool = True,
    ):
        self.config = config
        self.tp_size = tp_size
        self.tp_rank = tp_rank
        self.tie_word_embeddings = tie_word_embeddings
        
        self.embed_tokens = Tensor[DType.float16](config.vocab_size, config.hidden_size)
        
        self.layers = List[GemmaDecoderLayer]()
        for i in range(config.num_hidden_layers):
            self.layers.append(GemmaDecoderLayer(config, i, tp_size, tp_rank))
        
        self.norm = RMSNorm(config.hidden_size, config.rms_norm_eps)
    
    fn forward(
        self,
        input_ids: Tensor[DType.int32],
        positions: Tensor[DType.int32],
        kv_caches: List[KVCache],
    ) -> Tensor[DType.float16]:
        """Forward pass with optional final logit softcapping."""
        var hidden_states = self._embed(input_ids)
        
        # Gemma normalizes embeddings
        hidden_states = hidden_states * sqrt(Float16(self.config.hidden_size))
        
        for i in range(self.config.num_hidden_layers):
            hidden_states = self.layers[i].forward(
                hidden_states,
                positions,
                kv_caches[i],
            )
        
        hidden_states = self.norm.forward(hidden_states)
        
        # Compute logits (tied embeddings)
        var logits = self._compute_logits(hidden_states)
        
        # Apply final logit softcapping (Gemma 2)
        if self.config.final_logit_softcapping > 0.0:
            logits = softcap(logits.cast[DType.float32](), self.config.final_logit_softcapping).cast[DType.float16]()
        
        return logits
    
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
    
    fn _compute_logits(self, hidden_states: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Compute logits using tied embeddings."""
        let batch_size = hidden_states.shape()[0]
        let seq_len = hidden_states.shape()[1]
        
        var logits = Tensor[DType.float16](batch_size, seq_len, self.config.vocab_size)
        
        # hidden @ embedding.T
        for b in range(batch_size):
            for s in range(seq_len):
                for v in range(self.config.vocab_size):
                    var sum: Float16 = 0.0
                    for h in range(self.config.hidden_size):
                        sum += hidden_states[b, s, h] * self.embed_tokens[v, h]
                    logits.store(b, s, v, sum)
        
        return logits
    
    fn num_parameters(self) -> Int:
        """Calculate total parameters."""
        var params = 0
        
        # Embedding (shared with output)
        params += self.config.vocab_size * self.config.hidden_size
        
        let qkv_size = (
            self.config.num_attention_heads * self.config.head_dim +
            2 * self.config.num_key_value_heads * self.config.head_dim
        )
        
        for _ in range(self.config.num_hidden_layers):
            params += self.config.hidden_size * qkv_size
            params += self.config.num_attention_heads * self.config.head_dim * self.config.hidden_size
            params += self.config.hidden_size * self.config.intermediate_size * 3
            params += 2 * self.config.hidden_size
        
        params += self.config.hidden_size
        
        return params