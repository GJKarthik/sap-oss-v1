//! Mangle File Loader — Scan and load all .mg files from mangle/ directory
//!
//! This module provides independent Mangle loading capabilities for this service.
//! Each service has its own replicated copy - no shared dependencies.

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Loaded Mangle file contents
pub const MangleFile = struct {
    filename: []const u8,
    content: []const u8,
    
    pub fn deinit(self: *MangleFile, allocator: Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.content);
    }
};

/// Mangle File Loader
pub const MangleLoader = struct {
    allocator: Allocator,
    files: std.ArrayList(MangleFile),
    mangle_dir: []const u8,
    
    pub fn init(allocator: Allocator, mangle_dir: []const u8) MangleLoader {
        return .{
            .allocator = allocator,
            .files = std.ArrayList(MangleFile).init(allocator),
            .mangle_dir = mangle_dir,
        };
    }
    
    pub fn deinit(self: *MangleLoader) void {
        for (self.files.items) |*file| {
            file.deinit(self.allocator);
        }
        self.files.deinit();
    }
    
    /// Load all .mg files from the mangle directory
    pub fn loadAll(self: *MangleLoader) !usize {
        var dir = fs.cwd().openDir(self.mangle_dir, .{ .iterate = true }) catch |err| {
            std.log.warn("Could not open mangle directory '{s}': {}", .{ self.mangle_dir, err });
            return 0;
        };
        defer dir.close();
        
        var count: usize = 0;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!mem.endsWith(u8, entry.name, ".mg")) continue;
            
            // Read file content
            const file = dir.openFile(entry.name, .{}) catch |err| {
                std.log.warn("Could not open {s}: {}", .{ entry.name, err });
                continue;
            };
            defer file.close();
            
            const stat = try file.stat();
            const content = try self.allocator.alloc(u8, stat.size);
            errdefer self.allocator.free(content);
            
            const bytes_read = try file.readAll(content);
            if (bytes_read != stat.size) {
                self.allocator.free(content);
                continue;
            }
            
            const filename = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(filename);
            
            try self.files.append(.{
                .filename = filename,
                .content = content,
            });
            
            std.log.info("Loaded mangle file: {s} ({d} bytes)", .{ entry.name, stat.size });
            count += 1;
        }
        
        return count;
    }
    
    /// Load a specific .mg file by name
    pub fn loadFile(self: *MangleLoader, filename: []const u8) !void {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.mangle_dir, filename });
        
        const file = try fs.cwd().openFile(path, .{});
        defer file.close();
        
        const stat = try file.stat();
        const content = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(content);
        
        const bytes_read = try file.readAll(content);
        if (bytes_read != stat.size) {
            self.allocator.free(content);
            return error.IncompleteRead;
        }
        
        const filename_copy = try self.allocator.dupe(u8, filename);
        errdefer self.allocator.free(filename_copy);
        
        try self.files.append(.{
            .filename = filename_copy,
            .content = content,
        });
    }
    
    /// Get all loaded file contents concatenated
    pub fn getAllContent(self: *MangleLoader) ![]const u8 {
        var total_size: usize = 0;
        for (self.files.items) |file| {
            total_size += file.content.len + 2; // +2 for newlines between files
        }
        
        const result = try self.allocator.alloc(u8, total_size);
        var offset: usize = 0;
        
        for (self.files.items) |file| {
            @memcpy(result[offset..][0..file.content.len], file.content);
            offset += file.content.len;
            result[offset] = '\n';
            result[offset + 1] = '\n';
            offset += 2;
        }
        
        return result;
    }
    
    /// Get content of a specific file by name
    pub fn getFileContent(self: *MangleLoader, filename: []const u8) ?[]const u8 {
        for (self.files.items) |file| {
            if (mem.eql(u8, file.filename, filename)) {
                return file.content;
            }
        }
        return null;
    }
    
    /// Get list of loaded filenames
    pub fn getLoadedFiles(self: *MangleLoader) []const []const u8 {
        var names = std.ArrayList([]const u8).init(self.allocator);
        for (self.files.items) |file| {
            names.append(file.filename) catch continue;
        }
        return names.toOwnedSlice() catch &[_][]const u8{};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "loader init" {
    const allocator = std.testing.allocator;
    var loader = MangleLoader.init(allocator, "mangle");
    defer loader.deinit();
    
    try std.testing.expect(loader.files.items.len == 0);
}