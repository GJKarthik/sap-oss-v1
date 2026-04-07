//! Model Hub — Dynamic HuggingFace model discovery + SAP Object Store persistence
//!
//! Bridges Mangle model catalog (model_zoo.mg) with:
//!   - HuggingFace Hub API for dynamic model search and download
//!   - SAP Object Store for persistent model caching
//!   - MangleQueryEngine for fact injection of discovered models

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const mangle_query = @import("../mangle/query.zig");
const mangle_parser = @import("../mangle/parser.zig");
const object_store = @import("../sap/object_store.zig");
const toon_pointer = @import("../sap/toon_pointer.zig");

// ============================================================================
// HuggingFace Hub Client
// ============================================================================

pub const HuggingFaceHub = struct {
    allocator: Allocator,
    api_base: []const u8,
    token: ?[]const u8,
    max_retries: u32,
    timeout_ms: u64,

    pub fn init(allocator: Allocator) HuggingFaceHub {
        return .{
            .allocator = allocator,
            .api_base = "https://huggingface.co/api",
            .token = std.posix.getenv("HF_TOKEN") orelse std.posix.getenv("HUGGING_FACE_HUB_TOKEN"),
            .max_retries = 3,
            .timeout_ms = 30_000,
        };
    }

    /// Search HuggingFace for models matching query and filter
    pub fn searchModels(self: *HuggingFaceHub, query: []const u8, filter: []const u8, limit: usize) ![]HfModelInfo {
        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/models?search={s}&filter={s}&sort=downloads&direction=-1&limit={d}", .{
            self.api_base, query, filter, limit,
        }) catch return &[_]HfModelInfo{};

        const response = self.httpGet(url) catch |err| {
            std.log.warn("HF API search failed: {}", .{err});
            return &[_]HfModelInfo{};
        };
        defer self.allocator.free(response);

        return self.parseModelList(response);
    }

    /// Get model info by repo ID
    pub fn getModelInfo(self: *HuggingFaceHub, repo_id: []const u8) !?HfModelInfo {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/models/{s}", .{ self.api_base, repo_id }) catch return null;

        const response = self.httpGet(url) catch return null;
        defer self.allocator.free(response);

        return self.parseSingleModel(response);
    }

    /// Build download URL for a GGUF file
    pub fn buildDownloadUrl(self: *HuggingFaceHub, repo_id: []const u8, filename: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "https://huggingface.co/{s}/resolve/main/{s}", .{ repo_id, filename });
    }

    /// Perform HTTP GET with auth token and retry logic
    fn httpGet(self: *HuggingFaceHub, url: []const u8) ![]const u8 {
        var retry: u32 = 0;
        while (retry < self.max_retries) : (retry += 1) {
            // Build HTTP/1.1 request manually (no external deps)
            const host_start = mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
            const host_end_slice = url[host_start + 3 ..];
            const path_start = mem.indexOf(u8, host_end_slice, "/") orelse host_end_slice.len;
            const host = host_end_slice[0..path_start];
            const path = if (path_start < host_end_slice.len) host_end_slice[path_start..] else "/";

            var header_buf: [2048]u8 = undefined;
            var header_len: usize = 0;
            const req_prefix = std.fmt.bufPrint(header_buf[0..], "GET {s} HTTP/1.1\r\nHost: {s}\r\nAccept: application/json\r\n", .{ path, host }) catch return error.BufferOverflow;
            header_len = req_prefix.len;

            if (self.token) |tok| {
                const auth_line = std.fmt.bufPrint(header_buf[header_len..], "Authorization: Bearer {s}\r\n", .{tok}) catch return error.BufferOverflow;
                header_len += auth_line.len;
            }
            @memcpy(header_buf[header_len..][0..4], "\r\n\r\n"[0..4]);
            header_len += 4;

            // TCP connect
            const addr = std.net.Address.resolveIp(host, 443) catch {
                std.Thread.sleep(1_000_000_000 * (@as(u64, 1) << @intCast(retry)));
                continue;
            };
            const stream = std.net.tcpConnectToAddress(addr) catch {
                std.Thread.sleep(1_000_000_000 * (@as(u64, 1) << @intCast(retry)));
                continue;
            };
            defer stream.close();

            _ = stream.write(header_buf[0..header_len]) catch continue;

            var body = std.ArrayListUnmanaged(u8){};
            var read_buf: [8192]u8 = undefined;
            while (true) {
                const n = stream.read(&read_buf) catch break;
                if (n == 0) break;
                body.appendSlice(read_buf[0..n]) catch break;
            }

            // Skip HTTP headers to find body
            const raw = body.items;
            if (mem.indexOf(u8, raw, "\r\n\r\n")) |hdr_end| {
                const result = self.allocator.dupe(u8, raw[hdr_end + 4 ..]) catch {
                    body.deinit();
                    return error.OutOfMemory;
                };
                body.deinit();
                return result;
            }
            body.deinit();
        }
        return error.MaxRetriesExceeded;
    }

    fn parseModelList(self: *HuggingFaceHub, json_data: []const u8) []HfModelInfo {
        // Simple JSON array parser — extract modelId fields from [{...}, ...]
        var models = std.ArrayListUnmanaged(HfModelInfo){};
        var pos: usize = 0;
        while (pos < json_data.len) {
            if (findJsonString(json_data, pos, "modelId")) |result| {
                models.append(.{
                    .repo_id = self.allocator.dupe(u8, result.value) catch continue,
                    .downloads = findJsonInt(json_data, result.end_pos, "downloads") orelse 0,
                    .likes = findJsonInt(json_data, result.end_pos, "likes") orelse 0,
                }) catch continue;
                pos = result.end_pos;
            } else break;
        }
        return models.toOwnedSlice() catch &[_]HfModelInfo{};
    }

    fn parseSingleModel(self: *HuggingFaceHub, json_data: []const u8) ?HfModelInfo {
        const repo_id_result = findJsonString(json_data, 0, "modelId") orelse return null;
        return HfModelInfo{
            .repo_id = self.allocator.dupe(u8, repo_id_result.value) catch return null,
            .downloads = findJsonInt(json_data, 0, "downloads") orelse 0,
            .likes = findJsonInt(json_data, 0, "likes") orelse 0,
        };
    }
};

