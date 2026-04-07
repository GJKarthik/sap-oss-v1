const std = @import("std");

pub const LoopError = error{
    InvalidResponseType,
    InvalidResponseShape,
    GroupCreateFailed,
    AckFailed,
    LineTooLong,
    InvalidRespPrefix,
    InvalidRespTerminator,
    InvalidRespLength,
    UnexpectedEndOfStream,
};

pub const WorkerLoopOptions = struct {
    pub const Mode = enum {
        pending,
        reclaim,
    };

    host: []const u8,
    port: u16,
    stream_name: []const u8,
    group_name: []const u8,
    consumer_name: []const u8,
    block_ms: u32 = 3000,
    count: u16 = 1,
    ack_on_receive: bool = false,
    mode: Mode = .pending,
    reclaim_min_idle_ms: u32 = 60_000,
    reclaim_start: []const u8 = "0-0",
};

pub const WorkerOnceResult = struct {
    message_id: ?[]u8 = null,
    task_preview: ?[]u8 = null,
    task_size: usize = 0,
    truncated: bool = false,
    acked: bool = false,
    reclaim_next_start: ?[]u8 = null,

    pub fn deinit(self: *WorkerOnceResult, allocator: std.mem.Allocator) void {
        if (self.message_id) |value| allocator.free(value);
        if (self.task_preview) |value| allocator.free(value);
        if (self.reclaim_next_start) |value| allocator.free(value);
    }
};

const ExtractedMessage = struct {
    id: []u8,
    task: []u8,

    fn deinit(self: *ExtractedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.task);
    }
};

const RespValue = union(enum) {
    simple: []u8,
    err: []u8,
    integer: i64,
    bulk: ?[]u8,
    array: ?[]RespValue,

    fn deinit(self: *RespValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .simple => |value| allocator.free(value),
            .err => |value| allocator.free(value),
            .bulk => |value_opt| if (value_opt) |value| allocator.free(value),
            .array => |items_opt| if (items_opt) |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .integer => {},
        }
    }
};

pub fn runOnce(
    allocator: std.mem.Allocator,
    options: WorkerLoopOptions,
) !WorkerOnceResult {
    var stream = std.net.tcpConnectToHost(allocator, options.host, options.port) catch {
        return error.ConnectionRefused;
    };
    defer stream.close();

    var reader = StreamByteReader{ .stream = &stream };

    try ensureGroupExists(allocator, &stream, &reader, options);

    var result: WorkerOnceResult = .{};
    switch (options.mode) {
        .pending => {
            var read_value = try xreadgroupOnce(allocator, &stream, &reader, options);
            defer read_value.deinit(allocator);

            var message = try extractFirstTaskMessage(allocator, &read_value);
            defer if (message) |*msg| msg.deinit(allocator);

            if (message) |msg| {
                result.message_id = try allocator.dupe(u8, msg.id);
                result.task_size = msg.task.len;
                const preview_meta = try makeTaskPreview(allocator, msg.task, 200);
                result.task_preview = preview_meta.preview;
                result.truncated = preview_meta.truncated;

                if (options.ack_on_receive) {
                    result.acked = try xackMessage(
                        allocator,
                        &stream,
                        &reader,
                        options,
                        msg.id,
                    );
                }
            }
        },
        .reclaim => {
            var auto_value = try xautoclaimOnce(allocator, &stream, &reader, options);
            defer auto_value.deinit(allocator);

            const next_start = try extractAutoclaimNextStart(allocator, &auto_value);
            if (next_start) |value| {
                result.reclaim_next_start = value;
            }

            var message = try extractFirstTaskMessageFromAutoclaim(allocator, &auto_value);
            defer if (message) |*msg| msg.deinit(allocator);

            if (message) |msg| {
                result.message_id = try allocator.dupe(u8, msg.id);
                result.task_size = msg.task.len;
                const preview_meta = try makeTaskPreview(allocator, msg.task, 200);
                result.task_preview = preview_meta.preview;
                result.truncated = preview_meta.truncated;

                if (options.ack_on_receive) {
                    result.acked = try xackMessage(
                        allocator,
                        &stream,
                        &reader,
                        options,
                        msg.id,
                    );
                }
            }
        }
    }

    return result;
}

