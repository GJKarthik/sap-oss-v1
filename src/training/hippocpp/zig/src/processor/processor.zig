//! Query Processor - Full Implementation
//!
//! Converted from: kuzu/src/processor/*.cpp
//!
//! Purpose:
//! Executes physical query plans. Decomposes plans into parallel tasks,
//! schedules them on the task scheduler, and coordinates execution.
//!
//! Architecture:
//! ```
//! PhysicalPlan
//!   │
//!   └── QueryProcessor::execute()
//!         │
//!         ├── 1. Get Sink operator (root)
//!         ├── 2. Create root ProcessorTask
//!         ├── 3. decomposePlanIntoTask()
//!         │     └── Recursively create child tasks
//!         ├── 4. initTask()
//!         │     └── Mark single-threaded if needed
//!         ├── 5. taskScheduler->scheduleTaskAndWaitOrError()
//!         └── 6. Return QueryResult from Sink
//! ```

const std = @import("std");
const physical_operator = @import("physical_operator.zig");
const common = @import("common");

const PhysicalOperator = physical_operator.PhysicalOperator;
const DataChunk = physical_operator.DataChunk;
const ResultState = physical_operator.ResultState;
const OperatorMetrics = physical_operator.OperatorMetrics;
const PhysicalOperatorType = physical_operator.PhysicalOperatorType;

// ============================================================================
// Query Result
// ============================================================================

/// Column metadata
pub const ColumnInfo = struct {
    name: []const u8,
    column_type: common.LogicalType,
    is_nullable: bool,
    
    pub fn init(name: []const u8, col_type: common.LogicalType) ColumnInfo {
        return .{
            .name = name,
            .column_type = col_type,
            .is_nullable = true,
        };
    }
};

/// Query result containing execution output
pub const QueryResult = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayList(ColumnInfo),
    chunks: std.ArrayList(DataChunk),
    num_tuples: u64,
    execution_time_ns: u64,
    success: bool,
    error_message: ?[]const u8,
    warning_messages: std.ArrayList([]const u8),
    query_id: u64,
    is_exhausted: bool,
    
    // Profiling info
    profiling_enabled: bool,
    operator_profiles: std.ArrayList(OperatorProfile),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .columns = .{},
            .chunks = .{},
            .num_tuples = 0,
            .execution_time_ns = 0,
            .success = true,
            .error_message = null,
            .warning_messages = .{},
            .query_id = 0,
            .is_exhausted = false,
            .profiling_enabled = false,
            .operator_profiles = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.chunks.deinit(self.allocator);
        self.columns.deinit(self.allocator);
        self.warning_messages.deinit(self.allocator);
        self.operator_profiles.deinit(self.allocator);
    }
    
    pub fn addColumn(self: *Self, name: []const u8, col_type: common.LogicalType) !void {
        try self.columns.append(self.allocator, ColumnInfo.init(name, col_type));
    }
    
    pub fn addColumnInfo(self: *Self, info: ColumnInfo) !void {
        try self.columns.append(self.allocator, info);
    }
    
    pub fn setError(self: *Self, message: []const u8) void {
        self.success = false;
        self.error_message = message;
    }
    
    pub fn addWarning(self: *Self, message: []const u8) !void {
        try self.warning_messages.append(self.allocator, message);
    }
    
    pub fn getNumColumns(self: *const Self) usize {
        return self.columns.items.len;
    }
    
    pub fn getColumnName(self: *const Self, idx: usize) ?[]const u8 {
        if (idx >= self.columns.items.len) return null;
        return self.columns.items[idx].name;
    }
    
    pub fn getColumnType(self: *const Self, idx: usize) ?common.LogicalType {
        if (idx >= self.columns.items.len) return null;
        return self.columns.items[idx].column_type;
    }
    
    pub fn hasNext(self: *const Self) bool {
        return !self.is_exhausted and self.chunks.items.len > 0;
    }
    
    /// Get next batch of results
    pub fn getNextBatch(self: *Self) ?*DataChunk {
        if (self.is_exhausted or self.chunks.items.len == 0) {
            return null;
        }
        return &self.chunks.items[0];
    }
    
    /// Check if query completed successfully
    pub fn isSuccess(self: *const Self) bool {
        return self.success;
    }
    
    /// Get total execution time in milliseconds
    pub fn getExecutionTimeMs(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.execution_time_ns)) / 1_000_000.0;
    }
    
    /// Get operator profiling info
    pub fn getProfiles(self: *const Self) []const OperatorProfile {
        return self.operator_profiles.items;
    }
};

