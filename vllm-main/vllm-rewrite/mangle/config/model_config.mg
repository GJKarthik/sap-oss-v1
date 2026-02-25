# vLLM Model Configuration Validation Rules
#
# This file defines declarative rules for validating model configurations.
# These rules ensure that model, hardware, and quantization settings are
# compatible and within supported limits.

# =============================================================================
# HARDWARE LIMITS
# =============================================================================

# GPU memory limits (in GB)
fn gpu_memory_a100_80gb() = 80.
fn gpu_memory_a100_40gb() = 40.
fn gpu_memory_h100() = 80.
fn gpu_memory_l40() = 48.
fn gpu_memory_a10() = 24.
fn gpu_memory_t4() = 16.

# Maximum supported configurations
fn max_tensor_parallel() = 8.
fn max_pipeline_parallel() = 8.
fn max_data_parallel() = 64.

# Block size options
fn valid_block_sizes() = [8, 16, 32].

# =============================================================================
# MODEL CONFIGURATION VALIDATION
# =============================================================================

# Valid model configuration
valid_model_config(Config) :-
    valid_model_name(Config.model_name),
    valid_dtype(Config.dtype),
    valid_parallel_config(Config),
    valid_memory_config(Config),
    valid_quantization_config(Config).

# Model name validation
valid_model_name(Name) :-
    Name != "",
    string_length(Name) > 0,
    string_length(Name) < 256.

# Data type validation
valid_dtype(Dtype) :-
    Dtype in ["float16", "bfloat16", "float32", "auto"].

# =============================================================================
# PARALLELISM VALIDATION
# =============================================================================

# Valid parallel configuration
valid_parallel_config(Config) :-
    Config.tensor_parallel_size > 0,
    Config.tensor_parallel_size <= max_tensor_parallel(),
    Config.pipeline_parallel_size > 0,
    Config.pipeline_parallel_size <= max_pipeline_parallel(),
    valid_tp_pp_combination(Config).

# TP and PP must divide number of layers evenly
valid_tp_pp_combination(Config) :-
    total_gpus(Config, TotalGPUs),
    TotalGPUs == Config.tensor_parallel_size * Config.pipeline_parallel_size,
    TotalGPUs <= available_gpus().

total_gpus(Config, Total) :-
    Total = Config.tensor_parallel_size * Config.pipeline_parallel_size.

# Attention heads must be divisible by TP size
valid_attention_tp(Config) :-
    Config.num_attention_heads mod Config.tensor_parallel_size == 0.

valid_attention_tp(Config) :-
    Config.num_key_value_heads mod Config.tensor_parallel_size == 0.

# =============================================================================
# MEMORY CONFIGURATION
# =============================================================================

# Valid memory configuration
valid_memory_config(Config) :-
    Config.gpu_memory_utilization > 0,
    Config.gpu_memory_utilization <= 1.0,
    Config.block_size in valid_block_sizes(),
    sufficient_memory(Config).

# Check if there's sufficient memory for the model
sufficient_memory(Config) :-
    estimated_model_memory(Config, ModelMemory),
    estimated_kv_cache_memory(Config, KVMemory),
    available_gpu_memory(Config, AvailableMemory),
    ModelMemory + KVMemory <= AvailableMemory.

# Estimate model memory in GB
estimated_model_memory(Config, Memory) :-
    Config.num_parameters > 0,
    bytes_per_param(Config, BytesPerParam),
    Memory = (Config.num_parameters * BytesPerParam) / (1024 * 1024 * 1024).

# Bytes per parameter based on dtype
bytes_per_param(Config, 2) :-
    Config.dtype in ["float16", "bfloat16"].

bytes_per_param(Config, 4) :-
    Config.dtype == "float32".

bytes_per_param(Config, 1) :-
    Config.quantization in ["int8", "fp8"].

bytes_per_param(Config, 0.5) :-
    Config.quantization == "int4".

# Estimate KV cache memory
estimated_kv_cache_memory(Config, Memory) :-
    Config.max_model_len > 0,
    Config.num_layers > 0,
    kv_cache_per_token(Config, PerToken),
    Memory = (Config.max_model_len * PerToken * Config.max_num_seqs) / (1024 * 1024 * 1024).

# KV cache bytes per token
kv_cache_per_token(Config, Bytes) :-
    Bytes = 2 * Config.num_layers * Config.num_key_value_heads * Config.head_dim * 2.  # 2 for K+V, 2 for fp16

# =============================================================================
# QUANTIZATION VALIDATION
# =============================================================================

# Valid quantization configuration
valid_quantization_config(Config) :-
    Config.quantization == null.  # No quantization is valid

valid_quantization_config(Config) :-
    Config.quantization != null,
    valid_quantization_method(Config.quantization),
    quantization_compatible(Config).

# Valid quantization methods
valid_quantization_method(Method) :-
    Method in ["awq", "gptq", "squeezellm", "fp8", "int8", "int4", "marlin", "gguf"].

# Check quantization compatibility with model
quantization_compatible(Config) :-
    Config.quantization == "awq",
    Config.dtype in ["float16", "bfloat16"].

quantization_compatible(Config) :-
    Config.quantization == "gptq",
    Config.dtype in ["float16", "bfloat16"].

quantization_compatible(Config) :-
    Config.quantization == "fp8",
    gpu_supports_fp8(Config.gpu_type).

