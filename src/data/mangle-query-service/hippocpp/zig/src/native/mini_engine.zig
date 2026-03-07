const std = @import("std");

const ColumnType = enum {
    STRING,
    INT8,
    INT16,
    INT32,
    INT64,
    UINT8,
    UINT16,
    UINT32,
    UINT64,
    BOOL,
    DOUBLE,
};

const Cell = union(enum) {
    null,
    string: []u8,
    int64: i64,
    uint64: u64,
    float64: f64,

    fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }

    fn clone(self: Cell, allocator: std.mem.Allocator) !Cell {
        return switch (self) {
            .null => .null,
            .int64 => |v| .{ .int64 = v },
            .uint64 => |v| .{ .uint64 = v },
            .float64 => |v| .{ .float64 = v },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
        };
    }
};

const Column = struct {
    name: []u8,
    ty: ColumnType,
};

const Table = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    columns: std.ArrayList(Column),
    primary_key: ?[]u8,
    rows: std.ArrayList([]Cell),

    fn init(allocator: std.mem.Allocator, name: []const u8) !Table {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .columns = .{},
            .primary_key = null,
            .rows = .{},
        };
    }

    fn deinit(self: *Table) void {
        for (self.columns.items) |col| {
            self.allocator.free(col.name);
        }
        self.columns.deinit(self.allocator);

        if (self.primary_key) |pk| {
            self.allocator.free(pk);
        }

        for (self.rows.items) |row| {
            for (row) |*cell| {
                cell.deinit(self.allocator);
            }
            self.allocator.free(row);
        }
        self.rows.deinit(self.allocator);
        self.allocator.free(self.name);
    }

    fn columnIndex(self: *const Table, column_name: []const u8) ?usize {
        for (self.columns.items, 0..) |col, idx| {
            if (std.mem.eql(u8, col.name, column_name)) return idx;
        }
        return null;
    }

    fn typeFor(self: *const Table, column_name: []const u8) ?ColumnType {
        const idx = self.columnIndex(column_name) orelse return null;
        return self.columns.items[idx].ty;
    }
};

const RelRow = struct {
    src_row: usize,
    dst_row: usize,
    props: []Cell,

    fn deinit(self: *RelRow, allocator: std.mem.Allocator) void {
        for (self.props) |*cell| {
            cell.deinit(allocator);
        }
        allocator.free(self.props);
    }
};

const RelTable = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    from_table: []u8,
    to_table: []u8,
    columns: std.ArrayList(Column),
    rows: std.ArrayList(RelRow),

    fn init(allocator: std.mem.Allocator, name: []const u8, from_table: []const u8, to_table: []const u8) !RelTable {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .from_table = try allocator.dupe(u8, from_table),
            .to_table = try allocator.dupe(u8, to_table),
            .columns = .{},
            .rows = .{},
        };
    }

    fn deinit(self: *RelTable) void {
        for (self.columns.items) |col| {
            self.allocator.free(col.name);
        }
        self.columns.deinit(self.allocator);

        for (self.rows.items) |*row| {
            row.deinit(self.allocator);
        }
        self.rows.deinit(self.allocator);

        self.allocator.free(self.name);
        self.allocator.free(self.from_table);
        self.allocator.free(self.to_table);
    }

    fn columnIndex(self: *const RelTable, column_name: []const u8) ?usize {
        for (self.columns.items, 0..) |col, idx| {
            if (std.mem.eql(u8, col.name, column_name)) return idx;
        }
        return null;
    }

    fn typeFor(self: *const RelTable, column_name: []const u8) ?ColumnType {
        const idx = self.columnIndex(column_name) orelse return null;
        return self.columns.items[idx].ty;
    }
};

const ParsedLiteral = union(enum) {
    null,
    string: []const u8,
    int64: i64,
    uint64: u64,
    bool: bool,
    float64: f64,
};

const FilterValue = union(enum) {
    null,
    string: []const u8,
    int64: i64,
    uint64: u64,
    bool: bool,
    float64: f64,
};

const FilterOp = enum {
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
};

const NullPredicate = enum {
    none,
    is_null,
    is_not_null,
};

const FilterOperand = union(enum) {
    literal: FilterValue,
    column_idx: usize,
};

const Filter = struct {
    column_idx: usize,
    op: FilterOp,
    rhs: FilterOperand,
    null_predicate: NullPredicate = .none,
};

const ProjSource = enum {
    left,
    right,
    rel,
};

const ProjRef = struct {
    source: ProjSource,
    col_idx: usize,
};

const RelFilter = struct {
    key: ProjRef,
    op: FilterOp,
    rhs: union(enum) {
        literal: FilterValue,
        ref: ProjRef,
    },
    null_predicate: NullPredicate = .none,
};

const NodeOrderKey = struct {
    col_idx: usize,
    desc: bool,
};

const NodeOrderAlias = struct {
    alias: []const u8,
    col_idx: usize,
};

const RelOrderKey = struct {
    ref: ProjRef,
    desc: bool,
};

const RelOrderAlias = struct {
    alias: []const u8,
    ref: ProjRef,
};

const OutputOrderKey = struct {
    col_idx: usize,
    desc: bool,
};

const CountProjectionTerm = struct {
    position: usize,
    count_expr: []const u8,
    alias: []const u8,
    alias_owned: bool = false,
    distinct: bool,
};

const GroupProjectionTerm = struct {
    position: usize,
    expr: []const u8,
    alias: []const u8,
    alias_explicit: bool,
};

const NodeCountTarget = union(enum) {
    star,
    column: usize,
    constant_non_null: bool,
};

const RelCountTarget = union(enum) {
    star,
    ref: ProjRef,
    constant_non_null: bool,
};

const NodeFilterGroup = struct {
    filters: std.ArrayList(Filter),

    fn deinit(self: *NodeFilterGroup, allocator: std.mem.Allocator) void {
        self.filters.deinit(allocator);
    }
};

const RelFilterGroup = struct {
    filters: std.ArrayList(RelFilter),

    fn deinit(self: *RelFilterGroup, allocator: std.mem.Allocator) void {
        self.filters.deinit(allocator);
    }
};

const MatchCreateFilterGroup = struct {
    left_filters: std.ArrayList(Filter),
    right_filters: std.ArrayList(Filter),

    fn deinit(self: *MatchCreateFilterGroup, allocator: std.mem.Allocator) void {
        self.left_filters.deinit(allocator);
        self.right_filters.deinit(allocator);
    }
};

const MatchCreateOperand = union(enum) {
    left_col: usize,
    right_col: usize,
    literal: FilterValue,
};

const NodeSetOperand = union(enum) {
    literal: FilterValue,
    literal_int64_to_string: i64,
    literal_float64_to_string: f64,
    column_idx: usize,
    column_idx_int64_to_string: usize,
    column_idx_int64_to_double: usize,
    column_idx_float64_to_int64: usize,
};

const NodeSetAssignment = struct {
    col_idx: usize,
    rhs: NodeSetOperand,
};

const RelSetOperand = union(enum) {
    literal: FilterValue,
    literal_int64_to_string: i64,
    literal_float64_to_string: f64,
    ref: ProjRef,
    ref_int64_to_string: ProjRef,
    ref_int64_to_double: ProjRef,
    ref_float64_to_int64: ProjRef,
};

const RelSetAssignment = struct {
    col_idx: usize,
    rhs: RelSetOperand,
};

const ResultSet = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayList([]u8),
    types: std.ArrayList([]const u8),
    rows: std.ArrayList([]Cell),

    fn init(allocator: std.mem.Allocator) ResultSet {
        return .{
            .allocator = allocator,
            .columns = .{},
            .types = .{},
            .rows = .{},
        };
    }

    fn deinit(self: *ResultSet) void {
        for (self.columns.items) |col| {
            self.allocator.free(col);
        }
        self.columns.deinit(self.allocator);

        for (self.rows.items) |row| {
            for (row) |*cell| {
                cell.deinit(self.allocator);
            }
            self.allocator.free(row);
        }
        self.rows.deinit(self.allocator);
        self.types.deinit(self.allocator);
    }
};

const Engine = struct {
    allocator: std.mem.Allocator,
    node_tables: std.StringHashMap(Table),
    rel_tables: std.StringHashMap(RelTable),
    last_error_message: ?[]u8,

    fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .allocator = allocator,
            .node_tables = std.StringHashMap(Table).init(allocator),
            .rel_tables = std.StringHashMap(RelTable).init(allocator),
            .last_error_message = null,
        };
    }

    fn deinit(self: *Engine) void {
        self.clearLastErrorMessage();

        var it = self.node_tables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.node_tables.deinit();

        var rel_it = self.rel_tables.iterator();
        while (rel_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.rel_tables.deinit();
    }

    fn clearLastErrorMessage(self: *Engine) void {
        if (self.last_error_message) |msg| {
            self.allocator.free(msg);
            self.last_error_message = null;
        }
    }

    fn setLastErrorMessage(self: *Engine, message: []const u8) !void {
        self.clearLastErrorMessage();
        self.last_error_message = try self.allocator.dupe(u8, message);
    }

    fn setLastErrorFmt(self: *Engine, comptime fmt: []const u8, args: anytype) !void {
        self.clearLastErrorMessage();
        self.last_error_message = try std.fmt.allocPrint(self.allocator, fmt, args);
    }

    fn failUserMessage(self: *Engine, message: []const u8) !void {
        try self.setLastErrorMessage(message);
        return error.UserVisibleError;
    }

    fn failUserFmt(self: *Engine, comptime fmt: []const u8, args: anytype) !void {
        try self.setLastErrorFmt(fmt, args);
        return error.UserVisibleError;
    }

    fn normalizeIdentifierToken(text: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed.len >= 2 and trimmed[0] == '`' and trimmed[trimmed.len - 1] == '`') {
            return trimmed[1 .. trimmed.len - 1];
        }
        return trimmed;
    }

    fn findNodeTableKeyCaseInsensitive(self: *Engine, name: []const u8) ?[]const u8 {
        if (self.node_tables.contains(name)) return name;
        var it = self.node_tables.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.key_ptr.*;
        }
        return null;
    }

    fn catalogNameExistsCaseInsensitive(self: *Engine, name: []const u8) bool {
        if (self.findNodeTableKeyCaseInsensitive(name) != null) return true;
        if (self.rel_tables.contains(name)) return true;
        var rel_it = self.rel_tables.iterator();
        while (rel_it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return true;
        }
        return false;
    }

    fn appendCreateTableResult(self: *Engine, result: *ResultSet, table_name: []const u8) !void {
        try result.columns.append(self.allocator, try self.allocator.dupe(u8, "result"));
        try result.types.append(self.allocator, "STRING");

        var row = try self.allocator.alloc(Cell, 1);
        row[0] = .null;
        errdefer {
            row[0].deinit(self.allocator);
            self.allocator.free(row);
        }

        const message = try std.fmt.allocPrint(self.allocator, "Table {s} has been created.", .{table_name});
        row[0] = .{ .string = message };
        try result.rows.append(self.allocator, row);
    }

    fn raiseExtraneousInputParserError(
        self: *Engine,
        query: []const u8,
        token: []const u8,
        expected: []const u8,
        token_offset: usize,
    ) !void {
        const caret_pad = try self.allocator.alloc(u8, token_offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');

        const caret_len = if (token.len == 0) 1 else token.len;
        const caret_marks = try self.allocator.alloc(u8, caret_len);
        defer self.allocator.free(caret_marks);
        @memset(caret_marks, '^');

        try self.failUserFmt(
            "Parser exception: extraneous input '{s}' expecting {s} (line: 1, offset: {d})\n\"{s}\"\n{s}{s}",
            .{ token, expected, token_offset, query, caret_pad, caret_marks },
        );
    }

    fn execute(self: *Engine, query_in: []const u8, params: ?*const std.json.ObjectMap, result: *ResultSet) !void {
        self.clearLastErrorMessage();
        const query = std.mem.trim(u8, query_in, " \t\n\r;");
        try self.validateExtraParameters(query, params);
        try self.enforceMalformedMatchParserParity(query);
        try self.enforceUnsupportedNotEqualBangParserParity(query);
        try self.enforceUnsupportedGroupByParserParity(query);

        if (startsWithAsciiNoCase(query, "CREATE NODE TABLE ")) {
            try self.executeCreateNodeTable(query, result);
            return;
        }

        if (startsWithAsciiNoCase(query, "CREATE REL TABLE ")) {
            try self.executeCreateRelTable(query, result);
            return;
        }

        if (startsWithAsciiNoCase(query, "CREATE (") and std.mem.indexOf(u8, query, ")-[") != null and std.mem.indexOf(u8, query, "]->(") != null) {
            try self.executeCreateRelationship(query, params, result);
            return;
        }

        if (startsWithAsciiNoCase(query, "CREATE (")) {
            try self.executeCreateNode(query, params, result);
            return;
        }

        if (startsWithAsciiNoCase(query, "MATCH (")) {
            if (indexOfAsciiNoCase(query, " CREATE ") != null and std.mem.indexOf(u8, query, ")-[") != null and std.mem.indexOf(u8, query, "]->(") != null) {
                try self.executeMatchCreateFlexible(query, params, result);
                return;
            }
            if (indexOfAsciiNoCase(query, " DELETE ") != null and indexOfAsciiNoCase(query, " CREATE ") == null and indexOfAsciiNoCase(query, " SET ") == null) {
                if (std.mem.indexOf(u8, query, ")-[") != null and std.mem.indexOf(u8, query, "]->(") != null) {
                    try self.executeMatchRelDelete(query, params);
                } else {
                    try self.executeMatchDelete(query, params);
                }
                return;
            }
            if (indexOfAsciiNoCase(query, " SET ") != null and indexOfAsciiNoCase(query, " CREATE ") == null) {
                if (std.mem.indexOf(u8, query, ")-[") != null and std.mem.indexOf(u8, query, "]->(") != null) {
                    try self.executeMatchRelSet(query, params, result);
                    return;
                }
                try self.executeMatchSet(query, params, result);
                return;
            }
            if (std.mem.indexOf(u8, query, ")-[") != null and std.mem.indexOf(u8, query, "]->(") != null) {
                try self.executeMatchRel(query, params, result);
            } else {
                try self.executeMatch(query, params, result);
            }
            return;
        }

        if (startsWithAsciiNoCase(query, "RETURN ")) {
            try self.executeReturn(query, params, result);
            return;
        }

        return error.UnsupportedQuery;
    }

    fn executeCreateNodeTable(self: *Engine, query: []const u8, result: *ResultSet) !void {
        const prefix = "CREATE NODE TABLE ";
        const after_prefix = query[prefix.len..];
        const open_idx_rel = std.mem.indexOfScalar(u8, after_prefix, '(') orelse return error.InvalidCreateTable;
        const close_idx = std.mem.lastIndexOfScalar(u8, query, ')') orelse return error.InvalidCreateTable;

        const table_name = Engine.normalizeIdentifierToken(after_prefix[0..open_idx_rel]);
        if (table_name.len == 0) return error.InvalidCreateTable;

        var table = try Table.init(self.allocator, table_name);
        errdefer table.deinit();

        const open_idx = prefix.len + open_idx_rel;
        const inner = query[open_idx + 1 .. close_idx];

        var iter = std.mem.splitScalar(u8, inner, ',');
        while (iter.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t\n\r");
            if (part.len == 0) continue;

            if (startsWithAsciiNoCase(part, "PRIMARY KEY(")) {
                const pk_close = std.mem.lastIndexOfScalar(u8, part, ')') orelse return error.InvalidCreateTable;
                const pk_name = Engine.normalizeIdentifierToken(part[12..pk_close]);
                if (table.primary_key) |existing_pk| {
                    if (!std.mem.eql(u8, existing_pk, pk_name)) {
                        try self.failUserMessage("Parser exception: Found multiple primary keys.");
                        unreachable;
                    }
                } else {
                    table.primary_key = try self.allocator.dupe(u8, pk_name);
                }
                continue;
            }

            var token_iter = std.mem.tokenizeScalar(u8, part, ' ');
            const col_name_raw = token_iter.next() orelse return error.InvalidCreateTable;
            const col_name = Engine.normalizeIdentifierToken(col_name_raw);
            const col_type = token_iter.next() orelse return error.InvalidCreateTable;

            if (table.columnIndex(col_name) != null) {
                try self.failUserFmt("Binder exception: Duplicated column name: {s}, column name must be unique.", .{col_name});
                unreachable;
            }

            const ty: ColumnType = try Engine.parseColumnTypeToken(col_type);

            var inline_primary_key = false;
            if (token_iter.next()) |pk_kw| {
                if (!std.ascii.eqlIgnoreCase(pk_kw, "PRIMARY")) return error.InvalidCreateTable;
                const key_kw = token_iter.next() orelse return error.InvalidCreateTable;
                if (!std.ascii.eqlIgnoreCase(key_kw, "KEY")) return error.InvalidCreateTable;
                if (token_iter.next() != null) return error.InvalidCreateTable;
                inline_primary_key = true;
            }

            try table.columns.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, col_name),
                .ty = ty,
            });

            if (inline_primary_key) {
                if (table.primary_key) |existing_pk| {
                    if (!std.mem.eql(u8, existing_pk, col_name)) {
                        try self.failUserMessage("Parser exception: Found multiple primary keys.");
                        unreachable;
                    }
                } else {
                    table.primary_key = try self.allocator.dupe(u8, col_name);
                }
            }
        }

        const pk_name = table.primary_key orelse {
            try self.failUserMessage("Parser exception: Can not find primary key.");
            unreachable;
        };
        if (table.columnIndex(pk_name) == null) {
            try self.failUserFmt(
                "Binder exception: Primary key {s} does not match any of the predefined node properties.",
                .{pk_name},
            );
            unreachable;
        }

        if (self.catalogNameExistsCaseInsensitive(table_name)) {
            try self.failUserFmt("Binder exception: {s} already exists in catalog.", .{table_name});
            unreachable;
        }

        const key = try self.allocator.dupe(u8, table_name);
        errdefer self.allocator.free(key);
        try self.node_tables.put(key, table);
        try self.appendCreateTableResult(result, table_name);
    }

    fn parseLiteral(text: []const u8) !ParsedLiteral {
        const trimmed = std.mem.trim(u8, text, " \t\n\r");
        if (std.ascii.eqlIgnoreCase(trimmed, "NULL")) {
            return .null;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "TRUE")) {
            return .{ .bool = true };
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "FALSE")) {
            return .{ .bool = false };
        }
        if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') {
            return .{ .string = trimmed[1 .. trimmed.len - 1] };
        }
        if (std.fmt.parseInt(i64, trimmed, 10)) |v| {
            return .{ .int64 = v };
        } else |_| {}
        if (trimmed.len > 0 and trimmed[0] != '-' and std.mem.indexOfAny(u8, trimmed, ".eE") == null) {
            if (std.fmt.parseInt(u64, trimmed, 10)) |v| {
                return .{ .uint64 = v };
            } else |_| {}
        }
        return .{ .float64 = try std.fmt.parseFloat(f64, trimmed) };
    }

    fn parseLiteralOrParameter(self: *Engine, text: []const u8, params: ?*const std.json.ObjectMap) !ParsedLiteral {
        const trimmed = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed.len > 0 and trimmed[0] == '$') {
            const json_value = try self.getParameterValue(trimmed, params);
            return switch (json_value) {
                .null => .null,
                .string => |s| .{ .string = s },
                .integer => |i| .{ .int64 = @intCast(i) },
                .bool => |b| .{ .bool = b },
                .float => |f| .{ .float64 = f },
                else => error.UnsupportedParameterType,
            };
        }
        return try parseLiteral(trimmed);
    }

    fn cellToCypherLiteral(self: *Engine, cell: Cell) ![]u8 {
        return switch (cell) {
            .null => try self.allocator.dupe(u8, "NULL"),
            .string => |s| try std.fmt.allocPrint(self.allocator, "'{s}'", .{s}),
            .int64 => |v| try std.fmt.allocPrint(self.allocator, "{d}", .{v}),
            .uint64 => |v| try std.fmt.allocPrint(self.allocator, "{d}", .{v}),
            .float64 => |v| try std.fmt.allocPrint(self.allocator, "{d}", .{v}),
        };
    }

    fn rewriteCreateNodePatternForBoundProps(
        self: *Engine,
        pattern_in: []const u8,
        bindings: anytype,
    ) !?[]u8 {
        const pattern = std.mem.trim(u8, pattern_in, " \t\n\r");
        if (pattern.len < 4 or pattern[0] != '(' or pattern[pattern.len - 1] != ')') return null;

        const inner = std.mem.trim(u8, pattern[1 .. pattern.len - 1], " \t\n\r");
        const head_colon_idx = std.mem.indexOfScalar(u8, inner, ':') orelse return null;
        const var_name = std.mem.trim(u8, inner[0..head_colon_idx], " \t\n\r");
        const after_colon = inner[head_colon_idx + 1 ..];
        const brace_idx = std.mem.indexOfScalar(u8, after_colon, '{') orelse return null;
        const close_brace = std.mem.lastIndexOfScalar(u8, after_colon, '}') orelse return null;
        if (close_brace <= brace_idx) return null;
        const table_name = std.mem.trim(u8, after_colon[0..brace_idx], " \t\n\r");
        if (table_name.len == 0) return null;

        const props_inner = after_colon[brace_idx + 1 .. close_brace];
        var changed = false;
        var rewritten_props: std.ArrayList(u8) = .{};
        defer rewritten_props.deinit(self.allocator);
        var first = true;
        var props = std.mem.splitScalar(u8, props_inner, ',');
        while (props.next()) |raw_prop| {
            const prop = std.mem.trim(u8, raw_prop, " \t\n\r");
            if (prop.len == 0) continue;
            const prop_colon_idx = std.mem.indexOfScalar(u8, prop, ':') orelse return error.InvalidCreateNode;
            const key = std.mem.trim(u8, prop[0..prop_colon_idx], " \t\n\r");
            var value_text = std.mem.trim(u8, prop[prop_colon_idx + 1 ..], " \t\n\r");
            var value_text_owned: ?[]u8 = null;
            defer if (value_text_owned) |owned| self.allocator.free(owned);

            if (Engine.parsePropertyAccessExpr(value_text)) |rhs_prop| {
                for (bindings) |binding| {
                    if (!std.mem.eql(u8, binding.name, rhs_prop.var_name)) continue;
                    const rhs_col_idx = try self.nodeColumnIndexOrBinderError(binding.table, rhs_prop.var_name, rhs_prop.prop_name);
                    value_text_owned = try self.cellToCypherLiteral(binding.table.rows.items[binding.row_idx][rhs_col_idx]);
                    value_text = value_text_owned.?;
                    changed = true;
                    break;
                }
            }

            if (!first) try rewritten_props.appendSlice(self.allocator, ", ");
            first = false;
            try rewritten_props.appendSlice(self.allocator, key);
            try rewritten_props.appendSlice(self.allocator, ": ");
            try rewritten_props.appendSlice(self.allocator, value_text);
        }

        if (!changed) return null;
        return try std.fmt.allocPrint(self.allocator, "({s}:{s} {{{s}}})", .{ var_name, table_name, rewritten_props.items });
    }

    fn isIntegerType(ty: ColumnType) bool {
        return switch (ty) {
            .INT8, .INT16, .INT32, .INT64, .UINT8, .UINT16, .UINT32, .UINT64 => true,
            else => false,
        };
    }

    fn isUnsignedIntegerType(ty: ColumnType) bool {
        return switch (ty) {
            .UINT8, .UINT16, .UINT32, .UINT64 => true,
            else => false,
        };
    }

    fn parseColumnTypeToken(token_in: []const u8) !ColumnType {
        const token = std.mem.trim(u8, token_in, " \t\n\r");
        if (std.ascii.eqlIgnoreCase(token, "STRING")) return .STRING;
        if (std.ascii.eqlIgnoreCase(token, "BOOL")) return .BOOL;
        if (std.ascii.eqlIgnoreCase(token, "DOUBLE")) return .DOUBLE;
        if (std.ascii.eqlIgnoreCase(token, "INT8")) return .INT8;
        if (std.ascii.eqlIgnoreCase(token, "INT16")) return .INT16;
        if (std.ascii.eqlIgnoreCase(token, "INT32")) return .INT32;
        if (std.ascii.eqlIgnoreCase(token, "INT64")) return .INT64;
        if (std.ascii.eqlIgnoreCase(token, "UINT8")) return .UINT8;
        if (std.ascii.eqlIgnoreCase(token, "UINT16")) return .UINT16;
        if (std.ascii.eqlIgnoreCase(token, "UINT32")) return .UINT32;
        if (std.ascii.eqlIgnoreCase(token, "UINT64")) return .UINT64;
        return error.UnsupportedType;
    }

    fn invertFilterOp(op: FilterOp) FilterOp {
        return switch (op) {
            .eq => .neq,
            .neq => .eq,
            .lt => .gte,
            .lte => .gt,
            .gt => .lte,
            .gte => .lt,
        };
    }

    fn reverseFilterOp(op: FilterOp) FilterOp {
        return switch (op) {
            .eq => .eq,
            .neq => .neq,
            .lt => .gt,
            .lte => .gte,
            .gt => .lt,
            .gte => .lte,
        };
    }

    fn normalizeComparisonClauseForNot(clause_in: []const u8) !struct { clause: []const u8, negate: bool } {
        var clause = std.mem.trim(u8, clause_in, " \t\n\r");
        var negate = false;

        while (true) {
            if (clause.len < 3) break;
            if (!std.mem.startsWith(u8, clause, "NOT")) break;
            if (clause.len > 3 and clause[3] != ' ' and clause[3] != '\t' and clause[3] != '\n' and clause[3] != '\r') break;

            negate = !negate;
            clause = std.mem.trim(u8, clause[3..], " \t\n\r");
            if (clause.len == 0) return error.InvalidWhere;
        }

        return .{ .clause = clause, .negate = negate };
    }

    fn parseComparisonClause(clause: []const u8) !struct { lhs: []const u8, rhs: []const u8, op: FilterOp } {
        const Candidate = struct {
            token: []const u8,
            op: FilterOp,
        };
        const candidates = [_]Candidate{
            .{ .token = ">=", .op = .gte },
            .{ .token = "<=", .op = .lte },
            .{ .token = "!=", .op = .neq },
            .{ .token = "<>", .op = .neq },
            .{ .token = "=", .op = .eq },
            .{ .token = ">", .op = .gt },
            .{ .token = "<", .op = .lt },
        };

        for (candidates) |candidate| {
            if (std.mem.indexOf(u8, clause, candidate.token)) |idx| {
                const lhs = std.mem.trim(u8, clause[0..idx], " \t\n\r");
                const rhs = std.mem.trim(u8, clause[idx + candidate.token.len ..], " \t\n\r");
                if (lhs.len == 0 or rhs.len == 0) return error.InvalidWhere;
                return .{ .lhs = lhs, .rhs = rhs, .op = candidate.op };
            }
        }
        return error.InvalidWhere;
    }

    fn parseNullPredicateClause(clause_in: []const u8) ?struct { expr: []const u8, is_null: bool } {
        const clause = std.mem.trim(u8, clause_in, " \t\n\r");
        const is_not_null_suffix = " IS NOT NULL";
        if (endsWithAsciiNoCase(clause, is_not_null_suffix)) {
            const expr = std.mem.trim(u8, clause[0 .. clause.len - is_not_null_suffix.len], " \t\n\r");
            if (expr.len == 0) return null;
            return .{ .expr = expr, .is_null = false };
        }
        const is_null_suffix = " IS NULL";
        if (endsWithAsciiNoCase(clause, is_null_suffix)) {
            const expr = std.mem.trim(u8, clause[0 .. clause.len - is_null_suffix.len], " \t\n\r");
            if (expr.len == 0) return null;
            return .{ .expr = expr, .is_null = true };
        }
        return null;
    }

    fn parseOrderTerm(term_in: []const u8) !struct { expr: []const u8, desc: bool } {
        const term = std.mem.trim(u8, term_in, " \t\n\r");
        if (term.len == 0) return error.InvalidReturn;

        if (term.len >= " DESC".len and std.ascii.eqlIgnoreCase(term[term.len - " DESC".len ..], " DESC")) {
            const expr = std.mem.trim(u8, term[0 .. term.len - " DESC".len], " \t\n\r");
            if (expr.len == 0) return error.InvalidReturn;
            return .{ .expr = expr, .desc = true };
        }
        if (term.len >= " ASC".len and std.ascii.eqlIgnoreCase(term[term.len - " ASC".len ..], " ASC")) {
            const expr = std.mem.trim(u8, term[0 .. term.len - " ASC".len], " \t\n\r");
            if (expr.len == 0) return error.InvalidReturn;
            return .{ .expr = expr, .desc = false };
        }
        return .{ .expr = term, .desc = false };
    }

    fn findLastProjectionAsDelimiter(term: []const u8) ?usize {
        if (term.len < 4) return null;
        var idx: isize = @as(isize, @intCast(term.len)) - 2;
        while (idx >= 1) : (idx -= 1) {
            const as_idx: usize = @intCast(idx);
            const a = term[as_idx];
            const s = term[as_idx + 1];
            if (!((a == 'A' or a == 'a') and (s == 'S' or s == 's'))) continue;
            if (!std.ascii.isWhitespace(term[as_idx - 1])) continue;
            if (as_idx + 2 >= term.len or !std.ascii.isWhitespace(term[as_idx + 2])) continue;
            return as_idx;
        }
        return null;
    }

    fn parseProjectionTerm(term_in: []const u8) !struct { expr: []const u8, alias: ?[]const u8 } {
        const term = std.mem.trim(u8, term_in, " \t\n\r");
        if (term.len == 0) return error.InvalidReturn;

        if (findLastProjectionAsDelimiter(term)) |as_idx| {
            const expr = std.mem.trim(u8, term[0..as_idx], " \t\n\r");
            const alias = std.mem.trim(u8, term[as_idx + 2 ..], " \t\n\r");
            if (expr.len == 0 or alias.len == 0) return error.InvalidReturn;
            return .{ .expr = expr, .alias = alias };
        }

        return .{ .expr = term, .alias = null };
    }

    fn findFirstTopLevelWhitespace(term: []const u8) ?usize {
        var in_string = false;
        var paren_depth: usize = 0;
        for (term, 0..) |ch, idx| {
            if (ch == '\'') {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;
            switch (ch) {
                '(' => paren_depth += 1,
                ')' => {
                    if (paren_depth > 0) paren_depth -= 1;
                },
                else => {},
            }
            if (paren_depth == 0 and std.ascii.isWhitespace(ch)) return idx;
        }
        return null;
    }

    fn raiseUnexpectedProjectionTokenParserError(
        self: *Engine,
        query: []const u8,
        token_offset: usize,
        token: []const u8,
    ) !void {
        const caret_pad = try self.allocator.alloc(u8, token_offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');
        const caret_marks = try self.allocator.alloc(u8, token.len);
        defer self.allocator.free(caret_marks);
        @memset(caret_marks, '^');

        try self.failUserFmt(
            "Parser exception: Invalid input < {s}>: expected rule ku_Statements (line: 1, offset: {d})\n\"{s}\"\n{s}{s}",
            .{ token, token_offset, query, caret_pad, caret_marks },
        );
    }

    fn validateProjectionTermsExplicitAs(
        self: *Engine,
        query: []const u8,
        projection_part: []const u8,
    ) !void {
        var terms = try self.splitTopLevelProjectionTerms(projection_part);
        defer terms.deinit(self.allocator);

        for (terms.items) |term| {
            if (findLastProjectionAsDelimiter(term) != null) continue;
            const ws_idx = Engine.findFirstTopLevelWhitespace(term) orelse continue;
            const suffix = std.mem.trimLeft(u8, term[ws_idx..], " \t\n\r");
            if (suffix.len == 0) continue;
            if (suffix[0] == '(') continue;

            var token_end: usize = 0;
            while (token_end < suffix.len and !std.ascii.isWhitespace(suffix[token_end])) : (token_end += 1) {}
            if (token_end == 0) continue;
            const token = suffix[0..token_end];
            const token_offset = @as(usize, @intCast(@intFromPtr(token.ptr) - @intFromPtr(query.ptr)));
            try self.raiseUnexpectedProjectionTokenParserError(query, token_offset, token);
            unreachable;
        }
    }

    fn splitTopLevelProjectionTerms(self: *Engine, text_in: []const u8) !std.ArrayList([]const u8) {
        const text = std.mem.trim(u8, text_in, " \t\n\r");
        if (text.len == 0) return error.InvalidReturn;

        var terms: std.ArrayList([]const u8) = .{};
        errdefer terms.deinit(self.allocator);

        var in_string = false;
        var paren_depth: usize = 0;
        var start: usize = 0;
        var idx: usize = 0;
        while (idx < text.len) : (idx += 1) {
            const ch = text[idx];
            if (ch == '\'') {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;

            switch (ch) {
                '(' => paren_depth += 1,
                ')' => {
                    if (paren_depth == 0) return error.InvalidReturn;
                    paren_depth -= 1;
                },
                ',' => {
                    if (paren_depth == 0) {
                        const term = std.mem.trim(u8, text[start..idx], " \t\n\r");
                        if (term.len == 0) return error.InvalidReturn;
                        try terms.append(self.allocator, term);
                        start = idx + 1;
                    }
                },
                else => {},
            }
        }

        if (in_string or paren_depth != 0) return error.InvalidReturn;

        const last = std.mem.trim(u8, text[start..], " \t\n\r");
        if (last.len == 0) return error.InvalidReturn;
        try terms.append(self.allocator, last);
        return terms;
    }

    fn splitTopLevelCreatePatterns(self: *Engine, text_in: []const u8) !std.ArrayList([]const u8) {
        const text = std.mem.trim(u8, text_in, " \t\n\r");
        if (text.len == 0) return error.InvalidCreateNode;

        var patterns: std.ArrayList([]const u8) = .{};
        errdefer patterns.deinit(self.allocator);

        var in_string = false;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        var start: usize = 0;
        var idx: usize = 0;
        while (idx < text.len) : (idx += 1) {
            const ch = text[idx];
            if (ch == '\'') {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;

            switch (ch) {
                '(' => paren_depth += 1,
                ')' => {
                    if (paren_depth == 0) return error.InvalidCreateNode;
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => {
                    if (bracket_depth == 0) return error.InvalidCreateNode;
                    bracket_depth -= 1;
                },
                '{' => brace_depth += 1,
                '}' => {
                    if (brace_depth == 0) return error.InvalidCreateNode;
                    brace_depth -= 1;
                },
                ',' => {
                    if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                        const part = std.mem.trim(u8, text[start..idx], " \t\n\r");
                        if (part.len == 0) return error.InvalidCreateNode;
                        try patterns.append(self.allocator, part);
                        start = idx + 1;
                    }
                },
                else => {},
            }
        }

        if (in_string or paren_depth != 0 or bracket_depth != 0 or brace_depth != 0) return error.InvalidCreateNode;

        const last = std.mem.trim(u8, text[start..], " \t\n\r");
        if (last.len == 0) return error.InvalidCreateNode;
        try patterns.append(self.allocator, last);
        return patterns;
    }

    fn parseCountTermExpr(expr_in: []const u8) !?struct { count_expr: []const u8, distinct: bool } {
        const expr = std.mem.trim(u8, expr_in, " \t\n\r");
        if (expr.len < "COUNT".len or !std.ascii.eqlIgnoreCase(expr[0.."COUNT".len], "COUNT")) return null;

        const after_count = std.mem.trimLeft(u8, expr["COUNT".len..], " \t\n\r");
        if (after_count.len < 2 or after_count[0] != '(' or after_count[after_count.len - 1] != ')') {
            return error.InvalidReturn;
        }

        var count_expr = std.mem.trim(u8, after_count[1 .. after_count.len - 1], " \t\n\r");
        if (count_expr.len == 0) return error.InvalidReturn;

        var distinct = false;
        const distinct_prefix = "DISTINCT ";
        if (count_expr.len >= distinct_prefix.len and std.ascii.eqlIgnoreCase(count_expr[0..distinct_prefix.len], distinct_prefix)) {
            distinct = true;
            count_expr = std.mem.trim(u8, count_expr[distinct_prefix.len..], " \t\n\r");
            if (count_expr.len == 0) return error.InvalidReturn;
            if (std.mem.eql(u8, count_expr, "*")) return error.InvalidCountDistinctStar;
        }

        return .{
            .count_expr = count_expr,
            .distinct = distinct,
        };
    }

    fn formatCountOutputName(self: *Engine, count_expr: []const u8, distinct: bool) ![]u8 {
        if (!distinct and std.mem.eql(u8, count_expr, "*")) {
            return try self.allocator.dupe(u8, "COUNT_STAR()");
        }
        var normalized_expr = count_expr;
        var normalized_owned: ?[]u8 = null;
        defer if (normalized_owned) |owned| self.allocator.free(owned);
        if (Engine.isIdentifierToken(count_expr) and
            !std.ascii.eqlIgnoreCase(count_expr, "true") and
            !std.ascii.eqlIgnoreCase(count_expr, "false") and
            !std.ascii.eqlIgnoreCase(count_expr, "null"))
        {
            normalized_owned = try std.fmt.allocPrint(self.allocator, "{s}._ID", .{count_expr});
            normalized_expr = normalized_owned.?;
        }
        if (distinct) {
            return try std.fmt.allocPrint(self.allocator, "COUNT(DISTINCT {s})", .{normalized_expr});
        }
        return try std.fmt.allocPrint(self.allocator, "COUNT({s})", .{normalized_expr});
    }

    fn formatImplicitParamAlias(self: *Engine, idx: usize) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "$_{d}_", .{idx});
    }

    fn shouldUseImplicitMissingParamAlias(params: ?*const std.json.ObjectMap) bool {
        const obj = params orelse return true;
        return obj.count() == 0;
    }

    fn countImplicitAliasLiterals(text_in: []const u8) usize {
        const text = std.mem.trim(u8, text_in, " \t\n\r");
        if (text.len == 0) return 0;

        var count: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const ch = text[i];
            if (ch == '\'') {
                i += 1;
                while (i < text.len and text[i] != '\'') : (i += 1) {}
                if (i < text.len) i += 1;
                count += 1;
                continue;
            }

            if (std.ascii.isDigit(ch) or
                (ch == '-' and i + 1 < text.len and std.ascii.isDigit(text[i + 1])))
            {
                i += 1;
                while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
                if (i < text.len and text[i] == '.') {
                    i += 1;
                    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
                }
                if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
                    i += 1;
                    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
                    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
                }
                count += 1;
                continue;
            }

            if (std.ascii.isAlphabetic(ch)) {
                const start = i;
                i += 1;
                while (i < text.len and (std.ascii.isAlphabetic(text[i]) or std.ascii.isDigit(text[i]) or text[i] == '_')) : (i += 1) {}
                const token = text[start..i];
                if (std.ascii.eqlIgnoreCase(token, "true") or std.ascii.eqlIgnoreCase(token, "false")) {
                    count += 1;
                }
                continue;
            }

            i += 1;
        }

        return count;
    }

    fn parseCountProjectionPlan(
        self: *Engine,
        projection_part_in: []const u8,
        out_term_count: *usize,
        out_count_terms: *std.ArrayList(CountProjectionTerm),
        out_group_terms: *std.ArrayList(GroupProjectionTerm),
        params: ?*const std.json.ObjectMap,
    ) !bool {
        const projection_part = std.mem.trim(u8, projection_part_in, " \t\n\r");
        if (projection_part.len == 0) return error.InvalidReturn;

        var term_count: usize = 0;
        var has_count = false;
        var terms = try self.splitTopLevelProjectionTerms(projection_part);
        defer terms.deinit(self.allocator);
        for (terms.items) |raw_term| {
            const term = try parseProjectionTerm(raw_term);
            if (try parseCountTermExpr(term.expr)) |parsed_count| {
                if (parsed_count.count_expr.len > 0 and parsed_count.count_expr[0] == '$') {
                    const param_lookup = try self.getParameterValueWithPresence(parsed_count.count_expr, params);
                    if (!param_lookup.present) {
                        try out_group_terms.append(self.allocator, .{
                            .position = term_count,
                            .expr = parsed_count.count_expr,
                            .alias = term.alias orelse parsed_count.count_expr,
                            .alias_explicit = term.alias != null,
                        });
                        term_count += 1;
                        continue;
                    }
                }

                var alias_owned = false;
                const alias: []const u8 = if (term.alias) |explicit_alias|
                    explicit_alias
                else blk: {
                    const generated = try self.formatCountOutputName(parsed_count.count_expr, parsed_count.distinct);
                    alias_owned = true;
                    break :blk generated;
                };
                errdefer if (alias_owned) self.allocator.free(alias);
                try out_count_terms.append(self.allocator, .{
                    .position = term_count,
                    .count_expr = parsed_count.count_expr,
                    .alias = alias,
                    .alias_owned = alias_owned,
                    .distinct = parsed_count.distinct,
                });
                has_count = true;
            } else {
                try out_group_terms.append(self.allocator, .{
                    .position = term_count,
                    .expr = term.expr,
                    .alias = term.alias orelse term.expr,
                    .alias_explicit = term.alias != null,
                });
            }
            term_count += 1;
        }

        out_term_count.* = term_count;
        return has_count;
    }

    fn raiseCountDistinctStarProjectionError(self: *Engine, query: []const u8) !void {
        const star_offset = if (std.mem.indexOf(u8, query, "COUNT(DISTINCT *")) |idx|
            idx + "COUNT(DISTINCT ".len
        else if (std.mem.indexOf(u8, query, "COUNT(DISTINCT *)")) |idx|
            idx + "COUNT(DISTINCT ".len
        else
            0;
        const caret_pad = try self.allocator.alloc(u8, star_offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');

        try self.failUserFmt(
            "Parser exception: Invalid input <COUNT(DISTINCT *>: expected rule oC_ProjectionItem (line: 1, offset: {d})\n\"{s}\"\n{s}^",
            .{ star_offset, query, caret_pad },
        );
    }

    fn raiseTopReturnCountDistinctStarParserError(self: *Engine, query: []const u8) !void {
        const star_offset = if (std.mem.indexOf(u8, query, "COUNT(DISTINCT *")) |idx|
            idx + "COUNT(DISTINCT ".len
        else if (std.mem.indexOf(u8, query, "COUNT(DISTINCT *)")) |idx|
            idx + "COUNT(DISTINCT ".len
        else
            0;
        const caret_pad = try self.allocator.alloc(u8, star_offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');
        const token = query[0 .. @min(query.len, star_offset + 1)];

        try self.failUserFmt(
            "Parser exception: Invalid input <{s}>: expected rule oC_RegularQuery (line: 1, offset: {d})\n\"{s}\"\n{s}^",
            .{ token, star_offset, query, caret_pad },
        );
    }

    fn raiseSkipAfterLimitParserError(self: *Engine, query: []const u8, skip_offset: usize) !void {
        const caret_pad = try self.allocator.alloc(u8, skip_offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');

        try self.failUserFmt(
            "Parser exception: Invalid input < SKIP>: expected rule ku_Statements (line: 1, offset: {d})\n\"{s}\"\n{s}^^^^",
            .{ skip_offset, query, caret_pad },
        );
    }

    fn raiseSingleQueryInvalidInputParserError(
        self: *Engine,
        query: []const u8,
        token_offset: usize,
        token_end: usize,
        caret_len: usize,
    ) !void {
        const capped_end = @min(token_end, query.len);
        const token = query[0..capped_end];
        const caret_pad = try self.allocator.alloc(u8, token_offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');
        const caret_marks = try self.allocator.alloc(u8, if (caret_len == 0) 1 else caret_len);
        defer self.allocator.free(caret_marks);
        @memset(caret_marks, '^');

        try self.failUserFmt(
            "Parser exception: Invalid input <{s}>: expected rule oC_SingleQuery (line: 1, offset: {d})\n\"{s}\"\n{s}{s}",
            .{ token, token_offset, query, caret_pad, caret_marks },
        );
    }

    fn raiseGroupByParserError(self: *Engine, query: []const u8, token_offset: usize) !void {
        const caret_pad = try self.allocator.alloc(u8, token_offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');

        try self.failUserFmt(
            "Parser exception: Invalid input < GROUP>: expected rule ku_Statements (line: 1, offset: {d})\n\"{s}\"\n{s}^^^^^",
            .{ token_offset, query, caret_pad },
        );
    }

    fn raiseUnknownNotEqualBangParserError(self: *Engine, query: []const u8, token_offset: usize) !void {
        const caret_pad = try self.allocator.alloc(u8, token_offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');

        try self.failUserFmt(
            "Parser exception: Unknown operation '!=' (you probably meant to use '<>', which is the operator for inequality testing.) (line: 1, offset: {d})\n\"{s}\"\n{s}^^",
            .{ token_offset, query, caret_pad },
        );
    }

    fn raisePaginationKeywordParserError(
        self: *Engine,
        query: []const u8,
        token_offset: usize,
        keyword: []const u8,
    ) !void {
        const token = try std.fmt.allocPrint(self.allocator, " {s}", .{keyword});
        defer self.allocator.free(token);

        const caret_pad = try self.allocator.alloc(u8, token_offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');
        const caret_marks = try self.allocator.alloc(u8, keyword.len);
        defer self.allocator.free(caret_marks);
        @memset(caret_marks, '^');

        try self.failUserFmt(
            "Parser exception: Invalid input <{s}>: expected rule ku_Statements (line: 1, offset: {d})\n\"{s}\"\n{s}{s}",
            .{ token, token_offset, query, caret_pad, caret_marks },
        );
    }

    fn raiseTopReturnRegularQueryParserError(self: *Engine, query: []const u8) !void {
        const offset = query.len;
        const caret_pad = try self.allocator.alloc(u8, offset + 1);
        defer self.allocator.free(caret_pad);
        @memset(caret_pad, ' ');

        try self.failUserFmt(
            "Parser exception: Invalid input <{s}>: expected rule oC_RegularQuery (line: 1, offset: {d})\n\"{s}\"\n{s}",
            .{ query, offset, query, caret_pad },
        );
    }

    fn enforceMalformedMatchParserParity(self: *Engine, query: []const u8) !void {
        if (!startsWithAsciiNoCase(query, "MATCH ")) return;

        if (indexOfAsciiNoCaseOutsideStrings(query, " RETURN ")) |return_idx| {
            if (indexOfAsciiNoCaseOutsideStrings(query, " ORDER BY ")) |order_idx| {
                if (order_idx < return_idx) {
                    const offset = order_idx + 1;
                    try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + "ORDER".len, "ORDER".len);
                    unreachable;
                }
            }
        }

        const where_idx = indexOfAsciiNoCaseOutsideStrings(query, " WHERE ") orelse return;
        const where_start = where_idx + " WHERE ".len;
        const return_idx = indexOfAsciiNoCaseOutsideStrings(query[where_start..], " RETURN ") orelse return;
        const where_end = where_start + return_idx;
        const where_text = query[where_start..where_end];
        const trimmed_where = std.mem.trim(u8, where_text, " \t\n\r");

        if (indexOfLiteralOutsideStrings(where_text, "!==")) |rel| {
            const offset = where_start + rel + 2;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + 1, 1);
            unreachable;
        }
        if (indexOfLiteralOutsideStrings(where_text, "===")) |rel| {
            const offset = where_start + rel + 1;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + 1, 1);
            unreachable;
        }
        if (indexOfLiteralOutsideStrings(where_text, "==")) |rel| {
            const offset = where_start + rel + 1;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + 1, 1);
            unreachable;
        }
        if (indexOfLiteralOutsideStrings(where_text, "=>")) |rel| {
            const offset = where_start + rel + 1;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + 1, 1);
            unreachable;
        }
        if (indexOfLiteralOutsideStrings(where_text, "=<")) |rel| {
            const offset = where_start + rel + 1;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + 1, 1);
            unreachable;
        }

        var i: usize = 0;
        while (i + 2 < where_text.len) : (i += 1) {
            if (where_text[i] != '<') continue;
            var j = i + 1;
            while (j < where_text.len and std.ascii.isWhitespace(where_text[j])) : (j += 1) {}
            if (j > i + 1 and j < where_text.len and where_text[j] == '>') {
                const offset = where_start + j;
                try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + 1, 1);
                unreachable;
            }
        }

        if (endsWithAsciiNoCase(trimmed_where, "<>")) {
            const return_arg_offset = where_end + " RETURN ".len;
            try self.raiseSingleQueryInvalidInputParserError(query, return_arg_offset, return_arg_offset + 1, 1);
            unreachable;
        }

        if (trimmed_where.len > 0 and trimmed_where[0] == '=') {
            const rel = std.mem.indexOfScalar(u8, where_text, '=') orelse 0;
            const offset = where_start + rel;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + 1, 1);
            unreachable;
        }

        if (trimmed_where.len >= "IS NULL".len and std.ascii.eqlIgnoreCase(trimmed_where[0.."IS NULL".len], "IS NULL")) {
            const rel = indexOfAsciiNoCase(where_text, "IS NULL") orelse 0;
            const offset = where_start + rel + "IS ".len;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + "NULL".len, "NULL".len);
            unreachable;
        }
        if (endsWithAsciiNoCase(trimmed_where, " IS NOT")) {
            const offset = where_end + 1;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + "RETURN".len, "RETURN".len);
            unreachable;
        }
        if (endsWithAsciiNoCase(trimmed_where, " IS")) {
            const offset = where_end + 1;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + "RETURN".len, "RETURN".len);
            unreachable;
        }
        if (indexOfAsciiNoCase(where_text, " IS MAYBE ")) |rel| {
            const offset = where_start + rel + " IS ".len;
            try self.raiseSingleQueryInvalidInputParserError(query, offset, offset + "MAYBE".len, "MAYBE".len);
            unreachable;
        }
    }

    fn isIdentifierToken(text_in: []const u8) bool {
        const text = std.mem.trim(u8, text_in, " \t\n\r");
        if (text.len == 0) return false;
        const first = text[0];
        if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
        for (text[1..]) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
        }
        return true;
    }

    fn scopeVariableForUnknownExpr(expr_in: []const u8) ?[]const u8 {
        const expr = std.mem.trim(u8, expr_in, " \t\n\r");
        if (expr.len == 0) return null;
        if (Engine.isIdentifierToken(expr)) return expr;
        if (std.mem.indexOfScalar(u8, expr, '.')) |dot_idx| {
            const var_name = std.mem.trim(u8, expr[0..dot_idx], " \t\n\r");
            if (Engine.isIdentifierToken(var_name)) return var_name;
        }
        return null;
    }

    fn parsePropertyAccessExpr(expr_in: []const u8) ?struct { var_name: []const u8, prop_name: []const u8 } {
        const expr = std.mem.trim(u8, expr_in, " \t\n\r");
        if (expr.len == 0) return null;
        const dot_idx = std.mem.indexOfScalar(u8, expr, '.') orelse return null;
        const var_name = std.mem.trim(u8, expr[0..dot_idx], " \t\n\r");
        const prop_name = std.mem.trim(u8, expr[dot_idx + 1 ..], " \t\n\r");
        if (!Engine.isIdentifierToken(var_name) or !Engine.isIdentifierToken(prop_name)) return null;
        return .{ .var_name = var_name, .prop_name = prop_name };
    }

    fn failCannotFindProperty(self: *Engine, var_name: []const u8, prop_name: []const u8) !void {
        try self.failUserFmt("Binder exception: Cannot find property {s} for {s}.", .{ prop_name, var_name });
    }

    fn failPropertyAccessTypeMismatch(self: *Engine, var_name: []const u8, type_name: []const u8) !void {
        try self.failUserFmt(
            "Binder exception: {s} has data type {s} but (NODE,REL,STRUCT,ANY) was expected.",
            .{ var_name, type_name },
        );
    }

    fn failImplicitCastTypeMismatch(self: *Engine, expr: []const u8, actual_type: []const u8, expected_type: []const u8) !void {
        try self.failUserFmt(
            "Binder exception: Expression {s} has data type {s} but expected {s}. Implicit cast is not supported.",
            .{ expr, actual_type, expected_type },
        );
    }

    fn nodeColumnIndexOrBinderError(self: *Engine, table: *const Table, var_name: []const u8, col_name: []const u8) !usize {
        return table.columnIndex(col_name) orelse {
            try self.failCannotFindProperty(var_name, col_name);
            unreachable;
        };
    }

    fn nodeColumnTypeOrBinderError(self: *Engine, table: *const Table, var_name: []const u8, col_name: []const u8) !ColumnType {
        return table.typeFor(col_name) orelse {
            try self.failCannotFindProperty(var_name, col_name);
            unreachable;
        };
    }

    fn relColumnIndexOrBinderError(self: *Engine, rel_table: *const RelTable, var_name: []const u8, col_name: []const u8) !usize {
        return rel_table.columnIndex(col_name) orelse {
            try self.failCannotFindProperty(var_name, col_name);
            unreachable;
        };
    }

    fn relColumnTypeOrBinderError(self: *Engine, rel_table: *const RelTable, var_name: []const u8, col_name: []const u8) !ColumnType {
        return rel_table.typeFor(col_name) orelse {
            try self.failCannotFindProperty(var_name, col_name);
            unreachable;
        };
    }

    fn enforceSkipBeforeLimitParserParity(self: *Engine, query: []const u8, clause: []const u8) !void {
        const limit_keyword = " LIMIT ";
        const skip_keyword = " SKIP ";
        if (indexOfAsciiNoCase(clause, limit_keyword)) |limit_idx| {
            if (indexOfAsciiNoCase(clause, skip_keyword)) |skip_idx| {
                if (limit_idx < skip_idx) {
                    const clause_start = @as(usize, @intCast(@intFromPtr(clause.ptr) - @intFromPtr(query.ptr)));
                    const skip_offset = clause_start + skip_idx + 1;
                    try self.raiseSkipAfterLimitParserError(query, skip_offset);
                    unreachable;
                }
            }
        }
    }

    fn enforceUnsupportedGroupByParserParity(self: *Engine, query: []const u8) !void {
        const group_by_keyword = " GROUP BY ";
        if (indexOfAsciiNoCaseOutsideStrings(query, group_by_keyword)) |idx| {
            const token_offset = idx + 1;
            try self.raiseGroupByParserError(query, token_offset);
            unreachable;
        }
    }

    fn enforceUnsupportedNotEqualBangParserParity(self: *Engine, query: []const u8) !void {
        var start: usize = 0;
        while (start + 2 <= query.len) {
            if (indexOfLiteralOutsideStrings(query[start..], "!=")) |rel_idx| {
                const idx = start + rel_idx;
                if (idx + 2 < query.len and query[idx + 2] == '=') {
                    start = idx + 1;
                    continue;
                }
                try self.raiseUnknownNotEqualBangParserError(query, idx);
                unreachable;
            }
            break;
        }
    }

    fn parseCountProjectionClause(projection_part_in: []const u8) !?struct {
        count_expr: []const u8,
        alias: []const u8,
        count_position: usize,
        term_count: usize,
        distinct: bool,
    } {
        _ = projection_part_in;
        return null;
    }

    fn deinitCountProjectionTerms(self: *Engine, count_terms: *std.ArrayList(CountProjectionTerm)) void {
        for (count_terms.items) |term| {
            if (term.alias_owned) {
                self.allocator.free(term.alias);
            }
        }
        count_terms.deinit(self.allocator);
    }

    fn indexOfAsciiNoCase(haystack: []const u8, needle: []const u8) ?usize {
        if (needle.len == 0) return 0;
        if (haystack.len < needle.len) return null;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
        }
        return null;
    }

    fn indexOfAsciiNoCaseOutsideStrings(haystack: []const u8, needle: []const u8) ?usize {
        if (needle.len == 0) return 0;
        if (haystack.len < needle.len) return null;
        var in_string = false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            const c = haystack[i];
            if (c == '\'') {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
        }
        return null;
    }

    fn indexOfLiteralOutsideStrings(haystack: []const u8, needle: []const u8) ?usize {
        if (needle.len == 0) return 0;
        if (haystack.len < needle.len) return null;
        var in_string = false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            const c = haystack[i];
            if (c == '\'') {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;
            if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
        }
        return null;
    }

    fn startsWithAsciiNoCase(text: []const u8, prefix: []const u8) bool {
        if (text.len < prefix.len) return false;
        return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
    }

    fn endsWithAsciiNoCase(text: []const u8, suffix: []const u8) bool {
        if (text.len < suffix.len) return false;
        return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
    }

    fn collectReferencedParameters(
        self: *Engine,
        query: []const u8,
        out_references: *std.StringHashMap(void),
    ) !void {
        _ = self;
        var i: usize = 0;
        var in_string = false;
        while (i < query.len) {
            const c = query[i];
            if (c == '\'') {
                in_string = !in_string;
                i += 1;
                continue;
            }
            if (!in_string and c == '$') {
                var j = i + 1;
                if (j < query.len and (std.ascii.isAlphabetic(query[j]) or query[j] == '_')) {
                    j += 1;
                    while (j < query.len and (std.ascii.isAlphanumeric(query[j]) or query[j] == '_')) : (j += 1) {}
                    try out_references.put(query[i + 1 .. j], {});
                    i = j;
                    continue;
                }
            }
            i += 1;
        }
    }

    fn validateExtraParameters(self: *Engine, query: []const u8, params: ?*const std.json.ObjectMap) !void {
        const obj = params orelse return;

        var refs = std.StringHashMap(void).init(self.allocator);
        defer refs.deinit();
        try self.collectReferencedParameters(query, &refs);

        var keys: std.ArrayList([]const u8) = .{};
        defer keys.deinit(self.allocator);
        var it = obj.iterator();
        while (it.next()) |entry| {
            try keys.append(self.allocator, entry.key_ptr.*);
        }

        const less = struct {
            fn f(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.f;
        std.sort.heap([]const u8, keys.items, {}, less);

        for (keys.items) |key| {
            if (refs.contains(key)) continue;
            try self.failUserFmt("Parameter {s} not found.", .{key});
            unreachable;
        }
    }

    fn lastIndexOfAsciiNoCase(haystack: []const u8, needle: []const u8) ?usize {
        if (needle.len == 0) return haystack.len;
        if (haystack.len < needle.len) return null;
        var i: usize = haystack.len - needle.len;
        while (true) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
            if (i == 0) break;
            i -= 1;
        }
        return null;
    }

    fn parseDistinctClause(text_in: []const u8) !struct { body: []const u8, distinct: bool } {
        const text = std.mem.trim(u8, text_in, " \t\n\r");
        const distinct_prefix = "DISTINCT ";
        if (text.len >= distinct_prefix.len and std.ascii.eqlIgnoreCase(text[0..distinct_prefix.len], distinct_prefix)) {
            const body = std.mem.trim(u8, text[distinct_prefix.len..], " \t\n\r");
            if (body.len == 0) return error.InvalidReturn;
            return .{
                .body = body,
                .distinct = true,
            };
        }
        return .{
            .body = text,
            .distinct = false,
        };
    }

    fn parsePaginationClause(
        self: *Engine,
        query: []const u8,
        text_in: []const u8,
    ) !struct { body: []const u8, skip: usize, limit: ?usize } {
        var text = std.mem.trim(u8, text_in, " \t\n\r");
        var out_skip: usize = 0;
        var out_limit: ?usize = null;
        var seen_skip = false;
        var seen_limit = false;

        const limit_keyword = " LIMIT ";
        const skip_keyword = " SKIP ";
        const clause_start = @as(usize, @intCast(@intFromPtr(text.ptr) - @intFromPtr(query.ptr)));

        if (indexOfAsciiNoCase(text, skip_keyword)) |first_skip| {
            const rest_start = first_skip + 1;
            if (rest_start < text.len) {
                if (indexOfAsciiNoCase(text[rest_start..], skip_keyword)) |second_skip_rel| {
                    const second_skip = rest_start + second_skip_rel;
                    try self.raisePaginationKeywordParserError(query, clause_start + second_skip + 1, "SKIP");
                    unreachable;
                }
            }
        }
        if (indexOfAsciiNoCase(text, limit_keyword)) |first_limit| {
            const rest_start = first_limit + 1;
            if (rest_start < text.len) {
                if (indexOfAsciiNoCase(text[rest_start..], limit_keyword)) |second_limit_rel| {
                    const second_limit = rest_start + second_limit_rel;
                    try self.raisePaginationKeywordParserError(query, clause_start + second_limit + 1, "LIMIT");
                    unreachable;
                }
            }
        }

        if (indexOfAsciiNoCase(text, limit_keyword)) |limit_idx| {
            if (indexOfAsciiNoCase(text, skip_keyword)) |skip_idx| {
                if (limit_idx < skip_idx) return error.InvalidReturn;
            }
        }
        while (true) {
            const limit_idx = lastIndexOfAsciiNoCase(text, limit_keyword);
            const skip_idx = lastIndexOfAsciiNoCase(text, skip_keyword);

            if (limit_idx == null and skip_idx == null) break;

            const choose_limit = switch (limit_idx != null) {
                true => switch (skip_idx != null) {
                    true => limit_idx.? > skip_idx.?,
                    false => true,
                },
                false => false,
            };

            if (choose_limit) {
                if (seen_limit) return error.InvalidReturn;
                const idx = limit_idx.?;
                const value_text = std.mem.trim(u8, text[idx + limit_keyword.len ..], " \t\n\r");
                if (value_text.len == 0) return error.InvalidReturn;
                const value_i64 = std.fmt.parseInt(i64, value_text, 10) catch {
                    if (Engine.isIdentifierToken(value_text)) {
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{value_text});
                        unreachable;
                    }
                    return error.InvalidReturn;
                };
                if (value_i64 < 0) {
                    try self.failUserMessage("Runtime exception: The number of rows to skip/limit must be a non-negative integer.");
                    unreachable;
                }
                out_limit = @intCast(value_i64);
                seen_limit = true;
                text = std.mem.trim(u8, text[0..idx], " \t\n\r");
                continue;
            }

            if (seen_skip) return error.InvalidReturn;
            const idx = skip_idx.?;
            const value_text = std.mem.trim(u8, text[idx + skip_keyword.len ..], " \t\n\r");
            if (value_text.len == 0) return error.InvalidReturn;
            const value_i64 = std.fmt.parseInt(i64, value_text, 10) catch {
                if (Engine.isIdentifierToken(value_text)) {
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{value_text});
                    unreachable;
                }
                return error.InvalidReturn;
            };
            if (value_i64 < 0) {
                try self.failUserMessage("Runtime exception: The number of rows to skip/limit must be a non-negative integer.");
                unreachable;
            }
            out_skip = @intCast(value_i64);
            seen_skip = true;
            text = std.mem.trim(u8, text[0..idx], " \t\n\r");
        }

        if (text.len == 0) return error.InvalidReturn;
        return .{
            .body = text,
            .skip = out_skip,
            .limit = out_limit,
        };
    }

    fn executeCreateRelTable(self: *Engine, query: []const u8, result: *ResultSet) !void {
        const prefix = "CREATE REL TABLE ";
        const after_prefix = query[prefix.len..];
        const open_idx_rel = std.mem.indexOfScalar(u8, after_prefix, '(') orelse return error.InvalidCreateTable;
        const close_idx = std.mem.lastIndexOfScalar(u8, query, ')') orelse return error.InvalidCreateTable;

        const table_name = Engine.normalizeIdentifierToken(after_prefix[0..open_idx_rel]);
        if (table_name.len == 0) return error.InvalidCreateTable;

        const open_idx = prefix.len + open_idx_rel;
        const inner = query[open_idx + 1 .. close_idx];

        var first_start_rel: usize = 0;
        while (first_start_rel < inner.len and std.ascii.isWhitespace(inner[first_start_rel])) : (first_start_rel += 1) {}
        if (first_start_rel >= inner.len) return error.InvalidCreateTable;

        const comma_idx_rel = if (std.mem.indexOfScalar(u8, inner[first_start_rel..], ',')) |idx|
            first_start_rel + idx
        else
            null;
        const first_end_rel = comma_idx_rel orelse inner.len;
        const first_clause = std.mem.trim(u8, inner[first_start_rel..first_end_rel], " \t\n\r");

        if (!startsWithAsciiNoCase(first_clause, "FROM ")) {
            var token_end: usize = 0;
            while (token_end < first_clause.len and !std.ascii.isWhitespace(first_clause[token_end])) : (token_end += 1) {}
            const token = if (token_end == 0) first_clause else first_clause[0..token_end];
            const token_offset = open_idx + 1 + first_start_rel;
            try self.raiseExtraneousInputParserError(query, token, "{FROM, SP}", token_offset);
            unreachable;
        }

        var first_tokens = std.mem.tokenizeScalar(u8, first_clause, ' ');
        _ = first_tokens.next(); // FROM
        _ = first_tokens.next() orelse return error.InvalidCreateTable; // from table name
        const maybe_to_kw = first_tokens.next();
        if (maybe_to_kw == null and comma_idx_rel != null) {
            const comma_offset = open_idx + 1 + comma_idx_rel.?;
            try self.raiseExtraneousInputParserError(query, ",", "SP", comma_offset);
            unreachable;
        }

        var from_table: ?[]const u8 = null;
        var to_table: ?[]const u8 = null;

        var table = try RelTable.init(self.allocator, table_name, "", "");
        errdefer table.deinit();

        var iter = std.mem.splitScalar(u8, inner, ',');
        while (iter.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t\n\r");
            if (part.len == 0) continue;

            if (startsWithAsciiNoCase(part, "FROM ")) {
                var token_iter = std.mem.tokenizeScalar(u8, part, ' ');
                _ = token_iter.next(); // FROM
                const from_name_raw = token_iter.next() orelse return error.InvalidCreateTable;
                const to_kw = token_iter.next() orelse return error.InvalidCreateTable;
                const to_name_raw = token_iter.next() orelse return error.InvalidCreateTable;
                if (!std.ascii.eqlIgnoreCase(to_kw, "TO")) return error.InvalidCreateTable;
                from_table = Engine.normalizeIdentifierToken(from_name_raw);
                to_table = Engine.normalizeIdentifierToken(to_name_raw);
                continue;
            }

            var token_iter = std.mem.tokenizeScalar(u8, part, ' ');
            const col_name_raw = token_iter.next() orelse return error.InvalidCreateTable;
            const col_name = Engine.normalizeIdentifierToken(col_name_raw);
            const col_type = token_iter.next() orelse return error.InvalidCreateTable;

            if (table.columnIndex(col_name) != null) {
                try self.failUserFmt("Binder exception: Duplicated column name: {s}, column name must be unique.", .{col_name});
                unreachable;
            }

            const ty: ColumnType = try Engine.parseColumnTypeToken(col_type);

            try table.columns.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, col_name),
                .ty = ty,
            });
        }

        const from_name_input = from_table orelse return error.InvalidCreateTable;
        const to_name_input = to_table orelse return error.InvalidCreateTable;
        const from_name = self.findNodeTableKeyCaseInsensitive(from_name_input) orelse {
            return self.failUserFmt("Binder exception: Table {s} does not exist.", .{from_name_input});
        };
        const to_name = self.findNodeTableKeyCaseInsensitive(to_name_input) orelse {
            return self.failUserFmt("Binder exception: Table {s} does not exist.", .{to_name_input});
        };
        if (from_name.len == 0 or to_name.len == 0) {
            return error.InvalidCreateTable;
        }

        self.allocator.free(table.from_table);
        self.allocator.free(table.to_table);
        table.from_table = try self.allocator.dupe(u8, from_name);
        table.to_table = try self.allocator.dupe(u8, to_name);

        if (self.catalogNameExistsCaseInsensitive(table_name)) {
            try self.failUserFmt("Binder exception: {s} already exists in catalog.", .{table_name});
            unreachable;
        }

        const key = try self.allocator.dupe(u8, table_name);
        errdefer self.allocator.free(key);
        try self.rel_tables.put(key, table);
        try self.appendCreateTableResult(result, table_name);
    }

    fn cellsEqualForPk(left: Cell, right: Cell) bool {
        return switch (left) {
            .string => |ls| switch (right) {
                .string => |rs| std.mem.eql(u8, ls, rs),
                else => false,
            },
            .int64 => |li| switch (right) {
                .int64 => |ri| li == ri,
                else => false,
            },
            .uint64 => |li| switch (right) {
                .uint64 => |ri| li == ri,
                else => false,
            },
            .float64 => |lf| switch (right) {
                .float64 => |rf| lf == rf,
                else => false,
            },
            .null => false,
        };
    }

    fn enforceCreatePrimaryKey(self: *Engine, table: *const Table, row: []const Cell, pk_present: bool) !void {
        const pk_name = table.primary_key orelse return;
        const pk_idx = table.columnIndex(pk_name) orelse return error.ColumnNotFound;
        const pk_cell = row[pk_idx];

        if (!pk_present) {
            return self.failUserFmt("Binder exception: Create node  expects primary key {s} as input.", .{pk_name});
        }

        if (cellIsNull(pk_cell)) {
            return self.failUserMessage("Runtime exception: Found NULL, which violates the non-null constraint of the primary key column.");
        }

        for (table.rows.items) |existing_row| {
            if (!Engine.cellsEqualForPk(existing_row[pk_idx], pk_cell)) continue;
            return switch (pk_cell) {
                .string => |s| self.failUserFmt("Runtime exception: Found duplicated primary key value {s}, which violates the uniqueness constraint of the primary key column.", .{s}),
                .int64 => |v| self.failUserFmt("Runtime exception: Found duplicated primary key value {d}, which violates the uniqueness constraint of the primary key column.", .{v}),
                .uint64 => |v| self.failUserFmt("Runtime exception: Found duplicated primary key value {d}, which violates the uniqueness constraint of the primary key column.", .{v}),
                .float64 => |v| self.failUserFmt("Runtime exception: Found duplicated primary key value {d}, which violates the uniqueness constraint of the primary key column.", .{v}),
                .null => self.failUserMessage("Runtime exception: Found NULL, which violates the non-null constraint of the primary key column."),
            };
        }
    }

    fn createNodeFromPattern(
        self: *Engine,
        pattern_in: []const u8,
        params: ?*const std.json.ObjectMap,
        scope_vars: []const []const u8,
    ) !struct { table: *Table, row_idx: usize, var_name: []const u8 } {
        const pattern = std.mem.trim(u8, pattern_in, " \t\n\r");
        if (pattern.len < 4 or pattern[0] != '(' or pattern[pattern.len - 1] != ')') return error.InvalidCreateNode;

        const inner = std.mem.trim(u8, pattern[1 .. pattern.len - 1], " \t\n\r");
        const head_colon_idx = std.mem.indexOfScalar(u8, inner, ':') orelse return error.InvalidCreateNode;
        const var_name = std.mem.trim(u8, inner[0..head_colon_idx], " \t\n\r");
        if (var_name.len > 0 and !Engine.isIdentifierToken(var_name)) return error.InvalidCreateNode;
        const after_colon = inner[head_colon_idx + 1 ..];
        const brace_idx = std.mem.indexOfScalar(u8, after_colon, '{') orelse return error.InvalidCreateNode;
        const close_brace = std.mem.lastIndexOfScalar(u8, after_colon, '}') orelse return error.InvalidCreateNode;
        if (close_brace <= brace_idx) return error.InvalidCreateNode;

        const table_name = std.mem.trim(u8, after_colon[0..brace_idx], " \t\n\r");
        if (table_name.len == 0) return error.InvalidCreateNode;
        const table = self.node_tables.getPtr(table_name) orelse {
            try self.failUserFmt("Binder exception: Table {s} does not exist.", .{table_name});
            unreachable;
        };
        const props_inner = after_colon[brace_idx + 1 .. close_brace];

        var row = try self.allocator.alloc(Cell, table.columns.items.len);
        errdefer self.allocator.free(row);
        for (row) |*cell| {
            cell.* = .null;
        }

        var pk_present = false;
        var props = std.mem.splitScalar(u8, props_inner, ',');
        while (props.next()) |raw_prop| {
            const prop = std.mem.trim(u8, raw_prop, " \t\n\r");
            if (prop.len == 0) continue;

            const colon_idx = std.mem.indexOfScalar(u8, prop, ':') orelse return error.InvalidCreateNode;
            const key = std.mem.trim(u8, prop[0..colon_idx], " \t\n\r");
            const value_text = prop[colon_idx + 1 ..];
            const col_idx = table.columnIndex(key) orelse return error.ColumnNotFound;
            const expected = table.columns.items[col_idx].ty;
            if (table.primary_key) |pk_name| {
                if (std.mem.eql(u8, key, pk_name)) {
                    pk_present = true;
                }
            }
            const literal = self.parseLiteralOrParameter(value_text, params) catch |err| {
                if (Engine.parsePropertyAccessExpr(value_text)) |property_expr| {
                    var in_scope = var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, var_name);
                    if (!in_scope) {
                        for (scope_vars) |scope_var| {
                            if (std.mem.eql(u8, property_expr.var_name, scope_var)) {
                                in_scope = true;
                                break;
                            }
                        }
                    }
                    if (in_scope) {
                        try self.failUserMessage("Cannot evaluate expression with type PROPERTY.");
                        unreachable;
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                    unreachable;
                }
                const rhs = std.mem.trim(u8, value_text, " \t\n\r");
                if (Engine.isIdentifierToken(rhs) and
                    !std.ascii.eqlIgnoreCase(rhs, "true") and
                    !std.ascii.eqlIgnoreCase(rhs, "false") and
                    !std.ascii.eqlIgnoreCase(rhs, "null"))
                {
                    var in_scope = var_name.len > 0 and std.mem.eql(u8, rhs, var_name);
                    if (!in_scope) {
                        for (scope_vars) |scope_var| {
                            if (std.mem.eql(u8, rhs, scope_var)) {
                                in_scope = true;
                                break;
                            }
                        }
                    }
                    if (in_scope) {
                        try self.failImplicitCastTypeMismatch(rhs, "NODE", typeName(expected));
                        unreachable;
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{rhs});
                    unreachable;
                }
                return err;
            };

            switch (literal) {
                .string => |s| {
                    if (expected != .STRING) {
                        try self.failImplicitCastTypeMismatch(s, "STRING", typeName(expected));
                        unreachable;
                    }
                    row[col_idx] = .{ .string = try self.allocator.dupe(u8, s) };
                },
                .int64 => |v| {
                    if (Engine.isIntegerType(expected)) {
                        try self.ensureIntegerInTypeRange(v, expected);
                        if (expected == .UINT64) {
                            row[col_idx] = .{ .uint64 = @intCast(v) };
                        } else {
                            row[col_idx] = .{ .int64 = v };
                        }
                    } else if (expected == .DOUBLE) {
                        row[col_idx] = .{ .float64 = @as(f64, @floatFromInt(v)) };
                    } else if (expected == .STRING) {
                        row[col_idx] = .{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) };
                    } else {
                        const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                        defer self.allocator.free(expr);
                        try self.failImplicitCastTypeMismatch(expr, "INT64", typeName(expected));
                        unreachable;
                    }
                },
                .float64 => |v| {
                    if (expected == .DOUBLE) {
                        row[col_idx] = .{ .float64 = v };
                    } else if (Engine.isIntegerType(expected)) {
                        const rounded = Engine.roundFloatToInt64LikeKuzu(v);
                        try self.ensureIntegerInTypeRange(rounded, expected);
                        if (expected == .UINT64) {
                            row[col_idx] = .{ .uint64 = @intCast(rounded) };
                        } else {
                            row[col_idx] = .{ .int64 = rounded };
                        }
                    } else if (expected == .STRING) {
                        row[col_idx] = .{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) };
                    } else {
                        const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                        defer self.allocator.free(expr);
                        try self.failImplicitCastTypeMismatch(expr, "DOUBLE", typeName(expected));
                        unreachable;
                    }
                },
                .bool => |b| {
                    if (expected == .BOOL) {
                        row[col_idx] = .{ .int64 = if (b) 1 else 0 };
                    } else if (expected == .STRING) {
                        row[col_idx] = .{ .string = try self.allocator.dupe(u8, if (b) "True" else "False") };
                    } else {
                        try self.failImplicitCastTypeMismatch(if (b) "True" else "False", "BOOL", typeName(expected));
                        unreachable;
                    }
                },
                .uint64 => |v| {
                    if (expected == .UINT64) {
                        row[col_idx] = .{ .uint64 = v };
                    } else if (Engine.isUnsignedIntegerType(expected)) {
                        try self.ensureUnsignedInTypeRange(v, expected);
                        row[col_idx] = .{ .int64 = @intCast(v) };
                    } else if (expected == .DOUBLE) {
                        row[col_idx] = .{ .float64 = @floatFromInt(v) };
                    } else if (expected == .STRING) {
                        row[col_idx] = .{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) };
                    } else if (Engine.isIntegerType(expected)) {
                        try self.failUserFmt("Overflow exception: Value {d} is not within {s} range", .{ v, typeName(expected) });
                        unreachable;
                    } else {
                        const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                        defer self.allocator.free(expr);
                        try self.failImplicitCastTypeMismatch(expr, "UINT64", typeName(expected));
                        unreachable;
                    }
                },
                .null => {
                    row[col_idx] = .null;
                },
            }
        }

        try self.enforceCreatePrimaryKey(table, row, pk_present);
        try table.rows.append(self.allocator, row);
        return .{ .table = table, .row_idx = table.rows.items.len - 1, .var_name = var_name };
    }

    fn executeCreateNode(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        const return_keyword = " RETURN ";
        var create_part = std.mem.trim(u8, query["CREATE ".len..], " \t\n\r");
        var return_part: ?[]const u8 = null;
        if (indexOfAsciiNoCase(query, return_keyword)) |return_idx| {
            create_part = std.mem.trim(u8, query["CREATE ".len..return_idx], " \t\n\r");
            return_part = std.mem.trim(u8, query[return_idx + return_keyword.len ..], " \t\n\r");
        }
        var create_patterns = try self.splitTopLevelCreatePatterns(create_part);
        defer create_patterns.deinit(self.allocator);
        if (create_patterns.items.len > 1) {
            try self.executeCreateMultiPattern(query, params, result);
            return;
        }

        const created = try self.createNodeFromPattern(create_part, params, &[_][]const u8{});
        if (return_part == null) return;

        const table = created.table;
        const created_row = table.rows.items[created.row_idx];
        const scope_var = if (created.var_name.len > 0) created.var_name else "__hippo_create_node_out_of_scope__";
        const return_text = return_part.?;

        try self.enforceSkipBeforeLimitParserParity(query, return_text);
        const pagination = try self.parsePaginationClause(query, return_text);
        const distinct_clause = try parseDistinctClause(pagination.body);
        const return_body = distinct_clause.body;
        const return_distinct = distinct_clause.distinct;
        const result_skip = pagination.skip;
        const result_limit = pagination.limit;

        const order_keyword = " ORDER BY ";
        var projection_part = return_body;
        var order_expr: ?[]const u8 = null;
        if (indexOfAsciiNoCase(return_body, order_keyword)) |order_idx| {
            projection_part = std.mem.trim(u8, return_body[0..order_idx], " \t\n\r");
            order_expr = std.mem.trim(u8, return_body[order_idx + order_keyword.len ..], " \t\n\r");
        }
        try self.validateProjectionTermsExplicitAs(query, projection_part);

        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        const has_count_projection = (self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
            error.InvalidCountDistinctStar => {
                try self.raiseCountDistinctStarProjectionError(query);
                unreachable;
            },
            else => return err,
        });

        if (has_count_projection) {
            var count_targets: std.ArrayList(NodeCountTarget) = .{};
            defer count_targets.deinit(self.allocator);
            for (count_terms.items) |count_term| {
                if (self.parsePropertyExprOptional(count_term.count_expr, scope_var) == null) {
                    if (Engine.parsePropertyAccessExpr(count_term.count_expr)) |property_expr| {
                        if (created.var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, created.var_name)) {
                            try self.failCannotFindProperty(created.var_name, property_expr.prop_name);
                            unreachable;
                        }
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                        unreachable;
                    }
                    if (Engine.scopeVariableForUnknownExpr(count_term.count_expr)) |unknown_var| {
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                        unreachable;
                    }
                }
                try count_targets.append(
                    self.allocator,
                    try self.parseNodeCountTarget(count_term.count_expr, scope_var, table, params, count_term.distinct),
                );
            }

            var group_types: std.ArrayList([]const u8) = .{};
            defer group_types.deinit(self.allocator);
            var group_is_scalar: std.ArrayList(bool) = .{};
            defer group_is_scalar.deinit(self.allocator);
            var group_scalar_default_aliases: std.ArrayList(?[]const u8) = .{};
            defer group_scalar_default_aliases.deinit(self.allocator);
            const group_cells = try self.allocator.alloc(Cell, group_terms.items.len);
            defer self.allocator.free(group_cells);
            var group_cells_initialized: usize = 0;
            defer {
                for (group_cells[0..group_cells_initialized]) |*cell| {
                    cell.deinit(self.allocator);
                }
            }

            for (group_terms.items, 0..) |group_term, idx| {
                if (self.parsePropertyExprOptional(group_term.expr, scope_var)) |col_name| {
                    const col_idx = try self.nodeColumnIndexOrBinderError(table, scope_var, col_name);
                    const ty = try self.nodeColumnTypeOrBinderError(table, scope_var, col_name);
                    group_cells[idx] = try created_row[col_idx].clone(self.allocator);
                    group_cells_initialized += 1;
                    try group_types.append(self.allocator, typeName(ty));
                    try group_is_scalar.append(self.allocator, false);
                    try group_scalar_default_aliases.append(self.allocator, null);
                    continue;
                }

                if (Engine.parsePropertyAccessExpr(group_term.expr)) |property_expr| {
                    if (created.var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, created.var_name)) {
                        try self.failCannotFindProperty(created.var_name, property_expr.prop_name);
                        unreachable;
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                    unreachable;
                }
                if (Engine.scopeVariableForUnknownExpr(group_term.expr)) |unknown_var| {
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                    unreachable;
                }

                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                group_cells[idx] = scalar.cell;
                group_cells_initialized += 1;
                try group_types.append(self.allocator, scalar.type_name);
                try group_is_scalar.append(self.allocator, true);
                try group_scalar_default_aliases.append(self.allocator, scalar.default_alias);
            }

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = 4;
            for (0..projection_term_count) |position| {
                if (Engine.findCountTermIndexByPosition(count_terms.items, position)) |count_idx| {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[count_idx].alias));
                    try result.types.append(self.allocator, "INT64");
                    implicit_param_alias_slot += 1;
                    continue;
                }
                if (Engine.findGroupTermIndexByPosition(group_terms.items, position)) |group_idx| {
                    const group_term = group_terms.items[group_idx];
                    var output_alias = group_term.alias;
                    var output_alias_owned = false;
                    defer if (output_alias_owned) self.allocator.free(output_alias);
                    if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                        const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                        if (!param_lookup.present) {
                            output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                            output_alias_owned = true;
                        }
                    } else if (!group_term.alias_explicit and group_is_scalar.items[group_idx]) {
                        output_alias = group_scalar_default_aliases.items[group_idx] orelse output_alias;
                    }
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                    try result.types.append(self.allocator, group_types.items[group_idx]);
                    if (group_is_scalar.items[group_idx]) {
                        implicit_param_alias_slot += 1;
                    }
                    continue;
                }
                return error.InvalidReturn;
            }

            const counts = try self.allocator.alloc(i64, count_terms.items.len);
            defer self.allocator.free(counts);
            @memset(counts, 0);
            const seen_maps = try self.initSeenMaps(count_terms.items);
            defer self.deinitSeenMaps(seen_maps);
            try self.updateNodeCountAccumulators(created_row, count_terms.items, count_targets.items, counts, seen_maps);

            const out = try self.buildCountOutputRowFromTerms(
                projection_term_count,
                group_terms.items,
                group_cells[0..group_cells_initialized],
                count_terms.items,
                counts,
            );
            try result.rows.append(self.allocator, out);
        } else {
            if (projection_term_count != group_terms.items.len) return error.InvalidReturn;

            const CreateNodeReturnSource = union(enum) {
                column: usize,
                scalar_expr: []const u8,
            };
            var projection_sources: std.ArrayList(CreateNodeReturnSource) = .{};
            defer projection_sources.deinit(self.allocator);

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = 4;

            for (group_terms.items) |group_term| {
                if (self.parsePropertyExprOptional(group_term.expr, scope_var)) |col_name| {
                    const col_idx = try self.nodeColumnIndexOrBinderError(table, scope_var, col_name);
                    const ty = try self.nodeColumnTypeOrBinderError(table, scope_var, col_name);
                    try projection_sources.append(self.allocator, .{ .column = col_idx });
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_term.alias));
                    try result.types.append(self.allocator, typeName(ty));
                    continue;
                }

                if (Engine.parsePropertyAccessExpr(group_term.expr)) |property_expr| {
                    if (created.var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, created.var_name)) {
                        try self.failCannotFindProperty(created.var_name, property_expr.prop_name);
                        unreachable;
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                    unreachable;
                }
                if (Engine.scopeVariableForUnknownExpr(group_term.expr)) |unknown_var| {
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                    unreachable;
                }

                var output_alias = group_term.alias;
                var output_alias_owned = false;
                defer if (output_alias_owned) self.allocator.free(output_alias);
                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                var probe_cell = scalar.cell;
                probe_cell.deinit(self.allocator);
                if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                    const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                    if (!param_lookup.present) {
                        output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                        output_alias_owned = true;
                    } else {
                        output_alias = scalar.default_alias;
                    }
                } else if (!group_term.alias_explicit) {
                    output_alias = scalar.default_alias;
                }
                try projection_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                try result.types.append(self.allocator, scalar.type_name);
                implicit_param_alias_slot += 1;
            }

            var out_row = try self.allocator.alloc(Cell, projection_sources.items.len);
            errdefer self.allocator.free(out_row);
            var initialized: usize = 0;
            errdefer {
                for (0..initialized) |i| {
                    out_row[i].deinit(self.allocator);
                }
            }
            for (projection_sources.items, 0..) |projection_source, out_idx| {
                out_row[out_idx] = switch (projection_source) {
                    .column => |col_idx| try created_row[col_idx].clone(self.allocator),
                    .scalar_expr => |expr| blk: {
                        const scalar = try self.evaluateReturnScalarExpr(expr, params);
                        break :blk scalar.cell;
                    },
                };
                initialized += 1;
            }
            try result.rows.append(self.allocator, out_row);
        }

        if (return_distinct) {
            try self.dedupeResultRows(result);
        }
        if (order_expr) |order_text| {
            var out_keys: std.ArrayList(OutputOrderKey) = .{};
            defer out_keys.deinit(self.allocator);
            try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
            if (return_distinct) {
                sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
            } else {
                sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
            }
        }
        self.applyResultWindow(result, result_skip, result_limit);
    }

    fn executeCreateRelationship(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        const return_keyword = " RETURN ";
        var create_query = query;
        var return_part: ?[]const u8 = null;
        if (indexOfAsciiNoCase(query, return_keyword)) |return_idx| {
            create_query = std.mem.trim(u8, query[0..return_idx], " \t\n\r");
            return_part = std.mem.trim(u8, query[return_idx + return_keyword.len ..], " \t\n\r");
        }

        const after_create = std.mem.trim(u8, create_query["CREATE ".len..], " \t\n\r");
        var create_patterns = try self.splitTopLevelCreatePatterns(after_create);
        defer create_patterns.deinit(self.allocator);
        if (create_patterns.items.len > 1) {
            try self.executeCreateMultiPattern(query, params, result);
            return;
        }

        const left_end = std.mem.indexOf(u8, after_create, ")-[") orelse return error.InvalidCreateNode;

        const left_pattern = after_create[0 .. left_end + 1];
        const after_left = after_create[left_end + 3 ..];
        const rel_end = std.mem.indexOf(u8, after_left, "]->(") orelse return error.InvalidCreateNode;
        const rel_part = std.mem.trim(u8, after_left[0..rel_end], " \t\n\r");
        const right_pattern = after_left[rel_end + 3 ..];

        const left_ref = try self.createNodeFromPattern(left_pattern, params, &[_][]const u8{});
        const right_ref = try self.createNodeFromPattern(right_pattern, params, &[_][]const u8{});
        const left_var = if (left_ref.var_name.len > 0) left_ref.var_name else "__hippo_create_rel_left_out_of_scope__";
        const right_var = if (right_ref.var_name.len > 0) right_ref.var_name else "__hippo_create_rel_right_out_of_scope__";

        var rel_head = rel_part;
        var rel_props: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rel_part, '{')) |open_brace| {
            const close_brace = std.mem.lastIndexOfScalar(u8, rel_part, '}') orelse return error.InvalidCreateNode;
            if (close_brace <= open_brace) return error.InvalidCreateNode;
            rel_head = std.mem.trim(u8, rel_part[0..open_brace], " \t\n\r");
            rel_props = rel_part[open_brace + 1 .. close_brace];
        }
        const rel_colon_idx = std.mem.indexOfScalar(u8, rel_head, ':') orelse return error.InvalidCreateNode;
        const rel_var_raw = std.mem.trim(u8, rel_head[0..rel_colon_idx], " \t\n\r");
        if (rel_var_raw.len > 0 and !Engine.isIdentifierToken(rel_var_raw)) return error.InvalidCreateNode;
        const rel_name = std.mem.trim(u8, rel_head[rel_colon_idx + 1 ..], " \t\n\r");
        if (rel_name.len == 0) return error.InvalidCreateNode;
        const rel_var = if (rel_var_raw.len > 0) rel_var_raw else "__hippo_create_rel_rel_out_of_scope__";

        const rel_table = self.rel_tables.getPtr(rel_name) orelse return error.TableNotFound;
        if (!std.mem.eql(u8, left_ref.table.name, rel_table.from_table)) return error.RelEndpointTypeMismatch;
        if (!std.mem.eql(u8, right_ref.table.name, rel_table.to_table)) return error.RelEndpointTypeMismatch;

        var prop_assignments: std.ArrayList(RelSetAssignment) = .{};
        defer prop_assignments.deinit(self.allocator);
        var prop_assignment_texts: std.ArrayList([]u8) = .{};
        defer {
            for (prop_assignment_texts.items) |text| {
                self.allocator.free(text);
            }
            prop_assignment_texts.deinit(self.allocator);
        }
        const rel_assign_var = if (rel_var_raw.len > 0) rel_var_raw else "__hippo_create_rel_assign__";
        var prop_iter = std.mem.splitScalar(u8, rel_props, ',');
        while (prop_iter.next()) |raw_prop| {
            const prop = std.mem.trim(u8, raw_prop, " \t\n\r");
            if (prop.len == 0) continue;

            const prop_colon_idx = std.mem.indexOfScalar(u8, prop, ':') orelse return error.InvalidCreateNode;
            const key = std.mem.trim(u8, prop[0..prop_colon_idx], " \t\n\r");
            const value_text = std.mem.trim(u8, prop[prop_colon_idx + 1 ..], " \t\n\r");
            const assignment_text = try std.fmt.allocPrint(self.allocator, "{s}.{s} = {s}", .{
                rel_assign_var,
                key,
                value_text,
            });
            try prop_assignment_texts.append(self.allocator, assignment_text);
            try prop_assignments.append(
                self.allocator,
                try self.parseRelSetAssignment(
                    left_var,
                    right_var,
                    rel_table,
                    rel_assign_var,
                    left_ref.table,
                    right_ref.table,
                    assignment_text,
                    params,
                ),
            );
        }

        var props = try self.allocator.alloc(Cell, rel_table.columns.items.len);
        errdefer self.allocator.free(props);
        for (props) |*cell| {
            cell.* = .null;
        }

        const left_row = left_ref.table.rows.items[left_ref.row_idx];
        const right_row = right_ref.table.rows.items[right_ref.row_idx];
        for (prop_assignments.items) |assignment| {
            const new_value = switch (assignment.rhs) {
                .literal => |value| switch (value) {
                    .null => Cell.null,
                    .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                    .int64 => |v| Cell{ .int64 = v },
                    .uint64 => |v| Cell{ .uint64 = v },
                    .bool => |b| Cell{ .int64 = if (b) 1 else 0 },
                    .float64 => |v| Cell{ .float64 = v },
                },
                .literal_int64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                .literal_float64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                .ref => |rhs_ref| try Engine.relCellFor(rhs_ref, left_row, right_row, props).clone(self.allocator),
                .ref_int64_to_string => |rhs_ref| blk: {
                    const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                    const cast_cell: Cell = switch (source) {
                        .null => Cell.null,
                        .int64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                        .uint64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                        .float64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                        .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                    };
                    break :blk cast_cell;
                },
                .ref_int64_to_double => |rhs_ref| blk: {
                    const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                    const cast_cell: Cell = switch (source) {
                        .null => Cell.null,
                        .int64 => |v| Cell{ .float64 = @as(f64, @floatFromInt(v)) },
                        .uint64 => |v| Cell{ .float64 = @floatFromInt(v) },
                        .float64 => |v| Cell{ .float64 = v },
                        .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                    };
                    break :blk cast_cell;
                },
                .ref_float64_to_int64 => |rhs_ref| blk: {
                    const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                    const cast_cell: Cell = switch (source) {
                        .null => Cell.null,
                        .int64 => |v| Cell{ .int64 = v },
                        .uint64 => |v| blk2: {
                            if (v > std.math.maxInt(i64)) {
                                try self.failUserFmt("Overflow exception: Value {d} is not within INT64 range", .{v});
                                unreachable;
                            }
                            break :blk2 Cell{ .int64 = @intCast(v) };
                        },
                        .float64 => |v| Cell{ .int64 = Engine.roundFloatToInt64LikeKuzu(v) },
                        .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                    };
                    break :blk cast_cell;
                },
            };
            const target = &props[assignment.col_idx];
            target.deinit(self.allocator);
            target.* = new_value;
        }

        try rel_table.rows.append(self.allocator, .{
            .src_row = left_ref.row_idx,
            .dst_row = right_ref.row_idx,
            .props = props,
        });

        if (return_part == null) return;
        const return_text = return_part.?;

        try self.enforceSkipBeforeLimitParserParity(query, return_text);
        const pagination = try self.parsePaginationClause(query, return_text);
        const distinct_clause = try parseDistinctClause(pagination.body);
        const return_body = distinct_clause.body;
        const return_distinct = distinct_clause.distinct;
        const result_skip = pagination.skip;
        const result_limit = pagination.limit;

        const order_keyword = " ORDER BY ";
        var projection_part = return_body;
        var order_expr: ?[]const u8 = null;
        if (indexOfAsciiNoCase(return_body, order_keyword)) |order_idx| {
            projection_part = std.mem.trim(u8, return_body[0..order_idx], " \t\n\r");
            order_expr = std.mem.trim(u8, return_body[order_idx + order_keyword.len ..], " \t\n\r");
        }
        try self.validateProjectionTermsExplicitAs(query, projection_part);

        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        const has_count_projection = (self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
            error.InvalidCountDistinctStar => {
                try self.raiseCountDistinctStarProjectionError(query);
                unreachable;
            },
            else => return err,
        });

        if (has_count_projection) {
            var count_targets: std.ArrayList(RelCountTarget) = .{};
            defer count_targets.deinit(self.allocator);
            for (count_terms.items) |count_term| {
                if ((try self.resolveRelProjectionRefOptional(
                    count_term.count_expr,
                    left_var,
                    right_var,
                    rel_var,
                    left_ref.table,
                    right_ref.table,
                    rel_table,
                )) == null) {
                    if (Engine.parsePropertyAccessExpr(count_term.count_expr)) |property_expr| {
                        if (left_ref.var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, left_ref.var_name)) {
                            try self.failCannotFindProperty(left_ref.var_name, property_expr.prop_name);
                            unreachable;
                        }
                        if (right_ref.var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, right_ref.var_name)) {
                            try self.failCannotFindProperty(right_ref.var_name, property_expr.prop_name);
                            unreachable;
                        }
                        if (rel_var_raw.len > 0 and std.mem.eql(u8, property_expr.var_name, rel_var_raw)) {
                            try self.failCannotFindProperty(rel_var_raw, property_expr.prop_name);
                            unreachable;
                        }
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                        unreachable;
                    }
                    if (Engine.scopeVariableForUnknownExpr(count_term.count_expr)) |unknown_var| {
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                        unreachable;
                    }
                }

                try count_targets.append(
                    self.allocator,
                    try self.parseRelCountTarget(
                        count_term.count_expr,
                        left_var,
                        right_var,
                        rel_var,
                        left_ref.table,
                        right_ref.table,
                        rel_table,
                        params,
                        count_term.distinct,
                    ),
                );
            }

            var group_types: std.ArrayList([]const u8) = .{};
            defer group_types.deinit(self.allocator);
            var group_is_scalar: std.ArrayList(bool) = .{};
            defer group_is_scalar.deinit(self.allocator);
            var group_scalar_default_aliases: std.ArrayList(?[]const u8) = .{};
            defer group_scalar_default_aliases.deinit(self.allocator);
            const group_cells = try self.allocator.alloc(Cell, group_terms.items.len);
            defer self.allocator.free(group_cells);
            var group_cells_initialized: usize = 0;
            defer {
                for (group_cells[0..group_cells_initialized]) |*cell| {
                    cell.deinit(self.allocator);
                }
            }

            for (group_terms.items, 0..) |group_term, idx| {
                if (try self.resolveRelProjectionRefOptional(
                    group_term.expr,
                    left_var,
                    right_var,
                    rel_var,
                    left_ref.table,
                    right_ref.table,
                    rel_table,
                )) |resolved_ref| {
                    const resolved_ty = switch (resolved_ref.source) {
                        .left => left_ref.table.columns.items[resolved_ref.col_idx].ty,
                        .right => right_ref.table.columns.items[resolved_ref.col_idx].ty,
                        .rel => rel_table.columns.items[resolved_ref.col_idx].ty,
                    };
                    group_cells[idx] = try Engine.relCellFor(resolved_ref, left_ref.table.rows.items[left_ref.row_idx], right_ref.table.rows.items[right_ref.row_idx], props).clone(self.allocator);
                    group_cells_initialized += 1;
                    try group_types.append(self.allocator, typeName(resolved_ty));
                    try group_is_scalar.append(self.allocator, false);
                    try group_scalar_default_aliases.append(self.allocator, null);
                    continue;
                }

                if (Engine.parsePropertyAccessExpr(group_term.expr)) |property_expr| {
                    if (left_ref.var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, left_ref.var_name)) {
                        try self.failCannotFindProperty(left_ref.var_name, property_expr.prop_name);
                        unreachable;
                    }
                    if (right_ref.var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, right_ref.var_name)) {
                        try self.failCannotFindProperty(right_ref.var_name, property_expr.prop_name);
                        unreachable;
                    }
                    if (rel_var_raw.len > 0 and std.mem.eql(u8, property_expr.var_name, rel_var_raw)) {
                        try self.failCannotFindProperty(rel_var_raw, property_expr.prop_name);
                        unreachable;
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                    unreachable;
                }
                if (Engine.scopeVariableForUnknownExpr(group_term.expr)) |unknown_var| {
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                    unreachable;
                }

                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                group_cells[idx] = scalar.cell;
                group_cells_initialized += 1;
                try group_types.append(self.allocator, scalar.type_name);
                try group_is_scalar.append(self.allocator, true);
                try group_scalar_default_aliases.append(self.allocator, scalar.default_alias);
            }

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = 10;
            for (0..projection_term_count) |position| {
                if (Engine.findCountTermIndexByPosition(count_terms.items, position)) |count_idx| {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[count_idx].alias));
                    try result.types.append(self.allocator, "INT64");
                    implicit_param_alias_slot += 1;
                    continue;
                }
                if (Engine.findGroupTermIndexByPosition(group_terms.items, position)) |group_idx| {
                    const group_term = group_terms.items[group_idx];
                    var output_alias = group_term.alias;
                    var output_alias_owned = false;
                    defer if (output_alias_owned) self.allocator.free(output_alias);
                    if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                        const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                        if (!param_lookup.present) {
                            output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                            output_alias_owned = true;
                        }
                    } else if (!group_term.alias_explicit and group_is_scalar.items[group_idx]) {
                        output_alias = group_scalar_default_aliases.items[group_idx] orelse output_alias;
                    }
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                    try result.types.append(self.allocator, group_types.items[group_idx]);
                    if (group_is_scalar.items[group_idx]) {
                        implicit_param_alias_slot += 1;
                    }
                    continue;
                }
                return error.InvalidReturn;
            }

            const counts = try self.allocator.alloc(i64, count_terms.items.len);
            defer self.allocator.free(counts);
            @memset(counts, 0);
            const seen_maps = try self.initSeenMaps(count_terms.items);
            defer self.deinitSeenMaps(seen_maps);
            try self.updateRelCountAccumulators(
                left_ref.table.rows.items[left_ref.row_idx],
                right_ref.table.rows.items[right_ref.row_idx],
                props,
                count_terms.items,
                count_targets.items,
                counts,
                seen_maps,
            );

            const out = try self.buildCountOutputRowFromTerms(
                projection_term_count,
                group_terms.items,
                group_cells[0..group_cells_initialized],
                count_terms.items,
                counts,
            );
            try result.rows.append(self.allocator, out);
        } else {
            if (projection_term_count != group_terms.items.len) return error.InvalidReturn;

            const CreateRelReturnSource = union(enum) {
                ref: ProjRef,
                scalar_expr: []const u8,
            };
            var projection_sources: std.ArrayList(CreateRelReturnSource) = .{};
            defer projection_sources.deinit(self.allocator);

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = 10;

            for (group_terms.items) |group_term| {
                if (try self.resolveRelProjectionRefOptional(
                    group_term.expr,
                    left_var,
                    right_var,
                    rel_var,
                    left_ref.table,
                    right_ref.table,
                    rel_table,
                )) |resolved_ref| {
                    const resolved_ty = switch (resolved_ref.source) {
                        .left => left_ref.table.columns.items[resolved_ref.col_idx].ty,
                        .right => right_ref.table.columns.items[resolved_ref.col_idx].ty,
                        .rel => rel_table.columns.items[resolved_ref.col_idx].ty,
                    };
                    try projection_sources.append(self.allocator, .{ .ref = resolved_ref });
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_term.alias));
                    try result.types.append(self.allocator, typeName(resolved_ty));
                    continue;
                }

                if (Engine.parsePropertyAccessExpr(group_term.expr)) |property_expr| {
                    if (left_ref.var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, left_ref.var_name)) {
                        try self.failCannotFindProperty(left_ref.var_name, property_expr.prop_name);
                        unreachable;
                    }
                    if (right_ref.var_name.len > 0 and std.mem.eql(u8, property_expr.var_name, right_ref.var_name)) {
                        try self.failCannotFindProperty(right_ref.var_name, property_expr.prop_name);
                        unreachable;
                    }
                    if (rel_var_raw.len > 0 and std.mem.eql(u8, property_expr.var_name, rel_var_raw)) {
                        try self.failCannotFindProperty(rel_var_raw, property_expr.prop_name);
                        unreachable;
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                    unreachable;
                }
                if (Engine.scopeVariableForUnknownExpr(group_term.expr)) |unknown_var| {
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                    unreachable;
                }

                var output_alias = group_term.alias;
                var output_alias_owned = false;
                defer if (output_alias_owned) self.allocator.free(output_alias);

                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                var probe_cell = scalar.cell;
                probe_cell.deinit(self.allocator);
                if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                    const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                    if (!param_lookup.present) {
                        output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                        output_alias_owned = true;
                    } else {
                        output_alias = scalar.default_alias;
                    }
                } else if (!group_term.alias_explicit) {
                    output_alias = scalar.default_alias;
                }
                try projection_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                try result.types.append(self.allocator, scalar.type_name);
                implicit_param_alias_slot += 1;
            }

            var out_row = try self.allocator.alloc(Cell, projection_sources.items.len);
            errdefer self.allocator.free(out_row);
            var initialized: usize = 0;
            errdefer {
                for (0..initialized) |i| {
                    out_row[i].deinit(self.allocator);
                }
            }

            for (projection_sources.items, 0..) |projection_source, out_idx| {
                out_row[out_idx] = switch (projection_source) {
                    .ref => |ref| try Engine.relCellFor(ref, left_ref.table.rows.items[left_ref.row_idx], right_ref.table.rows.items[right_ref.row_idx], props).clone(self.allocator),
                    .scalar_expr => |expr| blk: {
                        const scalar = try self.evaluateReturnScalarExpr(expr, params);
                        break :blk scalar.cell;
                    },
                };
                initialized += 1;
            }
            try result.rows.append(self.allocator, out_row);
        }

        if (return_distinct) {
            try self.dedupeResultRows(result);
        }
        if (order_expr) |order_text| {
            var out_keys: std.ArrayList(OutputOrderKey) = .{};
            defer out_keys.deinit(self.allocator);
            try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
            if (return_distinct) {
                sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
            } else {
                sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
            }
        }
        self.applyResultWindow(result, result_skip, result_limit);
    }

    fn executeCreateMultiPattern(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        const return_keyword = " RETURN ";
        var create_query = query;
        var return_part: ?[]const u8 = null;
        if (indexOfAsciiNoCase(query, return_keyword)) |return_idx| {
            create_query = std.mem.trim(u8, query[0..return_idx], " \t\n\r");
            return_part = std.mem.trim(u8, query[return_idx + return_keyword.len ..], " \t\n\r");
        }

        const create_part = std.mem.trim(u8, create_query["CREATE ".len..], " \t\n\r");
        var patterns = try self.splitTopLevelCreatePatterns(create_part);
        defer patterns.deinit(self.allocator);

        const NodeBinding = struct {
            name: []const u8,
            table: *Table,
            row_idx: usize,
        };
        const RelBinding = struct {
            name: []const u8,
            rel_table: *RelTable,
            props: []Cell,
        };

        var node_bindings: std.ArrayList(NodeBinding) = .{};
        defer node_bindings.deinit(self.allocator);
        var rel_bindings: std.ArrayList(RelBinding) = .{};
        defer rel_bindings.deinit(self.allocator);
        var pattern_is_rel: std.ArrayList(bool) = .{};
        defer pattern_is_rel.deinit(self.allocator);
        var create_node_scope_vars: std.ArrayList([]const u8) = .{};
        defer create_node_scope_vars.deinit(self.allocator);

        // First create standalone node patterns so later relationship patterns can
        // reference their variables even if the relationship appears earlier.
        for (patterns.items) |pattern| {
            const has_rel = std.mem.indexOf(u8, pattern, ")-[") != null and std.mem.indexOf(u8, pattern, "]->(") != null;
            if (has_rel) continue;
            create_node_scope_vars.clearRetainingCapacity();
            for (node_bindings.items) |binding| {
                try create_node_scope_vars.append(self.allocator, binding.name);
            }
            const created = try self.createNodeFromPattern(pattern, params, create_node_scope_vars.items);
            if (created.var_name.len == 0) continue;
            var replaced = false;
            for (node_bindings.items) |*binding| {
                if (std.mem.eql(u8, binding.name, created.var_name)) {
                    binding.* = .{ .name = created.var_name, .table = created.table, .row_idx = created.row_idx };
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                try node_bindings.append(self.allocator, .{
                    .name = created.var_name,
                    .table = created.table,
                    .row_idx = created.row_idx,
                });
            }
        }

        for (patterns.items) |pattern| {
            const has_rel = std.mem.indexOf(u8, pattern, ")-[") != null and std.mem.indexOf(u8, pattern, "]->(") != null;
            try pattern_is_rel.append(self.allocator, has_rel);
            if (!has_rel) {
                continue;
            }

            const left_end = std.mem.indexOf(u8, pattern, ")-[") orelse return error.InvalidCreateNode;
            const left_pattern = pattern[0 .. left_end + 1];
            const after_left = pattern[left_end + 3 ..];
            const rel_end = std.mem.indexOf(u8, after_left, "]->(") orelse return error.InvalidCreateNode;
            const rel_part = std.mem.trim(u8, after_left[0..rel_end], " \t\n\r");
            const right_pattern = after_left[rel_end + 3 ..];

            const CreateEndpoint = struct {
                table: *Table,
                row_idx: usize,
                var_name: []const u8,
            };
            const left_ref: CreateEndpoint = blk: {
                if (parseMatchNodeVarRef(left_pattern)) |left_ref_name| {
                    for (node_bindings.items) |binding| {
                        if (std.mem.eql(u8, binding.name, left_ref_name)) {
                            break :blk .{
                                .table = binding.table,
                                .row_idx = binding.row_idx,
                                .var_name = left_ref_name,
                            };
                        }
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{left_ref_name});
                    unreachable;
                } else |_| {}
                create_node_scope_vars.clearRetainingCapacity();
                for (node_bindings.items) |binding| {
                    try create_node_scope_vars.append(self.allocator, binding.name);
                }
                const created = try self.createNodeFromPattern(left_pattern, params, create_node_scope_vars.items);
                break :blk .{
                    .table = created.table,
                    .row_idx = created.row_idx,
                    .var_name = created.var_name,
                };
            };
            const right_ref: CreateEndpoint = blk: {
                if (parseMatchNodeVarRef(right_pattern)) |right_ref_name| {
                    if (left_ref.var_name.len > 0 and std.mem.eql(u8, left_ref.var_name, right_ref_name)) {
                        break :blk .{
                            .table = left_ref.table,
                            .row_idx = left_ref.row_idx,
                            .var_name = right_ref_name,
                        };
                    }
                    for (node_bindings.items) |binding| {
                        if (std.mem.eql(u8, binding.name, right_ref_name)) {
                            break :blk .{
                                .table = binding.table,
                                .row_idx = binding.row_idx,
                                .var_name = right_ref_name,
                            };
                        }
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{right_ref_name});
                    unreachable;
                } else |_| {}
                create_node_scope_vars.clearRetainingCapacity();
                for (node_bindings.items) |binding| {
                    try create_node_scope_vars.append(self.allocator, binding.name);
                }
                if (left_ref.var_name.len > 0) {
                    var already_scoped = false;
                    for (create_node_scope_vars.items) |scope_var| {
                        if (std.mem.eql(u8, scope_var, left_ref.var_name)) {
                            already_scoped = true;
                            break;
                        }
                    }
                    if (!already_scoped) {
                        try create_node_scope_vars.append(self.allocator, left_ref.var_name);
                    }
                }
                const created = try self.createNodeFromPattern(right_pattern, params, create_node_scope_vars.items);
                break :blk .{
                    .table = created.table,
                    .row_idx = created.row_idx,
                    .var_name = created.var_name,
                };
            };
            const left_var = if (left_ref.var_name.len > 0) left_ref.var_name else "__hippo_create_rel_left_out_of_scope__";
            const right_var = if (right_ref.var_name.len > 0) right_ref.var_name else "__hippo_create_rel_right_out_of_scope__";

            var rel_head = rel_part;
            var rel_props: []const u8 = "";
            if (std.mem.indexOfScalar(u8, rel_part, '{')) |open_brace| {
                const close_brace = std.mem.lastIndexOfScalar(u8, rel_part, '}') orelse return error.InvalidCreateNode;
                if (close_brace <= open_brace) return error.InvalidCreateNode;
                rel_head = std.mem.trim(u8, rel_part[0..open_brace], " \t\n\r");
                rel_props = rel_part[open_brace + 1 .. close_brace];
            }
            const rel_colon_idx = std.mem.indexOfScalar(u8, rel_head, ':') orelse return error.InvalidCreateNode;
            const rel_var_raw = std.mem.trim(u8, rel_head[0..rel_colon_idx], " \t\n\r");
            if (rel_var_raw.len > 0 and !Engine.isIdentifierToken(rel_var_raw)) return error.InvalidCreateNode;
            const rel_name = std.mem.trim(u8, rel_head[rel_colon_idx + 1 ..], " \t\n\r");
            if (rel_name.len == 0) return error.InvalidCreateNode;

            const rel_table = self.rel_tables.getPtr(rel_name) orelse return error.TableNotFound;
            if (!std.mem.eql(u8, left_ref.table.name, rel_table.from_table)) return error.RelEndpointTypeMismatch;
            if (!std.mem.eql(u8, right_ref.table.name, rel_table.to_table)) return error.RelEndpointTypeMismatch;

            var prop_assignments: std.ArrayList(RelSetAssignment) = .{};
            defer prop_assignments.deinit(self.allocator);
            var prop_assignment_texts: std.ArrayList([]u8) = .{};
            defer {
                for (prop_assignment_texts.items) |text| {
                    self.allocator.free(text);
                }
                prop_assignment_texts.deinit(self.allocator);
            }
            const rel_assign_var = if (rel_var_raw.len > 0) rel_var_raw else "__hippo_create_rel_assign__";
            var prop_iter = std.mem.splitScalar(u8, rel_props, ',');
            while (prop_iter.next()) |raw_prop| {
                const prop = std.mem.trim(u8, raw_prop, " \t\n\r");
                if (prop.len == 0) continue;

                const prop_colon_idx = std.mem.indexOfScalar(u8, prop, ':') orelse return error.InvalidCreateNode;
                const key = std.mem.trim(u8, prop[0..prop_colon_idx], " \t\n\r");
                const col_idx_for_key = rel_table.columnIndex(key) orelse return error.ColumnNotFound;
                const target_ty_for_key = rel_table.columns.items[col_idx_for_key].ty;
                var value_text = std.mem.trim(u8, prop[prop_colon_idx + 1 ..], " \t\n\r");
                if (Engine.isIdentifierToken(value_text) and
                    !std.ascii.eqlIgnoreCase(value_text, "true") and
                    !std.ascii.eqlIgnoreCase(value_text, "false") and
                    !std.ascii.eqlIgnoreCase(value_text, "null"))
                {
                    for (node_bindings.items) |binding| {
                        if (!std.mem.eql(u8, binding.name, value_text)) continue;
                        try self.failImplicitCastTypeMismatch(value_text, "NODE", typeName(target_ty_for_key));
                        unreachable;
                    }
                    for (rel_bindings.items) |binding| {
                        if (!std.mem.eql(u8, binding.name, value_text)) continue;
                        try self.failImplicitCastTypeMismatch(value_text, "REL", typeName(target_ty_for_key));
                        unreachable;
                    }
                }
                if (Engine.parsePropertyAccessExpr(value_text)) |rhs_prop| {
                    for (rel_bindings.items) |binding| {
                        if (std.mem.eql(u8, binding.name, rhs_prop.var_name) and !std.mem.eql(u8, rhs_prop.var_name, rel_assign_var)) {
                            value_text = switch (target_ty_for_key) {
                                .STRING => "''",
                                .BOOL => "false",
                                .DOUBLE => "0.0",
                                else => "0",
                            };
                            break;
                        }
                    }
                }
                const assignment_text = try std.fmt.allocPrint(self.allocator, "{s}.{s} = {s}", .{
                    rel_assign_var,
                    key,
                    value_text,
                });
                try prop_assignment_texts.append(self.allocator, assignment_text);
                try prop_assignments.append(
                    self.allocator,
                    try self.parseRelSetAssignment(
                        left_var,
                        right_var,
                        rel_table,
                        rel_assign_var,
                        left_ref.table,
                        right_ref.table,
                        assignment_text,
                        params,
                    ),
                );
            }

            var props = try self.allocator.alloc(Cell, rel_table.columns.items.len);
            errdefer self.allocator.free(props);
            for (props) |*cell| {
                cell.* = .null;
            }

            const left_row = left_ref.table.rows.items[left_ref.row_idx];
            const right_row = right_ref.table.rows.items[right_ref.row_idx];
            for (prop_assignments.items) |assignment| {
                const new_value = switch (assignment.rhs) {
                    .literal => |value| switch (value) {
                        .null => Cell.null,
                        .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        .int64 => |v| Cell{ .int64 = v },
                        .uint64 => |v| Cell{ .uint64 = v },
                        .bool => |b| Cell{ .int64 = if (b) 1 else 0 },
                        .float64 => |v| Cell{ .float64 = v },
                    },
                    .literal_int64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                    .literal_float64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                    .ref => |rhs_ref| try Engine.relCellFor(rhs_ref, left_row, right_row, props).clone(self.allocator),
                    .ref_int64_to_string => |rhs_ref| blk: {
                        const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                        const cast_cell: Cell = switch (source) {
                            .null => Cell.null,
                            .int64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                            .uint64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                            .float64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        };
                        break :blk cast_cell;
                    },
                    .ref_int64_to_double => |rhs_ref| blk: {
                        const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                        const cast_cell: Cell = switch (source) {
                            .null => Cell.null,
                            .int64 => |v| Cell{ .float64 = @as(f64, @floatFromInt(v)) },
                            .uint64 => |v| Cell{ .float64 = @floatFromInt(v) },
                            .float64 => |v| Cell{ .float64 = v },
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        };
                        break :blk cast_cell;
                    },
                    .ref_float64_to_int64 => |rhs_ref| blk: {
                        const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                        const cast_cell: Cell = switch (source) {
                            .null => Cell.null,
                            .int64 => |v| Cell{ .int64 = v },
                            .uint64 => |v| blk2: {
                                if (v > std.math.maxInt(i64)) {
                                    try self.failUserFmt("Overflow exception: Value {d} is not within INT64 range", .{v});
                                    unreachable;
                                }
                                break :blk2 Cell{ .int64 = @intCast(v) };
                            },
                            .float64 => |v| Cell{ .int64 = Engine.roundFloatToInt64LikeKuzu(v) },
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        };
                        break :blk cast_cell;
                    },
                };
                const target = &props[assignment.col_idx];
                target.deinit(self.allocator);
                target.* = new_value;
            }

            try rel_table.rows.append(self.allocator, .{
                .src_row = left_ref.row_idx,
                .dst_row = right_ref.row_idx,
                .props = props,
            });

            if (left_ref.var_name.len > 0) {
                var replaced = false;
                for (node_bindings.items) |*binding| {
                    if (std.mem.eql(u8, binding.name, left_ref.var_name)) {
                        binding.* = .{ .name = left_ref.var_name, .table = left_ref.table, .row_idx = left_ref.row_idx };
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) {
                    try node_bindings.append(self.allocator, .{
                        .name = left_ref.var_name,
                        .table = left_ref.table,
                        .row_idx = left_ref.row_idx,
                    });
                }
            }
            if (right_ref.var_name.len > 0) {
                var replaced = false;
                for (node_bindings.items) |*binding| {
                    if (std.mem.eql(u8, binding.name, right_ref.var_name)) {
                        binding.* = .{ .name = right_ref.var_name, .table = right_ref.table, .row_idx = right_ref.row_idx };
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) {
                    try node_bindings.append(self.allocator, .{
                        .name = right_ref.var_name,
                        .table = right_ref.table,
                        .row_idx = right_ref.row_idx,
                    });
                }
            }
            if (rel_var_raw.len > 0) {
                var replaced = false;
                for (rel_bindings.items) |*binding| {
                    if (std.mem.eql(u8, binding.name, rel_var_raw)) {
                        binding.* = .{ .name = rel_var_raw, .rel_table = rel_table, .props = props };
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) {
                    try rel_bindings.append(self.allocator, .{
                        .name = rel_var_raw,
                        .rel_table = rel_table,
                        .props = props,
                    });
                }
            }
        }

        if (return_part == null) return;
        const return_text = return_part.?;
        try self.enforceSkipBeforeLimitParserParity(query, return_text);
        const pagination = try self.parsePaginationClause(query, return_text);
        const distinct_clause = try parseDistinctClause(pagination.body);
        const return_body = distinct_clause.body;
        const return_distinct = distinct_clause.distinct;
        const result_skip = pagination.skip;
        const result_limit = pagination.limit;

        const order_keyword = " ORDER BY ";
        var projection_part = return_body;
        var order_expr: ?[]const u8 = null;
        if (indexOfAsciiNoCase(return_body, order_keyword)) |order_idx| {
            projection_part = std.mem.trim(u8, return_body[0..order_idx], " \t\n\r");
            order_expr = std.mem.trim(u8, return_body[order_idx + order_keyword.len ..], " \t\n\r");
        }
        try self.validateProjectionTermsExplicitAs(query, projection_part);

        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        const has_count_projection = (self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
            error.InvalidCountDistinctStar => {
                try self.raiseCountDistinctStarProjectionError(query);
                unreachable;
            },
            else => return err,
        });

        var implicit_param_alias_slot: usize = blk: {
            var has_rel_pattern = false;
            for (pattern_is_rel.items) |is_rel| {
                if (is_rel) {
                    has_rel_pattern = true;
                    break;
                }
            }
            if (!has_rel_pattern) break :blk 2 + pattern_is_rel.items.len * 2;
            var slot: usize = 0;
            for (pattern_is_rel.items) |is_rel| {
                slot += if (is_rel) 10 else 3;
            }
            break :blk slot;
        };

        var group_cells = try self.allocator.alloc(Cell, group_terms.items.len);
        defer self.allocator.free(group_cells);
        var group_cells_initialized: usize = 0;
        defer {
            for (group_cells[0..group_cells_initialized]) |*cell| {
                cell.deinit(self.allocator);
            }
        }

        var group_types: std.ArrayList([]const u8) = .{};
        defer group_types.deinit(self.allocator);
        var group_is_scalar: std.ArrayList(bool) = .{};
        defer group_is_scalar.deinit(self.allocator);
        var group_scalar_default_aliases: std.ArrayList(?[]const u8) = .{};
        defer group_scalar_default_aliases.deinit(self.allocator);

        for (group_terms.items, 0..) |group_term, idx| {
            if (Engine.parsePropertyAccessExpr(group_term.expr)) |property_expr| {
                var node_match: ?NodeBinding = null;
                for (node_bindings.items) |binding| {
                    if (std.mem.eql(u8, binding.name, property_expr.var_name)) {
                        node_match = binding;
                        break;
                    }
                }
                if (node_match) |binding| {
                    const col_idx = try self.nodeColumnIndexOrBinderError(binding.table, property_expr.var_name, property_expr.prop_name);
                    const col_ty = try self.nodeColumnTypeOrBinderError(binding.table, property_expr.var_name, property_expr.prop_name);
                    group_cells[idx] = try binding.table.rows.items[binding.row_idx][col_idx].clone(self.allocator);
                    group_cells_initialized += 1;
                    try group_types.append(self.allocator, typeName(col_ty));
                    try group_is_scalar.append(self.allocator, false);
                    try group_scalar_default_aliases.append(self.allocator, null);
                    continue;
                }

                var rel_match: ?RelBinding = null;
                for (rel_bindings.items) |binding| {
                    if (std.mem.eql(u8, binding.name, property_expr.var_name)) {
                        rel_match = binding;
                        break;
                    }
                }
                if (rel_match) |binding| {
                    const col_idx = try self.relColumnIndexOrBinderError(binding.rel_table, property_expr.var_name, property_expr.prop_name);
                    const col_ty = try self.relColumnTypeOrBinderError(binding.rel_table, property_expr.var_name, property_expr.prop_name);
                    group_cells[idx] = try binding.props[col_idx].clone(self.allocator);
                    group_cells_initialized += 1;
                    try group_types.append(self.allocator, typeName(col_ty));
                    try group_is_scalar.append(self.allocator, false);
                    try group_scalar_default_aliases.append(self.allocator, null);
                    continue;
                }

                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                unreachable;
            }

            if (Engine.scopeVariableForUnknownExpr(group_term.expr)) |unknown_var| {
                for (node_bindings.items) |binding| {
                    if (std.mem.eql(u8, binding.name, unknown_var)) {
                        try self.failPropertyAccessTypeMismatch(unknown_var, "NODE");
                        unreachable;
                    }
                }
                for (rel_bindings.items) |binding| {
                    if (std.mem.eql(u8, binding.name, unknown_var)) {
                        try self.failPropertyAccessTypeMismatch(unknown_var, "REL");
                        unreachable;
                    }
                }
                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                unreachable;
            }

            const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
            group_cells[idx] = scalar.cell;
            group_cells_initialized += 1;
            try group_types.append(self.allocator, scalar.type_name);
            try group_is_scalar.append(self.allocator, true);
            try group_scalar_default_aliases.append(self.allocator, scalar.default_alias);
        }

        const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
        for (0..projection_term_count) |position| {
            if (Engine.findCountTermIndexByPosition(count_terms.items, position)) |count_idx| {
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[count_idx].alias));
                try result.types.append(self.allocator, "INT64");
                implicit_param_alias_slot += 1;
                continue;
            }
            if (Engine.findGroupTermIndexByPosition(group_terms.items, position)) |group_idx| {
                const group_term = group_terms.items[group_idx];
                var output_alias = group_term.alias;
                var output_alias_owned = false;
                defer if (output_alias_owned) self.allocator.free(output_alias);
                if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                    const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                    if (!param_lookup.present) {
                        output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                        output_alias_owned = true;
                    } else if (group_is_scalar.items[group_idx]) {
                        output_alias = group_scalar_default_aliases.items[group_idx] orelse output_alias;
                    }
                } else if (!group_term.alias_explicit and group_is_scalar.items[group_idx]) {
                    output_alias = group_scalar_default_aliases.items[group_idx] orelse output_alias;
                }
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                try result.types.append(self.allocator, group_types.items[group_idx]);
                if (group_is_scalar.items[group_idx]) {
                    implicit_param_alias_slot += 1;
                }
                continue;
            }
            return error.InvalidReturn;
        }

        if (has_count_projection) {
            const counts = try self.allocator.alloc(i64, count_terms.items.len);
            defer self.allocator.free(counts);
            @memset(counts, 0);

            for (count_terms.items, 0..) |count_term, idx| {
                if (std.mem.eql(u8, count_term.count_expr, "*")) {
                    counts[idx] = 1;
                    continue;
                }

                var include = false;
                if (Engine.parsePropertyAccessExpr(count_term.count_expr)) |property_expr| {
                    var handled = false;
                    for (node_bindings.items) |binding| {
                        if (std.mem.eql(u8, binding.name, property_expr.var_name)) {
                            const col_idx = try self.nodeColumnIndexOrBinderError(binding.table, property_expr.var_name, property_expr.prop_name);
                            include = !cellIsNull(binding.table.rows.items[binding.row_idx][col_idx]);
                            handled = true;
                            break;
                        }
                    }
                    if (!handled) {
                        for (rel_bindings.items) |binding| {
                            if (std.mem.eql(u8, binding.name, property_expr.var_name)) {
                                const col_idx = try self.relColumnIndexOrBinderError(binding.rel_table, property_expr.var_name, property_expr.prop_name);
                                include = !cellIsNull(binding.props[col_idx]);
                                handled = true;
                                break;
                            }
                        }
                    }
                    if (!handled) {
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                        unreachable;
                    }
                } else if (Engine.scopeVariableForUnknownExpr(count_term.count_expr)) |unknown_var| {
                    for (node_bindings.items) |binding| {
                        if (std.mem.eql(u8, binding.name, unknown_var)) {
                            try self.failPropertyAccessTypeMismatch(unknown_var, "NODE");
                            unreachable;
                        }
                    }
                    for (rel_bindings.items) |binding| {
                        if (std.mem.eql(u8, binding.name, unknown_var)) {
                            try self.failPropertyAccessTypeMismatch(unknown_var, "REL");
                            unreachable;
                        }
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                    unreachable;
                } else {
                    const scalar = try self.evaluateReturnScalarExpr(count_term.count_expr, params);
                    var cell = scalar.cell;
                    defer cell.deinit(self.allocator);
                    if (cellIsNull(cell)) {
                        try self.failCountAnyBinderError(count_term.distinct);
                        unreachable;
                    }
                    include = true;
                }

                counts[idx] = if (include) 1 else 0;
            }

            const out = try self.buildCountOutputRowFromTerms(
                projection_term_count,
                group_terms.items,
                group_cells[0..group_cells_initialized],
                count_terms.items,
                counts,
            );
            try result.rows.append(self.allocator, out);
        } else {
            const out = try self.allocator.alloc(Cell, group_cells_initialized);
            for (group_cells[0..group_cells_initialized], 0..) |cell, i| {
                out[i] = try cell.clone(self.allocator);
            }
            try result.rows.append(self.allocator, out);
        }

        if (return_distinct) {
            try self.dedupeResultRows(result);
        }
        if (order_expr) |order_text| {
            var out_keys: std.ArrayList(OutputOrderKey) = .{};
            defer out_keys.deinit(self.allocator);
            try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
            if (return_distinct) {
                sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
            } else {
                sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
            }
        }
        self.applyResultWindow(result, result_skip, result_limit);
    }

    fn executeMatchCreateFlexible(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        if (startsWithAsciiNoCase(query, "MATCH ")) {
            var match_create_query = query;
            if (indexOfAsciiNoCase(query, " RETURN ")) |return_idx| {
                match_create_query = std.mem.trim(u8, query[0..return_idx], " \t\n\r");
            }
            if (indexOfAsciiNoCase(match_create_query, " CREATE ")) |create_idx| {
                const match_part = std.mem.trim(u8, match_create_query["MATCH ".len..create_idx], " \t\n\r");
                var match_patterns_part = match_part;
                if (indexOfAsciiNoCase(match_part, " WHERE ")) |where_idx| {
                    match_patterns_part = std.mem.trim(u8, match_part[0..where_idx], " \t\n\r");
                }
                var match_patterns = try self.splitTopLevelCreatePatterns(match_patterns_part);
                defer match_patterns.deinit(self.allocator);
                if (match_patterns.items.len != 2) {
                    return self.executeMatchCreateMultiPattern(query, params, result);
                }
            }
        }

        self.executeMatchCreateRelationship(query, params, result) catch |err| switch (err) {
            error.InvalidMatch => try self.executeMatchCreateMultiPattern(query, params, result),
            else => return err,
        };
    }

    fn executeMatchCreateMultiPattern(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        if (!startsWithAsciiNoCase(query, "MATCH ")) return error.InvalidMatch;

        var match_create_query = query;
        var return_clause_raw: ?[]const u8 = null;
        if (indexOfAsciiNoCase(query, " RETURN ")) |return_idx| {
            match_create_query = std.mem.trim(u8, query[0..return_idx], " \t\n\r");
            return_clause_raw = std.mem.trim(u8, query[return_idx + " RETURN ".len ..], " \t\n\r");
        }

        const create_idx = indexOfAsciiNoCase(match_create_query, " CREATE ") orelse return error.InvalidMatch;
        const match_part = std.mem.trim(u8, match_create_query["MATCH ".len..create_idx], " \t\n\r");
        const create_part = std.mem.trim(u8, match_create_query[create_idx + " CREATE ".len ..], " \t\n\r");

        var where_text: ?[]const u8 = null;
        var match_patterns_part = match_part;
        if (indexOfAsciiNoCase(match_part, " WHERE ")) |where_idx| {
            match_patterns_part = std.mem.trim(u8, match_part[0..where_idx], " \t\n\r");
            where_text = std.mem.trim(u8, match_part[where_idx + " WHERE ".len ..], " \t\n\r");
        }

        var match_patterns = try self.splitTopLevelCreatePatterns(match_patterns_part);
        defer match_patterns.deinit(self.allocator);
        if (match_patterns.items.len == 0) return error.InvalidMatch;

        const MatchPattern = struct {
            var_name: []const u8,
            table: *Table,
        };
        var match_nodes: std.ArrayList(MatchPattern) = .{};
        defer match_nodes.deinit(self.allocator);
        for (match_patterns.items) |match_pattern| {
            const parsed = try parseMatchNodePattern(match_pattern);
            try match_nodes.append(self.allocator, .{
                .var_name = parsed.var_name,
                .table = self.node_tables.getPtr(parsed.table_name) orelse return error.TableNotFound,
            });
        }

        var create_patterns = try self.splitTopLevelCreatePatterns(create_part);
        defer create_patterns.deinit(self.allocator);

        var create_pattern_is_rel: std.ArrayList(bool) = .{};
        defer create_pattern_is_rel.deinit(self.allocator);
        for (create_patterns.items) |pattern| {
            const has_rel = std.mem.indexOf(u8, pattern, ")-[") != null and std.mem.indexOf(u8, pattern, "]->(") != null;
            try create_pattern_is_rel.append(self.allocator, has_rel);
        }

        const NodeSymbol = struct {
            name: []const u8,
            table: *Table,
        };
        const RelSymbol = struct {
            name: []const u8,
            table: *RelTable,
        };
        var node_symbols: std.ArrayList(NodeSymbol) = .{};
        defer node_symbols.deinit(self.allocator);
        var rel_symbols: std.ArrayList(RelSymbol) = .{};
        defer rel_symbols.deinit(self.allocator);

        for (match_nodes.items) |match_node| {
            var replaced = false;
            for (node_symbols.items) |*symbol| {
                if (std.mem.eql(u8, symbol.name, match_node.var_name)) {
                    symbol.* = .{ .name = match_node.var_name, .table = match_node.table };
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                try node_symbols.append(self.allocator, .{ .name = match_node.var_name, .table = match_node.table });
            }
        }

        for (create_patterns.items, create_pattern_is_rel.items) |pattern, is_rel| {
            if (!is_rel) {
                if (parseMatchNodePattern(pattern)) |node_pat| {
                    const table = self.node_tables.getPtr(node_pat.table_name) orelse return error.TableNotFound;
                    var replaced = false;
                    for (node_symbols.items) |*symbol| {
                        if (std.mem.eql(u8, symbol.name, node_pat.var_name)) {
                            symbol.* = .{ .name = node_pat.var_name, .table = table };
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced and node_pat.var_name.len > 0) {
                        try node_symbols.append(self.allocator, .{ .name = node_pat.var_name, .table = table });
                    }
                    continue;
                } else |_| {
                    if (parseMatchNodeVarRef(pattern)) |_| {} else |_| return error.InvalidCreateNode;
                    continue;
                }
            }

            const left_end = std.mem.indexOf(u8, pattern, ")-[") orelse return error.InvalidCreateNode;
            const left_pattern = pattern[0 .. left_end + 1];
            const after_left = pattern[left_end + 3 ..];
            const rel_end = std.mem.indexOf(u8, after_left, "]->(") orelse return error.InvalidCreateNode;
            const rel_part = std.mem.trim(u8, after_left[0..rel_end], " \t\n\r");
            const right_pattern = after_left[rel_end + 3 ..];

            if (parseMatchNodePattern(left_pattern)) |left_pat| {
                const table = self.node_tables.getPtr(left_pat.table_name) orelse return error.TableNotFound;
                var replaced = false;
                for (node_symbols.items) |*symbol| {
                    if (std.mem.eql(u8, symbol.name, left_pat.var_name)) {
                        symbol.* = .{ .name = left_pat.var_name, .table = table };
                        replaced = true;
                        break;
                    }
                }
                if (!replaced and left_pat.var_name.len > 0) {
                    try node_symbols.append(self.allocator, .{ .name = left_pat.var_name, .table = table });
                }
            } else |_| {
                _ = parseMatchNodeVarRef(left_pattern) catch return error.InvalidCreateNode;
            }

            if (parseMatchNodePattern(right_pattern)) |right_pat| {
                const table = self.node_tables.getPtr(right_pat.table_name) orelse return error.TableNotFound;
                var replaced = false;
                for (node_symbols.items) |*symbol| {
                    if (std.mem.eql(u8, symbol.name, right_pat.var_name)) {
                        symbol.* = .{ .name = right_pat.var_name, .table = table };
                        replaced = true;
                        break;
                    }
                }
                if (!replaced and right_pat.var_name.len > 0) {
                    try node_symbols.append(self.allocator, .{ .name = right_pat.var_name, .table = table });
                }
            } else |_| {
                _ = parseMatchNodeVarRef(right_pattern) catch return error.InvalidCreateNode;
            }

            var rel_head = rel_part;
            if (std.mem.indexOfScalar(u8, rel_part, '{')) |open_brace| {
                rel_head = std.mem.trim(u8, rel_part[0..open_brace], " \t\n\r");
            }
            const rel_colon_idx = std.mem.indexOfScalar(u8, rel_head, ':') orelse return error.InvalidCreateNode;
            const rel_var_raw = std.mem.trim(u8, rel_head[0..rel_colon_idx], " \t\n\r");
            const rel_name = std.mem.trim(u8, rel_head[rel_colon_idx + 1 ..], " \t\n\r");
            const rel_table_ptr = self.rel_tables.getPtr(rel_name) orelse return error.TableNotFound;
            if (rel_var_raw.len > 0) {
                var replaced = false;
                for (rel_symbols.items) |*symbol| {
                    if (std.mem.eql(u8, symbol.name, rel_var_raw)) {
                        symbol.* = .{ .name = rel_var_raw, .table = rel_table_ptr };
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) {
                    try rel_symbols.append(self.allocator, .{ .name = rel_var_raw, .table = rel_table_ptr });
                }
            }
        }

        var return_projection: ?[]const u8 = null;
        var return_distinct = false;
        var result_skip: usize = 0;
        var result_limit: ?usize = null;
        var order_expr: ?[]const u8 = null;
        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        var has_count_projection = false;
        const CountSource = union(enum) {
            star,
            node_prop: struct { var_name: []const u8, col_idx: usize },
            rel_prop: struct { var_name: []const u8, col_idx: usize },
            scalar_expr: []const u8,
        };
        var count_sources: std.ArrayList(CountSource) = .{};
        defer count_sources.deinit(self.allocator);
        const ReturnSource = union(enum) {
            node_prop: struct { var_name: []const u8, col_idx: usize },
            rel_prop: struct { var_name: []const u8, col_idx: usize },
            scalar_expr: []const u8,
        };
        var return_sources: std.ArrayList(ReturnSource) = .{};
        defer return_sources.deinit(self.allocator);
        var group_types: std.ArrayList([]const u8) = .{};
        defer group_types.deinit(self.allocator);
        var group_is_scalar: std.ArrayList(bool) = .{};
        defer group_is_scalar.deinit(self.allocator);
        var group_scalar_default_aliases: std.ArrayList(?[]const u8) = .{};
        defer group_scalar_default_aliases.deinit(self.allocator);

        if (return_clause_raw) |return_clause| {
            try self.enforceSkipBeforeLimitParserParity(query, return_clause);
            const pagination = try self.parsePaginationClause(query, return_clause);
            const distinct_clause = try parseDistinctClause(pagination.body);
            return_distinct = distinct_clause.distinct;
            result_skip = pagination.skip;
            result_limit = pagination.limit;

            const order_keyword = " ORDER BY ";
            var projection_part = distinct_clause.body;
            if (indexOfAsciiNoCase(distinct_clause.body, order_keyword)) |order_idx| {
                projection_part = std.mem.trim(u8, distinct_clause.body[0..order_idx], " \t\n\r");
                order_expr = std.mem.trim(u8, distinct_clause.body[order_idx + order_keyword.len ..], " \t\n\r");
            }
            return_projection = projection_part;

            try self.validateProjectionTermsExplicitAs(query, projection_part);
            has_count_projection = (self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
                error.InvalidCountDistinctStar => {
                    try self.raiseCountDistinctStarProjectionError(query);
                    unreachable;
                },
                else => return err,
            });
            if (!has_count_projection and projection_term_count != group_terms.items.len) return error.InvalidReturn;

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = blk: {
                var has_rel_pattern = false;
                for (create_pattern_is_rel.items) |is_rel| {
                    if (is_rel) {
                        has_rel_pattern = true;
                        break;
                    }
                }
                if (!has_rel_pattern) break :blk 2 + create_pattern_is_rel.items.len * 2;
                var slot: usize = 0;
                for (create_pattern_is_rel.items) |is_rel| {
                    slot += if (is_rel) 10 else 3;
                }
                break :blk slot;
            };
            if (where_text) |where_clause| {
                implicit_param_alias_slot += Engine.countImplicitAliasLiterals(where_clause);
            }

            if (has_count_projection) {
                for (count_terms.items) |count_term| {
                    if (std.mem.eql(u8, count_term.count_expr, "*")) {
                        try count_sources.append(self.allocator, .star);
                        continue;
                    }
                    if (Engine.parsePropertyAccessExpr(count_term.count_expr)) |property_expr| {
                        var resolved = false;
                        for (node_symbols.items) |symbol| {
                            if (!std.mem.eql(u8, symbol.name, property_expr.var_name)) continue;
                            const col_idx = try self.nodeColumnIndexOrBinderError(symbol.table, property_expr.var_name, property_expr.prop_name);
                            try count_sources.append(self.allocator, .{ .node_prop = .{ .var_name = property_expr.var_name, .col_idx = col_idx } });
                            resolved = true;
                            break;
                        }
                        if (resolved) continue;
                        for (rel_symbols.items) |symbol| {
                            if (!std.mem.eql(u8, symbol.name, property_expr.var_name)) continue;
                            const col_idx = try self.relColumnIndexOrBinderError(symbol.table, property_expr.var_name, property_expr.prop_name);
                            try count_sources.append(self.allocator, .{ .rel_prop = .{ .var_name = property_expr.var_name, .col_idx = col_idx } });
                            resolved = true;
                            break;
                        }
                        if (resolved) continue;
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                        unreachable;
                    }

                    if (Engine.isIdentifierToken(count_term.count_expr) and
                        !std.ascii.eqlIgnoreCase(count_term.count_expr, "true") and
                        !std.ascii.eqlIgnoreCase(count_term.count_expr, "false") and
                        !std.ascii.eqlIgnoreCase(count_term.count_expr, "null"))
                    {
                        var resolved_identifier = false;
                        for (node_symbols.items) |symbol| {
                            if (!std.mem.eql(u8, symbol.name, count_term.count_expr)) continue;
                            const pk_name = symbol.table.primary_key orelse return error.InvalidReturn;
                            const col_idx = try self.nodeColumnIndexOrBinderError(symbol.table, symbol.name, pk_name);
                            try count_sources.append(self.allocator, .{ .node_prop = .{ .var_name = symbol.name, .col_idx = col_idx } });
                            resolved_identifier = true;
                            break;
                        }
                        if (resolved_identifier) continue;
                    }

                    if (Engine.scopeVariableForUnknownExpr(count_term.count_expr)) |unknown_var| {
                        for (node_symbols.items) |symbol| {
                            if (std.mem.eql(u8, symbol.name, unknown_var)) {
                                try self.failPropertyAccessTypeMismatch(unknown_var, "NODE");
                                unreachable;
                            }
                        }
                        for (rel_symbols.items) |symbol| {
                            if (std.mem.eql(u8, symbol.name, unknown_var)) {
                                try self.failPropertyAccessTypeMismatch(unknown_var, "REL");
                                unreachable;
                            }
                        }
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                        unreachable;
                    }

                    try count_sources.append(self.allocator, .{ .scalar_expr = count_term.count_expr });
                }
            }

            for (group_terms.items) |group_term| {
                if (Engine.parsePropertyAccessExpr(group_term.expr)) |property_expr| {
                    var resolved = false;
                    for (node_symbols.items) |symbol| {
                        if (!std.mem.eql(u8, symbol.name, property_expr.var_name)) continue;
                        const col_idx = try self.nodeColumnIndexOrBinderError(symbol.table, property_expr.var_name, property_expr.prop_name);
                        const ty = try self.nodeColumnTypeOrBinderError(symbol.table, property_expr.var_name, property_expr.prop_name);
                        try return_sources.append(self.allocator, .{ .node_prop = .{ .var_name = property_expr.var_name, .col_idx = col_idx } });
                        try group_types.append(self.allocator, typeName(ty));
                        try group_is_scalar.append(self.allocator, false);
                        try group_scalar_default_aliases.append(self.allocator, null);
                        resolved = true;
                        break;
                    }
                    if (resolved) continue;
                    for (rel_symbols.items) |symbol| {
                        if (!std.mem.eql(u8, symbol.name, property_expr.var_name)) continue;
                        const col_idx = try self.relColumnIndexOrBinderError(symbol.table, property_expr.var_name, property_expr.prop_name);
                        const ty = try self.relColumnTypeOrBinderError(symbol.table, property_expr.var_name, property_expr.prop_name);
                        try return_sources.append(self.allocator, .{ .rel_prop = .{ .var_name = property_expr.var_name, .col_idx = col_idx } });
                        try group_types.append(self.allocator, typeName(ty));
                        try group_is_scalar.append(self.allocator, false);
                        try group_scalar_default_aliases.append(self.allocator, null);
                        resolved = true;
                        break;
                    }
                    if (resolved) continue;
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                    unreachable;
                }

                if (Engine.scopeVariableForUnknownExpr(group_term.expr)) |unknown_var| {
                    for (node_symbols.items) |symbol| {
                        if (std.mem.eql(u8, symbol.name, unknown_var)) {
                            try self.failPropertyAccessTypeMismatch(unknown_var, "NODE");
                            unreachable;
                        }
                    }
                    for (rel_symbols.items) |symbol| {
                        if (std.mem.eql(u8, symbol.name, unknown_var)) {
                            try self.failPropertyAccessTypeMismatch(unknown_var, "REL");
                            unreachable;
                        }
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                    unreachable;
                }

                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                var probe = scalar.cell;
                probe.deinit(self.allocator);
                try return_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
                try group_types.append(self.allocator, scalar.type_name);
                try group_is_scalar.append(self.allocator, true);
                try group_scalar_default_aliases.append(self.allocator, scalar.default_alias);
            }

            for (0..projection_term_count) |position| {
                if (has_count_projection) {
                    if (Engine.findCountTermIndexByPosition(count_terms.items, position)) |count_idx| {
                        try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[count_idx].alias));
                        try result.types.append(self.allocator, "INT64");
                        implicit_param_alias_slot += 1;
                        continue;
                    }
                }
                if (Engine.findGroupTermIndexByPosition(group_terms.items, position)) |group_idx| {
                    const group_term = group_terms.items[group_idx];
                    var output_alias = group_term.alias;
                    var output_alias_owned = false;
                    defer if (output_alias_owned) self.allocator.free(output_alias);
                    if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                        const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                        if (!param_lookup.present) {
                            output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                            output_alias_owned = true;
                        } else if (group_is_scalar.items[group_idx]) {
                            output_alias = group_scalar_default_aliases.items[group_idx] orelse output_alias;
                        }
                    } else if (!group_term.alias_explicit and group_is_scalar.items[group_idx]) {
                        output_alias = group_scalar_default_aliases.items[group_idx] orelse output_alias;
                    }
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                    try result.types.append(self.allocator, group_types.items[group_idx]);
                    if (group_is_scalar.items[group_idx]) {
                        implicit_param_alias_slot += 1;
                    }
                    continue;
                }
                return error.InvalidReturn;
            }
        }

        const MatchState = struct {
            row_indices: []usize,
        };
        var match_states: std.ArrayList(MatchState) = .{};
        defer {
            for (match_states.items) |state| {
                self.allocator.free(state.row_indices);
            }
            match_states.deinit(self.allocator);
        }

        var has_match_rows = true;
        for (match_nodes.items) |match_node| {
            if (match_node.table.rows.items.len == 0) {
                has_match_rows = false;
                break;
            }
        }
        if (has_match_rows) {
            var cur_indices = try self.allocator.alloc(usize, match_nodes.items.len);
            defer self.allocator.free(cur_indices);
            @memset(cur_indices, 0);

            while (true) {
                var include = true;
                if (where_text) |wt| {
                    var where_bindings = try self.allocator.alloc(MatchCreateMultiWhereBinding, match_nodes.items.len);
                    defer self.allocator.free(where_bindings);
                    for (match_nodes.items, 0..) |match_node, idx| {
                        where_bindings[idx] = .{
                            .var_name = match_node.var_name,
                            .table = match_node.table,
                            .row = match_node.table.rows.items[cur_indices[idx]],
                        };
                    }
                    include = try self.evaluateMatchCreateMultiWhereExpression(wt, params, where_bindings);
                }

                if (include) {
                    const copied_indices = try self.allocator.alloc(usize, cur_indices.len);
                    std.mem.copyForwards(usize, copied_indices, cur_indices);
                    try match_states.append(self.allocator, .{ .row_indices = copied_indices });
                }

                var advanced = false;
                var odometer_idx: usize = 0;
                while (odometer_idx < cur_indices.len) : (odometer_idx += 1) {
                    const next_idx = cur_indices[odometer_idx] + 1;
                    if (next_idx < match_nodes.items[odometer_idx].table.rows.items.len) {
                        cur_indices[odometer_idx] = next_idx;
                        var reset_idx: usize = 0;
                        while (reset_idx < odometer_idx) : (reset_idx += 1) {
                            cur_indices[reset_idx] = 0;
                        }
                        advanced = true;
                        break;
                    }
                }
                if (!advanced) break;
            }
        }

        const NodeBinding = struct {
            name: []const u8,
            table: *Table,
            row_idx: usize,
        };
        const RelBinding = struct {
            name: []const u8,
            rel_table: *RelTable,
            props: []Cell,
        };

        const CountGroupState = struct {
            cells: []Cell,
            counts: []i64,
            seen: []std.StringHashMap(void),
        };

        var global_counts_opt: ?[]i64 = null;
        defer if (global_counts_opt) |counts| self.allocator.free(counts);
        var global_seen_opt: ?[]std.StringHashMap(void) = null;
        defer if (global_seen_opt) |seen_maps| self.deinitSeenMaps(seen_maps);

        var count_groups = std.StringHashMap(CountGroupState).init(self.allocator);
        defer {
            if (return_projection != null and has_count_projection and group_terms.items.len > 0) {
                var it = count_groups.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    for (entry.value_ptr.cells) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(entry.value_ptr.cells);
                    self.allocator.free(entry.value_ptr.counts);
                    self.deinitSeenMaps(entry.value_ptr.seen);
                }
            }
            count_groups.deinit();
        }

        if (return_projection != null and has_count_projection and group_terms.items.len == 0) {
            const counts = try self.allocator.alloc(i64, count_terms.items.len);
            @memset(counts, 0);
            global_counts_opt = counts;
            global_seen_opt = try self.initSeenMaps(count_terms.items);
        }

        var rewritten_create_patterns: std.ArrayList([]u8) = .{};
        defer {
            for (rewritten_create_patterns.items) |owned| self.allocator.free(owned);
            rewritten_create_patterns.deinit(self.allocator);
        }

        for (match_states.items) |state| {
            var node_bindings: std.ArrayList(NodeBinding) = .{};
            defer node_bindings.deinit(self.allocator);
            var rel_bindings: std.ArrayList(RelBinding) = .{};
            defer rel_bindings.deinit(self.allocator);
            var create_node_scope_vars: std.ArrayList([]const u8) = .{};
            defer create_node_scope_vars.deinit(self.allocator);

            for (match_nodes.items, 0..) |match_node, match_idx| {
                var replaced = false;
                for (node_bindings.items) |*binding| {
                    if (std.mem.eql(u8, binding.name, match_node.var_name)) {
                        binding.* = .{
                            .name = match_node.var_name,
                            .table = match_node.table,
                            .row_idx = state.row_indices[match_idx],
                        };
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) {
                    try node_bindings.append(self.allocator, .{
                        .name = match_node.var_name,
                        .table = match_node.table,
                        .row_idx = state.row_indices[match_idx],
                    });
                }
            }

            for (create_patterns.items, create_pattern_is_rel.items) |pattern, is_rel| {
                if (is_rel) continue;
                if (parseMatchNodePattern(pattern)) |_| {
                    create_node_scope_vars.clearRetainingCapacity();
                    for (node_bindings.items) |binding| {
                        try create_node_scope_vars.append(self.allocator, binding.name);
                    }
                    const rewritten_pattern = try self.rewriteCreateNodePatternForBoundProps(pattern, node_bindings.items);
                    if (rewritten_pattern) |owned| try rewritten_create_patterns.append(self.allocator, owned);
                    const pattern_for_create = rewritten_pattern orelse pattern;
                    const created = try self.createNodeFromPattern(pattern_for_create, params, create_node_scope_vars.items);
                    if (created.var_name.len > 0) {
                        var replaced = false;
                        for (node_bindings.items) |*binding| {
                            if (std.mem.eql(u8, binding.name, created.var_name)) {
                                binding.* = .{ .name = created.var_name, .table = created.table, .row_idx = created.row_idx };
                                replaced = true;
                                break;
                            }
                        }
                        if (!replaced) {
                            try node_bindings.append(self.allocator, .{
                                .name = created.var_name,
                                .table = created.table,
                                .row_idx = created.row_idx,
                            });
                        }
                    }
                    continue;
                } else |_| {
                    if (parseMatchNodeVarRef(pattern)) |var_ref| {
                        var found = false;
                        for (node_bindings.items) |binding| {
                            if (std.mem.eql(u8, binding.name, var_ref)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{var_ref});
                            unreachable;
                        }
                        continue;
                    } else |_| {}
                    return error.InvalidCreateNode;
                }
            }

            for (create_patterns.items, create_pattern_is_rel.items) |pattern, is_rel| {
                if (!is_rel) continue;

                const left_end = std.mem.indexOf(u8, pattern, ")-[") orelse return error.InvalidCreateNode;
                const left_pattern = pattern[0 .. left_end + 1];
                const after_left = pattern[left_end + 3 ..];
                const rel_end = std.mem.indexOf(u8, after_left, "]->(") orelse return error.InvalidCreateNode;
                const rel_part = std.mem.trim(u8, after_left[0..rel_end], " \t\n\r");
                const right_pattern = after_left[rel_end + 3 ..];

                const CreateEndpoint = struct {
                    table: *Table,
                    row_idx: usize,
                    var_name: []const u8,
                };
                const left_ref: CreateEndpoint = blk: {
                    if (parseMatchNodeVarRef(left_pattern)) |left_ref_name| {
                        for (node_bindings.items) |binding| {
                            if (std.mem.eql(u8, binding.name, left_ref_name)) {
                                break :blk .{
                                    .table = binding.table,
                                    .row_idx = binding.row_idx,
                                    .var_name = left_ref_name,
                                };
                            }
                        }
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{left_ref_name});
                        unreachable;
                    } else |_| {}
                    create_node_scope_vars.clearRetainingCapacity();
                    for (node_bindings.items) |binding| {
                        try create_node_scope_vars.append(self.allocator, binding.name);
                    }
                    const rewritten_left = try self.rewriteCreateNodePatternForBoundProps(left_pattern, node_bindings.items);
                    if (rewritten_left) |owned| try rewritten_create_patterns.append(self.allocator, owned);
                    const left_pattern_for_create = rewritten_left orelse left_pattern;
                    const created = try self.createNodeFromPattern(left_pattern_for_create, params, create_node_scope_vars.items);
                    break :blk .{
                        .table = created.table,
                        .row_idx = created.row_idx,
                        .var_name = created.var_name,
                    };
                };
                const right_ref: CreateEndpoint = blk: {
                    if (parseMatchNodeVarRef(right_pattern)) |right_ref_name| {
                        if (left_ref.var_name.len > 0 and std.mem.eql(u8, left_ref.var_name, right_ref_name)) {
                            break :blk .{
                                .table = left_ref.table,
                                .row_idx = left_ref.row_idx,
                                .var_name = right_ref_name,
                            };
                        }
                        for (node_bindings.items) |binding| {
                            if (std.mem.eql(u8, binding.name, right_ref_name)) {
                                break :blk .{
                                    .table = binding.table,
                                    .row_idx = binding.row_idx,
                                    .var_name = right_ref_name,
                                };
                            }
                        }
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{right_ref_name});
                        unreachable;
                    } else |_| {}
                    create_node_scope_vars.clearRetainingCapacity();
                    for (node_bindings.items) |binding| {
                        try create_node_scope_vars.append(self.allocator, binding.name);
                    }
                    if (left_ref.var_name.len > 0) {
                        var already_scoped = false;
                        for (create_node_scope_vars.items) |scope_var| {
                            if (std.mem.eql(u8, scope_var, left_ref.var_name)) {
                                already_scoped = true;
                                break;
                            }
                        }
                        if (!already_scoped) {
                            try create_node_scope_vars.append(self.allocator, left_ref.var_name);
                        }
                    }
                    const rewritten_right = try self.rewriteCreateNodePatternForBoundProps(right_pattern, node_bindings.items);
                    if (rewritten_right) |owned| try rewritten_create_patterns.append(self.allocator, owned);
                    const right_pattern_for_create = rewritten_right orelse right_pattern;
                    const created = try self.createNodeFromPattern(right_pattern_for_create, params, create_node_scope_vars.items);
                    break :blk .{
                        .table = created.table,
                        .row_idx = created.row_idx,
                        .var_name = created.var_name,
                    };
                };
                const left_var = if (left_ref.var_name.len > 0) left_ref.var_name else "__hippo_mc_mp_left_out_of_scope__";
                const right_var = if (right_ref.var_name.len > 0) right_ref.var_name else "__hippo_mc_mp_right_out_of_scope__";

                var rel_head = rel_part;
                var rel_props: []const u8 = "";
                if (std.mem.indexOfScalar(u8, rel_part, '{')) |open_brace| {
                    const close_brace = std.mem.lastIndexOfScalar(u8, rel_part, '}') orelse return error.InvalidCreateNode;
                    if (close_brace <= open_brace) return error.InvalidCreateNode;
                    rel_head = std.mem.trim(u8, rel_part[0..open_brace], " \t\n\r");
                    rel_props = rel_part[open_brace + 1 .. close_brace];
                }
                const rel_colon_idx = std.mem.indexOfScalar(u8, rel_head, ':') orelse return error.InvalidCreateNode;
                const rel_var_raw = std.mem.trim(u8, rel_head[0..rel_colon_idx], " \t\n\r");
                if (rel_var_raw.len > 0 and !Engine.isIdentifierToken(rel_var_raw)) return error.InvalidCreateNode;
                const rel_name = std.mem.trim(u8, rel_head[rel_colon_idx + 1 ..], " \t\n\r");
                if (rel_name.len == 0) return error.InvalidCreateNode;
                const rel_assign_var = if (rel_var_raw.len > 0) rel_var_raw else "__hippo_mc_mp_rel_assign__";

                const rel_table_ptr = self.rel_tables.getPtr(rel_name) orelse return error.TableNotFound;
                if (!std.mem.eql(u8, left_ref.table.name, rel_table_ptr.from_table)) return error.RelEndpointTypeMismatch;
                if (!std.mem.eql(u8, right_ref.table.name, rel_table_ptr.to_table)) return error.RelEndpointTypeMismatch;

                var prop_assignments: std.ArrayList(RelSetAssignment) = .{};
                defer prop_assignments.deinit(self.allocator);
                var prop_assignment_texts: std.ArrayList([]u8) = .{};
                defer {
                    for (prop_assignment_texts.items) |text| {
                        self.allocator.free(text);
                    }
                    prop_assignment_texts.deinit(self.allocator);
                }
                var prop_iter = std.mem.splitScalar(u8, rel_props, ',');
                while (prop_iter.next()) |raw_prop| {
                    const prop = std.mem.trim(u8, raw_prop, " \t\n\r");
                    if (prop.len == 0) continue;

                    const prop_colon_idx = std.mem.indexOfScalar(u8, prop, ':') orelse return error.InvalidCreateNode;
                    const key = std.mem.trim(u8, prop[0..prop_colon_idx], " \t\n\r");
                    const col_idx_for_key = rel_table_ptr.columnIndex(key) orelse return error.ColumnNotFound;
                    const target_ty_for_key = rel_table_ptr.columns.items[col_idx_for_key].ty;
                    var value_text = std.mem.trim(u8, prop[prop_colon_idx + 1 ..], " \t\n\r");
                    var value_text_owned: ?[]u8 = null;
                    defer if (value_text_owned) |owned| self.allocator.free(owned);
                    if (Engine.isIdentifierToken(value_text) and
                        !std.ascii.eqlIgnoreCase(value_text, "true") and
                        !std.ascii.eqlIgnoreCase(value_text, "false") and
                        !std.ascii.eqlIgnoreCase(value_text, "null"))
                    {
                        for (node_bindings.items) |binding| {
                            if (!std.mem.eql(u8, binding.name, value_text)) continue;
                            try self.failImplicitCastTypeMismatch(value_text, "NODE", typeName(target_ty_for_key));
                            unreachable;
                        }
                        for (rel_bindings.items) |binding| {
                            if (!std.mem.eql(u8, binding.name, value_text)) continue;
                            try self.failImplicitCastTypeMismatch(value_text, "REL", typeName(target_ty_for_key));
                            unreachable;
                        }
                    }
                    if (Engine.parsePropertyAccessExpr(value_text)) |rhs_prop| {
                        var resolved_external_node = false;
                        if (!std.mem.eql(u8, rhs_prop.var_name, left_var) and
                            !std.mem.eql(u8, rhs_prop.var_name, right_var) and
                            !std.mem.eql(u8, rhs_prop.var_name, rel_assign_var))
                        {
                            for (node_bindings.items) |binding| {
                                if (!std.mem.eql(u8, binding.name, rhs_prop.var_name)) continue;
                                const rhs_col_idx = try self.nodeColumnIndexOrBinderError(binding.table, rhs_prop.var_name, rhs_prop.prop_name);
                                value_text_owned = try self.cellToCypherLiteral(binding.table.rows.items[binding.row_idx][rhs_col_idx]);
                                value_text = value_text_owned.?;
                                resolved_external_node = true;
                                break;
                            }
                        }
                        if (!resolved_external_node) {
                            for (rel_bindings.items) |binding| {
                                if (std.mem.eql(u8, binding.name, rhs_prop.var_name) and !std.mem.eql(u8, rhs_prop.var_name, rel_assign_var)) {
                                    value_text = switch (target_ty_for_key) {
                                        .STRING => "''",
                                        .BOOL => "false",
                                        .DOUBLE => "0.0",
                                        else => "0",
                                    };
                                    break;
                                }
                            }
                        }
                    }

                    const assignment_text = try std.fmt.allocPrint(self.allocator, "{s}.{s} = {s}", .{
                        rel_assign_var,
                        key,
                        value_text,
                    });
                    try prop_assignment_texts.append(self.allocator, assignment_text);
                    try prop_assignments.append(
                        self.allocator,
                        try self.parseRelSetAssignment(
                            left_var,
                            right_var,
                            rel_table_ptr,
                            rel_assign_var,
                            left_ref.table,
                            right_ref.table,
                            assignment_text,
                            params,
                        ),
                    );
                }

                var props = try self.allocator.alloc(Cell, rel_table_ptr.columns.items.len);
                errdefer self.allocator.free(props);
                for (props) |*cell| {
                    cell.* = .null;
                }
                const left_row = left_ref.table.rows.items[left_ref.row_idx];
                const right_row = right_ref.table.rows.items[right_ref.row_idx];
                for (prop_assignments.items) |assignment| {
                    const new_value = switch (assignment.rhs) {
                        .literal => |value| switch (value) {
                            .null => Cell.null,
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                            .int64 => |v| Cell{ .int64 = v },
                            .uint64 => |v| Cell{ .uint64 = v },
                            .bool => |b| Cell{ .int64 = if (b) 1 else 0 },
                            .float64 => |v| Cell{ .float64 = v },
                        },
                        .literal_int64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                        .literal_float64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                        .ref => |rhs_ref| try Engine.relCellFor(rhs_ref, left_row, right_row, props).clone(self.allocator),
                        .ref_int64_to_string => |rhs_ref| blk: {
                            const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                            const cast_cell: Cell = switch (source) {
                                .null => Cell.null,
                                .int64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                                .uint64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                                .float64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                                .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                            };
                            break :blk cast_cell;
                        },
                        .ref_int64_to_double => |rhs_ref| blk: {
                            const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                            const cast_cell: Cell = switch (source) {
                                .null => Cell.null,
                                .int64 => |v| Cell{ .float64 = @as(f64, @floatFromInt(v)) },
                                .uint64 => |v| Cell{ .float64 = @floatFromInt(v) },
                                .float64 => |v| Cell{ .float64 = v },
                                .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                            };
                            break :blk cast_cell;
                        },
                        .ref_float64_to_int64 => |rhs_ref| blk: {
                            const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                            const cast_cell: Cell = switch (source) {
                                .null => Cell.null,
                                .int64 => |v| Cell{ .int64 = v },
                                .uint64 => |v| blk2: {
                                    if (v > std.math.maxInt(i64)) {
                                        try self.failUserFmt("Overflow exception: Value {d} is not within INT64 range", .{v});
                                        unreachable;
                                    }
                                    break :blk2 Cell{ .int64 = @intCast(v) };
                                },
                                .float64 => |v| Cell{ .int64 = Engine.roundFloatToInt64LikeKuzu(v) },
                                .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                            };
                            break :blk cast_cell;
                        },
                    };
                    const target = &props[assignment.col_idx];
                    target.deinit(self.allocator);
                    target.* = new_value;
                }

                try rel_table_ptr.rows.append(self.allocator, .{
                    .src_row = left_ref.row_idx,
                    .dst_row = right_ref.row_idx,
                    .props = props,
                });

                if (left_ref.var_name.len > 0) {
                    var replaced = false;
                    for (node_bindings.items) |*binding| {
                        if (std.mem.eql(u8, binding.name, left_ref.var_name)) {
                            binding.* = .{ .name = left_ref.var_name, .table = left_ref.table, .row_idx = left_ref.row_idx };
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) {
                        try node_bindings.append(self.allocator, .{
                            .name = left_ref.var_name,
                            .table = left_ref.table,
                            .row_idx = left_ref.row_idx,
                        });
                    }
                }
                if (right_ref.var_name.len > 0) {
                    var replaced = false;
                    for (node_bindings.items) |*binding| {
                        if (std.mem.eql(u8, binding.name, right_ref.var_name)) {
                            binding.* = .{ .name = right_ref.var_name, .table = right_ref.table, .row_idx = right_ref.row_idx };
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) {
                        try node_bindings.append(self.allocator, .{
                            .name = right_ref.var_name,
                            .table = right_ref.table,
                            .row_idx = right_ref.row_idx,
                        });
                    }
                }
                if (rel_var_raw.len > 0) {
                    var replaced = false;
                    for (rel_bindings.items) |*binding| {
                        if (std.mem.eql(u8, binding.name, rel_var_raw)) {
                            binding.* = .{ .name = rel_var_raw, .rel_table = rel_table_ptr, .props = props };
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) {
                        try rel_bindings.append(self.allocator, .{
                            .name = rel_var_raw,
                            .rel_table = rel_table_ptr,
                            .props = props,
                        });
                    }
                }
            }

            if (return_projection != null and has_count_projection) {
                var group_counts: []i64 = undefined;
                var group_seen: []std.StringHashMap(void) = undefined;

                if (group_terms.items.len > 0) {
                    var key_buf: std.ArrayList(u8) = .{};
                    defer key_buf.deinit(self.allocator);
                    for (return_sources.items) |src| {
                        switch (src) {
                            .node_prop => |ref| blk: {
                                for (node_bindings.items) |binding| {
                                    if (!std.mem.eql(u8, binding.name, ref.var_name)) continue;
                                    try Engine.appendCellToGroupKey(self.allocator, &key_buf, binding.table.rows.items[binding.row_idx][ref.col_idx]);
                                    break :blk;
                                }
                                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{ref.var_name});
                                unreachable;
                            },
                            .rel_prop => |ref| blk: {
                                for (rel_bindings.items) |binding| {
                                    if (!std.mem.eql(u8, binding.name, ref.var_name)) continue;
                                    try Engine.appendCellToGroupKey(self.allocator, &key_buf, binding.props[ref.col_idx]);
                                    break :blk;
                                }
                                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{ref.var_name});
                                unreachable;
                            },
                            .scalar_expr => |expr| {
                                const scalar = try self.evaluateReturnScalarExpr(expr, params);
                                var cell = scalar.cell;
                                defer cell.deinit(self.allocator);
                                try Engine.appendCellToGroupKey(self.allocator, &key_buf, cell);
                            },
                        }
                    }

                    const group_key = try key_buf.toOwnedSlice(self.allocator);
                    errdefer self.allocator.free(group_key);

                    if (count_groups.getPtr(group_key)) |existing| {
                        self.allocator.free(group_key);
                        group_counts = existing.counts;
                        group_seen = existing.seen;
                    } else {
                        const stored = try self.allocator.alloc(Cell, return_sources.items.len);
                        errdefer self.allocator.free(stored);
                        for (return_sources.items, 0..) |src, out_idx| {
                            stored[out_idx] = switch (src) {
                                .node_prop => |ref| blk: {
                                    for (node_bindings.items) |binding| {
                                        if (!std.mem.eql(u8, binding.name, ref.var_name)) continue;
                                        break :blk try binding.table.rows.items[binding.row_idx][ref.col_idx].clone(self.allocator);
                                    }
                                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{ref.var_name});
                                    unreachable;
                                },
                                .rel_prop => |ref| blk: {
                                    for (rel_bindings.items) |binding| {
                                        if (!std.mem.eql(u8, binding.name, ref.var_name)) continue;
                                        break :blk try binding.props[ref.col_idx].clone(self.allocator);
                                    }
                                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{ref.var_name});
                                    unreachable;
                                },
                                .scalar_expr => |expr| blk: {
                                    const scalar = try self.evaluateReturnScalarExpr(expr, params);
                                    break :blk scalar.cell;
                                },
                            };
                        }

                        const counts = try self.allocator.alloc(i64, count_terms.items.len);
                        @memset(counts, 0);
                        const seen_maps = try self.initSeenMaps(count_terms.items);
                        try count_groups.put(group_key, .{
                            .cells = stored,
                            .counts = counts,
                            .seen = seen_maps,
                        });
                        const inserted = count_groups.getPtr(group_key) orelse return error.OutOfMemory;
                        group_counts = inserted.counts;
                        group_seen = inserted.seen;
                    }
                } else {
                    group_counts = global_counts_opt orelse return error.InvalidMatch;
                    group_seen = global_seen_opt orelse return error.InvalidMatch;
                }

                for (count_terms.items, count_sources.items, 0..) |count_term, count_source, idx| {
                    var include = false;
                    var has_value = false;
                    var value_cell: Cell = .null;
                    var value_owned = false;
                    defer if (value_owned) value_cell.deinit(self.allocator);

                    switch (count_source) {
                        .star => include = true,
                        .node_prop => |ref| blk: {
                            for (node_bindings.items) |binding| {
                                if (!std.mem.eql(u8, binding.name, ref.var_name)) continue;
                                value_cell = binding.table.rows.items[binding.row_idx][ref.col_idx];
                                include = !cellIsNull(value_cell);
                                has_value = true;
                                break :blk;
                            }
                            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{ref.var_name});
                            unreachable;
                        },
                        .rel_prop => |ref| blk: {
                            for (rel_bindings.items) |binding| {
                                if (!std.mem.eql(u8, binding.name, ref.var_name)) continue;
                                value_cell = binding.props[ref.col_idx];
                                include = !cellIsNull(value_cell);
                                has_value = true;
                                break :blk;
                            }
                            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{ref.var_name});
                            unreachable;
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            value_cell = scalar.cell;
                            value_owned = true;
                            has_value = true;
                            if (cellIsNull(value_cell)) {
                                try self.failCountAnyBinderError(count_term.distinct);
                                unreachable;
                            }
                            include = true;
                        },
                    }
                    if (!include) continue;

                    if (count_term.distinct) {
                        if (!has_value) continue;
                        var distinct_key_buf: std.ArrayList(u8) = .{};
                        defer distinct_key_buf.deinit(self.allocator);
                        try Engine.appendCellToGroupKey(self.allocator, &distinct_key_buf, value_cell);
                        const distinct_key = try distinct_key_buf.toOwnedSlice(self.allocator);
                        errdefer self.allocator.free(distinct_key);
                        if (group_seen[idx].contains(distinct_key)) {
                            self.allocator.free(distinct_key);
                            continue;
                        }
                        try group_seen[idx].put(distinct_key, {});
                    }

                    group_counts[idx] += 1;
                }
            } else if (return_projection != null) {
                var out = try self.allocator.alloc(Cell, return_sources.items.len);
                errdefer self.allocator.free(out);
                var initialized: usize = 0;
                errdefer {
                    for (0..initialized) |i| {
                        out[i].deinit(self.allocator);
                    }
                }
                for (return_sources.items, 0..) |src, out_idx| {
                    out[out_idx] = switch (src) {
                        .node_prop => |ref| blk: {
                            for (node_bindings.items) |binding| {
                                if (!std.mem.eql(u8, binding.name, ref.var_name)) continue;
                                break :blk try binding.table.rows.items[binding.row_idx][ref.col_idx].clone(self.allocator);
                            }
                            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{ref.var_name});
                            unreachable;
                        },
                        .rel_prop => |ref| blk: {
                            for (rel_bindings.items) |binding| {
                                if (!std.mem.eql(u8, binding.name, ref.var_name)) continue;
                                break :blk try binding.props[ref.col_idx].clone(self.allocator);
                            }
                            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{ref.var_name});
                            unreachable;
                        },
                        .scalar_expr => |expr| blk: {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            break :blk scalar.cell;
                        },
                    };
                    initialized += 1;
                }
                try result.rows.append(self.allocator, out);
            }
        }

        if (return_projection != null and has_count_projection) {
            if (group_terms.items.len == 0) {
                const counts = global_counts_opt orelse return error.InvalidMatch;
                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    &[_]Cell{},
                    count_terms.items,
                    counts,
                );
                try result.rows.append(self.allocator, out);
            } else {
                var group_it = count_groups.iterator();
                while (group_it.next()) |entry| {
                    const state = entry.value_ptr.*;
                    const out = try self.buildCountOutputRowFromTerms(
                        projection_term_count,
                        group_terms.items,
                        state.cells,
                        count_terms.items,
                        state.counts,
                    );
                    try result.rows.append(self.allocator, out);
                }
            }
        }

        if (return_projection != null) {
            if (return_distinct) {
                try self.dedupeResultRows(result);
            }
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                if (return_distinct) {
                    sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                } else {
                    sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                }
            }
            self.applyResultWindow(result, result_skip, result_limit);
        }
    }

    fn executeMatchCreateRelationship(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        var match_create_query = query;
        var return_clause_raw: ?[]const u8 = null;
        if (indexOfAsciiNoCase(query, " RETURN ")) |return_idx| {
            match_create_query = std.mem.trim(u8, query[0..return_idx], " \t\n\r");
            return_clause_raw = std.mem.trim(u8, query[return_idx + " RETURN ".len ..], " \t\n\r");
        }

        var return_projection: ?[]const u8 = null;
        var return_distinct = false;
        var result_skip: usize = 0;
        var result_limit: ?usize = null;
        var order_expr: ?[]const u8 = null;
        if (return_clause_raw) |return_clause| {
            try self.enforceSkipBeforeLimitParserParity(query, return_clause);
            const pagination = try self.parsePaginationClause(query, return_clause);
            const distinct_clause = try parseDistinctClause(pagination.body);
            return_distinct = distinct_clause.distinct;
            result_skip = pagination.skip;
            result_limit = pagination.limit;

            const order_keyword = " ORDER BY ";
            var projection_part = distinct_clause.body;
            if (indexOfAsciiNoCase(distinct_clause.body, order_keyword)) |order_idx| {
                projection_part = std.mem.trim(u8, distinct_clause.body[0..order_idx], " \t\n\r");
                order_expr = std.mem.trim(u8, distinct_clause.body[order_idx + order_keyword.len ..], " \t\n\r");
            }
            return_projection = projection_part;
        }

        const parsed = try parseMatchCreateRelHead(match_create_query);

        const left_table = self.node_tables.getPtr(parsed.left_table) orelse return error.TableNotFound;
        const right_table = self.node_tables.getPtr(parsed.right_table) orelse return error.TableNotFound;
        const rel_table = self.rel_tables.getPtr(parsed.rel_table) orelse return error.TableNotFound;
        const rel_scope_var = if (parsed.rel_var.len > 0) parsed.rel_var else "__hippo_mc_rel_out_of_scope__";
        const rel_assign_var = if (parsed.rel_var.len > 0) parsed.rel_var else "__hippo_mc_rel_assign__";

        var src_is_left: ?bool = null;
        if (std.mem.eql(u8, parsed.src_var, parsed.left_var)) src_is_left = true;
        if (std.mem.eql(u8, parsed.src_var, parsed.right_var)) src_is_left = false;
        const src_left = src_is_left orelse return error.InvalidMatch;

        var dst_is_left: ?bool = null;
        if (std.mem.eql(u8, parsed.dst_var, parsed.left_var)) dst_is_left = true;
        if (std.mem.eql(u8, parsed.dst_var, parsed.right_var)) dst_is_left = false;
        const dst_left = dst_is_left orelse return error.InvalidMatch;

        const src_table_name = if (src_left) left_table.name else right_table.name;
        const dst_table_name = if (dst_left) left_table.name else right_table.name;
        if (!std.mem.eql(u8, rel_table.from_table, src_table_name)) return error.RelEndpointTypeMismatch;
        if (!std.mem.eql(u8, rel_table.to_table, dst_table_name)) return error.RelEndpointTypeMismatch;

        var prop_assignments: std.ArrayList(RelSetAssignment) = .{};
        defer prop_assignments.deinit(self.allocator);
        var prop_assignment_texts: std.ArrayList([]u8) = .{};
        defer {
            for (prop_assignment_texts.items) |text| {
                self.allocator.free(text);
            }
            prop_assignment_texts.deinit(self.allocator);
        }

        var prop_iter = std.mem.splitScalar(u8, parsed.rel_props, ',');
        while (prop_iter.next()) |raw_prop| {
            const prop = std.mem.trim(u8, raw_prop, " \t\n\r");
            if (prop.len == 0) continue;
            const colon_idx = std.mem.indexOfScalar(u8, prop, ':') orelse return error.InvalidCreateNode;
            const key = std.mem.trim(u8, prop[0..colon_idx], " \t\n\r");
            const value_text = prop[colon_idx + 1 ..];
            const assignment_text = try std.fmt.allocPrint(self.allocator, "{s}.{s} = {s}", .{
                rel_assign_var,
                key,
                std.mem.trim(u8, value_text, " \t\n\r"),
            });
            try prop_assignment_texts.append(self.allocator, assignment_text);
            try prop_assignments.append(
                self.allocator,
                try self.parseRelSetAssignment(
                    parsed.left_var,
                    parsed.right_var,
                    rel_table,
                    rel_assign_var,
                    left_table,
                    right_table,
                    assignment_text,
                    params,
                ),
            );
        }

        const MatchCreateReturnSource = union(enum) {
            left_col: usize,
            right_col: usize,
            rel_col: usize,
            scalar_expr: []const u8,
        };

        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        var has_count_projection = false;

        var return_sources: std.ArrayList(MatchCreateReturnSource) = .{};
        defer return_sources.deinit(self.allocator);

        if (return_projection) |projection_part| {
            try self.validateProjectionTermsExplicitAs(query, projection_part);
            has_count_projection = (self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
                error.InvalidCountDistinctStar => {
                    try self.raiseCountDistinctStarProjectionError(query);
                    unreachable;
                },
                else => return err,
            });

            if (!has_count_projection) {
                var projection_terms = try self.splitTopLevelProjectionTerms(projection_part);
                defer projection_terms.deinit(self.allocator);
                const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
                var implicit_param_alias_slot: usize = 8;

                for (projection_terms.items) |raw_term| {
                    const projection_term = try parseProjectionTerm(raw_term);
                    var scalar_expr = projection_term.expr;
                    if (try parseCountTermExpr(projection_term.expr)) |count_expr| {
                        if (count_expr.count_expr.len > 0 and count_expr.count_expr[0] == '$') {
                            const param_lookup = try self.getParameterValueWithPresence(count_expr.count_expr, params);
                            if (!param_lookup.present) {
                                scalar_expr = count_expr.count_expr;
                            }
                        }
                    }

                    if (self.parsePropertyExprOptional(scalar_expr, parsed.left_var)) |col_name| {
                        const col_idx = try self.nodeColumnIndexOrBinderError(left_table, parsed.left_var, col_name);
                        const ty = try self.nodeColumnTypeOrBinderError(left_table, parsed.left_var, col_name);
                        try result.columns.append(self.allocator, try self.allocator.dupe(u8, projection_term.alias orelse scalar_expr));
                        try result.types.append(self.allocator, typeName(ty));
                        try return_sources.append(self.allocator, .{ .left_col = col_idx });
                        implicit_param_alias_slot += 1;
                        continue;
                    }

                    if (self.parsePropertyExprOptional(scalar_expr, parsed.right_var)) |col_name| {
                        const col_idx = try self.nodeColumnIndexOrBinderError(right_table, parsed.right_var, col_name);
                        const ty = try self.nodeColumnTypeOrBinderError(right_table, parsed.right_var, col_name);
                        try result.columns.append(self.allocator, try self.allocator.dupe(u8, projection_term.alias orelse scalar_expr));
                        try result.types.append(self.allocator, typeName(ty));
                        try return_sources.append(self.allocator, .{ .right_col = col_idx });
                        implicit_param_alias_slot += 1;
                        continue;
                    }

                    if (self.parsePropertyExprOptional(scalar_expr, rel_scope_var)) |col_name| {
                        const col_idx = try self.relColumnIndexOrBinderError(rel_table, rel_scope_var, col_name);
                        const ty = try self.relColumnTypeOrBinderError(rel_table, rel_scope_var, col_name);
                        try result.columns.append(self.allocator, try self.allocator.dupe(u8, projection_term.alias orelse scalar_expr));
                        try result.types.append(self.allocator, typeName(ty));
                        try return_sources.append(self.allocator, .{ .rel_col = col_idx });
                        implicit_param_alias_slot += 1;
                        continue;
                    }

                    if (Engine.parsePropertyAccessExpr(scalar_expr)) |property_expr| {
                        if (std.mem.eql(u8, property_expr.var_name, parsed.left_var)) {
                            try self.failCannotFindProperty(parsed.left_var, property_expr.prop_name);
                            unreachable;
                        }
                        if (std.mem.eql(u8, property_expr.var_name, parsed.right_var)) {
                            try self.failCannotFindProperty(parsed.right_var, property_expr.prop_name);
                            unreachable;
                        }
                        if (parsed.rel_var.len > 0 and std.mem.eql(u8, property_expr.var_name, parsed.rel_var)) {
                            try self.failCannotFindProperty(parsed.rel_var, property_expr.prop_name);
                            unreachable;
                        }
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                        unreachable;
                    }

                    if (Engine.scopeVariableForUnknownExpr(scalar_expr)) |unknown_var| {
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                        unreachable;
                    }

                    var scalar = try self.evaluateReturnScalarExpr(scalar_expr, params);
                    defer scalar.cell.deinit(self.allocator);
                    var output_alias = projection_term.alias orelse scalar.default_alias;
                    var output_alias_owned = false;
                    defer if (output_alias_owned) self.allocator.free(output_alias);
                    if (projection_term.alias == null and implicit_param_aliases and scalar_expr.len > 0 and scalar_expr[0] == '$') {
                        const param_lookup = try self.getParameterValueWithPresence(scalar_expr, params);
                        if (!param_lookup.present) {
                            output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                            output_alias_owned = true;
                        }
                    }
                    try result.columns.append(
                        self.allocator,
                        try self.allocator.dupe(u8, output_alias),
                    );
                    try result.types.append(self.allocator, scalar.type_name);
                    try return_sources.append(self.allocator, .{ .scalar_expr = scalar_expr });
                    implicit_param_alias_slot += 1;
                }
            }
        }

        var created_rel_indices: std.ArrayList(usize) = .{};
        defer created_rel_indices.deinit(self.allocator);

        for (left_table.rows.items, 0..) |left_row, left_idx| {
            for (right_table.rows.items, 0..) |right_row, right_idx| {
                if (parsed.where_text) |wt| {
                    if (!(try self.evaluateMatchCreateWhereExpression(
                        wt,
                        params,
                        parsed.left_var,
                        parsed.right_var,
                        left_table,
                        right_table,
                        left_row,
                        right_row,
                    ))) continue;
                }

                const src_idx = if (src_left) left_idx else right_idx;
                const dst_idx = if (dst_left) left_idx else right_idx;
                var props = try self.allocator.alloc(Cell, rel_table.columns.items.len);
                for (props) |*cell| {
                    cell.* = .null;
                }
                for (prop_assignments.items) |assignment| {
                    const new_value = switch (assignment.rhs) {
                        .literal => |value| switch (value) {
                            .null => Cell.null,
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                            .int64 => |v| Cell{ .int64 = v },
                            .uint64 => |v| Cell{ .uint64 = v },
                            .bool => |b| Cell{ .int64 = if (b) 1 else 0 },
                            .float64 => |v| Cell{ .float64 = v },
                        },
                        .literal_int64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                        .literal_float64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                        .ref => |rhs_ref| try Engine.relCellFor(rhs_ref, left_row, right_row, props).clone(self.allocator),
                        .ref_int64_to_string => |rhs_ref| blk: {
                            const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                            const cast_cell: Cell = switch (source) {
                                .null => Cell.null,
                                .int64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                                .uint64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                                .float64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                                .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                            };
                            break :blk cast_cell;
                        },
                        .ref_int64_to_double => |rhs_ref| blk: {
                            const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                            const cast_cell: Cell = switch (source) {
                                .null => Cell.null,
                                .int64 => |v| Cell{ .float64 = @as(f64, @floatFromInt(v)) },
                                .uint64 => |v| Cell{ .float64 = @floatFromInt(v) },
                                .float64 => |v| Cell{ .float64 = v },
                                .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                            };
                            break :blk cast_cell;
                        },
                        .ref_float64_to_int64 => |rhs_ref| blk: {
                            const source = Engine.relCellFor(rhs_ref, left_row, right_row, props);
                            const cast_cell: Cell = switch (source) {
                                .null => Cell.null,
                                .int64 => |v| Cell{ .int64 = v },
                                .uint64 => |v| blk2: {
                                    if (v > std.math.maxInt(i64)) {
                                        try self.failUserFmt("Overflow exception: Value {d} is not within INT64 range", .{v});
                                        unreachable;
                                    }
                                    break :blk2 Cell{ .int64 = @intCast(v) };
                                },
                                .float64 => |v| Cell{ .int64 = Engine.roundFloatToInt64LikeKuzu(v) },
                                .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                            };
                            break :blk cast_cell;
                        },
                    };
                    const target = &props[assignment.col_idx];
                    target.deinit(self.allocator);
                    target.* = new_value;
                }
                try rel_table.rows.append(self.allocator, .{
                    .src_row = src_idx,
                    .dst_row = dst_idx,
                    .props = props,
                });

                if (return_projection != null and has_count_projection) {
                    try created_rel_indices.append(self.allocator, rel_table.rows.items.len - 1);
                }

                if (return_projection != null and !has_count_projection) {
                    var out_row = try self.allocator.alloc(Cell, return_sources.items.len);
                    errdefer self.allocator.free(out_row);
                    var initialized: usize = 0;
                    errdefer {
                        for (0..initialized) |i| {
                            out_row[i].deinit(self.allocator);
                        }
                    }

                    for (return_sources.items, 0..) |src, out_idx| {
                        out_row[out_idx] = switch (src) {
                            .left_col => |col_idx| try left_row[col_idx].clone(self.allocator),
                            .right_col => |col_idx| try right_row[col_idx].clone(self.allocator),
                            .rel_col => |col_idx| try props[col_idx].clone(self.allocator),
                            .scalar_expr => |expr| blk: {
                                const scalar = try self.evaluateReturnScalarExpr(expr, params);
                                break :blk scalar.cell;
                            },
                        };
                        initialized += 1;
                    }

                    try result.rows.append(self.allocator, out_row);
                }
            }
        }

        if (return_projection != null and has_count_projection) {
            var count_targets: std.ArrayList(RelCountTarget) = .{};
            defer count_targets.deinit(self.allocator);
            for (count_terms.items) |count_term| {
                try count_targets.append(
                    self.allocator,
                    try self.parseRelCountTarget(
                        count_term.count_expr,
                        parsed.left_var,
                        parsed.right_var,
                        rel_scope_var,
                        left_table,
                        right_table,
                        rel_table,
                        params,
                        count_term.distinct,
                    ),
                );
            }

            const MatchCreateGroupSource = union(enum) {
                ref: ProjRef,
                scalar_expr: []const u8,
            };

            var group_sources: std.ArrayList(MatchCreateGroupSource) = .{};
            defer group_sources.deinit(self.allocator);
            var group_types: std.ArrayList([]const u8) = .{};
            defer group_types.deinit(self.allocator);
            for (group_terms.items) |group_term| {
                if (try self.resolveRelProjectionRefOptional(
                    group_term.expr,
                    parsed.left_var,
                    parsed.right_var,
                    rel_scope_var,
                    left_table,
                    right_table,
                    rel_table,
                )) |resolved_ref| {
                    const resolved_ty = switch (resolved_ref.source) {
                        .left => left_table.columns.items[resolved_ref.col_idx].ty,
                        .right => right_table.columns.items[resolved_ref.col_idx].ty,
                        .rel => rel_table.columns.items[resolved_ref.col_idx].ty,
                    };
                    try group_sources.append(self.allocator, .{ .ref = resolved_ref });
                    try group_types.append(self.allocator, typeName(resolved_ty));
                    continue;
                }

                if (Engine.parsePropertyAccessExpr(group_term.expr)) |property_expr| {
                    if (std.mem.eql(u8, property_expr.var_name, parsed.left_var)) {
                        try self.failCannotFindProperty(parsed.left_var, property_expr.prop_name);
                        unreachable;
                    }
                    if (std.mem.eql(u8, property_expr.var_name, parsed.right_var)) {
                        try self.failCannotFindProperty(parsed.right_var, property_expr.prop_name);
                        unreachable;
                    }
                    if (parsed.rel_var.len > 0 and std.mem.eql(u8, property_expr.var_name, parsed.rel_var)) {
                        try self.failCannotFindProperty(parsed.rel_var, property_expr.prop_name);
                        unreachable;
                    }
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                    unreachable;
                }
                if (Engine.scopeVariableForUnknownExpr(group_term.expr)) |unknown_var| {
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                    unreachable;
                }

                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                var probe_cell = scalar.cell;
                probe_cell.deinit(self.allocator);
                try group_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
                try group_types.append(self.allocator, scalar.type_name);
            }

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = 4;
            for (0..projection_term_count) |position| {
                if (Engine.findCountTermIndexByPosition(count_terms.items, position)) |count_idx| {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[count_idx].alias));
                    try result.types.append(self.allocator, "INT64");
                    implicit_param_alias_slot += 1;
                    continue;
                }
                if (Engine.findGroupTermIndexByPosition(group_terms.items, position)) |group_idx| {
                    const group_term = group_terms.items[group_idx];
                    var output_alias = group_term.alias;
                    var output_alias_owned = false;
                    defer if (output_alias_owned) self.allocator.free(output_alias);
                    if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                        const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                        if (!param_lookup.present) {
                            output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                            output_alias_owned = true;
                        }
                    }
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                    try result.types.append(self.allocator, group_types.items[group_idx]);
                    switch (group_sources.items[group_idx]) {
                        .scalar_expr => implicit_param_alias_slot += 1,
                        .ref => {},
                    }
                    continue;
                }
                return error.InvalidReturn;
            }

            if (group_terms.items.len == 0) {
                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                defer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                defer self.deinitSeenMaps(seen_maps);

                for (created_rel_indices.items) |rel_idx| {
                    const rel_row = rel_table.rows.items[rel_idx];
                    const left_row = left_table.rows.items[rel_row.src_row];
                    const right_row = right_table.rows.items[rel_row.dst_row];
                    try self.updateRelCountAccumulators(left_row, right_row, rel_row.props, count_terms.items, count_targets.items, counts, seen_maps);
                }

                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    &[_]Cell{},
                    count_terms.items,
                    counts,
                );
                try result.rows.append(self.allocator, out);

                var parsed_out_key_count: usize = 0;
                if (order_expr) |order_text| {
                    var out_keys: std.ArrayList(OutputOrderKey) = .{};
                    defer out_keys.deinit(self.allocator);
                    try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                    parsed_out_key_count = out_keys.items.len;
                    if (out_keys.items.len == 0) {
                        if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                    } else {
                        if (return_distinct) {
                            sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                        } else {
                            sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                        }
                    }
                } else {
                    if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                }
                self.maybeSortDistinctEqualSuffixRows(
                    result,
                    return_distinct,
                    order_expr != null,
                    parsed_out_key_count,
                    result_skip,
                    result_limit,
                );
                if (!self.maybeApplyDistinctNoKeyWindowParity(
                    result,
                    return_distinct,
                    order_expr != null,
                    parsed_out_key_count,
                    result_skip,
                    result_limit,
                )) {
                    self.applyResultWindow(result, result_skip, result_limit);
                }
                return;
            }

            const GroupState = struct {
                cells: []Cell,
                counts: []i64,
                seen: []std.StringHashMap(void),
            };

            var groups = std.StringHashMap(GroupState).init(self.allocator);
            defer {
                var it = groups.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    for (entry.value_ptr.cells) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(entry.value_ptr.cells);
                    self.allocator.free(entry.value_ptr.counts);
                    self.deinitSeenMaps(entry.value_ptr.seen);
                }
                groups.deinit();
            }

            for (created_rel_indices.items) |rel_idx| {
                const rel_row = rel_table.rows.items[rel_idx];
                const left_row = left_table.rows.items[rel_row.src_row];
                const right_row = right_table.rows.items[rel_row.dst_row];

                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                for (group_sources.items) |group_source| {
                    switch (group_source) {
                        .ref => |gref| {
                            const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, cell);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            var scalar_cell = scalar.cell;
                            defer scalar_cell.deinit(self.allocator);
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, scalar_cell);
                        },
                    }
                }
                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);

                if (groups.getPtr(key)) |existing| {
                    self.allocator.free(key);
                    try self.updateRelCountAccumulators(
                        left_row,
                        right_row,
                        rel_row.props,
                        count_terms.items,
                        count_targets.items,
                        existing.counts,
                        existing.seen,
                    );
                    continue;
                }

                const stored = try self.allocator.alloc(Cell, group_sources.items.len);
                errdefer self.allocator.free(stored);
                for (group_sources.items, 0..) |group_source, i| {
                    switch (group_source) {
                        .ref => |gref| {
                            const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                            stored[i] = try cell.clone(self.allocator);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            stored[i] = scalar.cell;
                        },
                    }
                }

                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                errdefer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                errdefer self.deinitSeenMaps(seen_maps);
                try self.updateRelCountAccumulators(
                    left_row,
                    right_row,
                    rel_row.props,
                    count_terms.items,
                    count_targets.items,
                    counts,
                    seen_maps,
                );

                try groups.put(key, .{
                    .cells = stored,
                    .counts = counts,
                    .seen = seen_maps,
                });
            }

            var group_it = groups.iterator();
            while (group_it.next()) |entry| {
                const state = entry.value_ptr.*;
                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    state.cells,
                    count_terms.items,
                    state.counts,
                );
                try result.rows.append(self.allocator, out);
            }

            var parsed_out_key_count: usize = 0;
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                parsed_out_key_count = out_keys.items.len;
                if (out_keys.items.len == 0) {
                    if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                } else {
                    if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
                }
            } else {
                if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
            }
            self.maybeSortDistinctEqualSuffixRows(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            );
            if (!self.maybeApplyDistinctNoKeyWindowParity(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            )) {
                self.applyResultWindow(result, result_skip, result_limit);
            }
            return;
        }

        if (return_projection != null) {
            if (return_distinct) {
                try self.dedupeResultRows(result);
            }
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                if (return_distinct) {
                    sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                } else {
                    sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                }
            }
            self.applyResultWindow(result, result_skip, result_limit);
        }
    }

    fn parseMatchHead(query: []const u8) !struct { var_name: []const u8, table_name: []const u8, tail: []const u8 } {
        if (!startsWithAsciiNoCase(query, "MATCH (")) return error.InvalidMatch;
        const close_idx = std.mem.indexOfScalar(u8, query, ')') orelse return error.InvalidMatch;
        const head = query[7..close_idx]; // var:Table
        const colon_idx = std.mem.indexOfScalar(u8, head, ':') orelse return error.InvalidMatch;
        const var_name = std.mem.trim(u8, head[0..colon_idx], " \t\n\r");
        const table_name = std.mem.trim(u8, head[colon_idx + 1 ..], " \t\n\r");
        const tail = std.mem.trim(u8, query[close_idx + 1 ..], " \t\n\r");
        return .{ .var_name = var_name, .table_name = table_name, .tail = tail };
    }

    fn parseMatchNodePattern(pattern_in: []const u8) !struct { var_name: []const u8, table_name: []const u8 } {
        const pattern = std.mem.trim(u8, pattern_in, " \t\n\r");
        if (pattern.len < 4 or pattern[0] != '(' or pattern[pattern.len - 1] != ')') return error.InvalidMatch;

        const inner = std.mem.trim(u8, pattern[1 .. pattern.len - 1], " \t\n\r");
        const colon_idx = std.mem.indexOfScalar(u8, inner, ':') orelse return error.InvalidMatch;
        const after_colon = std.mem.trim(u8, inner[colon_idx + 1 ..], " \t\n\r");
        var table_name = after_colon;
        if (std.mem.indexOfScalar(u8, after_colon, '{')) |brace_idx| {
            table_name = std.mem.trim(u8, after_colon[0..brace_idx], " \t\n\r");
        }
        if (table_name.len == 0) return error.InvalidMatch;
        return .{
            .var_name = std.mem.trim(u8, inner[0..colon_idx], " \t\n\r"),
            .table_name = table_name,
        };
    }

    fn parseMatchNodeVarRef(pattern_in: []const u8) ![]const u8 {
        const pattern = std.mem.trim(u8, pattern_in, " \t\n\r");
        if (pattern.len < 3 or pattern[0] != '(' or pattern[pattern.len - 1] != ')') return error.InvalidMatch;
        const inner = std.mem.trim(u8, pattern[1 .. pattern.len - 1], " \t\n\r");
        if (inner.len == 0 or std.mem.indexOfScalar(u8, inner, ':') != null) return error.InvalidMatch;
        return inner;
    }

    fn parseMatchRelPattern(pattern_in: []const u8) !struct { var_name: []const u8, table_name: []const u8 } {
        const pattern = std.mem.trim(u8, pattern_in, " \t\n\r");
        const colon_idx = std.mem.indexOfScalar(u8, pattern, ':') orelse return error.InvalidMatch;
        return .{
            .var_name = std.mem.trim(u8, pattern[0..colon_idx], " \t\n\r"),
            .table_name = std.mem.trim(u8, pattern[colon_idx + 1 ..], " \t\n\r"),
        };
    }

    fn parseMatchRelHead(query: []const u8) !struct {
        left_var: []const u8,
        left_table: []const u8,
        rel_var: []const u8,
        rel_table: []const u8,
        right_var: []const u8,
        right_table: []const u8,
        tail: []const u8,
    } {
        if (!startsWithAsciiNoCase(query, "MATCH ")) return error.InvalidMatch;
        const after_match = std.mem.trim(u8, query["MATCH ".len..], " \t\n\r");

        const left_end = std.mem.indexOf(u8, after_match, ")-[") orelse return error.InvalidMatch;
        const left_pattern = after_match[0 .. left_end + 1];
        const after_left = after_match[left_end + 3 ..];

        const rel_end = std.mem.indexOf(u8, after_left, "]->(") orelse return error.InvalidMatch;
        const rel_pattern = after_left[0..rel_end];
        const after_rel = after_left[rel_end + 3 ..];

        const right_close = std.mem.indexOfScalar(u8, after_rel, ')') orelse return error.InvalidMatch;
        const right_pattern = after_rel[0 .. right_close + 1];
        const tail = std.mem.trim(u8, after_rel[right_close + 1 ..], " \t\n\r");

        const left = try parseMatchNodePattern(left_pattern);
        const rel = try parseMatchRelPattern(rel_pattern);
        const right = try parseMatchNodePattern(right_pattern);

        return .{
            .left_var = left.var_name,
            .left_table = left.table_name,
            .rel_var = rel.var_name,
            .rel_table = rel.table_name,
            .right_var = right.var_name,
            .right_table = right.table_name,
            .tail = tail,
        };
    }

    fn parseMatchCreateRelHead(query: []const u8) !struct {
        left_var: []const u8,
        left_table: []const u8,
        right_var: []const u8,
        right_table: []const u8,
        where_text: ?[]const u8,
        src_var: []const u8,
        dst_var: []const u8,
        rel_var: []const u8,
        rel_table: []const u8,
        rel_props: []const u8,
    } {
        if (!startsWithAsciiNoCase(query, "MATCH ")) return error.InvalidMatch;
        const create_idx = indexOfAsciiNoCase(query, " CREATE ") orelse return error.InvalidMatch;
        const match_part = std.mem.trim(u8, query["MATCH ".len..create_idx], " \t\n\r");
        const create_part = std.mem.trim(u8, query[create_idx + " CREATE ".len ..], " \t\n\r");

        const first_close = std.mem.indexOfScalar(u8, match_part, ')') orelse return error.InvalidMatch;
        const left_pattern = match_part[0 .. first_close + 1];
        var after_left = std.mem.trim(u8, match_part[first_close + 1 ..], " \t\n\r");
        if (after_left.len == 0 or after_left[0] != ',') return error.InvalidMatch;
        after_left = std.mem.trim(u8, after_left[1..], " \t\n\r");

        var right_pattern: []const u8 = undefined;
        var where_text: ?[]const u8 = null;
        if (indexOfAsciiNoCase(after_left, " WHERE ")) |where_idx| {
            right_pattern = std.mem.trim(u8, after_left[0..where_idx], " \t\n\r");
            where_text = std.mem.trim(u8, after_left[where_idx + " WHERE ".len ..], " \t\n\r");
        } else {
            right_pattern = std.mem.trim(u8, after_left, " \t\n\r");
        }

        const left = try parseMatchNodePattern(left_pattern);
        const right = try parseMatchNodePattern(right_pattern);

        const rel_mid_a = std.mem.indexOf(u8, create_part, ")-[") orelse return error.InvalidMatch;
        const src_ref = create_part[0 .. rel_mid_a + 1];
        const after_src = create_part[rel_mid_a + 3 ..];
        const rel_mid_b = std.mem.indexOf(u8, after_src, "]->(") orelse return error.InvalidMatch;
        const rel_part = std.mem.trim(u8, after_src[0..rel_mid_b], " \t\n\r");
        const dst_ref = after_src[rel_mid_b + 3 ..];

        const src_var = try parseMatchNodeVarRef(src_ref);
        const dst_var = try parseMatchNodeVarRef(dst_ref);

        var rel_head = std.mem.trim(u8, rel_part, " \t\n\r");
        var rel_props: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rel_part, '{')) |open_brace| {
            const close_brace = std.mem.lastIndexOfScalar(u8, rel_part, '}') orelse return error.InvalidMatch;
            if (close_brace <= open_brace) return error.InvalidMatch;
            rel_head = std.mem.trim(u8, rel_part[0..open_brace], " \t\n\r");
            rel_props = rel_part[open_brace + 1 .. close_brace];
        }
        const rel_colon_idx = std.mem.indexOfScalar(u8, rel_head, ':') orelse return error.InvalidMatch;
        const rel_var = std.mem.trim(u8, rel_head[0..rel_colon_idx], " \t\n\r");
        const rel_table = std.mem.trim(u8, rel_head[rel_colon_idx + 1 ..], " \t\n\r");
        if (rel_table.len == 0) return error.InvalidMatch;

        return .{
            .left_var = left.var_name,
            .left_table = left.table_name,
            .right_var = right.var_name,
            .right_table = right.table_name,
            .where_text = where_text,
            .src_var = src_var,
            .dst_var = dst_var,
            .rel_var = rel_var,
            .rel_table = rel_table,
            .rel_props = rel_props,
        };
    }

    fn parseFilter(self: *Engine, table: *const Table, var_name: []const u8, where_text: []const u8, params: ?*const std.json.ObjectMap) !Filter {
        const norm = try normalizeComparisonClauseForNot(where_text);
        if (parseNullPredicateClause(norm.clause)) |null_clause| {
            if (self.parsePropertyExprOptional(null_clause.expr, var_name)) |col_name| {
                const col_idx = try self.nodeColumnIndexOrBinderError(table, var_name, col_name);
                var pred: NullPredicate = if (null_clause.is_null) .is_null else .is_not_null;
                if (norm.negate) {
                    pred = switch (pred) {
                        .is_null => .is_not_null,
                        .is_not_null => .is_null,
                        .none => .none,
                    };
                }
                return .{
                    .column_idx = col_idx,
                    .op = .eq,
                    .rhs = .{ .literal = .null },
                    .null_predicate = pred,
                };
            }
            return error.InvalidWhere;
        }

        const cmp = try parseComparisonClause(norm.clause);
        var op = if (norm.negate) invertFilterOp(cmp.op) else cmp.op;

        const lhs_col_name = self.parsePropertyExprOptional(cmp.lhs, var_name);
        const rhs_col_name = self.parsePropertyExprOptional(cmp.rhs, var_name);

        if (lhs_col_name) |lhs_name| {
            const lhs_idx = try self.nodeColumnIndexOrBinderError(table, var_name, lhs_name);
            if (rhs_col_name) |rhs_name| {
                const rhs_idx = try self.nodeColumnIndexOrBinderError(table, var_name, rhs_name);
                return .{
                    .column_idx = lhs_idx,
                    .op = op,
                    .rhs = .{ .column_idx = rhs_idx },
                };
            }
            return .{
                .column_idx = lhs_idx,
                .op = op,
                .rhs = .{ .literal = try self.parseFilterValue(cmp.rhs, params) },
            };
        }

        if (rhs_col_name) |rhs_name| {
            const rhs_idx = try self.nodeColumnIndexOrBinderError(table, var_name, rhs_name);
            op = reverseFilterOp(op);
            return .{
                .column_idx = rhs_idx,
                .op = op,
                .rhs = .{ .literal = try self.parseFilterValue(cmp.lhs, params) },
            };
        }

        return error.InvalidWhere;
    }

    fn getParameterValueWithPresence(
        self: *Engine,
        param_expr: []const u8,
        params: ?*const std.json.ObjectMap,
    ) !struct { value: std.json.Value, present: bool } {
        const trimmed = std.mem.trim(u8, param_expr, " \t\n\r");
        const key = if (trimmed.len > 0 and trimmed[0] == '$') trimmed[1..] else trimmed;
        if (key.len == 0) return error.MissingParameter;

        const obj = params orelse return .{ .value = .null, .present = false };
        if (obj.get(key)) |value| {
            if (value == .number_string) {
                try self.failUserMessage("Unable to cast Python instance of type <class 'int'> to C++ type '?' (#define PYBIND11_DETAILED_ERROR_MESSAGES or compile in debug mode for details)");
                unreachable;
            }
            return .{ .value = value, .present = true };
        }
        return .{ .value = .null, .present = false };
    }

    fn getParameterValue(self: *Engine, param_expr: []const u8, params: ?*const std.json.ObjectMap) !std.json.Value {
        return (try self.getParameterValueWithPresence(param_expr, params)).value;
    }

    fn parseFilterValue(self: *Engine, rhs: []const u8, params: ?*const std.json.ObjectMap) !FilterValue {
        const trimmed = std.mem.trim(u8, rhs, " \t\n\r");
        if (trimmed.len > 0 and trimmed[0] == '$') {
            const json_value = try self.getParameterValue(trimmed, params);
            return switch (json_value) {
                .null => .null,
                .string => |s| .{ .string = s },
                .integer => |i| .{ .int64 = @intCast(i) },
                .bool => |b| .{ .bool = b },
                .float => |f| .{ .float64 = f },
                else => error.UnsupportedParameterType,
            };
        }
        const literal = try parseLiteral(trimmed);
        return switch (literal) {
            .null => .null,
            .string => |s| .{ .string = s },
            .int64 => |v| .{ .int64 = v },
            .uint64 => |v| .{ .uint64 = v },
            .bool => |b| .{ .bool = b },
            .float64 => |v| .{ .float64 = v },
        };
    }

    fn parseConstantWhereValue(self: *Engine, rhs: []const u8, params: ?*const std.json.ObjectMap) !FilterValue {
        const trimmed = std.mem.trim(u8, rhs, " \t\n\r");
        if (trimmed.len > 0 and trimmed[0] == '$') {
            const json_value = try self.getParameterValue(trimmed, params);
            return switch (json_value) {
                .null => .null,
                .string => |s| .{ .string = s },
                .integer => |i| .{ .int64 = @intCast(i) },
                .bool => |b| .{ .int64 = if (b) 1 else 0 },
                .float => |f| .{ .float64 = f },
                else => error.UnsupportedParameterType,
            };
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "TRUE")) return .{ .int64 = 1 };
        if (std.ascii.eqlIgnoreCase(trimmed, "FALSE")) return .{ .int64 = 0 };
        const literal = try parseLiteral(trimmed);
        return switch (literal) {
            .null => .null,
            .string => |s| .{ .string = s },
            .int64 => |v| .{ .int64 = v },
            .uint64 => |v| .{ .uint64 = v },
            .bool => |b| .{ .int64 = if (b) 1 else 0 },
            .float64 => |v| .{ .float64 = v },
        };
    }

    fn evaluateConstantWhereClause(self: *Engine, clause: []const u8, params: ?*const std.json.ObjectMap) !bool {
        const norm = try normalizeComparisonClauseForNot(clause);
        if (std.ascii.eqlIgnoreCase(norm.clause, "TRUE")) {
            return if (norm.negate) false else true;
        }
        if (std.ascii.eqlIgnoreCase(norm.clause, "FALSE")) {
            return if (norm.negate) true else false;
        }

        if (parseNullPredicateClause(norm.clause)) |null_clause| {
            // Kuzu currently treats parameterized constant where clauses as truthy
            // regardless of value/operator and NOT-prefixing.
            if (null_clause.expr.len > 0 and null_clause.expr[0] == '$') {
                _ = try self.parseConstantWhereValue(null_clause.expr, params);
                return true;
            }
            const value = try self.parseConstantWhereValue(null_clause.expr, params);
            const value_is_null = switch (value) {
                .null => true,
                else => false,
            };
            var out = if (null_clause.is_null) value_is_null else !value_is_null;
            if (norm.negate) out = !out;
            return out;
        }

        if (std.mem.indexOfScalar(u8, norm.clause, '$') != null) {
            const cmp = parseComparisonClause(norm.clause) catch {
                if (norm.clause.len > 1 and norm.clause[0] == '$') {
                    const json_value = try self.getParameterValue(norm.clause, params);
                    return switch (json_value) {
                        .bool => true,
                        .null => true,
                        .integer => |i| {
                            try self.failUserFmt(
                                "Binder exception: Expression {s} has data type {s} but expected BOOL. Implicit cast is not supported.",
                                .{ norm.clause, inferParamIntegerTypeName(i) },
                            );
                            unreachable;
                        },
                        .float => {
                            try self.failUserFmt(
                                "Binder exception: Expression {s} has data type DOUBLE but expected BOOL. Implicit cast is not supported.",
                                .{norm.clause},
                            );
                            unreachable;
                        },
                        .string => {
                            try self.failUserFmt(
                                "Binder exception: Expression {s} has data type STRING but expected BOOL. Implicit cast is not supported.",
                                .{norm.clause},
                            );
                            unreachable;
                        },
                        else => error.UnsupportedParameterType,
                    };
                }
                _ = try self.parseConstantWhereValue(norm.clause, params);
                return true;
            };
            _ = try self.parseConstantWhereValue(cmp.lhs, params);
            _ = try self.parseConstantWhereValue(cmp.rhs, params);
            return true;
        }

        const cmp = try parseComparisonClause(norm.clause);
        const lhs = try self.parseConstantWhereValue(cmp.lhs, params);
        const rhs = try self.parseConstantWhereValue(cmp.rhs, params);
        const op = if (norm.negate) invertFilterOp(cmp.op) else cmp.op;
        return valueMatchesValue(lhs, rhs, op);
    }

    fn parseNodeFilterGroups(
        self: *Engine,
        table: *const Table,
        var_name: []const u8,
        where_text: []const u8,
        params: ?*const std.json.ObjectMap,
        out_groups: *std.ArrayList(NodeFilterGroup),
    ) !void {
        var or_it = std.mem.splitSequence(u8, where_text, " OR ");
        while (or_it.next()) |raw_or| {
            const disj = std.mem.trim(u8, raw_or, " \t\n\r");
            if (disj.len == 0) return error.InvalidWhere;

            var group: NodeFilterGroup = .{ .filters = .{} };
            errdefer group.deinit(self.allocator);

            var and_it = std.mem.splitSequence(u8, disj, " AND ");
            while (and_it.next()) |raw_and| {
                const clause = std.mem.trim(u8, raw_and, " \t\n\r");
                if (clause.len == 0) return error.InvalidWhere;
                try group.filters.append(self.allocator, try self.parseFilter(table, var_name, clause, params));
            }

            try out_groups.append(self.allocator, group);
        }
    }

    fn parseNodeSetAssignment(
        self: *Engine,
        table: *const Table,
        var_name: []const u8,
        scope_vars: []const []const u8,
        assign_text: []const u8,
        params: ?*const std.json.ObjectMap,
    ) !NodeSetAssignment {
        const eq_idx = std.mem.indexOf(u8, assign_text, "=") orelse return error.InvalidMatch;
        const lhs = std.mem.trim(u8, assign_text[0..eq_idx], " \t\n\r");
        const rhs = std.mem.trim(u8, assign_text[eq_idx + 1 ..], " \t\n\r");

        const expected_prefix = try std.fmt.allocPrint(self.allocator, "{s}.", .{var_name});
        defer self.allocator.free(expected_prefix);
        if (!std.mem.startsWith(u8, lhs, expected_prefix)) return error.InvalidMatch;

        const col_name = lhs[expected_prefix.len..];
        const col_idx = try self.nodeColumnIndexOrBinderError(table, var_name, col_name);
        const expected_ty = table.columns.items[col_idx].ty;
        if (table.primary_key) |pk_name| {
            if (std.mem.eql(u8, col_name, pk_name)) {
                try self.setLastErrorFmt(
                    "Binder exception: Cannot set property {s} in table {s} because it is used as primary key. Try delete and then insert.",
                    .{ pk_name, table.name },
                );
                return error.UserVisibleError;
            }
        }

        if (self.parsePropertyExprOptional(rhs, var_name)) |rhs_col_name| {
            const rhs_col_idx = try self.nodeColumnIndexOrBinderError(table, var_name, rhs_col_name);
            const rhs_ty = table.columns.items[rhs_col_idx].ty;
            if (expected_ty == .STRING and (Engine.isIntegerType(rhs_ty) or rhs_ty == .BOOL)) {
                return .{
                    .col_idx = col_idx,
                    .rhs = .{ .column_idx_int64_to_string = rhs_col_idx },
                };
            }
            if (expected_ty == .DOUBLE and Engine.isIntegerType(rhs_ty)) {
                return .{
                    .col_idx = col_idx,
                    .rhs = .{ .column_idx_int64_to_double = rhs_col_idx },
                };
            }
            if (Engine.isIntegerType(expected_ty) and rhs_ty == .DOUBLE) {
                return .{
                    .col_idx = col_idx,
                    .rhs = .{ .column_idx_float64_to_int64 = rhs_col_idx },
                };
            }
            if (Engine.isIntegerType(expected_ty) and Engine.isIntegerType(rhs_ty)) {
                return .{
                    .col_idx = col_idx,
                    .rhs = .{ .column_idx = rhs_col_idx },
                };
            }
            if (expected_ty != rhs_ty) {
                try self.failImplicitCastTypeMismatch(rhs_col_name, typeName(rhs_ty), typeName(expected_ty));
                unreachable;
            }
            return .{
                .col_idx = col_idx,
                .rhs = .{ .column_idx = rhs_col_idx },
            };
        }

        if (Engine.isIdentifierToken(rhs) and
            !std.ascii.eqlIgnoreCase(rhs, "true") and
            !std.ascii.eqlIgnoreCase(rhs, "false") and
            !std.ascii.eqlIgnoreCase(rhs, "null"))
        {
            if (std.mem.eql(u8, rhs, var_name)) {
                try self.failImplicitCastTypeMismatch(rhs, "NODE", typeName(expected_ty));
                unreachable;
            }
            for (scope_vars) |scope_var| {
                if (!std.mem.eql(u8, rhs, scope_var)) continue;
                try self.failImplicitCastTypeMismatch(rhs, "NODE", typeName(expected_ty));
                unreachable;
            }
            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{rhs});
            unreachable;
        }

        const value = try self.parseFilterValue(rhs, params);
        switch (value) {
            .null => {},
            .string => |s| {
                if (expected_ty != .STRING) {
                    try self.failImplicitCastTypeMismatch(s, "STRING", typeName(expected_ty));
                    unreachable;
                }
            },
            .int64 => |v| {
                if (expected_ty == .STRING) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal_int64_to_string = v },
                    };
                }
                if (expected_ty == .DOUBLE) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .float64 = @as(f64, @floatFromInt(v)) } },
                    };
                }
                if (expected_ty == .UINT64) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .uint64 = @intCast(v) } },
                    };
                }
                if (Engine.isIntegerType(expected_ty)) {
                    try self.ensureIntegerInTypeRange(v, expected_ty);
                } else {
                    const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                    defer self.allocator.free(expr);
                    try self.failImplicitCastTypeMismatch(expr, "INT64", typeName(expected_ty));
                    unreachable;
                }
            },
            .uint64 => |v| {
                if (expected_ty == .STRING) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) } },
                    };
                }
                if (expected_ty == .DOUBLE) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .float64 = @floatFromInt(v) } },
                    };
                }
                if (expected_ty == .UINT64) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .uint64 = v } },
                    };
                }
                if (Engine.isUnsignedIntegerType(expected_ty)) {
                    try self.ensureUnsignedInTypeRange(v, expected_ty);
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .int64 = @intCast(v) } },
                    };
                }
                if (Engine.isIntegerType(expected_ty)) {
                    try self.failUserFmt("Overflow exception: Value {d} is not within {s} range", .{ v, typeName(expected_ty) });
                    unreachable;
                }
                const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                defer self.allocator.free(expr);
                try self.failImplicitCastTypeMismatch(expr, "UINT64", typeName(expected_ty));
                unreachable;
            },
            .float64 => |v| {
                if (expected_ty == .STRING) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal_float64_to_string = v },
                    };
                }
                if (Engine.isIntegerType(expected_ty)) {
                    const rounded = Engine.roundFloatToInt64LikeKuzu(v);
                    try self.ensureIntegerInTypeRange(rounded, expected_ty);
                    if (expected_ty == .UINT64) {
                        return .{
                            .col_idx = col_idx,
                            .rhs = .{ .literal = .{ .uint64 = @intCast(rounded) } },
                        };
                    }
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .int64 = rounded } },
                    };
                }
                if (expected_ty != .DOUBLE) {
                    const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                    defer self.allocator.free(expr);
                    try self.failImplicitCastTypeMismatch(expr, "DOUBLE", typeName(expected_ty));
                    unreachable;
                }
            },
            .bool => |b| {
                if (expected_ty == .STRING) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .string = if (b) "True" else "False" } },
                    };
                }
                if (expected_ty != .BOOL) {
                    try self.failImplicitCastTypeMismatch(if (b) "True" else "False", "BOOL", typeName(expected_ty));
                    unreachable;
                }
            },
        }

        return .{
            .col_idx = col_idx,
            .rhs = .{ .literal = value },
        };
    }

    fn parseNodeSetAssignments(
        self: *Engine,
        table: *const Table,
        var_name: []const u8,
        scope_vars: []const []const u8,
        set_text: []const u8,
        params: ?*const std.json.ObjectMap,
        out_assignments: *std.ArrayList(NodeSetAssignment),
    ) !void {
        var it = std.mem.splitScalar(u8, set_text, ',');
        while (it.next()) |raw| {
            const clause = std.mem.trim(u8, raw, " \t\n\r");
            if (clause.len == 0) return error.InvalidMatch;
            try out_assignments.append(self.allocator, try self.parseNodeSetAssignment(table, var_name, scope_vars, clause, params));
        }
    }

    fn applyNodeSetAssignment(self: *Engine, row: []Cell, assignment: NodeSetAssignment) !void {
        const new_value = switch (assignment.rhs) {
            .literal => |value| switch (value) {
                .null => Cell.null,
                .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                .int64 => |v| Cell{ .int64 = v },
                .uint64 => |v| Cell{ .uint64 = v },
                .bool => |b| Cell{ .int64 = if (b) 1 else 0 },
                .float64 => |v| Cell{ .float64 = v },
            },
            .literal_int64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
            .literal_float64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
            .column_idx => |rhs_col_idx| try row[rhs_col_idx].clone(self.allocator),
            .column_idx_int64_to_string => |rhs_col_idx| blk: {
                const source = row[rhs_col_idx];
                const cast_cell: Cell = switch (source) {
                    .null => Cell.null,
                    .int64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                    .uint64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                    .float64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                    .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                };
                break :blk cast_cell;
            },
            .column_idx_int64_to_double => |rhs_col_idx| blk: {
                const source = row[rhs_col_idx];
                const cast_cell: Cell = switch (source) {
                    .null => Cell.null,
                    .int64 => |v| Cell{ .float64 = @as(f64, @floatFromInt(v)) },
                    .uint64 => |v| Cell{ .float64 = @floatFromInt(v) },
                    .float64 => |v| Cell{ .float64 = v },
                    .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                };
                break :blk cast_cell;
            },
            .column_idx_float64_to_int64 => |rhs_col_idx| blk: {
                const source = row[rhs_col_idx];
                const cast_cell: Cell = switch (source) {
                    .null => Cell.null,
                    .int64 => |v| Cell{ .int64 = v },
                    .uint64 => |v| blk2: {
                        if (v > std.math.maxInt(i64)) {
                            try self.failUserFmt("Overflow exception: Value {d} is not within INT64 range", .{v});
                            unreachable;
                        }
                        break :blk2 Cell{ .int64 = @intCast(v) };
                    },
                    .float64 => |v| Cell{ .int64 = Engine.roundFloatToInt64LikeKuzu(v) },
                    .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                };
                break :blk cast_cell;
            },
        };
        const target = &row[assignment.col_idx];
        target.deinit(self.allocator);
        target.* = new_value;
    }

    fn stringMatchesOp(left: []const u8, right: []const u8, op: FilterOp) bool {
        return switch (op) {
            .eq => std.mem.eql(u8, left, right),
            .neq => !std.mem.eql(u8, left, right),
            .lt => std.mem.lessThan(u8, left, right),
            .lte => std.mem.lessThan(u8, left, right) or std.mem.eql(u8, left, right),
            .gt => std.mem.lessThan(u8, right, left),
            .gte => std.mem.lessThan(u8, right, left) or std.mem.eql(u8, left, right),
        };
    }

    fn intMatchesOp(left: i64, right: i64, op: FilterOp) bool {
        return switch (op) {
            .eq => left == right,
            .neq => left != right,
            .lt => left < right,
            .lte => left <= right,
            .gt => left > right,
            .gte => left >= right,
        };
    }

    fn uintMatchesOp(left: u64, right: u64, op: FilterOp) bool {
        return switch (op) {
            .eq => left == right,
            .neq => left != right,
            .lt => left < right,
            .lte => left <= right,
            .gt => left > right,
            .gte => left >= right,
        };
    }

    fn floatMatchesOp(left: f64, right: f64, op: FilterOp) bool {
        return switch (op) {
            .eq => left == right,
            .neq => left != right,
            .lt => left < right,
            .lte => left <= right,
            .gt => left > right,
            .gte => left >= right,
        };
    }

    fn roundFloatToInt64LikeKuzu(v: f64) i64 {
        const floored_f = @floor(v);
        const ceiled_f = @ceil(v);
        const dist_floor = v - floored_f;
        const dist_ceil = ceiled_f - v;

        if (dist_floor < dist_ceil) return @as(i64, @intFromFloat(floored_f));
        if (dist_ceil < dist_floor) return @as(i64, @intFromFloat(ceiled_f));

        // Tie (.5): round-to-even.
        const floor_i = @as(i64, @intFromFloat(floored_f));
        if (@mod(floor_i, 2) == 0) return floor_i;
        return @as(i64, @intFromFloat(ceiled_f));
    }

    fn cellMatchesValue(cell: Cell, op: FilterOp, value: FilterValue) bool {
        return switch (value) {
            .null => false,
            .string => |s| switch (cell) {
                .string => |cs| stringMatchesOp(cs, s, op),
                else => false,
            },
            .int64 => |v| switch (cell) {
                .int64 => |cv| intMatchesOp(cv, v, op),
                .float64 => |cv| floatMatchesOp(cv, @as(f64, @floatFromInt(v)), op),
                else => false,
            },
            .uint64 => |v| switch (cell) {
                .uint64 => |cv| uintMatchesOp(cv, v, op),
                .float64 => |cv| floatMatchesOp(cv, @floatFromInt(v), op),
                else => false,
            },
            .bool => |b| switch (cell) {
                .int64 => |cv| intMatchesOp(cv, if (b) 1 else 0, op),
                else => false,
            },
            .float64 => |v| switch (cell) {
                .float64 => |cv| floatMatchesOp(cv, v, op),
                .int64 => |cv| intMatchesOp(cv, Engine.roundFloatToInt64LikeKuzu(v), op),
                .uint64 => |cv| floatMatchesOp(@floatFromInt(cv), v, op),
                else => false,
            },
        };
    }

    fn cellMatchesCell(left: Cell, right: Cell, op: FilterOp) bool {
        return switch (left) {
            .string => |ls| switch (right) {
                .string => |rs| stringMatchesOp(ls, rs, op),
                else => false,
            },
            .int64 => |li| switch (right) {
                .int64 => |ri| intMatchesOp(li, ri, op),
                .float64 => |rf| floatMatchesOp(@as(f64, @floatFromInt(li)), rf, op),
                else => false,
            },
            .uint64 => |li| switch (right) {
                .uint64 => |ri| uintMatchesOp(li, ri, op),
                .float64 => |rf| floatMatchesOp(@floatFromInt(li), rf, op),
                else => false,
            },
            .float64 => |lf| switch (right) {
                .float64 => |rf| floatMatchesOp(lf, rf, op),
                .int64 => |ri| floatMatchesOp(lf, @as(f64, @floatFromInt(ri)), op),
                .uint64 => |ri| floatMatchesOp(lf, @floatFromInt(ri), op),
                else => false,
            },
            else => false,
        };
    }

    fn valueMatchesValue(left: FilterValue, right: FilterValue, op: FilterOp) bool {
        return switch (left) {
            .null => false,
            .string => |ls| switch (right) {
                .string => |rs| stringMatchesOp(ls, rs, op),
                .null => false,
                else => false,
            },
            .int64 => |li| switch (right) {
                .int64 => |ri| intMatchesOp(li, ri, op),
                .float64 => |rf| floatMatchesOp(@as(f64, @floatFromInt(li)), rf, op),
                .null => false,
                else => false,
            },
            .uint64 => |li| switch (right) {
                .uint64 => |ri| uintMatchesOp(li, ri, op),
                .float64 => |rf| floatMatchesOp(@floatFromInt(li), rf, op),
                .null => false,
                else => false,
            },
            .bool => |lb| switch (right) {
                .bool => |rb| intMatchesOp(if (lb) 1 else 0, if (rb) 1 else 0, op),
                .null => false,
                else => false,
            },
            .float64 => |lf| switch (right) {
                .float64 => |rf| floatMatchesOp(lf, rf, op),
                .int64 => |ri| floatMatchesOp(lf, @as(f64, @floatFromInt(ri)), op),
                .uint64 => |ri| floatMatchesOp(lf, @floatFromInt(ri), op),
                .null => false,
                else => false,
            },
        };
    }

    fn cellIsNull(cell: Cell) bool {
        return switch (cell) {
            .null => true,
            else => false,
        };
    }

    fn rowMatchesFilter(row: []const Cell, filter: Filter) bool {
        const probe = row[filter.column_idx];
        switch (filter.null_predicate) {
            .is_null => return cellIsNull(probe),
            .is_not_null => return !cellIsNull(probe),
            .none => {},
        }
        return switch (filter.rhs) {
            .literal => |value| cellMatchesValue(probe, filter.op, value),
            .column_idx => |rhs_idx| cellMatchesCell(probe, row[rhs_idx], filter.op),
        };
    }

    fn rowMatchesFilters(row: []const Cell, filters: []const Filter) bool {
        for (filters) |f| {
            if (!rowMatchesFilter(row, f)) return false;
        }
        return true;
    }

    fn rowMatchesFilterGroups(row: []const Cell, groups: []const NodeFilterGroup) bool {
        if (groups.len == 0) return true;
        for (groups) |group| {
            if (rowMatchesFilters(row, group.filters.items)) return true;
        }
        return false;
    }

    fn typeName(ty: ColumnType) []const u8 {
        return switch (ty) {
            .STRING => "STRING",
            .INT8 => "INT8",
            .INT16 => "INT16",
            .INT32 => "INT32",
            .INT64 => "INT64",
            .UINT8 => "UINT8",
            .UINT16 => "UINT16",
            .UINT32 => "UINT32",
            .UINT64 => "UINT64",
            .BOOL => "BOOL",
            .DOUBLE => "DOUBLE",
        };
    }

    fn integerBounds(ty: ColumnType) ?struct { min: i64, max: i64 } {
        return switch (ty) {
            .INT8 => .{ .min = -128, .max = 127 },
            .INT16 => .{ .min = -32768, .max = 32767 },
            .INT32 => .{ .min = -2147483648, .max = 2147483647 },
            .INT64 => .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) },
            .UINT8 => .{ .min = 0, .max = 255 },
            .UINT16 => .{ .min = 0, .max = 65535 },
            .UINT32 => .{ .min = 0, .max = 4294967295 },
            .UINT64 => .{ .min = 0, .max = std.math.maxInt(i64) },
            else => null,
        };
    }

    fn ensureIntegerInTypeRange(self: *Engine, value: i64, ty: ColumnType) !void {
        const bounds = Engine.integerBounds(ty) orelse return;
        if (value < bounds.min or value > bounds.max) {
            try self.failUserFmt("Overflow exception: Value {d} is not within {s} range", .{ value, typeName(ty) });
            unreachable;
        }
    }

    fn ensureUnsignedInTypeRange(self: *Engine, value: u64, ty: ColumnType) !void {
        const max: u64 = switch (ty) {
            .UINT8 => 255,
            .UINT16 => 65535,
            .UINT32 => 4294967295,
            .UINT64 => std.math.maxInt(u64),
            else => return,
        };
        if (value > max) {
            try self.failUserFmt("Overflow exception: Value {d} is not within {s} range", .{ value, typeName(ty) });
            unreachable;
        }
    }

    fn failCountAnyBinderError(self: *Engine, distinct: bool) !void {
        const actual = if (distinct) "DISTINCT (ANY)" else "(ANY)";
        return self.failCountBinderErrorWithActual(actual);
    }

    fn failCountBinderErrorWithActual(self: *Engine, actual: []const u8) !void {
        const expected =
            "DISTINCT (INTERNAL_ID) -> INT64\n" ++
            "          (INTERNAL_ID) -> INT64\n" ++
            "          DISTINCT (BOOL) -> INT64\n" ++
            "          (BOOL) -> INT64\n" ++
            "          DISTINCT (INT64) -> INT64\n" ++
            "          (INT64) -> INT64\n" ++
            "          DISTINCT (INT32) -> INT64\n" ++
            "          (INT32) -> INT64\n" ++
            "          DISTINCT (INT16) -> INT64\n" ++
            "          (INT16) -> INT64\n" ++
            "          DISTINCT (INT8) -> INT64\n" ++
            "          (INT8) -> INT64\n" ++
            "          DISTINCT (UINT64) -> INT64\n" ++
            "          (UINT64) -> INT64\n" ++
            "          DISTINCT (UINT32) -> INT64\n" ++
            "          (UINT32) -> INT64\n" ++
            "          DISTINCT (UINT16) -> INT64\n" ++
            "          (UINT16) -> INT64\n" ++
            "          DISTINCT (UINT8) -> INT64\n" ++
            "          (UINT8) -> INT64\n" ++
            "          DISTINCT (INT128) -> INT64\n" ++
            "          (INT128) -> INT64\n" ++
            "          DISTINCT (DOUBLE) -> INT64\n" ++
            "          (DOUBLE) -> INT64\n" ++
            "          DISTINCT (STRING) -> INT64\n" ++
            "          (STRING) -> INT64\n" ++
            "          DISTINCT (BLOB) -> INT64\n" ++
            "          (BLOB) -> INT64\n" ++
            "          DISTINCT (UUID) -> INT64\n" ++
            "          (UUID) -> INT64\n" ++
            "          DISTINCT (DATE) -> INT64\n" ++
            "          (DATE) -> INT64\n" ++
            "          DISTINCT (TIMESTAMP) -> INT64\n" ++
            "          (TIMESTAMP) -> INT64\n" ++
            "          DISTINCT (TIMESTAMP_NS) -> INT64\n" ++
            "          (TIMESTAMP_NS) -> INT64\n" ++
            "          DISTINCT (TIMESTAMP_MS) -> INT64\n" ++
            "          (TIMESTAMP_MS) -> INT64\n" ++
            "          DISTINCT (TIMESTAMP_SEC) -> INT64\n" ++
            "          (TIMESTAMP_SEC) -> INT64\n" ++
            "          DISTINCT (TIMESTAMP_TZ) -> INT64\n" ++
            "          (TIMESTAMP_TZ) -> INT64\n" ++
            "          DISTINCT (INTERVAL) -> INT64\n" ++
            "          (INTERVAL) -> INT64\n" ++
            "          DISTINCT (LIST) -> INT64\n" ++
            "          (LIST) -> INT64\n" ++
            "          DISTINCT (ARRAY) -> INT64\n" ++
            "          (ARRAY) -> INT64\n" ++
            "          DISTINCT (MAP) -> INT64\n" ++
            "          (MAP) -> INT64\n" ++
            "          DISTINCT (FLOAT) -> INT64\n" ++
            "          (FLOAT) -> INT64\n" ++
            "          DISTINCT (SERIAL) -> INT64\n" ++
            "          (SERIAL) -> INT64\n" ++
            "          DISTINCT (NODE) -> INT64\n" ++
            "          (NODE) -> INT64\n" ++
            "          DISTINCT (REL) -> INT64\n" ++
            "          (REL) -> INT64\n" ++
            "          DISTINCT (RECURSIVE_REL) -> INT64\n" ++
            "          (RECURSIVE_REL) -> INT64\n" ++
            "          DISTINCT (STRUCT) -> INT64\n" ++
            "          (STRUCT) -> INT64\n" ++
            "          DISTINCT (UNION) -> INT64\n" ++
            "          (UNION) -> INT64\n\n";
        try self.failUserFmt(
            "Binder exception: Function COUNT did not receive correct arguments:\nActual:   {s}\nExpected: {s}",
            .{ actual, expected },
        );
        unreachable;
    }

    fn inferCountArgTypeNameNode(
        self: *Engine,
        expr_in: []const u8,
        var_name: []const u8,
        table: *const Table,
        params: ?*const std.json.ObjectMap,
    ) ![]const u8 {
        const expr = std.mem.trim(u8, expr_in, " \t\n\r");
        if (expr.len == 0) return "ANY";
        if (self.parsePropertyExprOptional(expr, var_name)) |col_name| {
            const ty = try self.nodeColumnTypeOrBinderError(table, var_name, col_name);
            return typeName(ty);
        }
        if (expr.len > 0 and expr[0] == '$') {
            const value = try self.getParameterValue(expr, params);
            return switch (value) {
                .null => "ANY",
                .string => "STRING",
                .integer => "INT64",
                .bool => "BOOL",
                .float => "DOUBLE",
                else => "ANY",
            };
        }
        if (std.ascii.eqlIgnoreCase(expr, "true") or std.ascii.eqlIgnoreCase(expr, "false")) return "BOOL";
        const lit = parseLiteral(expr) catch {
            return "ANY";
        };
        return switch (lit) {
            .null => "ANY",
            .string => "STRING",
            .int64 => "INT64",
            .uint64 => "UINT64",
            .bool => "BOOL",
            .float64 => "DOUBLE",
        };
    }

    fn inferCountArgTypeNameRel(
        self: *Engine,
        expr_in: []const u8,
        left_var: []const u8,
        right_var: []const u8,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
        params: ?*const std.json.ObjectMap,
    ) ![]const u8 {
        const expr = std.mem.trim(u8, expr_in, " \t\n\r");
        if (expr.len == 0) return "ANY";
        if (try self.resolveRelProjectionRefOptional(expr, left_var, right_var, rel_var, left_table, right_table, rel_table)) |ref| {
            return switch (ref.source) {
                .left => typeName(left_table.columns.items[ref.col_idx].ty),
                .right => typeName(right_table.columns.items[ref.col_idx].ty),
                .rel => typeName(rel_table.columns.items[ref.col_idx].ty),
            };
        }
        if (expr.len > 0 and expr[0] == '$') {
            const value = try self.getParameterValue(expr, params);
            return switch (value) {
                .null => "ANY",
                .string => "STRING",
                .integer => "INT64",
                .bool => "BOOL",
                .float => "DOUBLE",
                else => "ANY",
            };
        }
        if (std.ascii.eqlIgnoreCase(expr, "true") or std.ascii.eqlIgnoreCase(expr, "false")) return "BOOL";
        const lit = parseLiteral(expr) catch {
            return "ANY";
        };
        return switch (lit) {
            .null => "ANY",
            .string => "STRING",
            .int64 => "INT64",
            .uint64 => "UINT64",
            .bool => "BOOL",
            .float64 => "DOUBLE",
        };
    }

    fn inferParamIntegerTypeName(v: i64) []const u8 {
        if (v < 0) {
            if (v >= -128) return "INT8";
            if (v >= -32768) return "INT16";
            if (v >= -2147483648) return "INT32";
            return "INT64";
        }
        if (v <= 127) return "INT8";
        if (v <= 255) return "UINT8";
        if (v <= 32767) return "INT16";
        if (v <= 65535) return "UINT16";
        if (v <= 2147483647) return "INT32";
        if (v <= 4294967295) return "UINT32";
        return "INT64";
    }

    fn parsePropertyExpr(self: *Engine, expr: []const u8, var_name: []const u8) ![]const u8 {
        const expected_prefix = try std.fmt.allocPrint(self.allocator, "{s}.", .{var_name});
        defer self.allocator.free(expected_prefix);
        const trimmed = std.mem.trim(u8, expr, " \t\n\r");
        if (!std.mem.startsWith(u8, trimmed, expected_prefix)) return error.InvalidReturn;
        return trimmed[expected_prefix.len..];
    }

    fn parsePropertyExprOptional(self: *Engine, expr: []const u8, var_name: []const u8) ?[]const u8 {
        const expected_prefix = std.fmt.allocPrint(self.allocator, "{s}.", .{var_name}) catch return null;
        defer self.allocator.free(expected_prefix);
        const trimmed = std.mem.trim(u8, expr, " \t\n\r");
        if (!std.mem.startsWith(u8, trimmed, expected_prefix)) return null;
        return trimmed[expected_prefix.len..];
    }

    fn parseNodeCountTarget(
        self: *Engine,
        count_expr_in: []const u8,
        var_name: []const u8,
        table: *const Table,
        params: ?*const std.json.ObjectMap,
        distinct: bool,
    ) !NodeCountTarget {
        const count_expr = std.mem.trim(u8, count_expr_in, " \t\n\r");
        if (std.mem.eql(u8, count_expr, "*")) return .star;
        if (std.mem.indexOfScalar(u8, count_expr, ',')) |_| {
            var actual: std.ArrayList(u8) = .{};
            defer actual.deinit(self.allocator);
            try actual.appendSlice(self.allocator, if (distinct) "DISTINCT (" else "(");
            var first = true;
            var it = std.mem.splitScalar(u8, count_expr, ',');
            while (it.next()) |raw_arg| {
                const arg = std.mem.trim(u8, raw_arg, " \t\n\r");
                if (arg.len == 0) return error.InvalidReturn;
                const ty_name = try self.inferCountArgTypeNameNode(arg, var_name, table, params);
                if (!first) try actual.append(self.allocator, ',');
                try actual.appendSlice(self.allocator, ty_name);
                first = false;
            }
            try actual.append(self.allocator, ')');
            const actual_owned = try actual.toOwnedSlice(self.allocator);
            defer self.allocator.free(actual_owned);
            try self.failCountBinderErrorWithActual(actual_owned);
            unreachable;
        }

        if (self.parsePropertyExprOptional(count_expr, var_name)) |col_name| {
            const col_idx = try self.nodeColumnIndexOrBinderError(table, var_name, col_name);
            return .{ .column = col_idx };
        }

        if (count_expr.len > 0 and count_expr[0] == '$') {
            const json_value = try self.getParameterValue(count_expr, params);
            switch (json_value) {
                .null => {
                    try self.failCountAnyBinderError(distinct);
                    unreachable;
                },
                .string, .integer, .bool, .float => return .{ .constant_non_null = true },
                else => return error.UnsupportedParameterType,
            }
        }
        if (std.ascii.eqlIgnoreCase(count_expr, "true") or std.ascii.eqlIgnoreCase(count_expr, "false")) {
            return .{ .constant_non_null = true };
        }

        const literal = parseLiteral(count_expr) catch return error.InvalidReturn;
        return .{
            .constant_non_null = switch (literal) {
                .null => {
                    try self.failCountAnyBinderError(distinct);
                    unreachable;
                },
                else => true,
            },
        };
    }

    fn nodeCountTargetIncludes(target: NodeCountTarget, row: []const Cell) bool {
        return switch (target) {
            .star => true,
            .column => |col_idx| !cellIsNull(row[col_idx]),
            .constant_non_null => |flag| flag,
        };
    }

    fn appendNodeCountDistinctKey(
        self: *Engine,
        target: NodeCountTarget,
        row: []const Cell,
        key_buf: *std.ArrayList(u8),
    ) !bool {
        switch (target) {
            .star => return error.InvalidReturn,
            .column => |col_idx| {
                const cell = row[col_idx];
                if (cellIsNull(cell)) return false;
                try Engine.appendCellToGroupKey(self.allocator, key_buf, cell);
                return true;
            },
            .constant_non_null => |flag| {
                if (!flag) return false;
                try key_buf.appendSlice(self.allocator, "CONST|");
                return true;
            },
        }
    }

    fn parseRelCountTarget(
        self: *Engine,
        count_expr_in: []const u8,
        left_var: []const u8,
        right_var: []const u8,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
        params: ?*const std.json.ObjectMap,
        distinct: bool,
    ) !RelCountTarget {
        const count_expr = std.mem.trim(u8, count_expr_in, " \t\n\r");
        if (std.mem.eql(u8, count_expr, "*")) return .star;
        if (std.mem.indexOfScalar(u8, count_expr, ',')) |_| {
            var actual: std.ArrayList(u8) = .{};
            defer actual.deinit(self.allocator);
            try actual.appendSlice(self.allocator, if (distinct) "DISTINCT (" else "(");
            var first = true;
            var it = std.mem.splitScalar(u8, count_expr, ',');
            while (it.next()) |raw_arg| {
                const arg = std.mem.trim(u8, raw_arg, " \t\n\r");
                if (arg.len == 0) return error.InvalidReturn;
                const ty_name = try self.inferCountArgTypeNameRel(
                    arg,
                    left_var,
                    right_var,
                    rel_var,
                    left_table,
                    right_table,
                    rel_table,
                    params,
                );
                if (!first) try actual.append(self.allocator, ',');
                try actual.appendSlice(self.allocator, ty_name);
                first = false;
            }
            try actual.append(self.allocator, ')');
            const actual_owned = try actual.toOwnedSlice(self.allocator);
            defer self.allocator.free(actual_owned);
            try self.failCountBinderErrorWithActual(actual_owned);
            unreachable;
        }

        if (try self.resolveRelProjectionRefOptional(count_expr, left_var, right_var, rel_var, left_table, right_table, rel_table)) |ref| {
            return .{ .ref = ref };
        }
        if (Engine.isIdentifierToken(count_expr)) {
            if (std.mem.eql(u8, count_expr, left_var)) {
                const pk_name = left_table.primary_key orelse return .{ .constant_non_null = true };
                const col_idx = try self.nodeColumnIndexOrBinderError(left_table, left_var, pk_name);
                return .{ .ref = .{ .source = .left, .col_idx = col_idx } };
            }
            if (std.mem.eql(u8, count_expr, right_var)) {
                const pk_name = right_table.primary_key orelse return .{ .constant_non_null = true };
                const col_idx = try self.nodeColumnIndexOrBinderError(right_table, right_var, pk_name);
                return .{ .ref = .{ .source = .right, .col_idx = col_idx } };
            }
            if (std.mem.eql(u8, count_expr, rel_var)) {
                if (!distinct) {
                    return .{ .constant_non_null = true };
                }
            }
        }

        if (count_expr.len > 0 and count_expr[0] == '$') {
            const json_value = try self.getParameterValue(count_expr, params);
            switch (json_value) {
                .null => {
                    try self.failCountAnyBinderError(distinct);
                    unreachable;
                },
                .string, .integer, .bool, .float => return .{ .constant_non_null = true },
                else => return error.UnsupportedParameterType,
            }
        }
        if (std.ascii.eqlIgnoreCase(count_expr, "true") or std.ascii.eqlIgnoreCase(count_expr, "false")) {
            return .{ .constant_non_null = true };
        }

        const literal = parseLiteral(count_expr) catch return error.InvalidReturn;
        return .{
            .constant_non_null = switch (literal) {
                .null => {
                    try self.failCountAnyBinderError(distinct);
                    unreachable;
                },
                else => true,
            },
        };
    }

    fn relCountTargetIncludes(target: RelCountTarget, left_row: []const Cell, right_row: []const Cell, rel_props: []const Cell) bool {
        return switch (target) {
            .star => true,
            .ref => |ref| !cellIsNull(Engine.relCellFor(ref, left_row, right_row, rel_props)),
            .constant_non_null => |flag| flag,
        };
    }

    fn appendRelCountDistinctKey(
        self: *Engine,
        target: RelCountTarget,
        left_row: []const Cell,
        right_row: []const Cell,
        rel_props: []const Cell,
        key_buf: *std.ArrayList(u8),
    ) !bool {
        switch (target) {
            .star => return error.InvalidReturn,
            .ref => |ref| {
                const cell = Engine.relCellFor(ref, left_row, right_row, rel_props);
                if (cellIsNull(cell)) return false;
                try Engine.appendCellToGroupKey(self.allocator, key_buf, cell);
                return true;
            },
            .constant_non_null => |flag| {
                if (!flag) return false;
                try key_buf.appendSlice(self.allocator, "CONST|");
                return true;
            },
        }
    }

    fn isNoOpOrderTerm(expr_in: []const u8) bool {
        const trimmed = std.mem.trim(u8, expr_in, " \t\n\r");
        if (trimmed.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(trimmed, "true") or std.ascii.eqlIgnoreCase(trimmed, "false")) {
            return true;
        }
        if (parseLiteral(trimmed)) |_| {
            return true;
        } else |_| {}
        if (trimmed[0] == '$') return true;
        if (std.fmt.parseFloat(f64, trimmed)) |_| {
            return true;
        } else |_| {}
        return false;
    }

    fn parseNodeOrderKeys(
        self: *Engine,
        table: *const Table,
        var_name: []const u8,
        order_text: []const u8,
        aliases: []const NodeOrderAlias,
        out_keys: *std.ArrayList(NodeOrderKey),
    ) !void {
        var it = std.mem.splitScalar(u8, order_text, ',');
        while (it.next()) |raw| {
            const term = try parseOrderTerm(raw);
            var col_idx_opt: ?usize = null;
            for (aliases) |alias| {
                if (std.mem.eql(u8, alias.alias, term.expr)) {
                    col_idx_opt = alias.col_idx;
                    break;
                }
            }
            if (col_idx_opt == null and Engine.isNoOpOrderTerm(term.expr)) continue;
            const col_idx = col_idx_opt orelse blk: {
                const col_name = self.parsePropertyExpr(term.expr, var_name) catch {
                    if (Engine.scopeVariableForUnknownExpr(term.expr)) |unknown_var| {
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                        unreachable;
                    }
                    return error.InvalidReturn;
                };
                break :blk try self.nodeColumnIndexOrBinderError(table, var_name, col_name);
            };
            try out_keys.append(self.allocator, .{ .col_idx = col_idx, .desc = term.desc });
        }
    }

    fn parseRelOrderKeys(
        self: *Engine,
        order_text: []const u8,
        left_var: []const u8,
        right_var: []const u8,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
        aliases: []const RelOrderAlias,
        out_keys: *std.ArrayList(RelOrderKey),
    ) !void {
        var it = std.mem.splitScalar(u8, order_text, ',');
        while (it.next()) |raw| {
            const term = try parseOrderTerm(raw);
            var ref_opt: ?ProjRef = null;
            for (aliases) |alias| {
                if (std.mem.eql(u8, alias.alias, term.expr)) {
                    ref_opt = alias.ref;
                    break;
                }
            }
            if (ref_opt == null and Engine.isNoOpOrderTerm(term.expr)) continue;
            const ref = ref_opt orelse blk: {
                const resolved = self.resolveRelProjectionRef(term.expr, left_var, right_var, rel_var, left_table, right_table, rel_table) catch |err| {
                    if (err == error.UserVisibleError) return err;
                    if (Engine.scopeVariableForUnknownExpr(term.expr)) |unknown_var| {
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                        unreachable;
                    }
                    return error.InvalidReturn;
                };
                break :blk resolved.ref;
            };
            try out_keys.append(self.allocator, .{ .ref = ref, .desc = term.desc });
        }
    }

    fn parseOutputOrderKeys(
        self: *Engine,
        order_text: []const u8,
        columns: []const []u8,
        column_types: []const []const u8,
        out_keys: *std.ArrayList(OutputOrderKey),
    ) !void {
        var it = std.mem.splitScalar(u8, order_text, ',');
        while (it.next()) |raw| {
            const term = try parseOrderTerm(raw);
            var col_idx_opt: ?usize = null;
            for (columns, 0..) |name, idx| {
                if (std.mem.eql(u8, name, term.expr)) {
                    col_idx_opt = idx;
                    break;
                }
            }
            if (col_idx_opt == null and Engine.isNoOpOrderTerm(term.expr)) continue;
            if (col_idx_opt == null) {
                if (try parseCountTermExpr(term.expr)) |count_term| {
                    const normalized = try self.formatCountOutputName(count_term.count_expr, count_term.distinct);
                    defer self.allocator.free(normalized);
                    for (columns, 0..) |name, idx| {
                        if (std.mem.eql(u8, name, normalized)) {
                            col_idx_opt = idx;
                            break;
                        }
                    }

                    if (col_idx_opt == null) {
                        if (std.mem.indexOfScalar(u8, count_term.count_expr, '.')) |dot_idx| {
                            const var_name = std.mem.trim(u8, count_term.count_expr[0..dot_idx], " \t\n\r");
                            if (var_name.len > 0 and std.mem.indexOfAny(u8, var_name, " \t\n\r") == null) {
                                return self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{var_name});
                            }
                        }
                        return self.failUserMessage("Cannot evaluate expression with type AGGREGATE_FUNCTION.");
                    }
                }
            }
            if (col_idx_opt == null) {
                if (Engine.parsePropertyAccessExpr(term.expr)) |property_expr| {
                    for (columns, 0..) |name, idx| {
                        if (std.mem.eql(u8, name, property_expr.var_name)) {
                            const ty_name = if (idx < column_types.len) column_types[idx] else "ANY";
                            try self.failPropertyAccessTypeMismatch(property_expr.var_name, ty_name);
                            unreachable;
                        }
                    }
                }
            }
            if (col_idx_opt == null) {
                if (Engine.scopeVariableForUnknownExpr(term.expr)) |unknown_var| {
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                    unreachable;
                }
            }
            const col_idx = col_idx_opt orelse return error.InvalidReturn;
            try out_keys.append(self.allocator, .{ .col_idx = col_idx, .desc = term.desc });
        }
    }

    fn resolveRelProjectionRef(
        self: *Engine,
        expr: []const u8,
        left_var: []const u8,
        right_var: []const u8,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
    ) !struct { ref: ProjRef, ty: ColumnType } {
        if (self.parsePropertyExprOptional(expr, left_var)) |col_name| {
            const col_idx = try self.nodeColumnIndexOrBinderError(left_table, left_var, col_name);
            return .{ .ref = .{ .source = .left, .col_idx = col_idx }, .ty = try self.nodeColumnTypeOrBinderError(left_table, left_var, col_name) };
        }
        if (self.parsePropertyExprOptional(expr, right_var)) |col_name| {
            const col_idx = try self.nodeColumnIndexOrBinderError(right_table, right_var, col_name);
            return .{ .ref = .{ .source = .right, .col_idx = col_idx }, .ty = try self.nodeColumnTypeOrBinderError(right_table, right_var, col_name) };
        }
        if (self.parsePropertyExprOptional(expr, rel_var)) |col_name| {
            const col_idx = try self.relColumnIndexOrBinderError(rel_table, rel_var, col_name);
            return .{ .ref = .{ .source = .rel, .col_idx = col_idx }, .ty = try self.relColumnTypeOrBinderError(rel_table, rel_var, col_name) };
        }
        if (Engine.parsePropertyAccessExpr(expr)) |property_expr| {
            if (!std.mem.eql(u8, property_expr.var_name, left_var) and
                !std.mem.eql(u8, property_expr.var_name, right_var) and
                !std.mem.eql(u8, property_expr.var_name, rel_var))
            {
                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                unreachable;
            }
        }
        return error.InvalidReturn;
    }

    fn resolveRelProjectionRefOptional(
        self: *Engine,
        expr: []const u8,
        left_var: []const u8,
        right_var: []const u8,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
    ) !?ProjRef {
        if (self.parsePropertyExprOptional(expr, left_var)) |col_name| {
            const col_idx = try self.nodeColumnIndexOrBinderError(left_table, left_var, col_name);
            return .{ .source = .left, .col_idx = col_idx };
        }
        if (self.parsePropertyExprOptional(expr, right_var)) |col_name| {
            const col_idx = try self.nodeColumnIndexOrBinderError(right_table, right_var, col_name);
            return .{ .source = .right, .col_idx = col_idx };
        }
        if (self.parsePropertyExprOptional(expr, rel_var)) |col_name| {
            const col_idx = try self.relColumnIndexOrBinderError(rel_table, rel_var, col_name);
            return .{ .source = .rel, .col_idx = col_idx };
        }
        return null;
    }

    fn parseRelFilterCondition(
        self: *Engine,
        clause: []const u8,
        params: ?*const std.json.ObjectMap,
        left_var: []const u8,
        right_var: []const u8,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
    ) !RelFilter {
        const norm = try normalizeComparisonClauseForNot(clause);
        if (parseNullPredicateClause(norm.clause)) |null_clause| {
            if (try self.resolveRelProjectionRefOptional(
                null_clause.expr,
                left_var,
                right_var,
                rel_var,
                left_table,
                right_table,
                rel_table,
            )) |key| {
                var pred: NullPredicate = if (null_clause.is_null) .is_null else .is_not_null;
                if (norm.negate) {
                    pred = switch (pred) {
                        .is_null => .is_not_null,
                        .is_not_null => .is_null,
                        .none => .none,
                    };
                }
                return .{
                    .key = key,
                    .op = .eq,
                    .rhs = .{ .literal = .null },
                    .null_predicate = pred,
                };
            }
            if (Engine.parsePropertyAccessExpr(null_clause.expr)) |property_expr| {
                if (!std.mem.eql(u8, property_expr.var_name, left_var) and
                    !std.mem.eql(u8, property_expr.var_name, right_var) and
                    !std.mem.eql(u8, property_expr.var_name, rel_var))
                {
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                    unreachable;
                }
            }
            return error.InvalidWhere;
        }

        const cmp = try parseComparisonClause(norm.clause);
        var op = if (norm.negate) invertFilterOp(cmp.op) else cmp.op;

        const lhs_ref = try self.resolveRelProjectionRefOptional(
            cmp.lhs,
            left_var,
            right_var,
            rel_var,
            left_table,
            right_table,
            rel_table,
        );
        const rhs_ref = try self.resolveRelProjectionRefOptional(
            cmp.rhs,
            left_var,
            right_var,
            rel_var,
            left_table,
            right_table,
            rel_table,
        );

        if (lhs_ref) |lhs| {
            if (rhs_ref) |rhs| {
                return .{
                    .key = lhs,
                    .op = op,
                    .rhs = .{ .ref = rhs },
                };
            }
            return .{
                .key = lhs,
                .op = op,
                .rhs = .{ .literal = try self.parseFilterValue(cmp.rhs, params) },
            };
        }

        if (rhs_ref) |rhs| {
            op = reverseFilterOp(op);
            return .{
                .key = rhs,
                .op = op,
                .rhs = .{ .literal = try self.parseFilterValue(cmp.lhs, params) },
            };
        }

        if (Engine.parsePropertyAccessExpr(cmp.lhs)) |property_expr| {
            if (!std.mem.eql(u8, property_expr.var_name, left_var) and
                !std.mem.eql(u8, property_expr.var_name, right_var) and
                !std.mem.eql(u8, property_expr.var_name, rel_var))
            {
                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                unreachable;
            }
        }
        if (Engine.parsePropertyAccessExpr(cmp.rhs)) |property_expr| {
            if (!std.mem.eql(u8, property_expr.var_name, left_var) and
                !std.mem.eql(u8, property_expr.var_name, right_var) and
                !std.mem.eql(u8, property_expr.var_name, rel_var))
            {
                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                unreachable;
            }
        }

        return error.InvalidWhere;
    }

    fn parseRelFilterGroups(
        self: *Engine,
        where_text: []const u8,
        params: ?*const std.json.ObjectMap,
        left_var: []const u8,
        right_var: []const u8,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
        out_groups: *std.ArrayList(RelFilterGroup),
    ) !void {
        var or_it = std.mem.splitSequence(u8, where_text, " OR ");
        while (or_it.next()) |raw_or| {
            const disj = std.mem.trim(u8, raw_or, " \t\n\r");
            if (disj.len == 0) return error.InvalidWhere;

            var group: RelFilterGroup = .{ .filters = .{} };
            errdefer group.deinit(self.allocator);

            var and_it = std.mem.splitSequence(u8, disj, " AND ");
            while (and_it.next()) |raw_and| {
                const clause = std.mem.trim(u8, raw_and, " \t\n\r");
                if (clause.len == 0) return error.InvalidWhere;
                try group.filters.append(
                    self.allocator,
                    try self.parseRelFilterCondition(clause, params, left_var, right_var, rel_var, left_table, right_table, rel_table),
                );
            }

            try out_groups.append(self.allocator, group);
        }
    }

    fn parseMatchCreateFilterGroups(
        self: *Engine,
        left_table: *const Table,
        right_table: *const Table,
        left_var: []const u8,
        right_var: []const u8,
        where_text: []const u8,
        params: ?*const std.json.ObjectMap,
        out_groups: *std.ArrayList(MatchCreateFilterGroup),
    ) !void {
        var or_it = std.mem.splitSequence(u8, where_text, " OR ");
        while (or_it.next()) |raw_or| {
            const disj = std.mem.trim(u8, raw_or, " \t\n\r");
            if (disj.len == 0) return error.InvalidWhere;

            var group: MatchCreateFilterGroup = .{
                .left_filters = .{},
                .right_filters = .{},
            };
            errdefer group.deinit(self.allocator);

            var and_it = std.mem.splitSequence(u8, disj, " AND ");
            while (and_it.next()) |raw_and| {
                const clause = std.mem.trim(u8, raw_and, " \t\n\r");
                if (clause.len == 0) return error.InvalidWhere;

                const norm = try normalizeComparisonClauseForNot(clause);
                const cmp = try parseComparisonClause(norm.clause);
                const touches_left = self.parsePropertyExprOptional(cmp.lhs, left_var) != null or
                    self.parsePropertyExprOptional(cmp.rhs, left_var) != null;
                if (touches_left) {
                    try group.left_filters.append(self.allocator, try self.parseFilter(left_table, left_var, clause, params));
                    continue;
                }
                const touches_right = self.parsePropertyExprOptional(cmp.lhs, right_var) != null or
                    self.parsePropertyExprOptional(cmp.rhs, right_var) != null;
                if (touches_right) {
                    try group.right_filters.append(self.allocator, try self.parseFilter(right_table, right_var, clause, params));
                    continue;
                }
                return error.InvalidWhere;
            }

            try out_groups.append(self.allocator, group);
        }
    }

    fn matchCreatePairMatchesGroups(left_row: []const Cell, right_row: []const Cell, groups: []const MatchCreateFilterGroup) bool {
        if (groups.len == 0) return true;
        for (groups) |group| {
            if (!rowMatchesFilters(left_row, group.left_filters.items)) continue;
            if (!rowMatchesFilters(right_row, group.right_filters.items)) continue;
            return true;
        }
        return false;
    }

    fn isExprBoundaryChar(c: u8) bool {
        return std.ascii.isWhitespace(c) or c == '(' or c == ')';
    }

    fn keywordAtExpr(text: []const u8, pos: usize, kw: []const u8) bool {
        if (pos + kw.len > text.len) return false;
        if (!std.ascii.eqlIgnoreCase(text[pos .. pos + kw.len], kw)) return false;
        if (pos > 0 and !isExprBoundaryChar(text[pos - 1])) return false;
        const end = pos + kw.len;
        if (end < text.len and !isExprBoundaryChar(text[end])) return false;
        return true;
    }

    fn skipExprSpaces(text: []const u8, pos: *usize) void {
        while (pos.* < text.len and std.ascii.isWhitespace(text[pos.*])) : (pos.* += 1) {}
    }

    fn consumeExprKeyword(text: []const u8, pos: *usize, kw: []const u8) bool {
        skipExprSpaces(text, pos);
        if (!keywordAtExpr(text, pos.*, kw)) return false;
        pos.* += kw.len;
        return true;
    }

    fn consumeExprChar(text: []const u8, pos: *usize, ch: u8) bool {
        skipExprSpaces(text, pos);
        if (pos.* >= text.len or text[pos.*] != ch) return false;
        pos.* += 1;
        return true;
    }

    fn parseExprClauseSlice(text: []const u8, pos: *usize) ![]const u8 {
        skipExprSpaces(text, pos);
        const start = pos.*;
        if (start >= text.len) return error.InvalidWhere;

        var in_string = false;
        var nested_paren_depth: usize = 0;
        while (pos.* < text.len) {
            const c = text[pos.*];
            if (c == '\'') {
                in_string = !in_string;
                pos.* += 1;
                continue;
            }

            if (!in_string) {
                if (c == '(') {
                    nested_paren_depth += 1;
                    pos.* += 1;
                    continue;
                }
                if (c == ')') {
                    if (nested_paren_depth == 0) break;
                    nested_paren_depth -= 1;
                    pos.* += 1;
                    continue;
                }
                if (nested_paren_depth == 0 and (keywordAtExpr(text, pos.*, "AND") or keywordAtExpr(text, pos.*, "OR"))) break;
            }

            pos.* += 1;
        }

        if (in_string or nested_paren_depth != 0) return error.InvalidWhere;
        const clause = std.mem.trim(u8, text[start..pos.*], " \t\n\r");
        if (clause.len == 0) return error.InvalidWhere;
        return clause;
    }

    fn parseParenthesizedSingleClauseAt(text: []const u8, start_pos: usize) !?struct { clause: []const u8, next_pos: usize } {
        var pos = start_pos;
        skipExprSpaces(text, &pos);
        if (pos >= text.len or text[pos] != '(') return null;
        pos += 1;

        const clause = parseExprClauseSlice(text, &pos) catch return null;
        skipExprSpaces(text, &pos);
        if (pos >= text.len or text[pos] != ')') return null;
        pos += 1;
        return .{ .clause = clause, .next_pos = pos };
    }

    const NodeWhereEvalState = struct {
        text: []const u8,
        pos: usize,
        table: *const Table,
        var_name: []const u8,
        params: ?*const std.json.ObjectMap,
        row: []const Cell,
    };

    fn parseNodeWherePrimary(self: *Engine, st: *NodeWhereEvalState) anyerror!bool {
        if (consumeExprKeyword(st.text, &st.pos, "NOT")) {
            if (try parseParenthesizedSingleClauseAt(st.text, st.pos)) |paren_clause| {
                if (std.mem.indexOfScalar(u8, paren_clause.clause, '$') != null) {
                    st.pos = paren_clause.next_pos;
                    return self.evaluateConstantWhereClause(paren_clause.clause, st.params);
                }
            }
            var probe_pos = st.pos;
            skipExprSpaces(st.text, &probe_pos);
            if (probe_pos < st.text.len and st.text[probe_pos] != '(') {
                const clause = try parseExprClauseSlice(st.text, &st.pos);
                const filter = self.parseFilter(st.table, st.var_name, clause, st.params) catch |err| switch (err) {
                    error.InvalidWhere => {
                        if (std.mem.indexOfScalar(u8, clause, '$') != null) {
                            return self.evaluateConstantWhereClause(clause, st.params);
                        }
                        return !(try self.evaluateConstantWhereClause(clause, st.params));
                    },
                    else => return err,
                };
                return !rowMatchesFilter(st.row, filter);
            }
            return !(try self.parseNodeWherePrimary(st));
        }
        if (consumeExprChar(st.text, &st.pos, '(')) {
            const v = try self.parseNodeWhereOr(st);
            if (!consumeExprChar(st.text, &st.pos, ')')) return error.InvalidWhere;
            return v;
        }

        const clause = try parseExprClauseSlice(st.text, &st.pos);
        const filter = self.parseFilter(st.table, st.var_name, clause, st.params) catch |err| switch (err) {
            error.InvalidWhere => {
                return self.evaluateConstantWhereClause(clause, st.params);
            },
            else => return err,
        };
        return rowMatchesFilter(st.row, filter);
    }

    fn parseNodeWhereAnd(self: *Engine, st: *NodeWhereEvalState) anyerror!bool {
        var left = try self.parseNodeWherePrimary(st);
        while (consumeExprKeyword(st.text, &st.pos, "AND")) {
            const right = try self.parseNodeWherePrimary(st);
            left = left and right;
        }
        return left;
    }

    fn parseNodeWhereOr(self: *Engine, st: *NodeWhereEvalState) anyerror!bool {
        var left = try self.parseNodeWhereAnd(st);
        while (consumeExprKeyword(st.text, &st.pos, "OR")) {
            const right = try self.parseNodeWhereAnd(st);
            left = left or right;
        }
        return left;
    }

    fn evaluateNodeWhereExpression(
        self: *Engine,
        table: *const Table,
        var_name: []const u8,
        where_text: []const u8,
        params: ?*const std.json.ObjectMap,
        row: []const Cell,
    ) !bool {
        var st = NodeWhereEvalState{
            .text = where_text,
            .pos = 0,
            .table = table,
            .var_name = var_name,
            .params = params,
            .row = row,
        };
        const out = try self.parseNodeWhereOr(&st);
        skipExprSpaces(st.text, &st.pos);
        if (st.pos != st.text.len) return error.InvalidWhere;
        return out;
    }

    const RelWhereEvalState = struct {
        text: []const u8,
        pos: usize,
        params: ?*const std.json.ObjectMap,
        left_var: []const u8,
        right_var: []const u8,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
        left_row: []const Cell,
        right_row: []const Cell,
        rel_props: []const Cell,
    };

    fn parseRelWherePrimary(self: *Engine, st: *RelWhereEvalState) anyerror!bool {
        if (consumeExprKeyword(st.text, &st.pos, "NOT")) {
            if (try parseParenthesizedSingleClauseAt(st.text, st.pos)) |paren_clause| {
                if (std.mem.indexOfScalar(u8, paren_clause.clause, '$') != null) {
                    st.pos = paren_clause.next_pos;
                    return self.evaluateConstantWhereClause(paren_clause.clause, st.params);
                }
            }
            var probe_pos = st.pos;
            skipExprSpaces(st.text, &probe_pos);
            if (probe_pos < st.text.len and st.text[probe_pos] != '(') {
                const clause = try parseExprClauseSlice(st.text, &st.pos);
                const filter = self.parseRelFilterCondition(
                    clause,
                    st.params,
                    st.left_var,
                    st.right_var,
                    st.rel_var,
                    st.left_table,
                    st.right_table,
                    st.rel_table,
                ) catch |err| switch (err) {
                    error.InvalidWhere => {
                        if (std.mem.indexOfScalar(u8, clause, '$') != null) {
                            return self.evaluateConstantWhereClause(clause, st.params);
                        }
                        return !(try self.evaluateConstantWhereClause(clause, st.params));
                    },
                    else => return err,
                };
                const probe = relCellFor(filter.key, st.left_row, st.right_row, st.rel_props);
                const match = switch (filter.null_predicate) {
                    .is_null => cellIsNull(probe),
                    .is_not_null => !cellIsNull(probe),
                    .none => switch (filter.rhs) {
                        .literal => |value| cellMatchesValue(probe, filter.op, value),
                        .ref => |rhs_ref| cellMatchesCell(probe, relCellFor(rhs_ref, st.left_row, st.right_row, st.rel_props), filter.op),
                    },
                };
                return !match;
            }
            return !(try self.parseRelWherePrimary(st));
        }
        if (consumeExprChar(st.text, &st.pos, '(')) {
            const v = try self.parseRelWhereOr(st);
            if (!consumeExprChar(st.text, &st.pos, ')')) return error.InvalidWhere;
            return v;
        }

        const clause = try parseExprClauseSlice(st.text, &st.pos);
        const filter = self.parseRelFilterCondition(
            clause,
            st.params,
            st.left_var,
            st.right_var,
            st.rel_var,
            st.left_table,
            st.right_table,
            st.rel_table,
        ) catch |err| switch (err) {
            error.InvalidWhere => {
                return self.evaluateConstantWhereClause(clause, st.params);
            },
            else => return err,
        };
        const probe = relCellFor(filter.key, st.left_row, st.right_row, st.rel_props);
        switch (filter.null_predicate) {
            .is_null => return cellIsNull(probe),
            .is_not_null => return !cellIsNull(probe),
            .none => {},
        }
        return switch (filter.rhs) {
            .literal => |value| cellMatchesValue(probe, filter.op, value),
            .ref => |rhs_ref| cellMatchesCell(probe, relCellFor(rhs_ref, st.left_row, st.right_row, st.rel_props), filter.op),
        };
    }

    fn parseRelWhereAnd(self: *Engine, st: *RelWhereEvalState) anyerror!bool {
        var left = try self.parseRelWherePrimary(st);
        while (consumeExprKeyword(st.text, &st.pos, "AND")) {
            const right = try self.parseRelWherePrimary(st);
            left = left and right;
        }
        return left;
    }

    fn parseRelWhereOr(self: *Engine, st: *RelWhereEvalState) anyerror!bool {
        var left = try self.parseRelWhereAnd(st);
        while (consumeExprKeyword(st.text, &st.pos, "OR")) {
            const right = try self.parseRelWhereAnd(st);
            left = left or right;
        }
        return left;
    }

    fn evaluateRelWhereExpression(
        self: *Engine,
        where_text: []const u8,
        params: ?*const std.json.ObjectMap,
        left_var: []const u8,
        right_var: []const u8,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
        left_row: []const Cell,
        right_row: []const Cell,
        rel_props: []const Cell,
    ) !bool {
        var st = RelWhereEvalState{
            .text = where_text,
            .pos = 0,
            .params = params,
            .left_var = left_var,
            .right_var = right_var,
            .rel_var = rel_var,
            .left_table = left_table,
            .right_table = right_table,
            .rel_table = rel_table,
            .left_row = left_row,
            .right_row = right_row,
            .rel_props = rel_props,
        };
        const out = try self.parseRelWhereOr(&st);
        skipExprSpaces(st.text, &st.pos);
        if (st.pos != st.text.len) return error.InvalidWhere;
        return out;
    }

const MatchCreateWhereEvalState = struct {
    text: []const u8,
    pos: usize,
    params: ?*const std.json.ObjectMap,
        left_var: []const u8,
        right_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        left_row: []const Cell,
    right_row: []const Cell,
};

const MatchCreateMultiWhereBinding = struct {
    var_name: []const u8,
    table: *const Table,
    row: []const Cell,
};

const MatchCreateMultiWhereOperand = union(enum) {
    col_ref: struct {
        binding_idx: usize,
        col_idx: usize,
    },
    literal: FilterValue,
};

const MatchCreateMultiWhereEvalState = struct {
    text: []const u8,
    pos: usize,
    params: ?*const std.json.ObjectMap,
    bindings: []const MatchCreateMultiWhereBinding,
};

    fn parseMatchCreateOperand(
        self: *Engine,
        expr: []const u8,
        params: ?*const std.json.ObjectMap,
        left_var: []const u8,
        right_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
    ) !MatchCreateOperand {
        if (self.parsePropertyExprOptional(expr, left_var)) |col_name| {
            const col_idx = try self.nodeColumnIndexOrBinderError(left_table, left_var, col_name);
            return .{ .left_col = col_idx };
        }
        if (self.parsePropertyExprOptional(expr, right_var)) |col_name| {
            const col_idx = try self.nodeColumnIndexOrBinderError(right_table, right_var, col_name);
            return .{ .right_col = col_idx };
        }
        return .{ .literal = try self.parseFilterValue(expr, params) };
    }

    fn evaluateMatchCreateComparison(
        lhs: MatchCreateOperand,
        rhs: MatchCreateOperand,
        op: FilterOp,
        left_row: []const Cell,
        right_row: []const Cell,
    ) bool {
        return switch (lhs) {
            .left_col => |lhs_idx| switch (rhs) {
                .left_col => |rhs_idx| cellMatchesCell(left_row[lhs_idx], left_row[rhs_idx], op),
                .right_col => |rhs_idx| cellMatchesCell(left_row[lhs_idx], right_row[rhs_idx], op),
                .literal => |rhs_value| cellMatchesValue(left_row[lhs_idx], op, rhs_value),
            },
            .right_col => |lhs_idx| switch (rhs) {
                .left_col => |rhs_idx| cellMatchesCell(right_row[lhs_idx], left_row[rhs_idx], op),
                .right_col => |rhs_idx| cellMatchesCell(right_row[lhs_idx], right_row[rhs_idx], op),
                .literal => |rhs_value| cellMatchesValue(right_row[lhs_idx], op, rhs_value),
            },
            .literal => |lhs_value| switch (rhs) {
                .left_col => |rhs_idx| cellMatchesValue(left_row[rhs_idx], reverseFilterOp(op), lhs_value),
                .right_col => |rhs_idx| cellMatchesValue(right_row[rhs_idx], reverseFilterOp(op), lhs_value),
                .literal => |rhs_value| valueMatchesValue(lhs_value, rhs_value, op),
            },
        };
    }

    fn parseMatchCreateWherePrimary(self: *Engine, st: *MatchCreateWhereEvalState) anyerror!bool {
        if (consumeExprKeyword(st.text, &st.pos, "NOT")) {
            return !(try self.parseMatchCreateWherePrimary(st));
        }
        if (consumeExprChar(st.text, &st.pos, '(')) {
            const v = try self.parseMatchCreateWhereOr(st);
            if (!consumeExprChar(st.text, &st.pos, ')')) return error.InvalidWhere;
            return v;
        }

        const clause = try parseExprClauseSlice(st.text, &st.pos);
        const norm = try normalizeComparisonClauseForNot(clause);
        if (parseNullPredicateClause(norm.clause)) |null_clause| {
            const operand = try self.parseMatchCreateOperand(
                null_clause.expr,
                st.params,
                st.left_var,
                st.right_var,
                st.left_table,
                st.right_table,
            );

            var is_null = null_clause.is_null;
            if (norm.negate) is_null = !is_null;

            return switch (operand) {
                .left_col => |idx| if (is_null) cellIsNull(st.left_row[idx]) else !cellIsNull(st.left_row[idx]),
                .right_col => |idx| if (is_null) cellIsNull(st.right_row[idx]) else !cellIsNull(st.right_row[idx]),
                .literal => self.evaluateConstantWhereClause(clause, st.params),
            };
        }

        const cmp = try parseComparisonClause(norm.clause);
        const op = if (norm.negate) invertFilterOp(cmp.op) else cmp.op;
        const lhs = try self.parseMatchCreateOperand(cmp.lhs, st.params, st.left_var, st.right_var, st.left_table, st.right_table);
        const rhs = try self.parseMatchCreateOperand(cmp.rhs, st.params, st.left_var, st.right_var, st.left_table, st.right_table);
        return evaluateMatchCreateComparison(lhs, rhs, op, st.left_row, st.right_row);
    }

    fn parseMatchCreateWhereAnd(self: *Engine, st: *MatchCreateWhereEvalState) anyerror!bool {
        var left = try self.parseMatchCreateWherePrimary(st);
        while (consumeExprKeyword(st.text, &st.pos, "AND")) {
            const right = try self.parseMatchCreateWherePrimary(st);
            left = left and right;
        }
        return left;
    }

    fn parseMatchCreateWhereOr(self: *Engine, st: *MatchCreateWhereEvalState) anyerror!bool {
        var left = try self.parseMatchCreateWhereAnd(st);
        while (consumeExprKeyword(st.text, &st.pos, "OR")) {
            const right = try self.parseMatchCreateWhereAnd(st);
            left = left or right;
        }
        return left;
    }

    fn evaluateMatchCreateWhereExpression(
        self: *Engine,
        where_text: []const u8,
        params: ?*const std.json.ObjectMap,
        left_var: []const u8,
        right_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        left_row: []const Cell,
        right_row: []const Cell,
    ) !bool {
        var st = MatchCreateWhereEvalState{
            .text = where_text,
            .pos = 0,
            .params = params,
            .left_var = left_var,
            .right_var = right_var,
            .left_table = left_table,
            .right_table = right_table,
            .left_row = left_row,
            .right_row = right_row,
        };
        const out = try self.parseMatchCreateWhereOr(&st);
        skipExprSpaces(st.text, &st.pos);
        if (st.pos != st.text.len) return error.InvalidWhere;
        return out;
    }

    fn parseMatchCreateMultiOperand(
        self: *Engine,
        expr: []const u8,
        params: ?*const std.json.ObjectMap,
        bindings: []const MatchCreateMultiWhereBinding,
    ) !MatchCreateMultiWhereOperand {
        for (bindings, 0..) |binding, binding_idx| {
            if (self.parsePropertyExprOptional(expr, binding.var_name)) |col_name| {
                const col_idx = try self.nodeColumnIndexOrBinderError(binding.table, binding.var_name, col_name);
                return .{
                    .col_ref = .{
                        .binding_idx = binding_idx,
                        .col_idx = col_idx,
                    },
                };
            }
        }
        if (Engine.parsePropertyAccessExpr(expr)) |property_expr| {
            for (bindings) |binding| {
                if (std.mem.eql(u8, binding.var_name, property_expr.var_name)) {
                    try self.failCannotFindProperty(binding.var_name, property_expr.prop_name);
                    unreachable;
                }
            }
            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
            unreachable;
        }
        return .{ .literal = try self.parseFilterValue(expr, params) };
    }

    fn evaluateMatchCreateMultiComparison(
        lhs: MatchCreateMultiWhereOperand,
        rhs: MatchCreateMultiWhereOperand,
        op: FilterOp,
        bindings: []const MatchCreateMultiWhereBinding,
    ) bool {
        return switch (lhs) {
            .col_ref => |lhs_ref| switch (rhs) {
                .col_ref => |rhs_ref| cellMatchesCell(
                    bindings[lhs_ref.binding_idx].row[lhs_ref.col_idx],
                    bindings[rhs_ref.binding_idx].row[rhs_ref.col_idx],
                    op,
                ),
                .literal => |rhs_value| cellMatchesValue(bindings[lhs_ref.binding_idx].row[lhs_ref.col_idx], op, rhs_value),
            },
            .literal => |lhs_value| switch (rhs) {
                .col_ref => |rhs_ref| cellMatchesValue(bindings[rhs_ref.binding_idx].row[rhs_ref.col_idx], reverseFilterOp(op), lhs_value),
                .literal => |rhs_value| valueMatchesValue(lhs_value, rhs_value, op),
            },
        };
    }

    fn parseMatchCreateMultiWherePrimary(self: *Engine, st: *MatchCreateMultiWhereEvalState) anyerror!bool {
        if (consumeExprKeyword(st.text, &st.pos, "NOT")) {
            return !(try self.parseMatchCreateMultiWherePrimary(st));
        }
        if (consumeExprChar(st.text, &st.pos, '(')) {
            const v = try self.parseMatchCreateMultiWhereOr(st);
            if (!consumeExprChar(st.text, &st.pos, ')')) return error.InvalidWhere;
            return v;
        }

        const clause = try parseExprClauseSlice(st.text, &st.pos);
        const norm = try normalizeComparisonClauseForNot(clause);
        if (parseNullPredicateClause(norm.clause)) |null_clause| {
            const operand = try self.parseMatchCreateMultiOperand(
                null_clause.expr,
                st.params,
                st.bindings,
            );

            var is_null = null_clause.is_null;
            if (norm.negate) is_null = !is_null;

            return switch (operand) {
                .col_ref => |ref| if (is_null) cellIsNull(st.bindings[ref.binding_idx].row[ref.col_idx]) else !cellIsNull(st.bindings[ref.binding_idx].row[ref.col_idx]),
                .literal => self.evaluateConstantWhereClause(clause, st.params),
            };
        }

        const cmp = try parseComparisonClause(norm.clause);
        const op = if (norm.negate) invertFilterOp(cmp.op) else cmp.op;
        const lhs = try self.parseMatchCreateMultiOperand(cmp.lhs, st.params, st.bindings);
        const rhs = try self.parseMatchCreateMultiOperand(cmp.rhs, st.params, st.bindings);
        return evaluateMatchCreateMultiComparison(lhs, rhs, op, st.bindings);
    }

    fn parseMatchCreateMultiWhereAnd(self: *Engine, st: *MatchCreateMultiWhereEvalState) anyerror!bool {
        var left = try self.parseMatchCreateMultiWherePrimary(st);
        while (consumeExprKeyword(st.text, &st.pos, "AND")) {
            const right = try self.parseMatchCreateMultiWherePrimary(st);
            left = left and right;
        }
        return left;
    }

    fn parseMatchCreateMultiWhereOr(self: *Engine, st: *MatchCreateMultiWhereEvalState) anyerror!bool {
        var left = try self.parseMatchCreateMultiWhereAnd(st);
        while (consumeExprKeyword(st.text, &st.pos, "OR")) {
            const right = try self.parseMatchCreateMultiWhereAnd(st);
            left = left or right;
        }
        return left;
    }

    fn evaluateMatchCreateMultiWhereExpression(
        self: *Engine,
        where_text: []const u8,
        params: ?*const std.json.ObjectMap,
        bindings: []const MatchCreateMultiWhereBinding,
    ) !bool {
        var st = MatchCreateMultiWhereEvalState{
            .text = where_text,
            .pos = 0,
            .params = params,
            .bindings = bindings,
        };
        const out = try self.parseMatchCreateMultiWhereOr(&st);
        skipExprSpaces(st.text, &st.pos);
        if (st.pos != st.text.len) return error.InvalidWhere;
        return out;
    }

    fn parseRelSetAssignment(
        self: *Engine,
        left_var: []const u8,
        right_var: []const u8,
        rel_table: *const RelTable,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        assign_text: []const u8,
        params: ?*const std.json.ObjectMap,
    ) !RelSetAssignment {
        const eq_idx = std.mem.indexOf(u8, assign_text, "=") orelse return error.InvalidMatch;
        const lhs = std.mem.trim(u8, assign_text[0..eq_idx], " \t\n\r");
        const rhs = std.mem.trim(u8, assign_text[eq_idx + 1 ..], " \t\n\r");

        const expected_prefix = try std.fmt.allocPrint(self.allocator, "{s}.", .{rel_var});
        defer self.allocator.free(expected_prefix);
        if (!std.mem.startsWith(u8, lhs, expected_prefix)) return error.InvalidMatch;

        const col_name = lhs[expected_prefix.len..];
        const col_idx = try self.relColumnIndexOrBinderError(rel_table, rel_var, col_name);
        const expected_ty = rel_table.columns.items[col_idx].ty;

        if (try self.resolveRelProjectionRefOptional(rhs, left_var, right_var, rel_var, left_table, right_table, rel_table)) |rhs_ref| {
            const rhs_ty: ColumnType = switch (rhs_ref.source) {
                .left => left_table.columns.items[rhs_ref.col_idx].ty,
                .right => right_table.columns.items[rhs_ref.col_idx].ty,
                .rel => rel_table.columns.items[rhs_ref.col_idx].ty,
            };
            if (expected_ty == .STRING and (Engine.isIntegerType(rhs_ty) or rhs_ty == .BOOL)) {
                return .{
                    .col_idx = col_idx,
                    .rhs = .{ .ref_int64_to_string = rhs_ref },
                };
            }
            if (expected_ty == .DOUBLE and Engine.isIntegerType(rhs_ty)) {
                return .{
                    .col_idx = col_idx,
                    .rhs = .{ .ref_int64_to_double = rhs_ref },
                };
            }
            if (Engine.isIntegerType(expected_ty) and rhs_ty == .DOUBLE) {
                return .{
                    .col_idx = col_idx,
                    .rhs = .{ .ref_float64_to_int64 = rhs_ref },
                };
            }
            if (Engine.isIntegerType(expected_ty) and Engine.isIntegerType(rhs_ty)) {
                return .{
                    .col_idx = col_idx,
                    .rhs = .{ .ref = rhs_ref },
                };
            }
            if (expected_ty != rhs_ty) {
                try self.failImplicitCastTypeMismatch(rhs, typeName(rhs_ty), typeName(expected_ty));
                unreachable;
            }
            return .{
                .col_idx = col_idx,
                .rhs = .{ .ref = rhs_ref },
            };
        }

        if (Engine.isIdentifierToken(rhs) and
            !std.ascii.eqlIgnoreCase(rhs, "true") and
            !std.ascii.eqlIgnoreCase(rhs, "false") and
            !std.ascii.eqlIgnoreCase(rhs, "null"))
        {
            if (std.mem.eql(u8, rhs, left_var) or std.mem.eql(u8, rhs, right_var)) {
                try self.failImplicitCastTypeMismatch(rhs, "NODE", typeName(expected_ty));
                unreachable;
            }
            if (std.mem.eql(u8, rhs, rel_var)) {
                try self.failImplicitCastTypeMismatch(rhs, "REL", typeName(expected_ty));
                unreachable;
            }
        }

        const value = try self.parseFilterValue(rhs, params);
        switch (value) {
            .null => {},
            .string => |s| {
                if (expected_ty != .STRING) {
                    try self.failImplicitCastTypeMismatch(s, "STRING", typeName(expected_ty));
                    unreachable;
                }
            },
            .int64 => |v| {
                if (expected_ty == .STRING) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal_int64_to_string = v },
                    };
                }
                if (expected_ty == .DOUBLE) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .float64 = @as(f64, @floatFromInt(v)) } },
                    };
                }
                if (expected_ty == .UINT64) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .uint64 = @intCast(v) } },
                    };
                }
                if (Engine.isIntegerType(expected_ty)) {
                    try self.ensureIntegerInTypeRange(v, expected_ty);
                } else {
                    const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                    defer self.allocator.free(expr);
                    try self.failImplicitCastTypeMismatch(expr, "INT64", typeName(expected_ty));
                    unreachable;
                }
            },
            .uint64 => |v| {
                if (expected_ty == .STRING) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) } },
                    };
                }
                if (expected_ty == .DOUBLE) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .float64 = @floatFromInt(v) } },
                    };
                }
                if (expected_ty == .UINT64) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .uint64 = v } },
                    };
                }
                if (Engine.isUnsignedIntegerType(expected_ty)) {
                    try self.ensureUnsignedInTypeRange(v, expected_ty);
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .int64 = @intCast(v) } },
                    };
                }
                if (Engine.isIntegerType(expected_ty)) {
                    try self.failUserFmt("Overflow exception: Value {d} is not within {s} range", .{ v, typeName(expected_ty) });
                    unreachable;
                }
                const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                defer self.allocator.free(expr);
                try self.failImplicitCastTypeMismatch(expr, "UINT64", typeName(expected_ty));
                unreachable;
            },
            .float64 => |v| {
                if (expected_ty == .STRING) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal_float64_to_string = v },
                    };
                }
                if (Engine.isIntegerType(expected_ty)) {
                    const rounded = Engine.roundFloatToInt64LikeKuzu(v);
                    try self.ensureIntegerInTypeRange(rounded, expected_ty);
                    if (expected_ty == .UINT64) {
                        return .{
                            .col_idx = col_idx,
                            .rhs = .{ .literal = .{ .uint64 = @intCast(rounded) } },
                        };
                    }
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .int64 = rounded } },
                    };
                }
                if (expected_ty != .DOUBLE) {
                    const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                    defer self.allocator.free(expr);
                    try self.failImplicitCastTypeMismatch(expr, "DOUBLE", typeName(expected_ty));
                    unreachable;
                }
            },
            .bool => |b| {
                if (expected_ty == .STRING) {
                    return .{
                        .col_idx = col_idx,
                        .rhs = .{ .literal = .{ .string = if (b) "True" else "False" } },
                    };
                }
                if (expected_ty != .BOOL) {
                    try self.failImplicitCastTypeMismatch(if (b) "True" else "False", "BOOL", typeName(expected_ty));
                    unreachable;
                }
            },
        }

        return .{
            .col_idx = col_idx,
            .rhs = .{ .literal = value },
        };
    }

    fn parseRelSetAssignments(
        self: *Engine,
        left_var: []const u8,
        right_var: []const u8,
        rel_table: *const RelTable,
        rel_var: []const u8,
        left_table: *const Table,
        right_table: *const Table,
        set_text: []const u8,
        params: ?*const std.json.ObjectMap,
        out_assignments: *std.ArrayList(RelSetAssignment),
    ) !void {
        var it = std.mem.splitScalar(u8, set_text, ',');
        while (it.next()) |raw| {
            const clause = std.mem.trim(u8, raw, " \t\n\r");
            if (clause.len == 0) return error.InvalidMatch;
            try out_assignments.append(
                self.allocator,
                try self.parseRelSetAssignment(left_var, right_var, rel_table, rel_var, left_table, right_table, clause, params),
            );
        }
    }

    fn relCellFor(ref: ProjRef, left_row: []const Cell, right_row: []const Cell, rel_props: []const Cell) Cell {
        return switch (ref.source) {
            .left => left_row[ref.col_idx],
            .right => right_row[ref.col_idx],
            .rel => rel_props[ref.col_idx],
        };
    }

    fn relRowMatchesFilters(
        left_row: []const Cell,
        right_row: []const Cell,
        rel_props: []const Cell,
        filters: []const RelFilter,
    ) bool {
        for (filters) |f| {
            const probe = relCellFor(f.key, left_row, right_row, rel_props);
            switch (f.null_predicate) {
                .is_null => {
                    if (!cellIsNull(probe)) return false;
                    continue;
                },
                .is_not_null => {
                    if (cellIsNull(probe)) return false;
                    continue;
                },
                .none => {},
            }
            const matches = switch (f.rhs) {
                .literal => |value| cellMatchesValue(probe, f.op, value),
                .ref => |rhs_ref| cellMatchesCell(probe, relCellFor(rhs_ref, left_row, right_row, rel_props), f.op),
            };
            if (!matches) return false;
        }
        return true;
    }

    fn relRowMatchesFilterGroups(
        left_row: []const Cell,
        right_row: []const Cell,
        rel_props: []const Cell,
        groups: []const RelFilterGroup,
    ) bool {
        if (groups.len == 0) return true;
        for (groups) |group| {
            if (relRowMatchesFilters(left_row, right_row, rel_props, group.filters.items)) return true;
        }
        return false;
    }

    fn cellLess(left: Cell, right: Cell) bool {
        return switch (left) {
            .string => |ls| switch (right) {
                .string => |rs| std.mem.lessThan(u8, ls, rs),
                else => false,
            },
            .int64 => |li| switch (right) {
                .int64 => |ri| li < ri,
                .float64 => |rf| @as(f64, @floatFromInt(li)) < rf,
                else => false,
            },
            .uint64 => |li| switch (right) {
                .uint64 => |ri| li < ri,
                .float64 => |rf| @as(f64, @floatFromInt(li)) < rf,
                else => false,
            },
            .float64 => |lf| switch (right) {
                .float64 => |rf| lf < rf,
                .int64 => |ri| lf < @as(f64, @floatFromInt(ri)),
                .uint64 => |ri| lf < @as(f64, @floatFromInt(ri)),
                else => false,
            },
            else => false,
        };
    }

    fn cellsLessWithDirection(left: Cell, right: Cell, desc: bool) ?bool {
        const left_less = cellLess(left, right);
        const right_less = cellLess(right, left);
        if (!left_less and !right_less) return null;
        return if (desc) right_less else left_less;
    }

    fn sortNodeIndicesByOrderKeys(table: *const Table, keys: []const NodeOrderKey, indices: []usize) void {
        if (keys.len == 0 or indices.len <= 1) return;
        var i: usize = 1;
        while (i < indices.len) : (i += 1) {
            const current = indices[i];
            var j = i;
            while (j > 0) {
                const prev = indices[j - 1];
                var move_prev = false;
                for (keys) |key| {
                    const left = table.rows.items[current][key.col_idx];
                    const right = table.rows.items[prev][key.col_idx];
                    if (Engine.cellsLessWithDirection(left, right, key.desc)) |decision| {
                        move_prev = decision;
                        break;
                    }
                }
                if (!move_prev) break;
                indices[j] = indices[j - 1];
                j -= 1;
            }
            indices[j] = current;
        }
    }

    fn sortRelIndicesByOrderKeys(
        left_table: *const Table,
        right_table: *const Table,
        rel_table: *const RelTable,
        keys: []const RelOrderKey,
        indices: []usize,
    ) void {
        if (keys.len == 0 or indices.len <= 1) return;
        var i: usize = 1;
        while (i < indices.len) : (i += 1) {
            const current = indices[i];
            var j = i;
            while (j > 0) {
                const prev = indices[j - 1];
                const rel_row_current = rel_table.rows.items[current];
                const rel_row_prev = rel_table.rows.items[prev];
                const left_row_current = left_table.rows.items[rel_row_current.src_row];
                const right_row_current = right_table.rows.items[rel_row_current.dst_row];
                const left_row_prev = left_table.rows.items[rel_row_prev.src_row];
                const right_row_prev = right_table.rows.items[rel_row_prev.dst_row];

                var move_prev = false;
                for (keys) |key| {
                    const lhs = Engine.relCellFor(key.ref, left_row_current, right_row_current, rel_row_current.props);
                    const rhs = Engine.relCellFor(key.ref, left_row_prev, right_row_prev, rel_row_prev.props);
                    if (Engine.cellsLessWithDirection(lhs, rhs, key.desc)) |decision| {
                        move_prev = decision;
                        break;
                    }
                }
                if (!move_prev) break;
                indices[j] = indices[j - 1];
                j -= 1;
            }
            indices[j] = current;
        }
    }

    fn sortResultRowsByOutputKeys(rows: [][]Cell, keys: []const OutputOrderKey) void {
        if (keys.len == 0 or rows.len <= 1) return;
        // Stable insertion sort preserves source order when ORDER BY keys tie.
        var i: usize = 1;
        while (i < rows.len) : (i += 1) {
            const current = rows[i];
            var j = i;
            while (j > 0) {
                const prev = rows[j - 1];
                var move_prev = false;
                for (keys) |key| {
                    if (Engine.cellsLessWithDirection(current[key.col_idx], prev[key.col_idx], key.desc)) |decision| {
                        move_prev = decision;
                        break;
                    }
                }
                if (!move_prev) break;
                rows[j] = rows[j - 1];
                j -= 1;
            }
            rows[j] = current;
        }
    }

    fn sortResultRowsByOutputKeysDistinctTieDesc(rows: [][]Cell, keys: []const OutputOrderKey) void {
        if (keys.len == 0 or rows.len <= 1) return;
        var i: usize = 1;
        while (i < rows.len) : (i += 1) {
            const current = rows[i];
            var j = i;
            while (j > 0) {
                const prev = rows[j - 1];
                var move_prev = false;

                for (keys) |key| {
                    if (Engine.cellsLessWithDirection(current[key.col_idx], prev[key.col_idx], key.desc)) |decision| {
                        move_prev = decision;
                        break;
                    }
                }

                if (!move_prev) break;
                rows[j] = rows[j - 1];
                j -= 1;
            }
            rows[j] = current;
        }
    }

    fn sortResultRowsLexicographically(rows: [][]Cell) void {
        if (rows.len <= 1) return;
        const less = struct {
            fn f(_: void, a: []Cell, b: []Cell) bool {
                const shared_len = @min(a.len, b.len);
                var i: usize = 0;
                while (i < shared_len) : (i += 1) {
                    if (Engine.cellsLessWithDirection(a[i], b[i], false)) |decision| {
                        return decision;
                    }
                }
                if (a.len != b.len) return a.len < b.len;
                return false;
            }
        }.f;
        std.sort.heap([]Cell, rows, {}, less);
    }

    fn rowsEqualFromColumn(rows: [][]Cell, start_col: usize) bool {
        if (rows.len <= 1) return true;
        const base = rows[0];
        for (rows[1..]) |row| {
            if (row.len != base.len) return false;
            var col: usize = start_col;
            while (col < row.len) : (col += 1) {
                const left = base[col];
                const right = row[col];
                const left_less = cellLess(left, right);
                const right_less = cellLess(right, left);
                if (left_less or right_less) return false;
            }
        }
        return true;
    }

    fn maybeSortDistinctEqualSuffixRows(
        self: *Engine,
        result: *ResultSet,
        return_distinct: bool,
        has_order_expr: bool,
        out_key_count: usize,
        skip: usize,
        maybe_limit: ?usize,
    ) void {
        _ = self;
        if (!return_distinct) return;
        if (has_order_expr and out_key_count != 0) return;
        if (result.rows.items.len == 0) return;
        if (!rowsEqualFromColumn(result.rows.items, 1)) return;
        sortResultRowsLexicographically(result.rows.items);
        _ = skip;
        _ = maybe_limit;
    }
    fn maybeApplyDistinctNoKeyWindowParity(
        self: *Engine,
        result: *ResultSet,
        return_distinct: bool,
        has_order_expr: bool,
        out_key_count: usize,
        skip: usize,
        maybe_limit: ?usize,
    ) bool {
        if (!return_distinct or !has_order_expr) return false;
        if (out_key_count != 0) return false;
        const limit = maybe_limit orelse return false;
        if (skip == 0) return false;
        if (result.rows.items.len == 0) return false;
        if (!rowsEqualFromColumn(result.rows.items, 1)) return false;

        // Align with Kuzu TOP_K behavior for DISTINCT grouped outputs ordered by no-op terms.
        self.applyResultWindow(result, 0, limit);
        self.applyResultWindow(result, skip, null);
        return true;
    }

    fn appendCellToGroupKey(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), cell: Cell) !void {
        switch (cell) {
            .null => try buf.appendSlice(allocator, "N|"),
            .string => |s| {
                try buf.appendSlice(allocator, "S:");
                try buf.appendSlice(allocator, s);
                try buf.appendSlice(allocator, "|");
            },
            .int64 => |v| {
                const tmp = try std.fmt.allocPrint(allocator, "I:{d}|", .{v});
                defer allocator.free(tmp);
                try buf.appendSlice(allocator, tmp);
            },
            .uint64 => |v| {
                const tmp = try std.fmt.allocPrint(allocator, "U:{d}|", .{v});
                defer allocator.free(tmp);
                try buf.appendSlice(allocator, tmp);
            },
            .float64 => |v| {
                const tmp = try std.fmt.allocPrint(allocator, "F:{d}|", .{v});
                defer allocator.free(tmp);
                try buf.appendSlice(allocator, tmp);
            },
        }
    }

    fn appendProjectedRows(
        self: *Engine,
        table: *const Table,
        selected_row_indices: []const usize,
        selected_columns: []const usize,
        result: *ResultSet,
    ) !void {
        for (selected_row_indices) |row_idx| {
            const source = table.rows.items[row_idx];
            var row = try self.allocator.alloc(Cell, selected_columns.len);
            errdefer self.allocator.free(row);
            for (selected_columns, 0..) |col_idx, out_idx| {
                row[out_idx] = try source[col_idx].clone(self.allocator);
            }
            try result.rows.append(self.allocator, row);
        }
    }

    fn findCountTermIndexByPosition(count_terms: []const CountProjectionTerm, position: usize) ?usize {
        for (count_terms, 0..) |term, idx| {
            if (term.position == position) return idx;
        }
        return null;
    }

    fn findGroupTermIndexByPosition(group_terms: []const GroupProjectionTerm, position: usize) ?usize {
        for (group_terms, 0..) |term, idx| {
            if (term.position == position) return idx;
        }
        return null;
    }

    fn buildCountOutputRowFromTerms(
        self: *Engine,
        term_count: usize,
        group_terms: []const GroupProjectionTerm,
        group_cells: []const Cell,
        count_terms: []const CountProjectionTerm,
        count_values: []const i64,
    ) ![]Cell {
        if (group_terms.len != group_cells.len) return error.InvalidReturn;
        if (count_terms.len != count_values.len) return error.InvalidReturn;

        const out = try self.allocator.alloc(Cell, term_count);
        for (0..term_count) |position| {
            if (Engine.findCountTermIndexByPosition(count_terms, position)) |count_idx| {
                out[position] = .{ .int64 = count_values[count_idx] };
                continue;
            }
            if (Engine.findGroupTermIndexByPosition(group_terms, position)) |group_idx| {
                out[position] = try group_cells[group_idx].clone(self.allocator);
                continue;
            }
            return error.InvalidReturn;
        }
        return out;
    }

    fn buildCountOutputRow(
        self: *Engine,
        group_cells: []const Cell,
        count_value: i64,
        count_position: usize,
    ) ![]Cell {
        if (count_position > group_cells.len) return error.InvalidReturn;
        const out = try self.allocator.alloc(Cell, group_cells.len + 1);
        var group_idx: usize = 0;
        for (out, 0..) |*cell, out_idx| {
            if (out_idx == count_position) {
                cell.* = .{ .int64 = count_value };
            } else {
                cell.* = try group_cells[group_idx].clone(self.allocator);
                group_idx += 1;
            }
        }
        return out;
    }

    fn initSeenMaps(self: *Engine, count_terms: []const CountProjectionTerm) ![]std.StringHashMap(void) {
        const seen_maps = try self.allocator.alloc(std.StringHashMap(void), count_terms.len);
        for (seen_maps) |*map| {
            map.* = std.StringHashMap(void).init(self.allocator);
        }
        return seen_maps;
    }

    fn deinitSeenMaps(self: *Engine, seen_maps: []std.StringHashMap(void)) void {
        for (seen_maps) |*map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            map.deinit();
        }
        self.allocator.free(seen_maps);
    }

    fn updateNodeCountAccumulators(
        self: *Engine,
        row: []const Cell,
        count_terms: []const CountProjectionTerm,
        count_targets: []const NodeCountTarget,
        counts: []i64,
        seen_maps: []std.StringHashMap(void),
    ) !void {
        if (count_terms.len != count_targets.len or count_terms.len != counts.len or count_terms.len != seen_maps.len) {
            return error.InvalidReturn;
        }

        for (count_terms, count_targets, 0..) |count_term, count_target, idx| {
            if (count_term.distinct) {
                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                const include = try self.appendNodeCountDistinctKey(count_target, row, &key_buf);
                if (!include) continue;

                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);
                if (seen_maps[idx].contains(key)) {
                    self.allocator.free(key);
                    continue;
                }
                try seen_maps[idx].put(key, {});
                counts[idx] += 1;
                continue;
            }

            if (Engine.nodeCountTargetIncludes(count_target, row)) {
                counts[idx] += 1;
            }
        }
    }

    fn updateRelCountAccumulators(
        self: *Engine,
        left_row: []const Cell,
        right_row: []const Cell,
        rel_props: []const Cell,
        count_terms: []const CountProjectionTerm,
        count_targets: []const RelCountTarget,
        counts: []i64,
        seen_maps: []std.StringHashMap(void),
    ) !void {
        if (count_terms.len != count_targets.len or count_terms.len != counts.len or count_terms.len != seen_maps.len) {
            return error.InvalidReturn;
        }

        for (count_terms, count_targets, 0..) |count_term, count_target, idx| {
            if (count_term.distinct) {
                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                const include = try self.appendRelCountDistinctKey(count_target, left_row, right_row, rel_props, &key_buf);
                if (!include) continue;

                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);
                if (seen_maps[idx].contains(key)) {
                    self.allocator.free(key);
                    continue;
                }
                try seen_maps[idx].put(key, {});
                counts[idx] += 1;
                continue;
            }

            if (Engine.relCountTargetIncludes(count_target, left_row, right_row, rel_props)) {
                counts[idx] += 1;
            }
        }
    }

    fn dedupeResultRows(self: *Engine, result: *ResultSet) !void {
        var seen = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = seen.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            seen.deinit();
        }

        var kept: std.ArrayList([]Cell) = .{};
        errdefer {
            for (kept.items) |row| {
                for (row) |*cell| {
                    cell.deinit(self.allocator);
                }
                self.allocator.free(row);
            }
            kept.deinit(self.allocator);
        }

        for (result.rows.items) |row| {
            var key_buf: std.ArrayList(u8) = .{};
            defer key_buf.deinit(self.allocator);
            for (row) |cell| {
                try Engine.appendCellToGroupKey(self.allocator, &key_buf, cell);
            }
            const key = try key_buf.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(key);

            if (seen.contains(key)) {
                self.allocator.free(key);
                for (row) |*cell| {
                    cell.deinit(self.allocator);
                }
                self.allocator.free(row);
                continue;
            }

            try seen.put(key, {});
            try kept.append(self.allocator, row);
        }

        result.rows.deinit(self.allocator);
        result.rows = kept;
    }

    fn applyResultWindow(self: *Engine, result: *ResultSet, skip: usize, maybe_limit: ?usize) void {
        if (skip > 0) {
            const row_count = result.rows.items.len;
            if (skip >= row_count) {
                var idx_all: usize = 0;
                while (idx_all < row_count) : (idx_all += 1) {
                    const row = result.rows.items[idx_all];
                    for (row) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(row);
                }
                result.rows.items.len = 0;
                return;
            }

            var idx: usize = 0;
            while (idx < skip) : (idx += 1) {
                const row = result.rows.items[idx];
                for (row) |*cell| {
                    cell.deinit(self.allocator);
                }
                self.allocator.free(row);
            }

            const kept_len = row_count - skip;
            std.mem.copyForwards([]Cell, result.rows.items[0..kept_len], result.rows.items[skip..row_count]);
            result.rows.items.len = kept_len;
        }

        const limit = maybe_limit orelse return;
        if (limit >= result.rows.items.len) return;

        var idx = limit;
        while (idx < result.rows.items.len) : (idx += 1) {
            const row = result.rows.items[idx];
            for (row) |*cell| {
                cell.deinit(self.allocator);
            }
            self.allocator.free(row);
        }
        result.rows.items.len = limit;
    }

    fn executeMatchSetMultiPattern(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        if (!startsWithAsciiNoCase(query, "MATCH ")) return error.InvalidMatch;

        var match_set_query = query;
        var return_clause_raw: ?[]const u8 = null;
        if (indexOfAsciiNoCase(query, " RETURN ")) |return_idx| {
            match_set_query = std.mem.trim(u8, query[0..return_idx], " \t\n\r");
            return_clause_raw = std.mem.trim(u8, query[return_idx + " RETURN ".len ..], " \t\n\r");
        }

        const set_idx = indexOfAsciiNoCase(match_set_query, " SET ") orelse return error.InvalidMatch;
        const match_part = std.mem.trim(u8, match_set_query["MATCH ".len..set_idx], " \t\n\r");
        const set_part = std.mem.trim(u8, match_set_query[set_idx + " SET ".len ..], " \t\n\r");

        var where_text: ?[]const u8 = null;
        var match_patterns_part = match_part;
        if (indexOfAsciiNoCase(match_part, " WHERE ")) |where_idx| {
            match_patterns_part = std.mem.trim(u8, match_part[0..where_idx], " \t\n\r");
            where_text = std.mem.trim(u8, match_part[where_idx + " WHERE ".len ..], " \t\n\r");
        }

        var match_patterns = try self.splitTopLevelCreatePatterns(match_patterns_part);
        defer match_patterns.deinit(self.allocator);
        if (match_patterns.items.len == 0) return error.InvalidMatch;

        const MatchPattern = struct {
            var_name: []const u8,
            table: *Table,
        };
        var match_nodes: std.ArrayList(MatchPattern) = .{};
        defer match_nodes.deinit(self.allocator);
        for (match_patterns.items) |match_pattern| {
            const parsed = try parseMatchNodePattern(match_pattern);
            try match_nodes.append(self.allocator, .{
                .var_name = parsed.var_name,
                .table = self.node_tables.getPtr(parsed.table_name) orelse return error.TableNotFound,
            });
        }

        const AssignmentRef = struct {
            binding_idx: usize,
            col_idx: usize,
        };
        const MatchSetRhs = union(enum) {
            literal: FilterValue,
            literal_int64_to_string: i64,
            literal_float64_to_string: f64,
            ref: AssignmentRef,
            ref_int64_to_string: AssignmentRef,
            ref_int64_to_double: AssignmentRef,
            ref_float64_to_int64: AssignmentRef,
        };
        const MatchSetAssignment = struct {
            target_binding_idx: usize,
            target_col_idx: usize,
            rhs: MatchSetRhs,
        };

        var assignments: std.ArrayList(MatchSetAssignment) = .{};
        defer assignments.deinit(self.allocator);
        var set_clauses = std.mem.splitScalar(u8, set_part, ',');
        while (set_clauses.next()) |raw_clause| {
            const clause = std.mem.trim(u8, raw_clause, " \t\n\r");
            if (clause.len == 0) return error.InvalidMatch;

            const eq_idx = std.mem.indexOfScalar(u8, clause, '=') orelse return error.InvalidMatch;
            const lhs = std.mem.trim(u8, clause[0..eq_idx], " \t\n\r");
            const rhs = std.mem.trim(u8, clause[eq_idx + 1 ..], " \t\n\r");

            const lhs_prop = Engine.parsePropertyAccessExpr(lhs) orelse return error.InvalidMatch;

            var target_binding_idx_opt: ?usize = null;
            for (match_nodes.items, 0..) |match_node, binding_idx| {
                if (std.mem.eql(u8, match_node.var_name, lhs_prop.var_name)) {
                    target_binding_idx_opt = binding_idx;
                    break;
                }
            }
            const target_binding_idx = target_binding_idx_opt orelse {
                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{lhs_prop.var_name});
                unreachable;
            };
            const target_table = match_nodes.items[target_binding_idx].table;
            const target_col_idx = try self.nodeColumnIndexOrBinderError(target_table, lhs_prop.var_name, lhs_prop.prop_name);
            const expected_ty = target_table.columns.items[target_col_idx].ty;
            if (target_table.primary_key) |pk_name| {
                if (std.mem.eql(u8, lhs_prop.prop_name, pk_name)) {
                    try self.setLastErrorFmt(
                        "Binder exception: Cannot set property {s} in table {s} because it is used as primary key. Try delete and then insert.",
                        .{ pk_name, target_table.name },
                    );
                    return error.UserVisibleError;
                }
            }

            var parsed_rhs: MatchSetRhs = undefined;
            if (Engine.parsePropertyAccessExpr(rhs)) |rhs_prop| {
                var rhs_binding_idx_opt: ?usize = null;
                for (match_nodes.items, 0..) |match_node, binding_idx| {
                    if (std.mem.eql(u8, match_node.var_name, rhs_prop.var_name)) {
                        rhs_binding_idx_opt = binding_idx;
                        break;
                    }
                }
                const rhs_binding_idx = rhs_binding_idx_opt orelse {
                    try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{rhs_prop.var_name});
                    unreachable;
                };
                const rhs_table = match_nodes.items[rhs_binding_idx].table;
                const rhs_col_idx = try self.nodeColumnIndexOrBinderError(rhs_table, rhs_prop.var_name, rhs_prop.prop_name);
                const rhs_ty = rhs_table.columns.items[rhs_col_idx].ty;
                const rhs_ref: AssignmentRef = .{ .binding_idx = rhs_binding_idx, .col_idx = rhs_col_idx };

                if (expected_ty == .STRING and (Engine.isIntegerType(rhs_ty) or rhs_ty == .BOOL)) {
                    parsed_rhs = .{ .ref_int64_to_string = rhs_ref };
                } else if (expected_ty == .DOUBLE and Engine.isIntegerType(rhs_ty)) {
                    parsed_rhs = .{ .ref_int64_to_double = rhs_ref };
                } else if (Engine.isIntegerType(expected_ty) and rhs_ty == .DOUBLE) {
                    parsed_rhs = .{ .ref_float64_to_int64 = rhs_ref };
                } else if (Engine.isIntegerType(expected_ty) and Engine.isIntegerType(rhs_ty)) {
                    parsed_rhs = .{ .ref = rhs_ref };
                } else if (expected_ty != rhs_ty) {
                    try self.failImplicitCastTypeMismatch(rhs, typeName(rhs_ty), typeName(expected_ty));
                    unreachable;
                } else {
                    parsed_rhs = .{ .ref = rhs_ref };
                }
            } else if (Engine.isIdentifierToken(rhs) and
                !std.ascii.eqlIgnoreCase(rhs, "true") and
                !std.ascii.eqlIgnoreCase(rhs, "false") and
                !std.ascii.eqlIgnoreCase(rhs, "null"))
            {
                var rhs_in_scope = false;
                for (match_nodes.items) |match_node| {
                    if (std.mem.eql(u8, match_node.var_name, rhs)) {
                        rhs_in_scope = true;
                        break;
                    }
                }
                if (rhs_in_scope) {
                    try self.failImplicitCastTypeMismatch(rhs, "NODE", typeName(expected_ty));
                    unreachable;
                }
                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{rhs});
                unreachable;
            } else {
                const value = try self.parseFilterValue(rhs, params);
                switch (value) {
                    .null => parsed_rhs = .{ .literal = .null },
                    .string => |s| {
                        if (expected_ty != .STRING) {
                            try self.failImplicitCastTypeMismatch(s, "STRING", typeName(expected_ty));
                            unreachable;
                        }
                        parsed_rhs = .{ .literal = value };
                    },
                    .int64 => |v| {
                        if (expected_ty == .STRING) {
                            parsed_rhs = .{ .literal_int64_to_string = v };
                        } else if (expected_ty == .DOUBLE) {
                            parsed_rhs = .{ .literal = .{ .float64 = @as(f64, @floatFromInt(v)) } };
                        } else if (expected_ty == .UINT64) {
                            parsed_rhs = .{ .literal = .{ .uint64 = @intCast(v) } };
                        } else if (Engine.isIntegerType(expected_ty)) {
                            try self.ensureIntegerInTypeRange(v, expected_ty);
                            parsed_rhs = .{ .literal = .{ .int64 = v } };
                        } else {
                            const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                            defer self.allocator.free(expr);
                            try self.failImplicitCastTypeMismatch(expr, "INT64", typeName(expected_ty));
                            unreachable;
                        }
                    },
                    .uint64 => |v| {
                        if (expected_ty == .STRING) {
                            parsed_rhs = .{ .literal = .{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) } };
                        } else if (expected_ty == .DOUBLE) {
                            parsed_rhs = .{ .literal = .{ .float64 = @floatFromInt(v) } };
                        } else if (expected_ty == .UINT64) {
                            parsed_rhs = .{ .literal = .{ .uint64 = v } };
                        } else if (Engine.isUnsignedIntegerType(expected_ty)) {
                            try self.ensureUnsignedInTypeRange(v, expected_ty);
                            parsed_rhs = .{ .literal = .{ .int64 = @intCast(v) } };
                        } else if (Engine.isIntegerType(expected_ty)) {
                            try self.failUserFmt("Overflow exception: Value {d} is not within {s} range", .{ v, typeName(expected_ty) });
                            unreachable;
                        } else {
                            const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                            defer self.allocator.free(expr);
                            try self.failImplicitCastTypeMismatch(expr, "UINT64", typeName(expected_ty));
                            unreachable;
                        }
                    },
                    .float64 => |v| {
                        if (expected_ty == .STRING) {
                            parsed_rhs = .{ .literal_float64_to_string = v };
                        } else if (Engine.isIntegerType(expected_ty)) {
                            const rounded = Engine.roundFloatToInt64LikeKuzu(v);
                            try self.ensureIntegerInTypeRange(rounded, expected_ty);
                            if (expected_ty == .UINT64) {
                                parsed_rhs = .{ .literal = .{ .uint64 = @intCast(rounded) } };
                            } else {
                                parsed_rhs = .{ .literal = .{ .int64 = rounded } };
                            }
                        } else if (expected_ty == .DOUBLE) {
                            parsed_rhs = .{ .literal = .{ .float64 = v } };
                        } else {
                            const expr = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                            defer self.allocator.free(expr);
                            try self.failImplicitCastTypeMismatch(expr, "DOUBLE", typeName(expected_ty));
                            unreachable;
                        }
                    },
                    .bool => |b| {
                        if (expected_ty == .STRING) {
                            parsed_rhs = .{ .literal = .{ .string = if (b) "True" else "False" } };
                        } else if (expected_ty == .BOOL) {
                            parsed_rhs = .{ .literal = .{ .bool = b } };
                        } else {
                            try self.failImplicitCastTypeMismatch(if (b) "True" else "False", "BOOL", typeName(expected_ty));
                            unreachable;
                        }
                    },
                }
            }

            try assignments.append(self.allocator, .{
                .target_binding_idx = target_binding_idx,
                .target_col_idx = target_col_idx,
                .rhs = parsed_rhs,
            });
        }

        var return_projection: ?[]const u8 = null;
        var return_distinct = false;
        var result_skip: usize = 0;
        var result_limit: ?usize = null;
        var order_expr: ?[]const u8 = null;
        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        var has_count_projection = false;

        const ReturnSource = union(enum) {
            col_ref: AssignmentRef,
            scalar_expr: []const u8,
        };
        var return_sources: std.ArrayList(ReturnSource) = .{};
        defer return_sources.deinit(self.allocator);

        if (return_clause_raw) |return_clause| {
            try self.enforceSkipBeforeLimitParserParity(query, return_clause);
            const pagination = try self.parsePaginationClause(query, return_clause);
            const distinct_clause = try parseDistinctClause(pagination.body);
            return_distinct = distinct_clause.distinct;
            result_skip = pagination.skip;
            result_limit = pagination.limit;

            const order_keyword = " ORDER BY ";
            var projection_part = distinct_clause.body;
            if (indexOfAsciiNoCase(distinct_clause.body, order_keyword)) |order_idx| {
                projection_part = std.mem.trim(u8, distinct_clause.body[0..order_idx], " \t\n\r");
                order_expr = std.mem.trim(u8, distinct_clause.body[order_idx + order_keyword.len ..], " \t\n\r");
            }
            return_projection = projection_part;
            try self.validateProjectionTermsExplicitAs(query, projection_part);

            has_count_projection = (self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
                error.InvalidCountDistinctStar => {
                    try self.raiseCountDistinctStarProjectionError(query);
                    unreachable;
                },
                else => return err,
            });

            if (has_count_projection) {
                if (!(projection_term_count == 1 and count_terms.items.len == 1 and group_terms.items.len == 0)) {
                    return error.InvalidReturn;
                }
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[0].alias));
                try result.types.append(self.allocator, "INT64");
            } else {
                if (projection_term_count != group_terms.items.len) return error.InvalidReturn;
                for (group_terms.items) |group_term| {
                    if (Engine.parsePropertyAccessExpr(group_term.expr)) |property_expr| {
                        var binding_idx_opt: ?usize = null;
                        for (match_nodes.items, 0..) |match_node, binding_idx| {
                            if (std.mem.eql(u8, match_node.var_name, property_expr.var_name)) {
                                binding_idx_opt = binding_idx;
                                break;
                            }
                        }
                        const binding_idx = binding_idx_opt orelse {
                            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                            unreachable;
                        };
                        const table = match_nodes.items[binding_idx].table;
                        const col_idx = try self.nodeColumnIndexOrBinderError(table, property_expr.var_name, property_expr.prop_name);
                        const col_ty = try self.nodeColumnTypeOrBinderError(table, property_expr.var_name, property_expr.prop_name);
                        try return_sources.append(self.allocator, .{
                            .col_ref = .{
                                .binding_idx = binding_idx,
                                .col_idx = col_idx,
                            },
                        });
                        try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_term.alias));
                        try result.types.append(self.allocator, typeName(col_ty));
                        continue;
                    }

                    if (Engine.scopeVariableForUnknownExpr(group_term.expr)) |unknown_var| {
                        for (match_nodes.items) |match_node| {
                            if (std.mem.eql(u8, match_node.var_name, unknown_var)) {
                                try self.failPropertyAccessTypeMismatch(unknown_var, "NODE");
                                unreachable;
                            }
                        }
                        try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{unknown_var});
                        unreachable;
                    }

                    const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                    var probe_cell = scalar.cell;
                    probe_cell.deinit(self.allocator);
                    try return_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
                    const output_alias = if (group_term.alias_explicit) group_term.alias else scalar.default_alias;
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                    try result.types.append(self.allocator, scalar.type_name);
                }
            }
        }

        const MatchState = struct {
            row_indices: []usize,
        };
        var match_states: std.ArrayList(MatchState) = .{};
        defer {
            for (match_states.items) |state| {
                self.allocator.free(state.row_indices);
            }
            match_states.deinit(self.allocator);
        }

        var has_match_rows = true;
        for (match_nodes.items) |match_node| {
            if (match_node.table.rows.items.len == 0) {
                has_match_rows = false;
                break;
            }
        }
        if (has_match_rows) {
            var cur_indices = try self.allocator.alloc(usize, match_nodes.items.len);
            defer self.allocator.free(cur_indices);
            @memset(cur_indices, 0);

            while (true) {
                var include = true;
                if (where_text) |wt| {
                    var where_bindings = try self.allocator.alloc(MatchCreateMultiWhereBinding, match_nodes.items.len);
                    defer self.allocator.free(where_bindings);
                    for (match_nodes.items, 0..) |match_node, idx| {
                        where_bindings[idx] = .{
                            .var_name = match_node.var_name,
                            .table = match_node.table,
                            .row = match_node.table.rows.items[cur_indices[idx]],
                        };
                    }
                    include = try self.evaluateMatchCreateMultiWhereExpression(wt, params, where_bindings);
                }

                if (include) {
                    const copied_indices = try self.allocator.alloc(usize, cur_indices.len);
                    std.mem.copyForwards(usize, copied_indices, cur_indices);
                    try match_states.append(self.allocator, .{ .row_indices = copied_indices });
                }

                var advanced = false;
                var odometer_idx: usize = 0;
                while (odometer_idx < cur_indices.len) : (odometer_idx += 1) {
                    const next_idx = cur_indices[odometer_idx] + 1;
                    if (next_idx < match_nodes.items[odometer_idx].table.rows.items.len) {
                        cur_indices[odometer_idx] = next_idx;
                        var reset_idx: usize = 0;
                        while (reset_idx < odometer_idx) : (reset_idx += 1) {
                            cur_indices[reset_idx] = 0;
                        }
                        advanced = true;
                        break;
                    }
                }
                if (!advanced) break;
            }
        }

        var count_value: i64 = 0;
        var count_seen = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = count_seen.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            count_seen.deinit();
        }

        for (match_states.items) |state| {
            for (assignments.items) |assignment| {
                const target_table = match_nodes.items[assignment.target_binding_idx].table;
                const target_row = &target_table.rows.items[state.row_indices[assignment.target_binding_idx]];
                const new_value = switch (assignment.rhs) {
                    .literal => |value| switch (value) {
                        .null => Cell.null,
                        .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        .int64 => |v| Cell{ .int64 = v },
                        .uint64 => |v| Cell{ .uint64 = v },
                        .bool => |b| Cell{ .int64 = if (b) 1 else 0 },
                        .float64 => |v| Cell{ .float64 = v },
                    },
                    .literal_int64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                    .literal_float64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                    .ref => |rhs_ref| blk: {
                        const src_table = match_nodes.items[rhs_ref.binding_idx].table;
                        break :blk try src_table.rows.items[state.row_indices[rhs_ref.binding_idx]][rhs_ref.col_idx].clone(self.allocator);
                    },
                    .ref_int64_to_string => |rhs_ref| blk: {
                        const src_table = match_nodes.items[rhs_ref.binding_idx].table;
                        const source = src_table.rows.items[state.row_indices[rhs_ref.binding_idx]][rhs_ref.col_idx];
                        const cast_cell: Cell = switch (source) {
                            .null => Cell.null,
                            .int64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                            .uint64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                            .float64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        };
                        break :blk cast_cell;
                    },
                    .ref_int64_to_double => |rhs_ref| blk: {
                        const src_table = match_nodes.items[rhs_ref.binding_idx].table;
                        const source = src_table.rows.items[state.row_indices[rhs_ref.binding_idx]][rhs_ref.col_idx];
                        const cast_cell: Cell = switch (source) {
                            .null => Cell.null,
                            .int64 => |v| Cell{ .float64 = @as(f64, @floatFromInt(v)) },
                            .uint64 => |v| Cell{ .float64 = @floatFromInt(v) },
                            .float64 => |v| Cell{ .float64 = v },
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        };
                        break :blk cast_cell;
                    },
                    .ref_float64_to_int64 => |rhs_ref| blk: {
                        const src_table = match_nodes.items[rhs_ref.binding_idx].table;
                        const source = src_table.rows.items[state.row_indices[rhs_ref.binding_idx]][rhs_ref.col_idx];
                        const cast_cell: Cell = switch (source) {
                            .null => Cell.null,
                            .int64 => |v| Cell{ .int64 = v },
                            .uint64 => |v| blk2: {
                                if (v > std.math.maxInt(i64)) {
                                    try self.failUserFmt("Overflow exception: Value {d} is not within INT64 range", .{v});
                                    unreachable;
                                }
                                break :blk2 Cell{ .int64 = @intCast(v) };
                            },
                            .float64 => |v| Cell{ .int64 = Engine.roundFloatToInt64LikeKuzu(v) },
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        };
                        break :blk cast_cell;
                    },
                };

                const target = &target_row.*[assignment.target_col_idx];
                target.deinit(self.allocator);
                target.* = new_value;
            }

            if (return_projection != null) {
                if (has_count_projection) {
                    const count_term = count_terms.items[0];
                    const count_expr = std.mem.trim(u8, count_term.count_expr, " \t\n\r");

                    var include = false;
                    var key_cell: Cell = .null;
                    var key_cell_owned = false;
                    var has_key_cell = false;
                    defer if (key_cell_owned) key_cell.deinit(self.allocator);

                    if (std.mem.eql(u8, count_expr, "*")) {
                        include = true;
                    } else if (Engine.parsePropertyAccessExpr(count_expr)) |property_expr| {
                        var binding_idx_opt: ?usize = null;
                        for (match_nodes.items, 0..) |match_node, binding_idx| {
                            if (std.mem.eql(u8, match_node.var_name, property_expr.var_name)) {
                                binding_idx_opt = binding_idx;
                                break;
                            }
                        }
                        const binding_idx = binding_idx_opt orelse {
                            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
                            unreachable;
                        };
                        const table = match_nodes.items[binding_idx].table;
                        const col_idx = try self.nodeColumnIndexOrBinderError(table, property_expr.var_name, property_expr.prop_name);
                        key_cell = table.rows.items[state.row_indices[binding_idx]][col_idx];
                        has_key_cell = true;
                        include = !cellIsNull(key_cell);
                    } else if (Engine.isIdentifierToken(count_expr) and
                        !std.ascii.eqlIgnoreCase(count_expr, "true") and
                        !std.ascii.eqlIgnoreCase(count_expr, "false") and
                        !std.ascii.eqlIgnoreCase(count_expr, "null"))
                    {
                        var binding_idx_opt: ?usize = null;
                        for (match_nodes.items, 0..) |match_node, binding_idx| {
                            if (std.mem.eql(u8, match_node.var_name, count_expr)) {
                                binding_idx_opt = binding_idx;
                                break;
                            }
                        }
                        const binding_idx = binding_idx_opt orelse {
                            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{count_expr});
                            unreachable;
                        };
                        include = true;
                        const table = match_nodes.items[binding_idx].table;
                        if (table.primary_key) |pk_name| {
                            const pk_idx = try self.nodeColumnIndexOrBinderError(table, count_expr, pk_name);
                            key_cell = table.rows.items[state.row_indices[binding_idx]][pk_idx];
                            has_key_cell = true;
                        }
                    } else {
                        const scalar = try self.evaluateReturnScalarExpr(count_expr, params);
                        key_cell = scalar.cell;
                        key_cell_owned = true;
                        has_key_cell = true;
                        if (cellIsNull(key_cell)) {
                            try self.failCountAnyBinderError(count_term.distinct);
                            unreachable;
                        }
                        include = true;
                    }

                    if (!include) continue;
                    if (count_term.distinct) {
                        if (!has_key_cell) continue;
                        var key_buf: std.ArrayList(u8) = .{};
                        defer key_buf.deinit(self.allocator);
                        try Engine.appendCellToGroupKey(self.allocator, &key_buf, key_cell);
                        const key = try key_buf.toOwnedSlice(self.allocator);
                        errdefer self.allocator.free(key);
                        if (count_seen.contains(key)) {
                            self.allocator.free(key);
                            continue;
                        }
                        try count_seen.put(key, {});
                    }
                    count_value += 1;
                } else {
                    var out_row = try self.allocator.alloc(Cell, return_sources.items.len);
                    errdefer self.allocator.free(out_row);
                    var initialized: usize = 0;
                    errdefer {
                        for (0..initialized) |i| out_row[i].deinit(self.allocator);
                    }
                    for (return_sources.items, 0..) |source, out_idx| {
                        out_row[out_idx] = switch (source) {
                            .col_ref => |ref| blk: {
                                const table = match_nodes.items[ref.binding_idx].table;
                                break :blk try table.rows.items[state.row_indices[ref.binding_idx]][ref.col_idx].clone(self.allocator);
                            },
                            .scalar_expr => |expr| blk: {
                                const scalar = try self.evaluateReturnScalarExpr(expr, params);
                                break :blk scalar.cell;
                            },
                        };
                        initialized += 1;
                    }
                    try result.rows.append(self.allocator, out_row);
                }
            }
        }

        if (return_projection != null and has_count_projection) {
            const out = try self.allocator.alloc(Cell, 1);
            out[0] = .{ .int64 = count_value };
            try result.rows.append(self.allocator, out);
        }

        if (return_projection != null) {
            if (return_distinct) {
                try self.dedupeResultRows(result);
            }
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                if (return_distinct) {
                    sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                } else {
                    sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                }
            }
            self.applyResultWindow(result, result_skip, result_limit);
        }
    }

    fn executeMatchSet(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        if (startsWithAsciiNoCase(query, "MATCH ")) {
            var match_set_query = query;
            if (indexOfAsciiNoCase(query, " RETURN ")) |return_idx| {
                match_set_query = std.mem.trim(u8, query[0..return_idx], " \t\n\r");
            }
            if (indexOfAsciiNoCase(match_set_query, " SET ")) |set_idx_probe| {
                const match_part_probe = std.mem.trim(u8, match_set_query["MATCH ".len..set_idx_probe], " \t\n\r");
                var match_patterns_probe = match_part_probe;
                if (indexOfAsciiNoCase(match_part_probe, " WHERE ")) |where_idx_probe| {
                    match_patterns_probe = std.mem.trim(u8, match_part_probe[0..where_idx_probe], " \t\n\r");
                }
                var split_probe = try self.splitTopLevelCreatePatterns(match_patterns_probe);
                defer split_probe.deinit(self.allocator);
                if (split_probe.items.len != 1) {
                    return self.executeMatchSetMultiPattern(query, params, result);
                }
            }
        }

        const head = try parseMatchHead(query);
        const table = self.node_tables.getPtr(head.table_name) orelse return error.TableNotFound;

        const where_keyword = "WHERE ";
        const set_keyword = "SET ";
        const return_keyword = " RETURN ";

        const set_idx = indexOfAsciiNoCase(head.tail, set_keyword) orelse return error.InvalidMatch;

        const after_set = head.tail[set_idx + set_keyword.len ..];
        var set_text: []const u8 = undefined;
        var return_part: ?[]const u8 = null;
        if (indexOfAsciiNoCase(after_set, return_keyword)) |return_idx_rel| {
            set_text = std.mem.trim(u8, after_set[0..return_idx_rel], " \t\n\r");
            return_part = std.mem.trim(u8, after_set[return_idx_rel + return_keyword.len ..], " \t\n\r");
        } else {
            set_text = std.mem.trim(u8, after_set, " \t\n\r");
        }

        var where_text: ?[]const u8 = null;
        var match_scope_end = set_idx;
        if (indexOfAsciiNoCase(head.tail, where_keyword)) |where_idx| {
            if (where_idx >= set_idx) return error.InvalidMatch;
            match_scope_end = where_idx;
            where_text = std.mem.trim(u8, head.tail[where_idx + where_keyword.len .. set_idx], " \t\n\r");
        }

        var set_scope_vars: std.ArrayList([]const u8) = .{};
        defer set_scope_vars.deinit(self.allocator);
        var extra_match_scope = std.mem.trim(u8, head.tail[0..match_scope_end], " \t\n\r");
        if (extra_match_scope.len > 0 and extra_match_scope[0] == ',') {
            extra_match_scope = std.mem.trimLeft(u8, extra_match_scope[1..], " \t\n\r");
        }
        if (extra_match_scope.len > 0) {
            var extra_patterns = try self.splitTopLevelCreatePatterns(extra_match_scope);
            defer extra_patterns.deinit(self.allocator);
            for (extra_patterns.items) |pattern| {
                if (parseMatchNodePattern(pattern)) |node_pat| {
                    if (node_pat.var_name.len == 0 or std.mem.eql(u8, node_pat.var_name, head.var_name)) continue;
                    var seen = false;
                    for (set_scope_vars.items) |existing| {
                        if (std.mem.eql(u8, existing, node_pat.var_name)) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) {
                        try set_scope_vars.append(self.allocator, node_pat.var_name);
                    }
                } else |_| {}
            }
        }

        var assignments: std.ArrayList(NodeSetAssignment) = .{};
        defer assignments.deinit(self.allocator);
        try self.parseNodeSetAssignments(table, head.var_name, set_scope_vars.items, set_text, params, &assignments);

        var indices: std.ArrayList(usize) = .{};
        defer indices.deinit(self.allocator);
        for (table.rows.items, 0..) |row, idx| {
            if (where_text) |wt| {
                if (!(try self.evaluateNodeWhereExpression(table, head.var_name, wt, params, row))) continue;
            }
            try indices.append(self.allocator, idx);
        }

        for (indices.items) |idx| {
            const row = table.rows.items[idx];
            for (assignments.items) |assignment| {
                try self.applyNodeSetAssignment(row, assignment);
            }
        }

        if (return_part == null) return;
        const return_text = return_part.?;
        try self.enforceSkipBeforeLimitParserParity(query, return_text);
        const pagination = try self.parsePaginationClause(query, return_text);
        const distinct_clause = try parseDistinctClause(pagination.body);
        const return_body = distinct_clause.body;
        const return_distinct = distinct_clause.distinct;
        const result_skip = pagination.skip;
        const result_limit = pagination.limit;

        var order_keys: std.ArrayList(NodeOrderKey) = .{};
        defer order_keys.deinit(self.allocator);
        const order_keyword = " ORDER BY ";
        var projection_part = return_body;
        var order_expr: ?[]const u8 = null;
        if (indexOfAsciiNoCase(return_body, order_keyword)) |order_idx| {
            projection_part = std.mem.trim(u8, return_body[0..order_idx], " \t\n\r");
            order_expr = std.mem.trim(u8, return_body[order_idx + order_keyword.len ..], " \t\n\r");
        }
        try self.validateProjectionTermsExplicitAs(query, projection_part);

        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        if ((self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
            error.InvalidCountDistinctStar => {
                try self.raiseCountDistinctStarProjectionError(query);
                unreachable;
            },
            else => return err,
        })) {
            var count_targets: std.ArrayList(NodeCountTarget) = .{};
            defer count_targets.deinit(self.allocator);
            for (count_terms.items) |count_term| {
                try count_targets.append(
                    self.allocator,
                    try self.parseNodeCountTarget(count_term.count_expr, head.var_name, table, params, count_term.distinct),
                );
            }

            const NodeGroupSource = union(enum) {
                column: usize,
                scalar_expr: []const u8,
            };

            var group_sources: std.ArrayList(NodeGroupSource) = .{};
            defer group_sources.deinit(self.allocator);
            var group_types: std.ArrayList([]const u8) = .{};
            defer group_types.deinit(self.allocator);
            for (group_terms.items) |group_term| {
                if (self.parsePropertyExprOptional(group_term.expr, head.var_name)) |col_name| {
                    const col_idx = try self.nodeColumnIndexOrBinderError(table, head.var_name, col_name);
                    const ty = try self.nodeColumnTypeOrBinderError(table, head.var_name, col_name);
                    try group_sources.append(self.allocator, .{ .column = col_idx });
                    try group_types.append(self.allocator, typeName(ty));
                    continue;
                }

                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                var probe_cell = scalar.cell;
                probe_cell.deinit(self.allocator);
                try group_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
                try group_types.append(self.allocator, scalar.type_name);
            }

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = 2;
            for (0..projection_term_count) |position| {
                if (Engine.findCountTermIndexByPosition(count_terms.items, position)) |count_idx| {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[count_idx].alias));
                    try result.types.append(self.allocator, "INT64");
                    implicit_param_alias_slot += 1;
                    continue;
                }
                if (Engine.findGroupTermIndexByPosition(group_terms.items, position)) |group_idx| {
                    const group_term = group_terms.items[group_idx];
                    var output_alias = group_term.alias;
                    var output_alias_owned = false;
                    defer if (output_alias_owned) self.allocator.free(output_alias);
                    if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                        const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                        if (!param_lookup.present) {
                            output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                            output_alias_owned = true;
                        }
                    }
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                    try result.types.append(self.allocator, group_types.items[group_idx]);
                    switch (group_sources.items[group_idx]) {
                        .scalar_expr => implicit_param_alias_slot += 1,
                        .column => {},
                    }
                    continue;
                }
                return error.InvalidReturn;
            }

            if (group_terms.items.len == 0) {
                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                defer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                defer self.deinitSeenMaps(seen_maps);

                for (indices.items) |row_idx| {
                    const row = table.rows.items[row_idx];
                    try self.updateNodeCountAccumulators(row, count_terms.items, count_targets.items, counts, seen_maps);
                }

                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    &[_]Cell{},
                    count_terms.items,
                    counts,
                );
                try result.rows.append(self.allocator, out);
                self.applyResultWindow(result, result_skip, result_limit);
                return;
            }

            const GroupState = struct {
                cells: []Cell,
                counts: []i64,
                seen: []std.StringHashMap(void),
            };

            var groups = std.StringHashMap(GroupState).init(self.allocator);
            defer {
                var it = groups.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    for (entry.value_ptr.cells) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(entry.value_ptr.cells);
                    self.allocator.free(entry.value_ptr.counts);
                    self.deinitSeenMaps(entry.value_ptr.seen);
                }
                groups.deinit();
            }

            for (indices.items) |row_idx| {
                const row = table.rows.items[row_idx];

                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                for (group_sources.items) |group_source| {
                    switch (group_source) {
                        .column => |col_idx| {
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, row[col_idx]);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            var scalar_cell = scalar.cell;
                            defer scalar_cell.deinit(self.allocator);
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, scalar_cell);
                        },
                    }
                }
                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);

                if (groups.getPtr(key)) |existing| {
                    self.allocator.free(key);
                    try self.updateNodeCountAccumulators(row, count_terms.items, count_targets.items, existing.counts, existing.seen);
                    continue;
                }

                const stored = try self.allocator.alloc(Cell, group_sources.items.len);
                errdefer self.allocator.free(stored);
                for (group_sources.items, 0..) |group_source, i| {
                    switch (group_source) {
                        .column => |col_idx| {
                            stored[i] = try row[col_idx].clone(self.allocator);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            stored[i] = scalar.cell;
                        },
                    }
                }

                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                errdefer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                errdefer self.deinitSeenMaps(seen_maps);
                try self.updateNodeCountAccumulators(row, count_terms.items, count_targets.items, counts, seen_maps);

                try groups.put(key, .{
                    .cells = stored,
                    .counts = counts,
                    .seen = seen_maps,
                });
            }

            var group_it = groups.iterator();
            while (group_it.next()) |entry| {
                const state = entry.value_ptr.*;
                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    state.cells,
                    count_terms.items,
                    state.counts,
                );
                try result.rows.append(self.allocator, out);
            }

            var parsed_out_key_count: usize = 0;
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                parsed_out_key_count = out_keys.items.len;
                if (out_keys.items.len == 0) {
                    if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                } else {
                    if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
                }
            } else {
                if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
            }
            self.maybeSortDistinctEqualSuffixRows(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            );
            if (!self.maybeApplyDistinctNoKeyWindowParity(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            )) {
                self.applyResultWindow(result, result_skip, result_limit);
            }
            return;
        }

        if (projection_term_count != group_terms.items.len) return error.InvalidReturn;

        const NodeProjectionSource = union(enum) {
            column: usize,
            scalar_expr: []const u8,
        };

        var projection_sources: std.ArrayList(NodeProjectionSource) = .{};
        defer projection_sources.deinit(self.allocator);
        var alias_bindings: std.ArrayList(NodeOrderAlias) = .{};
        defer alias_bindings.deinit(self.allocator);
        const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
        var implicit_param_alias_slot: usize = 2;

        for (group_terms.items) |group_term| {
            if (self.parsePropertyExprOptional(group_term.expr, head.var_name)) |col_name| {
                const col_idx = try self.nodeColumnIndexOrBinderError(table, head.var_name, col_name);
                const ty = try self.nodeColumnTypeOrBinderError(table, head.var_name, col_name);
                try projection_sources.append(self.allocator, .{ .column = col_idx });
                if (!std.mem.eql(u8, group_term.alias, group_term.expr)) {
                    try alias_bindings.append(self.allocator, .{ .alias = group_term.alias, .col_idx = col_idx });
                }
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_term.alias));
                try result.types.append(self.allocator, typeName(ty));
                continue;
            }

            var output_alias = group_term.alias;
            var output_alias_owned = false;
            defer if (output_alias_owned) self.allocator.free(output_alias);
            if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                if (!param_lookup.present) {
                    output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                    output_alias_owned = true;
                }
            }

            const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
            var probe_cell = scalar.cell;
            probe_cell.deinit(self.allocator);
            try projection_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
            try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
            try result.types.append(self.allocator, scalar.type_name);
            implicit_param_alias_slot += 1;
        }

        if (!return_distinct) {
            if (order_expr) |order_text| {
                try self.parseNodeOrderKeys(table, head.var_name, order_text, alias_bindings.items, &order_keys);
            }
            sortNodeIndicesByOrderKeys(table, order_keys.items, indices.items);
        }

        for (indices.items) |row_idx| {
            const source = table.rows.items[row_idx];
            var out_row = try self.allocator.alloc(Cell, projection_sources.items.len);
            errdefer self.allocator.free(out_row);
            for (projection_sources.items, 0..) |projection_source, out_idx| {
                switch (projection_source) {
                    .column => |col_idx| {
                        out_row[out_idx] = try source[col_idx].clone(self.allocator);
                    },
                    .scalar_expr => |expr| {
                        const scalar = try self.evaluateReturnScalarExpr(expr, params);
                        out_row[out_idx] = scalar.cell;
                    },
                }
            }
            try result.rows.append(self.allocator, out_row);
        }
        if (return_distinct) {
            try self.dedupeResultRows(result);
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                if (out_keys.items.len > 0) {
                    sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                }
            }
        }
        self.applyResultWindow(result, result_skip, result_limit);
    }

    fn executeMatchRelSet(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        const head = try parseMatchRelHead(query);

        const left_table = self.node_tables.getPtr(head.left_table) orelse return error.TableNotFound;
        const right_table = self.node_tables.getPtr(head.right_table) orelse return error.TableNotFound;
        const rel_table = self.rel_tables.getPtr(head.rel_table) orelse return error.TableNotFound;

        if (!std.mem.eql(u8, rel_table.from_table, head.left_table)) return error.InvalidMatch;
        if (!std.mem.eql(u8, rel_table.to_table, head.right_table)) return error.InvalidMatch;

        const where_keyword = "WHERE ";
        const set_keyword = "SET ";
        const return_keyword = " RETURN ";

        const set_idx = indexOfAsciiNoCase(head.tail, set_keyword) orelse return error.InvalidMatch;
        const after_set = head.tail[set_idx + set_keyword.len ..];

        var set_text: []const u8 = undefined;
        var return_part: ?[]const u8 = null;
        if (indexOfAsciiNoCase(after_set, return_keyword)) |return_idx_rel| {
            set_text = std.mem.trim(u8, after_set[0..return_idx_rel], " \t\n\r");
            return_part = std.mem.trim(u8, after_set[return_idx_rel + return_keyword.len ..], " \t\n\r");
        } else {
            set_text = std.mem.trim(u8, after_set, " \t\n\r");
        }

        var where_text: ?[]const u8 = null;
        if (indexOfAsciiNoCase(head.tail, where_keyword)) |where_idx| {
            if (where_idx >= set_idx) return error.InvalidMatch;
            where_text = std.mem.trim(u8, head.tail[where_idx + where_keyword.len .. set_idx], " \t\n\r");
        }

        var assignments: std.ArrayList(RelSetAssignment) = .{};
        defer assignments.deinit(self.allocator);
        try self.parseRelSetAssignments(
            head.left_var,
            head.right_var,
            rel_table,
            head.rel_var,
            left_table,
            right_table,
            set_text,
            params,
            &assignments,
        );

        var indices: std.ArrayList(usize) = .{};
        defer indices.deinit(self.allocator);
        for (rel_table.rows.items, 0..) |rel_row, idx| {
            if (where_text) |where_expr| {
                if (!(try self.evaluateRelWhereExpression(
                    where_expr,
                    params,
                    head.left_var,
                    head.right_var,
                    head.rel_var,
                    left_table,
                    right_table,
                    rel_table,
                    left_table.rows.items[rel_row.src_row],
                    right_table.rows.items[rel_row.dst_row],
                    rel_row.props,
                ))) continue;
            }
            try indices.append(self.allocator, idx);
        }

        for (indices.items) |rel_idx| {
            const rel_row = &rel_table.rows.items[rel_idx];
            const left_row = left_table.rows.items[rel_row.src_row];
            const right_row = right_table.rows.items[rel_row.dst_row];
            for (assignments.items) |assignment| {
                const new_value = switch (assignment.rhs) {
                    .literal => |value| switch (value) {
                        .null => Cell.null,
                        .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        .int64 => |v| Cell{ .int64 = v },
                        .uint64 => |v| Cell{ .uint64 = v },
                        .bool => |b| Cell{ .int64 = if (b) 1 else 0 },
                        .float64 => |v| Cell{ .float64 = v },
                    },
                    .literal_int64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                    .literal_float64_to_string => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                    .ref => |rhs_ref| try Engine.relCellFor(rhs_ref, left_row, right_row, rel_row.props).clone(self.allocator),
                    .ref_int64_to_string => |rhs_ref| blk: {
                        const source = Engine.relCellFor(rhs_ref, left_row, right_row, rel_row.props);
                        const cast_cell: Cell = switch (source) {
                            .null => Cell.null,
                            .int64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                            .uint64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{v}) },
                            .float64 => |v| Cell{ .string = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v}) },
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        };
                        break :blk cast_cell;
                    },
                    .ref_int64_to_double => |rhs_ref| blk: {
                        const source = Engine.relCellFor(rhs_ref, left_row, right_row, rel_row.props);
                        const cast_cell: Cell = switch (source) {
                            .null => Cell.null,
                            .int64 => |v| Cell{ .float64 = @as(f64, @floatFromInt(v)) },
                            .uint64 => |v| Cell{ .float64 = @floatFromInt(v) },
                            .float64 => |v| Cell{ .float64 = v },
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        };
                        break :blk cast_cell;
                    },
                    .ref_float64_to_int64 => |rhs_ref| blk: {
                        const source = Engine.relCellFor(rhs_ref, left_row, right_row, rel_row.props);
                        const cast_cell: Cell = switch (source) {
                            .null => Cell.null,
                            .int64 => |v| Cell{ .int64 = v },
                            .uint64 => |v| blk2: {
                                if (v > std.math.maxInt(i64)) {
                                    try self.failUserFmt("Overflow exception: Value {d} is not within INT64 range", .{v});
                                    unreachable;
                                }
                                break :blk2 Cell{ .int64 = @intCast(v) };
                            },
                            .float64 => |v| Cell{ .int64 = Engine.roundFloatToInt64LikeKuzu(v) },
                            .string => |s| Cell{ .string = try self.allocator.dupe(u8, s) },
                        };
                        break :blk cast_cell;
                    },
                };
                const target = &rel_row.props[assignment.col_idx];
                target.deinit(self.allocator);
                target.* = new_value;
            }
        }

        if (return_part == null) return;
        const return_text = return_part.?;
        try self.enforceSkipBeforeLimitParserParity(query, return_text);
        const pagination = try self.parsePaginationClause(query, return_text);
        const distinct_clause = try parseDistinctClause(pagination.body);
        const return_body = distinct_clause.body;
        const return_distinct = distinct_clause.distinct;
        const result_skip = pagination.skip;
        const result_limit = pagination.limit;

        var order_keys: std.ArrayList(RelOrderKey) = .{};
        defer order_keys.deinit(self.allocator);
        const order_keyword = " ORDER BY ";
        var projection_part = return_body;
        var order_expr: ?[]const u8 = null;
        if (indexOfAsciiNoCase(return_body, order_keyword)) |order_idx| {
            projection_part = std.mem.trim(u8, return_body[0..order_idx], " \t\n\r");
            order_expr = std.mem.trim(u8, return_body[order_idx + order_keyword.len ..], " \t\n\r");
        }
        try self.validateProjectionTermsExplicitAs(query, projection_part);

        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        if ((self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
            error.InvalidCountDistinctStar => {
                try self.raiseCountDistinctStarProjectionError(query);
                unreachable;
            },
            else => return err,
        })) {
            var count_targets: std.ArrayList(RelCountTarget) = .{};
            defer count_targets.deinit(self.allocator);
            for (count_terms.items) |count_term| {
                try count_targets.append(
                    self.allocator,
                    try self.parseRelCountTarget(
                        count_term.count_expr,
                        head.left_var,
                        head.right_var,
                        head.rel_var,
                        left_table,
                        right_table,
                        rel_table,
                        params,
                        count_term.distinct,
                    ),
                );
            }

            const RelGroupSource = union(enum) {
                ref: ProjRef,
                scalar_expr: []const u8,
            };

            var group_sources: std.ArrayList(RelGroupSource) = .{};
            defer group_sources.deinit(self.allocator);
            var group_types: std.ArrayList([]const u8) = .{};
            defer group_types.deinit(self.allocator);
            for (group_terms.items) |group_term| {
                if (try self.resolveRelProjectionRefOptional(
                    group_term.expr,
                    head.left_var,
                    head.right_var,
                    head.rel_var,
                    left_table,
                    right_table,
                    rel_table,
                )) |resolved_ref| {
                    const resolved_ty = switch (resolved_ref.source) {
                        .left => left_table.columns.items[resolved_ref.col_idx].ty,
                        .right => right_table.columns.items[resolved_ref.col_idx].ty,
                        .rel => rel_table.columns.items[resolved_ref.col_idx].ty,
                    };
                    try group_sources.append(self.allocator, .{ .ref = resolved_ref });
                    try group_types.append(self.allocator, typeName(resolved_ty));
                    continue;
                }

                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                var probe_cell = scalar.cell;
                probe_cell.deinit(self.allocator);
                try group_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
                try group_types.append(self.allocator, scalar.type_name);
            }

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = 6;
            for (0..projection_term_count) |position| {
                if (Engine.findCountTermIndexByPosition(count_terms.items, position)) |count_idx| {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[count_idx].alias));
                    try result.types.append(self.allocator, "INT64");
                    implicit_param_alias_slot += 1;
                    continue;
                }
                if (Engine.findGroupTermIndexByPosition(group_terms.items, position)) |group_idx| {
                    const group_term = group_terms.items[group_idx];
                    var output_alias = group_term.alias;
                    var output_alias_owned = false;
                    defer if (output_alias_owned) self.allocator.free(output_alias);
                    if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                        const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                        if (!param_lookup.present) {
                            output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                            output_alias_owned = true;
                        }
                    }
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                    try result.types.append(self.allocator, group_types.items[group_idx]);
                    switch (group_sources.items[group_idx]) {
                        .scalar_expr => implicit_param_alias_slot += 1,
                        .ref => {},
                    }
                    continue;
                }
                return error.InvalidReturn;
            }

            if (group_terms.items.len == 0) {
                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                defer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                defer self.deinitSeenMaps(seen_maps);

                for (indices.items) |rel_idx| {
                    const rel_row = rel_table.rows.items[rel_idx];
                    const left_row = left_table.rows.items[rel_row.src_row];
                    const right_row = right_table.rows.items[rel_row.dst_row];
                    try self.updateRelCountAccumulators(left_row, right_row, rel_row.props, count_terms.items, count_targets.items, counts, seen_maps);
                }

                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    &[_]Cell{},
                    count_terms.items,
                    counts,
                );
                try result.rows.append(self.allocator, out);
                self.applyResultWindow(result, result_skip, result_limit);
                return;
            }

            const GroupState = struct {
                cells: []Cell,
                counts: []i64,
                seen: []std.StringHashMap(void),
            };

            var groups = std.StringHashMap(GroupState).init(self.allocator);
            defer {
                var it = groups.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    for (entry.value_ptr.cells) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(entry.value_ptr.cells);
                    self.allocator.free(entry.value_ptr.counts);
                    self.deinitSeenMaps(entry.value_ptr.seen);
                }
                groups.deinit();
            }

            for (indices.items) |rel_idx| {
                const rel_row = rel_table.rows.items[rel_idx];
                const left_row = left_table.rows.items[rel_row.src_row];
                const right_row = right_table.rows.items[rel_row.dst_row];

                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                for (group_sources.items) |group_source| {
                    switch (group_source) {
                        .ref => |gref| {
                            const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, cell);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            var scalar_cell = scalar.cell;
                            defer scalar_cell.deinit(self.allocator);
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, scalar_cell);
                        },
                    }
                }
                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);

                if (groups.getPtr(key)) |existing| {
                    self.allocator.free(key);
                    try self.updateRelCountAccumulators(
                        left_row,
                        right_row,
                        rel_row.props,
                        count_terms.items,
                        count_targets.items,
                        existing.counts,
                        existing.seen,
                    );
                    continue;
                }

                const stored = try self.allocator.alloc(Cell, group_sources.items.len);
                errdefer self.allocator.free(stored);
                for (group_sources.items, 0..) |group_source, i| {
                    switch (group_source) {
                        .ref => |gref| {
                            const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                            stored[i] = try cell.clone(self.allocator);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            stored[i] = scalar.cell;
                        },
                    }
                }

                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                errdefer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                errdefer self.deinitSeenMaps(seen_maps);
                try self.updateRelCountAccumulators(
                    left_row,
                    right_row,
                    rel_row.props,
                    count_terms.items,
                    count_targets.items,
                    counts,
                    seen_maps,
                );

                try groups.put(key, .{
                    .cells = stored,
                    .counts = counts,
                    .seen = seen_maps,
                });
            }

            var group_it = groups.iterator();
            while (group_it.next()) |entry| {
                const state = entry.value_ptr.*;
                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    state.cells,
                    count_terms.items,
                    state.counts,
                );
                try result.rows.append(self.allocator, out);
            }

            var parsed_out_key_count: usize = 0;
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                parsed_out_key_count = out_keys.items.len;
                if (out_keys.items.len == 0) {
                    if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                } else {
                    if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
                }
            } else {
                if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
            }
            self.maybeSortDistinctEqualSuffixRows(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            );
            if (!self.maybeApplyDistinctNoKeyWindowParity(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            )) {
                self.applyResultWindow(result, result_skip, result_limit);
            }
            return;
        }

        if (try parseCountProjectionClause(projection_part)) |count_clause| {
            const count_target = try self.parseRelCountTarget(
                count_clause.count_expr,
                head.left_var,
                head.right_var,
                head.rel_var,
                left_table,
                right_table,
                rel_table,
                params,
                count_clause.distinct,
            );

            var group_refs: std.ArrayList(ProjRef) = .{};
            defer group_refs.deinit(self.allocator);
            var group_types: std.ArrayList(ColumnType) = .{};
            defer group_types.deinit(self.allocator);
            var group_names: std.ArrayList([]const u8) = .{};
            defer group_names.deinit(self.allocator);

            var term_idx: usize = 0;
            var group_iter = std.mem.splitScalar(u8, projection_part, ',');
            while (group_iter.next()) |raw_expr| {
                const term = try parseProjectionTerm(raw_expr);
                if (term_idx == count_clause.count_position) {
                    term_idx += 1;
                    continue;
                }

                const resolved = try self.resolveRelProjectionRef(term.expr, head.left_var, head.right_var, head.rel_var, left_table, right_table, rel_table);
                try group_refs.append(self.allocator, resolved.ref);
                try group_types.append(self.allocator, resolved.ty);
                try group_names.append(self.allocator, term.alias orelse term.expr);
                term_idx += 1;
            }
            if (term_idx != count_clause.term_count) return error.InvalidReturn;

            var group_out_idx: usize = 0;
            for (0..count_clause.term_count) |out_idx| {
                if (out_idx == count_clause.count_position) {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_clause.alias));
                    try result.types.append(self.allocator, "INT64");
                    continue;
                }
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_names.items[group_out_idx]));
                try result.types.append(self.allocator, typeName(group_types.items[group_out_idx]));
                group_out_idx += 1;
            }

            if (count_clause.distinct) {
                if (group_refs.items.len == 0) {
                    var seen = std.StringHashMap(void).init(self.allocator);
                    defer {
                        var it = seen.iterator();
                        while (it.next()) |entry| {
                            self.allocator.free(entry.key_ptr.*);
                        }
                        seen.deinit();
                    }

                    var count_value: i64 = 0;
                    for (indices.items) |rel_idx| {
                        const rel_row = rel_table.rows.items[rel_idx];
                        const left_row = left_table.rows.items[rel_row.src_row];
                        const right_row = right_table.rows.items[rel_row.dst_row];

                        var distinct_key_buf: std.ArrayList(u8) = .{};
                        defer distinct_key_buf.deinit(self.allocator);
                        const include = try self.appendRelCountDistinctKey(count_target, left_row, right_row, rel_row.props, &distinct_key_buf);
                        if (!include) continue;
                        const distinct_key = try distinct_key_buf.toOwnedSlice(self.allocator);
                        errdefer self.allocator.free(distinct_key);
                        if (seen.contains(distinct_key)) {
                            self.allocator.free(distinct_key);
                            continue;
                        }
                        try seen.put(distinct_key, {});
                        count_value += 1;
                    }

                    const out = try self.allocator.alloc(Cell, 1);
                    out[0] = .{ .int64 = count_value };
                    try result.rows.append(self.allocator, out);
                    self.applyResultWindow(result, result_skip, result_limit);
                    return;
                }

                const GroupStateDistinct = struct {
                    cells: []Cell,
                    count: i64,
                    seen: std.StringHashMap(void),
                };

                var groups = std.StringHashMap(GroupStateDistinct).init(self.allocator);
                defer {
                    var it = groups.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        for (entry.value_ptr.cells) |*cell| {
                            cell.deinit(self.allocator);
                        }
                        self.allocator.free(entry.value_ptr.cells);
                        var seen_it = entry.value_ptr.seen.iterator();
                        while (seen_it.next()) |seen_entry| {
                            self.allocator.free(seen_entry.key_ptr.*);
                        }
                        entry.value_ptr.seen.deinit();
                    }
                    groups.deinit();
                }

                for (indices.items) |rel_idx| {
                    const rel_row = rel_table.rows.items[rel_idx];
                    const left_row = left_table.rows.items[rel_row.src_row];
                    const right_row = right_table.rows.items[rel_row.dst_row];

                    var group_key_buf: std.ArrayList(u8) = .{};
                    defer group_key_buf.deinit(self.allocator);
                    for (group_refs.items) |gref| {
                        const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                        try Engine.appendCellToGroupKey(self.allocator, &group_key_buf, cell);
                    }
                    const group_key = try group_key_buf.toOwnedSlice(self.allocator);
                    errdefer self.allocator.free(group_key);

                    var distinct_key_buf: std.ArrayList(u8) = .{};
                    defer distinct_key_buf.deinit(self.allocator);
                    const include = try self.appendRelCountDistinctKey(count_target, left_row, right_row, rel_row.props, &distinct_key_buf);
                    const distinct_key_opt: ?[]u8 = if (include) blk: {
                        const owned = try distinct_key_buf.toOwnedSlice(self.allocator);
                        break :blk owned;
                    } else null;
                    if (distinct_key_opt) |owned_key| {
                        errdefer self.allocator.free(owned_key);
                    }

                    if (groups.getPtr(group_key)) |existing| {
                        self.allocator.free(group_key);
                        if (distinct_key_opt) |distinct_key| {
                            if (existing.seen.contains(distinct_key)) {
                                self.allocator.free(distinct_key);
                            } else {
                                try existing.seen.put(distinct_key, {});
                                existing.count += 1;
                            }
                        }
                        continue;
                    }

                    const stored = try self.allocator.alloc(Cell, group_refs.items.len);
                    errdefer self.allocator.free(stored);
                    for (group_refs.items, 0..) |gref, i| {
                        const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                        stored[i] = try cell.clone(self.allocator);
                    }

                    var seen_values = std.StringHashMap(void).init(self.allocator);
                    errdefer seen_values.deinit();
                    var initial_count: i64 = 0;
                    if (distinct_key_opt) |distinct_key| {
                        try seen_values.put(distinct_key, {});
                        initial_count = 1;
                    }

                    try groups.put(group_key, .{
                        .cells = stored,
                        .count = initial_count,
                        .seen = seen_values,
                    });
                }

                var group_it = groups.iterator();
                while (group_it.next()) |entry| {
                    const state = entry.value_ptr.*;
                    const out = try self.buildCountOutputRow(state.cells, state.count, count_clause.count_position);
                    try result.rows.append(self.allocator, out);
                }

                var parsed_out_key_count: usize = 0;
                if (order_expr) |order_text| {
                    var out_keys: std.ArrayList(OutputOrderKey) = .{};
                    defer out_keys.deinit(self.allocator);
                    try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                    parsed_out_key_count = out_keys.items.len;
                    if (out_keys.items.len == 0) {
                        if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                    } else {
                        if (return_distinct) {
                            sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                        } else {
                            sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                        }
                    }
                } else {
                    if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                }
                self.maybeSortDistinctEqualSuffixRows(
                    result,
                    return_distinct,
                    order_expr != null,
                    parsed_out_key_count,
                    result_skip,
                    result_limit,
                );
                if (!self.maybeApplyDistinctNoKeyWindowParity(
                    result,
                    return_distinct,
                    order_expr != null,
                    parsed_out_key_count,
                    result_skip,
                    result_limit,
                )) {
                    self.applyResultWindow(result, result_skip, result_limit);
                }
                return;
            }

            if (group_refs.items.len == 0) {
                var count_value: i64 = 0;
                for (indices.items) |rel_idx| {
                    const rel_row = rel_table.rows.items[rel_idx];
                    const left_row = left_table.rows.items[rel_row.src_row];
                    const right_row = right_table.rows.items[rel_row.dst_row];
                    if (Engine.relCountTargetIncludes(count_target, left_row, right_row, rel_row.props)) {
                        count_value += 1;
                    }
                }
                const out = try self.allocator.alloc(Cell, 1);
                out[0] = .{ .int64 = count_value };
                try result.rows.append(self.allocator, out);
                self.applyResultWindow(result, result_skip, result_limit);
                return;
            }

            const GroupState = struct {
                cells: []Cell,
                count: i64,
            };

            var groups = std.StringHashMap(GroupState).init(self.allocator);
            defer {
                var it = groups.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    for (entry.value_ptr.cells) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(entry.value_ptr.cells);
                }
                groups.deinit();
            }

            for (indices.items) |rel_idx| {
                const rel_row = rel_table.rows.items[rel_idx];
                const left_row = left_table.rows.items[rel_row.src_row];
                const right_row = right_table.rows.items[rel_row.dst_row];
                const include = Engine.relCountTargetIncludes(count_target, left_row, right_row, rel_row.props);

                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                for (group_refs.items) |gref| {
                    const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                    try Engine.appendCellToGroupKey(self.allocator, &key_buf, cell);
                }
                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);

                if (groups.getPtr(key)) |existing| {
                    if (include) {
                        existing.count += 1;
                    }
                    self.allocator.free(key);
                    continue;
                }

                const stored = try self.allocator.alloc(Cell, group_refs.items.len);
                errdefer self.allocator.free(stored);
                for (group_refs.items, 0..) |gref, i| {
                    const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                    stored[i] = try cell.clone(self.allocator);
                }
                try groups.put(key, .{
                    .cells = stored,
                    .count = if (include) 1 else 0,
                });
            }

            var group_it = groups.iterator();
            while (group_it.next()) |entry| {
                const state = entry.value_ptr.*;
                const out = try self.buildCountOutputRow(state.cells, state.count, count_clause.count_position);
                try result.rows.append(self.allocator, out);
            }

            var parsed_out_key_count: usize = 0;
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                parsed_out_key_count = out_keys.items.len;
                if (out_keys.items.len == 0) {
                    if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                } else {
                    if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
                }
            } else {
                if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
            }
            self.maybeSortDistinctEqualSuffixRows(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            );
            if (!self.maybeApplyDistinctNoKeyWindowParity(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            )) {
                self.applyResultWindow(result, result_skip, result_limit);
            }
            return;
        }

        if (projection_term_count != group_terms.items.len) return error.InvalidReturn;

        const RelProjectionSource = union(enum) {
            ref: ProjRef,
            scalar_expr: []const u8,
        };

        var projection_sources: std.ArrayList(RelProjectionSource) = .{};
        defer projection_sources.deinit(self.allocator);
        var alias_bindings: std.ArrayList(RelOrderAlias) = .{};
        defer alias_bindings.deinit(self.allocator);
        const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
        var implicit_param_alias_slot: usize = 6;

        for (group_terms.items) |group_term| {
            if (try self.resolveRelProjectionRefOptional(
                group_term.expr,
                head.left_var,
                head.right_var,
                head.rel_var,
                left_table,
                right_table,
                rel_table,
            )) |resolved_ref| {
                try projection_sources.append(self.allocator, .{ .ref = resolved_ref });
                if (!std.mem.eql(u8, group_term.alias, group_term.expr)) {
                    try alias_bindings.append(self.allocator, .{ .alias = group_term.alias, .ref = resolved_ref });
                }
                const resolved_ty = switch (resolved_ref.source) {
                    .left => left_table.columns.items[resolved_ref.col_idx].ty,
                    .right => right_table.columns.items[resolved_ref.col_idx].ty,
                    .rel => rel_table.columns.items[resolved_ref.col_idx].ty,
                };
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_term.alias));
                try result.types.append(self.allocator, typeName(resolved_ty));
                continue;
            }

            var output_alias = group_term.alias;
            var output_alias_owned = false;
            defer if (output_alias_owned) self.allocator.free(output_alias);
            if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                if (!param_lookup.present) {
                    output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                    output_alias_owned = true;
                }
            }

            const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
            var probe_cell = scalar.cell;
            probe_cell.deinit(self.allocator);
            try projection_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
            try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
            try result.types.append(self.allocator, scalar.type_name);
            implicit_param_alias_slot += 1;
        }

        if (!return_distinct) {
            if (order_expr) |order_text| {
                try self.parseRelOrderKeys(
                    order_text,
                    head.left_var,
                    head.right_var,
                    head.rel_var,
                    left_table,
                    right_table,
                    rel_table,
                    alias_bindings.items,
                    &order_keys,
                );
            }

            sortRelIndicesByOrderKeys(left_table, right_table, rel_table, order_keys.items, indices.items);
        }

        for (indices.items) |rel_idx| {
            const rel_row = rel_table.rows.items[rel_idx];
            const left_row = left_table.rows.items[rel_row.src_row];
            const right_row = right_table.rows.items[rel_row.dst_row];
            const out_row = try self.allocator.alloc(Cell, projection_sources.items.len);
            for (projection_sources.items, 0..) |projection_source, out_idx| {
                switch (projection_source) {
                    .ref => |ref| {
                        out_row[out_idx] = try Engine.relCellFor(ref, left_row, right_row, rel_row.props).clone(self.allocator);
                    },
                    .scalar_expr => |expr| {
                        const scalar = try self.evaluateReturnScalarExpr(expr, params);
                        out_row[out_idx] = scalar.cell;
                    },
                }
            }
            try result.rows.append(self.allocator, out_row);
        }
        if (return_distinct) {
            try self.dedupeResultRows(result);
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                if (out_keys.items.len > 0) {
                    sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                }
            }
        }
        self.applyResultWindow(result, result_skip, result_limit);
    }

    fn executeMatch(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        const head = try parseMatchHead(query);
        const table = self.node_tables.getPtr(head.table_name) orelse return error.TableNotFound;

        const return_keyword = "RETURN ";
        const where_keyword = "WHERE ";

        var where_text: ?[]const u8 = null;
        var return_part: []const u8 = undefined;

        if (indexOfAsciiNoCase(head.tail, where_keyword)) |where_idx| {
            const before_where = std.mem.trim(u8, head.tail[0..where_idx], " \t\n\r");
            if (before_where.len != 0) return error.InvalidMatch;
            const after_where = head.tail[where_idx + where_keyword.len ..];
            const return_idx_rel = indexOfAsciiNoCase(after_where, return_keyword) orelse return error.InvalidMatch;
            where_text = std.mem.trim(u8, after_where[0..return_idx_rel], " \t\n\r");
            return_part = std.mem.trim(u8, after_where[return_idx_rel + return_keyword.len ..], " \t\n\r");
        } else {
            const return_idx = indexOfAsciiNoCase(head.tail, return_keyword) orelse return error.InvalidMatch;
            const before_return = std.mem.trim(u8, head.tail[0..return_idx], " \t\n\r");
            if (before_return.len != 0) return error.InvalidMatch;
            return_part = std.mem.trim(u8, head.tail[return_idx + return_keyword.len ..], " \t\n\r");
        }

        try self.enforceSkipBeforeLimitParserParity(query, return_part);
        const pagination = try self.parsePaginationClause(query, return_part);
        const distinct_clause = try parseDistinctClause(pagination.body);
        const return_body = distinct_clause.body;
        const return_distinct = distinct_clause.distinct;
        const result_skip = pagination.skip;
        const result_limit = pagination.limit;

        var order_keys: std.ArrayList(NodeOrderKey) = .{};
        defer order_keys.deinit(self.allocator);
        const order_keyword = " ORDER BY ";
        var projection_part = return_body;
        var order_expr: ?[]const u8 = null;
        if (indexOfAsciiNoCase(return_body, order_keyword)) |order_idx| {
            projection_part = std.mem.trim(u8, return_body[0..order_idx], " \t\n\r");
            order_expr = std.mem.trim(u8, return_body[order_idx + order_keyword.len ..], " \t\n\r");
        }
        try self.validateProjectionTermsExplicitAs(query, projection_part);

        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        if ((self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
            error.InvalidCountDistinctStar => {
                try self.raiseCountDistinctStarProjectionError(query);
                unreachable;
            },
            else => return err,
        })) {
            var count_targets: std.ArrayList(NodeCountTarget) = .{};
            defer count_targets.deinit(self.allocator);
            for (count_terms.items) |count_term| {
                try count_targets.append(
                    self.allocator,
                    try self.parseNodeCountTarget(count_term.count_expr, head.var_name, table, params, count_term.distinct),
                );
            }

            const NodeGroupSource = union(enum) {
                column: usize,
                scalar_expr: []const u8,
            };

            var group_sources: std.ArrayList(NodeGroupSource) = .{};
            defer group_sources.deinit(self.allocator);
            var group_types: std.ArrayList([]const u8) = .{};
            defer group_types.deinit(self.allocator);
            for (group_terms.items) |group_term| {
                if (self.parsePropertyExprOptional(group_term.expr, head.var_name)) |col_name| {
                    const col_idx = try self.nodeColumnIndexOrBinderError(table, head.var_name, col_name);
                    const ty = try self.nodeColumnTypeOrBinderError(table, head.var_name, col_name);
                    try group_sources.append(self.allocator, .{ .column = col_idx });
                    try group_types.append(self.allocator, typeName(ty));
                    continue;
                }

                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                var probe_cell = scalar.cell;
                probe_cell.deinit(self.allocator);
                try group_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
                try group_types.append(self.allocator, scalar.type_name);
            }

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = 2;
            for (0..projection_term_count) |position| {
                if (Engine.findCountTermIndexByPosition(count_terms.items, position)) |count_idx| {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[count_idx].alias));
                    try result.types.append(self.allocator, "INT64");
                    implicit_param_alias_slot += 1;
                    continue;
                }
                if (Engine.findGroupTermIndexByPosition(group_terms.items, position)) |group_idx| {
                    const group_term = group_terms.items[group_idx];
                    var output_alias = group_term.alias;
                    var output_alias_owned = false;
                    defer if (output_alias_owned) self.allocator.free(output_alias);
                    if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                        const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                        if (!param_lookup.present) {
                            output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                            output_alias_owned = true;
                        }
                    }
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                    try result.types.append(self.allocator, group_types.items[group_idx]);
                    switch (group_sources.items[group_idx]) {
                        .scalar_expr => implicit_param_alias_slot += 1,
                        .column => {},
                    }
                    continue;
                }
                return error.InvalidReturn;
            }

            var filtered_indices: std.ArrayList(usize) = .{};
            defer filtered_indices.deinit(self.allocator);
            for (table.rows.items, 0..) |row, idx| {
                if (where_text) |wt| {
                    if (!(try self.evaluateNodeWhereExpression(table, head.var_name, wt, params, row))) continue;
                }
                try filtered_indices.append(self.allocator, idx);
            }

            if (group_terms.items.len == 0) {
                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                defer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                defer self.deinitSeenMaps(seen_maps);

                for (filtered_indices.items) |row_idx| {
                    const row = table.rows.items[row_idx];
                    try self.updateNodeCountAccumulators(row, count_terms.items, count_targets.items, counts, seen_maps);
                }

                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    &[_]Cell{},
                    count_terms.items,
                    counts,
                );
                try result.rows.append(self.allocator, out);
                self.applyResultWindow(result, result_skip, result_limit);
                return;
            }

            const GroupState = struct {
                cells: []Cell,
                counts: []i64,
                seen: []std.StringHashMap(void),
            };

            var groups = std.StringHashMap(GroupState).init(self.allocator);
            defer {
                var it = groups.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    for (entry.value_ptr.cells) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(entry.value_ptr.cells);
                    self.allocator.free(entry.value_ptr.counts);
                    self.deinitSeenMaps(entry.value_ptr.seen);
                }
                groups.deinit();
            }

            for (filtered_indices.items) |row_idx| {
                const row = table.rows.items[row_idx];

                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                for (group_sources.items) |group_source| {
                    switch (group_source) {
                        .column => |col_idx| {
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, row[col_idx]);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            var scalar_cell = scalar.cell;
                            defer scalar_cell.deinit(self.allocator);
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, scalar_cell);
                        },
                    }
                }
                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);

                if (groups.getPtr(key)) |existing| {
                    self.allocator.free(key);
                    try self.updateNodeCountAccumulators(row, count_terms.items, count_targets.items, existing.counts, existing.seen);
                    continue;
                }

                const stored = try self.allocator.alloc(Cell, group_sources.items.len);
                errdefer self.allocator.free(stored);
                for (group_sources.items, 0..) |group_source, i| {
                    switch (group_source) {
                        .column => |col_idx| {
                            stored[i] = try row[col_idx].clone(self.allocator);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            stored[i] = scalar.cell;
                        },
                    }
                }

                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                errdefer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                errdefer self.deinitSeenMaps(seen_maps);
                try self.updateNodeCountAccumulators(row, count_terms.items, count_targets.items, counts, seen_maps);

                try groups.put(key, .{
                    .cells = stored,
                    .counts = counts,
                    .seen = seen_maps,
                });
            }

            var group_it = groups.iterator();
            while (group_it.next()) |entry| {
                const state = entry.value_ptr.*;
                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    state.cells,
                    count_terms.items,
                    state.counts,
                );
                try result.rows.append(self.allocator, out);
            }

            var parsed_out_key_count: usize = 0;
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                parsed_out_key_count = out_keys.items.len;
                if (out_keys.items.len == 0) {
                    if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                } else {
                    if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
                }
            } else {
                if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
            }
            self.maybeSortDistinctEqualSuffixRows(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            );
            if (!self.maybeApplyDistinctNoKeyWindowParity(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            )) {
                self.applyResultWindow(result, result_skip, result_limit);
            }
            return;
        }

        if (try parseCountProjectionClause(projection_part)) |count_clause| {
            const count_target = try self.parseNodeCountTarget(
                count_clause.count_expr,
                head.var_name,
                table,
                params,
                count_clause.distinct,
            );

            var group_cols: std.ArrayList(usize) = .{};
            defer group_cols.deinit(self.allocator);
            var group_types: std.ArrayList(ColumnType) = .{};
            defer group_types.deinit(self.allocator);
            var group_names: std.ArrayList([]const u8) = .{};
            defer group_names.deinit(self.allocator);

            var term_idx: usize = 0;
            var group_iter = std.mem.splitScalar(u8, projection_part, ',');
            while (group_iter.next()) |raw_expr| {
                const term = try parseProjectionTerm(raw_expr);
                if (term_idx == count_clause.count_position) {
                    term_idx += 1;
                    continue;
                }

                const col_name = try self.parsePropertyExpr(term.expr, head.var_name);
                const col_idx = try self.nodeColumnIndexOrBinderError(table, head.var_name, col_name);
                const ty = try self.nodeColumnTypeOrBinderError(table, head.var_name, col_name);
                try group_cols.append(self.allocator, col_idx);
                try group_types.append(self.allocator, ty);
                try group_names.append(self.allocator, term.alias orelse term.expr);
                term_idx += 1;
            }
            if (term_idx != count_clause.term_count) return error.InvalidReturn;

            var group_out_idx: usize = 0;
            for (0..count_clause.term_count) |out_idx| {
                if (out_idx == count_clause.count_position) {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_clause.alias));
                    try result.types.append(self.allocator, "INT64");
                    continue;
                }
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_names.items[group_out_idx]));
                try result.types.append(self.allocator, typeName(group_types.items[group_out_idx]));
                group_out_idx += 1;
            }

            var filtered_indices: std.ArrayList(usize) = .{};
            defer filtered_indices.deinit(self.allocator);
            for (table.rows.items, 0..) |row, idx| {
                if (where_text) |wt| {
                    if (!(try self.evaluateNodeWhereExpression(table, head.var_name, wt, params, row))) continue;
                }
                try filtered_indices.append(self.allocator, idx);
            }

            if (count_clause.distinct) {
                if (group_cols.items.len == 0) {
                    var seen = std.StringHashMap(void).init(self.allocator);
                    defer {
                        var it = seen.iterator();
                        while (it.next()) |entry| {
                            self.allocator.free(entry.key_ptr.*);
                        }
                        seen.deinit();
                    }

                    var count_value: i64 = 0;
                    for (filtered_indices.items) |row_idx| {
                        const row = table.rows.items[row_idx];
                        var distinct_key_buf: std.ArrayList(u8) = .{};
                        defer distinct_key_buf.deinit(self.allocator);
                        const include = try self.appendNodeCountDistinctKey(count_target, row, &distinct_key_buf);
                        if (!include) continue;
                        const distinct_key = try distinct_key_buf.toOwnedSlice(self.allocator);
                        errdefer self.allocator.free(distinct_key);
                        if (seen.contains(distinct_key)) {
                            self.allocator.free(distinct_key);
                            continue;
                        }
                        try seen.put(distinct_key, {});
                        count_value += 1;
                    }

                    const out = try self.allocator.alloc(Cell, 1);
                    out[0] = .{ .int64 = count_value };
                    try result.rows.append(self.allocator, out);
                    self.applyResultWindow(result, result_skip, result_limit);
                    return;
                }

                const GroupStateDistinct = struct {
                    cells: []Cell,
                    count: i64,
                    seen: std.StringHashMap(void),
                };

                var groups = std.StringHashMap(GroupStateDistinct).init(self.allocator);
                defer {
                    var it = groups.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        for (entry.value_ptr.cells) |*cell| {
                            cell.deinit(self.allocator);
                        }
                        self.allocator.free(entry.value_ptr.cells);
                        var seen_it = entry.value_ptr.seen.iterator();
                        while (seen_it.next()) |seen_entry| {
                            self.allocator.free(seen_entry.key_ptr.*);
                        }
                        entry.value_ptr.seen.deinit();
                    }
                    groups.deinit();
                }

                for (filtered_indices.items) |row_idx| {
                    const row = table.rows.items[row_idx];

                    var group_key_buf: std.ArrayList(u8) = .{};
                    defer group_key_buf.deinit(self.allocator);
                    for (group_cols.items) |col_idx| {
                        try Engine.appendCellToGroupKey(self.allocator, &group_key_buf, row[col_idx]);
                    }
                    const group_key = try group_key_buf.toOwnedSlice(self.allocator);
                    errdefer self.allocator.free(group_key);

                    var distinct_key_buf: std.ArrayList(u8) = .{};
                    defer distinct_key_buf.deinit(self.allocator);
                    const include = try self.appendNodeCountDistinctKey(count_target, row, &distinct_key_buf);
                    const distinct_key_opt: ?[]u8 = if (include) blk: {
                        const owned = try distinct_key_buf.toOwnedSlice(self.allocator);
                        break :blk owned;
                    } else null;
                    if (distinct_key_opt) |owned_key| {
                        errdefer self.allocator.free(owned_key);
                    }

                    if (groups.getPtr(group_key)) |existing| {
                        self.allocator.free(group_key);
                        if (distinct_key_opt) |distinct_key| {
                            if (existing.seen.contains(distinct_key)) {
                                self.allocator.free(distinct_key);
                            } else {
                                try existing.seen.put(distinct_key, {});
                                existing.count += 1;
                            }
                        }
                        continue;
                    }

                    const stored = try self.allocator.alloc(Cell, group_cols.items.len);
                    errdefer self.allocator.free(stored);
                    for (group_cols.items, 0..) |col_idx, i| {
                        stored[i] = try row[col_idx].clone(self.allocator);
                    }

                    var seen_values = std.StringHashMap(void).init(self.allocator);
                    errdefer seen_values.deinit();
                    var initial_count: i64 = 0;
                    if (distinct_key_opt) |distinct_key| {
                        try seen_values.put(distinct_key, {});
                        initial_count = 1;
                    }

                    try groups.put(group_key, .{
                        .cells = stored,
                        .count = initial_count,
                        .seen = seen_values,
                    });
                }

                var group_it = groups.iterator();
                while (group_it.next()) |entry| {
                    const state = entry.value_ptr.*;
                    const out = try self.buildCountOutputRow(state.cells, state.count, count_clause.count_position);
                    try result.rows.append(self.allocator, out);
                }

                var parsed_out_key_count: usize = 0;
                if (order_expr) |order_text| {
                    var out_keys: std.ArrayList(OutputOrderKey) = .{};
                    defer out_keys.deinit(self.allocator);
                    try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                    parsed_out_key_count = out_keys.items.len;
                    if (out_keys.items.len == 0) {
                        if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                    } else {
                        if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
                    }
                } else {
                    if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                }
                self.maybeSortDistinctEqualSuffixRows(
                    result,
                    return_distinct,
                    order_expr != null,
                    parsed_out_key_count,
                    result_skip,
                    result_limit,
                );
                if (!self.maybeApplyDistinctNoKeyWindowParity(
                    result,
                    return_distinct,
                    order_expr != null,
                    parsed_out_key_count,
                    result_skip,
                    result_limit,
                )) {
                    self.applyResultWindow(result, result_skip, result_limit);
                }
                return;
            }

            if (group_cols.items.len == 0) {
                var count_value: i64 = 0;
                for (filtered_indices.items) |row_idx| {
                    const row = table.rows.items[row_idx];
                    if (Engine.nodeCountTargetIncludes(count_target, row)) {
                        count_value += 1;
                    }
                }
                const out = try self.allocator.alloc(Cell, 1);
                out[0] = .{ .int64 = count_value };
                try result.rows.append(self.allocator, out);
                self.applyResultWindow(result, result_skip, result_limit);
                return;
            }

            const GroupState = struct {
                cells: []Cell,
                count: i64,
            };

            var groups = std.StringHashMap(GroupState).init(self.allocator);
            defer {
                var it = groups.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    for (entry.value_ptr.cells) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(entry.value_ptr.cells);
                }
                groups.deinit();
            }

            for (filtered_indices.items) |row_idx| {
                const row = table.rows.items[row_idx];
                const include = Engine.nodeCountTargetIncludes(count_target, row);

                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                for (group_cols.items) |col_idx| {
                    try Engine.appendCellToGroupKey(self.allocator, &key_buf, row[col_idx]);
                }
                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);

                if (groups.getPtr(key)) |existing| {
                    if (include) {
                        existing.count += 1;
                    }
                    self.allocator.free(key);
                    continue;
                }

                const stored = try self.allocator.alloc(Cell, group_cols.items.len);
                errdefer self.allocator.free(stored);
                for (group_cols.items, 0..) |col_idx, i| {
                    stored[i] = try row[col_idx].clone(self.allocator);
                }
                try groups.put(key, .{
                    .cells = stored,
                    .count = if (include) 1 else 0,
                });
            }

            var group_it = groups.iterator();
            while (group_it.next()) |entry| {
                const state = entry.value_ptr.*;
                const out = try self.buildCountOutputRow(state.cells, state.count, count_clause.count_position);
                try result.rows.append(self.allocator, out);
            }

            var parsed_out_key_count: usize = 0;
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                parsed_out_key_count = out_keys.items.len;
                if (out_keys.items.len == 0) {
                    if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
                } else {
                    if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
                }
            } else {
                if (!return_distinct) sortResultRowsLexicographically(result.rows.items);
            }
            self.maybeSortDistinctEqualSuffixRows(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            );
            if (!self.maybeApplyDistinctNoKeyWindowParity(
                result,
                return_distinct,
                order_expr != null,
                parsed_out_key_count,
                result_skip,
                result_limit,
            )) {
                self.applyResultWindow(result, result_skip, result_limit);
            }
            return;
        }

        if (projection_term_count != group_terms.items.len) return error.InvalidReturn;

        const NodeProjectionSource = union(enum) {
            column: usize,
            scalar_expr: []const u8,
        };

        var projection_sources: std.ArrayList(NodeProjectionSource) = .{};
        defer projection_sources.deinit(self.allocator);
        var alias_bindings: std.ArrayList(NodeOrderAlias) = .{};
        defer alias_bindings.deinit(self.allocator);
        const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
        var implicit_param_alias_slot: usize = 2;

        for (group_terms.items) |group_term| {
            if (self.parsePropertyExprOptional(group_term.expr, head.var_name)) |col_name| {
                const col_idx = try self.nodeColumnIndexOrBinderError(table, head.var_name, col_name);
                const ty = try self.nodeColumnTypeOrBinderError(table, head.var_name, col_name);
                try projection_sources.append(self.allocator, .{ .column = col_idx });
                if (!std.mem.eql(u8, group_term.alias, group_term.expr)) {
                    try alias_bindings.append(self.allocator, .{ .alias = group_term.alias, .col_idx = col_idx });
                }
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_term.alias));
                try result.types.append(self.allocator, typeName(ty));
                continue;
            }

            var output_alias = group_term.alias;
            var output_alias_owned = false;
            defer if (output_alias_owned) self.allocator.free(output_alias);
            if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                if (!param_lookup.present) {
                    output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                    output_alias_owned = true;
                }
            }

            const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
            var probe_cell = scalar.cell;
            probe_cell.deinit(self.allocator);
            try projection_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
            try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
            try result.types.append(self.allocator, scalar.type_name);
            implicit_param_alias_slot += 1;
        }

        if (!return_distinct) {
            if (order_expr) |order_text| {
                try self.parseNodeOrderKeys(table, head.var_name, order_text, alias_bindings.items, &order_keys);
            }
        }

        var indices: std.ArrayList(usize) = .{};
        defer indices.deinit(self.allocator);

        for (table.rows.items, 0..) |row, idx| {
            if (where_text) |wt| {
                if (!(try self.evaluateNodeWhereExpression(table, head.var_name, wt, params, row))) continue;
            }
            try indices.append(self.allocator, idx);
        }

        if (!return_distinct) {
            sortNodeIndicesByOrderKeys(table, order_keys.items, indices.items);
        }

        for (indices.items) |row_idx| {
            const source = table.rows.items[row_idx];
            var out_row = try self.allocator.alloc(Cell, projection_sources.items.len);
            errdefer self.allocator.free(out_row);
            for (projection_sources.items, 0..) |projection_source, out_idx| {
                switch (projection_source) {
                    .column => |col_idx| {
                        out_row[out_idx] = try source[col_idx].clone(self.allocator);
                    },
                    .scalar_expr => |expr| {
                        const scalar = try self.evaluateReturnScalarExpr(expr, params);
                        out_row[out_idx] = scalar.cell;
                    },
                }
            }
            try result.rows.append(self.allocator, out_row);
        }
        if (return_distinct) {
            try self.dedupeResultRows(result);
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                if (out_keys.items.len > 0) {
                    sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                }
            }
        }
        self.applyResultWindow(result, result_skip, result_limit);
    }

    fn executeMatchRel(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        const head = try parseMatchRelHead(query);

        const left_table = self.node_tables.getPtr(head.left_table) orelse return error.TableNotFound;
        const right_table = self.node_tables.getPtr(head.right_table) orelse return error.TableNotFound;
        const rel_table = self.rel_tables.getPtr(head.rel_table) orelse return error.TableNotFound;

        if (!std.mem.eql(u8, rel_table.from_table, head.left_table)) return error.InvalidMatch;
        if (!std.mem.eql(u8, rel_table.to_table, head.right_table)) return error.InvalidMatch;

        const return_keyword = "RETURN ";
        const where_keyword = "WHERE ";
        var where_text: ?[]const u8 = null;
        var return_part: []const u8 = undefined;

        if (indexOfAsciiNoCase(head.tail, where_keyword)) |where_idx| {
            const before_where = std.mem.trim(u8, head.tail[0..where_idx], " \t\n\r");
            if (before_where.len != 0) return error.InvalidMatch;
            const after_where = head.tail[where_idx + where_keyword.len ..];
            const return_idx_rel = indexOfAsciiNoCase(after_where, return_keyword) orelse return error.InvalidMatch;
            where_text = std.mem.trim(u8, after_where[0..return_idx_rel], " \t\n\r");
            return_part = std.mem.trim(u8, after_where[return_idx_rel + return_keyword.len ..], " \t\n\r");
        } else {
            const return_idx = indexOfAsciiNoCase(head.tail, return_keyword) orelse return error.InvalidMatch;
            const before_return = std.mem.trim(u8, head.tail[0..return_idx], " \t\n\r");
            if (before_return.len != 0) return error.InvalidMatch;
            return_part = std.mem.trim(u8, head.tail[return_idx + return_keyword.len ..], " \t\n\r");
        }

        try self.enforceSkipBeforeLimitParserParity(query, return_part);
        const pagination = try self.parsePaginationClause(query, return_part);
        const distinct_clause = try parseDistinctClause(pagination.body);
        const return_body = distinct_clause.body;
        const return_distinct = distinct_clause.distinct;
        const result_skip = pagination.skip;
        const result_limit = pagination.limit;

        var order_keys: std.ArrayList(RelOrderKey) = .{};
        defer order_keys.deinit(self.allocator);
        const order_keyword = " ORDER BY ";
        var projection_part = return_body;
        var order_expr: ?[]const u8 = null;
        if (indexOfAsciiNoCase(return_body, order_keyword)) |order_idx| {
            projection_part = std.mem.trim(u8, return_body[0..order_idx], " \t\n\r");
            order_expr = std.mem.trim(u8, return_body[order_idx + order_keyword.len ..], " \t\n\r");
        }
        try self.validateProjectionTermsExplicitAs(query, projection_part);

        var projection_term_count: usize = 0;
        var count_terms: std.ArrayList(CountProjectionTerm) = .{};
        defer self.deinitCountProjectionTerms(&count_terms);
        var group_terms: std.ArrayList(GroupProjectionTerm) = .{};
        defer group_terms.deinit(self.allocator);
        if ((self.parseCountProjectionPlan(projection_part, &projection_term_count, &count_terms, &group_terms, params) catch |err| switch (err) {
            error.InvalidCountDistinctStar => {
                try self.raiseCountDistinctStarProjectionError(query);
                unreachable;
            },
            else => return err,
        })) {
            var count_targets: std.ArrayList(RelCountTarget) = .{};
            defer count_targets.deinit(self.allocator);
            for (count_terms.items) |count_term| {
                try count_targets.append(
                    self.allocator,
                    try self.parseRelCountTarget(
                        count_term.count_expr,
                        head.left_var,
                        head.right_var,
                        head.rel_var,
                        left_table,
                        right_table,
                        rel_table,
                        params,
                        count_term.distinct,
                    ),
                );
            }

            const RelGroupSource = union(enum) {
                ref: ProjRef,
                scalar_expr: []const u8,
            };

            var group_sources: std.ArrayList(RelGroupSource) = .{};
            defer group_sources.deinit(self.allocator);
            var group_types: std.ArrayList([]const u8) = .{};
            defer group_types.deinit(self.allocator);
            for (group_terms.items) |group_term| {
                if (try self.resolveRelProjectionRefOptional(
                    group_term.expr,
                    head.left_var,
                    head.right_var,
                    head.rel_var,
                    left_table,
                    right_table,
                    rel_table,
                )) |resolved_ref| {
                    const resolved_ty = switch (resolved_ref.source) {
                        .left => left_table.columns.items[resolved_ref.col_idx].ty,
                        .right => right_table.columns.items[resolved_ref.col_idx].ty,
                        .rel => rel_table.columns.items[resolved_ref.col_idx].ty,
                    };
                    try group_sources.append(self.allocator, .{ .ref = resolved_ref });
                    try group_types.append(self.allocator, typeName(resolved_ty));
                    continue;
                }

                const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
                var probe_cell = scalar.cell;
                probe_cell.deinit(self.allocator);
                try group_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
                try group_types.append(self.allocator, scalar.type_name);
            }

            const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
            var implicit_param_alias_slot: usize = 6;
            for (0..projection_term_count) |position| {
                if (Engine.findCountTermIndexByPosition(count_terms.items, position)) |count_idx| {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_terms.items[count_idx].alias));
                    try result.types.append(self.allocator, "INT64");
                    implicit_param_alias_slot += 1;
                    continue;
                }
                if (Engine.findGroupTermIndexByPosition(group_terms.items, position)) |group_idx| {
                    const group_term = group_terms.items[group_idx];
                    var output_alias = group_term.alias;
                    var output_alias_owned = false;
                    defer if (output_alias_owned) self.allocator.free(output_alias);
                    if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                        const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                        if (!param_lookup.present) {
                            output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                            output_alias_owned = true;
                        }
                    }
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
                    try result.types.append(self.allocator, group_types.items[group_idx]);
                    switch (group_sources.items[group_idx]) {
                        .scalar_expr => implicit_param_alias_slot += 1,
                        .ref => {},
                    }
                    continue;
                }
                return error.InvalidReturn;
            }

            var filtered_indices: std.ArrayList(usize) = .{};
            defer filtered_indices.deinit(self.allocator);
            for (rel_table.rows.items, 0..) |rel_row, idx| {
                if (where_text) |where_expr| {
                    if (!(try self.evaluateRelWhereExpression(
                        where_expr,
                        params,
                        head.left_var,
                        head.right_var,
                        head.rel_var,
                        left_table,
                        right_table,
                        rel_table,
                        left_table.rows.items[rel_row.src_row],
                        right_table.rows.items[rel_row.dst_row],
                        rel_row.props,
                    ))) continue;
                }
                try filtered_indices.append(self.allocator, idx);
            }

            if (group_terms.items.len == 0) {
                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                defer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                defer self.deinitSeenMaps(seen_maps);

                for (filtered_indices.items) |rel_idx| {
                    const rel_row = rel_table.rows.items[rel_idx];
                    const left_row = left_table.rows.items[rel_row.src_row];
                    const right_row = right_table.rows.items[rel_row.dst_row];
                    try self.updateRelCountAccumulators(left_row, right_row, rel_row.props, count_terms.items, count_targets.items, counts, seen_maps);
                }

                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    &[_]Cell{},
                    count_terms.items,
                    counts,
                );
                try result.rows.append(self.allocator, out);
                self.applyResultWindow(result, result_skip, result_limit);
                return;
            }

            const GroupState = struct {
                cells: []Cell,
                counts: []i64,
                seen: []std.StringHashMap(void),
            };

            var groups = std.StringHashMap(GroupState).init(self.allocator);
            defer {
                var it = groups.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    for (entry.value_ptr.cells) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(entry.value_ptr.cells);
                    self.allocator.free(entry.value_ptr.counts);
                    self.deinitSeenMaps(entry.value_ptr.seen);
                }
                groups.deinit();
            }

            for (filtered_indices.items) |rel_idx| {
                const rel_row = rel_table.rows.items[rel_idx];
                const left_row = left_table.rows.items[rel_row.src_row];
                const right_row = right_table.rows.items[rel_row.dst_row];

                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                for (group_sources.items) |group_source| {
                    switch (group_source) {
                        .ref => |gref| {
                            const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, cell);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            var scalar_cell = scalar.cell;
                            defer scalar_cell.deinit(self.allocator);
                            try Engine.appendCellToGroupKey(self.allocator, &key_buf, scalar_cell);
                        },
                    }
                }
                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);

                if (groups.getPtr(key)) |existing| {
                    self.allocator.free(key);
                    try self.updateRelCountAccumulators(
                        left_row,
                        right_row,
                        rel_row.props,
                        count_terms.items,
                        count_targets.items,
                        existing.counts,
                        existing.seen,
                    );
                    continue;
                }

                const stored = try self.allocator.alloc(Cell, group_sources.items.len);
                errdefer self.allocator.free(stored);
                for (group_sources.items, 0..) |group_source, i| {
                    switch (group_source) {
                        .ref => |gref| {
                            const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                            stored[i] = try cell.clone(self.allocator);
                        },
                        .scalar_expr => |expr| {
                            const scalar = try self.evaluateReturnScalarExpr(expr, params);
                            stored[i] = scalar.cell;
                        },
                    }
                }

                const counts = try self.allocator.alloc(i64, count_terms.items.len);
                errdefer self.allocator.free(counts);
                for (counts) |*count| {
                    count.* = 0;
                }

                const seen_maps = try self.initSeenMaps(count_terms.items);
                errdefer self.deinitSeenMaps(seen_maps);
                try self.updateRelCountAccumulators(
                    left_row,
                    right_row,
                    rel_row.props,
                    count_terms.items,
                    count_targets.items,
                    counts,
                    seen_maps,
                );

                try groups.put(key, .{
                    .cells = stored,
                    .counts = counts,
                    .seen = seen_maps,
                });
            }

            var group_it = groups.iterator();
            while (group_it.next()) |entry| {
                const state = entry.value_ptr.*;
                const out = try self.buildCountOutputRowFromTerms(
                    projection_term_count,
                    group_terms.items,
                    state.cells,
                    count_terms.items,
                    state.counts,
                );
                try result.rows.append(self.allocator, out);
            }

            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
            }
            self.applyResultWindow(result, result_skip, result_limit);
            return;
        }

        if (try parseCountProjectionClause(projection_part)) |count_clause| {
            const count_target = try self.parseRelCountTarget(
                count_clause.count_expr,
                head.left_var,
                head.right_var,
                head.rel_var,
                left_table,
                right_table,
                rel_table,
                params,
                count_clause.distinct,
            );

            var group_refs: std.ArrayList(ProjRef) = .{};
            defer group_refs.deinit(self.allocator);
            var group_types: std.ArrayList(ColumnType) = .{};
            defer group_types.deinit(self.allocator);
            var group_names: std.ArrayList([]const u8) = .{};
            defer group_names.deinit(self.allocator);

            var term_idx: usize = 0;
            var group_iter = std.mem.splitScalar(u8, projection_part, ',');
            while (group_iter.next()) |raw_expr| {
                const term = try parseProjectionTerm(raw_expr);
                if (term_idx == count_clause.count_position) {
                    term_idx += 1;
                    continue;
                }

                const resolved = try self.resolveRelProjectionRef(term.expr, head.left_var, head.right_var, head.rel_var, left_table, right_table, rel_table);
                try group_refs.append(self.allocator, resolved.ref);
                try group_types.append(self.allocator, resolved.ty);
                try group_names.append(self.allocator, term.alias orelse term.expr);
                term_idx += 1;
            }
            if (term_idx != count_clause.term_count) return error.InvalidReturn;

            var group_out_idx: usize = 0;
            for (0..count_clause.term_count) |out_idx| {
                if (out_idx == count_clause.count_position) {
                    try result.columns.append(self.allocator, try self.allocator.dupe(u8, count_clause.alias));
                    try result.types.append(self.allocator, "INT64");
                    continue;
                }
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_names.items[group_out_idx]));
                try result.types.append(self.allocator, typeName(group_types.items[group_out_idx]));
                group_out_idx += 1;
            }

            var filtered_indices: std.ArrayList(usize) = .{};
            defer filtered_indices.deinit(self.allocator);
            for (rel_table.rows.items, 0..) |rel_row, idx| {
                if (where_text) |where_expr| {
                    if (!(try self.evaluateRelWhereExpression(
                        where_expr,
                        params,
                        head.left_var,
                        head.right_var,
                        head.rel_var,
                        left_table,
                        right_table,
                        rel_table,
                        left_table.rows.items[rel_row.src_row],
                        right_table.rows.items[rel_row.dst_row],
                        rel_row.props,
                    ))) continue;
                }
                try filtered_indices.append(self.allocator, idx);
            }

            if (count_clause.distinct) {
                if (group_refs.items.len == 0) {
                    var seen = std.StringHashMap(void).init(self.allocator);
                    defer {
                        var it = seen.iterator();
                        while (it.next()) |entry| {
                            self.allocator.free(entry.key_ptr.*);
                        }
                        seen.deinit();
                    }

                    var count_value: i64 = 0;
                    for (filtered_indices.items) |rel_idx| {
                        const rel_row = rel_table.rows.items[rel_idx];
                        const left_row = left_table.rows.items[rel_row.src_row];
                        const right_row = right_table.rows.items[rel_row.dst_row];

                        var distinct_key_buf: std.ArrayList(u8) = .{};
                        defer distinct_key_buf.deinit(self.allocator);
                        const include = try self.appendRelCountDistinctKey(count_target, left_row, right_row, rel_row.props, &distinct_key_buf);
                        if (!include) continue;
                        const distinct_key = try distinct_key_buf.toOwnedSlice(self.allocator);
                        errdefer self.allocator.free(distinct_key);
                        if (seen.contains(distinct_key)) {
                            self.allocator.free(distinct_key);
                            continue;
                        }
                        try seen.put(distinct_key, {});
                        count_value += 1;
                    }

                    const out = try self.allocator.alloc(Cell, 1);
                    out[0] = .{ .int64 = count_value };
                    try result.rows.append(self.allocator, out);
                    self.applyResultWindow(result, result_skip, result_limit);
                    return;
                }

                const GroupStateDistinct = struct {
                    cells: []Cell,
                    count: i64,
                    seen: std.StringHashMap(void),
                };

                var groups = std.StringHashMap(GroupStateDistinct).init(self.allocator);
                defer {
                    var it = groups.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        for (entry.value_ptr.cells) |*cell| {
                            cell.deinit(self.allocator);
                        }
                        self.allocator.free(entry.value_ptr.cells);
                        var seen_it = entry.value_ptr.seen.iterator();
                        while (seen_it.next()) |seen_entry| {
                            self.allocator.free(seen_entry.key_ptr.*);
                        }
                        entry.value_ptr.seen.deinit();
                    }
                    groups.deinit();
                }

                for (filtered_indices.items) |rel_idx| {
                    const rel_row = rel_table.rows.items[rel_idx];
                    const left_row = left_table.rows.items[rel_row.src_row];
                    const right_row = right_table.rows.items[rel_row.dst_row];

                    var group_key_buf: std.ArrayList(u8) = .{};
                    defer group_key_buf.deinit(self.allocator);
                    for (group_refs.items) |gref| {
                        const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                        try Engine.appendCellToGroupKey(self.allocator, &group_key_buf, cell);
                    }
                    const group_key = try group_key_buf.toOwnedSlice(self.allocator);
                    errdefer self.allocator.free(group_key);

                    var distinct_key_buf: std.ArrayList(u8) = .{};
                    defer distinct_key_buf.deinit(self.allocator);
                    const include = try self.appendRelCountDistinctKey(count_target, left_row, right_row, rel_row.props, &distinct_key_buf);
                    const distinct_key_opt: ?[]u8 = if (include) blk: {
                        const owned = try distinct_key_buf.toOwnedSlice(self.allocator);
                        break :blk owned;
                    } else null;
                    if (distinct_key_opt) |owned_key| {
                        errdefer self.allocator.free(owned_key);
                    }

                    if (groups.getPtr(group_key)) |existing| {
                        self.allocator.free(group_key);
                        if (distinct_key_opt) |distinct_key| {
                            if (existing.seen.contains(distinct_key)) {
                                self.allocator.free(distinct_key);
                            } else {
                                try existing.seen.put(distinct_key, {});
                                existing.count += 1;
                            }
                        }
                        continue;
                    }

                    const stored = try self.allocator.alloc(Cell, group_refs.items.len);
                    errdefer self.allocator.free(stored);
                    for (group_refs.items, 0..) |gref, i| {
                        const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                        stored[i] = try cell.clone(self.allocator);
                    }

                    var seen_values = std.StringHashMap(void).init(self.allocator);
                    errdefer seen_values.deinit();
                    var initial_count: i64 = 0;
                    if (distinct_key_opt) |distinct_key| {
                        try seen_values.put(distinct_key, {});
                        initial_count = 1;
                    }

                    try groups.put(group_key, .{
                        .cells = stored,
                        .count = initial_count,
                        .seen = seen_values,
                    });
                }

                var group_it = groups.iterator();
                while (group_it.next()) |entry| {
                    const state = entry.value_ptr.*;
                    const out = try self.buildCountOutputRow(state.cells, state.count, count_clause.count_position);
                    try result.rows.append(self.allocator, out);
                }

                if (order_expr) |order_text| {
                    var out_keys: std.ArrayList(OutputOrderKey) = .{};
                    defer out_keys.deinit(self.allocator);
                    try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                    if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
                }
                self.applyResultWindow(result, result_skip, result_limit);
                return;
            }

            if (group_refs.items.len == 0) {
                var count_value: i64 = 0;
                for (filtered_indices.items) |rel_idx| {
                    const rel_row = rel_table.rows.items[rel_idx];
                    const left_row = left_table.rows.items[rel_row.src_row];
                    const right_row = right_table.rows.items[rel_row.dst_row];
                    if (Engine.relCountTargetIncludes(count_target, left_row, right_row, rel_row.props)) {
                        count_value += 1;
                    }
                }
                const out = try self.allocator.alloc(Cell, 1);
                out[0] = .{ .int64 = count_value };
                try result.rows.append(self.allocator, out);
                self.applyResultWindow(result, result_skip, result_limit);
                return;
            }

            const GroupState = struct {
                cells: []Cell,
                count: i64,
            };

            var groups = std.StringHashMap(GroupState).init(self.allocator);
            defer {
                var it = groups.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    for (entry.value_ptr.cells) |*cell| {
                        cell.deinit(self.allocator);
                    }
                    self.allocator.free(entry.value_ptr.cells);
                }
                groups.deinit();
            }

            for (filtered_indices.items) |rel_idx| {
                const rel_row = rel_table.rows.items[rel_idx];
                const left_row = left_table.rows.items[rel_row.src_row];
                const right_row = right_table.rows.items[rel_row.dst_row];
                const include = Engine.relCountTargetIncludes(count_target, left_row, right_row, rel_row.props);

                var key_buf: std.ArrayList(u8) = .{};
                defer key_buf.deinit(self.allocator);
                for (group_refs.items) |gref| {
                    const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                    try Engine.appendCellToGroupKey(self.allocator, &key_buf, cell);
                }
                const key = try key_buf.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(key);

                if (groups.getPtr(key)) |existing| {
                    if (include) {
                        existing.count += 1;
                    }
                    self.allocator.free(key);
                    continue;
                }

                const stored = try self.allocator.alloc(Cell, group_refs.items.len);
                errdefer self.allocator.free(stored);
                for (group_refs.items, 0..) |gref, i| {
                    const cell = Engine.relCellFor(gref, left_row, right_row, rel_row.props);
                    stored[i] = try cell.clone(self.allocator);
                }
                try groups.put(key, .{
                    .cells = stored,
                    .count = if (include) 1 else 0,
                });
            }

            var group_it = groups.iterator();
            while (group_it.next()) |entry| {
                const state = entry.value_ptr.*;
                const out = try self.buildCountOutputRow(state.cells, state.count, count_clause.count_position);
                try result.rows.append(self.allocator, out);
            }

            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
            }
            self.applyResultWindow(result, result_skip, result_limit);
            return;
        }

        if (projection_term_count != group_terms.items.len) return error.InvalidReturn;

        const RelProjectionSource = union(enum) {
            ref: ProjRef,
            scalar_expr: []const u8,
        };

        var projection_sources: std.ArrayList(RelProjectionSource) = .{};
        defer projection_sources.deinit(self.allocator);
        var alias_bindings: std.ArrayList(RelOrderAlias) = .{};
        defer alias_bindings.deinit(self.allocator);
        const implicit_param_aliases = Engine.shouldUseImplicitMissingParamAlias(params);
        var implicit_param_alias_slot: usize = 6;

        for (group_terms.items) |group_term| {
            if (try self.resolveRelProjectionRefOptional(
                group_term.expr,
                head.left_var,
                head.right_var,
                head.rel_var,
                left_table,
                right_table,
                rel_table,
            )) |resolved_ref| {
                try projection_sources.append(self.allocator, .{ .ref = resolved_ref });
                if (!std.mem.eql(u8, group_term.alias, group_term.expr)) {
                    try alias_bindings.append(self.allocator, .{ .alias = group_term.alias, .ref = resolved_ref });
                }
                const resolved_ty = switch (resolved_ref.source) {
                    .left => left_table.columns.items[resolved_ref.col_idx].ty,
                    .right => right_table.columns.items[resolved_ref.col_idx].ty,
                    .rel => rel_table.columns.items[resolved_ref.col_idx].ty,
                };
                try result.columns.append(self.allocator, try self.allocator.dupe(u8, group_term.alias));
                try result.types.append(self.allocator, typeName(resolved_ty));
                continue;
            }

            var output_alias = group_term.alias;
            var output_alias_owned = false;
            defer if (output_alias_owned) self.allocator.free(output_alias);
            if (!group_term.alias_explicit and implicit_param_aliases and group_term.expr.len > 0 and group_term.expr[0] == '$') {
                const param_lookup = try self.getParameterValueWithPresence(group_term.expr, params);
                if (!param_lookup.present) {
                    output_alias = try self.formatImplicitParamAlias(implicit_param_alias_slot);
                    output_alias_owned = true;
                }
            }

            const scalar = try self.evaluateReturnScalarExpr(group_term.expr, params);
            var probe_cell = scalar.cell;
            probe_cell.deinit(self.allocator);
            try projection_sources.append(self.allocator, .{ .scalar_expr = group_term.expr });
            try result.columns.append(self.allocator, try self.allocator.dupe(u8, output_alias));
            try result.types.append(self.allocator, scalar.type_name);
            implicit_param_alias_slot += 1;
        }

        if (!return_distinct) {
            if (order_expr) |order_text| {
                try self.parseRelOrderKeys(
                    order_text,
                    head.left_var,
                    head.right_var,
                    head.rel_var,
                    left_table,
                    right_table,
                    rel_table,
                    alias_bindings.items,
                    &order_keys,
                );
            }
        }

        var indices: std.ArrayList(usize) = .{};
        defer indices.deinit(self.allocator);
        for (rel_table.rows.items, 0..) |rel_row, idx| {
            if (where_text) |where_expr| {
                if (!(try self.evaluateRelWhereExpression(
                    where_expr,
                    params,
                    head.left_var,
                    head.right_var,
                    head.rel_var,
                    left_table,
                    right_table,
                    rel_table,
                    left_table.rows.items[rel_row.src_row],
                    right_table.rows.items[rel_row.dst_row],
                    rel_row.props,
                ))) continue;
            }
            try indices.append(self.allocator, idx);
        }

        if (!return_distinct) {
            sortRelIndicesByOrderKeys(left_table, right_table, rel_table, order_keys.items, indices.items);
        }

        for (indices.items) |rel_idx| {
            const rel_row = rel_table.rows.items[rel_idx];
            const left_row = left_table.rows.items[rel_row.src_row];
            const right_row = right_table.rows.items[rel_row.dst_row];

            const out_row = try self.allocator.alloc(Cell, projection_sources.items.len);
            for (projection_sources.items, 0..) |projection_source, out_idx| {
                switch (projection_source) {
                    .ref => |ref| {
                        out_row[out_idx] = try Engine.relCellFor(ref, left_row, right_row, rel_row.props).clone(self.allocator);
                    },
                    .scalar_expr => |expr| {
                        const scalar = try self.evaluateReturnScalarExpr(expr, params);
                        out_row[out_idx] = scalar.cell;
                    },
                }
            }
            try result.rows.append(self.allocator, out_row);
        }
        if (return_distinct) {
            try self.dedupeResultRows(result);
            if (order_expr) |order_text| {
                var out_keys: std.ArrayList(OutputOrderKey) = .{};
                defer out_keys.deinit(self.allocator);
                try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
                if (out_keys.items.len > 0) {
                    sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                }
            }
        }
        self.applyResultWindow(result, result_skip, result_limit);
    }

    fn executeMatchRelDelete(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
    ) !void {
        const head = try parseMatchRelHead(query);

        const left_table = self.node_tables.getPtr(head.left_table) orelse return error.TableNotFound;
        const right_table = self.node_tables.getPtr(head.right_table) orelse return error.TableNotFound;
        const rel_table = self.rel_tables.getPtr(head.rel_table) orelse return error.TableNotFound;

        if (!std.mem.eql(u8, rel_table.from_table, head.left_table)) return error.InvalidMatch;
        if (!std.mem.eql(u8, rel_table.to_table, head.right_table)) return error.InvalidMatch;

        const where_keyword = "WHERE ";
        const delete_keyword = "DELETE ";
        const delete_idx = indexOfAsciiNoCase(head.tail, delete_keyword) orelse return error.InvalidMatch;
        const delete_var = std.mem.trim(u8, head.tail[delete_idx + delete_keyword.len ..], " \t\n\r");

        var where_text: ?[]const u8 = null;
        if (indexOfAsciiNoCase(head.tail, where_keyword)) |where_idx| {
            if (where_idx >= delete_idx) return error.InvalidMatch;
            where_text = std.mem.trim(u8, head.tail[where_idx + where_keyword.len .. delete_idx], " \t\n\r");
        }

        if (std.mem.eql(u8, delete_var, head.left_var) or std.mem.eql(u8, delete_var, head.right_var)) {
            const deleting_left = std.mem.eql(u8, delete_var, head.left_var);
            for (rel_table.rows.items) |row| {
                var applies = true;
                if (where_text) |where_expr| {
                    applies = try self.evaluateRelWhereExpression(
                        where_expr,
                        params,
                        head.left_var,
                        head.right_var,
                        head.rel_var,
                        left_table,
                        right_table,
                        rel_table,
                        left_table.rows.items[row.src_row],
                        right_table.rows.items[row.dst_row],
                        row.props,
                    );
                }
                if (!applies) continue;
                const node_offset = if (deleting_left) row.src_row else row.dst_row;
                const direction = if (deleting_left) "fwd" else "bwd";
                try self.failUserFmt(
                    "Runtime exception: Node(nodeOffset: {d}) has connected edges in table {s} in the {s} direction, which cannot be deleted. Please delete the edges first or try DETACH DELETE.",
                    .{ node_offset, rel_table.name, direction },
                );
                unreachable;
            }
            return;
        }

        if (!std.mem.eql(u8, delete_var, head.rel_var)) {
            if (Engine.isIdentifierToken(delete_var)) {
                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{delete_var});
                unreachable;
            }
            return error.InvalidMatch;
        }

        var kept: std.ArrayList(RelRow) = .{};
        errdefer {
            for (kept.items) |*row| {
                row.deinit(self.allocator);
            }
            kept.deinit(self.allocator);
        }
        for (rel_table.rows.items) |row| {
            var should_delete = true;
            if (where_text) |where_expr| {
                should_delete = try self.evaluateRelWhereExpression(
                    where_expr,
                    params,
                    head.left_var,
                    head.right_var,
                    head.rel_var,
                    left_table,
                    right_table,
                    rel_table,
                    left_table.rows.items[row.src_row],
                    right_table.rows.items[row.dst_row],
                    row.props,
                );
            }

            if (should_delete) {
                var doomed = row;
                doomed.deinit(self.allocator);
                continue;
            }
            try kept.append(self.allocator, row);
        }

        rel_table.rows.deinit(self.allocator);
        rel_table.rows = kept;
    }

    fn executeMatchDelete(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
    ) !void {
        const head = try parseMatchHead(query);
        const table = self.node_tables.getPtr(head.table_name) orelse return error.TableNotFound;

        const where_keyword = "WHERE ";
        const detach_delete_keyword = "DETACH DELETE ";
        const delete_keyword = "DELETE ";

        var detach = false;
        var delete_idx: usize = undefined;
        var delete_len: usize = undefined;
        if (indexOfAsciiNoCase(head.tail, detach_delete_keyword)) |idx| {
            detach = true;
            delete_idx = idx;
            delete_len = detach_delete_keyword.len;
        } else if (indexOfAsciiNoCase(head.tail, delete_keyword)) |idx| {
            delete_idx = idx;
            delete_len = delete_keyword.len;
        } else {
            return error.InvalidMatch;
        }

        const delete_var = std.mem.trim(u8, head.tail[delete_idx + delete_len ..], " \t\n\r");
        if (!std.mem.eql(u8, delete_var, head.var_name)) {
            if (Engine.isIdentifierToken(delete_var)) {
                try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{delete_var});
                unreachable;
            }
            return error.InvalidMatch;
        }

        var where_text: ?[]const u8 = null;
        if (indexOfAsciiNoCase(head.tail, where_keyword)) |where_idx| {
            if (where_idx >= delete_idx) return error.InvalidMatch;
            where_text = std.mem.trim(u8, head.tail[where_idx + where_keyword.len .. delete_idx], " \t\n\r");
        }

        if (table.rows.items.len == 0) return;
        const row_count = table.rows.items.len;

        var to_delete = try self.allocator.alloc(bool, row_count);
        defer self.allocator.free(to_delete);
        for (to_delete) |*flag| {
            flag.* = false;
        }
        for (table.rows.items, 0..) |row, i| {
            if (where_text) |wt| {
                if (!(try self.evaluateNodeWhereExpression(table, head.var_name, wt, params, row))) continue;
            }
            to_delete[i] = true;
        }

        var old_to_new = try self.allocator.alloc(usize, row_count);
        defer self.allocator.free(old_to_new);
        const invalid_index = std.math.maxInt(usize);
        var new_idx: usize = 0;
        for (to_delete, 0..) |flag, i| {
            if (flag) {
                old_to_new[i] = invalid_index;
            } else {
                old_to_new[i] = new_idx;
                new_idx += 1;
            }
        }

        var rel_it = self.rel_tables.iterator();
        while (rel_it.next()) |entry| {
            const rel_table = entry.value_ptr;
            const affects_src = std.mem.eql(u8, rel_table.from_table, table.name);
            const affects_dst = std.mem.eql(u8, rel_table.to_table, table.name);
            if (!affects_src and !affects_dst) continue;

            if (!detach) {
                for (rel_table.rows.items) |rel_row| {
                    const src_deleted = affects_src and to_delete[rel_row.src_row];
                    const dst_deleted = affects_dst and to_delete[rel_row.dst_row];
                    if (src_deleted or dst_deleted) {
                        if (src_deleted) {
                            try self.failUserFmt(
                                "Runtime exception: Node(nodeOffset: {d}) has connected edges in table {s} in the fwd direction, which cannot be deleted. Please delete the edges first or try DETACH DELETE.",
                                .{ rel_row.src_row, rel_table.name },
                            );
                            unreachable;
                        }
                        try self.failUserFmt(
                            "Runtime exception: Node(nodeOffset: {d}) has connected edges in table {s} in the bwd direction, which cannot be deleted. Please delete the edges first or try DETACH DELETE.",
                            .{ rel_row.dst_row, rel_table.name },
                        );
                        unreachable;
                    }
                }
            }

            var kept_rel: std.ArrayList(RelRow) = .{};
            errdefer {
                for (kept_rel.items) |*row| {
                    row.deinit(self.allocator);
                }
                kept_rel.deinit(self.allocator);
            }
            for (rel_table.rows.items) |rel_row| {
                const src_deleted = affects_src and to_delete[rel_row.src_row];
                const dst_deleted = affects_dst and to_delete[rel_row.dst_row];
                if (detach and (src_deleted or dst_deleted)) {
                    var doomed_rel = rel_row;
                    doomed_rel.deinit(self.allocator);
                    continue;
                }

                var next_rel = rel_row;
                if (affects_src) {
                    const mapped = old_to_new[next_rel.src_row];
                    if (mapped == invalid_index) return error.ConstraintViolation;
                    next_rel.src_row = mapped;
                }
                if (affects_dst) {
                    const mapped = old_to_new[next_rel.dst_row];
                    if (mapped == invalid_index) return error.ConstraintViolation;
                    next_rel.dst_row = mapped;
                }
                try kept_rel.append(self.allocator, next_rel);
            }

            rel_table.rows.deinit(self.allocator);
            rel_table.rows = kept_rel;
        }

        var kept_rows: std.ArrayList([]Cell) = .{};
        errdefer {
            for (kept_rows.items) |row| {
                for (row) |*cell| {
                    cell.deinit(self.allocator);
                }
                self.allocator.free(row);
            }
            kept_rows.deinit(self.allocator);
        }
        for (table.rows.items, 0..) |row, i| {
            if (to_delete[i]) {
                for (row) |*cell| {
                    cell.deinit(self.allocator);
                }
                self.allocator.free(row);
                continue;
            }
            try kept_rows.append(self.allocator, row);
        }

        table.rows.deinit(self.allocator);
        table.rows = kept_rows;
    }

    fn evaluateReturnScalarExpr(
        self: *Engine,
        literal_text: []const u8,
        params: ?*const std.json.ObjectMap,
    ) !struct { cell: Cell, type_name: []const u8, default_alias: []const u8 } {
        if (Engine.parsePropertyAccessExpr(literal_text)) |property_expr| {
            try self.failUserFmt("Binder exception: Variable {s} is not in scope.", .{property_expr.var_name});
            unreachable;
        }

        if (literal_text.len > 0 and literal_text[0] == '$') {
            const param_lookup = try self.getParameterValueWithPresence(literal_text, params);
            const json_value = param_lookup.value;
            return switch (json_value) {
                .null => .{
                    .cell = .null,
                    .type_name = "STRING",
                    .default_alias = literal_text,
                },
                .string => |s| .{
                    .cell = .{ .string = try self.allocator.dupe(u8, s) },
                    .type_name = "STRING",
                    .default_alias = literal_text,
                },
                .integer => |i| .{
                    .cell = .{ .int64 = @intCast(i) },
                    .type_name = inferParamIntegerTypeName(i),
                    .default_alias = literal_text,
                },
                .bool => |b| .{
                    .cell = .{ .int64 = if (b) 1 else 0 },
                    .type_name = "BOOL",
                    .default_alias = literal_text,
                },
                .float => |f| .{
                    .cell = .{ .float64 = f },
                    .type_name = "DOUBLE",
                    .default_alias = literal_text,
                },
                else => error.UnsupportedParameterType,
            };
        }

        if (std.ascii.eqlIgnoreCase(literal_text, "true")) {
            return .{
                .cell = .{ .int64 = 1 },
                .type_name = "BOOL",
                .default_alias = "True",
            };
        }
        if (std.ascii.eqlIgnoreCase(literal_text, "false")) {
            return .{
                .cell = .{ .int64 = 0 },
                .type_name = "BOOL",
                .default_alias = "False",
            };
        }

        const literal = try parseLiteral(literal_text);
        return switch (literal) {
            .null => .{
                .cell = .null,
                .type_name = "STRING",
                .default_alias = "",
            },
            .string => |s| .{
                .cell = .{ .string = try self.allocator.dupe(u8, s) },
                .type_name = "STRING",
                .default_alias = s,
            },
            .int64 => |v| .{
                .cell = .{ .int64 = v },
                .type_name = "INT64",
                .default_alias = literal_text,
            },
            .uint64 => |v| .{
                .cell = .{ .uint64 = v },
                .type_name = "UINT64",
                .default_alias = literal_text,
            },
            .bool => |b| .{
                .cell = .{ .int64 = if (b) 1 else 0 },
                .type_name = "BOOL",
                .default_alias = if (b) "True" else "False",
            },
            .float64 => |v| .{
                .cell = .{ .float64 = v },
                .type_name = "DOUBLE",
                .default_alias = literal_text,
            },
        };
    }

    fn executeReturn(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        const body = std.mem.trim(u8, query[7..], " \t\n\r");
        if (endsWithAsciiNoCase(body, " AS")) {
            try self.raiseTopReturnRegularQueryParserError(query);
            unreachable;
        }
        if (endsWithAsciiNoCase(body, " SKIP")) {
            if (indexOfAsciiNoCase(body, " LIMIT ") != null) {
                if (indexOfAsciiNoCase(query, " SKIP")) |skip_idx| {
                    try self.raiseSkipAfterLimitParserError(query, skip_idx + 1);
                    unreachable;
                }
            }
            try self.raiseTopReturnRegularQueryParserError(query);
            unreachable;
        }
        if (endsWithAsciiNoCase(body, " LIMIT")) {
            try self.raiseTopReturnRegularQueryParserError(query);
            unreachable;
        }
        try self.enforceSkipBeforeLimitParserParity(query, body);
        const pagination = try self.parsePaginationClause(query, body);
        const distinct_clause = try parseDistinctClause(pagination.body);
        const return_distinct = distinct_clause.distinct;
        const result_skip = pagination.skip;
        const result_limit = pagination.limit;

        const order_keyword = " ORDER BY ";
        var projection_part = distinct_clause.body;
        var order_expr: ?[]const u8 = null;
        if (indexOfAsciiNoCase(distinct_clause.body, order_keyword)) |order_idx| {
            projection_part = std.mem.trim(u8, distinct_clause.body[0..order_idx], " \t\n\r");
            order_expr = std.mem.trim(u8, distinct_clause.body[order_idx + order_keyword.len ..], " \t\n\r");
        }
        try self.validateProjectionTermsExplicitAs(query, projection_part);

        var projection_terms = try self.splitTopLevelProjectionTerms(projection_part);
        defer projection_terms.deinit(self.allocator);

        const row = try self.allocator.alloc(Cell, projection_terms.items.len);
        var initialized_cells: usize = 0;
        errdefer {
            for (row[0..initialized_cells]) |*cell| {
                cell.deinit(self.allocator);
            }
            self.allocator.free(row);
        }

        for (projection_terms.items, 0..) |raw_term, idx| {
            const projection_term = try parseProjectionTerm(raw_term);

            var out_cell: Cell = .null;
            var type_name: []const u8 = undefined;
            var alias: []const u8 = undefined;
            var alias_allocated = false;
            var out_cell_owned = true;
            errdefer {
                if (alias_allocated) self.allocator.free(alias);
                if (out_cell_owned) out_cell.deinit(self.allocator);
            }

            if (parseCountTermExpr(projection_term.expr) catch |err| switch (err) {
                error.InvalidCountDistinctStar => {
                    try self.raiseTopReturnCountDistinctStarParserError(query);
                    unreachable;
                },
                else => return err,
            }) |count_term| {
                var fallback_to_scalar = false;
                if (count_term.count_expr.len > 0 and count_term.count_expr[0] == '$') {
                    const param_lookup = try self.getParameterValueWithPresence(count_term.count_expr, params);
                    fallback_to_scalar = !param_lookup.present;
                }

                if (fallback_to_scalar) {
                    const scalar = try self.evaluateReturnScalarExpr(count_term.count_expr, params);
                    out_cell = scalar.cell;
                    type_name = scalar.type_name;
                    if (projection_term.alias) |explicit_alias| {
                        alias = explicit_alias;
                    } else {
                        if (Engine.shouldUseImplicitMissingParamAlias(params)) {
                            alias = try self.formatImplicitParamAlias(idx);
                            alias_allocated = true;
                        } else {
                            alias = count_term.count_expr;
                        }
                    }
                } else {
                    var count_value: i64 = 0;
                    if (std.mem.eql(u8, count_term.count_expr, "*")) {
                        count_value = 1;
                    } else {
                        const scalar = try self.evaluateReturnScalarExpr(count_term.count_expr, params);
                        var scalar_cell = scalar.cell;
                        defer scalar_cell.deinit(self.allocator);
                        if (cellIsNull(scalar_cell)) {
                            try self.failCountAnyBinderError(count_term.distinct);
                            unreachable;
                        }
                        count_value = 1;
                    }

                    out_cell = .{ .int64 = count_value };
                    type_name = "INT64";
                    if (projection_term.alias) |explicit_alias| {
                        alias = explicit_alias;
                    } else {
                        alias = try self.formatCountOutputName(count_term.count_expr, count_term.distinct);
                        alias_allocated = true;
                    }
                }
            } else {
                const scalar = try self.evaluateReturnScalarExpr(projection_term.expr, params);
                out_cell = scalar.cell;
                type_name = scalar.type_name;
                if (projection_term.alias) |explicit_alias| {
                    alias = explicit_alias;
                } else if (projection_term.expr.len > 0 and projection_term.expr[0] == '$') {
                    const param_lookup = try self.getParameterValueWithPresence(projection_term.expr, params);
                    if (!param_lookup.present and Engine.shouldUseImplicitMissingParamAlias(params)) {
                        alias = try self.formatImplicitParamAlias(idx);
                        alias_allocated = true;
                    } else {
                        alias = scalar.default_alias;
                    }
                } else {
                    alias = scalar.default_alias;
                    if (std.mem.eql(u8, scalar.type_name, "DOUBLE")) {
                        if (parseLiteral(projection_term.expr)) |lit| {
                            switch (lit) {
                                .float64 => |v| {
                                    alias = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{v});
                                    alias_allocated = true;
                                },
                                else => {},
                            }
                        } else |_| {}
                    }
                }
            }

            try result.columns.append(self.allocator, try self.allocator.dupe(u8, alias));
            try result.types.append(self.allocator, type_name);
            row[idx] = out_cell;
            out_cell_owned = false;
            initialized_cells += 1;
        }

        try result.rows.append(self.allocator, row);

        if (return_distinct) {
            try self.dedupeResultRows(result);
        }
        if (order_expr) |order_text| {
            var out_keys: std.ArrayList(OutputOrderKey) = .{};
            defer out_keys.deinit(self.allocator);
            try self.parseOutputOrderKeys(order_text, result.columns.items, result.types.items, &out_keys);
            if (return_distinct) {
                        sortResultRowsByOutputKeysDistinctTieDesc(result.rows.items, out_keys.items);
                    } else {
                        sortResultRowsByOutputKeys(result.rows.items, out_keys.items);
                    }
        }
        self.applyResultWindow(result, result_skip, result_limit);
    }
};

fn escapeJsonString(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

fn writeError(writer: anytype, message: []const u8) !void {
    try writer.writeAll("{\"status\":\"error\",\"error\":\"");
    try escapeJsonString(writer, message);
    try writer.writeAll("\"}\n");
}

fn writeOk(writer: anytype, result: *const ResultSet) !void {
    try writer.writeAll("{\"status\":\"ok\",\"columns\":[");
    for (result.columns.items, 0..) |col, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try escapeJsonString(writer, col);
        try writer.writeByte('"');
    }

    try writer.writeAll("],\"types\":[");
    for (result.types.items, 0..) |ty, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try escapeJsonString(writer, ty);
        try writer.writeByte('"');
    }

    try writer.writeAll("],\"rows\":[");
    for (result.rows.items, 0..) |row, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('[');
        for (row, 0..) |cell, j| {
            if (j > 0) try writer.writeByte(',');
            switch (cell) {
                .null => try writer.writeAll("null"),
                .int64 => |v| {
                    if (j < result.types.items.len and std.mem.eql(u8, result.types.items[j], "BOOL")) {
                        try writer.writeAll(if (v == 0) "false" else "true");
                    } else {
                        try writer.print("{d}", .{v});
                    }
                },
                .uint64 => |v| {
                    try writer.print("{d}", .{v});
                },
                .float64 => |v| {
                    try writer.print("{d}", .{v});
                },
                .string => |s| {
                    try writer.writeByte('"');
                    try escapeJsonString(writer, s);
                    try writer.writeByte('"');
                },
            }
        }
        try writer.writeByte(']');
    }

    try writer.writeAll("]}\n");
}

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    var engine = Engine.init(allocator);
    defer engine.deinit();

    const stdin = std.fs.File.stdin().deprecatedReader();
    const writer = std.fs.File.stdout().deprecatedWriter();

    while (try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024 * 1024)) |line| {
        defer allocator.free(line);
        const trimmed = std.mem.trim(u8, line, " \t\n\r");
        if (trimmed.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| {
            try writeError(writer, @errorName(err));
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            try writeError(writer, "InvalidRequest");
            continue;
        }

        const obj = parsed.value.object;

        if (obj.get("action")) |act| {
            if (act == .string and std.mem.eql(u8, act.string, "shutdown")) {
                try writer.writeAll("{\"status\":\"ok\"}\n");
                return;
            }
        }

        const query_value = obj.get("query") orelse {
            try writeError(writer, "MissingQuery");
            continue;
        };
        if (query_value != .string) {
            try writeError(writer, "InvalidQuery");
            continue;
        }

        var params_obj: ?*const std.json.ObjectMap = null;
        if (obj.get("parameters")) |params| {
            if (params == .object) {
                params_obj = &params.object;
            }
        }

        var result = ResultSet.init(allocator);
        defer result.deinit();

        engine.execute(query_value.string, params_obj, &result) catch |err| {
            if (err == error.UserVisibleError and engine.last_error_message != null) {
                try writeError(writer, engine.last_error_message.?);
            } else {
                try writeError(writer, @errorName(err));
            }
            engine.clearLastErrorMessage();
            continue;
        };

        try writeOk(writer, &result);
        engine.clearLastErrorMessage();
    }
}