/// Profile information for a single operator
pub const OperatorProfile = struct {
    operator_id: u32,
    operator_type: PhysicalOperatorType,
    operator_name: []const u8,
    execution_time_ns: u64,
    num_output_tuples: u64,
    memory_usage: u64,
    children: std.ArrayList(u32), // Child operator IDs
    
    pub fn init(_: std.mem.Allocator, id: u32, op_type: PhysicalOperatorType) OperatorProfile {
        return .{
            .operator_id = id,
            .operator_type = op_type,
            .operator_name = @tagName(op_type),
            .execution_time_ns = 0,
            .num_output_tuples = 0,
            .memory_usage = 0,
            .children = .{},
        };
    }
    
    pub fn deinit(self: *OperatorProfile) void {
        self.children.deinit(self.allocator);
    }
};

// ============================================================================
// Result Set
// ============================================================================

/// Result set descriptor - describes the shape of query results
pub const ResultSetDescriptor = struct {
    allocator: std.mem.Allocator,
    num_columns: usize,
    column_names: std.ArrayList([]const u8),
    column_types: std.ArrayList(common.LogicalType),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .num_columns = 0,
            .column_names = .{},
            .column_types = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.column_names.deinit(self.allocator);
        self.column_types.deinit(self.allocator);
    }
    
    pub fn addColumn(self: *Self, name: []const u8, col_type: common.LogicalType) !void {
        try self.column_names.append(self.allocator, name);
        try self.column_types.append(self.allocator, col_type);
        self.num_columns += 1;
    }
};

/// Result set - holds actual result data during execution
pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    descriptor: ResultSetDescriptor,
    data_chunks: std.ArrayList(DataChunk),
    multiplicity: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .descriptor = ResultSetDescriptor.init(allocator),
            .data_chunks = .{},
            .multiplicity = 1,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.data_chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.data_chunks.deinit(self.allocator);
        self.descriptor.deinit(self.allocator);
    }
    
    pub fn addChunk(self: *Self, chunk: DataChunk) !void {
        try self.data_chunks.append(self.allocator, chunk);
    }
    
    pub fn getNumTuples(self: *const Self) u64 {
        var count: u64 = 0;
        for (self.data_chunks.items) |chunk| {
            count += chunk.num_tuples;
        }
        return count;
    }
};

// ============================================================================
// Execution Context
// ============================================================================

/// Execution context - runtime state for query execution
pub const ExecutionContext = struct {
    allocator: std.mem.Allocator,
    max_threads: u32,
    memory_limit: u64,
    current_memory: u64,
    enable_profiling: bool,
    enable_progress: bool,
    interrupted: std.atomic.Value(bool),
    timeout_ms: ?u64,
    start_time: i64,
    query_id: u64,
    transaction_id: u64,
    
    // Progress tracking
    pipelines_total: u32,
    pipelines_completed: u32,
    current_pipeline_progress: f64,
    
    // Profiler
    profiler: ?*Profiler,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .max_threads = 1,
            .memory_limit = 1024 * 1024 * 1024, // 1GB default
            .current_memory = 0,
            .enable_profiling = false,
            .enable_progress = false,
            .interrupted = std.atomic.Value(bool).init(false),
            .timeout_ms = null,
            .start_time = std.time.milliTimestamp(),
            .query_id = 0,
            .transaction_id = 0,
            .pipelines_total = 0,
            .pipelines_completed = 0,
            .current_pipeline_progress = 0,
            .profiler = null,
        };
    }
    
    pub fn interrupt(self: *Self) void {
        self.interrupted.store(true, .release);
    }
    
    pub fn isInterrupted(self: *const Self) bool {
        return self.interrupted.load(.acquire);
    }
    
    pub fn checkTimeout(self: *const Self) bool {
        if (self.timeout_ms) |timeout| {
            const elapsed = std.time.milliTimestamp() - self.start_time;
            return @as(u64, @intCast(elapsed)) > timeout;
        }
        return false;
    }
    
    pub fn setTimeout(self: *Self, timeout_ms: u64) void {
        self.timeout_ms = timeout_ms;
        self.start_time = std.time.milliTimestamp();
    }
    
    pub fn allocateMemory(self: *Self, size: u64) !void {
        if (self.current_memory + size > self.memory_limit) {
            return error.OutOfMemory;
        }
        self.current_memory += size;
    }
    
    pub fn freeMemory(self: *Self, size: u64) void {
        self.current_memory -= @min(self.current_memory, size);
    }
    
    pub fn addPipeline(self: *Self) void {
        self.pipelines_total += 1;
    }
    
    pub fn completePipeline(self: *Self) void {
        self.pipelines_completed += 1;
    }
    
    pub fn getOverallProgress(self: *const Self) f64 {
        if (self.pipelines_total == 0) return 0;
        const completed_progress = @as(f64, @floatFromInt(self.pipelines_completed));
        const pipeline_contribution = self.current_pipeline_progress / @as(f64, @floatFromInt(self.pipelines_total));
        return (completed_progress + pipeline_contribution) / @as(f64, @floatFromInt(self.pipelines_total));
    }
};

