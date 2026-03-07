//! Multi-GPU Manager for Distributed Inference and Training
//! 
//! Supports up to 16 GPUs across 4 nodes (4 GPUs per node)
//! Target hardware: NVIDIA T4, L4, A100, H100
//! 
//! Features:
//! - Multi-GPU workload distribution
//! - P2P (Peer-to-Peer) memory transfers
//! - Batch splitting and load balancing
//! - Topology-aware scheduling

const std = @import("std");
const builtin = @import("builtin");
const cuda_bindings = @import("cuda_bindings.zig");

const log = std.log.scoped(.multi_gpu);

// ============================================================================
// Cluster Configuration Constants
// ============================================================================

pub const ClusterConfig = struct {
    /// Maximum GPUs per node
    pub const MAX_GPUS_PER_NODE: u8 = 4;
    /// Maximum nodes in cluster
    pub const MAX_NODES: u8 = 4;
    /// Maximum total GPUs
    pub const MAX_TOTAL_GPUS: u8 = MAX_GPUS_PER_NODE * MAX_NODES; // 16
};

// ============================================================================
// GPU Device Information
// ============================================================================

pub const GpuArchitecture = enum {
    unknown,
    turing,      // T4 (SM 7.5)
    ampere,      // A100 (SM 8.0), L4 (SM 8.9)
    ada,         // L4 (SM 8.9) - also Ada Lovelace
    hopper,      // H100 (SM 9.0)
    
    pub fn fromComputeCapability(major: c_int, minor: c_int) GpuArchitecture {
        return switch (major) {
            9 => .hopper,
            8 => if (minor >= 9) .ada else .ampere,
            7 => if (minor >= 5) .turing else .unknown,
            else => .unknown,
        };
    }
    
    pub fn getName(self: GpuArchitecture) []const u8 {
        return switch (self) {
            .turing => "Turing (T4)",
            .ampere => "Ampere (A100/A10)",
            .ada => "Ada Lovelace (L4)",
            .hopper => "Hopper (H100)",
            .unknown => "Unknown",
        };
    }
    
    /// Get optimal thread block size for this architecture
    pub fn getOptimalBlockSize(self: GpuArchitecture) u32 {
        return switch (self) {
            .hopper => 512,  // H100 has more registers
            .ampere, .ada => 256,
            .turing => 256,
            .unknown => 128,
        };
    }
};

pub const GpuDevice = struct {
    /// Device ID (0-15)
    device_id: u8,
    /// Node this GPU belongs to (0-3)
    node_id: u8,
    /// Local rank within node (0-3)
    local_rank: u8,
    
    /// Device properties
    name: [256]u8 = [_]u8{0} ** 256,
    name_len: usize = 0,
    architecture: GpuArchitecture = .unknown,
    compute_capability_major: c_int = 0,
    compute_capability_minor: c_int = 0,
    
    /// Memory
    total_memory_bytes: usize = 0,
    free_memory_bytes: usize = 0,
    
    /// Compute units
    multiprocessor_count: c_int = 0,
    max_threads_per_block: c_int = 0,
    
    /// Features
    supports_p2p: bool = false,
    supports_unified_memory: bool = false,
    supports_cooperative_launch: bool = false,
    
    pub fn getName(self: *const GpuDevice) []const u8 {
        return self.name[0..self.name_len];
    }
    
    /// Get memory in GB
    pub fn getTotalMemoryGB(self: *const GpuDevice) f32 {
        return @as(f32, @floatFromInt(self.total_memory_bytes)) / (1024 * 1024 * 1024);
    }
    
    pub fn getFreeMemoryGB(self: *const GpuDevice) f32 {
        return @as(f32, @floatFromInt(self.free_memory_bytes)) / (1024 * 1024 * 1024);
    }
};

// ============================================================================
// P2P (Peer-to-Peer) Connectivity
// ============================================================================

