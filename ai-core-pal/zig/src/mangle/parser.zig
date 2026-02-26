//! Mangle Datalog Parser — Parse facts, rules, and queries from .mg files
//!
//! Parses a subset of Datalog syntax used in Mangle files:
//!   - Facts: predicate(arg1, arg2, ...).
//!   - Rules: head(X, Y) :- body1(X), body2(Y).
//!   - Comments: % single line
//!
//! This is a self-contained parser - each service has its own copy.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ============================================================================
// AST Types
// ============================================================================

/// A term in a predicate (variable, constant, or number)
pub const Term = union(enum) {
    variable: []const u8,      // Starts with uppercase
    constant: []const u8,      // Quoted string or atom
    number_int: i64,
    number_float: f64,
    
    pub fn format(
        self: Term,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .variable => |v| try writer.print("{s}", .{v}),
            .constant => |c| try writer.print("\"{s}\"", .{c}),
            .number_int => |n| try writer.print("{d}", .{n}),
            .number_float => |n| try writer.print("{d:.4}", .{n}),
        }
    }
};

/// A predicate (fact or goal): name(term1, term2, ...)
pub const Predicate = struct {
    name: []const u8,
    args: []const Term,
    
    pub fn arity(self: Predicate) usize {
        return self.args.len;
    }
};

/// A fact: predicate.
pub const Fact = struct {
    predicate: Predicate,
};

/// A rule: head :- body1, body2, ...
pub const Rule = struct {
    head: Predicate,
    body: []const Predicate,
};

/// Parsed Mangle program
pub const MangleProgram = struct {
    allocator: Allocator,
    facts: std.ArrayList(Fact),
    rules: std.ArrayList(Rule),
    
    pub fn init(allocator: Allocator) MangleProgram {
        return .{
            .allocator = allocator,
            .facts = std.ArrayList(Fact).init(allocator),
            .rules = std.ArrayList(Rule).init(allocator),
        };
    }
    
    pub fn deinit(self: *MangleProgram) void {
        self.facts.deinit();
        self.rules.deinit();
    }
    
    /// Find all facts matching a predicate name
    pub fn findFacts(self: *MangleProgram, name: []const u8) []const Fact {
        var matches = std.ArrayList(Fact).init(self.allocator);
        for (self.facts.items) |fact| {
            if (mem.eql(u8, fact.predicate.name, name)) {
                matches.append(fact) catch continue;
            }
        }
        return matches.toOwnedSlice() catch &[_]Fact{};
    }
    
    /// Find all rules with matching head predicate
    pub fn findRules(self: *MangleProgram, name: []const u8) []const Rule {
        var matches = std.ArrayList(Rule).init(self.allocator);
        for (self.rules.items) |rule| {
            if (mem.eql(u8, rule.head.name, name)) {
                matches.append(rule) catch continue;
            }
        }
        return matches.toOwnedSlice() catch &[_]Rule{};
    }
};

// ============================================================================
// Parser
// ============================================================================