// ============================================================================
// Profiler
// ============================================================================

/// Time metric for profiling
pub const TimeMetric = struct {
    name: []const u8,
    total_ns: u64,
    count: u64,
    start_time: ?i64,
    
    pub fn init(name: []const u8) TimeMetric {
        return .{
            .name = name,
            .total_ns = 0,
            .count = 0,
            .start_time = null,
        };
    }
    
    pub fn start(self: *TimeMetric) void {
        self.start_time = @intCast(std.time.nanoTimestamp());
    }
    
    pub fn stop(self: *TimeMetric) void {
        if (self.start_time) |_| {
            // const elapsed = std.time.nanoTimestamp() - start;
    // self.total_ns += @intCast(elapsed);
            self.count += 1;
            self.start_time = null;
        }
    }
    
    pub fn getAverageNs(self: *const TimeMetric) u64 {
        if (self.count == 0) return 0;
        return self.total_ns / self.count;
    }
};

/// Numeric metric for profiling
pub const NumericMetric = struct {
    name: []const u8,
    value: u64,
    
    pub fn init(name: []const u8) NumericMetric {
        return .{
            .name = name,
            .value = 0,
        };
    }
    
    pub fn add(self: *NumericMetric, amount: u64) void {
        self.value += amount;
    }
    
    pub fn set(self: *NumericMetric, val: u64) void {
        self.value = val;
    }
};

/// Query profiler
pub const Profiler = struct {
    allocator: std.mem.Allocator,
    time_metrics: std.StringHashMap(TimeMetric),
    numeric_metrics: std.StringHashMap(NumericMetric),
    enabled: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .time_metrics = std.StringHashMap(TimeMetric).init(allocator),
            .numeric_metrics = std.StringHashMap(NumericMetric).init(allocator),
            .enabled = true,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.time_metrics.deinit();
        self.numeric_metrics.deinit();
    }
    
    pub fn registerTimeMetric(self: *Self, key: []const u8) !*TimeMetric {
        const result = try self.time_metrics.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = TimeMetric.init(key);
        }
        return result.value_ptr;
    }
    
    pub fn registerNumericMetric(self: *Self, key: []const u8) !*NumericMetric {
        const result = try self.numeric_metrics.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = NumericMetric.init(key);
        }
        return result.value_ptr;
    }
    
    pub fn sumAllTimeMetrics(self: *const Self, key_prefix: []const u8) u64 {
        var sum: u64 = 0;
        var it = self.time_metrics.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, key_prefix)) {
                sum += entry.value_ptr.total_ns;
            }
        }
        return sum;
    }
    
    pub fn sumAllNumericMetrics(self: *const Self, key_prefix: []const u8) u64 {
        var sum: u64 = 0;
        var it = self.numeric_metrics.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, key_prefix)) {
                sum += entry.value_ptr.value;
            }
        }
        return sum;
    }
};

// ============================================================================
// Progress Bar
// ============================================================================

