//! ANWID HTTP Server
//! Lightweight HTTP/1.1 server using kqueue (macOS) or epoll (Linux)

const std = @import("std");
const net = std.net;
const posix = std.posix;

const log = std.log.scoped(.http_server);

// ============================================================================
// Types
// ============================================================================

pub const Request = struct {
    method: Method,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,

    // Internal
    raw_data: []const u8,
    allocator: std.mem.Allocator,
    body_owned: bool = false,

    pub const Method = enum {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
        OPTIONS,
        HEAD,
        UNKNOWN,

        pub fn fromString(s: []const u8) Method {
            if (std.mem.eql(u8, s, "GET")) return .GET;
            if (std.mem.eql(u8, s, "POST")) return .POST;
            if (std.mem.eql(u8, s, "PUT")) return .PUT;
            if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
            if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
            if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
            if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
            return .UNKNOWN;
        }
    };

    pub fn deinit(self: *Request) void {
        if (self.body_owned) {
            if (self.body) |b| {
                self.allocator.free(b);
            }
        }
        self.headers.deinit();
    }
};

pub const Response = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,
    body_allocated: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .status = 200,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
            .body_allocated = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Response) void {
        if (self.body_allocated) {
            if (self.body) |b| self.allocator.free(b);
        }
        self.headers.deinit();
    }

    pub fn setHeader(self: *Response, key: []const u8, value: []const u8) void {
        self.headers.put(key, value) catch {};
    }

    pub fn serialize(self: *const Response, writer: anytype) !void {
        // Status line
        try writer.print("HTTP/1.1 {} {s}\r\n", .{
            self.status,
            statusText(self.status),
        });

        // Headers
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Body
        if (self.body) |body| {
            try writer.print("Content-Length: {}\r\n\r\n", .{body.len});
            try writer.writeAll(body);
        } else {
            try writer.writeAll("Content-Length: 0\r\n\r\n");
        }
    }
};

pub const RequestHandler = *const fn (*Request, *Response) void;

// ============================================================================
// Server Configuration
// ============================================================================

pub const ServerOptions = struct {
    port: u16 = 8080,
    host: []const u8 = "0.0.0.0",
    max_connections: u32 = 10000,
    max_worker_threads: usize = 64,
    max_pending_connections: usize = 4096,
    read_buffer_size: usize = 16 * 1024,
    max_body_size: usize = 1024 * 1024, // 1MB max body
    request_handler: ?RequestHandler = null,
};

// ============================================================================
// HTTP Server
// ============================================================================

