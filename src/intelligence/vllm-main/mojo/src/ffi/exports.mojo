"""
C FFI Exports for Private LLM Inference Engine

Stateful engine API for Zig/C integration via dlopen.
All functions follow the naming convention: pllm_*

Design: Stateful engine handle — create once, load model, generate tokens.
Replaces the old "stateless preset" design which hardcoded model configs
and returned mock tokens.
"""

from memory import UnsafePointer, memcpy, memset_zero
from math import sqrt

from ..inference import ModelConfig, ModelWeights, GenerationConfig, generate
from ..inference import TransformerLayerWeights, embed_tokens, transformer_layer_forward
from ..kernel.attention import KVCache
from ..kernel import MatrixView, matmul_simd, rms_layer_norm

alias FloatType = DType.float32

# =============================================================================
# Error Codes
# =============================================================================

alias PLLM_SUCCESS: Int32 = 0
alias PLLM_ERROR_NULL_POINTER: Int32 = -1
alias PLLM_ERROR_INVALID_HANDLE: Int32 = -2
alias PLLM_ERROR_OUT_OF_MEMORY: Int32 = -3
alias PLLM_ERROR_INVALID_CONFIG: Int32 = -4
alias PLLM_ERROR_LOAD_FAILED: Int32 = -5
alias PLLM_ERROR_INFERENCE_FAILED: Int32 = -6
alias PLLM_ERROR_BUFFER_TOO_SMALL: Int32 = -7
alias PLLM_ERROR_MODEL_NOT_LOADED: Int32 = -8

# Q4_K_M constants
alias QK_K: Int = 256
alias BLOCK_SIZE_Q4_K_M: Int = 142

# Config field IDs for pllm_engine_get_config
alias PLLM_CONFIG_VOCAB_SIZE: Int32 = 0
alias PLLM_CONFIG_EMBED_DIM: Int32 = 1
alias PLLM_CONFIG_NUM_HEADS: Int32 = 2
alias PLLM_CONFIG_NUM_KV_HEADS: Int32 = 3
alias PLLM_CONFIG_NUM_LAYERS: Int32 = 4
alias PLLM_CONFIG_FFN_DIM: Int32 = 5
alias PLLM_CONFIG_MAX_SEQ_LEN: Int32 = 6
alias PLLM_CONFIG_HEAD_DIM: Int32 = 7


# =============================================================================
# Engine Handle — holds loaded model state
# =============================================================================

