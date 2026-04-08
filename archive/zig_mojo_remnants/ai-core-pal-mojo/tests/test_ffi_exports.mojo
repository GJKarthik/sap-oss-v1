# =============================================================================
# FFI Exports Unit Tests - MCP PAL Operations
# =============================================================================
#
# Tests for the BDC MCP PAL Mojo FFI exports.
# Covers Chain-of-Thought, ReAct, SQL validation, token counting, and tool matching.
#
# Run with: mojo test mojo/tests/test_ffi_exports.mojo
# =============================================================================

from memory import UnsafePointer
from testing import assert_true, assert_equal

# Import the module under test
from ..src.ffi_exports import (
    mojo_init,
    mojo_shutdown,
    mojo_chain_of_thought,
    mojo_react_step,
    mojo_validate_sql_template,
    mojo_count_tokens,
    mojo_score_tool_match,
)


# =============================================================================
# TEST: Initialization
# =============================================================================

fn test_init_success():
    """Test that initialization returns success."""
    let result = mojo_init()
    assert_equal(result, 0, "Init should return 0 on success")
    mojo_shutdown()


# =============================================================================
# TEST: Chain-of-Thought
# =============================================================================

fn test_cot_generates_steps():
    """Test that CoT generates structured reasoning steps."""
    _ = mojo_init()
    
    let prompt = "Execute kmeans clustering on SALES_DATA"
    var prompt_bytes = UnsafePointer[UInt8].alloc(len(prompt))
    for i in range(len(prompt)):
        prompt_bytes[i] = ord(prompt[i])
    
    let context = "Schema: id INT, value DOUBLE"
    var context_bytes = UnsafePointer[UInt8].alloc(len(context))
    for i in range(len(context)):
        context_bytes[i] = ord(context[i])
    
    var output = UnsafePointer[UInt8].alloc(1024)
    
    let result_len = mojo_chain_of_thought(
        prompt_bytes, Int32(len(prompt)),
        context_bytes, Int32(len(context)),
        output, 1024
    )
    
    assert_true(result_len > 0, "CoT should produce output")
    
    # Verify output contains step markers
    var output_str = String()
    for i in range(int(result_len)):
        output_str += chr(int(output[i]))
    
    assert_true("Step 1" in output_str, "Should contain Step 1")
    assert_true("Step 2" in output_str, "Should contain Step 2")
    assert_true("Step 3" in output_str, "Should contain Step 3")
    assert_true("Step 4" in output_str, "Should contain Step 4")
    
    prompt_bytes.free()
    context_bytes.free()
    output.free()
    mojo_shutdown()


fn test_cot_includes_prompt_summary():
    """Test that CoT includes prompt in output."""
    _ = mojo_init()
    
    let prompt = "ARIMA forecasting"
    var prompt_bytes = UnsafePointer[UInt8].alloc(len(prompt))
    for i in range(len(prompt)):
        prompt_bytes[i] = ord(prompt[i])
    
    var context_bytes = UnsafePointer[UInt8].alloc(0)
    var output = UnsafePointer[UInt8].alloc(1024)
    
    let result_len = mojo_chain_of_thought(
        prompt_bytes, Int32(len(prompt)),
        context_bytes, 0,
        output, 1024
    )
    
    var output_str = String()
    for i in range(int(result_len)):
        output_str += chr(int(output[i]))
    
    assert_true("ARIMA" in output_str, "Should include prompt content")
    
    prompt_bytes.free()
    output.free()
    mojo_shutdown()


# =============================================================================
# TEST: ReAct Step
# =============================================================================

fn test_react_error_triggers_retry():
    """Test that error observation triggers retry action."""
    _ = mojo_init()
    
    let observation = "Error: Connection failed to HANA"
    var obs_bytes = UnsafePointer[UInt8].alloc(len(observation))
    for i in range(len(observation)):
        obs_bytes[i] = ord(observation[i])
    
    var action_out = UnsafePointer[UInt8].alloc(512)
    
    let result_len = mojo_react_step(
        obs_bytes, Int32(len(observation)),
        action_out, 512
    )
    
    assert_true(result_len > 0, "ReAct should produce output")
    
    var output_str = String()
    for i in range(int(result_len)):
        output_str += chr(int(action_out[i]))
    
    assert_true("retry_with_fallback" in output_str, "Should trigger retry action")
    assert_true("THOUGHT" in output_str, "Should contain thought")
    
    obs_bytes.free()
    action_out.free()
    mojo_shutdown()


