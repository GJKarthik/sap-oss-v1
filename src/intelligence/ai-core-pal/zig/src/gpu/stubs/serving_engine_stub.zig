//! Serving Engine Stub — used when -Dgpu=false (the default).
//! Provides no-op / error-returning versions of all serving_engine exports.

const std = @import("std");

pub const ServingConfig = struct {
    max_sequences: u32 = 0,
    max_pages: u32 = 0,
    page_size: u32 = 0,
    max_seq_len: u32 = 0,
    max_new_tokens: usize = 0,
    prefix_caching: bool = false,
};

pub const ServingEngine = opaque {};

pub fn initGlobalEngine(
    config: ServingConfig,
    vocab_size: u32,
    num_layers: u32,
    num_heads: u32,
    num_kv_heads: u32,
    head_dim: u32,
    intermediate_size: u32,
) error{GpuNotEnabled}!*ServingEngine {
    _ = config;
    _ = vocab_size;
    _ = num_layers;
    _ = num_heads;
    _ = num_kv_heads;
    _ = head_dim;
    _ = intermediate_size;
    return error.GpuNotEnabled;
}

pub fn shutdownGlobalEngine() void {}
