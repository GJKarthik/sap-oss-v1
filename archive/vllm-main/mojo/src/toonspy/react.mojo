# ===----------------------------------------------------------------------=== #
# ToonSPy ReAct Module
#
# ReAct (Reasoning + Acting) agent module for tool-using agents.
# ===----------------------------------------------------------------------=== #

from collections import Dict, List
from .signature import Signature, InputField, OutputField
from .aicore import AICoreAdapter
from .predict import _parse_toon_kv


@value
struct Tool:
    """A tool that the ReAct agent can use."""
    var name: String
    var description: String
    var parameters: List[String]
    
    fn __init__(
        mut self,
        name: String,
        description: String,
        parameters: List[String] = List[String]()
    ):
        self.name = name
        self.description = description
        self.parameters = parameters
    
    fn to_prompt(self) -> String:
        """Format tool for prompt."""
        var result = self.name + ": " + self.description
        if len(self.parameters) > 0:
            result += " (params: "
            for i in range(len(self.parameters)):
                if i > 0:
                    result += ", "
                result += self.parameters[i]
            result += ")"
        return result


@value
struct ReActStep(Copyable, Movable):
    """A single step in the ReAct loop."""
    var thought: String
    var action: String
    var action_input: String
    var observation: String
    
    fn __init__(
        mut self,
        thought: String = "",
        action: String = "",
        action_input: String = "",
        observation: String = ""
    ):
        self.thought = thought
        self.action = action
        self.action_input = action_input
        self.observation = observation
    
    fn __copyinit__(mut self, existing: Self):
        self.thought = existing.thought
        self.action = existing.action
        self.action_input = existing.action_input
        self.observation = existing.observation
    
    fn __moveinit__(mut self, owned existing: Self):
        self.thought = existing.thought^
        self.action = existing.action^
        self.action_input = existing.action_input^
        self.observation = existing.observation^
    
    fn to_toon(self) -> String:
        """Convert step to TOON format."""
        return "thought:" + self.thought + " action:" + self.action + " input:" + self.action_input


