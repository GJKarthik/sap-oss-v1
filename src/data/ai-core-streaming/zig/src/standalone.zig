//! BDC AIPrompt Streaming - Standalone Entry Point
//! Runs the broker with local metadata and simplified configuration

const std = @import("std");
const types = @import("connector_types");
const broker = @import("broker");

const log = std.log.scoped(.aiprompt_standalone);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.info("Starting BDC AIPrompt Streaming in Standalone Mode", .{});

    // Initialize and start broker with standalone options
    var broker_instance = try broker.Broker.init(allocator, .{
        .cluster_name = "standalone",
    });
    defer broker_instance.deinit();

    // Start the broker
    try broker_instance.start();

    log.info("Standalone broker started successfully", .{});
    
    // Wait for shutdown signal
    broker_instance.waitForShutdown();

    log.info("Standalone broker shutdown complete", .{});
}
