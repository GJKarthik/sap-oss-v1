const std = @import("std");

pub const ApigwConfigError = error{
    InvalidApigwPort,
    OutOfMemory,
};

pub const ApigwAction = enum {
    config,
    validate_gid_cid,
    check_valid_filename,
    sanitize_filename,
    check_relative_to_base,
    check_file_size,
    append_filename,
    get_suffix,
    get_stem,
    plugin_storage_layout,
    data_storage_layout,
    save_artifact,
    get_artifact,
    save_model_local,
    get_model_local,
    delete_model_local,
    save_dataset_local,
    get_dataset_local,
    delete_dataset_local,
    save_plugin_local,
    save_plugin_algorithm_local,
    save_plugin_widgets_local,
    save_plugin_inputs_local,
    save_plugin_mdx_bundles_local,
    backup_plugin_local,
    get_plugin_zip_local,
    get_plugin_algorithm_zip_local,
    get_plugin_widgets_zip_local,
    get_plugin_inputs_zip_local,
    get_plugin_mdx_bundle_local,
    get_plugin_mdx_summary_bundle_local,
    delete_plugin_local,
    usage_error,
    pass_through,
};

pub const PluginStorageMode = enum {
    local,
    prefix,
    s3,
};

pub const DataStorageMode = enum {
    local,
    s3,
};

pub const ApigwInvocation = struct {
    action: ApigwAction = .pass_through,
    gid_cid_value: []const u8 = "",
    filename_value: []const u8 = "",
    base_path_value: []const u8 = "",
    filepath_value: []const u8 = "",
    size_value: []const u8 = "",
    append_name_value: []const u8 = "",
    storage_mode_value: []const u8 = "",
    plugin_base_value: []const u8 = "",
    plugin_gid_value: []const u8 = "",
    plugin_cid_value: []const u8 = "",
    artifacts_base_value: []const u8 = "",
    models_base_value: []const u8 = "",
    dataset_base_value: []const u8 = "",
    test_result_id_value: []const u8 = "",
    subfolder_value: []const u8 = "",
    payload_value: []const u8 = "",
    source_path_value: []const u8 = "",
    target_path_value: []const u8 = "",
};

pub const ApigwConfig = struct {
    host: []const u8,
    port: u16,
    data_dir: []u8,
    db_uri: []u8,
    valkey_host: []const u8,
    valkey_port: u16,
    log_level: ?[]const u8,

    pub fn deinit(self: *ApigwConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.data_dir);
        allocator.free(self.db_uri);
    }
};

pub fn classifyArgs(args: []const []const u8) ApigwAction {
    return classifyInvocation(args).action;
}