pub const Server = struct {
    allocator: std.mem.Allocator,
    options: ServerOptions,
    listener: ?net.Server,
    running: std.atomic.Value(bool),
    accept_thread: ?std.Thread,

    // Worker pool
    workers: []std.Thread,
    queue_lock: std.Thread.Mutex,
    queue_cv: std.Thread.Condition,
    pending: std.ArrayListUnmanaged(net.Server.Connection),

    // Statistics
    connections_accepted: std.atomic.Value(u64),
    connections_active: std.atomic.Value(u64),
    requests_handled: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions) !*Server {
        const server = try allocator.create(Server);
        server.* = .{
            .allocator = allocator,
            .options = options,
            .listener = null,
            .running = std.atomic.Value(bool).init(false),
            .accept_thread = null,
            .workers = &[_]std.Thread{},
            .queue_lock = .{},
            .queue_cv = .{},
            .pending = .{},
            .connections_accepted = std.atomic.Value(u64).init(0),
            .connections_active = std.atomic.Value(u64).init(0),
            .requests_handled = std.atomic.Value(u64).init(0),
        };
        return server;
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Server) !void {
        if (self.running.load(.acquire)) {
            return error.AlreadyRunning;
        }

        // Bind and listen
        const address = try net.Address.parseIp4(self.options.host, self.options.port);
        self.listener = try address.listen(.{
            .reuse_address = true,
        });

        self.running.store(true, .release);

        log.info("HTTP server listening on {s}:{}", .{ self.options.host, self.options.port });

        // Start worker pool
        self.workers = try self.allocator.alloc(std.Thread, self.options.max_worker_threads);
        for (self.workers, 0..) |*t, i| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{ self, i });
        }

        // Start accept thread
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *Server) void {
        if (!self.running.load(.acquire)) return;

        self.running.store(false, .release);

        // Close listener to unblock accept
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }

        // Wait for accept thread
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }

        // Wake workers and join
        self.queue_lock.lock();
        self.queue_cv.broadcast();
        self.queue_lock.unlock();

        for (self.workers) |t| {
            t.join();
        }
        self.allocator.free(self.workers);
        self.workers = &[_]std.Thread{};

        // Close any pending connections
        self.queue_lock.lock();
        for (self.pending.items) |conn| {
            conn.stream.close();
            _ = self.connections_active.fetchSub(1, .monotonic);
        }
        self.pending.deinit(self.allocator);
        self.queue_lock.unlock();

        log.info("HTTP server stopped", .{});
    }

    fn acceptLoop(self: *Server) void {
        while (self.running.load(.acquire)) {
            if (self.listener) |*listener| {
                const conn = listener.accept() catch |err| {
                    if (!self.running.load(.acquire)) break;
                    log.err("Accept error: {}", .{err});
                    continue;
                };

                _ = self.connections_accepted.fetchAdd(1, .monotonic);
                _ = self.connections_active.fetchAdd(1, .monotonic);

                // Enqueue connection for worker pool
                self.queue_lock.lock();
                if (self.pending.items.len >= self.options.max_pending_connections) {
                    self.queue_lock.unlock();
                    conn.stream.close();
                    _ = self.connections_active.fetchSub(1, .monotonic);
                    continue;
                }
                self.pending.append(self.allocator, conn) catch {
                    self.queue_lock.unlock();
                    conn.stream.close();
                    _ = self.connections_active.fetchSub(1, .monotonic);
                    continue;
                };
                self.queue_cv.signal();
                self.queue_lock.unlock();
            } else break;
        }
    }

    fn workerLoop(self: *Server, worker_id: usize) void {
        _ = worker_id;
        while (true) {
            self.queue_lock.lock();
            while (self.pending.items.len == 0 and self.running.load(.acquire)) {
                self.queue_cv.wait(&self.queue_lock);
            }

            if (!self.running.load(.acquire) and self.pending.items.len == 0) {
                self.queue_lock.unlock();
                break;
            }

            const conn = self.pending.orderedRemove(0);
            self.queue_lock.unlock();

            handleConnection(self, conn);
        }
    }

    fn handleConnection(self: *Server, conn: net.Server.Connection) void {
        defer {
            conn.stream.close();
            _ = self.connections_active.fetchSub(1, .monotonic);
        }

        // Read headers first (up to 16KB)
        var header_buf: [16 * 1024]u8 = undefined;
        var total_read: usize = 0;
        var header_end: ?usize = null;

        // Buffered header reading - keep reading until we find \r\n\r\n
        while (total_read < header_buf.len) {
            const n = conn.stream.read(header_buf[total_read..]) catch |err| {
                log.debug("Read error: {}", .{err});
                return;
            };
            if (n == 0) break;
            total_read += n;

            // Check for end of headers
            if (std.mem.indexOf(u8, header_buf[0..total_read], "\r\n\r\n")) |end| {
                header_end = end;
                break;
            }
        }

        if (total_read == 0) return;

        const hdr_end = header_end orelse {
            sendError(conn.stream, 400, "Bad Request");
            return;
        };

        // Parse request (headers portion)
        var request = parseRequest(self.allocator, header_buf[0..total_read]) catch |err| {
            log.debug("Parse error: {}", .{err});
            sendError(conn.stream, 400, "Bad Request");
            return;
        };
        defer request.deinit();

        // Read remaining body if Content-Length specified
        if (request.headers.get("Content-Length")) |cl_str| {
            const content_length = std.fmt.parseInt(usize, cl_str, 10) catch {
                sendError(conn.stream, 400, "Bad Request");
                return;
            };

            // Limit body size
            if (content_length > self.options.max_body_size) {
                sendError(conn.stream, 413, "Payload Too Large");
                return;
            }

            const body_start = hdr_end + 4;
            const already_read = total_read - body_start;

            if (content_length > already_read) {
                // Need to read more body data
                const body_buf = self.allocator.alloc(u8, content_length) catch {
                    sendError(conn.stream, 500, "Internal Server Error");
                    return;
                };

                // Copy what we already have
                @memcpy(body_buf[0..already_read], header_buf[body_start..total_read]);

                // Read the rest
                var body_read = already_read;
                while (body_read < content_length) {
                    const n = conn.stream.read(body_buf[body_read..content_length]) catch |err| {
                        log.debug("Body read error: {}", .{err});
                        self.allocator.free(body_buf);
                        return;
                    };
                    if (n == 0) break;
                    body_read += n;
                }

                request.body = body_buf[0..body_read];
                request.body_owned = true;
            }
            // If already_read >= content_length, body is already in header_buf and already parsed
        }

        // Create response
        var response = Response.init(self.allocator);
        defer response.deinit();

        // Default Content-Type
        response.setHeader("Content-Type", "application/json");

        // Call handler
        if (self.options.request_handler) |handler| {
            handler(&request, &response);
        } else {
            response.status = 404;
            response.body = "{\"error\":\"no_handler\"}";
        }

        // Send response
        const writer = conn.stream.writer();
        response.serialize(writer) catch |err| {
            log.debug("Write error: {}", .{err});
            return;
        };

        _ = self.requests_handled.fetchAdd(1, .monotonic);
    }

    pub fn getStats(self: *const Server) struct {
        connections_accepted: u64,
        connections_active: u64,
        requests_handled: u64,
    } {
        return .{
            .connections_accepted = self.connections_accepted.load(.acquire),
            .connections_active = self.connections_active.load(.acquire),
            .requests_handled = self.requests_handled.load(.acquire),
        };
    }
};

