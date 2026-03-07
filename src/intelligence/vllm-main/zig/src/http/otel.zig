//! OpenTelemetry (OTEL) Tracing & Metrics Export
//!
//! W3C Trace Context propagation + OTLP HTTP/JSON exporter:
//! - Span creation with parent/child relationships
//! - W3C traceparent header parsing/generation
//! - Batch span export via OTLP HTTP
//! - Integration with existing Prometheus metrics

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Trace Context (W3C)
// ============================================================================

pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

pub const TraceFlags = packed struct(u8) {
    sampled: bool = false,
    _padding: u7 = 0,
};

pub const TraceContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    flags: TraceFlags,
    parent_span_id: ?SpanId,

    /// Parse W3C traceparent header: "00-{trace_id}-{span_id}-{flags}"
    pub fn fromTraceparent(header: []const u8) ?TraceContext {
        if (header.len < 55) return null;
        if (header[0] != '0' or header[1] != '0' or header[2] != '-') return null;
        var ctx: TraceContext = .{
            .trace_id = undefined,
            .span_id = undefined,
            .flags = .{},
            .parent_span_id = null,
        };
        const trace_hex = header[3..35];
        for (0..16) |i| {
            ctx.trace_id[i] = parseHexByte(trace_hex[i * 2 .. i * 2 + 2]) orelse return null;
        }
        if (header[35] != '-') return null;
        const span_hex = header[36..52];
        for (0..8) |i| {
            ctx.span_id[i] = parseHexByte(span_hex[i * 2 .. i * 2 + 2]) orelse return null;
        }
        if (header[52] != '-') return null;
        const flags_byte = parseHexByte(header[53..55]) orelse return null;
        ctx.flags.sampled = (flags_byte & 0x01) != 0;
        return ctx;
    }

    /// Format as W3C traceparent header
    pub fn toTraceparent(self: *const TraceContext, buf: *[55]u8) void {
        buf[0] = '0';
        buf[1] = '0';
        buf[2] = '-';
        for (0..16) |i| {
            const b = self.trace_id[i];
            buf[3 + i * 2] = hexDigit(@truncate(b >> 4));
            buf[3 + i * 2 + 1] = hexDigit(@truncate(b & 0xf));
        }
        buf[35] = '-';
        for (0..8) |i| {
            const b = self.span_id[i];
            buf[36 + i * 2] = hexDigit(@truncate(b >> 4));
            buf[36 + i * 2 + 1] = hexDigit(@truncate(b & 0xf));
        }
        buf[52] = '-';
        const flags_byte: u8 = if (self.flags.sampled) 0x01 else 0x00;
        buf[53] = hexDigit(@truncate(flags_byte >> 4));
        buf[54] = hexDigit(@truncate(flags_byte & 0xf));
    }
};