pub fn classifyInvocation(args: []const []const u8) ApigwInvocation {
    if (args.len == 1) {
        const arg = args[0];
        if (std.mem.eql(u8, arg, "config") or
            std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "preflight") or
            std.mem.eql(u8, arg, "--preflight"))
        {
            return .{ .action = .config };
        }
    }

    if (args.len >= 1) {
        const arg = args[0];
        if (std.mem.eql(u8, arg, "validate-gid-cid") or std.mem.eql(u8, arg, "--validate-gid-cid")) {
            if (args.len == 2 and args[1].len > 0) {
                return .{
                    .action = .validate_gid_cid,
                    .gid_cid_value = args[1],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "check-valid-filename") or std.mem.eql(u8, arg, "--check-valid-filename")) {
            if (args.len == 2) {
                return .{
                    .action = .check_valid_filename,
                    .filename_value = args[1],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "sanitize-filename") or std.mem.eql(u8, arg, "--sanitize-filename")) {
            if (args.len == 2) {
                return .{
                    .action = .sanitize_filename,
                    .filename_value = args[1],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "check-relative-to-base") or std.mem.eql(u8, arg, "--check-relative-to-base")) {
            if (args.len == 3) {
                return .{
                    .action = .check_relative_to_base,
                    .base_path_value = args[1],
                    .filepath_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "check-file-size") or std.mem.eql(u8, arg, "--check-file-size")) {
            if (args.len == 2) {
                return .{
                    .action = .check_file_size,
                    .size_value = args[1],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "append-filename") or std.mem.eql(u8, arg, "--append-filename")) {
            if (args.len == 3) {
                return .{
                    .action = .append_filename,
                    .filename_value = args[1],
                    .append_name_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-suffix") or std.mem.eql(u8, arg, "--get-suffix")) {
            if (args.len == 2) {
                return .{
                    .action = .get_suffix,
                    .filename_value = args[1],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-stem") or std.mem.eql(u8, arg, "--get-stem")) {
            if (args.len == 2) {
                return .{
                    .action = .get_stem,
                    .filename_value = args[1],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "plugin-storage-layout") or std.mem.eql(u8, arg, "--plugin-storage-layout")) {
            if (args.len == 5) {
                return .{
                    .action = .plugin_storage_layout,
                    .storage_mode_value = args[1],
                    .plugin_base_value = args[2],
                    .plugin_gid_value = args[3],
                    .plugin_cid_value = args[4],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "data-storage-layout") or std.mem.eql(u8, arg, "--data-storage-layout")) {
            if (args.len == 8) {
                return .{
                    .action = .data_storage_layout,
                    .storage_mode_value = args[1],
                    .artifacts_base_value = args[2],
                    .models_base_value = args[3],
                    .dataset_base_value = args[4],
                    .test_result_id_value = args[5],
                    .filename_value = args[6],
                    .subfolder_value = args[7],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "save-artifact") or std.mem.eql(u8, arg, "--save-artifact")) {
            if (args.len == 5) {
                return .{
                    .action = .save_artifact,
                    .artifacts_base_value = args[1],
                    .test_result_id_value = args[2],
                    .filename_value = args[3],
                    .payload_value = args[4],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-artifact") or std.mem.eql(u8, arg, "--get-artifact")) {
            if (args.len == 4) {
                return .{
                    .action = .get_artifact,
                    .artifacts_base_value = args[1],
                    .test_result_id_value = args[2],
                    .filename_value = args[3],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "save-model-local") or std.mem.eql(u8, arg, "--save-model-local")) {
            if (args.len == 3) {
                return .{
                    .action = .save_model_local,
                    .models_base_value = args[1],
                    .source_path_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-model-local") or std.mem.eql(u8, arg, "--get-model-local")) {
            if (args.len == 3) {
                return .{
                    .action = .get_model_local,
                    .models_base_value = args[1],
                    .filename_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "delete-model-local") or std.mem.eql(u8, arg, "--delete-model-local")) {
            if (args.len == 3) {
                return .{
                    .action = .delete_model_local,
                    .models_base_value = args[1],
                    .filename_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "save-dataset-local") or std.mem.eql(u8, arg, "--save-dataset-local")) {
            if (args.len == 3) {
                return .{
                    .action = .save_dataset_local,
                    .dataset_base_value = args[1],
                    .source_path_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-dataset-local") or std.mem.eql(u8, arg, "--get-dataset-local")) {
            if (args.len == 3) {
                return .{
                    .action = .get_dataset_local,
                    .dataset_base_value = args[1],
                    .filename_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "delete-dataset-local") or std.mem.eql(u8, arg, "--delete-dataset-local")) {
            if (args.len == 3) {
                return .{
                    .action = .delete_dataset_local,
                    .dataset_base_value = args[1],
                    .filename_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "save-plugin-local") or std.mem.eql(u8, arg, "--save-plugin-local")) {
            if (args.len == 4) {
                return .{
                    .action = .save_plugin_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                    .source_path_value = args[3],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "save-plugin-algorithm-local") or std.mem.eql(u8, arg, "--save-plugin-algorithm-local")) {
            if (args.len == 5) {
                return .{
                    .action = .save_plugin_algorithm_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                    .plugin_cid_value = args[3],
                    .source_path_value = args[4],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "save-plugin-widgets-local") or std.mem.eql(u8, arg, "--save-plugin-widgets-local")) {
            if (args.len == 4) {
                return .{
                    .action = .save_plugin_widgets_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                    .source_path_value = args[3],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "save-plugin-inputs-local") or std.mem.eql(u8, arg, "--save-plugin-inputs-local")) {
            if (args.len == 4) {
                return .{
                    .action = .save_plugin_inputs_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                    .source_path_value = args[3],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "save-plugin-mdx-bundles-local") or std.mem.eql(u8, arg, "--save-plugin-mdx-bundles-local")) {
            if (args.len == 4) {
                return .{
                    .action = .save_plugin_mdx_bundles_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                    .source_path_value = args[3],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "backup-plugin-local") or std.mem.eql(u8, arg, "--backup-plugin-local")) {
            if (args.len == 4) {
                return .{
                    .action = .backup_plugin_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                    .target_path_value = args[3],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-plugin-zip-local") or std.mem.eql(u8, arg, "--get-plugin-zip-local")) {
            if (args.len == 3) {
                return .{
                    .action = .get_plugin_zip_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-plugin-algorithm-zip-local") or std.mem.eql(u8, arg, "--get-plugin-algorithm-zip-local")) {
            if (args.len == 4) {
                return .{
                    .action = .get_plugin_algorithm_zip_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                    .plugin_cid_value = args[3],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-plugin-widgets-zip-local") or std.mem.eql(u8, arg, "--get-plugin-widgets-zip-local")) {
            if (args.len == 3) {
                return .{
                    .action = .get_plugin_widgets_zip_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-plugin-inputs-zip-local") or std.mem.eql(u8, arg, "--get-plugin-inputs-zip-local")) {
            if (args.len == 3) {
                return .{
                    .action = .get_plugin_inputs_zip_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-plugin-mdx-bundle-local") or std.mem.eql(u8, arg, "--get-plugin-mdx-bundle-local")) {
            if (args.len == 4) {
                return .{
                    .action = .get_plugin_mdx_bundle_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                    .plugin_cid_value = args[3],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "get-plugin-mdx-summary-bundle-local") or std.mem.eql(u8, arg, "--get-plugin-mdx-summary-bundle-local")) {
            if (args.len == 4) {
                return .{
                    .action = .get_plugin_mdx_summary_bundle_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                    .plugin_cid_value = args[3],
                };
            }
            return .{ .action = .usage_error };
        }
        if (std.mem.eql(u8, arg, "delete-plugin-local") or std.mem.eql(u8, arg, "--delete-plugin-local")) {
            if (args.len == 3) {
                return .{
                    .action = .delete_plugin_local,
                    .plugin_base_value = args[1],
                    .plugin_gid_value = args[2],
                };
            }
            return .{ .action = .usage_error };
        }
    }

    return .{ .action = .pass_through };
}

pub fn validateGidCid(value: []const u8) bool {
    if (value.len == 0) return false;

    // Python re `^[a-zA-Z0-9][a-zA-Z0-9-._]*$` accepts a single trailing
    // '\n' because `$` can match before terminal newline.
    var core = value;
    if (core[core.len - 1] == '\n') {
        core = core[0 .. core.len - 1];
    }
    if (core.len == 0) return false;
    if (!isAsciiAlphaNumeric(core[0])) return false;

    for (core[1..]) |ch| {
        if (isAsciiAlphaNumeric(ch)) continue;
        if (ch == '-' or ch == '.' or ch == '_') continue;
        return false;
    }
    return true;
}

pub fn checkValidFilename(filename: []const u8) bool {
    if (std.mem.indexOf(u8, filename, "..") != null) return false;
    for (filename) |ch_raw| {
        const ch = if (ch_raw == '\\') '/' else ch_raw;
        if (isAsciiAlphaNumeric(ch)) continue;
        if (ch == '.' or ch == '_' or ch == '-' or ch == '/') continue;
        return false;
    }
    return true;
}

pub fn sanitizeFilenameAlloc(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    if (filename.len == 0 or !isAsciiAlphaNumeric(filename[0])) return error.InvalidFilename;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (filename) |ch| {
        if (isAsciiAlphaNumeric(ch) or ch == '.' or ch == '/' or ch == '_') {
            try output.append(allocator, ch);
        }
    }

    return output.toOwnedSlice(allocator);
}

pub fn checkRelativeToBase(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    filepath: []const u8,
) !bool {
    if (std.mem.startsWith(u8, base_path, "s3://")) {
        const resolved = try resolveS3Url(allocator, base_path, filepath);
        defer allocator.free(resolved);
        return std.mem.startsWith(u8, resolved, base_path);
    }

    if (!isAbsolutePath(filepath)) return true;
    return absolutePathIsRelativeToBase(filepath, base_path);
}

pub fn checkFileSize(size: i128) bool {
    return size <= 4_294_967_296;
}

pub fn appendFilenameAlloc(
    allocator: std.mem.Allocator,
    filename: []const u8,
    append_name: []const u8,
) ![]u8 {
    const split = splitPurePathStemSuffix(filename);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        split.stem,
        append_name,
        split.suffix,
    });
}

pub fn getSuffixAlloc(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const split = splitPurePathStemSuffix(filename);
    const suffix = try allocator.dupe(u8, split.suffix);
    _ = std.ascii.lowerString(suffix, suffix);
    return suffix;
}

pub fn getStem(filename: []const u8) []const u8 {
    const split = splitPurePathStemSuffix(filename);
    return split.stem;
}

pub fn renderPluginStorageLayoutAlloc(
    allocator: std.mem.Allocator,
    mode_raw: []const u8,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
) ![]u8 {
    const mode = try parsePluginStorageMode(mode_raw);

    const plugin_zip_name = try std.fmt.allocPrint(allocator, "{s}.zip", .{gid});
    defer allocator.free(plugin_zip_name);
    const plugin_hash_name = try std.fmt.allocPrint(allocator, "{s}.hash", .{gid});
    defer allocator.free(plugin_hash_name);
    const algorithm_zip_name = try std.fmt.allocPrint(allocator, "{s}.zip", .{cid});
    defer allocator.free(algorithm_zip_name);
    const algorithm_hash_name = try std.fmt.allocPrint(allocator, "{s}.hash", .{cid});
    defer allocator.free(algorithm_hash_name);

    const plugin_folder = switch (mode) {
        .local => try pathJoinAlloc(allocator, base_plugin_dir, gid),
        .prefix, .s3 => blk: {
            const gid_folder = try std.fmt.allocPrint(allocator, "{s}/", .{gid});
            defer allocator.free(gid_folder);
            break :blk try urlJoinLikeAlloc(allocator, base_plugin_dir, gid_folder);
        },
    };
    defer allocator.free(plugin_folder);

    const mdx_folder = switch (mode) {
        .local => try pathJoinAlloc(allocator, plugin_folder, "mdx_bundles"),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, plugin_folder, "mdx_bundles/"),
    };
    defer allocator.free(mdx_folder);

    const algorithms_folder = switch (mode) {
        .local => try pathJoinAlloc(allocator, plugin_folder, "algorithms"),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, plugin_folder, "algorithms/"),
    };
    defer allocator.free(algorithms_folder);

    const plugin_zip_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, plugin_folder, plugin_zip_name),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, plugin_folder, plugin_zip_name),
    };
    defer allocator.free(plugin_zip_path);

    const plugin_hash_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, plugin_folder, plugin_hash_name),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, plugin_folder, plugin_hash_name),
    };
    defer allocator.free(plugin_hash_path);

    const algorithm_zip_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, algorithms_folder, algorithm_zip_name),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, algorithms_folder, algorithm_zip_name),
    };
    defer allocator.free(algorithm_zip_path);

    const algorithm_hash_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, algorithms_folder, algorithm_hash_name),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, algorithms_folder, algorithm_hash_name),
    };
    defer allocator.free(algorithm_hash_path);

    const widgets_zip_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, plugin_folder, "widgets.zip"),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, plugin_folder, "widgets.zip"),
    };
    defer allocator.free(widgets_zip_path);

    const widgets_hash_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, plugin_folder, "widgets.hash"),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, plugin_folder, "widgets.hash"),
    };
    defer allocator.free(widgets_hash_path);

    const inputs_zip_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, plugin_folder, "inputs.zip"),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, plugin_folder, "inputs.zip"),
    };
    defer allocator.free(inputs_zip_path);

    const inputs_hash_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, plugin_folder, "inputs.hash"),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, plugin_folder, "inputs.hash"),
    };
    defer allocator.free(inputs_hash_path);

    const mdx_bundle_name = try std.fmt.allocPrint(allocator, "{s}.bundle.json", .{cid});
    defer allocator.free(mdx_bundle_name);
    const mdx_summary_name = try std.fmt.allocPrint(allocator, "{s}.summary.bundle.json", .{cid});
    defer allocator.free(mdx_summary_name);

    const mdx_bundle_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, mdx_folder, mdx_bundle_name),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, mdx_folder, mdx_bundle_name),
    };
    defer allocator.free(mdx_bundle_path);

    const mdx_summary_bundle_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, mdx_folder, mdx_summary_name),
        .prefix, .s3 => try urlJoinLikeAlloc(allocator, mdx_folder, mdx_summary_name),
    };
    defer allocator.free(mdx_summary_bundle_path);

    return std.fmt.allocPrint(
        allocator,
        \\APIGW plugin storage layout
        \\  mode: {s}
        \\  plugin_folder: {s}
        \\  mdx_bundles_folder: {s}
        \\  algorithms_folder: {s}
        \\  plugin_zip_path: {s}
        \\  plugin_hash_path: {s}
        \\  algorithm_zip_path: {s}
        \\  algorithm_hash_path: {s}
        \\  widgets_zip_path: {s}
        \\  widgets_hash_path: {s}
        \\  inputs_zip_path: {s}
        \\  inputs_hash_path: {s}
        \\  mdx_bundle_path: {s}
        \\  mdx_summary_bundle_path: {s}
    ,
        .{
            mode_raw,
            plugin_folder,
            mdx_folder,
            algorithms_folder,
            plugin_zip_path,
            plugin_hash_path,
            algorithm_zip_path,
            algorithm_hash_path,
            widgets_zip_path,
            widgets_hash_path,
            inputs_zip_path,
            inputs_hash_path,
            mdx_bundle_path,
            mdx_summary_bundle_path,
        },
    );
}

pub fn renderDataStorageLayoutAlloc(
    allocator: std.mem.Allocator,
    mode_raw: []const u8,
    base_artifacts_dir: []const u8,
    base_models_dir: []const u8,
    base_dataset_dir: []const u8,
    test_result_id: []const u8,
    filename: []const u8,
    subfolder_raw: []const u8,
) ![]u8 {
    const mode = try parseDataStorageMode(mode_raw);
    const subfolder: ?[]const u8 = if (subfolder_raw.len == 0 or (subfolder_raw.len == 1 and subfolder_raw[0] == '-'))
        null
    else
        subfolder_raw;

    const id_status = if (isAsciiAlphaNumericString(test_result_id)) "yes" else "no";
    const filename_status = if (checkValidFilename(filename)) "yes" else "no";

    const artifact_folder = switch (mode) {
        .local => try pathJoinAlloc(allocator, base_artifacts_dir, test_result_id),
        .s3 => blk: {
            const dir = try std.fmt.allocPrint(allocator, "{s}/", .{test_result_id});
            defer allocator.free(dir);
            break :blk try urlJoinLikeAlloc(allocator, base_artifacts_dir, dir);
        },
    };
    defer allocator.free(artifact_folder);

    const artifact_target_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, artifact_folder, filename),
        .s3 => try urlJoinLikeAlloc(allocator, artifact_folder, filename),
    };
    defer allocator.free(artifact_target_path);

    const artifact_relative_ok = if (try checkRelativeToBase(allocator, artifact_folder, filename)) "yes" else "no";

    const model_folder = if (subfolder) |value|
        switch (mode) {
            .local => try pathJoinAlloc(allocator, base_models_dir, value),
            .s3 => blk: {
                const dir = try std.fmt.allocPrint(allocator, "{s}/", .{value});
                defer allocator.free(dir);
                break :blk try urlJoinLikeAlloc(allocator, base_models_dir, dir);
            },
        }
    else
        try allocator.dupe(u8, base_models_dir);
    defer allocator.free(model_folder);

    const model_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, model_folder, filename),
        .s3 => try urlJoinLikeAlloc(allocator, model_folder, filename),
    };
    defer allocator.free(model_path);

    const model_relative_ok = if (try checkRelativeToBase(allocator, base_models_dir, filename)) "yes" else "no";

    const model_sidecar_zip_save_key = try allocSuffix(allocator, filename, ".zip");
    defer allocator.free(model_sidecar_zip_save_key);
    const model_sidecar_hash_save_key = try allocSuffix(allocator, filename, ".hash");
    defer allocator.free(model_sidecar_hash_save_key);

    const model_sidecar_zip_lookup = switch (mode) {
        .local => blk: {
            const parent = std.fs.path.dirname(model_path) orelse "";
            const name = purePathName(model_path);
            const zip_name = try allocSuffix(allocator, name, ".zip");
            defer allocator.free(zip_name);
            break :blk if (parent.len == 0)
                try allocator.dupe(u8, zip_name)
            else
                try pathJoinAlloc(allocator, parent, zip_name);
        },
        .s3 => try allocSuffix(allocator, model_path, ".zip"),
    };
    defer allocator.free(model_sidecar_zip_lookup);

    const model_sidecar_hash_lookup = switch (mode) {
        .local => blk: {
            const parent = std.fs.path.dirname(model_path) orelse "";
            const name = purePathName(model_path);
            const hash_name = try allocSuffix(allocator, name, ".hash");
            defer allocator.free(hash_name);
            break :blk if (parent.len == 0)
                try allocator.dupe(u8, hash_name)
            else
                try pathJoinAlloc(allocator, parent, hash_name);
        },
        .s3 => try allocSuffix(allocator, model_path, ".hash"),
    };
    defer allocator.free(model_sidecar_hash_lookup);

    const dataset_folder = if (subfolder) |value|
        switch (mode) {
            .local => try pathJoinAlloc(allocator, base_dataset_dir, value),
            .s3 => blk: {
                const dir = try std.fmt.allocPrint(allocator, "{s}/", .{value});
                defer allocator.free(dir);
                break :blk try urlJoinLikeAlloc(allocator, base_dataset_dir, dir);
            },
        }
    else
        try allocator.dupe(u8, base_dataset_dir);
    defer allocator.free(dataset_folder);

    const dataset_path = switch (mode) {
        .local => try pathJoinAlloc(allocator, dataset_folder, filename),
        .s3 => try urlJoinLikeAlloc(allocator, dataset_folder, filename),
    };
    defer allocator.free(dataset_path);

    const dataset_relative_ok = if (try checkRelativeToBase(allocator, base_dataset_dir, filename)) "yes" else "no";

    const dataset_sidecar_zip_save_key = try allocSuffix(allocator, filename, ".zip");
    defer allocator.free(dataset_sidecar_zip_save_key);
    const dataset_sidecar_hash_save_key = try allocSuffix(allocator, filename, ".hash");
    defer allocator.free(dataset_sidecar_hash_save_key);

    const dataset_sidecar_zip_lookup = switch (mode) {
        .local => blk: {
            const parent = std.fs.path.dirname(dataset_path) orelse "";
            const name = purePathName(dataset_path);
            const zip_name = try allocSuffix(allocator, name, ".zip");
            defer allocator.free(zip_name);
            break :blk if (parent.len == 0)
                try allocator.dupe(u8, zip_name)
            else
                try pathJoinAlloc(allocator, parent, zip_name);
        },
        .s3 => try allocSuffix(allocator, dataset_path, ".zip"),
    };
    defer allocator.free(dataset_sidecar_zip_lookup);

    const dataset_sidecar_hash_lookup = switch (mode) {
        .local => blk: {
            const parent = std.fs.path.dirname(dataset_path) orelse "";
            const name = purePathName(dataset_path);
            const hash_name = try allocSuffix(allocator, name, ".hash");
            defer allocator.free(hash_name);
            break :blk if (parent.len == 0)
                try allocator.dupe(u8, hash_name)
            else
                try pathJoinAlloc(allocator, parent, hash_name);
        },
        .s3 => try allocSuffix(allocator, dataset_path, ".hash"),
    };
    defer allocator.free(dataset_sidecar_hash_lookup);

    const subfolder_value = subfolder orelse "<none>";
    return std.fmt.allocPrint(
        allocator,
        \\APIGW data storage layout
        \\  mode: {s}
        \\  subfolder: {s}
        \\  valid_test_result_id: {s}
        \\  valid_filename: {s}
        \\  artifact_folder: {s}
        \\  artifact_target_path: {s}
        \\  artifact_relative_guard: {s}
        \\  model_folder: {s}
        \\  model_path: {s}
        \\  model_relative_guard: {s}
        \\  model_sidecar_zip_save_key: {s}
        \\  model_sidecar_hash_save_key: {s}
        \\  model_sidecar_zip_lookup: {s}
        \\  model_sidecar_hash_lookup: {s}
        \\  dataset_folder: {s}
        \\  dataset_path: {s}
        \\  dataset_relative_guard: {s}
        \\  dataset_sidecar_zip_save_key: {s}
        \\  dataset_sidecar_hash_save_key: {s}
        \\  dataset_sidecar_zip_lookup: {s}
        \\  dataset_sidecar_hash_lookup: {s}
    ,
        .{
            mode_raw,
            subfolder_value,
            id_status,
            filename_status,
            artifact_folder,
            artifact_target_path,
            artifact_relative_ok,
            model_folder,
            model_path,
            model_relative_ok,
            model_sidecar_zip_save_key,
            model_sidecar_hash_save_key,
            model_sidecar_zip_lookup,
            model_sidecar_hash_lookup,
            dataset_folder,
            dataset_path,
            dataset_relative_ok,
            dataset_sidecar_zip_save_key,
            dataset_sidecar_hash_save_key,
            dataset_sidecar_zip_lookup,
            dataset_sidecar_hash_lookup,
        },
    );
}

pub fn saveArtifactLocalAlloc(
    allocator: std.mem.Allocator,
    base_artifacts_dir: []const u8,
    test_result_id: []const u8,
    filename: []const u8,
    data: []const u8,
) ![]u8 {
    if (!isAsciiAlphaNumericString(test_result_id)) return error.InvalidTestResultId;
    if (!checkValidFilename(filename)) return error.InvalidFilename;

    const artifact_folder = try pathJoinAlloc(allocator, base_artifacts_dir, test_result_id);
    defer allocator.free(artifact_folder);
    try std.fs.cwd().makePath(artifact_folder);

    if (!(try checkRelativeToBase(allocator, artifact_folder, filename))) {
        return error.InvalidFilename;
    }

    const artifact_path = try pathJoinAlloc(allocator, artifact_folder, filename);
    errdefer allocator.free(artifact_path);

    const parent = std.fs.path.dirname(artifact_path) orelse "";
    if (parent.len > 0) {
        try std.fs.cwd().makePath(parent);
    }

    var file = try std.fs.cwd().createFile(artifact_path, .{});
    defer file.close();
    try file.writeAll(data);
    return artifact_path;
}

pub fn getArtifactLocalAlloc(
    allocator: std.mem.Allocator,
    base_artifacts_dir: []const u8,
    test_result_id: []const u8,
    filename: []const u8,
) ![]u8 {
    if (!isAsciiAlphaNumericString(test_result_id)) return error.InvalidTestResultId;
    if (!checkValidFilename(filename)) return error.InvalidFilename;

    const artifact_folder = try pathJoinAlloc(allocator, base_artifacts_dir, test_result_id);
    defer allocator.free(artifact_folder);
    if (!(try checkRelativeToBase(allocator, artifact_folder, filename))) {
        return error.InvalidFilename;
    }

    const artifact_path = try pathJoinAlloc(allocator, artifact_folder, filename);
    defer allocator.free(artifact_path);

    var file = std.fs.cwd().openFile(artifact_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ArtifactNotFound,
        else => return err,
    };
    defer file.close();
    return file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

pub const LocalStoreSaveResult = struct {
    target_path: []u8,
    sha256_hex: []u8,

    pub fn deinit(self: *LocalStoreSaveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.target_path);
        allocator.free(self.sha256_hex);
    }
};

pub fn saveModelLocalAlloc(
    allocator: std.mem.Allocator,
    base_models_dir: []const u8,
    source_path: []const u8,
) !LocalStoreSaveResult {
    return saveLocalFileToBaseAlloc(allocator, base_models_dir, source_path);
}

pub fn getModelLocalAlloc(
    allocator: std.mem.Allocator,
    base_models_dir: []const u8,
    filename: []const u8,
) ![]u8 {
    return getLocalFileFromBaseAlloc(allocator, base_models_dir, filename) catch |err| switch (err) {
        error.FileNotFound => return error.ModelNotFound,
        else => return err,
    };
}

pub fn deleteModelLocal(
    allocator: std.mem.Allocator,
    base_models_dir: []const u8,
    filename: []const u8,
) !bool {
    return deleteLocalFileFromBase(allocator, base_models_dir, filename);
}

pub fn saveDatasetLocalAlloc(
    allocator: std.mem.Allocator,
    base_dataset_dir: []const u8,
    source_path: []const u8,
) !LocalStoreSaveResult {
    return saveLocalFileToBaseAlloc(allocator, base_dataset_dir, source_path);
}

pub fn getDatasetLocalAlloc(
    allocator: std.mem.Allocator,
    base_dataset_dir: []const u8,
    filename: []const u8,
) ![]u8 {
    return getLocalFileFromBaseAlloc(allocator, base_dataset_dir, filename) catch |err| switch (err) {
        error.FileNotFound => return error.DatasetNotFound,
        else => return err,
    };
}

pub fn deleteDatasetLocal(
    allocator: std.mem.Allocator,
    base_dataset_dir: []const u8,
    filename: []const u8,
) !bool {
    return deleteLocalFileFromBase(allocator, base_dataset_dir, filename);
}

const PluginArchiveKind = enum {
    plugin,
    algorithm,
    widgets,
    inputs,
};

pub const PluginArchiveSaveResult = struct {
    zip_path: []u8,
    hash_path: []u8,
    sha256_hex: []u8,

    pub fn deinit(self: *PluginArchiveSaveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.zip_path);
        allocator.free(self.hash_path);
        allocator.free(self.sha256_hex);
    }
};

