# TOON (Token Oriented Object Notation) - Rules
# Pure rules for TOON serialization/deserialization
# No hardcoded facts - all rules are generic

# =============================================================================
# TOKEN TYPES
# =============================================================================

Decl toon_token_type(type_name: string).

# Rule to define valid token types
toon_token_type("key").          # Identifier before : or =
toon_token_type("value").        # Value after : or =
toon_token_type("separator").    # : or =
toon_token_type("pipe").         # | for arrays
toon_token_type("tilde").        # ~ for null
toon_token_type("lbrace").       # {
toon_token_type("rbrace").       # }
toon_token_type("lbracket").     # [
toon_token_type("rbracket").     # ]
toon_token_type("quote").        # " or '
toon_token_type("whitespace").   # space, tab, newline

# =============================================================================
# CHARACTER CLASSIFICATION
# =============================================================================

Decl is_separator(char: string) :-
  char = ":"; char = "=".

Decl is_whitespace(char: string) :-
  char = " "; char = "\t"; char = "\n"; char = "\r".

Decl is_special_char(char: string) :-
  is_separator(char);
  char = "|"; char = ","; char = ";";
  char = "{"; char = "}"; char = "["; char = "]";
  char = "\""; char = "'".

# =============================================================================
# VALUE TYPE DETECTION
# =============================================================================

Decl value_type(value: string, type_name: string) :-
  value = "~"; value = "null"; value = "nil",
  type_name = "null".

Decl value_type(value: string, type_name: string) :-
  value = "true"; value = "yes"; value = "Y"; value = "1",
  type_name = "bool_true".

Decl value_type(value: string, type_name: string) :-
  value = "false"; value = "no"; value = "N"; value = "0",
  type_name = "bool_false".

Decl value_type(value: string, type_name: string) :-
  fn:is_integer(value),
  type_name = "integer".

Decl value_type(value: string, type_name: string) :-
  fn:is_float(value),
  type_name = "float".

Decl value_type(value: string, type_name: string) :-
  fn:contains(value, "|"),
  type_name = "array".

# =============================================================================
# TOON SERIALIZATION
# =============================================================================

# Serialize null
Decl toon_value(input: any, output: string) :-
  input = null,
  output = "~".

# Serialize boolean
Decl toon_value(input: any, output: string) :-
  input = true,
  output = "true".

Decl toon_value(input: any, output: string) :-
  input = false,
  output = "false".

# Serialize number (pass through)
Decl toon_value(input: any, output: string) :-
  fn:is_number(input),
  output = fn:to_string(input).

# Check if string needs quoting
Decl needs_quoting(str: string) :-
  fn:contains(str, " ");
  fn:contains(str, ":");
  fn:contains(str, "=");
  fn:contains(str, "|");
  fn:contains(str, ",");
  fn:contains(str, "\n");
  fn:contains(str, "{");
  fn:contains(str, "}");
  fn:contains(str, "[");
  fn:contains(str, "]").

# Serialize string (quote if needed)
Decl toon_value(input: any, output: string) :-
  fn:is_string(input),
  needs_quoting(input),
  output = fn:concat("\"", input, "\"").

Decl toon_value(input: any, output: string) :-
  fn:is_string(input),
  !needs_quoting(input),
  output = input.

# =============================================================================
# TOON KEY-VALUE PAIRS
# =============================================================================

Decl toon_pair(key: string, value: any, output: string) :-
  toon_value(value, toon_val),
  output = fn:concat(key, ":", toon_val).

# =============================================================================
# TOON ARRAY SERIALIZATION
# =============================================================================

# Simple arrays use pipe notation
Decl is_simple_array(items: list) :-
  fn:all(items, fn:is_primitive).

Decl toon_array(items: list, output: string) :-
  is_simple_array(items),
  output = fn:join(items, "|").

# Complex arrays use bracket notation
Decl toon_array(items: list, output: string) :-
  !is_simple_array(items),
  inner = fn:map(items, toon_value),
  joined = fn:join(inner, ","),
  output = fn:concat("[", joined, "]").

# =============================================================================
# TOON PARSING
# =============================================================================

