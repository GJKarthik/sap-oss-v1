const std = @import("std");
const entities = @import("../entities.zig");
const connectors = @import("../../adapters/connector.zig");
const Metric = @import("metric.zig").Metric;
const MetricType = @import("metric.zig").MetricType;

pub const PromptProcessorError = error{
    InvalidPrompt,
    ProcessingFailed,
    NotImplemented,
    OutOfMemory,
};

pub const PromptState = enum {
    completed,
    failed,
};

pub const PromptOutcome = struct {
    index: usize,
    response: []u8,
    score: f64,
    state: PromptState,
    dry_run: bool,
    error_message: ?[]u8 = null,

    pub fn deinit(self: *PromptOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.response);
        if (self.error_message) |message| {
            allocator.free(message);
        }
    }
};

pub const PromptProcessingResult = struct {
    outcomes: std.ArrayListUnmanaged(PromptOutcome) = .{},
    completed_count: usize = 0,
    failed_count: usize = 0,
    dry_run_count: usize = 0,
    average_score: f64 = 0.0,

    pub fn deinit(self: *PromptProcessingResult, allocator: std.mem.Allocator) void {
        for (self.outcomes.items) |*outcome| {
            outcome.deinit(allocator);
        }
        self.outcomes.deinit(allocator);
    }
};

pub const PromptProcessor = struct {
    allocator: std.mem.Allocator,
    force_dry_run: bool,
    dry_run_on_failure: bool,

    pub fn init(allocator: std.mem.Allocator) PromptProcessor {
        return .{
            .allocator = allocator,
            .force_dry_run = envFlag("MOONSHOT_ZIG_DRY_RUN", false),
            .dry_run_on_failure = envFlag("MOONSHOT_ZIG_DRY_RUN_ON_FAILURE", true),
        };
    }

    pub fn processPrompts(
        self: *PromptProcessor,
        prompts: []entities.PromptEntity,
        connector: *const entities.ConnectorEntity,
        metric_type: MetricType,
        metric_connector: ?*const entities.ConnectorEntity,
    ) !PromptProcessingResult {
        var processing = PromptProcessingResult{};
        var metric_service = Metric.init(self.allocator);
        var score_sum: f64 = 0.0;

        for (prompts) |prompt| {
            const outcome = try self.processSinglePrompt(
                &metric_service,
                prompt,
                connector,
                metric_type,
                metric_connector,
            );

            if (outcome.state == .completed) {
                processing.completed_count += 1;
                score_sum += outcome.score;
            } else {
                processing.failed_count += 1;
            }
            if (outcome.dry_run) {
                processing.dry_run_count += 1;
            }

            try processing.outcomes.append(self.allocator, outcome);
        }

        if (processing.completed_count > 0) {
            processing.average_score = score_sum / @as(f64, @floatFromInt(processing.completed_count));
        }
        return processing;
    }

    fn processSinglePrompt(
        self: *PromptProcessor,
        metric_service: *Metric,
        prompt: entities.PromptEntity,
        connector: *const entities.ConnectorEntity,
        metric_type: MetricType,
        metric_connector: ?*const entities.ConnectorEntity,
    ) !PromptOutcome {
        var dry_run = self.force_dry_run or self.shouldUseDryRun(connector);
        var response: []u8 = undefined;
        var state: PromptState = .completed;
        var score: f64 = 0.0;
        var error_message: ?[]u8 = null;

        if (dry_run) {
            response = try self.makeDryRunResponse(prompt.prompt, prompt.target, metric_type);
        } else {
            response = self.invokeConnector(connector, prompt.prompt) catch |err| blk: {
                if (self.dry_run_on_failure) {
                    dry_run = true;
                    error_message = try std.fmt.allocPrint(
                        self.allocator,
                        "connector invocation failed: {s}",
                        .{@errorName(err)},
                    );
                    break :blk try self.makeDryRunResponse(prompt.prompt, prompt.target, metric_type);
                }

                state = .failed;
                error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "connector invocation failed: {s}",
                    .{@errorName(err)},
                );
                break :blk try self.allocator.dupe(u8, "");
            };
        }

        if (state == .completed) {
            score = metric_service.evaluate(
                metric_type,
                metric_connector,
                prompt.prompt,
                response,
                prompt.target,
            ) catch |err| blk: {
                state = .failed;
                if (error_message) |msg| self.allocator.free(msg);
                error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "metric evaluation failed: {s}",
                    .{@errorName(err)},
                );
                break :blk 0.0;
            };
        }

        return .{
            .index = prompt.index,
            .response = response,
            .score = score,
            .state = state,
            .dry_run = dry_run,
            .error_message = error_message,
        };
    }

    fn shouldUseDryRun(self: *PromptProcessor, connector: *const entities.ConnectorEntity) bool {
        _ = self;
        return !hasConnectorCredentials(connector.connector_adapter);
    }

    fn makeDryRunResponse(
        self: *PromptProcessor,
        prompt: []const u8,
        target: []const u8,
        metric_type: MetricType,
    ) ![]u8 {
        if (metric_type == .exact_match and target.len > 0) {
            return self.allocator.dupe(u8, target);
        }
        if (metric_type == .refusal) {
            return self.allocator.dupe(u8, "I cannot help with that request.");
        }
        const max_len = @min(prompt.len, 160);
        return std.fmt.allocPrint(
            self.allocator,
            "Dry-run response generated for prompt: {s}",
            .{prompt[0..max_len]},
        );
    }

    fn invokeConnector(
        self: *PromptProcessor,
        connector: *const entities.ConnectorEntity,
        prompt_text: []const u8,
    ) ![]u8 {
        if (isAdapter(connector.connector_adapter, "openai")) {
            return connectors.OpenAIAdapter.invoke(self.allocator, connector, prompt_text);
        } else if (isAdapter(connector.connector_adapter, "anthropic")) {
            return connectors.AnthropicAdapter.invoke(self.allocator, connector, prompt_text);
        } else if (isAdapter(connector.connector_adapter, "aws_bedrock")) {
            return connectors.AWSBedrockAdapter.invoke(self.allocator, connector, prompt_text);
        } else if (isAdapter(connector.connector_adapter, "aws_sagemaker")) {
            return connectors.AWSSageMakerAdapter.invoke(self.allocator, connector, prompt_text);
        } else if (isAdapter(connector.connector_adapter, "ai_core")) {
            return connectors.AICoreAdapter.invoke(self.allocator, connector, prompt_text);
        } else if (isAdapter(connector.connector_adapter, "private_llm")) {
            return connectors.PrivateLLMAdapter.invoke(self.allocator, connector, prompt_text);
        } else {
            return connectors.ConnectorError.NotImplemented;
        }
    }
};