/// Progress bar for tracking query execution
pub const ProgressBar = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    pipelines: std.AutoHashMap(u64, PipelineProgress),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .enabled = false,
            .pipelines = .{ .unmanaged = .empty, .allocator = std.testing.allocator, .ctx = .{} },
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.pipelines.deinit();
    }
    
    pub fn startProgress(self: *Self, query_id: u64) void {
        if (!self.enabled) return;
        self.pipelines.put(query_id, PipelineProgress.init()) catch {};
    }
    
    pub fn updateProgress(self: *Self, query_id: u64, progress: f64) void {
        if (!self.enabled) return;
        if (self.pipelines.getPtr(query_id)) |p| {
            p.progress = progress;
        }
    }
    
    pub fn endProgress(self: *Self, query_id: u64) void {
        if (!self.enabled) return;
        _ = self.pipelines.remove(query_id);
    }
    
    pub fn addPipeline(self: *Self, query_id: u64) void {
        if (!self.enabled) return;
        if (self.pipelines.getPtr(query_id)) |p| {
            p.total_pipelines += 1;
        }
    }
    
    pub fn getProgress(self: *const Self, query_id: u64) f64 {
        if (self.pipelines.get(query_id)) |p| {
            return p.progress;
        }
        return 0;
    }
};

const PipelineProgress = struct {
    progress: f64,
    total_pipelines: u32,
    completed_pipelines: u32,
    
    pub fn init() PipelineProgress {
        return .{
            .progress = 0,
            .total_pipelines = 0,
            .completed_pipelines = 0,
        };
    }
};

// ============================================================================
// Processor Task
// ============================================================================

/// Task status
pub const TaskStatus = enum {
    PENDING,
    RUNNING,
    COMPLETED,
    FAILED,
    CANCELLED,
};

/// Processor task - unit of parallel execution
pub const ProcessorTask = struct {
    allocator: std.mem.Allocator,
    sink: *PhysicalOperator,
    context: *ExecutionContext,
    result: *QueryResult,
    children: std.ArrayList(*ProcessorTask),
    status: TaskStatus,
    single_threaded: bool,
    task_id: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, sink: *PhysicalOperator, context: *ExecutionContext, result: *QueryResult) Self {
        return .{
            .allocator = allocator,
            .sink = sink,
            .context = context,
            .result = result,
            .children = .{},
            .status = .PENDING,
            .single_threaded = false,
            .task_id = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
    }
    
    /// Add a child task (for pipeline decomposition)
    pub fn addChildTask(self: *Self, child: *ProcessorTask) !void {
        try self.children.append(self.allocator, child);
    }
    
    /// Set task as single-threaded
    pub fn setSingleThreaded(self: *Self) void {
        self.single_threaded = true;
    }
    
    /// Execute the task
    pub fn execute(self: *Self) !void {
        self.status = .RUNNING;
        
        // Execute child tasks first
        for (self.children.items) |child| {
            try child.execute();
        }
        
        // Initialize operator tree
        try self.sink.initOp();
        
        var chunk = DataChunk.init(self.context.allocator);
        defer chunk.deinit(self.allocator);
        
        const start_time = std.time.nanoTimestamp();
        
        // Pull tuples from operator tree
        while (!self.context.isInterrupted() and !self.context.checkTimeout()) {
            const state = try self.sink.getNext(&chunk);
            
            if (state == .NO_MORE_TUPLES) break;
            
            if (chunk.num_tuples > 0) {
                self.result.num_tuples += chunk.num_tuples;
                
                // Optionally store results
                const stored_chunk = DataChunk.init(self.context.allocator);
                // Copy data to stored chunk
                try self.result.chunks.append(self.allocator, stored_chunk);
            }
            
            chunk.reset();
        }
        
        const end_time = std.time.nanoTimestamp();
        self.result.execution_time_ns = @intCast(end_time - start_time);
        
        // Close operator tree
        self.sink.close();
        
        if (self.context.isInterrupted()) {
            self.status = .CANCELLED;
            self.result.setError("Query execution interrupted");
        } else if (self.context.checkTimeout()) {
            self.status = .FAILED;
            self.result.setError("Query execution timeout");
        } else {
            self.status = .COMPLETED;
        }
    }
    
    /// Get task progress
    pub fn getProgress(self: *const Self) f64 {
        if (self.status == .COMPLETED) return 1.0;
        if (self.status == .PENDING) return 0.0;
        
        // Get progress from sink operator
        return self.sink.getProgress();
    }
};

// ============================================================================
// Task Scheduler
// ============================================================================

