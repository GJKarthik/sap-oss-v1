//! SAP HANA Native ODBC Connection Management
//! Production-grade connection pooling with persistent sockets
//! Eliminates process-spawning overhead of hdbsql CLI

const std = @import("std");
const odbc = @import("odbc_bindings");

const log = std.log.scoped(.odbc_connection);

// ============================================================================
// ODBC Environment (Singleton)
// ============================================================================

var global_env: ?odbc.SQLHENV = null;
var global_env_mutex: std.Thread.Mutex = .{};
var global_env_initialized: bool = false;

pub fn initializeOdbcEnvironment() !void {
    global_env_mutex.lock();
    defer global_env_mutex.unlock();

    if (global_env_initialized) return;

    // Allocate environment handle
    var env: odbc.SQLHANDLE = null;
    var ret = odbc.SQLAllocHandle(odbc.SQL_HANDLE_ENV, null, &env);
    if (odbc.failed(ret)) {
        log.err("Failed to allocate ODBC environment handle", .{});
        return error.OdbcEnvironmentAllocationFailed;
    }

    // Set ODBC version to 3.80
    ret = odbc.SQLSetEnvAttr(
        env,
        odbc.SQL_ATTR_ODBC_VERSION,
        @ptrFromInt(odbc.SQL_OV_ODBC3_80),
        0,
    );
    if (odbc.failed(ret)) {
        _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_ENV, env);
        log.err("Failed to set ODBC version attribute", .{});
        return error.OdbcVersionSetFailed;
    }

    global_env = env;
    global_env_initialized = true;
    log.info("ODBC environment initialized successfully", .{});
}

pub fn getOdbcEnvironment() !odbc.SQLHENV {
    if (!global_env_initialized) {
        try initializeOdbcEnvironment();
    }
    return global_env orelse error.OdbcEnvironmentNotInitialized;
}

pub fn shutdownOdbcEnvironment() void {
    global_env_mutex.lock();
    defer global_env_mutex.unlock();

    if (global_env) |env| {
        _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_ENV, env);
        global_env = null;
        global_env_initialized = false;
        log.info("ODBC environment shutdown complete", .{});
    }
}

// ============================================================================
// Connection Configuration
// ============================================================================

pub const OdbcConfig = struct {
    host: []const u8,
    port: u16 = 443,
    user: []const u8,
    password: []const u8,
    schema: []const u8 = "AIPROMPT_STORAGE",
    connection_timeout_sec: u32 = 30,
    login_timeout_sec: u32 = 30,
    query_timeout_sec: u32 = 60,
    auto_commit: bool = true,
    read_only: bool = false,

    pub fn fromEnv(allocator: std.mem.Allocator) !OdbcConfig {
        const host = std.process.getEnvVarOwned(allocator, "HANA_HOST") catch "localhost";
        const port_str = std.process.getEnvVarOwned(allocator, "HANA_PORT") catch "443";
        const port = std.fmt.parseInt(u16, port_str, 10) catch 443;
        const user = std.process.getEnvVarOwned(allocator, "HANA_USER") catch "SYSTEM";
        const password = std.process.getEnvVarOwned(allocator, "HANA_PASSWORD") catch "";
        const schema = std.process.getEnvVarOwned(allocator, "HANA_SCHEMA") catch "AIPROMPT_STORAGE";

        return .{
            .host = host,
            .port = port,
            .user = user,
            .password = password,
            .schema = schema,
        };
    }
};

// ============================================================================
// Native ODBC Connection
// ============================================================================

