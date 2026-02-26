//! SafeTensors Weight Loader
//! Loads model weights from .safetensors files
//! Compatible with HuggingFace models (Llama, Mistral, BERT, etc.)

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.safetensors);

// ============================================================================
// SafeTensors Format
// ============================================================================

/// SafeTensors file structure:
/// - 8 bytes: header size (little-endian u64)
/// - N bytes: JSON header (tensor metadata)
/// - remaining: raw tensor data

pub const DType = enum {
    F16,
    BF16,
    F32,
    F64,
    I8,
    I16,
    I32,
    I64,
    U8,
    U16,
    U32,
    U64,
    BOOL,
    
    pub fn fromString(s: []const u8) ?DType {
        const map = std.StaticStringMap(DType).initComptime(.{
            .{ "F16", .F16 },
            .{ "BF16", .BF16 },
            .{ "F32", .F32 },
            .{ "F64", .F64 },
            .{ "I8", .I8 },
            .{ "I16", .I16 },
            .{ "I32", .I32 },
            .{ "I64", .I64 },
            .{ "U8", .U8 },
            .{ "U16", .U16 },
            .{ "U32", .U32 },
            .{ "U64", .U64 },
            .{ "BOOL", .BOOL },
        });
        return map.get(s);
    }
    
    pub fn byteSize(self: DType) usize {
        return switch (self) {
            .F16, .BF16, .I16, .U16 => 2,
            .F32, .I32, .U32 => 4,
            .F64, .I64, .U64 => 8,
            .I8, .U8, .BOOL => 1,
        };
    }
};

pub const TensorInfo = struct {
    name: []const u8,
    dtype: DType,
    shape: []const usize,
    data_offsets: [2]usize, // [start, end] in the data section
    
    pub fn numElements(self: *const TensorInfo) usize {
        var n: usize = 1;
        for (self.shape) |dim| {
            n *= dim;
        }
        return n;
    }
    
    pub fn byteSize(self: *const TensorInfo) usize {
        return self.numElements() * self.dtype.byteSize();
    }
};

// ============================================================================
// SafeTensors Loader
// ============================================================================

