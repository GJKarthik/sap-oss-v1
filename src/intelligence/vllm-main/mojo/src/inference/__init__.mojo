"""
LLM inference pipeline implementation in Mojo.

Provides:
- Transformer layer forward pass
- Full model inference
- Text generation with various sampling strategies
- Memory-efficient generation
"""

from sys.info import simdwidthof
from algorithm import vectorize, parallelize
from memory import memset_zero, memcpy
from math import exp, sqrt

from ..kernel import MatrixView, matmul_simd, softmax_simd, layer_norm, rms_layer_norm, gelu, silu
from ..kernel.attention import scaled_dot_product_attention, flash_attention, apply_rope_inplace, KVCache
from ..kernel.fused_ops import fused_rmsnorm_linear, fused_qkv_rope, fused_swiglu_ffn
from ..tokenizer import encode_text, sample_token_greedy, apply_temperature, apply_top_p


alias FloatType = DType.float32
alias simd_width = simdwidthof[FloatType]()


# =============================================================================
# Model Configuration
# =============================================================================

struct ModelConfig:
    """Configuration for transformer model."""
    var vocab_size: Int
    var embed_dim: Int
    var num_heads: Int
    var num_layers: Int
    var ffn_dim: Int
    var max_seq_len: Int
    var head_dim: Int
    var rope_base: Float32
    var layer_norm_eps: Float32
    var use_rms_norm: Bool
    var activation: String  # "gelu" or "silu"
    
    fn __init__(
        inout self,
        vocab_size: Int = 32000,
        embed_dim: Int = 4096,
        num_heads: Int = 32,
        num_layers: Int = 32,
        ffn_dim: Int = 11008,
        max_seq_len: Int = 4096,
        rope_base: Float32 = 10000.0,
        layer_norm_eps: Float32 = 1e-6,
        use_rms_norm: Bool = True,
        activation: String = "silu"
    ):
        self.vocab_size = vocab_size
        self.embed_dim = embed_dim
        self.num_heads = num_heads
        self.num_layers = num_layers
        self.ffn_dim = ffn_dim
        self.max_seq_len = max_seq_len
        self.head_dim = embed_dim // num_heads
        self.rope_base = rope_base
        self.layer_norm_eps = layer_norm_eps
        self.use_rms_norm = use_rms_norm
        self.activation = activation


# =============================================================================
# Layer Weights
# =============================================================================

struct TransformerLayerWeights:
    """Weights for a single transformer layer."""
    # Attention weights
    var wq: UnsafePointer[Scalar[FloatType]]  # [embed_dim, embed_dim]
    var wk: UnsafePointer[Scalar[FloatType]]  # [embed_dim, embed_dim]
    var wv: UnsafePointer[Scalar[FloatType]]  # [embed_dim, embed_dim]
    var wo: UnsafePointer[Scalar[FloatType]]  # [embed_dim, embed_dim]
    
    # FFN weights
    var w1: UnsafePointer[Scalar[FloatType]]  # [embed_dim, ffn_dim]
    var w2: UnsafePointer[Scalar[FloatType]]  # [ffn_dim, embed_dim]
    var w3: UnsafePointer[Scalar[FloatType]]  # [embed_dim, ffn_dim] (for gated FFN)
    
    # Layer norm weights
    var ln1_weight: UnsafePointer[Scalar[FloatType]]  # [embed_dim]
    var ln2_weight: UnsafePointer[Scalar[FloatType]]  # [embed_dim]
    
    var embed_dim: Int
    var ffn_dim: Int
    
    fn __init__(inout self, embed_dim: Int, ffn_dim: Int):
        self.embed_dim = embed_dim
        self.ffn_dim = ffn_dim
        
        # Allocate attention weights
        self.wq = UnsafePointer[Scalar[FloatType]].alloc(embed_dim * embed_dim)
        self.wk = UnsafePointer[Scalar[FloatType]].alloc(embed_dim * embed_dim)
        self.wv = UnsafePointer[Scalar[FloatType]].alloc(embed_dim * embed_dim)
        self.wo = UnsafePointer[Scalar[FloatType]].alloc(embed_dim * embed_dim)
        
        # Allocate FFN weights
        self.w1 = UnsafePointer[Scalar[FloatType]].alloc(embed_dim * ffn_dim)
        self.w2 = UnsafePointer[Scalar[FloatType]].alloc(ffn_dim * embed_dim)
        self.w3 = UnsafePointer[Scalar[FloatType]].alloc(embed_dim * ffn_dim)
        
        # Allocate layer norm weights
        self.ln1_weight = UnsafePointer[Scalar[FloatType]].alloc(embed_dim)
        self.ln2_weight = UnsafePointer[Scalar[FloatType]].alloc(embed_dim)
        
        # Initialize to zeros
        memset_zero(self.wq, embed_dim * embed_dim)
        memset_zero(self.wk, embed_dim * embed_dim)
        memset_zero(self.wv, embed_dim * embed_dim)
        memset_zero(self.wo, embed_dim * embed_dim)
        memset_zero(self.w1, embed_dim * ffn_dim)
        memset_zero(self.w2, ffn_dim * embed_dim)
        memset_zero(self.w3, embed_dim * ffn_dim)
        
        # Initialize layer norm weights to 1.0
        for i in range(embed_dim):
            self.ln1_weight[i] = 1.0
            self.ln2_weight[i] = 1.0
    
    fn __del__(owned self):
        self.wq.free()
        self.wk.free()
        self.wv.free()
        self.wo.free()
        self.w1.free()
        self.w2.free()
        self.w3.free()
        self.ln1_weight.free()
        self.ln2_weight.free()