# Parse null values
Decl parse_toon_value(input: string, output: any) :-
  input = "~"; input = "null"; input = "nil",
  output = null.

# Parse boolean true
Decl parse_toon_value(input: string, output: any) :-
  input = "true"; input = "yes"; input = "Y",
  output = true.

# Parse boolean false
Decl parse_toon_value(input: string, output: any) :-
  input = "false"; input = "no"; input = "N",
  output = false.

# Parse integer
Decl parse_toon_value(input: string, output: any) :-
  fn:is_integer(input),
  output = fn:to_integer(input).

# Parse float
Decl parse_toon_value(input: string, output: any) :-
  fn:is_float(input),
  output = fn:to_float(input).

# Parse pipe-separated array
Decl parse_toon_value(input: string, output: any) :-
  fn:contains(input, "|"),
  parts = fn:split(input, "|"),
  output = fn:map(parts, parse_toon_value).

# =============================================================================
# TOKEN ESTIMATION
# =============================================================================

# Estimate token count (GPT-style approximation)
Decl estimate_tokens(text: string, count: integer) :-
  word_count = fn:length(fn:split(text, " \t\n")),
  punct_count = fn:count_chars(text, "{}[]\":,|~=#"),
  count = word_count + punct_count.

# Calculate token savings
Decl token_savings(json_text: string, toon_text: string, savings_percent: float) :-
  estimate_tokens(json_text, json_tokens),
  estimate_tokens(toon_text, toon_tokens),
  diff = json_tokens - toon_tokens,
  savings_percent = (diff * 100.0) / json_tokens.

# =============================================================================
# LLM PROMPT TEMPLATES
# =============================================================================

Decl toon_prompt(task: string, schema: string, prompt: string) :-
  task = "extraction",
  prompt = fn:concat(
    "Extract fields and respond ONLY in TOON format:\n",
    "Required: ", schema, "\n",
    "Example: field1:value1 field2:value2 array:item1|item2\n",
    "Use ~ for null/unknown.\n"
  ).

Decl toon_prompt(task: string, categories: string, prompt: string) :-
  task = "classification",
  prompt = fn:concat(
    "Classify and respond in TOON format:\n",
    "category:<", categories, "> confidence:<0.0-1.0> reason:<brief>\n"
  ).

Decl toon_prompt(task: string, schema: string, prompt: string) :-
  task = "sentiment",
  prompt = "Analyze sentiment. Respond: sentiment:positive|negative|neutral confidence:0.0-1.0".

Decl toon_prompt(task: string, schema: string, prompt: string) :-
  task = "summarization",
  prompt = "Summarize. Respond: summary:<text> key_points:point1|point2|point3 word_count:<n>".

# =============================================================================
# FORMAT OPTIONS
# =============================================================================

Decl format_option(name: string).
format_option("compact").       # Single line
format_option("readable").      # Multiple lines
format_option("indented").      # YAML-like

# Format TOON output
Decl format_toon(pairs: list, format_name: string, output: string) :-
  format_name = "compact",
  output = fn:join(pairs, " ").

Decl format_toon(pairs: list, format_name: string, output: string) :-
  format_name = "readable",
  output = fn:join(pairs, "\n").

# =============================================================================
# STREAMING PARSER STATES
# =============================================================================

Decl parser_state(state_name: string).
parser_state("init").
parser_state("key").
parser_state("separator").
parser_state("value").
parser_state("array_item").
parser_state("quoted_string").
parser_state("object").
parser_state("bracket_array").
parser_state("comment").

# State transitions
Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "init", fn:is_alpha(char), to_state = "key".

Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "init", char = "#", to_state = "comment".

Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "init", is_whitespace(char), to_state = "init".

Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "key", is_separator(char), to_state = "separator".

Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "value", char = "|", to_state = "array_item".

Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "value", char = "{", to_state = "object".

Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "value", char = "[", to_state = "bracket_array".

Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "object", char = "}", to_state = "value".

Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "bracket_array", char = "]", to_state = "value".

Decl transition(from_state: string, char: string, to_state: string) :-
  from_state = "comment", char = "\n", to_state = "init".