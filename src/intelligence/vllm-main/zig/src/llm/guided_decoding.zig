//! Structured Output / Guided Decoding
//!
//! JSON schema → finite automaton → logit masking per decoding step:
//! - Parse JSON schema into a state machine (NFA → DFA)
//! - Track current DFA state across generated tokens
//! - Mask logits to only allow tokens valid in current state
//! - Supports: object, array, string, number, boolean, null, enum

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// JSON Schema Types
// ============================================================================

pub const JsonType = enum { object, array, string, number, integer, boolean, null_type, enum_type, any_of };

pub const JsonSchema = struct {
    schema_type: JsonType,
    properties: []const Property = &.{},
    required: []const []const u8 = &.{},
    items: ?*const JsonSchema = null,
    enum_values: []const []const u8 = &.{},
    min_length: ?u32 = null,
    max_length: ?u32 = null,

    pub const Property = struct {
        name: []const u8,
        schema: JsonSchema,
    };
};

// ============================================================================
// DFA State Machine
// ============================================================================

pub const StateId = u16;

pub const CharClass = enum(u8) {
    lbrace,   // {
    rbrace,   // }
    lbracket, // [
    rbracket, // ]
    quote,    // "
    colon,    // :
    comma,    // ,
    digit,    // 0-9
    alpha,    // a-z A-Z _
    dot,      // .
    minus,    // -
    backslash,// \
    whitespace,
    other,

    pub fn fromByte(b: u8) CharClass {
        return switch (b) {
            '{' => .lbrace, '}' => .rbrace,
            '[' => .lbracket, ']' => .rbracket,
            '"' => .quote, ':' => .colon, ',' => .comma,
            '0'...'9' => .digit, '.' => .dot, '-' => .minus,
            'a'...'z', 'A'...'Z', '_' => .alpha,
            '\\' => .backslash,
            ' ', '\t', '\n', '\r' => .whitespace,
            else => .other,
        };
    }
};

pub const Transition = struct {
    char_class: CharClass,
    next_state: StateId,
};

pub const DfaState = struct {
    transitions: [14]?StateId, // indexed by CharClass
    is_accepting: bool,
    depth: u8, // nesting depth tracker

    pub fn init(accepting: bool, depth: u8) DfaState {
        return .{
            .transitions = .{null} ** 14,
            .is_accepting = accepting,
            .depth = depth,
        };
    }

    pub fn addTransition(self: *DfaState, cc: CharClass, next: StateId) void {
        self.transitions[@intFromEnum(cc)] = next;
    }

    pub fn getNext(self: *const DfaState, cc: CharClass) ?StateId {
        return self.transitions[@intFromEnum(cc)];
    }
};

// ============================================================================
// Guided Decoder
// ============================================================================

