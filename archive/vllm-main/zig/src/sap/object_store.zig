//! SAP Object Store Connector — Resolve TOON Pointers to Object Storage
//!
//! Supports:
//!   - SAP Object Store: S3-compatible API via BTP
//!   - HANA Data Lake Files (HDL): Object storage integrated with HANA
//!
//! All operations use BTP Destinations for credential management.
//! Generates presigned URLs for direct access (zero-copy to GPU).

const std = @import("std");
const toon_pointer = @import("toon_pointer.zig");

/// Object Store configuration from BTP Destination
pub const ObjectStoreConfig = struct {
    endpoint: []const u8,
    region: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    bucket_prefix: ?[]const u8,
    
    /// Load from environment (BTP Object Store binding)
    pub fn fromEnv(allocator: std.mem.Allocator, destination_name: []const u8) !ObjectStoreConfig {
        _ = destination_name;
        
        return ObjectStoreConfig{
            .endpoint = std.posix.getenv("OBJECT_STORE_ENDPOINT") orelse 
                try allocator.dupe(u8, "s3.eu-central-1.amazonaws.com"),
            .region = std.posix.getenv("OBJECT_STORE_REGION") orelse
                try allocator.dupe(u8, "eu-central-1"),
            .access_key = std.posix.getenv("OBJECT_STORE_ACCESS_KEY") orelse
                try allocator.dupe(u8, ""),
            .secret_key = std.posix.getenv("OBJECT_STORE_SECRET_KEY") orelse
                try allocator.dupe(u8, ""),
            .bucket_prefix = std.posix.getenv("OBJECT_STORE_BUCKET_PREFIX"),
        };
    }
    
    /// Load HDL configuration
    pub fn forHdl(allocator: std.mem.Allocator) !ObjectStoreConfig {
        return ObjectStoreConfig{
            .endpoint = std.posix.getenv("HDL_ENDPOINT") orelse
                try allocator.dupe(u8, "files.hana.cloud.sap"),
            .region = std.posix.getenv("HDL_REGION") orelse
                try allocator.dupe(u8, "eu10"),
            .access_key = std.posix.getenv("HDL_ACCESS_KEY") orelse
                try allocator.dupe(u8, ""),
            .secret_key = std.posix.getenv("HDL_SECRET_KEY") orelse
                try allocator.dupe(u8, ""),
            .bucket_prefix = null,
        };
    }
};

