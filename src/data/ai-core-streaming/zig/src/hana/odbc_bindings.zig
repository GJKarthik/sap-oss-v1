//! SAP HANA ODBC C-ABI Bindings
//! Native bindings to libodbc for high-performance database access
//! Eliminates shell-out overhead and credential exposure in process listings

const std = @import("std");

// ============================================================================
// ODBC Types (from sql.h, sqlext.h, sqltypes.h)
// ============================================================================

pub const SQLCHAR = u8;
pub const SQLWCHAR = u16;
pub const SQLSCHAR = i8;
pub const SQLSMALLINT = i16;
pub const SQLUSMALLINT = u16;
pub const SQLINTEGER = i32;
pub const SQLUINTEGER = u32;
pub const SQLLEN = i64;
pub const SQLULEN = u64;
pub const SQLREAL = f32;
pub const SQLDOUBLE = f64;
pub const SQLPOINTER = ?*anyopaque;
pub const SQLHANDLE = ?*anyopaque;
pub const SQLHENV = SQLHANDLE;
pub const SQLHDBC = SQLHANDLE;
pub const SQLHSTMT = SQLHANDLE;
pub const SQLHDESC = SQLHANDLE;
pub const SQLRETURN = SQLSMALLINT;

// ============================================================================
// Return Codes
// ============================================================================

pub const SQL_SUCCESS: SQLRETURN = 0;
pub const SQL_SUCCESS_WITH_INFO: SQLRETURN = 1;
pub const SQL_NO_DATA: SQLRETURN = 100;
pub const SQL_ERROR: SQLRETURN = -1;
pub const SQL_INVALID_HANDLE: SQLRETURN = -2;
pub const SQL_STILL_EXECUTING: SQLRETURN = 2;
pub const SQL_NEED_DATA: SQLRETURN = 99;

// ============================================================================
// Handle Types
// ============================================================================

pub const SQL_HANDLE_ENV: SQLSMALLINT = 1;
pub const SQL_HANDLE_DBC: SQLSMALLINT = 2;
pub const SQL_HANDLE_STMT: SQLSMALLINT = 3;
pub const SQL_HANDLE_DESC: SQLSMALLINT = 4;

// ============================================================================
// Environment Attributes
// ============================================================================

pub const SQL_ATTR_ODBC_VERSION: SQLINTEGER = 200;
pub const SQL_ATTR_CONNECTION_POOLING: SQLINTEGER = 201;
pub const SQL_ATTR_CP_MATCH: SQLINTEGER = 202;
pub const SQL_ATTR_OUTPUT_NTS: SQLINTEGER = 10001;

pub const SQL_OV_ODBC3: SQLULEN = 3;
pub const SQL_OV_ODBC3_80: SQLULEN = 380;

// ============================================================================
// Connection Attributes
// ============================================================================

pub const SQL_ATTR_ACCESS_MODE: SQLINTEGER = 101;
pub const SQL_ATTR_AUTOCOMMIT: SQLINTEGER = 102;
pub const SQL_ATTR_CONNECTION_TIMEOUT: SQLINTEGER = 113;
pub const SQL_ATTR_CURRENT_CATALOG: SQLINTEGER = 109;
pub const SQL_ATTR_LOGIN_TIMEOUT: SQLINTEGER = 103;
pub const SQL_ATTR_PACKET_SIZE: SQLINTEGER = 112;
pub const SQL_ATTR_TRACE: SQLINTEGER = 104;
pub const SQL_ATTR_TRACEFILE: SQLINTEGER = 105;
pub const SQL_ATTR_TRANSLATE_LIB: SQLINTEGER = 106;
pub const SQL_ATTR_TRANSLATE_OPTION: SQLINTEGER = 107;
pub const SQL_ATTR_TXN_ISOLATION: SQLINTEGER = 108;

pub const SQL_AUTOCOMMIT_OFF: SQLULEN = 0;
pub const SQL_AUTOCOMMIT_ON: SQLULEN = 1;

pub const SQL_MODE_READ_ONLY: SQLULEN = 1;
pub const SQL_MODE_READ_WRITE: SQLULEN = 0;

// ============================================================================
// Statement Attributes
// ============================================================================

