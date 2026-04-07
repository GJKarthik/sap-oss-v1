# Mangle rules for model quantization configuration
# These rules define per-model quantization settings

# =============================================================================
# Default Quantization Settings
# =============================================================================

# Default bit width by model size
default_quantization_bits(/small, 8).    # < 3B params
default_quantization_bits(/medium, 4).   # 3B-13B params  
default_quantization_bits(/large, 4).    # > 13B params

# Default group size
default_group_size(128).

# =============================================================================
# Per-Model Quantization Configuration
# =============================================================================

# Model size classification
model_size_class(/phi3-lora, /small).
model_size_class(/llama3-8b, /medium).
model_size_class(/codellama-7b, /medium).
model_size_class(/mistral-7b, /medium).
model_size_class(/qwen2-7b, /medium).
model_size_class(/llama3-70b, /large).

# Explicit quantization bits (overrides default)
quantization_bits(/phi3-lora, 8).
quantization_bits(/llama3-8b, 4).
quantization_bits(/codellama-7b, 4).
quantization_bits(/mistral-7b, 4).
quantization_bits(/qwen2-7b, 4).
quantization_bits(/llama3-70b, 4).

# Group size per model
quantization_group_size(/phi3-lora, 128).
quantization_group_size(/llama3-8b, 128).
quantization_group_size(/codellama-7b, 128).
quantization_group_size(/mistral-7b, 128).
quantization_group_size(/qwen2-7b, 64).
quantization_group_size(/llama3-70b, 64).

# =============================================================================
# Per-Layer Precision Configuration
# =============================================================================

# Attention layers often need higher precision
layer_type_bits(/attention, /phi3-lora, 8).
layer_type_bits(/attention, /llama3-8b, 4).
layer_type_bits(/attention, /mistral-7b, 4).

# FFN layers can use lower precision
layer_type_bits(/ffn, /phi3-lora, 8).
layer_type_bits(/ffn, /llama3-8b, 4).
layer_type_bits(/ffn, /mistral-7b, 4).

# Embeddings usually need more precision
layer_type_bits(/embedding, /phi3-lora, 8).
layer_type_bits(/embedding, /llama3-8b, 8).
layer_type_bits(/embedding, /mistral-7b, 8).

# LM head precision
layer_type_bits(/lm_head, /phi3-lora, 8).
layer_type_bits(/lm_head, /llama3-8b, 8).
layer_type_bits(/lm_head, /mistral-7b, 8).

# =============================================================================
# Quantization Method Selection
# =============================================================================

# Quantization method: /gptq, /awq, /simple
quantization_method(/phi3-lora, /simple).
quantization_method(/llama3-8b, /gptq).
quantization_method(/codellama-7b, /gptq).
quantization_method(/mistral-7b, /awq).
quantization_method(/qwen2-7b, /awq).

# Symmetric vs asymmetric quantization
symmetric_quantization(/phi3-lora).
symmetric_quantization(/llama3-8b).
symmetric_quantization(/mistral-7b).
# asymmetric_quantization(/qwen2-7b). - default for AWQ

# =============================================================================
# Memory Budget Configuration
# =============================================================================

# Maximum GPU memory per model (MB)
max_gpu_memory_mb(/phi3-lora, 4096).
max_gpu_memory_mb(/llama3-8b, 8192).
max_gpu_memory_mb(/codellama-7b, 8192).
max_gpu_memory_mb(/mistral-7b, 8192).
max_gpu_memory_mb(/qwen2-7b, 8192).
max_gpu_memory_mb(/llama3-70b, 24576).

# Estimated memory after quantization (MB)
estimated_quantized_memory(/phi3-lora, 2000).
estimated_quantized_memory(/llama3-8b, 4500).
estimated_quantized_memory(/codellama-7b, 4000).
estimated_quantized_memory(/mistral-7b, 4500).
estimated_quantized_memory(/qwen2-7b, 4000).

# =============================================================================
# Quality-Memory Tradeoff Rules
# =============================================================================

# Compression ratio targets
target_compression_ratio(/phi3-lora, 2.0).   # INT8 ~2x
target_compression_ratio(/llama3-8b, 4.0).   # INT4 ~4x
target_compression_ratio(/codellama-7b, 4.0).
target_compression_ratio(/mistral-7b, 4.0).
target_compression_ratio(/qwen2-7b, 4.0).

# Acceptable perplexity increase (%)
max_perplexity_increase(/phi3-lora, 1.0).
max_perplexity_increase(/llama3-8b, 3.0).
max_perplexity_increase(/codellama-7b, 5.0).  # Code tasks more tolerant
max_perplexity_increase(/mistral-7b, 3.0).
max_perplexity_increase(/qwen2-7b, 3.0).

# =============================================================================
# Derived Rules
# =============================================================================

# Get effective bits for a model and layer type
effective_bits(Model, LayerType, Bits) :-
    layer_type_bits(LayerType, Model, Bits).

effective_bits(Model, LayerType, Bits) :-
    \+ layer_type_bits(LayerType, Model, _),
    quantization_bits(Model, Bits).

effective_bits(Model, LayerType, Bits) :-
    \+ layer_type_bits(LayerType, Model, _),
    \+ quantization_bits(Model, _),
    model_size_class(Model, SizeClass),
    default_quantization_bits(SizeClass, Bits).

# Check if quantization is recommended
should_quantize(Model) :-
    model_size_class(Model, SizeClass),
    SizeClass \= /small.

should_quantize(Model) :-
    max_gpu_memory_mb(Model, MaxMem),
    estimated_fp32_memory(Model, FP32Mem),
    FP32Mem > MaxMem.

# =============================================================================
# Tests
# =============================================================================

test_quantization_config() :-
    quantization_bits(/llama3-8b, 4),
    quantization_group_size(/llama3-8b, 128).

test_layer_precision() :-
    layer_type_bits(/embedding, /llama3-8b, 8),
    layer_type_bits(/ffn, /llama3-8b, 4).

test_compression() :-
    target_compression_ratio(/llama3-8b, 4.0).