//! Request Validation Middleware
//!
//! Validates incoming API requests before processing.
//! Ensures request parameters are within acceptable bounds.
//!
//! Features:
//! - Schema validation
//! - Parameter bounds checking
//! - Custom validators
//! - Detailed error messages

const std = @import("std");
const log = @import("../../utils/logging.zig");
const errors = @import("../../utils/errors.zig");

// ==============================================
// Validation Configuration
// ==============================================

pub const ValidationConfig = struct {
    /// Maximum prompt length (characters)
    max_prompt_length: usize = 100_000,
    
    /// Maximum number of tokens to generate
    max_max_tokens: u32 = 16384,
    
    /// Minimum temperature
    min_temperature: f32 = 0.0,
    
    /// Maximum temperature
    max_temperature: f32 = 2.0,
    
    /// Minimum top_p
    min_top_p: f32 = 0.0,
    
    /// Maximum top_p
    max_top_p: f32 = 1.0,
    
    /// Minimum top_k
    min_top_k: i32 = -1,  // -1 means disabled
    
    /// Maximum top_k
    max_top_k: i32 = 1000,
    
    /// Maximum number of stop sequences
    max_stop_sequences: usize = 16,
    
    /// Maximum stop sequence length
    max_stop_length: usize = 64,
    
    /// Maximum number of log probs
    max_logprobs: u32 = 20,
    
    /// Allowed models (empty = all)
    allowed_models: []const []const u8 = &.{},
    
    /// Maximum best_of
    max_best_of: u32 = 20,
    
    /// Maximum n (completions)
    max_n: u32 = 128,
};

// ==============================================
// Validation Errors
// ==============================================

pub const ValidationResult = struct {
    valid: bool,
    field: ?[]const u8 = null,
    message: ?[]const u8 = null,
    
    pub fn ok() ValidationResult {
        return ValidationResult{ .valid = true };
    }
    
    pub fn err(field: []const u8, message: []const u8) ValidationResult {
        return ValidationResult{
            .valid = false,
            .field = field,
            .message = message,
        };
    }
};

// ==============================================
// Chat Completion Request
// ==============================================

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
};

pub const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?i32 = null,
    n: ?u32 = null,
    max_tokens: ?u32 = null,
    stop: ?[]const []const u8 = null,
    stream: ?bool = null,
    presence_penalty: ?f32 = null,
    frequency_penalty: ?f32 = null,
    logprobs: ?bool = null,
    top_logprobs: ?u32 = null,
    user: ?[]const u8 = null,
};

// ==============================================
// Completion Request
// ==============================================

pub const CompletionRequest = struct {
    model: []const u8,
    prompt: []const u8,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?i32 = null,
    n: ?u32 = null,
    max_tokens: ?u32 = null,
    stop: ?[]const []const u8 = null,
    stream: ?bool = null,
    logprobs: ?u32 = null,
    echo: ?bool = null,
    best_of: ?u32 = null,
    user: ?[]const u8 = null,
};

// ==============================================
// Validator
// ==============================================