pub const SafeTensorsLoader = struct {
    allocator: Allocator,
    
    // Loaded file data
    file_data: ?[]align(8) u8,
    header_size: usize,
    
    // Parsed tensor metadata
    tensors: std.StringHashMap(TensorInfo),
    tensor_names: std.ArrayListUnmanaged([]const u8),
    
    // Metadata
    total_parameters: u64,
    total_bytes: u64,
    
    pub fn init(allocator: Allocator) !*SafeTensorsLoader {
        const loader = try allocator.create(SafeTensorsLoader);
        loader.* = .{
            .allocator = allocator,
            .file_data = null,
            .header_size = 0,
            .tensors = std.StringHashMap(TensorInfo).init(allocator),
            .tensor_names = .{},
            .total_parameters = 0,
            .total_bytes = 0,
        };
        return loader;
    }
    
    pub fn deinit(self: *SafeTensorsLoader) void {
        // Free tensor info strings
        var it = self.tensors.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.shape);
        }
        self.tensors.deinit();
        
        for (self.tensor_names.items) |name| {
            self.allocator.free(name);
        }
        self.tensor_names.deinit(self.allocator);
        
        if (self.file_data) |data| {
            self.allocator.free(data);
        }
        
        self.allocator.destroy(self);
    }
    
    /// Load a SafeTensors file
    pub fn loadFile(self: *SafeTensorsLoader, path: []const u8) !void {
        log.info("Loading SafeTensors file: {s}", .{path});
        
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        // Get file size
        const file_size = try file.getEndPos();
        if (file_size < 8) {
            return error.InvalidSafeTensorsFile;
        }
        
        // Read entire file (memory-mapped would be more efficient for large files)
        const data = try self.allocator.alignedAlloc(u8, 8, file_size);
        errdefer self.allocator.free(data);
        
        const bytes_read = try file.readAll(data);
        if (bytes_read != file_size) {
            return error.IncompleteRead;
        }
        
        // Parse header size (first 8 bytes, little-endian)
        self.header_size = std.mem.readInt(u64, data[0..8], .little);
        
        if (self.header_size > file_size - 8) {
            return error.InvalidHeaderSize;
        }
        
        // Parse JSON header
        const header_json = data[8 .. 8 + self.header_size];
        try self.parseHeader(header_json);
        
        // Store file data for tensor access
        if (self.file_data) |old_data| {
            self.allocator.free(old_data);
        }
        self.file_data = data;
        
        log.info("Loaded {d} tensors, {d} parameters, {d:.2} MB", .{
            self.tensors.count(),
            self.total_parameters,
            @as(f64, @floatFromInt(self.total_bytes)) / (1024 * 1024),
        });
    }
    
    fn parseHeader(self: *SafeTensorsLoader, json_data: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_data, .{});
        defer parsed.deinit();
        
        const root = parsed.value.object;
        
        // Clear existing tensors
        var it = self.tensors.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.shape);
        }
        self.tensors.clearRetainingCapacity();
        
        for (self.tensor_names.items) |name| {
            self.allocator.free(name);
        }
        self.tensor_names.clearRetainingCapacity();
        
        self.total_parameters = 0;
        self.total_bytes = 0;
        
        // Parse each tensor entry
        var root_it = root.iterator();
        while (root_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            
            // Skip __metadata__ entry
            if (std.mem.eql(u8, name, "__metadata__")) {
                continue;
            }
            
            const tensor_obj = value.object;
            
            // Parse dtype
            const dtype_str = tensor_obj.get("dtype").?.string;
            const dtype = DType.fromString(dtype_str) orelse {
                log.warn("Unknown dtype: {s}", .{dtype_str});
                continue;
            };
            
            // Parse shape
            const shape_array = tensor_obj.get("shape").?.array;
            const shape = try self.allocator.alloc(usize, shape_array.items.len);
            for (shape_array.items, 0..) |dim, i| {
                shape[i] = @intCast(dim.integer);
            }
            
            // Parse data_offsets
            const offsets_array = tensor_obj.get("data_offsets").?.array;
            const start: usize = @intCast(offsets_array.items[0].integer);
            const end: usize = @intCast(offsets_array.items[1].integer);
            
            // Store tensor info
            const tensor_info = TensorInfo{
                .name = try self.allocator.dupe(u8, name),
                .dtype = dtype,
                .shape = shape,
                .data_offsets = .{ start, end },
            };
            
            const name_copy = try self.allocator.dupe(u8, name);
            try self.tensors.put(name_copy, tensor_info);
            
            const name_list_copy = try self.allocator.dupe(u8, name);
            try self.tensor_names.append(self.allocator, name_list_copy);
            
            // Update statistics
            self.total_parameters += tensor_info.numElements();
            self.total_bytes += tensor_info.byteSize();
        }
    }
    
    /// Get tensor metadata by name
    pub fn getTensorInfo(self: *const SafeTensorsLoader, name: []const u8) ?TensorInfo {
        return self.tensors.get(name);
    }
    
    /// Get raw tensor data by name
    pub fn getTensorData(self: *const SafeTensorsLoader, name: []const u8) ?[]const u8 {
        const info = self.tensors.get(name) orelse return null;
        const data = self.file_data orelse return null;
        
        const data_start = 8 + self.header_size;
        const start = data_start + info.data_offsets[0];
        const end = data_start + info.data_offsets[1];
        
        return data[start..end];
    }
    
    /// Get tensor data as f32 slice (converts if needed)
    pub fn getTensorF32(self: *SafeTensorsLoader, name: []const u8) !?[]f32 {
        const info = self.tensors.get(name) orelse return null;
        const raw_data = self.getTensorData(name) orelse return null;
        
        const num_elements = info.numElements();
        
        switch (info.dtype) {
            .F32 => {
                // Already f32, return as-is (reinterpret)
                const aligned: []align(4) const u8 = @alignCast(raw_data);
                return std.mem.bytesAsSlice(f32, aligned);
            },
            .F16 => {
                // Convert f16 to f32
                const result = try self.allocator.alloc(f32, num_elements);
                const f16_data = std.mem.bytesAsSlice(f16, raw_data);
                for (f16_data, 0..) |val, i| {
                    result[i] = @as(f32, val);
                }
                return result;
            },
            .BF16 => {
                // Convert bf16 to f32
                const result = try self.allocator.alloc(f32, num_elements);
                const bf16_data = std.mem.bytesAsSlice(u16, raw_data);
                for (bf16_data, 0..) |val, i| {
                    // BF16 is just f32 with lower 16 bits truncated
                    const f32_bits: u32 = @as(u32, val) << 16;
                    result[i] = @bitCast(f32_bits);
                }
                return result;
            },
            else => {
                log.warn("Unsupported dtype for f32 conversion: {}", .{info.dtype});
                return null;
            },
        }
    }
    
    /// List all tensor names
    pub fn listTensors(self: *const SafeTensorsLoader) []const []const u8 {
        return self.tensor_names.items;
    }
    
    /// Get total number of parameters
    pub fn getTotalParameters(self: *const SafeTensorsLoader) u64 {
        return self.total_parameters;
    }
    
    /// Get total size in bytes
    pub fn getTotalBytes(self: *const SafeTensorsLoader) u64 {
        return self.total_bytes;
    }
};

// ============================================================================
// Model Weight Manager
// ============================================================================

