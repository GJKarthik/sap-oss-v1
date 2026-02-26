const std = @import("std");
const posix = std.posix;

// ============================================================================
// Search Service Client — HTTP proxy to ainuc-be-log-search-svc
//
// Provides:
//   - Hybrid search (vector + keyword + RRF fusion)
//   - ES→HANA query translation
//   - PAL optimization hints
//   - Vector similarity operations
// ============================================================================

pub const SearchClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    use_tls: bool,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) SearchClient {
        // Parse URL: http://host:port
        var host: []const u8 = "localhost";
        var port: u16 = 8080;
        var use_tls = false;

        var rest = url;
        if (std.mem.startsWith(u8, rest, "https://")) {
            use_tls = true;
            rest = rest["https://".len..];
            port = 443;
        } else if (std.mem.startsWith(u8, rest, "http://")) {
            rest = rest["http://".len..];
        }

        if (std.mem.indexOf(u8, rest, ":")) |colon| {
            host = rest[0..colon];
            port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch port;
        } else {
            host = rest;
        }

        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .use_tls = use_tls,
        };
    }

    pub fn isConfigured(self: *const SearchClient) bool {
        return self.host.len > 0 and !std.mem.eql(u8, self.host, "localhost");
    }

    /// Execute a hybrid search query (vector + keyword + RRF fusion)
    pub fn hybridSearch(self: *SearchClient, query: []const u8, top_k: usize) ![]const u8 {
        var body_buf: std.ArrayList(u8) = .{};
        const bw = body_buf.writer(self.allocator);
        try bw.writeAll("{\"q\":");
        try writeJsonStr(bw, query);
        try bw.print(",\"size\":{d},\"mode\":\"hybrid\"}}", .{top_k});
        const body = try body_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(body);

        return self.post("/v1/search", body);
    }

    /// Translate an Elasticsearch query DSL to HANA SQL via Mangle rules
    pub fn translateEsToHana(self: *SearchClient, es_query: []const u8) ![]const u8 {
        var body_buf: std.ArrayList(u8) = .{};
        const bw = body_buf.writer(self.allocator);
        try bw.writeAll("{\"query\":");
        try writeJsonStr(bw, es_query);
        try bw.writeAll(",\"target\":\"hana\"}");
        const body = try body_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(body);

        return self.post("/v1/chat/completions", body);
    }

    /// Get PAL optimization hints for a given table and algorithm
    pub fn palOptimize(self: *SearchClient, algorithm: []const u8, table_name: []const u8) ![]const u8 {
        var body_buf: std.ArrayList(u8) = .{};
        const bw = body_buf.writer(self.allocator);
        try bw.writeAll("{\"model\":\"es-search-v1\",\"messages\":[{\"role\":\"user\",\"content\":\"optimize ");
        try bw.writeAll(algorithm);
        try bw.writeAll(" on ");
        try bw.writeAll(table_name);
        try bw.writeAll("\"}]}");
        const body = try body_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(body);

        return self.post("/v1/chat/completions", body);
    }

    fn post(self: *SearchClient, path: []const u8, body: []const u8) ![]const u8 {
        // Build HTTP request
        var req_buf: std.ArrayList(u8) = .{};
        const rw = req_buf.writer(self.allocator);
        try rw.print("POST {s} HTTP/1.1\r\n", .{path});
        try rw.print("Host: {s}:{d}\r\n", .{ self.host, self.port });
        try rw.writeAll("Content-Type: application/json\r\n");
        try rw.print("Content-Length: {d}\r\n", .{body.len});
        try rw.writeAll("Connection: close\r\n\r\n");
        try rw.writeAll(body);

        const req_data = try req_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_data);

        // Connect via raw TCP
        const addr = std.net.Address.parseIp4(self.host, self.port) catch {
            // Try resolving hostname
            const list = try std.net.Address.resolveIp(self.host, self.port);
            return self.doRequest(list, req_data);
        };

        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        defer posix.close(sock);

        const sockaddr = addr.any;
        try posix.connect(sock, &sockaddr, @sizeOf(@TypeOf(addr.in)));

        _ = try posix.write(sock, req_data);

        // Read response
        var response: std.ArrayList(u8) = .{};
        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = posix.read(sock, &read_buf) catch break;
            if (n == 0) break;
            try response.appendSlice(self.allocator, read_buf[0..n]);
        }

        const full = try response.toOwnedSlice(self.allocator);
        // Strip HTTP headers — find \r\n\r\n
        if (std.mem.indexOf(u8, full, "\r\n\r\n")) |hdr_end| {
            const body_start = hdr_end + 4;
            const result = try self.allocator.dupe(u8, full[body_start..]);
            self.allocator.free(full);
            return result;
        }
        return full;
    }

    fn doRequest(self: *SearchClient, list: std.net.Address, req_data: []const u8) ![]const u8 {
        _ = list;
        _ = req_data;
        _ = self;
        return error.ConnectionRefused;
    }
};

