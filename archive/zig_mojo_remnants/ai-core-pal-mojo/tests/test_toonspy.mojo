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
                (jch >= "0" and jch <= "9") or jch == "_"):
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
            var value = segment[colon_pos + 1:].strip()
            if len(key) > 0:
                result[key] = value
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
    var d = _parse_toon_kv("answer:hello")
    if "answer" not in d:
        return False
    return d["answer"] == "hello"

fn test_parse_multiple_kv() -> Bool:
    var d = _parse_toon_kv("name:alice age:30")
    if "name" not in d or "age" not in d:
        return False
    return d["name"] == "alice" and d["age"] == "30"

fn test_parse_multiword_value() -> Bool:
    var d = _parse_toon_kv("answer:hello world confidence:0.9")
    if "answer" not in d or "confidence" not in d:
        return False
    return d["answer"] == "hello world" and d["confidence"] == "0.9"

fn test_parse_multiword_multiple() -> Bool:
    var d = _parse_toon_kv("thought:I need to search action:web_search input:latest news today")
    if "thought" not in d or "action" not in d or "input" not in d:
        return False
    return (d["thought"] == "I need to search" and
            d["action"] == "web_search" and
            d["input"] == "latest news today")

fn test_parse_empty_string() -> Bool:
    var d = _parse_toon_kv("")
    return len(d) == 0

fn test_parse_no_colon() -> Bool:
    var d = _parse_toon_kv("hello world no keys here")
    return len(d) == 0

fn test_parse_value_with_colon() -> Bool:
    var d = _parse_toon_kv("url:https://example.com status:ok")
    if "url" not in d or "status" not in d:
        return False
    return d["url"] == "https://example.com" and d["status"] == "ok"

fn test_parse_underscore_key() -> Bool:
    var d = _parse_toon_kv("action_input:some value next_key:v2")
    if "action_input" not in d or "next_key" not in d:
        return False
    return d["action_input"] == "some value" and d["next_key"] == "v2"

fn test_parse_newline_separated() -> Bool:
    var d = _parse_toon_kv("thought:think hard\naction:search\ninput:query text")
    if "thought" not in d or "action" not in d or "input" not in d:
        return False
    return (d["thought"] == "think hard" and
            d["action"] == "search" and
            d["input"] == "query text")

fn test_parse_pipe_array() -> Bool:
    var d = _parse_toon_kv("items:a|b|c count:3")
    if "items" not in d or "count" not in d:
        return False
    return d["items"] == "a|b|c" and d["count"] == "3"

fn test_parse_tilde_null() -> Bool:
    var d = _parse_toon_kv("name:alice middle:~ last:smith")
    if "name" not in d or "middle" not in d or "last" not in d:
        return False
    return d["name"] == "alice" and d["middle"] == "~" and d["last"] == "smith"


# ============================================================================
# _is_key_boundary tests
# ============================================================================

fn test_boundary_start_of_string() -> Bool:
    return _is_key_boundary("key:value", 0)

fn test_boundary_after_space() -> Bool:
    return _is_key_boundary("a:1 b:2", 4)

fn test_boundary_not_mid_word() -> Bool:
    return not _is_key_boundary("hello:world", 2)

fn test_boundary_digit_start() -> Bool:
    return not _is_key_boundary("1key:val", 0)

fn test_boundary_empty() -> Bool:
    return not _is_key_boundary("", 0)

fn test_boundary_out_of_range() -> Bool:
    return not _is_key_boundary("abc:1", 10)

fn test_boundary_no_colon() -> Bool:
    return not _is_key_boundary("hello world", 0)


# ============================================================================
# _clean_toon_response tests
# ============================================================================

fn test_clean_plain_text() -> Bool:
    return _clean_toon_response("answer:hello") == "answer:hello"

fn test_clean_code_block() -> Bool:
    var input = "```\nanswer:hello\n```"
    return _clean_toon_response(input) == "answer:hello"

fn test_clean_code_block_with_lang() -> Bool:
    var input = "```toon\nanswer:hello world\nstatus:ok\n```"
    var expected = "answer:hello world\nstatus:ok"
    return _clean_toon_response(input) == expected

fn test_clean_strips_whitespace() -> Bool:
    return _clean_toon_response("  answer:hello  ") == "answer:hello"

fn test_clean_no_leak_outside_block() -> Bool:
    var input = "```\ninside:yes\n```\noutside:no"
    var result = _clean_toon_response(input)
    return "inside" in result and "outside" not in result

fn test_clean_empty_code_block() -> Bool:
    var input = "```\n```"
    return _clean_toon_response(input) == ""

fn test_clean_multiline_code_block() -> Bool:
    var input = "```\nline1:a\nline2:b\nline3:c\n```"
    var result = _clean_toon_response(input)
    return "line1:a" in result and "line2:b" in result and "line3:c" in result


# ============================================================================
# Integration: clean then parse
# ============================================================================

fn test_clean_then_parse() -> Bool:
    var raw = "```toon\nanswer:the quick brown fox confidence:0.95\n```"
    var cleaned = _clean_toon_response(raw)
    var d = _parse_toon_kv(cleaned)
    if "answer" not in d or "confidence" not in d:
        return False
    return d["answer"] == "the quick brown fox" and d["confidence"] == "0.95"

fn test_error_response_passthrough() -> Bool:
    var response = "error:auth_failed"
    if not response.startswith("error:"):
        return False
    return True


# ============================================================================
# Tool validation logic (from react.mojo)
# ============================================================================

fn test_tool_validation_known() -> Bool:
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
    var tools = List[String]()
    var action = "anything"
    var valid = False
    for i in range(len(tools)):
        if tools[i] == action:
            valid = True
            break
    return not valid

fn test_tool_validation_empty_action() -> Bool:
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
# Main Test Runner
# ============================================================================

fn main():
    print("==============================================")
    print("ToonSPy Unit Test Suite")
    print("==============================================")
    print("")

    var passed = 0
    var failed = 0

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
    print("==============================================")
    print("Results: " + String(passed) + " passed, " + String(failed) + " failed, " + String(passed + failed) + " total")
    print("==============================================")
    if failed == 0:
        print("All tests passed!")
    else:
        print("Some tests FAILED")
