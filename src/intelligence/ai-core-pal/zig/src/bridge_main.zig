const std = @import("std");
const bridge = @import("mcp_openai_bridge.zig");
const mcp = @import("mcp/mcp.zig");
const anwid = @import("anwid/server.zig");

var global_handler: ?bridge.OpenAiBridge = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tools = mcp.getTools();
    global_handler = bridge.OpenAiBridge.init(allocator, &tools);

    var server = try anwid.Server.init(allocator, handleHttp);
    defer server.deinit();

    const address = try std.net.Address.parseIp4("0.0.0.0", 8080);
    try server.listen(address);
}

fn handleHttp(allocator: std.mem.Allocator, req: anwid.Request) anyerror!anwid.Response {
    _ = allocator;
    if (global_handler) |*h| {
        const response_body = try h.handleRequest(req.body);
        return anwid.Response{
            .status = 200,
            .body = response_body,
        };
    }
    return anwid.Response{
        .status = 500,
        .body = "Bridge handler not initialized",
    };
}