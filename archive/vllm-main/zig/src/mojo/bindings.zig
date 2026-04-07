//! Zig FFI Bindings for Mojo Private LLM core
//! Updated to support INT8/AWQ quantization and in-flight batching.
//! Links to libtrt_wrapper.a when TensorRT is available.

const std = @import("std");
const builtin = @import("builtin");

// --- Result/Status Codes (mirror exports.mojo) ---
pub const PLLM_SUCCESS: i32 = 0;
pub const PLLM_ERROR_NULL_POINTER: i32 = -1;
pub const PLLM_ERROR_INVALID_HANDLE: i32 = -2;
pub const PLLM_ERROR_OUT_OF_MEMORY: i32 = -3;
pub const PLLM_ERROR_INVALID_CONFIG: i32 = -4;
pub const PLLM_ERROR_LOAD_FAILED: i32 = -5;
pub const PLLM_ERROR_INFERENCE_FAILED: i32 = -6;
pub const PLLM_ERROR_BUFFER_TOO_SMALL: i32 = -7;

// --- Batch Request Status ---
pub const PLLM_BATCH_QUEUED: i32 = 0;
pub const PLLM_BATCH_RUNNING: i32 = 1;
pub const PLLM_BATCH_COMPLETE: i32 = 2;
pub const PLLM_BATCH_ERROR: i32 = -1;

/// Quantization mode for the TensorRT engine.
pub const QuantMode = enum(i32) {
    fp16 = 0, // Default: Full FP16 precision
    int8 = 1, // INT8 post-training quantization
    awq = 2, // Activation-aware Weight Quantization (4-bit)
    fp8 = 3, // FP8 (H100+ only)
};

// Opaque engine handle from TensorRT
pub const EngineHandle = *anyopaque;

// ============================================================================
// TensorRT C FFI Declarations (linked from libtrt_wrapper.a)
// ============================================================================

// --- Version Info ---
pub extern "C" fn pllm_version_major() i32;
pub extern "C" fn pllm_version_minor() i32;
pub extern "C" fn pllm_version_patch() i32;

// --- TensorRT Engine Lifecycle ---

/// Initialize a TensorRT engine with quantization and batching configuration.
pub extern "C" fn pllm_trt_init_engine(
    engine_path: [*:0]const u8,
    quant_mode: i32, // One of QuantMode values
    paged_kv_cache: bool, // Enable PagedAttention memory management
    max_inflight_requests: i32,
) ?EngineHandle;

/// Enqueue a prompt for non-blocking in-flight batch processing.
/// Returns PLLM_BATCH_QUEUED on success, PLLM_BATCH_ERROR on overflow.
pub extern "C" fn pllm_trt_enqueue_request(
    engine_handle: EngineHandle,
    request_id: i32,
    prompt_tokens: [*]const i32,
    prompt_len: i32,
    max_new_tokens: i32,
) i32;

/// Poll for completion of an enqueued request.
/// Returns number of tokens generated if done, PLLM_BATCH_RUNNING if still processing.
pub extern "C" fn pllm_trt_poll_request(
    engine_handle: EngineHandle,
    request_id: i32,
    output_tokens: [*]i32,
    output_capacity: i32,
) i32;

/// Get the current number of requests in the in-flight queue (for back-pressure).
pub extern "C" fn pllm_trt_get_inflight_count(engine_handle: EngineHandle) i32;

/// Synchronous (blocking) token generation — legacy path for GGUF parity testing.
pub extern "C" fn pllm_trt_generate(
    engine_handle: EngineHandle,
    prompt_tokens: [*]const i32,
    prompt_len: i32,
    output_tokens: [*]i32,
    max_tokens: i32,
) i32;

/// Release TensorRT engine resources.
pub extern "C" fn pllm_trt_free_engine(engine_handle: EngineHandle) i32;