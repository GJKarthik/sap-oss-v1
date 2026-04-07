"""
Mangle file parser for loading rules from .mg files.

Parses Datalog-style Mangle rules and extracts:
- Model definitions
- Model capabilities
- Speed/quality/memory ratings
- Context length limits
- Routing rules
"""

from memory import memset_zero, memcpy


alias MAX_LINE_LEN = 1024
alias MAX_FACTS = 500
alias MAX_ARGS = 5


# =============================================================================
# Parsed Fact Representation
# =============================================================================

struct MangleFact:
    """Represents a parsed Mangle fact/predicate."""
    var predicate: String
    var args: List[String]
    var num_args: Int
    
    fn __init__(inout self, predicate: String):
        self.predicate = predicate
        self.args = List[String]()
        self.num_args = 0
    
    fn add_arg(inout self, arg: String):
        self.args.append(arg)
        self.num_args += 1
    
    fn get_arg(self, idx: Int) -> String:
        if idx < self.num_args:
            return self.args[idx]
        return ""


struct ModelDefinition:
    """Parsed model definition from Mangle rules."""
    var model_id: String
    var display_name: String
    var max_context: Int
    var speed: Int
    var quality: Int
    var memory_gb: Int
    var is_available: Bool
    var specializations: List[String]
    var cost_per_1k: Int
    
    fn __init__(inout self, model_id: String):
        self.model_id = model_id
        self.display_name = model_id
        self.max_context = 4096
        self.speed = 5
        self.quality = 5
        self.memory_gb = 4
        self.is_available = False
        self.specializations = List[String]()
        self.cost_per_1k = 1


# =============================================================================
# Mangle File Parser
# =============================================================================

struct MangleParser:
    """Parses Mangle .mg files and extracts facts."""
    
    var facts: List[MangleFact]
    var models: List[ModelDefinition]
    var parse_errors: List[String]
    
    fn __init__(inout self):
        self.facts = List[MangleFact]()
        self.models = List[ModelDefinition]()
        self.parse_errors = List[String]()
    
    fn parse_file_content(inout self, content: String):
        """
        Parse Mangle file content and extract facts.
        
        Args:
            content: Full content of a .mg file
        """
        var lines = content.split("\n")
        
        for i in range(len(lines)):
            var line = lines[i].strip()
            
            # Skip empty lines and comments
            if len(line) == 0 or line.startswith("#"):
                continue
            
            # Skip rule definitions (lines with :-)
            if ":-" in line:
                continue
            
            # Parse fact (lines ending with .)
            if line.endswith("."):
                self._parse_fact(line)
    
    fn _parse_fact(inout self, line: String):
        """
        Parse a single Mangle fact.
        
        Format: predicate(arg1, arg2, ...).
        """
        # Guard against empty or too short lines
        if len(line) < 2:
            return
        
        # Remove trailing period
        var fact_str = line[:-1].strip()
        
        # Guard against empty result after stripping
        if len(fact_str) == 0:
            return
        
        # Find predicate name
        var paren_idx = fact_str.find("(")
        if paren_idx < 0:
            return  # Invalid format
        
        # Validate closing paren exists
        if not fact_str.endswith(")"):
            return  # Malformed - missing closing parenthesis
        
        var predicate = fact_str[:paren_idx].strip()
        
        # Guard against empty predicate name
        if len(predicate) == 0:
            return
        
        # Extract arguments - safely slice between ( and )
        var args_str = fact_str[paren_idx + 1:-1]  # Remove ( and )
        var args = args_str.split(",")
        
        var fact = MangleFact(predicate)
        for j in range(len(args)):
            var arg = args[j].strip()
            # Remove quotes if present
            if arg.startswith('"') and arg.endswith('"'):
                arg = arg[1:-1]
            fact.add_arg(arg)
        
        self.facts.append(fact^)
    
    fn extract_models(inout self):
        """
        Extract model definitions from parsed facts.
        
        Looks for:
        - model(ModelId, Name, MaxContext)
        - model_status(ModelId, Status)
        - model_speed(ModelId, Speed)
        - model_quality(ModelId, Quality)
        - model_memory(ModelId, Memory)
        - model_specializes_in(ModelId, Task)
        - cost_per_1k(ModelId, Cost)
        """
        # First pass: create model entries from model() facts
        for i in range(len(self.facts)):
            var fact = self.facts[i]
            if fact.predicate == "model" and fact.num_args >= 3:
                var model_id = fact.get_arg(0)
                var model = ModelDefinition(model_id)
                model.display_name = fact.get_arg(1)
                model.max_context = self._parse_int(fact.get_arg(2))
                self.models.append(model^)
        
        # Second pass: enrich with additional facts
        for i in range(len(self.facts)):
            var fact = self.facts[i]
            var model_id = fact.get_arg(0) if fact.num_args > 0 else ""
            
            if fact.predicate == "model_status" and fact.num_args >= 2:
                var model = self._find_model(model_id)
                if model:
                    model[].is_available = fact.get_arg(1) == "/available"
            
            elif fact.predicate == "model_speed" and fact.num_args >= 2:
                var model = self._find_model(model_id)
                if model:
                    model[].speed = self._parse_int(fact.get_arg(1))
            
            elif fact.predicate == "model_quality" and fact.num_args >= 2:
                var model = self._find_model(model_id)
                if model:
                    model[].quality = self._parse_int(fact.get_arg(1))
            
            elif fact.predicate == "model_memory" and fact.num_args >= 2:
                var model = self._find_model(model_id)
                if model:
                    model[].memory_gb = self._parse_int(fact.get_arg(1))
            
            elif fact.predicate == "model_specializes_in" and fact.num_args >= 2:
                var model = self._find_model(model_id)
                if model:
                    model[].specializations.append(fact.get_arg(1))
            
            elif fact.predicate == "cost_per_1k" and fact.num_args >= 2:
                var model = self._find_model(model_id)
                if model:
                    model[].cost_per_1k = self._parse_int(fact.get_arg(1))
    
    fn _find_model(inout self, model_id: String) -> UnsafePointer[ModelDefinition]:
        """Find a model by ID."""
        for i in range(len(self.models)):
            if self.models[i].model_id == model_id:
                return UnsafePointer.address_of(self.models[i])
        return UnsafePointer[ModelDefinition]()
    
    fn _parse_int(self, s: String) -> Int:
        """Parse an integer from string."""
        try:
            return int(s)
        except:
            return 0
    
    fn get_model_count(self) -> Int:
        """Get number of parsed models."""
        return len(self.models)
    
    fn get_model(self, idx: Int) -> ModelDefinition:
        """Get model by index."""
        if idx < len(self.models):
            return self.models[idx]
        return ModelDefinition("")


