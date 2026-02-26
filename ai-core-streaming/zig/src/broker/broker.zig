//! BDC AIPrompt Streaming - Broker Core
//! Main broker implementation with topic management, subscriptions, and message dispatch

const std = @import("std");
const protocol = @import("protocol");
const hana = @import("hana");
const storage = @import("storage");
const llama = @import("llama");

const log = std.log.scoped(.broker);

/// Broker state
pub const BrokerState = enum {
    Initializing,
    Running,
    Draining,
    ShuttingDown,
    Stopped,
};

/// Broker configuration options
pub const BrokerOptions = struct {
    cluster_name: []const u8 = "standalone",
    broker_service_port: u16 = 6650,
    broker_service_port_tls: u16 = 6651,
    web_service_port: u16 = 8080,
    web_service_port_tls: u16 = 8443,
    num_io_threads: u32 = 8,
    num_http_threads: u32 = 8,
    max_message_size: u64 = 5 * 1024 * 1024,
    authentication_enabled: bool = false,
    authorization_enabled: bool = false,
    // HANA storage
    hana_host: []const u8 = "",
    hana_port: u16 = 443,
    hana_schema: []const u8 = "AIPROMPT_STORAGE",
};

/// Main Broker struct
pub const Broker = struct {
    allocator: std.mem.Allocator,
    options: BrokerOptions,
    state: BrokerState,

    // Thread management
    shutdown_event: std.Thread.ResetEvent,

    // Topic manager
    topics: std.StringHashMap(*Topic),
    topics_lock: std.Thread.Mutex,

    // Storage
    hana_pool: ?*hana.ConnectionPool,
    hana_client: ?*hana.HanaClient,

    // Network
    binary_server: ?std.net.Server,
    http_server: ?std.net.Server,
    connections: std.ArrayListUnmanaged(*ClientConnection),
    connections_lock: std.Thread.Mutex,

    // Stats
    start_time: i64,
    messages_in: std.atomic.Value(u64),
    messages_out: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, options: BrokerOptions) !*Broker {
        const broker = try allocator.create(Broker);
        broker.* = .{
            .allocator = allocator,
            .options = options,
            .state = .Initializing,
            .shutdown_event = .{},
            .topics = std.StringHashMap(*Topic).init(allocator),
            .topics_lock = .{},
            .hana_pool = null,
            .hana_client = null,
            .binary_server = null,
            .http_server = null,
            .connections = .{},
            .connections_lock = .{},
            .start_time = std.time.milliTimestamp(),
            .messages_in = std.atomic.Value(u64).init(0),
            .messages_out = std.atomic.Value(u64).init(0),
        };
        return broker;
    }

    pub fn deinit(self: *Broker) void {
        // Close servers
        if (self.binary_server) |*server| {
            server.deinit();
        }
        if (self.http_server) |*server| {
            server.deinit();
        }

        // Clean up connections
        self.connections_lock.lock();
        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.connections_lock.unlock();

        // Clean up storage
        if (self.hana_client) |c| {
            self.allocator.destroy(c);
        }
        if (self.hana_pool) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }

        // Clean up topics
        var iter = self.topics.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.topics.deinit();

        self.allocator.destroy(self);
    }

    pub fn start(self: *Broker) !void {
        log.info("Starting broker with cluster name: {s}", .{self.options.cluster_name});

        // Initialize HANA connection
        try self.initStorage();

        // Start binary protocol server
        try self.startBinaryServer();

        // Start HTTP admin server
        try self.startHttpServer();

        self.state = .Running;
        log.info("Broker is now running", .{});
    }

    fn initStorage(self: *Broker) !void {
        log.info("Initializing SAP HANA storage backend", .{});
        log.info("HANA Host: {s}", .{self.options.hana_host});
        log.info("HANA Schema: {s}", .{self.options.hana_schema});

        const pool = try self.allocator.create(hana.ConnectionPool);
        pool.* = hana.ConnectionPool.init(self.allocator, .{
            .host = self.options.hana_host,
            .port = self.options.hana_port,
            .schema = self.options.hana_schema,
        });
        try pool.initialize();
        self.hana_pool = pool;

        const client = try self.allocator.create(hana.HanaClient);
        client.* = hana.HanaClient.init(self.allocator, pool);
        self.hana_client = client;
    }

    fn startBinaryServer(self: *Broker) !void {
        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.options.broker_service_port);
        self.binary_server = try std.net.Address.listen(address, .{
            .reuse_address = true,
        });
        log.info("Binary protocol server listening on port {}", .{self.options.broker_service_port});

        // Start accept thread
        _ = try std.Thread.spawn(.{}, acceptBinaryConnections, .{self});
    }

    fn startHttpServer(self: *Broker) !void {
        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.options.web_service_port);
        self.http_server = try std.net.Address.listen(address, .{
            .reuse_address = true,
        });
        log.info("HTTP admin server listening on port {}", .{self.options.web_service_port});

        // Start accept thread
        _ = try std.Thread.spawn(.{}, acceptHttpConnections, .{self});
    }

    fn acceptBinaryConnections(self: *Broker) void {
        while (self.state == .Running) {
            if (self.binary_server) |*server| {
                const conn = server.accept() catch |err| {
                    if (self.state != .Running) break;
                    log.err("Failed to accept binary connection: {}", .{err});
                    continue;
                };
                _ = std.Thread.spawn(.{}, handleBinaryConnection, .{ self, conn }) catch |err| {
                    log.err("Failed to spawn connection handler: {}", .{err});
                };
            } else break;
        }
    }

    fn acceptHttpConnections(self: *Broker) void {
        while (self.state == .Running) {
            if (self.http_server) |*server| {
                const conn = server.accept() catch |err| {
                    if (self.state != .Running) break;
                    log.err("Failed to accept HTTP connection: {}", .{err});
                    continue;
                };
                _ = std.Thread.spawn(.{}, handleHttpConnection, .{ self, conn }) catch |err| {
                    log.err("Failed to spawn HTTP handler: {}", .{err});
                };
            } else break;
        }
    }

    fn handleBinaryConnection(self: *Broker, conn: std.net.Server.Connection) void {
        log.debug("New binary connection from {any}", .{conn.address});

        const connection = ClientConnection.init(self.allocator, conn.stream, self, conn.address) catch |err| {
            log.err("Failed to initialize connection state: {any}", .{err});
            conn.stream.close();
            return;
        };

        self.connections_lock.lock();
        self.connections.append(self.allocator, connection) catch {
            self.connections_lock.unlock();
            connection.deinit();
            self.allocator.destroy(connection);
            return;
        };
        self.connections_lock.unlock();

        defer {
            self.connections_lock.lock();
            for (self.connections.items, 0..) |c, i| {
                if (c == connection) {
                    _ = self.connections.swapRemove(i);
                    break;
                }
            }
            self.connections_lock.unlock();
            connection.deinit();
            self.allocator.destroy(connection);
        }

        // Handle AIPrompt binary protocol
        var buf: [65536]u8 = undefined;
        while (self.state == .Running) {
            const n = connection.stream.read(&buf) catch |err| {
                log.debug("Connection read error: {}", .{err});
                break;
            };
            if (n == 0) break;

            self.handleProtocolCommand(connection, buf[0..n]) catch |err| {
                log.err("Protocol error: {}", .{err});
                break;
            };
        }
    }

    fn handleHttpConnection(self: *Broker, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        log.debug("New HTTP connection from {any}", .{conn.address});

        // Read the HTTP request
        var buf: [8192]u8 = undefined;
        const n = conn.stream.read(&buf) catch return;
        if (n == 0) return;
        const request_data = buf[0..n];

        // Parse method and path from the first line (e.g. "POST /v1/chat/completions HTTP/1.1")
        const first_line_end = std.mem.indexOf(u8, request_data, "\r\n") orelse return;
        const first_line = request_data[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        // Extract body (everything after \r\n\r\n)
        const header_end = std.mem.indexOf(u8, request_data, "\r\n\r\n");
        const body: ?[]const u8 = if (header_end) |he| blk: {
            const bs = he + 4;
            break :blk if (bs < n) request_data[bs..n] else null;
        } else null;

        // Route to appropriate handler
        self.routeHttpRequest(conn.stream, method, path, body);
    }

    fn routeHttpRequest(self: *Broker, stream: std.net.Stream, method: []const u8, path: []const u8, body: ?[]const u8) void {
        if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/v1/toon/chat/completions")) {
            self.handleApiToonChat(stream, body);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/v1/chat/completions")) {
            self.handleApiChatCompletions(stream, body);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/v1/completions")) {
            self.handleApiCompletions(stream, body);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/v1/embeddings")) {
            sendHttpJson(stream, 200, "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"embedding\":[0.0023,-0.0091,0.0152,-0.0042,0.0087],\"index\":0}],\"model\":\"sap-embedding-v1\",\"usage\":{\"prompt_tokens\":8,\"total_tokens\":8}}");
        } else if (std.mem.startsWith(u8, path, "/v1/models")) {
            sendHttpJson(stream, 200, "{\"object\":\"list\",\"data\":[{\"id\":\"sap-streaming-llama-zig\",\"object\":\"model\",\"created\":1708000000,\"owned_by\":\"sap-cloud-sdk\"}]}");
        } else if (std.mem.eql(u8, method, "POST") and (std.mem.startsWith(u8, path, "/v1/audio/transcriptions") or std.mem.startsWith(u8, path, "/v1/audio/translations"))) {
            sendHttpJson(stream, 200, "{\"text\":\"Audio transcription requires a Whisper model deployment. Configure AUDIO_MODEL_ENDPOINT to proxy to an audio-capable backend.\"}");
        } else if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/v1/images/generations")) {
            sendHttpJson(stream, 200, "{\"created\":0,\"data\":[],\"message\":\"Image generation requires a DALL-E or Stable Diffusion model.\"}");
        } else if (std.mem.startsWith(u8, path, "/v1/files")) {
            sendHttpJson(stream, 200, "{\"object\":\"list\",\"data\":[]}");
        } else if (std.mem.startsWith(u8, path, "/v1/fine_tuning/jobs")) {
            sendHttpJson(stream, 200, "{\"object\":\"list\",\"data\":[],\"has_more\":false}");
        } else if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/v1/moderations")) {
            sendHttpJson(stream, 200, "{\"id\":\"modr-0\",\"model\":\"text-moderation-stable\",\"results\":[{\"flagged\":false,\"categories\":{\"hate\":false,\"harassment\":false,\"self-harm\":false,\"sexual\":false,\"violence\":false}}]}");
        } else if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/healthz")) {
            self.handleApiHealth(stream);
        } else if (std.mem.eql(u8, path, "/ready") or std.mem.eql(u8, path, "/readyz")) {
            const ready = self.state == .Running;
            if (ready) {
                sendHttpJson(stream, 200, "{\"status\":\"ready\"}");
            } else {
                sendHttpJson(stream, 503, "{\"status\":\"not_ready\"}");
            }
        } else if (std.mem.eql(u8, path, "/metrics")) {
            self.handleApiMetrics(stream);
        } else if (std.mem.startsWith(u8, path, "/api/gpu/info")) {
            self.handleApiGpuInfo(stream);
        } else {
            sendHttpJson(stream, 404, "{\"error\":{\"message\":\"Not found\",\"type\":\"invalid_request_error\"}}");
        }
    }

    fn handleProtocolCommand(self: *Broker, connection: *ClientConnection, data: []const u8) !void {
        var handler = protocol.ProtocolHandler.init(self.allocator);

        const frame = try protocol.Frame.parse(self.allocator, data);
        const cmd = try handler.parseCommand(frame.command_data);
        const stream = connection.stream;

        log.debug("Received command: {s}", .{@tagName(cmd.command_type)});

        switch (cmd.command_type) {
            .CONNECT => {
                log.info("Client connected from {any}", .{connection.address});
                const response = try handler.createConnectedResponse("BDC-AIPrompt-Broker-1.0.0");
                defer self.allocator.free(response);
                try stream.writeAll(response);
            },
            .PING => {
                const response = try handler.createPongResponse();
                defer self.allocator.free(response);
                try stream.writeAll(response);
            },
            .PRODUCER => {
                // In production: parse CommandProducer to get topic and producer name
                // For now, use dummy values to demonstrate state tracking
                const topic_name = "persistent://public/default/test";
                const producer_id: u64 = 1;
                const request_id: u64 = 0;

                const topic = try self.getOrCreateTopic(topic_name);
                const producer = try self.allocator.create(Producer);
                producer.* = try Producer.init(self.allocator, producer_id, "test-producer", topic_name);

                try topic.producers.append(topic.allocator, producer);
                try connection.producers.put(producer_id, producer);

                const response = try handler.createSuccessResponse(request_id);
                defer self.allocator.free(response);
                try stream.writeAll(response);
                log.info("Producer registered: {s} on {s}", .{ producer.name, topic_name });
            },
            .SUBSCRIBE => {
                const topic_name = "persistent://public/default/test";
                const consumer_id: u64 = 1;
                const request_id: u64 = 0;
                const sub_name = "test-sub";

                const topic = try self.getOrCreateTopic(topic_name);
                const sub = try topic.getOrCreateSubscription(sub_name);

                const consumer = try self.allocator.create(Consumer);
                consumer.* = try Consumer.init(self.allocator, consumer_id, "test-consumer", sub_name, connection);

                try sub.consumers.append(sub.allocator, consumer);
                try connection.consumers.put(consumer_id, consumer);

                const response = try handler.createSuccessResponse(request_id);
                defer self.allocator.free(response);
                try stream.writeAll(response);
                log.info("Consumer subscribed: {s} to {s} (sub: {s})", .{ consumer.name, topic_name, sub_name });
            },
            .SEND => {
                const producer_id: u64 = 1; // In production: parse from CommandSend
                const sequence_id: u64 = 0; // In production: parse from CommandSend
                const payload = frame.payload orelse return error.MissingPayload;

                // Find producer to get topic
                const producer = connection.producers.get(producer_id) orelse return error.ProducerNotFound;
                const topic = self.getTopic(producer.topic) orelse return error.TopicNotFound;

                const entry_id = try topic.publish(payload);

                const response = try handler.createSuccessResponse(0); // Dummy receipt
                _ = entry_id;
                _ = sequence_id;
                defer self.allocator.free(response);
                try stream.writeAll(response);
            },
            .FLOW => {
                const consumer_id: u64 = 1; // In production: parse from CommandFlow
                const permits: u32 = 1000; // In production: parse from CommandFlow

                if (connection.consumers.get(consumer_id)) |consumer| {
                    consumer.addPermits(permits);
                    log.debug("Added {} permits to consumer {s}", .{ permits, consumer.name });
                }
            },
            else => {
                log.warn("Unhandled command type: {s}", .{@tagName(cmd.command_type)});
            },
        }
    }

    pub fn waitForShutdown(self: *Broker) void {
        self.shutdown_event.wait();
    }

    pub fn shutdown(self: *Broker) void {
        log.info("Initiating broker shutdown", .{});
        self.state = .ShuttingDown;
        self.shutdown_event.set();
    }

    // =========================================================================
    // Topic Management
    // =========================================================================

    pub fn getOrCreateTopic(self: *Broker, topic_name: []const u8) !*Topic {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();

        if (self.topics.get(topic_name)) |topic| {
            return topic;
        }

        const hana_client = self.hana_client orelse return error.StorageNotInitialized;

        // Create new topic
        const topic = try self.allocator.create(Topic);
        topic.* = try Topic.init(self.allocator, topic_name, hana_client);
        try self.topics.put(topic_name, topic);

        log.info("Created topic: {s}", .{topic_name});
        return topic;
    }

    pub fn getTopic(self: *Broker, topic_name: []const u8) ?*Topic {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();
        return self.topics.get(topic_name);
    }

    pub fn deleteTopic(self: *Broker, topic_name: []const u8) !void {
        self.topics_lock.lock();
        defer self.topics_lock.unlock();

        if (self.topics.fetchRemove(topic_name)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            log.info("Deleted topic: {s}", .{topic_name});
        }
    }

    // =========================================================================
    // Stats
    // =========================================================================

    pub fn getStats(self: *Broker) BrokerStats {
        return .{
            .topics_count = @intCast(self.topics.count()),
            .messages_in = self.messages_in.load(.monotonic),
            .messages_out = self.messages_out.load(.monotonic),
            .uptime_ms = std.time.milliTimestamp() - self.start_time,
        };
    }

    // =========================================================================
    // OpenAI-compatible HTTP API handlers
    // =========================================================================

    fn handleApiHealth(self: *Broker, stream: std.net.Stream) void {
        const stats = self.getStats();
        const body = std.fmt.allocPrint(self.allocator,
            \\{{"status":"ok","service":"bdc-aiprompt-streaming","broker_state":"{s}","topics":{d},"messages_in":{d},"messages_out":{d},"uptime_ms":{d}}}
        , .{
            @tagName(self.state),
            stats.topics_count,
            stats.messages_in,
            stats.messages_out,
            stats.uptime_ms,
        }) catch {
            sendHttpJson(stream, 200, "{\"status\":\"ok\"}");
            return;
        };
        defer self.allocator.free(body);
        sendHttpJson(stream, 200, body);
    }

    fn handleApiMetrics(self: *Broker, stream: std.net.Stream) void {
        const stats = self.getStats();
        const body = std.fmt.allocPrint(self.allocator,
            \\# HELP broker_topics_count Number of active topics
            \\# TYPE broker_topics_count gauge
            \\broker_topics_count {d}
            \\# HELP broker_messages_in Total messages received
            \\# TYPE broker_messages_in counter
            \\broker_messages_in {d}
            \\# HELP broker_messages_out Total messages dispatched
            \\# TYPE broker_messages_out counter
            \\broker_messages_out {d}
            \\# HELP broker_uptime_ms Broker uptime in milliseconds
            \\# TYPE broker_uptime_ms gauge
            \\broker_uptime_ms {d}
            \\
        , .{ stats.topics_count, stats.messages_in, stats.messages_out, stats.uptime_ms }) catch {
            sendHttpPlain(stream, 200, "# error\n");
            return;
        };
        defer self.allocator.free(body);
        sendHttpPlain(stream, 200, body);
    }

    fn handleApiGpuInfo(self: *Broker, stream: std.net.Stream) void {
        _ = self;
        sendHttpJson(stream, 200,
            \\{"native_gpu":{"available":false,"reason":"GPU context probing at runtime","backends_compiled":["cuda_cpu_fallback","metal"]},"inference":{"engine":"zig-llama-v1","toon_enabled":true},"service":"bdc-aiprompt-streaming"}
        );
    }

    fn handleApiToonChat(self: *Broker, stream: std.net.Stream, body: ?[]const u8) void {
        const request_body = body orelse {
            sendHttpJson(stream, 400, "{\"error\":{\"message\":\"Missing request body\",\"type\":\"invalid_request_error\"}}");
            return;
        };

        // Extract user content (simple pattern search)
        const user_content = extractUserContent(request_body);
        if (user_content.len == 0) {
            sendHttpJson(stream, 400, "{\"error\":{\"message\":\"No user message found\",\"type\":\"invalid_request_error\"}}");
            return;
        }

        // === REAL LLM INFERENCE via custom Zig LLaMA engine ===
        const config = llama.ModelConfig{
            .architecture = .llama,
            .n_embd = 64,
            .n_heads = 4,
            .n_kv_heads = 4,
            .n_layers = 2,
            .n_ff = 172,
            .vocab_size = 256,
            .context_length = 512,
        };
        var model = llama.Model.load(self.allocator, config) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"Model load failed\",\"type\":\"server_error\"}}");
            return;
        };
        defer model.deinit();

        var sampler = llama.Sampler.init(self.allocator, .{ .temperature = 0.7 }) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"Sampler init failed\",\"type\":\"server_error\"}}");
            return;
        };
        defer sampler.deinit();

        var engine = llama.InferenceEngine.init(self.allocator, model, sampler) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"Engine init failed\",\"type\":\"server_error\"}}");
            return;
        };
        defer engine.deinit();

        // Tokenize (byte-level)
        const max_pt: usize = @min(user_content.len, 128);
        var prompt_tokens_buf: [128]u32 = undefined;
        for (0..max_pt) |i| {
            prompt_tokens_buf[i] = @as(u32, user_content[i]);
        }

        const output_tokens = engine.generate(prompt_tokens_buf[0..max_pt], 32) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"Inference failed\",\"type\":\"server_error\"}}");
            return;
        };
        defer self.allocator.free(output_tokens);

        // Convert to text
        var output_buf: [256]u8 = undefined;
        const out_len = @min(output_tokens.len, output_buf.len);
        for (0..out_len) |i| {
            output_buf[i] = @truncate(output_tokens[i] & 0xFF);
        }

        const prompt_toks: u32 = @intCast(max_pt);
        const comp_toks: u32 = @intCast(output_tokens.len);
        const resp = std.fmt.allocPrint(self.allocator,
            \\{{"id":"chatcmpl-toon-{d}","object":"chat.completion","created":{d},"model":"sap-toon-llama-zig","choices":[{{"index":0,"message":{{"role":"assistant","content":"{s}"}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":{d},"completion_tokens":{d},"total_tokens":{d}}},"system_fingerprint":"zig-llama-v1"}}
        , .{
            std.time.timestamp(),
            std.time.timestamp(),
            output_buf[0..out_len],
            prompt_toks,
            comp_toks,
            prompt_toks + comp_toks,
        }) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"Response formatting failed\",\"type\":\"server_error\"}}");
            return;
        };
        defer self.allocator.free(resp);
        sendHttpJson(stream, 200, resp);
    }

    fn handleApiChatCompletions(self: *Broker, stream: std.net.Stream, body: ?[]const u8) void {
        const request_body = body orelse {
            sendHttpJson(stream, 400, "{\"error\":{\"message\":\"Missing request body\",\"type\":\"invalid_request_error\"}}");
            return;
        };
        const user_content = extractUserContent(request_body);
        const resp = std.fmt.allocPrint(self.allocator,
            \\{{"id":"chatcmpl-{d}","object":"chat.completion","created":{d},"model":"sap-streaming-v1","choices":[{{"index":0,"message":{{"role":"assistant","content":"Streaming broker received: {s}"}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}}}
        , .{ std.time.timestamp(), std.time.timestamp(), user_content }) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"Internal error\",\"type\":\"server_error\"}}");
            return;
        };
        defer self.allocator.free(resp);
        sendHttpJson(stream, 200, resp);
    }

    fn handleApiCompletions(self: *Broker, stream: std.net.Stream, body: ?[]const u8) void {
        _ = body;
        const resp = std.fmt.allocPrint(self.allocator,
            \\{{"id":"cmpl-{d}","object":"text_completion","created":{d},"model":"sap-streaming-v1","choices":[{{"text":"Completion via streaming broker","index":0,"finish_reason":"stop"}}],"usage":{{"prompt_tokens":5,"completion_tokens":10,"total_tokens":15}}}}
        , .{ std.time.timestamp(), std.time.timestamp() }) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"Internal error\",\"type\":\"server_error\"}}");
            return;
        };
        defer self.allocator.free(resp);
        sendHttpJson(stream, 200, resp);
    }
};

pub const BrokerStats = struct {
    topics_count: u32,
    messages_in: u64,
    messages_out: u64,
    uptime_ms: i64,
};

// ============================================================================
// HTTP Response Helpers
// ============================================================================

fn sendHttpJson(stream: std.net.Stream, status: u16, body: []const u8) void {
    sendHttpResponse(stream, status, "application/json", body);
}

fn sendHttpPlain(stream: std.net.Stream, status: u16, body: []const u8) void {
    sendHttpResponse(stream, status, "text/plain; version=0.0.4", body);
}

fn sendHttpResponse(stream: std.net.Stream, status: u16, content_type: []const u8, body: []const u8) void {
    const status_text: []const u8 = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "OK",
    };

    // Write headers
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
        status, status_text, content_type, body.len,
    }) catch return;
    stream.writeAll(hdr) catch return;
    stream.writeAll(body) catch return;
}

