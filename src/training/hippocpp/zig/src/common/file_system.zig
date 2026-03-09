//! File System - Virtual file system abstraction
//!
//! Purpose:
//! Provides a unified interface for file operations supporting
//! local files, memory-mapped files, and cloud storage backends.

const std = @import("std");

// ============================================================================
// File Open Flags
// ============================================================================

pub const OpenFlags = struct {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    direct_io: bool = false,
    sync: bool = false,

    pub fn readOnly() OpenFlags {
        return .{ .read = true };
    }

    pub fn readWrite() OpenFlags {
        return .{ .read = true, .write = true };
    }

    pub fn createNew() OpenFlags {
        return .{ .read = true, .write = true, .create = true, .truncate = true };
    }

    pub fn appendOnly() OpenFlags {
        return .{ .write = true, .create = true, .append = true };
    }
};

// ============================================================================
// File Info
// ============================================================================

pub const FileInfo = struct {
    path: []const u8,
    size: u64,
    is_directory: bool,
    is_regular: bool,
    is_symlink: bool,
    created: i128 = 0,
    modified: i128 = 0,
    accessed: i128 = 0,

    pub fn init(path: []const u8, size: u64, is_dir: bool) FileInfo {
        return .{
            .path = path,
            .size = size,
            .is_directory = is_dir,
            .is_regular = !is_dir,
            .is_symlink = false,
        };
    }
};

// ============================================================================
// File Handle (Abstract)
// ============================================================================

pub const FileHandle = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    flags: OpenFlags,
    impl: FileImpl,

    pub const FileImpl = union(enum) {
        local: std.fs.File,
        memory: *MemoryFile,
    };

    pub fn read(self: *FileHandle, buffer: []u8) !usize {
        return switch (self.impl) {
            .local => |f| f.read(buffer),
            .memory => |m| m.read(buffer),
        };
    }

    pub fn readAll(self: *FileHandle, buffer: []u8) !usize {
        return switch (self.impl) {
            .local => |f| f.readAll(buffer),
            .memory => |m| m.readAll(buffer),
        };
    }

    pub fn write(self: *FileHandle, data: []const u8) !usize {
        return switch (self.impl) {
            .local => |f| f.write(data),
            .memory => |m| m.write(data),
        };
    }

    pub fn writeAll(self: *FileHandle, data: []const u8) !void {
        switch (self.impl) {
            .local => |f| try f.writeAll(data),
            .memory => |m| try m.writeAll(data),
        }
    }

    pub fn seekTo(self: *FileHandle, pos: u64) !void {
        switch (self.impl) {
            .local => |f| try f.seekTo(pos),
            .memory => |m| m.seekTo(pos),
        }
    }

    pub fn getPos(self: *FileHandle) !u64 {
        return switch (self.impl) {
            .local => |f| f.getPos(),
            .memory => |m| m.getPos(),
        };
    }

    pub fn getEndPos(self: *FileHandle) !u64 {
        return switch (self.impl) {
            .local => |f| f.getEndPos(),
            .memory => |m| m.getEndPos(),
        };
    }

    pub fn sync(self: *FileHandle) !void {
        switch (self.impl) {
            .local => |f| try f.sync(),
            .memory => {},
        }
    }

    pub fn close(self: *FileHandle) void {
        switch (self.impl) {
            .local => |f| f.close(),
            .memory => {
                // Memory files are owned by VirtualFileSystem, don't free here
            },
        }
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Memory File (In-memory file)
// ============================================================================

pub const MemoryFile = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),
    position: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MemoryFile {
        return .{
            .allocator = allocator,
            .data = .{},
        };
    }

    pub fn initWithData(allocator: std.mem.Allocator, data: []const u8) !MemoryFile {
        var file = MemoryFile{
            .allocator = allocator,
            .data = .{},
        };
        try file.data.appendSlice(allocator, data);
        return file;
    }

    pub fn deinit(self: *MemoryFile) void {
        self.data.deinit(self.allocator);
    }

    pub fn read(self: *MemoryFile, buffer: []u8) usize {
        const available = self.data.items.len - self.position;
        const to_read = @min(available, buffer.len);
        @memcpy(buffer[0..to_read], self.data.items[self.position..self.position + to_read]);
        self.position += to_read;
        return to_read;
    }

    pub fn readAll(self: *MemoryFile, buffer: []u8) usize {
        return self.read(buffer);
    }

    pub fn write(self: *MemoryFile, data: []const u8) !usize {
        // Extend if needed
        const end_pos = self.position + data.len;
        if (end_pos > self.data.items.len) {
            try self.data.resize(self.allocator, end_pos);
        }
        @memcpy(self.data.items[self.position..self.position + data.len], data);
        self.position += data.len;
        return data.len;
    }

    pub fn writeAll(self: *MemoryFile, data: []const u8) !void {
        _ = try self.write(data);
    }

    pub fn seekTo(self: *MemoryFile, pos: u64) void {
        self.position = @intCast(@min(pos, self.data.items.len));
    }

    pub fn getPos(self: *const MemoryFile) u64 {
        return @intCast(self.position);
    }

    pub fn getEndPos(self: *const MemoryFile) u64 {
        return @intCast(self.data.items.len);
    }

    pub fn getBytes(self: *const MemoryFile) []const u8 {
        return self.data.items;
    }
};

