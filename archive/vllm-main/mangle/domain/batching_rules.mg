# Mangle rules for continuous batching configuration
# These rules define batching behavior, priority, and SLA management

# =============================================================================
# Batch Size Configuration
# =============================================================================

# Maximum batch size by model type (based on GPU memory)
max_batch_size(/phi3-lora, 32).
max_batch_size(/llama3-8b, 16).
max_batch_size(/codellama-7b, 16).
max_batch_size(/mistral-7b, 16).
max_batch_size(/qwen2-7b, 8).

# Maximum tokens per batch (GPU memory constraint)
max_batch_tokens(/phi3-lora, 8192).
max_batch_tokens(/llama3-8b, 16384).
max_batch_tokens(/codellama-7b, 32768).
max_batch_tokens(/mistral-7b, 16384).
max_batch_tokens(/qwen2-7b, 65536).

# Minimum batch wait time (ms) before starting inference
min_batch_wait(/phi3-lora, 10).
min_batch_wait(/llama3-8b, 20).
min_batch_wait(/codellama-7b, 20).
min_batch_wait(/mistral-7b, 20).
min_batch_wait(/qwen2-7b, 30).

# =============================================================================
# Priority Levels
# =============================================================================

# Priority level definitions (higher = more urgent)
priority_level(/critical, 10).
priority_level(/high, 7).
priority_level(/normal, 5).
priority_level(/low, 3).
priority_level(/batch, 1).

# Priority timeout multiplier
priority_timeout_multiplier(/critical, 0.5).
priority_timeout_multiplier(/high, 1.0).
priority_timeout_multiplier(/normal, 2.0).
priority_timeout_multiplier(/low, 4.0).
priority_timeout_multiplier(/batch, 10.0).

# =============================================================================
# SLA Targets (latency in milliseconds)
# =============================================================================

# Time to first token SLA
sla_ttft(/critical, 50).
sla_ttft(/high, 100).
sla_ttft(/normal, 500).
sla_ttft(/low, 1000).
sla_ttft(/batch, 5000).

# Total generation time SLA (per 100 tokens)
sla_gen_per_100(/critical, 200).
sla_gen_per_100(/high, 400).
sla_gen_per_100(/normal, 1000).
sla_gen_per_100(/low, 2000).
sla_gen_per_100(/batch, 10000).

# =============================================================================
# User Priority Mapping
# =============================================================================

# Default priority for user types
user_type_priority(/enterprise, /critical).
user_type_priority(/premium, /high).
user_type_priority(/standard, /normal).
user_type_priority(/free, /low).
user_type_priority(/api_batch, /batch).

# =============================================================================
# Preemption Rules
# =============================================================================

# Preemption threshold (priority difference needed to preempt)
preemption_threshold(3).

# Can preempt rule
can_preempt(HigherPriority, LowerPriority) :-
    priority_level(HigherPriority, H),
    priority_level(LowerPriority, L),
    H - L >= 3.

# Models that allow preemption
allows_preemption(/phi3-lora).
allows_preemption(/llama3-8b).
allows_preemption(/mistral-7b).
allows_preemption(/qwen35-9b).
allows_preemption(/qwen35-35b).

# =============================================================================
# KV Cache Configuration
# =============================================================================

# Block size for paged attention (tokens per block)
# Bug 8 note: Mojo PagedKVCache.KV_BLOCK_SIZE = 256; Zig PagedKvCache.block_size
# is now also 256 (fixed in AppState.init).  Mangle facts must agree.
kv_block_size(/phi3-lora, 256).
kv_block_size(/llama3-8b, 256).
kv_block_size(/codellama-7b, 256).
kv_block_size(/mistral-7b, 256).
kv_block_size(/qwen2-7b, 256).

# Qwen3.5 — 256-token blocks (matches Mojo KV_BLOCK_SIZE)
kv_block_size(/qwen35-0.8b, 256).
kv_block_size(/qwen35-9b, 256).
kv_block_size(/qwen35-35b, 256).

# Maximum KV cache blocks per model (based on GPU memory)
# T4 16 GB: after model load, remaining VRAM / bytes_per_block
# bytes_per_block = 256 * head_dim * 2 * 2 (K+V, FP16) * num_kv_heads * num_layers
max_kv_blocks(/phi3-lora, 4096).
max_kv_blocks(/llama3-8b, 2048).
max_kv_blocks(/codellama-7b, 2048).
max_kv_blocks(/mistral-7b, 2048).
max_kv_blocks(/qwen2-7b, 1024).