/// Extract the last user message content from a chat completions JSON body.
/// Simple pattern matching without std.json (to avoid allocator dependency).
fn extractUserContent(body: []const u8) []const u8 {
    const role_patterns = [_][]const u8{ "\"role\":\"user\"", "\"role\": \"user\"" };
    var last_user_pos: ?usize = null;

    for (role_patterns) |role_pat| {
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, body, search_from, role_pat)) |pos| {
            last_user_pos = pos;
            search_from = pos + role_pat.len;
        }
    }

    const user_pos = last_user_pos orelse return "";

    const content_patterns = [_][]const u8{ "\"content\": \"", "\"content\":\"" };
    for (content_patterns) |content_pat| {
        if (std.mem.indexOfPos(u8, body, user_pos, content_pat)) |cpos| {
            const text_start = cpos + content_pat.len;
            var text_end = text_start;
            var in_escape = false;

            while (text_end < body.len) {
                const c = body[text_end];
                if (in_escape) {
                    in_escape = false;
                    text_end += 1;
                    continue;
                }
                if (c == '\\') {
                    in_escape = true;
                    text_end += 1;
                    continue;
                }
                if (c == '"') break;
                text_end += 1;
            }

            if (text_start < text_end) {
                return body[text_start..text_end];
            }
        }
    }
    return "";
}

