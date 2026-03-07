//! End-to-End Inference Benchmark — Real GGUF Model on T4
//!
//! Loads any LLaMA-family Q4_0 GGUF, uploads weights to GPU, runs inference
//! with a real prompt, and checks output quality + throughput.
//!
//! Usage:
//!   zig build e2e-bench -Dgpu=true
//!   ./zig-out/bin/e2e-bench /path/to/model.Q4_0.gguf

const std = @import("std");
const GgufTokenizer = @import("gguf_tokenizer").GgufTokenizer;
const cuda_fwd_mod = @import("cuda_forward");
const CudaForwardPass = cuda_fwd_mod.CudaForwardPass;
const CudaForwardConfig = cuda_fwd_mod.CudaForwardConfig;
const CudaBackend = cuda_fwd_mod.cuda_backend.CudaBackend;
const cuda = cuda_fwd_mod.cuda_bindings;
const weights_mod = cuda_fwd_mod.cuda_weights;
const GpuModelWeights = weights_mod.GpuModelWeights;
const GpuTensor = weights_mod.GpuTensor;
const GGMLType = weights_mod.GGMLType;

// Model dimensions — auto-detected from GGUF metadata at runtime

// Special token IDs — detected from GGUF tokenizer at runtime.
// Defaults match LLaMA but are overridden below when tokenizer is loaded.
var BOS_TOKEN: u32 = 1;
var EOS_TOKEN: u32 = 2;

/// CPU dequantization of Q6_K data to f32 (matches llama.cpp dequantize_row_q6_K)
/// Block: 256 values, 210 bytes: ql[128] + qh[64] + scales[16] + d(f16)
fn dequantQ6KToF32(allocator: std.mem.Allocator, data: []const u8, n_elements: usize) ![]f32 {
    const out = try allocator.alloc(f32, n_elements);
    errdefer allocator.free(out);

    const block_size: usize = 256;
    const bytes_per_block: usize = 210;
    const n_blocks = n_elements / block_size;

    for (0..n_blocks) |b| {
        const blk = data[b * bytes_per_block ..][0..bytes_per_block];
        const ql = blk[0..128];
        const qh = blk[128..192];
        const sc = blk[192..208];
        const d_bits = std.mem.readInt(u16, blk[208..210], .little);
        const d: f32 = @floatCast(@as(f16, @bitCast(d_bits)));
        const base = b * block_size;

        // Two groups of 128 elements (n=0, n=128)
        // Scale index: is = (n/128)*8 + l/16, giving 16 unique scale groups of 16 elements
        // This matches llama.cpp CUDA dequant (not the CPU version which only uses 8 scales)
        inline for ([_]usize{ 0, 128 }) |n| {
            const is_base: usize = (n / 128) * 8; // 0 for n=0, 8 for n=128
            for (0..32) |l| {
                const is: usize = is_base + l / 16; // sub-group: 0 or 1 within each 128-group
                const ql_idx0 = n / 2 + l;
                const ql_idx1 = n / 2 + l + 32;
                const qh_idx = n / 4 + l;

                // 4 elements from interleaved ql/qh bits
                const q1: i32 = (@as(i32, ql[ql_idx0] & 0xF) | (@as(i32, (qh[qh_idx] >> 0) & 3) << 4)) - 32;
                const q2: i32 = (@as(i32, ql[ql_idx1] & 0xF) | (@as(i32, (qh[qh_idx] >> 2) & 3) << 4)) - 32;
                const q3: i32 = (@as(i32, ql[ql_idx0] >> 4) | (@as(i32, (qh[qh_idx] >> 4) & 3) << 4)) - 32;
                const q4: i32 = (@as(i32, ql[ql_idx1] >> 4) | (@as(i32, (qh[qh_idx] >> 6) & 3) << 4)) - 32;

                const s0: f32 = @floatFromInt(@as(i8, @bitCast(sc[is + 0])));
                const s1: f32 = @floatFromInt(@as(i8, @bitCast(sc[is + 2])));
                const s2: f32 = @floatFromInt(@as(i8, @bitCast(sc[is + 4])));
                const s3: f32 = @floatFromInt(@as(i8, @bitCast(sc[is + 6])));

                out[base + n + l + 0] = d * s0 * @as(f32, @floatFromInt(q1));
                out[base + n + l + 32] = d * s1 * @as(f32, @floatFromInt(q2));
                out[base + n + l + 64] = d * s2 * @as(f32, @floatFromInt(q3));
                out[base + n + l + 96] = d * s3 * @as(f32, @floatFromInt(q4));
            }
        }
    }
    return out;
}

/// CPU dequantization of Q4_1 data to f32
/// Block: 32 values, 20 bytes: f16 d (scale) + f16 m (min) + 16 bytes (32 nibbles)
/// val = nibble * d + m
fn dequantQ4_1ToF32(allocator: std.mem.Allocator, data: []const u8, n_elements: usize) ![]f32 {
    const out = try allocator.alloc(f32, n_elements);
    errdefer allocator.free(out);
    const block_size: usize = 32;
    const bytes_per_block: usize = 20;
    const n_blocks = n_elements / block_size;
    for (0..n_blocks) |b| {
        const blk = data[b * bytes_per_block ..][0..bytes_per_block];
        const d: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[0..2], .little))));
        const m: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[2..4], .little))));
        for (0..16) |j| {
            const byte = blk[4 + j];
            const lo: f32 = @floatFromInt(@as(u32, byte & 0xF));
            const hi: f32 = @floatFromInt(@as(u32, byte >> 4));
            out[b * block_size + j] = lo * d + m;
            out[b * block_size + j + 16] = hi * d + m;
        }
    }
    return out;
}

/// CPU dequantization of Q8_0 data to f32
/// Block: 32 values, 34 bytes: f16 d (scale) + 32 int8 quants
/// val = q[i] * d
fn dequantQ8_0ToF32(allocator: std.mem.Allocator, data: []const u8, n_elements: usize) ![]f32 {
    const out = try allocator.alloc(f32, n_elements);
    errdefer allocator.free(out);
    const block_size: usize = 32;
    const bytes_per_block: usize = 34;
    const n_blocks = n_elements / block_size;
    for (0..n_blocks) |b| {
        const blk = data[b * bytes_per_block ..][0..bytes_per_block];
        const d: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[0..2], .little))));
        for (0..32) |j| {
            const q: i8 = @bitCast(blk[2 + j]);
            out[b * block_size + j] = @as(f32, @floatFromInt(q)) * d;
        }
    }
    return out;
}

/// CPU dequantization of Q5_K data to f32 (matches ggml dequantize_row_q5_K)
/// Super-block: 256 values, 176 bytes
/// Layout: d(f16) + dmin(f16) + scales[12] + qh[32] + qs[128]
/// 4 groups of 64 elements: each group has 32 low-nibble + 32 high-nibble values
/// with separate scale/min pairs, using 2 qh bits per element (shifted by group).
fn dequantQ4KToF32(allocator: std.mem.Allocator, data: []const u8, n_elements: usize) ![]f32 {
    const out = try allocator.alloc(f32, n_elements);
    errdefer allocator.free(out);
    const block_size: usize = 256;
    const bytes_per_block: usize = 144; // Q4_K: 2+2+12+128 = 144 bytes per 256 elements
    const n_blocks = n_elements / block_size;
    for (0..n_blocks) |bi| {
        const blk = data[bi * bytes_per_block ..][0..bytes_per_block];
        const d_val: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[0..2], .little))));
        const dmin: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[2..4], .little))));
        const scales_raw = blk[4..16]; // 12 bytes of packed scales
        const qs = blk[16..144]; // 128 bytes of nibbles

        // Unpack 8 scale/min pairs (same as Q5_K)
        var sc: [8]u8 = undefined;
        var mn: [8]u8 = undefined;
        for (0..4) |i| {
            sc[i] = scales_raw[i] & 63;
            mn[i] = scales_raw[i + 4] & 63;
        }
        for (0..2) |i| {
            sc[4 + i] = (scales_raw[8 + i] & 0xF) | ((scales_raw[i] >> 6) << 4);
            mn[4 + i] = (scales_raw[8 + i] >> 4) | ((scales_raw[i + 4] >> 6) << 4);
            sc[6 + i] = (scales_raw[10 + i] & 0xF) | ((scales_raw[i + 2] >> 6) << 4);
            mn[6 + i] = (scales_raw[10 + i] >> 4) | ((scales_raw[i + 6] >> 6) << 4);
        }

        const base = bi * block_size;
        // 8 sub-blocks of 32 elements each
        for (0..8) |sb| {
            const d1: f32 = d_val * @as(f32, @floatFromInt(sc[sb]));
            const m1: f32 = dmin * @as(f32, @floatFromInt(mn[sb]));
            const qs_off = sb * 16; // 16 bytes = 32 nibbles
            for (0..32) |j| {
                const byte_idx = qs_off + j / 2;
                const nibble: u8 = if (j % 2 == 0) qs[byte_idx] & 0xF else qs[byte_idx] >> 4;
                out[base + sb * 32 + j] = d1 * @as(f32, @floatFromInt(nibble)) - m1;
            }
        }
    }
    return out;
}


fn dequantQ5KToF32(allocator: std.mem.Allocator, data: []const u8, n_elements: usize) ![]f32 {
    const out = try allocator.alloc(f32, n_elements);
    errdefer allocator.free(out);
    const block_size: usize = 256;
    const bytes_per_block: usize = 176;
    const n_blocks = n_elements / block_size;
    for (0..n_blocks) |bi| {
        const blk = data[bi * bytes_per_block ..][0..bytes_per_block];
        const d_val: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[0..2], .little))));
        const dmin: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[2..4], .little))));
        const scales_raw = blk[4..16]; // 12 bytes of packed scales
        const qh = blk[16..48]; // 32 bytes of high bits (256 bits)
        const qs = blk[48..176]; // 128 bytes of low nibbles

        // Unpack 8 scale/min pairs using get_scale_min_k4 logic
        var sc: [8]u8 = undefined;
        var mn: [8]u8 = undefined;
        for (0..4) |i| {
            sc[i] = scales_raw[i] & 63;
            mn[i] = scales_raw[i + 4] & 63;
        }
        for (0..2) |i| {
            sc[4 + i] = (scales_raw[8 + i] & 0xF) | ((scales_raw[i] >> 6) << 4);
            mn[4 + i] = (scales_raw[8 + i] >> 4) | ((scales_raw[i + 4] >> 6) << 4);
            sc[6 + i] = (scales_raw[10 + i] & 0xF) | ((scales_raw[i + 2] >> 6) << 4);
            mn[6 + i] = (scales_raw[10 + i] >> 4) | ((scales_raw[i + 6] >> 6) << 4);
        }

        const base = bi * block_size;
        var is: usize = 0; // scale index
        var ql_off: usize = 0; // offset into qs array

        // 4 groups of 64 elements (j advances by 64)
        for (0..4) |grp| {
            const d1: f32 = d_val * @as(f32, @floatFromInt(sc[is]));
            const m1: f32 = dmin * @as(f32, @floatFromInt(mn[is]));
            const d2: f32 = d_val * @as(f32, @floatFromInt(sc[is + 1]));
            const m2: f32 = dmin * @as(f32, @floatFromInt(mn[is + 1]));
            const j_base = grp * 64;
            // u1/u2 bit masks for qh: shift by 2*grp
            const u1_shift: u3 = @intCast(2 * grp);
            const u2_shift: u3 = @intCast(2 * grp + 1);

            for (0..32) |l| {
                const ql_byte = qs[ql_off + l];
                const qh_byte = qh[l];
                const h1: u8 = if ((qh_byte >> u1_shift) & 1 != 0) 16 else 0;
                const h2: u8 = if ((qh_byte >> u2_shift) & 1 != 0) 16 else 0;
                out[base + j_base + l] = d1 * @as(f32, @floatFromInt(@as(u32, ql_byte & 0xF) + h1)) - m1;
                out[base + j_base + l + 32] = d2 * @as(f32, @floatFromInt(@as(u32, ql_byte >> 4) + h2)) - m2;
            }
            ql_off += 32;
            is += 2;
        }
    }
    return out;
}

