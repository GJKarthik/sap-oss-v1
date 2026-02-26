const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // SDK Generated Types Module
    // =========================================================================
    const connector_types_mod = b.createModule(.{
        .root_source_file = b.path("src/gen/connector_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =========================================================================
    // Llama Inference Engine Module
    // =========================================================================
    const llama_mod = b.createModule(.{
        .root_source_file = b.path("deps/llama/llama.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =========================================================================
    // Protocol Module
    // =========================================================================
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/aiprompt_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =========================================================================
    // SAP Standard Modules
    // =========================================================================
    const sap_config_mod = b.createModule(.{
        .root_source_file = b.path("src/sap/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const hana_connector_mod = b.createModule(.{
        .root_source_file = b.path("src/sap/hana_connector.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =========================================================================
    // Storage and HANA Modules
    // =========================================================================
    const storage_mod = b.createModule(.{
        .root_source_file = b.path("src/storage/managed_ledger.zig"),
        .target = target,
        .optimize = optimize,
    });

    const hana_mod = b.createModule(.{
        .root_source_file = b.path("src/hana/hana_db.zig"),
        .target = target,
        .optimize = optimize,
    });

    storage_mod.addImport("connector_types", connector_types_mod);
    storage_mod.addImport("hana", hana_mod);

    hana_mod.addImport("connector_types", connector_types_mod);
    hana_mod.addImport("sap_config", sap_config_mod);
    hana_mod.addImport("hana_connector", hana_connector_mod);

    // =========================================================================
    // Broker Module
    // =========================================================================
    const broker_mod = b.createModule(.{
        .root_source_file = b.path("src/broker/broker.zig"),
        .target = target,
        .optimize = optimize,
    });
    broker_mod.addImport("connector_types", connector_types_mod);
    broker_mod.addImport("protocol", protocol_mod);
    broker_mod.addImport("storage", storage_mod);
    broker_mod.addImport("hana", hana_mod);
    broker_mod.addImport("llama", llama_mod);

    // =========================================================================
    // Arrow Flight Module
    // =========================================================================
    const flight_mod = b.createModule(.{
        .root_source_file = b.path("src/flight/arrow_flight.zig"),
        .target = target,
        .optimize = optimize,
    });
    flight_mod.addImport("connector_types", connector_types_mod);
    flight_mod.addImport("broker", broker_mod);

    // =========================================================================
    // Blackboard Module (Fabric Integration)
    // =========================================================================
    const blackboard_mod = b.createModule(.{
        .root_source_file = b.path("src/fabric/blackboard.zig"),
        .target = target,
        .optimize = optimize,
    });
    blackboard_mod.addImport("connector_types", connector_types_mod);

    // =========================================================================
    // RDMA Channel Module (High-Performance Networking)
    // =========================================================================
    const rdma_mod = b.createModule(.{
        .root_source_file = b.path("src/fabric/rdma_channel.zig"),
        .target = target,
        .optimize = optimize,
    });
    rdma_mod.addImport("connector_types", connector_types_mod);

    // =========================================================================
    // Data Classification Module
    // =========================================================================
    const classification_mod = b.createModule(.{
        .root_source_file = b.path("src/classification/data_classifier.zig"),
        .target = target,
        .optimize = optimize,
    });
    classification_mod.addImport("connector_types", connector_types_mod);

    // =========================================================================
    // Metrics Module (Prometheus)
    // =========================================================================
    const metrics_mod = b.createModule(.{
        .root_source_file = b.path("src/metrics/prometheus.zig"),
        .target = target,
        .optimize = optimize,
    });
    metrics_mod.addImport("connector_types", connector_types_mod);

    // =========================================================================
    // Metrics HTTP Server Module (Production /metrics endpoint)
    // =========================================================================
    const metrics_http_mod = b.createModule(.{
        .root_source_file = b.path("src/metrics/http_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    metrics_http_mod.addImport("prometheus", metrics_mod);

    // =========================================================================
    // Client Module
    // =========================================================================
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("connector_types", connector_types_mod);
    client_mod.addImport("protocol", protocol_mod);

    // =========================================================================
    // Main Broker Executable
    // =========================================================================
    const broker_exe = b.addExecutable(.{
        .name = "aiprompt-broker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    broker_exe.root_module.addImport("connector_types", connector_types_mod);
    broker_exe.root_module.addImport("protocol", protocol_mod);
    broker_exe.root_module.addImport("storage", storage_mod);
    broker_exe.root_module.addImport("hana", hana_mod);
    broker_exe.root_module.addImport("broker", broker_mod);
    broker_exe.root_module.addImport("client", client_mod);
    broker_exe.root_module.addImport("flight", flight_mod);
    broker_exe.root_module.addImport("blackboard", blackboard_mod);
    broker_exe.root_module.addImport("rdma", rdma_mod);
    broker_exe.root_module.addImport("classification", classification_mod);
    broker_exe.root_module.addImport("metrics", metrics_mod);
    broker_exe.root_module.addImport("metrics_http", metrics_http_mod);
    broker_exe.root_module.addImport("sap_config", sap_config_mod);
    broker_exe.root_module.addImport("llama", llama_mod);
    broker_exe.linkLibC();
    broker_exe.addIncludePath(b.path("deps/cuda"));
    b.installArtifact(broker_exe);

    // =========================================================================
    // Standalone Executable (broker + local metadata)
    // =========================================================================
    const standalone_exe = b.addExecutable(.{
        .name = "aiprompt-standalone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/standalone.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    standalone_exe.root_module.addImport("connector_types", connector_types_mod);
    standalone_exe.root_module.addImport("protocol", protocol_mod);
    standalone_exe.root_module.addImport("storage", storage_mod);
    standalone_exe.root_module.addImport("hana", hana_mod);
    standalone_exe.root_module.addImport("broker", broker_mod);
    standalone_exe.root_module.addImport("flight", flight_mod);
    standalone_exe.root_module.addImport("blackboard", blackboard_mod);
    standalone_exe.root_module.addImport("metrics", metrics_mod);
    standalone_exe.root_module.addImport("metrics_http", metrics_http_mod);
    standalone_exe.root_module.addImport("llama", llama_mod);
    standalone_exe.linkLibC();
    standalone_exe.addIncludePath(b.path("deps/cuda"));
    b.installArtifact(standalone_exe);

    // =========================================================================
    // Client CLI Executable
    // =========================================================================
    const client_exe = b.addExecutable(.{
        .name = "aiprompt-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    client_exe.root_module.addImport("connector_types", connector_types_mod);
    client_exe.root_module.addImport("protocol", protocol_mod);
    client_exe.root_module.addImport("client", client_mod);
    client_exe.linkLibC();
    client_exe.addIncludePath(b.path("deps/cuda"));
    b.installArtifact(client_exe);

    // =========================================================================
    // Admin CLI Executable
    // =========================================================================
    const admin_exe = b.addExecutable(.{
        .name = "aiprompt-admin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/admin_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    admin_exe.root_module.addImport("connector_types", connector_types_mod);
    admin_exe.linkLibC();
    admin_exe.addIncludePath(b.path("deps/cuda"));
    b.installArtifact(admin_exe);

    // =========================================================================
    // Run Commands
    // =========================================================================
    const run_broker = b.addRunArtifact(broker_exe);
    run_broker.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_broker.addArgs(args);
    b.step("run-broker", "Run the AIPrompt broker").dependOn(&run_broker.step);

    const run_standalone = b.addRunArtifact(standalone_exe);
    run_standalone.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_standalone.addArgs(args);
    b.step("run-standalone", "Run in standalone mode").dependOn(&run_standalone.step);

    const run_client = b.addRunArtifact(client_exe);
    run_client.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_client.addArgs(args);
    b.step("run-client", "Run the AIPrompt client CLI").dependOn(&run_client.step);

    // =========================================================================
    // Tests
    // =========================================================================
    
    // Protocol tests
    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol/aiprompt_protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    protocol_tests.root_module.addImport("connector_types", connector_types_mod);
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    b.step("test-protocol", "Run protocol tests").dependOn(&run_protocol_tests.step);

    // Storage tests
    const storage_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage/managed_ledger.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    storage_tests.root_module.addImport("connector_types", connector_types_mod);
    const run_storage_tests = b.addRunArtifact(storage_tests);
    b.step("test-storage", "Run storage tests").dependOn(&run_storage_tests.step);

    // Broker tests
    const broker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/broker/broker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    broker_tests.root_module.addImport("connector_types", connector_types_mod);
    broker_tests.root_module.addImport("protocol", protocol_mod);
    broker_tests.root_module.addImport("storage", storage_mod);
    broker_tests.root_module.addImport("hana", hana_mod);
    broker_tests.root_module.addImport("llama", llama_mod);
    const run_broker_tests = b.addRunArtifact(broker_tests);
    b.step("test-broker", "Run broker tests").dependOn(&run_broker_tests.step);

    // Connector types tests
    const connector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen/connector_types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_connector_tests = b.addRunArtifact(connector_tests);
    b.step("test-connectors", "Run connector type tests").dependOn(&run_connector_tests.step);

    // Arrow Flight tests
    const flight_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flight/arrow_flight.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    flight_tests.root_module.addImport("connector_types", connector_types_mod);
    flight_tests.root_module.addImport("broker", broker_mod);
    const run_flight_tests = b.addRunArtifact(flight_tests);
    b.step("test-flight", "Run Arrow Flight tests").dependOn(&run_flight_tests.step);

    // Blackboard tests
    const blackboard_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fabric/blackboard.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    blackboard_tests.root_module.addImport("connector_types", connector_types_mod);
    const run_blackboard_tests = b.addRunArtifact(blackboard_tests);
    b.step("test-blackboard", "Run blackboard tests").dependOn(&run_blackboard_tests.step);

    // RDMA tests
    const rdma_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fabric/rdma_channel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rdma_tests.root_module.addImport("connector_types", connector_types_mod);
    const run_rdma_tests = b.addRunArtifact(rdma_tests);
    b.step("test-rdma", "Run RDMA channel tests").dependOn(&run_rdma_tests.step);

    // Classification tests
    const classification_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/classification/data_classifier.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    classification_tests.root_module.addImport("connector_types", connector_types_mod);
    const run_classification_tests = b.addRunArtifact(classification_tests);
    b.step("test-classification", "Run classification tests").dependOn(&run_classification_tests.step);

    // HANA DB tests
    const hana_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hana/hana_db.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hana_tests.root_module.addImport("connector_types", connector_types_mod);
    hana_tests.root_module.addImport("sap_config", sap_config_mod);
    hana_tests.root_module.addImport("hana_connector", hana_connector_mod);
    const run_hana_tests = b.addRunArtifact(hana_tests);
    b.step("test-hana", "Run HANA DB tests").dependOn(&run_hana_tests.step);

    // Metrics HTTP Server tests
    const metrics_http_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/metrics/http_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    metrics_http_tests.root_module.addImport("prometheus", metrics_mod);
    const run_metrics_http_tests = b.addRunArtifact(metrics_http_tests);
    b.step("test-metrics-http", "Run metrics HTTP server tests").dependOn(&run_metrics_http_tests.step);

    // GPU: CUDA backend tests
    const cuda_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/cuda_backend.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cuda_tests.addIncludePath(b.path("deps/cuda"));
    const run_cuda_tests = b.addRunArtifact(cuda_tests);
    b.step("test-cuda", "Run CUDA backend tests").dependOn(&run_cuda_tests.step);

    // GPU: Metal backend tests
    const metal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/metal_backend.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    metal_tests.linkSystemLibrary("objc");
    const run_metal_tests = b.addRunArtifact(metal_tests);
    b.step("test-metal", "Run Metal backend tests").dependOn(&run_metal_tests.step);

    // GPU: Kernel tests
    const kernel_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/kernels.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_kernel_tests = b.addRunArtifact(kernel_tests);
    b.step("test-kernels", "Run GPU kernel tests").dependOn(&run_kernel_tests.step);

    // GPU: Memory pool tests
    const mempool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/memory_pool.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_mempool_tests = b.addRunArtifact(mempool_tests);
    b.step("test-memory-pool", "Run GPU memory pool tests").dependOn(&run_mempool_tests.step);

    // GPU: Kernel autotuner tests
    const autotuner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/kernel_autotuner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_autotuner_tests = b.addRunArtifact(autotuner_tests);
    b.step("test-kernel-autotuner", "Run kernel autotuner tests").dependOn(&run_autotuner_tests.step);

    // GPU: Backend tests
    const backend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/backend.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_backend_tests = b.addRunArtifact(backend_tests);
    b.step("test-backend", "Run GPU backend tests").dependOn(&run_backend_tests.step);

    // Multi-GPU Manager tests
    const multi_gpu_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/multi_gpu_manager.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_multi_gpu_tests = b.addRunArtifact(multi_gpu_tests);
    b.step("test-multi-gpu", "Run multi-GPU manager tests").dependOn(&run_multi_gpu_tests.step);

    // NCCL bindings tests
    const nccl_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/nccl_bindings.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_nccl_tests = b.addRunArtifact(nccl_tests);
    b.step("test-nccl", "Run NCCL bindings tests").dependOn(&run_nccl_tests.step);

    // All tests
    const all_tests_step = b.step("test", "Run all tests");
    all_tests_step.dependOn(&run_protocol_tests.step);
    all_tests_step.dependOn(&run_storage_tests.step);
    all_tests_step.dependOn(&run_broker_tests.step);
    all_tests_step.dependOn(&run_connector_tests.step);
    all_tests_step.dependOn(&run_flight_tests.step);
    all_tests_step.dependOn(&run_blackboard_tests.step);
    all_tests_step.dependOn(&run_rdma_tests.step);
    all_tests_step.dependOn(&run_classification_tests.step);
    all_tests_step.dependOn(&run_hana_tests.step);
    all_tests_step.dependOn(&run_metrics_http_tests.step);
    all_tests_step.dependOn(&run_cuda_tests.step);
    all_tests_step.dependOn(&run_metal_tests.step);
    all_tests_step.dependOn(&run_kernel_tests.step);
    all_tests_step.dependOn(&run_mempool_tests.step);
    all_tests_step.dependOn(&run_autotuner_tests.step);
    all_tests_step.dependOn(&run_backend_tests.step);

    // Llama inference engine tests
    const llama_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("deps/llama/llama.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_llama_tests = b.addRunArtifact(llama_tests);
    b.step("test-llama", "Run LLM inference engine tests").dependOn(&run_llama_tests.step);
    all_tests_step.dependOn(&run_llama_tests.step);

    // =========================================================================
    // Code Generation (Zig-based)
    // =========================================================================
    const codegen_exe = b.addExecutable(.{
        .name = "codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/codegen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_codegen = b.addRunArtifact(codegen_exe);
    run_codegen.addArgs(&.{
        "--schema", "../mangle/connectors/aiprompt_streaming.mg",
        "--output", "src/gen/connector_types.zig",
        "--service", "bdc-aiprompt-streaming",
    });

    const gen_step = b.step("generate-types", "Generate Zig types from Mangle definitions");
    gen_step.dependOn(&run_codegen.step);
}