pub const SQL_ATTR_CURSOR_TYPE: SQLINTEGER = 6;
pub const SQL_ATTR_ROW_ARRAY_SIZE: SQLINTEGER = 27;
pub const SQL_ATTR_ROW_STATUS_PTR: SQLINTEGER = 25;
pub const SQL_ATTR_ROWS_FETCHED_PTR: SQLINTEGER = 26;
pub const SQL_ATTR_PARAM_BIND_TYPE: SQLINTEGER = 18;
pub const SQL_ATTR_PARAMSET_SIZE: SQLINTEGER = 22;
pub const SQL_ATTR_PARAM_STATUS_PTR: SQLINTEGER = 20;
pub const SQL_ATTR_PARAMS_PROCESSED_PTR: SQLINTEGER = 21;
pub const SQL_ATTR_QUERY_TIMEOUT: SQLINTEGER = 0;

pub const SQL_CURSOR_FORWARD_ONLY: SQLULEN = 0;
pub const SQL_CURSOR_KEYSET_DRIVEN: SQLULEN = 1;
pub const SQL_CURSOR_DYNAMIC: SQLULEN = 2;
pub const SQL_CURSOR_STATIC: SQLULEN = 3;

// ============================================================================
// SQL Data Types
// ============================================================================

pub const SQL_UNKNOWN_TYPE: SQLSMALLINT = 0;
pub const SQL_CHAR: SQLSMALLINT = 1;
pub const SQL_NUMERIC: SQLSMALLINT = 2;
pub const SQL_DECIMAL: SQLSMALLINT = 3;
pub const SQL_INTEGER: SQLSMALLINT = 4;
pub const SQL_SMALLINT: SQLSMALLINT = 5;
pub const SQL_FLOAT: SQLSMALLINT = 6;
pub const SQL_REAL: SQLSMALLINT = 7;
pub const SQL_DOUBLE: SQLSMALLINT = 8;
pub const SQL_DATETIME: SQLSMALLINT = 9;
pub const SQL_VARCHAR: SQLSMALLINT = 12;
pub const SQL_TYPE_DATE: SQLSMALLINT = 91;
pub const SQL_TYPE_TIME: SQLSMALLINT = 92;
pub const SQL_TYPE_TIMESTAMP: SQLSMALLINT = 93;
pub const SQL_LONGVARCHAR: SQLSMALLINT = -1;
pub const SQL_BINARY: SQLSMALLINT = -2;
pub const SQL_VARBINARY: SQLSMALLINT = -3;
pub const SQL_LONGVARBINARY: SQLSMALLINT = -4;
pub const SQL_BIGINT: SQLSMALLINT = -5;
pub const SQL_TINYINT: SQLSMALLINT = -6;
pub const SQL_BIT: SQLSMALLINT = -7;
pub const SQL_WCHAR: SQLSMALLINT = -8;
pub const SQL_WVARCHAR: SQLSMALLINT = -9;
pub const SQL_WLONGVARCHAR: SQLSMALLINT = -10;

// ============================================================================
// C Data Types for binding
// ============================================================================

pub const SQL_C_CHAR: SQLSMALLINT = SQL_CHAR;
pub const SQL_C_WCHAR: SQLSMALLINT = SQL_WCHAR;
pub const SQL_C_LONG: SQLSMALLINT = SQL_INTEGER;
pub const SQL_C_SHORT: SQLSMALLINT = SQL_SMALLINT;
pub const SQL_C_FLOAT: SQLSMALLINT = SQL_REAL;
pub const SQL_C_DOUBLE: SQLSMALLINT = SQL_DOUBLE;
pub const SQL_C_NUMERIC: SQLSMALLINT = SQL_NUMERIC;
pub const SQL_C_DEFAULT: SQLSMALLINT = 99;
pub const SQL_C_DATE: SQLSMALLINT = SQL_TYPE_DATE;
pub const SQL_C_TIME: SQLSMALLINT = SQL_TYPE_TIME;
pub const SQL_C_TIMESTAMP: SQLSMALLINT = SQL_TYPE_TIMESTAMP;
pub const SQL_C_BINARY: SQLSMALLINT = SQL_BINARY;
pub const SQL_C_BIT: SQLSMALLINT = SQL_BIT;
pub const SQL_C_TINYINT: SQLSMALLINT = SQL_TINYINT;
pub const SQL_C_SLONG: SQLSMALLINT = -16;
pub const SQL_C_SSHORT: SQLSMALLINT = -15;
pub const SQL_C_STINYINT: SQLSMALLINT = -26;
pub const SQL_C_ULONG: SQLSMALLINT = -18;
pub const SQL_C_USHORT: SQLSMALLINT = -17;
pub const SQL_C_UTINYINT: SQLSMALLINT = -28;
pub const SQL_C_SBIGINT: SQLSMALLINT = -25;
pub const SQL_C_UBIGINT: SQLSMALLINT = -27;

// ============================================================================
// Null-terminated string length indicators
// ============================================================================