fn ensureGroupExists(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    reader: anytype,
    options: WorkerLoopOptions,
) !void {
    const args = [_][]const u8{
        "XGROUP",
        "CREATE",
        options.stream_name,
        options.group_name,
        "$",
        "MKSTREAM",
    };
    try sendCommand(allocator, stream, &args);

    var response = try parseRespValue(allocator, reader);
    defer response.deinit(allocator);

    switch (response) {
        .simple => |value| {
            if (!std.mem.eql(u8, value, "OK")) return LoopError.GroupCreateFailed;
        },
        .err => |value| {
            if (!std.mem.startsWith(u8, value, "BUSYGROUP")) {
                return LoopError.GroupCreateFailed;
            }
        },
        else => return LoopError.GroupCreateFailed,
    }
}

fn xreadgroupOnce(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    reader: anytype,
    options: WorkerLoopOptions,
) !RespValue {
    var count_buf: [16]u8 = undefined;
    const count = try std.fmt.bufPrint(&count_buf, "{d}", .{options.count});
    var block_buf: [32]u8 = undefined;
    const block = try std.fmt.bufPrint(&block_buf, "{d}", .{options.block_ms});

    const args = [_][]const u8{
        "XREADGROUP",
        "GROUP",
        options.group_name,
        options.consumer_name,
        "COUNT",
        count,
        "BLOCK",
        block,
        "STREAMS",
        options.stream_name,
        ">",
    };
    try sendCommand(allocator, stream, &args);
    return parseRespValue(allocator, reader);
}

fn xackMessage(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    reader: anytype,
    options: WorkerLoopOptions,
    message_id: []const u8,
) !bool {
    const args = [_][]const u8{
        "XACK",
        options.stream_name,
        options.group_name,
        message_id,
    };
    try sendCommand(allocator, stream, &args);

    var response = try parseRespValue(allocator, reader);
    defer response.deinit(allocator);

    return switch (response) {
        .integer => |value| value > 0,
        else => LoopError.AckFailed,
    };
}

fn xautoclaimOnce(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    reader: anytype,
    options: WorkerLoopOptions,
) !RespValue {
    var min_idle_buf: [32]u8 = undefined;
    const min_idle = try std.fmt.bufPrint(&min_idle_buf, "{d}", .{options.reclaim_min_idle_ms});
    var count_buf: [16]u8 = undefined;
    const count = try std.fmt.bufPrint(&count_buf, "{d}", .{options.count});

    const args = [_][]const u8{
        "XAUTOCLAIM",
        options.stream_name,
        options.group_name,
        options.consumer_name,
        min_idle,
        options.reclaim_start,
        "COUNT",
        count,
    };
    try sendCommand(allocator, stream, &args);
    return parseRespValue(allocator, reader);
}

fn sendCommand(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    args: []const []const u8,
) !void {
    var command_buf: std.ArrayListUnmanaged(u8) = .{};
    defer command_buf.deinit(allocator);
    const writer = command_buf.writer(allocator);

    try writer.print("*{d}\r\n", .{args.len});
    for (args) |arg| {
        try writer.print("${d}\r\n", .{arg.len});
        try writer.writeAll(arg);
        try writer.writeAll("\r\n");
    }
    try stream.writeAll(command_buf.items);
}

fn extractFirstTaskMessage(
    allocator: std.mem.Allocator,
    value: *const RespValue,
) !?ExtractedMessage {
    const top = switch (value.*) {
        .array => |items_opt| items_opt orelse return null,
        .bulk => |bulk_opt| {
            if (bulk_opt == null) return null;
            return LoopError.InvalidResponseType;
        },
        else => return LoopError.InvalidResponseType,
    };
    if (top.len == 0) return null;

    const stream_tuple = expectArray(top[0]) orelse return LoopError.InvalidResponseShape;
    if (stream_tuple.len < 2) return LoopError.InvalidResponseShape;

    const message_list = expectArray(stream_tuple[1]) orelse return null;
    if (message_list.len == 0) return null;

    const message_tuple = expectArray(message_list[0]) orelse return LoopError.InvalidResponseShape;
    if (message_tuple.len < 2) return LoopError.InvalidResponseShape;

    const message_id = expectBulk(message_tuple[0]) orelse return LoopError.InvalidResponseShape;
    const fields = expectArray(message_tuple[1]) orelse return LoopError.InvalidResponseShape;

    var task_value: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < fields.len) : (i += 2) {
        const key = expectBulk(fields[i]) orelse continue;
        if (std.mem.eql(u8, key, "task")) {
            task_value = expectBulk(fields[i + 1]);
            break;
        }
    }

    const task = task_value orelse return LoopError.InvalidResponseShape;
    return .{
        .id = try allocator.dupe(u8, message_id),
        .task = try allocator.dupe(u8, task),
    };
}