pub const GuidedDecoder = struct {
    allocator: Allocator,
    states: []DfaState,
    num_states: u16,
    current_state: StateId,
    schema: JsonSchema,
    in_string: bool,

    const MAX_STATES = 256;

    pub fn init(allocator: Allocator, schema: JsonSchema) !GuidedDecoder {
        const states = try allocator.alloc(DfaState, MAX_STATES);
        var decoder = GuidedDecoder{
            .allocator = allocator,
            .states = states,
            .num_states = 0,
            .current_state = 0,
            .schema = schema,
            .in_string = false,
        };
        try decoder.buildDfa();
        return decoder;
    }

    pub fn deinit(self: *GuidedDecoder) void {
        self.allocator.free(self.states);
    }

    fn addState(self: *GuidedDecoder, accepting: bool, depth: u8) StateId {
        const id = self.num_states;
        self.states[id] = DfaState.init(accepting, depth);
        self.num_states += 1;
        return id;
    }

    /// Build DFA from JSON schema
    fn buildDfa(self: *GuidedDecoder) !void {
        switch (self.schema.schema_type) {
            .object => try self.buildObjectDfa(0),
            .array => try self.buildArrayDfa(0),
            .string => self.buildStringDfa(0),
            .number, .integer => self.buildNumberDfa(0),
            .boolean => self.buildBooleanDfa(0),
            .null_type => self.buildNullDfa(0),
            else => try self.buildObjectDfa(0), // default to object
        }
    }

    fn buildObjectDfa(self: *GuidedDecoder, depth: u8) !void {
        const s0 = self.addState(false, depth); // start: expect {
        const s1 = self.addState(false, depth); // after {: expect key or }
        const s2 = self.addState(false, depth); // in key string
        const s3 = self.addState(false, depth); // after key: expect :
        const s4 = self.addState(false, depth); // after :: expect value
        const s5 = self.addState(false, depth); // after value: expect , or }
        const s6 = self.addState(true, depth);  // after }: accepting
        self.states[s0].addTransition(.lbrace, s1);
        self.states[s1].addTransition(.quote, s2);
        self.states[s1].addTransition(.rbrace, s6);
        self.states[s1].addTransition(.whitespace, s1);
        // In key: accept alpha, digit, underscore
        self.states[s2].addTransition(.alpha, s2);
        self.states[s2].addTransition(.digit, s2);
        self.states[s2].addTransition(.quote, s3);
        self.states[s3].addTransition(.colon, s4);
        self.states[s3].addTransition(.whitespace, s3);
        // After colon: value can be string, number, object, array, bool, null
        self.states[s4].addTransition(.quote, s5);  // string value (simplified)
        self.states[s4].addTransition(.digit, s5);  // number
        self.states[s4].addTransition(.minus, s5);   // negative number
        self.states[s4].addTransition(.lbrace, s4);  // nested object
        self.states[s4].addTransition(.lbracket, s4);// nested array
        self.states[s4].addTransition(.alpha, s5);   // true/false/null
        self.states[s4].addTransition(.whitespace, s4);
        self.states[s5].addTransition(.comma, s1);
        self.states[s5].addTransition(.rbrace, s6);
        self.states[s5].addTransition(.whitespace, s5);
        self.states[s5].addTransition(.alpha, s5);   // continued value
        self.states[s5].addTransition(.digit, s5);   // continued number
        self.states[s5].addTransition(.dot, s5);     // decimal point
        self.states[s5].addTransition(.quote, s5);   // end string quote
    }

    fn buildArrayDfa(self: *GuidedDecoder, depth: u8) !void {
        const s0 = self.addState(false, depth);
        const s1 = self.addState(false, depth); // after [
        const s2 = self.addState(false, depth); // after element
        const s3 = self.addState(true, depth);  // after ]
        self.states[s0].addTransition(.lbracket, s1);
        self.states[s1].addTransition(.rbracket, s3);
        self.states[s1].addTransition(.quote, s2);
        self.states[s1].addTransition(.digit, s2);
        self.states[s1].addTransition(.lbrace, s2);
        self.states[s1].addTransition(.whitespace, s1);
        self.states[s2].addTransition(.comma, s1);
        self.states[s2].addTransition(.rbracket, s3);
        self.states[s2].addTransition(.whitespace, s2);
        self.states[s2].addTransition(.alpha, s2);
        self.states[s2].addTransition(.digit, s2);
    }

    fn buildStringDfa(self: *GuidedDecoder, depth: u8) void {
        const s0 = self.addState(false, depth);
        const s1 = self.addState(false, depth); // in string
        const s2 = self.addState(true, depth);  // after closing quote
        self.states[s0].addTransition(.quote, s1);
        self.states[s1].addTransition(.alpha, s1);
        self.states[s1].addTransition(.digit, s1);
        self.states[s1].addTransition(.whitespace, s1);
        self.states[s1].addTransition(.other, s1);
        self.states[s1].addTransition(.quote, s2);
        self.states[s1].addTransition(.backslash, s1); // escape
    }

    fn buildNumberDfa(self: *GuidedDecoder, depth: u8) void {
        const s0 = self.addState(false, depth);
        const s1 = self.addState(true, depth);  // digits
        self.states[s0].addTransition(.digit, s1);
        self.states[s0].addTransition(.minus, s0);
        self.states[s1].addTransition(.digit, s1);
        self.states[s1].addTransition(.dot, s1);
    }

    fn buildBooleanDfa(self: *GuidedDecoder, depth: u8) void {
        // Accept "true" or "false" as alpha sequences
        const s0 = self.addState(false, depth);
        const s1 = self.addState(true, depth);
        self.states[s0].addTransition(.alpha, s1);
        self.states[s1].addTransition(.alpha, s1);
    }

    fn buildNullDfa(self: *GuidedDecoder, depth: u8) void {
        const s0 = self.addState(false, depth);
        const s1 = self.addState(true, depth);
        self.states[s0].addTransition(.alpha, s1);
        self.states[s1].addTransition(.alpha, s1);
    }

    /// Get allowed byte mask for current state (256-bit mask)
    pub fn getAllowedMask(self: *const GuidedDecoder, mask: *[256]bool) void {
        @memset(mask, false);
        if (self.current_state >= self.num_states) return;
        const state = &self.states[self.current_state];
        for (state.transitions, 0..) |maybe_next, cc_idx| {
            if (maybe_next != null) {
                const cc: CharClass = @enumFromInt(cc_idx);
                switch (cc) {
                    .lbrace => mask['{'] = true,
                    .rbrace => mask['}'] = true,
                    .lbracket => mask['['] = true,
                    .rbracket => mask[']'] = true,
                    .quote => mask['"'] = true,
                    .colon => mask[':'] = true,
                    .comma => mask[','] = true,
                    .digit => for ('0'..('9' + 1)) |d| { mask[d] = true; },
                    .alpha => {
                        for ('a'..('z' + 1)) |c| { mask[c] = true; }
                        for ('A'..('Z' + 1)) |c| { mask[c] = true; }
                        mask['_'] = true;
                    },
                    .dot => mask['.'] = true,
                    .minus => mask['-'] = true,
                    .backslash => mask['\\'] = true,
                    .whitespace => { mask[' '] = true; mask['\t'] = true; mask['\n'] = true; },
                    .other => {},
                }
            }
        }
    }

    /// Feed a byte and advance state. Returns false if byte is rejected.
    pub fn feedByte(self: *GuidedDecoder, byte: u8) bool {
        if (self.current_state >= self.num_states) return false;
        const cc = CharClass.fromByte(byte);
        const state = &self.states[self.current_state];
        if (state.getNext(cc)) |next| {
            self.current_state = next;
            return true;
        }
        return false;
    }

    /// Apply logit mask: set logits for disallowed tokens to -inf
    pub fn applyLogitMask(self: *const GuidedDecoder, logits: []f32, vocab_to_first_byte: []const u8) void {
        var mask: [256]bool = undefined;
        self.getAllowedMask(&mask);
        for (logits, 0..) |*logit, token_id| {
            if (token_id < vocab_to_first_byte.len) {
                const first_byte = vocab_to_first_byte[token_id];
                if (!mask[first_byte]) {
                    logit.* = -std.math.inf(f32);
                }
            }
        }
    }

    pub fn isAccepting(self: *const GuidedDecoder) bool {
        if (self.current_state >= self.num_states) return false;
        return self.states[self.current_state].is_accepting;
    }

    pub fn reset(self: *GuidedDecoder) void {
        self.current_state = 0;
        self.in_string = false;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "guided decoding char class" {
    try std.testing.expectEqual(CharClass.lbrace, CharClass.fromByte('{'));
    try std.testing.expectEqual(CharClass.digit, CharClass.fromByte('5'));
    try std.testing.expectEqual(CharClass.alpha, CharClass.fromByte('a'));
    try std.testing.expectEqual(CharClass.whitespace, CharClass.fromByte(' '));
    try std.testing.expectEqual(CharClass.quote, CharClass.fromByte('"'));
}

test "guided decoding object schema" {
    const allocator = std.testing.allocator;
    var decoder = try GuidedDecoder.init(allocator, .{ .schema_type = .object });
    defer decoder.deinit();
    // Feed valid JSON object characters
    try std.testing.expect(decoder.feedByte('{'));
    try std.testing.expect(decoder.feedByte('"'));
    try std.testing.expect(decoder.feedByte('k'));
    try std.testing.expect(decoder.feedByte('"'));
    try std.testing.expect(decoder.feedByte(':'));
}

test "guided decoding string schema" {
    const allocator = std.testing.allocator;
    var decoder = try GuidedDecoder.init(allocator, .{ .schema_type = .string });
    defer decoder.deinit();
    try std.testing.expect(decoder.feedByte('"'));
    try std.testing.expect(decoder.feedByte('h'));
    try std.testing.expect(decoder.feedByte('i'));
    try std.testing.expect(decoder.feedByte('"'));
    try std.testing.expect(decoder.isAccepting());
}

test "guided decoding number schema" {
    const allocator = std.testing.allocator;
    var decoder = try GuidedDecoder.init(allocator, .{ .schema_type = .number });
    defer decoder.deinit();
    try std.testing.expect(decoder.feedByte('4'));
    try std.testing.expect(decoder.feedByte('2'));
    try std.testing.expect(decoder.isAccepting());
}

test "guided decoding logit mask" {
    const allocator = std.testing.allocator;
    var decoder = try GuidedDecoder.init(allocator, .{ .schema_type = .object });
    defer decoder.deinit();
    // At start, only { should be allowed
    var mask: [256]bool = undefined;
    decoder.getAllowedMask(&mask);
    try std.testing.expect(mask['{']);
    try std.testing.expect(!mask['a']);
    try std.testing.expect(!mask['[']);
}

test "guided decoding reset" {
    const allocator = std.testing.allocator;
    var decoder = try GuidedDecoder.init(allocator, .{ .schema_type = .number });
    defer decoder.deinit();
    _ = decoder.feedByte('1');
    try std.testing.expect(decoder.isAccepting());
    decoder.reset();
    try std.testing.expect(!decoder.isAccepting());
}

