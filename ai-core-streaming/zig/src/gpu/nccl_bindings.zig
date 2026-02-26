//! NCCL (NVIDIA Collective Communications Library) Bindings
//! 
//! Provides GPU-to-GPU collective operations for distributed training and inference:
//! - AllReduce: Sum/Average gradients across all GPUs
//! - Broadcast: Distribute model weights from one GPU to all
//! - AllGather: Collect data from all GPUs
//! - ReduceScatter: Reduce and scatter results
//! 
//! Optimized for:
//! - 16 GPU cluster (4 nodes × 4 GPUs)
//! - Network: TCP/IP (Ethernet)
//! - Hardware: T4, L4, A100, H100

const std = @import("std");
const builtin = @import("builtin");
const cuda_bindings = @import("cuda_bindings.zig");
const multi_gpu = @import("multi_gpu_manager.zig");

const log = std.log.scoped(.nccl);

// ============================================================================
// NCCL Types
// ============================================================================

pub const NcclComm = *anyopaque;
pub const NcclUniqueId = extern struct {
    internal: [128]u8 = [_]u8{0} ** 128,
};

// ============================================================================
// NCCL Error Codes
// ============================================================================

pub const NcclResult = enum(c_int) {
    Success = 0,
    UnhandledCudaError = 1,
    SystemError = 2,
    InternalError = 3,
    InvalidArgument = 4,
    InvalidUsage = 5,
    RemoteError = 6,
    InProgress = 7,
    NumResults = 8,
    _,
    
    pub fn isSuccess(self: NcclResult) bool {
        return self == .Success;
    }
    
    pub fn toString(self: NcclResult) []const u8 {
        return switch (self) {
            .Success => "Success",
            .UnhandledCudaError => "Unhandled CUDA error",
            .SystemError => "System error",
            .InternalError => "Internal error",
            .InvalidArgument => "Invalid argument",
            .InvalidUsage => "Invalid usage",
            .RemoteError => "Remote error",
            .InProgress => "Operation in progress",
            else => "Unknown error",
        };
    }
};

// ============================================================================
// NCCL Data Types
// ============================================================================

pub const NcclDataType = enum(c_int) {
    ncclInt8 = 0,
    // ncclChar = 0, // Same as ncclInt8
    ncclUint8 = 1,
    ncclInt32 = 2,
    // ncclInt = 2,  // Same as ncclInt32
    ncclUint32 = 3,
    ncclInt64 = 4,
    ncclUint64 = 5,
    ncclFloat16 = 6,
    // ncclHalf = 6, // Same as ncclFloat16
    ncclFloat32 = 7,
    // ncclFloat = 7, // Same as ncclFloat32
    ncclFloat64 = 8,
    // ncclDouble = 8, // Same as ncclFloat64
    ncclBfloat16 = 9,
    ncclNumTypes = 10,
    
    // Aliases as constants
    pub const ncclChar = NcclDataType.ncclInt8;
    pub const ncclInt = NcclDataType.ncclInt32;
    pub const ncclHalf = NcclDataType.ncclFloat16;
    pub const ncclFloat = NcclDataType.ncclFloat32;
    pub const ncclDouble = NcclDataType.ncclFloat64;
    
    pub fn getSize(self: NcclDataType) usize {
        return switch (self) {
            .ncclInt8, .ncclUint8 => 1,
            .ncclFloat16, .ncclBfloat16 => 2,
            .ncclInt32, .ncclUint32, .ncclFloat32 => 4,
            .ncclInt64, .ncclUint64, .ncclFloat64 => 8,
            else => 4,
        };
    }
};

// ============================================================================
// NCCL Reduction Operations
// ============================================================================

pub const NcclRedOp = enum(c_int) {
    ncclSum = 0,
    ncclProd = 1,
    ncclMax = 2,
    ncclMin = 3,
    ncclAvg = 4,  // NCCL 2.10+
    ncclNumOps = 5,
};

// ============================================================================
// External NCCL Declarations
// ============================================================================

const nccl_available = builtin.os.tag == .linux and !builtin.is_test;