// ============================================================================
// File System Interface
// ============================================================================

pub const FileSystemType = enum {
    LOCAL,
    MEMORY,
    VIRTUAL,
};

pub const FileSystem = struct {
    allocator: std.mem.Allocator,
    type_id: FileSystemType,

    // VTable for polymorphism
    openFileFn: *const fn (*FileSystem, []const u8, OpenFlags) anyerror!*FileHandle,
    fileExistsFn: *const fn (*FileSystem, []const u8) bool,
    getFileSizeFn: *const fn (*FileSystem, []const u8) anyerror!u64,
    removeFileFn: *const fn (*FileSystem, []const u8) anyerror!void,
    createDirectoryFn: *const fn (*FileSystem, []const u8) anyerror!void,
    listDirectoryFn: *const fn (*FileSystem, []const u8, std.mem.Allocator) anyerror![]FileInfo,

    pub fn openFile(self: *FileSystem, path: []const u8, flags: OpenFlags) !*FileHandle {
        return self.openFileFn(self, path, flags);
    }

    pub fn fileExists(self: *FileSystem, path: []const u8) bool {
        return self.fileExistsFn(self, path);
    }

    pub fn getFileSize(self: *FileSystem, path: []const u8) !u64 {
        return self.getFileSizeFn(self, path);
    }

    pub fn removeFile(self: *FileSystem, path: []const u8) !void {
        return self.removeFileFn(self, path);
    }

    pub fn createDirectory(self: *FileSystem, path: []const u8) !void {
        return self.createDirectoryFn(self, path);
    }

    pub fn listDirectory(self: *FileSystem, path: []const u8, alloc: std.mem.Allocator) ![]FileInfo {
        return self.listDirectoryFn(self, path, alloc);
    }
};

// ============================================================================
// Local File System
// ============================================================================

pub const LocalFileSystem = struct {
    base: FileSystem,

    pub fn init(allocator: std.mem.Allocator) LocalFileSystem {
        return .{
            .base = .{
                .allocator = allocator,
                .type_id = .LOCAL,
                .openFileFn = openFileImpl,
                .fileExistsFn = fileExistsImpl,
                .getFileSizeFn = getFileSizeImpl,
                .removeFileFn = removeFileImpl,
                .createDirectoryFn = createDirectoryImpl,
                .listDirectoryFn = listDirectoryImpl,
            },
        };
    }

    fn openFileImpl(fs: *FileSystem, path: []const u8, flags: OpenFlags) !*FileHandle {
        const open_flags: std.fs.File.OpenFlags = .{};
        const create_flags: std.fs.File.CreateFlags = .{};

        if (flags.read) open_flags.mode = .read_only;
        if (flags.write) open_flags.mode = .read_write;

        const file = if (flags.create)
            try std.fs.cwd().createFile(path, create_flags)
        else
            try std.fs.cwd().openFile(path, open_flags);

        const handle = try fs.allocator.create(FileHandle);
        handle.* = .{
            .allocator = fs.allocator,
            .path = try fs.allocator.dupe(u8, path),
            .flags = flags,
            .impl = .{ .local = file },
        };

        return handle;
    }

    fn fileExistsImpl(_: *FileSystem, path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    fn getFileSizeImpl(_: *FileSystem, path: []const u8) !u64 {
        const stat = try std.fs.cwd().statFile(path);
        return stat.size;
    }

    fn removeFileImpl(_: *FileSystem, path: []const u8) !void {
        try std.fs.cwd().deleteFile(path);
    }

    fn createDirectoryImpl(_: *FileSystem, path: []const u8) !void {
        try std.fs.cwd().makeDir(path);
    }

    fn listDirectoryImpl(_: *FileSystem, path: []const u8, alloc: std.mem.Allocator) ![]FileInfo {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();

        var entries: std.ArrayList(FileInfo) = .{};

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, entry.name });
            const is_dir = entry.kind == .directory;
            const size: u64 = if (is_dir) 0 else blk: {
                const stat = std.fs.cwd().statFile(full_path) catch break :blk 0;
                break :blk stat.size;
            };

            try entries.append(alloc, .{ .path = full_path, .size = size, .is_directory = is_dir, .is_regular = !is_dir });
        }

        return try entries.toOwnedSlice(alloc);
    }

    pub fn asFileSystem(self: *LocalFileSystem) *FileSystem {
        return &self.base;
    }
};

// ============================================================================
// Virtual File System (In-Memory)
// ============================================================================

