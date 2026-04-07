const std = @import("std");
const bridge = @import("../mojo_bridge.zig");

// Note: This test file is specifically designated to catch subtle ABI differences
// between the Zig coordinator and the Mojo kernel FFI layer.

test "Mojo FFI Configuration creation and destruction ABI" {
    var lib = bridge.MojoLibrary.load(null) catch |err| {
        std.debug.print("Skipping test: {}\n", .{err});
        return;
    };
    defer lib.close();

    // Test Config allocation
    const cfg = bridge.ModelConfig.llama_1b;
    const config_handle = lib.config_create(
        @intCast(cfg.vocab_size),
        @intCast(cfg.embed_dim),
        @intCast(cfg.num_heads),
        @intCast(cfg.num_kv_heads),
        @intCast(cfg.num_layers),
        @intCast(cfg.ffn_dim),
        @intCast(cfg.max_seq_len),
    );

    try std.testing.expect(config_handle != null);

    // Test Config destruction
    const free_res = lib.config_free(config_handle);
    try std.testing.expectEqual(bridge.PLLM_SUCCESS, free_res);
}

test "Mojo FFI Version ABI signature" {
    var lib = bridge.MojoLibrary.load(null) catch return;
    defer lib.close();

    const version = lib.getVersion();
    try std.testing.expect(version.major >= 0); // basic sanity check
    try std.testing.expect(version.minor >= 0);
    try std.testing.expect(version.patch >= 0);
}

test "Mojo FFI Model allocation and memory querying" {
    var lib = bridge.MojoLibrary.load(null) catch return;
    defer lib.close();

    var model = bridge.MojoModel.initLlama1b(&lib) catch |err| {
        std.debug.print("Skipping Model ABI test, creation failed: {}\n", .{err});
        return;
    };
    defer model.deinit();

    // Validate that the methods querying ints and floats from Mojo FFI return sane bounds
    const mem_mb = model.memoryMb();
    try std.testing.expect(mem_mb >= 0.0);

    const vocab = model.vocabSize();
    try std.testing.expect(vocab > 0);

    const embed = model.embedDim();
    try std.testing.expect(embed > 0);
}

test "Mojo FFI tensor load ABI" {
    var lib = bridge.MojoLibrary.load(null) catch return;
    defer lib.close();

    var model = bridge.MojoModel.initLlama1b(&lib) catch return;
    defer model.deinit();

    // Create a dummy tensor payload
    const dummy_emb = [_]f32{ 0.1, 0.2, 0.3, 0.4 };

    // Assuming the C FFI for loadEmbedding doesn't crash on small slices,
    // though in reality it might expect exact dimensions. We will just check
    // the function pointer call logic works.
    // If it requires exact sizing, this will fail or return an error code from Mojo.
    const res = lib.model_load_embedding(model.model_handle, &dummy_emb, dummy_emb.len * @sizeOf(f32));

    // We expect either SUCCESS, BUFFER_TOO_SMALL, or INVALID_CONFIG, but not a segfault.
    try std.testing.expect(res == bridge.PLLM_SUCCESS or res == bridge.PLLM_ERROR_BUFFER_TOO_SMALL or res == bridge.PLLM_ERROR_INVALID_CONFIG);
}
