const std = @import("std");

const ColumnType = enum {
    STRING,
    INT64,
};

const Cell = union(enum) {
    null,
    string: []u8,
    int64: i64,

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

const ParsedLiteral = union(enum) {
    string: []const u8,
    int64: i64,
};

const FilterValue = union(enum) {
    string: []const u8,
    int64: i64,
};

const Filter = struct {
    column_idx: usize,
    value: FilterValue,
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
    tables: std.StringHashMap(Table),

    fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .allocator = allocator,
            .tables = std.StringHashMap(Table).init(allocator),
        };
    }

    fn deinit(self: *Engine) void {
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.tables.deinit();
    }

    fn execute(self: *Engine, query_in: []const u8, params: ?*const std.json.ObjectMap, result: *ResultSet) !void {
        const query = std.mem.trim(u8, query_in, " \t\n\r;");

        if (std.mem.startsWith(u8, query, "CREATE NODE TABLE ")) {
            try self.executeCreateNodeTable(query);
            return;
        }

        if (std.mem.startsWith(u8, query, "CREATE (:")) {
            try self.executeCreateNode(query);
            return;
        }

        if (std.mem.startsWith(u8, query, "MATCH (")) {
            try self.executeMatch(query, params, result);
            return;
        }

        if (std.mem.startsWith(u8, query, "RETURN ")) {
            try self.executeReturn(query, params, result);
            return;
        }

        return error.UnsupportedQuery;
    }

    fn executeCreateNodeTable(self: *Engine, query: []const u8) !void {
        const prefix = "CREATE NODE TABLE ";
        const after_prefix = query[prefix.len..];
        const open_idx_rel = std.mem.indexOfScalar(u8, after_prefix, '(') orelse return error.InvalidCreateTable;
        const close_idx = std.mem.lastIndexOfScalar(u8, query, ')') orelse return error.InvalidCreateTable;

        const table_name = std.mem.trim(u8, after_prefix[0..open_idx_rel], " \t\n\r");
        if (table_name.len == 0) return error.InvalidCreateTable;

        var table = try Table.init(self.allocator, table_name);
        errdefer table.deinit();

        const open_idx = prefix.len + open_idx_rel;
        const inner = query[open_idx + 1 .. close_idx];

        var iter = std.mem.splitScalar(u8, inner, ',');
        while (iter.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t\n\r");
            if (part.len == 0) continue;

            if (std.mem.startsWith(u8, part, "PRIMARY KEY(")) {
                const pk_close = std.mem.lastIndexOfScalar(u8, part, ')') orelse return error.InvalidCreateTable;
                const pk_name = std.mem.trim(u8, part[12..pk_close], " \t\n\r");
                table.primary_key = try self.allocator.dupe(u8, pk_name);
                continue;
            }

            var token_iter = std.mem.tokenizeScalar(u8, part, ' ');
            const col_name = token_iter.next() orelse return error.InvalidCreateTable;
            const col_type = token_iter.next() orelse return error.InvalidCreateTable;

            const ty: ColumnType = if (std.mem.eql(u8, col_type, "STRING"))
                .STRING
            else if (std.mem.eql(u8, col_type, "INT64"))
                .INT64
            else
                return error.UnsupportedType;

            try table.columns.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, col_name),
                .ty = ty,
            });
        }

        const key = try self.allocator.dupe(u8, table_name);
        errdefer self.allocator.free(key);

        if (self.tables.getPtr(table_name)) |existing| {
            existing.deinit();
            _ = self.tables.remove(table_name);
        }

        try self.tables.put(key, table);
    }

    fn parseLiteral(text: []const u8) !ParsedLiteral {
        const trimmed = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') {
            return .{ .string = trimmed[1 .. trimmed.len - 1] };
        }
        return .{ .int64 = try std.fmt.parseInt(i64, trimmed, 10) };
    }

    fn executeCreateNode(self: *Engine, query: []const u8) !void {
        const label_start = 9; // after "CREATE (:"
        const brace_idx = std.mem.indexOfScalar(u8, query, '{') orelse return error.InvalidCreateNode;
        if (brace_idx <= label_start) return error.InvalidCreateNode;

        const table_name = std.mem.trim(u8, query[label_start..brace_idx], " \t\n\r");
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;

        const close_brace = std.mem.lastIndexOfScalar(u8, query, '}') orelse return error.InvalidCreateNode;
        if (close_brace <= brace_idx) return error.InvalidCreateNode;
        const inner = query[brace_idx + 1 .. close_brace];

        var row = try self.allocator.alloc(Cell, table.columns.items.len);
        errdefer self.allocator.free(row);
        for (row) |*cell| {
            cell.* = .null;
        }

        var props = std.mem.splitScalar(u8, inner, ',');
        while (props.next()) |raw_prop| {
            const prop = std.mem.trim(u8, raw_prop, " \t\n\r");
            if (prop.len == 0) continue;

            const colon_idx = std.mem.indexOfScalar(u8, prop, ':') orelse return error.InvalidCreateNode;
            const key = std.mem.trim(u8, prop[0..colon_idx], " \t\n\r");
            const value_text = prop[colon_idx + 1 ..];
            const literal = try parseLiteral(value_text);

            const col_idx = table.columnIndex(key) orelse return error.ColumnNotFound;
            const expected = table.columns.items[col_idx].ty;

            switch (literal) {
                .string => |s| {
                    if (expected != .STRING) return error.TypeMismatch;
                    row[col_idx] = .{ .string = try self.allocator.dupe(u8, s) };
                },
                .int64 => |v| {
                    if (expected != .INT64) return error.TypeMismatch;
                    row[col_idx] = .{ .int64 = v };
                },
            }
        }

        try table.rows.append(self.allocator, row);
    }

    fn parseMatchHead(query: []const u8) !struct { var_name: []const u8, table_name: []const u8, tail: []const u8 } {
        if (!std.mem.startsWith(u8, query, "MATCH (")) return error.InvalidMatch;
        const close_idx = std.mem.indexOfScalar(u8, query, ')') orelse return error.InvalidMatch;
        const head = query[7..close_idx]; // var:Table
        const colon_idx = std.mem.indexOfScalar(u8, head, ':') orelse return error.InvalidMatch;
        const var_name = std.mem.trim(u8, head[0..colon_idx], " \t\n\r");
        const table_name = std.mem.trim(u8, head[colon_idx + 1 ..], " \t\n\r");
        const tail = std.mem.trim(u8, query[close_idx + 1 ..], " \t\n\r");
        return .{ .var_name = var_name, .table_name = table_name, .tail = tail };
    }

    fn parseFilter(self: *Engine, table: *const Table, var_name: []const u8, where_text: []const u8, params: ?*const std.json.ObjectMap) !Filter {
        const eq_idx = std.mem.indexOf(u8, where_text, "=") orelse return error.InvalidWhere;
        const lhs = std.mem.trim(u8, where_text[0..eq_idx], " \t\n\r");
        const rhs = std.mem.trim(u8, where_text[eq_idx + 1 ..], " \t\n\r");

        const expected_prefix = try std.fmt.allocPrint(self.allocator, "{s}.", .{var_name});
        defer self.allocator.free(expected_prefix);
        if (!std.mem.startsWith(u8, lhs, expected_prefix)) return error.InvalidWhere;
        const col_name = lhs[expected_prefix.len..];
        const col_idx = table.columnIndex(col_name) orelse return error.ColumnNotFound;

        var value: FilterValue = undefined;
        if (rhs.len > 0 and rhs[0] == '$') {
            const key = rhs[1..];
            const obj = params orelse return error.MissingParameter;
            const json_value = obj.get(key) orelse return error.MissingParameter;
            switch (json_value) {
                .string => |s| value = .{ .string = s },
                .integer => |i| value = .{ .int64 = @intCast(i) },
                else => return error.UnsupportedParameterType,
            }
        } else {
            const literal = try parseLiteral(rhs);
            value = switch (literal) {
                .string => |s| .{ .string = s },
                .int64 => |v| .{ .int64 = v },
            };
        }

        return .{ .column_idx = col_idx, .value = value };
    }

    fn rowMatchesFilter(row: []const Cell, filter: Filter) bool {
        const cell = row[filter.column_idx];
        return switch (filter.value) {
            .string => |s| switch (cell) {
                .string => |cs| std.mem.eql(u8, cs, s),
                else => false,
            },
            .int64 => |v| switch (cell) {
                .int64 => |cv| cv == v,
                else => false,
            },
        };
    }

    fn typeName(ty: ColumnType) []const u8 {
        return switch (ty) {
            .STRING => "STRING",
            .INT64 => "INT64",
        };
    }

    fn parsePropertyExpr(self: *Engine, expr: []const u8, var_name: []const u8) ![]const u8 {
        const expected_prefix = try std.fmt.allocPrint(self.allocator, "{s}.", .{var_name});
        defer self.allocator.free(expected_prefix);
        const trimmed = std.mem.trim(u8, expr, " \t\n\r");
        if (!std.mem.startsWith(u8, trimmed, expected_prefix)) return error.InvalidReturn;
        return trimmed[expected_prefix.len..];
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

    fn executeMatch(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        const head = try parseMatchHead(query);
        const table = self.tables.getPtr(head.table_name) orelse return error.TableNotFound;

        const return_keyword = "RETURN ";
        const where_keyword = "WHERE ";

        var where_text: ?[]const u8 = null;
        var return_part: []const u8 = undefined;

        if (std.mem.indexOf(u8, head.tail, where_keyword)) |where_idx| {
            const after_where = head.tail[where_idx + where_keyword.len ..];
            const return_idx_rel = std.mem.indexOf(u8, after_where, return_keyword) orelse return error.InvalidMatch;
            where_text = std.mem.trim(u8, after_where[0..return_idx_rel], " \t\n\r");
            return_part = std.mem.trim(u8, after_where[return_idx_rel + return_keyword.len ..], " \t\n\r");
        } else {
            const return_idx = std.mem.indexOf(u8, head.tail, return_keyword) orelse return error.InvalidMatch;
            return_part = std.mem.trim(u8, head.tail[return_idx + return_keyword.len ..], " \t\n\r");
        }

        var filter: ?Filter = null;
        if (where_text) |wt| {
            filter = try self.parseFilter(table, head.var_name, wt, params);
        }

        if (std.mem.startsWith(u8, return_part, "COUNT(*) AS ")) {
            const alias = std.mem.trim(u8, return_part[11..], " \t\n\r");
            try result.columns.append(self.allocator, try self.allocator.dupe(u8, alias));
            try result.types.append(self.allocator, "INT64");

            var count: i64 = 0;
            for (table.rows.items) |row| {
                if (filter) |f| {
                    if (!rowMatchesFilter(row, f)) continue;
                }
                count += 1;
            }

            var out = try self.allocator.alloc(Cell, 1);
            out[0] = .{ .int64 = count };
            try result.rows.append(self.allocator, out);
            return;
        }

        var order_col_idx: ?usize = null;
        const order_keyword = " ORDER BY ";
        var projection_part = return_part;
        if (std.mem.indexOf(u8, return_part, order_keyword)) |order_idx| {
            projection_part = std.mem.trim(u8, return_part[0..order_idx], " \t\n\r");
            const order_expr = std.mem.trim(u8, return_part[order_idx + order_keyword.len ..], " \t\n\r");
            const order_col_name = try self.parsePropertyExpr(order_expr, head.var_name);
            order_col_idx = table.columnIndex(order_col_name) orelse return error.ColumnNotFound;
        }

        var selected_cols: std.ArrayList(usize) = .{};
        defer selected_cols.deinit(self.allocator);

        var proj_iter = std.mem.splitScalar(u8, projection_part, ',');
        while (proj_iter.next()) |raw_expr| {
            const expr = std.mem.trim(u8, raw_expr, " \t\n\r");
            const col_name = try self.parsePropertyExpr(expr, head.var_name);
            const col_idx = table.columnIndex(col_name) orelse return error.ColumnNotFound;
            const ty = table.typeFor(col_name) orelse return error.ColumnNotFound;

            try selected_cols.append(self.allocator, col_idx);
            try result.columns.append(self.allocator, try self.allocator.dupe(u8, expr));
            try result.types.append(self.allocator, typeName(ty));
        }

        var indices: std.ArrayList(usize) = .{};
        defer indices.deinit(self.allocator);

        for (table.rows.items, 0..) |row, idx| {
            if (filter) |f| {
                if (!rowMatchesFilter(row, f)) continue;
            }
            try indices.append(self.allocator, idx);
        }

        if (order_col_idx) |oci| {
            const Ctx = struct {
                table: *const Table,
                col_idx: usize,
            };
            const ctx = Ctx{ .table = table, .col_idx = oci };
            const less = struct {
                fn f(c: Ctx, a: usize, b: usize) bool {
                    const left = c.table.rows.items[a][c.col_idx];
                    const right = c.table.rows.items[b][c.col_idx];
                    return switch (left) {
                        .string => |ls| switch (right) {
                            .string => |rs| std.mem.lessThan(u8, ls, rs),
                            else => false,
                        },
                        .int64 => |li| switch (right) {
                            .int64 => |ri| li < ri,
                            else => false,
                        },
                        else => false,
                    };
                }
            }.f;
            std.sort.heap(usize, indices.items, ctx, less);
        }

        try self.appendProjectedRows(table, indices.items, selected_cols.items, result);
    }

    fn executeReturn(
        self: *Engine,
        query: []const u8,
        params: ?*const std.json.ObjectMap,
        result: *ResultSet,
    ) !void {
        const body = std.mem.trim(u8, query[7..], " \t\n\r");
        const as_token = " AS ";
        const as_idx = std.mem.lastIndexOf(u8, body, as_token) orelse return error.InvalidReturn;

        const literal_text = std.mem.trim(u8, body[0..as_idx], " \t\n\r");
        const alias = std.mem.trim(u8, body[as_idx + as_token.len ..], " \t\n\r");
        if (alias.len == 0) return error.InvalidReturn;

        var out_cell: Cell = .null;
        var type_name: []const u8 = undefined;
        errdefer out_cell.deinit(self.allocator);

        if (literal_text.len > 0 and literal_text[0] == '$') {
            const key = literal_text[1..];
            const obj = params orelse return error.MissingParameter;
            const json_value = obj.get(key) orelse return error.MissingParameter;
            switch (json_value) {
                .string => |s| {
                    out_cell = .{ .string = try self.allocator.dupe(u8, s) };
                    type_name = "STRING";
                },
                .integer => |i| {
                    out_cell = .{ .int64 = @intCast(i) };
                    type_name = "INT64";
                },
                else => return error.UnsupportedParameterType,
            }
        } else {
            const literal = try parseLiteral(literal_text);
            switch (literal) {
                .string => |s| {
                    out_cell = .{ .string = try self.allocator.dupe(u8, s) };
                    type_name = "STRING";
                },
                .int64 => |v| {
                    out_cell = .{ .int64 = v };
                    type_name = "INT64";
                },
            }
        }

        try result.columns.append(self.allocator, try self.allocator.dupe(u8, alias));
        try result.types.append(self.allocator, type_name);

        const row = try self.allocator.alloc(Cell, 1);
        row[0] = out_cell;
        try result.rows.append(self.allocator, row);
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
                .int64 => |v| try writer.print("{d}", .{v}),
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
            try writeError(writer, @errorName(err));
            continue;
        };

        try writeOk(writer, &result);
    }
}
