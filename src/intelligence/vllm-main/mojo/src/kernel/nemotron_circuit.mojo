"""
Nemotron-Nano-8B AWQ Inference Circuit for T4 Tensor Cores

Complete inference pipeline optimized for NVIDIA T4 GPU.
Uses INT8 AWQ quantization for linear layers and FP16 for attention.

Architecture (Nemotron-Nano-8B):
- Parameters: 8.0B
- Hidden Dim: 4096
- Layers: 32
- Attention Heads: 32 (Q), 8 (KV) - GQA 4:1
- Head Dim: 128
- FFN Dim: 14336 (3.5x expansion, SwiGLU)
- Vocab Size: 128256
- Max Context: 8192

Performance Targets on T4:
- Single-user: 80-100 TPS
- Batch 16: 700-900 TPS
- TTFT: <80ms
- Quality: ≥99% of FP16
"""

from memory import LegacyUnsafePointer
comptime UnsafePointer = LegacyUnsafePointer[mut=True, ...]
from memory.unsafe_pointer import alloc
from math import sqrt, exp

# Import kernel modules
from .t4_tensor_core import (
    AWQ_GROUP_SIZE, get_t4_capabilities, T4Capabilities,
    quantize_dynamic_int8
)
from .t4_int8_gemm import (
    gemv_int8_awq, fused_qkv_int8, fused_gate_up_int8,
    QKVProjectionConfig
)
from .t4_flash_attention_fp16 import (
    gqa_flash_attention, PagedKVCache, PagedKVBlock, KV_BLOCK_SIZE
)
from .t4_fused_kernels import (
    rmsnorm_fp16, rmsnorm_fp16_inplace,
    silu_mul_fp16, apply_rope_batch_fp16, RoPECache,
    quantize_activation_int8
)


# =============================================================================
# Nemotron-Nano-8B Model Configuration
# =============================================================================

struct NemotronConfig:
    """Nemotron-Nano-8B model configuration."""
    var hidden_dim: Int
    var num_layers: Int
    var num_heads: Int
    var num_kv_heads: Int
    var head_dim: Int
    var ff_dim: Int
    var vocab_size: Int
    var max_seq_len: Int
    var rope_theta: Float32
    var rms_norm_eps: Float32
    var awq_group_size: Int
    
    fn __init__(out self):
        self.hidden_dim = 4096
        self.num_layers = 32
        self.num_heads = 32
        self.num_kv_heads = 8
        self.head_dim = 128
        self.ff_dim = 14336
        self.vocab_size = 128256
        self.max_seq_len = 8192
        self.rope_theta = 10000.0
        self.rms_norm_eps = 1e-5
        self.awq_group_size = 128
    
    fn qkv_config(self) -> QKVProjectionConfig:
        return QKVProjectionConfig(
            self.hidden_dim,
            self.num_heads,
            self.num_kv_heads
        )
    
    fn model_size_bytes(self) -> Int:
        """Estimate model size in bytes (INT8 AWQ)."""
        # Embedding: vocab * hidden * 2 (FP16)
        var embed = self.vocab_size * self.hidden_dim * 2
        
        # Per layer (INT8 + scales)
        var qkv = self.hidden_dim * (self.num_heads + 2 * self.num_kv_heads) * self.head_dim
        var o_proj = self.hidden_dim * self.hidden_dim
        var gate_up = 2 * self.hidden_dim * self.ff_dim
        var down = self.ff_dim * self.hidden_dim
        var norms = 2 * self.hidden_dim * 2  # FP16
        var layer_size = qkv + o_proj + gate_up + down + norms
        
        # LM head: hidden * vocab * 2 (FP16 for quality)
        var lm_head = self.hidden_dim * self.vocab_size * 2
        
        return embed + self.num_layers * layer_size + lm_head
    
    fn model_size_gb(self) -> Float32:
        return Float32(self.model_size_bytes()) / (1024.0 * 1024.0 * 1024.0)


# =============================================================================
# Model Weights Structure (AWQ Quantized)
# =============================================================================

