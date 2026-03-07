const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

/// Air-gapped deployment configuration
pub const AirGapConfig = struct {
    enabled: bool = false,
    cache_dir: []const u8 = "/opt/privatellm/models",
    skip_tls_verify: bool = false,
    registry_mirror: []const u8 = "",
    manifest_path: []const u8 = "",

    pub fn fromEnv() AirGapConfig {
        var cfg = AirGapConfig{};
        if (posix.getenv("AIRGAP_ENABLED")) |val| {
            cfg.enabled = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }
        if (posix.getenv("AIRGAP_CACHE_DIR")) |dir| {
            cfg.cache_dir = dir;
        }
        if (posix.getenv("AIRGAP_SKIP_TLS")) |val| {
            cfg.skip_tls_verify = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }
        if (posix.getenv("AIRGAP_REGISTRY_MIRROR")) |mirror| {
            cfg.registry_mirror = mirror;
        }
        if (posix.getenv("AIRGAP_MANIFEST_PATH")) |path| {
            cfg.manifest_path = path;
        }
        return cfg;
    }
};

/// vGPU environment type
pub const GpuEnvironment = enum {
    bare_metal,
    nvidia_vgpu,
    nvidia_mig,
    cloud_gpu,
    unknown,

    pub fn detect() GpuEnvironment {
        // Check for NVIDIA vGPU indicators
        if (posix.getenv("NVIDIA_DRIVER_CAPABILITIES")) |caps| {
            if (std.mem.indexOf(u8, caps, "vgpu") != null) {
                return .nvidia_vgpu;
            }
        }
        // Check for MIG mode
        if (posix.getenv("NVIDIA_MIG_MONITOR_DEVICES")) |_| {
            return .nvidia_mig;
        }
        // Check for cloud GPU indicators
        if (posix.getenv("AWS_EXECUTION_ENV")) |_| {
            return .cloud_gpu;
        }
        if (posix.getenv("GOOGLE_CLOUD_PROJECT")) |_| {
            return .cloud_gpu;
        }
        if (posix.getenv("AZURE_SUBSCRIPTION_ID")) |_| {
            return .cloud_gpu;
        }
        // Default to bare metal if no virtualization detected
        return .bare_metal;
    }

    pub fn name(self: GpuEnvironment) []const u8 {
        return switch (self) {
            .bare_metal => "bare_metal",
            .nvidia_vgpu => "nvidia_vgpu",
            .nvidia_mig => "nvidia_mig",
            .cloud_gpu => "cloud_gpu",
            .unknown => "unknown",
        };
    }

    pub fn isVirtualized(self: GpuEnvironment) bool {
        return switch (self) {
            .bare_metal => false,
            .unknown => false,
            else => true,
        };
    }
};

/// Model manifest entry
pub const ManifestEntry = struct {
    name: []const u8,
    path: []const u8,
    size_bytes: u64,
    checksum: []const u8,
    format: []const u8,
};

/// Model manifest for air-gapped environments
pub const ModelManifest = struct {
    models: std.ArrayListUnmanaged(ManifestEntry),

    pub fn init() ModelManifest {
        return .{ .models = .{} };
    }

    pub fn deinit(self: *ModelManifest, allocator: Allocator) void {
        _ = allocator;
        self.models.deinit();
    }

    pub fn addEntry(self: *ModelManifest, allocator: Allocator, entry: ManifestEntry) !void {
        _ = allocator;
        try self.models.append(entry);
    }

    pub fn findModel(self: *const ModelManifest, name: []const u8) ?ManifestEntry {
        for (self.models.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }

    pub fn count(self: *const ModelManifest) usize {
        return self.models.items.len;
    }
};

/// Deployment manager
pub const DeploymentManager = struct {
    allocator: Allocator,
    air_gap: AirGapConfig,
    gpu_env: GpuEnvironment,
    manifest: ModelManifest,

    pub fn init(allocator: Allocator) DeploymentManager {
        return .{
            .allocator = allocator,
            .air_gap = AirGapConfig.fromEnv(),
            .gpu_env = GpuEnvironment.detect(),
            .manifest = ModelManifest.init(),
        };
    }

    pub fn deinit(self: *DeploymentManager) void {
        self.manifest.deinit();
    }

    pub fn isModelAvailable(self: *const DeploymentManager, name: []const u8) bool {
        return self.manifest.findModel(name) != null;
    }

    pub fn resolveModelPath(self: *const DeploymentManager, name: []const u8) ?[]const u8 {
        if (self.manifest.findModel(name)) |entry| {
            return entry.path;
        }
        return null;
    }

    pub fn isReady(self: *const DeploymentManager) bool {
        return !self.air_gap.enabled or self.manifest.count() > 0;
    }

    pub fn getInfo(self: *const DeploymentManager) DeploymentInfo {
        return .{
            .air_gapped = self.air_gap.enabled,
            .gpu_environment = self.gpu_env,
            .models_available = self.manifest.count(),
            .cache_dir = self.air_gap.cache_dir,
        };
    }
};

pub const DeploymentInfo = struct {
    air_gapped: bool,
    gpu_environment: GpuEnvironment,
    models_available: usize,
    cache_dir: []const u8,
};

// ============================================================================
// Tests
// ============================================================================

test "AirGapConfig.fromEnv with defaults" {
    const cfg = AirGapConfig.fromEnv();
    try std.testing.expect(!cfg.enabled);
    try std.testing.expectEqualStrings(cfg.cache_dir, "/opt/privatellm/models");
    try std.testing.expect(!cfg.skip_tls_verify);
}

test "GpuEnvironment.detect returns valid value" {
    const env = GpuEnvironment.detect();
    try std.testing.expect(env != .unknown);
}

test "GpuEnvironment.isVirtualized logic" {
    try std.testing.expect(!GpuEnvironment.bare_metal.isVirtualized());
    try std.testing.expect(GpuEnvironment.nvidia_vgpu.isVirtualized());
    try std.testing.expect(GpuEnvironment.nvidia_mig.isVirtualized());
    try std.testing.expect(GpuEnvironment.cloud_gpu.isVirtualized());
}

test "ModelManifest add and find entries" {
    var manifest = ModelManifest.init();
    defer manifest.deinit(std.testing.allocator);

    const entry = ManifestEntry{
        .name = "phi-2",
        .path = "/opt/models/phi-2.gguf",
        .size_bytes = 1024,
        .checksum = "abc123",
        .format = "gguf",
    };
    try manifest.addEntry(std.testing.allocator, entry);
    try std.testing.expectEqual(@as(usize, 1), manifest.count());
    try std.testing.expect(manifest.findModel("phi-2") != null);
    try std.testing.expect(manifest.findModel("unknown") == null);
}

test "DeploymentManager init and readiness" {
    var mgr = DeploymentManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expect(mgr.isReady());
    const info = mgr.getInfo();
    try std.testing.expectEqual(info.models_available, 0);
}

