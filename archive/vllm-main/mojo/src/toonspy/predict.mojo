# ===----------------------------------------------------------------------=== #
# ToonSPy Predict Module
#
# Basic prediction module that takes a signature and generates TOON output.
# ===----------------------------------------------------------------------=== #

from collections import Dict
from .signature import Signature, InputField, OutputField
from .aicore import AICoreAdapter


struct Predict:
    """
    Basic DSPy-style Predict module for ToonSPy.
    
    Predict takes a signature and calls the LLM to generate TOON-formatted output.
    
    Example:
        var sig = Signature("Classify sentiment")
        sig.add_input(InputField(name="text"))
        sig.add_output(OutputField(name="sentiment", field_type="enum", 
                                   enum_values=List("positive", "negative")))
        
        var predictor = Predict(sig)
        var result = predictor.call({"text": "I love this!"})
        # Returns: {"sentiment": "positive"}
    """
    var signature: Signature
    var lm: AICoreAdapter
    var demos: List[Dict[String, String]]  # Few-shot examples
    
    fn __init__(
        mut self,
        signature: Signature,
        lm: AICoreAdapter = AICoreAdapter()
    ):
        self.signature = signature
        self.lm = lm
        self.demos = List[Dict[String, String]]()
    
    fn add_demo(mut self, demo: Dict[String, String]):
        """Add a few-shot demonstration example."""
        self.demos.append(demo)
    
    fn call(mut self, inputs: Dict[String, String]) -> Dict[String, String]:
        """
        Execute prediction with the given inputs.
        
        Args:
            inputs: Dictionary of input field names to values
        
        Returns:
            Dictionary of output field names to parsed values
        """
        # Validate inputs
        if not self.signature.validate_inputs(inputs):
            var error_result = Dict[String, String]()
            error_result["error"] = "validation_failed"
            error_result["error_type"] = "missing_required_inputs"
            # Build list of missing fields for debugging
            var missing_fields = String()
            for i in range(len(self.signature.inputs)):
                var field = self.signature.inputs[i]
                if field.required and len(field.name) > 0 and field.name not in inputs:
                    if len(missing_fields) > 0:
                        missing_fields += ","
                    missing_fields += field.name
            error_result["missing_fields"] = missing_fields
            return error_result
        
        # Build prompt
        var prompt = self._build_prompt(inputs)
        var system_prompt = self.signature.generate_system_prompt()
        
        # Call LLM
        var response = self.lm.complete(prompt, system_prompt)
        
        # Parse TOON response
        return self._parse_toon_response(response)
    
    fn _build_prompt(self, inputs: Dict[String, String]) -> String:
        """Build the full prompt with signature, demos, and inputs."""
        var prompt = self.signature.generate_toon_prompt()
        
        # Add few-shot demonstrations if available
        if len(self.demos) > 0:
            prompt += "\n\nExamples:\n"
            for i in range(len(self.demos)):
                prompt += self._format_demo(self.demos[i]) + "\n"
        
        # Add current inputs
        prompt += "\n\nInput:\n"
        for i in range(len(self.signature.inputs)):
            var field = self.signature.inputs[i]
            # Guard against empty field names
            if len(field.name) > 0 and field.name in inputs:
                prompt += field.name + ": " + inputs[field.name] + "\n"
        
        prompt += "\nOutput:"
        
        return prompt
    
    fn _format_demo(self, demo: Dict[String, String]) -> String:
        """Format a demonstration example."""
        var result = String()
        
        # Input part
        result += "Input: "
        for i in range(len(self.signature.inputs)):
            var field = self.signature.inputs[i]
            # Guard against empty field names
            if len(field.name) > 0 and field.name in demo:
                if i > 0:
                    result += " "
                result += field.name + ":" + demo[field.name]
        
        # Output part
        result += "\nOutput: "
        for i in range(len(self.signature.outputs)):
            var field = self.signature.outputs[i]
            # Guard against empty field names
            if len(field.name) > 0 and field.name in demo:
                if i > 0:
                    result += " "
                result += field.name + ":" + demo[field.name]
        
        return result
    
    fn _parse_toon_response(self, response: String) -> Dict[String, String]:
        """Parse TOON-formatted response into dictionary.
        
        Uses boundary-aware parsing: a new key starts where an alpha word
        is immediately followed by ':'. The value runs until the next key
        boundary or end-of-string, so multi-word values are preserved.
        """
        var result = Dict[String, String]()
        
        # Handle error responses
        if response.startswith("error:"):
            result["error"] = response
            return result
        
        result = _parse_toon_kv(_clean_toon_response(response))
        return result
    
    fn forward(mut self, inputs: Dict[String, String]) -> Dict[String, String]:
        """Alias for call() to match DSPy convention."""
        return self.call(inputs)^


