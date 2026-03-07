# Model Architecture Specifications
# Declarative definition of transformer architectures

# ============================================================================
# Architecture registry: arch(name, description)
# ============================================================================
arch("llama", "LLaMA family (LLaMA 1/2/3, Mistral, etc.)").
arch("phi2", "Microsoft Phi-2").
arch("phi3", "Microsoft Phi-3").
arch("gemma", "Google Gemma").
arch("qwen2", "Alibaba Qwen 2").
arch("falcon", "TII Falcon").
arch("gpt2", "OpenAI GPT-2").
arch("gptj", "EleutherAI GPT-J").
arch("starcoder", "BigCode StarCoder").
arch("mamba", "State Space Models (Mamba)").

# ============================================================================
# Architecture properties: arch_prop(arch, property, value)
# ============================================================================

# LLaMA family
arch_prop("llama", "attention_type", "gqa").           # Grouped Query Attention
arch_prop("llama", "norm_type", "rms_norm").           # RMS normalization
arch_prop("llama", "activation", "silu").              # SiLU/Swish activation
arch_prop("llama", "ffn_type", "gated").               # Gated FFN (SwiGLU)
arch_prop("llama", "position_embedding", "rope").      # Rotary Position Embedding
arch_prop("llama", "bias", false).                     # No bias in linear layers
arch_prop("llama", "norm_eps_default", 1.0e-5).

# Phi-2
arch_prop("phi2", "attention_type", "mha").            # Multi-Head Attention
arch_prop("phi2", "norm_type", "layer_norm").          # Layer normalization
arch_prop("phi2", "activation", "gelu").               # GELU activation
arch_prop("phi2", "ffn_type", "standard").             # Standard FFN
arch_prop("phi2", "position_embedding", "rope").
arch_prop("phi2", "bias", true).                       # Has bias
arch_prop("phi2", "qkv_fused", true).                  # Fused QKV projection
arch_prop("phi2", "norm_eps_default", 1.0e-5).

# Phi-3
arch_prop("phi3", "attention_type", "gqa").
arch_prop("phi3", "norm_type", "rms_norm").
arch_prop("phi3", "activation", "silu").
arch_prop("phi3", "ffn_type", "gated").
arch_prop("phi3", "position_embedding", "su_rope").    # Scaled RoPE
arch_prop("phi3", "bias", false).
arch_prop("phi3", "norm_eps_default", 1.0e-5).

# Gemma
arch_prop("gemma", "attention_type", "mqa").           # Multi-Query Attention
arch_prop("gemma", "norm_type", "rms_norm").
arch_prop("gemma", "activation", "gelu").
arch_prop("gemma", "ffn_type", "gated").
arch_prop("gemma", "position_embedding", "rope").
arch_prop("gemma", "bias", false).
arch_prop("gemma", "norm_eps_default", 1.0e-6).

# ============================================================================
# Attention types
# ============================================================================
attention_type("mha", "Multi-Head Attention", false).
attention_type("gqa", "Grouped Query Attention", true).
attention_type("mqa", "Multi-Query Attention", true).

# MHA: n_kv_heads == n_heads
# GQA: n_kv_heads < n_heads (typically n_heads / 8)
# MQA: n_kv_heads == 1

kv_head_count("mha", NumHeads, NumHeads) :- num_heads(_, NumHeads).
kv_head_count("gqa", NumHeads, KVHeads) :- KVHeads = fn:div(NumHeads, 8).
kv_head_count("mqa", _, 1).

# ============================================================================
# Normalization types
# ============================================================================
norm_type("layer_norm", "Standard Layer Normalization").
norm_type("rms_norm", "Root Mean Square Normalization").

norm_has_bias("layer_norm").
norm_has_weight("layer_norm").
norm_has_weight("rms_norm").
# RMS norm has no bias (center=False)

# ============================================================================
# Activation functions
# ============================================================================
activation_fn("relu", "fn:max(0, x)").
activation_fn("gelu", "x * 0.5 * (1 + erf(x / sqrt(2)))").
activation_fn("silu", "x * sigmoid(x)").
activation_fn("swiglu", "silu(gate) * up").

# ============================================================================
# FFN types
# ============================================================================
ffn_type("standard", "Standard FFN: down(activation(up(x)))").
ffn_type("gated", "Gated FFN: down(activation(gate(x)) * up(x))").

ffn_projections("standard", ["up", "down"]).
ffn_projections("gated", ["gate", "up", "down"]).

# ============================================================================
# Position embedding types
# ============================================================================
pos_emb_type("absolute", "Absolute learned embeddings").
pos_emb_type("rope", "Rotary Position Embedding").
pos_emb_type("alibi", "Attention with Linear Biases").
pos_emb_type("su_rope", "Scaled/Uniform RoPE").

rope_config("rope", BaseFreq, Dim) :-
    rope_freq_base(BaseFreq),
    rope_dimension(Dim).