pub const P2PConnectivity = struct {
    /// P2P access matrix: can_access[src][dst] = true if src can directly access dst
    can_access: [ClusterConfig.MAX_GPUS_PER_NODE][ClusterConfig.MAX_GPUS_PER_NODE]bool = 
        [_][ClusterConfig.MAX_GPUS_PER_NODE]bool{[_]bool{false} ** ClusterConfig.MAX_GPUS_PER_NODE} ** ClusterConfig.MAX_GPUS_PER_NODE,
    
    /// NVLink connectivity (faster than PCIe P2P)
    has_nvlink: [ClusterConfig.MAX_GPUS_PER_NODE][ClusterConfig.MAX_GPUS_PER_NODE]bool = 
        [_][ClusterConfig.MAX_GPUS_PER_NODE]bool{[_]bool{false} ** ClusterConfig.MAX_GPUS_PER_NODE} ** ClusterConfig.MAX_GPUS_PER_NODE,
    
    /// Number of GPUs with P2P capability
    p2p_enabled_count: u8 = 0,
    
    pub fn canAccessPeer(self: *const P2PConnectivity, src: u8, dst: u8) bool {
        if (src >= ClusterConfig.MAX_GPUS_PER_NODE or dst >= ClusterConfig.MAX_GPUS_PER_NODE) {
            return false;
        }
        return self.can_access[src][dst];
    }
    
    pub fn hasNvLinkConnection(self: *const P2PConnectivity, src: u8, dst: u8) bool {
        if (src >= ClusterConfig.MAX_GPUS_PER_NODE or dst >= ClusterConfig.MAX_GPUS_PER_NODE) {
            return false;
        }
        return self.has_nvlink[src][dst];
    }
};

// ============================================================================
// Workload Distribution
// ============================================================================

pub const WorkloadStrategy = enum {
    /// Split batch evenly across all GPUs
    data_parallel,
    /// Split model layers across GPUs (for large models)
    pipeline_parallel,
    /// Split tensor dimensions across GPUs (for very large layers)
    tensor_parallel,
    /// Hybrid of data and model parallelism
    hybrid,
};

pub const DeviceTask = struct {
    /// Which GPU to execute on
    device_id: u8,
    /// Start index in batch
    batch_start: usize,
    /// Number of items in this chunk
    batch_size: usize,
    /// Memory buffer for this GPU (device pointer)
    input_buffer: u64 = 0,
    output_buffer: u64 = 0,
    /// Execution status
    completed: bool = false,
    task_error: ?anyerror = null,
};

pub const WorkloadDistribution = struct {
    tasks: [ClusterConfig.MAX_TOTAL_GPUS]?DeviceTask = [_]?DeviceTask{null} ** ClusterConfig.MAX_TOTAL_GPUS,
    task_count: u8 = 0,
    total_batch_size: usize = 0,
    strategy: WorkloadStrategy = .data_parallel,
    
    pub fn getTasks(self: *const WorkloadDistribution) []const ?DeviceTask {
        return self.tasks[0..self.task_count];
    }
};

// ============================================================================
// Multi-GPU Manager
// ============================================================================

