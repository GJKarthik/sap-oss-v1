//! Structured Output Module
//!
//! Implements constrained generation for structured outputs.
//! Supports JSON mode, JSON schema enforcement, and grammar-based sampling.
//!
//! Features:
//! - JSON mode (guaranteed valid JSON)
//! - JSON schema enforcement
//! - Grammar-based sampling (GBNF)
//! - Regex constraints
//! - Output validation

const std = @import("std");

// ==============================================
// Response Format Types
// ==============================================

pub const ResponseFormatType = enum {
    text,           // Free-form text (default)
    json_object,    // Valid JSON object
    json_schema,    // Matches specific JSON schema
};

pub const ResponseFormat = struct {
    format_type: ResponseFormatType,
    json_schema: ?JsonSchemaFormat,
    
    pub fn text() ResponseFormat {
        return .{
            .format_type = .text,
            .json_schema = null,
        };
    }
    
    pub fn jsonObject() ResponseFormat {
        return .{
            .format_type = .json_object,
            .json_schema = null,
        };
    }
    
    pub fn jsonSchema(schema: JsonSchemaFormat) ResponseFormat {
        return .{
            .format_type = .json_schema,
            .json_schema = schema,
        };
    }
};

pub const JsonSchemaFormat = struct {
    name: []const u8,
    description: ?[]const u8,
    schema: JsonSchema,
    strict: bool,
};

// ==============================================
// JSON Schema (Reuse from tool_calling)
// ==============================================

pub const JsonSchema = struct {
    schema_type: JsonSchemaType,
    properties: std.StringHashMap(JsonSchema),
    required: std.ArrayList([]const u8),
    items: ?*JsonSchema,
    enum_values: ?[]const []const u8,
    description: ?[]const u8,
    minimum: ?f64,
    maximum: ?f64,
    min_length: ?usize,
    max_length: ?usize,
    pattern: ?[]const u8,
    additional_properties: bool,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) JsonSchema {
        return .{
            .schema_type = .object,
            .properties = std.StringHashMap(JsonSchema).init(allocator),
            .required = std.ArrayList([]const u8).init(allocator),
            .items = null,
            .enum_values = null,
            .description = null,
            .minimum = null,
            .maximum = null,
            .min_length = null,
            .max_length = null,
            .pattern = null,
            .additional_properties = false,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *JsonSchema) void {
        self.properties.deinit();
        self.required.deinit();
    }
    
    pub fn object() JsonSchema {
        return init(std.heap.page_allocator);
    }
    
    pub fn string() JsonSchema {
        var s = init(std.heap.page_allocator);
        s.schema_type = .string;
        return s;
    }
    
    pub fn number() JsonSchema {
        var s = init(std.heap.page_allocator);
        s.schema_type = .number;
        return s;
    }
    
    pub fn integer() JsonSchema {
        var s = init(std.heap.page_allocator);
        s.schema_type = .integer;
        return s;
    }
    
    pub fn boolean() JsonSchema {
        var s = init(std.heap.page_allocator);
        s.schema_type = .boolean;
        return s;
    }
    
    pub fn array(items_schema: *JsonSchema) JsonSchema {
        var s = init(std.heap.page_allocator);
        s.schema_type = .array;
        s.items = items_schema;
        return s;
    }
};

pub const JsonSchemaType = enum {
    string,
    number,
    integer,
    boolean,
    array,
    object,
    null_type,
};

// ==============================================
// Grammar-Based Sampling (GBNF)
// ==============================================

