# ===----------------------------------------------------------------------=== #
# TOON (Token Oriented Object Notation) - Mangle Rules
#
# Comprehensive rules for:
#   1. TOON serialization/deserialization
#   2. JSON ↔ TOON conversion
#   3. Token counting and optimization
#   4. LLM prompt generation in TOON format
#   5. Streaming parser state machine
#
# Usage:
#   Query `to_toon(JsonValue, ToonString)` for conversion
#   Query `toon_prompt(Task, Prompt)` for LLM prompts
#   Query `token_savings(Json, Toon, Savings)` for optimization
# ===----------------------------------------------------------------------=== #

# =============================================================================
# TOON Grammar Definition
# =============================================================================

# TOON token types
toon_token_type("key").          # Identifier before : or =
toon_token_type("value").        # Value after : or =
toon_token_type("separator").    # : or =
toon_token_type("pipe").         # | for arrays
toon_token_type("tilde").        # ~ for null
toon_token_type("lbrace").       # { for objects
toon_token_type("rbrace").       # } for objects
toon_token_type("lbracket").     # [ for arrays
toon_token_type("rbracket").     # ] for arrays
toon_token_type("quote").        # " or ' for strings
toon_token_type("comment").      # # comment
toon_token_type("whitespace").   # space, tab, newline

# Character classification
is_separator(':').
is_separator('=').

is_whitespace(' ').
is_whitespace('\t').
is_whitespace('\n').
is_whitespace('\r').

is_special_char(':').
is_special_char('=').
is_special_char('|').
is_special_char(',').
is_special_char(';').
is_special_char('{').
is_special_char('}').
is_special_char('[').
is_special_char(']').
is_special_char('"').
is_special_char('\'').
is_special_char(' ').
is_special_char('\t').
is_special_char('\n').

# Value type detection
value_type(V, "null") :- V == "~" ; V == "null" ; V == "nil".
value_type(V, "bool_true") :- V == "true" ; V == "yes" ; V == "Y" ; V == "1".
value_type(V, "bool_false") :- V == "false" ; V == "no" ; V == "N" ; V == "0".
value_type(V, "integer") :- fn:is_integer(V).
value_type(V, "float") :- fn:is_float(V).
value_type(V, "array") :- fn:contains(V, "|").
value_type(V, "string") :- \+ value_type(V, "null"), 
                          \+ value_type(V, "bool_true"),
                          \+ value_type(V, "bool_false"),
                          \+ value_type(V, "integer"),
                          \+ value_type(V, "float"),
                          \+ value_type(V, "array").

# =============================================================================
# TOON Serialization (Value → TOON String)
# =============================================================================

# Serialize key-value pair
toon_pair(Key, Value, Output) :-
    toon_value(Value, ToonValue),
    Output = fn:concat(Key, ":", ToonValue).

# Serialize values to TOON format
toon_value(null, "~").
toon_value(true, "true").
toon_value(false, "false").
toon_value(V, V) :- fn:is_number(V).

# Serialize string (quote if needed)
toon_value(V, Quoted) :-
    fn:is_string(V),
    needs_quoting(V),
    Quoted = fn:concat("\"", V, "\"").

toon_value(V, V) :-
    fn:is_string(V),
    \+ needs_quoting(V).

# Check if string needs quoting
needs_quoting(S) :- fn:contains(S, " ").
needs_quoting(S) :- fn:contains(S, ":").
needs_quoting(S) :- fn:contains(S, "=").
needs_quoting(S) :- fn:contains(S, "|").
needs_quoting(S) :- fn:contains(S, ",").
needs_quoting(S) :- fn:contains(S, "\n").
needs_quoting(S) :- fn:contains(S, "{").
needs_quoting(S) :- fn:contains(S, "}").
needs_quoting(S) :- fn:contains(S, "[").
needs_quoting(S) :- fn:contains(S, "]").

# Serialize array (simple → pipe notation)
toon_array(Items, Output) :-
    is_simple_array(Items),
    Output = fn:join(Items, "|").

toon_array(Items, Output) :-
    \+ is_simple_array(Items),
    serialize_complex_array(Items, Inner),
    Output = fn:concat("[", Inner, "]").

is_simple_array([]).
is_simple_array([H|T]) :-
    (fn:is_string(H) ; fn:is_number(H) ; fn:is_boolean(H)),
    is_simple_array(T).

# Serialize object
toon_object(Pairs, Output) :-
    serialize_pairs(Pairs, PairStrs),
    Output = fn:join(PairStrs, " ").