struct ModelWeights:
    """Complete model weights."""
    var config: ModelConfig
    var token_embed: UnsafePointer[Scalar[FloatType]]  # [vocab_size, embed_dim]
    var layers: UnsafePointer[TransformerLayerWeights]
    var ln_final_weight: UnsafePointer[Scalar[FloatType]]  # [embed_dim]
    var lm_head: UnsafePointer[Scalar[FloatType]]  # [embed_dim, vocab_size]
    
    fn __init__(inout self, config: ModelConfig):
        self.config = config
        
        # Allocate embedding table
        self.token_embed = UnsafePointer[Scalar[FloatType]].alloc(
            config.vocab_size * config.embed_dim
        )
        memset_zero(self.token_embed, config.vocab_size * config.embed_dim)
        
        # Allocate layer weights
        self.layers = UnsafePointer[TransformerLayerWeights].alloc(config.num_layers)
        for i in range(config.num_layers):
            self.layers[i] = TransformerLayerWeights(config.embed_dim, config.ffn_dim)
        
        # Allocate final layer norm
        self.ln_final_weight = UnsafePointer[Scalar[FloatType]].alloc(config.embed_dim)
        for i in range(config.embed_dim):
            self.ln_final_weight[i] = 1.0
        
        # Allocate LM head (output projection)
        self.lm_head = UnsafePointer[Scalar[FloatType]].alloc(
            config.embed_dim * config.vocab_size
        )
        memset_zero(self.lm_head, config.embed_dim * config.vocab_size)
    
    fn __del__(owned self):
        self.token_embed.free()
        self.layers.free()
        self.ln_final_weight.free()
        self.lm_head.free()


# =============================================================================
# Forward Pass
# =============================================================================

fn embed_tokens(
    token_ids: UnsafePointer[Int],
    num_tokens: Int,
    embeddings: UnsafePointer[Scalar[FloatType]],
    token_embed_table: UnsafePointer[Scalar[FloatType]],
    embed_dim: Int
):
    """
    Look up token embeddings.
    
    Args:
        token_ids: Input token IDs [num_tokens]
        num_tokens: Number of tokens
        embeddings: Output embeddings [num_tokens, embed_dim]
        token_embed_table: Embedding table [vocab_size, embed_dim]
        embed_dim: Embedding dimension
    """
    for i in range(num_tokens):
        var token_id = token_ids[i]
        var src = token_embed_table + token_id * embed_dim
        var dst = embeddings + i * embed_dim
        memcpy(dst, src, embed_dim)