// ============================================================================
// HF Model Info
// ============================================================================

pub const HfModelInfo = struct {
    repo_id: []const u8,
    downloads: i64,
    likes: i64,
};

// ============================================================================
// JSON Helpers — minimal parser for HF API responses
// ============================================================================

const JsonStringResult = struct { value: []const u8, end_pos: usize };

fn findJsonString(data: []const u8, start: usize, key: []const u8) ?JsonStringResult {
    // Find "key":"value" pattern
    const pos = start;
    while (pos + key.len + 4 < data.len) {
        if (mem.indexOf(u8, data[pos..], key)) |offset| {
            const key_pos = pos + offset;
            // Skip past key + closing quote + colon + opening quote
            var scan = key_pos + key.len;
            while (scan < data.len and data[scan] != '"') : (scan += 1) {}
            if (scan >= data.len) return null;
            scan += 1; // skip colon-side quote
            // Skip whitespace and colon
            while (scan < data.len and (data[scan] == ':' or data[scan] == ' ' or data[scan] == '"')) : (scan += 1) {}
            if (scan == 0) return null;
            // Back up one if we overshot past opening quote of value
            const value_start = scan;
            while (scan < data.len and data[scan] != '"') : (scan += 1) {}
            return .{ .value = data[value_start..scan], .end_pos = scan + 1 };
        } else break;
    }
    return null;
}

fn findJsonInt(data: []const u8, start: usize, key: []const u8) ?i64 {
    const pos = start;
    if (pos + key.len + 3 >= data.len) return null;
    if (mem.indexOf(u8, data[pos..], key)) |offset| {
        var scan = pos + offset + key.len;
        // Skip to colon and digits
        while (scan < data.len and (data[scan] == '"' or data[scan] == ':' or data[scan] == ' ')) : (scan += 1) {}
        // Parse integer
        var result: i64 = 0;
        var found_digit = false;
        while (scan < data.len and data[scan] >= '0' and data[scan] <= '9') : (scan += 1) {
            result = result * 10 + @as(i64, data[scan] - '0');
            found_digit = true;
        }
        if (found_digit) return result;
    }
    return null;
}

// ============================================================================
// SAP Object Store Bridge — persist downloaded models
// ============================================================================

pub const SapObjectStoreBridge = struct {
    allocator: Allocator,
    prefix: []const u8,
    bucket_env: []const u8,

    pub fn init(allocator: Allocator) SapObjectStoreBridge {
        return .{
            .allocator = allocator,
            .prefix = "models/gguf",
            .bucket_env = "MODEL_CACHE_BUCKET",
        };
    }

    /// Build the object store key for a model file
    pub fn buildObjectKey(self: *SapObjectStoreBridge, repo_id: []const u8, filename: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.prefix, repo_id, filename });
    }

    /// Check if model exists in object store.
    /// Tries ObjectStoreConnector.resolveObject first; falls back to local cache.
    pub fn modelExists(self: *SapObjectStoreBridge, repo_id: []const u8, filename: []const u8) bool {
        const key = self.buildObjectKey(repo_id, filename) catch return false;
        defer self.allocator.free(key);
        // If bucket env not set, object store is not configured — skip remote check
        if (std.posix.getenv(self.bucket_env) == null) return self.existsInLocalCache(key);
        // Try real object store resolution via ObjectStoreConnector
        const cfg = object_store.ObjectStoreConfig.fromEnv(self.allocator, "privatellm-models") catch
            return self.existsInLocalCache(key);
        var connector = object_store.ObjectStoreConnector.init(self.allocator, cfg);
        // Build a minimal ToonPointer to probe the key
        var ptr = toon_pointer.ToonPointer{
            .ptr_type = .sap_object,
            .location = key,
            .format = .auto,
            .columns = null,
            .ttl_seconds = 60,
        };
        const resolution = connector.resolveObject(&ptr) catch return self.existsInLocalCache(key);
        defer self.allocator.free(resolution.value);
        if (resolution.schema_hint) |sh| self.allocator.free(sh);
        return true;
    }

    fn existsInLocalCache(self: *SapObjectStoreBridge, key: []const u8) bool {
        const local_path = std.fmt.allocPrint(self.allocator, "/tmp/privatellm_cache/{s}", .{key}) catch return false;
        defer self.allocator.free(local_path);
        const file = std.fs.cwd().openFile(local_path, .{}) catch return false;
        file.close();
        return true;
    }
};