pub fn savePluginLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    source_path: []const u8,
) !PluginArchiveSaveResult {
    return savePluginArchiveLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        "",
        source_path,
        .plugin,
    );
}

pub fn savePluginAlgorithmLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
    source_path: []const u8,
) !PluginArchiveSaveResult {
    return savePluginArchiveLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        cid,
        source_path,
        .algorithm,
    );
}

pub fn savePluginWidgetsLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    source_path: []const u8,
) !PluginArchiveSaveResult {
    return savePluginArchiveLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        "",
        source_path,
        .widgets,
    );
}

pub fn savePluginInputsLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    source_path: []const u8,
) !PluginArchiveSaveResult {
    return savePluginArchiveLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        "",
        source_path,
        .inputs,
    );
}

pub fn savePluginMdxBundlesLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    source_path: []const u8,
) ![]u8 {
    if (!validateGidCid(gid)) return error.InvalidGid;

    var source_dir = std.fs.cwd().openDir(source_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SourceNotFound,
        error.NotDir => return error.SourceDirectoryUnsupported,
        else => return err,
    };
    source_dir.close();

    const source_name = purePathName(source_path);
    if (source_name.len == 0 or !checkValidFilename(source_name)) return error.InvalidFilename;

    const plugin_folder = try pathJoinAlloc(allocator, base_plugin_dir, gid);
    defer allocator.free(plugin_folder);
    const mdx_bundles_folder = try pathJoinAlloc(allocator, plugin_folder, "mdx_bundles");
    errdefer allocator.free(mdx_bundles_folder);

    try std.fs.cwd().makePath(mdx_bundles_folder);
    try copyDirectoryTreeLocal(allocator, source_path, mdx_bundles_folder);
    return mdx_bundles_folder;
}

pub fn backupPluginLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    target_dir: []const u8,
) ![]u8 {
    if (!validateGidCid(gid)) return error.InvalidGid;

    const plugin_folder = try pathJoinAlloc(allocator, base_plugin_dir, gid);
    defer allocator.free(plugin_folder);

    std.fs.cwd().access(plugin_folder, .{}) catch |source_err| switch (source_err) {
        error.FileNotFound => return error.PluginSourceNotFound,
        else => return source_err,
    };

    std.fs.cwd().deleteFile(target_dir) catch |delete_err| switch (delete_err) {
        error.FileNotFound => {},
        error.IsDir => try std.fs.cwd().deleteTree(target_dir),
        else => return delete_err,
    };

    try std.fs.cwd().makePath(target_dir);
    try copyDirectoryTreeLocalIgnoringPluginPattern(allocator, plugin_folder, target_dir);
    return allocator.dupe(u8, target_dir);
}

pub fn getPluginMdxBundleLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
    summary: bool,
) ![]u8 {
    if (!validateGidCid(gid)) return error.InvalidGid;
    if (!validateGidCid(cid)) return error.InvalidCid;

    const plugin_folder = try pathJoinAlloc(allocator, base_plugin_dir, gid);
    defer allocator.free(plugin_folder);
    const mdx_bundles_folder = try pathJoinAlloc(allocator, plugin_folder, "mdx_bundles");
    defer allocator.free(mdx_bundles_folder);

    const filename = if (summary)
        try std.fmt.allocPrint(allocator, "{s}.summary.bundle.json", .{cid})
    else
        try std.fmt.allocPrint(allocator, "{s}.bundle.json", .{cid});
    defer allocator.free(filename);
    if (!checkValidFilename(filename)) return error.InvalidFilename;

    const bundle_path = try pathJoinAlloc(allocator, mdx_bundles_folder, filename);
    defer allocator.free(bundle_path);

    var bundle_file = std.fs.cwd().openFile(bundle_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.PluginBundleNotFound,
        else => return err,
    };
    defer bundle_file.close();
    return bundle_file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

pub fn getPluginZipLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
) ![]u8 {
    return getPluginArchiveZipLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        "",
        .plugin,
    );
}

pub fn getPluginAlgorithmZipLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
) ![]u8 {
    return getPluginArchiveZipLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        cid,
        .algorithm,
    );
}

pub fn getPluginWidgetsZipLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
) ![]u8 {
    return getPluginArchiveZipLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        "",
        .widgets,
    );
}

pub fn getPluginInputsZipLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
) ![]u8 {
    return getPluginArchiveZipLocalAlloc(
        allocator,
        base_plugin_dir,
        gid,
        "",
        .inputs,
    );
}

pub fn deletePluginLocal(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
) !bool {
    if (!validateGidCid(gid)) return error.InvalidGid;
    const plugin_folder = try pathJoinAlloc(allocator, base_plugin_dir, gid);
    defer allocator.free(plugin_folder);

    std.fs.cwd().access(plugin_folder, .{}) catch |access_err| switch (access_err) {
        error.FileNotFound => return false,
        else => return access_err,
    };

    std.fs.cwd().deleteTree(plugin_folder) catch |err| switch (err) {
        error.NotDir => {
            std.fs.cwd().deleteFile(plugin_folder) catch |file_err| switch (file_err) {
                error.FileNotFound => return false,
                else => return file_err,
            };
            return true;
        },
        else => return err,
    };
    return true;
}

fn savePluginArchiveLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
    source_path: []const u8,
    kind: PluginArchiveKind,
) !PluginArchiveSaveResult {
    if (!validateGidCid(gid)) return error.InvalidGid;
    if (kind == .algorithm and !validateGidCid(cid)) return error.InvalidCid;

    var source_dir = std.fs.cwd().openDir(source_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SourceNotFound,
        error.NotDir => return error.SourceDirectoryUnsupported,
        else => return err,
    };
    source_dir.close();

    const source_name = purePathName(source_path);
    if (source_name.len == 0 or !checkValidFilename(source_name)) return error.InvalidFilename;

    const target_folder = try pluginArchiveFolderAlloc(allocator, base_plugin_dir, gid, kind);
    defer allocator.free(target_folder);
    try std.fs.cwd().makePath(target_folder);

    const zip_name = try pluginArchiveZipFilenameAlloc(allocator, kind, gid, cid);
    defer allocator.free(zip_name);
    const hash_name = try pluginArchiveHashFilenameAlloc(allocator, kind, gid, cid);
    defer allocator.free(hash_name);

    const zip_path = try pathJoinAlloc(allocator, target_folder, zip_name);
    errdefer allocator.free(zip_path);
    const sha256_hex = try writeDirectoryZipAndShaAlloc(allocator, source_path, zip_path);
    errdefer allocator.free(sha256_hex);

    const hash_path = try pathJoinAlloc(allocator, target_folder, hash_name);
    errdefer allocator.free(hash_path);
    var hash_file = try std.fs.cwd().createFile(hash_path, .{});
    defer hash_file.close();
    try hash_file.writeAll(sha256_hex);

    return .{
        .zip_path = zip_path,
        .hash_path = hash_path,
        .sha256_hex = sha256_hex,
    };
}

fn getPluginArchiveZipLocalAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    cid: []const u8,
    kind: PluginArchiveKind,
) ![]u8 {
    if (!validateGidCid(gid)) return error.InvalidGid;
    if (kind == .algorithm and !validateGidCid(cid)) return error.InvalidCid;

    const target_folder = try pluginArchiveFolderAlloc(allocator, base_plugin_dir, gid, kind);
    defer allocator.free(target_folder);
    const zip_name = try pluginArchiveZipFilenameAlloc(allocator, kind, gid, cid);
    defer allocator.free(zip_name);
    const zip_path = try pathJoinAlloc(allocator, target_folder, zip_name);
    defer allocator.free(zip_path);

    var zip_file = std.fs.cwd().openFile(zip_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.PluginArchiveNotFound,
        else => return err,
    };
    defer zip_file.close();
    return zip_file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn pluginArchiveFolderAlloc(
    allocator: std.mem.Allocator,
    base_plugin_dir: []const u8,
    gid: []const u8,
    kind: PluginArchiveKind,
) ![]u8 {
    const plugin_folder = try pathJoinAlloc(allocator, base_plugin_dir, gid);
    if (kind != .algorithm) return plugin_folder;

    const algorithm_folder = try pathJoinAlloc(allocator, plugin_folder, "algorithms");
    allocator.free(plugin_folder);
    return algorithm_folder;
}

fn pluginArchiveZipFilenameAlloc(
    allocator: std.mem.Allocator,
    kind: PluginArchiveKind,
    gid: []const u8,
    cid: []const u8,
) ![]u8 {
    return switch (kind) {
        .plugin => std.fmt.allocPrint(allocator, "{s}.zip", .{gid}),
        .algorithm => std.fmt.allocPrint(allocator, "{s}.zip", .{cid}),
        .widgets => allocator.dupe(u8, "widgets.zip"),
        .inputs => allocator.dupe(u8, "inputs.zip"),
    };
}

fn pluginArchiveHashFilenameAlloc(
    allocator: std.mem.Allocator,
    kind: PluginArchiveKind,
    gid: []const u8,
    cid: []const u8,
) ![]u8 {
    return switch (kind) {
        .plugin => std.fmt.allocPrint(allocator, "{s}.hash", .{gid}),
        .algorithm => std.fmt.allocPrint(allocator, "{s}.hash", .{cid}),
        .widgets => allocator.dupe(u8, "widgets.hash"),
        .inputs => allocator.dupe(u8, "inputs.hash"),
    };
}

fn saveLocalFileToBaseAlloc(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    source_path: []const u8,
) !LocalStoreSaveResult {
    const source_name = purePathName(source_path);
    if (source_name.len == 0 or !checkValidFilename(source_name)) return error.InvalidFilename;

    try std.fs.cwd().makePath(base_dir);
    const target_path = try pathJoinAlloc(allocator, base_dir, source_name);
    errdefer allocator.free(target_path);

    var source_dir = std.fs.cwd().openDir(source_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SourceNotFound,
        error.NotDir => return saveLocalRegularFileToBaseAlloc(allocator, source_path, target_path),
        else => return err,
    };
    source_dir.close();
    return saveLocalDirectoryToBaseAlloc(allocator, source_path, target_path);
}

fn getLocalFileFromBaseAlloc(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    filename: []const u8,
) ![]u8 {
    if (!checkValidFilename(filename)) return error.InvalidFilename;
    if (!(try checkRelativeToBase(allocator, base_dir, filename))) return error.InvalidFilename;

    try std.fs.cwd().makePath(base_dir);
    const target_path = try pathJoinAlloc(allocator, base_dir, filename);
    defer allocator.free(target_path);

    var target_file = std.fs.cwd().openFile(target_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.IsDir => return readDirectorySidecarAlloc(allocator, target_path),
        else => return err,
    };
    defer target_file.close();
    return target_file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |read_err| switch (read_err) {
        error.IsDir => return readDirectorySidecarAlloc(allocator, target_path),
        else => return read_err,
    };
}

fn deleteLocalFileFromBase(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    filename: []const u8,
) !bool {
    if (!(try checkRelativeToBase(allocator, base_dir, filename))) return error.InvalidFilename;

    try std.fs.cwd().makePath(base_dir);
    const target_path = try pathJoinAlloc(allocator, base_dir, filename);
    defer allocator.free(target_path);

    std.fs.cwd().deleteFile(target_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.IsDir => {
            try std.fs.cwd().deleteTree(target_path);

            const zip_sidecar_path = try sidecarPathAlloc(allocator, target_path, ".zip");
            defer allocator.free(zip_sidecar_path);
            std.fs.cwd().deleteFile(zip_sidecar_path) catch |zip_err| switch (zip_err) {
                error.FileNotFound => {},
                else => return zip_err,
            };

            const hash_sidecar_path = try sidecarPathAlloc(allocator, target_path, ".hash");
            defer allocator.free(hash_sidecar_path);
            std.fs.cwd().deleteFile(hash_sidecar_path) catch |hash_err| switch (hash_err) {
                error.FileNotFound => {},
                else => return hash_err,
            };
            return true;
        },
        else => return err,
    };
    return true;
}

fn saveLocalRegularFileToBaseAlloc(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    target_path: []u8,
) !LocalStoreSaveResult {
    var source_file = std.fs.cwd().openFile(source_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SourceNotFound,
        error.IsDir => return error.SourceDirectoryUnsupported,
        else => return err,
    };
    defer source_file.close();

    const parent = std.fs.path.dirname(target_path) orelse "";
    if (parent.len > 0) {
        try std.fs.cwd().makePath(parent);
    }
    var target_file = try std.fs.cwd().createFile(target_path, .{});
    defer target_file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    while (true) {
        const read_len = try source_file.read(&buffer);
        if (read_len == 0) break;
        const chunk = buffer[0..read_len];
        hasher.update(chunk);
        try target_file.writeAll(chunk);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    const sha256_hex = try allocator.dupe(u8, &encoded);
    errdefer allocator.free(sha256_hex);

    return .{
        .target_path = target_path,
        .sha256_hex = sha256_hex,
    };
}

fn saveLocalDirectoryToBaseAlloc(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    target_path: []u8,
) !LocalStoreSaveResult {
    try std.fs.cwd().makePath(target_path);
    try copyDirectoryTreeLocal(allocator, source_path, target_path);

    const zip_sidecar_path = try sidecarPathAlloc(allocator, target_path, ".zip");
    defer allocator.free(zip_sidecar_path);
    const sha256_hex = try writeDirectoryZipAndShaAlloc(allocator, source_path, zip_sidecar_path);
    errdefer allocator.free(sha256_hex);

    const hash_sidecar_path = try sidecarPathAlloc(allocator, target_path, ".hash");
    defer allocator.free(hash_sidecar_path);
    var hash_sidecar_file = try std.fs.cwd().createFile(hash_sidecar_path, .{});
    defer hash_sidecar_file.close();
    try hash_sidecar_file.writeAll(sha256_hex);

    return .{
        .target_path = target_path,
        .sha256_hex = sha256_hex,
    };
}

const DirectoryZipEntry = struct {
    path: []u8,
    is_directory: bool,
};

const DirectoryZipCentralRecord = struct {
    name: []const u8,
    is_directory: bool,
    crc32: u32,
    size: u32,
    local_header_offset: u32,
};

fn copyDirectoryTreeLocal(
    allocator: std.mem.Allocator,
    source_root_path: []const u8,
    target_root_path: []const u8,
) !void {
    var source_root_dir = try std.fs.cwd().openDir(source_root_path, .{ .iterate = true });
    defer source_root_dir.close();

    var walker = try source_root_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        const target_entry_path = try pathJoinAlloc(allocator, target_root_path, entry.path);
        defer allocator.free(target_entry_path);
        switch (entry.kind) {
            .directory => try std.fs.cwd().makePath(target_entry_path),
            .file => {
                const parent = std.fs.path.dirname(target_entry_path) orelse "";
                if (parent.len > 0) {
                    try std.fs.cwd().makePath(parent);
                }
                try source_root_dir.copyFile(entry.path, std.fs.cwd(), target_entry_path, .{});
            },
            else => {},
        }
    }
}

fn copyDirectoryTreeLocalIgnoringPluginPattern(
    allocator: std.mem.Allocator,
    source_root_path: []const u8,
    target_root_path: []const u8,
) !void {
    var source_root_dir = try std.fs.cwd().openDir(source_root_path, .{ .iterate = true });
    defer source_root_dir.close();

    var walker = try source_root_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (shouldIgnorePluginBackupPath(entry.path)) continue;

        const target_entry_path = try pathJoinAlloc(allocator, target_root_path, entry.path);
        defer allocator.free(target_entry_path);
        switch (entry.kind) {
            .directory => try std.fs.cwd().makePath(target_entry_path),
            .file => {
                const parent = std.fs.path.dirname(target_entry_path) orelse "";
                if (parent.len > 0) {
                    try std.fs.cwd().makePath(parent);
                }
                try source_root_dir.copyFile(entry.path, std.fs.cwd(), target_entry_path, .{});
            },
            else => {},
        }
    }
}

fn shouldIgnorePluginBackupPath(relative_path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, relative_path, "/\\");
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, ".venv") or
            std.mem.eql(u8, segment, "venv") or
            std.mem.eql(u8, segment, "output") or
            std.mem.eql(u8, segment, "node_modules") or
            std.mem.eql(u8, segment, "build") or
            std.mem.eql(u8, segment, "temp") or
            std.mem.eql(u8, segment, "__pycache__") or
            std.mem.eql(u8, segment, ".pytest_cache") or
            std.mem.eql(u8, segment, ".cache"))
        {
            return true;
        }
        if (std.mem.endsWith(u8, segment, ".pyc")) return true;
    }
    return false;
}

fn writeDirectoryZipAndShaAlloc(
    allocator: std.mem.Allocator,
    source_root_path: []const u8,
    zip_output_path: []const u8,
) ![]u8 {
    const entries = try collectDirectoryZipEntriesAlloc(allocator, source_root_path);
    defer {
        for (entries) |entry| allocator.free(entry.path);
        allocator.free(entries);
    }

    var source_root_dir = try std.fs.cwd().openDir(source_root_path, .{ .iterate = true });
    defer source_root_dir.close();

    var zip_file = try std.fs.cwd().createFile(zip_output_path, .{});
    defer zip_file.close();

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});

    var central_records: std.ArrayList(DirectoryZipCentralRecord) = .empty;
    defer central_records.deinit(allocator);

    var zip_offset: u64 = 0;
    for (entries) |entry| {
        if (zip_offset > std.math.maxInt(u32)) return error.SourceTooLarge;
        const local_header_offset: u32 = @intCast(zip_offset);

        if (entry.is_directory) {
            const written = try writeZipLocalHeader(
                &zip_file,
                &sha256,
                entry.path,
                0,
                0,
            );
            zip_offset += written;
            try central_records.append(allocator, .{
                .name = entry.path,
                .is_directory = true,
                .crc32 = 0,
                .size = 0,
                .local_header_offset = local_header_offset,
            });
            continue;
        }

        const file_meta = try computeFileCrc32AndSize(source_root_dir, entry.path);
        if (file_meta.size > std.math.maxInt(u32)) return error.SourceTooLarge;
        const size_u32: u32 = @intCast(file_meta.size);

        const local_written = try writeZipLocalHeader(
            &zip_file,
            &sha256,
            entry.path,
            file_meta.crc32,
            size_u32,
        );
        zip_offset += local_written;

        const content_written = try writeFileDataAndHash(source_root_dir, entry.path, &zip_file, &sha256);
        zip_offset += content_written;
        if (zip_offset > std.math.maxInt(u32)) return error.SourceTooLarge;

        try central_records.append(allocator, .{
            .name = entry.path,
            .is_directory = false,
            .crc32 = file_meta.crc32,
            .size = size_u32,
            .local_header_offset = local_header_offset,
        });
    }

    if (zip_offset > std.math.maxInt(u32)) return error.SourceTooLarge;
    const central_dir_offset: u32 = @intCast(zip_offset);

    for (central_records.items) |record| {
        const written = try writeZipCentralHeader(
            &zip_file,
            &sha256,
            record,
        );
        zip_offset += written;
        if (zip_offset > std.math.maxInt(u32)) return error.SourceTooLarge;
    }

    const central_dir_size_u64 = zip_offset - central_dir_offset;
    if (central_dir_size_u64 > std.math.maxInt(u32)) return error.SourceTooLarge;
    if (central_records.items.len > std.math.maxInt(u16)) return error.SourceTooLarge;

    const central_dir_size: u32 = @intCast(central_dir_size_u64);
    const record_count: u16 = @intCast(central_records.items.len);
    const end_written = try writeZipEndRecord(
        &zip_file,
        &sha256,
        record_count,
        central_dir_size,
        central_dir_offset,
    );
    zip_offset += end_written;

    var digest: [32]u8 = undefined;
    sha256.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn collectDirectoryZipEntriesAlloc(
    allocator: std.mem.Allocator,
    source_root_path: []const u8,
) ![]DirectoryZipEntry {
    var source_root_dir = try std.fs.cwd().openDir(source_root_path, .{ .iterate = true });
    defer source_root_dir.close();

    var walker = try source_root_dir.walk(allocator);
    defer walker.deinit();

    var entries: std.ArrayList(DirectoryZipEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory, .file => {
                if (entry.path.len == 0) continue;
                const normalized_path = try normalizeZipEntryPathAlloc(
                    allocator,
                    entry.path,
                    entry.kind == .directory,
                );
                try entries.append(allocator, .{
                    .path = normalized_path,
                    .is_directory = entry.kind == .directory,
                });
            },
            else => {},
        }
    }

    std.sort.block(DirectoryZipEntry, entries.items, {}, directoryZipEntryLessThan);
    return entries.toOwnedSlice(allocator);
}

fn directoryZipEntryLessThan(_: void, lhs: DirectoryZipEntry, rhs: DirectoryZipEntry) bool {
    return std.mem.order(u8, lhs.path, rhs.path) == .lt;
}

fn normalizeZipEntryPathAlloc(
    allocator: std.mem.Allocator,
    raw_path: []const u8,
    is_directory: bool,
) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);

    for (raw_path) |ch| {
        try normalized.append(allocator, if (ch == '\\') '/' else ch);
    }
    if (is_directory and (normalized.items.len == 0 or normalized.items[normalized.items.len - 1] != '/')) {
        try normalized.append(allocator, '/');
    }

    return normalized.toOwnedSlice(allocator);
}

