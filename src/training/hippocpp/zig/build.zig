//! Build Configuration - Zig 0.15.1 build system for kuzu-zig library
//!
//! Build commands:
//!   zig build              - Build the library
//!   zig build test         - Run all tests
//!   zig build -Doptimize=ReleaseFast - Optimized build

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Unit Tests
    // ========================================================================

    const test_modules = [_][]const u8{
        // Common — Core Types & Utilities
        "src/common/exception.zig",
        "src/common/enums.zig",
        "src/common/constants.zig",
        "src/common/common.zig",
        "src/common/value.zig",
        "src/common/data_chunk.zig",
        "src/common/serializer.zig",
        "src/common/file_system.zig",
        "src/common/profiler.zig",
        "src/common/logger.zig",
        "src/common/arrow/arrow.zig",
        "src/common/types/types.zig",
        "src/common/types/date_t.zig",
        "src/common/types/timestamp_t.zig",
        "src/common/types/interval_t.zig",
        "src/common/types/dtime_t.zig",
        "src/common/types/ku_string.zig",
        "src/common/types/uuid.zig",
        "src/common/types/ku_list.zig",
        "src/common/types/internal_id.zig",
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

        // Processor (standalone modules only)
        "src/processor/processor.zig",

        // Evaluator (standalone modules only)
        "src/evaluator/evaluator.zig",

        // Functions (standalone modules only — subdirs need parent imports)
        "src/function/function.zig",
        "src/function/comparison.zig",

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

    // Create shared module imports for cross-directory dependencies.
    // Zig 0.15.1 blocks @import("../dir/file.zig") for files outside
    // the module root. We register named imports instead.
    const imports = .{
        .{ "common", "src/common/common.zig" },
        .{ "function", "src/function/function.zig" },
        .{ "function_catalog", "src/function/function_catalog.zig" },
        .{ "evaluator", "src/evaluator/evaluator.zig" },
        .{ "expression", "src/expression/expression.zig" },
        .{ "parser", "src/parser/parser.zig" },
        .{ "parser_ast", "src/parser/ast.zig" },
        .{ "catalog", "src/catalog/catalog.zig" },
        .{ "binder", "src/binder/binder.zig" },
        .{ "planner", "src/planner/planner.zig" },
        .{ "logical_plan", "src/planner/logical_plan.zig" },
        .{ "processor", "src/processor/processor.zig" },
        .{ "physical_operator", "src/processor/physical_operator.zig" },
        .{ "optimizer", "src/optimizer/optimizer.zig" },
        .{ "graph", "src/graph/graph.zig" },
        .{ "database", "src/main/database.zig" },
        .{ "main_version", "src/main/version.zig" },
        .{ "c_api_version", "src/c_api/version.zig" },
        .{ "gds", "src/function/gds/gds.zig" },
        .{ "rec_joins", "src/function/gds/rec_joins.zig" },
        .{ "var_path", "src/function/gds/var_path.zig" },
        .{ "file_handle", "src/storage/file_handle.zig" },
        .{ "query_result", "src/main/query_result.zig" },
        .{ "persistent_types", "src/processor/operator/persistent/persistent_types.zig" },
    };

    // Pre-create all shared modules
    var shared_mods: [imports.len]*std.Build.Module = undefined;
    inline for (imports, 0..) |entry, i| {
        shared_mods[i] = b.createModule(.{
            .root_source_file = b.path(entry[1]),
            .target = target,
            .optimize = optimize,
        });
    }

    // Give shared modules access to each other (cross-module imports)
    inline for (0..imports.len) |i| {
        inline for (imports, 0..) |entry, j| {
            if (i != j) {
                shared_mods[i].addImport(entry[0], shared_mods[j]);
            }
        }
    }

    for (test_modules) |module| {
        const mod = b.createModule(.{
            .root_source_file = b.path(module),
            .target = target,
            .optimize = optimize,
        });
        // Register all shared imports
        inline for (imports, 0..) |entry, i| {
            mod.addImport(entry[0], shared_mods[i]);
        }

        const unit_test = b.addTest(.{ .root_module = mod });
        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }
}