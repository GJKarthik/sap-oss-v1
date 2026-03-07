// Mangle: Functions - Built-in Functions for Query Engine
//
// Converted from: kuzu function semantics
//
// Purpose:
// Defines built-in scalar functions for string, math, and date operations.
// These are used in expressions and computed columns.

// ============================================================================
// String Functions
// ============================================================================

// String length
// str_length(InputString, Length)
Decl str_length(input: String, length: i64).

// Upper case conversion
// str_upper(Input, Output)
Decl str_upper(input: String, output: String).

// Lower case conversion
// str_lower(Input, Output)
Decl str_lower(input: String, output: String).

// String trim (both sides)
// str_trim(Input, Output)
Decl str_trim(input: String, output: String).

// Left trim
// str_ltrim(Input, Output)
Decl str_ltrim(input: String, output: String).

// Right trim
// str_rtrim(Input, Output)
Decl str_rtrim(input: String, output: String).

// Substring
// str_substring(Input, Start, Length, Output)
Decl str_substring(input: String, start: i64, length: i64, output: String).

// String concatenation
// str_concat(Left, Right, Output)
Decl str_concat(left: String, right: String, output: String).

// String contains
// str_contains(Haystack, Needle, Result)
Decl str_contains(haystack: String, needle: String, result: bool).

// String starts with
// str_starts_with(Input, Prefix, Result)
Decl str_starts_with(input: String, prefix: String, result: bool).

// String ends with
// str_ends_with(Input, Suffix, Result)
Decl str_ends_with(input: String, suffix: String, result: bool).

// String replace
// str_replace(Input, Search, Replace, Output)
Decl str_replace(input: String, search: String, replace: String, output: String).

// String reverse
// str_reverse(Input, Output)
Decl str_reverse(input: String, output: String).

// String repeat
// str_repeat(Input, Count, Output)
Decl str_repeat(input: String, count: i64, output: String).

// Left pad
// str_lpad(Input, Length, PadChar, Output)
Decl str_lpad(input: String, length: i64, pad_char: String, output: String).

// Right pad
// str_rpad(Input, Length, PadChar, Output)
Decl str_rpad(input: String, length: i64, pad_char: String, output: String).

// ============================================================================
// Math Functions
// ============================================================================

// Absolute value (integer)
// math_abs_int(Input, Output)
Decl math_abs_int(input: i64, output: i64).

math_abs_int(X, X) :- X >= 0.
math_abs_int(X, -X) :- X < 0.

// Absolute value (float)
// math_abs_float(Input, Output)
Decl math_abs_float(input: f64, output: f64).

// Ceiling
// math_ceil(Input, Output)
Decl math_ceil(input: f64, output: i64).

// Floor
// math_floor(Input, Output)
Decl math_floor(input: f64, output: i64).

// Round
// math_round(Input, Output)
Decl math_round(input: f64, output: i64).

// Round to decimal places
// math_round_dp(Input, DecimalPlaces, Output)
Decl math_round_dp(input: f64, dp: i32, output: f64).

// Sign
// math_sign(Input, Output)
// Output: -1, 0, or 1
Decl math_sign(input: f64, output: i32).

math_sign(X, 1) :- X > 0.
math_sign(X, 0) :- X = 0.
math_sign(X, -1) :- X < 0.

// Power
// math_pow(Base, Exponent, Result)
Decl math_pow(base: f64, exp: f64, result: f64).

// Square root
// math_sqrt(Input, Output)
Decl math_sqrt(input: f64, output: f64).

// Natural logarithm
// math_ln(Input, Output)
Decl math_ln(input: f64, output: f64).

// Logarithm base 10
// math_log10(Input, Output)
Decl math_log10(input: f64, output: f64).

// Logarithm base 2
// math_log2(Input, Output)
Decl math_log2(input: f64, output: f64).

// Exponential
// math_exp(Input, Output)
Decl math_exp(input: f64, output: f64).

// Modulo
// math_mod(Dividend, Divisor, Remainder)
Decl math_mod(dividend: i64, divisor: i64, remainder: i64).

// ============================================================================
// Trigonometric Functions
// ============================================================================

// Sine
Decl math_sin(input: f64, output: f64).

// Cosine
Decl math_cos(input: f64, output: f64).

// Tangent
Decl math_tan(input: f64, output: f64).

// Arc sine
Decl math_asin(input: f64, output: f64).

// Arc cosine
Decl math_acos(input: f64, output: f64).

// Arc tangent
Decl math_atan(input: f64, output: f64).

// Arc tangent 2 (y, x)
Decl math_atan2(y: f64, x: f64, output: f64).

// Radians to degrees
Decl math_degrees(radians: f64, degrees: f64).

// Degrees to radians
Decl math_radians(degrees: f64, radians: f64).

// Pi constant
Decl math_pi(value: f64).
math_pi(3.14159265358979323846).

// ============================================================================
// Type Conversion Functions
// ============================================================================

// Cast integer to float
// cast_int_to_float(IntValue, FloatValue)
Decl cast_int_to_float(int_val: i64, float_val: f64).

// Cast float to integer (truncate)
// cast_float_to_int(FloatValue, IntValue)
Decl cast_float_to_int(float_val: f64, int_val: i64).

// Cast to string
// cast_int_to_string(IntValue, StringValue)
Decl cast_int_to_string(int_val: i64, str_val: String).

// cast_float_to_string(FloatValue, StringValue)
Decl cast_float_to_string(float_val: f64, str_val: String).

// cast_bool_to_string(BoolValue, StringValue)
Decl cast_bool_to_string(bool_val: bool, str_val: String).

// Parse string to integer
// parse_string_to_int(StringValue, IntValue)
Decl parse_string_to_int(str_val: String, int_val: i64).

// Parse string to float
// parse_string_to_float(StringValue, FloatValue)
Decl parse_string_to_float(str_val: String, float_val: f64).

// ============================================================================
// Null Handling Functions
// ============================================================================

// Coalesce - return first non-null
// coalesce_int(Value1, Value2, Result)
Decl coalesce_int(v1: i64, v2: i64, result: i64).

coalesce_int(V1, _, V1) :- V1 != 0.  // simplified - actual null handling needed
coalesce_int(_, V2, V2).

// IFNULL - same as coalesce for two args
Decl ifnull_int(value: i64, default_val: i64, result: i64).

// NULLIF - return null if equal
// nullif_int(Value1, Value2, Result)
Decl nullif_int(v1: i64, v2: i64, result: i64).

nullif_int(V, V, 0).  // returns "null" represented as 0
nullif_int(V1, V2, V1) :- V1 != V2.

// ============================================================================
// ID Functions
// ============================================================================

// Get node ID
// id(NodeID, Result)
Decl fn_id(node_id: i64, result: i64).

fn_id(N, N).

// Get label of node
// label(NodeID, LabelName)
Decl fn_label(node_id: i64, label_name: String).

fn_label(N, L) :- node_label(N, L).

// Get type of edge
// type(EdgeID, TypeName)
Decl fn_type(edge_id: i64, type_name: String).

fn_type(E, T) :- edge_type(E, T).

// ============================================================================
// List Functions
// ============================================================================

// List size
// list_size(ListID, Size)
Decl list_size(list_id: i64, size: i64).

// List element access
// list_element(ListID, Index, Value)
Decl list_element_int(list_id: i64, index: i64, value: i64).
Decl list_element_string(list_id: i64, index: i64, value: String).

// List contains
// list_contains_int(ListID, Value, Result)
Decl list_contains_int(list_id: i64, value: i64, result: bool).
Decl list_contains_string(list_id: i64, value: String, result: bool).