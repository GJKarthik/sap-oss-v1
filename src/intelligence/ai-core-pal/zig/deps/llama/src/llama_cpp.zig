//! llama.cpp C FFI Bindings
//!
//! This module provides Zig bindings to llama.cpp, which supports:
//! - CUDA (NVIDIA GPUs like T4)
//! - Metal (Apple Silicon)
//! - CPU (fallback)
//!
//! When compiled with CUDA support, all tensor operations run on GPU.

const std = @import("std");
const c = @cImport({
    @cInclude("llama.h");
});

// ============================================================================
// Type Aliases from llama.h
// ============================================================================

pub const Model = *c.llama_model;
pub const Context = *c.llama_context;
pub const Token = c.llama_token;
pub const TokenData = c.llama_token_data;
pub const TokenDataArray = c.llama_token_data_array;
pub const Batch = c.llama_batch;
pub const Pos = c.llama_pos;
pub const SeqId = c.llama_seq_id;

// ============================================================================
// Model Loading
// ============================================================================

pub const ModelParams = struct {
    n_gpu_layers: i32 = -1, // -1 = all layers on GPU
    main_gpu: i32 = 0,
    vocab_only: bool = false,
    use_mmap: bool = true,
    use_mlock: bool = false,
    
    pub fn toC(self: ModelParams) c.llama_model_params {
        var params = c.llama_model_default_params();
        params.n_gpu_layers = self.n_gpu_layers;
        params.main_gpu = self.main_gpu;
        params.vocab_only = self.vocab_only;
        params.use_mmap = self.use_mmap;
        params.use_mlock = self.use_mlock;
        return params;
    }
    
    /// T4 GPU optimized params
    pub fn forT4() ModelParams {
        return .{
            .n_gpu_layers = -1, // All layers on GPU
            .main_gpu = 0,
            .use_mmap = true,
            .use_mlock = false,
        };
    }
};

/// Load a GGUF model from disk
pub fn loadModel(path: [*:0]const u8, params: ModelParams) !Model {
    const model = c.llama_load_model_from_file(path, params.toC());
    if (model == null) {
        return error.FailedToLoadModel;
    }
    return model.?;
}

/// Free a model
