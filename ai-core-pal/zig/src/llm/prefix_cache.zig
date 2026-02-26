// =============================================================================
// Cross-Service Prefix Cache — POSIX Shared Memory PagedAttention KV Cache
// =============================================================================
//
// Shares GPU-computed PagedAttention KV cache prefixes between the
// mesh-gateway and local-models services on the same node.
//
// Use case: Repetitive enterprise queries (e.g., "list clustering algorithms",
// "optimize kmeans") generate identical prompt prefixes.  By sharing the
// computed KV cache across services, we skip the prefill phase entirely,
// reducing TTFT (Time To First Token) by 40-60%.
//
// In K8s/Kyma: mount an emptyDir with `medium: Memory` and set
// MCPPAL_PREFIX_CACHE_SHM to a shared name (e.g., "/mcppal-prefix-cache").
//
// Layout in shared memory:
//   [Header:     64 bytes]
//   [Slot 0:     SlotHeader (64 bytes) + page_data (page_size_bytes)]
//   [Slot 1:     ...]
//   ...
//
// Lock-free via atomic generation counters (seqlock pattern).
// Writers bump generation to odd before write, even after write.
// Readers compare generation before/after to detect torn reads.
//
// PagedAttention integration:
//   Each slot stores the KV cache pages for a prompt prefix hash.
//   Pages are laid out as [num_layers × num_heads × head_dim × 2 (K+V)] blocks.
//   The serving engine checks this cache before running prefill.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PrefixCache = struct {
    const MAGIC: u32 = 0x4D435050; // "MCPP"
    const VERSION: u32 = 1;
    const HEADER_SIZE: usize = 64;
    const SLOT_HEADER_SIZE: usize = 64;

    // =========================================================================
    // Shared Memory Structures (must match between services)
    // =========================================================================

    const ShmHeader = extern struct {
        magic: u32,
        version: u32,
        num_slots: u32,
        page_size_bytes: u32,  // Max KV page data per slot
        slot_stride: u32,      // SLOT_HEADER_SIZE + page_size_bytes
        _reserved: u32,
        total_puts: u64,
        total_hits: u64,
        total_misses: u64,
        evictions: u64,
        _pad: [8]u8,
    };

    const SlotHeader = extern struct {
        prefix_hash: u64,          // Wyhash of prompt prefix tokens
        generation: u64,           // Seqlock generation (odd = write in progress)
        num_tokens: u32,           // Number of prefix tokens cached
        num_pages: u32,            // Number of PagedAttention pages stored
        kv_data_len: u32,          // Actual bytes used in page_data region
        num_layers: u16,           // Model layers (e.g., 32 for Phi-2)
        num_heads: u16,            // KV heads per layer
        head_dim: u16,             // Dimension per head (e.g., 128)
        _reserved: u16,
        created_at: i64,           // Unix timestamp (seconds)
        last_access: i64,          // Last read timestamp
        access_count: u32,
        writer_service_id: u32,    // 0 = gateway, 1 = local-models
    };

    // =========================================================================
    // Instance State
    // =========================================================================

    shm_ptr: [*]align(std.mem.page_size) u8,
    shm_len: usize,
    num_slots: u32,
    page_size_bytes: u32,
    slot_stride: u32,
    shm_fd: std.posix.fd_t,
    allocator: Allocator,
    service_id: u32,

    const Self = @This();

    /// Open or create the shared prefix cache.
    /// `name` must start with "/" (e.g., "/mcppal-prefix-cache").
    /// `page_size_bytes` is the max KV cache data per slot.
    /// `service_id`: 0 = mesh-gateway, 1 = local-models.
    pub fn init(
        allocator: Allocator,
        name: []const u8,
        num_slots: u32,
        page_size_bytes: u32,
        service_id: u32,
    ) !Self {
        const slot_stride: u32 = SLOT_HEADER_SIZE + page_size_bytes;
        const total_size = HEADER_SIZE + @as(usize, num_slots) * slot_stride;

        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);

        const fd = std.c.shm_open(
            name_z.ptr,
            @bitCast(@as(u32, std.c.O.CREAT | std.c.O.RDWR)),
            0o666,
        );
        if (fd < 0) return error.ShmOpenFailed;
        errdefer _ = std.c.close(fd);

        if (std.c.ftruncate(fd, @intCast(total_size)) < 0) return error.FtruncateFailed;

        const ptr = std.posix.mmap(
            null,
            total_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return error.MmapFailed;

        const hdr: *ShmHeader = @ptrCast(@alignCast(ptr.ptr));
        if (hdr.magic != MAGIC) {
            // First initialization — zero everything
            hdr.magic = MAGIC;
            hdr.version = VERSION;
            hdr.num_slots = num_slots;
            hdr.page_size_bytes = page_size_bytes;
            hdr.slot_stride = slot_stride;
            hdr._reserved = 0;
            hdr.total_puts = 0;
            hdr.total_hits = 0;
            hdr.total_misses = 0;
            hdr.evictions = 0;
            hdr._pad = std.mem.zeroes([8]u8);
            @memset(ptr[HEADER_SIZE..total_size], 0);
        }

        return Self{
            .shm_ptr = @ptrCast(ptr.ptr),
            .shm_len = total_size,
            .num_slots = num_slots,
            .page_size_bytes = page_size_bytes,
            .slot_stride = slot_stride,
            .shm_fd = fd,
            .allocator = allocator,
            .service_id = service_id,
        };
    }

    pub fn deinit(self: *Self) void {
        const slice: []align(std.mem.page_size) u8 = @alignCast(self.shm_ptr[0..self.shm_len]);
        std.posix.munmap(slice);
        _ = std.c.close(self.shm_fd);
    }

    fn header(self: *Self) *ShmHeader {
        return @ptrCast(@alignCast(self.shm_ptr));
    }

    fn slotBase(self: *Self, idx: u32) [*]u8 {
        return self.shm_ptr + HEADER_SIZE + @as(usize, idx) * self.slot_stride;
    }

    fn slotHdr(self: *Self, idx: u32) *SlotHeader {
        return @ptrCast(@alignCast(self.slotBase(idx)));
    }

    fn slotData(self: *Self, idx: u32) [*]u8 {
        return self.slotBase(idx) + SLOT_HEADER_SIZE;
    }

    // =========================================================================
    // Public API
    // =========================================================================

    /// Hash a prompt token sequence for cache lookup.
    pub fn hashPrefix(tokens: []const u32) u64 {
        const bytes: []const u8 = @as([*]const u8, @ptrCast(tokens.ptr))[0 .. tokens.len * @sizeOf(u32)];
        return std.hash.Wyhash.hash(0x4D435050, bytes);
    }

    /// Hash a prompt string (for text-based lookup).
    pub fn hashPrompt(prompt: []const u8) u64 {
        return std.hash.Wyhash.hash(0x4D435050, prompt);
    }

    /// Look up cached KV page data for a prefix hash.
    /// Returns true if found; copies data into `out_pages` and sets `out_meta`.
    pub fn get(self: *Self, prefix_hash: u64, out_pages: []u8, out_meta: *SlotMeta) bool {
        for (0..self.num_slots) |i| {
            const sh = self.slotHdr(@intCast(i));
            if (sh.prefix_hash != prefix_hash) continue;

            // Seqlock read
            const gen1 = @atomicLoad(u64, &sh.generation, .acquire);
            if (gen1 & 1 != 0) continue; // Write in progress

            const data_len = sh.kv_data_len;
            if (data_len > out_pages.len or data_len > self.page_size_bytes) continue;

            const src = self.slotData(@intCast(i));
            @memcpy(out_pages[0..data_len], src[0..data_len]);

            out_meta.* = .{
                .num_tokens = sh.num_tokens,
                .num_pages = sh.num_pages,
                .kv_data_len = data_len,
                .num_layers = sh.num_layers,
                .num_heads = sh.num_heads,
                .head_dim = sh.head_dim,
                .writer_service_id = sh.writer_service_id,
            };

            const gen2 = @atomicLoad(u64, &sh.generation, .acquire);
            if (gen1 != gen2) continue; // Torn read — skip

            // Update access metadata (best-effort, not seqlocked)
            sh.last_access = std.time.timestamp();
            sh.access_count += 1;
            _ = @atomicRmw(u64, &self.header().total_hits, .Add, 1, .monotonic);

            return true;
        }
        _ = @atomicRmw(u64, &self.header().total_misses, .Add, 1, .monotonic);
        return false;
    }

    /// Store KV page data for a prefix hash.
    pub fn put(
        self: *Self,
        prefix_hash: u64,
        kv_data: []const u8,
        num_tokens: u32,
        num_pages: u32,
        num_layers: u16,
        num_heads: u16,
        head_dim: u16,
    ) void {
        if (kv_data.len > self.page_size_bytes) return;

        // Find existing slot or evict least-accessed
        var target: u32 = 0;
        var min_access: u32 = std.math.maxInt(u32);

        for (0..self.num_slots) |i| {
            const sh = self.slotHdr(@intCast(i));

            if (sh.prefix_hash == prefix_hash) {
                target = @intCast(i);
                break;
            }

            // Empty slot
            if (sh.prefix_hash == 0) {
                target = @intCast(i);
                min_access = 0;
                continue;
            }

            // LRU-ish eviction: least access_count
            if (sh.access_count < min_access) {
                min_access = sh.access_count;
                target = @intCast(i);
            }
        }

        const sh = self.slotHdr(target);
        const was_occupied = sh.prefix_hash != 0 and sh.prefix_hash != prefix_hash;

        // Seqlock write: bump to odd
        const old_gen = @atomicLoad(u64, &sh.generation, .acquire);
        @atomicStore(u64, &sh.generation, old_gen | 1, .release);

        sh.prefix_hash = prefix_hash;
        sh.num_tokens = num_tokens;
        sh.num_pages = num_pages;
        sh.kv_data_len = @intCast(kv_data.len);
        sh.num_layers = num_layers;
        sh.num_heads = num_heads;
        sh.head_dim = head_dim;
        sh.created_at = std.time.timestamp();
        sh.last_access = sh.created_at;
        sh.access_count = 1;
        sh.writer_service_id = self.service_id;

        const dst = self.slotData(target);
        @memcpy(dst[0..kv_data.len], kv_data);

        // Bump to next even
        @atomicStore(u64, &sh.generation, (old_gen + 2) & ~@as(u64, 1), .release);
        _ = @atomicRmw(u64, &self.header().total_puts, .Add, 1, .monotonic);

        if (was_occupied) {
            _ = @atomicRmw(u64, &self.header().evictions, .Add, 1, .monotonic);
        }
    }

    /// Invalidate a specific prefix hash.
    pub fn invalidate(self: *Self, prefix_hash: u64) bool {
        for (0..self.num_slots) |i| {
            const sh = self.slotHdr(@intCast(i));
            if (sh.prefix_hash == prefix_hash) {
                const old_gen = @atomicLoad(u64, &sh.generation, .acquire);
                @atomicStore(u64, &sh.generation, old_gen | 1, .release);
                sh.prefix_hash = 0;
                sh.kv_data_len = 0;
                @atomicStore(u64, &sh.generation, (old_gen + 2) & ~@as(u64, 1), .release);
                return true;
            }
        }
        return false;
    }

    /// Get cache statistics as a JSON-formatted string.
    pub fn statsJson(self: *Self, allocator: Allocator) ![]u8 {
        const hdr = self.header();
        var occupied: u32 = 0;
        var total_kv_bytes: u64 = 0;
        var gateway_entries: u32 = 0;
        var models_entries: u32 = 0;

        for (0..self.num_slots) |i| {
            const sh = self.slotHdr(@intCast(i));
            if (sh.prefix_hash != 0) {
                occupied += 1;
                total_kv_bytes += sh.kv_data_len;
                if (sh.writer_service_id == 0) gateway_entries += 1;
                if (sh.writer_service_id == 1) models_entries += 1;
            }
        }

        const total_ops = hdr.total_hits + hdr.total_misses;
        const hit_rate: f32 = if (total_ops > 0)
            @as(f32, @floatFromInt(hdr.total_hits)) / @as(f32, @floatFromInt(total_ops))
        else
            0;

        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "prefix_cache": {{
            \\    "total_puts": {d},
            \\    "total_hits": {d},
            \\    "total_misses": {d},
            \\    "evictions": {d},
            \\    "hit_rate": {d:.3},
            \\    "occupied_slots": {d},
            \\    "total_slots": {d},
            \\    "total_kv_bytes": {d},
            \\    "by_service": {{
            \\      "gateway_entries": {d},
            \\      "models_entries": {d}
            \\    }}
            \\  }}
            \\}}
        , .{
            hdr.total_puts,
            hdr.total_hits,
            hdr.total_misses,
            hdr.evictions,
            hit_rate,
            occupied,
            self.num_slots,
            total_kv_bytes,
            gateway_entries,
            models_entries,
        });
    }

    /// Default shm name from env or fallback.
    pub fn defaultShmName() []const u8 {
        return std.posix.getenv("MCPPAL_PREFIX_CACHE_SHM") orelse "/mcppal-prefix-cache";
    }
};

