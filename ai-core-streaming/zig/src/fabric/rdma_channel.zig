//! BDC AIPrompt Streaming - RDMA Channel Support
//! High-performance networking via Remote Direct Memory Access

const std = @import("std");

const log = std.log.scoped(.rdma);

// ============================================================================
// RDMA Configuration
// ============================================================================

pub const RdmaConfig = struct {
    /// Enable RDMA support
    enabled: bool = false,
    /// Device name (e.g., "mlx5_0")
    device_name: []const u8 = "mlx5_0",
    /// GID index
    gid_index: u32 = 0,
    /// Max send work requests
    max_send_wr: u32 = 1024,
    /// Max receive work requests
    max_recv_wr: u32 = 1024,
    /// Max scatter/gather entries
    max_sge: u32 = 16,
    /// Max inline data size
    max_inline_data: u32 = 256,
    /// Connection timeout (ms)
    timeout_ms: u32 = 5000,
    /// Retry count
    retry_count: u32 = 7,
};

// ============================================================================
// RDMA Device
// ============================================================================

pub const RdmaDevice = struct {
    device_id: []const u8,
    name: []const u8,
    vendor: []const u8,
    port_count: u32,
    max_qp: u32,
    max_mr: u32,
    is_available: bool,

    pub fn init(name: []const u8) RdmaDevice {
        return .{
            .device_id = name,
            .name = name,
            .vendor = "Mellanox",
            .port_count = 2,
            .max_qp = 65535,
            .max_mr = 16777216,
            .is_available = false,
        };
    }
};

// ============================================================================
// RDMA Memory Region
// ============================================================================

