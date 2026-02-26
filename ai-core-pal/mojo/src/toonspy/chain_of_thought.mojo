# ===----------------------------------------------------------------------=== #
# ToonSPy Chain of Thought Module
#
# ChainOfThought module that adds reasoning to predictions.
# ===----------------------------------------------------------------------=== #

from collections import Dict, List
from .signature import Signature, InputField, OutputField
from .aicore import AICoreAdapter
from .predict import Predict, _parse_toon_kv


struct ChainOfThought:
    """
    Chain of Thought (CoT) module for ToonSPy.
    
    Extends Predict by adding a reasoning step before the final output.
    The LLM is prompted to think step-by-step before generating the answer.
    
    TOON output format includes reasoning:
        reasoning:<step1>|<step2>|<step3> answer:<value>
    
    Example:
        var sig = Signature("Solve the math problem")
        sig.add_input(InputField(name="problem"))
        sig.add_output(OutputField(name="answer"))
        
        var cot = ChainOfThought(sig)
        var result = cot.call({"problem": "What is 2 + 2?"})
        # Returns: {"reasoning": "add|2|plus|2|equals|4", "answer": "4"}
    """
    var signature: Signature
    var lm: AICoreAdapter
    var demos: List[Dict[String, String]]
    var reasoning_field: OutputField
    
    fn __init__(
        inout self,
        signature: Signature,
        lm: AICoreAdapter = AICoreAdapter()
    ):
        self.signature = signature
        self.lm = lm
        self.demos = List[Dict[String, String]]()
        
        # Add reasoning field to outputs
        self.reasoning_field = OutputField(
            name="reasoning",
            desc="Step-by-step reasoning",
            field_type="string"
        )
    
    fn add_demo(inout self, demo: Dict[String, String]):
        """Add a few-shot demonstration with reasoning."""
        self.demos.append(demo)
    
    fn call(inout self, inputs: Dict[String, String]) -> Dict[String, String]:
        """
        Execute Chain of Thought prediction.
        
        Args:
            inputs: Dictionary of input field names to values
        
        Returns:
            Dictionary with reasoning and output fields
        """
        # Validate inputs
        if not self.signature.validate_inputs(inputs):
            var error_result = Dict[String, String]()
            error_result["error"] = "missing_required_inputs"
            return error_result
        
        # Build CoT prompt
        var prompt = self._build_cot_prompt(inputs)
        var system_prompt = self._build_cot_system_prompt()
        
        # Call LLM
        var response = self.lm.complete(prompt, system_prompt)
        
        # Parse TOON response
        return self._parse_toon_response(response)
    
    fn _build_cot_prompt(self, inputs: Dict[String, String]) -> String:
        """Build prompt that encourages step-by-step reasoning."""
        var prompt = self.signature.description + "\n\n"
        prompt += "Think step by step, then provide your answer.\n\n"
        prompt += "Respond in TOON format:\n"
        prompt += "reasoning:<step1>|<step2>|<step3> "
        
        # Add output specifications
        for i in range(len(self.signature.outputs)):
            prompt += self.signature.outputs[i].to_toon_spec() + " "
        
        # Add few-shot demonstrations
        if len(self.demos) > 0:
            prompt += "\n\nExamples:\n"
            for i in range(len(self.demos)):
                prompt += self._format_demo(self.demos[i]) + "\n"
        
        # Add current inputs
        prompt += "\n\nInput:\n"
        for i in range(len(self.signature.inputs)):
            var field = self.signature.inputs[i]
            if field.name in inputs:
                prompt += field.name + ": " + inputs[field.name] + "\n"
        
        prompt += "\nOutput:"
        
        return prompt
    
    fn _build_cot_system_prompt(self) -> String:
        """Build system prompt for Chain of Thought."""
        return """You are a precise assistant that thinks step by step and responds in TOON format.

For every question:
1. First, break down the problem into steps
2. Reason through each step
3. Then provide your final answer

TOON format rules:
- Use key:value syntax (no quotes for simple strings)
- Arrays/steps use pipe separator: reasoning:step1|step2|step3
- Always include reasoning before the answer
- Be concise in your reasoning steps"""
    
    fn _format_demo(self, demo: Dict[String, String]) -> String:
        """Format a demonstration with reasoning."""
        var result = String()
        
        # Input part
        result += "Input: "
        for i in range(len(self.signature.inputs)):
            var field = self.signature.inputs[i]
            if field.name in demo:
                if i > 0:
                    result += " "
                result += field.name + ":" + demo[field.name]
        
        # Output part with reasoning
        result += "\nOutput: "
        if "reasoning" in demo:
            result += "reasoning:" + demo["reasoning"] + " "
        
        for i in range(len(self.signature.outputs)):
            var field = self.signature.outputs[i]
            if field.name in demo:
                result += field.name + ":" + demo[field.name] + " "
        
        return result
    
    fn _parse_toon_response(self, response: String) -> Dict[String, String]:
        """Parse TOON-formatted response with reasoning.
        
        Uses boundary-aware parsing so multi-word values are preserved.
        """
        var result = Dict[String, String]()
        
        if response.startswith("error:"):
            result["error"] = response
            return result
        
        result = _parse_toon_kv(response)
        return result
    
    fn get_reasoning_steps(self, result: Dict[String, String]) -> List[String]:
        """Extract reasoning steps from result as a list."""
        var steps = List[String]()
        
        if "reasoning" in result:
            var reasoning = result["reasoning"]
            var parts = reasoning.split("|")
            for i in range(len(parts)):
                steps.append(parts[i])
        
        return steps
    
    fn forward(inout self, inputs: Dict[String, String]) -> Dict[String, String]:
        """Alias for call() to match DSPy convention."""
        return self.call(inputs)


# ===----------------------------------------------------------------------=== #
# Convenience functions
# ===----------------------------------------------------------------------=== #

fn chain_of_thought(
    signature: Signature,
    inputs: Dict[String, String],
    lm: AICoreAdapter = AICoreAdapter()
) -> Dict[String, String]:
    """One-shot Chain of Thought prediction."""
    var cot = ChainOfThought(signature, lm)
    return cot.call(inputs)