/// Metadata returned from a cache hit (excludes the actual page data).
pub const SlotMeta = struct {
    num_tokens: u32 = 0,
    num_pages: u32 = 0,
    kv_data_len: u32 = 0,
    num_layers: u16 = 0,
    num_heads: u16 = 0,
    head_dim: u16 = 0,
    writer_service_id: u32 = 0,
};

// =============================================================================
// Tests
// =============================================================================

test "PrefixCache hashPrompt deterministic" {
    const h1 = PrefixCache.hashPrompt("list clustering algorithms");
    const h2 = PrefixCache.hashPrompt("list clustering algorithms");
    const h3 = PrefixCache.hashPrompt("optimize kmeans on SALES_DATA");

    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "PrefixCache hashPrefix deterministic" {
    const tokens1 = [_]u32{ 1, 2, 3, 4, 5 };
    const tokens2 = [_]u32{ 1, 2, 3, 4, 5 };
    const tokens3 = [_]u32{ 5, 4, 3, 2, 1 };

    try std.testing.expectEqual(
        PrefixCache.hashPrefix(&tokens1),
        PrefixCache.hashPrefix(&tokens2),
    );
    try std.testing.expect(
        PrefixCache.hashPrefix(&tokens1) != PrefixCache.hashPrefix(&tokens3),
    );
}
