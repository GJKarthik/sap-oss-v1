//! Build Configuration - Zig build system for kuzu-zig library
//!
//! Build commands:
//!   zig build              - Build the library
//!   zig build test         - Run all tests
//!   zig build run          - Run the executable
//!   zig build -Doptimize=ReleaseFast - Optimized build

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target and optimization options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Static Library
    // ========================================================================
    
    const lib = b.addStaticLibrary(.{
        .name = "kuzu-zig",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install the library
    b.installArtifact(lib);

    // ========================================================================
    // Shared Library (for C FFI)
    // ========================================================================
    
    const shared_lib = b.addSharedLibrary(.{
        .name = "kuzu",
        .root_source_file = b.path("src/main/api.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install shared library
    b.installArtifact(shared_lib);

    // ========================================================================
    // Executable (CLI tool)
    // ========================================================================
    
    const exe = b.addExecutable(.{
        .name = "kuzu-cli",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the kuzu CLI");
    run_step.dependOn(&run_cmd.step);

    // ========================================================================
    // Unit Tests
    // ========================================================================
    
    const test_modules = [_][]const u8{
        // Common
        "src/common/exception.zig",
        "src/common/enums.zig",
        "src/common/constants.zig",
        "src/common/value.zig",
        "src/common/data_chunk.zig",
        "src/common/serializer.zig",
        "src/common/file_system.zig",
        "src/common/profiler.zig",
        "src/common/logger.zig",
        "src/common/arrow/arrow.zig",
        "src/common/types/date_time.zig",
        "src/common/types/blob.zig",
        
        // Catalog
        "src/catalog/catalog.zig",
        
        // Parser & Binder
        "src/parser/parser.zig",
        "src/binder/binder.zig",
        
        // Planner & Optimizer
        "src/planner/planner.zig",
        "src/optimizer/optimizer.zig",
        
        // Processor
        "src/processor/processor.zig",
        "src/processor/operator/recursive_join.zig",
        
        // Evaluator
        "src/evaluator/evaluator.zig",
        "src/evaluator/function_evaluator.zig",
        
        // Functions
        "src/function/function.zig",
        "src/function/comparison.zig",
        "src/function/aggregate/count.zig",
        "src/function/aggregate/sum.zig",
        "src/function/aggregate/avg.zig",
        "src/function/aggregate/min_max.zig",
        "src/function/aggregate/collect.zig",
        "src/function/string/string.zig",
        "src/function/list/list.zig",
        "src/function/cast/cast.zig",
        "src/function/gds/gds.zig",
        "src/function/gds/shortest_path.zig",
        "src/function/gds/var_path.zig",
        "src/function/gds/rec_joins.zig",
        "src/function/export/csv.zig",
        
        // Storage
        "src/storage/disk_manager.zig",
        "src/storage/local_storage.zig",
        "src/storage/checkpointer.zig",
        "src/storage/buffer_manager/buffer_pool.zig",
        "src/storage/table/column.zig",
        "src/storage/table/rel_table.zig",
        "src/storage/table/node_group.zig",
        "src/storage/index/hash_index.zig",
        "src/storage/wal/wal_record.zig",
        "src/storage/compression/compression.zig",
        "src/storage/stats/stats.zig",
        
        // Transaction
        "src/transaction/transaction_manager.zig",
        
        // Extension
        "src/extension/extension_manager.zig",
        
        // Main
        "src/main/database.zig",
        "src/main/client_context.zig",
        "src/main/query_result.zig",
        "src/main/prepared_statement.zig",
        "src/main/api.zig",
        
        // Testing
        "src/testing/test_helper.zig",
        "src/testing/benchmark.zig",
    };

    const test_step = b.step("test", "Run unit tests");
    
    for (test_modules) |module| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(module),
            .target = target,
            .optimize = optimize,
        });
        
        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }

    // ========================================================================
    // Documentation
    // ========================================================================
    
    const lib_docs = b.addStaticLibrary(.{
        .name = "kuzu-zig",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // ========================================================================
    // Benchmark
    // ========================================================================
    
    const bench_exe = b.addExecutable(.{
        .name = "kuzu-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // ========================================================================
    // Clean
    // ========================================================================
    
    const clean_step = b.step("clean", "Remove build artifacts");
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-cache")).step);
}