# =============================================================================
# Rule Extractor for Intent/Prompt Rules
# =============================================================================

struct IntentRule:
    """Parsed intent detection rule."""
    var pattern: String
    var intent: String
    
    fn __init__(inout self, pattern: String, intent: String):
        self.pattern = pattern
        self.intent = intent


struct PromptRule:
    """Parsed system prompt rule."""
    var intent: String
    var prompt: String
    var temperature: Float32
    
    fn __init__(inout self, intent: String, prompt: String, temp: Float32):
        self.intent = intent
        self.prompt = prompt
        self.temperature = temp


struct PromptRulesParser:
    """Parser for prompt_rules.mg"""
    
    var intent_rules: List[IntentRule]
    var prompt_rules: List[PromptRule]
    
    fn __init__(inout self):
        self.intent_rules = List[IntentRule]()
        self.prompt_rules = List[PromptRule]()
    
    fn parse_file_content(inout self, content: String):
        """Parse prompt rules from file content."""
        var lines = content.split("\n")
        
        for i in range(len(lines)):
            var line = lines[i].strip()
            
            if len(line) == 0 or line.startswith("#"):
                continue
            
            if ":-" in line:
                continue
            
            if not line.endswith("."):
                continue
            
            # Guard against too short lines
            if len(line) < 2:
                continue
            
            var fact_str = line[:-1].strip()
            
            # Guard against empty result
            if len(fact_str) == 0:
                continue
            
            # Parse keyword_pattern(Pattern, Intent)
            if fact_str.startswith("keyword_pattern("):
                self._parse_keyword_pattern(fact_str)
            
            # Parse system_prompt(Intent, Prompt)
            elif fact_str.startswith("system_prompt("):
                self._parse_system_prompt(fact_str)
            
            # Parse recommended_temp(Intent, Temp)
            elif fact_str.startswith("recommended_temp("):
                self._parse_temperature(fact_str)
    
    fn _parse_keyword_pattern(inout self, fact_str: String):
        """Parse keyword_pattern(Pattern, Intent)."""
        # Validate minimum length and closing paren
        if len(fact_str) < 18 or not fact_str.endswith(")"):
            return
        var content = fact_str[16:-1]  # Remove "keyword_pattern(" and ")"
        var parts = content.split(",")
        if len(parts) >= 2:
            var pattern = parts[0].strip().strip('"')
            var intent = parts[1].strip()
            self.intent_rules.append(IntentRule(pattern, intent))
    
    fn _parse_system_prompt(inout self, fact_str: String):
        """Parse system_prompt(Intent, Prompt)."""
        # Validate minimum length and closing paren
        if len(fact_str) < 16 or not fact_str.endswith(")"):
            return
        # Find the first comma after the intent
        var content = fact_str[14:-1]  # Remove "system_prompt(" and ")"
        var comma_idx = content.find(",")
        if comma_idx > 0:
            var intent = content[:comma_idx].strip()
            var prompt = content[comma_idx + 1:].strip().strip('"')
            
            # Find existing rule or create new
            var found = False
            for i in range(len(self.prompt_rules)):
                if self.prompt_rules[i].intent == intent:
                    self.prompt_rules[i].prompt = prompt
                    found = True
                    break
            
            if not found:
                self.prompt_rules.append(PromptRule(intent, prompt, 0.7))
    
    fn _parse_temperature(inout self, fact_str: String):
        """Parse recommended_temp(Intent, Temp)."""
        # Validate minimum length and closing paren
        if len(fact_str) < 18 or not fact_str.endswith(")"):
            return
        var content = fact_str[16:-1]  # Remove "recommended_temp(" and ")"
        var parts = content.split(",")
        if len(parts) >= 2:
            var intent = parts[0].strip()
            var temp_str = parts[1].strip()
            var temp = self._parse_float(temp_str)
            
            # Update existing rule
            for i in range(len(self.prompt_rules)):
                if self.prompt_rules[i].intent == intent:
                    self.prompt_rules[i].temperature = temp
                    return
            
            # Create new rule with temperature
            self.prompt_rules.append(PromptRule(intent, "", temp))
    
    fn _parse_float(self, s: String) -> Float32:
        """Parse float from string."""
        try:
            return Float32(float(s))
        except:
            return 0.7
    
    fn get_intent(self, message: String) -> String:
        """Match message against intent rules."""
        var lower_msg = message.lower()
        
        for i in range(len(self.intent_rules)):
            if self.intent_rules[i].pattern.lower() in lower_msg:
                return self.intent_rules[i].intent
        
        return "/general"
    
    fn get_prompt(self, intent: String) -> String:
        """Get system prompt for intent."""
        for i in range(len(self.prompt_rules)):
            if self.prompt_rules[i].intent == intent:
                return self.prompt_rules[i].prompt
        return "You are a helpful AI assistant."
    
    fn get_temperature(self, intent: String) -> Float32:
        """Get temperature for intent."""
        for i in range(len(self.prompt_rules)):
            if self.prompt_rules[i].intent == intent:
                return self.prompt_rules[i].temperature
        return 0.7