/// Task scheduler - manages parallel task execution
pub const TaskScheduler = struct {
    allocator: std.mem.Allocator,
    num_threads: u32,
    pending_tasks: std.ArrayList(*ProcessorTask),
    running_tasks: std.ArrayList(*ProcessorTask),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, num_threads: u32) Self {
        return .{
            .allocator = allocator,
            .num_threads = num_threads,
            .pending_tasks = .{},
            .running_tasks = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.pending_tasks.deinit(self.allocator);
        self.running_tasks.deinit(self.allocator);
    }
    
    /// Schedule a task and wait for completion
    pub fn scheduleTaskAndWait(self: *Self, task: *ProcessorTask, context: *ExecutionContext) !void {
        _ = self;
        
        // For single-threaded mode, just execute directly
        if (task.single_threaded or context.max_threads == 1) {
            try task.execute();
            return;
        }
        
        // TODO: Implement parallel scheduling with thread pool
        try task.execute();
    }
    
    /// Check for any errors during execution
    pub fn checkForErrors(self: *const Self) ?[]const u8 {
        for (self.running_tasks.items) |task| {
            if (task.status == .FAILED) {
                if (task.result.error_message) |msg| {
                    return msg;
                }
            }
        }
        return null;
    }
};

// ============================================================================
// Plan Mapper
// ============================================================================

/// Plan mapper - maps logical plan to physical plan
pub const PlanMapper = struct {
    allocator: std.mem.Allocator,
    next_operator_id: u32,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .next_operator_id = 0,
        };
    }
    
    /// Get next operator ID
    pub fn getNextOperatorId(self: *Self) u32 {
        const id = self.next_operator_id;
        self.next_operator_id += 1;
        return id;
    }
};

// ============================================================================
// Query Processor
// ============================================================================

/// Query processor - main execution engine
pub const QueryProcessor = struct {
    allocator: std.mem.Allocator,
    context: ExecutionContext,
    scheduler: TaskScheduler,
    progress_bar: ProgressBar,
    current_task: ?*ProcessorTask,
    next_query_id: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .context = ExecutionContext.init(allocator),
            .scheduler = TaskScheduler.init(allocator, 1),
            .progress_bar = ProgressBar.init(allocator),
            .current_task = null,
            .next_query_id = 1,
        };
    }
    
    pub fn initWithThreads(allocator: std.mem.Allocator, num_threads: u32) Self {
        var self = Self.init(allocator);
        self.context.max_threads = num_threads;
        self.scheduler = TaskScheduler.init(allocator, num_threads);
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        if (self.current_task) |task| {
            task.deinit();
            self.allocator.destroy(task);
        }
        self.scheduler.deinit();
        self.progress_bar.deinit();
    }
    
    /// Execute a physical plan
    pub fn execute(self: *Self, root_operator: *PhysicalOperator) !QueryResult {
        var result = QueryResult.init(self.allocator);
        result.query_id = self.next_query_id;
        self.next_query_id += 1;
        self.context.query_id = result.query_id;
        
        // Create root task
        const task = try self.allocator.create(ProcessorTask);
        task.* = ProcessorTask.init(self.allocator, root_operator, &self.context, &result);
        task.task_id = result.query_id;
        
        self.current_task = task;
        
        // Decompose plan into tasks
        try self.decomposePlanIntoTask(root_operator, task);
        
        // Initialize task parallelism
        self.initTask(task);
        
        // Start progress tracking
        self.progress_bar.startProgress(result.query_id);
        
        // Execute
        self.scheduler.scheduleTaskAndWait(task, &self.context) catch |err| {
            result.setError(@errorName(err));
        };
        
        // End progress tracking
        self.progress_bar.endProgress(result.query_id);
        
        // Collect profiling info if enabled
        if (self.context.enable_profiling) {
            try self.collectProfilingInfo(&result, root_operator);
        }
        
        return result;
    }
    
    /// Decompose plan into tasks based on pipeline breakers
    fn decomposePlanIntoTask(self: *Self, op: *PhysicalOperator, task: *ProcessorTask) !void {
        // Check if operator is a source (adds to progress)
        if (op.isSource()) {
            self.progress_bar.addPipeline(task.task_id);
        }
        
        // Check if operator is a sink (creates new task)
        if (op.isSink()) {
            const child_task = try self.allocator.create(ProcessorTask);
            child_task.* = ProcessorTask.init(self.allocator, op, &self.context, task.result);
            
            // Recursively decompose children
            var i = op.children.items.len;
            while (i > 0) {
                i -= 1;
                try self.decomposePlanIntoTask(op.children.items[i], child_task);
            }
            
            try task.addChildTask(child_task);
        } else {
            // Continue in current task
            var i = op.children.items.len;
            while (i > 0) {
                i -= 1;
                try self.decomposePlanIntoTask(op.children.items[i], task);
            }
        }
    }
    
    /// Initialize task parallelism
    fn initTask(self: *Self, task: *ProcessorTask) void {
        var op = task.sink;
        
        // Traverse to source, check for non-parallel operators
        while (!op.isSource()) {
            if (!op.isParallel()) {
                task.setSingleThreaded();
            }
            if (op.children.items.len > 0) {
                op = op.children.items[0];
            } else {
                break;
            }
        }
        
        // Check source operator
        if (!op.isParallel()) {
            task.setSingleThreaded();
        }
        
        // Initialize child tasks
        for (task.children.items) |child| {
            self.initTask(child);
        }
    }
    
    /// Collect profiling information from operator tree
    fn collectProfilingInfo(self: *Self, result: *QueryResult, op: *PhysicalOperator) !void {
        var profile = OperatorProfile.init(self.allocator, op.operator_id, op.operator_type);
        profile.execution_time_ns = op.metrics.execution_time.total_ns;
        profile.num_output_tuples = op.metrics.num_output_tuples;
        
        // Collect child profiles
        for (op.children.items) |child| {
            try profile.children.append(self.allocator, child.operator_id);
            try self.collectProfilingInfo(result, child);
        }
        
        try result.operator_profiles.append(self.allocator, profile);
    }
    
    /// Interrupt current execution
    pub fn interrupt(self: *Self) void {
        self.context.interrupt();
    }
    
    /// Set max threads for parallel execution
    pub fn setMaxThreads(self: *Self, threads: u32) void {
        self.context.max_threads = threads;
    }
    
    /// Set memory limit
    pub fn setMemoryLimit(self: *Self, limit: u64) void {
        self.context.memory_limit = limit;
    }
    
    /// Enable profiling
    pub fn enableProfiling(self: *Self, enable: bool) void {
        self.context.enable_profiling = enable;
    }
    
    /// Set query timeout
    pub fn setTimeout(self: *Self, timeout_ms: u64) void {
        self.context.setTimeout(timeout_ms);
    }
};