# Default RoPE parameters
rope_freq_base_default(10000.0).
rope_scaling_default(1.0).

# ============================================================================
# Layer structure templates
# ============================================================================

# Transformer layer structure: layer_op(arch, order, operation, inputs, output)
layer_op("llama", 1, "rms_norm", ["hidden"], "normed").
layer_op("llama", 2, "attention", ["normed"], "attn_out").
layer_op("llama", 3, "residual_add", ["hidden", "attn_out"], "post_attn").
layer_op("llama", 4, "rms_norm", ["post_attn"], "ffn_in").
layer_op("llama", 5, "gated_ffn", ["ffn_in"], "ffn_out").
layer_op("llama", 6, "residual_add", ["post_attn", "ffn_out"], "output").

layer_op("phi2", 1, "layer_norm", ["hidden"], "normed").
layer_op("phi2", 2, "attention", ["normed"], "attn_out").
layer_op("phi2", 3, "layer_norm", ["hidden"], "ffn_in").
layer_op("phi2", 4, "ffn", ["ffn_in"], "ffn_out").
layer_op("phi2", 5, "parallel_add", ["attn_out", "ffn_out"], "residual").
layer_op("phi2", 6, "residual_add", ["hidden", "residual"], "output").

# ============================================================================
# Model configurations (concrete instances)
# ============================================================================

# model_config(arch, name, n_layers, n_heads, n_kv_heads, dim, ff_dim, vocab, ctx)
model_config("llama", "llama-7b", 32, 32, 32, 4096, 11008, 32000, 4096).
model_config("llama", "llama-13b", 40, 40, 40, 5120, 13824, 32000, 4096).
model_config("llama", "llama-70b", 80, 64, 8, 8192, 28672, 32000, 4096).
model_config("llama", "llama-3-8b", 32, 32, 8, 4096, 14336, 128256, 8192).
model_config("llama", "mistral-7b", 32, 32, 8, 4096, 14336, 32000, 32768).

model_config("phi2", "phi-2", 32, 32, 32, 2560, 10240, 51200, 2048).

model_config("phi3", "phi-3-mini", 32, 32, 8, 3072, 8192, 32064, 4096).
model_config("phi3", "phi-3-small", 32, 32, 8, 4096, 14336, 100352, 8192).

model_config("gemma", "gemma-2b", 18, 8, 1, 2048, 16384, 256128, 8192).
model_config("gemma", "gemma-7b", 28, 16, 1, 3072, 24576, 256128, 8192).

# ============================================================================
# Derived properties
# ============================================================================

# Head dimension
head_dim(Arch, Name, HeadDim) :-
    model_config(Arch, Name, _, NumHeads, _, Dim, _, _, _),
    HeadDim = fn:div(Dim, NumHeads).

# KV cache size per layer (in elements)
kv_cache_size(Arch, Name, Size) :-
    model_config(Arch, Name, _, _, KVHeads, Dim, _, _, Ctx),
    HeadDim = fn:div(Dim, KVHeads),
    Size = fn:mul(fn:mul(Ctx, KVHeads), fn:mul(HeadDim, 2)).  # K + V

# Total parameters (approximate)
total_params(Arch, Name, Params) :-
    model_config(Arch, Name, NLayers, _, _, Dim, FFDim, Vocab, _),
    EmbedParams = fn:mul(Vocab, Dim),
    AttnParams = fn:mul(4, fn:mul(Dim, Dim)),  # Q, K, V, O
    FFNParams = fn:mul(3, fn:mul(Dim, FFDim)), # gate, up, down
    LayerParams = fn:add(AttnParams, FFNParams),
    TotalLayerParams = fn:mul(NLayers, LayerParams),
    Params = fn:add(EmbedParams, TotalLayerParams).

# Memory requirement (approximate, in bytes, for F16)
memory_bytes(Arch, Name, Bytes) :-
    total_params(Arch, Name, Params),
    Bytes = fn:mul(Params, 2).  # F16 = 2 bytes per param

# ============================================================================
# Inference compute graph
# ============================================================================

# Operations needed for forward pass
forward_op("embedding_lookup", ["token_ids"], ["embeddings"]).
forward_op("rms_norm", ["input", "weight"], ["output"]).
forward_op("layer_norm", ["input", "weight", "bias"], ["output"]).
forward_op("rope", ["q", "k", "positions"], ["q_rotated", "k_rotated"]).
forward_op("attention", ["q", "k", "v", "mask"], ["output"]).
forward_op("matmul", ["input", "weight"], ["output"]).
forward_op("silu", ["input"], ["output"]).
forward_op("gelu", ["input"], ["output"]).
forward_op("add", ["a", "b"], ["output"]).
forward_op("mul", ["a", "b"], ["output"]).
forward_op("softmax", ["input"], ["output"]).
forward_op("sample", ["logits"], ["token_id"]).