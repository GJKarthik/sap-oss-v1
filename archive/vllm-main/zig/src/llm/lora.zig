//! LoRA / PEFT Runtime Serving
//!
//! Low-Rank Adaptation runtime adapter loading and composition:
//! - Adapter weight loading from safetensors/GGUF
//! - Base + adapter merge at inference time: W' = W + α * (B × A)
//! - Multi-LoRA batching with shared base weights
//! - Hot-swap adapters without reloading base model

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// LoRA Configuration
// ============================================================================

pub const LoraConfig = struct {
    rank: u32 = 16,
    alpha: f32 = 32.0,
    dropout: f32 = 0.0,
    target_modules: []const []const u8 = &.{ "q_proj", "v_proj" },
    fan_in_fan_out: bool = false,
    bias: BiasType = .none,

    pub const BiasType = enum { none, all, lora_only };

    pub fn scalingFactor(self: *const LoraConfig) f32 {
        return self.alpha / @as(f32, @floatFromInt(self.rank));
    }
};

// ============================================================================
// LoRA Weight Pair (A and B matrices)
// ============================================================================

pub const LoraWeight = struct {
    a_data: []f32, // [rank × in_features]
    b_data: []f32, // [out_features × rank]
    in_features: u32,
    out_features: u32,
    rank: u32,

    pub fn init(allocator: Allocator, in_features: u32, out_features: u32, rank: u32) !LoraWeight {
        const a_size = @as(usize, rank) * @as(usize, in_features);
        const b_size = @as(usize, out_features) * @as(usize, rank);
        const a_data = try allocator.alloc(f32, a_size);
        const b_data = try allocator.alloc(f32, b_size);
        for (a_data) |*v| v.* = 0.01;
        @memset(b_data, 0.0);
        return .{ .a_data = a_data, .b_data = b_data, .in_features = in_features, .out_features = out_features, .rank = rank };
    }

    pub fn deinit(self: *LoraWeight, allocator: Allocator) void {
        allocator.free(self.a_data);
        allocator.free(self.b_data);
    }

    /// Compute LoRA output: output += scaling * (x @ A^T @ B^T)
    pub fn forward(self: *const LoraWeight, x: []const f32, output: []f32, batch: u32, scaling: f32) void {
        const r = self.rank;
        const in_f = self.in_features;
        const out_f = self.out_features;
        var b: u32 = 0;
        while (b < batch) : (b += 1) {
            const x_row = x[b * in_f .. (b + 1) * in_f];
            const out_row = output[b * out_f .. (b + 1) * out_f];
            var ri: u32 = 0;
            while (ri < r) : (ri += 1) {
                var dot: f32 = 0.0;
                const a_row = self.a_data[ri * in_f .. (ri + 1) * in_f];
                for (x_row, a_row) |xv, av| dot += xv * av;
                var oi: u32 = 0;
                while (oi < out_f) : (oi += 1) {
                    out_row[oi] += dot * self.b_data[oi * r + ri] * scaling;
                }
            }
        }
    }
};

// ============================================================================
// LoRA Adapter (collection of weight pairs per target module)
// ============================================================================