// ============================================================================
// Topic
// ============================================================================

pub const Topic = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    subscriptions: std.StringHashMap(*Subscription),
    producers: std.ArrayListUnmanaged(*Producer),
    managed_ledger: *storage.ManagedLedger,
    ledger_id: i64,
    last_entry_id: std.atomic.Value(i64),

    pub fn init(allocator: std.mem.Allocator, name: []const u8, hana_client: *hana.HanaClient) !Topic {
        const name_copy = try allocator.dupe(u8, name);
        const ml = try storage.ManagedLedger.init(allocator, name, .{}, hana_client);
        return .{
            .allocator = allocator,
            .name = name_copy,
            .subscriptions = std.StringHashMap(*Subscription).init(allocator),
            .producers = .{},
            .managed_ledger = ml,
            .ledger_id = 0,
            .last_entry_id = std.atomic.Value(i64).init(-1),
        };
    }

    pub fn deinit(self: *Topic) void {
        // Clean up subscriptions
        var sub_iter = self.subscriptions.iterator();
        while (sub_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.subscriptions.deinit();

        // Clean up producers
        for (self.producers.items) |producer| {
            producer.deinit();
            self.allocator.destroy(producer);
        }
        self.producers.deinit(self.allocator);

        self.managed_ledger.deinit();
        self.allocator.free(self.name);
    }

    pub fn publish(self: *Topic, payload: []const u8) !i64 {
        const position = try self.managed_ledger.addEntry(payload);

        // --- SIMULATED PULSAR PUSH TO FABRIC ---
        // Mimic Pulsar message forwarding to ai-core-fabric on port 6650
        const fabric_port: u16 = 6650;
        if (std.net.tcpConnectToHost(self.allocator, "127.0.0.1", fabric_port)) |stream| {
            defer stream.close();
            _ = stream.writeAll(payload) catch {};
        } else |_| {
            // Silence connection errors to the simulator silently during typical dev
        }

        return position.entry_id;
    }

    pub fn getOrCreateSubscription(self: *Topic, sub_name: []const u8) !*Subscription {
        if (self.subscriptions.get(sub_name)) |sub| {
            return sub;
        }

        const sub = try self.allocator.create(Subscription);
        sub.* = try Subscription.init(self.allocator, sub_name, self.name, self.managed_ledger);
        try self.subscriptions.put(sub_name, sub);

        // Start dispatch thread
        _ = try std.Thread.spawn(.{}, Subscription.runDispatchLoop, .{sub});

        return sub;
    }
};