fn test_react_success_triggers_finalize():
    """Test that success observation triggers finalize action."""
    _ = mojo_init()
    
    let observation = "Result: 5 clusters found successfully"
    var obs_bytes = UnsafePointer[UInt8].alloc(len(observation))
    for i in range(len(observation)):
        obs_bytes[i] = ord(observation[i])
    
    var action_out = UnsafePointer[UInt8].alloc(512)
    
    let result_len = mojo_react_step(
        obs_bytes, Int32(len(observation)),
        action_out, 512
    )
    
    var output_str = String()
    for i in range(int(result_len)):
        output_str += chr(int(action_out[i]))
    
    assert_true("finalize_response" in output_str, "Should trigger finalize action")
    
    obs_bytes.free()
    action_out.free()
    mojo_shutdown()


fn test_react_schema_triggers_query():
    """Test that schema observation triggers query action."""
    _ = mojo_init()
    
    let observation = "Need to check table schema for CUSTOMERS"
    var obs_bytes = UnsafePointer[UInt8].alloc(len(observation))
    for i in range(len(observation)):
        obs_bytes[i] = ord(observation[i])
    
    var action_out = UnsafePointer[UInt8].alloc(512)
    
    let result_len = mojo_react_step(
        obs_bytes, Int32(len(observation)),
        action_out, 512
    )
    
    var output_str = String()
    for i in range(int(result_len)):
        output_str += chr(int(action_out[i]))
    
    assert_true("query_schema" in output_str, "Should trigger query_schema action")
    
    obs_bytes.free()
    action_out.free()
    mojo_shutdown()


# =============================================================================
# TEST: SQL Validation
# =============================================================================

fn test_sql_valid_select():
    """Test that valid SELECT is accepted."""
    _ = mojo_init()
    
    let sql = "SELECT * FROM CUSTOMERS WHERE ID > 100"
    var sql_bytes = UnsafePointer[UInt8].alloc(len(sql))
    for i in range(len(sql)):
        sql_bytes[i] = ord(sql[i])
    
    var schema_bytes = UnsafePointer[UInt8].alloc(0)
    
    let result = mojo_validate_sql_template(
        sql_bytes, Int32(len(sql)),
        schema_bytes, 0
    )
    
    assert_equal(result, 0, "Valid SELECT should return 0")
    
    sql_bytes.free()
    mojo_shutdown()


fn test_sql_valid_call():
    """Test that valid CALL is accepted."""
    _ = mojo_init()
    
    let sql = "CALL _SYS_AFL.PAL_KMEANS(:input, :params, :result)"
    var sql_bytes = UnsafePointer[UInt8].alloc(len(sql))
    for i in range(len(sql)):
        sql_bytes[i] = ord(sql[i])
    
    var schema_bytes = UnsafePointer[UInt8].alloc(0)
    
    let result = mojo_validate_sql_template(
        sql_bytes, Int32(len(sql)),
        schema_bytes, 0
    )
    
    assert_equal(result, 0, "Valid CALL should return 0")
    
    sql_bytes.free()
    mojo_shutdown()


fn test_sql_rejects_drop():
    """Test that DROP is rejected."""
    _ = mojo_init()
    
    let sql = "DROP TABLE CUSTOMERS"
    var sql_bytes = UnsafePointer[UInt8].alloc(len(sql))
    for i in range(len(sql)):
        sql_bytes[i] = ord(sql[i])
    
    var schema_bytes = UnsafePointer[UInt8].alloc(0)
    
    let result = mojo_validate_sql_template(
        sql_bytes, Int32(len(sql)),
        schema_bytes, 0
    )
    
    assert_equal(result, -2, "DROP should return -2 (dangerous)")
    
    sql_bytes.free()
    mojo_shutdown()


fn test_sql_rejects_truncate():
    """Test that TRUNCATE is rejected."""
    _ = mojo_init()
    
    let sql = "TRUNCATE TABLE LOGS"
    var sql_bytes = UnsafePointer[UInt8].alloc(len(sql))
    for i in range(len(sql)):
        sql_bytes[i] = ord(sql[i])
    
    var schema_bytes = UnsafePointer[UInt8].alloc(0)
    
    let result = mojo_validate_sql_template(
        sql_bytes, Int32(len(sql)),
        schema_bytes, 0
    )
    
    assert_equal(result, -2, "TRUNCATE should return -2 (dangerous)")
    
    sql_bytes.free()
    mojo_shutdown()


fn test_sql_rejects_unbalanced_parens():
    """Test that unbalanced parentheses are rejected."""
    _ = mojo_init()
    
    let sql = "SELECT * FROM (SELECT id FROM users"  # Missing closing paren
    var sql_bytes = UnsafePointer[UInt8].alloc(len(sql))
    for i in range(len(sql)):
        sql_bytes[i] = ord(sql[i])
    
    var schema_bytes = UnsafePointer[UInt8].alloc(0)
    
    let result = mojo_validate_sql_template(
        sql_bytes, Int32(len(sql)),
        schema_bytes, 0
    )
    
    assert_equal(result, -4, "Unbalanced parens should return -4")
    
    sql_bytes.free()
    mojo_shutdown()