pub const RequestValidator = struct {
    config: ValidationConfig,
    
    pub fn init(config: ValidationConfig) RequestValidator {
        return RequestValidator{ .config = config };
    }
    
    /// Validate chat completion request
    pub fn validateChatCompletion(self: *RequestValidator, req: ChatCompletionRequest) ValidationResult {
        // Validate model
        if (req.model.len == 0) {
            return ValidationResult.err("model", "Model is required");
        }
        
        if (self.config.allowed_models.len > 0) {
            var found = false;
            for (self.config.allowed_models) |m| {
                if (std.mem.eql(u8, m, req.model)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return ValidationResult.err("model", "Model not allowed");
            }
        }
        
        // Validate messages
        if (req.messages.len == 0) {
            return ValidationResult.err("messages", "At least one message is required");
        }
        
        var total_length: usize = 0;
        for (req.messages) |msg| {
            // Validate role
            if (!isValidRole(msg.role)) {
                return ValidationResult.err("messages.role", "Invalid role. Must be system, user, or assistant");
            }
            
            // Validate content length
            total_length += msg.content.len;
            if (total_length > self.config.max_prompt_length) {
                return ValidationResult.err("messages", "Total message content exceeds maximum length");
            }
        }
        
        // Validate temperature
        if (req.temperature) |temp| {
            if (temp < self.config.min_temperature or temp > self.config.max_temperature) {
                return ValidationResult.err("temperature", "Temperature must be between 0 and 2");
            }
        }
        
        // Validate top_p
        if (req.top_p) |p| {
            if (p < self.config.min_top_p or p > self.config.max_top_p) {
                return ValidationResult.err("top_p", "top_p must be between 0 and 1");
            }
        }
        
        // Validate top_k
        if (req.top_k) |k| {
            if (k < self.config.min_top_k or k > self.config.max_top_k) {
                return ValidationResult.err("top_k", "top_k must be between -1 and 1000");
            }
        }
        
        // Validate n
        if (req.n) |n| {
            if (n == 0 or n > self.config.max_n) {
                return ValidationResult.err("n", "n must be between 1 and 128");
            }
        }
        
        // Validate max_tokens
        if (req.max_tokens) |tokens| {
            if (tokens == 0 or tokens > self.config.max_max_tokens) {
                return ValidationResult.err("max_tokens", "max_tokens must be between 1 and 16384");
            }
        }
        
        // Validate stop sequences
        if (req.stop) |stop| {
            if (stop.len > self.config.max_stop_sequences) {
                return ValidationResult.err("stop", "Too many stop sequences");
            }
            for (stop) |s| {
                if (s.len > self.config.max_stop_length) {
                    return ValidationResult.err("stop", "Stop sequence too long");
                }
            }
        }
        
        // Validate top_logprobs
        if (req.top_logprobs) |lp| {
            if (lp > self.config.max_logprobs) {
                return ValidationResult.err("top_logprobs", "top_logprobs must be at most 20");
            }
        }
        
        return ValidationResult.ok();
    }
    
    /// Validate completion request
    pub fn validateCompletion(self: *RequestValidator, req: CompletionRequest) ValidationResult {
        // Validate model
        if (req.model.len == 0) {
            return ValidationResult.err("model", "Model is required");
        }
        
        // Validate prompt
        if (req.prompt.len == 0) {
            return ValidationResult.err("prompt", "Prompt is required");
        }
        
        if (req.prompt.len > self.config.max_prompt_length) {
            return ValidationResult.err("prompt", "Prompt exceeds maximum length");
        }
        
        // Validate temperature
        if (req.temperature) |temp| {
            if (temp < self.config.min_temperature or temp > self.config.max_temperature) {
                return ValidationResult.err("temperature", "Temperature must be between 0 and 2");
            }
        }
        
        // Validate top_p
        if (req.top_p) |p| {
            if (p < self.config.min_top_p or p > self.config.max_top_p) {
                return ValidationResult.err("top_p", "top_p must be between 0 and 1");
            }
        }
        
        // Validate max_tokens
        if (req.max_tokens) |tokens| {
            if (tokens == 0 or tokens > self.config.max_max_tokens) {
                return ValidationResult.err("max_tokens", "max_tokens must be between 1 and 16384");
            }
        }
        
        // Validate best_of
        if (req.best_of) |best| {
            if (best > self.config.max_best_of) {
                return ValidationResult.err("best_of", "best_of must be at most 20");
            }
            if (req.n) |n| {
                if (best < n) {
                    return ValidationResult.err("best_of", "best_of must be >= n");
                }
            }
        }
        
        return ValidationResult.ok();
    }
};

fn isValidRole(role: []const u8) bool {
    return std.mem.eql(u8, role, "system") or
           std.mem.eql(u8, role, "user") or
           std.mem.eql(u8, role, "assistant") or
           std.mem.eql(u8, role, "tool");
}

// ==============================================
// Validation Middleware
// ==============================================

pub const ValidationMiddleware = struct {
    validator: RequestValidator,
    
    pub fn init(config: ValidationConfig) ValidationMiddleware {
        return ValidationMiddleware{
            .validator = RequestValidator.init(config),
        };
    }
    
    /// Middleware handler for chat completions
    pub fn validateChatRequest(
        self: *ValidationMiddleware,
        req: ChatCompletionRequest,
    ) !ChatCompletionRequest {
        const result = self.validator.validateChatCompletion(req);
        
        if (!result.valid) {
            log.warn("Request validation failed: {s} - {s}", .{
                result.field orelse "unknown",
                result.message orelse "unknown error",
            });
            return error.ValidationFailed;
        }
        
        return req;
    }
    
    /// Middleware handler for completions
    pub fn validateCompletionRequest(
        self: *ValidationMiddleware,
        req: CompletionRequest,
    ) !CompletionRequest {
        const result = self.validator.validateCompletion(req);
        
        if (!result.valid) {
            log.warn("Request validation failed: {s} - {s}", .{
                result.field orelse "unknown",
                result.message orelse "unknown error",
            });
            return error.ValidationFailed;
        }
        
        return req;
    }
};

// ==============================================
// Tests
// ==============================================

test "RequestValidator chat completion" {
    var validator = RequestValidator.init(.{});
    
    // Valid request
    const valid_req = ChatCompletionRequest{
        .model = "llama-7b",
        .messages = &.{
            ChatMessage{ .role = "user", .content = "Hello!" },
        },
    };
    try std.testing.expect(validator.validateChatCompletion(valid_req).valid);
    
    // Missing model
    const no_model = ChatCompletionRequest{
        .model = "",
        .messages = &.{},
    };
    try std.testing.expect(!validator.validateChatCompletion(no_model).valid);
}

test "RequestValidator temperature bounds" {
    var validator = RequestValidator.init(.{});
    
    // Valid temperature
    var req = ChatCompletionRequest{
        .model = "test",
        .messages = &.{ChatMessage{ .role = "user", .content = "Hi" }},
        .temperature = 0.7,
    };
    try std.testing.expect(validator.validateChatCompletion(req).valid);
    
    // Invalid temperature (too high)
    req.temperature = 3.0;
    try std.testing.expect(!validator.validateChatCompletion(req).valid);
}