pub const WeightManager = struct {
    allocator: Allocator,
    loaders: std.StringHashMap(*SafeTensorsLoader),
    
    // Cached tensors (for GPU upload)
    tensor_cache: std.StringHashMap([]const u8),
    
    pub fn init(allocator: Allocator) !*WeightManager {
        const mgr = try allocator.create(WeightManager);
        mgr.* = .{
            .allocator = allocator,
            .loaders = std.StringHashMap(*SafeTensorsLoader).init(allocator),
            .tensor_cache = std.StringHashMap([]const u8).init(allocator),
        };
        return mgr;
    }
    
    pub fn deinit(self: *WeightManager) void {
        var it = self.loaders.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.loaders.deinit();
        
        self.tensor_cache.deinit();
        self.allocator.destroy(self);
    }
    
    /// Load a model from a directory containing .safetensors files
    pub fn loadModel(self: *WeightManager, model_path: []const u8) !void {
        log.info("Loading model from: {s}", .{model_path});
        
        // Check if it's a single file or directory
        const stat = std.fs.cwd().statFile(model_path) catch {
            return error.PathNotFound;
        };
        
        if (stat.kind == .file) {
            // Single file
            try self.loadSingleFile(model_path);
        } else if (stat.kind == .directory) {
            // Directory - load all .safetensors files
            try self.loadDirectory(model_path);
        }
    }
    
    fn loadSingleFile(self: *WeightManager, path: []const u8) !void {
        const loader = try SafeTensorsLoader.init(self.allocator);
        errdefer loader.deinit();
        
        try loader.loadFile(path);
        
        const path_copy = try self.allocator.dupe(u8, path);
        try self.loaders.put(path_copy, loader);
    }
    
    fn loadDirectory(self: *WeightManager, dir_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            
            // Check for .safetensors extension
            if (std.mem.endsWith(u8, entry.name, ".safetensors")) {
                // Build full path
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                
                try self.loadSingleFile(full_path);
            }
        }
    }
    
    /// Get tensor data from any loaded file
    pub fn getTensor(self: *const WeightManager, name: []const u8) ?[]const u8 {
        var it = self.loaders.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.getTensorData(name)) |data| {
                return data;
            }
        }
        return null;
    }
    
    /// Get tensor info from any loaded file
    pub fn getTensorInfo(self: *const WeightManager, name: []const u8) ?TensorInfo {
        var it = self.loaders.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.getTensorInfo(name)) |info| {
                return info;
            }
        }
        return null;
    }
    
    /// Get all tensor names across all files
    pub fn listAllTensors(self: *WeightManager) ![][]const u8 {
        var all_names: std.ArrayListUnmanaged([]const u8) = .{};
        defer all_names.deinit(self.allocator);
        
        var it = self.loaders.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*.listTensors()) |name| {
                try all_names.append(self.allocator, name);
            }
        }
        
        return try all_names.toOwnedSlice(self.allocator);
    }
    
    /// Get total parameters across all files
    pub fn getTotalParameters(self: *const WeightManager) u64 {
        var total: u64 = 0;
        var it = self.loaders.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.*.getTotalParameters();
        }
        return total;
    }
    
    /// Get total size across all files
    pub fn getTotalBytes(self: *const WeightManager) u64 {
        var total: u64 = 0;
        var it = self.loaders.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.*.getTotalBytes();
        }
        return total;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DType parsing" {
    try std.testing.expectEqual(DType.F32, DType.fromString("F32").?);
    try std.testing.expectEqual(DType.F16, DType.fromString("F16").?);
    try std.testing.expectEqual(DType.BF16, DType.fromString("BF16").?);
    try std.testing.expect(DType.fromString("INVALID") == null);
}

test "DType byte size" {
    try std.testing.expectEqual(@as(usize, 4), DType.F32.byteSize());
    try std.testing.expectEqual(@as(usize, 2), DType.F16.byteSize());
    try std.testing.expectEqual(@as(usize, 2), DType.BF16.byteSize());
    try std.testing.expectEqual(@as(usize, 1), DType.I8.byteSize());
}

test "SafeTensorsLoader init/deinit" {
    const allocator = std.testing.allocator;
    const loader = try SafeTensorsLoader.init(allocator);
    defer loader.deinit();
    
    try std.testing.expectEqual(@as(u64, 0), loader.getTotalParameters());
}

test "WeightManager init/deinit" {
    const allocator = std.testing.allocator;
    const mgr = try WeightManager.init(allocator);
    defer mgr.deinit();
    
    try std.testing.expectEqual(@as(u64, 0), mgr.getTotalParameters());
}

test "TensorInfo calculations" {
    const shape = [_]usize{ 4096, 4096 };
    const info = TensorInfo{
        .name = "test",
        .dtype = .F32,
        .shape = &shape,
        .data_offsets = .{ 0, 67108864 },
    };
    
    try std.testing.expectEqual(@as(usize, 16777216), info.numElements());
    try std.testing.expectEqual(@as(usize, 67108864), info.byteSize());
}