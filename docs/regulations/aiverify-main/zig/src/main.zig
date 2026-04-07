const std = @import("std");
const metadata_mod = @import("runtime/metadata.zig");
const python_bridge = @import("runtime/python_bridge.zig");
const test_engine_runtime = @import("runtime/test_engine.zig");
const apigw_runtime = @import("runtime/apigw.zig");
const mojo_metrics_runtime = @import("runtime/mojo_metrics.zig");
const worker_runtime = @import("runtime/worker.zig");
const worker_loop = @import("runtime/worker_loop.zig");

const Component = struct {
    name: []const u8,
    component_cwd: []const u8,
    python_module: []const u8,
    pythonpath: ?[]const u8 = null,
};

const components = [_]Component{
    .{
        .name = "apigw",
        .component_cwd = "aiverify-apigw",
        .python_module = "aiverify_apigw",
    },
    .{
        .name = "test-engine",
        .component_cwd = "aiverify-test-engine",
        .python_module = "aiverify_test_engine",
    },
    .{
        .name = "worker",
        .component_cwd = "aiverify-test-engine-worker",
        .python_module = "aiverify_test_engine_worker",
        .pythonpath = "aiverify-test-engine-worker/src",
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const project_root = try findProjectRoot(allocator);
    defer allocator.free(project_root);

    var metadata: metadata_mod.Metadata = metadata_mod.loadMetadata(allocator, project_root) catch blk: {
        break :blk .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, "aiverify"),
            .version = try allocator.dupe(u8, "unknown"),
            .author = try allocator.dupe(u8, "AI Verify Foundation"),
            .license = try allocator.dupe(u8, "MIT"),
            .description = try allocator.dupe(u8, "AI Verify Zig compatibility runtime"),
        };
    };
    defer metadata.deinit();

    const all_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, all_args);

    if (all_args.len <= 1) {
        printBanner(metadata);
        printUsage(all_args[0]);
        return;
    }

    const first = all_args[1];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "help")) {
        printBanner(metadata);
        printUsage(all_args[0]);
        return;
    }

    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "version")) {
        std.debug.print("{s} {s}\n", .{ metadata.name, metadata.version });
        return;
    }

    if (std.mem.eql(u8, first, "components")) {
        std.debug.print("Available components:\n", .{});
        for (components) |component| {
            std.debug.print("  - {s}\n", .{component.name});
        }
        return;
    }

    const python_executable = getenvOrDefault("AIVERIFY_PYTHON", "python3");

    if (std.mem.eql(u8, first, "test-engine-version")) {
        try handleTestEngineInvocation(
            allocator,
            project_root,
            python_executable,
            &.{},
        );
        return;
    }

    if (std.mem.eql(u8, first, "worker-config")) {
        try handleWorkerConfigInvocation(allocator, project_root);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-config")) {
        try handleApigwConfigInvocation(allocator, project_root);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-validate-gid-cid")) {
        if (all_args.len != 3) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwValidateGidCidInvocation(all_args[2]);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-check-valid-filename")) {
        if (all_args.len != 3) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwCheckValidFilenameInvocation(all_args[2]);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-sanitize-filename")) {
        if (all_args.len != 3) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwSanitizeFilenameInvocation(allocator, all_args[2]);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-check-relative-to-base")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwCheckRelativeToBaseInvocation(allocator, all_args[2], all_args[3]);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-check-file-size")) {
        if (all_args.len != 3) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwCheckFileSizeInvocation(all_args[2]);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-append-filename")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwAppendFilenameInvocation(allocator, all_args[2], all_args[3]);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-suffix")) {
        if (all_args.len != 3) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetSuffixInvocation(allocator, all_args[2]);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-stem")) {
        if (all_args.len != 3) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetStemInvocation(all_args[2]);
        return;
    }

    if (std.mem.eql(u8, first, "apigw-plugin-storage-layout")) {
        if (all_args.len != 6) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwPluginStorageLayoutInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
            all_args[5],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-data-storage-layout")) {
        if (all_args.len != 9) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwDataStorageLayoutInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
            all_args[5],
            all_args[6],
            all_args[7],
            all_args[8],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-save-artifact")) {
        if (all_args.len != 6) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwSaveArtifactInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
            all_args[5],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-artifact")) {
        if (all_args.len != 5) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetArtifactInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-save-model-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwSaveModelLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-model-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetModelLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-delete-model-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwDeleteModelLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-save-dataset-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwSaveDatasetLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-dataset-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetDatasetLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-delete-dataset-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwDeleteDatasetLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-save-plugin-local")) {
        if (all_args.len != 5) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwSavePluginLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-save-plugin-algorithm-local")) {
        if (all_args.len != 6) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwSavePluginAlgorithmLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
            all_args[5],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-save-plugin-widgets-local")) {
        if (all_args.len != 5) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwSavePluginWidgetsLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-save-plugin-inputs-local")) {
        if (all_args.len != 5) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwSavePluginInputsLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-save-plugin-mdx-bundles-local")) {
        if (all_args.len != 5) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwSavePluginMdxBundlesLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-backup-plugin-local")) {
        if (all_args.len != 5) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwBackupPluginLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-plugin-zip-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetPluginZipLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-plugin-algorithm-zip-local")) {
        if (all_args.len != 5) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetPluginAlgorithmZipLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-plugin-widgets-zip-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetPluginWidgetsZipLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-plugin-inputs-zip-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetPluginInputsZipLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-plugin-mdx-bundle-local")) {
        if (all_args.len != 5) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetPluginMdxBundleLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-get-plugin-mdx-summary-bundle-local")) {
        if (all_args.len != 5) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwGetPluginMdxSummaryBundleLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
            all_args[4],
        );
        return;
    }

    if (std.mem.eql(u8, first, "apigw-delete-plugin-local")) {
        if (all_args.len != 4) {
            printApigwHelperUsage(all_args[0]);
            std.process.exit(2);
        }
        try handleApigwDeletePluginLocalInvocation(
            allocator,
            all_args[2],
            all_args[3],
        );
        return;
    }

    if (std.mem.eql(u8, first, "worker-once")) {
        const invocation = worker_runtime.classifyOnceArgs(all_args[2..]);
        if (invocation.action != .once) {
            std.debug.print(
                "Usage: {s} worker-once [--ack] [--reclaim] [--min-idle-ms <ms>] [--start <id>]\n",
                .{all_args[0]},
            );
            std.process.exit(2);
        }
        try handleWorkerOnceInvocation(allocator, project_root, invocation);
        return;
    }

    if (std.mem.eql(u8, first, "metrics-gap")) {
        if (all_args.len != 4) {
            std.debug.print(
                "Usage: {s} metrics-gap <reference> <candidate>\n",
                .{all_args[0]},
            );
            std.process.exit(2);
        }

        const reference = std.fmt.parseFloat(f64, all_args[2]) catch {
            std.debug.print("Invalid reference value: {s}\n", .{all_args[2]});
            std.process.exit(2);
        };
        const candidate = std.fmt.parseFloat(f64, all_args[3]) catch {
            std.debug.print("Invalid candidate value: {s}\n", .{all_args[3]});
            std.process.exit(2);
        };

        try handleMetricsGapInvocation(allocator, project_root, reference, candidate);
        return;
    }

    if (std.mem.eql(u8, first, "normalize-plugin-gid")) {
        if (all_args.len != 3) {
            std.debug.print(
                "Usage: {s} normalize-plugin-gid <text>\n",
                .{all_args[0]},
            );
            std.process.exit(2);
        }
        try handleNormalizePluginGidInvocation(allocator, project_root, all_args[2]);
        return;
    }

    if (std.mem.eql(u8, first, "run")) {
        if (all_args.len < 3) {
            std.debug.print("Missing component name.\n\n", .{});
            printUsage(all_args[0]);
            std.process.exit(2);
        }
        const component_name = all_args[2];
        const component = findComponent(component_name) orelse {
            std.debug.print("Unknown component: {s}\n\n", .{component_name});
            printUsage(all_args[0]);
            std.process.exit(2);
        };
        if (std.mem.eql(u8, component.name, "test-engine")) {
            try handleTestEngineInvocation(
                allocator,
                project_root,
                python_executable,
                all_args[3..],
            );
            return;
        }
        if (std.mem.eql(u8, component.name, "apigw")) {
            const invocation = apigw_runtime.classifyInvocation(all_args[3..]);
            switch (invocation.action) {
                .config => {
                    try handleApigwConfigInvocation(allocator, project_root);
                    return;
                },
                .validate_gid_cid => {
                    try handleApigwValidateGidCidInvocation(invocation.gid_cid_value);
                    return;
                },
                .check_valid_filename => {
                    try handleApigwCheckValidFilenameInvocation(invocation.filename_value);
                    return;
                },
                .sanitize_filename => {
                    try handleApigwSanitizeFilenameInvocation(allocator, invocation.filename_value);
                    return;
                },
                .check_relative_to_base => {
                    try handleApigwCheckRelativeToBaseInvocation(
                        allocator,
                        invocation.base_path_value,
                        invocation.filepath_value,
                    );
                    return;
                },
                .check_file_size => {
                    try handleApigwCheckFileSizeInvocation(invocation.size_value);
                    return;
                },
                .append_filename => {
                    try handleApigwAppendFilenameInvocation(
                        allocator,
                        invocation.filename_value,
                        invocation.append_name_value,
                    );
                    return;
                },
                .get_suffix => {
                    try handleApigwGetSuffixInvocation(allocator, invocation.filename_value);
                    return;
                },
                .get_stem => {
                    try handleApigwGetStemInvocation(invocation.filename_value);
                    return;
                },
                .plugin_storage_layout => {
                    try handleApigwPluginStorageLayoutInvocation(
                        allocator,
                        invocation.storage_mode_value,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                    );
                    return;
                },
                .data_storage_layout => {
                    try handleApigwDataStorageLayoutInvocation(
                        allocator,
                        invocation.storage_mode_value,
                        invocation.artifacts_base_value,
                        invocation.models_base_value,
                        invocation.dataset_base_value,
                        invocation.test_result_id_value,
                        invocation.filename_value,
                        invocation.subfolder_value,
                    );
                    return;
                },
                .save_artifact => {
                    try handleApigwSaveArtifactInvocation(
                        allocator,
                        invocation.artifacts_base_value,
                        invocation.test_result_id_value,
                        invocation.filename_value,
                        invocation.payload_value,
                    );
                    return;
                },
                .get_artifact => {
                    try handleApigwGetArtifactInvocation(
                        allocator,
                        invocation.artifacts_base_value,
                        invocation.test_result_id_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .save_model_local => {
                    try handleApigwSaveModelLocalInvocation(
                        allocator,
                        invocation.models_base_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .get_model_local => {
                    try handleApigwGetModelLocalInvocation(
                        allocator,
                        invocation.models_base_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .delete_model_local => {
                    try handleApigwDeleteModelLocalInvocation(
                        allocator,
                        invocation.models_base_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .save_dataset_local => {
                    try handleApigwSaveDatasetLocalInvocation(
                        allocator,
                        invocation.dataset_base_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .get_dataset_local => {
                    try handleApigwGetDatasetLocalInvocation(
                        allocator,
                        invocation.dataset_base_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .delete_dataset_local => {
                    try handleApigwDeleteDatasetLocalInvocation(
                        allocator,
                        invocation.dataset_base_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .save_plugin_local => {
                    try handleApigwSavePluginLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .save_plugin_algorithm_local => {
                    try handleApigwSavePluginAlgorithmLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .save_plugin_widgets_local => {
                    try handleApigwSavePluginWidgetsLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .save_plugin_inputs_local => {
                    try handleApigwSavePluginInputsLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .save_plugin_mdx_bundles_local => {
                    try handleApigwSavePluginMdxBundlesLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .backup_plugin_local => {
                    try handleApigwBackupPluginLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.target_path_value,
                    );
                    return;
                },
                .get_plugin_zip_local => {
                    try handleApigwGetPluginZipLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                    );
                    return;
                },
                .get_plugin_algorithm_zip_local => {
                    try handleApigwGetPluginAlgorithmZipLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                    );
                    return;
                },
                .get_plugin_widgets_zip_local => {
                    try handleApigwGetPluginWidgetsZipLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                    );
                    return;
                },
                .get_plugin_inputs_zip_local => {
                    try handleApigwGetPluginInputsZipLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                    );
                    return;
                },
                .get_plugin_mdx_bundle_local => {
                    try handleApigwGetPluginMdxBundleLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                    );
                    return;
                },
                .get_plugin_mdx_summary_bundle_local => {
                    try handleApigwGetPluginMdxSummaryBundleLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                    );
                    return;
                },
                .delete_plugin_local => {
                    try handleApigwDeletePluginLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                    );
                    return;
                },
                .usage_error => {
                    printApigwHelperUsage(all_args[0]);
                    std.process.exit(2);
                },
                .pass_through => {},
            }
        }
        if (std.mem.eql(u8, component.name, "worker")) {
            const invocation = worker_runtime.classifyInvocation(all_args[3..]);
            switch (invocation.action) {
                .config => {
                    try handleWorkerConfigInvocation(allocator, project_root);
                    return;
                },
                .once => {
                    try handleWorkerOnceInvocation(allocator, project_root, invocation);
                    return;
                },
                .pass_through => {},
            }
        }
        const exit_code = try runComponent(
            allocator,
            project_root,
            python_executable,
            component,
            all_args[3..],
        );
        std.process.exit(exit_code);
    }

    if (findComponent(first)) |component| {
        if (std.mem.eql(u8, component.name, "test-engine")) {
            try handleTestEngineInvocation(
                allocator,
                project_root,
                python_executable,
                all_args[2..],
            );
            return;
        }
        if (std.mem.eql(u8, component.name, "apigw")) {
            const invocation = apigw_runtime.classifyInvocation(all_args[2..]);
            switch (invocation.action) {
                .config => {
                    try handleApigwConfigInvocation(allocator, project_root);
                    return;
                },
                .validate_gid_cid => {
                    try handleApigwValidateGidCidInvocation(invocation.gid_cid_value);
                    return;
                },
                .check_valid_filename => {
                    try handleApigwCheckValidFilenameInvocation(invocation.filename_value);
                    return;
                },
                .sanitize_filename => {
                    try handleApigwSanitizeFilenameInvocation(allocator, invocation.filename_value);
                    return;
                },
                .check_relative_to_base => {
                    try handleApigwCheckRelativeToBaseInvocation(
                        allocator,
                        invocation.base_path_value,
                        invocation.filepath_value,
                    );
                    return;
                },
                .check_file_size => {
                    try handleApigwCheckFileSizeInvocation(invocation.size_value);
                    return;
                },
                .append_filename => {
                    try handleApigwAppendFilenameInvocation(
                        allocator,
                        invocation.filename_value,
                        invocation.append_name_value,
                    );
                    return;
                },
                .get_suffix => {
                    try handleApigwGetSuffixInvocation(allocator, invocation.filename_value);
                    return;
                },
                .get_stem => {
                    try handleApigwGetStemInvocation(invocation.filename_value);
                    return;
                },
                .plugin_storage_layout => {
                    try handleApigwPluginStorageLayoutInvocation(
                        allocator,
                        invocation.storage_mode_value,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                    );
                    return;
                },
                .data_storage_layout => {
                    try handleApigwDataStorageLayoutInvocation(
                        allocator,
                        invocation.storage_mode_value,
                        invocation.artifacts_base_value,
                        invocation.models_base_value,
                        invocation.dataset_base_value,
                        invocation.test_result_id_value,
                        invocation.filename_value,
                        invocation.subfolder_value,
                    );
                    return;
                },
                .save_artifact => {
                    try handleApigwSaveArtifactInvocation(
                        allocator,
                        invocation.artifacts_base_value,
                        invocation.test_result_id_value,
                        invocation.filename_value,
                        invocation.payload_value,
                    );
                    return;
                },
                .get_artifact => {
                    try handleApigwGetArtifactInvocation(
                        allocator,
                        invocation.artifacts_base_value,
                        invocation.test_result_id_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .save_model_local => {
                    try handleApigwSaveModelLocalInvocation(
                        allocator,
                        invocation.models_base_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .get_model_local => {
                    try handleApigwGetModelLocalInvocation(
                        allocator,
                        invocation.models_base_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .delete_model_local => {
                    try handleApigwDeleteModelLocalInvocation(
                        allocator,
                        invocation.models_base_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .save_dataset_local => {
                    try handleApigwSaveDatasetLocalInvocation(
                        allocator,
                        invocation.dataset_base_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .get_dataset_local => {
                    try handleApigwGetDatasetLocalInvocation(
                        allocator,
                        invocation.dataset_base_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .delete_dataset_local => {
                    try handleApigwDeleteDatasetLocalInvocation(
                        allocator,
                        invocation.dataset_base_value,
                        invocation.filename_value,
                    );
                    return;
                },
                .save_plugin_local => {
                    try handleApigwSavePluginLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .save_plugin_algorithm_local => {
                    try handleApigwSavePluginAlgorithmLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .save_plugin_widgets_local => {
                    try handleApigwSavePluginWidgetsLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .save_plugin_inputs_local => {
                    try handleApigwSavePluginInputsLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .save_plugin_mdx_bundles_local => {
                    try handleApigwSavePluginMdxBundlesLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.source_path_value,
                    );
                    return;
                },
                .backup_plugin_local => {
                    try handleApigwBackupPluginLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.target_path_value,
                    );
                    return;
                },
                .get_plugin_zip_local => {
                    try handleApigwGetPluginZipLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                    );
                    return;
                },
                .get_plugin_algorithm_zip_local => {
                    try handleApigwGetPluginAlgorithmZipLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                    );
                    return;
                },
                .get_plugin_widgets_zip_local => {
                    try handleApigwGetPluginWidgetsZipLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                    );
                    return;
                },
                .get_plugin_inputs_zip_local => {
                    try handleApigwGetPluginInputsZipLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                    );
                    return;
                },
                .get_plugin_mdx_bundle_local => {
                    try handleApigwGetPluginMdxBundleLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                    );
                    return;
                },
                .get_plugin_mdx_summary_bundle_local => {
                    try handleApigwGetPluginMdxSummaryBundleLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                        invocation.plugin_cid_value,
                    );
                    return;
                },
                .delete_plugin_local => {
                    try handleApigwDeletePluginLocalInvocation(
                        allocator,
                        invocation.plugin_base_value,
                        invocation.plugin_gid_value,
                    );
                    return;
                },
                .usage_error => {
                    printApigwHelperUsage(all_args[0]);
                    std.process.exit(2);
                },
                .pass_through => {},
            }
        }
        if (std.mem.eql(u8, component.name, "worker")) {
            const invocation = worker_runtime.classifyInvocation(all_args[2..]);
            switch (invocation.action) {
                .config => {
                    try handleWorkerConfigInvocation(allocator, project_root);
                    return;
                },
                .once => {
                    try handleWorkerOnceInvocation(allocator, project_root, invocation);
                    return;
                },
                .pass_through => {},
            }
        }
        const exit_code = try runComponent(
            allocator,
            project_root,
            python_executable,
            component,
            all_args[2..],
        );
        std.process.exit(exit_code);
    }

    std.debug.print("Unknown command: {s}\n\n", .{first});
    printUsage(all_args[0]);
    std.process.exit(2);
}

fn handleTestEngineInvocation(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    python_executable: []const u8,
    args: []const []const u8,
) !void {
    const stdout = std.fs.File.stdout();
    switch (test_engine_runtime.classifyArgs(args)) {
        .version => {
            const message = try test_engine_runtime.renderVersionMessage(
                allocator,
                project_root,
                python_executable,
            );
            defer allocator.free(message);
            try stdout.writeAll(message);
            try stdout.writeAll("\n");
        },
        .help => {
            try stdout.writeAll(test_engine_runtime.helpText());
            try stdout.writeAll("\n");
        },
        .pass_through => {
            const component = findComponent("test-engine").?;
            const exit_code = try runComponent(
                allocator,
                project_root,
                python_executable,
                component,
                args,
            );
            std.process.exit(exit_code);
        },
    }
}

fn handleWorkerConfigInvocation(
    allocator: std.mem.Allocator,
    project_root: []const u8,
) !void {
    var config = try worker_runtime.loadConfig(allocator, project_root);
    defer config.deinit(allocator);

    try worker_runtime.validateStartupConfig(allocator, project_root, &config);

    const summary = try worker_runtime.renderSummary(allocator, &config);
    defer allocator.free(summary);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(summary);
    try stdout.writeAll("\n");
}

fn handleApigwConfigInvocation(
    allocator: std.mem.Allocator,
    project_root: []const u8,
) !void {
    var config = try apigw_runtime.loadConfig(allocator, project_root);
    defer config.deinit(allocator);

    const summary = try apigw_runtime.renderSummary(allocator, &config);
    defer allocator.free(summary);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(summary);
    try stdout.writeAll("\n");
}

fn handleApigwValidateGidCidInvocation(value: []const u8) !void {
    const valid = apigw_runtime.validateGidCid(value);
    const status = if (valid) "yes" else "no";
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW gid/cid valid: ");
    try stdout.writeAll(status);
    try stdout.writeAll("\n");
}

fn handleApigwCheckValidFilenameInvocation(value: []const u8) !void {
    const valid = apigw_runtime.checkValidFilename(value);
    const status = if (valid) "yes" else "no";
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW filename valid: ");
    try stdout.writeAll(status);
    try stdout.writeAll("\n");
}

fn handleApigwSanitizeFilenameInvocation(
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    const sanitized = apigw_runtime.sanitizeFilenameAlloc(allocator, value) catch |err| switch (err) {
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(sanitized);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW sanitized filename: ");
    try stdout.writeAll(sanitized);
    try stdout.writeAll("\n");
}

fn handleApigwCheckRelativeToBaseInvocation(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    filepath: []const u8,
) !void {
    const valid = try apigw_runtime.checkRelativeToBase(allocator, base_path, filepath);
    const status = if (valid) "yes" else "no";
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW path relative: ");
    try stdout.writeAll(status);
    try stdout.writeAll("\n");
}

fn handleApigwCheckFileSizeInvocation(raw_size: []const u8) !void {
    const size = std.fmt.parseInt(i128, raw_size, 10) catch {
        std.debug.print("Invalid file size value: {s}\n", .{raw_size});
        std.process.exit(2);
    };

    const valid = apigw_runtime.checkFileSize(size);
    const status = if (valid) "yes" else "no";
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW file size valid: ");
    try stdout.writeAll(status);
    try stdout.writeAll("\n");
}

fn handleApigwAppendFilenameInvocation(
    allocator: std.mem.Allocator,
    filename: []const u8,
    append_name: []const u8,
) !void {
    const appended = try apigw_runtime.appendFilenameAlloc(allocator, filename, append_name);
    defer allocator.free(appended);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW appended filename: ");
    try stdout.writeAll(appended);
    try stdout.writeAll("\n");
}

fn handleApigwGetSuffixInvocation(
    allocator: std.mem.Allocator,
    filename: []const u8,
) !void {
    const suffix = try apigw_runtime.getSuffixAlloc(allocator, filename);
    defer allocator.free(suffix);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW suffix: ");
    try stdout.writeAll(suffix);
    try stdout.writeAll("\n");
}

fn handleApigwGetStemInvocation(filename: []const u8) !void {
    const stem = apigw_runtime.getStem(filename);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW stem: ");
    try stdout.writeAll(stem);
    try stdout.writeAll("\n");
}

fn handleApigwPluginStorageLayoutInvocation(
    allocator: std.mem.Allocator,
    mode: []const u8,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
) !void {
    const rendered = apigw_runtime.renderPluginStorageLayoutAlloc(
        allocator,
        mode,
        base_plugin_dir,
        gid,
        cid,
    ) catch |err| switch (err) {
        error.InvalidStorageMode => {
            std.debug.print("Invalid storage mode: {s} (expected local|prefix|s3)\n", .{mode});
            std.process.exit(2);
        },
        else => return err,
    };
    defer allocator.free(rendered);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(rendered);
    try stdout.writeAll("\n");
}

fn handleApigwDataStorageLayoutInvocation(
    allocator: std.mem.Allocator,
    mode: []const u8,
    base_artifacts_dir: []const u8,
    base_models_dir: []const u8,
    base_dataset_dir: []const u8,
    test_result_id: []const u8,
    filename: []const u8,
    subfolder: []const u8,
) !void {
    const rendered = apigw_runtime.renderDataStorageLayoutAlloc(
        allocator,
        mode,
        base_artifacts_dir,
        base_models_dir,
        base_dataset_dir,
        test_result_id,
        filename,
        subfolder,
    ) catch |err| switch (err) {
        error.InvalidStorageMode => {
            std.debug.print("Invalid storage mode: {s} (expected local|s3)\n", .{mode});
            std.process.exit(2);
        },
        else => return err,
    };
    defer allocator.free(rendered);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(rendered);
    try stdout.writeAll("\n");
}

fn handleApigwSaveArtifactInvocation(
    allocator: std.mem.Allocator,
    base_artifacts_dir: []const u8,
    test_result_id: []const u8,
    filename: []const u8,
    payload: []const u8,
) !void {
    const saved_path = apigw_runtime.saveArtifactLocalAlloc(
        allocator,
        base_artifacts_dir,
        test_result_id,
        filename,
        payload,
    ) catch |err| switch (err) {
        error.InvalidTestResultId => {
            std.debug.print("error: InvalidTestResultId\n", .{});
            std.process.exit(1);
        },
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(saved_path);

    const summary = try std.fmt.allocPrint(
        allocator,
        \\APIGW artifact saved
        \\  path: {s}
        \\  bytes: {d}
    ,
        .{ saved_path, payload.len },
    );
    defer allocator.free(summary);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(summary);
    try stdout.writeAll("\n");
}

fn handleApigwGetArtifactInvocation(
    allocator: std.mem.Allocator,
    base_artifacts_dir: []const u8,
    test_result_id: []const u8,
    filename: []const u8,
) !void {
    const content = apigw_runtime.getArtifactLocalAlloc(
        allocator,
        base_artifacts_dir,
        test_result_id,
        filename,
    ) catch |err| switch (err) {
        error.InvalidTestResultId => {
            std.debug.print("error: InvalidTestResultId\n", .{});
            std.process.exit(1);
        },
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.ArtifactNotFound => {
            std.debug.print("error: ArtifactNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(content);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW artifact content: ");
    try stdout.writeAll(content);
    try stdout.writeAll("\n");
}

fn handleApigwSaveModelLocalInvocation(
    allocator: std.mem.Allocator,
    base_models_dir: []const u8,
    source_path: []const u8,
) !void {
    var save_result = apigw_runtime.saveModelLocalAlloc(
        allocator,
        base_models_dir,
        source_path,
    ) catch |err| switch (err) {
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.SourceNotFound => {
            std.debug.print("error: SourceNotFound\n", .{});
            std.process.exit(1);
        },
        error.SourceDirectoryUnsupported => {
            std.debug.print("error: SourceDirectoryUnsupported\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer save_result.deinit(allocator);

    const summary = try std.fmt.allocPrint(
        allocator,
        \\APIGW model saved
        \\  path: {s}
        \\  sha256: {s}
    ,
        .{ save_result.target_path, save_result.sha256_hex },
    );
    defer allocator.free(summary);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(summary);
    try stdout.writeAll("\n");
}

fn handleApigwGetModelLocalInvocation(
    allocator: std.mem.Allocator,
    base_models_dir: []const u8,
    filename: []const u8,
) !void {
    const content = apigw_runtime.getModelLocalAlloc(
        allocator,
        base_models_dir,
        filename,
    ) catch |err| switch (err) {
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.ModelNotFound => {
            std.debug.print("error: ModelNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(content);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW model content: ");
    try stdout.writeAll(content);
    try stdout.writeAll("\n");
}

fn handleApigwDeleteModelLocalInvocation(
    allocator: std.mem.Allocator,
    base_models_dir: []const u8,
    filename: []const u8,
) !void {
    const deleted = apigw_runtime.deleteModelLocal(
        allocator,
        base_models_dir,
        filename,
    ) catch |err| switch (err) {
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };

    const status = if (deleted) "yes" else "no";
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW model deleted: ");
    try stdout.writeAll(status);
    try stdout.writeAll("\n");
}

fn handleApigwSaveDatasetLocalInvocation(
    allocator: std.mem.Allocator,
    base_dataset_dir: []const u8,
    source_path: []const u8,
) !void {
    var save_result = apigw_runtime.saveDatasetLocalAlloc(
        allocator,
        base_dataset_dir,
        source_path,
    ) catch |err| switch (err) {
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.SourceNotFound => {
            std.debug.print("error: SourceNotFound\n", .{});
            std.process.exit(1);
        },
        error.SourceDirectoryUnsupported => {
            std.debug.print("error: SourceDirectoryUnsupported\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer save_result.deinit(allocator);

    const summary = try std.fmt.allocPrint(
        allocator,
        \\APIGW dataset saved
        \\  path: {s}
        \\  sha256: {s}
    ,
        .{ save_result.target_path, save_result.sha256_hex },
    );
    defer allocator.free(summary);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(summary);
    try stdout.writeAll("\n");
}

fn handleApigwGetDatasetLocalInvocation(
    allocator: std.mem.Allocator,
    base_dataset_dir: []const u8,
    filename: []const u8,
) !void {
    const content = apigw_runtime.getDatasetLocalAlloc(
        allocator,
        base_dataset_dir,
        filename,
    ) catch |err| switch (err) {
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.DatasetNotFound => {
            std.debug.print("error: DatasetNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(content);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW dataset content: ");
    try stdout.writeAll(content);
    try stdout.writeAll("\n");
}

fn handleApigwDeleteDatasetLocalInvocation(
    allocator: std.mem.Allocator,
    base_dataset_dir: []const u8,
    filename: []const u8,
) !void {
    const deleted = apigw_runtime.deleteDatasetLocal(
        allocator,
        base_dataset_dir,
        filename,
    ) catch |err| switch (err) {
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };

    const status = if (deleted) "yes" else "no";
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW dataset deleted: ");
    try stdout.writeAll(status);
    try stdout.writeAll("\n");
}

fn handleApigwSavePluginLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    source_path: []const u8,
) !void {
    var save_result = apigw_runtime.savePluginLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        source_path,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.SourceNotFound => {
            std.debug.print("error: SourceNotFound\n", .{});
            std.process.exit(1);
        },
        error.SourceDirectoryUnsupported => {
            std.debug.print("error: SourceDirectoryUnsupported\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer save_result.deinit(allocator);

    try writePluginArchiveSaveSummary(
        allocator,
        "APIGW plugin archive saved",
        save_result.zip_path,
        save_result.hash_path,
        save_result.sha256_hex,
    );
}

fn handleApigwSavePluginAlgorithmLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
    source_path: []const u8,
) !void {
    var save_result = apigw_runtime.savePluginAlgorithmLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        cid,
        source_path,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.InvalidCid => {
            std.debug.print("error: InvalidCid\n", .{});
            std.process.exit(1);
        },
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.SourceNotFound => {
            std.debug.print("error: SourceNotFound\n", .{});
            std.process.exit(1);
        },
        error.SourceDirectoryUnsupported => {
            std.debug.print("error: SourceDirectoryUnsupported\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer save_result.deinit(allocator);

    try writePluginArchiveSaveSummary(
        allocator,
        "APIGW plugin algorithm archive saved",
        save_result.zip_path,
        save_result.hash_path,
        save_result.sha256_hex,
    );
}

fn handleApigwSavePluginWidgetsLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    source_path: []const u8,
) !void {
    var save_result = apigw_runtime.savePluginWidgetsLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        source_path,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.SourceNotFound => {
            std.debug.print("error: SourceNotFound\n", .{});
            std.process.exit(1);
        },
        error.SourceDirectoryUnsupported => {
            std.debug.print("error: SourceDirectoryUnsupported\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer save_result.deinit(allocator);

    try writePluginArchiveSaveSummary(
        allocator,
        "APIGW plugin widgets archive saved",
        save_result.zip_path,
        save_result.hash_path,
        save_result.sha256_hex,
    );
}

fn handleApigwSavePluginInputsLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    source_path: []const u8,
) !void {
    var save_result = apigw_runtime.savePluginInputsLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        source_path,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.SourceNotFound => {
            std.debug.print("error: SourceNotFound\n", .{});
            std.process.exit(1);
        },
        error.SourceDirectoryUnsupported => {
            std.debug.print("error: SourceDirectoryUnsupported\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer save_result.deinit(allocator);

    try writePluginArchiveSaveSummary(
        allocator,
        "APIGW plugin inputs archive saved",
        save_result.zip_path,
        save_result.hash_path,
        save_result.sha256_hex,
    );
}

fn handleApigwSavePluginMdxBundlesLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    source_path: []const u8,
) !void {
    const saved_path = apigw_runtime.savePluginMdxBundlesLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        source_path,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.SourceNotFound => {
            std.debug.print("error: SourceNotFound\n", .{});
            std.process.exit(1);
        },
        error.SourceDirectoryUnsupported => {
            std.debug.print("error: SourceDirectoryUnsupported\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(saved_path);

    const summary = try std.fmt.allocPrint(
        allocator,
        \\APIGW plugin mdx bundles saved
        \\  path: {s}
    ,
        .{saved_path},
    );
    defer allocator.free(summary);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(summary);
    try stdout.writeAll("\n");
}

fn handleApigwGetPluginMdxBundleLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
) !void {
    const content = apigw_runtime.getPluginMdxBundleLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        cid,
        false,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.InvalidCid => {
            std.debug.print("error: InvalidCid\n", .{});
            std.process.exit(1);
        },
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.PluginBundleNotFound => {
            std.debug.print("error: PluginBundleNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(content);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW plugin mdx bundle content: ");
    try stdout.writeAll(content);
    try stdout.writeAll("\n");
}

fn handleApigwGetPluginMdxSummaryBundleLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
) !void {
    const content = apigw_runtime.getPluginMdxBundleLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        cid,
        true,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.InvalidCid => {
            std.debug.print("error: InvalidCid\n", .{});
            std.process.exit(1);
        },
        error.InvalidFilename => {
            std.debug.print("error: InvalidFilename\n", .{});
            std.process.exit(1);
        },
        error.PluginBundleNotFound => {
            std.debug.print("error: PluginBundleNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(content);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW plugin mdx summary bundle content: ");
    try stdout.writeAll(content);
    try stdout.writeAll("\n");
}

fn handleApigwBackupPluginLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    target_dir: []const u8,
) !void {
    const backup_path = apigw_runtime.backupPluginLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        target_dir,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.PluginSourceNotFound => {
            std.debug.print("error: PluginSourceNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(backup_path);

    const summary = try std.fmt.allocPrint(
        allocator,
        \\APIGW plugin backup completed
        \\  path: {s}
    ,
        .{backup_path},
    );
    defer allocator.free(summary);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(summary);
    try stdout.writeAll("\n");
}

fn handleApigwGetPluginZipLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
) !void {
    const zip_content = apigw_runtime.getPluginZipLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.PluginArchiveNotFound => {
            std.debug.print("error: PluginArchiveNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(zip_content);
    try writePluginArchiveGetSummary(allocator, "APIGW plugin zip bytes", zip_content.len);
}

fn handleApigwGetPluginAlgorithmZipLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
) !void {
    const zip_content = apigw_runtime.getPluginAlgorithmZipLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        cid,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.InvalidCid => {
            std.debug.print("error: InvalidCid\n", .{});
            std.process.exit(1);
        },
        error.PluginArchiveNotFound => {
            std.debug.print("error: PluginArchiveNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(zip_content);
    try writePluginArchiveGetSummary(allocator, "APIGW plugin algorithm zip bytes", zip_content.len);
}

fn handleApigwGetPluginWidgetsZipLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
) !void {
    const zip_content = apigw_runtime.getPluginWidgetsZipLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.PluginArchiveNotFound => {
            std.debug.print("error: PluginArchiveNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(zip_content);
    try writePluginArchiveGetSummary(allocator, "APIGW plugin widgets zip bytes", zip_content.len);
}

fn handleApigwGetPluginInputsZipLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
) !void {
    const zip_content = apigw_runtime.getPluginInputsZipLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        error.PluginArchiveNotFound => {
            std.debug.print("error: PluginArchiveNotFound\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(zip_content);
    try writePluginArchiveGetSummary(allocator, "APIGW plugin inputs zip bytes", zip_content.len);
}

fn handleApigwDeletePluginLocalInvocation(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
) !void {
    const deleted = apigw_runtime.deletePluginLocal(
        allocator,
        base_plugin_dir,
        gid,
    ) catch |err| switch (err) {
        error.InvalidGid => {
            std.debug.print("error: InvalidGid\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };

    const status = if (deleted) "yes" else "no";
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("APIGW plugin deleted: ");
    try stdout.writeAll(status);
    try stdout.writeAll("\n");
}

fn writePluginArchiveSaveSummary(
    allocator: std.mem.Allocator,
    header: []const u8,
    zip_path: []const u8,
    hash_path: []const u8,
    sha256_hex: []const u8,
) !void {
    const summary = try std.fmt.allocPrint(
        allocator,
        \\{s}
        \\  zip_path: {s}
        \\  hash_path: {s}
        \\  sha256: {s}
    ,
        .{ header, zip_path, hash_path, sha256_hex },
    );
    defer allocator.free(summary);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(summary);
    try stdout.writeAll("\n");
}

fn writePluginArchiveGetSummary(
    allocator: std.mem.Allocator,
    label: []const u8,
    byte_len: usize,
) !void {
    const summary = try std.fmt.allocPrint(
        allocator,
        "{s}: {d}\n",
        .{ label, byte_len },
    );
    defer allocator.free(summary);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(summary);
}

fn handleMetricsGapInvocation(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    reference: f64,
    candidate: f64,
) !void {
    var metrics_runtime = try mojo_metrics_runtime.Runtime.init(allocator, project_root);
    defer metrics_runtime.deinit();

    const gap = metrics_runtime.parityGap(reference, candidate);
    const source = metrics_runtime.sourceLabel();

    const message = try std.fmt.allocPrint(
        allocator,
        "Metric parity gap: {d:.10} (source={s})\n",
        .{ gap, source },
    );
    defer allocator.free(message);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(message);
}

fn handleNormalizePluginGidInvocation(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    text: []const u8,
) !void {
    var metrics_runtime = try mojo_metrics_runtime.Runtime.init(allocator, project_root);
    defer metrics_runtime.deinit();

    var normalized = try metrics_runtime.normalizePluginGid(allocator, text);
    defer normalized.deinit(allocator);

    const source = mojo_metrics_runtime.sourceLabelFor(normalized.source);
    const message = try std.fmt.allocPrint(
        allocator,
        "Normalized plugin gid: {s} (source={s})\n",
        .{ normalized.value, source },
    );
    defer allocator.free(message);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(message);
}

fn handleWorkerOnceInvocation(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    invocation: worker_runtime.WorkerInvocation,
) !void {
    var config = try worker_runtime.loadConfig(allocator, project_root);
    defer config.deinit(allocator);
    try worker_runtime.validateStartupConfig(allocator, project_root, &config);

    var once_result = try worker_loop.runOnce(allocator, .{
        .host = config.valkey_host,
        .port = config.valkey_port,
        .stream_name = worker_runtime.TASK_STREAM_NAME,
        .group_name = worker_runtime.TASK_GROUP_NAME,
        .consumer_name = "zig-worker-once",
        .block_ms = worker_runtime.WORKER_BLOCK_MS,
        .count = 1,
        .ack_on_receive = invocation.ack,
        .mode = if (invocation.reclaim) .reclaim else .pending,
        .reclaim_min_idle_ms = invocation.reclaim_min_idle_ms,
        .reclaim_start = invocation.reclaim_start,
    });
    defer once_result.deinit(allocator);

    const stdout = std.fs.File.stdout();
    if (once_result.message_id == null) {
        if (once_result.reclaim_next_start) |next| {
            const no_msg = try std.fmt.allocPrint(
                allocator,
                "Worker once poll: no messages available. reclaim_next_start={s}\n",
                .{next},
            );
            defer allocator.free(no_msg);
            try stdout.writeAll(no_msg);
            return;
        }
        try stdout.writeAll("Worker once poll: no messages available.\n");
        return;
    }

    const message_id = once_result.message_id.?;
    const preview = once_result.task_preview orelse "";
    const truncated = if (once_result.truncated) "yes" else "no";
    const acked = if (once_result.acked) "yes" else "no";
    const reclaim_mode = if (invocation.reclaim) "yes" else "no";
    const reclaim_next_start = once_result.reclaim_next_start orelse "<n/a>";

    const summary = try std.fmt.allocPrint(
        allocator,
        \\Worker once poll result
        \\  message_id: {s}
        \\  task_size: {d}
        \\  task_preview: {s}
        \\  preview_truncated: {s}
        \\  acked: {s}
        \\  reclaim_mode: {s}
        \\  reclaim_next_start: {s}
        \\
    ,
        .{ message_id, once_result.task_size, preview, truncated, acked, reclaim_mode, reclaim_next_start },
    );
    defer allocator.free(summary);
    try stdout.writeAll(summary);
}

fn runComponent(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    python_executable: []const u8,
    component: Component,
    forwarded_args: []const []const u8,
) !u8 {
    return python_bridge.run(.{
        .allocator = allocator,
        .project_root = project_root,
        .python_executable = python_executable,
        .component_cwd = component.component_cwd,
        .python_module = component.python_module,
        .pythonpath = component.pythonpath,
        .forward_args = forwarded_args,
    });
}

fn printBanner(metadata: metadata_mod.Metadata) void {
    std.debug.print("AI Verify (Zig compatibility runtime)\n", .{});
    std.debug.print("Name: {s}\n", .{metadata.name});
    std.debug.print("Version: {s}\n", .{metadata.version});
    std.debug.print("Author: {s}\n", .{metadata.author});
    std.debug.print("License: {s}\n", .{metadata.license});
    std.debug.print("Description: {s}\n\n", .{metadata.description});
}

fn printUsage(argv0: []const u8) void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  {s} components\n", .{argv0});
    std.debug.print("  {s} run <apigw|test-engine|worker> [args...]\n", .{argv0});
    std.debug.print("  {s} <apigw|test-engine|worker> [args...]\n", .{argv0});
    std.debug.print("  {s} test-engine-version\n", .{argv0});
    std.debug.print("  {s} apigw-config\n", .{argv0});
    std.debug.print("  {s} apigw-validate-gid-cid <value>\n", .{argv0});
    std.debug.print("  {s} apigw-check-valid-filename <filename>\n", .{argv0});
    std.debug.print("  {s} apigw-sanitize-filename <filename>\n", .{argv0});
    std.debug.print("  {s} apigw-check-relative-to-base <base> <filepath>\n", .{argv0});
    std.debug.print("  {s} apigw-check-file-size <bytes>\n", .{argv0});
    std.debug.print("  {s} apigw-append-filename <filename> <append>\n", .{argv0});
    std.debug.print("  {s} apigw-get-suffix <filename>\n", .{argv0});
    std.debug.print("  {s} apigw-get-stem <filename>\n", .{argv0});
    std.debug.print("  {s} apigw-plugin-storage-layout <local|prefix|s3> <base_plugin_dir> <gid> <cid>\n", .{argv0});
    std.debug.print(
        "  {s} apigw-data-storage-layout <local|s3> <base_artifacts_dir> <base_models_dir> <base_dataset_dir> <test_result_id> <filename> <subfolder-or-->\n",
        .{argv0},
    );
    std.debug.print("  {s} apigw-save-artifact <base_artifacts_dir> <test_result_id> <filename> <payload>\n", .{argv0});
    std.debug.print("  {s} apigw-get-artifact <base_artifacts_dir> <test_result_id> <filename>\n", .{argv0});
    std.debug.print("  {s} apigw-save-model-local <base_models_dir> <source_path>\n", .{argv0});
    std.debug.print("  {s} apigw-get-model-local <base_models_dir> <filename>\n", .{argv0});
    std.debug.print("  {s} apigw-delete-model-local <base_models_dir> <filename>\n", .{argv0});
    std.debug.print("  {s} apigw-save-dataset-local <base_dataset_dir> <source_path>\n", .{argv0});
    std.debug.print("  {s} apigw-get-dataset-local <base_dataset_dir> <filename>\n", .{argv0});
    std.debug.print("  {s} apigw-delete-dataset-local <base_dataset_dir> <filename>\n", .{argv0});
    std.debug.print("  {s} apigw-save-plugin-local <base_plugin_dir> <gid> <source_path>\n", .{argv0});
    std.debug.print("  {s} apigw-save-plugin-algorithm-local <base_plugin_dir> <gid> <cid> <source_path>\n", .{argv0});
    std.debug.print("  {s} apigw-save-plugin-widgets-local <base_plugin_dir> <gid> <source_path>\n", .{argv0});
    std.debug.print("  {s} apigw-save-plugin-inputs-local <base_plugin_dir> <gid> <source_path>\n", .{argv0});
    std.debug.print("  {s} apigw-save-plugin-mdx-bundles-local <base_plugin_dir> <gid> <source_path>\n", .{argv0});
    std.debug.print("  {s} apigw-backup-plugin-local <base_plugin_dir> <gid> <target_dir>\n", .{argv0});
    std.debug.print("  {s} apigw-get-plugin-zip-local <base_plugin_dir> <gid>\n", .{argv0});
    std.debug.print("  {s} apigw-get-plugin-algorithm-zip-local <base_plugin_dir> <gid> <cid>\n", .{argv0});
    std.debug.print("  {s} apigw-get-plugin-widgets-zip-local <base_plugin_dir> <gid>\n", .{argv0});
    std.debug.print("  {s} apigw-get-plugin-inputs-zip-local <base_plugin_dir> <gid>\n", .{argv0});
    std.debug.print("  {s} apigw-get-plugin-mdx-bundle-local <base_plugin_dir> <gid> <cid>\n", .{argv0});
    std.debug.print("  {s} apigw-get-plugin-mdx-summary-bundle-local <base_plugin_dir> <gid> <cid>\n", .{argv0});
    std.debug.print("  {s} apigw-delete-plugin-local <base_plugin_dir> <gid>\n", .{argv0});
    std.debug.print("  {s} worker-config\n", .{argv0});
    std.debug.print("  {s} worker-once [--ack] [--reclaim] [--min-idle-ms <ms>] [--start <id>]\n", .{argv0});
    std.debug.print("  {s} metrics-gap <reference> <candidate>\n", .{argv0});
    std.debug.print("  {s} normalize-plugin-gid <text>\n", .{argv0});
    std.debug.print("  {s} --version\n", .{argv0});
    std.debug.print("\n", .{});
    std.debug.print(
        "Default behavior forwards execution to Python modules while Zig/Mojo internals are ported incrementally.\n",
        .{},
    );
}

fn printApigwHelperUsage(argv0: []const u8) void {
    std.debug.print("Usage: {s} apigw-validate-gid-cid <value>\n", .{argv0});
    std.debug.print("   or: {s} apigw validate-gid-cid <value>\n", .{argv0});
    std.debug.print("Usage: {s} apigw-check-valid-filename <filename>\n", .{argv0});
    std.debug.print("   or: {s} apigw check-valid-filename <filename>\n", .{argv0});
    std.debug.print("Usage: {s} apigw-sanitize-filename <filename>\n", .{argv0});
    std.debug.print("   or: {s} apigw sanitize-filename <filename>\n", .{argv0});
    std.debug.print("Usage: {s} apigw-check-relative-to-base <base> <filepath>\n", .{argv0});
    std.debug.print("   or: {s} apigw check-relative-to-base <base> <filepath>\n", .{argv0});
    std.debug.print("Usage: {s} apigw-check-file-size <bytes>\n", .{argv0});
    std.debug.print("   or: {s} apigw check-file-size <bytes>\n", .{argv0});
    std.debug.print("Usage: {s} apigw-append-filename <filename> <append>\n", .{argv0});
    std.debug.print("   or: {s} apigw append-filename <filename> <append>\n", .{argv0});
    std.debug.print("Usage: {s} apigw-get-suffix <filename>\n", .{argv0});
    std.debug.print("   or: {s} apigw get-suffix <filename>\n", .{argv0});
    std.debug.print("Usage: {s} apigw-get-stem <filename>\n", .{argv0});
    std.debug.print("   or: {s} apigw get-stem <filename>\n", .{argv0});
    std.debug.print(
        "Usage: {s} apigw-plugin-storage-layout <local|prefix|s3> <base_plugin_dir> <gid> <cid>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw plugin-storage-layout <local|prefix|s3> <base_plugin_dir> <gid> <cid>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-data-storage-layout <local|s3> <base_artifacts_dir> <base_models_dir> <base_dataset_dir> <test_result_id> <filename> <subfolder-or-->\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw data-storage-layout <local|s3> <base_artifacts_dir> <base_models_dir> <base_dataset_dir> <test_result_id> <filename> <subfolder-or-->\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-save-artifact <base_artifacts_dir> <test_result_id> <filename> <payload>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw save-artifact <base_artifacts_dir> <test_result_id> <filename> <payload>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-get-artifact <base_artifacts_dir> <test_result_id> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw get-artifact <base_artifacts_dir> <test_result_id> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-save-model-local <base_models_dir> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw save-model-local <base_models_dir> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-get-model-local <base_models_dir> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw get-model-local <base_models_dir> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-delete-model-local <base_models_dir> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw delete-model-local <base_models_dir> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-save-dataset-local <base_dataset_dir> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw save-dataset-local <base_dataset_dir> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-get-dataset-local <base_dataset_dir> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw get-dataset-local <base_dataset_dir> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-delete-dataset-local <base_dataset_dir> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw delete-dataset-local <base_dataset_dir> <filename>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-save-plugin-local <base_plugin_dir> <gid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw save-plugin-local <base_plugin_dir> <gid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-save-plugin-algorithm-local <base_plugin_dir> <gid> <cid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw save-plugin-algorithm-local <base_plugin_dir> <gid> <cid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-save-plugin-widgets-local <base_plugin_dir> <gid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw save-plugin-widgets-local <base_plugin_dir> <gid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-save-plugin-inputs-local <base_plugin_dir> <gid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw save-plugin-inputs-local <base_plugin_dir> <gid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-save-plugin-mdx-bundles-local <base_plugin_dir> <gid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw save-plugin-mdx-bundles-local <base_plugin_dir> <gid> <source_path>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-backup-plugin-local <base_plugin_dir> <gid> <target_dir>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw backup-plugin-local <base_plugin_dir> <gid> <target_dir>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-get-plugin-zip-local <base_plugin_dir> <gid>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw get-plugin-zip-local <base_plugin_dir> <gid>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-get-plugin-algorithm-zip-local <base_plugin_dir> <gid> <cid>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw get-plugin-algorithm-zip-local <base_plugin_dir> <gid> <cid>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-get-plugin-widgets-zip-local <base_plugin_dir> <gid>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw get-plugin-widgets-zip-local <base_plugin_dir> <gid>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-get-plugin-inputs-zip-local <base_plugin_dir> <gid>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw get-plugin-inputs-zip-local <base_plugin_dir> <gid>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-get-plugin-mdx-bundle-local <base_plugin_dir> <gid> <cid>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw get-plugin-mdx-bundle-local <base_plugin_dir> <gid> <cid>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-get-plugin-mdx-summary-bundle-local <base_plugin_dir> <gid> <cid>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw get-plugin-mdx-summary-bundle-local <base_plugin_dir> <gid> <cid>\n",
        .{argv0},
    );
    std.debug.print(
        "Usage: {s} apigw-delete-plugin-local <base_plugin_dir> <gid>\n",
        .{argv0},
    );
    std.debug.print(
        "   or: {s} apigw delete-plugin-local <base_plugin_dir> <gid>\n",
        .{argv0},
    );
}

fn findComponent(name: []const u8) ?Component {
    for (components) |component| {
        if (std.mem.eql(u8, name, component.name)) {
            return component;
        }
    }
    return null;
}

fn getenvOrDefault(name: []const u8, default_value: []const u8) []const u8 {
    const maybe_value = std.posix.getenv(name);
    return if (maybe_value) |value| value else default_value;
}

fn findProjectRoot(allocator: std.mem.Allocator) ![]u8 {
    var current = try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(current);

    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        if (try isAiverifyProjectRoot(allocator, current)) {
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return error.ProjectRootNotFound;
}

fn isAiverifyProjectRoot(allocator: std.mem.Allocator, candidate: []const u8) !bool {
    const apigw = try std.fs.path.join(allocator, &.{ candidate, "aiverify-apigw" });
    defer allocator.free(apigw);
    const test_engine = try std.fs.path.join(allocator, &.{ candidate, "aiverify-test-engine" });
    defer allocator.free(test_engine);
    const worker = try std.fs.path.join(allocator, &.{ candidate, "aiverify-test-engine-worker" });
    defer allocator.free(worker);
    return pathExists(apigw) and pathExists(test_engine) and pathExists(worker);
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "findComponent resolves known command" {
    try std.testing.expect(findComponent("worker") != null);
    try std.testing.expect(findComponent("unknown-component") == null);
}
