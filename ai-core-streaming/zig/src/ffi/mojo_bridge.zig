//! AIPrompt Streaming - Zig-Mojo FFI Hot-Link Bridge
//! Zero-copy FFI integration for SIMD-accelerated message processing
//!
//! This module enables direct calling of Mojo functions from the Zig hot path
//! without data copying, using shared memory buffers for maximum throughput.

const std = @import("std");

const log = std.log.scoped(.mojo_bridge);

// ============================================================================
// Mojo Library C-ABI Declarations
// ============================================================================

/// Mojo shared library handle
var mojo_lib: ?std.DynLib = null;

/// Mojo FFI function pointers (resolved at runtime)
pub const MojoFunctions = struct {
    /// Initialize the Mojo runtime
    init: ?*const fn () callconv(.C) c_int,
    /// Shutdown the Mojo runtime
    shutdown: ?*const fn () callconv(.C) void,
    /// Process a batch of messages using SIMD
    process_batch: ?*const fn (
        payloads: [*]const u8,
        offsets: [*]const i64,
        sizes: [*]const i32,
        count: c_int,
        output_buffer: [*]u8,
        output_capacity: c_int,
    ) callconv(.C) c_int,
    /// Compute checksums for a batch of messages
    compute_checksums: ?*const fn (
        payloads: [*]const u8,
        offsets: [*]const i64,
        sizes: [*]const i32,
        count: c_int,
        checksums_out: [*]u64,
    ) callconv(.C) c_int,
    /// Generate embeddings for text payloads
    generate_embeddings: ?*const fn (
        texts: [*]const u8,
        text_lengths: [*]const i32,
        count: c_int,
        embeddings_out: [*]f32,
        embedding_dim: c_int,
    ) callconv(.C) c_int,
    /// Compute cosine similarity between vectors
    cosine_similarity: ?*const fn (
        vec_a: [*]const f32,
        vec_b: [*]const f32,
        dim: c_int,
    ) callconv(.C) f32,
    /// Batch cosine similarity (one query against many)
    batch_similarity: ?*const fn (
        query: [*]const f32,
        vectors: [*]const f32,
        count: c_int,
        dim: c_int,
        scores_out: [*]f32,
    ) callconv(.C) c_int,
    /// Compress data using LZ4
    compress_lz4: ?*const fn (
        input: [*]const u8,
        input_size: c_int,
        output: [*]u8,
        output_capacity: c_int,
    ) callconv(.C) c_int,
    /// Decompress LZ4 data
    decompress_lz4: ?*const fn (
        input: [*]const u8,
        input_size: c_int,
        output: [*]u8,
        output_capacity: c_int,
    ) callconv(.C) c_int,
};

var mojo_functions: MojoFunctions = .{
    .init = null,
    .shutdown = null,
    .process_batch = null,
    .compute_checksums = null,
    .generate_embeddings = null,
    .cosine_similarity = null,
    .batch_similarity = null,
    .compress_lz4 = null,
    .decompress_lz4 = null,
};

// ============================================================================
// Shared Memory Buffer for Zero-Copy FFI
// ============================================================================

pub const SharedBuffer = struct {
    data: []align(64) u8,
    allocator: std.mem.Allocator,
    size: usize,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !SharedBuffer {
        const aligned_capacity = std.mem.alignForward(usize, capacity, 64);
        const data = try allocator.alignedAlloc(u8, 64, aligned_capacity);
        return .{
            .data = data,
            .allocator = allocator,
            .size = 0,
            .capacity = aligned_capacity,
        };
    }

    pub fn deinit(self: *SharedBuffer) void {
        self.allocator.free(self.data);
    }

    pub fn reset(self: *SharedBuffer) void {
        self.size = 0;
    }

    pub fn write(self: *SharedBuffer, bytes: []const u8) !usize {
        if (self.size + bytes.len > self.capacity) {
            return error.BufferFull;
        }
        @memcpy(self.data[self.size..][0..bytes.len], bytes);
        const offset = self.size;
        self.size += bytes.len;
        return offset;
    }

    pub fn getSlice(self: *SharedBuffer) []u8 {
        return self.data[0..self.size];
    }
};