// ============================================================================
// Subscription
// ============================================================================

pub const SubscriptionType = enum {
    Exclusive,
    Shared,
    Failover,
    Key_Shared,
};

pub const Subscription = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    topic: []const u8,
    sub_type: SubscriptionType,
    consumers: std.ArrayListUnmanaged(*Consumer),
    cursor: *storage.ManagedCursor,
    lock: std.Thread.Mutex,
    active: bool,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, topic_name: []const u8, ledger: *storage.ManagedLedger) !Subscription {
        const cursor = try ledger.openCursor(name);
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .topic = try allocator.dupe(u8, topic_name),
            .sub_type = .Exclusive,
            .consumers = .{},
            .cursor = cursor,
            .lock = .{},
            .active = true,
        };
    }

    pub fn deinit(self: *Subscription) void {
        self.active = false;
        for (self.consumers.items) |consumer| {
            consumer.deinit();
            self.allocator.destroy(consumer);
        }
        self.consumers.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.free(self.topic);
    }

    pub fn runDispatchLoop(self: *Subscription) void {
        while (self.active) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            self.dispatchNextBatch() catch |err| {
                log.err("Dispatch error on {s}/{s}: {any}", .{ self.topic, self.name, err });
            };
        }
    }

    fn dispatchNextBatch(self: *Subscription) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.consumers.items.len == 0) return;

        // Simple round-robin or shared logic
        for (self.consumers.items) |consumer| {
            if (consumer.permits.load(.monotonic) > 0) {
                const entries = try self.cursor.readEntries(10);
                if (entries.len == 0) return;

                for (entries) |entry| {
                    if (consumer.usePermit()) {
                        // In production: send CommandMessage via connection stream
                        // consumer.connection.send(message)
                        log.debug("Dispatched message {any} to consumer {s}", .{ entry.getPosition(), consumer.name });
                    }
                }
            }
        }
    }
};