/// Object Store Connector for pointer resolution
pub const ObjectStoreConnector = struct {
    allocator: std.mem.Allocator,
    config: ObjectStoreConfig,
    
    pub fn init(allocator: std.mem.Allocator, config: ObjectStoreConfig) ObjectStoreConnector {
        return ObjectStoreConnector{
            .allocator = allocator,
            .config = config,
        };
    }
    
    // ========================================================================
    // SAP Object Store Resolution (S3 API)
    // ========================================================================
    
    /// Resolve a SAP Object Store pointer to presigned URL
    pub fn resolveObject(self: *ObjectStoreConnector, ptr: *const toon_pointer.ToonPointer) !toon_pointer.PointerResolution {
        if (ptr.ptr_type != .sap_object) return error.WrongPointerType;
        
        // Parse location: bucket/key
        const slash_idx = std.mem.indexOf(u8, ptr.location, "/") orelse return error.InvalidLocation;
        const bucket = ptr.location[0..slash_idx];
        const key = ptr.location[slash_idx + 1 ..];
        
        // Generate presigned URL
        const url = try self.generatePresignedUrl(bucket, key, ptr.ttl_seconds);
        
        // Build schema hint based on format
        var schema_hint: ?[]const u8 = null;
        if (ptr.format != .auto) {
            schema_hint = try std.fmt.allocPrint(self.allocator, 
                \\{{"format":"{s}","columns":{s}}}
            , .{
                @tagName(ptr.format),
                if (ptr.columns) |cols| cols else "null",
            });
        }
        
        return toon_pointer.PointerResolution{
            .resolution_type = .presigned_url,
            .value = url,
            .schema_hint = schema_hint,
            .estimated_rows = null,
        };
    }
    
    // ========================================================================
    // HANA Data Lake Files Resolution
    // ========================================================================
    
    /// Resolve a HANA Data Lake pointer to presigned URL
    pub fn resolveHdl(self: *ObjectStoreConnector, ptr: *const toon_pointer.ToonPointer) !toon_pointer.PointerResolution {
        if (ptr.ptr_type != .hdl_file) return error.WrongPointerType;
        
        // Parse location: container/path
        const slash_idx = std.mem.indexOf(u8, ptr.location, "/") orelse return error.InvalidLocation;
        const container = ptr.location[0..slash_idx];
        const path = ptr.location[slash_idx + 1 ..];
        
        // Generate HDL presigned URL (uses HANA Data Lake API)
        const url = try self.generateHdlUrl(container, path, ptr.ttl_seconds);
        
        // Detect format from file extension
        const detected_format = detectFormatFromPath(path);
        
        return toon_pointer.PointerResolution{
            .resolution_type = .presigned_url,
            .value = url,
            .schema_hint = try std.fmt.allocPrint(self.allocator,
                \\{{"format":"{s}","container":"{s}","path":"{s}"}}
            , .{ @tagName(detected_format), container, path }),
            .estimated_rows = null,
        };
    }
    
    // ========================================================================
    // Universal Resolver
    // ========================================================================
    
    /// Resolve any object store pointer type
    pub fn resolve(self: *ObjectStoreConnector, ptr: *const toon_pointer.ToonPointer) !toon_pointer.PointerResolution {
        return switch (ptr.ptr_type) {
            .sap_object => self.resolveObject(ptr),
            .hdl_file => self.resolveHdl(ptr),
            else => error.UnsupportedPointerType,
        };
    }
    
    // ========================================================================
    // Presigned URL Generation (S3 Signature V4)
    // ========================================================================
    
    /// Generate S3 presigned URL for direct access using AWS Signature V4.
    fn generatePresignedUrl(self: *ObjectStoreConnector, bucket: []const u8, key: []const u8, expires_in: u32) ![]const u8 {
        const timestamp = std.time.timestamp();
        const date = timestampToDate(timestamp);
        
        const host = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ bucket, self.config.endpoint });
        defer self.allocator.free(host);
        
        const datetime = try std.fmt.allocPrint(self.allocator, "{s}T000000Z", .{date});
        defer self.allocator.free(datetime);
        
        const credential_scope = try std.fmt.allocPrint(self.allocator, "{s}/{s}/s3/aws4_request", .{ date, self.config.region });
        defer self.allocator.free(credential_scope);
        
        // Build canonical query string (parameters in alphabetical order)
        var cqs = std.ArrayList(u8){};
        defer cqs.deinit();
        const cqw = cqs.writer();
        try cqw.print("X-Amz-Algorithm=AWS4-HMAC-SHA256", .{});
        try cqw.print("&X-Amz-Credential={s}%2F{s}%2F{s}%2Fs3%2Faws4_request", .{
            self.config.access_key, date, self.config.region,
        });
        try cqw.print("&X-Amz-Date={s}", .{datetime});
        try cqw.print("&X-Amz-Expires={d}", .{expires_in});
        try cqw.print("&X-Amz-SignedHeaders=host", .{});
        const canonical_qs = cqs.items;
        
        // Build canonical request
        var creq = std.ArrayList(u8){};
        defer creq.deinit();
        const crw = creq.writer();
        try crw.print("GET\n/{s}\n{s}\nhost:{s}\n\nhost\nUNSIGNED-PAYLOAD", .{
            key, canonical_qs, host,
        });
        
        // Hash canonical request
        var creq_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(creq.items, &creq_hash, .{});
        var creq_hash_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&creq_hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&creq_hash)}) catch unreachable;
        
        // Build string to sign
        var sts = std.ArrayList(u8){};
        defer sts.deinit();
        const sw = sts.writer();
        try sw.print("AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ datetime, credential_scope, creq_hash_hex });
        
        // Derive signing key: HMAC-SHA256 chain
        const secret_key = try std.fmt.allocPrint(self.allocator, "AWS4{s}", .{self.config.secret_key});
        defer self.allocator.free(secret_key);
        
        var k_date: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&k_date, &date, secret_key);
        var k_region: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&k_region, self.config.region, &k_date);
        var k_service: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&k_service, "s3", &k_region);
        var k_signing: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&k_signing, "aws4_request", &k_service);
        
        // Compute signature
        var sig: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&sig, sts.items, &k_signing);
        var sig_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&sig_hex, "{}", .{std.fmt.fmtSliceHexLower(&sig)}) catch unreachable;
        
        // Build final URL
        var url = std.ArrayList(u8){};
        const writer = url.writer();
        try writer.print("https://{s}/{s}?{s}&X-Amz-Signature={s}", .{
            host, key, canonical_qs, sig_hex,
        });

        return url.toOwnedSlice();
    }
    
    /// Generate HANA Data Lake Files URL with HMAC-based signature.
    fn generateHdlUrl(self: *ObjectStoreConnector, container: []const u8, path: []const u8, expires_in: u32) ![]const u8 {
        const timestamp = std.time.timestamp();
        const expiry = timestamp + @as(i64, expires_in);
        
        // Build string to sign for HDL
        var sts = std.ArrayList(u8){};
        defer sts.deinit();
        const sw = sts.writer();
        try sw.print("GET\n/{s}/{s}\n{d}", .{ container, path, expiry });
        
        // HMAC-SHA256 sign with secret key
        var sig: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&sig, sts.items, self.config.secret_key);
        var sig_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&sig_hex, "{}", .{std.fmt.fmtSliceHexLower(&sig)}) catch unreachable;
        
        var url = std.ArrayList(u8){};
        const writer = url.writer();
        try writer.print("https://{s}/files/v1/{s}/{s}", .{
            self.config.endpoint, container, path,
        });
        try writer.print("?sig={s}", .{sig_hex});
        try writer.print("&exp={d}", .{expiry});
        try writer.print("&key_id={s}", .{self.config.access_key});
        
        return url.toOwnedSlice();
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Convert Unix timestamp to date string (YYYYMMDD)
fn timestampToDate(timestamp: i64) [8]u8 {
    // Simple calculation (approximate, ignores leap seconds)
    const days_since_epoch = @divTrunc(timestamp, 86400);
    
    // Calculate year, month, day (simplified)
    var year: i32 = 1970;
    var days_remaining = days_since_epoch;
    
    while (days_remaining >= daysInYear(year)) {
        days_remaining -= daysInYear(year);
        year += 1;
    }
    
    var month: i32 = 1;
    while (days_remaining >= daysInMonth(@intCast(month), year)) {
        days_remaining -= daysInMonth(@intCast(month), year);
        month += 1;
    }
    
    const day = days_remaining + 1;
    
    var result: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{d:0>4}{d:0>2}{d:0>2}", .{
        @as(u32, @intCast(year)),
        @as(u32, @intCast(month)),
        @as(u32, @intCast(day)),
    }) catch return "20260101".*;
    
    return result;
}

