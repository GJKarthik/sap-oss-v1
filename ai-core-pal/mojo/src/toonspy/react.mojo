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
        inout self,
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
struct ReActStep:
    """A single step in the ReAct loop."""
    var thought: String
    var action: String
    var action_input: String
    var observation: String
    
    fn __init__(
        inout self,
        thought: String = "",
        action: String = "",
        action_input: String = "",
        observation: String = ""
    ):
        self.thought = thought
        self.action = action
        self.action_input = action_input
        self.observation = observation
    
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
        inout self,
        signature: Signature,
        lm: AICoreAdapter = AICoreAdapter(),
        max_steps: Int = 10
    ):
        self.signature = signature
        self.lm = lm
        self.tools = List[Tool]()
        self.max_steps = max_steps
        self.history = List[ReActStep]()
        
        # Add default finish tool
        self.tools.append(Tool(
            name="finish",
            description="Return the final answer",
            parameters=List[String]("answer")
        ))
    
    fn add_tool(inout self, tool: Tool):
        """Add a tool the agent can use."""
        self.tools.append(tool)
    
    fn call(
        inout self,
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
                return result
            
            # Validate tool name against registered tools
            var tool_valid = False
            for t in range(len(self.tools)):
                if self.tools[t].name == action:
                    tool_valid = True
                    break
            if not tool_valid:
                var react_step = ReActStep(
                    thought=thought,
                    action=action,
                    action_input=action_input,
                    observation="error: unknown tool '" + action + "'"
                )
                self.history.append(react_step)
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
            self.history.append(react_step)
            
            step += 1
        
        # Max steps reached
        var error_result = Dict[String, String]()
        error_result["error"] = "max_steps_reached"
        error_result["steps"] = String(self.max_steps)
        return error_result
    
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
        inout self,
        inputs: Dict[String, String],
        tool_executor: fn(String, String) -> String = default_executor
    ) -> Dict[String, String]:
        """Alias for call()."""
        return self.call(inputs, tool_executor)


# ===----------------------------------------------------------------------=== #
# Tool Executor with Dispatch Table
# ===----------------------------------------------------------------------=== #

fn default_executor(tool_name: String, tool_input: String) -> String:
    """
    Default tool executor with dispatch table for common tools.
    
    Supports:
    - search: Web search via requests
    - calculate: Math evaluation (sandboxed)
    - lookup: Database/dictionary lookup
    - http: Generic HTTP request for MCP/API calls
    - datetime: Current date/time queries
    """
    try:
        # Search tool - web search via requests
        if tool_name == "search":
            return _execute_search(tool_input)
        
        # Calculator tool - safe math evaluation
        if tool_name == "calculate":
            return _execute_calculate(tool_input)
        
        # Lookup tool - dictionary/database lookup
        if tool_name == "lookup":
            return _execute_lookup(tool_input)
        
        # HTTP tool - generic API/MCP calls
        if tool_name == "http":
            return _execute_http(tool_input)
        
        # DateTime tool - current time queries
        if tool_name == "datetime":
            return _execute_datetime(tool_input)
        
        # Finish action (handled in ReAct.call)
        if tool_name == "finish":
            return tool_input
        
        # Unknown tool
        return "error:unknown_tool name:" + tool_name
        
    except e:
        return "error:executor_exception tool:" + tool_name + " message:" + str(e)


fn _execute_search(query: String) -> String:
    """Execute web search using DuckDuckGo HTML (no API key needed)."""
    try:
        var requests = Python.import_module("requests")
        var urllib = Python.import_module("urllib.parse")
        
        # Use DuckDuckGo HTML interface (no API key required)
        var encoded_query = urllib.quote_plus(query)
        var url = "https://html.duckduckgo.com/html/?q=" + str(encoded_query)
        
        var headers = {
            "User-Agent": "Mozilla/5.0 (compatible; ToonSPy/1.0; +https://sap.com)"
        }
        
        var response = requests.get(url, headers=headers, timeout=10)
        
        if response.status_code != 200:
            return "error:search_failed status:" + str(response.status_code)
        
        # Parse results from HTML (basic extraction)
        var html = str(response.text)
        
        # Extract result snippets (simplified - look for result class)
        var results = List[String]()
        var bs4 = Python.import_module("bs4")
        var soup = bs4.BeautifulSoup(html, "html.parser")
        
        var result_divs = soup.find_all("a", class_="result__snippet")
        for i in range(min(3, len(result_divs))):  # Top 3 results
            var text = str(result_divs[i].get_text(strip=True))
            if len(text) > 0:
                results.append(text)
        
        if len(results) == 0:
            return "results:~"
        
        # Format as TOON
        var result_str = String()
        for i in range(len(results)):
            if i > 0:
                result_str += "|"
            result_str += results[i]
        
        return "results:" + result_str
        
    except e:
        return "error:search_exception message:" + str(e)


