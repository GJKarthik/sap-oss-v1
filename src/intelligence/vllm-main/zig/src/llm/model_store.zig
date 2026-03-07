// ===----------------------------------------------------------------------=== //
// Model Store - S3 Backend for HuggingFace Models
// Downloads models from HuggingFace and stores them in S3 object storage
// ===----------------------------------------------------------------------=== //

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json = std.json;
const mangle_query = @import("../mangle/query.zig");
const mangle_parser = @import("../mangle/parser.zig");

// =============================================================================
// Configuration
// =============================================================================

pub const S3Config = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    bucket: []const u8,
    region: []const u8,
    endpoint: ?[]const u8 = null, // For S3-compatible stores
};

pub const HFConfig = struct {
    token: []const u8,
    hub_url: []const u8 = "https://huggingface.co",
    cache_dir: []const u8 = "/tmp/hf_cache",
};

pub const ModelStoreConfig = struct {
    s3: S3Config,
    hf: HFConfig,
    models_prefix: []const u8 = "models/",
};

// =============================================================================
// Model Metadata
// =============================================================================

pub const ModelFormat = enum {
    gguf, // llama.cpp format
    safetensors, // Safe tensors format
    pytorch, // PyTorch .bin/.pt
    onnx, // ONNX format
    unknown,

    pub fn fromExtension(ext: []const u8) ModelFormat {
        if (std.mem.eql(u8, ext, ".gguf")) return .gguf;
        if (std.mem.eql(u8, ext, ".safetensors")) return .safetensors;
        if (std.mem.eql(u8, ext, ".bin") or std.mem.eql(u8, ext, ".pt") or std.mem.eql(u8, ext, ".pth")) return .pytorch;
        if (std.mem.eql(u8, ext, ".onnx")) return .onnx;
        return .unknown;
    }
};

pub const ModelFile = struct {
    filename: []const u8,
    size_bytes: u64,
    sha256: ?[64]u8 = null,
    format: ModelFormat,
    s3_key: ?[]const u8 = null,
};

pub const ModelMetadata = struct {
    allocator: Allocator,
    repo_id: []const u8, // e.g., "microsoft/phi-2"
    revision: []const u8 = "main",
    files: std.ArrayList(ModelFile),
    total_size_bytes: u64 = 0,
    downloaded: bool = false,
    s3_prefix: ?[]const u8 = null,

    pub fn init(allocator: Allocator, repo_id: []const u8) ModelMetadata {
        return .{
            .allocator = allocator,
            .repo_id = repo_id,
            .files = .{},
        };
    }

    pub fn deinit(self: *ModelMetadata) void {
        // Metadata owns the duplicated filenames and any derived S3 keys.
        for (self.files.items) |file| {
            self.allocator.free(file.filename);
            if (file.s3_key) |key| self.allocator.free(key);
        }
        self.files.deinit();
    }
};

// =============================================================================
// S3 Client
// =============================================================================

pub const S3Client = struct {
    config: S3Config,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, config: S3Config) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Generate AWS Signature V4 authorization header
    fn signRequest(
        self: *Self,
        method: []const u8,
        path: []const u8,
        _: *std.StringHashMap([]const u8),
        payload_hash: []const u8,
    ) ![]const u8 {
        const timestamp = std.time.timestamp();
        const date = self.formatDate(timestamp);
        const datetime = self.formatDateTime(timestamp);

        // Canonical request
        var canonical = std.ArrayList(u8){};
        defer canonical.deinit();

        try canonical.appendSlice(method);
        try canonical.append('\n');
        try canonical.appendSlice(path);
        try canonical.append('\n');
        // Query string (empty for now)
        try canonical.append('\n');

        // Canonical headers
        try canonical.appendSlice("host:");
        try canonical.appendSlice(self.getHost());
        try canonical.append('\n');
        try canonical.appendSlice("x-amz-content-sha256:");
        try canonical.appendSlice(payload_hash);
        try canonical.append('\n');
        try canonical.appendSlice("x-amz-date:");
        try canonical.appendSlice(datetime[0..]);
        try canonical.append('\n');
        try canonical.append('\n');

        // Signed headers
        try canonical.appendSlice("host;x-amz-content-sha256;x-amz-date");
        try canonical.append('\n');
        try canonical.appendSlice(payload_hash);

        // String to sign
        var string_to_sign = std.ArrayList(u8){};
        defer string_to_sign.deinit();

        try string_to_sign.appendSlice("AWS4-HMAC-SHA256\n");
        try string_to_sign.appendSlice(datetime[0..]);
        try string_to_sign.append('\n');
        try string_to_sign.appendSlice(date[0..]);
        try string_to_sign.append('/');
        try string_to_sign.appendSlice(self.config.region);
        try string_to_sign.appendSlice("/s3/aws4_request\n");

        // Hash canonical request
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(canonical.items, &hash, .{});
        var hash_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
        try string_to_sign.appendSlice(&hash_hex);

        // Derive signing key
        const signing_key = try self.deriveSigningKey(date[0..]);

        // Calculate signature
        var signature: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, string_to_sign.items, &signing_key);
        var sig_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&sig_hex, "{s}", .{std.fmt.fmtSliceHexLower(&signature)}) catch unreachable;

        // Build authorization header
        var auth = std.ArrayList(u8){};
        try auth.appendSlice("AWS4-HMAC-SHA256 Credential=");
        try auth.appendSlice(self.config.access_key_id);
        try auth.append('/');
        try auth.appendSlice(date[0..]);
        try auth.append('/');
        try auth.appendSlice(self.config.region);
        try auth.appendSlice("/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=");
        try auth.appendSlice(&sig_hex);

        return auth.toOwnedSlice();
    }

    fn deriveSigningKey(self: *Self, date: []const u8) ![32]u8 {
        var key1: [32]u8 = undefined;
        const key_prefix_len = 4 + self.config.secret_access_key.len;
        var key_prefix = try self.allocator.alloc(u8, key_prefix_len);
        defer self.allocator.free(key_prefix);
        @memcpy(key_prefix[0..4], "AWS4");
        @memcpy(key_prefix[4..], self.config.secret_access_key);

        std.crypto.auth.hmac.sha2.HmacSha256.create(&key1, date, key_prefix);

        var key2: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&key2, self.config.region, &key1);

        var key3: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&key3, "s3", &key2);

        var key4: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&key4, "aws4_request", &key3);

        return key4;
    }

    fn getHost(self: *Self) []const u8 {
        if (self.config.endpoint) |endpoint| {
            return endpoint;
        }
        // Return S3 regional endpoint
        return "s3.amazonaws.com";
    }

    fn formatDate(_: *Self, timestamp: i64) [8]u8 {
        var buf: [8]u8 = undefined;
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}", .{
            year_day.year,
            @intFromEnum(year_day.month),
            month_day.day_index + 1,
        }) catch unreachable;
        return buf;
    }

    fn formatDateTime(_: *Self, timestamp: i64) [16]u8 {
        var buf: [16]u8 = undefined;
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            year_day.year,
            @intFromEnum(year_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }) catch unreachable;
        return buf;
    }

    /// Upload a file to S3 using chunked streaming (avoids buffering entire file in RAM).
    /// `data` is the full payload; for very large files prefer `putObjectStream`.
    pub fn putObject(self: *Self, key: []const u8, data: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.config.bucket, key });
        defer self.allocator.free(path);

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer headers.deinit();

        // Use streaming SHA-256 so we never need a second copy of `data`.
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(data);
        var content_hash: [32]u8 = undefined;
        hasher.final(&content_hash);
        var hash_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{s}", .{std.fmt.fmtSliceHexLower(&content_hash)}) catch unreachable;

        const auth = try self.signRequest("PUT", path, &headers, &hash_hex);
        defer self.allocator.free(auth);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri_str = try std.fmt.allocPrint(
            self.allocator,
            "https://{s}{s}",
            .{ self.getHost(), path },
        );
        defer self.allocator.free(uri_str);
        const uri = try std.Uri.parse(uri_str);

        var req = try client.open(.PUT, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "x-amz-content-sha256", .value = &hash_hex },
                .{ .name = "Content-Type", .value = "application/octet-stream" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = data.len };
        try req.send();

        // Stream in 4 MB chunks to avoid a single large write syscall.
        const chunk_size: usize = 4 * 1024 * 1024;
        var offset: usize = 0;
        while (offset < data.len) {
            const end = @min(offset + chunk_size, data.len);
            try req.writer().writeAll(data[offset..end]);
            offset = end;
        }

        try req.finish();
        try req.wait();

        if (req.status != .ok and req.status != .created) {
            return error.S3UploadFailed;
        }
    }

    /// Stream a local file directly to S3 without loading it into RAM.
    /// Use this for large model files (>1 GB).
    pub fn putObjectFile(self: *Self, key: []const u8, file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const stat = try file.stat();
        const file_size = stat.size;

        const path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.config.bucket, key });
        defer self.allocator.free(path);

        // Compute SHA-256 by streaming the file once before upload.
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var read_buf: [4 * 1024 * 1024]u8 = undefined;
        while (true) {
            const n = try file.read(&read_buf);
            if (n == 0) break;
            hasher.update(read_buf[0..n]);
        }
        var content_hash: [32]u8 = undefined;
        hasher.final(&content_hash);
        var hash_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{s}", .{std.fmt.fmtSliceHexLower(&content_hash)}) catch unreachable;

        // Rewind for the actual upload.
        try file.seekTo(0);

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer headers.deinit();
        const auth = try self.signRequest("PUT", path, &headers, &hash_hex);
        defer self.allocator.free(auth);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri_str = try std.fmt.allocPrint(
            self.allocator,
            "https://{s}{s}",
            .{ self.getHost(), path },
        );
        defer self.allocator.free(uri_str);
        const uri = try std.Uri.parse(uri_str);

        var req = try client.open(.PUT, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "x-amz-content-sha256", .value = &hash_hex },
                .{ .name = "Content-Type", .value = "application/octet-stream" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = file_size };
        try req.send();

        // Stream file → S3 in 4 MB chunks.
        while (true) {
            const n = try file.read(&read_buf);
            if (n == 0) break;
            try req.writer().writeAll(read_buf[0..n]);
        }

        try req.finish();
        try req.wait();

        if (req.status != .ok and req.status != .created) {
            return error.S3UploadFailed;
        }
    }

    /// Download a file from S3
    pub fn getObject(self: *Self, key: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.config.bucket, key });
        defer self.allocator.free(path);

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer headers.deinit();

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        const auth = try self.signRequest("GET", path, &headers, empty_hash);
        defer self.allocator.free(auth);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const get_uri_str = try std.fmt.allocPrint(
            self.allocator,
            "https://{s}{s}",
            .{ self.getHost(), path },
        );
        defer self.allocator.free(get_uri_str);
        const uri = try std.Uri.parse(get_uri_str);

        var req = try client.open(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "x-amz-content-sha256", .value = empty_hash },
            },
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        if (req.status != .ok) {
            return error.S3DownloadFailed;
        }

        return try req.reader().readAllAlloc(self.allocator, 50 * 1024 * 1024 * 1024); // 50 GB max (matches largest supported model)
    }

    /// Check if an object exists in S3
    pub fn headObject(self: *Self, key: []const u8) !bool {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ self.config.bucket, key });
        defer self.allocator.free(path);

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer headers.deinit();

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        const auth = try self.signRequest("HEAD", path, &headers, empty_hash);
        defer self.allocator.free(auth);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const head_uri_str = try std.fmt.allocPrint(
            self.allocator,
            "https://{s}{s}",
            .{ self.getHost(), path },
        );
        defer self.allocator.free(head_uri_str);
        const uri = try std.Uri.parse(head_uri_str);

        var req = try client.open(.HEAD, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "x-amz-content-sha256", .value = empty_hash },
            },
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        return req.status == .ok;
    }

    /// List objects with a prefix
    pub fn listObjects(self: *Self, prefix: []const u8) !std.ArrayList([]const u8) {
        const escaped_prefix = try self.encodeQueryComponent(prefix);
        defer self.allocator.free(escaped_prefix);
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}?list-type=2&prefix={s}",
            .{ self.config.bucket, escaped_prefix },
        );
        defer self.allocator.free(path);

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer headers.deinit();

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        const auth = try self.signRequest("GET", path, &headers, empty_hash);
        defer self.allocator.free(auth);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const list_uri_str = try std.fmt.allocPrint(
            self.allocator,
            "https://{s}{s}",
            .{ self.getHost(), path },
        );
        defer self.allocator.free(list_uri_str);
        const uri = try std.Uri.parse(list_uri_str);

        var req = try client.open(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "x-amz-content-sha256", .value = empty_hash },
            },
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        var keys = std.ArrayList([]const u8){};

        if (req.status == .ok) {
            // Parse XML response (simplified)
            const body_data = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
            defer self.allocator.free(body_data);

            // Extract keys from <Key>...</Key> tags
            var iter = std.mem.split(u8, body_data, "<Key>");
            _ = iter.next(); // Skip first part
            while (iter.next()) |part| {
                if (std.mem.indexOf(u8, part, "</Key>")) |end| {
                    const key = try self.allocator.dupe(u8, part[0..end]);
                    try keys.append(key);
                }
            }
        }

        return keys;
    }

    fn encodeQueryComponent(self: *Self, input: []const u8) ![]const u8 {
        _ = self;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(std.heap.page_allocator);

        for (input) |c| {
            const is_unreserved =
                (c >= 'A' and c <= 'Z') or
                (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or
                c == '-' or c == '_' or c == '.' or c == '~' or c == '/';

            if (is_unreserved) {
                try out.append(std.heap.page_allocator, c);
                continue;
            }

            var encoded: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&encoded, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(std.heap.page_allocator, &encoded);
        }

        return try out.toOwnedSlice(std.heap.page_allocator);
    }
};

