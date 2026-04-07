"""
Q4_K_M Quantized LLM Inference

This module provides LLM inference using Q4_K_M quantized weights,
enabling efficient memory usage (~7x compression) while maintaining
accuracy close to FP32.

Key features:
- Q4_K_M weight storage (GGUF compatible)
- Fused dequantization during matmul
- Memory-efficient generation
- KV cache with FP16/FP32 for quality
"""

from sys.info import simdwidthof
from algorithm import vectorize, parallelize
from memory import memset_zero, memcpy
from math import exp, sqrt

from ..quantization import (
    Q4KMTensor,
    dequantize_q4_k_m_simd,
    q4_k_m_matmul,
    QK_K,
    K_SCALE_SIZE,
)
from ..kernel import softmax_simd, rms_layer_norm
from ..kernel.attention import scaled_dot_product_attention, apply_rope_inplace, KVCache


alias FloatType = DType.float32
alias SIMD_WIDTH = simdwidthof[FloatType]()


# =============================================================================
# Q4_K_M Model Configuration
# =============================================================================

struct Q4ModelConfig:
    """Configuration for Q4_K_M quantized transformer model."""
    var vocab_size: Int
    var embed_dim: Int
    var num_heads: Int
    var num_kv_heads: Int  # For GQA (Grouped Query Attention)
    var num_layers: Int
    var ffn_dim: Int
    var max_seq_len: Int
    var head_dim: Int
    var rope_base: Float32
    var layer_norm_eps: Float32
    
    fn __init__(
        inout self,
        vocab_size: Int = 32000,
        embed_dim: Int = 2048,      # Smaller default for 1B models
        num_heads: Int = 32,
        num_kv_heads: Int = 8,      # GQA with 8 KV heads
        num_layers: Int = 22,
        ffn_dim: Int = 5632,
        max_seq_len: Int = 4096,
        rope_base: Float32 = 10000.0,
        layer_norm_eps: Float32 = 1e-5,
    ):
        self.vocab_size = vocab_size
        self.embed_dim = embed_dim
        self.num_heads = num_heads
        self.num_kv_heads = num_kv_heads
        self.num_layers = num_layers
        self.ffn_dim = ffn_dim
        self.max_seq_len = max_seq_len
        self.head_dim = embed_dim // num_heads
        self.rope_base = rope_base
        self.layer_norm_eps = layer_norm_eps
    
    @staticmethod
    fn for_llama_1b() -> Q4ModelConfig:
        """Configuration for LLaMA 1B model."""
        return Q4ModelConfig(
            vocab_size=32000,
            embed_dim=2048,
            num_heads=32,
            num_kv_heads=8,
            num_layers=22,
            ffn_dim=5632,
            max_seq_len=4096,
        )
    
    @staticmethod
    fn for_phi2() -> Q4ModelConfig:
        """Configuration for Phi-2 model."""
        return Q4ModelConfig(
            vocab_size=51200,
            embed_dim=2560,
            num_heads=32,
            num_kv_heads=32,
            num_layers=32,
            ffn_dim=10240,
            max_seq_len=2048,
        )


# =============================================================================
# Q4_K_M Layer Weights
# =============================================================================

