const std = @import("std");

pub const WireType = enum(u3) {
    Varint = 0,
    Fixed64 = 1,
    LengthDelimited = 2,
    StartGroup = 3,
    EndGroup = 4,
    Fixed32 = 5,
};

pub fn writeVarint(writer: anytype, value: anytype) !void {
    var v = @as(u64, @intCast(value));
    while (v >= 0x80) {
        try writer.writeByte(@as(u8, @intCast(v & 0x7f)) | 0x80);
        v >>= 7;
    }
    try writer.writeByte(@as(u8, @intCast(v)));
}

pub fn readVarint(reader: anytype) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = try reader.readByte();
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
        if (shift >= 64) return error.MalformedVarint;
    }
    return value;
}

/// Read varint from a byte slice with an index pointer
pub fn readVarintFromSlice(data: []const u8, idx: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (idx.* < data.len) {
        const byte = data[idx.*];
        idx.* += 1;
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        shift += 7;
        if (shift >= 64) return error.MalformedVarint;
    }
    return error.InsufficientData;
}

pub fn writeTag(writer: anytype, field_number: u32, wire_type: WireType) !void {
    try writeVarint(writer, (field_number << 3) | @intFromEnum(wire_type));
}

pub fn writeString(writer: anytype, field_number: u32, value: []const u8) !void {
    try writeTag(writer, field_number, .LengthDelimited);
    try writeVarint(writer, value.len);
    try writer.writeAll(value);
}

pub fn writeUint32(writer: anytype, field_number: u32, value: u32) !void {
    try writeTag(writer, field_number, .Varint);
    try writeVarint(writer, value);
}

pub fn writeUint64(writer: anytype, field_number: u32, value: u64) !void {
    try writeTag(writer, field_number, .Varint);
    try writeVarint(writer, value);
}

pub fn writeBool(writer: anytype, field_number: u32, value: bool) !void {
    try writeTag(writer, field_number, .Varint);
    try writer.writeByte(if (value) 1 else 0);
}

pub fn writeEnum(writer: anytype, field_number: u32, value: anytype) !void {
    try writeTag(writer, field_number, .Varint);
    try writeVarint(writer, @intFromEnum(value));
}

pub fn readTag(reader: anytype) !struct { field_number: u32, wire_type: WireType } {
    const tag = try readVarint(reader);
    return .{
        .field_number = @as(u32, @intCast(tag >> 3)),
        .wire_type = @enumFromInt(@as(u3, @intCast(tag & 0x07))),
    };
}

pub fn skipValue(reader: anytype, wire_type: WireType) !void {
    switch (wire_type) {
        .Varint => _ = try readVarint(reader),
        .Fixed64 => try reader.skipBytes(8),
        .LengthDelimited => {
            const len = try readVarint(reader);
            try reader.skipBytes(len);
        },
        .Fixed32 => try reader.skipBytes(4),
        else => return error.UnsupportedWireType,
    }
}