// NCCL library functions (linked via -lnccl)
extern "c" fn ncclGetVersion(version: *c_int) NcclResult;
extern "c" fn ncclGetUniqueId(uniqueId: *NcclUniqueId) NcclResult;
extern "c" fn ncclCommInitRank(comm: *NcclComm, nranks: c_int, commId: NcclUniqueId, rank: c_int) NcclResult;
extern "c" fn ncclCommInitAll(comms: [*]NcclComm, ndev: c_int, devlist: [*]const c_int) NcclResult;
extern "c" fn ncclCommDestroy(comm: NcclComm) NcclResult;
extern "c" fn ncclCommAbort(comm: NcclComm) NcclResult;
extern "c" fn ncclCommGetAsyncError(comm: NcclComm, asyncError: *NcclResult) NcclResult;
extern "c" fn ncclCommCount(comm: NcclComm, count: *c_int) NcclResult;
extern "c" fn ncclCommCuDevice(comm: NcclComm, device: *c_int) NcclResult;
extern "c" fn ncclCommUserRank(comm: NcclComm, rank: *c_int) NcclResult;

// Collective operations
extern "c" fn ncclAllReduce(
    sendbuff: *const anyopaque,
    recvbuff: *anyopaque,
    count: usize,
    datatype: NcclDataType,
    op: NcclRedOp,
    comm: NcclComm,
    stream: cuda_bindings.cudaStream_t,
) NcclResult;

extern "c" fn ncclBroadcast(
    sendbuff: *const anyopaque,
    recvbuff: *anyopaque,
    count: usize,
    datatype: NcclDataType,
    root: c_int,
    comm: NcclComm,
    stream: cuda_bindings.cudaStream_t,
) NcclResult;

extern "c" fn ncclReduce(
    sendbuff: *const anyopaque,
    recvbuff: *anyopaque,
    count: usize,
    datatype: NcclDataType,
    op: NcclRedOp,
    root: c_int,
    comm: NcclComm,
    stream: cuda_bindings.cudaStream_t,
) NcclResult;

extern "c" fn ncclAllGather(
    sendbuff: *const anyopaque,
    recvbuff: *anyopaque,
    sendcount: usize,
    datatype: NcclDataType,
    comm: NcclComm,
    stream: cuda_bindings.cudaStream_t,
) NcclResult;

extern "c" fn ncclReduceScatter(
    sendbuff: *const anyopaque,
    recvbuff: *anyopaque,
    recvcount: usize,
    datatype: NcclDataType,
    op: NcclRedOp,
    comm: NcclComm,
    stream: cuda_bindings.cudaStream_t,
) NcclResult;

extern "c" fn ncclSend(
    sendbuff: *const anyopaque,
    count: usize,
    datatype: NcclDataType,
    peer: c_int,
    comm: NcclComm,
    stream: cuda_bindings.cudaStream_t,
) NcclResult;

extern "c" fn ncclRecv(
    recvbuff: *anyopaque,
    count: usize,
    datatype: NcclDataType,
    peer: c_int,
    comm: NcclComm,
    stream: cuda_bindings.cudaStream_t,
) NcclResult;

extern "c" fn ncclGroupStart() NcclResult;
extern "c" fn ncclGroupEnd() NcclResult;

// ============================================================================
// NCCL Communicator Configuration
// ============================================================================

pub const NcclConfig = struct {
    /// Total number of ranks (GPUs) in the communicator
    world_size: u8 = 16,
    /// This rank's ID (0 to world_size-1)
    rank: u8 = 0,
    /// Number of GPUs on this node
    local_world_size: u8 = 4,
    /// This GPU's local rank (0 to local_world_size-1)
    local_rank: u8 = 0,
    /// Node ID
    node_id: u8 = 0,
    
    /// Network settings
    socket_ifname: ?[]const u8 = null, // Network interface (e.g., "eth0")
    
    pub fn fromEnvironment() NcclConfig {
        var config = NcclConfig{};
        
        // Read from environment variables (set by orchestrator like Kubernetes)
        if (std.posix.getenv("WORLD_SIZE")) |ws| {
            config.world_size = std.fmt.parseInt(u8, ws, 10) catch 1;
        }
        if (std.posix.getenv("RANK")) |r| {
            config.rank = std.fmt.parseInt(u8, r, 10) catch 0;
        }
        if (std.posix.getenv("LOCAL_WORLD_SIZE")) |lws| {
            config.local_world_size = std.fmt.parseInt(u8, lws, 10) catch 1;
        }
        if (std.posix.getenv("LOCAL_RANK")) |lr| {
            config.local_rank = std.fmt.parseInt(u8, lr, 10) catch 0;
        }
        if (std.posix.getenv("NODE_RANK")) |nr| {
            config.node_id = std.fmt.parseInt(u8, nr, 10) catch 0;
        }
        
        // NCCL-specific environment
        if (std.posix.getenv("NCCL_SOCKET_IFNAME")) |ifname| {
            config.socket_ifname = ifname;
        }
        
        return config;
    }
    
    pub fn getGlobalRank(self: NcclConfig) u8 {
        return self.node_id * self.local_world_size + self.local_rank;
    }
};