struct Q4LayerWeights:
    """
    Weights for a single transformer layer using Q4_K_M quantization.
    
    Attention weights (Q, K, V, O) and FFN weights (gate, up, down)
    are stored in Q4_K_M format. Layer norm weights remain in FP32.
    """
    var wq: Q4KMTensor      # [embed_dim, embed_dim]
    var wk: Q4KMTensor      # [embed_dim, kv_dim]
    var wv: Q4KMTensor      # [embed_dim, kv_dim]
    var wo: Q4KMTensor      # [embed_dim, embed_dim]
    
    var w_gate: Q4KMTensor  # [embed_dim, ffn_dim] - gate projection
    var w_up: Q4KMTensor    # [embed_dim, ffn_dim] - up projection
    var w_down: Q4KMTensor  # [ffn_dim, embed_dim] - down projection
    
    # Layer norm weights (FP32 for precision)
    var ln_attn_weight: UnsafePointer[Float32]   # [embed_dim]
    var ln_ffn_weight: UnsafePointer[Float32]    # [embed_dim]
    
    var embed_dim: Int
    var kv_dim: Int
    var ffn_dim: Int
    
    fn __init__(inout self, embed_dim: Int, kv_dim: Int, ffn_dim: Int):
        self.embed_dim = embed_dim
        self.kv_dim = kv_dim
        self.ffn_dim = ffn_dim
        
        # Initialize Q4_K_M tensors
        self.wq = Q4KMTensor(embed_dim, embed_dim)
        self.wk = Q4KMTensor(embed_dim, kv_dim)
        self.wv = Q4KMTensor(embed_dim, kv_dim)
        self.wo = Q4KMTensor(embed_dim, embed_dim)
        
        self.w_gate = Q4KMTensor(embed_dim, ffn_dim)
        self.w_up = Q4KMTensor(embed_dim, ffn_dim)
        self.w_down = Q4KMTensor(ffn_dim, embed_dim)
        
        # Allocate FP32 layer norm weights
        self.ln_attn_weight = UnsafePointer[Float32].alloc(embed_dim)
        self.ln_ffn_weight = UnsafePointer[Float32].alloc(embed_dim)
        
        # Initialize layer norm weights to 1.0
        for i in range(embed_dim):
            self.ln_attn_weight[i] = 1.0
            self.ln_ffn_weight[i] = 1.0
    
    fn __del__(owned self):
        self.ln_attn_weight.free()
        self.ln_ffn_weight.free()
    
    fn memory_mb(self) -> Float32:
        """Calculate layer memory usage in MB."""
        var q4_bytes = (
            self.wq.memory_bytes() +
            self.wk.memory_bytes() +
            self.wv.memory_bytes() +
            self.wo.memory_bytes() +
            self.w_gate.memory_bytes() +
            self.w_up.memory_bytes() +
            self.w_down.memory_bytes()
        )
        var fp32_bytes = self.embed_dim * 4 * 2  # Two layer norm weights
        return Float32(q4_bytes + fp32_bytes) / (1024.0 * 1024.0)


struct Q4ModelWeights:
    """
    Complete model weights with Q4_K_M quantization.
    
    Embedding and LM head remain in FP32 for output quality.
    Transformer layers use Q4_K_M for memory efficiency.
    """
    var config: Q4ModelConfig
    var token_embed: UnsafePointer[Float32]      # [vocab_size, embed_dim] FP32
    var layers: List[Q4LayerWeights]
    var ln_final_weight: UnsafePointer[Float32]  # [embed_dim]
    var lm_head: UnsafePointer[Float32]          # [embed_dim, vocab_size] FP32
    
    fn __init__(inout self, config: Q4ModelConfig):
        self.config = config
        self.layers = List[Q4LayerWeights]()
        
        # Embedding table (FP32)
        self.token_embed = UnsafePointer[Float32].alloc(
            config.vocab_size * config.embed_dim
        )
        memset_zero(self.token_embed.bitcast[UInt8](), 
                   config.vocab_size * config.embed_dim * 4)
        
        # Layer weights (Q4_K_M)
        var kv_dim = config.num_kv_heads * config.head_dim
        for i in range(config.num_layers):
            self.layers.append(Q4LayerWeights(config.embed_dim, kv_dim, config.ffn_dim))
        
        # Final layer norm (FP32)
        self.ln_final_weight = UnsafePointer[Float32].alloc(config.embed_dim)
        for i in range(config.embed_dim):
            self.ln_final_weight[i] = 1.0
        
        # LM head (FP32 for output quality)
        self.lm_head = UnsafePointer[Float32].alloc(
            config.embed_dim * config.vocab_size
        )
        memset_zero(self.lm_head.bitcast[UInt8](), 
                   config.embed_dim * config.vocab_size * 4)
    
    fn __del__(owned self):
        self.token_embed.free()
        self.ln_final_weight.free()
        self.lm_head.free()
    
    fn total_memory_mb(self) -> Float32:
        """Calculate total model memory in MB."""
        var embed_bytes = self.config.vocab_size * self.config.embed_dim * 4
        var lm_head_bytes = self.config.embed_dim * self.config.vocab_size * 4
        var ln_bytes = self.config.embed_dim * 4
        
        var layer_mb = Float32(0.0)
        for i in range(len(self.layers)):
            layer_mb += self.layers[i].memory_mb()
        
        var other_mb = Float32(embed_bytes + lm_head_bytes + ln_bytes) / (1024.0 * 1024.0)
        return layer_mb + other_mb


