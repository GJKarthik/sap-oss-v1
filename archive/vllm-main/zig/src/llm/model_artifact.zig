const std = @import("std");

const Allocator = std.mem.Allocator;
const json = std.json;

pub const ModelArtifactKind = enum {
    gguf_file,
    safetensors_file,
    safetensors_index,

    pub fn name(self: ModelArtifactKind) []const u8 {
        return switch (self) {
            .gguf_file => "gguf_file",
            .safetensors_file => "safetensors_file",
            .safetensors_index => "safetensors_index",
        };
    }
};

pub const ResolvedModelArtifact = struct {
    allocator: Allocator,
    source_env: []const u8,
    source_path: []const u8,
    kind: ModelArtifactKind,
    model_dir: ?[]const u8 = null,
    gguf_path: ?[]const u8 = null,
    safetensors_path: ?[]const u8 = null,
    safetensors_index_path: ?[]const u8 = null,
    config_json_path: ?[]const u8 = null,
    tokenizer_json_path: ?[]const u8 = null,
    chat_template_path: ?[]const u8 = null,
    model_type: ?[]const u8 = null,
    shard_files: std.ArrayListUnmanaged([]const u8),
    total_size_bytes: u64 = 0,

    pub fn init(
        allocator: Allocator,
        source_env: []const u8,
        source_path: []const u8,
        kind: ModelArtifactKind,
    ) !ResolvedModelArtifact {
        return .{
            .allocator = allocator,
            .source_env = try allocator.dupe(u8, source_env),
            .source_path = try allocator.dupe(u8, source_path),
            .kind = kind,
            .shard_files = .empty,
        };
    }

    pub fn deinit(self: *ResolvedModelArtifact) void {
        self.allocator.free(self.source_env);
        self.allocator.free(self.source_path);
        if (self.model_dir) |path| self.allocator.free(path);
        if (self.gguf_path) |path| self.allocator.free(path);
        if (self.safetensors_path) |path| self.allocator.free(path);
        if (self.safetensors_index_path) |path| self.allocator.free(path);
        if (self.config_json_path) |path| self.allocator.free(path);
        if (self.tokenizer_json_path) |path| self.allocator.free(path);
        if (self.chat_template_path) |path| self.allocator.free(path);
        if (self.model_type) |value| self.allocator.free(value);
        for (self.shard_files.items) |shard| {
            self.allocator.free(shard);
        }
        self.shard_files.deinit(self.allocator);
    }

    pub fn directToonReady(self: *const ResolvedModelArtifact) bool {
        return self.kind == .gguf_file;
    }

    pub fn primaryPath(self: *const ResolvedModelArtifact) []const u8 {
        return switch (self.kind) {
            .gguf_file => self.gguf_path orelse self.source_path,
            .safetensors_file => self.safetensors_path orelse self.source_path,
            .safetensors_index => self.safetensors_index_path orelse self.source_path,
        };
    }
};

pub fn resolveFromEnv(allocator: Allocator) !?ResolvedModelArtifact {
    if (std.posix.getenv("GGUF_PATH")) |path| {
        return try resolvePath(allocator, "GGUF_PATH", path);
    }
    if (std.posix.getenv("SAFETENSORS_INDEX_PATH")) |path| {
        return try resolvePath(allocator, "SAFETENSORS_INDEX_PATH", path);
    }
    if (std.posix.getenv("MODEL_PATH")) |path| {
        return try resolvePath(allocator, "MODEL_PATH", path);
    }
    return null;
}

pub fn resolvePath(
    allocator: Allocator,
    source_env: []const u8,
    source_path: []const u8,
) !ResolvedModelArtifact {
    var dir = std.fs.cwd().openDir(source_path, .{ .iterate = true }) catch |dir_err| switch (dir_err) {
        error.NotDir => return try resolveFile(allocator, source_env, source_path),
        else => return dir_err,
    };
    defer dir.close();
    return try resolveDirectory(allocator, source_env, source_path);
}

