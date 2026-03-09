//! SQL/Cypher Parser - Full Recursive Descent Parser
//!
//! Converted from: kuzu/src/parser/parser.cpp
//!
//! Purpose:
//! Hand-written recursive descent parser for SQL and Cypher.
//! Supports operator precedence, all DML/DDL, and graph patterns.

const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common");

const ParsedStatement = ast.ParsedStatement;
const QueryStatement = ast.QueryStatement;
const SelectClause = ast.SelectClause;
const FromClause = ast.FromClause;
const ParsedExpression = ast.ParsedExpression;
const TableReference = ast.TableReference;
const ColumnDefinition = ast.ColumnDefinition;
const CreateTableStatement = ast.CreateTableStatement;

// ============================================================================
// Token Types
// ============================================================================

pub const TokenType = enum {
    // Literals
    INTEGER,
    FLOAT,
    STRING,
    IDENTIFIER,
    PARAMETER,  // $1 or ?
    
    // Keywords
    SELECT, FROM, WHERE, AND, OR, NOT, AS, DISTINCT, ALL,
    TRUE, FALSE,
    
    // Aggregates
    COUNT, SUM, AVG, MIN, MAX,
    
    // Joins
    JOIN, LEFT, RIGHT, INNER, OUTER, FULL, CROSS, ON, USING, NATURAL,
    
    // Ordering
    ORDER, BY, ASC, DESC, NULLS, FIRST, LAST,
    
    // Grouping
    GROUP, HAVING,
    
    // Limit
    LIMIT, OFFSET,
    
    // Set operations
    UNION, INTERSECT, EXCEPT,
    
    // DML
    INSERT, INTO, VALUES, UPDATE, SET, DELETE, RETURNING,
    
    // DDL
    CREATE, DROP, ALTER, TABLE, INDEX, IF, EXISTS, CASCADE, RESTRICT,
    NODE, REL, RELATIONSHIP,
    
    // Types
    INT, INT8, INT16, INT32, INT64, UINT8, UINT16, UINT32, UINT64,
    FLOAT_TYPE, DOUBLE, REAL, DECIMAL, NUMERIC,
    VARCHAR, CHAR, TEXT, STRING_TYPE, BLOB,
    BOOLEAN, BOOL,
    DATE, TIME, TIMESTAMP, INTERVAL,
    LIST, MAP, STRUCT,
    
    // Constraints
    PRIMARY, KEY, FOREIGN, REFERENCES, UNIQUE, CHECK, CONSTRAINT,
    NULL_KW, DEFAULT, SERIAL,
    
    // Graph (Cypher)
    MATCH, RETURN, WITH, UNWIND, OPTIONAL, MERGE, DETACH,
    SHORTEST, PATH, ALL_SHORTEST,
    
    // Subquery
    IN, ANY, SOME, EVERY, EXISTS_KW,
    
    // Case
    CASE, WHEN, THEN, ELSE, END,
    
    // Cast
    CAST,
    
    // Between/Like
    BETWEEN, LIKE, ILIKE, SIMILAR, ESCAPE,
    
    // Operators
    EQUALS, NOT_EQUALS, LESS_THAN, LESS_THAN_EQUALS,
    GREATER_THAN, GREATER_THAN_EQUALS,
    PLUS, MINUS, STAR, SLASH, PERCENT, CARET,
    DOUBLE_COLON,  // :: for cast
    ARROW,         // -> for property
    DOUBLE_ARROW,  // ->> for JSON
    CONCAT,        // ||
    
    // Punctuation
    LPAREN, RPAREN, LBRACKET, RBRACKET, LBRACE, RBRACE,
    COMMA, DOT, SEMICOLON, COLON, QUESTION,
    
    // Special
    EOF, UNKNOWN, IS,
};

// ============================================================================
// Token
// ============================================================================

pub const Token = struct {
    token_type: TokenType,
    text: []const u8,
    line: u32,
    column: u32,
    
    pub fn init(token_type: TokenType, text: []const u8, line: u32, column: u32) Token {
        return .{ .token_type = token_type, .text = text, .line = line, .column = column };
    }
    
    pub fn isKeyword(self: *const Token) bool {
        return @intFromEnum(self.token_type) >= @intFromEnum(TokenType.SELECT) and
               @intFromEnum(self.token_type) <= @intFromEnum(TokenType.IS);
    }
    
    pub fn isComparisonOp(self: *const Token) bool {
        return self.token_type == .EQUALS or self.token_type == .NOT_EQUALS or
               self.token_type == .LESS_THAN or self.token_type == .LESS_THAN_EQUALS or
               self.token_type == .GREATER_THAN or self.token_type == .GREATER_THAN_EQUALS;
    }
};

// ============================================================================
// Lexer
// ============================================================================

pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    line: u32,
    column: u32,
    
    const Self = @This();
    
    pub fn init(input: []const u8) Self {
        return .{ .input = input, .pos = 0, .line = 1, .column = 1 };
    }
    
    pub fn nextToken(self: *Self) Token {
        self.skipWhitespaceAndComments();
        
        if (self.pos >= self.input.len) {
            return Token.init(.EOF, "", self.line, self.column);
        }
        
        const start = self.pos;
        const start_col = self.column;
        const c = self.current();
        
        // Two-character operators first
        if (self.pos + 1 < self.input.len) {
            const next = self.input[self.pos + 1];
            const two_char: ?TokenType = switch (c) {
                '<' => if (next == '=') .LESS_THAN_EQUALS else if (next == '>') .NOT_EQUALS else null,
                '>' => if (next == '=') .GREATER_THAN_EQUALS else null,
                '!' => if (next == '=') .NOT_EQUALS else null,
                '|' => if (next == '|') .CONCAT else null,
                ':' => if (next == ':') .DOUBLE_COLON else null,
                '-' => if (next == '>') .ARROW else null,
                else => null,
            };
            if (two_char) |tt| {
                self.advance();
                self.advance();
                return Token.init(tt, self.input[start..self.pos], self.line, start_col);
            }
        }
        
        // Single character tokens
        const single: ?TokenType = switch (c) {
            '(' => .LPAREN, ')' => .RPAREN,
            '[' => .LBRACKET, ']' => .RBRACKET,
            '{' => .LBRACE, '}' => .RBRACE,
            ',' => .COMMA, '.' => .DOT,
            ';' => .SEMICOLON, ':' => .COLON,
            '+' => .PLUS, '-' => .MINUS,
            '*' => .STAR, '/' => .SLASH,
            '%' => .PERCENT, '^' => .CARET,
            '=' => .EQUALS, '<' => .LESS_THAN,
            '>' => .GREATER_THAN, '?' => .QUESTION,
            else => null,
        };
        
        if (single) |tt| {
            self.advance();
            return Token.init(tt, self.input[start..self.pos], self.line, start_col);
        }
        
        // String literal
        if (c == '\'' or c == '"') return self.scanString(c);
        
        // Parameter ($1, $name, ?)
        if (c == '$' or (c == '?' and !std.ascii.isAlphanumeric(self.peek(1)))) {
            return self.scanParameter();
        }
        
        // Number
        if (std.ascii.isDigit(c)) return self.scanNumber();
        
        // Identifier or keyword
        if (std.ascii.isAlphabetic(c) or c == '_') return self.scanIdentifier();
        
        self.advance();
        return Token.init(.UNKNOWN, self.input[start..self.pos], self.line, start_col);
    }
    
    fn current(self: *const Self) u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else 0;
    }
    
    fn peek(self: *const Self, offset: usize) u8 {
        const idx = self.pos + offset;
        return if (idx < self.input.len) self.input[idx] else 0;
    }
    
    fn advance(self: *Self) void {
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }
    
    fn skipWhitespaceAndComments(self: *Self) void {
        while (self.pos < self.input.len) {
            const c = self.current();
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else if (c == '-' and self.peek(1) == '-') {
                while (self.pos < self.input.len and self.current() != '\n') self.advance();
            } else if (c == '/' and self.peek(1) == '*') {
                self.advance(); self.advance();
                while (self.pos < self.input.len) {
                    if (self.current() == '*' and self.peek(1) == '/') {
                        self.advance(); self.advance();
                        break;
                    }
                    self.advance();
                }
            } else break;
        }
    }
    
    fn scanString(self: *Self, quote: u8) Token {
        const start = self.pos;
        const start_col = self.column;
        self.advance();
        
        while (self.pos < self.input.len) {
            if (self.current() == quote) {
                if (self.peek(1) == quote) {
                    self.advance(); self.advance();  // Escaped quote
                } else {
                    self.advance();
                    break;
                }
            } else if (self.current() == '\\') {
                self.advance();
                if (self.pos < self.input.len) self.advance();
            } else {
                self.advance();
            }
        }
        
        return Token.init(.STRING, self.input[start..self.pos], self.line, start_col);
    }
    
    fn scanParameter(self: *Self) Token {
        const start = self.pos;
        const start_col = self.column;
        
        if (self.current() == '?') {
            self.advance();
        } else {
            self.advance();  // $
            while (std.ascii.isAlphanumeric(self.current()) or self.current() == '_') {
                self.advance();
            }
        }
        
        return Token.init(.PARAMETER, self.input[start..self.pos], self.line, start_col);
    }
    
    fn scanNumber(self: *Self) Token {
        const start = self.pos;
        const start_col = self.column;
        var is_float = false;
        
        while (std.ascii.isDigit(self.current())) self.advance();
        
        if (self.current() == '.' and std.ascii.isDigit(self.peek(1))) {
            is_float = true;
            self.advance();
            while (std.ascii.isDigit(self.current())) self.advance();
        }
        
        if (self.current() == 'e' or self.current() == 'E') {
            is_float = true;
            self.advance();
            if (self.current() == '+' or self.current() == '-') self.advance();
            while (std.ascii.isDigit(self.current())) self.advance();
        }
        
        return Token.init(if (is_float) .FLOAT else .INTEGER, self.input[start..self.pos], self.line, start_col);
    }
    
    fn scanIdentifier(self: *Self) Token {
        const start = self.pos;
        const start_col = self.column;
        
        while (std.ascii.isAlphanumeric(self.current()) or self.current() == '_') {
            self.advance();
        }
        
        const text = self.input[start..self.pos];
        return Token.init(lookupKeyword(text), text, self.line, start_col);
    }
    
    fn lookupKeyword(text: []const u8) TokenType {
        const map = std.StaticStringMap(TokenType).initComptime(.{
            // Core SQL
            .{ "SELECT", .SELECT }, .{ "select", .SELECT },
            .{ "FROM", .FROM }, .{ "from", .FROM },
            .{ "WHERE", .WHERE }, .{ "where", .WHERE },
            .{ "AND", .AND }, .{ "and", .AND },
            .{ "OR", .OR }, .{ "or", .OR },
            .{ "NOT", .NOT }, .{ "not", .NOT },
            .{ "AS", .AS }, .{ "as", .AS },
            .{ "DISTINCT", .DISTINCT }, .{ "distinct", .DISTINCT },
            .{ "ALL", .ALL }, .{ "all", .ALL },
            .{ "TRUE", .TRUE }, .{ "true", .TRUE },
            .{ "FALSE", .FALSE }, .{ "false", .FALSE },
            // Aggregates
            .{ "COUNT", .COUNT }, .{ "count", .COUNT },
            .{ "SUM", .SUM }, .{ "sum", .SUM },
            .{ "AVG", .AVG }, .{ "avg", .AVG },
            .{ "MIN", .MIN }, .{ "min", .MIN },
            .{ "MAX", .MAX }, .{ "max", .MAX },
            // Joins
            .{ "JOIN", .JOIN }, .{ "join", .JOIN },
            .{ "LEFT", .LEFT }, .{ "left", .LEFT },
            .{ "RIGHT", .RIGHT }, .{ "right", .RIGHT },
            .{ "INNER", .INNER }, .{ "inner", .INNER },
            .{ "OUTER", .OUTER }, .{ "outer", .OUTER },
            .{ "FULL", .FULL }, .{ "full", .FULL },
            .{ "CROSS", .CROSS }, .{ "cross", .CROSS },
            .{ "ON", .ON }, .{ "on", .ON },
            .{ "USING", .USING }, .{ "using", .USING },
            .{ "NATURAL", .NATURAL }, .{ "natural", .NATURAL },
            // Ordering
            .{ "ORDER", .ORDER }, .{ "order", .ORDER },
            .{ "BY", .BY }, .{ "by", .BY },
            .{ "ASC", .ASC }, .{ "asc", .ASC },
            .{ "DESC", .DESC }, .{ "desc", .DESC },
            .{ "NULLS", .NULLS }, .{ "nulls", .NULLS },
            .{ "FIRST", .FIRST }, .{ "first", .FIRST },
            .{ "LAST", .LAST }, .{ "last", .LAST },
            // Grouping
            .{ "GROUP", .GROUP }, .{ "group", .GROUP },
            .{ "HAVING", .HAVING }, .{ "having", .HAVING },
            // Limit
            .{ "LIMIT", .LIMIT }, .{ "limit", .LIMIT },
            .{ "OFFSET", .OFFSET }, .{ "offset", .OFFSET },
            // Set operations
            .{ "UNION", .UNION }, .{ "union", .UNION },
            .{ "INTERSECT", .INTERSECT }, .{ "intersect", .INTERSECT },
            .{ "EXCEPT", .EXCEPT }, .{ "except", .EXCEPT },
            // DML
            .{ "INSERT", .INSERT }, .{ "insert", .INSERT },
            .{ "INTO", .INTO }, .{ "into", .INTO },
            .{ "VALUES", .VALUES }, .{ "values", .VALUES },
            .{ "UPDATE", .UPDATE }, .{ "update", .UPDATE },
            .{ "SET", .SET }, .{ "set", .SET },
            .{ "DELETE", .DELETE }, .{ "delete", .DELETE },
            .{ "RETURNING", .RETURNING }, .{ "returning", .RETURNING },
            // DDL
            .{ "CREATE", .CREATE }, .{ "create", .CREATE },
            .{ "DROP", .DROP }, .{ "drop", .DROP },
            .{ "ALTER", .ALTER }, .{ "alter", .ALTER },
            .{ "TABLE", .TABLE }, .{ "table", .TABLE },
            .{ "INDEX", .INDEX }, .{ "index", .INDEX },
            .{ "IF", .IF }, .{ "if", .IF },
            .{ "EXISTS", .EXISTS }, .{ "exists", .EXISTS },
            .{ "NODE", .NODE }, .{ "node", .NODE },
            .{ "REL", .REL }, .{ "rel", .REL },
            // Types
            .{ "INT", .INT }, .{ "int", .INT },
            .{ "INT64", .INT64 }, .{ "int64", .INT64 },
            .{ "BIGINT", .INT64 }, .{ "bigint", .INT64 },
            .{ "FLOAT", .FLOAT_TYPE }, .{ "float", .FLOAT_TYPE },
            .{ "DOUBLE", .DOUBLE }, .{ "double", .DOUBLE },
            .{ "VARCHAR", .VARCHAR }, .{ "varchar", .VARCHAR },
            .{ "STRING", .STRING_TYPE }, .{ "string", .STRING_TYPE },
            .{ "TEXT", .TEXT }, .{ "text", .TEXT },
            .{ "BOOLEAN", .BOOLEAN }, .{ "boolean", .BOOLEAN },
            .{ "BOOL", .BOOL }, .{ "bool", .BOOL },
            .{ "DATE", .DATE }, .{ "date", .DATE },
            .{ "TIMESTAMP", .TIMESTAMP }, .{ "timestamp", .TIMESTAMP },
            // Constraints
            .{ "PRIMARY", .PRIMARY }, .{ "primary", .PRIMARY },
            .{ "KEY", .KEY }, .{ "key", .KEY },
            .{ "FOREIGN", .FOREIGN }, .{ "foreign", .FOREIGN },
            .{ "REFERENCES", .REFERENCES }, .{ "references", .REFERENCES },
            .{ "UNIQUE", .UNIQUE }, .{ "unique", .UNIQUE },
            .{ "NULL", .NULL_KW }, .{ "null", .NULL_KW },
            .{ "DEFAULT", .DEFAULT }, .{ "default", .DEFAULT },
            // Cypher
            .{ "MATCH", .MATCH }, .{ "match", .MATCH },
            .{ "RETURN", .RETURN }, .{ "return", .RETURN },
            .{ "WITH", .WITH }, .{ "with", .WITH },
            .{ "UNWIND", .UNWIND }, .{ "unwind", .UNWIND },
            .{ "OPTIONAL", .OPTIONAL }, .{ "optional", .OPTIONAL },
            .{ "MERGE", .MERGE }, .{ "merge", .MERGE },
            .{ "SHORTEST", .SHORTEST }, .{ "shortest", .SHORTEST },
            .{ "PATH", .PATH }, .{ "path", .PATH },
            // Special
            .{ "IS", .IS }, .{ "is", .IS },
            .{ "IN", .IN }, .{ "in", .IN },
            .{ "BETWEEN", .BETWEEN }, .{ "between", .BETWEEN },
            .{ "LIKE", .LIKE }, .{ "like", .LIKE },
            .{ "CASE", .CASE }, .{ "case", .CASE },
            .{ "WHEN", .WHEN }, .{ "when", .WHEN },
            .{ "THEN", .THEN }, .{ "then", .THEN },
            .{ "ELSE", .ELSE }, .{ "else", .ELSE },
            .{ "END", .END }, .{ "end", .END },
            .{ "CAST", .CAST }, .{ "cast", .CAST },
        });
        return map.get(text) orelse .IDENTIFIER;
    }
};

