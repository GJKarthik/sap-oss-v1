const std = @import("std");

pub const WriteResult = struct {
    success: bool,
    message: []const u8,
};

pub const FileList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged([]u8),

    pub fn init(allocator: std.mem.Allocator) FileList {
        return .{
            .allocator = allocator,
            .items = .{},
        };
    }

    pub fn deinit(self: *FileList) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }
};

pub const LocalStorageAdapter = struct {
    pub fn supports(_: []const u8) bool {
        return true;
    }

    pub fn readFile(allocator: std.mem.Allocator, file_path: []const u8) ?[]u8 {
        return std.fs.cwd().readFileAlloc(allocator, file_path, 64 * 1024 * 1024) catch null;
    }

    pub fn writeFile(file_path: []const u8, content: []const u8) WriteResult {
        const directory = std.fs.path.dirname(file_path) orelse ".";
        std.fs.cwd().makePath(directory) catch |err| {
            return .{ .success = false, .message = @errorName(err) };
        };

        if (exists(file_path)) {
            return .{ .success = false, .message = "File already exists" };
        }

        const file = std.fs.cwd().createFile(file_path, .{}) catch |err| {
            return .{ .success = false, .message = @errorName(err) };
        };
        defer file.close();

        file.writeAll(content) catch |err| {
            return .{ .success = false, .message = @errorName(err) };
        };

        return .{ .success = true, .message = "File written successfully" };
    }

    pub fn list(allocator: std.mem.Allocator, directory_path: []const u8) ?FileList {
        var dir = std.fs.cwd().openDir(directory_path, .{ .iterate = true }) catch return null;
        defer dir.close();

        var result = FileList.init(allocator);
        errdefer result.deinit();

        var iter = dir.iterate();
        while (iter.next() catch return null) |entry| {
            const name = allocator.dupe(u8, entry.name) catch return null;
            result.items.append(allocator, name) catch return null;
        }

        return result;
    }

    pub fn exists(file_path: []const u8) bool {
        std.fs.cwd().access(file_path, .{}) catch return false;
        return true;
    }

    pub fn getCreationDatetime(file_path: []const u8) !f64 {
        const stat = try std.fs.cwd().statFile(file_path);
        return @as(f64, @floatFromInt(stat.ctime)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    }
};

pub const S3Path = struct {
    bucket: []const u8,
    key: []const u8,
};

pub const S3StorageAdapter = struct {
    pub const PREFIX = "s3://";

    pub const PathError = error{
        InvalidPrefix,
        InvalidPath,
    };

    pub fn supports(path: []const u8) bool {
        return std.mem.startsWith(u8, path, PREFIX);
    }

    pub fn extractBucketAndKey(path: []const u8) PathError!S3Path {
        if (!supports(path)) return PathError.InvalidPrefix;

        const raw = path[PREFIX.len..];
        const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return PathError.InvalidPath;
        if (slash == 0 or slash + 1 >= raw.len) return PathError.InvalidPath;

        return .{
            .bucket = raw[0..slash],
            .key = raw[slash + 1 ..],
        };
    }
};

test "local storage supports parity" {
    try std.testing.expect(LocalStorageAdapter.supports("anything"));
}

test "local storage write/read/list/exists parity semantics" {
    const allocator = std.testing.allocator;

    var tmp_name_buf: [128]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "moonshot_adapter_test_{d}", .{std.time.timestamp()});
    const base = try std.fs.path.join(allocator, &.{ "/tmp", tmp_name });
    defer allocator.free(base);
    defer std.fs.deleteTreeAbsolute(base) catch {};

    const file_path = try std.fs.path.join(allocator, &.{ base, "result.json" });
    defer allocator.free(file_path);

    const first = LocalStorageAdapter.writeFile(file_path, "content");
    try std.testing.expect(first.success);
    try std.testing.expectEqualStrings("File written successfully", first.message);

    const second = LocalStorageAdapter.writeFile(file_path, "new-content");
    try std.testing.expect(!second.success);
    try std.testing.expectEqualStrings("File already exists", second.message);

    try std.testing.expect(LocalStorageAdapter.exists(file_path));

    const content = LocalStorageAdapter.readFile(allocator, file_path) orelse return error.ReadFailed;
    defer allocator.free(content);
    try std.testing.expectEqualStrings("content", content);

    var listing = LocalStorageAdapter.list(allocator, base) orelse return error.ListFailed;
    defer listing.deinit();
    try std.testing.expect(listing.items.items.len >= 1);

    const ctime = try LocalStorageAdapter.getCreationDatetime(file_path);
    try std.testing.expect(ctime > 0.0);
}

test "local storage missing read returns null" {
    const allocator = std.testing.allocator;
    try std.testing.expect(LocalStorageAdapter.readFile(allocator, "/tmp/moonshot_missing_file_123456.txt") == null);
}

test "s3 parser parity supports and extraction" {
    try std.testing.expect(S3StorageAdapter.supports("s3://bucket/file.txt"));
    try std.testing.expect(!S3StorageAdapter.supports("/tmp/file.txt"));

    const p = try S3StorageAdapter.extractBucketAndKey("s3://my-bucket/path/to/file.json");
    try std.testing.expectEqualStrings("my-bucket", p.bucket);
    try std.testing.expectEqualStrings("path/to/file.json", p.key);
}

test "s3 parser invalid paths fail" {
    try std.testing.expectError(S3StorageAdapter.PathError.InvalidPrefix, S3StorageAdapter.extractBucketAndKey("http://bucket/file.txt"));
    try std.testing.expectError(S3StorageAdapter.PathError.InvalidPath, S3StorageAdapter.extractBucketAndKey("s3://bucket-only"));
}