fn extractAutoclaimNextStart(
    allocator: std.mem.Allocator,
    value: *const RespValue,
) !?[]u8 {
    const top = switch (value.*) {
        .array => |items_opt| items_opt orelse return null,
        else => return LoopError.InvalidResponseType,
    };
    if (top.len == 0) return null;
    const next_start = expectBulk(top[0]) orelse return null;
    return try allocator.dupe(u8, next_start);
}

fn extractFirstTaskMessageFromAutoclaim(
    allocator: std.mem.Allocator,
    value: *const RespValue,
) !?ExtractedMessage {
    const top = switch (value.*) {
        .array => |items_opt| items_opt orelse return null,
        else => return LoopError.InvalidResponseType,
    };
    if (top.len < 2) return LoopError.InvalidResponseShape;

    const entries = expectArray(top[1]) orelse return null;
    if (entries.len == 0) return null;

    const message_tuple = expectArray(entries[0]) orelse return LoopError.InvalidResponseShape;
    if (message_tuple.len < 2) return LoopError.InvalidResponseShape;

    const message_id = expectBulk(message_tuple[0]) orelse return LoopError.InvalidResponseShape;
    const fields = expectArray(message_tuple[1]) orelse return LoopError.InvalidResponseShape;

    var task_value: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < fields.len) : (i += 2) {
        const key = expectBulk(fields[i]) orelse continue;
        if (std.mem.eql(u8, key, "task")) {
            task_value = expectBulk(fields[i + 1]);
            break;
        }
    }
    const task = task_value orelse return LoopError.InvalidResponseShape;
    return .{
        .id = try allocator.dupe(u8, message_id),
        .task = try allocator.dupe(u8, task),
    };
}

fn expectArray(value: RespValue) ?[]RespValue {
    return switch (value) {
        .array => |items_opt| items_opt,
        else => null,
    };
}

fn expectBulk(value: RespValue) ?[]const u8 {
    return switch (value) {
        .bulk => |bytes_opt| bytes_opt,
        else => null,
    };
}

fn makeTaskPreview(
    allocator: std.mem.Allocator,
    task: []const u8,
    max_len: usize,
) !struct { preview: []u8, truncated: bool } {
    const preview_len = @min(task.len, max_len);
    const preview = try allocator.alloc(u8, preview_len);
    std.mem.copyForwards(u8, preview, task[0..preview_len]);
    for (preview) |*ch| {
        if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
            ch.* = ' ';
        }
    }
    return .{
        .preview = preview,
        .truncated = task.len > max_len,
    };
}

fn parseRespValue(allocator: std.mem.Allocator, reader: anytype) !RespValue {
    const prefix = reader.readByte() catch return LoopError.UnexpectedEndOfStream;
    return switch (prefix) {
        '+' => .{ .simple = try readRespLineAlloc(allocator, reader, 1024 * 1024) },
        '-' => .{ .err = try readRespLineAlloc(allocator, reader, 1024 * 1024) },
        ':' => blk: {
            const line = try readRespLineAlloc(allocator, reader, 128);
            defer allocator.free(line);
            const value = std.fmt.parseInt(i64, line, 10) catch return LoopError.InvalidRespLength;
            break :blk .{ .integer = value };
        },
        '$' => blk: {
            const line = try readRespLineAlloc(allocator, reader, 128);
            defer allocator.free(line);
            const len_signed = std.fmt.parseInt(i64, line, 10) catch return LoopError.InvalidRespLength;
            if (len_signed == -1) break :blk .{ .bulk = null };
            if (len_signed < 0) return LoopError.InvalidRespLength;
            const len: usize = @intCast(len_signed);
            const bytes = try allocator.alloc(u8, len);
            errdefer allocator.free(bytes);
            reader.readNoEof(bytes) catch return LoopError.UnexpectedEndOfStream;
            try consumeCrlf(reader);
            break :blk .{ .bulk = bytes };
        },
        '*' => blk: {
            const line = try readRespLineAlloc(allocator, reader, 128);
            defer allocator.free(line);
            const len_signed = std.fmt.parseInt(i64, line, 10) catch return LoopError.InvalidRespLength;
            if (len_signed == -1) break :blk .{ .array = null };
            if (len_signed < 0) return LoopError.InvalidRespLength;
            const len: usize = @intCast(len_signed);
            var items = try allocator.alloc(RespValue, len);
            var initialized: usize = 0;
            errdefer {
                for (items[0..initialized]) |*item| item.deinit(allocator);
                allocator.free(items);
            }
            while (initialized < len) : (initialized += 1) {
                items[initialized] = try parseRespValue(allocator, reader);
            }
            break :blk .{ .array = items };
        },
        else => LoopError.InvalidRespPrefix,
    };
}