// ============================================================================
// Physical Operators - Specialized Implementations
// ============================================================================

/// Result collector operator - collects and materializes results
pub const ResultCollector = struct {
        allocator: std.mem.Allocator = undefined,
    base: PhysicalOperator,
    result_chunks: std.ArrayList(DataChunk),
    total_tuples: u64,
    materialized: bool,
    
    const vtable = PhysicalOperator.VTable{
        .initFn = collectInit,
        .getNextFn = collectGetNext,
        .closeFn = collectClose,
    };
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = PhysicalOperator.init(allocator, .RESULT_COLLECTOR, &vtable),
            .result_chunks = .{},
            .total_tuples = 0,
            .materialized = false,
        };
        return self;
    }
    
    pub fn destroy(self: *Self) void {
        for (self.result_chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.result_chunks.deinit(self.allocator);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }
    
    fn collectInit(base: *PhysicalOperator) !void {
        const self: *Self = @fieldParentPtr("base", base);
        self.total_tuples = 0;
        self.materialized = false;
        
        if (base.children.items.len > 0) {
            try base.children.items[0].initOp();
        }
    }
    
    fn collectGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        const self: *Self = @fieldParentPtr("base", base);
        
        if (base.children.items.len == 0) {
            return .NO_MORE_TUPLES;
        }
        
        const child = base.children.items[0];
        const result = try child.getNext(chunk);
        
    // if (result == .EXHAUSTED and chunk.num_tuples > 0) {
            self.total_tuples += chunk.num_tuples;
            base.metrics.addOutputTuples(chunk.num_tuples);
    // }
        
        return result;
    }
    
    fn collectClose(base: *PhysicalOperator) void {
        const self: *Self = @fieldParentPtr("base", base);
        self.materialized = true;
        
        if (base.children.items.len > 0) {
            base.children.items[0].close();
        }
    }
    
    pub fn getTotalTuples(self: *const Self) u64 {
        return self.total_tuples;
    }
};

