const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_gpu = b.option(bool, "gpu", "Enable GPU CUDA modules") orelse false;
    _ = enable_gpu;
    const source_file = b.path("src/main.zig");

    // =========================================================================
    // SDK Generated Types Module
    // =========================================================================
    const connector_types_mod = b.createModule(.{
        .root_source_file = b.path("src/gen/connector_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gpu_kernels_mod = b.createModule(.{
        .root_source_file = b.path("deps/llama/src/gpu_kernels.zig"),
        .target = target,
        .optimize = optimize,
    });
    const serving_engine_mod = b.createModule(.{
        .root_source_file = b.path("deps/llama/src/serving_engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const quantization_mod = b.createModule(.{
        .root_source_file = b.path("deps/llama/src/quantization.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fabric_mod = b.createModule(.{
        .root_source_file = b.path("../../ai-core-fabric/zig/src/fabric.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cuda_include = b.path("../../ai-core-fabric/zig/deps/cuda");
    gpu_kernels_mod.addIncludePath(cuda_include);
    serving_engine_mod.addIncludePath(cuda_include);
    quantization_mod.addIncludePath(cuda_include);

    // =========================================================================
    // Main Executable
    // =========================================================================
    const main_mod = b.createModule(.{
        .root_source_file = source_file,
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("connector_types", connector_types_mod);
    main_mod.addImport("gpu_kernels", gpu_kernels_mod);
    main_mod.addImport("serving_engine", serving_engine_mod);
    main_mod.addImport("quantization", quantization_mod);
    main_mod.addImport("fabric", fabric_mod);

    const exe = b.addExecutable(.{
        .name = "mcp-mesh-gateway",
        .root_module = main_mod,
    });
    exe.linkLibC();
    exe.addIncludePath(b.path("../../ai-core-fabric/zig/deps/cuda"));
    exe.addIncludePath(b.path("deps/llama/csrc"));
    b.installArtifact(exe);

    // =========================================================================
    // ANWID Module
    // =========================================================================
    const anwid_path = "../../../bdc-intelligence-fabric/zig/src/anwid/server.zig";
    if (std.fs.cwd().access(anwid_path, .{})) |_| {
        const anwid_mod = b.createModule(.{
            .root_source_file = b.path(anwid_path),
            .target = target,
            .optimize = optimize,
        });

        // =========================================================================
        // MCP OpenAI Bridge Executable
        // =========================================================================
        const bridge_mod = b.createModule(.{
            .root_source_file = b.path("src/bridge_main.zig"),
            .target = target,
            .optimize = optimize,
        });
        bridge_mod.addImport("anwid", anwid_mod);

        const bridge_exe = b.addExecutable(.{
            .name = "mcp-openai-bridge",
            .root_module = bridge_mod,
        });
        bridge_exe.linkLibC();
        b.installArtifact(bridge_exe);

        const run_bridge = b.addRunArtifact(bridge_exe);
        if (b.args) |args| run_bridge.addArgs(args);
        b.step("run-bridge", "Run MCP OpenAI Bridge").dependOn(&run_bridge.step);

        const build_bridge_step = b.step("build-bridge", "Build MCP OpenAI Bridge");
        build_bridge_step.dependOn(&bridge_exe.step);
    } else |_| {}

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run MCP Mesh Gateway").dependOn(&run_cmd.step);

    // =========================================================================
    // Tests
    // =========================================================================
    const test_mod = b.createModule(.{
        .root_source_file = source_file,
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("connector_types", connector_types_mod);
    test_mod.addImport("gpu_kernels", gpu_kernels_mod);
    test_mod.addImport("serving_engine", serving_engine_mod);
    test_mod.addImport("quantization", quantization_mod);
    test_mod.addImport("fabric", fabric_mod);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    tests.addIncludePath(b.path("../../ai-core-fabric/zig/deps/cuda"));
    tests.addIncludePath(b.path("deps/llama/csrc"));
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);

    // Connector types tests
    const connector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen/connector_types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test-connectors", "Run connector type tests").dependOn(&b.addRunArtifact(connector_tests).step);
}