pub const OdbcConnection = struct {
    allocator: std.mem.Allocator,
    config: OdbcConfig,
    dbc_handle: odbc.SQLHDBC,
    id: u64,
    state: ConnectionState,
    created_at: i64,
    last_used_at: i64,
    total_queries: std.atomic.Value(u64),
    total_errors: std.atomic.Value(u64),

    // Prepared statement cache
    stmt_cache: std.StringHashMap(*PreparedStatement),
    stmt_cache_mutex: std.Thread.Mutex,

    pub const ConnectionState = enum {
        Disconnected,
        Connecting,
        Connected,
        InTransaction,
        Error,
        Closed,
    };

    pub fn init(allocator: std.mem.Allocator, config: OdbcConfig, id: u64) !*OdbcConnection {
        const env = try getOdbcEnvironment();

        // Allocate connection handle
        var dbc: odbc.SQLHANDLE = null;
        const ret = odbc.SQLAllocHandle(odbc.SQL_HANDLE_DBC, env, &dbc);
        if (odbc.failed(ret)) {
            log.err("Failed to allocate ODBC connection handle", .{});
            return error.OdbcConnectionAllocationFailed;
        }

        const conn = try allocator.create(OdbcConnection);
        conn.* = .{
            .allocator = allocator,
            .config = config,
            .dbc_handle = dbc,
            .id = id,
            .state = .Disconnected,
            .created_at = std.time.milliTimestamp(),
            .last_used_at = std.time.milliTimestamp(),
            .total_queries = std.atomic.Value(u64).init(0),
            .total_errors = std.atomic.Value(u64).init(0),
            .stmt_cache = std.StringHashMap(*PreparedStatement).init(allocator),
            .stmt_cache_mutex = .{},
        };

        return conn;
    }

    pub fn deinit(self: *OdbcConnection) void {
        self.disconnect();

        // Free cached prepared statements
        self.stmt_cache_mutex.lock();
        var iter = self.stmt_cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.stmt_cache.deinit();
        self.stmt_cache_mutex.unlock();

        if (self.dbc_handle) |dbc| {
            _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_DBC, dbc);
        }

        self.allocator.destroy(self);
    }

    pub fn connect(self: *OdbcConnection) !void {
        if (self.state == .Connected) return;

        self.state = .Connecting;
        log.info("Connecting to HANA: {s}:{} (connection {})", .{ self.config.host, self.config.port, self.id });

        // Set connection timeout
        var ret = odbc.SQLSetConnectAttr(
            self.dbc_handle,
            odbc.SQL_ATTR_CONNECTION_TIMEOUT,
            @ptrFromInt(self.config.connection_timeout_sec),
            0,
        );
        if (odbc.failed(ret)) {
            log.warn("Failed to set connection timeout", .{});
        }

        // Set login timeout
        ret = odbc.SQLSetConnectAttr(
            self.dbc_handle,
            odbc.SQL_ATTR_LOGIN_TIMEOUT,
            @ptrFromInt(self.config.login_timeout_sec),
            0,
        );
        if (odbc.failed(ret)) {
            log.warn("Failed to set login timeout", .{});
        }

        // Build connection string
        const conn_str = try odbc.formatHanaConnectionString(
            self.allocator,
            self.config.host,
            self.config.port,
            self.config.user,
            self.config.password,
            self.config.schema,
        );
        defer self.allocator.free(conn_str);

        // Connect using driver connection string
        var out_conn_str: [1024]odbc.SQLCHAR = undefined;
        var out_len: odbc.SQLSMALLINT = 0;

        ret = odbc.SQLDriverConnect(
            self.dbc_handle,
            null,
            conn_str.ptr,
            @intCast(conn_str.len),
            &out_conn_str,
            @intCast(out_conn_str.len),
            &out_len,
            odbc.SQL_DRIVER_NOPROMPT,
        );

        if (odbc.failed(ret)) {
            self.state = .Error;
            const diags = odbc.getDiagnostics(self.allocator, odbc.SQL_HANDLE_DBC, self.dbc_handle) catch &[_]odbc.DiagRecord{};
            defer {
                for (diags) |*d| {
                    var diag = d;
                    diag.deinit(self.allocator);
                }
                self.allocator.free(diags);
            }
            for (diags) |diag| {
                log.err("ODBC Error [{s}]: {s}", .{ diag.getSqlState(), diag.message });
            }
            return error.OdbcConnectionFailed;
        }

        // Set auto-commit mode
        ret = odbc.SQLSetConnectAttr(
            self.dbc_handle,
            odbc.SQL_ATTR_AUTOCOMMIT,
            @ptrFromInt(if (self.config.auto_commit) odbc.SQL_AUTOCOMMIT_ON else odbc.SQL_AUTOCOMMIT_OFF),
            0,
        );
        if (odbc.failed(ret)) {
            log.warn("Failed to set auto-commit mode", .{});
        }

        self.state = .Connected;
        self.last_used_at = std.time.milliTimestamp();
        log.info("Connected to HANA successfully (connection {})", .{self.id});
    }

    pub fn disconnect(self: *OdbcConnection) void {
        if (self.state == .Disconnected or self.state == .Closed) return;

        if (self.dbc_handle) |dbc| {
            _ = odbc.SQLDisconnect(dbc);
        }

        self.state = .Disconnected;
        log.debug("Disconnected HANA connection {}", .{self.id});
    }

    pub fn isConnected(self: *OdbcConnection) bool {
        return self.state == .Connected or self.state == .InTransaction;
    }

    pub fn reconnect(self: *OdbcConnection) !void {
        self.disconnect();
        try self.connect();
    }

    // =========================================================================
    // Transaction Management
    // =========================================================================

    pub fn beginTransaction(self: *OdbcConnection) !void {
        if (!self.isConnected()) return error.NotConnected;

        // Disable auto-commit to start transaction
        const ret = odbc.SQLSetConnectAttr(
            self.dbc_handle,
            odbc.SQL_ATTR_AUTOCOMMIT,
            @ptrFromInt(odbc.SQL_AUTOCOMMIT_OFF),
            0,
        );
        if (odbc.failed(ret)) {
            return error.TransactionStartFailed;
        }

        self.state = .InTransaction;
        log.debug("Started transaction on connection {}", .{self.id});
    }

    pub fn commit(self: *OdbcConnection) !void {
        if (self.state != .InTransaction) return error.NoActiveTransaction;

        const ret = odbc.SQLEndTran(odbc.SQL_HANDLE_DBC, self.dbc_handle, odbc.SQL_COMMIT);
        if (odbc.failed(ret)) {
            return error.CommitFailed;
        }

        // Restore auto-commit if configured
        if (self.config.auto_commit) {
            _ = odbc.SQLSetConnectAttr(
                self.dbc_handle,
                odbc.SQL_ATTR_AUTOCOMMIT,
                @ptrFromInt(odbc.SQL_AUTOCOMMIT_ON),
                0,
            );
        }

        self.state = .Connected;
        log.debug("Committed transaction on connection {}", .{self.id});
    }

    pub fn rollback(self: *OdbcConnection) !void {
        if (self.state != .InTransaction) return error.NoActiveTransaction;

        const ret = odbc.SQLEndTran(odbc.SQL_HANDLE_DBC, self.dbc_handle, odbc.SQL_ROLLBACK);
        if (odbc.failed(ret)) {
            return error.RollbackFailed;
        }

        // Restore auto-commit if configured
        if (self.config.auto_commit) {
            _ = odbc.SQLSetConnectAttr(
                self.dbc_handle,
                odbc.SQL_ATTR_AUTOCOMMIT,
                @ptrFromInt(odbc.SQL_AUTOCOMMIT_ON),
                0,
            );
        }

        self.state = .Connected;
        log.debug("Rolled back transaction on connection {}", .{self.id});
    }

    // =========================================================================
    // Query Execution
    // =========================================================================

    pub fn execute(self: *OdbcConnection, sql: []const u8) !void {
        if (!self.isConnected()) return error.NotConnected;

        var stmt: odbc.SQLHANDLE = null;
        var ret = odbc.SQLAllocHandle(odbc.SQL_HANDLE_STMT, self.dbc_handle, &stmt);
        if (odbc.failed(ret)) {
            return error.StatementAllocationFailed;
        }
        defer _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_STMT, stmt);

        // Set query timeout
        ret = odbc.SQLSetStmtAttr(
            stmt,
            odbc.SQL_ATTR_QUERY_TIMEOUT,
            @ptrFromInt(self.config.query_timeout_sec),
            0,
        );

        // Execute the SQL
        ret = odbc.SQLExecDirect(stmt, sql.ptr, @intCast(sql.len));

        _ = self.total_queries.fetchAdd(1, .monotonic);
        self.last_used_at = std.time.milliTimestamp();

        if (odbc.failed(ret)) {
            _ = self.total_errors.fetchAdd(1, .monotonic);
            const diags = odbc.getDiagnostics(self.allocator, odbc.SQL_HANDLE_STMT, stmt) catch &[_]odbc.DiagRecord{};
            defer {
                for (diags) |*d| {
                    var diag = d;
                    diag.deinit(self.allocator);
                }
                self.allocator.free(diags);
            }
            for (diags) |diag| {
                log.err("SQL Error [{s}]: {s}", .{ diag.getSqlState(), diag.message });
            }
            return error.QueryExecutionFailed;
        }

        log.debug("Executed SQL on connection {}: {s}...", .{ self.id, sql[0..@min(50, sql.len)] });
    }

    pub fn executeQuery(self: *OdbcConnection, sql: []const u8) !*ResultSet {
        if (!self.isConnected()) return error.NotConnected;

        var stmt: odbc.SQLHANDLE = null;
        var ret = odbc.SQLAllocHandle(odbc.SQL_HANDLE_STMT, self.dbc_handle, &stmt);
        if (odbc.failed(ret)) {
            return error.StatementAllocationFailed;
        }

        // Set query timeout
        ret = odbc.SQLSetStmtAttr(
            stmt,
            odbc.SQL_ATTR_QUERY_TIMEOUT,
            @ptrFromInt(self.config.query_timeout_sec),
            0,
        );

        // Execute the query
        ret = odbc.SQLExecDirect(stmt, sql.ptr, @intCast(sql.len));

        _ = self.total_queries.fetchAdd(1, .monotonic);
        self.last_used_at = std.time.milliTimestamp();

        if (odbc.failed(ret)) {
            _ = self.total_errors.fetchAdd(1, .monotonic);
            _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_STMT, stmt);
            return error.QueryExecutionFailed;
        }

        // Create result set
        const result_set = try self.allocator.create(ResultSet);
        result_set.* = ResultSet.init(self.allocator, stmt);

        return result_set;
    }

    // =========================================================================
    // Prepared Statement Support
    // =========================================================================

    pub fn prepare(self: *OdbcConnection, sql: []const u8) !*PreparedStatement {
        // Check cache first
        self.stmt_cache_mutex.lock();
        if (self.stmt_cache.get(sql)) |cached| {
            self.stmt_cache_mutex.unlock();
            return cached;
        }
        self.stmt_cache_mutex.unlock();

        if (!self.isConnected()) return error.NotConnected;

        var stmt: odbc.SQLHANDLE = null;
        var ret = odbc.SQLAllocHandle(odbc.SQL_HANDLE_STMT, self.dbc_handle, &stmt);
        if (odbc.failed(ret)) {
            return error.StatementAllocationFailed;
        }

        ret = odbc.SQLPrepare(stmt, sql.ptr, @intCast(sql.len));
        if (odbc.failed(ret)) {
            _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_STMT, stmt);
            return error.PrepareFailed;
        }

        const prepared = try self.allocator.create(PreparedStatement);
        prepared.* = .{
            .allocator = self.allocator,
            .stmt_handle = stmt,
            .sql = try self.allocator.dupe(u8, sql),
            .param_count = 0,
            .execution_count = std.atomic.Value(u64).init(0),
        };

        // Cache the prepared statement
        self.stmt_cache_mutex.lock();
        const sql_key = try self.allocator.dupe(u8, sql);
        try self.stmt_cache.put(sql_key, prepared);
        self.stmt_cache_mutex.unlock();

        log.debug("Prepared statement cached: {s}...", .{sql[0..@min(50, sql.len)]});

        return prepared;
    }

    // =========================================================================
    // Stats
    // =========================================================================

    pub fn getStats(self: *OdbcConnection) ConnectionStats {
        return .{
            .id = self.id,
            .state = self.state,
            .created_at = self.created_at,
            .last_used_at = self.last_used_at,
            .total_queries = self.total_queries.load(.monotonic),
            .total_errors = self.total_errors.load(.monotonic),
            .cached_statements = @intCast(self.stmt_cache.count()),
        };
    }
};