struct LayerWeights:
    """Weights for a single transformer layer (AWQ quantized)."""
    # Attention
    var wq: UnsafePointer[Int8]              # [hidden, hidden]
    var wk: UnsafePointer[Int8]              # [hidden, kv_dim]
    var wv: UnsafePointer[Int8]              # [hidden, kv_dim]
    var wo: UnsafePointer[Int8]              # [hidden, hidden]
    
    # AWQ scales for attention
    var sq: UnsafePointer[Float16]
    var sk: UnsafePointer[Float16]
    var sv: UnsafePointer[Float16]
    var so: UnsafePointer[Float16]
    
    # AWQ zeros for attention
    var zq: UnsafePointer[Int8]
    var zk: UnsafePointer[Int8]
    var zv: UnsafePointer[Int8]
    var zo: UnsafePointer[Int8]
    
    # FFN
    var w_gate: UnsafePointer[Int8]          # [hidden, ff_dim]
    var w_up: UnsafePointer[Int8]            # [hidden, ff_dim]
    var w_down: UnsafePointer[Int8]          # [ff_dim, hidden]
    
    # AWQ scales for FFN
    var s_gate: UnsafePointer[Float16]
    var s_up: UnsafePointer[Float16]
    var s_down: UnsafePointer[Float16]
    
    # AWQ zeros for FFN
    var z_gate: UnsafePointer[Int8]
    var z_up: UnsafePointer[Int8]
    var z_down: UnsafePointer[Int8]
    
    # Norms (FP16)
    var attn_norm: UnsafePointer[Float16]    # [hidden]
    var ffn_norm: UnsafePointer[Float16]     # [hidden]
    
    var is_allocated: Bool
    
    fn __init__(out self):
        self.is_allocated = False
        # Initialize all pointers to null (will be set during load)
        self.wq = UnsafePointer[Int8]()
        self.wk = UnsafePointer[Int8]()
        self.wv = UnsafePointer[Int8]()
        self.wo = UnsafePointer[Int8]()
        self.sq = UnsafePointer[Float16]()
        self.sk = UnsafePointer[Float16]()
        self.sv = UnsafePointer[Float16]()
        self.so = UnsafePointer[Float16]()
        self.zq = UnsafePointer[Int8]()
        self.zk = UnsafePointer[Int8]()
        self.zv = UnsafePointer[Int8]()
        self.zo = UnsafePointer[Int8]()
        self.w_gate = UnsafePointer[Int8]()
        self.w_up = UnsafePointer[Int8]()
        self.w_down = UnsafePointer[Int8]()
        self.s_gate = UnsafePointer[Float16]()
        self.s_up = UnsafePointer[Float16]()
        self.s_down = UnsafePointer[Float16]()
        self.z_gate = UnsafePointer[Int8]()
        self.z_up = UnsafePointer[Int8]()
        self.z_down = UnsafePointer[Int8]()
        self.attn_norm = UnsafePointer[Float16]()
        self.ffn_norm = UnsafePointer[Float16]()


struct ModelWeights:
    """Complete model weights."""
    var embedding: UnsafePointer[Float16]     # [vocab, hidden] FP16
    var layers: UnsafePointer[LayerWeights]   # [num_layers]
    var final_norm: UnsafePointer[Float16]    # [hidden]
    var lm_head: UnsafePointer[Float16]       # [hidden, vocab] FP16
    var num_layers: Int
    var is_loaded: Bool
    
    fn __init__(out self, num_layers: Int):
        self.num_layers = num_layers
        self.is_loaded = False
        self.embedding = UnsafePointer[Float16]()
        self.layers = alloc[LayerWeights](num_layers)
        for i in range(num_layers):
            self.layers[i] = LayerWeights()
        self.final_norm = UnsafePointer[Float16]()
        self.lm_head = UnsafePointer[Float16]()


# =============================================================================
# Inference State (KV Cache + Activations)
# =============================================================================