fn daysInYear(year: i32) i64 {
    if (@rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0)) {
        return 366;
    }
    return 365;
}

fn daysInMonth(month: u8, year: i32) i64 {
    const days_per_month = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and daysInYear(year) == 366) {
        return 29;
    }
    return days_per_month[month - 1];
}

/// Detect data format from file path extension
fn detectFormatFromPath(path: []const u8) toon_pointer.DataFormat {
    if (std.mem.endsWith(u8, path, ".parquet")) return .parquet;
    if (std.mem.endsWith(u8, path, ".arrow") or std.mem.endsWith(u8, path, ".ipc")) return .arrow;
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".jsonl")) return .json;
    if (std.mem.endsWith(u8, path, ".csv")) return .csv;
    return .binary;
}

// ============================================================================
// Parquet Column Projection (for efficient reads)
// ============================================================================

pub const ParquetProjection = struct {
    columns: []const []const u8,
    row_groups: ?[]const usize,
    
    /// Build column projection query string
    pub fn toQueryParams(self: *const ParquetProjection, allocator: std.mem.Allocator) ![]const u8 {
        var params: std.ArrayListUnmanaged(u8) = .empty;
        const writer = params.writer(allocator);
        
        try writer.writeAll("columns=");
        for (self.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll(col);
        }
        
        if (self.row_groups) |rgs| {
            try writer.writeAll("&row_groups=");
            for (rgs, 0..) |rg, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{d}", .{rg});
            }
        }
        
        return try params.toOwnedSlice(allocator);
    }
};