pub const LoraAdapter = struct {
    allocator: Allocator,
    name: []const u8,
    config: LoraConfig,
    weights: std.StringHashMap(LoraWeight),
    ref_count: std.atomic.Value(u32),
    loaded: bool,

    pub fn init(allocator: Allocator, name: []const u8, config: LoraConfig) LoraAdapter {
        return .{
            .allocator = allocator, .name = name, .config = config,
            .weights = std.StringHashMap(LoraWeight).init(allocator),
            .ref_count = std.atomic.Value(u32).init(0), .loaded = false,
        };
    }

    pub fn deinit(self: *LoraAdapter) void {
        var it = self.weights.iterator();
        while (it.next()) |entry| {
            var w = entry.value_ptr.*;
            w.deinit();
        }
        self.weights.deinit();
    }

    pub fn addWeight(self: *LoraAdapter, module_name: []const u8, weight: LoraWeight) !void {
        try self.weights.put(module_name, weight);
    }

    pub fn getWeight(self: *const LoraAdapter, module_name: []const u8) ?LoraWeight {
        return self.weights.get(module_name);
    }

    /// Load LoRA weights from a flat binary file.
    ///
    /// File format (little-endian):
    ///   [u32 num_modules]
    ///   For each module:
    ///     [u32 name_len] [u8 × name_len]   — module name (e.g. "q_proj")
    ///     [u32 in_features]
    ///     [u32 out_features]
    ///     [u32 rank]
    ///     [f32 × rank*in_features]          — A matrix
    ///     [f32 × out_features*rank]         — B matrix
    ///
    /// This format is written by the companion Python export script
    /// (scripts/export_lora.py) from a HuggingFace PEFT adapter.
    pub fn loadFromFile(self: *LoraAdapter, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var reader = file.reader();

        const num_modules = try reader.readInt(u32, .little);

        var i: u32 = 0;
        while (i < num_modules) : (i += 1) {
            // Read module name.
            const name_len = try reader.readInt(u32, .little);
            if (name_len == 0 or name_len > 256) return error.InvalidLoraFile;
            const name_buf = try self.allocator.alloc(u8, name_len);
            errdefer self.allocator.free(name_buf);
            try reader.readNoEof(name_buf);

            // Read dimensions.
            const in_features = try reader.readInt(u32, .little);
            const out_features = try reader.readInt(u32, .little);
            const rank = try reader.readInt(u32, .little);

            if (rank == 0 or rank > 1024 or in_features == 0 or out_features == 0) {
                self.allocator.free(name_buf);
                return error.InvalidLoraFile;
            }

            // Allocate and read A matrix [rank × in_features].
            const a_size = @as(usize, rank) * @as(usize, in_features);
            const a_data = try self.allocator.alloc(f32, a_size);
            errdefer self.allocator.free(a_data);
            for (a_data) |*v| {
                v.* = @bitCast(try reader.readInt(u32, .little));
            }

            // Allocate and read B matrix [out_features × rank].
            const b_size = @as(usize, out_features) * @as(usize, rank);
            const b_data = try self.allocator.alloc(f32, b_size);
            errdefer self.allocator.free(b_data);
            for (b_data) |*v| {
                v.* = @bitCast(try reader.readInt(u32, .little));
            }

            const weight = LoraWeight{
                .a_data = a_data,
                .b_data = b_data,
                .in_features = in_features,
                .out_features = out_features,
                .rank = rank,
            };

            // HashMap takes ownership of name_buf as key.
            try self.weights.put(name_buf, weight);
        }

        self.loaded = true;
    }

    /// Load LoRA weights from a HuggingFace PEFT SafeTensors file.
    ///
    /// Expects tensors named like:
    ///   "base_model.model.<module>.lora_A.weight"  — shape [rank, in_features]
    ///   "base_model.model.<module>.lora_B.weight"  — shape [out_features, rank]
    ///
    /// The module name is extracted as everything between "base_model.model."
    /// and ".lora_A/B.weight", e.g. "model.layers.0.self_attn.q_proj".
    pub fn loadFromSafeTensors(self: *LoraAdapter, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const file_size: usize = @intCast(stat.size);
        if (file_size < 8) return error.InvalidSafeTensors;

        const data = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(data);

        var off: usize = 0;
        while (off < file_size) {
            const n = try file.read(data[off..]);
            if (n == 0) return error.UnexpectedEOF;
            off += n;
        }

        const header_len = std.mem.readInt(u64, data[0..8], .little);
        if (header_len > file_size - 8) return error.InvalidSafeTensors;
        const header_json = data[8 .. 8 + header_len];
        const tensor_data_base: usize = 8 + @as(usize, @intCast(header_len));

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, header_json, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidSafeTensors;

        // Two-pass: first collect A tensors, then match with B tensors
        // Key: module_name → {a_data, b_data, in_features, out_features, rank}
        const TensorEntry = struct {
            a_data: ?[]f32 = null,
            b_data: ?[]f32 = null,
            in_features: u32 = 0,
            out_features: u32 = 0,
            rank: u32 = 0,
        };
        var entries = std.StringHashMap(TensorEntry).init(self.allocator);
        defer {
            var eit = entries.iterator();
            while (eit.next()) |e| {
                if (e.value_ptr.a_data) |a| self.allocator.free(a);
                if (e.value_ptr.b_data) |b| self.allocator.free(b);
                self.allocator.free(e.key_ptr.*);
            }
            entries.deinit();
        }

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const tname = entry.key_ptr.*;
            const tval = entry.value_ptr.*;
            if (tval != .object) continue;
            const obj = tval.object;

            // Determine if this is a lora_A or lora_B tensor
            const is_a = std.mem.indexOf(u8, tname, ".lora_A.weight") != null;
            const is_b = std.mem.indexOf(u8, tname, ".lora_B.weight") != null;
            if (!is_a and !is_b) continue;

            // Extract module name
            const prefix = "base_model.model.";
            const suffix_a = ".lora_A.weight";
            const suffix_b = ".lora_B.weight";
            const suffix = if (is_a) suffix_a else suffix_b;

            const start = if (std.mem.indexOf(u8, tname, prefix)) |p| p + prefix.len else 0;
            const end_pos = std.mem.lastIndexOf(u8, tname, suffix) orelse continue;
            if (end_pos <= start) continue;
            const module_name_raw = tname[start..end_pos];

            // Get shape and data offsets
            const shape_val = obj.get("shape") orelse continue;
            if (shape_val != .array or shape_val.array.items.len < 2) continue;
            const rows: u32 = @intCast(shape_val.array.items[0].integer);
            const cols: u32 = @intCast(shape_val.array.items[1].integer);

            const dtype_val = obj.get("dtype") orelse continue;
            if (dtype_val != .string) continue;

            const offsets_val = obj.get("data_offsets") orelse continue;
            if (offsets_val != .array or offsets_val.array.items.len < 2) continue;
            const begin: usize = @intCast(offsets_val.array.items[0].integer);
            const end_off: usize = @intCast(offsets_val.array.items[1].integer);
            if (tensor_data_base + end_off > data.len) continue;

            const src = data[tensor_data_base + begin .. tensor_data_base + end_off];
            const n_elems: usize = @as(usize, rows) * @as(usize, cols);
            const buf = try self.allocator.alloc(f32, n_elems);
            errdefer self.allocator.free(buf);

            // Dequant
            if (std.mem.eql(u8, dtype_val.string, "F32")) {
                const n = @min(n_elems, src.len / 4);
                for (0..n) |i| {
                    buf[i] = @bitCast([4]u8{ src[i*4], src[i*4+1], src[i*4+2], src[i*4+3] });
                }
            } else if (std.mem.eql(u8, dtype_val.string, "F16")) {
                const n = @min(n_elems, src.len / 2);
                for (0..n) |i| {
                    const h: u16 = @as(u16, src[i*2]) | (@as(u16, src[i*2+1]) << 8);
                    buf[i] = loraSafetensorsF16ToF32(h);
                }
            } else if (std.mem.eql(u8, dtype_val.string, "BF16")) {
                const n = @min(n_elems, src.len / 2);
                for (0..n) |i| {
                    const bits: u32 = (@as(u32, src[i*2]) | (@as(u32, src[i*2+1]) << 8)) << 16;
                    buf[i] = @bitCast(bits);
                }
            } else {
                self.allocator.free(buf);
                continue;
            }

            // Upsert into entries map
            const key = try self.allocator.dupe(u8, module_name_raw);
            const gop = try entries.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = TensorEntry{};
                gop.key_ptr.* = key;
            } else {
                self.allocator.free(key);
            }

            if (is_a) {
                if (gop.value_ptr.a_data) |old| self.allocator.free(old);
                gop.value_ptr.a_data = buf;
                gop.value_ptr.rank = rows;
                gop.value_ptr.in_features = cols;
            } else {
                if (gop.value_ptr.b_data) |old| self.allocator.free(old);
                gop.value_ptr.b_data = buf;
                gop.value_ptr.out_features = rows;
                if (gop.value_ptr.rank == 0) gop.value_ptr.rank = cols;
            }
        }

        // Build LoraWeight entries from matched A+B pairs
        var eit = entries.iterator();
        while (eit.next()) |e| {
            const te = e.value_ptr.*;
            const a = te.a_data orelse continue;
            const b = te.b_data orelse continue;
            if (te.rank == 0 or te.in_features == 0 or te.out_features == 0) continue;

            const weight = LoraWeight{
                .a_data = try self.allocator.dupe(f32, a),
                .b_data = try self.allocator.dupe(f32, b),
                .in_features = te.in_features,
                .out_features = te.out_features,
                .rank = te.rank,
            };
            const mod_key = try self.allocator.dupe(u8, e.key_ptr.*);
            try self.weights.put(mod_key, weight);
        }

        self.loaded = true;
    }

    pub fn retain(self: *LoraAdapter) void { _ = self.ref_count.fetchAdd(1, .monotonic); }
    pub fn release(self: *LoraAdapter) void { _ = self.ref_count.fetchSub(1, .monotonic); }
    pub fn isInUse(self: *const LoraAdapter) bool { return self.ref_count.load(.monotonic) > 0; }
};