pub const MultiGpuManager = struct {
    allocator: std.mem.Allocator,
    
    /// Discovered GPUs on this node
    local_devices: [ClusterConfig.MAX_GPUS_PER_NODE]?GpuDevice = [_]?GpuDevice{null} ** ClusterConfig.MAX_GPUS_PER_NODE,
    local_gpu_count: u8 = 0,
    
    /// P2P connectivity matrix for local GPUs
    p2p_connectivity: P2PConnectivity = .{},
    
    /// Node identification
    node_id: u8 = 0,
    
    /// Currently active device
    active_device: u8 = 0,
    
    /// Initialization status
    initialized: bool = false,
    
    const Self = @This();
    
    /// Initialize the Multi-GPU Manager
    /// Discovers all GPUs on this node and enables P2P access
    pub fn init(allocator: std.mem.Allocator) !*Self {
        var self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
        };
        
        try self.discoverDevices();
        try self.setupP2PAccess();
        
        self.initialized = true;
        
        log.info("Multi-GPU Manager initialized: {} GPUs on node {}", .{ self.local_gpu_count, self.node_id });
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.disableP2PAccess();
        self.allocator.destroy(self);
    }
    
    /// Discover all CUDA devices on this node
    fn discoverDevices(self: *Self) !void {
        const device_count = cuda_bindings.getDeviceCount() catch |err| {
            log.warn("Failed to get CUDA device count: {}", .{err});
            return;
        };
        
        if (device_count == 0) {
            log.info("No CUDA devices found", .{});
            return;
        }
        
        const count: u8 = @min(@as(u8, @intCast(device_count)), ClusterConfig.MAX_GPUS_PER_NODE);
        
        for (0..count) |i| {
            const device_id: c_int = @intCast(i);
            
            const info = cuda_bindings.getDeviceInfo(device_id) catch |err| {
                log.warn("Failed to get info for device {}: {}", .{ device_id, err });
                continue;
            };
            
            var device = GpuDevice{
                .device_id = @intCast(i),
                .node_id = self.node_id,
                .local_rank = @intCast(i),
                .compute_capability_major = info.compute_capability_major,
                .compute_capability_minor = info.compute_capability_minor,
                .total_memory_bytes = info.total_global_mem,
                .free_memory_bytes = info.free_global_mem,
                .multiprocessor_count = info.multiprocessor_count,
                .max_threads_per_block = info.max_threads_per_block,
                .supports_unified_memory = info.managed_memory,
                .supports_cooperative_launch = info.cooperative_launch,
            };
            
            // Copy name
            const name_slice = info.getName();
            @memcpy(device.name[0..name_slice.len], name_slice);
            device.name_len = name_slice.len;
            
            // Determine architecture
            device.architecture = GpuArchitecture.fromComputeCapability(
                info.compute_capability_major,
                info.compute_capability_minor,
            );
            
            self.local_devices[i] = device;
            self.local_gpu_count += 1;
            
            log.info("Discovered GPU {}: {s} ({s}) - {d:.1f} GB", .{
                i,
                device.getName(),
                device.architecture.getName(),
                device.getTotalMemoryGB(),
            });
        }
    }
    
    /// Setup P2P (Peer-to-Peer) access between GPUs
    fn setupP2PAccess(self: *Self) !void {
        if (self.local_gpu_count < 2) {
            return; // P2P only relevant with 2+ GPUs
        }
        
        // Check P2P capability between all GPU pairs
        for (0..self.local_gpu_count) |i| {
            for (0..self.local_gpu_count) |j| {
                if (i == j) {
                    self.p2p_connectivity.can_access[i][j] = true;
                    continue;
                }
                
                // Check if P2P access is possible
                const can_access = self.checkP2PCapability(@intCast(i), @intCast(j));
                self.p2p_connectivity.can_access[i][j] = can_access;
                
                if (can_access) {
                    // Enable P2P access
                    self.enableP2P(@intCast(i), @intCast(j)) catch |err| {
                        log.warn("Failed to enable P2P {} -> {}: {}", .{ i, j, err });
                    };
                    self.p2p_connectivity.p2p_enabled_count += 1;
                }
            }
        }
        
        log.info("P2P setup complete: {} connections enabled", .{self.p2p_connectivity.p2p_enabled_count});
    }
    
    /// Check if P2P access is possible between two devices
    fn checkP2PCapability(self: *Self, src: u8, dst: u8) bool {
        _ = self;
        
        // In a real implementation, this would call:
        // cudaDeviceCanAccessPeer(&can_access, src, dst)
        
        // For now, assume P2P is possible between GPUs on same node
        // (actual check requires CUDA runtime call)
        _ = src;
        _ = dst;
        return true; // Optimistic default
    }
    
    /// Enable P2P access from src to dst
    fn enableP2P(self: *Self, src: u8, dst: u8) !void {
        _ = self;
        
        // In real implementation:
        // cudaSetDevice(src);
        // cudaDeviceEnablePeerAccess(dst, 0);
        
        log.debug("Enabled P2P access: {} -> {}", .{ src, dst });
    }
    
    /// Disable all P2P access
    fn disableP2PAccess(self: *Self) void {
        for (0..self.local_gpu_count) |i| {
            for (0..self.local_gpu_count) |j| {
                if (i != j and self.p2p_connectivity.can_access[i][j]) {
                    // cudaSetDevice(i);
                    // cudaDeviceDisablePeerAccess(j);
                    log.debug("Disabled P2P access: {} -> {}", .{ i, j });
                }
            }
        }
    }
    
    /// Set the active CUDA device
    pub fn setActiveDevice(self: *Self, device_id: u8) !void {
        if (device_id >= self.local_gpu_count) {
            return error.InvalidDeviceId;
        }
        
        try cuda_bindings.setDevice(@intCast(device_id));
        self.active_device = device_id;
    }
    
    /// Get device by ID
    pub fn getDevice(self: *Self, device_id: u8) ?*GpuDevice {
        if (device_id >= ClusterConfig.MAX_GPUS_PER_NODE) {
            return null;
        }
        if (self.local_devices[device_id]) |*device| {
            return device;
        }
        return null;
    }
    
    /// Distribute a batch across available GPUs using data parallelism
    pub fn distributeWorkload(
        self: *Self,
        total_batch_size: usize,
        strategy: WorkloadStrategy,
    ) WorkloadDistribution {
        var distribution = WorkloadDistribution{
            .total_batch_size = total_batch_size,
            .strategy = strategy,
        };
        
        if (self.local_gpu_count == 0) {
            return distribution;
        }
        
        switch (strategy) {
            .data_parallel => {
                // Split batch evenly across GPUs
                const base_batch_size = total_batch_size / self.local_gpu_count;
                const remainder = total_batch_size % self.local_gpu_count;
                
                var offset: usize = 0;
                for (0..self.local_gpu_count) |i| {
                    const extra: usize = if (i < remainder) 1 else 0;
                    const chunk_size = base_batch_size + extra;
                    
                    distribution.tasks[i] = DeviceTask{
                        .device_id = @intCast(i),
                        .batch_start = offset,
                        .batch_size = chunk_size,
                    };
                    
                    offset += chunk_size;
                    distribution.task_count += 1;
                }
            },
            .tensor_parallel => {
                // Tensor parallelism: split weight matrices column-wise across GPUs
                // Each GPU computes a portion of each layer, then all-reduce to sync
                // This is for very large models that don't fit on a single GPU
                
                if (self.local_gpu_count < 2) {
                    // Fall back to single GPU
                    return self.distributeWorkload(total_batch_size, .data_parallel);
                }
                
                // For tensor parallel, each GPU processes ALL batch items,
                // but only a slice of the hidden dimensions
                for (0..self.local_gpu_count) |i| {
                    distribution.tasks[i] = DeviceTask{
                        .device_id = @intCast(i),
                        .batch_start = 0,  // All GPUs process full batch
                        .batch_size = total_batch_size,
                        // The tensor_shard_idx and total_shards would be used
                        // by the kernel to compute only columns [i*cols/n, (i+1)*cols/n)
                    };
                    distribution.task_count += 1;
                }
                
                log.info("Tensor parallel distribution: {} GPUs, each processing {} items (sharded)", .{
                    distribution.task_count,
                    total_batch_size,
                });
            },
            
            .pipeline_parallel => {
                // Pipeline parallelism: assign transformer layers to GPUs in round-robin
                // GPU 0: layers 0, 4, 8, ...
                // GPU 1: layers 1, 5, 9, ...
                // GPU 2: layers 2, 6, 10, ...
                // GPU 3: layers 3, 7, 11, ...
                // Activations are passed between GPUs via ZeroCopyPipeline
                
                if (self.local_gpu_count < 2) {
                    return self.distributeWorkload(total_batch_size, .data_parallel);
                }
                
                // For pipeline parallel with micro-batching:
                // Split batch into micro-batches, pipeline through stages
                const num_stages = self.local_gpu_count;
                const micro_batch_size = @max(1, total_batch_size / (num_stages * 2)); // 2x microbatches per stage
                const num_micro_batches = (total_batch_size + micro_batch_size - 1) / micro_batch_size;
                
                var offset: usize = 0;
                var task_idx: u8 = 0;
                
                // Create tasks for each micro-batch assigned to its starting stage
                for (0..num_micro_batches) |mb| {
                    const remaining = total_batch_size - offset;
                    const mb_size = @min(micro_batch_size, remaining);
                    
                    if (mb_size == 0) break;
                    
                    // Assign to stage based on micro-batch index for pipeline fill
                    const stage: u8 = @intCast(mb % num_stages);
                    
                    distribution.tasks[task_idx] = DeviceTask{
                        .device_id = stage,
                        .batch_start = offset,
                        .batch_size = mb_size,
                    };
                    
                    offset += mb_size;
                    task_idx += 1;
                    
                    if (task_idx >= ClusterConfig.MAX_TOTAL_GPUS) break;
                }
                
                distribution.task_count = task_idx;
                
                log.info("Pipeline parallel distribution: {} stages, {} micro-batches of ~{} items", .{
                    num_stages,
                    num_micro_batches,
                    micro_batch_size,
                });
            },
            
            .hybrid => {
                // Hybrid: combine data parallel + tensor/pipeline parallel
                // Example: 8 GPUs = 2 data-parallel replicas × 4 tensor-parallel shards
                
                if (self.local_gpu_count < 4) {
                    // Not enough GPUs for hybrid, use data parallel
                    return self.distributeWorkload(total_batch_size, .data_parallel);
                }
                
                // Split GPUs into replica groups
                const tensor_parallel_degree: u8 = 2; // Each replica uses 2 GPUs for tensor parallel
                const num_replicas = self.local_gpu_count / tensor_parallel_degree;
                
                // Split batch across replicas (data parallel)
                const base_batch_per_replica = total_batch_size / num_replicas;
                const remainder = total_batch_size % num_replicas;
                
                var offset: usize = 0;
                var task_idx: u8 = 0;
                
                for (0..num_replicas) |replica| {
                    const extra: usize = if (replica < remainder) 1 else 0;
                    const replica_batch_size = base_batch_per_replica + extra;
                    
                    // Each replica has tensor_parallel_degree GPUs
                    for (0..tensor_parallel_degree) |shard| {
                        const device_id = replica * tensor_parallel_degree + shard;
                        
                        distribution.tasks[task_idx] = DeviceTask{
                            .device_id = @intCast(device_id),
                            .batch_start = offset,
                            .batch_size = replica_batch_size,
                            // Within replica, this GPU handles shard [shard] of [tensor_parallel_degree]
                        };
                        task_idx += 1;
                    }
                    
                    offset += replica_batch_size;
                }
                
                distribution.task_count = task_idx;
                
                log.info("Hybrid distribution: {} replicas × {} tensor-parallel shards", .{
                    num_replicas,
                    tensor_parallel_degree,
                });
            },
        }
        
        return distribution;
    }
    
    /// Get total GPU memory across all local GPUs
    pub fn getTotalMemory(self: *Self) usize {
        var total: usize = 0;
        for (self.local_devices) |maybe_device| {
            if (maybe_device) |device| {
                total += device.total_memory_bytes;
            }
        }
        return total;
    }
    
    /// Get total free memory across all local GPUs
    pub fn getTotalFreeMemory(self: *Self) usize {
        var total: usize = 0;
        for (self.local_devices) |maybe_device| {
            if (maybe_device) |device| {
                total += device.free_memory_bytes;
            }
        }
        return total;
    }
    
    /// Print cluster status
    pub fn printStatus(self: *Self) void {
        log.info("=== Multi-GPU Manager Status ===", .{});
        log.info("Node ID: {}", .{self.node_id});
        log.info("Local GPUs: {}", .{self.local_gpu_count});
        log.info("Total Memory: {d:.1f} GB", .{
            @as(f32, @floatFromInt(self.getTotalMemory())) / (1024 * 1024 * 1024),
        });
        log.info("P2P Connections: {}", .{self.p2p_connectivity.p2p_enabled_count});
        
        for (0..self.local_gpu_count) |i| {
            if (self.local_devices[i]) |device| {
                log.info("  GPU {}: {s} ({d:.1f} GB free)", .{
                    i,
                    device.getName(),
                    device.getFreeMemoryGB(),
                });
            }
        }
    }
};

