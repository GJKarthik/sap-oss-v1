//! ANWID GPU Memory Pool
//! Triple-buffered GPU memory allocation for zero-copy data transfer

const std = @import("std");
const builtin = @import("builtin");
const context = @import("context.zig");

const log = std.log.scoped(.gpu_memory_pool);

// ============================================================================
// Memory Pool Configuration
// ============================================================================

pub const PoolConfig = struct {
    /// Number of buffer slots (triple buffering = 3)
    num_slots: usize = 3,
    /// Size of each buffer slot in bytes
    slot_size_bytes: usize = 64 * 1024 * 1024, // 64MB per slot
    /// Maximum elements per slot (for embedding batches)
    max_elements_per_slot: usize = 1024,
    /// Element stride in bytes (for f32 embeddings)
    element_stride: usize = 4096, // 1024 floats * 4 bytes
    /// Use pinned memory for faster transfers
    use_pinned_memory: bool = true,
};

// ============================================================================
// Buffer Slot
// ============================================================================

pub const BufferSlot = struct {
    /// Slot index (0, 1, 2 for triple buffering)
    index: usize,
    /// Current state of the slot
    state: State,
    /// CPU-side staging buffer
    cpu_buffer: ?[]u8,
    /// GPU-side buffer pointer (opaque)
    gpu_buffer: ?*anyopaque,
    /// Number of elements currently in slot
    element_count: usize,
    /// Size of data in bytes
    data_size: usize,
    /// Generation counter for tracking
    generation: u64,
    
    pub const State = enum {
        /// Slot is free for CPU to fill
        free,
        /// CPU is writing to slot
        cpu_filling,
        /// Ready for H2D transfer
        ready_for_transfer,
        /// GPU is processing
        gpu_processing,
        /// GPU complete, ready for D2H
        gpu_complete,
    };
    
    pub fn init(index: usize, size_bytes: usize, allocator: std.mem.Allocator) !BufferSlot {
        const cpu_buffer = try allocator.alloc(u8, size_bytes);
        @memset(cpu_buffer, 0);
        
        return .{
            .index = index,
            .state = .free,
            .cpu_buffer = cpu_buffer,
            .gpu_buffer = null, // Will be allocated on GPU init
            .element_count = 0,
            .data_size = 0,
            .generation = 0,
        };
    }
    
    pub fn deinit(self: *BufferSlot, allocator: std.mem.Allocator) void {
        if (self.cpu_buffer) |buf| {
            allocator.free(buf);
        }
        self.cpu_buffer = null;
        self.gpu_buffer = null;
    }
    
    pub fn reset(self: *BufferSlot) void {
        self.state = .free;
        self.element_count = 0;
        self.data_size = 0;
        self.generation += 1;
    }
    
    pub fn getWritePtr(self: *BufferSlot) ?[]u8 {
        if (self.state != .free and self.state != .cpu_filling) return null;
        self.state = .cpu_filling;
        return self.cpu_buffer;
    }
    
    pub fn commitWrite(self: *BufferSlot, element_count: usize, data_size: usize) void {
        self.element_count = element_count;
        self.data_size = data_size;
        self.state = .ready_for_transfer;
    }
};

// ============================================================================
// Ring Buffer Index
// ============================================================================

pub const RingIndex = struct {
    write_idx: std.atomic.Value(u64),
    read_idx: std.atomic.Value(u64),
    size: usize,
    
    pub fn init(size: usize) RingIndex {
        return .{
            .write_idx = std.atomic.Value(u64).init(0),
            .read_idx = std.atomic.Value(u64).init(0),
            .size = size,
        };
    }
    
    pub fn acquireWrite(self: *RingIndex) ?usize {
        const write = self.write_idx.load(.acquire);
        const read = self.read_idx.load(.acquire);
        
        // Check if buffer is full
        if (write - read >= self.size) return null;
        
        // Advance write index
        _ = self.write_idx.fetchAdd(1, .release);
        return @intCast(write % self.size);
    }
    
    pub fn acquireRead(self: *RingIndex) ?usize {
        const write = self.write_idx.load(.acquire);
        const read = self.read_idx.load(.acquire);
        
        // Check if buffer is empty
        if (read >= write) return null;
        
        return @intCast(read % self.size);
    }
    
    pub fn releaseRead(self: *RingIndex) void {
        _ = self.read_idx.fetchAdd(1, .release);
    }
    
    pub fn pendingCount(self: *const RingIndex) usize {
        const write = self.write_idx.load(.acquire);
        const read = self.read_idx.load(.acquire);
        return @intCast(write - read);
    }
};

// ============================================================================
// GPU Memory Pool
// ============================================================================