# =============================================================================
# TEST: Token Counting
# =============================================================================

fn test_token_count_short_text():
    """Test token counting for short text."""
    _ = mojo_init()
    
    let text = "Hello world"
    var text_bytes = UnsafePointer[UInt8].alloc(len(text))
    for i in range(len(text)):
        text_bytes[i] = ord(text[i])
    
    let count = mojo_count_tokens(text_bytes, Int32(len(text)))
    
    assert_true(count > 0, "Token count should be positive")
    assert_true(count < 10, "Short text should have few tokens")
    
    text_bytes.free()
    mojo_shutdown()


fn test_token_count_sql():
    """Test token counting for SQL text."""
    _ = mojo_init()
    
    let text = "SELECT customer_id, customer_name FROM customers WHERE status = 'active'"
    var text_bytes = UnsafePointer[UInt8].alloc(len(text))
    for i in range(len(text)):
        text_bytes[i] = ord(text[i])
    
    let count = mojo_count_tokens(text_bytes, Int32(len(text)))
    
    assert_true(count > 5, "SQL should have multiple tokens")
    assert_true(count < 50, "Token count should be reasonable")
    
    text_bytes.free()
    mojo_shutdown()


# =============================================================================
# TEST: Tool Matching
# =============================================================================

fn test_tool_match_scoring():
    """Test that tool matching produces valid scores."""
    _ = mojo_init()
    
    let query = "cluster my data using kmeans"
    var query_bytes = UnsafePointer[UInt8].alloc(len(query))
    for i in range(len(query)):
        query_bytes[i] = ord(query[i])
    
    # Two tool descriptions
    let desc1 = "Execute kmeans clustering algorithm"
    let desc2 = "Forecast time series with ARIMA"
    
    var tool_descs = UnsafePointer[UInt8].alloc(len(desc1) + len(desc2))
    for i in range(len(desc1)):
        tool_descs[i] = ord(desc1[i])
    for i in range(len(desc2)):
        tool_descs[len(desc1) + i] = ord(desc2[i])
    
    var desc_lengths = UnsafePointer[Int32].alloc(2)
    desc_lengths[0] = Int32(len(desc1))
    desc_lengths[1] = Int32(len(desc2))
    
    var scores = UnsafePointer[Float32].alloc(2)
    
    let result = mojo_score_tool_match(
        query_bytes, Int32(len(query)),
        tool_descs, desc_lengths,
        2, scores
    )
    
    assert_equal(result, 0, "Tool match should succeed")
    
    # kmeans description should score higher than ARIMA for this query
    assert_true(scores[0] > scores[1], "kmeans tool should score higher")
    
    # Scores should be in [0, 1]
    assert_true(scores[0] >= 0.0 and scores[0] <= 1.0, "Score 0 in valid range")
    assert_true(scores[1] >= 0.0 and scores[1] <= 1.0, "Score 1 in valid range")
    
    query_bytes.free()
    tool_descs.free()
    desc_lengths.free()
    scores.free()
    mojo_shutdown()


# =============================================================================
# Main Test Runner
# =============================================================================

fn main():
    print("=" * 60)
    print("BDC MCP PAL - FFI Exports Tests")
    print("=" * 60)
    
    print("\n[TEST] Initialization...")
    test_init_success()
    print("  ✓ test_init_success")
    
    print("\n[TEST] Chain-of-Thought...")
    test_cot_generates_steps()
    print("  ✓ test_cot_generates_steps")
    
    test_cot_includes_prompt_summary()
    print("  ✓ test_cot_includes_prompt_summary")
    
    print("\n[TEST] ReAct Step...")
    test_react_error_triggers_retry()
    print("  ✓ test_react_error_triggers_retry")
    
    test_react_success_triggers_finalize()
    print("  ✓ test_react_success_triggers_finalize")
    
    test_react_schema_triggers_query()
    print("  ✓ test_react_schema_triggers_query")
    
    print("\n[TEST] SQL Validation...")
    test_sql_valid_select()
    print("  ✓ test_sql_valid_select")
    
    test_sql_valid_call()
    print("  ✓ test_sql_valid_call")
    
    test_sql_rejects_drop()
    print("  ✓ test_sql_rejects_drop")
    
    test_sql_rejects_truncate()
    print("  ✓ test_sql_rejects_truncate")
    
    test_sql_rejects_unbalanced_parens()
    print("  ✓ test_sql_rejects_unbalanced_parens")
    
    print("\n[TEST] Token Counting...")
    test_token_count_short_text()
    print("  ✓ test_token_count_short_text")
    
    test_token_count_sql()
    print("  ✓ test_token_count_sql")
    
    print("\n[TEST] Tool Matching...")
    test_tool_match_scoring()
    print("  ✓ test_tool_match_scoring")
    
    print("\n" + "=" * 60)
    print("All tests passed! ✓")
    print("=" * 60)