# Qwen3.5 T4 KV block budgets (remaining VRAM after model load)
# 0.8B Q8: ~14 GB free → 256*64*2*2*8*28 = 1.5 MB/block → ~9300 blocks (cap 4096)
max_kv_blocks(/qwen35-0.8b, 4096).
# 9B Q4: ~10 GB free → 256*128*2*2*8*36 = 9.4 MB/block → ~1060 blocks
max_kv_blocks(/qwen35-9b, 1024).
# 35B Q3: ~2.5 GB free → 256*128*2*2*8*64 = 16.7 MB/block → ~150 blocks
max_kv_blocks(/qwen35-35b, 150).

# KV cache eviction policy
kv_eviction_policy(/phi3-lora, /lru).
kv_eviction_policy(/llama3-8b, /lru).
kv_eviction_policy(/codellama-7b, /fifo).
kv_eviction_policy(/mistral-7b, /lru).
kv_eviction_policy(/qwen2-7b, /lru).
kv_eviction_policy(/qwen35-0.8b, /lru).
kv_eviction_policy(/qwen35-9b, /lru).
kv_eviction_policy(/qwen35-35b, /lru).

# =============================================================================
# Dynamic Batching Rules
# =============================================================================

# Batch should start if any condition is met
should_start_batch(Model, BatchSize, WaitTime, TokenCount) :-
    max_batch_size(Model, MaxSize),
    BatchSize >= MaxSize.

should_start_batch(Model, BatchSize, WaitTime, TokenCount) :-
    max_batch_tokens(Model, MaxTokens),
    TokenCount >= MaxTokens.

should_start_batch(Model, BatchSize, WaitTime, TokenCount) :-
    min_batch_wait(Model, MinWait),
    WaitTime >= MinWait,
    BatchSize > 0.

# =============================================================================
# Speculative Decoding Configuration
# =============================================================================

# Draft model for speculative decoding
speculative_draft_model(/llama3-8b, /phi3-lora).
speculative_draft_model(/codellama-7b, /phi3-lora).
speculative_draft_model(/mistral-7b, /phi3-lora).

# Number of speculative tokens
speculative_tokens(/llama3-8b, 4).
speculative_tokens(/codellama-7b, 5).
speculative_tokens(/mistral-7b, 4).

# Enable speculative decoding
speculative_enabled(/llama3-8b).
speculative_enabled(/codellama-7b).
speculative_enabled(/mistral-7b).

# =============================================================================
# Queue Management
# =============================================================================

# Maximum queue depth per model
max_queue_depth(/phi3-lora, 256).
max_queue_depth(/llama3-8b, 128).
max_queue_depth(/codellama-7b, 128).
max_queue_depth(/mistral-7b, 128).
max_queue_depth(/qwen2-7b, 64).

# Queue rejection policy when full
queue_full_policy(/phi3-lora, /reject_lowest).
queue_full_policy(/llama3-8b, /reject_lowest).
queue_full_policy(/codellama-7b, /reject_oldest).
queue_full_policy(/mistral-7b, /reject_lowest).
queue_full_policy(/qwen2-7b, /reject_oldest).

# =============================================================================
# Scaling Rules
# =============================================================================

# Auto-scaling thresholds (queue depth percentage)
scale_up_threshold(80).
scale_down_threshold(20).

# Minimum and maximum replicas
min_replicas(/phi3-lora, 1).
max_replicas(/phi3-lora, 8).
min_replicas(/llama3-8b, 1).
max_replicas(/llama3-8b, 4).
min_replicas(/codellama-7b, 1).
max_replicas(/codellama-7b, 4).
min_replicas(/mistral-7b, 1).
max_replicas(/mistral-7b, 4).
min_replicas(/qwen2-7b, 1).
max_replicas(/qwen2-7b, 2).

# Cooldown period between scaling events (seconds)
scale_cooldown(60).

# =============================================================================
# Tests
# =============================================================================

test_batch_config() :-
    max_batch_size(/phi3-lora, 32),
    max_batch_tokens(/phi3-lora, 8192).

test_priority() :-
    priority_level(/critical, 10),
    can_preempt(/critical, /low).

test_sla() :-
    sla_ttft(/critical, 50),
    sla_gen_per_100(/critical, 200).