// ============================================================================
// Parser Error
// ============================================================================

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEOF,
    InvalidSyntax,
    UnsupportedFeature,
};

// ============================================================================
// Parser
// ============================================================================

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,
    previous: Token,
    errors: std.ArrayList([]const u8),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, input: []const u8) Self {
        var lexer = Lexer.init(input);
        const first = lexer.nextToken();
        return .{
            .allocator = allocator,
            .lexer = lexer,
            .current = first,
            .previous = first,
            .errors = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.errors.deinit(self.allocator);
    }
    
    pub fn parse(self: *Self) ParseError!ParsedStatement {
        return switch (self.current.token_type) {
            .SELECT => self.parseSelect(),
            .CREATE => self.parseCreate(),
            .INSERT => self.parseInsert(),
            .UPDATE => self.parseUpdate(),
            .DELETE => self.parseDelete(),
            .DROP => self.parseDrop(),
            .MATCH => self.parseMatch(),
            else => ParseError.UnexpectedToken,
        };
    }
    
    // Token management
    fn advance(self: *Self) void {
        self.previous = self.current;
        self.current = self.lexer.nextToken();
    }
    
    fn check(self: *const Self, tt: TokenType) bool {
        return self.current.token_type == tt;
    }
    
    fn match(self: *Self, tt: TokenType) bool {
        if (self.check(tt)) {
            self.advance();
            return true;
        }
        return false;
    }
    
    fn expect(self: *Self, tt: TokenType) ParseError!void {
        if (!self.check(tt)) return ParseError.UnexpectedToken;
        self.advance();
    }
    
    fn expectIdentifier(self: *Self) ParseError![]const u8 {
        if (self.current.token_type != .IDENTIFIER) return ParseError.UnexpectedToken;
        const text = self.current.text;
        self.advance();
        return text;
    }
    
    // ========================================================================
    // SELECT
    // ========================================================================
    
    fn parseSelect(self: *Self) ParseError!ParsedStatement {
        var stmt = ParsedStatement.createQuery(self.allocator);
        errdefer stmt.deinit();
        
        try self.expect(.SELECT);
        
        // DISTINCT / ALL
        if (self.match(.DISTINCT)) {
            stmt.query.?.select_clause.?.is_distinct = true;
        } else {
            _ = self.match(.ALL);
        }
        
        // Projections
        stmt.query.?.select_clause = SelectClause.init(self.allocator);
        try self.parseProjectionList(&stmt.query.?.select_clause.?);
        
        // FROM
        if (self.match(.FROM)) {
            stmt.query.?.from_clause = FromClause.init(self.allocator);
            try self.parseFromList(&stmt.query.?.from_clause.?);
        }
        
        // WHERE
        if (self.match(.WHERE)) {
            stmt.query.?.where_clause = try self.parseOrExpression();
        }
        
        // GROUP BY
        if (self.match(.GROUP)) {
            try self.expect(.BY);
            try self.parseGroupByList(&stmt.query.?);
        }
        
        // HAVING
        if (self.match(.HAVING)) {
            stmt.query.?.having_clause = try self.parseOrExpression();
        }
        
        // ORDER BY
        if (self.match(.ORDER)) {
            try self.expect(.BY);
            try self.parseOrderByList(&stmt.query.?);
        }
        
        // LIMIT
        if (self.match(.LIMIT)) {
            if (self.check(.INTEGER)) {
                stmt.query.?.limit = std.fmt.parseInt(u64, self.current.text, 10) catch 0;
                self.advance();
            }
        }
        
        // OFFSET
        if (self.match(.OFFSET)) {
            if (self.check(.INTEGER)) {
                stmt.query.?.offset = std.fmt.parseInt(u64, self.current.text, 10) catch 0;
                self.advance();
            }
        }
        
        return stmt;
    }
    
    fn parseProjectionList(self: *Self, select: *SelectClause) ParseError!void {
        while (true) {
            if (self.match(.STAR)) {
                const expr = try self.allocator.create(ParsedExpression);
                expr.* = ParsedExpression.init(self.allocator, "*");
                try select.addProjection(expr);
            } else {
                const expr = try self.parseOrExpression();
                
                // AS alias
                if (self.match(.AS)) {
                    expr.alias = self.current.text;
                    self.advance();
                } else if (self.check(.IDENTIFIER) and !self.check(.FROM) and !self.check(.WHERE)) {
                    expr.alias = self.current.text;
                    self.advance();
                }
                
                try select.addProjection(expr);
            }
            
            if (!self.match(.COMMA)) break;
        }
    }
    
    fn parseFromList(self: *Self, from: *FromClause) ParseError!void {
        while (true) {
            // Table reference
            const table_name = try self.expectIdentifier();
            var table_ref = TableReference.init(self.allocator, table_name);
            
            // Alias
            if (self.match(.AS)) {
                table_ref.alias = try self.expectIdentifier();
            } else if (self.check(.IDENTIFIER) and !self.isJoinKeyword()) {
                table_ref.alias = self.current.text;
                self.advance();
            }
            
            try from.addTable(table_ref);
            
            // JOINs
            while (self.isJoinKeyword()) {
                try self.parseJoin(from);
            }
            
            if (!self.match(.COMMA)) break;
        }
    }
    
    fn isJoinKeyword(self: *const Self) bool {
        return self.check(.JOIN) or self.check(.LEFT) or self.check(.RIGHT) or
               self.check(.INNER) or self.check(.OUTER) or self.check(.FULL) or
               self.check(.CROSS) or self.check(.NATURAL);
    }
    
    fn parseJoin(self: *Self, from: *FromClause) ParseError!void {
        var join_type: ast.JoinType = .INNER;
        
        if (self.match(.LEFT)) {
            join_type = .LEFT;
            _ = self.match(.OUTER);
        } else if (self.match(.RIGHT)) {
            join_type = .RIGHT;
            _ = self.match(.OUTER);
        } else if (self.match(.FULL)) {
            join_type = .FULL;
            _ = self.match(.OUTER);
        } else if (self.match(.CROSS)) {
            join_type = .CROSS;
        } else if (self.match(.NATURAL)) {
            join_type = .NATURAL;
        } else if (self.match(.INNER)) {
            join_type = .INNER;
        }
        
        try self.expect(.JOIN);
        
        const table_name = try self.expectIdentifier();
        var table_ref = TableReference.init(self.allocator, table_name);
        
        if (self.match(.AS)) {
            table_ref.alias = try self.expectIdentifier();
        }
        
        try from.addTable(table_ref);
        
        // ON condition
        if (self.match(.ON)) {
            const condition = try self.parseOrExpression();
            try from.addJoin(ast.JoinInfo{
                .join_type = join_type,
                .left_table = from.tables.items[from.tables.items.len - 2].table_name,
                .right_table = table_name,
                .condition = condition,
            });
        }
    }
    
    fn parseGroupByList(self: *Self, query: *QueryStatement) ParseError!void {
        while (true) {
            const expr = try self.parseOrExpression();
            try query.group_by.append(self.allocator, expr);
            if (!self.match(.COMMA)) break;
        }
    }
    
    fn parseOrderByList(self: *Self, query: *QueryStatement) ParseError!void {
        while (true) {
            const expr = try self.parseOrExpression();
            var order: ast.ParsedSortOrder = .ASC;
            var nulls_first = false;
            
            if (self.match(.ASC)) {
                order = .ASC;
            } else if (self.match(.DESC)) {
                order = .DESC;
            }
            
            if (self.match(.NULLS)) {
                if (self.match(.FIRST)) {
                    nulls_first = true;
                } else if (self.match(.LAST)) {
                    nulls_first = false;
                }
            }
            
            var item = ast.OrderByItem.init(expr, order);
            item.nulls_first = nulls_first;
            try query.order_by.append(self.allocator, item);
            
            if (!self.match(.COMMA)) break;
        }
    }
    
    // ========================================================================
    // Expression Parsing (Precedence Climbing)
    // ========================================================================
    
    fn parseOrExpression(self: *Self) ParseError!*ParsedExpression {
        var left = try self.parseAndExpression();
        
        while (self.match(.OR)) {
            const right = try self.parseAndExpression();
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, "OR");
            expr.expr_type = .LOGICAL;
            expr.left = left;
            expr.right = right;
            left = expr;
        }
        
        return left;
    }
    
    fn parseAndExpression(self: *Self) ParseError!*ParsedExpression {
        var left = try self.parseNotExpression();
        
        while (self.match(.AND)) {
            const right = try self.parseNotExpression();
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, "AND");
            expr.expr_type = .LOGICAL;
            expr.left = left;
            expr.right = right;
            left = expr;
        }
        
        return left;
    }
    
    fn parseNotExpression(self: *Self) ParseError!*ParsedExpression {
        if (self.match(.NOT)) {
            const operand = try self.parseNotExpression();
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, "NOT");
            expr.expr_type = .LOGICAL;
            expr.left = operand;
            return expr;
        }
        return self.parseComparisonExpression();
    }
    
    fn parseComparisonExpression(self: *Self) ParseError!*ParsedExpression {
        const left = try self.parseAddExpression();
        
        // IS NULL / IS NOT NULL
        if (self.match(.IS)) {
            const not = self.match(.NOT);
            try self.expect(.NULL_KW);
            
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, if (not) "IS NOT NULL" else "IS NULL");
            expr.expr_type = .NULL_TEST;
            expr.left = left;
            return expr;
        }
        
        // BETWEEN
        if (self.match(.BETWEEN)) {
            const low = try self.parseAddExpression();
            try self.expect(.AND);
            const high = try self.parseAddExpression();
            
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, "BETWEEN");
            expr.expr_type = .BETWEEN;
            expr.left = left;
            try expr.args.append(self.allocator, low);
            try expr.args.append(self.allocator, high);
            return expr;
        }
        
        // IN
        if (self.match(.IN)) {
            try self.expect(.LPAREN);
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, "IN");
            expr.expr_type = .IN;
            expr.left = left;
            expr.args = .{};
            
            while (!self.check(.RPAREN) and !self.check(.EOF)) {
                const val = try self.parseOrExpression();
                try expr.args.?.append(self.allocator, val);
                if (!self.match(.COMMA)) break;
            }
            try self.expect(.RPAREN);
            return expr;
        }
        
        // LIKE
        if (self.match(.LIKE)) {
            const pattern = try self.parseAddExpression();
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, "LIKE");
            expr.expr_type = .LIKE;
            expr.left = left;
            expr.right = pattern;
            return expr;
        }
        
        // Comparison operators
        if (self.current.isComparisonOp()) {
            const op = self.current.text;
            self.advance();
            const right = try self.parseAddExpression();
            
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, op);
            expr.expr_type = .COMPARISON;
            expr.left = left;
            expr.right = right;
            return expr;
        }
        
        return left;
    }
    
    fn parseAddExpression(self: *Self) ParseError!*ParsedExpression {
        var left = try self.parseMulExpression();
        
        while (self.check(.PLUS) or self.check(.MINUS) or self.check(.CONCAT)) {
            const op = self.current.text;
            self.advance();
            const right = try self.parseMulExpression();
            
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, op);
            expr.expr_type = .ARITHMETIC;
            expr.left = left;
            expr.right = right;
            left = expr;
        }
        
        return left;
    }
    
    fn parseMulExpression(self: *Self) ParseError!*ParsedExpression {
        var left = try self.parseUnaryExpression();
        
        while (self.check(.STAR) or self.check(.SLASH) or self.check(.PERCENT)) {
            const op = self.current.text;
            self.advance();
            const right = try self.parseUnaryExpression();
            
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, op);
            expr.expr_type = .ARITHMETIC;
            expr.left = left;
            expr.right = right;
            left = expr;
        }
        
        return left;
    }
    
    fn parseUnaryExpression(self: *Self) ParseError!*ParsedExpression {
        if (self.match(.MINUS)) {
            const operand = try self.parseUnaryExpression();
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, "-");
            expr.expr_type = .ARITHMETIC;
            expr.left = operand;
            return expr;
        }
        return self.parsePrimaryExpression();
    }
    
    fn parsePrimaryExpression(self: *Self) ParseError!*ParsedExpression {
        // Parenthesized or subquery
        if (self.match(.LPAREN)) {
            if (self.check(.SELECT)) {
                _ = try self.parseSelect();
                const expr = try self.allocator.create(ParsedExpression);
                expr.* = ParsedExpression.init(self.allocator, "SUBQUERY");
                expr.expr_type = .SUBQUERY;
                try self.expect(.RPAREN);
                return expr;
            }
            const inner = try self.parseOrExpression();
            try self.expect(.RPAREN);
            return inner;
        }
        
        // CASE
        if (self.match(.CASE)) {
            return self.parseCaseExpression();
        }
        
        // CAST
        if (self.match(.CAST)) {
            try self.expect(.LPAREN);
            const value = try self.parseOrExpression();
            try self.expect(.AS);
            const type_name = try self.expectIdentifier();
            try self.expect(.RPAREN);
            
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, type_name);
            expr.expr_type = .CAST;
            expr.left = value;
            return expr;
        }
        
        // Literals
        if (self.check(.INTEGER) or self.check(.FLOAT) or self.check(.STRING) or
            self.check(.TRUE) or self.check(.FALSE) or self.check(.NULL_KW)) {
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, self.current.text);
            expr.expr_type = .LITERAL;
            self.advance();
            return expr;
        }
        
        // Parameter
        if (self.check(.PARAMETER)) {
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, self.current.text);
            expr.expr_type = .PARAMETER;
            self.advance();
            return expr;
        }
        
        // Function call or identifier
        if (self.check(.IDENTIFIER) or self.isAggregateKeyword()) {
            return self.parseFunctionOrIdentifier();
        }
        
        return ParseError.UnexpectedToken;
    }
    
    fn isAggregateKeyword(self: *const Self) bool {
        return self.check(.COUNT) or self.check(.SUM) or self.check(.AVG) or
               self.check(.MIN) or self.check(.MAX);
    }
    
    fn parseFunctionOrIdentifier(self: *Self) ParseError!*ParsedExpression {
        const name = self.current.text;
        const is_agg = self.isAggregateKeyword();
        self.advance();
        
        // Check for function call
        if (self.match(.LPAREN)) {
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, name);
            expr.expr_type = if (is_agg) .AGGREGATE else .FUNCTION;
            expr.function_name = name;
            expr.args = .{};
            
            // DISTINCT for aggregates
            if (is_agg and self.match(.DISTINCT)) {
                expr.is_distinct = true;
            }
            
            // COUNT(*)
            if (self.match(.STAR)) {
                // Special case
            } else if (!self.check(.RPAREN)) {
                while (true) {
                    const arg = try self.parseOrExpression();
                    try expr.args.?.append(self.allocator, arg);
                    if (!self.match(.COMMA)) break;
                }
            }
            
            try self.expect(.RPAREN);
            return expr;
        }
        
        // Check for table.column
        if (self.match(.DOT)) {
            const col_name = try self.expectIdentifier();
            const expr = try self.allocator.create(ParsedExpression);
            expr.* = ParsedExpression.init(self.allocator, col_name);
            expr.expr_type = .COLUMN_REF;
            expr.table_name = name;
            return expr;
        }
        
        // Simple identifier
        const expr = try self.allocator.create(ParsedExpression);
        expr.* = ParsedExpression.init(self.allocator, name);
        expr.expr_type = .COLUMN_REF;
        return expr;
    }
    
    fn parseCaseExpression(self: *Self) ParseError!*ParsedExpression {
        const expr = try self.allocator.create(ParsedExpression);
        expr.* = ParsedExpression.init(self.allocator, "CASE");
        expr.expr_type = .CASE;
        expr.args = .{};
        
        while (self.match(.WHEN)) {
            const condition = try self.parseOrExpression();
            try self.expect(.THEN);
            const result = try self.parseOrExpression();
            try expr.args.?.append(self.allocator, condition);
            try expr.args.?.append(self.allocator, result);
        }
        
        if (self.match(.ELSE)) {
            const else_result = try self.parseOrExpression();
            expr.right = else_result;
        }
        
        try self.expect(.END);
        return expr;
    }
    
    // ========================================================================
    // INSERT
    // ========================================================================
    
    fn parseInsert(self: *Self) ParseError!ParsedStatement {
        try self.expect(.INSERT);
        try self.expect(.INTO);
        
        const table_name = try self.expectIdentifier();
        var stmt = ParsedStatement.createInsert(self.allocator, table_name);
        errdefer stmt.deinit();
        
        // Column list (optional)
        if (self.match(.LPAREN)) {
            while (!self.check(.RPAREN) and !self.check(.EOF)) {
                const col = try self.expectIdentifier();
                try stmt.insert.?.columns.append(self.allocator, col);
                if (!self.match(.COMMA)) break;
            }
            try self.expect(.RPAREN);
        }
        
        // VALUES
        try self.expect(.VALUES);
        
        while (true) {
            try self.expect(.LPAREN);
            var row: std.ArrayList(*ParsedExpression) = .{};
            _ = &row;

            while (!self.check(.RPAREN) and !self.check(.EOF)) {
                const val = try self.parseOrExpression();
                try row.append(self.allocator, val);
                if (!self.match(.COMMA)) break;
            }
            try self.expect(.RPAREN);
            try stmt.insert.?.values.append(self.allocator, row);
            
            if (!self.match(.COMMA)) break;
        }
        
        return stmt;
    }
    
    // ========================================================================
    // UPDATE
    // ========================================================================
    
    fn parseUpdate(self: *Self) ParseError!ParsedStatement {
        try self.expect(.UPDATE);
        const table_name = try self.expectIdentifier();
        
        var stmt = ParsedStatement.createUpdate(self.allocator, table_name);
        errdefer stmt.deinit();
        
        try self.expect(.SET);
        
        while (true) {
            const col = try self.expectIdentifier();
            try self.expect(.EQUALS);
            const val = try self.parseOrExpression();
            try stmt.update.?.assignments.append(self.allocator, .{ .column = col, .value = val });
            if (!self.match(.COMMA)) break;
        }
        
        if (self.match(.WHERE)) {
            stmt.update.?.where_clause = try self.parseOrExpression();
        }
        
        return stmt;
    }
    
    // ========================================================================
    // DELETE
    // ========================================================================
    
    fn parseDelete(self: *Self) ParseError!ParsedStatement {
        try self.expect(.DELETE);
        try self.expect(.FROM);
        
        const table_name = try self.expectIdentifier();
        var stmt = ParsedStatement.createDelete(self.allocator, table_name);
        errdefer stmt.deinit();
        
        if (self.match(.WHERE)) {
            stmt.delete.?.where_clause = try self.parseOrExpression();
        }
        
        return stmt;
    }
    
    // ========================================================================
    // CREATE / DROP
    // ========================================================================
    
    fn parseCreate(self: *Self) ParseError!ParsedStatement {
        try self.expect(.CREATE);
        
        if (self.check(.NODE)) {
            return self.parseCreateNodeTable();
        } else if (self.check(.REL)) {
            return self.parseCreateRelTable();
        } else if (self.check(.TABLE)) {
            return self.parseCreateTable();
        } else if (self.check(.INDEX)) {
            return self.parseCreateIndex();
        }
        
        return ParseError.UnexpectedToken;
    }
    
    fn parseCreateTable(self: *Self) ParseError!ParsedStatement {
        try self.expect(.TABLE);
        
        _ = self.match(.IF);
        _ = self.match(.NOT);
        _ = self.match(.EXISTS);
        
        const table_name = try self.expectIdentifier();
        var stmt = ParsedStatement.createCreateTable(self.allocator, table_name);
        errdefer stmt.deinit();
        
        try self.expect(.LPAREN);
        
        while (!self.check(.RPAREN) and !self.check(.EOF)) {
            // Check for constraints
            if (self.check(.PRIMARY) or self.check(.FOREIGN) or self.check(.UNIQUE)) {
                self.skipConstraint();
                if (!self.match(.COMMA)) break;
                continue;
            }
            
            const col_name = try self.expectIdentifier();
            const data_type = self.parseDataType();
            
            var col_def = ColumnDefinition.init(col_name, data_type);
            
            // Column constraints
            while (true) {
                if (self.match(.PRIMARY)) {
                    _ = self.match(.KEY);
                    col_def.is_primary_key = true;
                } else if (self.match(.NOT)) {
                    try self.expect(.NULL_KW);
                    col_def.is_nullable = false;
                } else if (self.match(.NULL_KW)) {
                    col_def.is_nullable = true;
                } else if (self.match(.UNIQUE)) {
                    col_def.is_unique = true;
                } else if (self.match(.DEFAULT)) {
                    const default_expr = try self.parseOrExpression();
                    col_def.default_value = default_expr.text;
                } else break;
            }
            
            try stmt.create_table.?.addColumn(col_def);
            if (!self.match(.COMMA)) break;
        }
        
        try self.expect(.RPAREN);
        return stmt;
    }
    
    fn parseCreateNodeTable(self: *Self) ParseError!ParsedStatement {
        try self.expect(.NODE);
        try self.expect(.TABLE);
        return self.parseCreateTable();
    }
    
    fn parseCreateRelTable(self: *Self) ParseError!ParsedStatement {
        try self.expect(.REL);
        try self.expect(.TABLE);
        return self.parseCreateTable();
    }
    
    fn parseCreateIndex(self: *Self) ParseError!ParsedStatement {
        try self.expect(.INDEX);
        // Simplified - just skip to table name
        _ = self.match(.IF);
        _ = self.match(.NOT);
        _ = self.match(.EXISTS);
        
        const index_name = try self.expectIdentifier();
        try self.expect(.ON);
        const table_name = try self.expectIdentifier();
        
        var stmt = ParsedStatement.createIndex(self.allocator, index_name);
        stmt.target_table = table_name;

        try self.expect(.LPAREN);
        while (!self.check(.RPAREN) and !self.check(.EOF)) {
            _ = try self.expectIdentifier();
            if (!self.match(.COMMA)) break;
        }
        try self.expect(.RPAREN);

        return stmt;
    }
    
    fn parseDrop(self: *Self) ParseError!ParsedStatement {
        try self.expect(.DROP);
        
        if (self.match(.TABLE)) {
            _ = self.match(.IF);
            _ = self.match(.EXISTS);
            const table_name = try self.expectIdentifier();
            return ParsedStatement.createDropTable(self.allocator, table_name);
        } else if (self.match(.INDEX)) {
            _ = self.match(.IF);
            _ = self.match(.EXISTS);
            const index_name = try self.expectIdentifier();
            var drop_stmt = ParsedStatement.init(self.allocator, .DROP_INDEX);
            drop_stmt.index_name = index_name;
            return drop_stmt;
        }
        
        return ParseError.UnexpectedToken;
    }
    
    fn parseDataType(self: *Self) common.LogicalType {
        const dt = switch (self.current.token_type) {
            .INT, .INT32 => common.LogicalType.INT32,
            .INT64 => common.LogicalType.INT64,
            .FLOAT_TYPE, .REAL => common.LogicalType.FLOAT,
            .DOUBLE => common.LogicalType.DOUBLE,
            .VARCHAR, .TEXT, .STRING_TYPE => common.LogicalType.STRING,
            .BOOLEAN, .BOOL => common.LogicalType.BOOL,
            .DATE => common.LogicalType.DATE,
            .TIMESTAMP => common.LogicalType.TIMESTAMP,
            else => common.LogicalType.ANY,
        };
        self.advance();
        
        // Handle VARCHAR(n)
        if (self.match(.LPAREN)) {
            while (!self.check(.RPAREN) and !self.check(.EOF)) self.advance();
            _ = self.match(.RPAREN);
        }
        
        return dt;
    }
    
    fn skipConstraint(self: *Self) void {
        // Skip table-level constraints
        while (!self.check(.COMMA) and !self.check(.RPAREN) and !self.check(.EOF)) {
            self.advance();
        }
    }
    
    // ========================================================================
    // Cypher MATCH
    // ========================================================================
    
    fn parseMatch(self: *Self) ParseError!ParsedStatement {
        var stmt = ParsedStatement.createMatch(self.allocator);
        errdefer stmt.deinit();
        
        // OPTIONAL MATCH
        if (self.match(.OPTIONAL)) {
            stmt.match.?.is_optional = true;
        }
        
        try self.expect(.MATCH);
        
        // Parse pattern
        try self.parsePattern(&stmt.match.?);
        
        // WHERE
        if (self.match(.WHERE)) {
            stmt.match.?.where_clause = try self.parseOrExpression();
        }
        
        // RETURN
        if (self.match(.RETURN)) {
            stmt.match.?.return_clause = SelectClause.init(self.allocator);
            try self.parseProjectionList(&stmt.match.?.return_clause.?);
        }
        
        return stmt;
    }
    
    fn parsePattern(self: *Self, match_stmt: *ast.MatchStatement) ParseError!void {
        while (true) {
            // (node)
            if (self.match(.LPAREN)) {
                var node = ast.NodePattern.init(self.allocator);
                
                // Variable name
                if (self.check(.IDENTIFIER)) {
                    node.variable = self.current.text;
                    self.advance();
                }
                
                // :Label
                if (self.match(.COLON)) {
                    node.label = try self.expectIdentifier();
                }
                
                // {properties}
                if (self.match(.LBRACE)) {
                    try self.parsePropertyMap(&node.properties);
                    try self.expect(.RBRACE);
                }
                
                try self.expect(.RPAREN);
                try match_stmt.nodes.append(self.allocator, node);
            }
            
            // -[edge]-> or <-[edge]-
            if (self.check(.MINUS) or self.check(.LESS_THAN)) {
                var edge = ast.EdgePattern.init(self.allocator);
                
                if (self.match(.LESS_THAN)) {
                    edge.direction = .LEFT;
                    try self.expect(.MINUS);
                } else {
                    try self.expect(.MINUS);
                }
                
                // [edge details]
                if (self.match(.LBRACKET)) {
                    if (self.check(.IDENTIFIER)) {
                        edge.variable = self.current.text;
                        self.advance();
                    }
                    
                    if (self.match(.COLON)) {
                        edge.edge_type = try self.expectIdentifier();
                    }
                    
                    // *min..max
                    if (self.match(.STAR)) {
                        try self.parseEdgeLengthSpec(&edge);
                    }
                    
                    try self.expect(.RBRACKET);
                }
                
                try self.expect(.MINUS);
                
                if (self.match(.GREATER_THAN)) {
                    edge.direction = .RIGHT;
                }
                
                try match_stmt.edges.append(self.allocator, edge);
                continue;
            }
            
            if (!self.match(.COMMA)) break;
        }
    }
    
    fn parsePropertyMap(self: *Self, props: *std.StringHashMap(*ParsedExpression)) ParseError!void {
        while (!self.check(.RBRACE) and !self.check(.EOF)) {
            const key = try self.expectIdentifier();
            try self.expect(.COLON);
            const value = try self.parseOrExpression();
            try props.put(key, value);
            if (!self.match(.COMMA)) break;
        }
    }
    
    fn parseEdgeLengthSpec(self: *Self, edge: *ast.EdgePattern) ParseError!void {
        if (self.check(.INTEGER)) {
            edge.min_length = std.fmt.parseInt(u32, self.current.text, 10) catch 1;
            edge.max_length = edge.min_length;
            self.advance();
        }
        
        if (self.match(.DOT)) {
            try self.expect(.DOT);
            if (self.check(.INTEGER)) {
                edge.max_length = std.fmt.parseInt(u32, self.current.text, 10) catch null;
                self.advance();
            } else {
                edge.max_length = null;  // Unbounded
            }
        }
    }


// ============================================================================
// Tests
// ============================================================================

test "lexer basic" {
    var lexer = Lexer.init("SELECT * FROM users WHERE id = 1");
    try std.testing.expectEqual(TokenType.SELECT, lexer.nextToken().token_type);
    try std.testing.expectEqual(TokenType.STAR, lexer.nextToken().token_type);
    try std.testing.expectEqual(TokenType.FROM, lexer.nextToken().token_type);
}

test "lexer string" {
    var lexer = Lexer.init("'hello world' \"test\"");
    try std.testing.expectEqual(TokenType.STRING, lexer.nextToken().token_type);
    try std.testing.expectEqual(TokenType.STRING, lexer.nextToken().token_type);
}

test "parser select" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "SELECT id, name FROM users WHERE age > 18");
    var stmt = try parser.parse();
    defer stmt.deinit();
    try std.testing.expectEqual(ast.StatementType.QUERY, stmt.statement_type);
}

test "parser create table" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "CREATE TABLE users (id INT PRIMARY KEY, name VARCHAR NOT NULL)");
    var stmt = try parser.parse();
    defer stmt.deinit();
    try std.testing.expectEqual(ast.StatementType.CREATE_TABLE, stmt.statement_type);
}
};

