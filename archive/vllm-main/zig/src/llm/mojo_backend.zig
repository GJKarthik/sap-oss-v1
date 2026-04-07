//! Mojo LLM Backend
//!
//! Direct LLM inference using the Mojo-based engine (libpllm).
//! This replaces llama.cpp with our custom Mojo kernels for Q4_K_M inference.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mojo_bridge = @import("../mojo_bridge.zig");
const llm_backend = @import("backend.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;

/// Backend mode selection
pub const BackendMode = enum {
    /// Use Mojo inference engine directly (default)
    mojo,
    /// Use HTTP backend (llama.cpp or other OpenAI-compatible server)
    http,
    /// Auto-detect: try Mojo first, fall back to HTTP
    auto,
};

/// Backend configuration
pub const BackendConfig = struct {
    mode: BackendMode = .auto,
    /// Path to libpllm library (for Mojo mode)
    mojo_lib_path: ?[]const u8 = null,
    /// HTTP backend URL (for HTTP mode)
    http_url: ?[]const u8 = null,
    /// GGUF model path
    model_path: ?[]const u8 = null,
    /// Model preset (llama_1b, phi2, etc.)
    model_preset: ?[]const u8 = null,
};

/// Generation request
pub const GenerateRequest = struct {
    prompt: []const u8,
    max_tokens: u32 = 256,
    temperature: f32 = 0.7,
    top_p: f32 = 0.9,
    stop_sequences: ?[]const []const u8 = null,
};

/// Generation response
pub const GenerateResponse = struct {
    text: []const u8,
    tokens_generated: u32,
    finish_reason: FinishReason,

    pub const FinishReason = enum {
        stop,
        length,
        eos,
    };
};

/// Unified LLM Backend
pub const Backend = struct {
    allocator: Allocator,
    config: BackendConfig,
    mojo_lib: ?mojo_bridge.MojoLibrary,
    mojo_model: ?mojo_bridge.MojoModel,
    tokenizer: ?Tokenizer,
    http_client: ?llm_backend.Client,

    const Self = @This();

    pub fn init(allocator: Allocator, config: BackendConfig) !Self {
        var self = Self{
            .allocator = allocator,
            .config = config,
            .mojo_lib = null,
            .mojo_model = null,
            .tokenizer = null,
            .http_client = null,
        };

        if ((config.mode == .http or config.mode == .auto) and config.http_url != null) {
            self.http_client = try llm_backend.Client.init(allocator, config.http_url.?);
        }

        // Try to initialize Mojo backend
        if (config.mode == .mojo or config.mode == .auto) {
            self.initMojo() catch |err| {
                if (config.mode == .mojo) {
                    return err;
                }
                // Auto mode: fall back to HTTP
                std.log.warn("Mojo backend unavailable, falling back to HTTP: {}", .{err});
            };
        }

        return self;
    }

    fn initMojo(self: *Self) !void {
        // Load Mojo library
        self.mojo_lib = try mojo_bridge.MojoLibrary.load(self.config.mojo_lib_path);

        // Create model based on preset
        if (self.config.model_preset) |preset| {
            if (std.mem.eql(u8, preset, "llama_1b")) {
                self.mojo_model = try mojo_bridge.MojoModel.initLlama1b(&self.mojo_lib.?);
            } else if (std.mem.eql(u8, preset, "phi2")) {
                self.mojo_model = try mojo_bridge.MojoModel.initPhi2(&self.mojo_lib.?);
            } else {
                // Default to llama_1b
                self.mojo_model = try mojo_bridge.MojoModel.initLlama1b(&self.mojo_lib.?);
            }
        } else {
            // Default model
            self.mojo_model = try mojo_bridge.MojoModel.initLlama1b(&self.mojo_lib.?);
        }

        // Initialize tokenizer
        self.tokenizer = Tokenizer.init(self.allocator);

        // Load tokenizer from GGUF if model is available
        if (self.config.model_path) |path| {
            var loader = try @import("../gguf_loader.zig").GGUFLoader.init(self.allocator, path);
            defer loader.deinit();
            if (loader.getVocab()) |vocab_tokens| {
                for (vocab_tokens, 0..) |tok_str, i| {
                    try self.tokenizer.?.addToken(tok_str, @intCast(i));
                }
            } else {
                std.log.warn("No vocab found in GGUF model: {s}", .{path});
            }
        }

        std.log.info("Mojo backend initialized: vocab={}, layers={}, memory={d:.1}MB", .{
            self.mojo_model.?.vocabSize(),
            self.mojo_model.?.numLayers(),
            self.mojo_model.?.memoryMb(),
        });
    }

    pub fn deinit(self: *Self) void {
        if (self.tokenizer) |*tok| {
            tok.deinit();
        }
        if (self.mojo_model) |*model| {
            model.deinit();
        }
        if (self.mojo_lib) |*lib| {
            lib.close();
        }
        if (self.http_client) |*client| {
            client.deinit();
        }
    }

    pub fn isReady(self: Self) bool {
        return self.mojo_model != null or self.http_client != null;
    }

    /// Generate text from prompt
    pub fn generate(self: *Self, request: GenerateRequest) !GenerateResponse {
        if (self.mojo_model) |*model| {
            return self.generateMojo(model, request);
        }

        // Fallback to HTTP backend
        return self.generateHttp(request);
    }

    fn generateMojo(
        self: *Self,
        model: *mojo_bridge.MojoModel,
        request: GenerateRequest,
    ) !GenerateResponse {
        // Tokenize input
        const input_tokens_u32 = try self.tokenizer.?.encode(request.prompt);
        defer self.allocator.free(input_tokens_u32);

        // Cast to i32 for MojoModel
        var input_tokens = try self.allocator.alloc(i32, input_tokens_u32.len);
        defer self.allocator.free(input_tokens);
        for (input_tokens_u32, 0..) |tok, i| input_tokens[i] = @intCast(tok);

        // Allocate output buffer
        const max_output_len = input_tokens.len + request.max_tokens;
        var output_tokens = try self.allocator.alloc(i32, max_output_len);
        defer self.allocator.free(output_tokens);

        // Generate
        const gen_config = mojo_bridge.GenerationConfig{
            .max_new_tokens = request.max_tokens,
            .temperature = request.temperature,
            .top_p = request.top_p,
            .eos_token_id = 2, // Default EOS
        };

        const total_tokens = try model.generate(input_tokens, output_tokens, gen_config);

        // Decode output (skip input tokens)
        const new_tokens = output_tokens[input_tokens.len..total_tokens];

        var new_tokens_u32 = try self.allocator.alloc(u32, new_tokens.len);
        defer self.allocator.free(new_tokens_u32);
        for (new_tokens, 0..) |tok, i| new_tokens_u32[i] = @intCast(tok);

        const text = try self.tokenizer.?.decode(new_tokens_u32);

        // Check stop sequences
        var finish_reason: GenerateResponse.FinishReason = .length;
        if (request.stop_sequences) |stops| {
            for (stops) |stop| {
                if (std.mem.indexOf(u8, text, stop)) |_| {
                    finish_reason = .stop;
                    break;
                }
            }
        }

        // Check if we hit EOS
        if (total_tokens < max_output_len and
            total_tokens > input_tokens.len and
            output_tokens[total_tokens - 1] == 2)
        {
            finish_reason = .eos;
        }

        return GenerateResponse{
            .text = text,
            .tokens_generated = @intCast(total_tokens - input_tokens.len),
            .finish_reason = finish_reason,
        };
    }

    fn generateHttp(self: *Self, request: GenerateRequest) !GenerateResponse {
        var client = self.http_client orelse return error.HttpBackendNotConfigured;

        const req_body = try std.json.stringifyAlloc(self.allocator, .{
            .prompt = request.prompt,
            .max_tokens = request.max_tokens,
            .temperature = request.temperature,
            .top_p = request.top_p,
            .stop = request.stop_sequences,
        }, .{});
        defer self.allocator.free(req_body);

        const res_body = try client.completions(req_body);
        defer self.allocator.free(res_body);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, res_body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidHttpResponse;

        const choices = root.object.get("choices") orelse return error.InvalidHttpResponse;
        if (choices != .array or choices.array.items.len == 0) return error.InvalidHttpResponse;

        const first_choice = choices.array.items[0];
        if (first_choice != .object) return error.InvalidHttpResponse;

        const text_val = first_choice.object.get("text") orelse return error.InvalidHttpResponse;
        if (text_val != .string) return error.InvalidHttpResponse;

        const text = try self.allocator.dupe(u8, text_val.string);

        return GenerateResponse{
            .text = text,
            .tokens_generated = 0, // In HTTP mode, we might not get exact token counts back easily without parsing usage
            .finish_reason = .stop,
        };
    }

    /// Get model information
    pub fn modelInfo(self: Self) ?ModelInfo {
        if (self.mojo_model) |model| {
            return ModelInfo{
                .name = if (self.config.model_preset) |p| p else "unknown",
                .vocab_size = model.vocabSize(),
                .embed_dim = model.embedDim(),
                .num_layers = model.numLayers(),
                .max_seq_len = model.maxSeqLen(),
                .memory_mb = model.memoryMb(),
            };
        }
        return null;
    }
};

pub const ModelInfo = struct {
    name: []const u8,
    vocab_size: u32,
    embed_dim: u32,
    num_layers: u32,
    max_seq_len: u32,
    memory_mb: f32,
};

// =============================================================================
// OpenAI-Compatible API Layer
// =============================================================================

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    stop: ?[]const []const u8 = null,
};

