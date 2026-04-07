% T4 GPU Optimization Rules — Dynamic Fact-Based
% ============================================================================
% NO HARDCODED VALUES — All facts are injected at runtime by the Zig service.
% This file contains only FACT SCHEMAS and DERIVATION RULES.
% ============================================================================

% ===========================================================================
% FACT SCHEMAS (injected at runtime, NOT defined here)
% ===========================================================================
%
% GPU facts (detected from nvidia-smi):
%   gpu_device(DeviceID, Name, ComputeCapability, MemoryMB, TensorCores).
%   gpu_has_feature(DeviceID, Feature).  % Feature: int8_tensor_cores, fp16_tensor_cores, flash_attention
%   gpu_memory_used(DeviceID, UsedMB).
%
% Model facts (from model config/registry):
%   model_loaded(Name).
%   model_params_billions(Name, Params).
%   model_hidden_dim(Name, HiddenDim).
%   model_layers(Name, Layers).
%   model_heads_kv(Name, HeadsKV).
%   model_vocab_size(Name, VocabSize).
%
% Request facts (from current request):
%   task_type(TaskID, Type).           % Type: simple, reasoning, coding, general
%   latency_requirement(TaskID, Req).  % Req: low, medium, high
%   quality_requirement(TaskID, Req).  % Req: low, medium, high
%
% SLA facts (from deployment config):
%   sla_max_latency_ms(MaxMs).
%   sla_min_throughput_tps(MinTPS).

% ===========================================================================
% DERIVED: Model Size Categories
% ===========================================================================

model_size_category(Model, small) :-
    model_params_billions(Model, Params),
    Params =< 3.0.

model_size_category(Model, medium) :-
    model_params_billions(Model, Params),
    Params > 3.0,
    Params =< 7.0.

model_size_category(Model, large) :-
    model_params_billions(Model, Params),
    Params > 7.0,
    Params =< 13.0.

model_size_category(Model, xlarge) :-
    model_params_billions(Model, Params),
    Params > 13.0.

% ===========================================================================
% DERIVED: GPU Capability Detection
% ===========================================================================

% Check if device supports Tensor Cores
has_tensor_cores(DeviceID) :-
    gpu_device(DeviceID, _, CC, _, TC),
    CC >= 7.0,
    TC > 0.

has_int8_tensor_cores(DeviceID) :-
    gpu_has_feature(DeviceID, int8_tensor_cores).

has_fp16_tensor_cores(DeviceID) :-
    gpu_has_feature(DeviceID, fp16_tensor_cores).

supports_flash_attention(DeviceID) :-
    gpu_device(DeviceID, _, CC, _, _),
    CC >= 7.0.

% ===========================================================================
% DERIVED: Memory Calculations
% ===========================================================================

% Available GPU memory
available_memory_mb(DeviceID, AvailMB) :-
    gpu_device(DeviceID, _, _, TotalMB, _),
    gpu_memory_used(DeviceID, UsedMB),
    AvailMB is TotalMB - UsedMB.

% Estimated model memory (FP16)
model_memory_fp16_mb(Model, MemMB) :-
    model_params_billions(Model, Params),
    MemMB is Params * 2000.  % 2 bytes per param

% Estimated model memory (INT8)
model_memory_int8_mb(Model, MemMB) :-
    model_params_billions(Model, Params),
    MemMB is Params * 1000.  % 1 byte per param

% Estimated model memory (INT4)
model_memory_int4_mb(Model, MemMB) :-
    model_params_billions(Model, Params),
    MemMB is Params * 500.  % 0.5 bytes per param

% KV cache budget after model load
% Bug 7 fix: thread DeviceID into model_memory_working so the quantization
% selection is resolved per-device, not matched against any device's facts.
kv_cache_budget_mb(DeviceID, Model, Budget) :-
    available_memory_mb(DeviceID, AvailMB),
    model_memory_working(DeviceID, Model, ModelMB),
    HeadroomMB is 1024,  % 1GB headroom
    Budget is AvailMB - ModelMB - HeadroomMB.

% ===========================================================================
% DERIVED: Quantization Selection
% ===========================================================================

% Select quantization based on memory constraints
select_quantization(DeviceID, Model, fp16) :-
    available_memory_mb(DeviceID, AvailMB),
    model_memory_fp16_mb(Model, ReqMB),
    HeadroomMB is ReqMB * 0.3,  % 30% headroom for KV cache
    AvailMB >= ReqMB + HeadroomMB.