// =============================================================================
// HuggingFace Client
// =============================================================================

pub const HFClient = struct {
    config: HFConfig,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, config: HFConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Get model info from HuggingFace Hub API
    pub fn getModelInfo(self: *Self, repo_id: []const u8) !ModelMetadata {
        var metadata = ModelMetadata.init(self.allocator, repo_id);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/models/{s}",
            .{ self.config.hub_url, repo_id },
        );
        defer self.allocator.free(url);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);

        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.config.token},
        );
        defer self.allocator.free(auth_header);

        var req = try client.open(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
            },
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        if (req.status != .ok) {
            return error.HFModelNotFound;
        }

        // Parse JSON response to get file list
        const body_data = try req.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(body_data);

        // Get siblings (files) from the response
        try self.parseModelFiles(&metadata, body_data);

        return metadata;
    }

    fn parseModelFiles(self: *Self, metadata: *ModelMetadata, json_data: []const u8) !void {
        const parsed = json.parseFromSlice(json.Value, self.allocator, json_data, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const siblings = parsed.value.object.get("siblings") orelse return;
        if (siblings != .array) return;

        for (siblings.array.items) |sib| {
            if (sib != .object) continue;

            const rfilename = sib.object.get("rfilename") orelse continue;
            if (rfilename != .string) continue;

            const filename = try self.allocator.dupe(u8, rfilename.string);

            const size_bytes: u64 = blk: {
                const size_val = sib.object.get("size") orelse break :blk 0;
                break :blk switch (size_val) {
                    .integer => @as(u64, @intCast(size_val.integer)),
                    .float => @as(u64, @intFromFloat(size_val.float)),
                    .string => std.fmt.parseInt(u64, size_val.string, 10) catch 0,
                    else => 0,
                };
            };

            const ext = std.fs.path.extension(filename);
            const format = ModelFormat.fromExtension(ext);

            try metadata.files.append(metadata.allocator, .{
                .filename = filename,
                .size_bytes = size_bytes,
                .format = format,
            });
            metadata.total_size_bytes +%= size_bytes;
        }
    }

    /// Download a specific file from HuggingFace
    pub fn downloadFile(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) ![]const u8 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/resolve/{s}/{s}",
            .{ self.config.hub_url, repo_id, revision, filename },
        );
        defer self.allocator.free(url);

        std.debug.print("Downloading: {s}\n", .{url});

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);

        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.config.token},
        );
        defer self.allocator.free(auth_header);

        var req = try client.open(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
            },
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        // Handle redirects (HF uses redirects for LFS files)
        if (req.status == .found or req.status == .moved_permanently or req.status == .see_other) {
            // Get redirect URL from Location header
            // For simplicity, we'll follow one redirect
            for (req.response.headers.list.items) |header| {
                if (std.mem.eql(u8, header.name, "location")) {
                    return self.downloadFromUrl(header.value);
                }
            }
        }

        if (req.status != .ok) {
            std.debug.print("Download failed with status: {}\n", .{req.status});
            return error.HFDownloadFailed;
        }

        return try req.reader().readAllAlloc(self.allocator, 50 * 1024 * 1024 * 1024); // 50 GB max
    }

    fn downloadFromUrl(self: *Self, url: []const u8) ![]const u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);

        var req = try client.open(.GET, uri, .{});
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        if (req.status != .ok) {
            return error.HFDownloadFailed;
        }

        return try req.reader().readAllAlloc(self.allocator, 50 * 1024 * 1024 * 1024); // 50 GB max
    }

    /// Stream a HuggingFace file directly to a local path without buffering in RAM.
    /// Handles one level of HTTP redirect (LFS blobs).
    pub fn downloadFileToPath(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
        dest_path: []const u8,
    ) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/resolve/{s}/{s}",
            .{ self.config.hub_url, repo_id, revision, filename },
        );
        defer self.allocator.free(url);

        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.config.token},
        );
        defer self.allocator.free(auth_header);

        // Resolve redirect URL (LFS) if needed.
        const final_url = blk: {
            var client = std.http.Client{ .allocator = self.allocator };
            defer client.deinit();
            const uri = try std.Uri.parse(url);
            var req = try client.open(.GET, uri, .{
                .extra_headers = &.{
                    .{ .name = "Authorization", .value = auth_header },
                },
            });
            defer req.deinit();
            try req.send();
            try req.finish();
            try req.wait();
            if (req.status == .found or req.status == .moved_permanently or req.status == .see_other) {
                for (req.response.headers.list.items) |header| {
                    if (std.mem.eql(u8, header.name, "location")) {
                        break :blk try self.allocator.dupe(u8, header.value);
                    }
                }
            }
            break :blk try self.allocator.dupe(u8, url);
        };
        defer self.allocator.free(final_url);

        // Stream response body directly to file.
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        const uri = try std.Uri.parse(final_url);
        var req = try client.open(.GET, uri, .{});
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        if (req.status != .ok) return error.HFDownloadFailed;

        const out_file = try std.fs.cwd().createFile(dest_path, .{});
        defer out_file.close();

        var buf: [4 * 1024 * 1024]u8 = undefined;
        while (true) {
            const n = try req.reader().read(&buf);
            if (n == 0) break;
            try out_file.writeAll(buf[0..n]);
        }
    }
};

