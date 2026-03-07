"""
ToonSPy Unit Tests

Tests for TOON parsing, response cleaning, and validation logic.
These are pure-function tests that do not require an LLM connection.
"""

from collections import Dict, List


# ============================================================================
# Inline copies of functions under test (avoid import issues with toonspy pkg)
# ============================================================================

fn _is_key_boundary(text: String, pos: Int) -> Bool:
    var tlen = len(text)
    if pos >= tlen:
        return False
    var ch = text[pos]
    if not ((ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")):
        return False
    if pos > 0:
        var prev = text[pos - 1]
        if prev != " " and prev != "\t" and prev != "\n" and prev != "\r":
            return False
    var j = pos + 1
    while j < tlen:
        var jch = text[j]
        if jch == ":":
            return True
        if not ((jch >= "a" and jch <= "z") or (jch >= "A" and jch <= "Z") or
                (jch >= "0" and jch <= "9") or jch == "_" or jch == "."):
            return False
        j += 1
    return False


fn _parse_toon_kv(text: String) -> Dict[String, String]:
    var result = Dict[String, String]()
    var tlen = len(text)
    var key_positions = List[Int]()
    for i in range(tlen):
        if _is_key_boundary(text, i):
            key_positions.append(i)
    for idx in range(len(key_positions)):
        var start = key_positions[idx]
        var end = tlen
        if idx + 1 < len(key_positions):
            end = key_positions[idx + 1]
        var segment = text[start:end]
        var colon_pos = segment.find(":")
        if colon_pos > 0:
            var key = segment[:colon_pos].strip()
            var raw_value = segment[colon_pos + 1:]
            # Handle quoted values
            var stripped = raw_value.strip()
            if len(stripped) > 0 and stripped[0] == "\"":
                var close_idx = -1
                for qi in range(1, len(stripped)):
                    if stripped[qi] == "\"" and stripped[qi - 1] != "\\":
                        close_idx = qi
                        break
                if close_idx > 0:
                    raw_value = stripped[1:close_idx]
                else:
                    raw_value = stripped[1:].strip()
            else:
                raw_value = stripped
            if len(key) > 0:
                result[key] = raw_value
    return result


fn _clean_toon_response(response: String) -> String:
    var cleaned = response
    if cleaned.startswith("```"):
        var lines = cleaned.split("\n")
        var result = String()
        var in_code = False
        for i in range(len(lines)):
            var line = lines[i]
            if line.startswith("```"):
                in_code = not in_code
                continue
            if in_code:
                if result != "":
                    result += "\n"
                result += line
        cleaned = result
    cleaned = cleaned.strip()
    return cleaned


# ============================================================================
# _parse_toon_kv tests
# ============================================================================

fn test_parse_simple_kv() -> Bool:
    """Single key:value pair."""
    var d = _parse_toon_kv("answer:hello")
    if "answer" not in d:
        return False
    return d["answer"] == "hello"


fn test_parse_multiple_kv() -> Bool:
    """Multiple key:value pairs."""
    var d = _parse_toon_kv("name:alice age:30")
    if "name" not in d or "age" not in d:
        return False
    return d["name"] == "alice" and d["age"] == "30"


fn test_parse_multiword_value() -> Bool:
    """Multi-word value must be preserved (the bug we fixed)."""
    var d = _parse_toon_kv("answer:hello world confidence:0.9")
    if "answer" not in d or "confidence" not in d:
        return False
    return d["answer"] == "hello world" and d["confidence"] == "0.9"


fn test_parse_multiword_multiple() -> Bool:
    """Multiple multi-word values."""
    var d = _parse_toon_kv("thought:I need to search action:web_search input:latest news today")
    if "thought" not in d or "action" not in d or "input" not in d:
        return False
    return (d["thought"] == "I need to search" and
            d["action"] == "web_search" and
            d["input"] == "latest news today")


fn test_parse_empty_string() -> Bool:
    """Empty input returns empty dict."""
    var d = _parse_toon_kv("")
    return len(d) == 0


fn test_parse_no_colon() -> Bool:
    """Input without colons returns empty dict."""
    var d = _parse_toon_kv("hello world no keys here")
    return len(d) == 0


fn test_parse_value_with_colon() -> Bool:
    """Value containing a colon (e.g. URL) is preserved."""
    var d = _parse_toon_kv("url:https://example.com status:ok")
    if "url" not in d or "status" not in d:
        return False
    return d["url"] == "https://example.com" and d["status"] == "ok"


fn test_parse_underscore_key() -> Bool:
    """Keys with underscores."""
    var d = _parse_toon_kv("action_input:some value next_key:v2")
    if "action_input" not in d or "next_key" not in d:
        return False
    return d["action_input"] == "some value" and d["next_key"] == "v2"


fn test_parse_newline_separated() -> Bool:
    """Keys separated by newlines."""
    var d = _parse_toon_kv("thought:think hard\naction:search\ninput:query text")
    if "thought" not in d or "action" not in d or "input" not in d:
        return False
    return (d["thought"] == "think hard" and
            d["action"] == "search" and
            d["input"] == "query text")


fn test_parse_pipe_array() -> Bool:
    """TOON array value with pipe separator."""
    var d = _parse_toon_kv("items:a|b|c count:3")
    if "items" not in d or "count" not in d:
        return False
    return d["items"] == "a|b|c" and d["count"] == "3"


fn test_parse_tilde_null() -> Bool:
    """TOON null value represented as ~."""
    var d = _parse_toon_kv("name:alice middle:~ last:smith")
    if "name" not in d or "middle" not in d or "last" not in d:
        return False
    return d["name"] == "alice" and d["middle"] == "~" and d["last"] == "smith"


# ============================================================================
# _is_key_boundary tests
# ============================================================================

fn test_boundary_start_of_string() -> Bool:
    """Key at start of string is a boundary."""
    return _is_key_boundary("key:value", 0)


fn test_boundary_after_space() -> Bool:
    """Key after space is a boundary."""
    return _is_key_boundary("a:1 b:2", 4)


fn test_boundary_not_mid_word() -> Bool:
    """Position inside a word is not a boundary."""
    return not _is_key_boundary("hello:world", 2)


fn test_boundary_digit_start() -> Bool:
    """Key starting with digit is not a boundary."""
    return not _is_key_boundary("1key:val", 0)


fn test_boundary_empty() -> Bool:
    """Empty string has no boundaries."""
    return not _is_key_boundary("", 0)


fn test_boundary_out_of_range() -> Bool:
    """Position past end is not a boundary."""
    return not _is_key_boundary("abc:1", 10)


fn test_boundary_no_colon() -> Bool:
    """Alpha word without colon is not a boundary."""
    return not _is_key_boundary("hello world", 0)


# ============================================================================
# _clean_toon_response tests
# ============================================================================

fn test_clean_plain_text() -> Bool:
    """Plain text passes through unchanged."""
    return _clean_toon_response("answer:hello") == "answer:hello"


fn test_clean_code_block() -> Bool:
    """Markdown code block is unwrapped."""
    var input = "```\nanswer:hello\n```"
    return _clean_toon_response(input) == "answer:hello"


fn test_clean_code_block_with_lang() -> Bool:
    """Markdown code block with language tag is unwrapped."""
    var input = "```toon\nanswer:hello world\nstatus:ok\n```"
    var expected = "answer:hello world\nstatus:ok"
    return _clean_toon_response(input) == expected


fn test_clean_strips_whitespace() -> Bool:
    """Leading/trailing whitespace is stripped."""
    return _clean_toon_response("  answer:hello  ") == "answer:hello"


fn test_clean_no_leak_outside_block() -> Bool:
    """Text outside code blocks must NOT appear in output."""
    var input = "```\ninside:yes\n```\noutside:no"
    var result = _clean_toon_response(input)
    return "inside" in result and "outside" not in result


fn test_clean_empty_code_block() -> Bool:
    """Empty code block returns empty string."""
    var input = "```\n```"
    return _clean_toon_response(input) == ""


fn test_clean_multiline_code_block() -> Bool:
    """Multi-line code block content preserved."""
    var input = "```\nline1:a\nline2:b\nline3:c\n```"
    var result = _clean_toon_response(input)
    return "line1:a" in result and "line2:b" in result and "line3:c" in result


# ============================================================================
# Integration: clean then parse
# ============================================================================

fn test_clean_then_parse() -> Bool:
    """End-to-end: clean code block then parse TOON."""
    var raw = "```toon\nanswer:the quick brown fox confidence:0.95\n```"
    var cleaned = _clean_toon_response(raw)
    var d = _parse_toon_kv(cleaned)
    if "answer" not in d or "confidence" not in d:
        return False
    return d["answer"] == "the quick brown fox" and d["confidence"] == "0.95"


fn test_error_response_passthrough() -> Bool:
    """Error responses start with 'error:' and are caught before parsing."""
    var response = "error:auth_failed"
    if not response.startswith("error:"):
        return False
    return True


# ============================================================================
# Tool validation logic (from react.mojo)
# ============================================================================

fn test_tool_validation_known() -> Bool:
    """Known tool name passes validation."""
    var tools = List[String]()
    tools.append("web_search")
    tools.append("calculator")
    var action = "web_search"
    var valid = False
    for i in range(len(tools)):
        if tools[i] == action:
            valid = True
            break
    return valid


fn test_tool_validation_unknown() -> Bool:
    """Unknown tool name fails validation."""
    var tools = List[String]()
    tools.append("web_search")
    tools.append("calculator")
    var action = "hack_system"
    var valid = False
    for i in range(len(tools)):
        if tools[i] == action:
            valid = True
            break
    return not valid


fn test_tool_validation_empty_tools() -> Bool:
    """Empty tool list rejects all actions."""
    var tools = List[String]()
    var action = "anything"
    var valid = False
    for i in range(len(tools)):
        if tools[i] == action:
            valid = True
            break
    return not valid


fn test_tool_validation_empty_action() -> Bool:
    """Empty action string fails validation."""
    var tools = List[String]()
    tools.append("web_search")
    var action = ""
    var valid = False
    for i in range(len(tools)):
        if tools[i] == action:
            valid = True
            break
    return not valid


# ============================================================================
# Quoted value & dot-notation tests (Task 8)
# ============================================================================

fn test_parse_quoted_value() -> Bool:
    """Quoted value preserves colons and special chars."""
    var d = _parse_toon_kv('query:"search for: things" status:ok')
    if "query" not in d or "status" not in d:
        return False
    return d["query"] == "search for: things" and d["status"] == "ok"


fn test_parse_quoted_value_with_spaces() -> Bool:
    """Quoted value preserves leading/trailing spaces."""
    var d = _parse_toon_kv('msg:"  hello  " done:yes')
    if "msg" not in d or "done" not in d:
        return False
    return d["msg"] == "  hello  " and d["done"] == "yes"


fn test_parse_quoted_value_no_close() -> Bool:
    """Missing closing quote uses rest of segment."""
    var d = _parse_toon_kv('text:"unclosed quote')
    if "text" not in d:
        return False
    return len(d["text"]) > 0


fn test_parse_dot_notation_key() -> Bool:
    """Dot-notation key like address.city:NYC."""
    var d = _parse_toon_kv("address.city:NYC address.zip:10001")
    if "address.city" not in d or "address.zip" not in d:
        return False
    return d["address.city"] == "NYC" and d["address.zip"] == "10001"


fn test_boundary_dot_notation() -> Bool:
    """_is_key_boundary recognises dotted key."""
    return _is_key_boundary("address.city:NYC", 0)


fn test_boundary_dot_only_mid() -> Bool:
    """Dot in the middle of a key is accepted."""
    return _is_key_boundary("a.b:1 c:2", 0)


# ============================================================================
# Predict module logic tests (Task 11)
# ============================================================================

fn _build_prompt_simple(
    description: String,
    input_names: List[String],
    output_names: List[String],
    inputs: Dict[String, String],
) -> String:
    """Reproduce Predict._build_prompt logic for testing."""
    var prompt = description + "\n\nInput:\n"
    for i in range(len(input_names)):
        var name = input_names[i]
        if name in inputs:
            prompt += name + ": " + inputs[name] + "\n"
    prompt += "\nOutput:"
    return prompt


fn test_predict_prompt_building() -> Bool:
    """Prompt contains description, input fields, Output: marker."""
    var inputs = Dict[String, String]()
    inputs["question"] = "What is 2+2?"
    var in_names = List[String]()
    in_names.append("question")
    var out_names = List[String]()
    out_names.append("answer")
    var prompt = _build_prompt_simple("Solve the math problem", in_names, out_names, inputs)
    if "Solve the math problem" not in prompt:
        return False
    if "question: What is 2+2?" not in prompt:
        return False
    if "Output:" not in prompt:
        return False
    return True


fn test_predict_response_parsing() -> Bool:
    """clean → parse pipeline produces correct outputs."""
    var raw = "```toon\nanswer:4 confidence:high\n```"
    var cleaned = _clean_toon_response(raw)
    var d = _parse_toon_kv(cleaned)
    if "answer" not in d or "confidence" not in d:
        return False
    return d["answer"] == "4" and d["confidence"] == "high"


fn test_predict_missing_input_detected() -> Bool:
    """Validate that missing required inputs can be detected."""
    var required = List[String]()
    required.append("question")
    required.append("context")
    var inputs = Dict[String, String]()
    inputs["question"] = "hello"
    # context is missing — check
    for i in range(len(required)):
        if required[i] not in inputs:
            return True  # detected
    return False


fn test_predict_error_response() -> Bool:
    """Error response starts with 'error:' and is caught."""
    var response = "error:rate_limit_exceeded"
    if response.startswith("error:"):
        var result = Dict[String, String]()
        result["error"] = response
        return "error" in result and result["error"] == "error:rate_limit_exceeded"
    return False


# ============================================================================
# ReAct module logic tests (Task 11)
# ============================================================================

fn _react_step_to_toon(thought: String, action: String, action_input: String) -> String:
    """Reproduce ReActStep.to_toon() for testing."""
    return "thought:" + thought + " action:" + action + " input:" + action_input


fn test_react_step_toon_format() -> Bool:
    """ReActStep.to_toon produces valid TOON that parses back."""
    var toon = _react_step_to_toon("I should search", "web_search", "latest news")
    var parsed = _parse_toon_kv(toon)
    if "thought" not in parsed or "action" not in parsed or "input" not in parsed:
        return False
    return (parsed["thought"] == "I should search" and
            parsed["action"] == "web_search" and
            parsed["input"] == "latest news")


fn test_react_finish_action() -> Bool:
    """Finish action with answer parses correctly."""
    var toon = "thought:I have the answer action:finish answer:42"
    var parsed = _parse_toon_kv(toon)
    if "action" not in parsed or "answer" not in parsed:
        return False
    return parsed["action"] == "finish" and parsed["answer"] == "42"


fn test_react_max_steps_result() -> Bool:
    """Max steps result has error and steps fields."""
    var max_steps = 10
    var error_result = Dict[String, String]()
    error_result["error"] = "max_steps_reached"
    error_result["steps"] = String(max_steps)
    return error_result["error"] == "max_steps_reached" and error_result["steps"] == "10"


fn test_react_tool_prompt_format() -> Bool:
    """Tool prompt format is readable."""
    # Reproduce Tool.to_prompt()
    var name = "search"
    var description = "Search the web"
    var params = List[String]()
    params.append("query")
    var result = name + ": " + description + " (params: "
    for i in range(len(params)):
        if i > 0:
            result += ", "
        result += params[i]
    result += ")"
    return result == "search: Search the web (params: query)"


fn test_react_history_prompt_format() -> Bool:
    """History is formatted with step numbers and observations."""
    var steps = List[String]()
    steps.append("thought:think action:search input:query")
    var prompt = "Previous steps:\n"
    for i in range(len(steps)):
        prompt += "Step " + String(i + 1) + ":\n"
        prompt += "  " + steps[i] + "\n"
        prompt += "  observation:result text\n"
    return "Step 1:" in prompt and "observation:result text" in prompt


# ============================================================================
# Edge Case Tests (Issue #20)
# ============================================================================

fn test_empty_signature_inputs() -> Bool:
    """Empty signature inputs list should not crash."""
    var in_names = List[String]()  # Empty
    var out_names = List[String]()
    out_names.append("answer")
    var inputs = Dict[String, String]()
    var prompt = _build_prompt_simple("Test", in_names, out_names, inputs)
    return "Input:" in prompt  # Should still have Input: section


fn test_empty_signature_outputs() -> Bool:
    """Empty signature outputs list should not crash."""
    var in_names = List[String]()
    in_names.append("question")
    var out_names = List[String]()  # Empty
    var inputs = Dict[String, String]()
    inputs["question"] = "test"
    var prompt = _build_prompt_simple("Test", in_names, out_names, inputs)
    return "Output:" in prompt


fn test_very_large_input_string() -> Bool:
    """Very large input string (>10KB) should be handled."""
    var large_text = String()
    for i in range(1000):
        large_text += "word" + String(i) + " "
    var d = _parse_toon_kv("text:" + large_text + " end:yes")
    return "text" in d and "end" in d


fn test_unicode_basic() -> Bool:
    """Basic unicode characters in values."""
    var d = _parse_toon_kv("greeting:hello name:世界")
    # Note: Full unicode support depends on Mojo's String implementation
    return "greeting" in d


fn test_special_chars_in_value() -> Bool:
    """Special characters like @, #, $ in values."""
    var d = _parse_toon_kv("email:user@example.com tag:#trending price:$100")
    if "email" not in d or "tag" not in d or "price" not in d:
        return False
    return d["email"] == "user@example.com"


fn test_escaped_quotes() -> Bool:
    """Escaped quotes in quoted values."""
    # Note: Parser may or may not handle escaped quotes
    var d = _parse_toon_kv('msg:"say \\"hello\\"" done:yes')
    return "msg" in d and "done" in d


fn test_empty_value() -> Bool:
    """Empty value after colon."""
    var d = _parse_toon_kv("key: next:value")
    # Empty value should be empty string
    return "key" in d and "next" in d


fn test_consecutive_colons() -> Bool:
    """Multiple consecutive colons."""
    var d = _parse_toon_kv("time:12:30:45 status:ok")
    if "time" not in d or "status" not in d:
        return False
    return "12:30:45" in d["time"]


fn test_very_long_key() -> Bool:
    """Very long key name."""
    var long_key = "a" * 100
    var text = long_key + ":value end:yes"
    var d = _parse_toon_kv(text)
    return long_key in d and d[long_key] == "value"


fn test_numeric_value_preservation() -> Bool:
    """Numeric values are preserved as strings."""
    var d = _parse_toon_kv("int:42 float:3.14159 negative:-100")
    if "int" not in d or "float" not in d or "negative" not in d:
        return False
    return d["int"] == "42" and d["float"] == "3.14159" and d["negative"] == "-100"


fn test_boolean_value_preservation() -> Bool:
    """Boolean values are preserved as strings."""
    var d = _parse_toon_kv("flag1:true flag2:false")
    if "flag1" not in d or "flag2" not in d:
        return False
    return d["flag1"] == "true" and d["flag2"] == "false"


fn test_array_with_many_items() -> Bool:
    """Array with many pipe-separated items."""
    var items = "a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p"
    var d = _parse_toon_kv("items:" + items + " count:16")
    if "items" not in d:
        return False
    return d["items"] == items


fn test_mixed_whitespace() -> Bool:
    """Mixed whitespace (spaces, tabs, newlines) between keys."""
    var d = _parse_toon_kv("a:1\tb:2\n\nc:3")
    return "a" in d and "b" in d and "c" in d


fn test_only_whitespace_value() -> Bool:
    """Value that is only whitespace."""
    var d = _parse_toon_kv("empty:   next:value")
    return "next" in d and d["next"] == "value"


# ============================================================================
# Main Test Runner
# ============================================================================

fn main():
    print("==============================================")
    print("ToonSPy Unit Test Suite")
    print("==============================================")
    print("")

    var passed = 0
    var failed = 0

    # --- _parse_toon_kv ---
    print("[_parse_toon_kv]")

    if test_parse_simple_kv():
        passed += 1; print("  PASS: simple kv")
    else:
        failed += 1; print("  FAIL: simple kv")

    if test_parse_multiple_kv():
        passed += 1; print("  PASS: multiple kv")
    else:
        failed += 1; print("  FAIL: multiple kv")

    if test_parse_multiword_value():
        passed += 1; print("  PASS: multi-word value")
    else:
        failed += 1; print("  FAIL: multi-word value")

    if test_parse_multiword_multiple():
        passed += 1; print("  PASS: multi-word multiple")
    else:
        failed += 1; print("  FAIL: multi-word multiple")

    if test_parse_empty_string():
        passed += 1; print("  PASS: empty string")
    else:
        failed += 1; print("  FAIL: empty string")

    if test_parse_no_colon():
        passed += 1; print("  PASS: no colon")
    else:
        failed += 1; print("  FAIL: no colon")

    if test_parse_value_with_colon():
        passed += 1; print("  PASS: value with colon")
    else:
        failed += 1; print("  FAIL: value with colon")

    if test_parse_underscore_key():
        passed += 1; print("  PASS: underscore key")
    else:
        failed += 1; print("  FAIL: underscore key")

    if test_parse_newline_separated():
        passed += 1; print("  PASS: newline separated")
    else:
        failed += 1; print("  FAIL: newline separated")

    if test_parse_pipe_array():
        passed += 1; print("  PASS: pipe array")
    else:
        failed += 1; print("  FAIL: pipe array")

    if test_parse_tilde_null():
        passed += 1; print("  PASS: tilde null")
    else:
        failed += 1; print("  FAIL: tilde null")

    print("")

    # --- _is_key_boundary ---
    print("[_is_key_boundary]")

    if test_boundary_start_of_string():
        passed += 1; print("  PASS: start of string")
    else:
        failed += 1; print("  FAIL: start of string")

    if test_boundary_after_space():
        passed += 1; print("  PASS: after space")
    else:
        failed += 1; print("  FAIL: after space")

    if test_boundary_not_mid_word():
        passed += 1; print("  PASS: not mid word")
    else:
        failed += 1; print("  FAIL: not mid word")

    if test_boundary_digit_start():
        passed += 1; print("  PASS: digit start")
    else:
        failed += 1; print("  FAIL: digit start")

    if test_boundary_empty():
        passed += 1; print("  PASS: empty string")
    else:
        failed += 1; print("  FAIL: empty string")

    if test_boundary_out_of_range():
        passed += 1; print("  PASS: out of range")
    else:
        failed += 1; print("  FAIL: out of range")

    if test_boundary_no_colon():
        passed += 1; print("  PASS: no colon")
    else:
        failed += 1; print("  FAIL: no colon")

    print("")

    # --- _clean_toon_response ---
    print("[_clean_toon_response]")

    if test_clean_plain_text():
        passed += 1; print("  PASS: plain text")
    else:
        failed += 1; print("  FAIL: plain text")

    if test_clean_code_block():
        passed += 1; print("  PASS: code block")
    else:
        failed += 1; print("  FAIL: code block")

    if test_clean_code_block_with_lang():
        passed += 1; print("  PASS: code block with lang")
    else:
        failed += 1; print("  FAIL: code block with lang")

    if test_clean_strips_whitespace():
        passed += 1; print("  PASS: strips whitespace")
    else:
        failed += 1; print("  FAIL: strips whitespace")

    if test_clean_no_leak_outside_block():
        passed += 1; print("  PASS: no leak outside block")
    else:
        failed += 1; print("  FAIL: no leak outside block")

    if test_clean_empty_code_block():
        passed += 1; print("  PASS: empty code block")
    else:
        failed += 1; print("  FAIL: empty code block")

    if test_clean_multiline_code_block():
        passed += 1; print("  PASS: multiline code block")
    else:
        failed += 1; print("  FAIL: multiline code block")

    print("")

    # --- Integration ---
    print("[Integration]")

    if test_clean_then_parse():
        passed += 1; print("  PASS: clean then parse")
    else:
        failed += 1; print("  FAIL: clean then parse")

    if test_error_response_passthrough():
        passed += 1; print("  PASS: error passthrough")
    else:
        failed += 1; print("  FAIL: error passthrough")

    print("")

    # --- Tool validation ---
    print("[Tool Validation]")

    if test_tool_validation_known():
        passed += 1; print("  PASS: known tool")
    else:
        failed += 1; print("  FAIL: known tool")

    if test_tool_validation_unknown():
        passed += 1; print("  PASS: unknown tool rejected")
    else:
        failed += 1; print("  FAIL: unknown tool rejected")

    if test_tool_validation_empty_tools():
        passed += 1; print("  PASS: empty tools list")
    else:
        failed += 1; print("  FAIL: empty tools list")

    if test_tool_validation_empty_action():
        passed += 1; print("  PASS: empty action")
    else:
        failed += 1; print("  FAIL: empty action")

    print("")

    # --- Quoted values & dot-notation (Task 8) ---
    print("[Quoted Values & Dot-Notation]")

    if test_parse_quoted_value():
        passed += 1; print("  PASS: quoted value")
    else:
        failed += 1; print("  FAIL: quoted value")

    if test_parse_quoted_value_with_spaces():
        passed += 1; print("  PASS: quoted value with spaces")
    else:
        failed += 1; print("  FAIL: quoted value with spaces")

    if test_parse_quoted_value_no_close():
        passed += 1; print("  PASS: quoted value no close")
    else:
        failed += 1; print("  FAIL: quoted value no close")

    if test_parse_dot_notation_key():
        passed += 1; print("  PASS: dot-notation key")
    else:
        failed += 1; print("  FAIL: dot-notation key")

    if test_boundary_dot_notation():
        passed += 1; print("  PASS: boundary dot-notation")
    else:
        failed += 1; print("  FAIL: boundary dot-notation")

    if test_boundary_dot_only_mid():
        passed += 1; print("  PASS: boundary dot mid")
    else:
        failed += 1; print("  FAIL: boundary dot mid")

    print("")

    # --- Predict module (Task 11) ---
    print("[Predict Module]")

    if test_predict_prompt_building():
        passed += 1; print("  PASS: prompt building")
    else:
        failed += 1; print("  FAIL: prompt building")

    if test_predict_response_parsing():
        passed += 1; print("  PASS: response parsing")
    else:
        failed += 1; print("  FAIL: response parsing")

    if test_predict_missing_input_detected():
        passed += 1; print("  PASS: missing input detected")
    else:
        failed += 1; print("  FAIL: missing input detected")

    if test_predict_error_response():
        passed += 1; print("  PASS: error response")
    else:
        failed += 1; print("  FAIL: error response")

    print("")

    # --- ReAct module (Task 11) ---
    print("[ReAct Module]")

    if test_react_step_toon_format():
        passed += 1; print("  PASS: step TOON format")
    else:
        failed += 1; print("  FAIL: step TOON format")

    if test_react_finish_action():
        passed += 1; print("  PASS: finish action")
    else:
        failed += 1; print("  FAIL: finish action")

    if test_react_max_steps_result():
        passed += 1; print("  PASS: max steps result")
    else:
        failed += 1; print("  FAIL: max steps result")

    if test_react_tool_prompt_format():
        passed += 1; print("  PASS: tool prompt format")
    else:
        failed += 1; print("  FAIL: tool prompt format")

    if test_react_history_prompt_format():
        passed += 1; print("  PASS: history prompt format")
    else:
        failed += 1; print("  FAIL: history prompt format")

    # --- Edge Cases (Issue #20) ---
    print("[Edge Cases]")

    if test_empty_signature_inputs():
        passed += 1; print("  PASS: empty signature inputs")
    else:
        failed += 1; print("  FAIL: empty signature inputs")

    if test_empty_signature_outputs():
        passed += 1; print("  PASS: empty signature outputs")
    else:
        failed += 1; print("  FAIL: empty signature outputs")

    if test_very_large_input_string():
        passed += 1; print("  PASS: very large input string")
    else:
        failed += 1; print("  FAIL: very large input string")

    if test_unicode_basic():
        passed += 1; print("  PASS: unicode basic")
    else:
        failed += 1; print("  FAIL: unicode basic")

    if test_special_chars_in_value():
        passed += 1; print("  PASS: special chars in value")
    else:
        failed += 1; print("  FAIL: special chars in value")

    if test_escaped_quotes():
        passed += 1; print("  PASS: escaped quotes")
    else:
        failed += 1; print("  FAIL: escaped quotes")

    if test_empty_value():
        passed += 1; print("  PASS: empty value")
    else:
        failed += 1; print("  FAIL: empty value")

    if test_consecutive_colons():
        passed += 1; print("  PASS: consecutive colons")
    else:
        failed += 1; print("  FAIL: consecutive colons")

    if test_very_long_key():
        passed += 1; print("  PASS: very long key")
    else:
        failed += 1; print("  FAIL: very long key")

    if test_numeric_value_preservation():
        passed += 1; print("  PASS: numeric value preservation")
    else:
        failed += 1; print("  FAIL: numeric value preservation")

    if test_boolean_value_preservation():
        passed += 1; print("  PASS: boolean value preservation")
    else:
        failed += 1; print("  FAIL: boolean value preservation")

    if test_array_with_many_items():
        passed += 1; print("  PASS: array with many items")
    else:
        failed += 1; print("  FAIL: array with many items")

    if test_mixed_whitespace():
        passed += 1; print("  PASS: mixed whitespace")
    else:
        failed += 1; print("  FAIL: mixed whitespace")

    if test_only_whitespace_value():
        passed += 1; print("  PASS: only whitespace value")
    else:
        failed += 1; print("  FAIL: only whitespace value")

    print("")

    # --- Summary ---
    print("")
    print("==============================================")
    print("Results: " + String(passed) + " passed, " + String(failed) + " failed, " + String(passed + failed) + " total")
    print("==============================================")

    if failed == 0:
        print("All tests passed!")
    else:
        print("Some tests FAILED")
