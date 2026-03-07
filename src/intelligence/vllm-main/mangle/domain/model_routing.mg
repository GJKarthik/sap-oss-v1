# Mangle rules for model routing in ainuc-be-log-local-models
# These rules define how requests are routed to appropriate models

# =============================================================================
# Available Models
# =============================================================================

# Define available models with their specs
model(/phi3-lora, "phi3-lora", 4096).
model(/llama3-8b, "llama3-8b", 8192).
model(/codellama-7b, "codellama-7b", 16384).
model(/mistral-7b, "mistral-7b", 8192).
model(/qwen2-7b, "qwen2-7b", 32768).

# Qwen3.5 family — T4 primary models
model(/qwen35-0.8b, "qwen3.5-0.8b", 32768).
model(/qwen35-9b,   "qwen3.5-9b",   32768).
model(/qwen35-35b,  "qwen3.5-35b",  32768).

# Model status (can be updated dynamically)
model_status(/phi3-lora, /available).
model_status(/llama3-8b, /unavailable).
model_status(/codellama-7b, /unavailable).
model_status(/mistral-7b, /unavailable).
model_status(/qwen2-7b, /unavailable).

# Qwen3.5 status — set /available once GGUF files are downloaded to /models/
model_status(/qwen35-0.8b, /available).   # Q8_0 ~880 MB — always fits
model_status(/qwen35-9b,   /available).   # Q4_K_M ~5 GB — fits with KV headroom
model_status(/qwen35-35b,  /available).   # Q3_K_M ~13 GB — fits, small KV only

# Model specialization
model_specializes_in(/phi3-lora, /general).
model_specializes_in(/phi3-lora, /code).
model_specializes_in(/phi3-lora, /reasoning).
model_specializes_in(/llama3-8b, /general).
model_specializes_in(/llama3-8b, /reasoning).
model_specializes_in(/llama3-8b, /log_analysis).
model_specializes_in(/codellama-7b, /code).
model_specializes_in(/codellama-7b, /debug).
model_specializes_in(/mistral-7b, /general).
model_specializes_in(/mistral-7b, /analysis).
model_specializes_in(/qwen2-7b, /code).
model_specializes_in(/qwen2-7b, /long_context).

# Qwen3.5 — all-rounder with strong reasoning and code
model_specializes_in(/qwen35-0.8b, /general).
model_specializes_in(/qwen35-0.8b, /code).
model_specializes_in(/qwen35-0.8b, /reasoning).
model_specializes_in(/qwen35-0.8b, /long_context).
model_specializes_in(/qwen35-9b, /general).
model_specializes_in(/qwen35-9b, /reasoning).
model_specializes_in(/qwen35-9b, /code).
model_specializes_in(/qwen35-9b, /long_context).
model_specializes_in(/qwen35-35b, /general).
model_specializes_in(/qwen35-35b, /reasoning).
model_specializes_in(/qwen35-35b, /code).
model_specializes_in(/qwen35-35b, /long_context).

# =============================================================================
# Performance Characteristics
# =============================================================================

# Model speed ratings (higher = faster)
model_speed(/phi3-lora, 8).
model_speed(/llama3-8b, 5).
model_speed(/codellama-7b, 5).
model_speed(/mistral-7b, 6).
model_speed(/qwen2-7b, 4).

# Qwen3.5 speed on T4 (Q8/Q4/Q3 respectively)
model_speed(/qwen35-0.8b, 9).   # ~1200 tok/s on T4 with Q8_0
model_speed(/qwen35-9b, 5).     # ~120 tok/s on T4 with Q4_K_M
model_speed(/qwen35-35b, 2).    # ~25 tok/s on T4 with Q3_K_M

# Model quality ratings (higher = better)
model_quality(/phi3-lora, 7).
model_quality(/llama3-8b, 8).
model_quality(/codellama-7b, 9).
model_quality(/mistral-7b, 8).
model_quality(/qwen2-7b, 8).

# Qwen3.5 quality (35B > 9B > 0.8B)
model_quality(/qwen35-0.8b, 6).
model_quality(/qwen35-9b, 8).
model_quality(/qwen35-35b, 9).

# Memory requirements (GB)
model_memory(/phi3-lora, 4).
model_memory(/llama3-8b, 8).
model_memory(/codellama-7b, 7).
model_memory(/mistral-7b, 7).
model_memory(/qwen2-7b, 8).

# Qwen3.5 footprint at recommended T4 quant
model_memory(/qwen35-0.8b, 1).    # Q8_0 ~880 MB
model_memory(/qwen35-9b, 5).      # Q4_K_M ~5 GB
model_memory(/qwen35-35b, 14).    # Q3_K_M ~13.4 GB

# =============================================================================
# Hardware Detection and Engine Routing
# =============================================================================

# Define hardware nodes availability (can be injected via API)
hardware_node(/node_gpu_01, /nvidia_h100).
hardware_node(/node_gpu_02, /nvidia_a100).
hardware_node(/node_cpu_01, /intel_xeon).
hardware_node(/node_mac_01, /apple_m3).
# Brev T4 instance — primary node for Qwen3.5 testing
hardware_node(/node_t4_brev, /nvidia_t4).