// ============================================================================
// NCCL Communicator Manager
// ============================================================================

pub const NcclCommunicator = struct {
    allocator: std.mem.Allocator,
    config: NcclConfig,
    
    /// NCCL communicator handle (one per local GPU)
    comms: [multi_gpu.ClusterConfig.MAX_GPUS_PER_NODE]?NcclComm = 
        [_]?NcclComm{null} ** multi_gpu.ClusterConfig.MAX_GPUS_PER_NODE,
    
    /// CUDA streams for async operations
    streams: [multi_gpu.ClusterConfig.MAX_GPUS_PER_NODE]?cuda_bindings.cudaStream_t = 
        [_]?cuda_bindings.cudaStream_t{null} ** multi_gpu.ClusterConfig.MAX_GPUS_PER_NODE,
    
    /// Unique ID for this communicator group
    unique_id: NcclUniqueId = .{},
    
    /// Initialization status
    initialized: bool = false,
    
    const Self = @This();
    
    /// Initialize NCCL communicator for single-node multi-GPU
    pub fn initSingleNode(allocator: std.mem.Allocator, gpu_count: u8) !*Self {
        var self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = .{
                .world_size = gpu_count,
                .local_world_size = gpu_count,
            },
        };
        
        if (comptime !nccl_available) {
            log.warn("NCCL not available on this platform", .{});
            self.initialized = true;
            return self;
        }
        
        // Create device list [0, 1, 2, ..., gpu_count-1]
        var devices: [multi_gpu.ClusterConfig.MAX_GPUS_PER_NODE]c_int = undefined;
        for (0..gpu_count) |i| {
            devices[i] = @intCast(i);
        }
        
        // Initialize all communicators at once
        var comms_array: [multi_gpu.ClusterConfig.MAX_GPUS_PER_NODE]NcclComm = undefined;
        const result = ncclCommInitAll(&comms_array, @intCast(gpu_count), &devices);
        
        if (!result.isSuccess()) {
            log.err("ncclCommInitAll failed: {s}", .{result.toString()});
            allocator.destroy(self);
            return error.NcclInitFailed;
        }
        
        // Store communicators
        for (0..gpu_count) |i| {
            self.comms[i] = comms_array[i];
            
            // Create CUDA stream for this GPU
            try cuda_bindings.setDevice(@intCast(i));
            self.streams[i] = try cuda_bindings.createStream();
        }
        
        self.initialized = true;
        log.info("NCCL single-node initialized with {} GPUs", .{gpu_count});
        
        return self;
    }
    
    /// Initialize NCCL communicator for multi-node cluster
    pub fn initMultiNode(allocator: std.mem.Allocator, config: NcclConfig, unique_id: NcclUniqueId) !*Self {
        var self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .unique_id = unique_id,
        };
        
        if (comptime !nccl_available) {
            log.warn("NCCL not available on this platform", .{});
            self.initialized = true;
            return self;
        }
        
        // Initialize communicator for each local GPU
        for (0..config.local_world_size) |local_rank| {
            const global_rank = config.node_id * config.local_world_size + @as(u8, @intCast(local_rank));
            
            try cuda_bindings.setDevice(@intCast(local_rank));
            
            var comm: NcclComm = undefined;
            const result = ncclCommInitRank(
                &comm,
                @intCast(config.world_size),
                unique_id,
                @intCast(global_rank),
            );
            
            if (!result.isSuccess()) {
                log.err("ncclCommInitRank failed for rank {}: {s}", .{ global_rank, result.toString() });
                self.cleanup();
                allocator.destroy(self);
                return error.NcclInitFailed;
            }
            
            self.comms[local_rank] = comm;
            self.streams[local_rank] = try cuda_bindings.createStream();
        }
        
        self.initialized = true;
        log.info("NCCL multi-node initialized: rank {}/{} on node {}", .{
            config.rank,
            config.world_size,
            config.node_id,
        });
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.cleanup();
        self.allocator.destroy(self);
    }
    
    fn cleanup(self: *Self) void {
        for (0..multi_gpu.ClusterConfig.MAX_GPUS_PER_NODE) |i| {
            if (self.comms[i]) |comm| {
                if (comptime nccl_available) {
                    _ = ncclCommDestroy(comm);
                }
                self.comms[i] = null;
            }
            if (self.streams[i]) |stream| {
                cuda_bindings.destroyStream(stream);
                self.streams[i] = null;
            }
        }
    }
    
    // ========================================================================
    // Collective Operations
    // ========================================================================
    
    /// AllReduce: Sum values across all GPUs
    /// After operation, all GPUs have the sum of all inputs
    pub fn allReduce(
        self: *Self,
        local_gpu: u8,
        sendbuff: *const anyopaque,
        recvbuff: *anyopaque,
        count: usize,
        datatype: NcclDataType,
        op: NcclRedOp,
    ) !void {
        if (!self.initialized) return error.NotInitialized;
        if (local_gpu >= multi_gpu.ClusterConfig.MAX_GPUS_PER_NODE) return error.InvalidGpu;
        
        const comm = self.comms[local_gpu] orelse return error.CommNotInitialized;
        const stream = self.streams[local_gpu] orelse return error.StreamNotInitialized;
        
        if (comptime !nccl_available) {
            log.debug("NCCL AllReduce (simulated): {} elements", .{count});
            return;
        }
        
        const result = ncclAllReduce(sendbuff, recvbuff, count, datatype, op, comm, stream);
        if (!result.isSuccess()) {
            log.err("ncclAllReduce failed: {s}", .{result.toString()});
            return error.NcclOperationFailed;
        }
    }
    
    /// Broadcast: Send data from root GPU to all others
    pub fn broadcast(
        self: *Self,
        local_gpu: u8,
        sendbuff: *const anyopaque,
        recvbuff: *anyopaque,
        count: usize,
        datatype: NcclDataType,
        root: c_int,
    ) !void {
        if (!self.initialized) return error.NotInitialized;
        
        const comm = self.comms[local_gpu] orelse return error.CommNotInitialized;
        const stream = self.streams[local_gpu] orelse return error.StreamNotInitialized;
        
        if (comptime !nccl_available) {
            log.debug("NCCL Broadcast (simulated): {} elements from root {}", .{ count, root });
            return;
        }
        
        const result = ncclBroadcast(sendbuff, recvbuff, count, datatype, root, comm, stream);
        if (!result.isSuccess()) {
            log.err("ncclBroadcast failed: {s}", .{result.toString()});
            return error.NcclOperationFailed;
        }
    }
    
    /// AllGather: Gather data from all GPUs to all GPUs
    /// Each GPU sends `sendcount` elements, receives `sendcount * world_size` elements
    pub fn allGather(
        self: *Self,
        local_gpu: u8,
        sendbuff: *const anyopaque,
        recvbuff: *anyopaque,
        sendcount: usize,
        datatype: NcclDataType,
    ) !void {
        if (!self.initialized) return error.NotInitialized;
        
        const comm = self.comms[local_gpu] orelse return error.CommNotInitialized;
        const stream = self.streams[local_gpu] orelse return error.StreamNotInitialized;
        
        if (comptime !nccl_available) {
            log.debug("NCCL AllGather (simulated): {} elements", .{sendcount});
            return;
        }
        
        const result = ncclAllGather(sendbuff, recvbuff, sendcount, datatype, comm, stream);
        if (!result.isSuccess()) {
            log.err("ncclAllGather failed: {s}", .{result.toString()});
            return error.NcclOperationFailed;
        }
    }
    
    /// ReduceScatter: Reduce and scatter across GPUs
    /// Each GPU receives 1/world_size of the reduced result
    pub fn reduceScatter(
        self: *Self,
        local_gpu: u8,
        sendbuff: *const anyopaque,
        recvbuff: *anyopaque,
        recvcount: usize,
        datatype: NcclDataType,
        op: NcclRedOp,
    ) !void {
        if (!self.initialized) return error.NotInitialized;
        
        const comm = self.comms[local_gpu] orelse return error.CommNotInitialized;
        const stream = self.streams[local_gpu] orelse return error.StreamNotInitialized;
        
        if (comptime !nccl_available) {
            log.debug("NCCL ReduceScatter (simulated): {} elements", .{recvcount});
            return;
        }
        
        const result = ncclReduceScatter(sendbuff, recvbuff, recvcount, datatype, op, comm, stream);
        if (!result.isSuccess()) {
            log.err("ncclReduceScatter failed: {s}", .{result.toString()});
            return error.NcclOperationFailed;
        }
    }
    
    /// Synchronize CUDA stream for a specific GPU
    pub fn synchronize(self: *Self, local_gpu: u8) !void {
        if (self.streams[local_gpu]) |stream| {
            try cuda_bindings.streamSynchronize(stream);
        }
    }
    
    /// Synchronize all local GPU streams
    pub fn synchronizeAll(self: *Self) !void {
        for (0..self.config.local_world_size) |i| {
            try self.synchronize(@intCast(i));
        }
    }
};