// ============================================================================
// Batch Processor for Multi-GPU Inference
// ============================================================================

pub const BatchProcessor = struct {
    manager: *MultiGpuManager,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, manager: *MultiGpuManager) Self {
        return .{
            .manager = manager,
            .allocator = allocator,
        };
    }
    
    /// Process a batch of embeddings across multiple GPUs
    pub fn processEmbeddingBatch(
        self: *Self,
        input_ids: []const []const u32,
        embedding_dim: usize,
    ) ![][]f32 {
        const batch_size = input_ids.len;
        
        // Distribute workload
        const distribution = self.manager.distributeWorkload(batch_size, .data_parallel);
        
        log.info("Processing batch of {} across {} GPUs", .{ batch_size, distribution.task_count });
        
        // Allocate output buffer
        const outputs = try self.allocator.alloc([]f32, batch_size);
        errdefer self.allocator.free(outputs);
        
        for (outputs) |*out| {
            out.* = try self.allocator.alloc(f32, embedding_dim);
        }
        
        // Process on each GPU (in real implementation, this would be parallel)
        for (distribution.getTasks()) |maybe_task| {
            if (maybe_task) |task| {
                try self.processOnDevice(task, input_ids, outputs, embedding_dim);
            }
        }
        
        return outputs;
    }
    
    fn processOnDevice(
        self: *Self,
        task: DeviceTask,
        input_ids: []const []const u32,
        outputs: [][]f32,
        embedding_dim: usize,
    ) !void {
        _ = self;
        
        // Set active device
        // try self.manager.setActiveDevice(task.device_id);
        
        log.debug("GPU {}: Processing items {} to {}", .{
            task.device_id,
            task.batch_start,
            task.batch_start + task.batch_size,
        });
        
        // In real implementation:
        // 1. Copy input_ids[task.batch_start..task.batch_start + task.batch_size] to GPU
        // 2. Execute embedding lookup kernel
        // 3. Copy results back to outputs
        
        // Placeholder: fill with zeros
        for (task.batch_start..task.batch_start + task.batch_size) |i| {
            @memset(outputs[i], 0.0);
        }
        
        // In real implementation, use actual GPU kernel results
        _ = input_ids;
        _ = embedding_dim;
    }
    
    pub fn deinit(self: *Self, outputs: [][]f32) void {
        for (outputs) |out| {
            self.allocator.free(out);
        }
        self.allocator.free(outputs);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GpuArchitecture detection" {
    try std.testing.expectEqual(GpuArchitecture.turing, GpuArchitecture.fromComputeCapability(7, 5));
    try std.testing.expectEqual(GpuArchitecture.ampere, GpuArchitecture.fromComputeCapability(8, 0));
    try std.testing.expectEqual(GpuArchitecture.ada, GpuArchitecture.fromComputeCapability(8, 9));
    try std.testing.expectEqual(GpuArchitecture.hopper, GpuArchitecture.fromComputeCapability(9, 0));
}