# =============================================================================
# Q4_K_M Forward Pass
# =============================================================================

fn q4_attention_forward(
    hidden: UnsafePointer[Float32],        # [seq_len, embed_dim]
    output: UnsafePointer[Float32],        # [seq_len, embed_dim]
    weights: Q4LayerWeights,
    config: Q4ModelConfig,
    seq_len: Int,
    kv_cache: KVCache,
    position: Int,
):
    """
    Attention forward pass with Q4_K_M quantized weights.
    
    Uses fused Q4_K_M matmul for memory efficiency.
    """
    var embed_dim = config.embed_dim
    var num_heads = config.num_heads
    var num_kv_heads = config.num_kv_heads
    var head_dim = config.head_dim
    var kv_dim = num_kv_heads * head_dim
    
    # Allocate projections
    var q_proj = UnsafePointer[Float32].alloc(seq_len * embed_dim)
    var k_proj = UnsafePointer[Float32].alloc(seq_len * kv_dim)
    var v_proj = UnsafePointer[Float32].alloc(seq_len * kv_dim)
    var attn_out = UnsafePointer[Float32].alloc(seq_len * embed_dim)
    
    # Project Q, K, V using Q4_K_M matmul
    q4_k_m_matmul(hidden, weights.wq, q_proj, seq_len, embed_dim, embed_dim)
    q4_k_m_matmul(hidden, weights.wk, k_proj, seq_len, embed_dim, kv_dim)
    q4_k_m_matmul(hidden, weights.wv, v_proj, seq_len, embed_dim, kv_dim)
    
    # Apply RoPE to Q and K
    for i in range(seq_len):
        for h in range(num_heads):
            apply_rope_inplace(
                q_proj + i * embed_dim + h * head_dim,
                1,
                head_dim,
                position + i,
                config.rope_base
            )
        for h in range(num_kv_heads):
            apply_rope_inplace(
                k_proj + i * kv_dim + h * head_dim,
                1,
                head_dim,
                position + i,
                config.rope_base
            )
    
    # Update KV cache
    kv_cache.append(k_proj, v_proj, seq_len)
    
    # Compute attention (with GQA support)
    memset_zero(attn_out.bitcast[UInt8](), seq_len * embed_dim * 4)
    var scale = 1.0 / sqrt(Float32(head_dim))
    var kv_per_q = num_heads // num_kv_heads
    
    for h in range(num_heads):
        var kv_h = h // kv_per_q  # Map Q head to KV head
        
        # Get Q for this head
        var q_head = UnsafePointer[Float32].alloc(seq_len * head_dim)
        var out_head = UnsafePointer[Float32].alloc(seq_len * head_dim)
        
        for i in range(seq_len):
            for j in range(head_dim):
                q_head[i * head_dim + j] = q_proj[i * embed_dim + h * head_dim + j]
        
        # Attention for this head
        scaled_dot_product_attention(
            q_head,
            kv_cache.get_keys() + kv_h * head_dim,
            kv_cache.get_values() + kv_h * head_dim,
            out_head,
            seq_len,
            head_dim,
            scale,
            True  # causal
        )
        
        # Copy to output
        for i in range(seq_len):
            for j in range(head_dim):
                attn_out[i * embed_dim + h * head_dim + j] = out_head[i * head_dim + j]
        
        q_head.free()
        out_head.free()
    
    # Output projection using Q4_K_M
    q4_k_m_matmul(attn_out, weights.wo, output, seq_len, embed_dim, embed_dim)
    
    q_proj.free()
    k_proj.free()
    v_proj.free()
    attn_out.free()