pub const VirtualFileSystem = struct {
    base: FileSystem,
    files: std.StringHashMap(*MemoryFile),

    pub fn init(allocator: std.mem.Allocator) VirtualFileSystem {
        return .{
            .base = .{
                .allocator = allocator,
                .type_id = .VIRTUAL,
                .openFileFn = openFileImpl,
                .fileExistsFn = fileExistsImpl,
                .getFileSizeFn = getFileSizeImpl,
                .removeFileFn = removeFileImpl,
                .createDirectoryFn = createDirectoryImpl,
                .listDirectoryFn = listDirectoryImpl,
            },
            .files = std.StringHashMap(*MemoryFile).init(allocator),
        };
    }

    pub fn deinit(self: *VirtualFileSystem) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.base.allocator.destroy(entry.value_ptr.*);
            self.base.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit();
    }

    fn openFileImpl(fs: *FileSystem, path: []const u8, flags: OpenFlags) !*FileHandle {
        const vfs: *VirtualFileSystem = @fieldParentPtr("base", fs);

        var mem_file: *MemoryFile = undefined;

        if (vfs.files.get(path)) |existing| {
            mem_file = existing;
            mem_file.position = 0; // Reset position for new handle
        } else if (flags.create) {
            mem_file = try fs.allocator.create(MemoryFile);
            mem_file.* = MemoryFile.init(fs.allocator);
            try vfs.files.put(try fs.allocator.dupe(u8, path), mem_file);
        } else {
            return error.FileNotFound;
        }

        const handle = try fs.allocator.create(FileHandle);
        handle.* = .{
            .allocator = fs.allocator,
            .path = try fs.allocator.dupe(u8, path),
            .flags = flags,
            .impl = .{ .memory = mem_file },
        };

        return handle;
    }

    fn fileExistsImpl(fs: *FileSystem, path: []const u8) bool {
        const vfs: *VirtualFileSystem = @fieldParentPtr("base", fs);
        return vfs.files.contains(path);
    }

    fn getFileSizeImpl(fs: *FileSystem, path: []const u8) !u64 {
        const vfs: *VirtualFileSystem = @fieldParentPtr("base", fs);
        if (vfs.files.get(path)) |file| {
            return file.getEndPos();
        }
        return error.FileNotFound;
    }

    fn removeFileImpl(fs: *FileSystem, path: []const u8) !void {
        const vfs: *VirtualFileSystem = @fieldParentPtr("base", fs);
        if (vfs.files.fetchRemove(path)) |entry| {
            entry.value.deinit();
            fs.allocator.destroy(entry.value);
        }
    }

    fn createDirectoryImpl(_: *FileSystem, _: []const u8) !void {
        // Directories are implicit in virtual FS
    }

    fn listDirectoryImpl(fs: *FileSystem, prefix: []const u8, alloc: std.mem.Allocator) ![]FileInfo {
        const vfs: *VirtualFileSystem = @fieldParentPtr("base", fs);
        var entries: std.ArrayList(FileInfo) = .{};

        var iter = vfs.files.iterator();
        while (iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                try entries.append(alloc, FileInfo.init(
                    try alloc.dupe(u8, entry.key_ptr.*),
                    entry.value_ptr.*.getEndPos(),
                    false,
                ));
            }
        }

        return try entries.toOwnedSlice(alloc);
    }

    pub fn asFileSystem(self: *VirtualFileSystem) *FileSystem {
        return &self.base;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "memory file read write" {
    const allocator = std.testing.allocator;

    var file = MemoryFile.init(allocator);
    defer file.deinit();

    _ = try file.write("Hello, ");
    _ = try file.write("World!");

    try std.testing.expectEqual(@as(u64, 13), file.getEndPos());
    try std.testing.expectEqualStrings("Hello, World!", file.getBytes());

    file.seekTo(0);
    var buffer: [5]u8 = undefined;
    const read = file.read(&buffer);
    try std.testing.expectEqual(@as(usize, 5), read);
    try std.testing.expectEqualStrings("Hello", &buffer);
}

test "virtual file system" {
    const allocator = std.testing.allocator;

    var vfs = VirtualFileSystem.init(allocator);
    defer vfs.deinit();

    var fs = vfs.asFileSystem();

    // Create file
    const handle = try fs.openFile("test.txt", OpenFlags.createNew());
    try handle.writeAll("Test content");
    handle.close();

    // File should exist
    try std.testing.expect(fs.fileExists("test.txt"));
    try std.testing.expectEqual(@as(u64, 12), try fs.getFileSize("test.txt"));

    // Read back
    const handle2 = try fs.openFile("test.txt", OpenFlags.readOnly());
    var buffer: [20]u8 = undefined;
    const read = try handle2.read(&buffer);
    try std.testing.expectEqual(@as(usize, 12), read);
    try std.testing.expectEqualStrings("Test content", buffer[0..12]);
    handle2.close();
}

test "open flags" {
    const ro = OpenFlags.readOnly();
    try std.testing.expect(ro.read);
    try std.testing.expect(!ro.write);

    const rw = OpenFlags.readWrite();
    try std.testing.expect(rw.read);
    try std.testing.expect(rw.write);

    const create = OpenFlags.createNew();
    try std.testing.expect(create.create);
    try std.testing.expect(create.truncate);
}

test "file info" {
    const info = FileInfo.init("/path/to/file.txt", 1024, false);
    try std.testing.expectEqualStrings("/path/to/file.txt", info.path);
    try std.testing.expectEqual(@as(u64, 1024), info.size);
    try std.testing.expect(!info.is_directory);
    try std.testing.expect(info.is_regular);

}