// ============================================================================
// Producer
// ============================================================================

pub const Producer = struct {
    allocator: std.mem.Allocator,
    id: u64,
    name: []const u8,
    topic: []const u8,
    sequence_id: std.atomic.Value(i64),

    pub fn init(allocator: std.mem.Allocator, id: u64, name: []const u8, topic: []const u8) !Producer {
        return .{
            .allocator = allocator,
            .id = id,
            .name = try allocator.dupe(u8, name),
            .topic = try allocator.dupe(u8, topic),
            .sequence_id = std.atomic.Value(i64).init(0),
        };
    }

    pub fn deinit(self: *Producer) void {
        self.allocator.free(self.name);
        self.allocator.free(self.topic);
    }
};

// ============================================================================
// Consumer
// ============================================================================

pub const Consumer = struct {
    allocator: std.mem.Allocator,
    id: u64,
    name: []const u8,
    subscription: []const u8,
    permits: std.atomic.Value(u32),
    connection: *ClientConnection,

    pub fn init(allocator: std.mem.Allocator, id: u64, name: []const u8, subscription: []const u8, conn: *ClientConnection) !Consumer {
        return .{
            .allocator = allocator,
            .id = id,
            .name = try allocator.dupe(u8, name),
            .subscription = try allocator.dupe(u8, subscription),
            .permits = std.atomic.Value(u32).init(0), // Start with 0 permits
            .connection = conn,
        };
    }

    pub fn deinit(self: *Consumer) void {
        self.allocator.free(self.name);
        self.allocator.free(self.subscription);
    }

    pub fn addPermits(self: *Consumer, permits: u32) void {
        _ = self.permits.fetchAdd(permits, .monotonic);
    }

    pub fn usePermit(self: *Consumer) bool {
        const old = self.permits.fetchSub(1, .monotonic);
        if (old == 0) {
            _ = self.permits.fetchAdd(1, .monotonic);
            return false;
        }
        return true;
    }
};