// ============================================================================
// Mojo Bridge
// ============================================================================

pub const MojoBridge = struct {
    allocator: std.mem.Allocator,
    is_initialized: bool,
    lib_path: []const u8,

    // Shared buffers for zero-copy FFI
    input_buffer: SharedBuffer,
    output_buffer: SharedBuffer,
    offsets_buffer: []i64,
    sizes_buffer: []i32,

    // Statistics
    calls_total: std.atomic.Value(u64),
    bytes_processed: std.atomic.Value(u64),
    simd_operations: std.atomic.Value(u64),

    pub const Config = struct {
        lib_path: []const u8 = "libmojo_streaming.so",
        input_buffer_size: usize = 64 * 1024 * 1024, // 64 MB
        output_buffer_size: usize = 64 * 1024 * 1024, // 64 MB
        max_batch_size: usize = 1024,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !MojoBridge {
        var bridge = MojoBridge{
            .allocator = allocator,
            .is_initialized = false,
            .lib_path = config.lib_path,
            .input_buffer = try SharedBuffer.init(allocator, config.input_buffer_size),
            .output_buffer = try SharedBuffer.init(allocator, config.output_buffer_size),
            .offsets_buffer = try allocator.alloc(i64, config.max_batch_size),
            .sizes_buffer = try allocator.alloc(i32, config.max_batch_size),
            .calls_total = std.atomic.Value(u64).init(0),
            .bytes_processed = std.atomic.Value(u64).init(0),
            .simd_operations = std.atomic.Value(u64).init(0),
        };

        // Try to load the Mojo library
        bridge.loadLibrary() catch |err| {
            log.warn("Failed to load Mojo library: {} - using fallback implementations", .{err});
        };

        return bridge;
    }

    pub fn deinit(self: *MojoBridge) void {
        if (mojo_lib) |*lib| {
            if (mojo_functions.shutdown) |shutdown| {
                shutdown();
            }
            lib.close();
            mojo_lib = null;
        }

        self.input_buffer.deinit();
        self.output_buffer.deinit();
        self.allocator.free(self.offsets_buffer);
        self.allocator.free(self.sizes_buffer);
    }

    fn loadLibrary(self: *MojoBridge) !void {
        mojo_lib = std.DynLib.open(self.lib_path) catch |err| {
            // Try alternate paths
            const alternate_paths = [_][]const u8{
                "./libmojo_streaming.so",
                "/usr/local/lib/libmojo_streaming.so",
                "libmojo_streaming.dylib",
                "./libmojo_streaming.dylib",
            };

            for (alternate_paths) |path| {
                mojo_lib = std.DynLib.open(path) catch continue;
                break;
            }

            if (mojo_lib == null) {
                return err;
            }
        };

        // Resolve function pointers
        if (mojo_lib) |lib| {
            mojo_functions.init = lib.lookup(*const fn () callconv(.C) c_int, "mojo_init");
            mojo_functions.shutdown = lib.lookup(*const fn () callconv(.C) void, "mojo_shutdown");
            mojo_functions.process_batch = lib.lookup(
                *const fn ([*]const u8, [*]const i64, [*]const i32, c_int, [*]u8, c_int) callconv(.C) c_int,
                "mojo_process_batch",
            );
            mojo_functions.compute_checksums = lib.lookup(
                *const fn ([*]const u8, [*]const i64, [*]const i32, c_int, [*]u64) callconv(.C) c_int,
                "mojo_compute_checksums",
            );
            mojo_functions.generate_embeddings = lib.lookup(
                *const fn ([*]const u8, [*]const i32, c_int, [*]f32, c_int) callconv(.C) c_int,
                "mojo_generate_embeddings",
            );
            mojo_functions.cosine_similarity = lib.lookup(
                *const fn ([*]const f32, [*]const f32, c_int) callconv(.C) f32,
                "mojo_cosine_similarity",
            );
            mojo_functions.batch_similarity = lib.lookup(
                *const fn ([*]const f32, [*]const f32, c_int, c_int, [*]f32) callconv(.C) c_int,
                "mojo_batch_similarity",
            );
            mojo_functions.compress_lz4 = lib.lookup(
                *const fn ([*]const u8, c_int, [*]u8, c_int) callconv(.C) c_int,
                "mojo_compress_lz4",
            );
            mojo_functions.decompress_lz4 = lib.lookup(
                *const fn ([*]const u8, c_int, [*]u8, c_int) callconv(.C) c_int,
                "mojo_decompress_lz4",
            );

            // Initialize Mojo runtime
            if (mojo_functions.init) |init_fn| {
                const result = init_fn();
                if (result != 0) {
                    return error.MojoInitFailed;
                }
            }

            self.is_initialized = true;
            log.info("Mojo library loaded successfully from {s}", .{self.lib_path});
        }
    }

    /// Process a batch of messages using Mojo SIMD (hot path)
    pub fn processBatch(self: *MojoBridge, payloads: []const []const u8) ![]u8 {
        _ = self.calls_total.fetchAdd(1, .monotonic);

        // Prepare batch in shared buffer
        self.input_buffer.reset();
        var total_bytes: usize = 0;

        for (payloads, 0..) |payload, i| {
            const offset = try self.input_buffer.write(payload);
            self.offsets_buffer[i] = @intCast(offset);
            self.sizes_buffer[i] = @intCast(payload.len);
            total_bytes += payload.len;
        }

        _ = self.bytes_processed.fetchAdd(total_bytes, .monotonic);

        // Call Mojo if available, otherwise use fallback
        if (mojo_functions.process_batch) |process_fn| {
            _ = self.simd_operations.fetchAdd(1, .monotonic);
            const result = process_fn(
                self.input_buffer.data.ptr,
                self.offsets_buffer.ptr,
                self.sizes_buffer.ptr,
                @intCast(payloads.len),
                self.output_buffer.data.ptr,
                @intCast(self.output_buffer.capacity),
            );
            if (result < 0) {
                return error.MojoProcessingFailed;
            }
            self.output_buffer.size = @intCast(result);
            return self.output_buffer.getSlice();
        }

        // Fallback: just return input as-is
        return self.input_buffer.getSlice();
    }

    /// Compute checksums using Mojo SIMD
    pub fn computeChecksums(self: *MojoBridge, payloads: []const []const u8, checksums: []u64) !void {
        _ = self.calls_total.fetchAdd(1, .monotonic);

        // Prepare batch
        self.input_buffer.reset();
        for (payloads, 0..) |payload, i| {
            const offset = try self.input_buffer.write(payload);
            self.offsets_buffer[i] = @intCast(offset);
            self.sizes_buffer[i] = @intCast(payload.len);
        }

        if (mojo_functions.compute_checksums) |checksum_fn| {
            _ = self.simd_operations.fetchAdd(1, .monotonic);
            const result = checksum_fn(
                self.input_buffer.data.ptr,
                self.offsets_buffer.ptr,
                self.sizes_buffer.ptr,
                @intCast(payloads.len),
                checksums.ptr,
            );
            if (result < 0) {
                return error.MojoChecksumFailed;
            }
            return;
        }

        // Fallback: simple XOR checksum
        for (payloads, 0..) |payload, i| {
            var checksum: u64 = 0;
            for (payload) |byte| {
                checksum ^= byte;
                checksum = (checksum << 1) | (checksum >> 63);
            }
            checksums[i] = checksum;
        }
    }

    /// Generate embeddings using Mojo SIMD
    pub fn generateEmbeddings(
        self: *MojoBridge,
        texts: []const []const u8,
        embedding_dim: usize,
        embeddings: []f32,
    ) !void {
        _ = self.calls_total.fetchAdd(1, .monotonic);

        // Prepare text batch
        self.input_buffer.reset();
        for (texts, 0..) |text, i| {
            _ = try self.input_buffer.write(text);
            self.sizes_buffer[i] = @intCast(text.len);
        }

        if (mojo_functions.generate_embeddings) |embed_fn| {
            _ = self.simd_operations.fetchAdd(1, .monotonic);
            const result = embed_fn(
                self.input_buffer.data.ptr,
                self.sizes_buffer.ptr,
                @intCast(texts.len),
                embeddings.ptr,
                @intCast(embedding_dim),
            );
            if (result < 0) {
                return error.MojoEmbeddingFailed;
            }
            return;
        }

        // Fallback: mock embeddings from text bytes
        for (texts, 0..) |text, i| {
            const base = i * embedding_dim;
            for (0..embedding_dim) |j| {
                if (j < text.len) {
                    embeddings[base + j] = @as(f32, @floatFromInt(text[j])) / 255.0;
                } else {
                    embeddings[base + j] = 0.0;
                }
            }
        }
    }

    /// Compute cosine similarity using Mojo SIMD
    pub fn cosineSimilarity(self: *MojoBridge, vec_a: []const f32, vec_b: []const f32) f32 {
        _ = self.calls_total.fetchAdd(1, .monotonic);

        if (vec_a.len != vec_b.len) return 0.0;

        if (mojo_functions.cosine_similarity) |sim_fn| {
            _ = self.simd_operations.fetchAdd(1, .monotonic);
            return sim_fn(vec_a.ptr, vec_b.ptr, @intCast(vec_a.len));
        }

        // Fallback: manual cosine similarity
        var dot: f32 = 0.0;
        var norm_a: f32 = 0.0;
        var norm_b: f32 = 0.0;

        for (vec_a, vec_b) |a, b| {
            dot += a * b;
            norm_a += a * a;
            norm_b += b * b;
        }

        const norm = @sqrt(norm_a) * @sqrt(norm_b);
        if (norm == 0) return 0.0;
        return dot / norm;
    }

    /// Batch similarity search using Mojo SIMD
    pub fn batchSimilarity(
        self: *MojoBridge,
        query: []const f32,
        vectors: []const f32,
        count: usize,
        dim: usize,
        scores: []f32,
    ) !void {
        _ = self.calls_total.fetchAdd(1, .monotonic);

        if (mojo_functions.batch_similarity) |batch_fn| {
            _ = self.simd_operations.fetchAdd(1, .monotonic);
            const result = batch_fn(
                query.ptr,
                vectors.ptr,
                @intCast(count),
                @intCast(dim),
                scores.ptr,
            );
            if (result < 0) {
                return error.MojoBatchSimFailed;
            }
            return;
        }

        // Fallback: compute each similarity
        for (0..count) |i| {
            const base = i * dim;
            scores[i] = self.cosineSimilarity(query, vectors[base..][0..dim]);
        }
    }

    pub fn getStats(self: *MojoBridge) BridgeStats {
        return .{
            .is_initialized = self.is_initialized,
            .calls_total = self.calls_total.load(.monotonic),
            .bytes_processed = self.bytes_processed.load(.monotonic),
            .simd_operations = self.simd_operations.load(.monotonic),
        };
    }
};

pub const BridgeStats = struct {
    is_initialized: bool,
    calls_total: u64,
    bytes_processed: u64,
    simd_operations: u64,
};

// ============================================================================
// Mojo C Export Header Generator
// ============================================================================

/// Generates the C header file that Mojo should implement
pub fn generateCHeader() []const u8 {
    return
        \\/* Auto-generated Mojo FFI header for AIPrompt Streaming */
        \\#ifndef MOJO_STREAMING_H
        \\#define MOJO_STREAMING_H
        \\
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
        \\/* Initialize the Mojo runtime. Returns 0 on success. */
        \\int mojo_init(void);
        \\
        \\/* Shutdown the Mojo runtime. */
        \\void mojo_shutdown(void);
        \\
        \\/* Process a batch of messages using SIMD.
        \\ * Returns output size on success, negative on error. */
        \\int mojo_process_batch(
        \\    const uint8_t* payloads,
        \\    const int64_t* offsets,
        \\    const int32_t* sizes,
        \\    int count,
        \\    uint8_t* output_buffer,
        \\    int output_capacity
        \\);
        \\
        \\/* Compute checksums for a batch of messages.
        \\ * Returns 0 on success, negative on error. */
        \\int mojo_compute_checksums(
        \\    const uint8_t* payloads,
        \\    const int64_t* offsets,
        \\    const int32_t* sizes,
        \\    int count,
        \\    uint64_t* checksums_out
        \\);
        \\
        \\/* Generate embeddings for text payloads.
        \\ * Returns 0 on success, negative on error. */
        \\int mojo_generate_embeddings(
        \\    const uint8_t* texts,
        \\    const int32_t* text_lengths,
        \\    int count,
        \\    float* embeddings_out,
        \\    int embedding_dim
        \\);
        \\
        \\/* Compute cosine similarity between two vectors. */
        \\float mojo_cosine_similarity(
        \\    const float* vec_a,
        \\    const float* vec_b,
        \\    int dim
        \\);
        \\
        \\/* Batch cosine similarity (one query against many).
        \\ * Returns 0 on success, negative on error. */
        \\int mojo_batch_similarity(
        \\    const float* query,
        \\    const float* vectors,
        \\    int count,
        \\    int dim,
        \\    float* scores_out
        \\);
        \\
        \\/* Compress data using LZ4.
        \\ * Returns compressed size on success, negative on error. */
        \\int mojo_compress_lz4(
        \\    const uint8_t* input,
        \\    int input_size,
        \\    uint8_t* output,
        \\    int output_capacity
        \\);
        \\
        \\/* Decompress LZ4 data.
        \\ * Returns decompressed size on success, negative on error. */
        \\int mojo_decompress_lz4(
        \\    const uint8_t* input,
        \\    int input_size,
        \\    uint8_t* output,
        \\    int output_capacity
        \\);
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* MOJO_STREAMING_H */
    ;
}

// ============================================================================
// Tests
// ============================================================================

test "SharedBuffer init and write" {
    const allocator = std.testing.allocator;
    var buf = try SharedBuffer.init(allocator, 1024);
    defer buf.deinit();

    const offset = try buf.write("hello");
    try std.testing.expectEqual(@as(usize, 0), offset);
    try std.testing.expectEqual(@as(usize, 5), buf.size);

    const offset2 = try buf.write(" world");
    try std.testing.expectEqual(@as(usize, 5), offset2);
    try std.testing.expectEqual(@as(usize, 11), buf.size);
}

test "MojoBridge init without library" {
    const allocator = std.testing.allocator;
    var bridge = try MojoBridge.init(allocator, .{
        .lib_path = "nonexistent.so",
        .input_buffer_size = 1024,
        .output_buffer_size = 1024,
        .max_batch_size = 10,
    });
    defer bridge.deinit();

    try std.testing.expect(!bridge.is_initialized);
}

test "MojoBridge fallback cosine similarity" {
    const allocator = std.testing.allocator;
    var bridge = try MojoBridge.init(allocator, .{
        .lib_path = "nonexistent.so",
        .input_buffer_size = 1024,
        .output_buffer_size = 1024,
        .max_batch_size = 10,
    });
    defer bridge.deinit();

    const vec_a = [_]f32{ 1.0, 0.0, 0.0 };
    const vec_b = [_]f32{ 1.0, 0.0, 0.0 };
    const vec_c = [_]f32{ 0.0, 1.0, 0.0 };

    const sim_same = bridge.cosineSimilarity(&vec_a, &vec_b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sim_same, 0.001);

    const sim_ortho = bridge.cosineSimilarity(&vec_a, &vec_c);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sim_ortho, 0.001);
}

test "generateCHeader" {
    const header = generateCHeader();
    try std.testing.expect(std.mem.indexOf(u8, header, "mojo_init") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "mojo_cosine_similarity") != null);
}