pub const ChatResponse = struct {
    id: []const u8,
    object: []const u8,
    model: []const u8,
    choices: []const Choice,

    pub const Choice = struct {
        index: u32,
        message: ChatMessage,
        finish_reason: []const u8,
    };
};

/// Convert chat messages to prompt
pub fn chatToPrompt(
    allocator: Allocator,
    messages: []const ChatMessage,
    template: TemplateFamily,
) ![]const u8 {
    var prompt: std.ArrayListUnmanaged(u8) = .empty;
    var writer = prompt.writer(allocator);

    for (messages) |msg| {
        switch (template) {
            .chatml => {
                try writer.print("<|im_start|>{s}\n{s}<|im_end|>\n", .{ msg.role, msg.content });
            },
            .llama3 => {
                try writer.print("<|start_header_id|>{s}<|end_header_id|>\n\n{s}<|eot_id|>", .{ msg.role, msg.content });
            },
            .phi => {
                try writer.print("<|{s}|>\n{s}<|end|>\n", .{ msg.role, msg.content });
            },
            else => {
                try writer.print("[{s}]\n{s}\n", .{ msg.role, msg.content });
            },
        }
    }

    // Add assistant prompt
    switch (template) {
        .chatml => try writer.writeAll("<|im_start|>assistant\n"),
        .llama3 => try writer.writeAll("<|start_header_id|>assistant<|end_header_id|>\n\n"),
        .phi => try writer.writeAll("<|assistant|>\n"),
        else => try writer.writeAll("[assistant]\n"),
    }

    return try prompt.toOwnedSlice(allocator);
}

pub const TemplateFamily = enum {
    chatml,
    llama3,
    openchat,
    mistral,
    phi,
};

// =============================================================================
// Tests
// =============================================================================

test "backend initialization" {
    const allocator = std.testing.allocator;

    var backend = Backend.init(allocator, .{
        .mode = .auto,
    }) catch |err| {
        // Expected to fail if Mojo library not built
        std.debug.print("Backend init failed (expected): {}\n", .{err});
        return;
    };
    defer backend.deinit();

    try std.testing.expect(backend.isReady());
}

test "tokenizer initialized successfully" {
    const allocator = std.testing.allocator;

    var tok = Tokenizer.init(allocator);
    defer tok.deinit();

    // With the unified tokenizer, it reserves 4 tokens natively.
    try std.testing.expectEqual(@as(usize, 4), tok.vocabSize());
}

test "chat to prompt" {
    const allocator = std.testing.allocator;

    const messages = [_]ChatMessage{
        .{ .role = "user", .content = "Hello" },
    };

    const prompt = try chatToPrompt(allocator, &messages, .chatml);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "<|im_start|>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Hello") != null);
}