fn writeZipLocalHeader(
    zip_file: *std.fs.File,
    sha256: *std.crypto.hash.sha2.Sha256,
    name: []const u8,
    crc32: u32,
    size: u32,
) !u64 {
    if (name.len > std.math.maxInt(u16)) return error.SourceTooLarge;

    var header: [30]u8 = [_]u8{0} ** 30;
    putU32Le(header[0..], 0, 0x04034B50);
    putU16Le(header[0..], 4, 20);
    putU16Le(header[0..], 6, 0);
    putU16Le(header[0..], 8, 0);
    putU16Le(header[0..], 10, 0);
    putU16Le(header[0..], 12, 0);
    putU32Le(header[0..], 14, crc32);
    putU32Le(header[0..], 18, size);
    putU32Le(header[0..], 22, size);
    putU16Le(header[0..], 26, @intCast(name.len));
    putU16Le(header[0..], 28, 0);

    try writeAndHash(zip_file, sha256, header[0..]);
    try writeAndHash(zip_file, sha256, name);
    return header.len + name.len;
}

fn writeZipCentralHeader(
    zip_file: *std.fs.File,
    sha256: *std.crypto.hash.sha2.Sha256,
    record: DirectoryZipCentralRecord,
) !u64 {
    if (record.name.len > std.math.maxInt(u16)) return error.SourceTooLarge;

    var header: [46]u8 = [_]u8{0} ** 46;
    putU32Le(header[0..], 0, 0x02014B50);
    putU16Le(header[0..], 4, 20);
    putU16Le(header[0..], 6, 20);
    putU16Le(header[0..], 8, 0);
    putU16Le(header[0..], 10, 0);
    putU16Le(header[0..], 12, 0);
    putU16Le(header[0..], 14, 0);
    putU32Le(header[0..], 16, record.crc32);
    putU32Le(header[0..], 20, record.size);
    putU32Le(header[0..], 24, record.size);
    putU16Le(header[0..], 28, @intCast(record.name.len));
    putU16Le(header[0..], 30, 0);
    putU16Le(header[0..], 32, 0);
    putU16Le(header[0..], 34, 0);
    putU16Le(header[0..], 36, 0);
    putU32Le(header[0..], 38, if (record.is_directory) 0x10 else 0);
    putU32Le(header[0..], 42, record.local_header_offset);

    try writeAndHash(zip_file, sha256, header[0..]);
    try writeAndHash(zip_file, sha256, record.name);
    return header.len + record.name.len;
}

fn writeZipEndRecord(
    zip_file: *std.fs.File,
    sha256: *std.crypto.hash.sha2.Sha256,
    record_count: u16,
    central_directory_size: u32,
    central_directory_offset: u32,
) !u64 {
    var header: [22]u8 = [_]u8{0} ** 22;
    putU32Le(header[0..], 0, 0x06054B50);
    putU16Le(header[0..], 4, 0);
    putU16Le(header[0..], 6, 0);
    putU16Le(header[0..], 8, record_count);
    putU16Le(header[0..], 10, record_count);
    putU32Le(header[0..], 12, central_directory_size);
    putU32Le(header[0..], 16, central_directory_offset);
    putU16Le(header[0..], 20, 0);

    try writeAndHash(zip_file, sha256, header[0..]);
    return header.len;
}

fn computeFileCrc32AndSize(source_root_dir: std.fs.Dir, relative_path: []const u8) !struct { crc32: u32, size: u64 } {
    var file = try source_root_dir.openFile(relative_path, .{});
    defer file.close();

    var crc = std.hash.Crc32.init();
    var size: u64 = 0;
    var buffer: [8192]u8 = undefined;
    while (true) {
        const read_len = try file.read(&buffer);
        if (read_len == 0) break;
        const chunk = buffer[0..read_len];
        crc.update(chunk);
        size += chunk.len;
        if (size > std.math.maxInt(u32)) return error.SourceTooLarge;
    }
    return .{
        .crc32 = crc.final(),
        .size = size,
    };
}

fn writeFileDataAndHash(
    source_root_dir: std.fs.Dir,
    relative_path: []const u8,
    zip_file: *std.fs.File,
    sha256: *std.crypto.hash.sha2.Sha256,
) !u64 {
    var file = try source_root_dir.openFile(relative_path, .{});
    defer file.close();

    var written: u64 = 0;
    var buffer: [8192]u8 = undefined;
    while (true) {
        const read_len = try file.read(&buffer);
        if (read_len == 0) break;
        const chunk = buffer[0..read_len];
        try writeAndHash(zip_file, sha256, chunk);
        written += chunk.len;
        if (written > std.math.maxInt(u32)) return error.SourceTooLarge;
    }
    return written;
}

fn sidecarPathAlloc(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) ![]u8 {
    return allocSuffix(allocator, path, suffix);
}

fn readDirectorySidecarAlloc(
    allocator: std.mem.Allocator,
    target_path: []const u8,
) ![]u8 {
    const zip_sidecar_path = try sidecarPathAlloc(allocator, target_path, ".zip");
    defer allocator.free(zip_sidecar_path);
    var zip_sidecar_file = std.fs.cwd().openFile(zip_sidecar_path, .{}) catch |zip_err| switch (zip_err) {
        error.FileNotFound => return error.FileNotFound,
        else => return zip_err,
    };
    defer zip_sidecar_file.close();
    return zip_sidecar_file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn writeAndHash(
    zip_file: *std.fs.File,
    sha256: *std.crypto.hash.sha2.Sha256,
    data: []const u8,
) !void {
    try zip_file.writeAll(data);
    sha256.update(data);
}

fn putU16Le(buffer: []u8, offset: usize, value: u16) void {
    buffer[offset] = @as(u8, @truncate(value));
    buffer[offset + 1] = @as(u8, @truncate(value >> 8));
}

fn putU32Le(buffer: []u8, offset: usize, value: u32) void {
    buffer[offset] = @as(u8, @truncate(value));
    buffer[offset + 1] = @as(u8, @truncate(value >> 8));
    buffer[offset + 2] = @as(u8, @truncate(value >> 16));
    buffer[offset + 3] = @as(u8, @truncate(value >> 24));
}

fn sha256HexAlloc(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

pub fn loadConfig(allocator: std.mem.Allocator, project_root: []const u8) !ApigwConfig {
    const port = parseApigwPort(std.posix.getenv("APIGW_PORT") orelse "4000") catch {
        return ApigwConfigError.InvalidApigwPort;
    };

    const data_dir = try resolveDataDir(allocator, project_root);
    errdefer allocator.free(data_dir);

    const db_uri = if (std.posix.getenv("APIGW_DB_URI")) |value|
        try allocator.dupe(u8, value)
    else
        try std.fmt.allocPrint(allocator, "sqlite:///{s}/database.db", .{data_dir});
    errdefer allocator.free(db_uri);

    const valkey_port = parseValkeyPortWithFallback(std.posix.getenv("VALKEY_PORT") orelse "6379");

    return .{
        .host = std.posix.getenv("APIGW_HOST_ADDRESS") orelse "127.0.0.1",
        .port = port,
        .data_dir = data_dir,
        .db_uri = db_uri,
        .valkey_host = std.posix.getenv("VALKEY_HOST_ADDRESS") orelse "127.0.0.1",
        .valkey_port = valkey_port,
        .log_level = optionalEnv("APIGW_LOG_LEVEL"),
    };
}

pub fn renderSummary(allocator: std.mem.Allocator, config: *const ApigwConfig) ![]u8 {
    const log_level = config.log_level orelse "<unset>";
    return std.fmt.allocPrint(
        allocator,
        \\API gateway startup preflight
        \\  host: {s}
        \\  port: {d}
        \\  data_dir: {s}
        \\  db_uri: {s}
        \\  valkey_host: {s}
        \\  valkey_port: {d}
        \\  log_level: {s}
    ,
        .{
            config.host,
            config.port,
            config.data_dir,
            config.db_uri,
            config.valkey_host,
            config.valkey_port,
            log_level,
        },
    );
}

fn resolveDataDir(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    if (std.posix.getenv("APIGW_DATA_DIR")) |value| {
        if (std.mem.startsWith(u8, value, "s3://")) {
            return allocator.dupe(u8, value);
        }

        try std.fs.cwd().makePath(value);
        const asset_dir = try std.fmt.allocPrint(allocator, "{s}/asset", .{value});
        defer allocator.free(asset_dir);
        try std.fs.cwd().makePath(asset_dir);
        return allocator.dupe(u8, value);
    }

    const data_dir = try std.fs.path.join(allocator, &.{ project_root, "aiverify-apigw", "data" });
    errdefer allocator.free(data_dir);

    try std.fs.cwd().makePath(data_dir);
    const asset_dir = try std.fs.path.join(allocator, &.{ data_dir, "asset" });
    defer allocator.free(asset_dir);
    try std.fs.cwd().makePath(asset_dir);
    return data_dir;
}

fn parseApigwPort(raw: []const u8) !u16 {
    const value = std.fmt.parseInt(u32, raw, 10) catch return ApigwConfigError.InvalidApigwPort;
    if (value > std.math.maxInt(u16)) return ApigwConfigError.InvalidApigwPort;
    return @intCast(value);
}

fn parseValkeyPortWithFallback(raw: []const u8) u16 {
    const value = std.fmt.parseInt(u32, raw, 10) catch return 6379;
    if (value > std.math.maxInt(u16)) return 6379;
    return @intCast(value);
}

fn optionalEnv(name: []const u8) ?[]const u8 {
    const value = std.posix.getenv(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn isAsciiAlphaNumeric(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9');
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) {
        return true;
    }
    return false;
}

fn absolutePathIsRelativeToBase(full_path: []const u8, base_path: []const u8) bool {
    const base = trimTrailingSeparators(base_path);
    if (base.len == 0) return false;
    if (std.mem.eql(u8, base, "/")) return std.mem.startsWith(u8, full_path, "/");
    if (!std.mem.startsWith(u8, full_path, base)) return false;
    if (full_path.len == base.len) return true;
    const boundary = full_path[base.len];
    return boundary == '/' or boundary == '\\';
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    if (path.len <= 1) return path;
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {}
    return path[0..end];
}

fn resolveS3Url(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    filepath: []const u8,
) ![]u8 {
    if (std.mem.startsWith(u8, filepath, "s3://")) {
        return allocator.dupe(u8, filepath);
    }

    const authority_end = s3AuthorityEnd(base_path) orelse return allocator.dupe(u8, filepath);
    const authority = base_path[0..authority_end];

    var unresolved: []u8 = undefined;
    if (filepath.len > 0 and filepath[0] == '/') {
        unresolved = try std.mem.concat(allocator, u8, &.{ authority, filepath });
    } else if (base_path.len > 0 and base_path[base_path.len - 1] == '/') {
        unresolved = try std.mem.concat(allocator, u8, &.{ base_path, filepath });
    } else {
        const last_slash = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse authority_end;
        const base_dir_end = if (last_slash < authority_end) authority_end else last_slash + 1;
        unresolved = try std.mem.concat(allocator, u8, &.{ base_path[0..base_dir_end], filepath });
    }
    defer allocator.free(unresolved);

    const unresolved_authority_end = s3AuthorityEnd(unresolved) orelse return allocator.dupe(u8, unresolved);
    const unresolved_authority = unresolved[0..unresolved_authority_end];
    const unresolved_path = if (unresolved_authority_end < unresolved.len) unresolved[unresolved_authority_end..] else "/";

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    var splitter = std.mem.splitScalar(u8, unresolved_path, '/');
    while (splitter.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(allocator, seg);
    }

    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    try normalized.appendSlice(allocator, unresolved_authority);
    try normalized.append(allocator, '/');
    for (segments.items, 0..) |seg, idx| {
        if (idx != 0) try normalized.append(allocator, '/');
        try normalized.appendSlice(allocator, seg);
    }
    return normalized.toOwnedSlice(allocator);
}

fn s3AuthorityEnd(url: []const u8) ?usize {
    if (!std.mem.startsWith(u8, url, "s3://")) return null;
    const after = url["s3://".len..];
    const slash_rel = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    return "s3://".len + slash_rel;
}

fn parsePluginStorageMode(raw: []const u8) !PluginStorageMode {
    if (std.mem.eql(u8, raw, "local")) return .local;
    if (std.mem.eql(u8, raw, "prefix")) return .prefix;
    if (std.mem.eql(u8, raw, "s3")) return .s3;
    return error.InvalidStorageMode;
}

fn parseDataStorageMode(raw: []const u8) !DataStorageMode {
    if (std.mem.eql(u8, raw, "local")) return .local;
    if (std.mem.eql(u8, raw, "s3")) return .s3;
    return error.InvalidStorageMode;
}

fn allocSuffix(allocator: std.mem.Allocator, value: []const u8, suffix: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ value, suffix });
}

fn pathJoinAlloc(
    allocator: std.mem.Allocator,
    base: []const u8,
    child: []const u8,
) ![]u8 {
    if (base.len == 0) return allocator.dupe(u8, child);
    if (base[base.len - 1] == '/' or base[base.len - 1] == '\\') {
        return std.mem.concat(allocator, u8, &.{ base, child });
    }
    return std.mem.concat(allocator, u8, &.{ base, "/", child });
}

fn urlJoinLikeAlloc(
    allocator: std.mem.Allocator,
    base: []const u8,
    relative: []const u8,
) ![]u8 {
    if (relative.len == 0) return allocator.dupe(u8, base);
    if (relative[0] == '/') return allocator.dupe(u8, relative);
    if (base.len == 0) return allocator.dupe(u8, relative);
    if (base[base.len - 1] == '/') {
        return std.mem.concat(allocator, u8, &.{ base, relative });
    }
    const slash = std.mem.lastIndexOfScalar(u8, base, '/');
    if (slash) |idx| {
        return std.mem.concat(allocator, u8, &.{ base[0 .. idx + 1], relative });
    }
    return allocator.dupe(u8, relative);
}

fn isAsciiAlphaNumericString(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (!isAsciiAlphaNumeric(ch)) return false;
    }
    return true;
}