// ============================================================================
// GPU Direct Loading Support
// ============================================================================

pub const GpuLoadOptions = struct {
    device_id: u32,
    stream_id: ?u32,
    pinned_memory: bool,
    async_load: bool,
    
    pub fn default() GpuLoadOptions {
        return .{
            .device_id = 0,
            .stream_id = null,
            .pinned_memory = true,
            .async_load = true,
        };
    }
    
    /// Add GPU load hints to presigned URL
    pub fn appendToUrl(self: *const GpuLoadOptions, allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
        var url: std.ArrayListUnmanaged(u8) = .empty;
        try url.appendSlice(allocator, base_url);

        const writer = url.writer(allocator);
        const sep: u8 = if (std.mem.indexOf(u8, base_url, "?") != null) '&' else '?';
        
        try writer.print("{c}gpu_device={d}", .{ sep, self.device_id });
        if (self.stream_id) |sid| {
            try writer.print("&gpu_stream={d}", .{sid});
        }
        if (self.pinned_memory) {
            try writer.writeAll("&pinned=true");
        }
        if (self.async_load) {
            try writer.writeAll("&async=true");
        }
        
        return try url.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "resolve sap object pointer" {
    const allocator = std.testing.allocator;
    
    var ptr = try toon_pointer.ToonPointer.sapObject(
        allocator,
        "ai-models",
        "embeddings/vectors.parquet",
        .parquet,
        "id,vector",
        "OBJECT_STORE",
    );
    defer ptr.deinit();
    
    const config = ObjectStoreConfig{
        .endpoint = "s3.eu-central-1.amazonaws.com",
        .region = "eu-central-1",
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .bucket_prefix = null,
    };
    
    var connector = ObjectStoreConnector.init(allocator, config);
    var resolution = try connector.resolve(&ptr);
    defer resolution.deinit();
    
    try std.testing.expectEqual(toon_pointer.ResolutionType.presigned_url, resolution.resolution_type);
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "ai-models") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "vectors.parquet") != null);
}

test "resolve hdl pointer" {
    const allocator = std.testing.allocator;
    
    var ptr = try toon_pointer.ToonPointer.hdlFile(
        allocator,
        "training-data",
        "datasets/sales_2024.parquet",
        .parquet,
        "HDL_PROD",
    );
    defer ptr.deinit();
    
    const config = ObjectStoreConfig{
        .endpoint = "files.hana.cloud.sap",
        .region = "eu10",
        .access_key = "",
        .secret_key = "",
        .bucket_prefix = null,
    };
    
    var connector = ObjectStoreConnector.init(allocator, config);
    var resolution = try connector.resolve(&ptr);
    defer resolution.deinit();
    
    try std.testing.expectEqual(toon_pointer.ResolutionType.presigned_url, resolution.resolution_type);
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "training-data") != null);
}

test "detect format from path" {
    try std.testing.expectEqual(toon_pointer.DataFormat.parquet, detectFormatFromPath("data/file.parquet"));
    try std.testing.expectEqual(toon_pointer.DataFormat.arrow, detectFormatFromPath("data/file.arrow"));
    try std.testing.expectEqual(toon_pointer.DataFormat.json, detectFormatFromPath("config.json"));
    try std.testing.expectEqual(toon_pointer.DataFormat.csv, detectFormatFromPath("export.csv"));
    try std.testing.expectEqual(toon_pointer.DataFormat.binary, detectFormatFromPath("model.bin"));
}

test "parquet projection query" {
    const allocator = std.testing.allocator;
    
    const projection = ParquetProjection{
        .columns = &.{ "id", "vector", "metadata" },
        .row_groups = &.{ 0, 1, 2 },
    };
    
    const params = try projection.toQueryParams(allocator);
    defer allocator.free(params);
    
    try std.testing.expect(std.mem.indexOf(u8, params, "columns=id,vector,metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "row_groups=0,1,2") != null);
}