/// CPU dequantization of Q4_0 data to f32
fn dequantQ4ToF32(allocator: std.mem.Allocator, q4_data: []const u8, n_elements: usize) ![]f32 {
    const out = try allocator.alloc(f32, n_elements);
    errdefer allocator.free(out);

    const block_size: usize = 32;
    const bytes_per_block: usize = 18;
    const n_blocks = n_elements / block_size;

    for (0..n_blocks) |b| {
        const block = q4_data[b * bytes_per_block ..][0..bytes_per_block];
        const scale_bits = std.mem.readInt(u16, block[0..2], .little);
        const delta: f32 = @floatCast(@as(f16, @bitCast(scale_bits)));

        for (0..16) |j| {
            const byte = block[2 + j];
            const lo: i32 = @as(i32, @intCast(byte & 0xF)) - 8;
            const hi: i32 = @as(i32, @intCast(byte >> 4)) - 8;
            out[b * block_size + j] = @as(f32, @floatFromInt(lo)) * delta;
            out[b * block_size + j + 16] = @as(f32, @floatFromInt(hi)) * delta;
        }
    }
    return out;
}

/// CPU dequantization of F16 data to f32
fn dequantF16ToF32(allocator: std.mem.Allocator, f16_data: []const u8, n_elements: usize) ![]f32 {
    const out = try allocator.alloc(f32, n_elements);
    errdefer allocator.free(out);
    const f16_vals = @as([*]const f16, @alignCast(@ptrCast(f16_data.ptr)))[0..n_elements];
    for (0..n_elements) |i| {
        out[i] = @floatCast(f16_vals[i]);
    }
    return out;
}

/// Upload a weight tensor, auto-dequanting F16/Q4_0 to F32 for sgemv compatibility
/// Set force_f32 = true to dequant Q4_0 to F32 (bypasses Q4_0 GEMV for debugging)
var force_f32_weights: bool = false;

/// Upload shared expert weight as FP16 (dequant from any quant type → F32 → FP16)
fn uploadSharedExpertFP16(allocator: std.mem.Allocator, ggml_dtype: GGMLType, data: []const u8, rows: usize, cols: usize) !GpuTensor {
    if (ggml_dtype == .q4_0) {
        return GpuTensor.uploadQ4AsFP16(allocator, data, rows, cols);
    } else if (ggml_dtype == .f32) {
        return GpuTensor.uploadF32AsFP16(allocator, data, rows, cols);
    } else {
        // Dequant to F32 first, then upload as FP16
        const n_elem = rows * cols;
        const fp32_buf = if (ggml_dtype == .q8_0)
            try dequantQ8_0ToF32(allocator, data, n_elem)
        else if (ggml_dtype == .q4_1)
            try dequantQ4_1ToF32(allocator, data, n_elem)
        else if (ggml_dtype == .q5_k)
            try dequantQ5KToF32(allocator, data, n_elem)
        else if (ggml_dtype == .q6_k)
            try dequantQ6KToF32(allocator, data, n_elem)
        else
            return GpuTensor.upload(ggml_dtype, data, rows, cols);
        defer allocator.free(fp32_buf);
        return GpuTensor.uploadF32AsFP16(allocator, std.mem.sliceAsBytes(fp32_buf), rows, cols);
    }
}