select_quantization(DeviceID, Model, q8_0) :-
    available_memory_mb(DeviceID, AvailMB),
    model_memory_fp16_mb(Model, FP16MB),
    model_memory_int8_mb(Model, INT8MB),
    HeadroomMB is INT8MB * 0.3,
    AvailMB < FP16MB + HeadroomMB,
    AvailMB >= INT8MB + HeadroomMB,
    has_int8_tensor_cores(DeviceID).

select_quantization(DeviceID, Model, q4_k_m) :-
    available_memory_mb(DeviceID, AvailMB),
    model_memory_int8_mb(Model, INT8MB),
    model_memory_int4_mb(Model, INT4MB),
    HeadroomMB is INT4MB * 0.3,
    AvailMB < INT8MB + HeadroomMB,
    AvailMB >= INT4MB + HeadroomMB.

% Q3_K_M: 0.375 bytes/param — needed for 35B+ models on T4 (16 GB).
% model_memory_int4_mb is reused as an upper-bound approximation;
% the actual Q3 model footprint is ~0.375/0.5 = 75% of the INT4 figure.
select_quantization(DeviceID, Model, q3_k_m) :-
    available_memory_mb(DeviceID, AvailMB),
    model_memory_int4_mb(Model, INT4MB),
    Q3MB is INT4MB * 75 / 100,
    HeadroomMB is Q3MB * 0.3,
    AvailMB < INT4MB + HeadroomMB,
    AvailMB >= Q3MB + HeadroomMB.

% Get working memory based on selected quantization for a specific device.
% Bug 7 fix: DeviceID is now an explicit parameter (was _ — anonymous) so
% quantization selection is scoped to the target device only.  In a multi-GPU
% setup, gpu0 having fp16 headroom must not affect gpu1's budget calculation.
model_memory_working(DeviceID, Model, MemMB) :-
    select_quantization(DeviceID, Model, fp16),
    model_memory_fp16_mb(Model, MemMB).

model_memory_working(DeviceID, Model, MemMB) :-
    select_quantization(DeviceID, Model, q8_0),
    model_memory_int8_mb(Model, MemMB).

model_memory_working(DeviceID, Model, MemMB) :-
    select_quantization(DeviceID, Model, q3_k_m),
    model_memory_int4_mb(Model, MemMB).  % Q3 ≈ 0.375B/param ≈ INT4 budget estimate

model_memory_working(DeviceID, Model, MemMB) :-
    select_quantization(DeviceID, Model, q4_k_m),
    model_memory_int4_mb(Model, MemMB).

% ===========================================================================
% DERIVED: Batch Size Optimization
% ===========================================================================

% Calculate optimal batch size based on KV cache budget and model
optimal_batch_size(DeviceID, Model, BatchSize) :-
    kv_cache_budget_mb(DeviceID, Model, BudgetMB),
    model_layers(Model, Layers),
    model_heads_kv(Model, HeadsKV),
    model_hidden_dim(Model, HiddenDim),
    HeadDim is HiddenDim / HeadsKV,
    MaxSeqLen is 2048,
    KVPerTokenMB is (Layers * HeadsKV * HeadDim * 2 * 2) / 1048576,  % 2 for K+V, 2 for FP16
    MaxBatch is BudgetMB / (MaxSeqLen * KVPerTokenMB),
    BatchSize is min(MaxBatch, 64).  % Cap at 64

% Simplified batch size by category (fallback if detailed info unavailable)
batch_size_by_category(Model, 16) :-
    model_size_category(Model, small).

batch_size_by_category(Model, 8) :-
    model_size_category(Model, medium).

batch_size_by_category(Model, 4) :-
    model_size_category(Model, large).

batch_size_by_category(Model, 2) :-
    model_size_category(Model, xlarge).

% ===========================================================================
% DERIVED: Context Length Limits
% ===========================================================================

% Max context based on KV cache budget
max_context_length(DeviceID, Model, MaxCtx) :-
    kv_cache_budget_mb(DeviceID, Model, BudgetMB),
    model_layers(Model, Layers),
    model_heads_kv(Model, HeadsKV),
    model_hidden_dim(Model, HiddenDim),
    HeadDim is HiddenDim / HeadsKV,
    KVPerTokenMB is (Layers * HeadsKV * HeadDim * 2 * 2) / 1048576,
    MaxCtx is BudgetMB / KVPerTokenMB.

% Simplified context limits by category (fallback)
context_by_category(Model, 8192) :-
    model_size_category(Model, small).

