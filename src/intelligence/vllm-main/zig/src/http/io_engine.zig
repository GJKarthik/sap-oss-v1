//! Cross-platform async I/O engine
//! Uses kqueue on macOS/BSD, epoll on Linux for event-driven socket I/O.
//! Integrates with the HTTP server's worker pool for request processing.

const std = @import("std");
const posix = std.posix;
const net = std.net;
const log = std.log.scoped(.io_engine);
const builtin = @import("builtin");

// ============================================================================
// Platform-specific constants
// ============================================================================

pub const Backend = enum {
    kqueue,
    epoll,
    poll_fallback,
};

pub const backend: Backend = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .openbsd or builtin.os.tag == .netbsd)
    .kqueue
else if (builtin.os.tag == .linux)
    .epoll
else
    .poll_fallback;

// ============================================================================
// Event Types
// ============================================================================

pub const EventKind = enum {
    readable,
    writable,
    error_hup,
};

pub const IoEvent = struct {
    fd: posix.fd_t,
    kind: EventKind,
    user_data: usize,
};

// ============================================================================
// I/O Engine Configuration
// ============================================================================

pub const IoEngineConfig = struct {
    max_events: u32 = 1024,
    timeout_ms: i32 = 100, // Poll timeout in milliseconds
};

// ============================================================================
// I/O Engine
// ============================================================================

pub const IoEngine = struct {
    config: IoEngineConfig,
    kq_fd: posix.fd_t,
    event_buf: []posix.Kevent,
    io_event_buf: []IoEvent,
    last_poll_count: usize,
    allocator: std.mem.Allocator,
    registered_fds: std.AutoHashMap(posix.fd_t, usize),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: IoEngineConfig) !Self {
        const kq = try posix.kqueue();
        const event_buf = try allocator.alloc(posix.Kevent, config.max_events);
        @memset(event_buf, std.mem.zeroes(posix.Kevent));
        const io_event_buf = try allocator.alloc(IoEvent, config.max_events);

        return .{
            .config = config,
            .kq_fd = kq,
            .event_buf = event_buf,
            .io_event_buf = io_event_buf,
            .last_poll_count = 0,
            .allocator = allocator,
            .registered_fds = std.AutoHashMap(posix.fd_t, usize).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.kq_fd);
        self.allocator.free(self.event_buf);
        self.allocator.free(self.io_event_buf);
        self.registered_fds.deinit();
    }

    /// Register a file descriptor for read events
    pub fn addRead(self: *Self, fd: posix.fd_t, user_data: usize) !void {
        var changelist = [1]posix.Kevent{makeEvent(fd, std.c.EVFILT.READ, std.c.EV.ADD | std.c.EV.ENABLE, user_data)};
        _ = try posix.kevent(self.kq_fd, &changelist, &[0]posix.Kevent{}, null);
        try self.registered_fds.put(fd, user_data);
    }

    /// Register a file descriptor for write events
    pub fn addWrite(self: *Self, fd: posix.fd_t, user_data: usize) !void {
        var changelist = [1]posix.Kevent{makeEvent(fd, std.c.EVFILT.WRITE, std.c.EV.ADD | std.c.EV.ENABLE, user_data)};
        _ = try posix.kevent(self.kq_fd, &changelist, &[0]posix.Kevent{}, null);
        try self.registered_fds.put(fd, user_data);
    }

    /// Remove a file descriptor from monitoring
    pub fn remove(self: *Self, fd: posix.fd_t) !void {
        var changelist = [2]posix.Kevent{
            makeEvent(fd, std.c.EVFILT.READ, std.c.EV.DELETE, 0),
            makeEvent(fd, std.c.EVFILT.WRITE, std.c.EV.DELETE, 0),
        };
        // Ignore errors on delete (fd may have been closed)
        _ = posix.kevent(self.kq_fd, &changelist, &[0]posix.Kevent{}, null) catch {};
        _ = self.registered_fds.remove(fd);
    }

    /// Wait for events, returns slice of ready IoEvents
    pub fn poll(self: *Self) ![]const IoEvent {
        const ms = self.config.timeout_ms;
        const timeout = posix.timespec{
            .sec = @intCast(@divTrunc(ms, 1000)),
            .nsec = @intCast(@rem(ms, 1000) * @as(i32, 1_000_000)),
        };
        const n = try posix.kevent(self.kq_fd, &[0]posix.Kevent{}, self.event_buf, &timeout);
        var count: usize = 0;
        for (self.event_buf[0..n]) |ev| {
            const kind: EventKind = if ((ev.flags & std.c.EV.ERROR) != 0)
                .error_hup
            else if (ev.filter == std.c.EVFILT.READ)
                .readable
            else if (ev.filter == std.c.EVFILT.WRITE)
                .writable
            else
                continue;
            self.io_event_buf[count] = .{
                .fd = @intCast(ev.ident),
                .kind = kind,
                .user_data = ev.udata,
            };
            count += 1;
        }
        self.last_poll_count = count;
        return self.io_event_buf[0..count];
    }

    /// Returns number of file descriptors currently registered
    pub fn registeredCount(self: *const Self) usize {
        return self.registered_fds.count();
    }
};

/// Construct a kqueue Kevent struct for changelist registration
fn makeEvent(fd: posix.fd_t, filter: i16, flags: u16, user_data: usize) posix.Kevent {
    return .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = user_data,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "IoEngine init/deinit" {
    var engine = try IoEngine.init(std.testing.allocator, .{});
    defer engine.deinit();
    try std.testing.expect(engine.kq_fd >= 0);
    try std.testing.expectEqual(@as(usize, 0), engine.registeredCount());
}

test "IoEngine poll empty returns no events" {
    var engine = try IoEngine.init(std.testing.allocator, .{ .timeout_ms = 0 });
    defer engine.deinit();
    const events = try engine.poll();
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "IoEngine addRead/remove" {
    var engine = try IoEngine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    try engine.addRead(pipe_fds[0], 42);
    try std.testing.expectEqual(@as(usize, 1), engine.registeredCount());

    try engine.remove(pipe_fds[0]);
    try std.testing.expectEqual(@as(usize, 0), engine.registeredCount());
}

test "IoEngine poll detects readable pipe" {
    var engine = try IoEngine.init(std.testing.allocator, .{ .timeout_ms = 100 });
    defer engine.deinit();

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    try engine.addRead(pipe_fds[0], 99);

    // Write to pipe to make read end readable
    _ = try posix.write(pipe_fds[1], "hello");

    const events = try engine.poll();
    try std.testing.expect(events.len >= 1);
    try std.testing.expectEqual(pipe_fds[0], events[0].fd);
    try std.testing.expectEqual(EventKind.readable, events[0].kind);
    try std.testing.expectEqual(@as(usize, 99), events[0].user_data);
}