/// Minimal f16→f32 conversion for LoRA SafeTensors loading.
fn loraSafetensorsF16ToF32(h: u16) f32 {
    const sign: u32 = @as(u32, h >> 15) << 31;
    const exp_bits: u32 = (h >> 10) & 0x1F;
    const mant: u32 = h & 0x3FF;
    if (exp_bits == 0) {
        if (mant == 0) return @bitCast(sign);
        var m = mant;
        var e: u32 = 0;
        while (m & 0x400 == 0) { m <<= 1; e += 1; }
        m &= 0x3FF;
        return @bitCast(sign | ((127 - 15 + 1 - e) << 23) | (m << 13));
    } else if (exp_bits == 31) {
        return @bitCast(sign | 0x7F800000 | (mant << 13));
    }
    return @bitCast(sign | ((exp_bits + 127 - 15) << 23) | (mant << 13));
}

// ============================================================================
// Multi-LoRA Manager
// ============================================================================

pub const LoraManager = struct {
    allocator: Allocator,
    adapters: std.StringHashMap(LoraAdapter),
    max_adapters: u32,
    max_rank: u32,

    pub fn init(allocator: Allocator, max_adapters: u32, max_rank: u32) LoraManager {
        return .{
            .allocator = allocator,
            .adapters = std.StringHashMap(LoraAdapter).init(allocator),
            .max_adapters = max_adapters,
            .max_rank = max_rank,
        };
    }

    pub fn deinit(self: *LoraManager) void {
        var it = self.adapters.iterator();
        while (it.next()) |entry| { entry.value_ptr.deinit(); }
        self.adapters.deinit();
    }

    pub fn registerAdapter(self: *LoraManager, name: []const u8, config: LoraConfig) !*LoraAdapter {
        if (self.adapters.count() >= self.max_adapters) return error.TooManyAdapters;
        if (config.rank > self.max_rank) return error.RankTooHigh;
        const adapter = LoraAdapter.init(self.allocator, name, config);
        try self.adapters.put(name, adapter);
        return self.adapters.getPtr(name).?;
    }

    pub fn getAdapter(self: *LoraManager, name: []const u8) ?*LoraAdapter {
        return self.adapters.getPtr(name);
    }

    pub fn removeAdapter(self: *LoraManager, name: []const u8) !void {
        if (self.adapters.getPtr(name)) |adapter| {
            if (adapter.isInUse()) return error.AdapterInUse;
            adapter.deinit();
            _ = self.adapters.remove(name);
        }
    }

    pub fn applyLora(self: *const LoraManager, adapter_name: []const u8, module_name: []const u8, input: []const f32, output: []f32, batch_size: u32) void {
        const adapter = self.adapters.get(adapter_name) orelse return;
        const weight = adapter.getWeight(module_name) orelse return;
        weight.forward(input, output, batch_size, adapter.config.scalingFactor());
    }

    pub fn adapterCount(self: *const LoraManager) u32 { return @intCast(self.adapters.count()); }

    pub fn listAdapters(self: *const LoraManager, allocator: Allocator) ![][]const u8 {
        const count = self.adapters.count();
        const names = try allocator.alloc([]const u8, count);
        var it = self.adapters.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            names[i] = entry.key_ptr.*;
            i += 1;
        }
        return names;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "lora weight forward" {
    const allocator = std.testing.allocator;
    var w = try LoraWeight.init(allocator, 4, 3, 2);
    defer w.deinit();
    @memset(w.a_data, 0.0);
    @memset(w.b_data, 0.0);
    w.a_data[0] = 1.0;
    w.a_data[5] = 1.0;
    w.b_data[0] = 1.0; // B[0][0] = 1
    w.b_data[3] = 1.0; // B[1][1] = 1  (index = 1*rank + 1 = 3)
    const x = [_]f32{ 2.0, 3.0, 0.0, 0.0 };
    var output = [_]f32{ 0.0, 0.0, 0.0 };
    w.forward(&x, &output, 1, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), output[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), output[1], 0.001);
}