const StemSuffix = struct {
    stem: []const u8,
    suffix: []const u8,
};

fn purePathName(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') : (end -= 1) {}
    if (end == 0) return "";

    const trimmed = path[0..end];
    const slash_index = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[slash_index + 1 ..];
}

fn splitPurePathStemSuffix(path: []const u8) StemSuffix {
    const name = purePathName(path);
    if (name.len == 0) return .{ .stem = "", .suffix = "" };
    if (std.mem.eql(u8, name, ".")) return .{ .stem = "", .suffix = "" };
    if (std.mem.eql(u8, name, "..")) return .{ .stem = "..", .suffix = "" };

    var first_non_dot: ?usize = null;
    for (name, 0..) |ch, idx| {
        if (ch != '.') {
            first_non_dot = idx;
            break;
        }
    }

    if (first_non_dot == null) return .{ .stem = name, .suffix = "" };

    const last_dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse {
        return .{ .stem = name, .suffix = "" };
    };
    if (last_dot <= first_non_dot.?) return .{ .stem = name, .suffix = "" };
    return .{
        .stem = name[0..last_dot],
        .suffix = name[last_dot..],
    };
}

test "classifyArgs detects config mode" {
    try std.testing.expectEqual(ApigwAction.config, classifyArgs(&.{"config"}));
    try std.testing.expectEqual(ApigwAction.config, classifyArgs(&.{"--preflight"}));
    try std.testing.expectEqual(ApigwAction.validate_gid_cid, classifyArgs(&.{ "validate-gid-cid", "aiverify.stock_reports-01" }));
    try std.testing.expectEqual(ApigwAction.check_valid_filename, classifyArgs(&.{ "check-valid-filename", "abc" }));
    try std.testing.expectEqual(ApigwAction.sanitize_filename, classifyArgs(&.{ "sanitize-filename", "abc" }));
    try std.testing.expectEqual(ApigwAction.check_relative_to_base, classifyArgs(&.{ "check-relative-to-base", "/base", "child" }));
    try std.testing.expectEqual(ApigwAction.check_file_size, classifyArgs(&.{ "check-file-size", "123" }));
    try std.testing.expectEqual(ApigwAction.append_filename, classifyArgs(&.{ "append-filename", "file.txt", "_new" }));
    try std.testing.expectEqual(ApigwAction.get_suffix, classifyArgs(&.{ "get-suffix", "file.txt" }));
    try std.testing.expectEqual(ApigwAction.get_stem, classifyArgs(&.{ "get-stem", "file.txt" }));
    try std.testing.expectEqual(ApigwAction.plugin_storage_layout, classifyArgs(&.{ "plugin-storage-layout", "local", "/base/plugin", "gid", "cid" }));
    try std.testing.expectEqual(ApigwAction.plugin_storage_layout, classifyArgs(&.{ "plugin-storage-layout", "s3", "s3://bucket/plugin/", "gid", "cid" }));
    try std.testing.expectEqual(ApigwAction.data_storage_layout, classifyArgs(&.{ "data-storage-layout", "local", "/base/artifacts", "/base/models", "/base/datasets", "TR123", "nested/file.bin", "nlp" }));
    try std.testing.expectEqual(ApigwAction.save_artifact, classifyArgs(&.{ "save-artifact", "/base/artifacts", "TR123", "nested/file.bin", "payload" }));
    try std.testing.expectEqual(ApigwAction.get_artifact, classifyArgs(&.{ "get-artifact", "/base/artifacts", "TR123", "nested/file.bin" }));
    try std.testing.expectEqual(ApigwAction.save_model_local, classifyArgs(&.{ "save-model-local", "/base/models", "/tmp/model.bin" }));
    try std.testing.expectEqual(ApigwAction.get_model_local, classifyArgs(&.{ "get-model-local", "/base/models", "model.bin" }));
    try std.testing.expectEqual(ApigwAction.delete_model_local, classifyArgs(&.{ "delete-model-local", "/base/models", "model.bin" }));
    try std.testing.expectEqual(ApigwAction.save_dataset_local, classifyArgs(&.{ "save-dataset-local", "/base/datasets", "/tmp/dataset.csv" }));
    try std.testing.expectEqual(ApigwAction.get_dataset_local, classifyArgs(&.{ "get-dataset-local", "/base/datasets", "dataset.csv" }));
    try std.testing.expectEqual(ApigwAction.delete_dataset_local, classifyArgs(&.{ "delete-dataset-local", "/base/datasets", "dataset.csv" }));
    try std.testing.expectEqual(ApigwAction.save_plugin_local, classifyArgs(&.{ "save-plugin-local", "/base/plugins", "gid-01", "/tmp/plugin-source" }));
    try std.testing.expectEqual(ApigwAction.save_plugin_algorithm_local, classifyArgs(&.{ "save-plugin-algorithm-local", "/base/plugins", "gid-01", "cid-01", "/tmp/algo-source" }));
    try std.testing.expectEqual(ApigwAction.save_plugin_widgets_local, classifyArgs(&.{ "save-plugin-widgets-local", "/base/plugins", "gid-01", "/tmp/widgets-source" }));
    try std.testing.expectEqual(ApigwAction.save_plugin_inputs_local, classifyArgs(&.{ "save-plugin-inputs-local", "/base/plugins", "gid-01", "/tmp/inputs-source" }));
    try std.testing.expectEqual(ApigwAction.save_plugin_mdx_bundles_local, classifyArgs(&.{ "save-plugin-mdx-bundles-local", "/base/plugins", "gid-01", "/tmp/mdx-bundles" }));
    try std.testing.expectEqual(ApigwAction.backup_plugin_local, classifyArgs(&.{ "backup-plugin-local", "/base/plugins", "gid-01", "/tmp/backup-target" }));
    try std.testing.expectEqual(ApigwAction.get_plugin_zip_local, classifyArgs(&.{ "get-plugin-zip-local", "/base/plugins", "gid-01" }));
    try std.testing.expectEqual(ApigwAction.get_plugin_algorithm_zip_local, classifyArgs(&.{ "get-plugin-algorithm-zip-local", "/base/plugins", "gid-01", "cid-01" }));
    try std.testing.expectEqual(ApigwAction.get_plugin_widgets_zip_local, classifyArgs(&.{ "get-plugin-widgets-zip-local", "/base/plugins", "gid-01" }));
    try std.testing.expectEqual(ApigwAction.get_plugin_inputs_zip_local, classifyArgs(&.{ "get-plugin-inputs-zip-local", "/base/plugins", "gid-01" }));
    try std.testing.expectEqual(ApigwAction.get_plugin_mdx_bundle_local, classifyArgs(&.{ "get-plugin-mdx-bundle-local", "/base/plugins", "gid-01", "cid-01" }));
    try std.testing.expectEqual(ApigwAction.get_plugin_mdx_summary_bundle_local, classifyArgs(&.{ "get-plugin-mdx-summary-bundle-local", "/base/plugins", "gid-01", "cid-01" }));
    try std.testing.expectEqual(ApigwAction.delete_plugin_local, classifyArgs(&.{ "delete-plugin-local", "/base/plugins", "gid-01" }));
    try std.testing.expectEqual(ApigwAction.usage_error, classifyArgs(&.{"validate-gid-cid"}));
    try std.testing.expectEqual(ApigwAction.pass_through, classifyArgs(&.{}));
}

test "classifyInvocation captures gid/cid value" {
    const invocation = classifyInvocation(&.{ "validate-gid-cid", "aiverify.stock_reports-01" });
    try std.testing.expectEqual(ApigwAction.validate_gid_cid, invocation.action);
    try std.testing.expectEqualStrings("aiverify.stock_reports-01", invocation.gid_cid_value);
}

test "validateGidCid matches apigw validator semantics" {
    try std.testing.expect(validateGidCid("abc"));
    try std.testing.expect(validateGidCid("aiverify.stock_reports-01"));
    try std.testing.expect(validateGidCid("abc\n"));
    try std.testing.expect(!validateGidCid(""));
    try std.testing.expect(!validateGidCid("\n"));
    try std.testing.expect(!validateGidCid(".abc"));
    try std.testing.expect(!validateGidCid("-abc"));
    try std.testing.expect(!validateGidCid("a/b"));
    try std.testing.expect(!validateGidCid("a b"));
    try std.testing.expect(!validateGidCid("abc\r\n"));
    try std.testing.expect(!validateGidCid("abc\nxyz"));
}

test "checkValidFilename matches python semantics" {
    try std.testing.expect(checkValidFilename(""));
    try std.testing.expect(checkValidFilename("abc-_.txt"));
    try std.testing.expect(checkValidFilename("a\\b"));
    try std.testing.expect(!checkValidFilename("a*b"));
    try std.testing.expect(!checkValidFilename("../abc"));
    try std.testing.expect(!checkValidFilename("abc..def"));
}

test "sanitizeFilenameAlloc matches python semantics" {
    const sanitized_1 = try sanitizeFilenameAlloc(std.testing.allocator, "abc-_.txt");
    defer std.testing.allocator.free(sanitized_1);
    try std.testing.expectEqualStrings("abc_.txt", sanitized_1);

    const sanitized_2 = try sanitizeFilenameAlloc(std.testing.allocator, "a*b$c");
    defer std.testing.allocator.free(sanitized_2);
    try std.testing.expectEqualStrings("abc", sanitized_2);

    try std.testing.expectError(error.InvalidFilename, sanitizeFilenameAlloc(std.testing.allocator, "_bad"));
}

test "checkRelativeToBase local and s3 semantics" {
    try std.testing.expect(try checkRelativeToBase(std.testing.allocator, "/base", "child"));
    try std.testing.expect(try checkRelativeToBase(std.testing.allocator, "/base", "../x"));
    try std.testing.expect(!(try checkRelativeToBase(std.testing.allocator, "/base", "/tmp/x")));
    try std.testing.expect(try checkRelativeToBase(std.testing.allocator, "/base", "/base/x"));

    try std.testing.expect(try checkRelativeToBase(std.testing.allocator, "s3://bucket/prefix/", "child"));
    try std.testing.expect(!(try checkRelativeToBase(std.testing.allocator, "s3://bucket/prefix/", "../child")));
    try std.testing.expect(!(try checkRelativeToBase(std.testing.allocator, "s3://bucket/prefix/", "s3://other/prefix/x")));
}

test "checkFileSize matches python semantics" {
    try std.testing.expect(checkFileSize(4_294_967_296));
    try std.testing.expect(checkFileSize(-1));
    try std.testing.expect(!checkFileSize(4_294_967_297));
}

test "appendFilenameAlloc matches python semantics" {
    const appended_1 = try appendFilenameAlloc(std.testing.allocator, "file.txt", "_new");
    defer std.testing.allocator.free(appended_1);
    try std.testing.expectEqualStrings("file_new.txt", appended_1);

    const appended_2 = try appendFilenameAlloc(std.testing.allocator, "path/to/file.tar.gz", "_v2");
    defer std.testing.allocator.free(appended_2);
    try std.testing.expectEqualStrings("file.tar_v2.gz", appended_2);

    const appended_3 = try appendFilenameAlloc(std.testing.allocator, ".bashrc", "_new");
    defer std.testing.allocator.free(appended_3);
    try std.testing.expectEqualStrings(".bashrc_new", appended_3);
}

test "getSuffixAlloc matches python semantics" {
    const suffix_1 = try getSuffixAlloc(std.testing.allocator, "file.TXT");
    defer std.testing.allocator.free(suffix_1);
    try std.testing.expectEqualStrings(".txt", suffix_1);

    const suffix_2 = try getSuffixAlloc(std.testing.allocator, "file.tar.gz");
    defer std.testing.allocator.free(suffix_2);
    try std.testing.expectEqualStrings(".gz", suffix_2);

    const suffix_3 = try getSuffixAlloc(std.testing.allocator, ".../.bashrc");
    defer std.testing.allocator.free(suffix_3);
    try std.testing.expectEqualStrings("", suffix_3);
}