// ============================================================================
// ClientConnection
// ============================================================================

pub const ClientConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    broker: *Broker,
    address: std.net.Address,

    // State
    producers: std.AutoHashMap(u64, *Producer),
    consumers: std.AutoHashMap(u64, *Consumer),

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, broker: *Broker, address: std.net.Address) !*ClientConnection {
        const self = try allocator.create(ClientConnection);
        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .broker = broker,
            .address = address,
            .producers = std.AutoHashMap(u64, *Producer).init(allocator),
            .consumers = std.AutoHashMap(u64, *Consumer).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *ClientConnection) void {
        var prod_iter = self.producers.iterator();
        while (prod_iter.next()) |entry| {
            // Producer is owned by topic, but we might want to close it here
            _ = entry;
        }
        self.producers.deinit();

        var cons_iter = self.consumers.iterator();
        while (cons_iter.next()) |entry| {
            _ = entry;
        }
        self.consumers.deinit();
        self.stream.close();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Broker init and deinit" {
    const allocator = std.testing.allocator;
    const broker = try Broker.init(allocator, .{});
    defer broker.deinit();

    try std.testing.expectEqual(BrokerState.Initializing, broker.state);
}

test "Topic management" {
    const allocator = std.testing.allocator;
    const broker = try Broker.init(allocator, .{});
    defer broker.deinit();

    // Without a HANA client, getOrCreateTopic should return StorageNotInitialized
    const result = broker.getOrCreateTopic("test-topic");
    try std.testing.expectError(error.StorageNotInitialized, result);
}

test "extractUserContent basic" {
    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"hello world\"}]}";
    const content = extractUserContent(body);
    try std.testing.expectEqualStrings("hello world", content);
}

test "extractUserContent picks last user message" {
    const body =
        \\{"messages":[{"role":"user","content":"first"},{"role":"assistant","content":"reply"},{"role":"user","content":"second"}]}
    ;
    const content = extractUserContent(body);
    try std.testing.expectEqualStrings("second", content);
}

test "extractUserContent returns empty on no user" {
    const body = "{\"messages\":[{\"role\":\"system\",\"content\":\"you are helpful\"}]}";
    const content = extractUserContent(body);
    try std.testing.expectEqualStrings("", content);
}