pub const MangleParser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize,
    line: usize,
    col: usize,
    
    pub fn init(allocator: Allocator, source: []const u8) MangleParser {
        return .{
            .allocator = allocator,
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }
    
    /// Parse entire source into a MangleProgram
    pub fn parse(self: *MangleParser) !MangleProgram {
        var program = MangleProgram.init(self.allocator);
        errdefer program.deinit();
        
        while (!self.isEof()) {
            self.skipWhitespaceAndComments();
            if (self.isEof()) break;
            
            // Parse a clause (fact or rule)
            const pred = self.parsePredicate() catch |err| {
                std.log.warn("Parse error at line {d}, col {d}: {}", .{ self.line, self.col, err });
                self.skipToNextLine();
                continue;
            };
            
            self.skipWhitespace();
            
            if (self.peek() == ':') {
                // Rule: head :- body
                self.advance(); // ':'
                if (self.peek() != '-') {
                    self.skipToNextLine();
                    continue;
                }
                self.advance(); // '-'
                
                const body = try self.parseBody();
                try program.rules.append(.{
                    .head = pred,
                    .body = body,
                });
            } else if (self.peek() == '.') {
                // Fact: predicate.
                self.advance(); // '.'
                try program.facts.append(.{
                    .predicate = pred,
                });
            } else {
                // Unexpected, skip to next line
                self.skipToNextLine();
            }
        }
        
        return program;
    }
    
    /// Parse a predicate: name(arg1, arg2, ...)
    fn parsePredicate(self: *MangleParser) !Predicate {
        const name = try self.parseIdentifier();
        
        self.skipWhitespace();
        if (self.peek() != '(') {
            // Zero-arity predicate
            return .{ .name = name, .args = &[_]Term{} };
        }
        
        self.advance(); // '('
        
        var args = std.ArrayList(Term).init(self.allocator);
        errdefer args.deinit();
        
        while (true) {
            self.skipWhitespace();
            if (self.peek() == ')') {
                self.advance();
                break;
            }
            
            const term = try self.parseTerm();
            try args.append(term);
            
            self.skipWhitespace();
            if (self.peek() == ',') {
                self.advance();
            } else if (self.peek() == ')') {
                self.advance();
                break;
            } else {
                return error.UnexpectedChar;
            }
        }
        
        return .{
            .name = name,
            .args = try args.toOwnedSlice(),
        };
    }
    
    /// Parse rule body: pred1, pred2, ...
    fn parseBody(self: *MangleParser) ![]const Predicate {
        var preds = std.ArrayList(Predicate).init(self.allocator);
        errdefer preds.deinit();
        
        while (true) {
            self.skipWhitespace();
            if (self.peek() == '.') {
                self.advance();
                break;
            }
            
            const pred = try self.parsePredicate();
            try preds.append(pred);
            
            self.skipWhitespace();
            if (self.peek() == ',') {
                self.advance();
            } else if (self.peek() == '.') {
                self.advance();
                break;
            } else if (self.peek() == ';') {
                // Disjunction - skip for now
                self.advance();
            }
        }
        
        return try preds.toOwnedSlice();
    }
    
    /// Parse a term (variable, constant, or number)
    fn parseTerm(self: *MangleParser) !Term {
        self.skipWhitespace();
        const c = self.peek();
        
        if (c == '"' or c == '\'') {
            // String constant
            return .{ .constant = try self.parseString() };
        } else if (std.ascii.isDigit(c) or c == '-') {
            // Number
            return self.parseNumber();
        } else if (std.ascii.isUpper(c) or c == '_') {
            // Variable
            return .{ .variable = try self.parseIdentifier() };
        } else if (std.ascii.isLower(c)) {
            // Atom constant
            return .{ .constant = try self.parseIdentifier() };
        } else {
            return error.InvalidTerm;
        }
    }
    
    /// Parse an identifier (starts with letter/underscore)
    fn parseIdentifier(self: *MangleParser) ![]const u8 {
        const start = self.pos;
        while (!self.isEof() and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) {
            self.advance();
        }
        if (start == self.pos) return error.ExpectedIdentifier;
        return self.source[start..self.pos];
    }
    
    /// Parse a quoted string
    fn parseString(self: *MangleParser) ![]const u8 {
        const quote = self.peek();
        self.advance(); // opening quote
        
        const start = self.pos;
        while (!self.isEof() and self.peek() != quote) {
            if (self.peek() == '\\') {
                self.advance(); // skip escape
            }
            self.advance();
        }
        const content = self.source[start..self.pos];
        
        if (!self.isEof()) {
            self.advance(); // closing quote
        }
        
        return content;
    }
    
    /// Parse a number (int or float)
    fn parseNumber(self: *MangleParser) !Term {
        const start = self.pos;
        var has_dot = false;
        
        if (self.peek() == '-') self.advance();
        
        while (!self.isEof() and (std.ascii.isDigit(self.peek()) or self.peek() == '.')) {
            if (self.peek() == '.') {
                if (has_dot) break;
                has_dot = true;
            }
            self.advance();
        }
        
        const num_str = self.source[start..self.pos];
        
        if (has_dot) {
            const f = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
            return .{ .number_float = f };
        } else {
            const i = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidNumber;
            return .{ .number_int = i };
        }
    }
    
    fn skipWhitespace(self: *MangleParser) void {
        while (!self.isEof() and std.ascii.isWhitespace(self.peek())) {
            if (self.peek() == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }
    
    fn skipWhitespaceAndComments(self: *MangleParser) void {
        while (true) {
            self.skipWhitespace();
            if (self.isEof()) return;
            if (self.peek() == '%') {
                self.skipToNextLine();
            } else {
                return;
            }
        }
    }
    
    fn skipToNextLine(self: *MangleParser) void {
        while (!self.isEof() and self.peek() != '\n') {
            self.pos += 1;
        }
        if (!self.isEof()) {
            self.pos += 1; // skip newline
            self.line += 1;
            self.col = 1;
        }
    }
    
    fn peek(self: *MangleParser) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }
    
    fn advance(self: *MangleParser) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
            self.col += 1;
        }
    }
    
    fn isEof(self: *MangleParser) bool {
        return self.pos >= self.source.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parse fact" {
    const allocator = std.testing.allocator;
    var parser = MangleParser.init(allocator, "gpu_device(0, \"T4\", 7.5).");
    var program = try parser.parse();
    defer program.deinit();
    
    try std.testing.expect(program.facts.items.len == 1);
    try std.testing.expectEqualStrings("gpu_device", program.facts.items[0].predicate.name);
}

test "parse rule" {
    const allocator = std.testing.allocator;
    var parser = MangleParser.init(allocator, "big(X) :- size(X, S), S > 100.");
    var program = try parser.parse();
    defer program.deinit();
    
    try std.testing.expect(program.rules.items.len == 1);
    try std.testing.expectEqualStrings("big", program.rules.items[0].head.name);
}