struct InferenceState:
    """Mutable state for inference (KV cache, activations)."""
    # KV cache per layer per head
    var kv_caches: UnsafePointer[PagedKVCache]
    var num_layers: Int
    var num_kv_heads: Int
    
    # Current position in sequence
    var position: Int
    
    # Activation buffers (reused across layers)
    var hidden: UnsafePointer[Float16]         # [hidden_dim]
    var residual: UnsafePointer[Float16]       # [hidden_dim]
    var normed: UnsafePointer[Float16]         # [hidden_dim]
    var q: UnsafePointer[Float16]              # [num_heads * head_dim]
    var k: UnsafePointer[Float16]              # [num_kv_heads * head_dim]
    var v: UnsafePointer[Float16]              # [num_kv_heads * head_dim]
    var attn_out: UnsafePointer[Float16]       # [num_heads * head_dim]
    var gate: UnsafePointer[Float16]           # [ff_dim]
    var up: UnsafePointer[Float16]             # [ff_dim]
    var ff_hidden: UnsafePointer[Float16]      # [ff_dim]
    var ff_out: UnsafePointer[Float16]         # [hidden_dim]
    
    # INT8 quantized activations
    var hidden_int8: UnsafePointer[Int8]       # [hidden_dim]
    var ff_hidden_int8: UnsafePointer[Int8]    # [ff_dim]
    
    # Logits buffer
    var logits: UnsafePointer[Float32]         # [vocab_size]
    
    # RoPE cache
    var rope_cache: RoPECache
    
    fn __init__(out self, config: NemotronConfig):
        self.num_layers = config.num_layers
        self.num_kv_heads = config.num_kv_heads
        self.position = 0
        
        # Allocate KV caches
        self.kv_caches = alloc[PagedKVCache](config.num_layers * config.num_kv_heads)
        for i in range(config.num_layers * config.num_kv_heads):
            self.kv_caches[i] = PagedKVCache(config.max_seq_len, config.head_dim)
        
        # Allocate activation buffers
        self.hidden = alloc[Float16](config.hidden_dim)
        self.residual = alloc[Float16](config.hidden_dim)
        self.normed = alloc[Float16](config.hidden_dim)
        self.q = alloc[Float16](config.num_heads * config.head_dim)
        self.k = alloc[Float16](config.num_kv_heads * config.head_dim)
        self.v = alloc[Float16](config.num_kv_heads * config.head_dim)
        self.attn_out = alloc[Float16](config.num_heads * config.head_dim)
        self.gate = alloc[Float16](config.ff_dim)
        self.up = alloc[Float16](config.ff_dim)
        self.ff_hidden = alloc[Float16](config.ff_dim)
        self.ff_out = alloc[Float16](config.hidden_dim)
        self.hidden_int8 = alloc[Int8](config.hidden_dim)
        self.ff_hidden_int8 = alloc[Int8](config.ff_dim)
        self.logits = alloc[Float32](config.vocab_size)
        
        # Initialize RoPE cache
        self.rope_cache = RoPECache(config.max_seq_len, config.head_dim, config.rope_theta)
    
    fn reset(mut self):
        """Reset state for new sequence."""
        self.position = 0
        # Clear KV caches would go here
    
    fn deinit(mut self):
        for i in range(self.num_layers * self.num_kv_heads):
            self.kv_caches[i].deinit()
        self.kv_caches.free()
        self.hidden.free()
        self.residual.free()
        self.normed.free()
        self.q.free()
        self.k.free()
        self.v.free()
        self.attn_out.free()
        self.gate.free()
        self.up.free()
        self.ff_hidden.free()
        self.ff_out.free()
        self.hidden_int8.free()
        self.ff_hidden_int8.free()
        self.logits.free()
        self.rope_cache.deinit()


# =============================================================================
# Nemotron Inference Circuit
# =============================================================================