context_by_category(Model, 4096) :-
    model_size_category(Model, medium).

context_by_category(Model, 2048) :-
    model_size_category(Model, large).

context_by_category(Model, 1024) :-
    model_size_category(Model, xlarge).

% ===========================================================================
% DERIVED: Model Fits Check
% ===========================================================================

% Check if model fits on device
model_fits(DeviceID, Model) :-
    available_memory_mb(DeviceID, AvailMB),
    model_memory_int4_mb(Model, MinReqMB),  % Minimum with INT4
    AvailMB >= MinReqMB.

% Check if model requires quantization
requires_quantization(DeviceID, Model) :-
    available_memory_mb(DeviceID, AvailMB),
    model_memory_fp16_mb(Model, FP16MB),
    AvailMB < FP16MB * 1.3.  % Less than 30% headroom

% ===========================================================================
% DERIVED: Feature Enablement
% ===========================================================================

% Enable continuous batching if memory allows
enable_continuous_batching(DeviceID, Model) :-
    kv_cache_budget_mb(DeviceID, Model, BudgetMB),
    BudgetMB > 1024.  % At least 1GB for KV cache

% Enable flash attention if supported
enable_flash_attention(DeviceID) :-
    supports_flash_attention(DeviceID).

% Prefill chunk size based on model size
prefill_chunk_size(Model, 1024) :-
    model_size_category(Model, small).

prefill_chunk_size(Model, 512) :-
    model_size_category(Model, medium).

prefill_chunk_size(Model, 256) :-
    model_size_category(Model, large).

prefill_chunk_size(Model, 128) :-
    model_size_category(Model, xlarge).

% ===========================================================================
% DERIVED: Performance Estimation
% ===========================================================================

% Throughput estimate based on model size and quantization
estimate_throughput_tps(DeviceID, Model, TPS) :-
    model_size_category(Model, small),
    select_quantization(DeviceID, Model, fp16),
    TPS is 200.

estimate_throughput_tps(DeviceID, Model, TPS) :-
    model_size_category(Model, medium),
    select_quantization(DeviceID, Model, fp16),
    TPS is 100.

estimate_throughput_tps(DeviceID, Model, TPS) :-
    model_size_category(Model, large),
    select_quantization(DeviceID, Model, q8_0),
    TPS is 60.

estimate_throughput_tps(DeviceID, Model, TPS) :-
    model_size_category(Model, xlarge),
    select_quantization(DeviceID, Model, q4_k_m),
    TPS is 30.

% ===========================================================================
% QUERY INTERFACE: Get Full GPU Config
% ===========================================================================

% Main query: returns complete optimized config
gpu_config(DeviceID, Model, Config) :-
    model_loaded(Model),
    select_quantization(DeviceID, Model, Quantization),
    (optimal_batch_size(DeviceID, Model, BatchSize) ; batch_size_by_category(Model, BatchSize)),
    (max_context_length(DeviceID, Model, MaxCtx) ; context_by_category(Model, MaxCtx)),
    prefill_chunk_size(Model, PrefillChunk),
    (enable_continuous_batching(DeviceID, Model) -> ContBatch = true ; ContBatch = false),
    (enable_flash_attention(DeviceID) -> FlashAttn = true ; FlashAttn = false),
    (has_tensor_cores(DeviceID) -> TensorCores = true ; TensorCores = false),
    estimate_throughput_tps(DeviceID, Model, EstTPS),
    Config = config{
        quantization: Quantization,
        batch_size: BatchSize,
        max_context: MaxCtx,
        prefill_chunk: PrefillChunk,
        continuous_batching: ContBatch,
        flash_attention: FlashAttn,
        tensor_cores: TensorCores,
        estimated_tps: EstTPS
    }.

% ===========================================================================
% EXAMPLES (for testing, facts would be injected)
% ===========================================================================

% Example query (after facts are injected):
% ?- gpu_config(0, "llama-7b", Config).
%
% Runtime would first inject:
%   gpu_device(0, "NVIDIA T4", 7.5, 16384, 320).
%   gpu_has_feature(0, int8_tensor_cores).
%   gpu_has_feature(0, fp16_tensor_cores).
%   gpu_memory_used(0, 1024).
%   model_loaded("llama-7b").
%   model_params_billions("llama-7b", 7.0).
%   model_hidden_dim("llama-7b", 4096).
%   model_layers("llama-7b", 32).
%   model_heads_kv("llama-7b", 32).
%   model_vocab_size("llama-7b", 32000).