fn q4_ffn_forward(
    hidden: UnsafePointer[Float32],        # [seq_len, embed_dim]
    output: UnsafePointer[Float32],        # [seq_len, embed_dim]
    weights: Q4LayerWeights,
    config: Q4ModelConfig,
    seq_len: Int,
):
    """
    FFN forward pass with Q4_K_M quantized weights.
    
    Implements SwiGLU: output = down(silu(gate(x)) * up(x))
    """
    var embed_dim = config.embed_dim
    var ffn_dim = config.ffn_dim
    
    # Allocate intermediate buffers
    var gate = UnsafePointer[Float32].alloc(seq_len * ffn_dim)
    var up = UnsafePointer[Float32].alloc(seq_len * ffn_dim)
    
    # Gate and Up projections using Q4_K_M
    q4_k_m_matmul(hidden, weights.w_gate, gate, seq_len, embed_dim, ffn_dim)
    q4_k_m_matmul(hidden, weights.w_up, up, seq_len, embed_dim, ffn_dim)
    
    # SwiGLU: silu(gate) * up
    for i in range(seq_len * ffn_dim):
        var g = gate[i]
        var silu_g = g / (1.0 + exp(-g))  # SiLU activation
        gate[i] = silu_g * up[i]
    
    # Down projection using Q4_K_M
    q4_k_m_matmul(gate, weights.w_down, output, seq_len, ffn_dim, embed_dim)
    
    gate.free()
    up.free()


fn q4_transformer_layer_forward(
    input: UnsafePointer[Float32],
    output: UnsafePointer[Float32],
    weights: Q4LayerWeights,
    config: Q4ModelConfig,
    seq_len: Int,
    kv_cache: KVCache,
    position: Int,
):
    """
    Complete transformer layer forward pass with Q4_K_M weights.
    
    Architecture: Pre-norm with residual connections
    """
    var embed_dim = config.embed_dim
    
    # Allocate intermediate buffers
    var normalized = UnsafePointer[Float32].alloc(seq_len * embed_dim)
    var attn_out = UnsafePointer[Float32].alloc(seq_len * embed_dim)
    var ffn_out = UnsafePointer[Float32].alloc(seq_len * embed_dim)
    
    # Pre-attention RMS LayerNorm
    for i in range(seq_len):
        rms_layer_norm(
            input + i * embed_dim,
            normalized + i * embed_dim,
            weights.ln_attn_weight,
            embed_dim,
            config.layer_norm_eps
        )
    
    # Attention
    q4_attention_forward(normalized, attn_out, weights, config, seq_len, kv_cache, position)
    
    # Residual connection
    for i in range(seq_len * embed_dim):
        output[i] = input[i] + attn_out[i]
    
    # Pre-FFN RMS LayerNorm
    for i in range(seq_len):
        rms_layer_norm(
            output + i * embed_dim,
            normalized + i * embed_dim,
            weights.ln_ffn_weight,
            embed_dim,
            config.layer_norm_eps
        )
    
    # FFN
    q4_ffn_forward(normalized, ffn_out, weights, config, seq_len)
    
    # Residual connection
    for i in range(seq_len * embed_dim):
        output[i] += ffn_out[i]
    
    normalized.free()
    attn_out.free()
    ffn_out.free()


# =============================================================================
# Q4_K_M Text Generation
# =============================================================================

struct Q4GenerationConfig:
    """Configuration for Q4_K_M text generation."""
    var max_new_tokens: Int
    var temperature: Float32
    var top_p: Float32
    var top_k: Int
    var eos_token_id: Int
    
    fn __init__(
        inout self,
        max_new_tokens: Int = 256,
        temperature: Float32 = 0.7,
        top_p: Float32 = 0.9,
        top_k: Int = 50,
        eos_token_id: Int = 2,
    ):
        self.max_new_tokens = max_new_tokens
        self.temperature = temperature
        self.top_p = top_p
        self.top_k = top_k
        self.eos_token_id = eos_token_id


