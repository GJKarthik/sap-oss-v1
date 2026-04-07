const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_gpu = b.option(bool, "gpu", "Enable GPU CUDA modules") orelse false;
    const enable_webgpu = b.option(bool, "webgpu", "Enable WebGPU/Vulkan via wgpu-native (Linux)") orelse false;
    const wgpu_lib_opt = b.option([]const u8, "wgpu_lib", "Path to wgpu-native library dir (default: /usr/local/lib)");
    const cuda_path_opt = b.option([]const u8, "cuda_path", "Path to CUDA toolkit (overrides CUDA_HOME/CUDA_PATH)");
    const cuda_lib_opt = b.option([]const u8, "cuda_lib", "Path to compiled CUDA kernels");
    // GPU architecture: sm_75=T4, sm_89=L4, sm_90=H200/H100. Defaults to sm_75.
    const gpu_arch = b.option([]const u8, "gpu_arch", "CUDA GPU architecture (sm_75/sm_89/sm_90)") orelse "sm_75";
    const source_file = b.path("src/main.zig");
    var cuda_kernels_build: ?*std.Build.Step.Run = null;

    if (enable_gpu) {
        const arch_flag = b.fmt("-arch={s}", .{gpu_arch});
        const mkdir_cuda_lib = b.addSystemCommand(&.{ "mkdir", "-p", "deps/llama-zig-cuda/zig-out/lib" });
        cuda_kernels_build = b.addSystemCommand(&.{
            "nvcc",
            "-O3",
            arch_flag,
            "-I",
            "csrc",
            "-lcublas",
            "-shared",
            "-Xcompiler",
            "-fPIC",
            "csrc/cuda_kernels.cu",
            "csrc/continuous_batching.cu",
            "csrc/cuda_graphs.cu",
            "csrc/flash_attention.cu",
            "csrc/flash_attention_v2.cu",
            "csrc/fp8_quantization.cu",
            "csrc/fused_kernels.cu",
            "csrc/glm5_kernels.cu",
            "csrc/gpu_tokenizer.cu",
            "csrc/int8_kv_cache.cu",
            "csrc/int8_quantization.cu",
            "csrc/kimi25_kernels.cu",
            "csrc/minimax25_kernels.cu",
            "csrc/mla_kernels.cu",
            "csrc/pipeline_parallel.cu",
            "csrc/tensor_core_ops.cu",
            "csrc/tensor_parallel.cu",
            "-o",
            "zig-out/lib/libcuda_kernels.so",
        });
        cuda_kernels_build.?.setCwd(b.path("deps/llama-zig-cuda"));
        cuda_kernels_build.?.step.dependOn(&mkdir_cuda_lib.step);
    }

    // ========================================================================
    // Generated SDK Types Module
    // ========================================================================
    const connector_types_mod = b.createModule(.{
        .root_source_file = b.path("src/gen/connector_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // RAG Service Module
    // ========================================================================
    const rag_service_mod = b.createModule(.{
        .root_source_file = b.path("src/rag/rag_service.zig"),
        .target = target,
        .optimize = optimize,
    });
    rag_service_mod.addImport("connector_types", connector_types_mod);

    // ========================================================================
    // OpenAI Gateway Modules
    // ========================================================================
    const http_mod = b.createModule(.{
        .root_source_file = b.path("src/http/server.zig"),
    });
    const auth_mod = b.createModule(.{
        .root_source_file = b.path("src/http/auth.zig"),
    });
    const resilience_mod = b.createModule(.{
        .root_source_file = b.path("src/resilience/circuit_breaker.zig"),
    });
    const broker_mod = b.createModule(.{
        .root_source_file = b.path("src/broker/broker.zig"),
    });

    // ========================================================================
    // GPU Metal Modules (named to avoid file-ownership conflicts)
    // ========================================================================
    const metal_bindings_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu/metal_bindings.zig"),
        .target = target,
        .optimize = optimize,
    });

    const metal_shaders_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu/metal_shaders.zig"),
        .target = target,
        .optimize = optimize,
    });
    metal_shaders_mod.addImport("metal_bindings", metal_bindings_mod);

    // ========================================================================
    // CUDA GPU Modules (GPU-resident weights, forward pass, kernels)
    // All files in src/gpu/ use relative @import for sibling files.
    // Named modules here are for external consumers (main_mod, test_mod).
    // ========================================================================
    const cuda_build_opts = b.addOptions();
    cuda_build_opts.addOption(bool, "enable_cuda", enable_gpu);
    cuda_build_opts.addOption(bool, "has_core_kernels_ptx", pathExists("src/gpu/core_kernels.ptx"));
    cuda_build_opts.addOption(bool, "has_qjl_kernels_ptx", pathExists("src/gpu/qjl_kernels.ptx"));
    cuda_build_opts.addOption(bool, "has_deltanet_kernels_ptx", pathExists("src/gpu/deltanet_kernels.ptx"));
    const cuda_opts_mod = cuda_build_opts.createModule();

    const fast_test_build_opts = b.addOptions();
    fast_test_build_opts.addOption(bool, "enable_slow_tests", false);
    const fast_test_opts_mod = fast_test_build_opts.createModule();

    const slow_test_build_opts = b.addOptions();
    slow_test_build_opts.addOption(bool, "enable_slow_tests", true);
    const slow_test_opts_mod = slow_test_build_opts.createModule();

    const cuda_forward_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu/cuda_forward.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    cuda_forward_mod.addImport("cuda_build_options", cuda_opts_mod);

    // ========================================================================
    // Apple Accelerate Module (SIMD-optimized BLAS for macOS)
    // ========================================================================
    const accelerate_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu/accelerate_backend.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Llama SDK Stub (for builds without full CUDA dependency)
    // ========================================================================
    const llama_mod = b.createModule(.{
        .root_source_file = b.path("deps/llama/llama.zig"),
        .target = target,
        .optimize = optimize,
    });
    llama_mod.addImport("metal_shaders", metal_shaders_mod);
    llama_mod.addImport("metal_bindings", metal_bindings_mod);
    llama_mod.addImport("accelerate", accelerate_mod);

    // ========================================================================
    // Main Executable - OpenAI Gateway
    // ========================================================================
    const main_mod = b.createModule(.{
        .root_source_file = source_file,
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("connector_types", connector_types_mod);
    main_mod.addImport("rag_service", rag_service_mod);
    main_mod.addImport("http", http_mod);
    main_mod.addImport("auth", auth_mod);
    main_mod.addImport("resilience", resilience_mod);
    main_mod.addImport("broker", broker_mod);
    main_mod.addImport("llama", llama_mod);
    main_mod.addImport("metal_bindings", metal_bindings_mod);
    main_mod.addImport("metal_shaders", metal_shaders_mod);
    // NOTE: cuda_forward and cuda_weights are NOT added here — main.zig imports
    // gpu/ files via relative paths, so adding named modules would cause
    // "file exists in two modules" errors. These named modules are only used
    // by standalone executables (e2e-bench, cuda-bench, llama-toon).
    main_mod.addImport("cuda_build_options", cuda_opts_mod);
    main_mod.addImport("test_build_options", fast_test_opts_mod);

    const exe = b.addExecutable(.{
        .name = "openai-gateway",
        .root_module = main_mod,
    });
    exe.linkLibC();
    exe.addCSourceFile(.{
        .file = b.path("deps/trt_wrapper/trt_wrapper.c"),
        .flags = &.{},
    });
    // Add stub CUDA header path for non-GPU builds
    exe.addIncludePath(b.path("deps/cuda"));

    // Link macOS frameworks for Metal GPU and Accelerate BLAS support
    if (target.result.os.tag == .macos) {
        exe.linkFramework("Metal");
        exe.linkFramework("Foundation");
        exe.linkFramework("CoreGraphics");
        exe.linkFramework("Accelerate"); // SIMD-optimized BLAS (cblas_sgemm, vDSP)
        exe.linkSystemLibrary("objc");
    }
    if (enable_gpu) {
        // Per-service local CUDA toolkit + replicated kernel library.
        const cuda_path = resolveCudaPath(b, cuda_path_opt);
        exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{cuda_path}) });
        exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{cuda_path}) });
        exe.linkSystemLibrary("cuda");
        exe.linkSystemLibrary("cudart");
        exe.linkSystemLibrary("cublas");
        exe.linkSystemLibrary("cublasLt");

        const cuda_lib_path = cuda_lib_opt orelse "deps/llama-zig-cuda/zig-out/lib";
        exe.addLibraryPath(.{ .cwd_relative = cuda_lib_path });
        exe.linkSystemLibrary("cuda_kernels");
        exe.step.dependOn(&cuda_kernels_build.?.step);

        // Note: When integrating actual TensorRT, add: libnvinfer, libcudart
        // exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        // exe.linkSystemLibrary("nvinfer");
    }
    if (target.result.os.tag == .linux) {
        exe.linkSystemLibrary("pthread");
    }
    if (enable_webgpu) {
        const wgpu_lib_path = wgpu_lib_opt orelse "/usr/local/lib";
        exe.addLibraryPath(.{ .cwd_relative = wgpu_lib_path });
        exe.linkSystemLibrary("wgpu_native");
        exe.root_module.addCMacro("WEBGPU_ENABLED", "1");
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run OpenAI Gateway").dependOn(&run_cmd.step);

    // ========================================================================
    // Tests
    // ========================================================================
    const test_mod = b.createModule(.{
        .root_source_file = source_file,
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("connector_types", connector_types_mod);
    test_mod.addImport("rag_service", rag_service_mod);
    test_mod.addImport("http", http_mod);
    test_mod.addImport("auth", auth_mod);
    test_mod.addImport("resilience", resilience_mod);
    test_mod.addImport("broker", broker_mod);
    test_mod.addImport("llama", llama_mod);
    test_mod.addImport("metal_bindings", metal_bindings_mod);
    test_mod.addImport("metal_shaders", metal_shaders_mod);
    test_mod.addImport("cuda_build_options", cuda_opts_mod);
    test_mod.addImport("test_build_options", fast_test_opts_mod);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    tests.linkLibC();
    tests.addCSourceFile(.{
        .file = b.path("deps/trt_wrapper/trt_wrapper.c"),
        .flags = &.{},
    });
    tests.addIncludePath(b.path("deps/cuda"));
    // Link macOS frameworks for tests (needed by Accelerate + Metal paths)
    if (target.result.os.tag == .macos) {
        tests.linkFramework("Metal");
        tests.linkFramework("Foundation");
        tests.linkFramework("CoreGraphics");
        tests.linkFramework("Accelerate");
        tests.linkSystemLibrary("objc");
    }
    if (target.result.os.tag == .linux) {
        tests.linkSystemLibrary("pthread");
    }

    // Connector types tests
    const connector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen/connector_types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test-connectors", "Run connector type tests").dependOn(&b.addRunArtifact(connector_tests).step);
    if (enable_gpu) {
        const cuda_path = resolveCudaPath(b, cuda_path_opt);
        tests.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{cuda_path}) });
        tests.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{cuda_path}) });
        tests.linkSystemLibrary("cudart");
        tests.linkSystemLibrary("cublas");
        tests.linkSystemLibrary("cublasLt");

        const cuda_lib_path = cuda_lib_opt orelse "deps/llama-zig-cuda/zig-out/lib";
        tests.addLibraryPath(.{ .cwd_relative = cuda_lib_path });
        tests.linkSystemLibrary("cuda_kernels");
        tests.linkLibC();
        tests.step.dependOn(&cuda_kernels_build.?.step);
    }
    if (enable_webgpu) {
        const wgpu_lib_path = wgpu_lib_opt orelse "/usr/local/lib";
        tests.addLibraryPath(.{ .cwd_relative = wgpu_lib_path });
        tests.linkSystemLibrary("wgpu_native");
        tests.root_module.addCMacro("WEBGPU_ENABLED", "1");
    }
    b.step("test", "Run fast unit and integration tests").dependOn(&b.addRunArtifact(tests).step);

    const slow_test_mod = b.createModule(.{
        .root_source_file = source_file,
        .target = target,
        .optimize = optimize,
    });
    slow_test_mod.addImport("connector_types", connector_types_mod);
    slow_test_mod.addImport("rag_service", rag_service_mod);
    slow_test_mod.addImport("http", http_mod);
    slow_test_mod.addImport("auth", auth_mod);
    slow_test_mod.addImport("resilience", resilience_mod);
    slow_test_mod.addImport("broker", broker_mod);
    slow_test_mod.addImport("llama", llama_mod);
    slow_test_mod.addImport("metal_bindings", metal_bindings_mod);
    slow_test_mod.addImport("metal_shaders", metal_shaders_mod);
    slow_test_mod.addImport("cuda_build_options", cuda_opts_mod);
    slow_test_mod.addImport("test_build_options", slow_test_opts_mod);

    const slow_tests = b.addTest(.{
        .root_module = slow_test_mod,
    });
    slow_tests.linkLibC();
    slow_tests.addCSourceFile(.{
        .file = b.path("deps/trt_wrapper/trt_wrapper.c"),
        .flags = &.{},
    });
    slow_tests.addIncludePath(b.path("deps/cuda"));
    if (target.result.os.tag == .macos) {
        slow_tests.linkFramework("Metal");
        slow_tests.linkFramework("Foundation");
        slow_tests.linkFramework("CoreGraphics");
        slow_tests.linkFramework("Accelerate");
        slow_tests.linkSystemLibrary("objc");
    }
    if (target.result.os.tag == .linux) {
        slow_tests.linkSystemLibrary("pthread");
    }
    if (enable_gpu) {
        const slow_cuda_path = resolveCudaPath(b, cuda_path_opt);
        slow_tests.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{slow_cuda_path}) });
        slow_tests.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{slow_cuda_path}) });
        slow_tests.linkSystemLibrary("cudart");
        slow_tests.linkSystemLibrary("cublas");
        slow_tests.linkSystemLibrary("cublasLt");

        const slow_cuda_lib_path = cuda_lib_opt orelse "deps/llama-zig-cuda/zig-out/lib";
        slow_tests.addLibraryPath(.{ .cwd_relative = slow_cuda_lib_path });
        slow_tests.linkSystemLibrary("cuda_kernels");
        slow_tests.linkLibC();
        slow_tests.step.dependOn(&cuda_kernels_build.?.step);
    }
    if (enable_webgpu) {
        const slow_wgpu_lib_path = wgpu_lib_opt orelse "/usr/local/lib";
        slow_tests.addLibraryPath(.{ .cwd_relative = slow_wgpu_lib_path });
        slow_tests.linkSystemLibrary("wgpu_native");
        slow_tests.root_module.addCMacro("WEBGPU_ENABLED", "1");
    }
    b.step("test-slow", "Run slow inference and benchmark tests").dependOn(&b.addRunArtifact(slow_tests).step);

    // ========================================================================
    // DART Module Tests
    // ========================================================================
    const dart_engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dart/dart_engine.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dart_engine_tests.linkLibC();
    if (target.result.os.tag == .macos) {
        dart_engine_tests.linkFramework("Accelerate");
    }

    const llama_dart_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dart/llama_dart.zig"),
        .target = target,
        .optimize = optimize,
    });
    llama_dart_test_mod.addImport("llama", llama_mod);

    const llama_dart_tests = b.addTest(.{
        .root_module = llama_dart_test_mod,
    });
    llama_dart_tests.linkLibC();
    if (target.result.os.tag == .macos) {
        llama_dart_tests.linkFramework("Accelerate");
    }

    const dart_test_step = b.step("test-dart", "Run Lean-DART module tests");
    dart_test_step.dependOn(&b.addRunArtifact(dart_engine_tests).step);
    dart_test_step.dependOn(&b.addRunArtifact(llama_dart_tests).step);

    // ========================================================================
    // Engram Module Tests
    // ========================================================================
    const engram_draft_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dart/engram_draft.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    engram_draft_tests.linkLibC();

    const engram_attention_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/llm/engram_attention.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    engram_attention_tests.linkLibC();

    const engram_routing_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/llm/engram_routing.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    engram_routing_tests.linkLibC();

    const engram_test_step = b.step("test-engram", "Run Engram module tests");
    engram_test_step.dependOn(&b.addRunArtifact(engram_draft_tests).step);
    engram_test_step.dependOn(&b.addRunArtifact(engram_attention_tests).step);
    engram_test_step.dependOn(&b.addRunArtifact(engram_routing_tests).step);

    // ========================================================================
    // Model Inference Test - Uses custom Zig engine only (no Ollama)
    // ========================================================================
    const model_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/model_inference_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    model_test_mod.addImport("llama", llama_mod);
    model_test_mod.addImport("accelerate", accelerate_mod);

    const model_test_exe = b.addExecutable(.{
        .name = "model-test",
        .root_module = model_test_mod,
    });
    model_test_exe.linkLibC();
    if (target.result.os.tag == .macos) {
        model_test_exe.linkFramework("Metal");
        model_test_exe.linkFramework("Foundation");
        model_test_exe.linkFramework("CoreGraphics");
        model_test_exe.linkFramework("Accelerate");
        model_test_exe.linkSystemLibrary("objc");
    }
    b.installArtifact(model_test_exe);

    const run_model_test = b.addRunArtifact(model_test_exe);
    // Don't depend on install step - run independently to avoid openai-gateway link errors
    b.step("test-model", "Run inference with GGUF model from vendor/layerModels using custom Zig engine").dependOn(&run_model_test.step);

    const run_model_decode = b.addRunArtifact(model_test_exe);
    run_model_decode.setEnvironmentVariable("PLLM_MODEL_TEST_MODE", "decode-only");
    b.step("test-model-decode", "Run decode-only benchmark with GGUF model from vendor/layerModels using custom Zig engine").dependOn(&run_model_decode.step);

    const run_model_decode_compare = b.addRunArtifact(model_test_exe);
    run_model_decode_compare.setEnvironmentVariable("PLLM_MODEL_TEST_MODE", "decode-compare");
    b.step("test-model-decode-compare", "Run same-process decode comparison benchmark with GGUF model from vendor/layerModels using custom Zig engine").dependOn(&run_model_decode_compare.step);

    // ========================================================================
    // Decode Attention Microbenchmark
    // ========================================================================
    const decode_attn_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/bench_decode_attention.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    decode_attn_bench_mod.addImport("metal_shaders", metal_shaders_mod);
    decode_attn_bench_mod.addImport("metal_bindings", metal_bindings_mod);

    const decode_attn_bench_exe = b.addExecutable(.{
        .name = "bench-decode-attention",
        .root_module = decode_attn_bench_mod,
    });
    decode_attn_bench_exe.linkLibC();
    if (target.result.os.tag == .macos) {
        decode_attn_bench_exe.linkFramework("Metal");
        decode_attn_bench_exe.linkFramework("Foundation");
        decode_attn_bench_exe.linkFramework("CoreGraphics");
        decode_attn_bench_exe.linkSystemLibrary("objc");
    }
    b.installArtifact(decode_attn_bench_exe);

    const run_decode_attn_bench = b.addRunArtifact(decode_attn_bench_exe);
    b.step("bench-decode-attn", "Run isolated Metal decode-attention microbenchmark").dependOn(&run_decode_attn_bench.step);

    // ========================================================================
    // Decode Layer Microbenchmark (attention + wo projection)
    // ========================================================================
    const decode_layer_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/bench_decode_layer.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    decode_layer_bench_mod.addImport("metal_shaders", metal_shaders_mod);
    decode_layer_bench_mod.addImport("metal_bindings", metal_bindings_mod);

    const decode_layer_bench_exe = b.addExecutable(.{
        .name = "bench-decode-layer",
        .root_module = decode_layer_bench_mod,
    });
    decode_layer_bench_exe.linkLibC();
    if (target.result.os.tag == .macos) {
        decode_layer_bench_exe.linkFramework("Metal");
        decode_layer_bench_exe.linkFramework("Foundation");
        decode_layer_bench_exe.linkFramework("CoreGraphics");
        decode_layer_bench_exe.linkSystemLibrary("objc");
    }
    b.installArtifact(decode_layer_bench_exe);

    const run_decode_layer_bench = b.addRunArtifact(decode_layer_bench_exe);
    b.step("bench-decode-layer", "Run decode layer microbenchmark including wo projection").dependOn(&run_decode_layer_bench.step);

    // ========================================================================
    // Decode Hot-Stage Microbenchmark
    // ========================================================================
    const decode_hotstages_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/bench_decode_hotstages.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    decode_hotstages_bench_mod.addImport("metal_shaders", metal_shaders_mod);
    decode_hotstages_bench_mod.addImport("metal_bindings", metal_bindings_mod);

    const decode_hotstages_bench_exe = b.addExecutable(.{
        .name = "bench-decode-hotstages",
        .root_module = decode_hotstages_bench_mod,
    });
    decode_hotstages_bench_exe.linkLibC();
    if (target.result.os.tag == .macos) {
        decode_hotstages_bench_exe.linkFramework("Metal");
        decode_hotstages_bench_exe.linkFramework("Foundation");
        decode_hotstages_bench_exe.linkFramework("CoreGraphics");
        decode_hotstages_bench_exe.linkSystemLibrary("objc");
    }
    b.installArtifact(decode_hotstages_bench_exe);

    const run_decode_hotstages_bench = b.addRunArtifact(decode_hotstages_bench_exe);
    b.step("bench-decode-hotstages", "Run isolated Metal benchmarks for the dominant decode-stage matmul shapes").dependOn(&run_decode_hotstages_bench.step);

    // ========================================================================
    // WO Projection Microbenchmark
    // ========================================================================
    const wo_projection_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/bench_wo_projection.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    wo_projection_bench_mod.addImport("metal_shaders", metal_shaders_mod);
    wo_projection_bench_mod.addImport("metal_bindings", metal_bindings_mod);

    const wo_projection_bench_exe = b.addExecutable(.{
        .name = "bench-wo-projection",
        .root_module = wo_projection_bench_mod,
    });
    wo_projection_bench_exe.linkLibC();
    if (target.result.os.tag == .macos) {
        wo_projection_bench_exe.linkFramework("Metal");
        wo_projection_bench_exe.linkFramework("Foundation");
        wo_projection_bench_exe.linkFramework("CoreGraphics");
        wo_projection_bench_exe.linkSystemLibrary("objc");
    }
    b.installArtifact(wo_projection_bench_exe);

    const run_wo_projection_bench = b.addRunArtifact(wo_projection_bench_exe);
    b.step("bench-wo-proj", "Run isolated Metal wo projection microbenchmark").dependOn(&run_wo_projection_bench.step);

    // ========================================================================
    // CUDA Forward Pass Tests
    // ========================================================================
    const cuda_weights_test_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu/cuda_weights.zig"),
        .target = target,
        .optimize = optimize,
    });
    cuda_weights_test_mod.addImport("cuda_build_options", cuda_opts_mod);
    const cuda_weights_tests = b.addTest(.{ .root_module = cuda_weights_test_mod });
    cuda_weights_tests.linkLibC();
    if (enable_gpu) {
        const cuda_path_t = resolveCudaPath(b, cuda_path_opt);
        cuda_weights_tests.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{cuda_path_t}) });
        cuda_weights_tests.linkSystemLibrary("cuda");
        cuda_weights_tests.linkSystemLibrary("cudart");
        cuda_weights_tests.linkSystemLibrary("cublas");
    }

    const cuda_forward_test_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu/cuda_forward.zig"),
        .target = target,
        .optimize = optimize,
    });
    cuda_forward_test_mod.addImport("cuda_build_options", cuda_opts_mod);
    const cuda_forward_tests = b.addTest(.{ .root_module = cuda_forward_test_mod });
    cuda_forward_tests.linkLibC();
    if (enable_gpu) {
        const cuda_path_t2 = resolveCudaPath(b, cuda_path_opt);
        cuda_forward_tests.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{cuda_path_t2}) });
        cuda_forward_tests.linkSystemLibrary("cuda");
        cuda_forward_tests.linkSystemLibrary("cudart");
        cuda_forward_tests.linkSystemLibrary("cublas");
    }

    const cuda_test_step = b.step("test-cuda", "Run CUDA forward pass tests");
    cuda_test_step.dependOn(&b.addRunArtifact(cuda_weights_tests).step);
    cuda_test_step.dependOn(&b.addRunArtifact(cuda_forward_tests).step);

    // ========================================================================
    // CUDA Benchmark — T4 decode throughput (zig build bench-cuda -Dgpu=true)
    // ========================================================================
    const cuda_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/cuda_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "cuda_forward", .module = cuda_forward_mod },
        },
    });

    const cuda_bench_exe = b.addExecutable(.{
        .name = "cuda-bench",
        .root_module = cuda_bench_mod,
    });
    cuda_bench_exe.linkLibC();
    if (enable_gpu) {
        const cuda_path = resolveCudaPath(b, cuda_path_opt);
        cuda_bench_exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{cuda_path}) });
        cuda_bench_exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{cuda_path}) });
        cuda_bench_exe.linkSystemLibrary("cuda");
        cuda_bench_exe.linkSystemLibrary("cudart");
        cuda_bench_exe.linkSystemLibrary("cublas");
        cuda_bench_exe.linkSystemLibrary("cublasLt");
    }
    b.installArtifact(cuda_bench_exe);

    const run_bench = b.addRunArtifact(cuda_bench_exe);
    b.step("bench-cuda", "Benchmark CUDA forward pass on T4 (use -Dgpu=true)").dependOn(&run_bench.step);

    // ========================================================================
    // E2E Benchmark — Real GGUF model on T4 (zig build e2e-bench -Dgpu=true)
    // ========================================================================
    const gguf_tok_mod = b.createModule(.{
        .root_source_file = b.path("src/toon/gguf_tokenizer.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const e2e_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/e2e_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "cuda_forward", .module = cuda_forward_mod },
            .{ .name = "gguf_tokenizer", .module = gguf_tok_mod },
        },
    });

    const e2e_bench_exe = b.addExecutable(.{
        .name = "e2e-bench",
        .root_module = e2e_bench_mod,
    });
    e2e_bench_exe.linkLibC();
    if (enable_gpu) {
        const cuda_path_e = resolveCudaPath(b, cuda_path_opt);
        e2e_bench_exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{cuda_path_e}) });
        e2e_bench_exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{cuda_path_e}) });
        e2e_bench_exe.linkSystemLibrary("cuda");
        e2e_bench_exe.linkSystemLibrary("cudart");
        e2e_bench_exe.linkSystemLibrary("cublas");
        e2e_bench_exe.linkSystemLibrary("cublasLt");
    }
    b.installArtifact(e2e_bench_exe);

    const run_e2e = b.addRunArtifact(e2e_bench_exe);
    b.step("e2e-bench", "E2E benchmark with real GGUF model on T4 (use -Dgpu=true)").dependOn(&run_e2e.step);
}

fn resolveCudaPath(b: *std.Build, cuda_path_opt: ?[]const u8) []const u8 {
    if (cuda_path_opt) |path| {
        return path;
    }
    if (std.process.getEnvVarOwned(b.allocator, "CUDA_HOME") catch null) |path| {
        return path;
    }
    if (std.process.getEnvVarOwned(b.allocator, "CUDA_PATH") catch null) |path| {
        return path;
    }
    return "/usr/local/cuda";
}

fn pathExists(rel_path: []const u8) bool {
    std.fs.cwd().access(rel_path, .{}) catch return false;
    return true;
}