fn transformer_layer_forward(
    input: UnsafePointer[Scalar[FloatType]],
    output: UnsafePointer[Scalar[FloatType]],
    weights: TransformerLayerWeights,
    config: ModelConfig,
    seq_len: Int,
    kv_cache: KVCache,
    position_offset: Int = 0
):
    """
    Forward pass through a single transformer layer.
    
    Uses fused kernels from kernel/fused_ops.mojo and flash_attention
    from kernel/attention.mojo for ~2-5× speedup over the scalar path.
    
    Args:
        input: Input tensor [seq_len, embed_dim]
        output: Output tensor [seq_len, embed_dim]
        weights: Layer weights
        config: Model configuration
        seq_len: Sequence length
        kv_cache: Key-value cache for incremental decoding
        position_offset: Position offset for RoPE
    """
    var embed_dim = config.embed_dim
    var num_heads = config.num_heads
    var head_dim = config.head_dim
    var ffn_dim = config.ffn_dim
    var num_kv_heads = num_heads  # Full MHA for now (GQA support can be added)
    
    # Allocate intermediate buffers
    var q_proj = UnsafePointer[Scalar[FloatType]].alloc(seq_len * embed_dim)
    var k_proj = UnsafePointer[Scalar[FloatType]].alloc(seq_len * embed_dim)
    var v_proj = UnsafePointer[Scalar[FloatType]].alloc(seq_len * embed_dim)
    var attn_out = UnsafePointer[Scalar[FloatType]].alloc(seq_len * embed_dim)
    var proj_out = UnsafePointer[Scalar[FloatType]].alloc(seq_len * embed_dim)
    var ffn_out = UnsafePointer[Scalar[FloatType]].alloc(seq_len * embed_dim)
    
    # --- Pre-attention: Fused RMSNorm + QKV projection + RoPE ---
    # Process each token position with the fused kernel
    for i in range(seq_len):
        var x = input + i * embed_dim
        var q = q_proj + i * embed_dim
        var k = k_proj + i * embed_dim
        var v = v_proj + i * embed_dim
        
        # Fused: RMSNorm → Q/K/V projection → RoPE
        # First do RMSNorm inline, then use fused_qkv_rope
        var normalized = UnsafePointer[Scalar[FloatType]].alloc(embed_dim)
        rms_layer_norm(x, normalized, weights.ln1_weight, embed_dim, config.layer_norm_eps)
        
        fused_qkv_rope(
            q, k, v,
            normalized,
            weights.wq, weights.wk, weights.wv,
            position_offset + i,
            embed_dim, num_heads, num_kv_heads, head_dim,
            config.rope_base
        )
        normalized.free()
    
    # Update KV cache
    kv_cache.append(k_proj, v_proj, seq_len)
    
    # --- Attention: Use flash_attention for O(N) memory ---
    memset_zero(attn_out, seq_len * embed_dim)
    var scale = 1.0 / sqrt(Float32(head_dim))
    
    for h in range(num_heads):
        var head_offset = h * head_dim
        
        # Extract Q head for this attention head
        var q_head = UnsafePointer[Scalar[FloatType]].alloc(seq_len * head_dim)
        var out_head = UnsafePointer[Scalar[FloatType]].alloc(seq_len * head_dim)
        
        for i in range(seq_len):
            memcpy(q_head + i * head_dim, q_proj + i * embed_dim + head_offset, head_dim)
        
        # Use flash_attention (tiled + online softmax) instead of scalar loops
        flash_attention(
            q_head,
            kv_cache.get_keys() + head_offset,
            kv_cache.get_values() + head_offset,
            out_head,
            seq_len,
            head_dim,
            scale
        )
        
        # Copy back to multi-head output
        for i in range(seq_len):
            memcpy(attn_out + i * embed_dim + head_offset, out_head + i * head_dim, head_dim)
        
        q_head.free()
        out_head.free()
    
    # Output projection + residual
    var attn_mat = MatrixView(attn_out, seq_len, embed_dim)
    var wo_mat = MatrixView(weights.wo, embed_dim, embed_dim)
    var proj_mat = MatrixView(proj_out, seq_len, embed_dim)
    matmul_simd(attn_mat, wo_mat, proj_mat)
    
    for i in range(seq_len * embed_dim):
        output[i] = input[i] + proj_out[i]
    
    # --- FFN: Fused SwiGLU ---
    # Process each token position with the fused SwiGLU kernel
    for i in range(seq_len):
        var x = output + i * embed_dim
        var ffn_x = ffn_out + i * embed_dim
        
        # Fused RMSNorm for pre-FFN
        var normalized = UnsafePointer[Scalar[FloatType]].alloc(embed_dim)
        rms_layer_norm(x, normalized, weights.ln2_weight, embed_dim, config.layer_norm_eps)
        
        # Fused SwiGLU: gate, up, silu, mul, down in 2 passes instead of 5 ops
        fused_swiglu_ffn(
            ffn_x,
            normalized,
            weights.w3,   # gate weights
            weights.w1,   # up weights
            weights.w2,   # down weights
            embed_dim,
            ffn_dim
        )
        normalized.free()
    
    # Final residual
    for i in range(seq_len * embed_dim):
        output[i] += ffn_out[i]
    
    # Free buffers
    q_proj.free()
    k_proj.free()
    v_proj.free()
    attn_out.free()
    proj_out.free()
    ffn_out.free()


# =============================================================================
# Generation
# =============================================================================