// ============================================================================
// HTTP Parsing
// ============================================================================

fn parseRequest(allocator: std.mem.Allocator, data: []const u8) !Request {
    var request = Request{
        .method = .UNKNOWN,
        .path = "",
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .raw_data = data,
        .allocator = allocator,
        .body_owned = false,
    };

    var lines = std.mem.splitSequence(u8, data, "\r\n");

    // Parse request line
    const request_line = lines.next() orelse return error.InvalidRequest;
    var parts = std.mem.splitScalar(u8, request_line, ' ');

    const method_str = parts.next() orelse return error.InvalidRequest;
    request.method = Request.Method.fromString(method_str);

    request.path = parts.next() orelse return error.InvalidRequest;

    // Parse headers
    while (lines.next()) |line| {
        if (line.len == 0) break; // Empty line = end of headers

        if (std.mem.indexOf(u8, line, ": ")) |sep| {
            const key = line[0..sep];
            const value = line[sep + 2 ..];
            try request.headers.put(key, value);
        }
    }

    // Body (everything after headers)
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n");
    if (header_end) |end| {
        const body_start = end + 4;
        if (body_start < data.len) {
            request.body = data[body_start..];
        }
    }

    return request;
}

fn sendError(stream: net.Stream, status: u16, message: []const u8) void {
    var writer = stream.writer();
    writer.print("HTTP/1.1 {} {s}\r\nContent-Length: 0\r\n\r\n", .{ status, message }) catch {};
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Request.Method.fromString" {
    try std.testing.expectEqual(Request.Method.GET, Request.Method.fromString("GET"));
    try std.testing.expectEqual(Request.Method.POST, Request.Method.fromString("POST"));
    try std.testing.expectEqual(Request.Method.UNKNOWN, Request.Method.fromString("INVALID"));
}

test "parseRequest basic" {
    const data = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var request = try parseRequest(std.testing.allocator, data);
    defer request.deinit();

    try std.testing.expectEqual(Request.Method.GET, request.method);
    try std.testing.expectEqualStrings("/health", request.path);
}

test "parseRequest with body" {
    const data = "POST /api/v1/embed HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\nContent-Type: application/json\r\n\r\n{\"text\":\"hi\"}";
    var request = try parseRequest(std.testing.allocator, data);
    defer request.deinit();

    try std.testing.expectEqual(Request.Method.POST, request.method);
    try std.testing.expectEqualStrings("/api/v1/embed", request.path);
    try std.testing.expect(request.body != null);
    try std.testing.expectEqualStrings("{\"text\":\"hi\"}", request.body.?);
}

test "Response serialization" {
    var response = Response.init(std.testing.allocator);
    defer response.deinit();

    response.status = 200;
    response.setHeader("Content-Type", "application/json");
    response.body = "{\"ok\":true}";

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try response.serialize(stream.writer());

    const result = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, result, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Content-Type: application/json") != null);
}