// ============================================================================
// High-Level Training Operations
// ============================================================================

pub const GradientReducer = struct {
    comm: *NcclCommunicator,
    
    const Self = @This();
    
    pub fn init(comm: *NcclCommunicator) Self {
        return .{ .comm = comm };
    }
    
    /// Reduce gradients across all GPUs using AllReduce with averaging
    /// This is the core operation for distributed training
    pub fn reduceGradients(
        self: *Self,
        local_gpu: u8,
        gradients: *anyopaque,
        count: usize,
    ) !void {
        // AllReduce with SUM, then divide by world_size for average
        try self.comm.allReduce(
            local_gpu,
            gradients,
            gradients, // In-place
            count,
            .ncclFloat32,
            .ncclSum,
        );
        
        // Note: For true averaging, divide by world_size after AllReduce
        // Or use ncclAvg (NCCL 2.10+)
    }
    
    /// Broadcast model weights from rank 0 to all other ranks
    pub fn broadcastWeights(
        self: *Self,
        local_gpu: u8,
        weights: *anyopaque,
        count: usize,
    ) !void {
        try self.comm.broadcast(
            local_gpu,
            weights,
            weights, // In-place
            count,
            .ncclFloat32,
            0, // Root rank
        );
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Get NCCL version
pub fn getVersion() !c_int {
    if (comptime !nccl_available) return 0;
    
    var version: c_int = 0;
    const result = ncclGetVersion(&version);
    if (!result.isSuccess()) {
        return error.NcclError;
    }
    return version;
}

/// Generate a unique ID (must be called on rank 0 and broadcast to others)
pub fn generateUniqueId() !NcclUniqueId {
    var id = NcclUniqueId{};
    
    if (comptime !nccl_available) {
        // Generate random ID for testing
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        prng.random().bytes(&id.internal);
        return id;
    }
    
    const result = ncclGetUniqueId(&id);
    if (!result.isSuccess()) {
        log.err("ncclGetUniqueId failed: {s}", .{result.toString()});
        return error.NcclError;
    }
    return id;
}

/// Check if NCCL is available
pub fn isAvailable() bool {
    if (comptime !nccl_available) return false;
    
    var version: c_int = 0;
    const result = ncclGetVersion(&version);
    return result.isSuccess() and version > 0;
}

// ============================================================================
// Tests
// ============================================================================

test "NcclConfig from environment" {
    // This test will use default values if env vars are not set
    const config = NcclConfig.fromEnvironment();
    
    // At minimum, we should have valid defaults
    try std.testing.expect(config.world_size >= 1);
    try std.testing.expect(config.local_world_size >= 1);
}

test "NcclDataType sizes" {
    try std.testing.expectEqual(@as(usize, 1), NcclDataType.ncclInt8.getSize());
    try std.testing.expectEqual(@as(usize, 2), NcclDataType.ncclFloat16.getSize());
    try std.testing.expectEqual(@as(usize, 4), NcclDataType.ncclFloat32.getSize());
    try std.testing.expectEqual(@as(usize, 8), NcclDataType.ncclFloat64.getSize());
}

test "NcclResult toString" {
    try std.testing.expectEqualStrings("Success", NcclResult.Success.toString());
    try std.testing.expectEqualStrings("Invalid argument", NcclResult.InvalidArgument.toString());
}

test "generateUniqueId returns valid ID" {
    const id = try generateUniqueId();
    
    // Check that not all bytes are zero (highly unlikely for random)
    var all_zero = true;
    for (id.internal) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    
    // In test mode without NCCL, we generate random bytes
    if (comptime !nccl_available) {
        try std.testing.expect(!all_zero);
    }
}

test "NcclConfig global rank calculation" {
    const config = NcclConfig{
        .world_size = 16,
        .local_world_size = 4,
        .node_id = 2,
        .local_rank = 3,
    };
    
    // Node 2, Local rank 3 = 2 * 4 + 3 = 11
    try std.testing.expectEqual(@as(u8, 11), config.getGlobalRank());
}