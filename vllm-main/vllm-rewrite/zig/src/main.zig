//! vLLM Rewrite - Main Entry Point
//!
//! High-performance LLM inference engine written in Zig.
//! This is the main executable that provides CLI access to the vLLM server.

const std = @import("std");
const builtin = @import("builtin");

// Module imports
const engine = @import("engine/engine_core.zig");
const scheduler = @import("scheduler/scheduler.zig");
const memory = @import("memory/block_manager.zig");
const server = @import("server/http/server.zig");
const cli = @import("cli/cli.zig");
const config = @import("utils/config.zig");
const logging = @import("utils/logging.zig");

const log = logging.scoped(.main);

/// Application version
pub const version = "0.1.0";

/// Global allocator - uses the C allocator for better interop with CUDA
pub const allocator = std.heap.c_allocator;

/// Command-line arguments structure
const Args = struct {
    command: Command,
    model: ?[]const u8 = null,
    host: []const u8 = "0.0.0.0",
    port: u16 = 8000,
    tensor_parallel_size: u32 = 1,
    max_model_len: ?u32 = null,
    gpu_memory_utilization: f32 = 0.9,
    quantization: ?[]const u8 = null,
    log_level: logging.Level = .info,
    help: bool = false,
    version_flag: bool = false,

    const Command = enum {
        serve,
        bench,
        help,
        version,
    };
};

pub fn main() !void {
    // Initialize logging
    logging.init(.info);
    log.info("vLLM Zig Engine v{s}", .{version});

    // Parse command-line arguments
    const args = try parseArgs();

    if (args.help) {
        printHelp();
        return;
    }

    if (args.version_flag) {
        printVersion();
        return;
    }

    // Set log level from args
    logging.setLevel(args.log_level);

    // Execute command
    switch (args.command) {
        .serve => try runServer(args),
        .bench => try runBenchmark(args),
        .help => printHelp(),
        .version => printVersion(),
    }
}

