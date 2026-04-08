//! Audit Log — append-only, file-backed, size-bounded, SHA-256 hashed.
//!
//! Each entry is written as a single newline-terminated JSON line:
//!   {"ts":<unix_s>,"event":"<kind>","detail":"<msg>","sha256":"<hex>"}
//!
//! When the file exceeds `max_bytes`, the oldest half is discarded (rotate).
//! The SHA-256 hash covers: timestamp + event + detail, giving tamper evidence.
//!
//! Usage:
//!   var log = AuditLog.init(allocator, "/var/log/mcppal/audit.log", 10 * 1024 * 1024);
//!   defer log.deinit();
//!   try log.write(.tool_call, "pal-execute on SALES_DATA");

const std = @import("std");

// ============================================================================
// SHA-256 (std library wrapper)
// ============================================================================

fn sha256Hex(out: *[64]u8, data: []const u8) void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    const hex = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

// ============================================================================
// Event kinds
// ============================================================================

pub const EventKind = enum {
    server_start,
    server_stop,
    tool_call,
    schema_refresh,
    sql_execute,
    auth_failure,
    circuit_open,
    config_load,
    mangle_load,
    snapshot_create,
    snapshot_delete,

    pub fn str(self: EventKind) []const u8 {
        return switch (self) {
            .server_start => "server_start",
            .server_stop => "server_stop",
            .tool_call => "tool_call",
            .schema_refresh => "schema_refresh",
            .sql_execute => "sql_execute",
            .auth_failure => "auth_failure",
            .circuit_open => "circuit_open",
            .config_load => "config_load",
            .mangle_load => "mangle_load",
            .snapshot_create => "snapshot_create",
            .snapshot_delete => "snapshot_delete",
        };
    }
};

// ============================================================================
// AuditLog
// ============================================================================

/// Default maximum log file size before rotation (10 MiB).
pub const DEFAULT_MAX_BYTES: u64 = 10 * 1024 * 1024;

pub const AuditLog = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: u64,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, max_bytes: u64) AuditLog {
        return .{
            .allocator = allocator,
            .path = path,
            .max_bytes = if (max_bytes == 0) DEFAULT_MAX_BYTES else max_bytes,
        };
    }

    pub fn deinit(_: *AuditLog) void {}

    /// Append one audit entry to the log file.
    /// Non-fatal: logs a warning on I/O error rather than propagating.
    pub fn write(self: *AuditLog, kind: EventKind, detail: []const u8) void {
        self.writeEntry(kind, detail) catch |err| {
            std.log.warn("[audit] write failed: {}", .{err});
        };
    }

    fn writeEntry(self: *AuditLog, kind: EventKind, detail: []const u8) !void {
        const ts = std.time.timestamp();

        // Build the hash input: "<ts>|<kind>|<detail>"
        var hash_input_buf: [2048]u8 = undefined;
        const hash_input = std.fmt.bufPrint(&hash_input_buf, "{d}|{s}|{s}", .{
            ts, kind.str(), detail,
        }) catch blk: {
            // Truncate if needed — hash still covers what fits
            break :blk hash_input_buf[0..hash_input_buf.len];
        };

        var hex: [64]u8 = undefined;
        sha256Hex(&hex, hash_input);

        // Build the JSON log line (detail is escaped inline)
        var line_buf = std.ArrayList(u8).init(self.allocator);
        defer line_buf.deinit();
        const w = line_buf.writer();
        try w.print("{{\"ts\":{d},\"event\":\"{s}\",\"detail\":", .{ ts, kind.str() });
        try writeJsonStr(w, detail);
        try w.print(",\"sha256\":\"{s}\"}}\n", .{hex});
        const line = line_buf.items;

        // Ensure the parent directory exists
        if (std.fs.path.dirname(self.path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Check current file size and rotate if needed
        const current_size: u64 = blk: {
            const stat = std.fs.cwd().statFile(self.path) catch break :blk 0;
            break :blk stat.size;
        };

        if (current_size + line.len > self.max_bytes) {
            try self.rotate();
        }

        // Append to log file (create if missing)
        const file = std.fs.cwd().openFile(self.path, .{ .mode = .write_only }) catch
            try std.fs.cwd().createFile(self.path, .{ .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(line);
    }

    /// Discard the oldest half of the log file (keep newest half).
    fn rotate(self: *AuditLog) !void {
        std.log.info("[audit] rotating log file: {s}", .{self.path});

        const file = std.fs.cwd().openFile(self.path, .{ .mode = .read_only }) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, self.max_bytes * 2) catch return;
        defer self.allocator.free(content);

        // Find the midpoint line boundary
        const mid = content.len / 2;
        const keep_start = if (std.mem.indexOfPos(u8, content, mid, "\n")) |nl|
            nl + 1
        else
            mid;

        const keep = content[keep_start..];

        // Overwrite file with kept content
        const out = try std.fs.cwd().createFile(self.path, .{ .truncate = true });
        defer out.close();
        try out.writeAll(keep);
    }
};

// ============================================================================
// JSON string escape helper
// ============================================================================

fn writeJsonStr(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    // Truncate very long details to avoid bloated log lines
    const limit = @min(s.len, 1024);
    for (s[0..limit]) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    if (s.len > limit) try writer.writeAll("...");
    try writer.writeByte('"');
}

// ============================================================================
// Tests
// ============================================================================

test "sha256 hex output length" {
    var hex: [64]u8 = undefined;
    sha256Hex(&hex, "hello");
    try std.testing.expectEqual(@as(usize, 64), hex.len);
    // Known SHA-256 of "hello"
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &hex,
    );
}

test "event kind str" {
    try std.testing.expectEqualStrings("tool_call", EventKind.tool_call.str());
    try std.testing.expectEqualStrings("auth_failure", EventKind.auth_failure.str());
}

test "audit log write to temp file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_buf, "{s}/audit.log", .{path});

    var log = AuditLog.init(allocator, full_path, 1024 * 1024);
    defer log.deinit();

    log.write(.tool_call, "pal-execute on SALES_DATA");
    log.write(.schema_refresh, "schema: DBADMIN");

    const file = try tmp.dir.openFile("audit.log", .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 65536);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "tool_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "schema_refresh") != null);
}