test "getStem matches python semantics" {
    try std.testing.expectEqualStrings("file", getStem("file.txt"));
    try std.testing.expectEqualStrings("file.tar", getStem("path/to/file.tar.gz"));
    try std.testing.expectEqualStrings(".env", getStem(".env"));
    try std.testing.expectEqualStrings("...", getStem("..."));
}

test "renderPluginStorageLayoutAlloc local mode" {
    const output = try renderPluginStorageLayoutAlloc(
        std.testing.allocator,
        "local",
        "/base/plugin",
        "gid-01",
        "cid-01",
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "plugin_folder: /base/plugin/gid-01") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mdx_bundles_folder: /base/plugin/gid-01/mdx_bundles") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plugin_zip_path: /base/plugin/gid-01/gid-01.zip") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "algorithm_zip_path: /base/plugin/gid-01/algorithms/cid-01.zip") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mdx_summary_bundle_path: /base/plugin/gid-01/mdx_bundles/cid-01.summary.bundle.json") != null);
}

test "renderPluginStorageLayoutAlloc prefix mode" {
    const output = try renderPluginStorageLayoutAlloc(
        std.testing.allocator,
        "prefix",
        "base/plugin/",
        "gid-01",
        "cid-01",
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "plugin_folder: base/plugin/gid-01/") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mdx_bundles_folder: base/plugin/gid-01/mdx_bundles/") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plugin_zip_path: base/plugin/gid-01/gid-01.zip") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "algorithm_zip_path: base/plugin/gid-01/algorithms/cid-01.zip") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mdx_bundle_path: base/plugin/gid-01/mdx_bundles/cid-01.bundle.json") != null);
}

test "renderPluginStorageLayoutAlloc s3 mode" {
    const output = try renderPluginStorageLayoutAlloc(
        std.testing.allocator,
        "s3",
        "s3://bucket/root/plugin/",
        "gid-01",
        "cid-01",
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "mode: s3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plugin_folder: s3://bucket/root/plugin/gid-01/") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mdx_bundles_folder: s3://bucket/root/plugin/gid-01/mdx_bundles/") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "algorithm_zip_path: s3://bucket/root/plugin/gid-01/algorithms/cid-01.zip") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mdx_summary_bundle_path: s3://bucket/root/plugin/gid-01/mdx_bundles/cid-01.summary.bundle.json") != null);
}

test "renderDataStorageLayoutAlloc local mode" {
    const output = try renderDataStorageLayoutAlloc(
        std.testing.allocator,
        "local",
        "/base/artifacts",
        "/base/models",
        "/base/datasets",
        "TR123",
        "nested/file.bin",
        "nlp",
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "artifact_folder: /base/artifacts/TR123") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "artifact_target_path: /base/artifacts/TR123/nested/file.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_folder: /base/models/nlp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_path: /base/models/nlp/nested/file.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_sidecar_zip_lookup: /base/models/nlp/nested/file.bin.zip") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dataset_path: /base/datasets/nlp/nested/file.bin") != null);
}

test "renderDataStorageLayoutAlloc s3 mode" {
    const output = try renderDataStorageLayoutAlloc(
        std.testing.allocator,
        "s3",
        "s3://bucket/root/artifacts/",
        "s3://bucket/root/models/",
        "s3://bucket/root/datasets/",
        "BAD_ID",
        "nested/file.bin",
        "nlp",
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "valid_test_result_id: no") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "artifact_folder: s3://bucket/root/artifacts/BAD_ID/") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_path: s3://bucket/root/models/nlp/nested/file.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_sidecar_zip_save_key: nested/file.bin.zip") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_sidecar_zip_lookup: s3://bucket/root/models/nlp/nested/file.bin.zip") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dataset_sidecar_hash_lookup: s3://bucket/root/datasets/nlp/nested/file.bin.hash") != null);
}

test "artifact local save/get roundtrip" {
    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ "/tmp", "aiverify-zig-apigw-artifact-test" });
    defer std.testing.allocator.free(tmp_root);
    std.fs.cwd().deleteTree(tmp_root) catch {};
    defer std.fs.cwd().deleteTree(tmp_root) catch {};

    const saved_path = try saveArtifactLocalAlloc(
        std.testing.allocator,
        tmp_root,
        "TR123",
        "nested/file.bin",
        "artifact_payload",
    );
    defer std.testing.allocator.free(saved_path);
    try std.testing.expect(std.mem.indexOf(u8, saved_path, "/TR123/nested/file.bin") != null);

    const content = try getArtifactLocalAlloc(
        std.testing.allocator,
        tmp_root,
        "TR123",
        "nested/file.bin",
    );
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("artifact_payload", content);
}

test "model and dataset local save/get/delete roundtrip" {
    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ "/tmp", "aiverify-zig-apigw-model-dataset-test" });
    defer std.testing.allocator.free(tmp_root);
    std.fs.cwd().deleteTree(tmp_root) catch {};
    defer std.fs.cwd().deleteTree(tmp_root) catch {};
    try std.fs.cwd().makePath(tmp_root);

    const model_src = try pathJoinAlloc(std.testing.allocator, tmp_root, "source-model.bin");
    defer std.testing.allocator.free(model_src);
    {
        var src_file = try std.fs.cwd().createFile(model_src, .{});
        defer src_file.close();
        try src_file.writeAll("model_payload");
    }

    const dataset_src = try pathJoinAlloc(std.testing.allocator, tmp_root, "source-dataset.csv");
    defer std.testing.allocator.free(dataset_src);
    {
        var src_file = try std.fs.cwd().createFile(dataset_src, .{});
        defer src_file.close();
        try src_file.writeAll("dataset_payload");
    }

    const models_base = try pathJoinAlloc(std.testing.allocator, tmp_root, "models");
    defer std.testing.allocator.free(models_base);
    const datasets_base = try pathJoinAlloc(std.testing.allocator, tmp_root, "datasets");
    defer std.testing.allocator.free(datasets_base);

    var model_save = try saveModelLocalAlloc(std.testing.allocator, models_base, model_src);
    defer model_save.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, model_save.target_path, "/models/source-model.bin") != null);
    try std.testing.expectEqual(@as(usize, 64), model_save.sha256_hex.len);

    const model_content = try getModelLocalAlloc(std.testing.allocator, models_base, "source-model.bin");
    defer std.testing.allocator.free(model_content);
    try std.testing.expectEqualStrings("model_payload", model_content);

    try std.testing.expect(try deleteModelLocal(std.testing.allocator, models_base, "source-model.bin"));
    try std.testing.expect(!(try deleteModelLocal(std.testing.allocator, models_base, "source-model.bin")));

    var dataset_save = try saveDatasetLocalAlloc(std.testing.allocator, datasets_base, dataset_src);
    defer dataset_save.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, dataset_save.target_path, "/datasets/source-dataset.csv") != null);
    try std.testing.expectEqual(@as(usize, 64), dataset_save.sha256_hex.len);

    const dataset_content = try getDatasetLocalAlloc(std.testing.allocator, datasets_base, "source-dataset.csv");
    defer std.testing.allocator.free(dataset_content);
    try std.testing.expectEqualStrings("dataset_payload", dataset_content);

    try std.testing.expect(try deleteDatasetLocal(std.testing.allocator, datasets_base, "source-dataset.csv"));
    try std.testing.expect(!(try deleteDatasetLocal(std.testing.allocator, datasets_base, "source-dataset.csv")));
}

test "model and dataset local directory sidecar roundtrip" {
    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ "/tmp", "aiverify-zig-apigw-model-dataset-dir-test" });
    defer std.testing.allocator.free(tmp_root);
    std.fs.cwd().deleteTree(tmp_root) catch {};
    defer std.fs.cwd().deleteTree(tmp_root) catch {};
    try std.fs.cwd().makePath(tmp_root);

    const model_src_dir = try pathJoinAlloc(std.testing.allocator, tmp_root, "source-model-dir");
    defer std.testing.allocator.free(model_src_dir);
    const model_nested_dir = try pathJoinAlloc(std.testing.allocator, model_src_dir, "weights");
    defer std.testing.allocator.free(model_nested_dir);
    try std.fs.cwd().makePath(model_nested_dir);
    const model_nested_file = try pathJoinAlloc(std.testing.allocator, model_nested_dir, "tensor.bin");
    defer std.testing.allocator.free(model_nested_file);
    {
        var fp = try std.fs.cwd().createFile(model_nested_file, .{});
        defer fp.close();
        try fp.writeAll("model_dir_payload");
    }

    const dataset_src_dir = try pathJoinAlloc(std.testing.allocator, tmp_root, "source-dataset-dir");
    defer std.testing.allocator.free(dataset_src_dir);
    const dataset_nested_file = try pathJoinAlloc(std.testing.allocator, dataset_src_dir, "data.csv");
    defer std.testing.allocator.free(dataset_nested_file);
    try std.fs.cwd().makePath(dataset_src_dir);
    {
        var fp = try std.fs.cwd().createFile(dataset_nested_file, .{});
        defer fp.close();
        try fp.writeAll("dataset_dir_payload");
    }

    const models_base = try pathJoinAlloc(std.testing.allocator, tmp_root, "models");
    defer std.testing.allocator.free(models_base);
    const datasets_base = try pathJoinAlloc(std.testing.allocator, tmp_root, "datasets");
    defer std.testing.allocator.free(datasets_base);

    var model_save = try saveModelLocalAlloc(std.testing.allocator, models_base, model_src_dir);
    defer model_save.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, model_save.target_path, "/models/source-model-dir") != null);
    try std.testing.expectEqual(@as(usize, 64), model_save.sha256_hex.len);

    const model_hash_sidecar = try sidecarPathAlloc(std.testing.allocator, model_save.target_path, ".hash");
    defer std.testing.allocator.free(model_hash_sidecar);
    {
        var hash_file = try std.fs.cwd().openFile(model_hash_sidecar, .{});
        defer hash_file.close();
        const hash_data = try hash_file.readToEndAlloc(std.testing.allocator, 1024);
        defer std.testing.allocator.free(hash_data);
        try std.testing.expectEqualStrings(model_save.sha256_hex, hash_data);
    }

    const model_zip_content = try getModelLocalAlloc(std.testing.allocator, models_base, "source-model-dir");
    defer std.testing.allocator.free(model_zip_content);
    try std.testing.expect(model_zip_content.len > 0);

    try std.testing.expect(try deleteModelLocal(std.testing.allocator, models_base, "source-model-dir"));
    try std.testing.expectError(error.ModelNotFound, getModelLocalAlloc(std.testing.allocator, models_base, "source-model-dir"));
    try std.testing.expect(!(try deleteModelLocal(std.testing.allocator, models_base, "source-model-dir")));

    var dataset_save = try saveDatasetLocalAlloc(std.testing.allocator, datasets_base, dataset_src_dir);
    defer dataset_save.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, dataset_save.target_path, "/datasets/source-dataset-dir") != null);
    try std.testing.expectEqual(@as(usize, 64), dataset_save.sha256_hex.len);

    const dataset_hash_sidecar = try sidecarPathAlloc(std.testing.allocator, dataset_save.target_path, ".hash");
    defer std.testing.allocator.free(dataset_hash_sidecar);
    {
        var hash_file = try std.fs.cwd().openFile(dataset_hash_sidecar, .{});
        defer hash_file.close();
        const hash_data = try hash_file.readToEndAlloc(std.testing.allocator, 1024);
        defer std.testing.allocator.free(hash_data);
        try std.testing.expectEqualStrings(dataset_save.sha256_hex, hash_data);
    }

    const dataset_zip_content = try getDatasetLocalAlloc(std.testing.allocator, datasets_base, "source-dataset-dir");
    defer std.testing.allocator.free(dataset_zip_content);
    try std.testing.expect(dataset_zip_content.len > 0);

    try std.testing.expect(try deleteDatasetLocal(std.testing.allocator, datasets_base, "source-dataset-dir"));
    try std.testing.expectError(error.DatasetNotFound, getDatasetLocalAlloc(std.testing.allocator, datasets_base, "source-dataset-dir"));
    try std.testing.expect(!(try deleteDatasetLocal(std.testing.allocator, datasets_base, "source-dataset-dir")));
}