pub const SQL_NULL_DATA: SQLLEN = -1;
pub const SQL_DATA_AT_EXEC: SQLLEN = -2;
pub const SQL_NTS: SQLLEN = -3;
pub const SQL_NTSL: SQLLEN = -3;

// ============================================================================
// Fetch directions
// ============================================================================

pub const SQL_FETCH_NEXT: SQLSMALLINT = 1;
pub const SQL_FETCH_FIRST: SQLSMALLINT = 2;
pub const SQL_FETCH_LAST: SQLSMALLINT = 3;
pub const SQL_FETCH_PRIOR: SQLSMALLINT = 4;
pub const SQL_FETCH_ABSOLUTE: SQLSMALLINT = 5;
pub const SQL_FETCH_RELATIVE: SQLSMALLINT = 6;

// ============================================================================
// Free statement options
// ============================================================================

pub const SQL_CLOSE: SQLUSMALLINT = 0;
pub const SQL_DROP: SQLUSMALLINT = 1;
pub const SQL_UNBIND: SQLUSMALLINT = 2;
pub const SQL_RESET_PARAMS: SQLUSMALLINT = 3;

// ============================================================================
// Diagnostic fields
// ============================================================================

pub const SQL_DIAG_RETURNCODE: SQLSMALLINT = 1;
pub const SQL_DIAG_NUMBER: SQLSMALLINT = 2;
pub const SQL_DIAG_ROW_COUNT: SQLSMALLINT = 3;
pub const SQL_DIAG_SQLSTATE: SQLSMALLINT = 4;
pub const SQL_DIAG_NATIVE: SQLSMALLINT = 5;
pub const SQL_DIAG_MESSAGE_TEXT: SQLSMALLINT = 6;
pub const SQL_DIAG_DYNAMIC_FUNCTION: SQLSMALLINT = 7;
pub const SQL_DIAG_CLASS_ORIGIN: SQLSMALLINT = 8;
pub const SQL_DIAG_SUBCLASS_ORIGIN: SQLSMALLINT = 9;
pub const SQL_DIAG_CONNECTION_NAME: SQLSMALLINT = 10;
pub const SQL_DIAG_SERVER_NAME: SQLSMALLINT = 11;
pub const SQL_DIAG_DYNAMIC_FUNCTION_CODE: SQLSMALLINT = 12;

// ============================================================================
// ODBC Function Declarations (extern "C")
// ============================================================================

pub extern "c" fn SQLAllocHandle(
    HandleType: SQLSMALLINT,
    InputHandle: SQLHANDLE,
    OutputHandle: *SQLHANDLE,
) SQLRETURN;

pub extern "c" fn SQLFreeHandle(
    HandleType: SQLSMALLINT,
    Handle: SQLHANDLE,
) SQLRETURN;

pub extern "c" fn SQLSetEnvAttr(
    EnvironmentHandle: SQLHENV,
    Attribute: SQLINTEGER,
    Value: SQLPOINTER,
    StringLength: SQLINTEGER,
) SQLRETURN;

pub extern "c" fn SQLSetConnectAttr(
    ConnectionHandle: SQLHDBC,
    Attribute: SQLINTEGER,
    Value: SQLPOINTER,
    StringLength: SQLINTEGER,
) SQLRETURN;

pub extern "c" fn SQLGetConnectAttr(
    ConnectionHandle: SQLHDBC,
    Attribute: SQLINTEGER,
    Value: SQLPOINTER,
    BufferLength: SQLINTEGER,
    StringLength: *SQLINTEGER,
) SQLRETURN;

pub extern "c" fn SQLSetStmtAttr(
    StatementHandle: SQLHSTMT,
    Attribute: SQLINTEGER,
    Value: SQLPOINTER,
    StringLength: SQLINTEGER,
) SQLRETURN;

pub extern "c" fn SQLDriverConnect(
    ConnectionHandle: SQLHDBC,
    WindowHandle: SQLHANDLE,
    InConnectionString: [*c]const SQLCHAR,
    StringLength1: SQLSMALLINT,
    OutConnectionString: [*c]SQLCHAR,
    BufferLength: SQLSMALLINT,
    StringLength2Ptr: *SQLSMALLINT,
    DriverCompletion: SQLUSMALLINT,
) SQLRETURN;

pub extern "c" fn SQLConnect(
    ConnectionHandle: SQLHDBC,
    ServerName: [*c]const SQLCHAR,
    NameLength1: SQLSMALLINT,
    UserName: [*c]const SQLCHAR,
    NameLength2: SQLSMALLINT,
    Authentication: [*c]const SQLCHAR,
    NameLength3: SQLSMALLINT,
) SQLRETURN;