pub const ConnectionStats = struct {
    id: u64,
    state: OdbcConnection.ConnectionState,
    created_at: i64,
    last_used_at: i64,
    total_queries: u64,
    total_errors: u64,
    cached_statements: u32,
};

// ============================================================================
// Prepared Statement
// ============================================================================

pub const PreparedStatement = struct {
    allocator: std.mem.Allocator,
    stmt_handle: odbc.SQLHSTMT,
    sql: []const u8,
    param_count: u32,
    execution_count: std.atomic.Value(u64),

    pub fn deinit(self: *PreparedStatement) void {
        if (self.stmt_handle) |stmt| {
            _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_STMT, stmt);
        }
        self.allocator.free(self.sql);
    }

    pub fn execute(self: *PreparedStatement) !void {
        const ret = odbc.SQLExecute(self.stmt_handle);
        _ = self.execution_count.fetchAdd(1, .monotonic);

        if (odbc.failed(ret)) {
            return error.ExecuteFailed;
        }
    }

    pub fn bindInt64(self: *PreparedStatement, param_num: u16, value: *i64, indicator: *odbc.SQLLEN) !void {
        const ret = odbc.SQLBindParameter(
            self.stmt_handle,
            param_num,
            odbc.SQL_PARAM_INPUT,
            odbc.SQL_C_SBIGINT,
            odbc.SQL_BIGINT,
            0,
            0,
            @ptrCast(value),
            @sizeOf(i64),
            indicator,
        );
        if (odbc.failed(ret)) {
            return error.BindParameterFailed;
        }
    }

    pub fn bindInt32(self: *PreparedStatement, param_num: u16, value: *i32, indicator: *odbc.SQLLEN) !void {
        const ret = odbc.SQLBindParameter(
            self.stmt_handle,
            param_num,
            odbc.SQL_PARAM_INPUT,
            odbc.SQL_C_SLONG,
            odbc.SQL_INTEGER,
            0,
            0,
            @ptrCast(value),
            @sizeOf(i32),
            indicator,
        );
        if (odbc.failed(ret)) {
            return error.BindParameterFailed;
        }
    }

    pub fn bindString(self: *PreparedStatement, param_num: u16, value: []const u8, indicator: *odbc.SQLLEN) !void {
        indicator.* = @intCast(value.len);
        const ret = odbc.SQLBindParameter(
            self.stmt_handle,
            param_num,
            odbc.SQL_PARAM_INPUT,
            odbc.SQL_C_CHAR,
            odbc.SQL_VARCHAR,
            @intCast(value.len),
            0,
            @constCast(@ptrCast(value.ptr)),
            @intCast(value.len),
            indicator,
        );
        if (odbc.failed(ret)) {
            return error.BindParameterFailed;
        }
    }

    pub fn bindBlob(self: *PreparedStatement, param_num: u16, value: []const u8, indicator: *odbc.SQLLEN) !void {
        indicator.* = @intCast(value.len);
        const ret = odbc.SQLBindParameter(
            self.stmt_handle,
            param_num,
            odbc.SQL_PARAM_INPUT,
            odbc.SQL_C_BINARY,
            odbc.SQL_LONGVARBINARY,
            @intCast(value.len),
            0,
            @constCast(@ptrCast(value.ptr)),
            @intCast(value.len),
            indicator,
        );
        if (odbc.failed(ret)) {
            return error.BindParameterFailed;
        }
    }

    pub fn reset(self: *PreparedStatement) void {
        _ = odbc.SQLFreeStmt(self.stmt_handle, odbc.SQL_RESET_PARAMS);
        _ = odbc.SQLCloseCursor(self.stmt_handle);
    }
};