struct ReAct:
    """
    ReAct (Reasoning + Acting) agent module for ToonSPy.
    
    ReAct agents alternate between:
    1. Thought: Reasoning about what to do
    2. Action: Calling a tool
    3. Observation: Receiving tool output
    
    TOON output format for each step:
        thought:<reasoning> action:<tool_name> input:<tool_args>
    
    Final answer format:
        thought:<final_reasoning> action:finish answer:<value>
    
    Example:
        var agent = ReAct(signature)
        agent.add_tool(Tool("search", "Search the web"))
        agent.add_tool(Tool("calculate", "Do math"))
        
        var result = agent.call({"question": "What is the population of France?"})
    """
    var signature: Signature
    var lm: AICoreAdapter
    var tools: List[Tool]
    var max_steps: Int
    var history: List[ReActStep]
    
    fn __init__(
        mut self,
        signature: Signature,
        lm: AICoreAdapter = AICoreAdapter(),
        max_steps: Int = 10
    ):
        self.signature = signature
        self.lm = lm
        self.tools = List[Tool]()
        # Ensure max_steps is positive to prevent infinite loops
        self.max_steps = max_steps if max_steps > 0 else 10
        self.history = List[ReActStep]()
        
        # Add default finish tool
        self.tools.append(Tool(
            name="finish",
            description="Return the final answer",
            parameters=List[String]("answer")
        ))
    
    fn add_tool(mut self, tool: Tool):
        """Add a tool the agent can use."""
        self.tools.append(tool)
    
    fn call(
        mut self,
        inputs: Dict[String, String],
        tool_executor: fn(String, String) -> String = default_executor
    ) -> Dict[String, String]:
        """
        Execute ReAct loop.
        
        Args:
            inputs: Input field values
            tool_executor: Function to execute tools (name, input) -> observation
        
        Returns:
            Final answer dictionary
        """
        self.history = List[ReActStep]()  # Reset history

        # Guard: Ensure max_steps is positive (defense in depth)
        if self.max_steps <= 0:
            self.max_steps = 10
        
        # Guard: Check if we have any tools besides finish
        if len(self.tools) <= 1:  # Only has finish tool
            var error_result = Dict[String, String]()
            error_result["error"] = "no_tools_registered"
            error_result["details"] = "ReAct agent requires at least one tool besides 'finish'"
            return error_result^

        # Validate required signature inputs are present
        for i in range(len(self.signature.inputs)):
            var field = self.signature.inputs[i]
            if field.required and len(field.name) > 0 and field.name not in inputs:
                var error_result = Dict[String, String]()
                error_result["error"] = "missing_required_input"
                error_result["field"] = field.name
                return error_result^

        var step = 0
        while step < self.max_steps:
            # Build prompt with history
            var prompt = self._build_react_prompt(inputs)
            var system_prompt = self._build_react_system_prompt()
            
            # Get next action from LLM
            var response = self.lm.complete(prompt, system_prompt)
            var parsed = self._parse_react_response(response)
            
            var thought = parsed.get("thought", "")
            var action = parsed.get("action", "")
            var action_input = parsed.get("input", "")
            
            # Check for finish action
            if action == "finish":
                var result = Dict[String, String]()
                result["answer"] = parsed.get("answer", action_input)
                result["steps"] = String(len(self.history))
                return result^
            
            # Validate action is not empty
            if len(action) == 0:
                var react_step = ReActStep(
                    thought=thought,
                    action="",
                    action_input=action_input,
                    observation="error: empty action returned by LLM"
                )
                self.history.append(react_step^)
                step += 1
                continue
            
            # Validate tool name against registered tools
            var tool_valid = False
            for t in range(len(self.tools)):
                if self.tools[t].name == action:
                    tool_valid = True
                    break
            if not tool_valid:
                # Record as failed step with helpful error, continue loop
                var available_tools = String()
                for t in range(len(self.tools)):
                    if len(available_tools) > 0:
                        available_tools += ", "
                    available_tools += self.tools[t].name
                
                var react_step = ReActStep(
                    thought=thought,
                    action=action,
                    action_input=action_input,
                    observation="error: unknown tool '" + action + "'. Available: " + available_tools
                )
                self.history.append(react_step^)
                step += 1
                continue
            
            # Execute tool
            var observation = tool_executor(action, action_input)
            
            # Record step
            var react_step = ReActStep(
                thought=thought,
                action=action,
                action_input=action_input,
                observation=observation
            )
            self.history.append(react_step^)
            
            step += 1
        
        # Max steps reached
        var error_result = Dict[String, String]()
        error_result["error"] = "max_steps_reached"
        error_result["steps"] = String(self.max_steps)
        return error_result^
    
    fn _build_react_prompt(self, inputs: Dict[String, String]) -> String:
        """Build ReAct prompt with tool descriptions and history."""
        var prompt = self.signature.description + "\n\n"
        
        # Tool descriptions
        prompt += "Available tools:\n"
        for i in range(len(self.tools)):
            prompt += "- " + self.tools[i].to_prompt() + "\n"
        
        # Format specification
        prompt += "\nRespond in TOON format:\n"
        prompt += "thought:<your_reasoning> action:<tool_name> input:<tool_args>\n"
        prompt += "OR to finish: thought:<reasoning> action:finish answer:<final_answer>\n"
        
        # Input
        prompt += "\nQuestion:\n"
        for i in range(len(self.signature.inputs)):
            var field = self.signature.inputs[i]
            if field.name in inputs:
                prompt += inputs[field.name] + "\n"
        
        # History
        if len(self.history) > 0:
            prompt += "\nPrevious steps:\n"
            for i in range(len(self.history)):
                var step = self.history[i]
                prompt += "Step " + String(i + 1) + ":\n"
                prompt += "  " + step.to_toon() + "\n"
                prompt += "  observation:" + step.observation + "\n"
        
        prompt += "\nNext step:"
        
        return prompt
    
    fn _build_react_system_prompt(self) -> String:
        """Build system prompt for ReAct."""
        return """You are a precise assistant that uses tools to answer questions.

For each step:
1. Think about what information you need
2. Choose the best tool to get that information
3. Provide the tool input

TOON format:
- thought:<your_reasoning>
- action:<tool_name>
- input:<tool_arguments>

When you have the final answer, use:
- action:finish
- answer:<final_answer>

Be concise and direct."""
    
    fn _parse_react_response(self, response: String) -> Dict[String, String]:
        """Parse ReAct TOON response.
        
        Uses boundary-aware parsing so multi-word thoughts and
        action inputs are preserved.
        """
        return _parse_toon_kv(response)
    
    fn get_history(self) -> List[ReActStep]:
        """Get the execution history."""
        return self.history
    
    fn forward(
        mut self,
        inputs: Dict[String, String],
        tool_executor: fn(String, String) -> String = default_executor
    ) -> Dict[String, String]:
        """Alias for call()."""
        return self.call(inputs, tool_executor)^


# ===----------------------------------------------------------------------=== #
# Default tool executor
# ===----------------------------------------------------------------------=== #

fn default_executor(tool_name: String, tool_input: String) -> String:
    """Default tool executor - returns placeholder."""
    return "Tool '" + tool_name + "' not implemented"


# ===----------------------------------------------------------------------=== #
# Common tools
# ===----------------------------------------------------------------------=== #

fn create_search_tool() -> Tool:
    """Create a web search tool."""
    return Tool(
        name="search",
        description="Search the web for information",
        parameters=List[String]("query")
    )


fn create_calculator_tool() -> Tool:
    """Create a calculator tool."""
    return Tool(
        name="calculate",
        description="Perform mathematical calculations",
        parameters=List[String]("expression")
    )


fn create_lookup_tool() -> Tool:
    """Create a database lookup tool."""
    return Tool(
        name="lookup",
        description="Look up information in the database",
        parameters=List[String]("key")
    )