fn q4_generate(
    prompt_tokens: UnsafePointer[Int],
    prompt_len: Int,
    output_tokens: UnsafePointer[Int],
    weights: Q4ModelWeights,
    gen_config: Q4GenerationConfig,
) -> Int:
    """
    Generate text using Q4_K_M quantized model.
    
    Args:
        prompt_tokens: Input prompt token IDs
        prompt_len: Prompt length
        output_tokens: Output buffer for generated tokens
        weights: Q4_K_M model weights
        gen_config: Generation configuration
    
    Returns:
        Total number of tokens (prompt + generated)
    """
    var config = weights.config
    var total_tokens = prompt_len
    
    # Copy prompt to output
    for i in range(prompt_len):
        output_tokens[i] = prompt_tokens[i]
    
    # Initialize KV caches
    var kv_caches = List[KVCache]()
    for i in range(config.num_layers):
        kv_caches.append(KVCache(config.max_seq_len, config.num_kv_heads, config.head_dim))
    
    # Working buffers
    var hidden = UnsafePointer[Float32].alloc(config.max_seq_len * config.embed_dim)
    var layer_out = UnsafePointer[Float32].alloc(config.max_seq_len * config.embed_dim)
    var final_hidden = UnsafePointer[Float32].alloc(config.embed_dim)
    var logits = UnsafePointer[Float32].alloc(config.vocab_size)
    
    # Embed prompt tokens
    for i in range(prompt_len):
        var token_id = prompt_tokens[i]
        var src = weights.token_embed + token_id * config.embed_dim
        var dst = hidden + i * config.embed_dim
        memcpy(dst.bitcast[UInt8](), src.bitcast[UInt8](), config.embed_dim * 4)
    
    # Prefill: run through all layers
    for layer_idx in range(config.num_layers):
        q4_transformer_layer_forward(
            hidden,
            layer_out,
            weights.layers[layer_idx],
            config,
            prompt_len,
            kv_caches[layer_idx],
            0  # position
        )
        # Swap buffers
        memcpy(hidden.bitcast[UInt8](), layer_out.bitcast[UInt8](), 
               prompt_len * config.embed_dim * 4)
    
    # Final layer norm on last position
    rms_layer_norm(
        hidden + (prompt_len - 1) * config.embed_dim,
        final_hidden,
        weights.ln_final_weight,
        config.embed_dim,
        config.layer_norm_eps
    )
    
    # Decode loop
    for gen_step in range(gen_config.max_new_tokens):
        # Compute logits: final_hidden @ lm_head
        for v in range(config.vocab_size):
            var sum = Float32(0.0)
            for d in range(config.embed_dim):
                sum += final_hidden[d] * weights.lm_head[d * config.vocab_size + v]
            logits[v] = sum
        
        # Apply temperature
        if gen_config.temperature > 0.0 and gen_config.temperature != 1.0:
            for i in range(config.vocab_size):
                logits[i] /= gen_config.temperature
        
        # Softmax
        var max_logit = logits[0]
        for i in range(1, config.vocab_size):
            if logits[i] > max_logit:
                max_logit = logits[i]
        
        var sum_exp = Float32(0.0)
        for i in range(config.vocab_size):
            logits[i] = exp(logits[i] - max_logit)
            sum_exp += logits[i]
        
        for i in range(config.vocab_size):
            logits[i] /= sum_exp
        
        # Sample (greedy for now)
        var next_token = 0
        var max_prob = logits[0]
        for i in range(1, config.vocab_size):
            if logits[i] > max_prob:
                max_prob = logits[i]
                next_token = i
        
        # Check EOS
        if next_token == gen_config.eos_token_id:
            break
        
        # Append token
        output_tokens[total_tokens] = next_token
        total_tokens += 1
        
        # Check max length
        if total_tokens >= config.max_seq_len:
            break
        
        # Embed new token
        var src = weights.token_embed + next_token * config.embed_dim
        memcpy(hidden.bitcast[UInt8](), src.bitcast[UInt8](), config.embed_dim * 4)
        
        # Single token forward through layers
        for layer_idx in range(config.num_layers):
            q4_transformer_layer_forward(
                hidden,
                layer_out,
                weights.layers[layer_idx],
                config,
                1,  # seq_len = 1
                kv_caches[layer_idx],
                total_tokens - 1  # position
            )
            memcpy(hidden.bitcast[UInt8](), layer_out.bitcast[UInt8](), config.embed_dim * 4)
        
        # Final layer norm
        rms_layer_norm(
            hidden,
            final_hidden,
            weights.ln_final_weight,
            config.embed_dim,
            config.layer_norm_eps
        )
    
    # Cleanup
    hidden.free()
    layer_out.free()
    final_hidden.free()
    logits.free()
    
    return total_tokens