quantization_compatible(Config) :-
    Config.quantization == "int8".

quantization_compatible(Config) :-
    Config.quantization == "int4".

quantization_compatible(Config) :-
    Config.quantization == "marlin",
    Config.tensor_parallel_size == 1.  # Marlin doesn't support TP yet

# GPU FP8 support
gpu_supports_fp8(GPUType) :-
    GPUType in ["h100", "h200", "l40s", "ada"].

# =============================================================================
# MODEL ARCHITECTURE VALIDATION
# =============================================================================

# Valid model architecture
valid_architecture(Config) :-
    Config.num_layers > 0,
    Config.hidden_size > 0,
    Config.num_attention_heads > 0,
    Config.num_key_value_heads > 0,
    Config.num_key_value_heads <= Config.num_attention_heads,
    valid_head_dim(Config).

# Head dimension must match
valid_head_dim(Config) :-
    Config.head_dim == Config.hidden_size / Config.num_attention_heads.

# GQA validation (grouped query attention)
valid_gqa_config(Config) :-
    Config.num_attention_heads mod Config.num_key_value_heads == 0.

# =============================================================================
# CONTEXT LENGTH VALIDATION
# =============================================================================

# Valid context length configuration
valid_context_config(Config) :-
    Config.max_model_len > 0,
    Config.max_model_len <= model_max_context_length(Config.model_type),
    rope_scaling_valid(Config).

# Model-specific max context lengths
model_max_context_length("llama") = 128000.
model_max_context_length("llama2") = 4096.
model_max_context_length("llama3") = 128000.
model_max_context_length("mistral") = 32768.
model_max_context_length("mixtral") = 32768.
model_max_context_length("qwen2") = 131072.
model_max_context_length("phi3") = 128000.
model_max_context_length(_) = 4096.  # Default

# RoPE scaling validation
rope_scaling_valid(Config) :-
    Config.rope_scaling == null.

rope_scaling_valid(Config) :-
    Config.rope_scaling != null,
    Config.rope_scaling.type in ["linear", "dynamic", "yarn", "longrope"],
    Config.rope_scaling.factor > 1.0.

# =============================================================================
# LoRA CONFIGURATION
# =============================================================================

# Valid LoRA configuration
valid_lora_config(Config) :-
    Config.enable_lora == false.

valid_lora_config(Config) :-
    Config.enable_lora == true,
    Config.max_loras > 0,
    Config.max_loras <= 64,
    Config.max_lora_rank > 0,
    Config.max_lora_rank <= 256,
    lora_compatible_with_quantization(Config).

# LoRA and quantization compatibility
lora_compatible_with_quantization(Config) :-
    Config.quantization == null.

lora_compatible_with_quantization(Config) :-
    Config.quantization in ["fp8", "int8"].

# =============================================================================
# SPECULATIVE DECODING VALIDATION
# =============================================================================

# Valid speculative decoding configuration
valid_speculative_config(Config) :-
    Config.speculative_model == null.

valid_speculative_config(Config) :-
    Config.speculative_model != null,
    Config.num_speculative_tokens > 0,
    Config.num_speculative_tokens <= 16,
    speculative_model_compatible(Config).

# Draft model compatibility
speculative_model_compatible(Config) :-
    Config.speculative_model.vocab_size == Config.vocab_size.

# =============================================================================
# ERROR MESSAGES
# =============================================================================

# Generate human-readable error for invalid configs
config_error(Config, "Invalid tensor parallel size") :-
    Config.tensor_parallel_size <= 0.

config_error(Config, "TP size exceeds available GPUs") :-
    Config.tensor_parallel_size > available_gpus().

config_error(Config, "Attention heads not divisible by TP size") :-
    Config.num_attention_heads mod Config.tensor_parallel_size != 0.

config_error(Config, "Insufficient GPU memory for model") :-
    not sufficient_memory(Config).

config_error(Config, "Quantization method not supported for this GPU") :-
    Config.quantization == "fp8",
    not gpu_supports_fp8(Config.gpu_type).

config_error(Config, "Invalid context length") :-
    Config.max_model_len > model_max_context_length(Config.model_type).

config_error(Config, "LoRA incompatible with quantization method") :-
    Config.enable_lora == true,
    not lora_compatible_with_quantization(Config).

# =============================================================================
# RECOMMENDATIONS
# =============================================================================

# Recommend optimal configurations
recommend_tp_size(Config, RecommendedTP) :-
    Config.num_attention_heads >= 64,
    available_gpus() >= 8,
    RecommendedTP = 8.

recommend_tp_size(Config, RecommendedTP) :-
    Config.num_attention_heads >= 32,
    available_gpus() >= 4,
    RecommendedTP = 4.

recommend_tp_size(Config, RecommendedTP) :-
    Config.num_attention_heads >= 16,
    available_gpus() >= 2,
    RecommendedTP = 2.

recommend_tp_size(Config, 1) :-
    available_gpus() == 1.

# Recommend quantization based on model size and GPU
recommend_quantization(Config, "fp8") :-
    Config.num_parameters >= 70e9,
    gpu_supports_fp8(Config.gpu_type).

recommend_quantization(Config, "awq") :-
    Config.num_parameters >= 30e9,
    not gpu_supports_fp8(Config.gpu_type).

recommend_quantization(Config, null) :-
    Config.num_parameters < 30e9.