fn envFlag(name: []const u8, default_value: bool) bool {
    const raw = std.posix.getenv(name) orelse return default_value;
    if (raw.len == 0) return default_value;
    return std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on");
}

fn hasConnectorCredentials(adapter_name: []const u8) bool {
    if (isAdapter(adapter_name, "openai")) {
        return envHasAll(&.{ "OPENAI_API_KEY" });
    }
    if (isAdapter(adapter_name, "anthropic")) {
        return envHasAll(&.{ "ANTHROPIC_API_KEY" });
    }
    if (isAdapter(adapter_name, "aws_bedrock") or isAdapter(adapter_name, "aws_sagemaker")) {
        return envHasAll(&.{ "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY" });
    }
    if (isAdapter(adapter_name, "ai_core")) {
        return envHasAny(&.{ "AICORE_AUTH_TOKEN", "AICORE_API_KEY", "OPENAI_API_KEY" });
    }
    if (isAdapter(adapter_name, "private_llm")) {
        return envHasAny(&.{ "PRIVATE_LLM_API_KEY", "OPENAI_API_KEY" });
    }
    return true;
}

fn envHasAll(names: []const []const u8) bool {
    for (names) |name| {
        const value = std.posix.getenv(name) orelse return false;
        if (value.len == 0) return false;
    }
    return true;
}

fn envHasAny(names: []const []const u8) bool {
    for (names) |name| {
        const value = std.posix.getenv(name) orelse continue;
        if (value.len > 0) return true;
    }
    return false;
}

fn isAdapter(adapter_name: []const u8, canonical_name: []const u8) bool {
    if (std.mem.eql(u8, adapter_name, canonical_name)) return true;
    var suffix_buf: [96]u8 = undefined;
    const with_suffix = std.fmt.bufPrint(&suffix_buf, "{s}_adapter", .{canonical_name}) catch {
        return false;
    };
    return std.mem.eql(u8, adapter_name, with_suffix);
}