# Engine compatibility
supports_engine(/nvidia_h100, /tensorrt).
supports_engine(/nvidia_a100, /tensorrt).
supports_engine(/nvidia_h100, /gguf).
supports_engine(/nvidia_a100, /gguf).
supports_engine(/nvidia_t4, /tensorrt).   # TRT with AWQ — needs .engine file
supports_engine(/nvidia_t4, /gguf).       # GGUF via llama.cpp — always available
supports_engine(/intel_xeon, /gguf).
supports_engine(/apple_m3, /gguf).

# Dynamic queue-depth threshold for TensorRT overflow routing.
# When the live in-flight count exceeds this value, Mangle routes to /gguf.
engine_queue_threshold(/tensorrt, 48).

# Route Engine based on hardware capabilities and live queue depth.
# Priority 1: TensorRT when hardware supports it AND queue is not overloaded.
route_engine(Node, /tensorrt) :-
    hardware_node(Node, Hardware),
    supports_engine(Hardware, /tensorrt),
    !engine_overloaded(Node, /tensorrt).

# Priority 2: GGUF fallback when TensorRT is overloaded (dynamic overflow).
route_engine(Node, /gguf) :-
    hardware_node(Node, Hardware),
    supports_engine(Hardware, /tensorrt),
    supports_engine(Hardware, /gguf),
    engine_overloaded(Node, /tensorrt).

# Priority 3: GGUF-only hardware (no TensorRT support at all).
route_engine(Node, /gguf) :-
    hardware_node(Node, Hardware),
    supports_engine(Hardware, /gguf),
    !supports_engine(Hardware, /tensorrt).

# Engine is overloaded when its live queue depth exceeds the threshold.
# gpu_queue_depth/2 is asserted as a runtime fact by the Zig gateway
# before each Mangle query (see main.zig handleChatCompletions).
engine_overloaded(Node, Engine) :-
    hardware_node(Node, _),
    gpu_queue_depth(Engine, Depth),
    engine_queue_threshold(Engine, Threshold),
    Depth > Threshold.

# =============================================================================
# Routing Rules
# =============================================================================

# Model is a candidate if it's available and specializes in the task
candidate_model(Model, Task) :-
    model(Model, _, _),
    model_status(Model, /available),
    model_specializes_in(Model, Task).

# Fallback: any available model is a candidate for general tasks
candidate_model(Model, /general) :-
    model(Model, _, _),
    model_status(Model, /available).

# Priority routing based on speed
fast_candidate(Model, Task, Speed) :-
    candidate_model(Model, Task),
    model_speed(Model, Speed),
    Speed > 5.

# Priority routing based on quality
quality_candidate(Model, Task, Quality) :-
    candidate_model(Model, Task),
    model_quality(Model, Quality),
    Quality > 7.

# =============================================================================
# Context Length Rules
# =============================================================================

# Check if model can handle prompt length
can_handle_context(Model, TokenCount) :-
    model(Model, _, MaxContext),
    TokenCount < MaxContext.

# Route to model based on context length requirements
route_for_context(Model, Task, TokenCount) :-
    candidate_model(Model, Task),
    can_handle_context(Model, TokenCount).

# Long context routing
needs_long_context(TokenCount) :- TokenCount > 4096.

long_context_model(Model) :-
    model(Model, _, MaxContext),
    model_status(Model, /available),
    MaxContext > 16000.

# =============================================================================
# Load Balancing Rules
# =============================================================================

# Model load state
model_load(/phi3-lora, 0).  # 0-100 representing current load %

# Model is overloaded if load > 80
is_overloaded(Model) :-
    model_load(Model, Load),
    Load > 80.

# Prefer less loaded models
prefer_model(Model, Task) :-
    candidate_model(Model, Task),
    !is_overloaded(Model).

# =============================================================================
# Cost Rules
# =============================================================================

# Cost per 1K tokens (in millicents for local models, this is compute cost)
cost_per_1k(/phi3-lora, 1).
cost_per_1k(/llama3-8b, 2).
cost_per_1k(/codellama-7b, 2).
cost_per_1k(/mistral-7b, 2).
cost_per_1k(/qwen2-7b, 3).

# Cheap model routing
cheap_model(Model, Task) :-
    candidate_model(Model, Task),
    cost_per_1k(Model, Cost),
    Cost < 2.

# =============================================================================
# Final Routing Decision
# =============================================================================

# Primary routing: prefer specialized, fast, available models
# Args: (Task, Model) — matches aicore_deployment.mg convention
route_request(Task, Model) :-
    candidate_model(Model, Task),
    model_speed(Model, Speed),
    model_quality(Model, Quality),
    Speed > 4,
    Quality > 6.

# Fallback routing: any available model
fallback_route(Model) :-
    model(Model, _, _),
    model_status(Model, /available).

# =============================================================================
# Tests
# =============================================================================

test_candidate() :-
    candidate_model(/phi3-lora, /general).

test_routing() :-
    route_request(/general, /phi3-lora).

test_context() :-
    can_handle_context(/phi3-lora, 1000).

test_engine_routing_gpu() :-
    route_engine(/node_gpu_01, /tensorrt).

test_engine_routing_cpu() :-
    route_engine(/node_cpu_01, /gguf).

test_engine_overflow_fallback() :-
    gpu_queue_depth(/tensorrt, 60),
    engine_overloaded(/node_gpu_01, /tensorrt),
    route_engine(/node_gpu_01, /gguf).