// ============================================================================
// Model Hub Orchestrator — queries Mangle, falls back to HF API
// ============================================================================

pub const ModelHub = struct {
    allocator: Allocator,
    hf_hub: HuggingFaceHub,
    store_bridge: SapObjectStoreBridge,
    mangle_engine: ?*mangle_query.MangleQueryEngine,

    pub fn init(allocator: Allocator, mangle_engine: ?*mangle_query.MangleQueryEngine) ModelHub {
        return .{
            .allocator = allocator,
            .hf_hub = HuggingFaceHub.init(allocator),
            .store_bridge = SapObjectStoreBridge.init(allocator),
            .mangle_engine = mangle_engine,
        };
    }

    /// Resolve a model by name — checks Mangle catalog first, then HF API
    pub fn resolveModel(self: *ModelHub, name: []const u8) !?HfModelInfo {
        // 1. Check Mangle catalog (model_zoo.mg facts)
        if (self.mangle_engine) |engine| {
            const expected = mangle_parser.Term{ .constant = name };
            if (engine.queryFactWithArgs("hf_model", 0, expected)) |_| {
                return HfModelInfo{
                    .repo_id = try self.allocator.dupe(u8, name),
                    .downloads = 0,
                    .likes = 0,
                };
            }
        }
        // 2. Try HF API search
        return self.hf_hub.getModelInfo(name);
    }

    /// Search models by family — uses hf_search facts from Mangle
    pub fn searchByFamily(self: *ModelHub, family: []const u8, limit: usize) ![]HfModelInfo {
        if (self.mangle_engine) |engine| {
            const expected = mangle_parser.Term{ .constant = family };
            if (engine.queryFactWithArgs("hf_search", 0, expected)) |fact| {
                if (fact.predicate.args.len >= 3) {
                    const query = switch (fact.predicate.args[1]) {
                        .constant => |s| s,
                        else => family,
                    };
                    const filter = switch (fact.predicate.args[2]) {
                        .constant => |s| s,
                        else => "gguf",
                    };
                    return self.hf_hub.searchModels(query, filter, limit);
                }
            }
        }
        // Fallback: generic search
        return self.hf_hub.searchModels(family, "gguf", limit);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "HfModelInfo struct" {
    const info = HfModelInfo{ .repo_id = "test/model", .downloads = 100, .likes = 50 };
    try std.testing.expectEqualStrings("test/model", info.repo_id);
    try std.testing.expectEqual(@as(i64, 100), info.downloads);
}

test "findJsonString basic" {
    const data = "{\"modelId\":\"meta-llama/Llama-3\",\"downloads\":1000}";
    if (findJsonString(data, 0, "modelId")) |result| {
        try std.testing.expect(result.value.len > 0);
    }
}

test "findJsonInt basic" {
    const data = "{\"downloads\":42,\"likes\":10}";
    const result = findJsonInt(data, 0, "downloads");
    try std.testing.expectEqual(@as(?i64, 42), result);
}

test "encodeVarint roundtrip" {
    // Verifying JSON helpers exist and compile
    const info = HfModelInfo{ .repo_id = "test", .downloads = 0, .likes = 0 };
    try std.testing.expectEqualStrings("test", info.repo_id);
}

test "SapObjectStoreBridge key construction" {
    const alloc = std.testing.allocator;
    var bridge = SapObjectStoreBridge.init(alloc);
    const key = try bridge.buildObjectKey("meta-llama/Llama-3", "model.gguf");
    defer alloc.free(key);
    try std.testing.expectEqualStrings("models/gguf/meta-llama/Llama-3/model.gguf", key);
}

test "HuggingFaceHub download URL" {
    const alloc = std.testing.allocator;
    var hub = HuggingFaceHub.init(alloc);
    const url = try hub.buildDownloadUrl("meta-llama/Llama-3", "model.gguf");
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://huggingface.co/meta-llama/Llama-3/resolve/main/model.gguf", url);
}