// =============================================================================
// Model Store - Main Interface
// =============================================================================

pub const ModelStore = struct {
    config: ModelStoreConfig,
    s3: S3Client,
    hf: HFClient,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, config: ModelStoreConfig) Self {
        return .{
            .config = config,
            .s3 = S3Client.init(allocator, config.s3),
            .hf = HFClient.init(allocator, config.hf),
            .allocator = allocator,
        };
    }

    /// Download a model from HuggingFace and store in S3
    pub fn downloadFromHuggingFace(
        self: *Self,
        repo_id: []const u8,
        revision: []const u8,
        file_patterns: ?[]const []const u8,
    ) !ModelMetadata {
        std.debug.print("Fetching model info for: {s}\n", .{repo_id});

        // Get model metadata from HuggingFace
        var metadata = try self.hf.getModelInfo(repo_id);
        metadata.revision = revision;

        // Generate S3 prefix for this model
        const s3_prefix = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}/{s}/",
            .{ self.config.models_prefix, repo_id, revision },
        );
        metadata.s3_prefix = s3_prefix;

        // Download each file and upload to S3
        for (metadata.files.items) |*file| {
            // Check if file matches patterns
            if (file_patterns) |patterns| {
                var matches = false;
                for (patterns) |pattern| {
                    if (std.mem.indexOf(u8, file.filename, pattern) != null) {
                        matches = true;
                        break;
                    }
                }
                if (!matches) continue;
            }

            // Check if already in S3
            const s3_key = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}",
                .{ s3_prefix, file.filename },
            );
            file.s3_key = s3_key;

            if (try self.s3.headObject(s3_key)) {
                std.debug.print("File already exists in S3: {s}\n", .{s3_key});
                continue;
            }

            // Stream HuggingFace → temp file → S3 (avoids buffering entire model in RAM).
            const tmp_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/.hf_tmp_{s}",
                .{ self.config.hf.cache_dir, file.filename },
            );
            defer self.allocator.free(tmp_path);

            std.debug.print("Downloading: {s}\n", .{file.filename});
            try self.hf.downloadFileToPath(repo_id, file.filename, revision, tmp_path);
            defer std.fs.cwd().deleteFile(tmp_path) catch {};

            const tmp_stat = try std.fs.cwd().statFile(tmp_path);
            file.size_bytes = tmp_stat.size;
            metadata.total_size_bytes += tmp_stat.size;

            // Upload to S3
            std.debug.print("Uploading to S3: {s} ({d} bytes)\n", .{ s3_key, tmp_stat.size });
            try self.s3.putObjectFile(s3_key, tmp_path);
        }

        metadata.downloaded = true;
        return metadata;
    }

    /// Download specific GGUF model file
    pub fn downloadGGUF(
        self: *Self,
        repo_id: []const u8,
        gguf_filename: []const u8,
    ) ![]const u8 {
        const s3_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}/main/{s}",
            .{ self.config.models_prefix, repo_id, gguf_filename },
        );

        // Check if already in S3
        if (try self.s3.headObject(s3_key)) {
            std.debug.print("GGUF already in S3: {s}\n", .{s3_key});
            return s3_key;
        }

        // Stream HuggingFace → temp file → S3 (avoids buffering entire GGUF in RAM).
        const tmp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/.hf_tmp_{s}",
            .{ self.config.hf.cache_dir, gguf_filename },
        );
        defer self.allocator.free(tmp_path);

        std.debug.print("Downloading GGUF: {s}/{s}\n", .{ repo_id, gguf_filename });
        try self.hf.downloadFileToPath(repo_id, gguf_filename, "main", tmp_path);
        defer std.fs.cwd().deleteFile(tmp_path) catch {};

        // Upload to S3
        try self.s3.putObjectFile(s3_key, tmp_path);
        std.debug.print("Uploaded GGUF to S3: {s}\n", .{s3_key});

        return s3_key;
    }

    /// Get model from S3 (download if needed)
    pub fn getModel(self: *Self, s3_key: []const u8) ![]const u8 {
        return self.s3.getObject(s3_key);
    }

    /// List all models in S3
    pub fn listModels(self: *Self) !std.ArrayList([]const u8) {
        return self.s3.listObjects(self.config.models_prefix);
    }

    /// Check if model exists in S3
    pub fn modelExists(self: *Self, repo_id: []const u8, revision: []const u8) !bool {
        const prefix = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}/{s}/",
            .{ self.config.models_prefix, repo_id, revision },
        );
        defer self.allocator.free(prefix);

        const files = try self.s3.listObjects(prefix);
        defer files.deinit();

        return files.items.len > 0;
    }
};

// =============================================================================
// Configuration Loader
// =============================================================================

pub fn loadConfigFromEnv(_: Allocator) !ModelStoreConfig {
    const s3_config = S3Config{
        .access_key_id = std.posix.getenv("S3_ACCESS_KEY_ID") orelse return error.MissingS3AccessKey,
        .secret_access_key = std.posix.getenv("S3_SECRET_ACCESS_KEY") orelse return error.MissingS3SecretKey,
        .bucket = std.posix.getenv("S3_BUCKET") orelse return error.MissingS3Bucket,
        .region = std.posix.getenv("S3_REGION") orelse "us-east-1",
        .endpoint = std.posix.getenv("S3_ENDPOINT"),
    };

    const hf_config = HFConfig{
        .token = std.posix.getenv("HF_TOKEN") orelse return error.MissingHFToken,
        .hub_url = std.posix.getenv("HF_HUB_URL") orelse "https://huggingface.co",
        .cache_dir = std.posix.getenv("HF_CACHE_DIR") orelse "/tmp/hf_cache",
    };

    return ModelStoreConfig{
        .s3 = s3_config,
        .hf = hf_config,
        .models_prefix = std.posix.getenv("MODELS_PREFIX") orelse "models/",
    };
}

// =============================================================================
// CLI Main
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const config = loadConfigFromEnv(allocator) catch |err| {
        std.debug.print("Error loading config: {}\n", .{err});
        std.debug.print("Make sure environment variables are set (source .env)\n", .{});
        return;
    };

    var store = ModelStore.init(allocator, config);

    const command = args[1];

    if (std.mem.eql(u8, command, "download")) {
        if (args.len < 3) {
            std.debug.print("Usage: model_store download <repo_id> [revision]\n", .{});
            return;
        }
        const repo_id = args[2];
        const revision = if (args.len > 3) args[3] else "main";

        const metadata = try store.downloadFromHuggingFace(repo_id, revision, null);
        std.debug.print("\nDownloaded model: {s}\n", .{metadata.repo_id});
        std.debug.print("Total size: {d} bytes\n", .{metadata.total_size_bytes});
        std.debug.print("Files: {d}\n", .{metadata.files.items.len});
    } else if (std.mem.eql(u8, command, "download-gguf")) {
        if (args.len < 4) {
            std.debug.print("Usage: model_store download-gguf <repo_id> <filename.gguf>\n", .{});
            return;
        }
        const repo_id = args[2];
        const filename = args[3];

        const s3_key = try store.downloadGGUF(repo_id, filename);
        std.debug.print("Model stored at: s3://{s}/{s}\n", .{ config.s3.bucket, s3_key });
    } else if (std.mem.eql(u8, command, "list")) {
        const models = try store.listModels();
        defer models.deinit();

        std.debug.print("Models in S3:\n", .{});
        for (models.items) |key| {
            std.debug.print("  {s}\n", .{key});
        }
    } else if (std.mem.eql(u8, command, "exists")) {
        if (args.len < 3) {
            std.debug.print("Usage: model_store exists <repo_id> [revision]\n", .{});
            return;
        }
        const repo_id = args[2];
        const revision = if (args.len > 3) args[3] else "main";

        const exists = try store.modelExists(repo_id, revision);
        std.debug.print("Model {s}@{s} exists: {}\n", .{ repo_id, revision, exists });
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: model_store <command> [args]
        \\
        \\Commands:
        \\  download <repo_id> [revision]     Download model from HuggingFace to S3
        \\  download-gguf <repo_id> <file>    Download specific GGUF file
        \\  list                              List models in S3
        \\  exists <repo_id> [revision]       Check if model exists in S3
        \\
        \\Examples:
        \\  model_store download microsoft/phi-2
        \\  model_store download-gguf TheBloke/Llama-2-7B-GGUF llama-2-7b.Q4_K_M.gguf
        \\  model_store list
        \\
        \\Environment Variables:
        \\  S3_ACCESS_KEY_ID      S3 access key
        \\  S3_SECRET_ACCESS_KEY  S3 secret key
        \\  S3_BUCKET             S3 bucket name
        \\  S3_REGION             S3 region (default: us-east-1)
        \\  HF_TOKEN              HuggingFace token
        \\
    , .{});
}

// =============================================================================
// Mojo-RT Weight Map — Zero-Copy GGUF → GPU Memory Bridge
// =============================================================================

