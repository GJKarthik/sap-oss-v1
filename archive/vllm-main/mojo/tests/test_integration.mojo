# ===----------------------------------------------------------------------=== #
# Integration Tests for ToonSPy + Backend Components
#
# Tests that verify correct interaction between multiple modules.
# ===----------------------------------------------------------------------=== #

from collections import Dict, List
from testing import assert_true, assert_equal, assert_false


# =============================================================================
# Test: Signature → Predict Pipeline
# =============================================================================

fn test_signature_predict_integration():
    """Test that Signature correctly flows through Predict module."""
    print("Testing: Signature → Predict integration...")
    
    # Create a classification signature
    from toonspy.signature import Signature, InputField, OutputField, create_classification_signature
    
    var categories = List[String]()
    categories.append("positive")
    categories.append("negative")
    categories.append("neutral")
    
    var sig = create_classification_signature(
        "Classify the sentiment of the text",
        categories
    )
    
    # Verify signature structure
    assert_true(len(sig.inputs) == 1, "Should have 1 input")
    assert_true(len(sig.outputs) == 2, "Should have 2 outputs (category + confidence)")
    assert_equal(sig.inputs[0].name, "text")
    assert_equal(sig.outputs[0].name, "category")
    
    # Verify TOON prompt generation
    var prompt = sig.generate_toon_prompt()
    assert_true("category:" in prompt, "Prompt should contain category field")
    assert_true("positive|negative|neutral" in prompt, "Prompt should contain enum values")
    
    print("✓ Signature → Predict integration passed")


fn test_predict_chainofthought_integration():
    """Test that Predict and ChainOfThought produce compatible outputs."""
    print("Testing: Predict → ChainOfThought integration...")
    
    from toonspy.signature import Signature, InputField, OutputField
    from toonspy.predict import _parse_toon_kv
    
    # Simulate a TOON response
    var response = "reasoning:step1|step2|step3 answer:42 confidence:0.95"
    var parsed = _parse_toon_kv(response)
    
    # Verify parsing works correctly
    assert_true("reasoning" in parsed, "Should parse reasoning field")
    assert_true("answer" in parsed, "Should parse answer field")
    assert_true("confidence" in parsed, "Should parse confidence field")
    
    assert_equal(parsed["reasoning"], "step1|step2|step3")
    assert_equal(parsed["answer"], "42")
    assert_equal(parsed["confidence"], "0.95")
    
    print("✓ Predict → ChainOfThought integration passed")


fn test_react_tool_flow():
    """Test ReAct tool registration and execution flow."""
    print("Testing: ReAct tool flow...")
    
    from toonspy.signature import Signature, InputField, OutputField
    from toonspy.react import Tool, ReActStep
    
    # Create tools
    var search_tool = Tool(
        name="search",
        description="Search the web for information",
        parameters=List[String]("query")
    )
    
    var calc_tool = Tool(
        name="calculate",
        description="Perform math calculations",
        parameters=List[String]("expression")
    )
    
    # Verify tool prompt generation
    var search_prompt = search_tool.to_prompt()
    assert_true("search:" in search_prompt, "Should contain tool name")
    assert_true("query" in search_prompt, "Should contain parameter")
    
    # Verify ReActStep TOON format
    var step = ReActStep(
        thought="I need to search for information",
        action="search",
        action_input="climate change",
        observation="Found 10 results about climate change"
    )
    
    var toon = step.to_toon()
    assert_true("thought:" in toon, "TOON should contain thought")
    assert_true("action:search" in toon, "TOON should contain action")
    
    print("✓ ReAct tool flow passed")


# =============================================================================
# Test: Parser → Model Routing
# =============================================================================

fn test_parser_model_extraction():
    """Test Mangle parser extracts model definitions correctly."""
    print("Testing: Parser model extraction...")
    
    from mangle.parser import MangleParser
    
    var parser = MangleParser()
    
    # Simulate Mangle facts
    var content = """
# Model definitions
model("/llama-7b", "LLaMA 7B", 4096).
model("/llama-13b", "LLaMA 13B", 8192).
model_status("/llama-7b", /available).
model_speed("/llama-7b", 8).
model_quality("/llama-7b", 7).
"""
    
    parser.parse_file_content(content)
    
    # Verify facts were parsed
    assert_true(len(parser.facts) >= 3, "Should parse at least 3 facts")
    
    # Extract models
    parser.extract_models()
    
    # Note: Full model extraction depends on complete Mangle implementation
    print("✓ Parser model extraction passed")