struct NemotronCircuit:
    """
    Complete Nemotron-Nano-8B inference circuit.
    
    Optimized for T4 Tensor Cores:
    - INT8 AWQ for linear layers (130 TOPS)
    - FP16 Flash Attention (65 TFLOPS)
    - Fused kernels for activation functions
    - PagedKV cache for memory efficiency
    """
    var config: NemotronConfig
    var weights: ModelWeights
    var state: InferenceState
    var t4_caps: T4Capabilities
    var is_initialized: Bool
    
    fn __init__(out self):
        self.config = NemotronConfig()
        self.weights = ModelWeights(self.config.num_layers)
        self.state = InferenceState(self.config)
        self.t4_caps = get_t4_capabilities()
        self.is_initialized = False
    
    fn mark_weights_loaded(mut self):
        """Mark circuit ready after external weight pointers are populated."""
        self.weights.is_loaded = True
        self.is_initialized = True
    
    fn _zero_logits(mut self):
        for i in range(self.config.vocab_size):
            self.state.logits[i] = 0.0
    
    fn forward_token(mut self, token_id: Int) -> UnsafePointer[Float32]:
        """
        Forward pass for a single token (decode phase).
        
        Returns pointer to logits [vocab_size].
        """
        if not self.is_initialized or not self.weights.is_loaded:
            print("NemotronCircuit error: weights are not loaded.")
            self._zero_logits()
            return self.state.logits
        
        if token_id < 0 or token_id >= self.config.vocab_size:
            print("NemotronCircuit error: token_id out of range:", token_id)
            self._zero_logits()
            return self.state.logits
        
        if self.state.position >= self.config.max_seq_len:
            print("NemotronCircuit error: max sequence length exceeded:", self.state.position)
            self._zero_logits()
            return self.state.logits
        
        # 1. Embedding lookup
        self._embed_token(token_id)
        
        # 2. Process through transformer layers
        for layer in range(self.config.num_layers):
            self._forward_layer(layer)
        
        # 3. Final normalization
        rmsnorm_fp16(
            self.state.hidden,
            self.state.hidden,
            self.weights.final_norm,
            self.config.hidden_dim,
            self.config.rms_norm_eps
        )
        
        # 4. LM head projection
        self._compute_logits()
        
        # 5. Update position
        self.state.position += 1
        
        return self.state.logits
    
    fn _embed_token(mut self, token_id: Int):
        """Look up token embedding."""
        var embed_ptr = self.weights.embedding + token_id * self.config.hidden_dim
        for i in range(self.config.hidden_dim):
            self.state.hidden[i] = embed_ptr[i]
    
    fn _forward_layer(mut self, layer_idx: Int):
        """
        Forward pass through a single transformer layer.
        
        Structure:
        1. Attention block (with pre-norm)
        2. Residual connection
        3. FFN block (with pre-norm)
        4. Residual connection
        """
        var layer = self.weights.layers[layer_idx]
        
        # Save residual
        for i in range(self.config.hidden_dim):
            self.state.residual[i] = self.state.hidden[i]
        
        # ========== Attention Block ==========
        
        # Pre-attention RMSNorm
        rmsnorm_fp16(
            self.state.normed,
            self.state.hidden,
            layer.attn_norm,
            self.config.hidden_dim,
            self.config.rms_norm_eps
        )
        
        # Quantize for INT8 projection
        var act_scale = quantize_activation_int8(
            self.state.hidden_int8,
            self.state.normed,
            self.config.hidden_dim
        )
        
        # QKV projection (INT8 Tensor Cores)
        fused_qkv_int8(
            self.state.q, self.state.k, self.state.v,
            self.state.hidden_int8,
            layer.wq, layer.wk, layer.wv,
            layer.sq, layer.sk, layer.sv,
            layer.zq, layer.zk, layer.zv,
            self.config.qkv_config(),
            act_scale
        )
        
        # Apply RoPE
        self.state.rope_cache.apply(self.state.q, self.state.position)
        for h in range(self.config.num_kv_heads):
            var k_head = self.state.k + h * self.config.head_dim
            self.state.rope_cache.apply(k_head, self.state.position)
        
        # Update KV cache with current token's K/V for each KV head
        self._append_kv_to_cache(layer_idx)
        
        # Single-token decode attention over cached K/V
        self._single_token_attention(layer_idx)
        
        # Output projection (INT8)
        var attn_act_scale = quantize_activation_int8(
            self.state.hidden_int8,
            self.state.attn_out,
            self.config.hidden_dim
        )
        gemv_int8_awq(
            self.state.hidden,
            self.state.hidden_int8,
            layer.wo,
            layer.so,
            layer.zo,
            self.config.hidden_dim,
            self.config.hidden_dim,
            attn_act_scale,
            self.config.awq_group_size
        )
        
        # Residual connection
        for i in range(self.config.hidden_dim):
            self.state.hidden[i] = Float16(
                Float32(self.state.hidden[i]) + Float32(self.state.residual[i])
            )
        
        # ========== FFN Block ==========
        
        # Save residual
        for i in range(self.config.hidden_dim):
            self.state.residual[i] = self.state.hidden[i]
        
        # Pre-FFN RMSNorm
        rmsnorm_fp16(
            self.state.normed,
            self.state.hidden,
            layer.ffn_norm,
            self.config.hidden_dim,
            self.config.rms_norm_eps
        )
        
        # Quantize for INT8 FFN
        var ffn_act_scale = quantize_activation_int8(
            self.state.hidden_int8,
            self.state.normed,
            self.config.hidden_dim
        )
        
        # Gate + Up projection (INT8, fused)
        fused_gate_up_int8(
            self.state.gate, self.state.up,
            self.state.hidden_int8,
            layer.w_gate, layer.w_up,
            layer.s_gate, layer.s_up,
            layer.z_gate, layer.z_up,
            self.config.hidden_dim,
            self.config.ff_dim,
            ffn_act_scale,
            self.config.awq_group_size
        )
        
        # SwiGLU activation (fused SiLU * multiply)
        silu_mul_fp16(
            self.state.ff_hidden,
            self.state.gate,
            self.state.up,
            self.config.ff_dim
        )
        
        # Down projection (INT8)
        var down_act_scale = quantize_activation_int8(
            self.state.ff_hidden_int8,
            self.state.ff_hidden,
            self.config.ff_dim
        )
        gemv_int8_awq(
            self.state.hidden,
            self.state.ff_hidden_int8,
            layer.w_down,
            layer.s_down,
            layer.z_down,
            self.config.ff_dim,
            self.config.hidden_dim,
            down_act_scale,
            self.config.awq_group_size
        )
        
        # Residual connection
        for i in range(self.config.hidden_dim):
            self.state.hidden[i] = Float16(
                Float32(self.state.hidden[i]) + Float32(self.state.residual[i])
            )
    
    fn _single_token_attention(mut self, layer_idx: Int):
        """
        Attention for single token decode over cached K/V.
        
        Q: [1, num_heads, head_dim]
        K,V from cache: [seq_len, num_kv_heads, head_dim]
        """
        var scale = Float32(1.0 / sqrt(Float32(self.config.head_dim)))
        var heads_per_kv = self.config.num_heads // self.config.num_kv_heads
        
        # For each query head
        for h in range(self.config.num_heads):
            var kv_h = h // heads_per_kv
            var q_head = self.state.q + h * self.config.head_dim
            var out_head = self.state.attn_out + h * self.config.head_dim
            var cache_idx = layer_idx * self.config.num_kv_heads + kv_h
            var cache = self.state.kv_caches[cache_idx]
            
            # Initialize output
            for d in range(self.config.head_dim):
                out_head[d] = Float16(0.0)
            
            # Pass 1: max score (for stable softmax)
            var row_max: Float32 = -1e30
            for b in range(cache.num_blocks):
                var block = cache.blocks[b]
                for t in range(block.num_tokens):
                    var k_ptr = block.keys + t * self.config.head_dim
                    var score: Float32 = 0.0
                    for d in range(self.config.head_dim):
                        score += Float32(q_head[d]) * Float32(k_ptr[d])
                    score *= scale
                    if score > row_max:
                        row_max = score
            
            # Pass 2: accumulate softmax-weighted values
            if row_max <= -1e29:
                continue
            
            var denom: Float32 = 0.0
            for b in range(cache.num_blocks):
                var block = cache.blocks[b]
                for t in range(block.num_tokens):
                    var k_ptr = block.keys + t * self.config.head_dim
                    var v_ptr = block.values + t * self.config.head_dim
                    var score: Float32 = 0.0
                    for d in range(self.config.head_dim):
                        score += Float32(q_head[d]) * Float32(k_ptr[d])
                    
                    var weight = exp(score * scale - row_max)
                    denom += weight
                    for d in range(self.config.head_dim):
                        out_head[d] = Float16(Float32(out_head[d]) + weight * Float32(v_ptr[d]))
            
            if denom > 0.0:
                var inv_denom = 1.0 / denom
                for d in range(self.config.head_dim):
                    out_head[d] = Float16(Float32(out_head[d]) * inv_denom)
    
    fn _append_kv_to_cache(mut self, layer_idx: Int):
        """Append current token's K/V vectors to per-layer paged KV caches."""
        for h in range(self.config.num_kv_heads):
            var cache_idx = layer_idx * self.config.num_kv_heads + h
            var k_head = self.state.k + h * self.config.head_dim
            var v_head = self.state.v + h * self.config.head_dim
            if not self.state.kv_caches[cache_idx].append(k_head, v_head):
                print("NemotronCircuit error: KV cache full at layer", layer_idx, "head", h)
    
    fn _compute_logits(mut self):
        """Compute output logits using LM head (FP16 for quality)."""
        # LM head: hidden @ lm_head^T → logits
        for v in range(self.config.vocab_size):
            var dot: Float32 = 0.0
            var lm_col = self.weights.lm_head + v * self.config.hidden_dim
            for d in range(self.config.hidden_dim):
                dot += Float32(self.state.hidden[d]) * Float32(lm_col[d])
            self.state.logits[v] = dot
    
    fn deinit(mut self):
        self.state.deinit()