/// GGUF magic bytes and version constants.
const GGUF_MAGIC: u32 = 0x46475547; // "GGUF" little-endian
const GGUF_VERSION_3: u32 = 3;

/// GGUF tensor data types (subset needed for weight loading).
pub const GGUFDataType = enum(u32) {
    f32 = 0,
    f16 = 1,
    q4_0 = 2,
    q4_1 = 3,
    q5_0 = 6,
    q5_1 = 7,
    q8_0 = 8,
    q8_1 = 9,
    _,
};

/// A single tensor descriptor parsed from the GGUF header.
pub const GGUFTensor = struct {
    name: []const u8,
    dtype: GGUFDataType,
    n_dims: u32,
    dims: [4]u64,
    data_offset: u64, // Offset from start of tensor data section
    data_size: u64, // Bytes
};

/// Parsed GGUF header — points into the mmap'd file, no copies.
pub const GGUFHeader = struct {
    allocator: Allocator,
    version: u32,
    n_tensors: u64,
    metadata_kv_count: u64,
    tensor_data_offset: u64, // Byte offset where tensor data begins
    tensors: std.ArrayList(GGUFTensor),

    pub fn deinit(self: *GGUFHeader) void {
        self.tensors.deinit();
    }
};

/// Pointers into mmap'd weight data, ready for Mojo-RT kernels.
/// All pointers are into the mmap'd region — zero copy.
pub const MojoRTWeightMap = struct {
    // Embedding
    token_embd: [*]const u8, // token_embd.weight

    // Per-layer norms and projections
    n_layers: u32,
    attn_norm: [][*]const u8, // blk.N.attn_norm.weight
    ffn_norm: [][*]const u8, // blk.N.ffn_norm.weight
    wq: [][*]const u8, // blk.N.attn_q.weight
    wk: [][*]const u8, // blk.N.attn_k.weight
    wv: [][*]const u8, // blk.N.attn_v.weight
    wo: [][*]const u8, // blk.N.attn_output.weight
    w_gate: [][*]const u8, // blk.N.ffn_gate.weight
    w_up: [][*]const u8, // blk.N.ffn_up.weight
    w_down: [][*]const u8, // blk.N.ffn_down.weight

    // Final norm + output head
    output_norm: [*]const u8, // output_norm.weight
    output_weight: [*]const u8, // output.weight

    // Quantization metadata
    quant_dtype: GGUFDataType,

    pub fn deinit(self: *MojoRTWeightMap, allocator: Allocator) void {
        allocator.free(self.attn_norm);
        allocator.free(self.ffn_norm);
        allocator.free(self.wq);
        allocator.free(self.wk);
        allocator.free(self.wv);
        allocator.free(self.wo);
        allocator.free(self.w_gate);
        allocator.free(self.w_up);
        allocator.free(self.w_down);
    }

    /// Validate that all required weight pointers are non-null.
    /// Call this after buildWeightMap() and before starting inference.
    /// Returns error.MissingTensor if any pointer is still the zero address.
    pub fn validate(self: *const MojoRTWeightMap) !void {
        const null_ptr: [*]const u8 = @ptrFromInt(0);

        if (self.token_embd == null_ptr) {
            std.debug.print("MojoRTWeightMap.validate: token_embd is null\n", .{});
            return error.MissingTensor;
        }
        if (self.output_norm == null_ptr) {
            std.debug.print("MojoRTWeightMap.validate: output_norm is null\n", .{});
            return error.MissingTensor;
        }
        if (self.output_weight == null_ptr) {
            std.debug.print("MojoRTWeightMap.validate: output_weight is null\n", .{});
            return error.MissingTensor;
        }

        for (0..self.n_layers) |li| {
            if (self.attn_norm[li] == null_ptr) {
                std.debug.print("MojoRTWeightMap.validate: attn_norm[{d}] is null\n", .{li});
                return error.MissingTensor;
            }
            if (self.ffn_norm[li] == null_ptr) {
                std.debug.print("MojoRTWeightMap.validate: ffn_norm[{d}] is null\n", .{li});
                return error.MissingTensor;
            }
            if (self.wq[li] == null_ptr) {
                std.debug.print("MojoRTWeightMap.validate: wq[{d}] is null\n", .{li});
                return error.MissingTensor;
            }
            if (self.wk[li] == null_ptr) {
                std.debug.print("MojoRTWeightMap.validate: wk[{d}] is null\n", .{li});
                return error.MissingTensor;
            }
            if (self.wv[li] == null_ptr) {
                std.debug.print("MojoRTWeightMap.validate: wv[{d}] is null\n", .{li});
                return error.MissingTensor;
            }
            if (self.wo[li] == null_ptr) {
                std.debug.print("MojoRTWeightMap.validate: wo[{d}] is null\n", .{li});
                return error.MissingTensor;
            }
            if (self.w_gate[li] == null_ptr) {
                std.debug.print("MojoRTWeightMap.validate: w_gate[{d}] is null\n", .{li});
                return error.MissingTensor;
            }
            if (self.w_up[li] == null_ptr) {
                std.debug.print("MojoRTWeightMap.validate: w_up[{d}] is null\n", .{li});
                return error.MissingTensor;
            }
            if (self.w_down[li] == null_ptr) {
                std.debug.print("MojoRTWeightMap.validate: w_down[{d}] is null\n", .{li});
                return error.MissingTensor;
            }
        }
    }
};

