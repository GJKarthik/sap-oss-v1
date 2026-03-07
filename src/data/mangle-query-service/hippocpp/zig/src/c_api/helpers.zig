//! C API helper utilities.

const std = @import("std");

/// Allocate a NUL-terminated C string from a Zig string slice.
/// Caller owns the memory and should free it with `freeOwnedCString`.
pub fn convertToOwnedCString(str: []const u8) ?[*:0]u8 {
    const buf = std.heap.c_allocator.alloc(u8, str.len + 1) catch return null;
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return @ptrCast(buf.ptr);
}

pub fn freeOwnedCString(c_str: [*:0]u8) void {
    const bytes = std.mem.span(c_str);
    std.heap.c_allocator.free(bytes.ptr[0 .. bytes.len + 1]);
}

test "owned c string roundtrip" {
    const c_str = convertToOwnedCString("hippocpp") orelse return error.OutOfMemory;
    defer freeOwnedCString(c_str);

    const back = std.mem.span(c_str);
    try std.testing.expectEqualStrings("hippocpp", back);
}
