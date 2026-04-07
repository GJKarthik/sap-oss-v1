//! Test ONNX model loading
//! Run: zig build-exe test_onnx_load.zig --release=fast -- deps/llama/llama.zig && ./test_onnx_load

const std = @import("std");
const llama = @import("deps/llama/llama.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const onnx_path = "../../../../models/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2/onnx/model.onnx";

    std.debug.print("Loading ONNX model from: {s}\n", .{onnx_path});
    std.debug.print("File size check...\n", .{});

    // Check file exists
    const file = std.fs.cwd().openFile(onnx_path, .{}) catch |err| {
        std.debug.print("ERROR: Could not open file: {any}\n", .{err});
        return;
    };
    defer file.close();
    const stat = try file.stat();
    std.debug.print("File size: {} bytes ({} MB)\n", .{ stat.size, stat.size / (1024 * 1024) });

    // Try to load
    std.debug.print("Loading with ONNX parser...\n", .{});
    const model = llama.loadFromONNX(allocator, onnx_path) catch |err| {
        std.debug.print("ERROR: Failed to load ONNX: {any}\n", .{err});
        return;
    };
    defer model.deinit();

    std.debug.print("\n=== ONNX Model Loaded Successfully ===\n", .{});
    std.debug.print("Architecture: {any}\n", .{model.config.architecture});
    std.debug.print("Vocab size: {}\n", .{model.config.vocab_size});
    std.debug.print("Hidden dim: {}\n", .{model.config.n_embd});
    std.debug.print("Num layers: {}\n", .{model.config.n_layers});
    std.debug.print("Num heads: {}\n", .{model.config.n_heads});
    std.debug.print("FF dim: {}\n", .{model.config.n_ff});
    std.debug.print("Context length: {}\n", .{model.config.context_length});
}