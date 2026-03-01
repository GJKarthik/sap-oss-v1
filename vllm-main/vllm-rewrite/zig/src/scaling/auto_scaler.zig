//! Auto-Scaler Module
//!
//! Automatic scaling of inference workers based on load metrics.
//! Supports horizontal scaling, predictive scaling, and cost optimization.
//!
//! Features:
//! - Load-based scaling
//! - Predictive scaling
//! - Cool-down periods
//! - Cost-aware scaling

const std = @import("std");

// ==============================================
// Metrics Collection
// ==============================================

pub const MetricType = enum {
    queue_depth,
    request_rate,
    latency_p50,
    latency_p99,
    gpu_utilization,
    memory_utilization,
    error_rate,
};

pub const MetricSample = struct {
    metric_type: MetricType,
    value: f64,
    timestamp: i64,
};

pub const MetricsWindow = struct {
    samples: std.ArrayList(MetricSample),
    window_size_ms: i64,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, window_ms: i64) MetricsWindow {
        return .{
            .samples = std.ArrayList(MetricSample).init(allocator),
            .window_size_ms = window_ms,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MetricsWindow) void {
        self.samples.deinit();
    }
    
    pub fn addSample(self: *MetricsWindow, sample: MetricSample) !void {
        try self.samples.append(sample);
        try self.pruneOld();
    }
    
    fn pruneOld(self: *MetricsWindow) !void {
        const cutoff = std.time.milliTimestamp() - self.window_size_ms;
        var i: usize = 0;
        while (i < self.samples.items.len) {
            if (self.samples.items[i].timestamp < cutoff) {
                _ = self.samples.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    
    pub fn average(self: *const MetricsWindow, metric_type: MetricType) ?f64 {
        var sum: f64 = 0;
        var count: usize = 0;
        
        for (self.samples.items) |sample| {
            if (sample.metric_type == metric_type) {
                sum += sample.value;
                count += 1;
            }
        }
        
        if (count == 0) return null;
        return sum / @as(f64, @floatFromInt(count));
    }
    
    pub fn max(self: *const MetricsWindow, metric_type: MetricType) ?f64 {
        var max_val: ?f64 = null;
        
        for (self.samples.items) |sample| {
            if (sample.metric_type == metric_type) {
                if (max_val == null or sample.value > max_val.?) {
                    max_val = sample.value;
                }
            }
        }
        
        return max_val;
    }
    
    pub fn min(self: *const MetricsWindow, metric_type: MetricType) ?f64 {
        var min_val: ?f64 = null;
        
        for (self.samples.items) |sample| {
            if (sample.metric_type == metric_type) {
                if (min_val == null or sample.value < min_val.?) {
                    min_val = sample.value;
                }
            }
        }
        
        return min_val;
    }
};

// ==============================================
// Scaling Policy
// ==============================================

pub const ScalingDirection = enum {
    scale_up,
    scale_down,
    no_change,
};

pub const ScalingPolicy = struct {
    // Thresholds
    scale_up_threshold: f64,
    scale_down_threshold: f64,
    
    // Limits
    min_replicas: usize,
    max_replicas: usize,
    
    // Timing
    scale_up_cooldown_ms: i64,
    scale_down_cooldown_ms: i64,
    
    // Increments
    scale_up_count: usize,
    scale_down_count: usize,
    
    pub fn default() ScalingPolicy {
        return .{
            .scale_up_threshold = 0.8,
            .scale_down_threshold = 0.3,
            .min_replicas = 1,
            .max_replicas = 10,
            .scale_up_cooldown_ms = 60_000,   // 1 minute
            .scale_down_cooldown_ms = 300_000, // 5 minutes
            .scale_up_count = 1,
            .scale_down_count = 1,
        };
    }
    
    pub fn aggressive() ScalingPolicy {
        return .{
            .scale_up_threshold = 0.6,
            .scale_down_threshold = 0.2,
            .min_replicas = 2,
            .max_replicas = 20,
            .scale_up_cooldown_ms = 30_000,
            .scale_down_cooldown_ms = 120_000,
            .scale_up_count = 2,
            .scale_down_count = 1,
        };
    }
    
    pub fn conservative() ScalingPolicy {
        return .{
            .scale_up_threshold = 0.9,
            .scale_down_threshold = 0.2,
            .min_replicas = 1,
            .max_replicas = 5,
            .scale_up_cooldown_ms = 120_000,
            .scale_down_cooldown_ms = 600_000,
            .scale_up_count = 1,
            .scale_down_count = 1,
        };
    }
};

// ==============================================
// Worker Pool
// ==============================================

pub const WorkerStatus = enum {
    starting,
    ready,
    busy,
    draining,
    stopping,
    stopped,
};

pub const ScalableWorker = struct {
    id: []const u8,
    status: WorkerStatus,
    started_at: i64,
    last_health_check: i64,
    
    // Instance info
    instance_type: []const u8,
    cost_per_hour: f64,
    
    // Metrics
    current_load: f64,
    requests_handled: u64,
    
    pub fn init(id: []const u8, instance_type: []const u8, cost: f64) ScalableWorker {
        return .{
            .id = id,
            .status = .starting,
            .started_at = std.time.milliTimestamp(),
            .last_health_check = std.time.milliTimestamp(),
            .instance_type = instance_type,
            .cost_per_hour = cost,
            .current_load = 0,
            .requests_handled = 0,
        };
    }
    
    pub fn uptime(self: *const ScalableWorker) i64 {
        return std.time.milliTimestamp() - self.started_at;
    }
    
    pub fn isHealthy(self: *const ScalableWorker) bool {
        const health_timeout: i64 = 30_000; // 30 seconds
        return (std.time.milliTimestamp() - self.last_health_check) < health_timeout;
    }
};

pub const WorkerPool = struct {
    workers: std.ArrayList(ScalableWorker),
    target_count: usize,
    default_instance_type: []const u8,
    default_cost: f64,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) WorkerPool {
        return .{
            .workers = std.ArrayList(ScalableWorker).init(allocator),
            .target_count = 1,
            .default_instance_type = "gpu-a100",
            .default_cost = 3.0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *WorkerPool) void {
        self.workers.deinit();
    }
    
    pub fn readyCount(self: *const WorkerPool) usize {
        var count: usize = 0;
        for (self.workers.items) |w| {
            if (w.status == .ready or w.status == .busy) {
                count += 1;
            }
        }
        return count;
    }
    
    pub fn averageLoad(self: *const WorkerPool) f64 {
        const ready = self.readyCount();
        if (ready == 0) return 0;
        
        var total_load: f64 = 0;
        for (self.workers.items) |w| {
            if (w.status == .ready or w.status == .busy) {
                total_load += w.current_load;
            }
        }
        return total_load / @as(f64, @floatFromInt(ready));
    }
    
    pub fn hourlySpend(self: *const WorkerPool) f64 {
        var total: f64 = 0;
        for (self.workers.items) |w| {
            if (w.status != .stopped) {
                total += w.cost_per_hour;
            }
        }
        return total;
    }
    
    pub fn addWorker(self: *WorkerPool, id: []const u8) !void {
        const worker = ScalableWorker.init(id, self.default_instance_type, self.default_cost);
        try self.workers.append(worker);
    }
    
    pub fn removeWorker(self: *WorkerPool, id: []const u8) bool {
        for (self.workers.items, 0..) |w, i| {
            if (std.mem.eql(u8, w.id, id)) {
                _ = self.workers.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

// ==============================================
// Auto Scaler
// ==============================================

pub const ScalingDecision = struct {
    direction: ScalingDirection,
    count: usize,
    reason: []const u8,
    metric_value: f64,
    threshold: f64,
};

pub const AutoScaler = struct {
    pool: WorkerPool,
    policy: ScalingPolicy,
    metrics: MetricsWindow,
    
    // Cooldown tracking
    last_scale_up: i64,
    last_scale_down: i64,
    
    // Statistics
    total_scale_ups: u64,
    total_scale_downs: u64,
    decisions_made: u64,
    
    // Predictive scaling
    enable_predictive: bool,
    prediction_window_ms: i64,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, policy: ScalingPolicy) AutoScaler {
        return .{
            .pool = WorkerPool.init(allocator),
            .policy = policy,
            .metrics = MetricsWindow.init(allocator, 300_000), // 5 min window
            .last_scale_up = 0,
            .last_scale_down = 0,
            .total_scale_ups = 0,
            .total_scale_downs = 0,
            .decisions_made = 0,
            .enable_predictive = true,
            .prediction_window_ms = 60_000,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *AutoScaler) void {
        self.pool.deinit();
        self.metrics.deinit();
    }
    
    /// Record a metric sample
    pub fn recordMetric(self: *AutoScaler, metric_type: MetricType, value: f64) !void {
        const sample = MetricSample{
            .metric_type = metric_type,
            .value = value,
            .timestamp = std.time.milliTimestamp(),
        };
        try self.metrics.addSample(sample);
    }
    
    /// Evaluate scaling decision
    pub fn evaluate(self: *AutoScaler) ScalingDecision {
        self.decisions_made += 1;
        
        const now = std.time.milliTimestamp();
        const current_count = self.pool.readyCount();
        
        // Get current metrics
        const avg_load = self.metrics.average(.gpu_utilization) orelse self.pool.averageLoad();
        const queue_depth = self.metrics.average(.queue_depth) orelse 0;
        
        // Check scale up
        if (avg_load > self.policy.scale_up_threshold or queue_depth > 10) {
            if (now - self.last_scale_up >= self.policy.scale_up_cooldown_ms) {
                if (current_count < self.policy.max_replicas) {
                    return ScalingDecision{
                        .direction = .scale_up,
                        .count = self.policy.scale_up_count,
                        .reason = "High load or queue depth",
                        .metric_value = avg_load,
                        .threshold = self.policy.scale_up_threshold,
                    };
                }
            }
        }
        
        // Check scale down
        if (avg_load < self.policy.scale_down_threshold and queue_depth < 2) {
            if (now - self.last_scale_down >= self.policy.scale_down_cooldown_ms) {
                if (current_count > self.policy.min_replicas) {
                    return ScalingDecision{
                        .direction = .scale_down,
                        .count = self.policy.scale_down_count,
                        .reason = "Low load",
                        .metric_value = avg_load,
                        .threshold = self.policy.scale_down_threshold,
                    };
                }
            }
        }
        
        return ScalingDecision{
            .direction = .no_change,
            .count = 0,
            .reason = "Within thresholds",
            .metric_value = avg_load,
            .threshold = 0,
        };
    }
    
    /// Execute scaling decision
    pub fn execute(self: *AutoScaler, decision: ScalingDecision) !void {
        switch (decision.direction) {
            .scale_up => {
                for (0..decision.count) |i| {
                    var id_buf: [32]u8 = undefined;
                    const id = std.fmt.bufPrint(&id_buf, "worker-{d}", .{
                        self.pool.workers.items.len + i
                    }) catch "worker-new";
                    try self.pool.addWorker(id);
                }
                self.last_scale_up = std.time.milliTimestamp();
                self.total_scale_ups += 1;
            },
            .scale_down => {
                // Find workers to remove (prefer lowest load)
                var to_remove = std.ArrayList([]const u8).init(self.allocator);
                defer to_remove.deinit();
                
                // Sort by load (would need actual implementation)
                var removed: usize = 0;
                for (self.pool.workers.items) |w| {
                    if (removed >= decision.count) break;
                    if (w.status == .ready and w.current_load < 0.1) {
                        try to_remove.append(w.id);
                        removed += 1;
                    }
                }
                
                for (to_remove.items) |id| {
                    _ = self.pool.removeWorker(id);
                }
                
                self.last_scale_down = std.time.milliTimestamp();
                self.total_scale_downs += 1;
            },
            .no_change => {},
        }
    }
    
    /// Main scaling loop step
    pub fn step(self: *AutoScaler) !ScalingDecision {
        const decision = self.evaluate();
        try self.execute(decision);
        return decision;
    }
    
    /// Get scaler statistics
    pub fn getStats(self: *const AutoScaler) ScalerStats {
        return .{
            .current_workers = self.pool.workers.items.len,
            .ready_workers = self.pool.readyCount(),
            .target_workers = self.pool.target_count,
            .average_load = self.pool.averageLoad(),
            .hourly_cost = self.pool.hourlySpend(),
            .total_scale_ups = self.total_scale_ups,
            .total_scale_downs = self.total_scale_downs,
            .decisions_made = self.decisions_made,
        };
    }
};

pub const ScalerStats = struct {
    current_workers: usize,
    ready_workers: usize,
    target_workers: usize,
    average_load: f64,
    hourly_cost: f64,
    total_scale_ups: u64,
    total_scale_downs: u64,
    decisions_made: u64,
};

// ==============================================
// Predictive Scaler
// ==============================================

pub const PredictiveScaler = struct {
    base_scaler: *AutoScaler,
    history: std.ArrayList(f64),
    prediction_horizon: usize,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, base: *AutoScaler) PredictiveScaler {
        return .{
            .base_scaler = base,
            .history = std.ArrayList(f64).init(allocator),
            .prediction_horizon = 10,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *PredictiveScaler) void {
        self.history.deinit();
    }
    
    pub fn recordLoad(self: *PredictiveScaler, load: f64) !void {
        try self.history.append(load);
        // Keep last 100 samples
        if (self.history.items.len > 100) {
            _ = self.history.orderedRemove(0);
        }
    }
    
    /// Simple linear prediction
    pub fn predictLoad(self: *const PredictiveScaler) ?f64 {
        if (self.history.items.len < 10) return null;
        
        // Simple moving average trend
        const recent = self.history.items[self.history.items.len - 5 ..];
        const older = self.history.items[self.history.items.len - 10 .. self.history.items.len - 5];
        
        var recent_avg: f64 = 0;
        var older_avg: f64 = 0;
        
        for (recent) |v| recent_avg += v;
        recent_avg /= 5.0;
        
        for (older) |v| older_avg += v;
        older_avg /= 5.0;
        
        // Project forward
        const trend = recent_avg - older_avg;
        return recent_avg + trend * @as(f64, @floatFromInt(self.prediction_horizon));
    }
    
    /// Pre-emptive scaling based on prediction
    pub fn evaluatePreemptive(self: *PredictiveScaler) ?ScalingDecision {
        const predicted = self.predictLoad() orelse return null;
        
        if (predicted > self.base_scaler.policy.scale_up_threshold * 1.2) {
            return ScalingDecision{
                .direction = .scale_up,
                .count = 1,
                .reason = "Predicted high load",
                .metric_value = predicted,
                .threshold = self.base_scaler.policy.scale_up_threshold,
            };
        }
        
        return null;
    }
};

// ==============================================
// Cost Optimizer
// ==============================================

pub const CostOptimizer = struct {
    scaler: *AutoScaler,
    budget_per_hour: f64,
    prefer_spot: bool,
    
    pub fn init(scaler: *AutoScaler, budget: f64) CostOptimizer {
        return .{
            .scaler = scaler,
            .budget_per_hour = budget,
            .prefer_spot = true,
        };
    }
    
    pub fn withinBudget(self: *const CostOptimizer) bool {
        return self.scaler.pool.hourlySpend() <= self.budget_per_hour;
    }
    
    pub fn recommendedWorkerCount(self: *const CostOptimizer) usize {
        const cost_per_worker = self.scaler.pool.default_cost;
        const max_workers = @as(usize, @intFromFloat(self.budget_per_hour / cost_per_worker));
        return @min(max_workers, self.scaler.policy.max_replicas);
    }
    
    pub fn dailyCost(self: *const CostOptimizer) f64 {
        return self.scaler.pool.hourlySpend() * 24.0;
    }
    
    pub fn monthlyCost(self: *const CostOptimizer) f64 {
        return self.dailyCost() * 30.0;
    }
};

// ==============================================
// Tests
// ==============================================

test "MetricsWindow average" {
    const allocator = std.testing.allocator;
    var window = MetricsWindow.init(allocator, 60_000);
    defer window.deinit();
    
    try window.addSample(.{ .metric_type = .gpu_utilization, .value = 0.5, .timestamp = std.time.milliTimestamp() });
    try window.addSample(.{ .metric_type = .gpu_utilization, .value = 0.7, .timestamp = std.time.milliTimestamp() });
    
    const avg = window.average(.gpu_utilization);
    try std.testing.expect(avg != null);
    try std.testing.expect(avg.? == 0.6);
}

test "ScalingPolicy defaults" {
    const policy = ScalingPolicy.default();
    try std.testing.expect(policy.min_replicas == 1);
    try std.testing.expect(policy.max_replicas == 10);
}

test "AutoScaler evaluate" {
    const allocator = std.testing.allocator;
    var scaler = AutoScaler.init(allocator, ScalingPolicy.default());
    defer scaler.deinit();
    
    const decision = scaler.evaluate();
    try std.testing.expect(decision.direction == .no_change);
}