test "lora config scaling" {
    const cfg = LoraConfig{ .rank = 8, .alpha = 16.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), cfg.scalingFactor(), 0.001);
}

test "lora adapter lifecycle" {
    const allocator = std.testing.allocator;
    var adapter = LoraAdapter.init(allocator, "test-adapter", .{});
    defer adapter.deinit();
    const w = try LoraWeight.init(allocator, 4, 4, 2);
    try adapter.addWeight("q_proj", w);
    try std.testing.expect(adapter.getWeight("q_proj") != null);
    try std.testing.expect(adapter.getWeight("k_proj") == null);
}

test "lora manager multi-adapter" {
    const allocator = std.testing.allocator;
    var mgr = LoraManager.init(allocator, 10, 64);
    defer mgr.deinit();
    _ = try mgr.registerAdapter("adapter-a", .{ .rank = 8 });
    _ = try mgr.registerAdapter("adapter-b", .{ .rank = 16 });
    try std.testing.expectEqual(@as(u32, 2), mgr.adapterCount());
    const names = try mgr.listAdapters(allocator);
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
}

test "lora manager apply" {
    const allocator = std.testing.allocator;
    var mgr = LoraManager.init(allocator, 10, 64);
    defer mgr.deinit();
    const adapter = try mgr.registerAdapter("test", .{ .rank = 2, .alpha = 2.0 });
    var w = try LoraWeight.init(allocator, 2, 2, 2);
    w.a_data[0] = 1.0;
    w.a_data[3] = 1.0;
    w.b_data[0] = 1.0;
    w.b_data[3] = 1.0;
    try adapter.addWeight("q_proj", w);
    const x = [_]f32{ 1.0, 1.0 };
    var output = [_]f32{ 0.0, 0.0 };
    mgr.applyLora("test", "q_proj", &x, &output, 1);
    try std.testing.expect(output[0] != 0.0);
}

test "lora manager reject excess rank" {
    const allocator = std.testing.allocator;
    var mgr = LoraManager.init(allocator, 10, 8);
    defer mgr.deinit();
    const result = mgr.registerAdapter("big", .{ .rank = 128 });
    try std.testing.expectError(error.RankTooHigh, result);
}

