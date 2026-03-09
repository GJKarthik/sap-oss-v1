const std = @import("std");

pub const AggFunc = enum { NONE, SUM, AVG, COUNT, MIN, MAX, COUNT_DISTINCT };

pub const SelectColumn = struct {
    table_alias: ?[]const u8,
    column: []const u8,
    agg: AggFunc,
    alias: ?[]const u8,
};

pub const WhereOp = enum { EQ, NEQ, GT, GTE, LT, LTE, LIKE, IN, BETWEEN, IS_NULL, IS_NOT_NULL };

pub const WhereClause = struct {
    column: []const u8,
    table_alias: ?[]const u8,
    op: WhereOp,
    value: []const u8,
};

pub const JoinType = enum { INNER, LEFT, RIGHT, CROSS };

pub const JoinClause = struct {
    join_type: JoinType,
    table: []const u8,
    schema: []const u8,
    alias: []const u8,
    on_left: []const u8,
    on_right: []const u8,
};

pub const OrderDirection = enum { ASC, DESC };

pub const OrderBy = struct {
    column: []const u8,
    direction: OrderDirection,
};

pub const QuerySpec = struct {
    select: []const SelectColumn,
    from_table: []const u8,
    from_schema: []const u8,
    from_alias: []const u8,
    joins: []const JoinClause,
    where: []const WhereClause,
    group_by: []const []const u8,
    order_by: []const OrderBy,
    limit: ?u32,
};

pub fn buildQuery(allocator: std.mem.Allocator, spec: QuerySpec) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // SELECT
    try w.writeAll("SELECT ");
    for (spec.select, 0..) |col, i| {
        if (i > 0) try w.writeAll(", ");
        if (col.agg != .NONE) { try w.writeAll(@tagName(col.agg)); try w.writeAll("("); }
        if (col.table_alias) |ta| { try w.writeAll(ta); try w.writeAll("."); }
        try w.writeAll(col.column);
        if (col.agg != .NONE) try w.writeAll(")");
        if (col.alias) |a| { try w.writeAll(" AS "); try w.writeAll(a); }
    }

    // FROM
    try w.writeAll(" FROM ");
    try w.writeAll(spec.from_schema);
    try w.writeAll(".");
    try w.writeAll(spec.from_table);
    if (spec.from_alias.len > 0) { try w.writeAll(" "); try w.writeAll(spec.from_alias); }

    // JOINs
    for (spec.joins) |j| {
        try w.writeAll(" ");
        try w.writeAll(@tagName(j.join_type));
        try w.writeAll(" JOIN ");
        try w.writeAll(j.schema); try w.writeAll("."); try w.writeAll(j.table);
        try w.writeAll(" "); try w.writeAll(j.alias);
        try w.writeAll(" ON "); try w.writeAll(j.on_left);
        try w.writeAll(" = "); try w.writeAll(j.on_right);
    }

    // WHERE
    if (spec.where.len > 0) {
        try w.writeAll(" WHERE ");
        for (spec.where, 0..) |wc, i| {
            if (i > 0) try w.writeAll(" AND ");
            if (wc.table_alias) |ta| { try w.writeAll(ta); try w.writeAll("."); }
            try w.writeAll(wc.column);
            switch (wc.op) {
                .EQ => { try w.writeAll(" = "); try w.writeAll(wc.value); },
                .LIKE => { try w.writeAll(" LIKE "); try w.writeAll(wc.value); },
                .GT => { try w.writeAll(" > "); try w.writeAll(wc.value); },
                .GTE => { try w.writeAll(" >= "); try w.writeAll(wc.value); },
                .LT => { try w.writeAll(" < "); try w.writeAll(wc.value); },
                .LTE => { try w.writeAll(" <= "); try w.writeAll(wc.value); },
                .IS_NULL => try w.writeAll(" IS NULL"),
                .IS_NOT_NULL => try w.writeAll(" IS NOT NULL"),
                else => { try w.writeAll(" = "); try w.writeAll(wc.value); },
            }
        }
    }

    // GROUP BY
    if (spec.group_by.len > 0) {
        try w.writeAll(" GROUP BY ");
        for (spec.group_by, 0..) |col, i| { if (i > 0) try w.writeAll(", "); try w.writeAll(col); }
    }

    // ORDER BY
    if (spec.order_by.len > 0) {
        try w.writeAll(" ORDER BY ");
        for (spec.order_by, 0..) |ob, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(ob.column);
            try w.writeAll(if (ob.direction == .DESC) " DESC" else " ASC");
        }
    }

    // LIMIT
    if (spec.limit) |lim| { try w.print(" LIMIT {d}", .{lim}); }

    return try buf.toOwnedSlice(allocator);
}

test "build simple select query" {
    const allocator = std.testing.allocator;
    const sql = try buildQuery(allocator, .{
        .select = &.{
            .{ .table_alias = "t", .column = "COUNTRY", .agg = .NONE, .alias = null },
            .{ .table_alias = "t", .column = "MTM", .agg = .SUM, .alias = "total_mtm" },
        },
        .from_table = "BOND_POSITIONS", .from_schema = "STG_TREASURY", .from_alias = "t",
        .joins = &.{},
        .where = &.{ .{ .column = "GLB_FV_HTC", .table_alias = "t", .op = .EQ, .value = "'FVOCI'" } },
        .group_by = &.{"t.COUNTRY"},
        .order_by = &.{ .{ .column = "total_mtm", .direction = .DESC } },
        .limit = 5,
    });
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "SELECT t.COUNTRY, SUM(t.MTM) AS total_mtm FROM STG_TREASURY.BOND_POSITIONS t WHERE t.GLB_FV_HTC = 'FVOCI' GROUP BY t.COUNTRY ORDER BY total_mtm DESC LIMIT 5",
        sql,
    );
}

test "build query with join" {
    const allocator = std.testing.allocator;
    const sql = try buildQuery(allocator, .{
        .select = &.{ .{ .table_alias = "f", .column = "NOTIONAL", .agg = .SUM, .alias = null } },
        .from_table = "BSI_REM_FACT", .from_schema = "STG_BCRS", .from_alias = "f",
        .joins = &.{ .{
            .join_type = .INNER, .table = "BSI_REM_DIM_COUNTRY", .schema = "STG_BCRS",
            .alias = "d", .on_left = "f.COUNTRY_ID", .on_right = "d.COUNTRY_ID",
        } },
        .where = &.{}, .group_by = &.{}, .order_by = &.{}, .limit = null,
    });
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "INNER JOIN STG_BCRS.BSI_REM_DIM_COUNTRY") != null);
}

