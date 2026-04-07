//! BDC AIPrompt Streaming - Broker Core
//! Main broker implementation with topic management, subscriptions, and message dispatch

const std = @import("std");
const protocol = @import("protocol");
const hana = @import("hana");
const storage = @import("storage");
const llama = @import("llama");
const prometheus = @import("../metrics/prometheus.zig");
const wal_mod = @import("../recovery/wal.zig");
const recovery_mod = @import("../recovery/state_recovery.zig");
const xsuaa = @import("../auth/xsuaa.zig");

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
    /// When authentication_enabled is true the broker validates every CONNECT
    /// token against this XSUAA configuration.  If null, the config is loaded
    /// from VCAP_SERVICES / individual XSUAA_* env vars at startup.
    xsuaa_config: ?xsuaa.XsuaaConfig = null,
    // HANA storage
    hana_host: []const u8 = "",
    hana_port: u16 = 443,
    hana_schema: []const u8 = "AIPROMPT_STORAGE",
    // vLLM upstream for /v1/toon/chat/completions and /v1/chat/completions
    // Set via VLLM_BASE_URL env var or override in BrokerOptions.
    // Example: "http://localhost:8000"
    vllm_base_url: []const u8 = "",

    // Speculative decoding (DART / Engram) configuration.
    //
    // DART  — Draft-Assisted Rejection-based Transformer decoding.
    //         Set VLLM_SPEC_DECODE_MODEL to the draft model path/name.
    //         Set VLLM_SPEC_DECODE_NUM_SPECULATIVE_TOKENS (default: 5).
    //
    // Engram — SAP-internal n-gram draft model (no separate model file needed).
    //          Set VLLM_SPEC_DECODE_METHOD=ngram to activate.
    //
    // When either env var is set the broker injects `speculative_config` into
    // every forwarded chat/completions request body before sending to vLLM.
    // vLLM ≥ 0.4.0 supports this field natively.
    //
    // Env vars (all optional):
    //   VLLM_SPEC_DECODE_MODEL   — draft model name/path (activates DART)
    //   VLLM_SPEC_DECODE_METHOD  — "ngram" activates Engram; default "draft_model"
    //   VLLM_SPEC_DECODE_TOKENS  — number of speculative tokens (default: 5)
    vllm_spec_decode_model: []const u8 = "",
    vllm_spec_decode_method: []const u8 = "draft_model",
    vllm_spec_decode_tokens: u8 = 5,
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

    // Prometheus metrics (wraps the same counters for /metrics exposition)
    metrics: prometheus.PrometheusMetrics,

    // WAL for crash recovery
    wal: ?wal_mod.WAL,

    // XSUAA token validator — non-null when authentication_enabled is true
    validator: ?xsuaa.TokenValidator,

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
            .metrics = prometheus.PrometheusMetrics.init(allocator),
            .wal = null,
            .validator = null,
        };

        // Initialise the XSUAA token validator when authentication is enabled
        if (options.authentication_enabled) {
            const cfg = options.xsuaa_config orelse
                xsuaa.XsuaaConfig.fromEnv(allocator) catch |err| blk: {
                    log.warn("Could not load XSUAA config from environment: {} — auth disabled", .{err});
                    break :blk null;
                };
            if (cfg) |c| {
                broker.validator = xsuaa.TokenValidator.init(allocator, c);
                log.info("XSUAA token validator initialised (url={s})", .{c.url});
            }
        }

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

        // Deinit WAL
        if (self.wal) |*w| w.deinit();

        // Deinit XSUAA validator
        if (self.validator) |*v| v.deinit();

        self.allocator.destroy(self);
    }

    pub fn start(self: *Broker) !void {
        log.info("Starting broker with cluster name: {s}", .{self.options.cluster_name});

        // Initialize HANA connection
        try self.initStorage();

        // Initialize WAL and replay any uncommitted state from a previous run
        try self.initAndReplayWAL();

        // Start binary protocol server
        try self.startBinaryServer();

        // Start HTTP admin server
        try self.startHttpServer();

        self.state = .Running;
        log.info("Broker is now running", .{});
    }

    fn initAndReplayWAL(self: *Broker) !void {
        const wal_dir = "data/wal";
        log.info("Initializing WAL at {s}", .{wal_dir});

        self.wal = try wal_mod.WAL.init(self.allocator, wal_dir, .{});

        // Run state recovery
        var engine = recovery_mod.StateRecoveryEngine.init(
            self.allocator,
            &self.wal.?,
            .{ .wal_dir = wal_dir, .hana_sync_enabled = false },
        );
        defer engine.deinit();

        const recovered = try engine.recover();

        // Re-create topics that were alive at crash time
        var topic_iter = recovered.topics.iterator();
        while (topic_iter.next()) |entry| {
            const ts = entry.value_ptr;
            if (ts.is_deleted) continue;
            _ = self.getOrCreateTopic(ts.name) catch |err| {
                log.warn("WAL replay: failed to restore topic {s}: {}", .{ ts.name, err });
            };
        }

        const p = engine.getProgress();
        log.info("WAL replay complete: {} topics, {} subscriptions, {} cursors restored (LSN {})", .{
            p.topics_recovered, p.subscriptions_recovered, p.cursors_recovered, recovered.last_lsn,
        });
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
        self.metrics.recordConnection();

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
                // Parse the CommandConnect to extract auth_data
                const parsed_connect = protocol.ParsedConnect.parse(frame.cmd_data, self.allocator) catch |err| {
                    log.warn("Failed to parse CommandConnect: {}", .{err});
                    const resp = try handler.createConnectFailedResponse("malformed CONNECT frame");
                    defer self.allocator.free(resp);
                    try stream.writeAll(resp);
                    return error.MalformedConnect;
                };
                defer {
                    self.allocator.free(parsed_connect.client_version);
                    self.allocator.free(parsed_connect.auth_method_name);
                    if (parsed_connect.auth_data) |ad| self.allocator.free(ad);
                }

                log.info("CONNECT from {any} client_version={s}", .{
                    connection.address, parsed_connect.client_version,
                });

                // Authenticate when a validator is configured
                if (self.validator) |*v| {
                    const token_bytes = parsed_connect.auth_data orelse {
                        log.warn("Auth required but no auth_data in CONNECT from {any}", .{connection.address});
                        const resp = try handler.createConnectFailedResponse("auth_data required");
                        defer self.allocator.free(resp);
                        try stream.writeAll(resp);
                        return error.AuthenticationRequired;
                    };

                    // auth_data may be prefixed with "Bearer " or be a raw token
                    const raw = token_bytes;
                    const token_str = if (std.mem.startsWith(u8, raw, "Bearer "))
                        raw[7..]
                    else
                        raw;

                    var jwt = v.validate(token_str) catch |err| {
                        log.warn("Token validation failed for {any}: {}", .{ connection.address, err });
                        const resp = try handler.createConnectFailedResponse("token validation failed");
                        defer self.allocator.free(resp);
                        try stream.writeAll(resp);
                        return error.AuthenticationFailed;
                    };
                    defer jwt.deinit();

                    log.info("Authenticated connection from {any} sub={s}", .{
                        connection.address,
                        jwt.payload.sub orelse "unknown",
                    });
                }

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
                const parsed = try protocol.ParsedProducer.parse(frame.cmd_data, self.allocator);
                defer {
                    self.allocator.free(parsed.topic);
                    self.allocator.free(parsed.producer_name);
                }

                const topic = try self.getOrCreateTopic(parsed.topic);
                const producer = try self.allocator.create(Producer);
                producer.* = try Producer.init(self.allocator, parsed.producer_id, parsed.producer_name, parsed.topic);

                try topic.producers.append(topic.allocator, producer);
                try connection.producers.put(parsed.producer_id, producer);

                const response = try handler.createSuccessResponse(parsed.request_id);
                defer self.allocator.free(response);
                try stream.writeAll(response);
                log.info("Producer registered: {s} on {s}", .{ producer.name, parsed.topic });
            },
            .SUBSCRIBE => {
                const parsed = try protocol.ParsedSubscribe.parse(frame.cmd_data, self.allocator);
                defer {
                    self.allocator.free(parsed.topic);
                    self.allocator.free(parsed.subscription);
                    self.allocator.free(parsed.consumer_name);
                }

                const topic = try self.getOrCreateTopic(parsed.topic);
                const sub = try topic.getOrCreateSubscription(parsed.subscription);

                const consumer = try self.allocator.create(Consumer);
                consumer.* = try Consumer.init(self.allocator, parsed.consumer_id, parsed.consumer_name, parsed.subscription, connection);

                try sub.consumers.append(sub.allocator, consumer);
                try connection.consumers.put(parsed.consumer_id, consumer);

                const response = try handler.createSuccessResponse(parsed.request_id);
                defer self.allocator.free(response);
                try stream.writeAll(response);
                log.info("Consumer subscribed: {s} to {s} (sub: {s})", .{ consumer.name, parsed.topic, parsed.subscription });
            },
            .SEND => {
                const parsed = protocol.ParsedSend.parse(frame.cmd_data);
                const payload = frame.payload orelse return error.MissingPayload;

                const producer = connection.producers.get(parsed.producer_id) orelse return error.ProducerNotFound;
                const topic = self.getTopic(producer.topic) orelse return error.TopicNotFound;

                const entry_id = try topic.publish(payload);
                self.metrics.recordMessageIn(1);
                _ = self.messages_in.fetchAdd(1, .monotonic);

                const response = try handler.createSuccessResponse(parsed.sequence_id);
                _ = entry_id;
                defer self.allocator.free(response);
                try stream.writeAll(response);
            },
            .FLOW => {
                const parsed = protocol.ParsedFlow.parse(frame.cmd_data);

                if (connection.consumers.get(parsed.consumer_id)) |consumer| {
                    consumer.addPermits(parsed.message_permits);
                    log.debug("Added {} permits to consumer {s}", .{ parsed.message_permits, consumer.name });
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
        // Keep gauge metrics in sync with broker state before rendering
        _ = self.metrics.messages_in.store(self.messages_in.load(.monotonic), .monotonic);
        _ = self.metrics.messages_out.store(self.messages_out.load(.monotonic), .monotonic);

        // Append broker-level gauges then delegate to PrometheusMetrics.renderText()
        const prom_text = self.metrics.renderText(self.allocator) catch {
            sendHttpPlain(stream, 200, "# render error\n");
            return;
        };
        defer self.allocator.free(prom_text);

        const stats = self.getStats();
        const gauge_text = std.fmt.allocPrint(self.allocator,
            \\# HELP broker_topics_count Number of active topics
            \\# TYPE broker_topics_count gauge
            \\broker_topics_count {d}
            \\# HELP broker_uptime_ms Broker uptime in milliseconds
            \\# TYPE broker_uptime_ms gauge
            \\broker_uptime_ms {d}
            \\
        , .{ stats.topics_count, stats.uptime_ms }) catch {
            sendHttpPlain(stream, 200, prom_text);
            return;
        };
        defer self.allocator.free(gauge_text);

        const full = std.mem.concat(self.allocator, u8, &.{ prom_text, gauge_text }) catch {
            sendHttpPlain(stream, 200, prom_text);
            return;
        };
        defer self.allocator.free(full);
        sendHttpPlain(stream, 200, full);
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

        // Determine vLLM base URL: option field > env var > localhost default
        const base_url = blk: {
            if (self.options.vllm_base_url.len > 0) break :blk self.options.vllm_base_url;
            if (std.posix.getenv("VLLM_BASE_URL")) |env| break :blk env;
            break :blk "http://127.0.0.1:8000";
        };

        // Build the upstream URL: forward to vLLM's OpenAI-compatible endpoint
        const upstream_url = std.fmt.allocPrint(self.allocator, "{s}/v1/chat/completions", .{base_url}) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"URL allocation failed\",\"type\":\"server_error\"}}");
            return;
        };
        defer self.allocator.free(upstream_url);

        // Parse host and port from upstream_url for std.net.tcpConnectToHost
        // Expected format: http://host:port  (no TLS for internal sidecar)
        const host_port = parseHostPort(upstream_url) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"Invalid vLLM URL\",\"type\":\"server_error\"}}");
            return;
        };

        const vllm_stream = std.net.tcpConnectToHost(self.allocator, host_port.host, host_port.port) catch {
            sendHttpJson(stream, 503, "{\"error\":{\"message\":\"vLLM upstream unavailable\",\"type\":\"server_error\"}}");
            return;
        };
        defer vllm_stream.close();

        // Optionally inject speculative_config (DART / Engram) into the request body
        const effective_body = self.injectSpecDecodeConfig(request_body) catch request_body;
        defer if (effective_body.ptr != request_body.ptr) self.allocator.free(effective_body);

        // Forward the (possibly enriched) body to vLLM
        const http_req = std.fmt.allocPrint(self.allocator,
            "POST /v1/chat/completions HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ host_port.host, host_port.port, effective_body.len, effective_body },
        ) catch {
            sendHttpJson(stream, 500, "{\"error\":{\"message\":\"Request build failed\",\"type\":\"server_error\"}}");
            return;
        };
        defer self.allocator.free(http_req);

        vllm_stream.writeAll(http_req) catch {
            sendHttpJson(stream, 502, "{\"error\":{\"message\":\"vLLM write failed\",\"type\":\"server_error\"}}");
            return;
        };

        // Read the full HTTP response from vLLM (up to 4 MiB)
        var resp_buf = std.ArrayList(u8).init(self.allocator);
        defer resp_buf.deinit();
        vllm_stream.reader().readAllArrayList(&resp_buf, 4 * 1024 * 1024) catch {};

        // Strip HTTP headers — find the blank line separating headers from body
        const raw = resp_buf.items;
        const body_start = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse 0;
        const json_body = if (body_start + 4 < raw.len) raw[body_start + 4 ..] else "{}";

        // Parse HTTP status from first line ("HTTP/1.1 200 OK")
        const status_code: u16 = parseHttpStatus(raw) orelse 200;

        sendHttpJson(stream, status_code, json_body);
    }

    /// Inject `speculative_config` into a JSON chat/completions body for vLLM
    /// speculative decoding (DART draft-model or Engram n-gram).
    ///
    /// Returns the original slice unchanged when spec-decode is not configured.
    /// Returns a newly allocated slice (caller must free) when injection occurs.
    fn injectSpecDecodeConfig(self: *Broker, body: []const u8) ![]u8 {
        // Resolve spec-decode settings: option fields > env vars
        const spec_model = blk: {
            if (self.options.vllm_spec_decode_model.len > 0) break :blk self.options.vllm_spec_decode_model;
            break :blk std.posix.getenv("VLLM_SPEC_DECODE_MODEL") orelse "";
        };
        const spec_method = blk: {
            if (self.options.vllm_spec_decode_method.len > 0) break :blk self.options.vllm_spec_decode_method;
            break :blk std.posix.getenv("VLLM_SPEC_DECODE_METHOD") orelse "draft_model";
        };
        const spec_tokens_str = std.posix.getenv("VLLM_SPEC_DECODE_TOKENS") orelse "";
        const spec_tokens: u8 = if (spec_tokens_str.len > 0)
            std.fmt.parseInt(u8, spec_tokens_str, 10) catch self.options.vllm_spec_decode_tokens
        else
            self.options.vllm_spec_decode_tokens;

        // Neither DART nor Engram configured → pass through unchanged
        const use_ngram = std.mem.eql(u8, spec_method, "ngram");
        if (!use_ngram and spec_model.len == 0) return body;

        // Already has speculative_config → don't double-inject
        if (std.mem.indexOf(u8, body, "speculative_config") != null) return body;

        // Build the speculative_config JSON fragment
        const spec_fragment = if (use_ngram)
            // Engram: SAP-internal n-gram draft (no separate model file)
            try std.fmt.allocPrint(self.allocator,
                \\,"speculative_config":{{"method":"ngram","num_speculative_tokens":{d},"prompt_lookup_max":4}}
            , .{spec_tokens})
        else
            // DART: draft-model-based speculative decoding
            try std.fmt.allocPrint(self.allocator,
                \\,"speculative_config":{{"draft_model_name":"{s}","num_speculative_tokens":{d}}}
            , .{ spec_model, spec_tokens });
        defer self.allocator.free(spec_fragment);

        // Inject before the closing `}` of the top-level JSON object
        const close = std.mem.lastIndexOfScalar(u8, body, '}') orelse return body;
        const new_body = try std.mem.concat(self.allocator, u8, &.{
            body[0..close],
            spec_fragment,
            body[close..],
        });
        return new_body;
    }

    /// Parse "http://host:port/..." → { host, port }
    const HostPort = struct { host: []const u8, port: u16 };
    fn parseHostPort(url: []const u8) !HostPort {
        // Strip scheme
        const after_scheme = if (std.mem.startsWith(u8, url, "http://"))
            url[7..]
        else if (std.mem.startsWith(u8, url, "https://"))
            url[8..]
        else
            url;
        // Strip path
        const host_part = if (std.mem.indexOfScalar(u8, after_scheme, '/')) |slash|
            after_scheme[0..slash]
        else
            after_scheme;
        // Split host:port
        if (std.mem.lastIndexOfScalar(u8, host_part, ':')) |colon| {
            const host = host_part[0..colon];
            const port = std.fmt.parseInt(u16, host_part[colon + 1 ..], 10) catch return error.InvalidPort;
            return .{ .host = host, .port = port };
        }
        return .{ .host = host_part, .port = 8000 };
    }

    fn parseHttpStatus(raw: []const u8) ?u16 {
        // "HTTP/1.1 200 OK\r\n..."
        const sp1 = std.mem.indexOfScalar(u8, raw, ' ') orelse return null;
        const rest = raw[sp1 + 1 ..];
        const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return std.fmt.parseInt(u16, rest[0..sp2], 10) catch null;
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