test "plugin archive local save/get/delete roundtrip" {
    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ "/tmp", "aiverify-zig-apigw-plugin-archive-test" });
    defer std.testing.allocator.free(tmp_root);
    std.fs.cwd().deleteTree(tmp_root) catch {};
    defer std.fs.cwd().deleteTree(tmp_root) catch {};
    try std.fs.cwd().makePath(tmp_root);

    const plugins_base = try pathJoinAlloc(std.testing.allocator, tmp_root, "plugins");
    defer std.testing.allocator.free(plugins_base);

    const plugin_src = try pathJoinAlloc(std.testing.allocator, tmp_root, "plugin_src");
    defer std.testing.allocator.free(plugin_src);
    const plugin_src_nested = try pathJoinAlloc(std.testing.allocator, plugin_src, "config");
    defer std.testing.allocator.free(plugin_src_nested);
    try std.fs.cwd().makePath(plugin_src_nested);
    {
        const plugin_src_file = try pathJoinAlloc(std.testing.allocator, plugin_src_nested, "plugin.json");
        defer std.testing.allocator.free(plugin_src_file);
        var fp = try std.fs.cwd().createFile(plugin_src_file, .{});
        defer fp.close();
        try fp.writeAll("{\"name\":\"plugin\"}");
    }

    const algo_src = try pathJoinAlloc(std.testing.allocator, tmp_root, "algo_src");
    defer std.testing.allocator.free(algo_src);
    try std.fs.cwd().makePath(algo_src);
    {
        const algo_src_file = try pathJoinAlloc(std.testing.allocator, algo_src, "algorithm.py");
        defer std.testing.allocator.free(algo_src_file);
        var fp = try std.fs.cwd().createFile(algo_src_file, .{});
        defer fp.close();
        try fp.writeAll("print('algo')");
    }

    const widgets_src = try pathJoinAlloc(std.testing.allocator, tmp_root, "widgets_src");
    defer std.testing.allocator.free(widgets_src);
    try std.fs.cwd().makePath(widgets_src);
    {
        const widgets_src_file = try pathJoinAlloc(std.testing.allocator, widgets_src, "widget.js");
        defer std.testing.allocator.free(widgets_src_file);
        var fp = try std.fs.cwd().createFile(widgets_src_file, .{});
        defer fp.close();
        try fp.writeAll("console.log('widget');");
    }

    const inputs_src = try pathJoinAlloc(std.testing.allocator, tmp_root, "inputs_src");
    defer std.testing.allocator.free(inputs_src);
    try std.fs.cwd().makePath(inputs_src);
    {
        const inputs_src_file = try pathJoinAlloc(std.testing.allocator, inputs_src, "input.json");
        defer std.testing.allocator.free(inputs_src_file);
        var fp = try std.fs.cwd().createFile(inputs_src_file, .{});
        defer fp.close();
        try fp.writeAll("{\"input\":true}");
    }

    var plugin_save = try savePluginLocalAlloc(std.testing.allocator, plugins_base, "gid-01", plugin_src);
    defer plugin_save.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, plugin_save.zip_path, "/gid-01/gid-01.zip") != null);
    try std.testing.expectEqual(@as(usize, 64), plugin_save.sha256_hex.len);
    {
        var hash_file = try std.fs.cwd().openFile(plugin_save.hash_path, .{});
        defer hash_file.close();
        const hash_data = try hash_file.readToEndAlloc(std.testing.allocator, 1024);
        defer std.testing.allocator.free(hash_data);
        try std.testing.expectEqualStrings(plugin_save.sha256_hex, hash_data);
    }

    var algo_save = try savePluginAlgorithmLocalAlloc(std.testing.allocator, plugins_base, "gid-01", "cid-01", algo_src);
    defer algo_save.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, algo_save.zip_path, "/gid-01/algorithms/cid-01.zip") != null);
    try std.testing.expectEqual(@as(usize, 64), algo_save.sha256_hex.len);

    var widgets_save = try savePluginWidgetsLocalAlloc(std.testing.allocator, plugins_base, "gid-01", widgets_src);
    defer widgets_save.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, widgets_save.zip_path, "/gid-01/widgets.zip") != null);
    try std.testing.expectEqual(@as(usize, 64), widgets_save.sha256_hex.len);

    var inputs_save = try savePluginInputsLocalAlloc(std.testing.allocator, plugins_base, "gid-01", inputs_src);
    defer inputs_save.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, inputs_save.zip_path, "/gid-01/inputs.zip") != null);
    try std.testing.expectEqual(@as(usize, 64), inputs_save.sha256_hex.len);

    const plugin_zip = try getPluginZipLocalAlloc(std.testing.allocator, plugins_base, "gid-01");
    defer std.testing.allocator.free(plugin_zip);
    try std.testing.expect(plugin_zip.len > 0);

    const algo_zip = try getPluginAlgorithmZipLocalAlloc(std.testing.allocator, plugins_base, "gid-01", "cid-01");
    defer std.testing.allocator.free(algo_zip);
    try std.testing.expect(algo_zip.len > 0);

    const widgets_zip = try getPluginWidgetsZipLocalAlloc(std.testing.allocator, plugins_base, "gid-01");
    defer std.testing.allocator.free(widgets_zip);
    try std.testing.expect(widgets_zip.len > 0);

    const inputs_zip = try getPluginInputsZipLocalAlloc(std.testing.allocator, plugins_base, "gid-01");
    defer std.testing.allocator.free(inputs_zip);
    try std.testing.expect(inputs_zip.len > 0);

    try std.testing.expect(try deletePluginLocal(std.testing.allocator, plugins_base, "gid-01"));
    try std.testing.expectError(error.PluginArchiveNotFound, getPluginZipLocalAlloc(std.testing.allocator, plugins_base, "gid-01"));
    try std.testing.expect(!(try deletePluginLocal(std.testing.allocator, plugins_base, "gid-01")));
}

test "plugin mdx bundle local save/get roundtrip" {
    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ "/tmp", "aiverify-zig-apigw-plugin-mdx-bundle-test" });
    defer std.testing.allocator.free(tmp_root);
    std.fs.cwd().deleteTree(tmp_root) catch {};
    defer std.fs.cwd().deleteTree(tmp_root) catch {};
    try std.fs.cwd().makePath(tmp_root);

    const plugins_base = try pathJoinAlloc(std.testing.allocator, tmp_root, "plugins");
    defer std.testing.allocator.free(plugins_base);

    const mdx_source = try pathJoinAlloc(std.testing.allocator, tmp_root, "mdx_source");
    defer std.testing.allocator.free(mdx_source);
    try std.fs.cwd().makePath(mdx_source);

    const widget_bundle = try pathJoinAlloc(std.testing.allocator, mdx_source, "cid-01.bundle.json");
    defer std.testing.allocator.free(widget_bundle);
    {
        var fp = try std.fs.cwd().createFile(widget_bundle, .{});
        defer fp.close();
        try fp.writeAll("{\"code\":\"widget_code_01\",\"frontmatter\":\"widget_frontmatter_01\"}");
    }

    const summary_bundle = try pathJoinAlloc(std.testing.allocator, mdx_source, "cid-01.summary.bundle.json");
    defer std.testing.allocator.free(summary_bundle);
    {
        var fp = try std.fs.cwd().createFile(summary_bundle, .{});
        defer fp.close();
        try fp.writeAll("{\"code\":\"summary_code_01\",\"frontmatter\":\"summary_frontmatter_01\"}");
    }

    const saved_path = try savePluginMdxBundlesLocalAlloc(std.testing.allocator, plugins_base, "gid-01", mdx_source);
    defer std.testing.allocator.free(saved_path);
    try std.testing.expect(std.mem.indexOf(u8, saved_path, "/gid-01/mdx_bundles") != null);

    const widget_content = try getPluginMdxBundleLocalAlloc(std.testing.allocator, plugins_base, "gid-01", "cid-01", false);
    defer std.testing.allocator.free(widget_content);
    try std.testing.expectEqualStrings("{\"code\":\"widget_code_01\",\"frontmatter\":\"widget_frontmatter_01\"}", widget_content);

    const summary_content = try getPluginMdxBundleLocalAlloc(std.testing.allocator, plugins_base, "gid-01", "cid-01", true);
    defer std.testing.allocator.free(summary_content);
    try std.testing.expectEqualStrings("{\"code\":\"summary_code_01\",\"frontmatter\":\"summary_frontmatter_01\"}", summary_content);

    try std.testing.expectError(error.PluginBundleNotFound, getPluginMdxBundleLocalAlloc(std.testing.allocator, plugins_base, "gid-01", "missing-cid", false));
    try std.testing.expectError(error.InvalidGid, savePluginMdxBundlesLocalAlloc(std.testing.allocator, plugins_base, "bad/gid", mdx_source));
}

test "plugin backup local copies plugin and ignores configured paths" {
    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ "/tmp", "aiverify-zig-apigw-plugin-backup-test" });
    defer std.testing.allocator.free(tmp_root);
    std.fs.cwd().deleteTree(tmp_root) catch {};
    defer std.fs.cwd().deleteTree(tmp_root) catch {};
    try std.fs.cwd().makePath(tmp_root);

    const plugins_base = try pathJoinAlloc(std.testing.allocator, tmp_root, "plugins");
    defer std.testing.allocator.free(plugins_base);
    const plugin_source = try pathJoinAlloc(std.testing.allocator, plugins_base, "gid-01");
    defer std.testing.allocator.free(plugin_source);
    try std.fs.cwd().makePath(plugin_source);

    const config_dir = try pathJoinAlloc(std.testing.allocator, plugin_source, "config");
    defer std.testing.allocator.free(config_dir);
    try std.fs.cwd().makePath(config_dir);
    const config_file = try pathJoinAlloc(std.testing.allocator, config_dir, "plugin.json");
    defer std.testing.allocator.free(config_file);
    {
        var fp = try std.fs.cwd().createFile(config_file, .{});
        defer fp.close();
        try fp.writeAll("{\"name\":\"plugin\"}");
    }

    const temp_dir = try pathJoinAlloc(std.testing.allocator, plugin_source, "temp");
    defer std.testing.allocator.free(temp_dir);
    try std.fs.cwd().makePath(temp_dir);
    const temp_file = try pathJoinAlloc(std.testing.allocator, temp_dir, "ignored.txt");
    defer std.testing.allocator.free(temp_file);
    {
        var fp = try std.fs.cwd().createFile(temp_file, .{});
        defer fp.close();
        try fp.writeAll("ignored-temp");
    }

    const node_modules_dir = try pathJoinAlloc(std.testing.allocator, plugin_source, "node_modules");
    defer std.testing.allocator.free(node_modules_dir);
    try std.fs.cwd().makePath(node_modules_dir);
    const node_modules_file = try pathJoinAlloc(std.testing.allocator, node_modules_dir, "mod.js");
    defer std.testing.allocator.free(node_modules_file);
    {
        var fp = try std.fs.cwd().createFile(node_modules_file, .{});
        defer fp.close();
        try fp.writeAll("ignored-node-modules");
    }

    const pyc_file = try pathJoinAlloc(std.testing.allocator, plugin_source, "script.pyc");
    defer std.testing.allocator.free(pyc_file);
    {
        var fp = try std.fs.cwd().createFile(pyc_file, .{});
        defer fp.close();
        try fp.writeAll("ignored-pyc");
    }

    const target_dir = try pathJoinAlloc(std.testing.allocator, tmp_root, "backup-target");
    defer std.testing.allocator.free(target_dir);
    try std.fs.cwd().makePath(target_dir);
    const stale_file = try pathJoinAlloc(std.testing.allocator, target_dir, "stale.txt");
    defer std.testing.allocator.free(stale_file);
    {
        var fp = try std.fs.cwd().createFile(stale_file, .{});
        defer fp.close();
        try fp.writeAll("stale");
    }

    const backup_path = try backupPluginLocalAlloc(std.testing.allocator, plugins_base, "gid-01", target_dir);
    defer std.testing.allocator.free(backup_path);
    try std.testing.expectEqualStrings(target_dir, backup_path);

    const copied_config = try pathJoinAlloc(std.testing.allocator, target_dir, "config/plugin.json");
    defer std.testing.allocator.free(copied_config);
    try std.fs.cwd().access(copied_config, .{});

    const copied_temp = try pathJoinAlloc(std.testing.allocator, target_dir, "temp/ignored.txt");
    defer std.testing.allocator.free(copied_temp);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(copied_temp, .{}));

    const copied_node_modules = try pathJoinAlloc(std.testing.allocator, target_dir, "node_modules/mod.js");
    defer std.testing.allocator.free(copied_node_modules);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(copied_node_modules, .{}));

    const copied_pyc = try pathJoinAlloc(std.testing.allocator, target_dir, "script.pyc");
    defer std.testing.allocator.free(copied_pyc);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(copied_pyc, .{}));

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(stale_file, .{}));
    try std.testing.expectError(error.InvalidGid, backupPluginLocalAlloc(std.testing.allocator, plugins_base, "bad/gid", target_dir));
}

test "parseApigwPort validates bounds" {
    try std.testing.expectEqual(@as(u16, 4000), try parseApigwPort("4000"));
    try std.testing.expectError(ApigwConfigError.InvalidApigwPort, parseApigwPort("70000"));
    try std.testing.expectError(ApigwConfigError.InvalidApigwPort, parseApigwPort("abc"));
}

test "parseValkeyPortWithFallback handles invalid values" {
    try std.testing.expectEqual(@as(u16, 6380), parseValkeyPortWithFallback("6380"));
    try std.testing.expectEqual(@as(u16, 6379), parseValkeyPortWithFallback("99999"));
    try std.testing.expectEqual(@as(u16, 6379), parseValkeyPortWithFallback("bad"));
}
