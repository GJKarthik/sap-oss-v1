//! Test ONNX model loading for all-MiniLM-L6-v2
//! Run: zig build-exe test_onnx_load_minilm.zig --release=fast -- deps/llama/llama.zig && ./test_onnx_load_minilm

const std = @import("std");
const llama = @import("deps/llama/llama.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test different ONNX model variants
    const model_variants = [_][]const u8{
        "model_O1.onnx",      // Default optimization level 1
        "model_O2.onnx",      // Optimization level 2
        "model_O3.onnx",      // Optimization level 3
        "model_O4.onnx",      // Optimization level 4 (smaller)
        "model_qint8_arm64.onnx",  // Quantized for ARM64
    };

    const base_path = "../../../../models/sentence-transformers/all-MiniLM-L6-v2/onnx/";

    std.debug.print("\n=== all-MiniLM-L6-v2 ONNX Model Loader Test ===\n\n", .{});
    std.debug.print("Model: sentence-transformers/all-MiniLM-L6-v2\n", .{});
    std.debug.print("Architecture: BERT (6 layers, 384 hidden dim)\n", .{});
    std.debug.print("Use case: English sentence embeddings\n\n", .{});

    for (model_variants) |variant| {
        const onnx_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_path, variant });
        defer allocator.free(onnx_path);

        std.debug.print("Testing: {s}\n", .{variant});
        std.debug.print("-" ** 50 ++ "\n", .{});

        // Check file exists
        const file = std.fs.cwd().openFile(onnx_path, .{}) catch |err| {
            std.debug.print("  SKIP: Could not open file: {any}\n\n", .{err});
            continue;
        };
        defer file.close();

        const stat = try file.stat();
        std.debug.print("  File size: {} bytes ({:.2} MB)\n", .{ stat.size, @as(f64, @floatFromInt(stat.size)) / (1024.0 * 1024.0) });

        // Try to load
        std.debug.print("  Loading with ONNX parser...\n", .{});
        const model = llama.loadFromONNX(allocator, onnx_path) catch |err| {
            std.debug.print("  ERROR: Failed to load ONNX: {any}\n\n", .{err});
            continue;
        };
        defer model.deinit();

        std.debug.print("  ✓ Loaded successfully!\n", .{});
        std.debug.print("    Architecture: {any}\n", .{model.config.architecture});
        std.debug.print("    Vocab size: {}\n", .{model.config.vocab_size});
        std.debug.print("    Hidden dim: {}\n", .{model.config.n_embd});
        std.debug.print("    Num layers: {}\n", .{model.config.n_layers});
        std.debug.print("    Num heads: {}\n", .{model.config.n_heads});
        std.debug.print("    FF dim: {}\n", .{model.config.n_ff});
        std.debug.print("    Context length: {}\n", .{model.config.context_length});
        std.debug.print("\n", .{});
    }

    std.debug.print("=== Test Complete ===\n", .{});
}