// ============================================================================
// Result Set
// ============================================================================

pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    stmt_handle: odbc.SQLHSTMT,
    column_count: u16,
    row_count: i64,
    fetched: bool,

    pub fn init(allocator: std.mem.Allocator, stmt: odbc.SQLHSTMT) ResultSet {
        var col_count: odbc.SQLSMALLINT = 0;
        _ = odbc.SQLNumResultCols(stmt, &col_count);

        return .{
            .allocator = allocator,
            .stmt_handle = stmt,
            .column_count = @intCast(col_count),
            .row_count = 0,
            .fetched = false,
        };
    }

    pub fn deinit(self: *ResultSet) void {
        if (self.stmt_handle) |stmt| {
            _ = odbc.SQLFreeHandle(odbc.SQL_HANDLE_STMT, stmt);
        }
        self.allocator.destroy(self);
    }

    pub fn next(self: *ResultSet) !bool {
        const ret = odbc.SQLFetch(self.stmt_handle);

        if (ret == odbc.SQL_NO_DATA) {
            return false;
        }

        if (odbc.failed(ret)) {
            return error.FetchFailed;
        }

        self.fetched = true;
        self.row_count += 1;
        return true;
    }

    pub fn getInt64(self: *ResultSet, col: u16) !?i64 {
        var value: i64 = 0;
        var indicator: odbc.SQLLEN = 0;

        const ret = odbc.SQLGetData(
            self.stmt_handle,
            col,
            odbc.SQL_C_SBIGINT,
            @ptrCast(&value),
            @sizeOf(i64),
            &indicator,
        );

        if (odbc.failed(ret)) {
            return error.GetDataFailed;
        }

        if (indicator == odbc.SQL_NULL_DATA) {
            return null;
        }

        return value;
    }

    pub fn getInt32(self: *ResultSet, col: u16) !?i32 {
        var value: i32 = 0;
        var indicator: odbc.SQLLEN = 0;

        const ret = odbc.SQLGetData(
            self.stmt_handle,
            col,
            odbc.SQL_C_SLONG,
            @ptrCast(&value),
            @sizeOf(i32),
            &indicator,
        );

        if (odbc.failed(ret)) {
            return error.GetDataFailed;
        }

        if (indicator == odbc.SQL_NULL_DATA) {
            return null;
        }

        return value;
    }

    pub fn getString(self: *ResultSet, col: u16, max_len: usize) !?[]u8 {
        var buffer = try self.allocator.alloc(u8, max_len);
        var indicator: odbc.SQLLEN = 0;

        const ret = odbc.SQLGetData(
            self.stmt_handle,
            col,
            odbc.SQL_C_CHAR,
            @ptrCast(buffer.ptr),
            @intCast(max_len),
            &indicator,
        );

        if (odbc.failed(ret)) {
            self.allocator.free(buffer);
            return error.GetDataFailed;
        }

        if (indicator == odbc.SQL_NULL_DATA) {
            self.allocator.free(buffer);
            return null;
        }

        const actual_len: usize = @intCast(indicator);
        if (actual_len < max_len) {
            buffer = try self.allocator.realloc(buffer, actual_len);
        }

        return buffer;
    }

    pub fn getBlob(self: *ResultSet, col: u16, max_len: usize) !?[]u8 {
        var buffer = try self.allocator.alloc(u8, max_len);
        var indicator: odbc.SQLLEN = 0;

        const ret = odbc.SQLGetData(
            self.stmt_handle,
            col,
            odbc.SQL_C_BINARY,
            @ptrCast(buffer.ptr),
            @intCast(max_len),
            &indicator,
        );

        if (odbc.failed(ret)) {
            self.allocator.free(buffer);
            return error.GetDataFailed;
        }

        if (indicator == odbc.SQL_NULL_DATA) {
            self.allocator.free(buffer);
            return null;
        }

        const actual_len: usize = @intCast(indicator);
        if (actual_len < max_len) {
            buffer = try self.allocator.realloc(buffer, actual_len);
        }

        return buffer;
    }

    pub fn close(self: *ResultSet) void {
        _ = odbc.SQLCloseCursor(self.stmt_handle);
    }
};