fn uploadWeight(allocator: std.mem.Allocator, ggml_dtype: GGMLType, data: []const u8, rows: usize, cols: usize) !GpuTensor {
    if (ggml_dtype == .f16) {
        const n_elem = rows * cols;
        const fp32_buf = try dequantF16ToF32(allocator, data, n_elem);
        defer allocator.free(fp32_buf);
        return GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
    }
    if (ggml_dtype == .q4_0 and force_f32_weights) {
        const n_elem = rows * cols;
        const fp32_buf = try dequantQ4ToF32(allocator, data, n_elem);
        defer allocator.free(fp32_buf);
        return GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
    }
    // Dequant unsupported quantization types to F32 (Q4_1, Q8_0, Q5_K used in Qwen3.5 mixed quant)
    if (ggml_dtype == .q4_1) {
        const n_elem = rows * cols;
        const fp32_buf = try dequantQ4_1ToF32(allocator, data, n_elem);
        defer allocator.free(fp32_buf);
        return GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
    }
    if (ggml_dtype == .q8_0) {
        const n_elem = rows * cols;
        const fp32_buf = try dequantQ8_0ToF32(allocator, data, n_elem);
        defer allocator.free(fp32_buf);
        return GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
    }
    if (ggml_dtype == .q4_k) {
        const n_elem = rows * cols;
        const fp32_buf = try dequantQ4KToF32(allocator, data, n_elem);
        defer allocator.free(fp32_buf);
        return GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
    }
    if (ggml_dtype == .q5_k) {
        const n_elem = rows * cols;
        const fp32_buf = try dequantQ5KToF32(allocator, data, n_elem);
        defer allocator.free(fp32_buf);
        return GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
    }
    if (ggml_dtype == .q6_k) {
        const n_elem = rows * cols;
        const fp32_buf = try dequantQ6KToF32(allocator, data, n_elem);
        defer allocator.free(fp32_buf);
        return GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
    }
    return GpuTensor.upload(ggml_dtype, data, rows, cols);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line for model path
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const model_path = if (args.len > 1) args[1] else "/root/models/tinyllama-1.1b-chat-v1.0.Q4_0.gguf";

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  E2E Inference Benchmark — LLaMA Q4_0 on T4                 ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Model:  {s:50}║\n", .{model_path});
    std.debug.print("║  GPU:    NVIDIA T4 (SM75, 16GB, 320 GB/s)                   ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // ========================================================================
    // Phase 1: Memory-map GGUF file
    // ========================================================================
    std.debug.print("[Phase 1] Loading GGUF model: {s}\n", .{model_path});

    const file = try std.fs.cwd().openFile(model_path, .{});
    defer file.close();
    const stat = try file.stat();
    const file_size = stat.size;

    const mmap_data = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(mmap_data);

    std.debug.print("  File size: {} MB\n", .{file_size / (1024 * 1024)});

    // Validate GGUF magic
    const magic = std.mem.readInt(u32, mmap_data[0..4], .little);
    if (magic != 0x46554747) { // "GGUF" little-endian
        std.debug.print("  ERROR: Invalid GGUF magic: 0x{X}\n", .{magic});
        return;
    }
    const version = std.mem.readInt(u32, mmap_data[4..8], .little);
    const n_tensors = std.mem.readInt(u64, mmap_data[8..16], .little);
    const n_kv = std.mem.readInt(u64, mmap_data[16..24], .little);
    std.debug.print("  GGUF v{}, {} tensors, {} metadata KVs\n", .{ version, n_tensors, n_kv });

    // Parse metadata KV pairs — extract model dimensions
    var model_dim: u32 = 0;
    var model_n_layers: u32 = 0;
    var model_n_heads: u32 = 0;
    var model_n_kv_heads: u32 = 0;
    var model_ff_dim: u32 = 0;
    var model_ctx_len: u32 = 2048; // updated from metadata
    // MoE metadata
    var model_n_experts: u32 = 0;
    var model_n_experts_used: u32 = 0;
    var model_expert_ff: u32 = 0;
    var model_shared_expert_count: u32 = 0;
    var model_head_dim: u32 = 0; // 0 = auto (dim / n_heads)
    var model_rope_base: f32 = 10000.0;
    var model_eps: f32 = 1e-5;
    // DeltaNet/SSM metadata (Qwen3.5 hybrid)
    var model_ssm_inner: u32 = 0;
    var model_ssm_state_size: u32 = 0;
    var model_ssm_group_count: u32 = 0;
    var model_ssm_conv_kernel: u32 = 0;
    var model_ssm_time_step_rank: u32 = 0;
    var model_full_attn_interval: u32 = 0;
    var model_rope_dim: u32 = 0;
    var model_attn_head_dim: u32 = 0;

    var gpos: usize = 24;
    var kv_i: u64 = 0;
    while (kv_i < n_kv) : (kv_i += 1) {
        // Read key
        const key_len = std.mem.readInt(u64, mmap_data[gpos..][0..8], .little);
        gpos += 8;
        const key = mmap_data[gpos..][0..@intCast(key_len)];
        gpos += @intCast(key_len);
        // Read value type
        const vtype = std.mem.readInt(u32, mmap_data[gpos..][0..4], .little);
        gpos += 4;
        // Extract model params by suffix (supports llama.*, qwen2.*, qwen3moe.*, qwen35.*, mistral.*, etc.)
        // Strip architecture prefix: "qwen2.block_count" → "block_count"
        const suffix = blk: {
            if (std.mem.indexOf(u8, key, ".")) |dot| {
                break :blk key[dot + 1 ..];
            }
            break :blk key;
        };

        if (vtype == 4) { // UINT32
            const val = std.mem.readInt(u32, mmap_data[gpos..][0..4], .little);
            if (std.mem.eql(u8, suffix, "embedding_length")) {
                model_dim = val;
            } else if (std.mem.eql(u8, suffix, "block_count")) {
                model_n_layers = val;
            } else if (std.mem.eql(u8, suffix, "attention.head_count")) {
                model_n_heads = val;
            } else if (std.mem.eql(u8, suffix, "attention.head_count_kv")) {
                model_n_kv_heads = val;
            } else if (std.mem.eql(u8, suffix, "feed_forward_length")) {
                model_ff_dim = val;
            } else if (std.mem.eql(u8, suffix, "context_length")) {
                model_ctx_len = val;
            } else if (std.mem.eql(u8, suffix, "expert_count")) {
                model_n_experts = val;
            } else if (std.mem.eql(u8, suffix, "expert_used_count")) {
                model_n_experts_used = val;
            } else if (std.mem.eql(u8, suffix, "expert_feed_forward_length")) {
                model_expert_ff = val;
            } else if (std.mem.eql(u8, suffix, "expert_shared_count")) {
                model_shared_expert_count = val;
            } else if (std.mem.eql(u8, suffix, "expert_shared_feed_forward_length")) {
                // Qwen3.5 MoE: shared expert detected via feed_forward_length
                if (model_shared_expert_count == 0) model_shared_expert_count = 1;
            } else if (std.mem.eql(u8, suffix, "attention.key_length")) {
                model_head_dim = val;
            } else if (std.mem.eql(u8, suffix, "ssm.inner_size")) {
                model_ssm_inner = val;
            } else if (std.mem.eql(u8, suffix, "ssm.state_size")) {
                model_ssm_state_size = val;
            } else if (std.mem.eql(u8, suffix, "ssm.group_count")) {
                model_ssm_group_count = val;
            } else if (std.mem.eql(u8, suffix, "ssm.conv_kernel")) {
                model_ssm_conv_kernel = val;
            } else if (std.mem.eql(u8, suffix, "ssm.time_step_rank")) {
                model_ssm_time_step_rank = val;
            } else if (std.mem.eql(u8, suffix, "full_attention_interval")) {
                model_full_attn_interval = val;
            } else if (std.mem.eql(u8, suffix, "rope.dimension_count")) {
                model_rope_dim = val;
            } else if (std.mem.eql(u8, suffix, "attention.value_length")) {
                model_attn_head_dim = val;
            }
        } else if (vtype == 6) { // F32
            const val = @as(f32, @bitCast(std.mem.readInt(u32, mmap_data[gpos..][0..4], .little)));
            if (std.mem.eql(u8, suffix, "rope.freq_base")) {
                model_rope_base = val;
            } else if (std.mem.eql(u8, suffix, "attention.layer_norm_rms_epsilon")) {
                model_eps = val;
            }
        }
        // Skip value bytes
        gpos = skipGGUFValue(mmap_data, gpos, vtype);
    }

    // Validate required params
    if (model_dim == 0 or model_n_layers == 0 or model_n_heads == 0) {
        std.debug.print("  ERROR: Could not detect model dimensions from GGUF metadata\n", .{});
        std.debug.print("    dim={} layers={} heads={}\n", .{ model_dim, model_n_layers, model_n_heads });
        return;
    }
    if (model_n_kv_heads == 0) model_n_kv_heads = model_n_heads; // default: MHA

    // Compute derived model dimensions
    const DIM: u32 = model_dim;
    const N_LAYERS: u32 = model_n_layers;
    const N_HEADS: u32 = model_n_heads;
    const N_KV_HEADS: u32 = model_n_kv_heads;
    const HEAD_DIM: u32 = if (model_head_dim > 0) model_head_dim else DIM / N_HEADS;
    const KV_DIM: u32 = N_KV_HEADS * HEAD_DIM;
    // For MoE models with no dense FFN, use expert_ff as the FFN dimension for activations
    const FF_DIM: u32 = if (model_ff_dim > 0) model_ff_dim else (if (model_expert_ff > 0) model_expert_ff else 0);
    const MAX_SEQ: u32 = @min(model_ctx_len, 2048); // Cap for VRAM
    const IS_MOE: bool = model_n_experts > 0;
    // For MoE: expert_ff may be in metadata, or fallback to inferring from tensor dims
    const EXPERT_FF: u32 = if (model_expert_ff > 0) model_expert_ff else model_ff_dim;
    const N_EXPERTS: u32 = model_n_experts;
    const N_EXPERTS_TOPK: u32 = if (model_n_experts_used > 0) model_n_experts_used else 8;
    const HAS_SHARED_EXPERT: bool = model_shared_expert_count > 0;
    if (IS_MOE) {
        std.debug.print("  MoE detected: {} experts, TopK={}, expert_ff={}, shared={}\n", .{ N_EXPERTS, N_EXPERTS_TOPK, EXPERT_FF, @as(u32, if (HAS_SHARED_EXPERT) 1 else 0) });
    }
    const IS_HYBRID: bool = model_full_attn_interval > 0;
    if (IS_HYBRID) {
        std.debug.print("  Hybrid DeltaNet+Attn: interval={}, ssm_inner={}, state={}, groups={}, rank={}, conv_k={}\n", .{
            model_full_attn_interval, model_ssm_inner, model_ssm_state_size,
            model_ssm_group_count, model_ssm_time_step_rank, model_ssm_conv_kernel,
        });
        std.debug.print("  Hybrid attention: head_dim={}, attn_head_dim={}, rope_dim={}, rope_base={d:.1}\n", .{
            model_head_dim, model_attn_head_dim, model_rope_dim, model_rope_base,
        });
    }
    // VOCAB is detected from token_embd tensor dimensions below

    // Parse tensor descriptors
    const TensorInfo = struct {
        name: []const u8,
        n_dims: u32,
        dims: [4]u64,
        dtype: u32,
        data_offset: u64,
    };

    var tensor_infos = try allocator.alloc(TensorInfo, @intCast(n_tensors));
    defer allocator.free(tensor_infos);

    var t_i: u64 = 0;
    while (t_i < n_tensors) : (t_i += 1) {
        // Read name
        const name_len = std.mem.readInt(u64, mmap_data[gpos..][0..8], .little);
        gpos += 8;
        const name = mmap_data[gpos..][0..@intCast(name_len)];
        gpos += @intCast(name_len);

        // Read n_dims
        const n_dims = std.mem.readInt(u32, mmap_data[gpos..][0..4], .little);
        gpos += 4;

        // Read dimensions
        var dims: [4]u64 = .{ 0, 0, 0, 0 };
        for (0..n_dims) |d| {
            dims[d] = std.mem.readInt(u64, mmap_data[gpos..][0..8], .little);
            gpos += 8;
        }

        // Read dtype
        const dtype = std.mem.readInt(u32, mmap_data[gpos..][0..4], .little);
        gpos += 4;

        // Read data offset
        const data_offset = std.mem.readInt(u64, mmap_data[gpos..][0..8], .little);
        gpos += 8;

        tensor_infos[@intCast(t_i)] = .{
            .name = name,
            .n_dims = n_dims,
            .dims = dims,
            .dtype = dtype,
            .data_offset = data_offset,
        };
    }

    // Tensor data starts after alignment
    const alignment: usize = 32;
    const tensor_data_start = (gpos + alignment - 1) & ~(alignment - 1);
    std.debug.print("  Tensor data offset: 0x{X}\n", .{tensor_data_start});

    // ========================================================================
    // Phase 2: Initialize CUDA backend
    // ========================================================================
    std.debug.print("\n[Phase 2] Initializing CUDA backend...\n", .{});

    var backend = try CudaBackend.init(allocator, .{
        .device_id = 0,
        .enable_int8 = true,
        .enable_flash_attention = true,
    });
    defer backend.deinit();

    if (!backend.isAvailable()) {
        std.debug.print("  ERROR: CUDA not available.\n", .{});
        return;
    }
    std.debug.print("  Device: {s}\n", .{backend.device_name});
    std.debug.print("  Kernels: {} loaded\n", .{backend.loadedKernelCount()});
    std.debug.print("  cuBLAS: {s}\n", .{if (backend.cublas_handle != null) "ready" else "N/A"});

    // ========================================================================
    // Phase 3: Upload weights to GPU
    // ========================================================================
    std.debug.print("\n[Phase 3] Uploading model weights to GPU...\n", .{});

    var gpu_weights = try GpuModelWeights.init(allocator, N_LAYERS);
    defer gpu_weights.deinit();
    gpu_weights.weight_dtype = .q4_0;

    // Initialize MoE weight arrays if this is a MoE model
    if (IS_MOE) {
        try gpu_weights.initMoE(N_EXPERTS, N_EXPERTS_TOPK, EXPERT_FF, HAS_SHARED_EXPERT);
    }

    var uploaded: u32 = 0;
    var total_bytes: usize = 0;

    // Expert offloading: if MoE model's expert weights exceed available VRAM,
    // keep them in CPU mmap and transfer TopK per layer via pinned DMA.
    // This is the key to fitting REAM-compressed 35B models on T4 (16GB).
    const offload_experts: bool = blk: {
        if (!IS_MOE) break :blk false;
        // Estimate expert VRAM: 3 matrices × n_experts × expert_ff × dim × Q4_0 density
        const q4_bytes_per_elem: usize = 18; // 18 bytes per 32 elements (Q4_0 block)
        const expert_gate_bytes = @as(usize, N_EXPERTS) * EXPERT_FF * (DIM / 32) * q4_bytes_per_elem;
        const expert_up_bytes = expert_gate_bytes;
        const expert_down_bytes = @as(usize, N_EXPERTS) * DIM * (EXPERT_FF / 32) * q4_bytes_per_elem;
        const total_expert_bytes = (expert_gate_bytes + expert_up_bytes + expert_down_bytes) * N_LAYERS;
        // Query available VRAM (after framework init, before weight upload)
        var vram_free: usize = 0;
        var vram_total: usize = 0;
        _ = cuda.cuMemGetInfo(&vram_free, &vram_total);
        // Reserve 512MB for activations, KV cache, scratch, and MoE staging
        const vram_reserve: usize = 512 * 1024 * 1024;
        const vram_available = if (vram_free > vram_reserve) vram_free - vram_reserve else 0;
        // Non-expert weight estimate: ~15% of total model for attention+norms+embeddings
        const non_expert_estimate = total_expert_bytes / 6;
        const will_fit = (total_expert_bytes + non_expert_estimate) <= vram_available;
        if (!will_fit) {
            std.debug.print("  EXPERT OFFLOAD: expert weights {d:.0}MB > available VRAM {d:.0}MB — offloading to CPU mmap\n", .{
                @as(f64, @floatFromInt(total_expert_bytes)) / (1024.0 * 1024.0),
                @as(f64, @floatFromInt(vram_available)) / (1024.0 * 1024.0),
            });
        }
        break :blk !will_fit;
    };

    // Deferred output.weight processing (may appear before token_embd in GGUF)
    var output_weight_dtype: GGMLType = .f32;
    var output_weight_data: []const u8 = &.{};
    var output_weight_rows: usize = 0;
    var output_weight_cols: usize = 0;
    var output_weight_n_elem: usize = 0;

    // Save raw Wq L0 data for CPU-side GEMV verification
    var wq_l0_raw: ?[]const u8 = null;

    // Auto-detect weight dtype from first layer's weight tensor
    var detected_weight_dtype: GGMLType = .q4_0;

    // NOTE: force_f32_weights can be enabled to bypass Q4_0 GEMV for debugging
    // if (model_ssm_inner > 0) { force_f32_weights = true; }

    for (tensor_infos) |ti| {
        const abs_offset = tensor_data_start + @as(usize, @intCast(ti.data_offset));
        // GGUF dims: 1D=[size], 2D=[cols, rows], 3D=[cols, rows, depth]
        // For 3D stacked expert tensors (e.g. [dim, expert_ff, n_experts]), flatten: rows = dims[1] * dims[2]
        const rows: usize = if (ti.n_dims >= 3) @intCast(ti.dims[1] * ti.dims[2]) else if (ti.n_dims >= 2) @intCast(ti.dims[1]) else 1;
        const cols: usize = @intCast(ti.dims[0]);
        const ggml_dtype: GGMLType = @enumFromInt(ti.dtype);
        const n_elem = rows * cols;
        const size = ggml_dtype.tensorBytes(n_elem);
        if (abs_offset + size > mmap_data.len) {
            std.debug.print("  WARN: tensor '{s}' exceeds file (off=0x{X}, size={})\n", .{ ti.name, abs_offset, size });
            continue;
        }
        const data_slice = mmap_data[abs_offset..][0..size];

        // Match tensor name to weight slot
        // Print ALL tensor names to verify mapping
        std.debug.print("  T: '{s}' dtype={} dims=[{},{}]\n", .{ ti.name, @intFromEnum(ggml_dtype), cols, rows });

        if (std.mem.eql(u8, ti.name, "token_embd.weight")) {
            // Detect vocab size from tensor dimensions (rows = VOCAB)
            var detected_vocab: u32 = @intCast(rows);
            _ = &detected_vocab;
            // Embedding lookup kernel expects f32 — dequantize all quant types on CPU
            if (ggml_dtype == .q4_0) {
                const fp32_buf = try dequantQ4ToF32(allocator, data_slice, n_elem);
                defer allocator.free(fp32_buf);
                gpu_weights.token_embedding = try GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
            } else if (ggml_dtype == .f16) {
                const fp32_buf = try dequantF16ToF32(allocator, data_slice, n_elem);
                defer allocator.free(fp32_buf);
                gpu_weights.token_embedding = try GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
            } else if (ggml_dtype == .q6_k) {
                const fp32_buf = try dequantQ6KToF32(allocator, data_slice, n_elem);
                defer allocator.free(fp32_buf);
                gpu_weights.token_embedding = try GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
            } else if (ggml_dtype == .q4_1) {
                const fp32_buf = try dequantQ4_1ToF32(allocator, data_slice, n_elem);
                defer allocator.free(fp32_buf);
                gpu_weights.token_embedding = try GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
            } else if (ggml_dtype == .q8_0) {
                const fp32_buf = try dequantQ8_0ToF32(allocator, data_slice, n_elem);
                defer allocator.free(fp32_buf);
                gpu_weights.token_embedding = try GpuTensor.upload(.f32, std.mem.sliceAsBytes(fp32_buf), rows, cols);
            } else {
                gpu_weights.token_embedding = try GpuTensor.upload(ggml_dtype, data_slice, rows, cols);
            }
            total_bytes += size;
            uploaded += 1;
        } else if (std.mem.eql(u8, ti.name, "output_norm.weight")) {
            gpu_weights.final_norm = try GpuTensor.upload(.f32, data_slice, 1, cols);
            total_bytes += size;
            uploaded += 1;
        } else if (std.mem.eql(u8, ti.name, "output.weight")) {
            // Save output.weight info for later — may need to use token_embd (tied weights)
            output_weight_dtype = ggml_dtype;
            output_weight_data = data_slice;
            output_weight_rows = rows;
            output_weight_cols = cols;
            output_weight_n_elem = n_elem;
            uploaded += 1;
        } else if (std.mem.startsWith(u8, ti.name, "blk.")) {
            const after_blk = ti.name[4..];
            const dot_pos = std.mem.indexOfScalar(u8, after_blk, '.') orelse continue;
            const layer_str = after_blk[0..dot_pos];
            const layer = std.fmt.parseInt(u32, layer_str, 10) catch continue;
            if (layer >= N_LAYERS) continue;

            const suffix = after_blk[dot_pos + 1 ..];
            const lw = &gpu_weights.layers[layer];

            if (std.mem.eql(u8, suffix, "attn_norm.weight")) {
                lw.attn_norm = try GpuTensor.upload(.f32, data_slice, 1, cols);
            } else if (std.mem.eql(u8, suffix, "ffn_norm.weight")) {
                lw.ffn_norm = try GpuTensor.upload(.f32, data_slice, 1, cols);
            } else if (std.mem.eql(u8, suffix, "attn_q.weight")) {
                if (ggml_dtype != .q4_0) std.debug.print("  WARN: blk.{}.{s} dtype={} (expected q4_0)\n", .{ layer, suffix, @intFromEnum(ggml_dtype) });
                if (layer == 0) wq_l0_raw = data_slice;
                lw.wq = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "attn_k.weight")) {
                lw.wk = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "attn_v.weight")) {
                lw.wv = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "attn_output.weight")) {
                lw.wo = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "ffn_gate.weight")) {
                lw.w_gate = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "ffn_up.weight")) {
                lw.w_up = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "ffn_down.weight")) {
                lw.w_down = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "post_attention_norm.weight")) {
                // Qwen3.5: post_attention_norm = ffn_norm
                lw.ffn_norm = try GpuTensor.upload(.f32, data_slice, 1, cols);
            } else if (std.mem.eql(u8, suffix, "attn_qkv.weight")) {
                // DeltaNet fused QKV weight
                if (layer == 0) {
                    detected_weight_dtype = if (ggml_dtype == .f16 or force_f32_weights) .f32 else ggml_dtype;
                    if (ggml_dtype == .q4_0) wq_l0_raw = data_slice;
                }
                lw.attn_qkv = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "attn_gate.weight")) {
                // DeltaNet output gate weight
                lw.attn_gate = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "ssm_a")) {
                lw.ssm_a = try GpuTensor.upload(.f32, data_slice, 1, cols);
            } else if (std.mem.eql(u8, suffix, "ssm_alpha.weight")) {
                lw.ssm_alpha = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "ssm_beta.weight")) {
                lw.ssm_beta = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "ssm_conv1d.weight")) {
                lw.ssm_conv1d = try GpuTensor.upload(.f32, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "ssm_dt.bias")) {
                lw.ssm_dt_bias = try GpuTensor.upload(.f32, data_slice, 1, cols);
            } else if (std.mem.eql(u8, suffix, "ssm_norm.weight")) {
                if (layer == 0) std.debug.print("  [DIAG] ssm_norm.weight: cols={} (state_size={}, ssm_inner={})\n", .{ cols, model_ssm_state_size, model_ssm_inner });
                lw.ssm_norm = try GpuTensor.upload(.f32, data_slice, 1, cols);
            } else if (std.mem.eql(u8, suffix, "ssm_out.weight")) {
                lw.ssm_out = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
            } else if (std.mem.eql(u8, suffix, "attn_q_norm.weight")) {
                lw.attn_q_norm = try GpuTensor.upload(.f32, data_slice, 1, cols);
            } else if (std.mem.eql(u8, suffix, "attn_k_norm.weight")) {
                lw.attn_k_norm = try GpuTensor.upload(.f32, data_slice, 1, cols);
            } else if (IS_MOE and gpu_weights.moe_layers != null) {
                // MoE tensors
                const mw = &gpu_weights.moe_layers.?[layer];
                if (std.mem.eql(u8, suffix, "ffn_gate_inp.weight")) {
                    // Router: [n_experts × dim] — convert to FP16 for HGEMM router projection
                    if (ggml_dtype == .q4_0) {
                        mw.router_w = try GpuTensor.uploadQ4AsFP16(allocator, data_slice, rows, cols);
                    } else if (ggml_dtype == .f32) {
                        mw.router_w = try GpuTensor.uploadF32AsFP16(allocator, data_slice, rows, cols);
                    } else {
                        mw.router_w = try GpuTensor.upload(ggml_dtype, data_slice, rows, cols);
                    }
                } else if (std.mem.eql(u8, suffix, "ffn_gate_exps.weight")) {
                    mw.gate_dtype = ggml_dtype;
                    if (offload_experts) {
                        // CPU offload: store mmap pointer, skip GPU upload
                        mw.cpu_gate_q4 = data_slice.ptr;
                        mw.offloaded = true;
                    } else {
                        mw.experts_gate_q4 = try GpuTensor.upload(ggml_dtype, data_slice, rows, cols);
                    }
                } else if (std.mem.eql(u8, suffix, "ffn_up_exps.weight")) {
                    if (offload_experts) {
                        mw.cpu_up_q4 = data_slice.ptr;
                        mw.offloaded = true;
                    } else {
                        mw.experts_up_q4 = try GpuTensor.upload(ggml_dtype, data_slice, rows, cols);
                    }
                } else if (std.mem.eql(u8, suffix, "ffn_down_exps.weight")) {
                    mw.down_dtype = ggml_dtype;
                    if (offload_experts) {
                        mw.cpu_down_q4 = data_slice.ptr;
                        mw.offloaded = true;
                    } else {
                        mw.experts_down_q4 = try GpuTensor.upload(ggml_dtype, data_slice, rows, cols);
                    }
                } else if (HAS_SHARED_EXPERT and std.mem.eql(u8, suffix, "ffn_gate_shexp.weight")) {
                    // Shared expert: dequant to F32 for sgemv (always active)
                    mw.shared_gate = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
                } else if (HAS_SHARED_EXPERT and std.mem.eql(u8, suffix, "ffn_up_shexp.weight")) {
                    mw.shared_up = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
                } else if (HAS_SHARED_EXPERT and std.mem.eql(u8, suffix, "ffn_down_shexp.weight")) {
                    mw.shared_down = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
                } else if (HAS_SHARED_EXPERT and std.mem.eql(u8, suffix, "ffn_gate_inp_shexp.weight")) {
                    // Shared expert gate: [1 × dim] → sigmoid(W @ x) scalar gate
                    mw.shared_gate_inp = try uploadWeight(allocator, ggml_dtype, data_slice, rows, cols);
                } else continue;
            } else continue;
            total_bytes += size;
            uploaded += 1;
        }
    }

    // Detect VOCAB from token_embd (always 32000 for LLaMA, but detect dynamically)
    const VOCAB: u32 = if (gpu_weights.token_embedding.rows > 0) @intCast(gpu_weights.token_embedding.rows) else 32000;
    std.debug.print("  Model config: dim={} layers={} heads={} kv_heads={} head_dim={} ff={} vocab={} ctx={}\n", .{
        DIM, N_LAYERS, N_HEADS, N_KV_HEADS, HEAD_DIM, FF_DIM, VOCAB, MAX_SEQ,
    });

    // Post-loop: upload LM head (deferred because output.weight may precede token_embd in GGUF)
    if (output_weight_data.len > 0) {
        // output.weight is a separate tensor — dequantize to f32 for sgemv kernel
        if (output_weight_dtype == .q6_k) {
            const fp32_buf = try dequantQ6KToF32(allocator, output_weight_data, output_weight_n_elem);
            defer allocator.free(fp32_buf);
            std.debug.print("  Q6K LM head[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
                fp32_buf[0], fp32_buf[1], fp32_buf[2], fp32_buf[3], fp32_buf[4],
            });
            const fp32_bytes = std.mem.sliceAsBytes(fp32_buf);
            gpu_weights.lm_head = try GpuTensor.upload(.f32, fp32_bytes, output_weight_rows, output_weight_cols);
            std.debug.print("  output.weight: Q6_K dequantized to f32, rows={} cols={}\n", .{ output_weight_rows, output_weight_cols });
        } else if (output_weight_dtype == .q4_0) {
            // Keep LM head in Q4_0 — the forward pass uses q4GemvGpu when weight_dtype is q4_0.
            // Dequantizing to F32 wastes 7x VRAM and bandwidth (critical for 9B+ models).
            gpu_weights.lm_head = try GpuTensor.upload(.q4_0, output_weight_data, output_weight_rows, output_weight_cols);
            std.debug.print("  output.weight: Q4_0 kept native, rows={} cols={}\n", .{ output_weight_rows, output_weight_cols });
        } else if (output_weight_dtype == .q8_0) {
            // Q8_0 LM head: dequant to F32 (no native Q8 GEMV kernel)
            const fp32_buf = try dequantQ8_0ToF32(allocator, output_weight_data, output_weight_n_elem);
            defer allocator.free(fp32_buf);
            const fp32_bytes = std.mem.sliceAsBytes(fp32_buf);
            gpu_weights.lm_head = try GpuTensor.upload(.f32, fp32_bytes, output_weight_rows, output_weight_cols);
            std.debug.print("  output.weight: Q8_0 dequantized to f32, rows={} cols={}\n", .{ output_weight_rows, output_weight_cols });
        } else {
            gpu_weights.lm_head = try GpuTensor.upload(output_weight_dtype, output_weight_data, output_weight_rows, output_weight_cols);
            std.debug.print("  output.weight: uploaded as dtype={}\n", .{@intFromEnum(output_weight_dtype)});
        }
        total_bytes += output_weight_data.len;
        uploaded += 1;
    } else if (gpu_weights.token_embedding.dptr != 0) {
        // No output.weight tensor — use tied embeddings (token_embd = lm_head)
        gpu_weights.lm_head = gpu_weights.token_embedding;
        std.debug.print("  LM head: tied to token_embd (dtype={}, rows={}, cols={})\n", .{
            @intFromEnum(gpu_weights.token_embedding.dtype),
            gpu_weights.token_embedding.rows,
            gpu_weights.token_embedding.cols,
        });
    }

    std.debug.print("  Uploaded: {} tensors, {} MB to GPU\n", .{ uploaded, total_bytes / (1024 * 1024) });
    gpu_weights.total_vram_bytes = total_bytes;
    if (offload_experts) {
        std.debug.print("  REAM offload: expert weights on CPU mmap, TopK transferred per-layer via pinned DMA\n", .{});
    }

    // Detect BOS/EOS from GGUF tokenizer (overrides hardcoded LLaMA defaults)
    // Keep tokenizer alive for prompt encoding below
    var gguf_tokenizer: ?*GgufTokenizer = null;
    if (GgufTokenizer.loadFromGGUF(allocator, model_path)) |tok_early| {
        BOS_TOKEN = tok_early.bos_id;
        EOS_TOKEN = tok_early.eos_id;
        std.debug.print("  Tokenizer: BOS={} EOS={} (detected from GGUF vocab)\n", .{ BOS_TOKEN, EOS_TOKEN });
        gguf_tokenizer = tok_early;
    } else |_| {
        std.debug.print("  Tokenizer: using default BOS={} EOS={} (GGUF tokenizer load failed)\n", .{ BOS_TOKEN, EOS_TOKEN });
    }
    defer if (gguf_tokenizer) |t| t.deinit();

    // ========================================================================
    // Phase 4: Create forward pass
    // ========================================================================
    std.debug.print("  Detected weight dtype: {}\n", .{@intFromEnum(detected_weight_dtype)});
    std.debug.print("\n[Phase 4] Creating CUDA forward pass...\n", .{});

    var fwd = try CudaForwardPass.init(allocator, .{
        .dim = DIM,
        .n_layers = N_LAYERS,
        .n_heads = N_HEADS,
        .n_kv_heads = N_KV_HEADS,
        .n_ff = FF_DIM,
        .vocab_size = VOCAB,
        .max_seq_len = MAX_SEQ,
        .rope_freq_base = model_rope_base,
        .eps = model_eps,
        .weight_dtype = detected_weight_dtype,
        .head_dim = HEAD_DIM,
        // MoE fields (zero = dense model)
        .n_experts = N_EXPERTS,
        .n_experts_topk = N_EXPERTS_TOPK,
        .expert_ff = EXPERT_FF,
        .has_shared_expert = HAS_SHARED_EXPERT,
        // DeltaNet/SSM fields (zero = pure transformer)
        .ssm_inner_size = model_ssm_inner,
        .ssm_state_size = model_ssm_state_size,
        .ssm_group_count = model_ssm_group_count,
        .ssm_conv_kernel = model_ssm_conv_kernel,
        .ssm_time_step_rank = model_ssm_time_step_rank,
        .full_attn_interval = model_full_attn_interval,
        .rope_dim = model_rope_dim,
        .attn_head_dim = model_attn_head_dim,
    }, backend, gpu_weights);
    defer fwd.deinit();

    const vram = fwd.vramUsageMB();
    std.debug.print("  VRAM: weights={} MB, KV={} MB, act={} MB, total={} MB\n", .{
        vram.weights, vram.kv_cache, vram.activations, vram.total,
    });

    // ========================================================================
    // Phase 5: Run inference — generate tokens from a real prompt
    // ========================================================================
    std.debug.print("\n[Phase 5] Running inference...\n", .{});

    // Prompt tokens for "The capital of France is" — tokenizer-dependent
    const prompt_tokens = if (IS_HYBRID)
        // Qwen3.5 thinking: <|im_start|>user\nWhat is the capital of France?<|im_end|>\n<|im_start|>assistant\n<think>\n
        [_]u32{ 248045, 846, 198, 3710, 369, 279, 6511, 314, 9338, 30, 248046, 198, 248045, 74455, 198, 248068, 198, 0, 0, 0 }
    else
        // LLaMA/TinyLlama tokenizer (BOS=1)
        [_]u32{ BOS_TOKEN, 450, 7483, 310, 3444, 338, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    // Use runtime tokenizer to encode the prompt for Qwen3.5 (chat template)
    var dynamic_tokens: ?[]u32 = null;
    defer if (dynamic_tokens) |dt| allocator.free(dt);
    var n_prompt: usize = if (IS_HYBRID) 17 else 6;

    if (IS_HYBRID) {
        if (gguf_tokenizer) |tok| {
            // Use buildChatTokens for proper special token handling (im_start/im_end)
            if (tok.buildChatTokens("You are a helpful assistant.", "What is the capital of France?")) |chat_tokens| {
                dynamic_tokens = chat_tokens;
                n_prompt = chat_tokens.len;
                std.debug.print("  Chat-templated prompt ({s}): {} tokens\n", .{ tok.chat_style.name(), n_prompt });
            } else |_| {
                std.debug.print("  WARN: buildChatTokens failed, using hardcoded tokens\n", .{});
            }
        }
    }

    // Resolve final prompt slice: dynamic (chat-templated) or hardcoded
    const active_prompt: []const u32 = if (dynamic_tokens) |dt| dt[0..n_prompt] else prompt_tokens[0..n_prompt];

    std.debug.print("  Prompt: The capital of France is\n", .{});
    std.debug.print("  Prompt tokens ({d}): ", .{n_prompt});
    for (active_prompt) |t| std.debug.print("{} ", .{t});
    std.debug.print("\n", .{});

    // Diagnostic: step-by-step check on first token (skip for hybrid — layer 0 is DeltaNet)
    if (!IS_HYBRID) {
        std.debug.print("\n  [DIAG] Step-by-step activation check (token=BOS, pos=0):\n", .{});
        var diag_buf = try allocator.alloc(f32, @max(VOCAB, @max(DIM, FF_DIM)));
        defer allocator.free(diag_buf);

        const act = &fwd.activations;
        const gw = fwd.gpu_weights;
        const layer0 = &gw.layers[0];

        // Step 1: Embedding
        try backend.embeddingGpu(act.hidden.dptr, gw.token_embedding.dptr, BOS_TOKEN, DIM);
        try backend.syncStream();
        try act.hidden.downloadF32(diag_buf[0..DIM]);
        std.debug.print("    Embedding[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            diag_buf[0], diag_buf[1], diag_buf[2], diag_buf[3], diag_buf[4],
        });

        // Step 2: Check attn_norm weights then RMSNorm
        try layer0.attn_norm.downloadF32(diag_buf[0..DIM]);
        std.debug.print("    NormW[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            diag_buf[0], diag_buf[1], diag_buf[2], diag_buf[3], diag_buf[4],
        });
        try backend.rmsNormGpu(act.norm.dptr, act.hidden.dptr, layer0.attn_norm.dptr, DIM, 1e-5);
        try backend.syncStream();
        try act.norm.downloadF32(diag_buf[0..DIM]);
        std.debug.print("    Norm[0:5]:  {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            diag_buf[0], diag_buf[1], diag_buf[2], diag_buf[3], diag_buf[4],
        });

        // Step 3: CPU-side Q4_0 GEMV reference for Wq row 0
        // Save norm output for CPU reference
        const norm_cpu = try allocator.alloc(f32, DIM);
        defer allocator.free(norm_cpu);
        @memcpy(norm_cpu, diag_buf[0..DIM]);

        // Q4_0 GEMV on GPU
        try backend.q4GemvGpu(act.q.dptr, layer0.wq.dptr, act.norm.dptr, N_HEADS * HEAD_DIM, DIM);
        try backend.syncStream();
        try act.q.downloadF32(diag_buf[0..DIM]);
        std.debug.print("    Wq GPU[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            diag_buf[0], diag_buf[1], diag_buf[2], diag_buf[3], diag_buf[4],
        });

        // CPU-side Q4_0 dot product for row 0 of Wq (using wq_raw_data saved earlier)
        if (wq_l0_raw) |wq_raw| {
            const row_bytes: usize = (DIM / 32) * 18; // 64 blocks per row
            const row0 = wq_raw[0..row_bytes];
            var cpu_dot: f32 = 0;
            for (0..(DIM / 32)) |blk_i| {
                const blk = row0[blk_i * 18 ..][0..18];
                const scale_bits = std.mem.readInt(u16, blk[0..2], .little);
                const d: f32 = @floatCast(@as(f16, @bitCast(scale_bits)));
                for (0..16) |jj| {
                    const byte = blk[2 + jj];
                    const lo: f32 = @floatFromInt(@as(i32, @intCast(byte & 0xF)) - 8);
                    const hi: f32 = @floatFromInt(@as(i32, @intCast(byte >> 4)) - 8);
                    cpu_dot += d * lo * norm_cpu[blk_i * 32 + jj];
                    cpu_dot += d * hi * norm_cpu[blk_i * 32 + jj + 16];
                }
            }
            std.debug.print("    Wq CPU row0: {d:.6} (GPU row0: {d:.6})\n", .{ cpu_dot, diag_buf[0] });
        }

        try backend.q4GemvGpu(act.k.dptr, layer0.wk.dptr, act.norm.dptr, KV_DIM, DIM);
        try backend.q4GemvGpu(act.v.dptr, layer0.wv.dptr, act.norm.dptr, KV_DIM, DIM);
        try backend.syncStream();
        try act.q.downloadF32(diag_buf[0..DIM]);
        std.debug.print("    Wq GEMV:   min={d:.4} max={d:.4}\n", .{ arrMin(diag_buf[0..DIM]), arrMax(diag_buf[0..DIM]) });
        try act.k.downloadF32(diag_buf[0..KV_DIM]);
        std.debug.print("    Wk GEMV:   min={d:.4} max={d:.4}\n", .{ arrMin(diag_buf[0..KV_DIM]), arrMax(diag_buf[0..KV_DIM]) });
        try act.v.downloadF32(diag_buf[0..KV_DIM]);
        std.debug.print("    Wv GEMV:   min={d:.4} max={d:.4}\n", .{ arrMin(diag_buf[0..KV_DIM]), arrMax(diag_buf[0..KV_DIM]) });

        // Step 4: RoPE
        try backend.ropeQGpu(act.q.dptr, 0, HEAD_DIM, 10000.0, N_HEADS);
        try backend.ropeKGpu(act.k.dptr, 0, HEAD_DIM, 10000.0, N_KV_HEADS);
        try backend.syncStream();
        try act.q.downloadF32(diag_buf[0..DIM]);
        std.debug.print("    RoPE Q:    min={d:.4} max={d:.4}\n", .{ arrMin(diag_buf[0..DIM]), arrMax(diag_buf[0..DIM]) });

        // Step 5: KV cache store
        const kv_bytes = KV_DIM * @sizeOf(f32);
        try backend.deviceCopy(fwd.kv_cache.keyPtr(0, 0), act.k.dptr, kv_bytes);
        try backend.deviceCopy(fwd.kv_cache.valuePtr(0, 0), act.v.dptr, kv_bytes);

        // Step 6: Decode attention
        const attn_scale = 1.0 / @sqrt(@as(f32, @floatFromInt(HEAD_DIM)));
        try backend.decodeAttentionGpu(
            act.attn_out.dptr, act.q.dptr,
            fwd.kv_cache.keyLayerPtr(0), fwd.kv_cache.valueLayerPtr(0),
            N_HEADS, N_KV_HEADS, HEAD_DIM, KV_DIM, 1, attn_scale,
        );
        try backend.syncStream();
        try act.attn_out.downloadF32(diag_buf[0..DIM]);
        std.debug.print("    Attention: min={d:.4} max={d:.4}\n", .{ arrMin(diag_buf[0..DIM]), arrMax(diag_buf[0..DIM]) });

        // Step 7: Wo projection + residual
        try backend.q4GemvGpu(act.norm.dptr, layer0.wo.dptr, act.attn_out.dptr, DIM, N_HEADS * HEAD_DIM);
        try backend.syncStream();
        try act.norm.downloadF32(diag_buf[0..DIM]);
        std.debug.print("    Wo GEMV:   min={d:.4} max={d:.4}\n", .{ arrMin(diag_buf[0..DIM]), arrMax(diag_buf[0..DIM]) });

        try backend.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.norm.dptr, DIM);
        try backend.syncStream();
        try act.hidden.downloadF32(diag_buf[0..DIM]);
        std.debug.print("    Residual1: min={d:.4} max={d:.4}\n", .{ arrMin(diag_buf[0..DIM]), arrMax(diag_buf[0..DIM]) });

        // Step 8: FFN norm + gate/up + swiglu + down + residual
        if (IS_MOE) {
            // MoE models have no dense FFN weights — skip dense diagnostic
            std.debug.print("    [MoE] Skipping dense FFN diagnostic (routed experts)\n", .{});
        } else {
            try backend.rmsNormGpu(act.norm.dptr, act.hidden.dptr, layer0.ffn_norm.dptr, DIM, 1e-5);
            try backend.q4GemvGpu(act.gate.dptr, layer0.w_gate.dptr, act.norm.dptr, FF_DIM, DIM);
            try backend.q4GemvGpu(act.up.dptr, layer0.w_up.dptr, act.norm.dptr, FF_DIM, DIM);
            try backend.swigluGpu(act.gate.dptr, act.gate.dptr, act.up.dptr, FF_DIM);
            try backend.q4GemvGpu(act.ffn_out.dptr, layer0.w_down.dptr, act.gate.dptr, DIM, FF_DIM);
            try backend.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.ffn_out.dptr, DIM);
            try backend.syncStream();
            try act.hidden.downloadF32(diag_buf[0..DIM]);
            std.debug.print("    Layer0 out:min={d:.4} max={d:.4}\n", .{ arrMin(diag_buf[0..DIM]), arrMax(diag_buf[0..DIM]) });
        }

        // Reset forward pass state for the actual run
        fwd.reset();
        std.debug.print("\n", .{});
    }

    // Quick test: run 1 full forward pass and check hidden state after each layer
    if (!IS_HYBRID) {
        std.debug.print("  [DIAG] Per-layer hidden state after full forward (BOS):\n", .{});
        var diag2 = try allocator.alloc(f32, DIM);
        defer allocator.free(diag2);

        const act = &fwd.activations;
        const gw = fwd.gpu_weights;

        try backend.embeddingGpu(act.hidden.dptr, gw.token_embedding.dptr, BOS_TOKEN, DIM);
        try backend.syncStream();

        for (0..N_LAYERS) |l| {
            const layer = &gw.layers[l];
            try backend.rmsNormGpu(act.norm.dptr, act.hidden.dptr, layer.attn_norm.dptr, DIM, 1e-5);
            try backend.q4GemvGpu(act.q.dptr, layer.wq.dptr, act.norm.dptr, N_HEADS * HEAD_DIM, DIM);
            try backend.q4GemvGpu(act.k.dptr, layer.wk.dptr, act.norm.dptr, KV_DIM, DIM);
            try backend.q4GemvGpu(act.v.dptr, layer.wv.dptr, act.norm.dptr, KV_DIM, DIM);
            try backend.ropeQGpu(act.q.dptr, 0, HEAD_DIM, 10000.0, N_HEADS);
            try backend.ropeKGpu(act.k.dptr, 0, HEAD_DIM, 10000.0, N_KV_HEADS);
            const kv_bytes = KV_DIM * @sizeOf(f32);
            try backend.deviceCopy(fwd.kv_cache.keyPtr(l, 0), act.k.dptr, kv_bytes);
            try backend.deviceCopy(fwd.kv_cache.valuePtr(l, 0), act.v.dptr, kv_bytes);
            const sc = 1.0 / @sqrt(@as(f32, @floatFromInt(HEAD_DIM)));
            try backend.decodeAttentionGpu(
                act.attn_out.dptr, act.q.dptr,
                fwd.kv_cache.keyLayerPtr(l), fwd.kv_cache.valueLayerPtr(l),
                N_HEADS, N_KV_HEADS, HEAD_DIM, KV_DIM, 1, sc,
            );
            // For layer 2: trace each sub-step to find the explosion
            if (l == 2) {
                try backend.syncStream();
                try act.attn_out.downloadF32(diag2[0..DIM]);
                std.debug.print("    L2 attn_out: min={d:.4} max={d:.4}\n", .{ arrMin(diag2[0..DIM]), arrMax(diag2[0..DIM]) });
            }
            try backend.q4GemvGpu(act.norm.dptr, layer.wo.dptr, act.attn_out.dptr, DIM, N_HEADS * HEAD_DIM);
            if (l == 2) {
                try backend.syncStream();
                try act.norm.downloadF32(diag2[0..DIM]);
                std.debug.print("    L2 Wo out:   min={d:.4} max={d:.4}\n", .{ arrMin(diag2[0..DIM]), arrMax(diag2[0..DIM]) });
                try act.hidden.downloadF32(diag2[0..DIM]);
                std.debug.print("    L2 hidden:   min={d:.4} max={d:.4}\n", .{ arrMin(diag2[0..DIM]), arrMax(diag2[0..DIM]) });
            }
            try backend.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.norm.dptr, DIM);
            if (l == 2) {
                try backend.syncStream();
                try act.hidden.downloadF32(diag2[0..DIM]);
                std.debug.print("    L2 resid1:   min={d:.4} max={d:.4}\n", .{ arrMin(diag2[0..DIM]), arrMax(diag2[0..DIM]) });
            }
            try backend.rmsNormGpu(act.norm.dptr, act.hidden.dptr, layer.ffn_norm.dptr, DIM, 1e-5);
            if (IS_MOE) {
                // MoE FFN: use the forward pass's MoE dispatch
                try fwd.forwardMoEFFN(l, act.norm.dptr, act.hidden.dptr);
            } else {
                if (l == 2) {
                    try backend.syncStream();
                    try act.norm.downloadF32(diag2[0..DIM]);
                    std.debug.print("    L2 ffn_norm: min={d:.4} max={d:.4}\n", .{ arrMin(diag2[0..DIM]), arrMax(diag2[0..DIM]) });
                }
                try backend.q4GemvGpu(act.gate.dptr, layer.w_gate.dptr, act.norm.dptr, FF_DIM, DIM);
                try backend.q4GemvGpu(act.up.dptr, layer.w_up.dptr, act.norm.dptr, FF_DIM, DIM);
                if (l == 2) {
                    try backend.syncStream();
                    const ffn_tmp = try allocator.alloc(f32, FF_DIM);
                    defer allocator.free(ffn_tmp);
                    try act.gate.downloadF32(ffn_tmp);
                    std.debug.print("    L2 gate:     min={d:.4} max={d:.4}\n", .{ arrMin(ffn_tmp), arrMax(ffn_tmp) });
                    try act.up.downloadF32(ffn_tmp);
                    std.debug.print("    L2 up:       min={d:.4} max={d:.4}\n", .{ arrMin(ffn_tmp), arrMax(ffn_tmp) });
                }
                try backend.swigluGpu(act.gate.dptr, act.gate.dptr, act.up.dptr, FF_DIM);
                if (l == 2) {
                    try backend.syncStream();
                    const ffn_tmp2 = try allocator.alloc(f32, FF_DIM);
                    defer allocator.free(ffn_tmp2);
                    try act.gate.downloadF32(ffn_tmp2);
                    std.debug.print("    L2 swiglu:   min={d:.4} max={d:.4}\n", .{ arrMin(ffn_tmp2), arrMax(ffn_tmp2) });
                }
                try backend.q4GemvGpu(act.ffn_out.dptr, layer.w_down.dptr, act.gate.dptr, DIM, FF_DIM);
                if (l == 2) {
                    try backend.syncStream();
                    try act.ffn_out.downloadF32(diag2[0..DIM]);
                    std.debug.print("    L2 ffn_out:  min={d:.4} max={d:.4}\n", .{ arrMin(diag2[0..DIM]), arrMax(diag2[0..DIM]) });
                }
                try backend.vectorAddGpu(act.hidden.dptr, act.hidden.dptr, act.ffn_out.dptr, DIM);
            } // end else (dense FFN)
            try backend.syncStream();
            try act.hidden.downloadF32(diag2[0..DIM]);
            std.debug.print("    L{:2}: min={d:.4} max={d:.4}\n", .{ l, arrMin(diag2[0..DIM]), arrMax(diag2[0..DIM]) });
        }
        // Final norm + LM head
        try backend.rmsNormGpu(act.norm.dptr, act.hidden.dptr, gw.final_norm.dptr, DIM, 1e-5);
        try backend.syncStream();
        try act.norm.downloadF32(diag2[0..DIM]);
        std.debug.print("    FinalNorm: min={d:.4} max={d:.4}\n", .{ arrMin(diag2[0..DIM]), arrMax(diag2[0..DIM]) });

        // Check LM head weight info
        std.debug.print("    LM head: dptr=0x{X} dtype={} rows={} cols={} bytes={}\n", .{
            gw.lm_head.dptr, @intFromEnum(gw.lm_head.dtype),
            gw.lm_head.rows, gw.lm_head.cols, gw.lm_head.size_bytes,
        });

        const logits_diag = try allocator.alloc(f32, VOCAB);
        defer allocator.free(logits_diag);
        // LM head: use sgemvGpu since weights are f32 (tied embedding)
        try backend.sgemvGpu(act.logits.dptr, gw.lm_head.dptr, act.norm.dptr, VOCAB, DIM);
        try backend.syncStream();
        try act.logits.downloadF32(logits_diag);
        std.debug.print("    Logits[0:10]:", .{});
        for (0..10) |li| std.debug.print(" {d:.4}", .{logits_diag[li]});
        std.debug.print("\n", .{});
        std.debug.print("    Logits range: [{d:.4}, {d:.4}]\n", .{ arrMin(logits_diag), arrMax(logits_diag) });

        fwd.reset();
        std.debug.print("\n", .{});
    }

    // Debug: for hybrid models, step through DeltaNet layer 0 and dump intermediates
    if (IS_HYBRID) {
        std.debug.print("\n  [DIAG] DeltaNet layer 0 step-by-step (tok={}, pos=0):\n", .{active_prompt[0]});
        fwd.reset();
        const act = &fwd.activations;
        const gw = fwd.gpu_weights;
        const ds = &fwd.deltanet_state.?;
        const ssm_kv = fwd.config.ssmKVDim();
        const ssm_channels = fwd.config.ssmQKVDim();
        const ssm_v_dim = fwd.config.ssmVDim();
        const nh = fwd.config.ssm_time_step_rank;
        var dbuf = try allocator.alloc(f32, @max(ssm_channels, @max(DIM, VOCAB)));
        defer allocator.free(dbuf);

        // Embedding
        try backend.embeddingGpu(act.hidden.dptr, gw.token_embedding.dptr, active_prompt[0], DIM);
        try backend.syncStream();
        try act.hidden.downloadF32(dbuf[0..DIM]);
        std.debug.print("    Embed[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[0], dbuf[1], dbuf[2], dbuf[3], dbuf[4],
        });

        // RMSNorm
        try backend.rmsNormGpu(act.norm.dptr, act.hidden.dptr, gw.layers[0].attn_norm.dptr, DIM, 1e-5);
        try backend.syncStream();
        try act.norm.downloadF32(dbuf[0..DIM]);
        std.debug.print("    Norm[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[0], dbuf[1], dbuf[2], dbuf[3], dbuf[4],
        });

        // QKV projection (per-tensor dtype for mixed-quant Qwen3.5)
        if (gw.layers[0].attn_qkv.dtype == .q4_0) {
            try backend.q4GemvGpu(ds.d_qkv, gw.layers[0].attn_qkv.dptr, act.norm.dptr, ssm_channels, DIM);
        } else {
            try backend.sgemvGpu(ds.d_qkv, gw.layers[0].attn_qkv.dptr, act.norm.dptr, ssm_channels, DIM);
        }
        try backend.syncStream();
        if (cuda.cuMemcpyDtoH(@ptrCast(dbuf.ptr), ds.d_qkv, ssm_channels * @sizeOf(f32)) != .success) return error.CudaMemcpyFailed;
        std.debug.print("    QKV[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[0], dbuf[1], dbuf[2], dbuf[3], dbuf[4],
        });

        // CPU-side Q4_0 GEMV verification (if Q4_0 weights available)
        if (wq_l0_raw != null and fwd.config.weight_dtype == .q4_0) {
            // Download full norm buffer from GPU
            const norm_cpu = try allocator.alloc(f32, DIM);
            defer allocator.free(norm_cpu);
            if (cuda.cuMemcpyDtoH(@ptrCast(norm_cpu.ptr), act.norm.dptr, DIM * @sizeOf(f32)) != .success) {
                std.debug.print("    [CPU GEMV] Failed to download norm\n", .{});
            } else {
                const raw = wq_l0_raw.?;
                const row_bytes: usize = (DIM / 32) * 18;
                // Compute first 5 rows of CPU Q4_0 GEMV
                for (0..5) |r| {
                    const row_start = r * row_bytes;
                    var dot: f32 = 0;
                    const n_blocks = DIM / 32;
                    for (0..n_blocks) |b| {
                        const block = raw[row_start + b * 18 ..][0..18];
                        const scale_bits = std.mem.readInt(u16, block[0..2], .little);
                        const scale: f32 = @floatCast(@as(f16, @bitCast(scale_bits)));
                        for (0..16) |j| {
                            const byte = block[2 + j];
                            const lo: f32 = @as(f32, @floatFromInt(@as(i32, @intCast(byte & 0xF)) - 8)) * scale;
                            const hi: f32 = @as(f32, @floatFromInt(@as(i32, @intCast(byte >> 4)) - 8)) * scale;
                            dot += lo * norm_cpu[b * 32 + j];
                            dot += hi * norm_cpu[b * 32 + j + 16];
                        }
                    }
                    std.debug.print("    CPU Q4 GEMV[{d}]={d:.6} GPU={d:.6} diff={d:.6}\n", .{
                        r, dot, dbuf[r], dot - dbuf[r],
                    });
                }
            }
        }

        // Conv1d + SiLU
        try backend.deltanetConv1d(ds.d_qkv, ds.convPtr(0), ds.d_qkv, gw.layers[0].ssm_conv1d.dptr, ssm_channels, fwd.config.ssm_conv_kernel);
        try backend.syncStream();
        if (cuda.cuMemcpyDtoH(@ptrCast(dbuf.ptr), ds.d_qkv, ssm_channels * @sizeOf(f32)) != .success) return error.CudaMemcpyFailed;
        std.debug.print("    Conv Q[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[0], dbuf[1], dbuf[2], dbuf[3], dbuf[4],
        });
        std.debug.print("    Conv K[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[ssm_kv], dbuf[ssm_kv + 1], dbuf[ssm_kv + 2], dbuf[ssm_kv + 3], dbuf[ssm_kv + 4],
        });
        std.debug.print("    Conv V[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[2 * ssm_kv], dbuf[2 * ssm_kv + 1], dbuf[2 * ssm_kv + 2], dbuf[2 * ssm_kv + 3], dbuf[2 * ssm_kv + 4],
        });
        std.debug.print("    QKV dims: Q={} K={} V={} total={}\n", .{ ssm_kv, ssm_kv, ssm_v_dim, ssm_channels });

        // Alpha/beta projections (before gates) — per-tensor dtype
        if (gw.layers[0].ssm_alpha.dtype == .q4_0) {
            try backend.q4GemvGpu(ds.d_alpha, gw.layers[0].ssm_alpha.dptr, act.norm.dptr, nh, DIM);
        } else {
            try backend.sgemvGpu(ds.d_alpha, gw.layers[0].ssm_alpha.dptr, act.norm.dptr, nh, DIM);
        }
        if (gw.layers[0].ssm_beta.dtype == .q4_0) {
            try backend.q4GemvGpu(ds.d_beta, gw.layers[0].ssm_beta.dptr, act.norm.dptr, nh, DIM);
        } else {
            try backend.sgemvGpu(ds.d_beta, gw.layers[0].ssm_beta.dptr, act.norm.dptr, nh, DIM);
        }
        try backend.syncStream();
        if (cuda.cuMemcpyDtoH(@ptrCast(dbuf.ptr), ds.d_alpha, nh * @sizeOf(f32)) != .success) return error.CudaMemcpyFailed;
        std.debug.print("    a_proj[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[0], dbuf[1], dbuf[2], dbuf[3], dbuf[4],
        });
        if (cuda.cuMemcpyDtoH(@ptrCast(dbuf.ptr), ds.d_beta, nh * @sizeOf(f32)) != .success) return error.CudaMemcpyFailed;
        std.debug.print("    b_proj[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[0], dbuf[1], dbuf[2], dbuf[3], dbuf[4],
        });

        // Gates
        try backend.deltanetGates(ds.d_alpha, ds.d_beta, ds.d_alpha, ds.d_beta, gw.layers[0].ssm_a.dptr, gw.layers[0].ssm_dt_bias.dptr, nh);
        try backend.syncStream();
        if (cuda.cuMemcpyDtoH(@ptrCast(dbuf.ptr), ds.d_alpha, nh * @sizeOf(f32)) != .success) return error.CudaMemcpyFailed;
        std.debug.print("    Alpha[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[0], dbuf[1], dbuf[2], dbuf[3], dbuf[4],
        });
        if (cuda.cuMemcpyDtoH(@ptrCast(dbuf.ptr), ds.d_beta, nh * @sizeOf(f32)) != .success) return error.CudaMemcpyFailed;
        std.debug.print("    Beta[0:5]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
            dbuf[0], dbuf[1], dbuf[2], dbuf[3], dbuf[4],
        });

        // Full forward for comparison
        fwd.reset();
        const test_logits = fwd.forward(active_prompt[0], 0) catch |err| {
            std.debug.print("  [DBG] forward failed: {}\n", .{err});
            return err;
        };
        std.debug.print("  [DBG] forward OK, logits[0]={d:.4}\n", .{test_logits[0]});
        fwd.reset();

        fwd.reset();
    }

    // Prefill: batched when possible, token-by-token fallback
    std.debug.print("  Prefilling...\n", .{});
    const prefill_start = std.time.nanoTimestamp();
    var logits: []f32 = undefined;

    // Token-by-token prefill for offloaded MoE (batch alloc would OOM and corrupt CUDA context)
    // Batched prefill for non-offloaded models
    if (offload_experts) {
        // Token-by-token prefill (safe — reuses single-token MoE scratch)
        std.debug.print("  (Token-by-token prefill for offloaded MoE)\n", .{});
        for (active_prompt, 0..) |tok, p| {
            logits = try fwd.forward(tok, p);
        }
    } else {
        const prefill_chunk: u32 = if (IS_MOE) 64 else 32;
        logits = fwd.prefillChunked(active_prompt, prefill_chunk) catch |err| blk: {
            std.debug.print("  (Batched prefill unavailable: {}, falling back to token-by-token)\n", .{err});
            fwd.reset();
            var fallback_logits: []f32 = undefined;
            for (active_prompt, 0..) |tok, p| {
                fallback_logits = try fwd.forward(tok, p);
            }
            break :blk fallback_logits;
        };
    }

    const prefill_ns = std.time.nanoTimestamp() - prefill_start;
    const prefill_chunk: u32 = if (IS_MOE) 64 else 32;
    const prefill_mode: []const u8 = if (offload_experts) "token-by-token-offload" else if (IS_MOE) "batched-MoE" else if (gpu_weights.has_fp16_weights) "batched-HGEMM" else "token-by-token";
    std.debug.print("  Prefill ({s}): {} tokens in {d:.1} ms ({d:.0} tokens/s)\n", .{
        prefill_mode,
        n_prompt,
        @as(f64, @floatFromInt(prefill_ns)) / 1e6,
        @as(f64, @floatFromInt(n_prompt)) / (@as(f64, @floatFromInt(prefill_ns)) / 1e9),
    });

    // Decode: generate tokens
    const gen_count: usize = 100;
    std.debug.print("\n  Generating {} tokens...\n", .{gen_count});

    // GPU warmup: run 10 forward passes to ramp up clocks before timing
    {
        var warmup_pos: usize = n_prompt;
        var warmup_logits = logits;
        for (0..10) |_| {
            const wtok = argmax(warmup_logits);
            warmup_logits = try fwd.forward(wtok, warmup_pos);
            warmup_pos += 1;
        }
        // Reset state for actual benchmark — re-prefill
        fwd.reset();
        if (offload_experts) {
            for (active_prompt, 0..) |tok, p| {
                logits = try fwd.forward(tok, p);
            }
        } else {
            logits = fwd.prefillChunked(active_prompt, prefill_chunk) catch blk: {
                for (active_prompt, 0..) |tok, p| {
                    _ = try fwd.forward(tok, p);
                }
                break :blk try fwd.forward(argmax(logits), n_prompt);
            };
        }
        logits = try fwd.forward(argmax(logits), n_prompt);
        std.debug.print("  (GPU warmup complete, clocks should be boosted)\n", .{});
    }

    var generated = std.ArrayListUnmanaged(u32){};
    defer generated.deinit(allocator);

    const decode_start = std.time.nanoTimestamp();
    var pos: usize = n_prompt;

    for (0..gen_count) |_| {
        // Greedy argmax
        const next_token = argmax(logits);
        try generated.append(allocator, next_token);

        if (next_token == EOS_TOKEN) {
            std.debug.print("  [EOS reached at token {}]\n", .{generated.items.len});
            break;
        }

        // Forward pass for next token
        logits = try fwd.forward(next_token, pos);
        pos += 1;
    }
    const decode_ns = std.time.nanoTimestamp() - decode_start;
    const decode_tokens = generated.items.len;
    const decode_ms = @as(f64, @floatFromInt(decode_ns)) / 1e6;
    const decode_tps = @as(f64, @floatFromInt(decode_tokens)) / (@as(f64, @floatFromInt(decode_ns)) / 1e9);

    // ========================================================================
    // Phase 6: Results
    // ========================================================================
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Results                                                     ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Generated: {} tokens in {d:.1} ms                       \n", .{ decode_tokens, decode_ms });
    std.debug.print("║  Decode TPS: {d:.1} tokens/sec                            \n", .{decode_tps});
    std.debug.print("║  Per-token:  {d:.2} ms/token                              \n", .{decode_ms / @as(f64, @floatFromInt(decode_tokens))});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Print generated token IDs
    std.debug.print("  Generated token IDs: ", .{});
    for (generated.items) |tok| {
        std.debug.print("{} ", .{tok});
    }
    std.debug.print("\n", .{});

    // Decode tokens to text using GGUF tokenizer
    if (GgufTokenizer.loadFromGGUF(allocator, model_path)) |tok_inst| {
        defer tok_inst.deinit();
        if (tok_inst.decode(generated.items)) |text| {
            defer allocator.free(text);
            std.debug.print("\n  Decoded text: {s}\n", .{text});
        } else |_| {
            std.debug.print("\n  (token decode failed)\n", .{});
        }
    } else |_| {
        std.debug.print("\n  (tokenizer load failed)\n", .{});
    }

    // Sanity check: top-5 logits after first decode should have reasonable distribution
    std.debug.print("\n  Top-5 logits after last token:\n", .{});
    var top5 = [_]struct { id: u32, val: f32 }{
        .{ .id = 0, .val = -std.math.inf(f32) },
        .{ .id = 0, .val = -std.math.inf(f32) },
        .{ .id = 0, .val = -std.math.inf(f32) },
        .{ .id = 0, .val = -std.math.inf(f32) },
        .{ .id = 0, .val = -std.math.inf(f32) },
    };
    for (logits, 0..) |val, i| {
        if (val > top5[4].val) {
            top5[4] = .{ .id = @intCast(i), .val = val };
            // Bubble sort the last element into place
            var j: usize = 4;
            while (j > 0 and top5[j].val > top5[j - 1].val) : (j -= 1) {
                const tmp = top5[j];
                top5[j] = top5[j - 1];
                top5[j - 1] = tmp;
            }
        }
    }
    for (top5) |entry| {
        std.debug.print("    token {}: logit {d:.4}\n", .{ entry.id, entry.val });
    }

    // Profiled decode — measure GEMV vs attention breakdown
    // (Skip for hybrid DeltaNet models — forwardProfiled assumes standard transformer)
    if (!IS_HYBRID) {
        std.debug.print("\n  Profiled single-token decode:\n", .{});
        fwd.reset();
        // Re-prefill
        for (active_prompt, 0..) |tok, p| {
            _ = try fwd.forward(tok, p);
        }
        // Profile 10 decode steps
        var total_gemv: i128 = 0;
        var total_attn: i128 = 0;
        var total_other: i128 = 0;
        var total_total: i128 = 0;
        const profile_steps: usize = 10;
        var next_tok: u32 = generated.items[0];
        var prof_pos: usize = n_prompt;
        for (0..profile_steps) |_| {
            const timing = try fwd.forwardProfiled(next_tok, prof_pos);
            total_gemv += timing[0];
            total_attn += timing[1];
            total_other += timing[2];
            total_total += timing[3];
            next_tok = argmax(fwd.logits_cpu[0..VOCAB]);
            prof_pos += 1;
        }
        const avg = struct {
            fn f(ns: i128, n: usize) f64 {
                return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n)) / 1e6;
            }
        }.f;
        std.debug.print("    GEMV:      {d:.2} ms ({d:.0}%%)\n", .{
            avg(total_gemv, profile_steps),
            @as(f64, @floatFromInt(total_gemv)) / @as(f64, @floatFromInt(total_total)) * 100,
        });
        std.debug.print("    Attention: {d:.2} ms ({d:.0}%%)\n", .{
            avg(total_attn, profile_steps),
            @as(f64, @floatFromInt(total_attn)) / @as(f64, @floatFromInt(total_total)) * 100,
        });
        std.debug.print("    Other:     {d:.2} ms ({d:.0}%%)\n", .{
            avg(total_other, profile_steps),
            @as(f64, @floatFromInt(total_other)) / @as(f64, @floatFromInt(total_total)) * 100,
        });
        std.debug.print("    Total:     {d:.2} ms → {d:.0} TPS\n", .{
            avg(total_total, profile_steps),
            1000.0 / avg(total_total, profile_steps),
        });
    } else {
        std.debug.print("\n  (Profiled breakdown skipped for hybrid DeltaNet model)\n", .{});
    }

    // Expert cache stats (MoE only)
    if (IS_MOE) {
        const cs = fwd.expertCacheStats();
        std.debug.print("\n  Expert cache: {} hits, {} misses ({d:.1}%% hit rate)\n", .{ cs.hits, cs.misses, cs.hit_rate });
        if (offload_experts) {
            const q4s = fwd.q4CacheStats();
            std.debug.print("  Q4 offload cache: {} hits, {} misses ({d:.1}%% hit rate)\n", .{ q4s.hits, q4s.misses, q4s.hit_rate });
        }
    }

    // ========================================================================
    // Phase 7a: DART Speculative Decode Generation (MoE only)
    // ========================================================================
    if (IS_MOE) {
        const dart_k: u32 = 16; // draft K tokens per cycle
        const dart_gen_count: usize = 100;
        std.debug.print("\n  DART Speculative Decode (K={}, greedy):\n", .{dart_k});

        // Reset and re-prefill
        fwd.reset();
        var dart_logits = fwd.prefillChunked(active_prompt, prefill_chunk) catch blk: {
            for (active_prompt, 0..) |tok, p| {
                _ = try fwd.forward(tok, p);
            }
            break :blk try fwd.forward(active_prompt[n_prompt - 1], n_prompt - 1);
        };

        var dart_generated = std.ArrayListUnmanaged(u32){};
        defer dart_generated.deinit(allocator);
        var dart_pos: usize = n_prompt;
        var dart_accepted: usize = 0;
        var dart_drafted: usize = 0;

        const dart_start = std.time.nanoTimestamp();

        while (dart_generated.items.len < dart_gen_count) {
            // Draft phase: generate K tokens greedily with single-token forward
            var draft_tokens: [128]u32 = undefined;
            var draft_positions: [128]usize = undefined;
            var draft_count: u32 = 0;

            // First draft token from current logits
            var draft_tok = @as(u32, @intCast(argmax(dart_logits)));
            if (draft_tok == EOS_TOKEN) {
                try dart_generated.append(allocator, draft_tok);
                break;
            }

            draft_tokens[0] = draft_tok;
            draft_positions[0] = dart_pos;
            draft_count = 1;

            // Draft remaining K-1 tokens
            while (draft_count < dart_k) {
                dart_logits = try fwd.forward(draft_tok, dart_pos + draft_count - 1);
                draft_tok = @as(u32, @intCast(argmax(dart_logits)));
                if (draft_tok == EOS_TOKEN) break;
                draft_tokens[draft_count] = draft_tok;
                draft_positions[draft_count] = dart_pos + draft_count;
                draft_count += 1;
            }

            dart_drafted += draft_count;

            // Verify phase: batch forward all draft tokens
            // Reset KV cache to pre-draft state and re-verify
            fwd.kv_cache.seq_len = dart_pos;
            fwd.seq_len = dart_pos;

            var verify_logits_buf: [256000]f32 = undefined;
            fwd.forwardBatchMoE(
                draft_tokens[0..draft_count],
                draft_positions[0..draft_count],
                verify_logits_buf[0..VOCAB],
            ) catch {
                // Batch verify failed — accept first token only
                try dart_generated.append(allocator, draft_tokens[0]);
                dart_pos += 1;
                dart_accepted += 1;
                dart_logits = try fwd.forward(draft_tokens[0], dart_pos - 1);
                continue;
            };

            // Accept phase: greedy — accept all draft tokens that match verify
            // For greedy decoding, the verify logits give us the "correct" next token
            // at each position. Accept draft[i] if it matches argmax(verify_logits[i-1]).
            // The first draft token is always accepted (it came from the real model).
            var accepted: u32 = 1;
            try dart_generated.append(allocator, draft_tokens[0]);

            // For positions 1..K: verify_logits gives logits AFTER processing draft[0..K]
            // Since forwardBatchMoE returns logits for the LAST token only,
            // we accept all draft tokens (greedy self-speculative: draft == verify model)
            for (1..draft_count) |i| {
                if (dart_generated.items.len >= dart_gen_count) break;
                try dart_generated.append(allocator, draft_tokens[i]);
                accepted += 1;
            }

            dart_accepted += accepted;
            dart_pos += accepted;

            // Get logits for next cycle
            dart_logits = verify_logits_buf[0..VOCAB];
        }

        const dart_ns = std.time.nanoTimestamp() - dart_start;
        const dart_ms = @as(f64, @floatFromInt(dart_ns)) / 1e6;
        const dart_tps = @as(f64, @floatFromInt(dart_generated.items.len)) / (@as(f64, @floatFromInt(dart_ns)) / 1e9);
        const accept_rate = if (dart_drafted > 0) @as(f64, @floatFromInt(dart_accepted)) / @as(f64, @floatFromInt(dart_drafted)) * 100.0 else 0.0;

        std.debug.print("    Generated: {} tokens in {d:.1} ms\n", .{ dart_generated.items.len, dart_ms });
        std.debug.print("    DART TPS: {d:.1} tokens/sec (vs {d:.1} baseline)\n", .{ dart_tps, decode_tps });
        std.debug.print("    Speedup: {d:.2}×\n", .{dart_tps / decode_tps});
        std.debug.print("    Acceptance: {}/{} ({d:.1}%%)\n", .{ dart_accepted, dart_drafted, accept_rate });
    }

    // ========================================================================
    // Phase 7b: DART Batch Benchmark (MoE only — union-dequant amortization)
    // ========================================================================
    if (IS_MOE) {
        // Disable and free expert cache to reclaim VRAM for batch scratch
        fwd.expert_cache_enabled = false;
        fwd.freeExpertCache();
        std.debug.print("\n  DART Batch Benchmark (MoE union-dequant amortization):\n", .{});
        std.debug.print("  ┌──────┬────────────┬────────────┬──────────┬──────────┬──────────┬──────────┐\n", .{});
        std.debug.print("  │  K   │  Batch ms  │  ms/tok    │  α=0.70  │  α=0.85  │  α=0.90  │  α=0.95  │\n", .{});
        std.debug.print("  ├──────┼────────────┼────────────┼──────────┼──────────┼──────────┼──────────┤\n", .{});

        const batch_ks = [_]u32{ 1, 4, 8, 16, 32, 48, 64, 96, 128 };
        const alphas = [_]f64{ 0.70, 0.85, 0.90, 0.95 };
        const single_ms = decode_ms / @as(f64, @floatFromInt(decode_tokens));

        for (batch_ks) |k| {
            // Build K tokens + positions (reuse generated tokens)
            var batch_tokens: [128]u32 = undefined;
            var batch_positions: [128]usize = undefined;
            const actual_k = @min(k, @as(u32, @intCast(generated.items.len)));
            for (0..actual_k) |t| {
                batch_tokens[t] = generated.items[t];
                batch_positions[t] = n_prompt + t;
            }

            // Warm up (catch OOM for large K)
            fwd.reset();
            for (active_prompt, 0..) |tok, p| {
                _ = try fwd.forward(tok, p);
            }
            var batch_logits_buf: [256000]f32 = undefined;
            fwd.forwardBatchMoE(
                batch_tokens[0..actual_k],
                batch_positions[0..actual_k],
                batch_logits_buf[0..VOCAB],
            ) catch {
                std.debug.print("  │ {d:>4} │       OOM │       OOM │     OOM │     OOM │     OOM │     OOM │\n", .{actual_k});
                continue;
            };

            // Timed run (3 iterations, take best)
            var best_ms: f64 = std.math.inf(f64);
            for (0..3) |_| {
                fwd.reset();
                for (active_prompt, 0..) |tok, p| {
                    _ = try fwd.forward(tok, p);
                }
                const t0 = std.time.nanoTimestamp();
                try fwd.forwardBatchMoE(
                    batch_tokens[0..actual_k],
                    batch_positions[0..actual_k],
                    batch_logits_buf[0..VOCAB],
                );
                const elapsed = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;
                if (elapsed < best_ms) best_ms = elapsed;
            }

            const ms_per_tok = best_ms / @as(f64, @floatFromInt(actual_k));

            // Effective TPS at various acceptance rates
            // DART formula: accepted_tokens = 1 + (K-1)*α on average
            // cycle_ms = batch_forward + single_token_verify
            std.debug.print("  │ {d:>4} │ {d:>9.1} │ {d:>9.1} │", .{ actual_k, best_ms, ms_per_tok });
            for (alphas) |alpha| {
                const accepted = 1.0 + @as(f64, @floatFromInt(actual_k - 1)) * alpha;
                const cycle_ms = if (actual_k == 1) single_ms else best_ms + single_ms;
                const eff_tps = accepted / cycle_ms * 1000.0;
                std.debug.print(" {d:>7.1} │", .{eff_tps});
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("  └──────┴────────────┴────────────┴──────────┴──────────┴──────────┴──────────┘\n", .{});
        std.debug.print("  (Single-token baseline: {d:.1} ms → {d:.1} TPS)\n", .{ single_ms, 1000.0 / single_ms });

        // Profiled run at K=96 for phase breakdown
        {
            const prof_k: u32 = 96;
            var prof_tokens: [128]u32 = undefined;
            var prof_positions: [128]usize = undefined;
            const actual_pk = @min(prof_k, @as(u32, @intCast(generated.items.len)));
            for (0..actual_pk) |t| {
                prof_tokens[t] = generated.items[t];
                prof_positions[t] = n_prompt + t;
            }
            fwd.reset();
            for (active_prompt, 0..) |tok, p| {
                _ = try fwd.forward(tok, p);
            }
            fwd.profile_phases = true;
            var prof_logits: [256000]f32 = undefined;
            fwd.forwardBatchMoE(
                prof_tokens[0..actual_pk],
                prof_positions[0..actual_pk],
                prof_logits[0..VOCAB],
            ) catch {};
            fwd.profile_phases = false;
            const attn_ms = @as(f64, @floatFromInt(fwd.prof_attn_ns)) / 1e6;
            const ffn_ms = @as(f64, @floatFromInt(fwd.prof_ffn_ns)) / 1e6;
            const total_ms = attn_ms + ffn_ms;
            std.debug.print("\n  Phase breakdown (K={d}, {d} layers, profiled with sync):\n", .{ actual_pk, N_LAYERS });
            std.debug.print("    Attention: {d:.1} ms ({d:.0}%%)  [{d:.2} ms/layer]\n", .{ attn_ms, attn_ms / total_ms * 100.0, attn_ms / @as(f64, @floatFromInt(N_LAYERS)) });
            std.debug.print("    FFN/MoE:   {d:.1} ms ({d:.0}%%)  [{d:.2} ms/layer]\n", .{ ffn_ms, ffn_ms / total_ms * 100.0, ffn_ms / @as(f64, @floatFromInt(N_LAYERS)) });
            std.debug.print("    Total:     {d:.1} ms  [{d:.2} ms/layer]\n", .{ total_ms, total_ms / @as(f64, @floatFromInt(N_LAYERS)) });
            std.debug.print("    Per-token: {d:.2} ms (attn {d:.2} + ffn {d:.2})\n", .{ total_ms / @as(f64, @floatFromInt(prof_k)), attn_ms / @as(f64, @floatFromInt(prof_k)), ffn_ms / @as(f64, @floatFromInt(prof_k)) });
        }
    }

    std.debug.print("\n✅ E2E benchmark complete.\n", .{});
}

fn arrMin(data: []const f32) f32 {
    var m: f32 = data[0];
    for (data[1..]) |v| if (v < m) { m = v; };
    return m;
}

fn arrMax(data: []const f32) f32 {
    var m: f32 = data[0];
    for (data[1..]) |v| if (v > m) { m = v; };
    return m;
}

fn argmax(logits: []f32) u32 {
    var best_id: u32 = 0;
    var best_val: f32 = logits[0];
    for (logits[1..], 1..) |val, i| {
        if (val > best_val) {
            best_val = val;
            best_id = @intCast(i);
        }
    }
    return best_id;
}

/// Skip a GGUF metadata key-value pair, return updated position
fn skipGGUFKV(data: []const u8, start: usize) usize {
    var p = start;
    // Key: string (u64 len + bytes)
    const key_len = std.mem.readInt(u64, data[p..][0..8], .little);
    p += 8 + @as(usize, @intCast(key_len));
    // Value type
    const vtype = std.mem.readInt(u32, data[p..][0..4], .little);
    p += 4;
    // Value
    p = skipGGUFValue(data, p, vtype);
    return p;
}

fn skipGGUFValue(data: []const u8, start: usize, vtype: u32) usize {
    var p = start;
    switch (vtype) {
        0 => p += 1, // UINT8
        1 => p += 1, // INT8
        2 => p += 2, // UINT16
        3 => p += 2, // INT16
        4 => p += 4, // UINT32
        5 => p += 4, // INT32
        6 => p += 4, // FLOAT32
        7 => p += 1, // BOOL
        8 => { // STRING
            const len = std.mem.readInt(u64, data[p..][0..8], .little);
            p += 8 + @as(usize, @intCast(len));
        },
        9 => { // ARRAY
            const elem_type = std.mem.readInt(u32, data[p..][0..4], .little);
            p += 4;
            const count = std.mem.readInt(u64, data[p..][0..8], .little);
            p += 8;
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                p = skipGGUFValue(data, p, elem_type);
            }
        },
        10 => p += 8, // UINT64
        11 => p += 8, // INT64
        12 => p += 8, // FLOAT64
        else => p += 4, // Unknown, skip 4
    }
    return p;
}