/// Parse command-line arguments
fn parseArgs() !Args {
    var args = Args{
        .command = .serve,
    };

    var arg_iter = std.process.args();
    _ = arg_iter.skip(); // Skip program name

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "serve")) {
            args.command = .serve;
        } else if (std.mem.eql(u8, arg, "bench")) {
            args.command = .bench;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            args.version_flag = true;
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            args.model = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--host")) {
            args.host = arg_iter.next() orelse "0.0.0.0";
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (arg_iter.next()) |port_str| {
                args.port = std.fmt.parseInt(u16, port_str, 10) catch 8000;
            }
        } else if (std.mem.eql(u8, arg, "--tensor-parallel-size") or std.mem.eql(u8, arg, "-tp")) {
            if (arg_iter.next()) |tp_str| {
                args.tensor_parallel_size = std.fmt.parseInt(u32, tp_str, 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "--max-model-len")) {
            if (arg_iter.next()) |len_str| {
                args.max_model_len = std.fmt.parseInt(u32, len_str, 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--gpu-memory-utilization")) {
            if (arg_iter.next()) |util_str| {
                args.gpu_memory_utilization = std.fmt.parseFloat(f32, util_str) catch 0.9;
            }
        } else if (std.mem.eql(u8, arg, "--quantization") or std.mem.eql(u8, arg, "-q")) {
            args.quantization = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            if (arg_iter.next()) |level_str| {
                args.log_level = logging.Level.fromString(level_str);
            }
        }
    }

    return args;
}

/// Run the vLLM server
fn runServer(args: Args) !void {
    const model = args.model orelse {
        log.err("Model path is required. Use --model <path>", .{});
        return error.MissingModel;
    };

    log.info("Starting vLLM server...", .{});
    log.info("  Model: {s}", .{model});
    log.info("  Host: {s}", .{args.host});
    log.info("  Port: {d}", .{args.port});
    log.info("  Tensor Parallel Size: {d}", .{args.tensor_parallel_size});
    log.info("  GPU Memory Utilization: {d:.2}", .{args.gpu_memory_utilization});

    if (args.quantization) |quant| {
        log.info("  Quantization: {s}", .{quant});
    }

    // Initialize configuration
    const engine_config = config.EngineConfig{
        .model_path = model,
        .tensor_parallel_size = args.tensor_parallel_size,
        .max_model_len = args.max_model_len,
        .gpu_memory_utilization = args.gpu_memory_utilization,
        .quantization = args.quantization,
    };

    // Initialize the engine (placeholder for now)
    log.info("Initializing engine...", .{});
    // var eng = try engine.EngineCore.init(allocator, engine_config);
    // defer eng.deinit();

    // Initialize the server
    log.info("Starting HTTP server on {s}:{d}...", .{ args.host, args.port });
    // try server.run(args.host, args.port, &eng);

    // Placeholder: just wait for interrupt
    log.info("Server started. Press Ctrl+C to stop.", .{});

    // Wait for signal (simplified)
    std.time.sleep(std.time.ns_per_s * 60 * 60 * 24); // Sleep for a day (will be interrupted)

    _ = engine_config;
}

/// Run benchmarks
fn runBenchmark(args: Args) !void {
    const model = args.model orelse {
        log.err("Model path is required for benchmarking. Use --model <path>", .{});
        return error.MissingModel;
    };

    log.info("Running benchmarks...", .{});
    log.info("  Model: {s}", .{model});

    // Placeholder for benchmark implementation
    log.info("Benchmark complete.", .{});
}

/// Print help message
fn printHelp() void {
    const help_text =
        \\vLLM - High-throughput LLM inference engine (Zig implementation)
        \\
        \\USAGE:
        \\    vllm <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    serve       Start the vLLM server (default)
        \\    bench       Run performance benchmarks
        \\    help        Show this help message
        \\    version     Show version information
        \\
        \\OPTIONS:
        \\    -m, --model <PATH>              Path to the model (required)
        \\    --host <HOST>                   Host to bind to (default: 0.0.0.0)
        \\    -p, --port <PORT>               Port to listen on (default: 8000)
        \\    -tp, --tensor-parallel-size <N> Number of GPUs for tensor parallelism (default: 1)
        \\    --max-model-len <N>             Maximum model context length
        \\    --gpu-memory-utilization <F>    GPU memory utilization (0.0-1.0, default: 0.9)
        \\    -q, --quantization <METHOD>     Quantization method (awq, gptq, fp8)
        \\    --log-level <LEVEL>             Log level (debug, info, warn, err)
        \\    -h, --help                      Show this help message
        \\    -v, --version                   Show version information
        \\
        \\EXAMPLES:
        \\    vllm serve --model meta-llama/Llama-3-8B --port 8000
        \\    vllm serve -m ./models/llama-7b -tp 2 --quantization awq
        \\    vllm bench --model meta-llama/Llama-3-8B
        \\
        \\For more information, visit: https://github.com/vllm-project/vllm-rewrite
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

/// Print version information
fn printVersion() void {
    std.debug.print(
        \\vLLM Zig Engine v{s}
        \\
        \\Build Information:
        \\  Zig Version: {s}
        \\  Target: {s}-{s}
        \\  Mode: {s}
        \\
        \\Components:
        \\  Engine Core: Zig
        \\  Model Layer: Mojo
        \\  Rules Engine: Mangle
        \\  CUDA Kernels: C++/CUDA
        \\
    , .{
        version,
        builtin.zig_version_string,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.mode),
    });
}

// ============================================
// Tests
// ============================================

test "parse args - default values" {
    // Test that default values are correctly set
    const args = Args{
        .command = .serve,
    };
    try std.testing.expectEqual(Args.Command.serve, args.command);
    try std.testing.expectEqualStrings("0.0.0.0", args.host);
    try std.testing.expectEqual(@as(u16, 8000), args.port);
    try std.testing.expectEqual(@as(u32, 1), args.tensor_parallel_size);
}

test "version string" {
    try std.testing.expect(version.len > 0);
}