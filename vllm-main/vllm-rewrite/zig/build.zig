const std = @import("std");

/// vLLM Rewrite - Zig Build Configuration
/// This build script configures the Zig infrastructure components including:
/// - Engine core
/// - Scheduler
/// - Memory management (KV-cache)
/// - Distributed computing
/// - HTTP/gRPC servers
/// - CLI interface

pub fn build(b: *std.Build) void {
    // Standard target and optimization options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================
    // Main vLLM executable
    // ============================================
    const exe = b.addExecutable(.{
        .name = "vllm",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link against system libraries
    exe.linkLibC();

    // Link CUDA libraries if available
    if (target.result.os.tag == .linux or target.result.os.tag == .windows) {
        // CUDA paths - adjust based on system
        exe.addLibraryPath(.{ .cwd_relative = "/usr/local/cuda/lib64" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/local/cuda/include" });
        exe.linkSystemLibrary("cuda");
        exe.linkSystemLibrary("cudart");
    }

    b.installArtifact(exe);

    // ============================================
    // Library for FFI exports
    // ============================================
    const lib = b.addStaticLibrary(.{
        .name = "vllm_zig",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    b.installArtifact(lib);

    // ============================================
    // Shared library for Mojo/Python interop
    // ============================================
    const shared_lib = b.addSharedLibrary(.{
        .name = "vllm_zig",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    shared_lib.linkLibC();
    b.installArtifact(shared_lib);

    // ============================================
    // Run command
    // ============================================
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the vLLM server");
    run_step.dependOn(&run_cmd.step);

    // ============================================
    // Unit tests
    // ============================================
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ============================================
    // Engine tests
    // ============================================
    const engine_tests = b.addTest(.{
        .root_source_file = b.path("src/engine/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_engine_tests = b.addRunArtifact(engine_tests);

    const engine_test_step = b.step("test-engine", "Run engine tests");
    engine_test_step.dependOn(&run_engine_tests.step);

    // ============================================
    // Memory tests
    // ============================================
    const memory_tests = b.addTest(.{
        .root_source_file = b.path("src/memory/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_memory_tests = b.addRunArtifact(memory_tests);

    const memory_test_step = b.step("test-memory", "Run memory management tests");
    memory_test_step.dependOn(&run_memory_tests.step);

    // ============================================
    // Scheduler tests
    // ============================================
    const scheduler_tests = b.addTest(.{
        .root_source_file = b.path("src/scheduler/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_scheduler_tests = b.addRunArtifact(scheduler_tests);

    const scheduler_test_step = b.step("test-scheduler", "Run scheduler tests");
    scheduler_test_step.dependOn(&run_scheduler_tests.step);

    // ============================================
    // All tests
    // ============================================
    const all_tests_step = b.step("test-all", "Run all tests");
    all_tests_step.dependOn(&run_unit_tests.step);
    all_tests_step.dependOn(&run_engine_tests.step);
    all_tests_step.dependOn(&run_memory_tests.step);
    all_tests_step.dependOn(&run_scheduler_tests.step);

    // ============================================
    // Benchmarks
    // ============================================
    const bench = b.addExecutable(.{
        .name = "vllm-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    bench.linkLibC();
    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // ============================================
    // Documentation
    // ============================================
    const docs = b.addStaticLibrary(.{
        .name = "vllm_docs",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // ============================================
    // Clean
    // ============================================
    const clean_step = b.step("clean", "Clean build artifacts");
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-cache")).step);
}