fn resolveDirectory(
    allocator: Allocator,
    source_env: []const u8,
    source_path: []const u8,
) !ResolvedModelArtifact {
    const index_path = try std.fs.path.join(allocator, &.{ source_path, "model.safetensors.index.json" });
    defer allocator.free(index_path);

    if (fileExists(index_path)) {
        return try resolveSafeTensorsIndex(allocator, source_env, source_path, index_path);
    }

    const safetensors_path = try std.fs.path.join(allocator, &.{ source_path, "model.safetensors" });
    defer allocator.free(safetensors_path);
    if (fileExists(safetensors_path)) {
        return try resolveSafeTensorsFile(allocator, source_env, source_path, safetensors_path);
    }

    var dir = try std.fs.cwd().openDir(source_path, .{ .iterate = true });
    defer dir.close();

    var walker = dir.iterate();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".gguf")) continue;

        const gguf_path = try std.fs.path.join(allocator, &.{ source_path, entry.name });
        defer allocator.free(gguf_path);
        return try resolveGgufFile(allocator, source_env, source_path, gguf_path);
    }

    return error.ModelArtifactNotFound;
}

fn resolveFile(
    allocator: Allocator,
    source_env: []const u8,
    source_path: []const u8,
) !ResolvedModelArtifact {
    if (std.mem.endsWith(u8, source_path, ".gguf")) {
        return try resolveGgufFile(allocator, source_env, source_path, source_path);
    }
    if (std.mem.endsWith(u8, source_path, "model.safetensors.index.json")) {
        const dir_path = std.fs.path.dirname(source_path) orelse ".";
        return try resolveSafeTensorsIndex(allocator, source_env, dir_path, source_path);
    }
    if (std.mem.endsWith(u8, source_path, ".safetensors")) {
        const dir_path = std.fs.path.dirname(source_path) orelse ".";
        return try resolveSafeTensorsFile(allocator, source_env, dir_path, source_path);
    }
    return error.UnsupportedModelArtifact;
}

fn resolveGgufFile(
    allocator: Allocator,
    source_env: []const u8,
    source_path: []const u8,
    gguf_path: []const u8,
) !ResolvedModelArtifact {
    var artifact = try ResolvedModelArtifact.init(allocator, source_env, source_path, .gguf_file);
    errdefer artifact.deinit();

    artifact.gguf_path = try allocator.dupe(u8, gguf_path);
    const stat = try std.fs.cwd().statFile(gguf_path);
    artifact.total_size_bytes = stat.size;
    return artifact;
}

fn resolveSafeTensorsFile(
    allocator: Allocator,
    source_env: []const u8,
    model_dir: []const u8,
    safetensors_path: []const u8,
) !ResolvedModelArtifact {
    var artifact = try ResolvedModelArtifact.init(allocator, source_env, model_dir, .safetensors_file);
    errdefer artifact.deinit();

    artifact.model_dir = try allocator.dupe(u8, model_dir);
    artifact.safetensors_path = try allocator.dupe(u8, safetensors_path);

    const stat = try std.fs.cwd().statFile(safetensors_path);
    artifact.total_size_bytes = stat.size;

    try attachOptionalMetadata(&artifact, model_dir);
    return artifact;
}

fn resolveSafeTensorsIndex(
    allocator: Allocator,
    source_env: []const u8,
    model_dir: []const u8,
    index_path: []const u8,
) !ResolvedModelArtifact {
    var artifact = try ResolvedModelArtifact.init(allocator, source_env, model_dir, .safetensors_index);
    errdefer artifact.deinit();

    artifact.model_dir = try allocator.dupe(u8, model_dir);
    artifact.safetensors_index_path = try allocator.dupe(u8, index_path);

    const index_data = try std.fs.cwd().readFileAlloc(allocator, index_path, 16 * 1024 * 1024);
    defer allocator.free(index_data);

    const parsed = try json.parseFromSlice(json.Value, allocator, index_data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidSafeTensorsIndex;
    const weight_map = parsed.value.object.get("weight_map") orelse return error.InvalidSafeTensorsIndex;
    if (weight_map != .object) return error.InvalidSafeTensorsIndex;

    var unique_shards = std.StringHashMap(void).init(allocator);
    defer unique_shards.deinit();

    var iter = weight_map.object.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const shard_rel = entry.value_ptr.*.string;
        const gop = try unique_shards.getOrPut(shard_rel);
        if (gop.found_existing) continue;

        const shard_copy = try allocator.dupe(u8, shard_rel);
        errdefer allocator.free(shard_copy);
        try artifact.shard_files.append(allocator, shard_copy);

        const shard_path = try std.fs.path.join(allocator, &.{ model_dir, shard_rel });
        defer allocator.free(shard_path);

        const stat = std.fs.cwd().statFile(shard_path) catch |err| switch (err) {
            error.FileNotFound => return error.MissingSafeTensorsShard,
            else => return err,
        };
        artifact.total_size_bytes +%= stat.size;
    }

    try attachOptionalMetadata(&artifact, model_dir);
    return artifact;
}