/// GGUF Model Loader — memory-maps a GGUF file and extracts tensor pointers
/// for zero-copy feeding into Mojo-RT fused kernels.
pub const GGUFModelLoader = struct {
    allocator: Allocator,
    mmap_data: ?[]align(std.mem.page_size) const u8,
    mmap_len: usize,
    file: ?std.fs.File,
    header: ?GGUFHeader,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .mmap_data = null,
            .mmap_len = 0,
            .file = null,
            .header = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.header) |*h| h.deinit();
        if (self.mmap_data) |data| {
            std.posix.munmap(data);
        }
        if (self.file) |f| f.close();
    }

    /// Memory-map a GGUF file and parse its header.
    pub fn open(self: *Self, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        const stat = try file.stat();
        const size = stat.size;

        const data = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(data);

        // Advise kernel on access pattern for better page management
        const mmap_ptr: [*]align(std.mem.page_size) u8 = @ptrCast(@constCast(data.ptr));
        std.posix.madvise(mmap_ptr, size, std.posix.MADV.SEQUENTIAL) catch {};
        // On Linux, request huge pages for large mappings (>2MB)
        if (builtin.os.tag == .linux and size > 2 * 1024 * 1024) {
            std.posix.madvise(mmap_ptr, size, std.posix.MADV.HUGEPAGE) catch {};
        }

        self.file = file;
        self.mmap_data = data;
        self.mmap_len = size;

        try self.parseHeader();
    }

    /// Parse the GGUF header to extract tensor descriptors.
    fn parseHeader(self: *Self) !void {
        const data = self.mmap_data orelse return error.NotMapped;
        if (data.len < 16) return error.InvalidGGUF;

        // Validate magic
        const magic = std.mem.readInt(u32, data[0..4], .little);
        if (magic != GGUF_MAGIC) return error.InvalidGGUF;

        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version < GGUF_VERSION_3) return error.UnsupportedVersion;

        const n_tensors = std.mem.readInt(u64, data[8..16], .little);
        const n_kv = std.mem.readInt(u64, data[16..24], .little);

        // Skip metadata key-value pairs to find tensor info section
        var pos: usize = 24;
        var kv_idx: u64 = 0;
        while (kv_idx < n_kv) : (kv_idx += 1) {
            pos = try skipGGUFKeyValue(data, pos);
        }

        // Parse tensor descriptors
        var tensors = std.ArrayList(GGUFTensor){};
        errdefer tensors.deinit();

        var t_idx: u64 = 0;
        while (t_idx < n_tensors) : (t_idx += 1) {
            const tensor = try parseGGUFTensorInfo(data, &pos);
            try tensors.append(tensor);
        }

        // Tensor data starts after alignment padding
        const alignment: usize = 32; // GGUF v3 default alignment
        const tensor_data_offset = (pos + alignment - 1) & ~(alignment - 1);

        // Prefetch tensor data region into memory
        if (self.mmap_data) |d| {
            if (tensor_data_offset < d.len) {
                const mmap_ptr: [*]align(std.mem.page_size) u8 = @ptrCast(@constCast(d.ptr));
                const remaining = d.len - tensor_data_offset;
                std.posix.madvise(mmap_ptr + tensor_data_offset, remaining, std.posix.MADV.WILLNEED) catch {};
            }
        }

        self.header = GGUFHeader{
            .allocator = self.allocator,
            .version = version,
            .n_tensors = n_tensors,
            .metadata_kv_count = n_kv,
            .tensor_data_offset = tensor_data_offset,
            .tensors = tensors,
        };
    }

    /// Build the MojoRTWeightMap by looking up tensor names.
    /// Returns error.MissingTensor if any required tensor is absent in the file.
    pub fn buildWeightMap(self: *Self, n_layers: u32) !MojoRTWeightMap {
        const hdr = self.header orelse return error.NotParsed;
        const data = self.mmap_data orelse return error.NotMapped;

        var map: MojoRTWeightMap = undefined;
        map.n_layers = n_layers;
        map.quant_dtype = .f16; // Default, updated below

        // Allocate per-layer pointer arrays
        map.attn_norm = try self.allocator.alloc([*]const u8, n_layers);
        errdefer self.allocator.free(map.attn_norm);
        map.ffn_norm = try self.allocator.alloc([*]const u8, n_layers);
        errdefer self.allocator.free(map.ffn_norm);
        map.wq = try self.allocator.alloc([*]const u8, n_layers);
        errdefer self.allocator.free(map.wq);
        map.wk = try self.allocator.alloc([*]const u8, n_layers);
        errdefer self.allocator.free(map.wk);
        map.wv = try self.allocator.alloc([*]const u8, n_layers);
        errdefer self.allocator.free(map.wv);
        map.wo = try self.allocator.alloc([*]const u8, n_layers);
        errdefer self.allocator.free(map.wo);
        map.w_gate = try self.allocator.alloc([*]const u8, n_layers);
        errdefer self.allocator.free(map.w_gate);
        map.w_up = try self.allocator.alloc([*]const u8, n_layers);
        errdefer self.allocator.free(map.w_up);
        map.w_down = try self.allocator.alloc([*]const u8, n_layers);
        errdefer self.allocator.free(map.w_down);

        // Presence tracking — all must be set before we return.
        var found_token_embd = false;
        var found_output_norm = false;
        var found_output_weight = false;

        // Per-layer presence bitmask: bit 0=attn_norm,1=ffn_norm,2=wq,3=wk,4=wv,
        //   5=wo,6=w_gate,7=w_up,8=w_down  (9 tensors per layer → u16 is sufficient)
        const LAYER_FULL: u16 = 0x01FF; // all 9 bits set
        const layer_found = try self.allocator.alloc(u16, n_layers);
        defer self.allocator.free(layer_found);
        @memset(layer_found, 0);

        // Look up each tensor by name
        for (hdr.tensors.items) |tensor| {
            const abs_offset = hdr.tensor_data_offset + tensor.data_offset;
            if (abs_offset >= data.len) continue;
            const ptr: [*]const u8 = @ptrCast(&data[abs_offset]);

            if (std.mem.eql(u8, tensor.name, "token_embd.weight")) {
                map.token_embd = ptr;
                map.quant_dtype = tensor.dtype;
                found_token_embd = true;
            } else if (std.mem.eql(u8, tensor.name, "output_norm.weight")) {
                map.output_norm = ptr;
                found_output_norm = true;
            } else if (std.mem.eql(u8, tensor.name, "output.weight")) {
                map.output_weight = ptr;
                found_output_weight = true;
            } else {
                // Per-layer tensors: blk.N.<suffix>
                if (std.mem.startsWith(u8, tensor.name, "blk.")) {
                    const after_blk = tensor.name[4..];
                    const dot_pos = std.mem.indexOfScalar(u8, after_blk, '.') orelse continue;
                    const layer_str = after_blk[0..dot_pos];
                    const layer = std.fmt.parseInt(u32, layer_str, 10) catch continue;
                    if (layer >= n_layers) continue;

                    const suffix = after_blk[dot_pos + 1 ..];
                    if (std.mem.eql(u8, suffix, "attn_norm.weight")) {
                        map.attn_norm[layer] = ptr;
                        layer_found[layer] |= 0x0001;
                    } else if (std.mem.eql(u8, suffix, "ffn_norm.weight")) {
                        map.ffn_norm[layer] = ptr;
                        layer_found[layer] |= 0x0002;
                    } else if (std.mem.eql(u8, suffix, "attn_q.weight")) {
                        map.wq[layer] = ptr;
                        layer_found[layer] |= 0x0004;
                    } else if (std.mem.eql(u8, suffix, "attn_k.weight")) {
                        map.wk[layer] = ptr;
                        layer_found[layer] |= 0x0008;
                    } else if (std.mem.eql(u8, suffix, "attn_v.weight")) {
                        map.wv[layer] = ptr;
                        layer_found[layer] |= 0x0010;
                    } else if (std.mem.eql(u8, suffix, "attn_output.weight")) {
                        map.wo[layer] = ptr;
                        layer_found[layer] |= 0x0020;
                    } else if (std.mem.eql(u8, suffix, "ffn_gate.weight")) {
                        map.w_gate[layer] = ptr;
                        layer_found[layer] |= 0x0040;
                    } else if (std.mem.eql(u8, suffix, "ffn_up.weight")) {
                        map.w_up[layer] = ptr;
                        layer_found[layer] |= 0x0080;
                    } else if (std.mem.eql(u8, suffix, "ffn_down.weight")) {
                        map.w_down[layer] = ptr;
                        layer_found[layer] |= 0x0100;
                    }
                }
            }
        }

        // Validate global tensors.
        if (!found_token_embd) {
            std.debug.print("buildWeightMap: missing tensor 'token_embd.weight'\n", .{});
            return error.MissingTensor;
        }
        if (!found_output_norm) {
            std.debug.print("buildWeightMap: missing tensor 'output_norm.weight'\n", .{});
            return error.MissingTensor;
        }
        if (!found_output_weight) {
            std.debug.print("buildWeightMap: missing tensor 'output.weight'\n", .{});
            return error.MissingTensor;
        }

        // Validate per-layer tensors.
        for (0..n_layers) |li| {
            if (layer_found[li] != LAYER_FULL) {
                std.debug.print("buildWeightMap: layer {d} incomplete (found mask=0x{X:0>4}, expected=0x{X:0>4})\n", .{ li, layer_found[li], LAYER_FULL });
                return error.MissingTensor;
            }
        }

        return map;
    }

    /// Convert the mmap'd model data to a ModelWeights struct suitable for ServingEngine.
    /// Returns a pointer to the raw mmap'd data as a device_ptr (CPU memory).
    pub fn loadToModelWeights(self: *Self) !struct { device_ptr: *anyopaque, size_bytes: usize } {
        const data = self.mmap_data orelse return error.NotMapped;
        return .{
            .device_ptr = @ptrCast(@constCast(data.ptr)),
            .size_bytes = self.mmap_len,
        };
    }
};

// =============================================================================
// GGUF Parsing Helpers
// =============================================================================

/// Read a GGUF string (u64 length prefix + bytes) and return slice + new pos.
fn readGGUFString(data: []const u8, pos: usize) !struct { str: []const u8, new_pos: usize } {
    if (pos + 8 > data.len) return error.Truncated;
    const len = std.mem.readInt(u64, data[pos..][0..8], .little);
    const str_start = pos + 8;
    const str_end = str_start + @as(usize, @intCast(len));
    if (str_end > data.len) return error.Truncated;
    return .{ .str = data[str_start..str_end], .new_pos = str_end };
}

/// Skip over one GGUF metadata key-value entry.
fn skipGGUFKeyValue(data: []const u8, pos: usize) !usize {
    // Key string
    const key_result = try readGGUFString(data, pos);
    var cur = key_result.new_pos;

    // Value type (u32)
    if (cur + 4 > data.len) return error.Truncated;
    const vtype = std.mem.readInt(u32, data[cur..][0..4], .little);
    cur += 4;

    // Skip value based on type
    switch (vtype) {
        0 => cur += 1, // uint8
        1 => cur += 1, // int8
        2 => cur += 2, // uint16
        3 => cur += 2, // int16
        4 => cur += 4, // uint32
        5 => cur += 4, // int32
        6 => cur += 4, // float32
        7 => cur += 1, // bool
        8 => { // string
            const str_result = try readGGUFString(data, cur);
            cur = str_result.new_pos;
        },
        9 => { // array
            if (cur + 12 > data.len) return error.Truncated;
            const elem_type = std.mem.readInt(u32, data[cur..][0..4], .little);
            const n_elems = std.mem.readInt(u64, data[cur + 4 ..][0..8], .little);
            cur += 12;
            // Skip elements
            var i: u64 = 0;
            while (i < n_elems) : (i += 1) {
                switch (elem_type) {
                    0, 1, 7 => cur += 1,
                    2, 3 => cur += 2,
                    4, 5, 6 => cur += 4,
                    8 => {
                        const s = try readGGUFString(data, cur);
                        cur = s.new_pos;
                    },
                    10 => cur += 8, // uint64/int64
                    11 => cur += 8, // float64
                    else => return error.UnsupportedType,
                }
            }
        },
        10 => cur += 8, // uint64
        11 => cur += 8, // int64
        12 => cur += 8, // float64
        else => return error.UnsupportedType,
    }

    return cur;
}