pub const GpuMemoryPool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    slots: []BufferSlot,
    ring: RingIndex,
    gpu_ctx: ?*context.GpuContext,
    
    // Statistics
    total_allocations: std.atomic.Value(u64),
    total_bytes_transferred: std.atomic.Value(u64),
    h2d_transfers: std.atomic.Value(u64),
    d2h_transfers: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator, config: PoolConfig, gpu_ctx: ?*context.GpuContext) !*GpuMemoryPool {
        const pool = try allocator.create(GpuMemoryPool);
        
        // Allocate slots
        const slots = try allocator.alloc(BufferSlot, config.num_slots);
        for (slots, 0..) |*slot, i| {
            slot.* = try BufferSlot.init(i, config.slot_size_bytes, allocator);
        }
        
        pool.* = .{
            .allocator = allocator,
            .config = config,
            .slots = slots,
            .ring = RingIndex.init(config.num_slots),
            .gpu_ctx = gpu_ctx,
            .total_allocations = std.atomic.Value(u64).init(0),
            .total_bytes_transferred = std.atomic.Value(u64).init(0),
            .h2d_transfers = std.atomic.Value(u64).init(0),
            .d2h_transfers = std.atomic.Value(u64).init(0),
        };
        
        log.info("GPU Memory Pool initialized:", .{});
        log.info("  Slots: {}", .{config.num_slots});
        log.info("  Slot size: {} MB", .{config.slot_size_bytes / (1024 * 1024)});
        log.info("  Total pool: {} MB", .{(config.num_slots * config.slot_size_bytes) / (1024 * 1024)});
        
        return pool;
    }
    
    pub fn deinit(self: *GpuMemoryPool) void {
        for (self.slots) |*slot| {
            slot.deinit(self.allocator);
        }
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
        log.info("GPU Memory Pool destroyed", .{});
    }
    
    /// Acquire a slot for CPU writing
    pub fn acquireWriteSlot(self: *GpuMemoryPool) ?*BufferSlot {
        const idx = self.ring.acquireWrite() orelse return null;
        const slot = &self.slots[idx];
        
        if (slot.state != .free) return null;
        
        _ = self.total_allocations.fetchAdd(1, .monotonic);
        return slot;
    }
    
    /// Get the next slot ready for GPU processing
    pub fn acquireReadSlot(self: *GpuMemoryPool) ?*BufferSlot {
        const idx = self.ring.acquireRead() orelse return null;
        const slot = &self.slots[idx];
        
        if (slot.state != .ready_for_transfer) return null;
        
        return slot;
    }
    
    /// Release a slot after GPU processing
    pub fn releaseSlot(self: *GpuMemoryPool, slot: *BufferSlot) void {
        slot.reset();
        self.ring.releaseRead();
    }
    
    /// Transfer data from CPU to GPU (H2D)
    pub fn transferToGpu(self: *GpuMemoryPool, slot: *BufferSlot) !void {
        if (slot.state != .ready_for_transfer) return error.InvalidSlotState;
        
        slot.state = .gpu_processing;
        
        // Actual GPU transfer would happen here
        if (self.gpu_ctx) |_| {
            // TODO: Implement actual Metal/CUDA transfer
            // For now, simulate with CPU copy
        }
        
        _ = self.h2d_transfers.fetchAdd(1, .monotonic);
        _ = self.total_bytes_transferred.fetchAdd(slot.data_size, .monotonic);
        
        log.debug("H2D transfer: slot={} size={} bytes", .{ slot.index, slot.data_size });
    }
    
    /// Transfer data from GPU to CPU (D2H)
    pub fn transferFromGpu(self: *GpuMemoryPool, slot: *BufferSlot) !void {
        if (slot.state != .gpu_complete) return error.InvalidSlotState;
        
        // Actual GPU transfer would happen here
        if (self.gpu_ctx) |_| {
            // TODO: Implement actual Metal/CUDA transfer
        }
        
        _ = self.d2h_transfers.fetchAdd(1, .monotonic);
        _ = self.total_bytes_transferred.fetchAdd(slot.data_size, .monotonic);
        
        log.debug("D2H transfer: slot={} size={} bytes", .{ slot.index, slot.data_size });
    }
    
    /// Get pool statistics
    pub fn getStats(self: *const GpuMemoryPool) PoolStats {
        return .{
            .total_allocations = self.total_allocations.load(.acquire),
            .total_bytes_transferred = self.total_bytes_transferred.load(.acquire),
            .h2d_transfers = self.h2d_transfers.load(.acquire),
            .d2h_transfers = self.d2h_transfers.load(.acquire),
            .pending_slots = self.ring.pendingCount(),
            .free_slots = self.config.num_slots - self.ring.pendingCount(),
        };
    }
};

pub const PoolStats = struct {
    total_allocations: u64,
    total_bytes_transferred: u64,
    h2d_transfers: u64,
    d2h_transfers: u64,
    pending_slots: usize,
    free_slots: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "BufferSlot lifecycle" {
    var slot = try BufferSlot.init(0, 1024, std.testing.allocator);
    defer slot.deinit(std.testing.allocator);
    
    try std.testing.expectEqual(BufferSlot.State.free, slot.state);
    
    const ptr = slot.getWritePtr();
    try std.testing.expect(ptr != null);
    try std.testing.expectEqual(BufferSlot.State.cpu_filling, slot.state);
    
    slot.commitWrite(10, 400);
    try std.testing.expectEqual(BufferSlot.State.ready_for_transfer, slot.state);
    try std.testing.expectEqual(@as(usize, 10), slot.element_count);
    
    slot.reset();
    try std.testing.expectEqual(BufferSlot.State.free, slot.state);
    try std.testing.expectEqual(@as(u64, 1), slot.generation);
}

test "RingIndex operations" {
    var ring = RingIndex.init(3);
    
    // Should be able to acquire 3 writes
    try std.testing.expect(ring.acquireWrite() != null);
    try std.testing.expect(ring.acquireWrite() != null);
    try std.testing.expect(ring.acquireWrite() != null);
    
    // Ring should be full
    try std.testing.expect(ring.acquireWrite() == null);
    
    // Release one read
    ring.releaseRead();
    
    // Now can write again
    try std.testing.expect(ring.acquireWrite() != null);
}

test "GpuMemoryPool init and deinit" {
    const pool = try GpuMemoryPool.init(std.testing.allocator, .{
        .num_slots = 2,
        .slot_size_bytes = 1024,
    }, null);
    defer pool.deinit();
    
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.total_allocations);
    try std.testing.expectEqual(@as(usize, 2), stats.free_slots);
}