pub const MemoryRegion = struct {
    mr_id: []const u8,
    address: usize,
    length: usize,
    access_flags: AccessFlags,
    lkey: u32,
    rkey: u32,
    buffer: ?[]u8,

    pub const AccessFlags = packed struct {
        local_write: bool = true,
        remote_write: bool = false,
        remote_read: bool = false,
        remote_atomic: bool = false,
        mw_bind: bool = false,
        zero_based: bool = false,
        on_demand: bool = false,
        _padding: u25 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, mr_id: []const u8, size: usize, flags: AccessFlags) !MemoryRegion {
        const buffer = try allocator.alloc(u8, size);

        return .{
            .mr_id = mr_id,
            .address = @intFromPtr(buffer.ptr),
            .length = size,
            .access_flags = flags,
            .lkey = generateKey(),
            .rkey = generateKey(),
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *MemoryRegion, allocator: std.mem.Allocator) void {
        if (self.buffer) |buf| {
            allocator.free(buf);
            self.buffer = null;
        }
    }

    fn generateKey() u32 {
        var buf: [4]u8 = undefined;
        std.crypto.random.bytes(&buf);
        return std.mem.readInt(u32, &buf, .little);
    }
};

// ============================================================================
// RDMA Connection
// ============================================================================

pub const RdmaConnection = struct {
    allocator: std.mem.Allocator,
    conn_id: []const u8,
    local_device: []const u8,
    remote_host: []const u8,
    remote_port: u16,
    status: ConnectionStatus,
    created_at: i64,

    // Queue pair info
    qp_num: u32,
    lid: u16,
    gid: [16]u8,

    // Registered memory regions
    memory_regions: std.ArrayList(*MemoryRegion),

    // Statistics
    bytes_sent: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),
    sends_completed: std.atomic.Value(u64),
    recvs_completed: std.atomic.Value(u64),
    errors: std.atomic.Value(u64),

    pub const ConnectionStatus = enum {
        disconnected,
        connecting,
        connected,
        @"error",
        closing,
    };

    pub fn init(allocator: std.mem.Allocator, conn_id: []const u8, local_device: []const u8, remote_host: []const u8, remote_port: u16) RdmaConnection {
        return .{
            .allocator = allocator,
            .conn_id = conn_id,
            .local_device = local_device,
            .remote_host = remote_host,
            .remote_port = remote_port,
            .status = .disconnected,
            .created_at = std.time.milliTimestamp(),
            .qp_num = 0,
            .lid = 0,
            .gid = std.mem.zeroes([16]u8),
            .memory_regions = .{},
            .bytes_sent = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .sends_completed = std.atomic.Value(u64).init(0),
            .recvs_completed = std.atomic.Value(u64).init(0),
            .errors = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *RdmaConnection) void {
        self.memory_regions.deinit(self.allocator);
    }

    /// Register a memory region for RDMA operations
    pub fn registerMemoryRegion(self: *RdmaConnection, mr: *MemoryRegion) !void {
        try self.memory_regions.append(self.allocator, mr);
        log.debug("Registered memory region: {s}, size={}", .{ mr.mr_id, mr.length });
    }

    /// Get connection statistics
    pub fn getStats(self: *RdmaConnection) ConnectionStats {
        return .{
            .bytes_sent = self.bytes_sent.load(.monotonic),
            .bytes_received = self.bytes_received.load(.monotonic),
            .sends_completed = self.sends_completed.load(.monotonic),
            .recvs_completed = self.recvs_completed.load(.monotonic),
            .errors = self.errors.load(.monotonic),
            .status = self.status,
        };
    }
};

pub const ConnectionStats = struct {
    bytes_sent: u64,
    bytes_received: u64,
    sends_completed: u64,
    recvs_completed: u64,
    errors: u64,
    status: RdmaConnection.ConnectionStatus,
};

// ============================================================================
// RDMA Operations
// ============================================================================

pub const RdmaOp = struct {
    op_id: []const u8,
    op_type: OpType,
    status: OpStatus,
    requested_at: i64,
    completed_at: ?i64,
    bytes_transferred: u64,
    duration_ns: u64,

    pub const OpType = enum {
        send,
        recv,
        write,
        read,
        atomic_cmp_swap,
        atomic_fetch_add,
    };

    pub const OpStatus = enum {
        pending,
        in_progress,
        success,
        @"error",
        timeout,
    };
};

// ============================================================================
// RDMA Channel Manager
// ============================================================================

pub const RdmaChannelManager = struct {
    allocator: std.mem.Allocator,
    config: RdmaConfig,
    device: ?RdmaDevice,
    connections: std.StringHashMap(*RdmaConnection),
    connection_lock: std.Thread.Mutex,

    // Statistics
    total_connections: std.atomic.Value(u64),
    active_connections: std.atomic.Value(u64),
    total_operations: std.atomic.Value(u64),
    failed_operations: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: RdmaConfig) RdmaChannelManager {
        return .{
            .allocator = allocator,
            .config = config,
            .device = null,
            .connections = std.StringHashMap(*RdmaConnection).init(allocator),
            .connection_lock = .{},
            .total_connections = std.atomic.Value(u64).init(0),
            .active_connections = std.atomic.Value(u64).init(0),
            .total_operations = std.atomic.Value(u64).init(0),
            .failed_operations = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *RdmaChannelManager) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
    }

    /// Initialize RDMA device
    pub fn initDevice(self: *RdmaChannelManager) !void {
        if (!self.config.enabled) {
            log.info("RDMA disabled in configuration", .{});
            return;
        }

        log.info("Initializing RDMA device: {s}", .{self.config.device_name});

        // In production: open RDMA device via ibverbs
        // struct ibv_device **dev_list = ibv_get_device_list(NULL);
        // struct ibv_context *ctx = ibv_open_device(dev_list[0]);

        self.device = RdmaDevice.init(self.config.device_name);

        // Check if device is available (simulate hardware check)
        if (self.device) |*dev| {
            dev.is_available = self.checkRdmaHardware();
            if (dev.is_available) {
                log.info("RDMA device {s} available: {} QPs, {} MRs", .{
                    dev.name,
                    dev.max_qp,
                    dev.max_mr,
                });
            } else {
                log.warn("RDMA device {s} not available - falling back to TCP", .{dev.name});
            }
        }
    }

    /// Check if RDMA hardware is available
    fn checkRdmaHardware(self: *RdmaChannelManager) bool {
        _ = self;
        // In production: check via /sys/class/infiniband/
        // For now: check environment variable
        if (std.posix.getenv("RDMA_ENABLED")) |val| {
            return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
        }
        return false;
    }

    /// Create connection to remote host
    pub fn createConnection(self: *RdmaChannelManager, remote_host: []const u8, remote_port: u16) !*RdmaConnection {
        if (self.device == null or !self.device.?.is_available) {
            return error.RdmaNotAvailable;
        }

        const conn_id = try std.fmt.allocPrint(self.allocator, "rdma-{s}-{}-{}", .{
            remote_host,
            remote_port,
            std.time.milliTimestamp(),
        });

        const conn = try self.allocator.create(RdmaConnection);
        conn.* = RdmaConnection.init(
            self.allocator,
            conn_id,
            self.config.device_name,
            remote_host,
            remote_port,
        );

        self.connection_lock.lock();
        defer self.connection_lock.unlock();

        try self.connections.put(conn_id, conn);
        _ = self.total_connections.fetchAdd(1, .monotonic);

        log.info("Created RDMA connection: {s} -> {s}:{}", .{
            conn_id,
            remote_host,
            remote_port,
        });

        return conn;
    }

    /// Connect to remote host
    pub fn connect(self: *RdmaChannelManager, conn: *RdmaConnection) !void {
        _ = self;

        conn.status = .connecting;
        log.info("Connecting RDMA: {s}", .{conn.conn_id});

        // In production: RDMA CM connection establishment
        // rdma_create_event_channel()
        // rdma_create_id()
        // rdma_resolve_addr()
        // rdma_resolve_route()
        // rdma_connect()

        // Simulate connection
        conn.status = .connected;
        conn.qp_num = std.crypto.random.int(u32);
        conn.lid = std.crypto.random.int(u16);
        std.crypto.random.bytes(&conn.gid);

        log.info("RDMA connected: {s}, QP={}, LID={}", .{
            conn.conn_id,
            conn.qp_num,
            conn.lid,
        });
    }

    /// Post RDMA send operation
    pub fn postSend(self: *RdmaChannelManager, conn: *RdmaConnection, mr: *MemoryRegion, offset: usize, length: usize) !RdmaOp {
        if (conn.status != .connected) {
            return error.NotConnected;
        }

        _ = self.total_operations.fetchAdd(1, .monotonic);

        const op = RdmaOp{
            .op_id = "send-op",
            .op_type = .send,
            .status = .in_progress,
            .requested_at = std.time.nanoTimestamp(),
            .completed_at = null,
            .bytes_transferred = length,
            .duration_ns = 0,
        };

        // In production: ibv_post_send()
        log.debug("RDMA send: conn={s}, mr={s}, offset={}, len={}", .{
            conn.conn_id,
            mr.mr_id,
            offset,
            length,
        });

        _ = conn.bytes_sent.fetchAdd(length, .monotonic);
        _ = conn.sends_completed.fetchAdd(1, .monotonic);

        return op;
    }

    /// Post RDMA receive operation
    pub fn postRecv(self: *RdmaChannelManager, conn: *RdmaConnection, mr: *MemoryRegion, offset: usize, length: usize) !RdmaOp {
        if (conn.status != .connected) {
            return error.NotConnected;
        }

        _ = self.total_operations.fetchAdd(1, .monotonic);

        const op = RdmaOp{
            .op_id = "recv-op",
            .op_type = .recv,
            .status = .in_progress,
            .requested_at = std.time.nanoTimestamp(),
            .completed_at = null,
            .bytes_transferred = length,
            .duration_ns = 0,
        };

        // In production: ibv_post_recv()
        log.debug("RDMA recv: conn={s}, mr={s}, offset={}, len={}", .{
            conn.conn_id,
            mr.mr_id,
            offset,
            length,
        });

        return op;
    }

    /// Post RDMA write (one-sided)
    pub fn postWrite(self: *RdmaChannelManager, conn: *RdmaConnection, local_mr: *MemoryRegion, remote_addr: u64, remote_rkey: u32, length: usize) !RdmaOp {
        if (conn.status != .connected) {
            return error.NotConnected;
        }

        _ = self.total_operations.fetchAdd(1, .monotonic);

        const op = RdmaOp{
            .op_id = "write-op",
            .op_type = .write,
            .status = .in_progress,
            .requested_at = std.time.nanoTimestamp(),
            .completed_at = null,
            .bytes_transferred = length,
            .duration_ns = 0,
        };

        // In production: ibv_post_send() with IBV_WR_RDMA_WRITE
        log.debug("RDMA write: conn={s}, mr={s}, remote_addr={x}, rkey={}, len={}", .{
            conn.conn_id,
            local_mr.mr_id,
            remote_addr,
            remote_rkey,
            length,
        });

        _ = conn.bytes_sent.fetchAdd(length, .monotonic);

        return op;
    }

    /// Post RDMA read (one-sided)
    pub fn postRead(self: *RdmaChannelManager, conn: *RdmaConnection, local_mr: *MemoryRegion, remote_addr: u64, remote_rkey: u32, length: usize) !RdmaOp {
        if (conn.status != .connected) {
            return error.NotConnected;
        }

        _ = self.total_operations.fetchAdd(1, .monotonic);

        const op = RdmaOp{
            .op_id = "read-op",
            .op_type = .read,
            .status = .in_progress,
            .requested_at = std.time.nanoTimestamp(),
            .completed_at = null,
            .bytes_transferred = length,
            .duration_ns = 0,
        };

        // In production: ibv_post_send() with IBV_WR_RDMA_READ
        log.debug("RDMA read: conn={s}, mr={s}, remote_addr={x}, rkey={}, len={}", .{
            conn.conn_id,
            local_mr.mr_id,
            remote_addr,
            remote_rkey,
            length,
        });

        _ = conn.bytes_received.fetchAdd(length, .monotonic);

        return op;
    }

    /// Get manager statistics
    pub fn getStats(self: *RdmaChannelManager) ManagerStats {
        return .{
            .total_connections = self.total_connections.load(.monotonic),
            .active_connections = self.connections.count(),
            .total_operations = self.total_operations.load(.monotonic),
            .failed_operations = self.failed_operations.load(.monotonic),
            .rdma_available = if (self.device) |d| d.is_available else false,
        };
    }
};