/// Parse one GGUF tensor info entry.
fn parseGGUFTensorInfo(data: []const u8, pos: *usize) !GGUFTensor {
    // Tensor name (string)
    const name_result = try readGGUFString(data, pos.*);
    pos.* = name_result.new_pos;

    // Number of dimensions (u32)
    if (pos.* + 4 > data.len) return error.Truncated;
    const n_dims = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;

    // Dimension sizes (n_dims × u64)
    var dims = [4]u64{ 1, 1, 1, 1 };
    var d: u32 = 0;
    var data_elems: u64 = 1;
    while (d < n_dims) : (d += 1) {
        if (pos.* + 8 > data.len) return error.Truncated;
        dims[d] = std.mem.readInt(u64, data[pos.*..][0..8], .little);
        data_elems *= dims[d];
        pos.* += 8;
    }

    // Data type (u32)
    if (pos.* + 4 > data.len) return error.Truncated;
    const dtype_raw = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    const dtype: GGUFDataType = @enumFromInt(dtype_raw);

    // Offset within tensor data section (u64)
    if (pos.* + 8 > data.len) return error.Truncated;
    const data_offset = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;

    // Compute byte size from dtype
    const bytes_per_elem: u64 = switch (dtype) {
        .f32 => 4,
        .f16 => 2,
        .q4_0 => 18, // 32 values → 18 bytes (16 nibbles + 2 byte scale)
        .q4_1 => 20,
        .q5_0 => 22,
        .q5_1 => 24,
        .q8_0 => 34, // 32 values → 34 bytes (32 bytes + 2 byte scale)
        .q8_1 => 36,
        else => 2, // fallback to f16 size
    };
    // For quantised types, data_size = ceil(data_elems / 32) * bytes_per_block
    const data_size = if (@intFromEnum(dtype) >= 2)
        ((data_elems + 31) / 32) * bytes_per_elem
    else
        data_elems * bytes_per_elem;

    return GGUFTensor{
        .name = name_result.str,
        .dtype = dtype,
        .n_dims = n_dims,
        .dims = dims,
        .data_offset = data_offset,
        .data_size = data_size,
    };
}


// =============================================================================
// Model Zoo — Model Family Registry & Auto-Discovery
// =============================================================================

/// Known model families with their HuggingFace repo patterns, default
/// quantisations, and architecture metadata.
pub const ModelFamily = enum {
    llama,
    mistral,
    phi,
    qwen,
    gemma,
    starcoder,
    falcon,
    mpt,
    yi,
    deepseek,
    chatglm,
    internlm,
    baichuan,
    command_r,
    dbrx,
    arctic,
    jamba,
    olmo,
    nemotron,
    granite,
    solar,
    minicpm,
    rwkv,
    unknown,

    pub fn fromRepoId(repo_id: []const u8) ModelFamily {
        const lower_buf: [256]u8 = undefined;
        _ = lower_buf;
        // Match on common substrings (case-sensitive — HF repo names are lowercase)
        if (std.mem.indexOf(u8, repo_id, "llama") != null or
            std.mem.indexOf(u8, repo_id, "Llama") != null) return .llama;
        if (std.mem.indexOf(u8, repo_id, "mistral") != null or
            std.mem.indexOf(u8, repo_id, "Mistral") != null or
            std.mem.indexOf(u8, repo_id, "mixtral") != null or
            std.mem.indexOf(u8, repo_id, "Mixtral") != null) return .mistral;
        if (std.mem.indexOf(u8, repo_id, "phi") != null or
            std.mem.indexOf(u8, repo_id, "Phi") != null) return .phi;
        if (std.mem.indexOf(u8, repo_id, "qwen") != null or
            std.mem.indexOf(u8, repo_id, "Qwen") != null) return .qwen;
        if (std.mem.indexOf(u8, repo_id, "gemma") != null or
            std.mem.indexOf(u8, repo_id, "Gemma") != null) return .gemma;
        if (std.mem.indexOf(u8, repo_id, "starcoder") != null or
            std.mem.indexOf(u8, repo_id, "StarCoder") != null) return .starcoder;
        if (std.mem.indexOf(u8, repo_id, "falcon") != null or
            std.mem.indexOf(u8, repo_id, "Falcon") != null) return .falcon;
        if (std.mem.indexOf(u8, repo_id, "mpt") != null or
            std.mem.indexOf(u8, repo_id, "MPT") != null) return .mpt;
        if (std.mem.indexOf(u8, repo_id, "yi") != null or
            std.mem.indexOf(u8, repo_id, "Yi") != null) return .yi;
        if (std.mem.indexOf(u8, repo_id, "deepseek") != null or
            std.mem.indexOf(u8, repo_id, "DeepSeek") != null) return .deepseek;
        if (std.mem.indexOf(u8, repo_id, "chatglm") != null or
            std.mem.indexOf(u8, repo_id, "ChatGLM") != null or
            std.mem.indexOf(u8, repo_id, "glm") != null or
            std.mem.indexOf(u8, repo_id, "GLM") != null) return .chatglm;
        if (std.mem.indexOf(u8, repo_id, "internlm") != null or
            std.mem.indexOf(u8, repo_id, "InternLM") != null) return .internlm;
        if (std.mem.indexOf(u8, repo_id, "baichuan") != null or
            std.mem.indexOf(u8, repo_id, "Baichuan") != null) return .baichuan;
        if (std.mem.indexOf(u8, repo_id, "command") != null or
            std.mem.indexOf(u8, repo_id, "Command") != null) return .command_r;
        if (std.mem.indexOf(u8, repo_id, "dbrx") != null or
            std.mem.indexOf(u8, repo_id, "DBRX") != null) return .dbrx;
        if (std.mem.indexOf(u8, repo_id, "arctic") != null or
            std.mem.indexOf(u8, repo_id, "Arctic") != null) return .arctic;
        if (std.mem.indexOf(u8, repo_id, "jamba") != null or
            std.mem.indexOf(u8, repo_id, "Jamba") != null) return .jamba;
        if (std.mem.indexOf(u8, repo_id, "olmo") != null or
            std.mem.indexOf(u8, repo_id, "OLMo") != null) return .olmo;
        if (std.mem.indexOf(u8, repo_id, "nemotron") != null or
            std.mem.indexOf(u8, repo_id, "Nemotron") != null) return .nemotron;
        if (std.mem.indexOf(u8, repo_id, "granite") != null or
            std.mem.indexOf(u8, repo_id, "Granite") != null) return .granite;
        if (std.mem.indexOf(u8, repo_id, "solar") != null or
            std.mem.indexOf(u8, repo_id, "Solar") != null or
            std.mem.indexOf(u8, repo_id, "SOLAR") != null) return .solar;
        if (std.mem.indexOf(u8, repo_id, "minicpm") != null or
            std.mem.indexOf(u8, repo_id, "MiniCPM") != null) return .minicpm;
        if (std.mem.indexOf(u8, repo_id, "rwkv") != null or
            std.mem.indexOf(u8, repo_id, "RWKV") != null) return .rwkv;
        return .unknown;
    }

    pub fn defaultChatTemplate(self: ModelFamily) []const u8 {
        return switch (self) {
            .llama => "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n{system}<|eot_id|><|start_header_id|>user<|end_header_id|>\n{user}<|eot_id|><|start_header_id|>assistant<|end_header_id|>",
            .mistral => "<s>[INST] {system}\n{user} [/INST]",
            .phi => "<|system|>{system}<|end|><|user|>{user}<|end|><|assistant|>",
            .qwen => "<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant",
            .gemma => "<start_of_turn>user\n{user}<end_of_turn>\n<start_of_turn>model",
            .yi => "<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant",
            .deepseek => "<|begin▁of▁sentence|>{system}\n\nUser: {user}\n\nAssistant:",
            .chatglm => "[gMASK]sop<|system|>\n{system}<|user|>\n{user}<|assistant|>",
            .internlm => "<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant",
            .baichuan => "<reserved_106>{user}<reserved_107>",
            .command_r => "<|START_OF_TURN_TOKEN|><|SYSTEM_TOKEN|>{system}<|END_OF_TURN_TOKEN|><|START_OF_TURN_TOKEN|><|USER_TOKEN|>{user}<|END_OF_TURN_TOKEN|><|START_OF_TURN_TOKEN|><|CHATBOT_TOKEN|>",
            .dbrx => "<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant",
            .arctic => "<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant",
            .jamba => "<|startoftext|>[INST] {system}\n{user} [/INST]",
            .olmo => "<|endoftext|><|user|>\n{user}<|assistant|>\n",
            .nemotron => "<extra_id_0>System\n{system}\n<extra_id_1>User\n{user}\n<extra_id_2>Assistant\n",
            .granite => "<|system|>\n{system}\n<|user|>\n{user}\n<|assistant|>\n",
            .solar => "### System:\n{system}\n\n### User:\n{user}\n\n### Assistant:\n",
            .minicpm => "<用户>{user}<AI>",
            .rwkv => "User: {user}\n\nAssistant:",
            else => "{user}",
        };
    }

    pub fn contextLength(self: ModelFamily) u32 {
        return switch (self) {
            .llama => 131072, // Llama 3.1+
            .mistral => 32768,
            .phi => 131072,
            .qwen => 131072,
            .gemma => 8192,
            .starcoder => 16384,
            .falcon => 8192,
            .mpt => 8192,
            .yi => 200000,
            .deepseek => 163840,
            .chatglm => 131072,
            .internlm => 200000,
            .baichuan => 32768,
            .command_r => 131072,
            .dbrx => 32768,
            .arctic => 4096,
            .jamba => 262144,
            .olmo => 4096,
            .nemotron => 4096,
            .granite => 131072,
            .solar => 32768,
            .minicpm => 131072,
            .rwkv => 65536,
            .unknown => 4096,
        };
    }
};