# =============================================================================
# Context Rules Parser
# =============================================================================

struct ContextRule:
    """Parsed context management rule."""
    var model_id: String
    var threshold_pct: Int
    
    fn __init__(inout self, model_id: String, threshold: Int):
        self.model_id = model_id
        self.threshold_pct = threshold


struct ContextRulesParser:
    """Parser for context_rules.mg"""
    
    var summarization_thresholds: List[ContextRule]
    var message_priorities: List[MangleFact]
    
    fn __init__(inout self):
        self.summarization_thresholds = List[ContextRule]()
        self.message_priorities = List[MangleFact]()
    
    fn parse_file_content(inout self, content: String):
        """Parse context rules from file content."""
        var lines = content.split("\n")
        
        for i in range(len(lines)):
            var line = lines[i].strip()
            
            if len(line) == 0 or line.startswith("#") or ":-" in line:
                continue
            
            if not line.endswith("."):
                continue
            
            var fact_str = line[:-1].strip()
            
            if fact_str.startswith("summarization_threshold("):
                self._parse_threshold(fact_str)
    
    fn _parse_threshold(inout self, fact_str: String):
        """Parse summarization_threshold(Model, Percent)."""
        # Validate minimum length and closing paren
        if len(fact_str) < 26 or not fact_str.endswith(")"):
            return
        var content = fact_str[24:-1]  # Remove "summarization_threshold(" and ")"
        var parts = content.split(",")
        if len(parts) >= 2:
            var model_id = parts[0].strip()
            var threshold = int(parts[1].strip())
            self.summarization_thresholds.append(ContextRule(model_id, threshold))
    
    fn get_summarization_threshold(self, model_id: String, max_context: Int) -> Int:
        """Get summarization threshold for a model."""
        for i in range(len(self.summarization_thresholds)):
            if self.summarization_thresholds[i].model_id == model_id:
                return max_context * self.summarization_thresholds[i].threshold_pct // 100
        return max_context * 80 // 100  # Default 80%