struct EngineState:
    """Mutable engine state holding model weights and inference buffers."""
    var config: ModelConfig
    var weights: UnsafePointer[ModelWeights]
    var kv_caches: UnsafePointer[KVCache]
    var loaded: Bool
    var hidden_buf: UnsafePointer[Scalar[FloatType]]
    var logits_buf: UnsafePointer[Scalar[FloatType]]
    var layer_buf: UnsafePointer[Scalar[FloatType]]
    
    fn __init__(inout self):
        self.config = ModelConfig()
        self.weights = UnsafePointer[ModelWeights]()
        self.kv_caches = UnsafePointer[KVCache]()
        self.loaded = False
        self.hidden_buf = UnsafePointer[Scalar[FloatType]]()
        self.logits_buf = UnsafePointer[Scalar[FloatType]]()
        self.layer_buf = UnsafePointer[Scalar[FloatType]]()
    
    fn load_model(inout self, config: ModelConfig) -> Int32:
        """Allocate weights and inference buffers for the given config."""
        self.config = config
        
        # Allocate model weights
        self.weights = UnsafePointer[ModelWeights].alloc(1)
        self.weights[0] = ModelWeights(config)
        
        # Allocate KV caches (one per layer)
        self.kv_caches = UnsafePointer[KVCache].alloc(config.num_layers)
        for i in range(config.num_layers):
            self.kv_caches[i] = KVCache(config.max_seq_len, config.num_heads, config.head_dim)
        
        # Allocate persistent inference buffers (reused across forward passes)
        self.hidden_buf = UnsafePointer[Scalar[FloatType]].alloc(config.max_seq_len * config.embed_dim)
        self.logits_buf = UnsafePointer[Scalar[FloatType]].alloc(config.vocab_size)
        self.layer_buf = UnsafePointer[Scalar[FloatType]].alloc(config.max_seq_len * config.embed_dim)
        
        self.loaded = True
        return PLLM_SUCCESS
    
    fn is_loaded(self) -> Bool:
        return self.loaded
    
    fn get_config_field(self, field_id: Int32) -> Int32:
        """Return any config field dynamically by field ID."""
        if field_id == PLLM_CONFIG_VOCAB_SIZE:
            return Int32(self.config.vocab_size)
        elif field_id == PLLM_CONFIG_EMBED_DIM:
            return Int32(self.config.embed_dim)
        elif field_id == PLLM_CONFIG_NUM_HEADS:
            return Int32(self.config.num_heads)
        elif field_id == PLLM_CONFIG_NUM_KV_HEADS:
            return Int32(self.config.num_kv_heads)
        elif field_id == PLLM_CONFIG_NUM_LAYERS:
            return Int32(self.config.num_layers)
        elif field_id == PLLM_CONFIG_FFN_DIM:
            return Int32(self.config.ffn_dim)
        elif field_id == PLLM_CONFIG_MAX_SEQ_LEN:
            return Int32(self.config.max_seq_len)
        elif field_id == PLLM_CONFIG_HEAD_DIM:
            return Int32(self.config.head_dim)
        return -1
    
    fn estimate_memory_mb(self) -> Float32:
        """Compute memory estimate from the loaded config (dynamic, not hardcoded)."""
        var dim = self.config.embed_dim
        var ffn = self.config.ffn_dim
        var vocab = self.config.vocab_size
        var n_layers = self.config.num_layers
        var n_heads = self.config.num_heads
        var n_kv_heads = self.config.num_kv_heads
        var head_dim = self.config.head_dim
        var kv_dim = n_kv_heads * head_dim
        
        # Embedding + LM head (FP32)
        var embed_bytes = vocab * dim * 4
        var lm_head_bytes = dim * vocab * 4
        
        # Per-layer weights in Q4_K_M
        var blocks_wq = (dim * dim + QK_K - 1) // QK_K
        var blocks_wk = (dim * kv_dim + QK_K - 1) // QK_K
        var blocks_wv = (dim * kv_dim + QK_K - 1) // QK_K
        var blocks_wo = (dim * dim + QK_K - 1) // QK_K
        var blocks_gate = (dim * ffn + QK_K - 1) // QK_K
        var blocks_up = (dim * ffn + QK_K - 1) // QK_K
        var blocks_down = (ffn * dim + QK_K - 1) // QK_K
        var layer_q4 = (blocks_wq + blocks_wk + blocks_wv + blocks_wo +
                        blocks_gate + blocks_up + blocks_down) * BLOCK_SIZE_Q4_K_M
        var ln_bytes = dim * 4 * 2  # 2 layer norms per layer
        
        var total = embed_bytes + n_layers * (layer_q4 + ln_bytes) + dim * 4 + lm_head_bytes
        return Float32(total) / (1024.0 * 1024.0)
    
    fn estimate_kv_cache_mb(self, seq_len: Int, batch_size: Int) -> Float32:
        """Dynamic KV cache memory estimate."""
        var kv_dim = self.config.num_kv_heads * self.config.head_dim
        var cache_bytes = 2 * self.config.num_layers * batch_size * seq_len * kv_dim * 4
        return Float32(cache_bytes) / (1024.0 * 1024.0)


# =============================================================================
# Version Info
# =============================================================================

@export
fn pllm_version_major() -> Int32:
    return 2

@export
fn pllm_version_minor() -> Int32:
    return 0

@export
fn pllm_version_patch() -> Int32:
    return 0


# =============================================================================
# Basic FFI Test Functions
# =============================================================================

@export
fn pllm_add(a: Int32, b: Int32) -> Int32:
    """Simple add function for FFI sanity check."""
    return a + b

@export
fn pllm_multiply(a: Int32, b: Int32) -> Int32:
    """Simple multiply function for FFI sanity check."""
    return a * b