serialize_pairs([], []).
serialize_pairs([[K,V]|Rest], [PairStr|RestStrs]) :-
    toon_pair(K, V, PairStr),
    serialize_pairs(Rest, RestStrs).

# =============================================================================
# JSON to TOON Conversion
# =============================================================================

# Convert JSON object to TOON
json_to_toon(json_object(Pairs), Toon) :-
    convert_json_pairs(Pairs, ToonPairs),
    Toon = fn:join(ToonPairs, " ").

convert_json_pairs([], []).
convert_json_pairs([[Key, Value]|Rest], [ToonPair|RestToon]) :-
    json_value_to_toon(Value, ToonValue),
    ToonPair = fn:concat(Key, ":", ToonValue),
    convert_json_pairs(Rest, RestToon).

# Convert JSON values
json_value_to_toon(json_null, "~").
json_value_to_toon(json_true, "true").
json_value_to_toon(json_false, "false").
json_value_to_toon(json_number(N), N).
json_value_to_toon(json_string(S), Toon) :- toon_value(S, Toon).

# Convert JSON array (simple → pipe, complex → brackets)
json_value_to_toon(json_array(Items), Toon) :-
    is_simple_json_array(Items),
    convert_simple_array(Items, Values),
    Toon = fn:join(Values, "|").

json_value_to_toon(json_array(Items), Toon) :-
    \+ is_simple_json_array(Items),
    convert_complex_array(Items, Inner),
    Toon = fn:concat("[", Inner, "]").

# Convert nested JSON object
json_value_to_toon(json_object(Pairs), Toon) :-
    json_to_toon(json_object(Pairs), Inner),
    Toon = fn:concat("{", Inner, "}").

is_simple_json_array([]).
is_simple_json_array([H|T]) :-
    (H = json_string(_) ; H = json_number(_) ; H = json_true ; H = json_false),
    is_simple_json_array(T).

convert_simple_array([], []).
convert_simple_array([json_string(S)|Rest], [S|RestVals]) :- 
    convert_simple_array(Rest, RestVals).
convert_simple_array([json_number(N)|Rest], [N|RestVals]) :- 
    convert_simple_array(Rest, RestVals).
convert_simple_array([json_true|Rest], ["true"|RestVals]) :- 
    convert_simple_array(Rest, RestVals).
convert_simple_array([json_false|Rest], ["false"|RestVals]) :- 
    convert_simple_array(Rest, RestVals).

# =============================================================================
# TOON to JSON Conversion
# =============================================================================

# Parse TOON to JSON-like structure
toon_to_json(Toon, JsonObj) :-
    parse_toon_pairs(Toon, Pairs),
    JsonObj = json_object(Pairs).

# Parse value from TOON string
parse_toon_value("~", json_null).
parse_toon_value("null", json_null).
parse_toon_value("nil", json_null).
parse_toon_value("true", json_true).
parse_toon_value("yes", json_true).
parse_toon_value("Y", json_true).
parse_toon_value("false", json_false).
parse_toon_value("no", json_false).
parse_toon_value("N", json_false).

parse_toon_value(V, json_number(V)) :-
    fn:is_integer(V).

parse_toon_value(V, json_number(V)) :-
    fn:is_float(V).

parse_toon_value(V, json_array(Items)) :-
    fn:contains(V, "|"),
    Parts = fn:split(V, "|"),
    parse_array_items(Parts, Items).

parse_toon_value(V, json_string(V)) :-
    \+ fn:contains(V, "|"),
    \+ fn:is_number(V),
    \+ value_type(V, "null"),
    \+ value_type(V, "bool_true"),
    \+ value_type(V, "bool_false").

parse_array_items([], []).
parse_array_items([H|T], [JsonH|JsonT]) :-
    Trimmed = fn:trim(H),
    parse_toon_value(Trimmed, JsonH),
    parse_array_items(T, JsonT).

# =============================================================================
# Token Counting and Optimization
# =============================================================================

# Estimate token count (GPT-style tokenization approximation)
# Rule: ~4 chars = 1 token for English, punctuation = 1 token each
estimate_tokens(Text, Count) :-
    Len = fn:length(Text),
    PunctCount = count_punctuation(Text),
    WordCount = count_words(Text),
    Count = WordCount + PunctCount.

count_punctuation(Text, Count) :-
    Count = fn:count_chars(Text, "{}[]\":,|~=#").

count_words(Text, Count) :-
    Words = fn:split(Text, " \t\n"),
    Count = fn:length(Words).