fn readRespLineAlloc(
    allocator: std.mem.Allocator,
    reader: anytype,
    max_len: usize,
) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .{};
    errdefer bytes.deinit(allocator);

    while (true) {
        const ch = reader.readByte() catch return LoopError.UnexpectedEndOfStream;
        if (ch == '\r') {
            const lf = reader.readByte() catch return LoopError.UnexpectedEndOfStream;
            if (lf != '\n') return LoopError.InvalidRespTerminator;
            break;
        }
        if (bytes.items.len >= max_len) return LoopError.LineTooLong;
        try bytes.append(allocator, ch);
    }

    return bytes.toOwnedSlice(allocator);
}

fn consumeCrlf(reader: anytype) !void {
    const cr = reader.readByte() catch return LoopError.UnexpectedEndOfStream;
    const lf = reader.readByte() catch return LoopError.UnexpectedEndOfStream;
    if (cr != '\r' or lf != '\n') return LoopError.InvalidRespTerminator;
}

const StreamByteReader = struct {
    stream: *std.net.Stream,

    fn readByte(self: *StreamByteReader) !u8 {
        var one: [1]u8 = undefined;
        const n = self.stream.read(one[0..]) catch return LoopError.UnexpectedEndOfStream;
        if (n == 0) return LoopError.UnexpectedEndOfStream;
        return one[0];
    }

    fn readNoEof(self: *StreamByteReader, dest: []u8) !void {
        var index: usize = 0;
        while (index < dest.len) {
            const n = self.stream.read(dest[index..]) catch return LoopError.UnexpectedEndOfStream;
            if (n == 0) return LoopError.UnexpectedEndOfStream;
            index += n;
        }
    }
};

test "parseRespValue parses null array response" {
    var stream = std.io.fixedBufferStream("*-1\r\n");
    var value = try parseRespValue(std.testing.allocator, stream.reader());
    defer value.deinit(std.testing.allocator);

    try std.testing.expect(switch (value) {
        .array => |items_opt| items_opt == null,
        else => false,
    });
}

test "extractFirstTaskMessage parses xreadgroup payload shape" {
    const payload =
        "*1\r\n" ++
        "*2\r\n" ++
        "$26\r\naiverify:worker:task_queue\r\n" ++
        "*1\r\n" ++
        "*2\r\n" ++
        "$6\r\n1700-0\r\n" ++
        "*2\r\n" ++
        "$4\r\ntask\r\n" ++
        "$16\r\n{\"id\":\"abc-123\"}\r\n";

    var stream = std.io.fixedBufferStream(payload);
    var value = try parseRespValue(std.testing.allocator, stream.reader());
    defer value.deinit(std.testing.allocator);

    var maybe_message = try extractFirstTaskMessage(std.testing.allocator, &value);
    defer if (maybe_message) |*msg| msg.deinit(std.testing.allocator);

    try std.testing.expect(maybe_message != null);
    const message = maybe_message.?;
    try std.testing.expectEqualStrings("1700-0", message.id);
    try std.testing.expectEqualStrings("{\"id\":\"abc-123\"}", message.task);
}

test "extractFirstTaskMessageFromAutoclaim parses xautoclaim payload shape" {
    const payload =
        "*3\r\n" ++
        "$3\r\n0-0\r\n" ++
        "*1\r\n" ++
        "*2\r\n" ++
        "$6\r\n1800-0\r\n" ++
        "*2\r\n" ++
        "$4\r\ntask\r\n" ++
        "$16\r\n{\"id\":\"xyz-789\"}\r\n" ++
        "*0\r\n";

    var stream = std.io.fixedBufferStream(payload);
    var value = try parseRespValue(std.testing.allocator, stream.reader());
    defer value.deinit(std.testing.allocator);

    const next_start = try extractAutoclaimNextStart(std.testing.allocator, &value);
    defer if (next_start) |s| std.testing.allocator.free(s);
    try std.testing.expect(next_start != null);
    try std.testing.expectEqualStrings("0-0", next_start.?);

    var maybe_message = try extractFirstTaskMessageFromAutoclaim(std.testing.allocator, &value);
    defer if (maybe_message) |*msg| msg.deinit(std.testing.allocator);
    try std.testing.expect(maybe_message != null);
    const message = maybe_message.?;
    try std.testing.expectEqualStrings("1800-0", message.id);
    try std.testing.expectEqualStrings("{\"id\":\"xyz-789\"}", message.task);
}