@export
fn pllm_compute_q4km_blocks(rows: Int32, cols: Int32) -> Int32:
    """Compute number of Q4_K_M blocks for given dimensions."""
    var total = Int(rows) * Int(cols)
    return Int32((total + QK_K - 1) // QK_K)

@export
fn pllm_compute_q4km_bytes(rows: Int32, cols: Int32) -> Int32:
    """Compute bytes needed for Q4_K_M tensor."""
    var blocks = (Int(rows) * Int(cols) + QK_K - 1) // QK_K
    return Int32(blocks * BLOCK_SIZE_Q4_K_M)

@export
fn pllm_get_qk_k() -> Int32:
    return Int32(QK_K)

@export
fn pllm_get_block_size_q4km() -> Int32:
    return Int32(BLOCK_SIZE_Q4_K_M)


# =============================================================================
# Stateful Engine API — replaces all per-model-preset stubs
# =============================================================================

@export
fn pllm_engine_create() -> UnsafePointer[UInt8]:
    """
    Create a new inference engine handle.
    Returns opaque pointer; null on allocation failure.
    Caller must call pllm_engine_destroy when done.
    """
    var state = UnsafePointer[EngineState].alloc(1)
    state[0] = EngineState()
    return state.bitcast[UInt8]()


@export
fn pllm_engine_load_model(
    handle: UnsafePointer[UInt8],
    vocab_size: Int32,
    embed_dim: Int32,
    num_heads: Int32,
    num_kv_heads: Int32,
    num_layers: Int32,
    ffn_dim: Int32,
    max_seq_len: Int32
) -> Int32:
    """
    Load a model with the given config. Allocates weights and KV caches.
    Config is set dynamically from the caller (Zig reads it from GGUF metadata).
    
    Returns PLLM_SUCCESS or error code.
    """
    if not handle:
        return PLLM_ERROR_NULL_POINTER
    
    var state = handle.bitcast[EngineState]()
    var config = ModelConfig(
        vocab_size=Int(vocab_size),
        embed_dim=Int(embed_dim),
        num_heads=Int(num_heads),
        num_kv_heads=Int(num_kv_heads),
        num_layers=Int(num_layers),
        ffn_dim=Int(ffn_dim),
        max_seq_len=Int(max_seq_len)
    )
    return state[0].load_model(config)


@export
fn pllm_engine_get_config(handle: UnsafePointer[UInt8], field_id: Int32) -> Int32:
    """
    Get any config value from the loaded model dynamically.
    
    field_id: PLLM_CONFIG_VOCAB_SIZE (0), PLLM_CONFIG_EMBED_DIM (1), etc.
    Returns -1 if handle is null, model not loaded, or unknown field.
    """
    if not handle:
        return -1
    var state = handle.bitcast[EngineState]()
    if not state[0].is_loaded():
        return -1
    return state[0].get_config_field(field_id)


@export
fn pllm_engine_get_memory_mb(handle: UnsafePointer[UInt8]) -> Float32:
    """Estimate memory for the loaded model in Q4_K_M format (MB)."""
    if not handle:
        return -1.0
    var state = handle.bitcast[EngineState]()
    if not state[0].is_loaded():
        return -1.0
    return state[0].estimate_memory_mb()


@export
fn pllm_engine_get_kv_cache_mb(
    handle: UnsafePointer[UInt8], seq_len: Int32, batch_size: Int32
) -> Float32:
    """Estimate KV cache memory for the loaded model (MB)."""
    if not handle:
        return -1.0
    var state = handle.bitcast[EngineState]()
    if not state[0].is_loaded():
        return -1.0
    return state[0].estimate_kv_cache_mb(Int(seq_len), Int(batch_size))


@export
fn pllm_engine_generate(
    handle: UnsafePointer[UInt8],
    prompt_tokens: UnsafePointer[Int32],
    prompt_len: Int32,
    output_tokens: UnsafePointer[Int32],
    max_new_tokens: Int32,
    temperature: Float32,
    top_p: Float32,
    eos_token_id: Int32
) -> Int32:
    """
    Run token generation on the loaded model.
    
    Args:
        handle: Engine handle from pllm_engine_create.
        prompt_tokens: Input token IDs.
        prompt_len: Number of prompt tokens.
        output_tokens: Output buffer (must hold prompt_len + max_new_tokens).
        max_new_tokens: Maximum tokens to generate.
        temperature: Sampling temperature (0.0 = greedy).
        top_p: Nucleus sampling threshold.
        eos_token_id: Stop token ID.
    
    Returns:
        Total tokens (prompt + generated) on success, or negative error code.
    """
    if not handle:
        return PLLM_ERROR_NULL_POINTER
    if not prompt_tokens or not output_tokens:
        return PLLM_ERROR_NULL_POINTER
    
    var state = handle.bitcast[EngineState]()
    if not state[0].is_loaded():
        return PLLM_ERROR_MODEL_NOT_LOADED
    
    # Convert Int32 tokens to Int for internal API
    var int_prompt = UnsafePointer[Int].alloc(Int(prompt_len))
    for i in range(Int(prompt_len)):
        int_prompt[i] = Int(prompt_tokens[i])
    
    var int_output = UnsafePointer[Int].alloc(Int(prompt_len) + Int(max_new_tokens))
    
    var gen_config = GenerationConfig(
        max_new_tokens=Int(max_new_tokens),
        temperature=temperature,
        top_p=top_p,
        do_sample=temperature > 0.0,
        eos_token_id=Int(eos_token_id)
    )
    
    var total = generate(
        int_prompt,
        Int(prompt_len),
        int_output,
        state[0].weights[0],
        gen_config
    )
    
    # Convert back to Int32
    for i in range(total):
        output_tokens[i] = Int32(int_output[i])
    
    int_prompt.free()
    int_output.free()
    
    return Int32(total)


@export
fn pllm_engine_forward_single(
    handle: UnsafePointer[UInt8],
    token_id: Int32,
    position: Int32,
    logits_out: UnsafePointer[Float32],
    logits_capacity: Int32
) -> Int32:
    """
    Single-token forward pass. Populates KV cache and writes logits.
    
    Returns vocab_size on success (= number of logits written), or error code.
    """
    if not handle:
        return PLLM_ERROR_NULL_POINTER
    if not logits_out:
        return PLLM_ERROR_NULL_POINTER
    
    var state = handle.bitcast[EngineState]()
    if not state[0].is_loaded():
        return PLLM_ERROR_MODEL_NOT_LOADED
    
    var config = state[0].config
    var vocab = config.vocab_size
    
    if Int(logits_capacity) < vocab:
        return PLLM_ERROR_BUFFER_TOO_SMALL
    
    var weights = state[0].weights[0]
    var embed_dim = config.embed_dim
    var hidden = state[0].hidden_buf
    var layer_out = state[0].layer_buf
    
    # Embed token
    var tok = Int(token_id)
    memcpy(hidden, weights.token_embed + tok * embed_dim, embed_dim)
    
    # Run through transformer layers using fused kernels
    var layer_in = hidden
    for l in range(config.num_layers):
        transformer_layer_forward(
            layer_in, layer_out,
            weights.layers[l], config,
            1, state[0].kv_caches[l],
            Int(position)
        )
        # Swap
        var tmp = layer_in
        layer_in = layer_out
        layer_out = tmp
    
    # Final norm
    var normed = UnsafePointer[Scalar[FloatType]].alloc(embed_dim)
    rms_layer_norm(layer_in, normed, weights.ln_final_weight, embed_dim, config.layer_norm_eps)
    
    # LM head → logits (SIMD matmul)
    var h_mat = MatrixView(normed, 1, embed_dim)
    var lm_mat = MatrixView(weights.lm_head, embed_dim, vocab)
    var l_mat = MatrixView(state[0].logits_buf, 1, vocab)
    matmul_simd(h_mat, lm_mat, l_mat)
    
    # Copy to caller buffer
    memcpy(logits_out.bitcast[Scalar[FloatType]](), state[0].logits_buf, vocab)
    normed.free()
    
    return Int32(vocab)


@export
fn pllm_engine_destroy(handle: UnsafePointer[UInt8]) -> Int32:
    """Free all engine resources."""
    if not handle:
        return PLLM_ERROR_NULL_POINTER
    
    var state = handle.bitcast[EngineState]()
    if state[0].is_loaded():
        state[0].hidden_buf.free()
        state[0].logits_buf.free()
        state[0].layer_buf.free()
        state[0].kv_caches.free()
        state[0].weights.free()
    
    state.free()
    return PLLM_SUCCESS


# =============================================================================
# Backward-compatible preset helpers (thin wrappers over engine API)
# =============================================================================

fn _estimate_memory_for_config(
    vocab: Int, dim: Int, n_heads: Int, n_kv_heads: Int,
    n_layers: Int, ffn: Int
) -> Float32:
    """Reusable memory estimator — replaces 4 copy-pasted functions."""
    var head_dim = dim // n_heads
    var kv_dim = n_kv_heads * head_dim
    var embed_bytes = vocab * dim * 4
    var blocks_wq = (dim * dim + QK_K - 1) // QK_K
    var blocks_wk = (dim * kv_dim + QK_K - 1) // QK_K
    var blocks_wv = (dim * kv_dim + QK_K - 1) // QK_K
    var blocks_wo = (dim * dim + QK_K - 1) // QK_K
    var blocks_gate = (dim * ffn + QK_K - 1) // QK_K
    var blocks_up = (dim * ffn + QK_K - 1) // QK_K
    var blocks_down = (ffn * dim + QK_K - 1) // QK_K
    var layer_q4 = (blocks_wq + blocks_wk + blocks_wv + blocks_wo +
                    blocks_gate + blocks_up + blocks_down) * BLOCK_SIZE_Q4_K_M
    var ln_bytes = dim * 4 * 2
    var total = embed_bytes + n_layers * (layer_q4 + ln_bytes) + dim * 4 + vocab * dim * 4
    return Float32(total) / (1024.0 * 1024.0)

# Model IDs (kept for backward compat with Zig callers)
alias MODEL_ID_LLAMA_1B: Int32 = 1
alias MODEL_ID_PHI2: Int32 = 2
alias MODEL_ID_LLAMA_7B: Int32 = 3
alias MODEL_ID_MISTRAL_7B: Int32 = 4

@export
fn pllm_get_vocab_size(model_id: Int32) -> Int32:
    if model_id == MODEL_ID_LLAMA_1B: return 32000
    elif model_id == MODEL_ID_PHI2: return 51200
    elif model_id == MODEL_ID_LLAMA_7B: return 32000
    elif model_id == MODEL_ID_MISTRAL_7B: return 32000
    return -1

@export
fn pllm_get_embed_dim(model_id: Int32) -> Int32:
    if model_id == MODEL_ID_LLAMA_1B: return 2048
    elif model_id == MODEL_ID_PHI2: return 2560
    elif model_id == MODEL_ID_LLAMA_7B: return 4096
    elif model_id == MODEL_ID_MISTRAL_7B: return 4096
    return -1

@export
fn pllm_get_num_layers(model_id: Int32) -> Int32:
    if model_id == MODEL_ID_LLAMA_1B: return 22
    elif model_id == MODEL_ID_PHI2: return 32
    elif model_id == MODEL_ID_LLAMA_7B: return 32
    elif model_id == MODEL_ID_MISTRAL_7B: return 32
    return -1

@export
fn pllm_get_num_heads(model_id: Int32) -> Int32:
    if model_id == MODEL_ID_LLAMA_1B: return 32
    elif model_id == MODEL_ID_PHI2: return 32
    elif model_id == MODEL_ID_LLAMA_7B: return 32
    elif model_id == MODEL_ID_MISTRAL_7B: return 32
    return -1

@export
fn pllm_get_num_kv_heads(model_id: Int32) -> Int32:
    if model_id == MODEL_ID_LLAMA_1B: return 8
    elif model_id == MODEL_ID_PHI2: return 32
    elif model_id == MODEL_ID_LLAMA_7B: return 32
    elif model_id == MODEL_ID_MISTRAL_7B: return 8
    return -1

@export
fn pllm_get_ffn_dim(model_id: Int32) -> Int32:
    if model_id == MODEL_ID_LLAMA_1B: return 5632
    elif model_id == MODEL_ID_PHI2: return 10240
    elif model_id == MODEL_ID_LLAMA_7B: return 11008
    elif model_id == MODEL_ID_MISTRAL_7B: return 14336
    return -1

@export
fn pllm_get_max_seq_len(model_id: Int32) -> Int32:
    if model_id == MODEL_ID_LLAMA_1B: return 2048
    elif model_id == MODEL_ID_PHI2: return 2048
    elif model_id == MODEL_ID_LLAMA_7B: return 4096
    elif model_id == MODEL_ID_MISTRAL_7B: return 32768
    return -1

@export
fn pllm_get_memory_mb(model_id: Int32) -> Float32:
    if model_id == MODEL_ID_LLAMA_1B: return _estimate_memory_for_config(32000, 2048, 32, 8, 22, 5632)
    elif model_id == MODEL_ID_PHI2: return _estimate_memory_for_config(51200, 2560, 32, 32, 32, 10240)
    elif model_id == MODEL_ID_LLAMA_7B: return _estimate_memory_for_config(32000, 4096, 32, 32, 32, 11008)
    elif model_id == MODEL_ID_MISTRAL_7B: return _estimate_memory_for_config(32000, 4096, 32, 8, 32, 14336)
    return -1.0

@export
fn pllm_get_supported_models() -> Int32:
    return 4

# =============================================================================
# TensorRT-compatible FFI — delegates to EngineState
#
# These functions keep the pllm_trt_* symbol names so existing Zig callers
# (main.zig) link without changes. Internally they create/use EngineState
# instead of returning mock tokens.
# =============================================================================

alias PLLM_QUANT_FP16: Int32 = 0
alias PLLM_QUANT_INT8: Int32 = 1
alias PLLM_QUANT_AWQ: Int32 = 2
alias PLLM_QUANT_FP8: Int32 = 3

alias PLLM_BATCH_QUEUED: Int32 = 0
alias PLLM_BATCH_RUNNING: Int32 = 1
alias PLLM_BATCH_COMPLETE: Int32 = 2
alias PLLM_BATCH_ERROR: Int32 = -1


@export
fn pllm_trt_init_engine(
    engine_path: UnsafePointer[UInt8],
    quant_mode: Int32,
    paged_kv_cache: Bool,
    max_inflight_requests: Int32
) -> UnsafePointer[UInt8]:
    """
    Initialize inference engine. Creates an EngineState handle.
    The engine_path is reserved for future GGUF/ONNX model loading.
    """
    if quant_mode < PLLM_QUANT_FP16 or quant_mode > PLLM_QUANT_FP8:
        return UnsafePointer[UInt8]()

    # Create a real engine handle (EngineState)
    return pllm_engine_create()


@export
fn pllm_trt_enqueue_request(
    engine_handle: UnsafePointer[UInt8],
    request_id: Int32,
    prompt_tokens: UnsafePointer[Int32],
    prompt_len: Int32,
    max_new_tokens: Int32
) -> Int32:
    """Enqueue is a no-op until async batching is implemented; returns QUEUED."""
    if not engine_handle:
        return PLLM_BATCH_ERROR
    return PLLM_BATCH_QUEUED


@export
fn pllm_trt_poll_request(
    engine_handle: UnsafePointer[UInt8],
    request_id: Int32,
    output_tokens: UnsafePointer[Int32],
    output_capacity: Int32
) -> Int32:
    """Poll is a no-op until async batching is implemented; returns RUNNING."""
    if not engine_handle:
        return PLLM_BATCH_ERROR
    return PLLM_BATCH_RUNNING


@export
fn pllm_trt_get_inflight_count(engine_handle: UnsafePointer[UInt8]) -> Int32:
    """Return 0 (no async requests in flight yet)."""
    if not engine_handle:
        return PLLM_BATCH_ERROR
    return 0


@export
fn pllm_trt_generate(
    engine_handle: UnsafePointer[UInt8],
    prompt_tokens: UnsafePointer[Int32],
    prompt_len: Int32,
    output_tokens: UnsafePointer[Int32],
    max_tokens: Int32
) -> Int32:
    """
    Synchronous generation — delegates to pllm_engine_generate with
    default sampling params (greedy, no top-p).
    """
    return pllm_engine_generate(
        engine_handle,
        prompt_tokens,
        prompt_len,
        output_tokens,
        max_tokens,
        0.0,    # temperature=0 → greedy
        1.0,    # top_p (unused when greedy)
        2       # eos_token_id (standard)
    )


@export
fn pllm_trt_free_engine(engine_handle: UnsafePointer[UInt8]) -> Int32:
    """Release engine resources."""
    return pllm_engine_destroy(engine_handle)