fn attachOptionalMetadata(artifact: *ResolvedModelArtifact, model_dir: []const u8) !void {
    const allocator = artifact.allocator;

    const config_path = try std.fs.path.join(allocator, &.{ model_dir, "config.json" });
    defer allocator.free(config_path);
    if (fileExists(config_path)) {
        artifact.config_json_path = try allocator.dupe(u8, config_path);
        artifact.model_type = try parseConfigModelType(allocator, config_path);
    }

    const tokenizer_path = try std.fs.path.join(allocator, &.{ model_dir, "tokenizer.json" });
    defer allocator.free(tokenizer_path);
    if (fileExists(tokenizer_path)) {
        artifact.tokenizer_json_path = try allocator.dupe(u8, tokenizer_path);
    }

    const chat_template_path = try std.fs.path.join(allocator, &.{ model_dir, "chat_template.jinja" });
    defer allocator.free(chat_template_path);
    if (fileExists(chat_template_path)) {
        artifact.chat_template_path = try allocator.dupe(u8, chat_template_path);
    }
}

fn parseConfigModelType(allocator: Allocator, config_path: []const u8) !?[]const u8 {
    const config_data = try std.fs.cwd().readFileAlloc(allocator, config_path, 4 * 1024 * 1024);
    defer allocator.free(config_data);

    const parsed = json.parseFromSlice(json.Value, allocator, config_data, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const model_type = parsed.value.object.get("model_type") orelse return null;
    if (model_type != .string) return null;
    return try allocator.dupe(u8, model_type.string);
}

fn fileExists(path: []const u8) bool {
    _ = std.fs.cwd().statFile(path) catch return false;
    return true;
}

test "resolve GGUF file artifact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "model.gguf", .data = "GGUF" });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const gguf_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "model.gguf" });
    defer std.testing.allocator.free(gguf_path);

    var artifact = try resolvePath(std.testing.allocator, "GGUF_PATH", gguf_path);
    defer artifact.deinit();

    try std.testing.expectEqual(ModelArtifactKind.gguf_file, artifact.kind);
    try std.testing.expectEqualStrings(gguf_path, artifact.primaryPath());
    try std.testing.expect(artifact.directToonReady());
}

test "resolve SafeTensors index artifact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "model.safetensors.index.json",
        .data =
        \\{"weight_map":{"layers.0.weight":"model-00001-of-00002.safetensors","layers.1.weight":"model-00002-of-00002.safetensors"}}
        ,
    });
    try tmp.dir.writeFile(.{ .sub_path = "model-00001-of-00002.safetensors", .data = "abcd" });
    try tmp.dir.writeFile(.{ .sub_path = "model-00002-of-00002.safetensors", .data = "efghij" });
    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = "{\"model_type\":\"nemotron_h\"}" });
    try tmp.dir.writeFile(.{ .sub_path = "tokenizer.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "chat_template.jinja", .data = "{{ prompt }}" });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var artifact = try resolvePath(std.testing.allocator, "MODEL_PATH", dir_path);
    defer artifact.deinit();

    try std.testing.expectEqual(ModelArtifactKind.safetensors_index, artifact.kind);
    try std.testing.expectEqual(@as(usize, 2), artifact.shard_files.items.len);
    try std.testing.expectEqualStrings("nemotron_h", artifact.model_type.?);
    try std.testing.expectEqual(@as(u64, 10), artifact.total_size_bytes);
    try std.testing.expect(!artifact.directToonReady());
}