# =============================================================================
# Performance Estimation
# =============================================================================

fn estimate_decode_latency_ms(config: NemotronConfig, kv_len: Int) -> Float32:
    """
    Estimate single-token decode latency on T4.
    
    Components:
    1. QKV projection: ~50μs (INT8 GEMV)
    2. Attention: scales with kv_len
    3. Output projection: ~25μs
    4. FFN (gate+up+down): ~150μs
    5. Norms + activations: ~20μs
    
    Per layer: ~250μs + attention
    Total: ~8ms for 32 layers (short context)
    """
    var qkv_us: Float32 = 50.0  # QKV projection
    var attn_us = Float32(kv_len) * 0.05  # Attention scales with context
    var o_proj_us: Float32 = 25.0
    var ffn_us: Float32 = 150.0
    var misc_us: Float32 = 20.0
    
    var per_layer_us = qkv_us + attn_us + o_proj_us + ffn_us + misc_us
    var total_us = per_layer_us * Float32(config.num_layers)
    
    # Add embedding + lm_head
    total_us += 50.0  # Embedding lookup
    total_us += 500.0  # LM head (vocab is large)
    
    return total_us / 1000.0  # Convert to ms


fn estimate_throughput_tps(config: NemotronConfig, batch_size: Int, kv_len: Int) -> Float32:
    """Estimate tokens per second for batched inference."""
    var single_latency_ms = estimate_decode_latency_ms(config, kv_len)
    # Batching amortizes some overhead
    var batch_efficiency = 0.7 + 0.3 * (1.0 - 1.0 / Float32(batch_size + 1))
    var effective_latency = single_latency_ms / batch_efficiency
    return 1000.0 / effective_latency * Float32(batch_size)


fn print_performance_estimates():
    """Print performance estimates for Nemotron-Nano-8B on T4."""
    var config = NemotronConfig()
    
    print("=== Nemotron-Nano-8B T4 Performance Estimates ===")
    print("Model size (AWQ):", config.model_size_gb(), "GB")
    print("")
    print("Single-token decode latency:")
    print("  Context 128:", estimate_decode_latency_ms(config, 128), "ms")
    print("  Context 1024:", estimate_decode_latency_ms(config, 1024), "ms")
    print("  Context 4096:", estimate_decode_latency_ms(config, 4096), "ms")
    print("")
    print("Throughput (batch=1):", estimate_throughput_tps(config, 1, 512), "TPS")
    print("Throughput (batch=8):", estimate_throughput_tps(config, 8, 512), "TPS")
    print("Throughput (batch=16):", estimate_throughput_tps(config, 16, 512), "TPS")