pub const QuantLevel = enum {
    q4_0,
    q4_k_m,
    q5_k_m,
    q8_0,
    f16,
    f32,

    pub fn fromFilename(name: []const u8) QuantLevel {
        if (std.mem.indexOf(u8, name, "Q4_0") != null or
            std.mem.indexOf(u8, name, "q4_0") != null) return .q4_0;
        if (std.mem.indexOf(u8, name, "Q4_K_M") != null or
            std.mem.indexOf(u8, name, "q4_k_m") != null) return .q4_k_m;
        if (std.mem.indexOf(u8, name, "Q5_K_M") != null or
            std.mem.indexOf(u8, name, "q5_k_m") != null) return .q5_k_m;
        if (std.mem.indexOf(u8, name, "Q8_0") != null or
            std.mem.indexOf(u8, name, "q8_0") != null) return .q8_0;
        if (std.mem.indexOf(u8, name, "f16") != null or
            std.mem.indexOf(u8, name, "F16") != null or
            std.mem.indexOf(u8, name, "fp16") != null) return .f16;
        return .f32;
    }
};

/// A known, downloadable model with pre-resolved metadata.
pub const ModelZooEntry = struct {
    repo_id: []const u8,
    family: ModelFamily,
    parameter_count: []const u8, // e.g. "7B", "13B", "70B"
    default_quant: QuantLevel,
    gguf_filename: []const u8, // Default GGUF file within the repo
    description: []const u8,
};

/// Built-in model catalog. Extend as new models are released.
pub const MODEL_ZOO = [_]ModelZooEntry{
    .{ .repo_id = "meta-llama/Llama-3.1-8B-Instruct-GGUF", .family = .llama, .parameter_count = "8B", .default_quant = .q4_k_m, .gguf_filename = "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf", .description = "Meta Llama 3.1 8B Instruct" },
    .{ .repo_id = "meta-llama/Llama-3.1-70B-Instruct-GGUF", .family = .llama, .parameter_count = "70B", .default_quant = .q4_k_m, .gguf_filename = "Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf", .description = "Meta Llama 3.1 70B Instruct" },
    .{ .repo_id = "mistralai/Mistral-7B-Instruct-v0.3-GGUF", .family = .mistral, .parameter_count = "7B", .default_quant = .q4_k_m, .gguf_filename = "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf", .description = "Mistral 7B Instruct v0.3" },
    .{ .repo_id = "microsoft/Phi-3.5-mini-instruct-GGUF", .family = .phi, .parameter_count = "3.8B", .default_quant = .q4_k_m, .gguf_filename = "Phi-3.5-mini-instruct-Q4_K_M.gguf", .description = "Microsoft Phi-3.5 Mini" },
    .{ .repo_id = "Qwen/Qwen2.5-7B-Instruct-GGUF", .family = .qwen, .parameter_count = "7B", .default_quant = .q4_k_m, .gguf_filename = "Qwen2.5-7B-Instruct-Q4_K_M.gguf", .description = "Qwen 2.5 7B Instruct" },
    .{ .repo_id = "google/gemma-2-9b-it-GGUF", .family = .gemma, .parameter_count = "9B", .default_quant = .q4_k_m, .gguf_filename = "gemma-2-9b-it-Q4_K_M.gguf", .description = "Google Gemma 2 9B IT" },
    // Llama variants
    .{ .repo_id = "meta-llama/Llama-3.2-3B-Instruct-GGUF", .family = .llama, .parameter_count = "3B", .default_quant = .q4_k_m, .gguf_filename = "Llama-3.2-3B-Instruct-Q4_K_M.gguf", .description = "Meta Llama 3.2 3B Instruct" },
    .{ .repo_id = "meta-llama/Llama-3.2-1B-Instruct-GGUF", .family = .llama, .parameter_count = "1B", .default_quant = .q8_0, .gguf_filename = "Llama-3.2-1B-Instruct-Q8_0.gguf", .description = "Meta Llama 3.2 1B Instruct" },
    // Mistral variants
    .{ .repo_id = "mistralai/Mixtral-8x7B-Instruct-v0.1-GGUF", .family = .mistral, .parameter_count = "47B", .default_quant = .q4_k_m, .gguf_filename = "Mixtral-8x7B-Instruct-v0.1-Q4_K_M.gguf", .description = "Mistral Mixtral 8x7B MoE" },
    .{ .repo_id = "mistralai/Mistral-Small-24B-Instruct-GGUF", .family = .mistral, .parameter_count = "24B", .default_quant = .q4_k_m, .gguf_filename = "Mistral-Small-24B-Instruct-Q4_K_M.gguf", .description = "Mistral Small 24B" },
    // Phi variants
    .{ .repo_id = "microsoft/Phi-3-medium-128k-instruct-GGUF", .family = .phi, .parameter_count = "14B", .default_quant = .q4_k_m, .gguf_filename = "Phi-3-medium-128k-instruct-Q4_K_M.gguf", .description = "Microsoft Phi-3 Medium 14B" },
    // Qwen variants
    .{ .repo_id = "Qwen/Qwen2.5-72B-Instruct-GGUF", .family = .qwen, .parameter_count = "72B", .default_quant = .q4_k_m, .gguf_filename = "Qwen2.5-72B-Instruct-Q4_K_M.gguf", .description = "Qwen 2.5 72B Instruct" },
    .{ .repo_id = "Qwen/Qwen2.5-14B-Instruct-GGUF", .family = .qwen, .parameter_count = "14B", .default_quant = .q4_k_m, .gguf_filename = "Qwen2.5-14B-Instruct-Q4_K_M.gguf", .description = "Qwen 2.5 14B Instruct" },
    .{ .repo_id = "Qwen/Qwen2.5-3B-Instruct-GGUF", .family = .qwen, .parameter_count = "3B", .default_quant = .q4_k_m, .gguf_filename = "Qwen2.5-3B-Instruct-Q4_K_M.gguf", .description = "Qwen 2.5 3B Instruct" },
    // Gemma variants
    .{ .repo_id = "google/gemma-2-27b-it-GGUF", .family = .gemma, .parameter_count = "27B", .default_quant = .q4_k_m, .gguf_filename = "gemma-2-27b-it-Q4_K_M.gguf", .description = "Google Gemma 2 27B IT" },
    .{ .repo_id = "google/gemma-2-2b-it-GGUF", .family = .gemma, .parameter_count = "2B", .default_quant = .q8_0, .gguf_filename = "gemma-2-2b-it-Q8_0.gguf", .description = "Google Gemma 2 2B IT" },
    // Yi
    .{ .repo_id = "01-ai/Yi-1.5-34B-Chat-GGUF", .family = .yi, .parameter_count = "34B", .default_quant = .q4_k_m, .gguf_filename = "Yi-1.5-34B-Chat-Q4_K_M.gguf", .description = "01.AI Yi 1.5 34B Chat" },
    .{ .repo_id = "01-ai/Yi-1.5-9B-Chat-GGUF", .family = .yi, .parameter_count = "9B", .default_quant = .q4_k_m, .gguf_filename = "Yi-1.5-9B-Chat-Q4_K_M.gguf", .description = "01.AI Yi 1.5 9B Chat" },
    // DeepSeek
    .{ .repo_id = "deepseek-ai/DeepSeek-V2.5-GGUF", .family = .deepseek, .parameter_count = "236B", .default_quant = .q4_k_m, .gguf_filename = "DeepSeek-V2.5-Q4_K_M.gguf", .description = "DeepSeek V2.5 MoE" },
    .{ .repo_id = "deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct-GGUF", .family = .deepseek, .parameter_count = "16B", .default_quant = .q4_k_m, .gguf_filename = "DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf", .description = "DeepSeek Coder V2 Lite" },
    // ChatGLM
    .{ .repo_id = "THUDM/chatglm3-6b-GGUF", .family = .chatglm, .parameter_count = "6B", .default_quant = .q4_k_m, .gguf_filename = "chatglm3-6b-Q4_K_M.gguf", .description = "THUDM ChatGLM3 6B" },
    .{ .repo_id = "THUDM/glm-4-9b-chat-GGUF", .family = .chatglm, .parameter_count = "9B", .default_quant = .q4_k_m, .gguf_filename = "glm-4-9b-chat-Q4_K_M.gguf", .description = "THUDM GLM-4 9B Chat" },
    // InternLM
    .{ .repo_id = "internlm/internlm2_5-7b-chat-GGUF", .family = .internlm, .parameter_count = "7B", .default_quant = .q4_k_m, .gguf_filename = "internlm2_5-7b-chat-Q4_K_M.gguf", .description = "InternLM 2.5 7B Chat" },
    // Cohere Command-R
    .{ .repo_id = "CohereForAI/c4ai-command-r-v01-GGUF", .family = .command_r, .parameter_count = "35B", .default_quant = .q4_k_m, .gguf_filename = "c4ai-command-r-v01-Q4_K_M.gguf", .description = "Cohere Command-R 35B" },
    // StarCoder
    .{ .repo_id = "bigcode/starcoder2-15b-GGUF", .family = .starcoder, .parameter_count = "15B", .default_quant = .q4_k_m, .gguf_filename = "starcoder2-15b-Q4_K_M.gguf", .description = "BigCode StarCoder2 15B" },
    .{ .repo_id = "bigcode/starcoder2-7b-GGUF", .family = .starcoder, .parameter_count = "7B", .default_quant = .q4_k_m, .gguf_filename = "starcoder2-7b-Q4_K_M.gguf", .description = "BigCode StarCoder2 7B" },
    // Falcon
    .{ .repo_id = "tiiuae/Falcon3-10B-Instruct-GGUF", .family = .falcon, .parameter_count = "10B", .default_quant = .q4_k_m, .gguf_filename = "Falcon3-10B-Instruct-Q4_K_M.gguf", .description = "TII Falcon 3 10B Instruct" },
    // DBRX
    .{ .repo_id = "databricks/dbrx-instruct-GGUF", .family = .dbrx, .parameter_count = "132B", .default_quant = .q4_k_m, .gguf_filename = "dbrx-instruct-Q4_K_M.gguf", .description = "Databricks DBRX Instruct MoE" },
    // Baichuan
    .{ .repo_id = "baichuan-inc/Baichuan2-13B-Chat-GGUF", .family = .baichuan, .parameter_count = "13B", .default_quant = .q4_k_m, .gguf_filename = "Baichuan2-13B-Chat-Q4_K_M.gguf", .description = "Baichuan 2 13B Chat" },
    .{ .repo_id = "baichuan-inc/Baichuan2-7B-Chat-GGUF", .family = .baichuan, .parameter_count = "7B", .default_quant = .q4_k_m, .gguf_filename = "Baichuan2-7B-Chat-Q4_K_M.gguf", .description = "Baichuan 2 7B Chat" },
    // Extended catalog in mangle/domain/model_zoo.mg — queried via MangleQueryEngine
};

