const std = @import("std");
const builtin = @import("builtin");

pub const Source = enum {
    zig_native,
    mojo_ffi,
};

const InitFn = *const fn () callconv(.c) c_int;
const ShutdownFn = *const fn () callconv(.c) void;
const ParityGapFn = *const fn (reference: f64, candidate: f64) callconv(.c) f64;
const NormalizePluginGidFn = *const fn (
    input_text: [*]const u8,
    input_len: c_int,
    output: [*]u8,
    output_capacity: c_int,
) callconv(.c) c_int;

pub const NormalizeResult = struct {
    value: []u8,
    source: Source,

    pub fn deinit(self: *NormalizeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const Runtime = struct {
    source: Source = .zig_native,
    dynlib: ?std.DynLib = null,
    parity_gap_fn: ?ParityGapFn = null,
    normalize_plugin_gid_fn: ?NormalizePluginGidFn = null,
    shutdown_fn: ?ShutdownFn = null,

    pub fn init(allocator: std.mem.Allocator, project_root: []const u8) !Runtime {
        if (std.posix.getenv("AIVERIFY_MOJO_FFI_LIB")) |override_path| {
            if (tryLoadFromPath(override_path)) |runtime| {
                return runtime;
            }
        }

        const lib_name = defaultLibraryName();

        const candidate_1 = try std.fs.path.join(allocator, &.{ project_root, "mojo", "lib", lib_name });
        defer allocator.free(candidate_1);
        if (tryLoadFromPath(candidate_1)) |runtime| {
            return runtime;
        }

        const candidate_2 = try std.fs.path.join(allocator, &.{ project_root, "mojo", "build", lib_name });
        defer allocator.free(candidate_2);
        if (tryLoadFromPath(candidate_2)) |runtime| {
            return runtime;
        }

        const candidate_3 = try std.fs.path.join(allocator, &.{ project_root, "mojo", "zig-out", "lib", lib_name });
        defer allocator.free(candidate_3);
        if (tryLoadFromPath(candidate_3)) |runtime| {
            return runtime;
        }

        return .{};
    }

    pub fn deinit(self: *Runtime) void {
        if (self.shutdown_fn) |shutdown| {
            shutdown();
        }
        if (self.dynlib) |*dynlib| {
            dynlib.close();
        }
        self.* = .{};
    }

    pub fn sourceLabel(self: *const Runtime) []const u8 {
        return sourceLabelFor(self.source);
    }

    pub fn parityGap(self: *const Runtime, reference: f64, candidate: f64) f64 {
        if (self.parity_gap_fn) |parity_gap_fn| {
            return parity_gap_fn(reference, candidate);
        }
        return nativeParityGap(reference, candidate);
    }

    pub fn normalizePluginGid(
        self: *const Runtime,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) !NormalizeResult {
        if (self.normalize_plugin_gid_fn) |normalize_fn| {
            const buffer_capacity: usize = if (text.len == 0) 1 else text.len;
            const output = try allocator.alloc(u8, buffer_capacity);
            defer allocator.free(output);
            @memset(output, 0);

            const written_raw = normalize_fn(
                text.ptr,
                @intCast(text.len),
                output.ptr,
                @intCast(buffer_capacity),
            );

            if (written_raw >= 0) {
                const written: usize = @intCast(written_raw);
                if (written <= output.len and (written == 0 or hasNonZeroByte(output[0..written]))) {
                    return .{
                        .value = try allocator.dupe(u8, output[0..written]),
                        .source = .mojo_ffi,
                    };
                }
            }
        }

        return .{
            .value = try nativeNormalizePluginGidAlloc(allocator, text),
            .source = .zig_native,
        };
    }
};

pub fn sourceLabelFor(source: Source) []const u8 {
    return switch (source) {
        .zig_native => "zig_native",
        .mojo_ffi => "mojo_ffi",
    };
}

fn defaultLibraryName() []const u8 {
    return switch (builtin.target.os.tag) {
        .windows => "aiverify_mojo_ffi.dll",
        .macos => "libaiverify_mojo_ffi.dylib",
        else => "libaiverify_mojo_ffi.so",
    };
}

fn tryLoadFromPath(path: []const u8) ?Runtime {
    var dynlib = std.DynLib.open(path) catch return null;
    errdefer dynlib.close();

    const parity_gap_fn = dynlib.lookup(ParityGapFn, "mojo_parity_gap") orelse return null;
    const normalize_plugin_gid_fn = dynlib.lookup(NormalizePluginGidFn, "mojo_normalize_plugin_gid");
    const init_fn = dynlib.lookup(InitFn, "mojo_init");
    const shutdown_fn = dynlib.lookup(ShutdownFn, "mojo_shutdown");

    if (init_fn) |init| {
        if (init() != 0) return null;
    }

    return .{
        .source = .mojo_ffi,
        .dynlib = dynlib,
        .parity_gap_fn = parity_gap_fn,
        .normalize_plugin_gid_fn = normalize_plugin_gid_fn,
        .shutdown_fn = shutdown_fn,
    };
}

fn nativeParityGap(reference: f64, candidate: f64) f64 {
    var delta = candidate - reference;
    if (delta < 0.0) delta = -delta;
    return delta;
}

fn nativeNormalizePluginGidAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    var previous_whitespace = true;
    for (text) |ch| {
        const is_whitespace = ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r';
        if (is_whitespace) {
            if (!previous_whitespace and output.items.len > 0) {
                try output.append(allocator, ' ');
            }
            previous_whitespace = true;
        } else {
            try output.append(allocator, std.ascii.toLower(ch));
            previous_whitespace = false;
        }
    }

    if (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
        _ = output.pop();
    }

    return output.toOwnedSlice(allocator);
}

fn hasNonZeroByte(data: []const u8) bool {
    for (data) |b| {
        if (b != 0) return true;
    }
    return false;
}

test "native parity gap is symmetric absolute delta" {
    const gap_1 = nativeParityGap(0.88, 0.81);
    const gap_2 = nativeParityGap(0.81, 0.88);
    try std.testing.expectApproxEqAbs(@as(f64, 0.07), gap_1, 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.07), gap_2, 0.0000001);
}

test "native normalize plugin gid lowercases and collapses whitespace" {
    const normalized = try nativeNormalizePluginGidAlloc(
        std.testing.allocator,
        "AIVERIFY.Stock \n \t Reports ",
    );
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("aiverify.stock reports", normalized);
}

test "runtime init falls back to zig native when mojo ffi is unavailable" {
    var runtime = try Runtime.init(std.testing.allocator, "/path/that/does/not/exist");
    defer runtime.deinit();
    try std.testing.expectEqual(Source.zig_native, runtime.source);
    try std.testing.expectEqualStrings("zig_native", runtime.sourceLabel());
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), runtime.parityGap(1.0, 1.5), 0.0000001);

    var normalized = try runtime.normalizePluginGid(std.testing.allocator, "  AbC   Def  ");
    defer normalized.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.zig_native, normalized.source);
    try std.testing.expectEqualStrings("abc def", normalized.value);
}