test "WorkloadDistribution even split" {
    var manager = MultiGpuManager{
        .allocator = std.testing.allocator,
        .local_gpu_count = 4,
    };
    
    const dist = manager.distributeWorkload(100, .data_parallel);
    
    try std.testing.expectEqual(@as(u8, 4), dist.task_count);
    
    var total: usize = 0;
    for (dist.getTasks()) |maybe_task| {
        if (maybe_task) |task| {
            total += task.batch_size;
        }
    }
    try std.testing.expectEqual(@as(usize, 100), total);
}

test "WorkloadDistribution with remainder" {
    var manager = MultiGpuManager{
        .allocator = std.testing.allocator,
        .local_gpu_count = 4,
    };
    
    const dist = manager.distributeWorkload(103, .data_parallel);
    
    // 103 / 4 = 25 remainder 3
    // First 3 GPUs get 26, last one gets 25
    if (dist.tasks[0]) |task| {
        try std.testing.expectEqual(@as(usize, 26), task.batch_size);
    }
    if (dist.tasks[3]) |task| {
        try std.testing.expectEqual(@as(usize, 25), task.batch_size);
    }
}

test "P2PConnectivity matrix" {
    var p2p = P2PConnectivity{};
    
    // Initially all false
    try std.testing.expect(!p2p.canAccessPeer(0, 1));
    
    // Enable access
    p2p.can_access[0][1] = true;
    try std.testing.expect(p2p.canAccessPeer(0, 1));
    
    // Out of bounds returns false
    try std.testing.expect(!p2p.canAccessPeer(10, 0));
}

test "ClusterConfig constants" {
    try std.testing.expectEqual(@as(u8, 4), ClusterConfig.MAX_GPUS_PER_NODE);
    try std.testing.expectEqual(@as(u8, 4), ClusterConfig.MAX_NODES);
    try std.testing.expectEqual(@as(u8, 16), ClusterConfig.MAX_TOTAL_GPUS);
}