fn _execute_calculate(expression: String) -> String:
    """Execute math calculation in a sandboxed scope."""
    try:
        var math_mod = Python.import_module("math")
        
        # Sanitize expression - only allow safe characters
        var safe_chars = "0123456789+-*/.() "
        var safe_funcs = ["sin", "cos", "tan", "sqrt", "abs", "pow", "log", "exp", "pi", "e"]
        
        var expr = expression
        
        # Check for unsafe content
        for c in expr:
            if c not in safe_chars:
                # Check if it's part of a safe function name
                var is_safe = False
                for func in safe_funcs:
                    if func in expr:
                        is_safe = True
                        break
                if not is_safe and c.isalpha():
                    return "error:unsafe_expression char:" + str(c)
        
        # Create safe namespace with only math functions
        var safe_namespace = {
            "sin": math_mod.sin,
            "cos": math_mod.cos,
            "tan": math_mod.tan,
            "sqrt": math_mod.sqrt,
            "abs": abs,
            "pow": pow,
            "log": math_mod.log,
            "exp": math_mod.exp,
            "pi": math_mod.pi,
            "e": math_mod.e,
        }
        
        # Evaluate expression
        var result = eval(expr, {"__builtins__": {}}, safe_namespace)
        
        return "result:" + str(result)
        
    except e:
        return "error:calculate_exception message:" + str(e)


fn _execute_lookup(key: String) -> String:
    """Execute lookup from a simple key-value store or API."""
    try:
        # Check for built-in knowledge base
        var knowledge_base = {
            "france_capital": "Paris",
            "germany_capital": "Berlin",
            "japan_capital": "Tokyo",
            "usa_capital": "Washington D.C.",
            "uk_capital": "London",
            "pi": "3.14159265359",
            "e": "2.71828182845",
            "speed_of_light": "299792458 m/s",
        }
        
        var normalized_key = key.lower().replace(" ", "_")
        
        if normalized_key in knowledge_base:
            return "value:" + knowledge_base[normalized_key]
        
        return "value:~"
        
    except e:
        return "error:lookup_exception message:" + str(e)


fn _execute_http(input_str: String) -> String:
    """Execute HTTP request for API/MCP tool calls."""
    try:
        var requests = Python.import_module("requests")
        var json_mod = Python.import_module("json")
        
        # Parse input: "method:url [body:json]"
        var parts = input_str.split(" ")
        if len(parts) < 2:
            return "error:invalid_http_input expected:method:url"
        
        var method_url = parts[0].split(":")
        if len(method_url) < 2:
            return "error:invalid_method_url"
        
        var method = method_url[0].upper()
        var url = ":".join(method_url[1:])  # Rejoin URL parts
        
        # Extract body if present
        var body = None
        for i in range(1, len(parts)):
            if parts[i].startswith("body:"):
                var body_json = parts[i][5:]
                body = json_mod.loads(body_json)
                break
        
        # Make request
        var response = None
        if method == "GET":
            response = requests.get(url, timeout=10)
        elif method == "POST":
            response = requests.post(url, json=body, timeout=10)
        elif method == "PUT":
            response = requests.put(url, json=body, timeout=10)
        elif method == "DELETE":
            response = requests.delete(url, timeout=10)
        else:
            return "error:unsupported_method method:" + method
        
        if response.status_code >= 400:
            return "error:http_error status:" + str(response.status_code)
        
        # Return response body
        var result = response.text
        if len(result) > 500:
            result = result[:500] + "...(truncated)"
        
        return "response:" + str(result)
        
    except e:
        return "error:http_exception message:" + str(e)


fn _execute_datetime(query: String) -> String:
    """Execute datetime queries."""
    try:
        var datetime_mod = Python.import_module("datetime")
        var now = datetime_mod.datetime.now()
        
        var q = query.lower()
        
        if "date" in q:
            return "date:" + str(now.strftime("%Y-%m-%d"))
        elif "time" in q:
            return "time:" + str(now.strftime("%H:%M:%S"))
        elif "year" in q:
            return "year:" + str(now.year)
        elif "month" in q:
            return "month:" + str(now.month)
        elif "day" in q:
            return "day:" + str(now.day)
        elif "weekday" in q:
            var weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            return "weekday:" + weekdays[now.weekday()]
        else:
            return "datetime:" + str(now.isoformat())
        
    except e:
        return "error:datetime_exception message:" + str(e)


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