# Calculate token savings
token_savings(Json, Savings) :-
    json_to_toon(Json, Toon),
    estimate_tokens(Json, JsonTokens),
    estimate_tokens(Toon, ToonTokens),
    Diff = JsonTokens - ToonTokens,
    Savings = (Diff * 100) / JsonTokens.

# =============================================================================
# LLM Prompt Generation with TOON
# =============================================================================

# Generate TOON-formatted prompt for various tasks
toon_prompt("extraction", Schema, Prompt) :-
    Prompt = fn:concat(
        "Extract the following fields and respond ONLY in TOON format:\n",
        "Required fields: ", Schema, "\n\n",
        "TOON format example: field1:value1 field2:value2 array_field:item1|item2\n",
        "Use ~ for null/unknown values.\n"
    ).

toon_prompt("classification", Categories, Prompt) :-
    CatList = fn:join(Categories, "|"),
    Prompt = fn:concat(
        "Classify the input and respond in TOON format:\n",
        "category:<one of ", CatList, "> confidence:<0.0-1.0> reason:<brief>\n"
    ).

toon_prompt("entity_extraction", EntityTypes, Prompt) :-
    TypeList = fn:join(EntityTypes, "|"),
    Prompt = fn:concat(
        "Extract entities and respond in TOON format:\n",
        "For each entity: type:<", TypeList, "> value:<text> start:<pos> end:<pos>\n",
        "Multiple entities: separate with newlines\n"
    ).

toon_prompt("sentiment", _, Prompt) :-
    Prompt = "Analyze sentiment. Respond: sentiment:positive|negative|neutral confidence:0.0-1.0 aspects:aspect1|aspect2".

toon_prompt("summarization", _, Prompt) :-
    Prompt = "Summarize and respond: summary:<text> key_points:point1|point2|point3 word_count:<n>".

# Chat completion in TOON format
toon_chat_prompt(SystemPrompt, UserMessage, FullPrompt) :-
    FullPrompt = fn:concat(
        "system:", SystemPrompt, "\n",
        "user:", UserMessage, "\n",
        "Respond in TOON format."
    ).

# =============================================================================
# Structured Output Templates
# =============================================================================

# API response template
toon_template("api_response", "status:success|error data:{...} message:<text> code:<int>").

# User profile template  
toon_template("user_profile", "id:<int> name:<text> email:<text> roles:role1|role2 active:Y|N").

# Model config template
toon_template("model_config", 
    "model:<name> quantization:Q4_K_M|Q5_K_M|Q8_0 context:<int> gpu_util:<0.0-1.0>").

# Chat message template
toon_template("chat_message", "role:system|user|assistant content:<text> model:<name>").

# Error response template
toon_template("error", "error:true code:<int> message:<text> details:{...}").

# Pagination template
toon_template("pagination", "page:<int> per_page:<int> total:<int> has_more:Y|N").

# =============================================================================
# TOON Schema Validation
# =============================================================================

# Schema definition format
# schema_field(FieldName, Type, Required, Default)
schema_field("id", "integer", true, _).
schema_field("name", "string", true, _).
schema_field("email", "string", false, "~").
schema_field("active", "boolean", false, "true").
schema_field("roles", "array", false, "user").

# Validate TOON against schema
validate_toon(Toon, SchemaName, Valid) :-
    schema_fields(SchemaName, Fields),
    check_required_fields(Toon, Fields, RequiredOk),
    check_field_types(Toon, Fields, TypesOk),
    Valid = RequiredOk and TypesOk.

check_required_fields(Toon, [], true).
check_required_fields(Toon, [field(Name, _, true, _)|Rest], Valid) :-
    has_field(Toon, Name),
    check_required_fields(Toon, Rest, Valid).
check_required_fields(Toon, [field(_, _, false, _)|Rest], Valid) :-
    check_required_fields(Toon, Rest, Valid).

# =============================================================================
# Streaming Parser State Machine
# =============================================================================

# Parser states
parser_state("init").           # Initial state
parser_state("key").            # Reading key
parser_state("separator").      # Expecting : or =
parser_state("value").          # Reading value
parser_state("array_item").     # In pipe-separated array
parser_state("quoted_string").  # Inside quotes
parser_state("object").         # Inside { }
parser_state("bracket_array").  # Inside [ ]
parser_state("comment").        # After #

# State transitions
transition("init", Char, "key") :- 
    fn:is_alpha(Char).

transition("init", Char, "comment") :- 
    Char == '#'.