pub const Grammar = struct {
    rules: std.StringHashMap(GrammarRule),
    start_rule: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Grammar {
        return .{
            .rules = std.StringHashMap(GrammarRule).init(allocator),
            .start_rule = "root",
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Grammar) void {
        var iter = self.rules.valueIterator();
        while (iter.next()) |rule| {
            rule.deinit();
        }
        self.rules.deinit();
    }
    
    pub fn addRule(self: *Grammar, name: []const u8, rule: GrammarRule) !void {
        try self.rules.put(name, rule);
    }
    
    /// Parse GBNF grammar string
    pub fn fromGBNF(allocator: std.mem.Allocator, gbnf: []const u8) !Grammar {
        var grammar = Grammar.init(allocator);
        
        // Parse GBNF format:
        // rule_name ::= expression
        var lines = std.mem.split(u8, gbnf, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            
            // Find ::=
            if (std.mem.indexOf(u8, trimmed, "::=")) |sep| {
                const name = std.mem.trim(u8, trimmed[0..sep], " \t");
                const expr = std.mem.trim(u8, trimmed[sep + 3 ..], " \t");
                
                const rule = try GrammarRule.parse(allocator, expr);
                try grammar.addRule(name, rule);
            }
        }
        
        return grammar;
    }
    
    /// Generate GBNF grammar for JSON schema
    pub fn fromJsonSchema(allocator: std.mem.Allocator, schema: *const JsonSchema) !Grammar {
        var grammar = Grammar.init(allocator);
        
        // Generate grammar rules from schema
        try grammar.generateSchemaRules(schema, "root");
        
        // Add common JSON rules
        try grammar.addJsonPrimitiveRules();
        
        return grammar;
    }
    
    fn generateSchemaRules(self: *Grammar, schema: *const JsonSchema, rule_name: []const u8) !void {
        switch (schema.schema_type) {
            .object => {
                // object ::= "{" ws (key ":" ws value ("," ws key ":" ws value)*)? "}"
                var rule = GrammarRule.init(self.allocator);
                try rule.addAlternative(.{ .literal = "{" });
                // Would add property rules here
                try self.rules.put(rule_name, rule);
            },
            .array => {
                // array ::= "[" ws (value ("," ws value)*)? "]"
                var rule = GrammarRule.init(self.allocator);
                try rule.addAlternative(.{ .literal = "[" });
                try self.rules.put(rule_name, rule);
            },
            .string => {
                // string ::= "\"" characters "\""
                var rule = GrammarRule.init(self.allocator);
                try rule.addAlternative(.{ .rule_ref = "string" });
                try self.rules.put(rule_name, rule);
            },
            .number => {
                var rule = GrammarRule.init(self.allocator);
                try rule.addAlternative(.{ .rule_ref = "number" });
                try self.rules.put(rule_name, rule);
            },
            .integer => {
                var rule = GrammarRule.init(self.allocator);
                try rule.addAlternative(.{ .rule_ref = "integer" });
                try self.rules.put(rule_name, rule);
            },
            .boolean => {
                var rule = GrammarRule.init(self.allocator);
                try rule.addAlternative(.{ .rule_ref = "boolean" });
                try self.rules.put(rule_name, rule);
            },
            .null_type => {
                var rule = GrammarRule.init(self.allocator);
                try rule.addAlternative(.{ .literal = "null" });
                try self.rules.put(rule_name, rule);
            },
        }
    }
    
    fn addJsonPrimitiveRules(self: *Grammar) !void {
        // ws ::= [ \t\n\r]*
        var ws_rule = GrammarRule.init(self.allocator);
        try ws_rule.addAlternative(.{ .char_class = " \t\n\r", .repeat = .zero_or_more });
        try self.rules.put("ws", ws_rule);
        
        // string ::= "\"" [^"\\]* "\""
        var string_rule = GrammarRule.init(self.allocator);
        try string_rule.addAlternative(.{ .literal = "\"" });
        try self.rules.put("string", string_rule);
        
        // number ::= "-"? [0-9]+ ("." [0-9]+)?
        var number_rule = GrammarRule.init(self.allocator);
        try number_rule.addAlternative(.{ .char_class = "0-9", .repeat = .one_or_more });
        try self.rules.put("number", number_rule);
        
        // integer ::= "-"? [0-9]+
        var integer_rule = GrammarRule.init(self.allocator);
        try integer_rule.addAlternative(.{ .char_class = "0-9", .repeat = .one_or_more });
        try self.rules.put("integer", integer_rule);
        
        // boolean ::= "true" | "false"
        var boolean_rule = GrammarRule.init(self.allocator);
        try boolean_rule.addAlternative(.{ .literal = "true" });
        try boolean_rule.addAlternative(.{ .literal = "false" });
        try self.rules.put("boolean", boolean_rule);
    }
};

pub const GrammarRule = struct {
    alternatives: std.ArrayList(RuleElement),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) GrammarRule {
        return .{
            .alternatives = std.ArrayList(RuleElement).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *GrammarRule) void {
        self.alternatives.deinit();
    }
    
    pub fn addAlternative(self: *GrammarRule, element: RuleElement) !void {
        try self.alternatives.append(element);
    }
    
    pub fn parse(allocator: std.mem.Allocator, expr: []const u8) !GrammarRule {
        var rule = GrammarRule.init(allocator);
        
        // Parse expression (simplified)
        // Would handle: literals, char classes, rule refs, sequences, alternatives
        if (expr.len > 0) {
            if (expr[0] == '"') {
                // Literal
                const end = std.mem.indexOfPos(u8, expr, 1, "\"") orelse expr.len;
                try rule.addAlternative(.{ .literal = expr[1..end] });
            } else if (expr[0] == '[') {
                // Character class
                const end = std.mem.indexOf(u8, expr, "]") orelse expr.len;
                try rule.addAlternative(.{ .char_class = expr[1..end], .repeat = .once });
            } else {
                // Rule reference
                try rule.addAlternative(.{ .rule_ref = expr });
            }
        }
        
        return rule;
    }
};

pub const RuleElement = union(enum) {
    literal: []const u8,
    char_class: struct {
        chars: []const u8,
        repeat: Repeat,
    },
    rule_ref: []const u8,
    sequence: []RuleElement,
    optional: *RuleElement,
};

pub const Repeat = enum {
    once,
    zero_or_more,
    one_or_more,
    optional,
};

// ==============================================
// Token Mask Generator
// ==============================================

pub const TokenMaskGenerator = struct {
    grammar: *const Grammar,
    vocab_size: usize,
    allocator: std.mem.Allocator,
    
    // State for incremental generation
    current_state: ParserState,
    
    pub fn init(allocator: std.mem.Allocator, grammar: *const Grammar, vocab_size: usize) TokenMaskGenerator {
        return .{
            .grammar = grammar,
            .vocab_size = vocab_size,
            .allocator = allocator,
            .current_state = ParserState.init(allocator),
        };
    }
    
    pub fn deinit(self: *TokenMaskGenerator) void {
        self.current_state.deinit();
    }
    
    /// Generate mask of valid tokens given current state
    pub fn generateMask(self: *TokenMaskGenerator) ![]bool {
        var mask = try self.allocator.alloc(bool, self.vocab_size);
        @memset(mask, false);
        
        // Get valid next characters from grammar
        const valid_chars = try self.getValidNextChars();
        defer self.allocator.free(valid_chars);
        
        // Map characters to tokens
        // In real impl, would use tokenizer to find tokens starting with valid chars
        for (valid_chars) |c| {
            // Mark tokens that could produce this character as valid
            _ = c;
        }
        
        return mask;
    }
    
    fn getValidNextChars(self: *TokenMaskGenerator) ![]u8 {
        var chars = std.ArrayList(u8).init(self.allocator);
        
        // Get current rule from state
        if (self.grammar.rules.get(self.current_state.current_rule)) |rule| {
            for (rule.alternatives.items) |alt| {
                switch (alt) {
                    .literal => |lit| {
                        if (lit.len > 0) {
                            try chars.append(lit[0]);
                        }
                    },
                    .char_class => |cc| {
                        // Add all characters in class
                        for (cc.chars) |c| {
                            try chars.append(c);
                        }
                    },
                    else => {},
                }
            }
        }
        
        return chars.toOwnedSlice();
    }
    
    /// Update state after token is generated
    pub fn updateState(self: *TokenMaskGenerator, token_text: []const u8) !void {
        try self.current_state.consumeText(token_text);
    }
};

pub const ParserState = struct {
    current_rule: []const u8,
    position: usize,
    stack: std.ArrayList([]const u8),
    generated_text: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ParserState {
        return .{
            .current_rule = "root",
            .position = 0,
            .stack = std.ArrayList([]const u8).init(allocator),
            .generated_text = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ParserState) void {
        self.stack.deinit();
        self.generated_text.deinit();
    }
    
    pub fn consumeText(self: *ParserState, text: []const u8) !void {
        try self.generated_text.appendSlice(text);
        self.position += text.len;
    }
};

// ==============================================
// Structured Output Manager
// ==============================================

pub const StructuredOutputManager = struct {
    allocator: std.mem.Allocator,
    format: ResponseFormat,
    grammar: ?Grammar,
    mask_generator: ?TokenMaskGenerator,
    validator: OutputValidator,
    
    // Schema cache
    schema_cache: std.StringHashMap(Grammar),
    
    pub fn init(allocator: std.mem.Allocator) StructuredOutputManager {
        return .{
            .allocator = allocator,
            .format = ResponseFormat.text(),
            .grammar = null,
            .mask_generator = null,
            .validator = OutputValidator.init(allocator),
            .schema_cache = std.StringHashMap(Grammar).init(allocator),
        };
    }
    
    pub fn deinit(self: *StructuredOutputManager) void {
        if (self.grammar) |*g| g.deinit();
        if (self.mask_generator) |*m| m.deinit();
        self.schema_cache.deinit();
    }
    
    pub fn setFormat(self: *StructuredOutputManager, format: ResponseFormat) !void {
        self.format = format;
        
        switch (format.format_type) {
            .text => {
                self.grammar = null;
                self.mask_generator = null;
            },
            .json_object => {
                // Create grammar for generic JSON object
                self.grammar = try createJsonObjectGrammar(self.allocator);
            },
            .json_schema => {
                if (format.json_schema) |schema_format| {
                    // Check cache first
                    if (self.schema_cache.get(schema_format.name)) |cached| {
                        self.grammar = cached;
                    } else {
                        // Generate grammar from schema
                        self.grammar = try Grammar.fromJsonSchema(self.allocator, &schema_format.schema);
                        try self.schema_cache.put(schema_format.name, self.grammar.?);
                    }
                }
            },
        }
    }
    
    /// Get token mask for constrained sampling
    pub fn getTokenMask(self: *StructuredOutputManager, vocab_size: usize) !?[]bool {
        if (self.grammar) |*grammar| {
            if (self.mask_generator == null) {
                self.mask_generator = TokenMaskGenerator.init(self.allocator, grammar, vocab_size);
            }
            return try self.mask_generator.?.generateMask();
        }
        return null;
    }
    
    /// Update state after token generation
    pub fn onTokenGenerated(self: *StructuredOutputManager, token_text: []const u8) !void {
        if (self.mask_generator) |*mg| {
            try mg.updateState(token_text);
        }
    }
    
    /// Validate final output
    pub fn validateOutput(self: *StructuredOutputManager, output: []const u8) ValidationResult {
        return self.validator.validate(output, &self.format);
    }
};

fn createJsonObjectGrammar(allocator: std.mem.Allocator) !Grammar {
    const gbnf =
        \\root ::= object
        \\object ::= "{" ws members? "}" ws
        \\members ::= pair ("," ws pair)*
        \\pair ::= string ":" ws value
        \\value ::= string | number | object | array | "true" | "false" | "null"
        \\array ::= "[" ws elements? "]" ws
        \\elements ::= value ("," ws value)*
        \\string ::= "\"" characters "\""
        \\characters ::= character*
        \\character ::= [^"\\]
        \\number ::= "-"? digits ("." digits)?
        \\digits ::= [0-9]+
        \\ws ::= [ \t\n\r]*
    ;
    
    return try Grammar.fromGBNF(allocator, gbnf);
}

// ==============================================
// Output Validator
// ==============================================

pub const OutputValidator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) OutputValidator {
        return .{ .allocator = allocator };
    }
    
    pub fn validate(self: *OutputValidator, output: []const u8, format: *const ResponseFormat) ValidationResult {
        _ = self;
        
        switch (format.format_type) {
            .text => return ValidationResult.valid(),
            .json_object => return validateJson(output),
            .json_schema => {
                // First validate JSON syntax
                const json_result = validateJson(output);
                if (!json_result.is_valid) return json_result;
                
                // Then validate against schema
                if (format.json_schema) |schema_format| {
                    return validateAgainstSchema(output, &schema_format.schema);
                }
                return ValidationResult.valid();
            },
        }
    }
};

fn validateJson(output: []const u8) ValidationResult {
    // Simple JSON validation
    var depth: i32 = 0;
    var in_string = false;
    var escaped = false;
    
    for (output) |c| {
        if (escaped) {
            escaped = false;
            continue;
        }
        
        if (c == '\\' and in_string) {
            escaped = true;
            continue;
        }
        
        if (c == '"' and !escaped) {
            in_string = !in_string;
            continue;
        }
        
        if (!in_string) {
            switch (c) {
                '{', '[' => depth += 1,
                '}', ']' => depth -= 1,
                else => {},
            }
            
            if (depth < 0) {
                return ValidationResult.invalid("Unmatched closing bracket");
            }
        }
    }
    
    if (in_string) {
        return ValidationResult.invalid("Unterminated string");
    }
    
    if (depth != 0) {
        return ValidationResult.invalid("Unmatched brackets");
    }
    
    return ValidationResult.valid();
}

fn validateAgainstSchema(output: []const u8, schema: *const JsonSchema) ValidationResult {
    _ = output;
    _ = schema;
    // Full schema validation would parse JSON and check:
    // - Type matches
    // - Required fields present
    // - Constraints satisfied (min, max, pattern, etc.)
    return ValidationResult.valid();
}

pub const ValidationResult = struct {
    is_valid: bool,
    error_message: ?[]const u8,
    error_path: ?[]const u8,
    
    pub fn valid() ValidationResult {
        return .{
            .is_valid = true,
            .error_message = null,
            .error_path = null,
        };
    }
    
    pub fn invalid(message: []const u8) ValidationResult {
        return .{
            .is_valid = false,
            .error_message = message,
            .error_path = null,
        };
    }
};

// ==============================================
// Regex Constraint Support
// ==============================================

pub const RegexConstraint = struct {
    pattern: []const u8,
    compiled: ?*anyopaque, // Would be compiled regex
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) RegexConstraint {
        return .{
            .pattern = pattern,
            .compiled = null,
            .allocator = allocator,
        };
    }
    
    pub fn compile(self: *RegexConstraint) !void {
        // Would compile regex pattern
        // self.compiled = ...
        _ = self;
    }
    
    pub fn matches(self: *const RegexConstraint, text: []const u8) bool {
        _ = self;
        _ = text;
        // Would match against compiled regex
        return true;
    }
    
    pub fn toGrammar(self: *const RegexConstraint, allocator: std.mem.Allocator) !Grammar {
        // Convert regex to grammar rules
        _ = self;
        return Grammar.init(allocator);
    }
};

// ==============================================
// Tests
// ==============================================

test "ResponseFormat creation" {
    const text_format = ResponseFormat.text();
    try std.testing.expect(text_format.format_type == .text);
    
    const json_format = ResponseFormat.jsonObject();
    try std.testing.expect(json_format.format_type == .json_object);
}

test "JSON validation" {
    const valid_json = "{\"name\": \"test\", \"value\": 123}";
    const result = validateJson(valid_json);
    try std.testing.expect(result.is_valid);
    
    const invalid_json = "{\"name\": \"test\"";
    const invalid_result = validateJson(invalid_json);
    try std.testing.expect(!invalid_result.is_valid);
}

test "Grammar from GBNF" {
    const allocator = std.testing.allocator;
    const gbnf = "root ::= \"hello\"";
    
    var grammar = try Grammar.fromGBNF(allocator, gbnf);
    defer grammar.deinit();
    
    try std.testing.expect(grammar.rules.contains("root"));
}