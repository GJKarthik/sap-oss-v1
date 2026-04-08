# ============================================================================
# Model Optimizer - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for model optimization MCP communication.
# OpenAI-compatible API for inference and model management.
# ============================================================================

# 1. Service Registry
service_registry("modelopt-inference",  "http://localhost:8001/v1",   "qwen3.5-int8").
service_registry("modelopt-quantize",   "http://localhost:8001/mcp",  "nvidia-modelopt").
service_registry("modelopt-prune",      "http://localhost:8001/mcp",  "minitron-pruner").

# 2. Intent Routing (OpenAI-compatible)
resolve_service_for_intent(/chat_completion, URL) :-
    service_registry("modelopt-inference", URL, _).

resolve_service_for_intent(/models, URL) :-
    service_registry("modelopt-inference", URL, _).

resolve_service_for_intent(/embeddings, URL) :-
    service_registry("modelopt-inference", URL, _).

resolve_service_for_intent(/quantization, URL) :-
    service_registry("modelopt-quantize", URL, _).

resolve_service_for_intent(/pruning, URL) :-
    service_registry("modelopt-prune", URL, _).

# 3. Tool Routing (MCP Tools)
tool_service("chat_completions", "modelopt-inference").
tool_service("list_models", "modelopt-inference").
tool_service("get_model", "modelopt-inference").
tool_service("create_embedding", "modelopt-inference").
tool_service("quantize_model", "modelopt-quantize").
tool_service("prune_model", "modelopt-prune").
tool_service("create_optimization_job", "modelopt-quantize").
tool_service("get_gpu_status", "modelopt-quantize").

# ============================================================================
# 4. Model Compatibility Rules
# Facts about GPU capabilities and quantization formats
# ============================================================================

# GPU Compute Capability Facts
gpu_compute_capability("Tesla T4", 7.5).
gpu_compute_capability("A100", 8.0).
gpu_compute_capability("H100", 9.0).
gpu_compute_capability("RTX 4090", 8.9).

# Quantization Format Support by Compute Capability
quant_format_requires("int8", 7.0).
quant_format_requires("int4_awq", 7.0).
quant_format_requires("w4a16", 7.0).
quant_format_requires("fp8", 8.9).
quant_format_requires("nvfp4", 9.0).

# Check if GPU supports a quantization format
gpu_supports_format(GPU, Format) :-
    gpu_compute_capability(GPU, Capability),
    quant_format_requires(Format, Required),
    Capability >= Required.

# T4 specifically supported formats
t4_supported_format("int8").
t4_supported_format("int4_awq").
t4_supported_format("w4a16").

# T4 unsupported formats
t4_unsupported_format("fp8").
t4_unsupported_format("nvfp4").

# ============================================================================
# 5. Model Size and Memory Rules
# ============================================================================

# Model base sizes (in GB, FP16)
model_size("qwen3.5-0.6b", 1.2).
model_size("qwen3.5-1.8b", 3.6).
model_size("qwen3.5-4b", 8.0).
model_size("qwen3.5-9b", 18.0).
model_size("qwen3.5-14b", 28.0).
model_size("qwen3.5-30b-a3b", 60.0).

# Quantization compression ratios
quant_compression("int8", 2.0).
quant_compression("int4_awq", 4.0).
quant_compression("w4a16", 4.0).
quant_compression("fp8", 2.0).
quant_compression("nvfp4", 4.0).

# Calculate quantized model size
quantized_size(Model, Format, Size) :-
    model_size(Model, BaseSize),
    quant_compression(Format, Ratio),
    Size = BaseSize / Ratio.

# T4 GPU memory (16GB)
t4_memory_gb(16.0).

# Check if model fits on T4 after quantization
model_fits_t4(Model, Format) :-
    quantized_size(Model, Format, Size),
    t4_memory_gb(Memory),
    Size < Memory * 0.9.  # Leave 10% headroom

# ============================================================================
# 6. Recommended Quantization Rules
# ============================================================================

# Recommend INT8 for models under 10B parameters
recommend_quant(Model, "int8") :-
    model_size(Model, Size),
    Size < 18.0.

# Recommend INT4-AWQ for larger models
recommend_quant(Model, "int4_awq") :-
    model_size(Model, Size),
    Size >= 18.0.

# ============================================================================
# 7. OpenAI API Routing Rules
# ============================================================================

# Map OpenAI endpoints to internal handlers
openai_endpoint("/v1/chat/completions", "chat_completions").
openai_endpoint("/v1/models", "list_models").
openai_endpoint("/v1/models/{model_id}", "get_model").
openai_endpoint("/v1/embeddings", "create_embedding").

# Validate model availability
model_available(ModelId) :-
    quantized_model(ModelId, _, _).

# Quantized models available for inference
quantized_model("qwen3.5-0.6b-int8", "qwen3.5-0.6b", "int8").
quantized_model("qwen3.5-1.8b-int8", "qwen3.5-1.8b", "int8").
quantized_model("qwen3.5-4b-int8", "qwen3.5-4b", "int8").
quantized_model("qwen3.5-9b-int4-awq", "qwen3.5-9b", "int4_awq").

# ============================================================================
# 8. Quality Thresholds for Optimization
# ============================================================================

quality_threshold("perplexity_increase", 0.5).  # Max 0.5 PPL increase
quality_threshold("accuracy_drop", 1.0).        # Max 1% accuracy drop
quality_threshold("latency_speedup", 1.5).      # Min 1.5x speedup

optimization_pass(Metric, Value) :-
    quality_threshold(Metric, Threshold),
    Value <= Threshold.

# ============================================================================
# 9. Pruning Configuration Rules
# ============================================================================

# Recommended pruning sparsity by model type
pruning_sparsity("dense", 0.3).     # 30% for dense models
pruning_sparsity("moe", 0.2).       # 20% for MoE models

# MoE pruning dimensions
moe_prune_dimension("num_moe_experts").
moe_prune_dimension("moe_ffn_hidden_size").
moe_prune_dimension("moe_shared_expert_intermediate_size").

# Dense pruning dimensions
dense_prune_dimension("num_attention_heads").
dense_prune_dimension("ffn_hidden_size").
dense_prune_dimension("embedding_dimension").

# ============================================================================
# 10. Service Health Rules
# ============================================================================

service_healthy(Service) :-
    service_registry(Service, URL, _),
    health_check(URL, "ok").

all_services_healthy() :-
    forall(service_registry(S, _, _), service_healthy(S)).