transition("init", Char, "init") :- 
    is_whitespace(Char).

transition("key", Char, "key") :- 
    fn:is_alphanumeric(Char) ; Char == '_' ; Char == '-'.

transition("key", Char, "separator") :- 
    is_separator(Char).

transition("separator", Char, "value") :- 
    \+ is_whitespace(Char).

transition("separator", Char, "separator") :- 
    is_whitespace(Char).

transition("value", Char, "array_item") :- 
    Char == '|'.

transition("value", Char, "quoted_string") :- 
    Char == '"' ; Char == '\''.

transition("value", Char, "object") :- 
    Char == '{'.

transition("value", Char, "bracket_array") :- 
    Char == '['.

transition("value", Char, "init") :- 
    is_whitespace(Char) ; Char == ',' ; Char == ';'.

transition("quoted_string", Char, "value") :- 
    Char == '"' ; Char == '\''.

transition("object", Char, "value") :- 
    Char == '}'.

transition("bracket_array", Char, "value") :- 
    Char == ']'.

transition("comment", Char, "init") :- 
    Char == '\n'.

# =============================================================================
# TOON Formatting Options
# =============================================================================

# Format options
format_option("compact").       # Single line, minimal whitespace
format_option("readable").      # Multiple lines, aligned
format_option("indented").      # YAML-like indentation

# Format TOON output
format_toon(Pairs, "compact", Output) :-
    serialize_pairs(Pairs, PairStrs),
    Output = fn:join(PairStrs, " ").

format_toon(Pairs, "readable", Output) :-
    serialize_pairs(Pairs, PairStrs),
    Output = fn:join(PairStrs, "\n").

format_toon(Pairs, "indented", Output) :-
    serialize_pairs_indented(Pairs, 0, PairStrs),
    Output = fn:join(PairStrs, "\n").

# =============================================================================
# Common TOON Patterns for LLM Use Cases
# =============================================================================

# Intent recognition output
llm_output_pattern("intent", 
    "intent:<action> entities:entity1|entity2 confidence:<0-1> slots:{slot1:val1 slot2:val2}").

# Question answering output
llm_output_pattern("qa", 
    "answer:<text> confidence:<0-1> sources:source1|source2 followup:question1|question2").

# Code generation output
llm_output_pattern("code", 
    "language:<lang> code:<base64_or_escaped> explanation:<text> imports:pkg1|pkg2").

# Translation output
llm_output_pattern("translation", 
    "source_lang:<iso> target_lang:<iso> translation:<text> alternatives:alt1|alt2").

# =============================================================================
# Integration with Model Store Rules
# =============================================================================

# Convert model config to TOON for deployment
model_config_to_toon(ModelId, Hardware, Toon) :-
    model_def(ModelId, Format, SizeGB, Capabilities),
    hw_profile(Hardware, VRAM, _, MaxBatch),
    Toon = fn:concat(
        "model:", ModelId, " ",
        "format:", Format, " ",
        "size_gb:", SizeGB, " ",
        "vram:", VRAM, " ",
        "max_batch:", MaxBatch, " ",
        "capabilities:", fn:join(Capabilities, "|")
    ).

# Convert deployment config to TOON
deployment_config_to_toon(Config, Toon) :-
    Config = config{model: M, resourcePlan: R, minReplicas: Min, maxReplicas: Max, contextSize: Ctx},
    Toon = fn:concat(
        "model:", M, " ",
        "resource_plan:", R, " ",
        "replicas:", Min, "-", Max, " ",
        "context:", Ctx
    ).

# =============================================================================
# Tests
# =============================================================================

test_json_to_toon() :-
    Json = json_object([["name", json_string("John")], ["age", json_number(30)]]),
    json_to_toon(Json, Toon),
    Toon = "name:John age:30".

test_array_pipe() :-
    toon_array(["NYC", "LA", "Chicago"], Toon),
    Toon = "NYC|LA|Chicago".

test_token_savings() :-
    Json = "{\"name\": \"John\", \"age\": 30}",
    token_savings(Json, Savings),
    Savings > 30.  % At least 30% savings

test_prompt_generation() :-
    toon_prompt("classification", ["positive", "negative", "neutral"], Prompt),
    fn:contains(Prompt, "TOON format").

test_value_parsing() :-
    parse_toon_value("~", json_null),
    parse_toon_value("true", json_true),
    parse_toon_value("42", json_number(42)),
    parse_toon_value("a|b|c", json_array([json_string("a"), json_string("b"), json_string("c")])).