struct GenerationConfig:
    """Configuration for text generation."""
    var max_new_tokens: Int
    var temperature: Float32
    var top_p: Float32
    var top_k: Int
    var repetition_penalty: Float32
    var do_sample: Bool
    var eos_token_id: Int
    var pad_token_id: Int
    
    fn __init__(
        inout self,
        max_new_tokens: Int = 256,
        temperature: Float32 = 0.7,
        top_p: Float32 = 0.9,
        top_k: Int = 50,
        repetition_penalty: Float32 = 1.1,
        do_sample: Bool = True,
        eos_token_id: Int = 2,
        pad_token_id: Int = 0
    ):
        self.max_new_tokens = max_new_tokens
        self.temperature = temperature
        self.top_p = top_p
        self.top_k = top_k
        self.repetition_penalty = repetition_penalty
        self.do_sample = do_sample
        self.eos_token_id = eos_token_id
        self.pad_token_id = pad_token_id


fn generate(
    prompt_tokens: UnsafePointer[Int],
    prompt_len: Int,
    output_tokens: UnsafePointer[Int],
    weights: ModelWeights,
    gen_config: GenerationConfig
) -> Int:
    """
    Generate text tokens given a prompt.
    
    Args:
        prompt_tokens: Input prompt token IDs
        prompt_len: Prompt length
        output_tokens: Output buffer for generated tokens
        weights: Model weights
        gen_config: Generation configuration
    
    Returns:
        Number of tokens generated (including prompt)
    """
    var config = weights.config
    var total_tokens = prompt_len
    
    # Copy prompt to output
    for i in range(prompt_len):
        output_tokens[i] = prompt_tokens[i]
    
    # Initialize KV cache
    var kv_caches = UnsafePointer[KVCache].alloc(config.num_layers)
    for i in range(config.num_layers):
        kv_caches[i] = KVCache(config.max_seq_len, config.num_heads, config.head_dim)
    
    # Allocate working buffers
    var hidden = UnsafePointer[Scalar[FloatType]].alloc(config.max_seq_len * config.embed_dim)
    var logits = UnsafePointer[Scalar[FloatType]].alloc(config.vocab_size)
    
    # Process prompt (prefill)
    embed_tokens(prompt_tokens, prompt_len, hidden, weights.token_embed, config.embed_dim)
    
    # Run through layers
    var layer_input = hidden
    var layer_output = UnsafePointer[Scalar[FloatType]].alloc(config.max_seq_len * config.embed_dim)
    
    for layer_idx in range(config.num_layers):
        transformer_layer_forward(
            layer_input,
            layer_output,
            weights.layers[layer_idx],
            config,
            prompt_len,
            kv_caches[layer_idx],
            0  # position_offset
        )
        # Swap buffers
        var tmp = layer_input
        layer_input = layer_output
        layer_output = tmp
    
    # Final layer norm on last position
    var final_hidden = UnsafePointer[Scalar[FloatType]].alloc(config.embed_dim)
    rms_layer_norm(
        layer_input + (prompt_len - 1) * config.embed_dim,
        final_hidden,
        weights.ln_final_weight,
        config.embed_dim,
        config.layer_norm_eps
    )
    
    # Generate new tokens
    for gen_step in range(gen_config.max_new_tokens):
        # Compute logits: hidden @ lm_head (using SIMD matmul instead of scalar loops)
        var hidden_mat = MatrixView(final_hidden, 1, config.embed_dim)
        var lm_head_mat = MatrixView(weights.lm_head, config.embed_dim, config.vocab_size)
        var logits_mat = MatrixView(logits, 1, config.vocab_size)
        matmul_simd(hidden_mat, lm_head_mat, logits_mat)
        
        # Apply sampling
        if gen_config.do_sample:
            apply_temperature(logits, config.vocab_size, gen_config.temperature)
            apply_top_p(logits, config.vocab_size, gen_config.top_p)
        
        # Sample or greedy decode
        var next_token = sample_token_greedy(logits, config.vocab_size)
        
        # Check for EOS
        if next_token == gen_config.eos_token_id:
            break
        
        # Append token
        output_tokens[total_tokens] = next_token
        total_tokens += 1
        
        # Check max length
        if total_tokens >= config.max_seq_len:
            break
        
        # Prepare for next iteration
        # Embed new token
        embed_tokens(
            output_tokens + total_tokens - 1,
            1,
            hidden,
            weights.token_embed,
            config.embed_dim
        )
        
        # Run through layers (single token)
        for layer_idx in range(config.num_layers):
            transformer_layer_forward(
                hidden,
                layer_output,
                weights.layers[layer_idx],
                config,
                1,
                kv_caches[layer_idx],
                total_tokens - 1
            )
            memcpy(hidden, layer_output, config.embed_dim)
        
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
    layer_output.free()
    logits.free()
    final_hidden.free()
    kv_caches.free()
    
    return total_tokens