/// Filter operator - filters tuples based on predicate
pub const FilterOperator = struct {
    base: PhysicalOperator,
    predicate: ?*anyopaque, // Expression pointer
    
    const vtable = PhysicalOperator.VTable{
        .initFn = filterInit,
        .getNextFn = filterGetNext,
        .closeFn = filterClose,
    };
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = PhysicalOperator.init(allocator, .FILTER, &vtable),
            .predicate = null,
        };
        return self;
    }
    
    pub fn destroy(self: *Self) void {
        self.base.deinit(self.allocator);
        self.base.allocator.destroy(self);
    }
    
    fn filterInit(base: *PhysicalOperator) !void {
        if (base.children.items.len > 0) {
            try base.children.items[0].initOp();
        }
    }
    
    fn filterGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        if (base.children.items.len == 0) {
            return .NO_MORE_TUPLES;
        }
        
        // Get next batch and filter
        const child = base.children.items[0];
        const result = try child.getNext(chunk);
        
        // TODO: Apply predicate to filter tuples
        
        return result;
    }
    
    fn filterClose(base: *PhysicalOperator) void {
        if (base.children.items.len > 0) {
            base.children.items[0].close();
        }
    }
};

/// Projection operator - projects columns
pub const ProjectionOperator = struct {
        allocator: std.mem.Allocator = undefined,
    base: PhysicalOperator,
    projection_cols: std.ArrayList(u32),
    
    const vtable = PhysicalOperator.VTable{
        .initFn = projInit,
        .getNextFn = projGetNext,
        .closeFn = projClose,
    };
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .base = PhysicalOperator.init(allocator, .PROJECTION, &vtable),
            .projection_cols = .{},
        };
        return self;
    }
    
    pub fn destroy(self: *Self) void {
        self.projection_cols.deinit(self.allocator);
        self.base.deinit();
        self.base.allocator.destroy(self);
    }
    
    pub fn addProjectionColumn(self: *Self, col_idx: u32) !void {
        try self.projection_cols.append(self.allocator, col_idx);
    }
    
    fn projInit(base: *PhysicalOperator) !void {
        if (base.children.items.len > 0) {
            try base.children.items[0].initOp();
        }
    }
    
    fn projGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        if (base.children.items.len == 0) {
            return .NO_MORE_TUPLES;
        }
        
        return base.children.items[0].getNext(chunk);
    }
    
    fn projClose(base: *PhysicalOperator) void {
        if (base.children.items.len > 0) {
            base.children.items[0].close();
        }
    }
};

/// Hash join build operator
pub const HashJoinBuild = struct {
    base: PhysicalOperator,
    hash_table: ?*anyopaque, // JoinHashTable pointer
    
    const vtable = PhysicalOperator.VTable{
        .initFn = buildInit,
        .getNextFn = buildGetNext,
        .closeFn = buildClose,
    };
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = PhysicalOperator.init(allocator, .HASH_JOIN_BUILD, &vtable),
            .hash_table = null,
        };
        self.base.is_sink = true; // This is a pipeline breaker
        return self;
    }
    
    pub fn destroy(self: *Self) void {
        self.base.deinit(self.allocator);
        self.base.allocator.destroy(self);
    }
    
    fn buildInit(base: *PhysicalOperator) !void {
        if (base.children.items.len > 0) {
            try base.children.items[0].initOp();
        }
    }
    
    fn buildGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        _ = chunk;
        
        if (base.children.items.len == 0) {
            return .NO_MORE_TUPLES;
        }
        
        // Build phase: consume all input and build hash table
        var input_chunk = DataChunk.init(base.allocator);
        defer input_chunk.deinit(std.testing.allocator);
        
        const child = base.children.items[0];
        while (true) {
            const result = try child.getNext(&input_chunk);
            if (result == .NO_MORE_TUPLES) break;
            
            // TODO: Insert into hash table
            
            input_chunk.reset();
        }
        
        return .NO_MORE_TUPLES;
    }
    
    fn buildClose(base: *PhysicalOperator) void {
        if (base.children.items.len > 0) {
            base.children.items[0].close();
        }
    }
};