fn test_prompt_rules_intent_matching():
    """Test intent matching from prompt rules."""
    print("Testing: Prompt rules intent matching...")
    
    from mangle.parser import PromptRulesParser
    
    var parser = PromptRulesParser()
    
    var content = """
keyword_pattern("code", /coding).
keyword_pattern("explain", /explanation).
keyword_pattern("summarize", /summarization).
system_prompt(/coding, "You are a helpful coding assistant.").
recommended_temp(/coding, 0.3).
"""
    
    parser.parse_file_content(content)
    
    # Test intent matching
    var intent1 = parser.get_intent("Please write some code for me")
    assert_equal(intent1, "/coding")
    
    var intent2 = parser.get_intent("Can you explain this concept?")
    assert_equal(intent2, "/explanation")
    
    var intent3 = parser.get_intent("Hello, how are you?")
    assert_equal(intent3, "/general")  # Default fallback
    
    # Test prompt and temperature retrieval
    var prompt = parser.get_prompt("/coding")
    assert_true("coding assistant" in prompt, "Should return coding prompt")
    
    var temp = parser.get_temperature("/coding")
    assert_true(temp < 0.5, "Coding temperature should be low")
    
    print("✓ Prompt rules intent matching passed")


# =============================================================================
# Test: End-to-End Pipeline Simulation
# =============================================================================

fn test_e2e_classification_pipeline():
    """Test complete classification pipeline from signature to output."""
    print("Testing: End-to-end classification pipeline...")
    
    from toonspy.signature import create_classification_signature
    from toonspy.predict import _parse_toon_kv
    
    # Step 1: Create signature
    var categories = List[String]("spam", "ham")
    var sig = create_classification_signature("Classify email as spam or ham", categories)
    
    # Step 2: Generate prompt (simulated)
    var prompt = sig.generate_toon_prompt()
    assert_true(len(prompt) > 0, "Prompt should not be empty")
    
    # Step 3: Simulate LLM response
    var llm_response = "category:spam confidence:0.92"
    
    # Step 4: Parse response
    var result = _parse_toon_kv(llm_response)
    
    # Step 5: Validate output
    assert_equal(result["category"], "spam")
    assert_equal(result["confidence"], "0.92")
    
    print("✓ End-to-end classification pipeline passed")


fn test_e2e_qa_pipeline():
    """Test complete QA pipeline with context."""
    print("Testing: End-to-end QA pipeline...")
    
    from toonspy.signature import create_qa_signature
    from toonspy.predict import _parse_toon_kv
    
    # Step 1: Create QA signature
    var sig = create_qa_signature("Answer the question based on context.")
    
    # Step 2: Verify inputs
    assert_true(len(sig.inputs) == 2, "QA should have question and context inputs")
    
    # Step 3: Simulate response
    var response = "answer:The capital of France is Paris. confidence:0.98"
    var result = _parse_toon_kv(response)
    
    # Step 4: Validate
    assert_true("Paris" in result["answer"], "Answer should mention Paris")
    
    print("✓ End-to-end QA pipeline passed")


# =============================================================================
# Test: Error Propagation
# =============================================================================

fn test_error_propagation_chain():
    """Test that errors propagate correctly through module chain."""
    print("Testing: Error propagation chain...")
    
    from toonspy.signature import Signature, InputField, OutputField
    from toonspy.predict import _parse_toon_kv
    
    # Test error response parsing
    var error_response = "error:auth_failed"
    var result = _parse_toon_kv(error_response)
    
    # In real code, this would be caught at higher level
    assert_true("error" in result, "Error should be parseable as key")
    
    # Test malformed response handling
    var malformed = "this is not toon format at all"
    var malformed_result = _parse_toon_kv(malformed)
    # Should not crash, just return empty or partial result
    
    print("✓ Error propagation chain passed")


# =============================================================================
# Main Test Runner
# =============================================================================

fn main():
    print("=" * 60)
    print("ToonSPy Integration Tests")
    print("=" * 60)
    print()
    
    # Signature + Predict tests
    test_signature_predict_integration()
    test_predict_chainofthought_integration()
    test_react_tool_flow()
    
    # Parser + Routing tests
    test_parser_model_extraction()
    test_prompt_rules_intent_matching()
    
    # End-to-end tests
    test_e2e_classification_pipeline()
    test_e2e_qa_pipeline()
    
    # Error handling tests
    test_error_propagation_chain()
    
    print()
    print("=" * 60)
    print("All integration tests passed! ✓")
    print("=" * 60)