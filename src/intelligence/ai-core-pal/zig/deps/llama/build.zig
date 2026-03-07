const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // CUDA Support Configuration
    // =========================================================================
    const enable_cuda = b.option(bool, "cuda", "Enable CUDA GPU support") orelse false;
    const cuda_path = b.option([]const u8, "cuda-path", "Path to CUDA installation") orelse "/usr/local/cuda";

    // =========================================================================
    // Core library module
    // =========================================================================
    const lib_mod = b.addModule("llama", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =========================================================================
    // GPU Kernels module (with CUDA FFI)
    // =========================================================================
    const gpu_mod = b.addModule("gpu_kernels", .{
        .root_source_file = b.path("src/gpu_kernels.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add CUDA header include path
    gpu_mod.addIncludePath(b.path("csrc"));

    // =========================================================================
    // CUDA Library (optional)
    // =========================================================================
    var cuda_lib: ?*std.Build.Step.Compile = null;

    if (enable_cuda) {
        // Build CUDA kernels as a static library
        // This requires nvcc to be available at build time
        cuda_lib = b.addStaticLibrary(.{
            .name = "cuda_kernels",
            .target = target,
            .optimize = optimize,
        });

        // Add CUDA source file (will be compiled with nvcc via system command)
        // Note: Zig's build system doesn't directly support .cu files,
        // so we need a pre-built library or use a custom build step

        // Link CUDA runtime libraries
        cuda_lib.?.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(
            b.allocator, "{s}/lib64", .{cuda_path}
        ) catch "/usr/local/cuda/lib64" });
        cuda_lib.?.linkSystemLibrary("cudart");
        cuda_lib.?.linkSystemLibrary("cublas");
        cuda_lib.?.linkLibC();

        // Add to GPU module
        gpu_mod.linkLibrary(cuda_lib.?);
    }

    // =========================================================================
    // Tests
    // =========================================================================
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const gpu_unit_tests = b.addTest(.{
        .root_module = gpu_mod,
    });
    if (enable_cuda and cuda_lib != null) {
        gpu_unit_tests.linkLibrary(cuda_lib.?);
    }
    const run_gpu_unit_tests = b.addRunArtifact(gpu_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_gpu_unit_tests.step);

    // =========================================================================
    // Server executable
    // =========================================================================
    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("llama", lib_mod);
    server_mod.addImport("gpu_kernels", gpu_mod);

    const server_exe = b.addExecutable(.{
        .name = "llama-server",
        .root_module = server_mod,
    });
    if (enable_cuda and cuda_lib != null) {
        server_exe.linkLibrary(cuda_lib.?);
    }
    b.installArtifact(server_exe);

    // =========================================================================
    // CLI executable
    // =========================================================================
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("llama", lib_mod);
    cli_mod.addImport("gpu_kernels", gpu_mod);

    const cli_exe = b.addExecutable(.{
        .name = "llama-cli",
        .root_module = cli_mod,
    });
    if (enable_cuda and cuda_lib != null) {
        cli_exe.linkLibrary(cuda_lib.?);
    }
    b.installArtifact(cli_exe);

    // =========================================================================
    // Benchmarks
    // =========================================================================
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("llama", lib_mod);
    bench_mod.addImport("gpu_kernels", gpu_mod);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    if (enable_cuda and cuda_lib != null) {
        bench_exe.linkLibrary(cuda_lib.?);
    }

    const bench_step = b.step("bench", "Run benchmarks");
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // =========================================================================
    // Run steps
    // =========================================================================
    const run_server = b.addRunArtifact(server_exe);
    run_server.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_server.addArgs(args);
    }
    const run_server_step = b.step("run-server", "Run the llama server");
    run_server_step.dependOn(&run_server.step);

    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli.addArgs(args);
    }
    const run_cli_step = b.step("run", "Run the llama CLI");
    run_cli_step.dependOn(&run_cli.step);

    // =========================================================================
    // Build CUDA step (requires nvcc)
    // =========================================================================
    const build_cuda_step = b.step("build-cuda", "Build CUDA kernels (requires nvcc)");
    const cuda_build = b.addSystemCommand(&.{
        "nvcc",
        "-O3",
        "-arch=sm_75", // T4 GPU compute capability
        "-lcublas",
        "-shared",
        "-Xcompiler", "-fPIC",
        "csrc/cuda_kernels.cu",
        "-o", "zig-out/lib/libcuda_kernels.so",
    });
    build_cuda_step.dependOn(&cuda_build.step);
}