struct PredictResult:
    """Result from a Predict call with additional metadata."""
    var outputs: Dict[String, String]
    var raw_response: String
    var tokens_used: Int
    var success: Bool
    
    fn __init__(
        mut self,
        outputs: Dict[String, String],
        raw_response: String = "",
        tokens_used: Int = 0
    ):
        self.outputs = outputs
        self.raw_response = raw_response
        self.tokens_used = tokens_used
        self.success = "error" not in outputs
    
    fn get(self, key: String, default: String = "") raises -> String:
        """Get output value by key."""
        if key in self.outputs:
            return self.outputs[key]
        return default


# ===----------------------------------------------------------------------=== #
# Convenience functions
# ===----------------------------------------------------------------------=== #

fn predict(
    signature: Signature,
    inputs: Dict[String, String],
    lm: AICoreAdapter = AICoreAdapter()
) -> Dict[String, String]:
    """One-shot prediction with a signature."""
    var predictor = Predict(signature, lm)
    return predictor.call(inputs)


fn predict_batch(
    signature: Signature,
    batch_inputs: List[Dict[String, String]],
    lm: AICoreAdapter = AICoreAdapter()
) -> List[Dict[String, String]]:
    """Batch prediction for multiple inputs."""
    var predictor = Predict(signature, lm)
    var results = List[Dict[String, String]]()
    
    for i in range(len(batch_inputs)):
        var result = predictor.call(batch_inputs[i])
        results.append(result)
    
    return results


# ===----------------------------------------------------------------------=== #
# Response cleaning
# ===----------------------------------------------------------------------=== #


fn _clean_toon_response(response: String) -> String:
    """Strip markdown code fences from LLM responses.

    LLMs sometimes wrap TOON output in ```toon ... ``` blocks.
    This strips the fences so the parser sees raw TOON key:value text.
    """
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


# ===----------------------------------------------------------------------=== #
# Shared TOON key:value parser
# ===----------------------------------------------------------------------=== #


fn _is_key_boundary(text: String, pos: Int) -> Bool:
    """Check if position marks the start of a TOON key:value pair.

    A key boundary is an alpha character at position 0 or preceded by
    whitespace, followed by one or more alphanumeric/underscore/dot chars
    and then ':'. Dots enable nested keys like 'address.city:NYC'.
    """
    var tlen = len(text)
    if pos >= tlen:
        return False
    var ch = text[pos]
    # Must start with a letter
    if not ((ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")):
        return False
    # Must be at start or preceded by whitespace
    if pos > 0:
        var prev = text[pos - 1]
        if prev != " " and prev != "\t" and prev != "\n" and prev != "\r":
            return False
    # Scan forward for ':'
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
    """Parse TOON key:value pairs with boundary-aware splitting.

    Handles multi-word values correctly by detecting key boundaries
    (alphanumeric word immediately followed by ':') rather than
    splitting on spaces.

    Enhanced features:
    - Quoted values: key:"value with : colons" preserves content
    - Pipe arrays: items:a|b|c preserved as string (split on | downstream)
    - Nested dot notation: address.city:NYC stored as "address.city" key

    Example: 'answer:hello world confidence:0.9'
      -> {"answer": "hello world", "confidence": "0.9"}
    Example: 'query:"search for: things" status:ok'
      -> {"query": "search for: things", "status": "ok"}
    """
    var result = Dict[String, String]()
    var tlen = len(text)

    # Find all key boundary positions
    var key_positions = List[Int]()
    for i in range(tlen):
        if _is_key_boundary(text, i):
            key_positions.append(i)

    # Extract key:value pairs between boundaries
    for idx in range(len(key_positions)):
        var start = key_positions[idx]
        var end = tlen
        if idx + 1 < len(key_positions):
            end = key_positions[idx + 1]

        # Find the colon in this segment
        var segment = text[start:end]
        var colon_pos = segment.find(":")
        if colon_pos > 0:
            var key = segment[:colon_pos].strip()
            var raw_value = segment[colon_pos + 1:]

            # Handle quoted values (preserves colons, special chars)
            var stripped = raw_value.strip()
            if len(stripped) > 0 and stripped[0] == "\"":
                # Find closing quote (skip escaped quotes)
                var close_idx = -1
                for qi in range(1, len(stripped)):
                    if stripped[qi] == "\"" and stripped[qi - 1] != "\\":
                        close_idx = qi
                        break
                if close_idx > 0:
                    raw_value = stripped[1:close_idx]
                else:
                    # No closing quote — use everything after opening quote
                    raw_value = stripped[1:].strip()
            else:
                raw_value = stripped

            if len(key) > 0:
                result[key] = raw_value

    return result