pub extern "c" fn SQLDisconnect(
    ConnectionHandle: SQLHDBC,
) SQLRETURN;

pub extern "c" fn SQLPrepare(
    StatementHandle: SQLHSTMT,
    StatementText: [*c]const SQLCHAR,
    TextLength: SQLINTEGER,
) SQLRETURN;

pub extern "c" fn SQLExecute(
    StatementHandle: SQLHSTMT,
) SQLRETURN;

pub extern "c" fn SQLExecDirect(
    StatementHandle: SQLHSTMT,
    StatementText: [*c]const SQLCHAR,
    TextLength: SQLINTEGER,
) SQLRETURN;

pub extern "c" fn SQLFetch(
    StatementHandle: SQLHSTMT,
) SQLRETURN;

pub extern "c" fn SQLFetchScroll(
    StatementHandle: SQLHSTMT,
    FetchOrientation: SQLSMALLINT,
    FetchOffset: SQLLEN,
) SQLRETURN;

pub extern "c" fn SQLNumResultCols(
    StatementHandle: SQLHSTMT,
    ColumnCount: *SQLSMALLINT,
) SQLRETURN;

pub extern "c" fn SQLDescribeCol(
    StatementHandle: SQLHSTMT,
    ColumnNumber: SQLUSMALLINT,
    ColumnName: [*c]SQLCHAR,
    BufferLength: SQLSMALLINT,
    NameLength: *SQLSMALLINT,
    DataType: *SQLSMALLINT,
    ColumnSize: *SQLULEN,
    DecimalDigits: *SQLSMALLINT,
    Nullable: *SQLSMALLINT,
) SQLRETURN;

pub extern "c" fn SQLBindCol(
    StatementHandle: SQLHSTMT,
    ColumnNumber: SQLUSMALLINT,
    TargetType: SQLSMALLINT,
    TargetValue: SQLPOINTER,
    BufferLength: SQLLEN,
    StrLen_or_Ind: *SQLLEN,
) SQLRETURN;

pub extern "c" fn SQLBindParameter(
    StatementHandle: SQLHSTMT,
    ParameterNumber: SQLUSMALLINT,
    InputOutputType: SQLSMALLINT,
    ValueType: SQLSMALLINT,
    ParameterType: SQLSMALLINT,
    ColumnSize: SQLULEN,
    DecimalDigits: SQLSMALLINT,
    ParameterValue: SQLPOINTER,
    BufferLength: SQLLEN,
    StrLen_or_IndPtr: *SQLLEN,
) SQLRETURN;

pub extern "c" fn SQLGetData(
    StatementHandle: SQLHSTMT,
    ColumnNumber: SQLUSMALLINT,
    TargetType: SQLSMALLINT,
    TargetValue: SQLPOINTER,
    BufferLength: SQLLEN,
    StrLen_or_IndPtr: *SQLLEN,
) SQLRETURN;

pub extern "c" fn SQLRowCount(
    StatementHandle: SQLHSTMT,
    RowCount: *SQLLEN,
) SQLRETURN;

pub extern "c" fn SQLCloseCursor(
    StatementHandle: SQLHSTMT,
) SQLRETURN;

pub extern "c" fn SQLFreeStmt(
    StatementHandle: SQLHSTMT,
    Option: SQLUSMALLINT,
) SQLRETURN;

pub extern "c" fn SQLGetDiagRec(
    HandleType: SQLSMALLINT,
    Handle: SQLHANDLE,
    RecNumber: SQLSMALLINT,
    Sqlstate: [*c]SQLCHAR,
    NativeError: *SQLINTEGER,
    MessageText: [*c]SQLCHAR,
    BufferLength: SQLSMALLINT,
    TextLength: *SQLSMALLINT,
) SQLRETURN;

pub extern "c" fn SQLGetDiagField(
    HandleType: SQLSMALLINT,
    Handle: SQLHANDLE,
    RecNumber: SQLSMALLINT,
    DiagIdentifier: SQLSMALLINT,
    DiagInfo: SQLPOINTER,
    BufferLength: SQLSMALLINT,
    StringLength: *SQLSMALLINT,
) SQLRETURN;

pub extern "c" fn SQLEndTran(
    HandleType: SQLSMALLINT,
    Handle: SQLHANDLE,
    CompletionType: SQLSMALLINT,
) SQLRETURN;

pub const SQL_COMMIT: SQLSMALLINT = 0;
pub const SQL_ROLLBACK: SQLSMALLINT = 1;