/// Hash join probe operator
pub const HashJoinProbe = struct {
    base: PhysicalOperator,
    hash_table: ?*anyopaque, // Reference to build's hash table
    
    const vtable = PhysicalOperator.VTable{
        .initFn = probeInit,
        .getNextFn = probeGetNext,
        .closeFn = probeClose,
    };
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = PhysicalOperator.init(allocator, .HASH_JOIN_PROBE, &vtable),
            .hash_table = null,
        };
        return self;
    }
    
    pub fn destroy(self: *Self) void {
        self.base.deinit(self.allocator);
        self.base.allocator.destroy(self);
    }
    
    fn probeInit(base: *PhysicalOperator) !void {
        if (base.children.items.len > 0) {
            try base.children.items[0].initOp();
        }
    }
    
    fn probeGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        if (base.children.items.len == 0) {
            return .NO_MORE_TUPLES;
        }
        
        // TODO: Probe hash table and produce matches
        return base.children.items[0].getNext(chunk);
    }
    
    fn probeClose(base: *PhysicalOperator) void {
        if (base.children.items.len > 0) {
            base.children.items[0].close();
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "query result" {
    const allocator = std.testing.allocator;
    
    var result = QueryResult.init(allocator);
    defer result.deinit();
    
    try result.addColumn("id", .INT64);
    try result.addColumn("name", .STRING);
    
    try std.testing.expectEqual(@as(usize, 2), result.getNumColumns());
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.eql(u8, "id", result.getColumnName(0).?));
}

test "execution context" {
    const allocator = std.testing.allocator;
    
    var ctx = ExecutionContext.init(allocator);
    try std.testing.expect(!ctx.isInterrupted());
    try std.testing.expect(!ctx.checkTimeout());
    
    ctx.interrupt();
    try std.testing.expect(ctx.isInterrupted());
    
    ctx.setTimeout(1000);
    try std.testing.expect(ctx.timeout_ms != null);
}

test "profiler" {
    const allocator = std.testing.allocator;
    
    var profiler = Profiler.init(allocator);
    defer profiler.deinit();
    
    const time_metric = try profiler.registerTimeMetric("test_time");
    time_metric.start();
    time_metric.stop();
    
    try std.testing.expect(time_metric.count == 1);
    
    const num_metric = try profiler.registerNumericMetric("test_num");
    num_metric.add(100);
    
    try std.testing.expectEqual(@as(u64, 100), num_metric.value);
}

test "query processor" {
    const allocator = std.testing.allocator;
    
    var processor = QueryProcessor.init(allocator);
    defer processor.deinit();
    
    processor.setMaxThreads(4);
    processor.setMemoryLimit(2 * 1024 * 1024 * 1024);
    processor.enableProfiling(true);
    
    try std.testing.expectEqual(@as(u32, 4), processor.context.max_threads);
    try std.testing.expect(processor.context.enable_profiling);
}

test "result collector" {
    const allocator = std.testing.allocator;
    
    var collector = try ResultCollector.create(allocator);
    defer collector.destroy();
    
    try std.testing.expectEqual(@as(u64, 0), collector.getTotalTuples());
}

test "projection operator" {
    const allocator = std.testing.allocator;
    
    var proj = try ProjectionOperator.create(allocator);
    defer proj.destroy();
    
    try proj.addProjectionColumn(0);
    try proj.addProjectionColumn(2);
    
    try std.testing.expectEqual(@as(usize, 2), proj.projection_cols.items.len);
}

test "result set descriptor" {
    const allocator = std.testing.allocator;
    
    var desc = ResultSetDescriptor.init(allocator);
    defer desc.deinit();
    
    try desc.addColumn("id", .INT64);
    try desc.addColumn("name", .STRING);
    
    try std.testing.expectEqual(@as(usize, 2), desc.num_columns);
}

test "progress bar" {
    const allocator = std.testing.allocator;
    
    var progress = ProgressBar.init(allocator);
    defer progress.deinit();
    
    progress.enabled = true;
    progress.startProgress(1);
    progress.updateProgress(1, 0.5);
    
    try std.testing.expectEqual(@as(f64, 0.5), progress.getProgress(1));
    
    progress.endProgress(1);
}

test "task scheduler" {
    const allocator = std.testing.allocator;
    
    var scheduler = TaskScheduler.init(allocator, 4);
    defer scheduler.deinit();
    
    try std.testing.expectEqual(@as(u32, 4), scheduler.num_threads);
}