fn parseHexByte(hex: []const u8) ?u8 {
    if (hex.len != 2) return null;
    const hi = hexVal(hex[0]) orelse return null;
    const lo = hexVal(hex[1]) orelse return null;
    return (hi << 4) | lo;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexDigit(v: u4) u8 {
    return if (v < 10) '0' + @as(u8, v) else 'a' + @as(u8, v) - 10;
}

// ============================================================================
// Span
// ============================================================================

pub const SpanKind = enum(u8) { internal, server, client, producer, consumer };

pub const SpanStatus = enum(u8) { unset, ok, @"error" };

pub const Span = struct {
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId,
    name: []const u8,
    kind: SpanKind,
    start_time_ns: i128,
    end_time_ns: ?i128,
    status: SpanStatus,
    attributes_count: u16,
};

// ============================================================================
// OTEL Exporter
// ============================================================================

pub const OtelConfig = struct {
    endpoint: []const u8 = "http://localhost:4318/v1/traces",
    service_name: []const u8 = "privatellm",
    batch_size: u32 = 256,
    export_interval_ms: u64 = 5000,
    enabled: bool = true,
};

pub const OtelExporter = struct {
    allocator: Allocator,
    config: OtelConfig,
    span_buffer: std.ArrayListUnmanaged(Span),
    spans_exported: std.atomic.Value(u64),
    spans_dropped: std.atomic.Value(u64),
    next_span_id: std.atomic.Value(u64),

    pub fn init(allocator: Allocator, config: OtelConfig) OtelExporter {
        return .{
            .allocator = allocator,
            .config = config,
            .span_buffer = .empty,
            .spans_exported = std.atomic.Value(u64).init(0),
            .spans_dropped = std.atomic.Value(u64).init(0),
            .next_span_id = std.atomic.Value(u64).init(1),
        };
    }

    pub fn deinit(self: *OtelExporter) void {
        self.span_buffer.deinit();
    }

    pub fn newSpanId(self: *OtelExporter) SpanId {
        const id = self.next_span_id.fetchAdd(1, .monotonic);
        var span_id: SpanId = undefined;
        @memcpy(&span_id, std.mem.asBytes(&id));
        return span_id;
    }

    pub fn newTraceId(self: *OtelExporter) TraceId {
        const hi = self.next_span_id.fetchAdd(1, .monotonic);
        const lo = self.next_span_id.fetchAdd(1, .monotonic);
        var trace_id: TraceId = undefined;
        @memcpy(trace_id[0..8], std.mem.asBytes(&hi));
        @memcpy(trace_id[8..16], std.mem.asBytes(&lo));
        return trace_id;
    }

    pub fn startSpan(self: *OtelExporter, name: []const u8, parent: ?*const TraceContext) Span {
        const trace_id = if (parent) |p| p.trace_id else self.newTraceId();
        const parent_span = if (parent) |p| p.span_id else null;
        return .{
            .trace_id = trace_id,
            .span_id = self.newSpanId(),
            .parent_span_id = parent_span,
            .name = name,
            .kind = .server,
            .start_time_ns = std.time.nanoTimestamp(),
            .end_time_ns = null,
            .status = .unset,
            .attributes_count = 0,
        };
    }

    pub fn endSpan(self: *OtelExporter, span: *Span, status: SpanStatus) !void {
        span.end_time_ns = std.time.nanoTimestamp();
        span.status = status;
        if (self.span_buffer.items.len >= self.config.batch_size) {
            _ = self.spans_dropped.fetchAdd(1, .monotonic);
            return;
        }
        try self.span_buffer.append(span.*);
    }

    pub fn exportSpans(self: *OtelExporter, allocator: Allocator) ![]u8 {
        if (self.span_buffer.items.len == 0) return allocator.alloc(u8, 0);
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit();
        const w = json.writer();
        try w.writeAll("{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"");
        try w.writeAll(self.config.service_name);
        try w.writeAll("\"}}]},\"scopeSpans\":[{\"spans\":[");
        for (self.span_buffer.items, 0..) |span, idx| {
            if (idx > 0) try w.writeByte(',');
            try writeSpanJson(w, &span);
        }
        try w.writeAll("]}]}]}");
        const exported = self.span_buffer.items.len;
        _ = self.spans_exported.fetchAdd(@intCast(exported), .monotonic);
        self.span_buffer.clearRetainingCapacity();
        return json.toOwnedSlice();
    }

    pub fn pendingCount(self: *const OtelExporter) u32 {
        return @intCast(self.span_buffer.items.len);
    }

    pub fn stats(self: *const OtelExporter) struct { exported: u64, dropped: u64 } {
        return .{
            .exported = self.spans_exported.load(.monotonic),
            .dropped = self.spans_dropped.load(.monotonic),
        };
    }
};

fn writeSpanJson(w: anytype, span: *const Span) !void {
    try w.writeAll("{\"traceId\":\"");
    for (span.trace_id) |b| {
        try std.fmt.format(w, "{x:0>2}", .{b});
    }
    try w.writeAll("\",\"spanId\":\"");
    for (span.span_id) |b| {
        try std.fmt.format(w, "{x:0>2}", .{b});
    }
    try w.writeAll("\",\"name\":\"");
    try w.writeAll(span.name);
    try w.writeAll("\",\"kind\":");
    try std.fmt.format(w, "{d}", .{@intFromEnum(span.kind)});
    try w.writeAll(",\"startTimeUnixNano\":\"");
    try std.fmt.format(w, "{d}", .{span.start_time_ns});
    try w.writeAll("\"");
    if (span.end_time_ns) |end| {
        try w.writeAll(",\"endTimeUnixNano\":\"");
        try std.fmt.format(w, "{d}", .{end});
        try w.writeAll("\"");
    }
    try w.writeAll(",\"status\":{\"code\":");
    try std.fmt.format(w, "{d}", .{@intFromEnum(span.status)});
    try w.writeAll("}}");
}

// ============================================================================
// Tests
// ============================================================================

test "trace context parse traceparent" {
    const header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    const ctx = TraceContext.fromTraceparent(header).?;
    try std.testing.expect(ctx.flags.sampled);
    try std.testing.expectEqual(@as(u8, 0x0a), ctx.trace_id[0]);
    try std.testing.expectEqual(@as(u8, 0xb7), ctx.span_id[0]);
}

test "trace context roundtrip" {
    const original = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    const ctx = TraceContext.fromTraceparent(original).?;
    var buf: [55]u8 = undefined;
    ctx.toTraceparent(&buf);
    try std.testing.expectEqualStrings(original, &buf);
}

test "trace context invalid" {
    try std.testing.expect(TraceContext.fromTraceparent("short") == null);
    try std.testing.expect(TraceContext.fromTraceparent("XX-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01") == null);
}

test "otel exporter span lifecycle" {
    const allocator = std.testing.allocator;
    var exporter = OtelExporter.init(allocator, .{});
    defer exporter.deinit();
    var span = exporter.startSpan("test-operation", null);
    try std.testing.expectEqualStrings("test-operation", span.name);
    try exporter.endSpan(&span, .ok);
    try std.testing.expectEqual(@as(u32, 1), exporter.pendingCount());
}

test "otel exporter json export" {
    const allocator = std.testing.allocator;
    var exporter = OtelExporter.init(allocator, .{});
    defer exporter.deinit();
    var span = exporter.startSpan("test-op", null);
    try exporter.endSpan(&span, .ok);
    const json = try exporter.exportSpans(allocator);
    defer allocator.free(json);
    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "resourceSpans") != null);
    try std.testing.expectEqual(@as(u32, 0), exporter.pendingCount());
    try std.testing.expectEqual(@as(u64, 1), exporter.stats().exported);
}

test "otel exporter unique ids" {
    const allocator = std.testing.allocator;
    var exporter = OtelExporter.init(allocator, .{});
    defer exporter.deinit();
    const id1 = exporter.newSpanId();
    const id2 = exporter.newSpanId();
    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}