pub const SQL_DRIVER_NOPROMPT: SQLUSMALLINT = 0;
pub const SQL_DRIVER_COMPLETE: SQLUSMALLINT = 1;
pub const SQL_DRIVER_PROMPT: SQLUSMALLINT = 2;
pub const SQL_DRIVER_COMPLETE_REQUIRED: SQLUSMALLINT = 3;

pub const SQL_PARAM_INPUT: SQLSMALLINT = 1;
pub const SQL_PARAM_INPUT_OUTPUT: SQLSMALLINT = 2;
pub const SQL_PARAM_OUTPUT: SQLSMALLINT = 4;

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if ODBC return code indicates success
pub inline fn succeeded(ret: SQLRETURN) bool {
    return ret == SQL_SUCCESS or ret == SQL_SUCCESS_WITH_INFO;
}

/// Check if ODBC return code indicates an error
pub inline fn failed(ret: SQLRETURN) bool {
    return ret != SQL_SUCCESS and ret != SQL_SUCCESS_WITH_INFO and ret != SQL_NO_DATA;
}

/// Get diagnostic information from an ODBC handle
pub fn getDiagnostics(
    allocator: std.mem.Allocator,
    handle_type: SQLSMALLINT,
    handle: SQLHANDLE,
) ![]DiagRecord {
    var records = std.ArrayList(DiagRecord).init(allocator);
    var rec_number: SQLSMALLINT = 1;

    while (true) {
        var sqlstate: [6]SQLCHAR = undefined;
        var native_error: SQLINTEGER = 0;
        var message: [1024]SQLCHAR = undefined;
        var text_length: SQLSMALLINT = 0;

        const ret = SQLGetDiagRec(
            handle_type,
            handle,
            rec_number,
            &sqlstate,
            &native_error,
            &message,
            @intCast(message.len),
            &text_length,
        );

        if (ret == SQL_NO_DATA) break;
        if (failed(ret)) break;

        try records.append(.{
            .sqlstate = sqlstate,
            .native_error = native_error,
            .message = try allocator.dupe(u8, message[0..@intCast(text_length)]),
        });

        rec_number += 1;
        if (rec_number > 100) break; // Safety limit
    }

    return records.toOwnedSlice();
}

pub const DiagRecord = struct {
    sqlstate: [6]SQLCHAR,
    native_error: SQLINTEGER,
    message: []const u8,

    pub fn deinit(self: *DiagRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }

    pub fn getSqlState(self: *const DiagRecord) []const u8 {
        return self.sqlstate[0..5];
    }
};

/// Format connection string for SAP HANA ODBC driver
pub fn formatHanaConnectionString(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    schema: ?[]const u8,
) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    var writer = buffer.writer();

    // SAP HANA ODBC connection string format
    try writer.print("DRIVER={{HDBODBC}};SERVERNODE={s}:{d};UID={s};PWD={s}", .{
        host,
        port,
        user,
        password,
    });

    if (schema) |s| {
        try writer.print(";CURRENTSCHEMA={s}", .{s});
    }

    // Additional HANA-specific options for production
    try writer.writeAll(";CHAR_AS_UTF8=1;RECONNECT=1");

    return buffer.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "succeeded helper" {
    try std.testing.expect(succeeded(SQL_SUCCESS));
    try std.testing.expect(succeeded(SQL_SUCCESS_WITH_INFO));
    try std.testing.expect(!succeeded(SQL_ERROR));
    try std.testing.expect(!succeeded(SQL_INVALID_HANDLE));
}

test "failed helper" {
    try std.testing.expect(!failed(SQL_SUCCESS));
    try std.testing.expect(!failed(SQL_SUCCESS_WITH_INFO));
    try std.testing.expect(!failed(SQL_NO_DATA));
    try std.testing.expect(failed(SQL_ERROR));
    try std.testing.expect(failed(SQL_INVALID_HANDLE));
}

test "formatHanaConnectionString" {
    const allocator = std.testing.allocator;
    const conn_str = try formatHanaConnectionString(
        allocator,
        "hana.example.com",
        443,
        "SYSTEM",
        "password123",
        "AIPROMPT_STORAGE",
    );
    defer allocator.free(conn_str);

    try std.testing.expect(std.mem.indexOf(u8, conn_str, "SERVERNODE=hana.example.com:443") != null);
    try std.testing.expect(std.mem.indexOf(u8, conn_str, "UID=SYSTEM") != null);
    try std.testing.expect(std.mem.indexOf(u8, conn_str, "CURRENTSCHEMA=AIPROMPT_STORAGE") != null);
}