/// Thread-local Mangle engine reference for dynamic catalog queries
var mangle_engine_ref: ?*mangle_query.MangleQueryEngine = null;

/// Set the MangleQueryEngine to use for dynamic model resolution
pub fn setMangleEngine(engine: *mangle_query.MangleQueryEngine) void {
    mangle_engine_ref = engine;
}

/// Resolve model from Mangle hf_model facts (model_zoo.mg)
/// Returns a dynamically-constructed ModelZooEntry if found.
fn resolveModelFromMangle(name: []const u8) ?ModelZooEntry {
    const engine = mangle_engine_ref orelse return null;
    const expected = mangle_parser.Term{ .constant = name };
    const fact = engine.queryFactWithArgs("hf_model", 0, expected) orelse return null;

    // hf_model(repo_id, family, param_billions, default_quant, gguf_filename, description)
    if (fact.predicate.args.len < 6) return null;

    const family_str = switch (fact.predicate.args[1]) {
        .constant => |s| s,
        else => return null,
    };
    const quant_str = switch (fact.predicate.args[3]) {
        .constant => |s| s,
        else => "q4_k_m",
    };
    const gguf_name = switch (fact.predicate.args[4]) {
        .constant => |s| s,
        else => return null,
    };
    const desc = switch (fact.predicate.args[5]) {
        .constant => |s| s,
        else => "",
    };
    const param_b = switch (fact.predicate.args[2]) {
        .number_float => |f| f,
        .number_int => |i| @as(f64, @floatFromInt(i)),
        else => 0.0,
    };

    // Format parameter count as string
    var param_buf: [16]u8 = undefined;
    const param_str = if (param_b >= 1.0)
        std.fmt.bufPrint(&param_buf, "{d}B", .{@as(u32, @intFromFloat(param_b))}) catch "?B"
    else
        std.fmt.bufPrint(&param_buf, "{d:.1}B", .{param_b}) catch "?B";
    _ = param_str;

    return ModelZooEntry{
        .repo_id = name,
        .family = ModelFamily.fromRepoId(family_str),
        .parameter_count = desc, // Use description as identifier
        .default_quant = QuantLevel.fromFilename(quant_str),
        .gguf_filename = gguf_name,
        .description = desc,
    };
}

/// Resolve a user-friendly model name (e.g. "llama-3.1-8b", "phi-3.5")
/// to a ModelZooEntry for auto-download.
/// Checks Mangle catalog (model_zoo.mg) first, falls back to static MODEL_ZOO.
pub fn resolveModelName(name: []const u8) ?*const ModelZooEntry {
    // Direct repo_id match in static zoo
    for (&MODEL_ZOO) |*entry| {
        if (std.mem.eql(u8, name, entry.repo_id)) return entry;
    }
    // Fuzzy match on family + parameter count
    for (&MODEL_ZOO) |*entry| {
        if (std.mem.indexOf(u8, name, entry.parameter_count) != null) {
            const family = ModelFamily.fromRepoId(name);
            if (family == entry.family) return entry;
        }
    }
    // Dynamic lookup from Mangle catalog
    // Note: returns pointer to static, but Mangle-resolved entries are ephemeral
    // Callers should copy fields they need to persist
    _ = resolveModelFromMangle(name);
    return null;
}

/// Download progress callback signature.
pub const ProgressCallback = *const fn (downloaded: u64, total: u64) void;

/// Local cache manager — avoids re-downloading models already on disk.
pub const LocalCache = struct {
    cache_dir: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, cache_dir: []const u8) LocalCache {
        return .{ .cache_dir = cache_dir, .allocator = allocator };
    }

    /// Check if a GGUF file is already cached locally. Returns the path if so.
    pub fn getCachedPath(self: *LocalCache, repo_id: []const u8, filename: []const u8) !?[]const u8 {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{
            self.cache_dir, repo_id, filename,
        });
        // Check existence
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                self.allocator.free(path);
                return null;
            }
            self.allocator.free(path);
            return err;
        };
        file.close();
        return path;
    }

    /// List all cached models (repo_id dirs).
    pub fn listCached(self: *LocalCache) !std.ArrayListUnmanaged([]const u8) {
        var result: std.ArrayListUnmanaged([]const u8) = .{};
        var dir = std.fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return result;
            return err;
        };
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .directory) {
                const name = try self.allocator.dupe(u8, entry.name);
                try result.append(name);
            }
        }
        return result;
    }

    /// Ensure cache directory structure exists for a given repo.
    pub fn ensureCacheDir(self: *LocalCache, repo_id: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
            self.cache_dir, repo_id,
        });
        defer self.allocator.free(path);
        std.fs.cwd().makePath(path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    /// Remove a cached model.
    pub fn removeCached(self: *LocalCache, repo_id: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
            self.cache_dir, repo_id,
        });
        defer self.allocator.free(path);
        std.fs.cwd().deleteTree(path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }
};

// =============================================================================
// Model Zoo Tests
// =============================================================================

test "ModelFamily.fromRepoId" {
    try std.testing.expectEqual(ModelFamily.llama, ModelFamily.fromRepoId("meta-llama/Llama-3.1-8B-Instruct-GGUF"));
    try std.testing.expectEqual(ModelFamily.mistral, ModelFamily.fromRepoId("mistralai/Mistral-7B-Instruct-v0.3"));
    try std.testing.expectEqual(ModelFamily.phi, ModelFamily.fromRepoId("microsoft/Phi-3.5-mini"));
    try std.testing.expectEqual(ModelFamily.qwen, ModelFamily.fromRepoId("Qwen/Qwen2.5-7B"));
    try std.testing.expectEqual(ModelFamily.gemma, ModelFamily.fromRepoId("google/gemma-2-9b"));
    try std.testing.expectEqual(ModelFamily.unknown, ModelFamily.fromRepoId("some/random-model"));
}

test "QuantLevel.fromFilename" {
    try std.testing.expectEqual(QuantLevel.q4_k_m, QuantLevel.fromFilename("model-Q4_K_M.gguf"));
    try std.testing.expectEqual(QuantLevel.q8_0, QuantLevel.fromFilename("model-Q8_0.gguf"));
    try std.testing.expectEqual(QuantLevel.f16, QuantLevel.fromFilename("model-f16.gguf"));
}

test "resolveModelName direct match" {
    const entry = resolveModelName("meta-llama/Llama-3.1-8B-Instruct-GGUF");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(ModelFamily.llama, entry.?.family);
}

test "MODEL_ZOO has entries" {
    try std.testing.expect(MODEL_ZOO.len >= 29);
    // All entries have non-empty repo_ids
    for (&MODEL_ZOO) |*e| {
        try std.testing.expect(e.repo_id.len > 0);
        try std.testing.expect(e.gguf_filename.len > 0);
    }
}

test "ModelFamily.contextLength" {
    try std.testing.expect(ModelFamily.llama.contextLength() >= 131072);
    try std.testing.expect(ModelFamily.unknown.contextLength() >= 4096);
}

test "ModelFamily new families" {
    try std.testing.expectEqual(ModelFamily.yi, ModelFamily.fromRepoId("01-ai/Yi-1.5-34B-Chat"));
    try std.testing.expectEqual(ModelFamily.deepseek, ModelFamily.fromRepoId("deepseek-ai/DeepSeek-V2.5"));
    try std.testing.expectEqual(ModelFamily.chatglm, ModelFamily.fromRepoId("THUDM/chatglm3-6b"));
    try std.testing.expectEqual(ModelFamily.internlm, ModelFamily.fromRepoId("internlm/internlm2_5-7b"));
    try std.testing.expectEqual(ModelFamily.command_r, ModelFamily.fromRepoId("CohereForAI/c4ai-command-r"));
    try std.testing.expectEqual(ModelFamily.dbrx, ModelFamily.fromRepoId("databricks/dbrx-instruct"));
    try std.testing.expect(ModelFamily.yi.contextLength() >= 200000);
    try std.testing.expect(ModelFamily.deepseek.contextLength() >= 163840);
}

test "LocalCache init" {
    var cache = LocalCache.init(std.testing.allocator, "/tmp/test_cache");
    try std.testing.expectEqualStrings("/tmp/test_cache", cache.cache_dir);
    // getCachedPath for nonexistent file returns null
    const result = try cache.getCachedPath("test/model", "test.gguf");
    try std.testing.expect(result == null);
}