// ============================================================================
// Vector Similarity — SIMD-accelerated operations (from search-svc)
// ============================================================================

const VEC_LEN = std.simd.suggestVectorLength(f32) orelse 4;
const VecF32 = @Vector(VEC_LEN, f32);

/// Cosine similarity: dot(a,b) / (||a|| * ||b||)
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    const dim = a.len;

    var dot_sum: VecF32 = @splat(0);
    var norm_a_sum: VecF32 = @splat(0);
    var norm_b_sum: VecF32 = @splat(0);

    var i: usize = 0;
    while (i + VEC_LEN <= dim) : (i += VEC_LEN) {
        const va: VecF32 = a[i..][0..VEC_LEN].*;
        const vb: VecF32 = b[i..][0..VEC_LEN].*;
        dot_sum += va * vb;
        norm_a_sum += va * va;
        norm_b_sum += vb * vb;
    }

    var dot: f32 = @reduce(.Add, dot_sum);
    var norm_a: f32 = @reduce(.Add, norm_a_sum);
    var norm_b: f32 = @reduce(.Add, norm_b_sum);

    while (i < dim) : (i += 1) {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }

    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (denom == 0.0) return 0.0;
    return dot / denom;
}

/// Dot product: sum(a[i] * b[i])
pub fn dotProduct(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    const dim = a.len;

    var sum_vec: VecF32 = @splat(0);
    var i: usize = 0;
    while (i + VEC_LEN <= dim) : (i += VEC_LEN) {
        const va: VecF32 = a[i..][0..VEC_LEN].*;
        const vb: VecF32 = b[i..][0..VEC_LEN].*;
        sum_vec += va * vb;
    }

    var sum: f32 = @reduce(.Add, sum_vec);
    while (i < dim) : (i += 1) {
        sum += a[i] * b[i];
    }
    return sum;
}

/// Euclidean distance: sqrt(sum((a[i] - b[i])^2))
pub fn euclideanDistance(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    const dim = a.len;

    var sum_vec: VecF32 = @splat(0);
    var i: usize = 0;
    while (i + VEC_LEN <= dim) : (i += VEC_LEN) {
        const va: VecF32 = a[i..][0..VEC_LEN].*;
        const vb: VecF32 = b[i..][0..VEC_LEN].*;
        const diff = va - vb;
        sum_vec += diff * diff;
    }

    var sum: f32 = @reduce(.Add, sum_vec);
    while (i < dim) : (i += 1) {
        const d = a[i] - b[i];
        sum += d * d;
    }
    return @sqrt(sum);
}

/// Reciprocal Rank Fusion — merge two ranked lists
pub fn rrfFuse(allocator: std.mem.Allocator, ranks_a: []const u32, ranks_b: []const u32, k: f32) ![]f32 {
    const n = @max(ranks_a.len, ranks_b.len);
    const scores = try allocator.alloc(f32, n);
    @memset(scores, 0.0);

    for (ranks_a, 0..) |rank, i| {
        if (i < n) {
            scores[i] += 1.0 / (k + @as(f32, @floatFromInt(rank)));
        }
    }
    for (ranks_b, 0..) |rank, i| {
        if (i < n) {
            scores[i] += 1.0 / (k + @as(f32, @floatFromInt(rank)));
        }
    }
    return scores;
}

fn writeJsonStr(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

// ============================================================================
// Tests
// ============================================================================

test "cosine similarity identical" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sim, 0.001);
}

test "cosine similarity orthogonal" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sim, 0.001);
}

test "dot product" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 4.0, 5.0, 6.0 };
    const dp = dotProduct(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), dp, 0.001);
}

test "euclidean distance zero" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    const dist = euclideanDistance(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dist, 0.001);
}

test "search client parse url" {
    const allocator = std.testing.allocator;
    const client = SearchClient.init(allocator, "http://search-svc:9200");
    try std.testing.expectEqualStrings("search-svc", client.host);
    try std.testing.expectEqual(@as(u16, 9200), client.port);
    try std.testing.expect(!client.use_tls);
}