pub const ManagerStats = struct {
    total_connections: u64,
    active_connections: usize,
    total_operations: u64,
    failed_operations: u64,
    rdma_available: bool,
};

// ============================================================================
// Mangle Integration - Fabric Channel Registration
// ============================================================================

pub const FabricChannelMangle = struct {
    /// Generate Mangle fact for RDMA channel
    pub fn getChannelFact(conn: *RdmaConnection) []const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator,
            \\fabric_channel(
            \\    "{s}",
            \\    "node-aiprompt",
            \\    "node-{s}",
            \\    "rdma",
            \\    "{s}",
            \\    {}
            \\).
        , .{
            conn.conn_id,
            conn.remote_host,
            @tagName(conn.status),
            conn.created_at,
        }) catch "";
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RdmaChannelManager init" {
    const allocator = std.testing.allocator;

    var manager = RdmaChannelManager.init(allocator, .{ .enabled = false });
    defer manager.deinit();

    try manager.initDevice();

    const stats = manager.getStats();
    try std.testing.expect(!stats.rdma_available);
}

test "MemoryRegion allocation" {
    const allocator = std.testing.allocator;

    var mr = try MemoryRegion.init(allocator, "test-mr", 4096, .{});
    defer mr.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4096), mr.length);
    try std.testing.expect(mr.buffer != null);
    try std.testing.expect(mr.lkey != 0);
    try std.testing.expect(mr.rkey != 0);
}

test "RdmaConnection init" {
    const allocator = std.testing.allocator;

    var conn = RdmaConnection.init(allocator, "test-conn", "mlx5_0", "remote-host", 4791);
    defer conn.deinit();

    try std.testing.expectEqual(RdmaConnection.ConnectionStatus.disconnected, conn.status);
    try std.testing.expectEqualStrings("remote-host", conn.remote_host);
}