// ============================================================================
// Native Connection Pool
// ============================================================================

pub const NativeConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: OdbcConfig,
    connections: std.ArrayList(*OdbcConnection),
    mutex: std.Thread.Mutex,
    next_id: std.atomic.Value(u64),
    min_connections: u32,
    max_connections: u32,
    is_initialized: bool,

    // Pool statistics
    total_acquired: std.atomic.Value(u64),
    total_released: std.atomic.Value(u64),
    wait_time_total_ns: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: OdbcConfig, min_conn: u32, max_conn: u32) NativeConnectionPool {
        return .{
            .allocator = allocator,
            .config = config,
            .connections = std.ArrayList(*OdbcConnection).init(allocator),
            .mutex = .{},
            .next_id = std.atomic.Value(u64).init(0),
            .min_connections = min_conn,
            .max_connections = max_conn,
            .is_initialized = false,
            .total_acquired = std.atomic.Value(u64).init(0),
            .total_released = std.atomic.Value(u64).init(0),
            .wait_time_total_ns = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *NativeConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |conn| {
            conn.deinit();
        }
        self.connections.deinit();

        log.info("Connection pool shut down", .{});
    }

    pub fn initialize(self: *NativeConnectionPool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_initialized) return;

        // Initialize ODBC environment
        try initializeOdbcEnvironment();

        log.info("Initializing native HANA connection pool (min={}, max={})", .{
            self.min_connections,
            self.max_connections,
        });

        // Create minimum connections
        var i: u32 = 0;
        while (i < self.min_connections) : (i += 1) {
            const conn = try self.createConnection();
            try conn.connect();
            try self.connections.append(conn);
        }

        self.is_initialized = true;
        log.info("Native connection pool initialized with {} connections", .{self.connections.items.len});
    }

    fn createConnection(self: *NativeConnectionPool) !*OdbcConnection {
        const id = self.next_id.fetchAdd(1, .monotonic);
        return OdbcConnection.init(self.allocator, self.config, id);
    }

    pub fn acquire(self: *NativeConnectionPool) !*OdbcConnection {
        const start_time = std.time.nanoTimestamp();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Find an idle connected connection
        for (self.connections.items) |conn| {
            if (conn.state == .Connected) {
                _ = self.total_acquired.fetchAdd(1, .monotonic);
                const elapsed = std.time.nanoTimestamp() - start_time;
                _ = self.wait_time_total_ns.fetchAdd(@intCast(elapsed), .monotonic);
                return conn;
            }
        }

        // Try to reconnect a disconnected connection
        for (self.connections.items) |conn| {
            if (conn.state == .Disconnected or conn.state == .Error) {
                conn.reconnect() catch continue;
                _ = self.total_acquired.fetchAdd(1, .monotonic);
                const elapsed = std.time.nanoTimestamp() - start_time;
                _ = self.wait_time_total_ns.fetchAdd(@intCast(elapsed), .monotonic);
                return conn;
            }
        }

        // Create new connection if under max
        if (self.connections.items.len < self.max_connections) {
            const conn = try self.createConnection();
            try conn.connect();
            try self.connections.append(conn);
            _ = self.total_acquired.fetchAdd(1, .monotonic);
            const elapsed = std.time.nanoTimestamp() - start_time;
            _ = self.wait_time_total_ns.fetchAdd(@intCast(elapsed), .monotonic);
            return conn;
        }

        return error.NoAvailableConnections;
    }

    pub fn release(self: *NativeConnectionPool, conn: *OdbcConnection) void {
        _ = self;
        // Connection stays in pool, just update last used time
        conn.last_used_at = std.time.milliTimestamp();
        _ = conn.total_queries.fetchAdd(0, .monotonic); // Touch for stats
    }

    pub fn getStats(self: *NativeConnectionPool) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var connected: u32 = 0;
        var disconnected: u32 = 0;
        var total_queries: u64 = 0;
        var total_errors: u64 = 0;

        for (self.connections.items) |conn| {
            if (conn.isConnected()) {
                connected += 1;
            } else {
                disconnected += 1;
            }
            total_queries += conn.total_queries.load(.monotonic);
            total_errors += conn.total_errors.load(.monotonic);
        }

        return .{
            .total_connections = @intCast(self.connections.items.len),
            .connected = connected,
            .disconnected = disconnected,
            .total_acquired = self.total_acquired.load(.monotonic),
            .total_released = self.total_released.load(.monotonic),
            .total_queries = total_queries,
            .total_errors = total_errors,
            .avg_wait_time_ns = if (self.total_acquired.load(.monotonic) > 0)
                self.wait_time_total_ns.load(.monotonic) / self.total_acquired.load(.monotonic)
            else
                0,
        };
    }
};

pub const PoolStats = struct {
    total_connections: u32,
    connected: u32,
    disconnected: u32,
    total_acquired: u64,
    total_released: u64,
    total_queries: u64,
    total_errors: u64,
    avg_wait_time_ns: u64,
};

// ============================================================================
// Tests
// ============================================================================

test "OdbcConfig fromEnv defaults" {
    // This test just ensures the struct works
    const config = OdbcConfig{
        .host = "localhost",
        .user = "test",
        .password = "test",
    };
    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(u16, 443), config.port);
}

test "NativeConnectionPool init" {
    const allocator = std.testing.allocator;
    var pool = NativeConnectionPool.init(allocator, .{
        .host = "localhost",
        .user = "test",
        .password = "test",
    }, 1, 5);
    defer pool.deinit();

    try std.testing.expect(!pool.is_initialized);
    try std.testing.expectEqual(@as(u32, 1), pool.min_connections);
    try std.testing.expectEqual(@as(u32, 5), pool.max_connections);
}