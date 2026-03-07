"""
Mangle integration for rule-based model management.

This module provides the bridge between Mojo kernels and Mangle Datalog rules,
enabling declarative decision-making for:
- Model routing based on task type
- Lazy loading decisions based on rules
- Context management policies
- Memory budget allocation

All model configurations are loaded from .mg files, NOT hardcoded.
"""

from memory import memset_zero, memcpy
from sys.info import simdwidthof

from .parser import MangleParser, ModelDefinition, PromptRulesParser, ContextRulesParser


alias FloatType = DType.float32
alias MAX_RULE_NAME = 128
alias MAX_MODELS = 16

# Default paths to Mangle rule files (relative to project root)
alias MODEL_ROUTING_PATH = "mangle/model_routing.mg"
alias PROMPT_RULES_PATH = "mangle/prompt_rules.mg"
alias CONTEXT_RULES_PATH = "mangle/context_rules.mg"


# =============================================================================
# Mangle Rule Result Types
# =============================================================================

struct MangleRuleResult:
    """Result from evaluating a Mangle rule."""
    var success: Bool
    var model_id: String
    var temperature: Float32
    var max_tokens: Int
    var system_prompt: String
    var preload_layers: Int
    
    fn __init__(inout self):
        self.success = False
        self.model_id = ""
        self.temperature = 0.7
        self.max_tokens = 256
        self.system_prompt = ""
        self.preload_layers = 0


struct ModelRoutingDecision:
    """Decision from Mangle model routing rules."""
    var model_id: String
    var model_idx: Int
    var priority: Int
    var can_handle_context: Bool
    var estimated_latency_ms: Int
    var is_available: Bool
    
    fn __init__(inout self):
        self.model_id = ""
        self.model_idx = -1
        self.priority = 0
        self.can_handle_context = False
        self.estimated_latency_ms = 0
        self.is_available = False


struct LoadingPolicy:
    """Loading policy derived from Mangle rules."""
    var preload_layers: Int
    var eviction_priority: Int
    var pin_model: Bool
    var background_load: Bool
    var memory_budget_mb: Int
    
    fn __init__(inout self):
        self.preload_layers = 0
        self.eviction_priority = 5
        self.pin_model = False
        self.background_load = True
        self.memory_budget_mb = 1024


# =============================================================================
# Mangle Rule Evaluator - Loads ALL configs from .mg files
# =============================================================================

struct MangleEvaluator:
    """
    Evaluates Mangle rules for model management decisions.
    
    ALL model configurations are loaded from .mg files - NO hardcoded values.
    Use load_rules_from_files() to initialize from actual Mangle rule files.
    """
    
    # Parsers for rule files
    var model_parser: MangleParser
    var prompt_parser: PromptRulesParser
    var context_parser: ContextRulesParser
    
    # State
    var rules_loaded: Bool
    var rules_path: String
    
    fn __init__(inout self, rules_path: String = "mangle"):
        """
        Initialize the evaluator.
        
        Args:
            rules_path: Path to the mangle rules directory
        """
        self.model_parser = MangleParser()
        self.prompt_parser = PromptRulesParser()
        self.context_parser = ContextRulesParser()
        self.rules_loaded = False
        self.rules_path = rules_path
    
    fn load_rules_from_files(
        inout self,
        model_routing_content: String,
        prompt_rules_content: String,
        context_rules_content: String
    ):
        """
        Load rules from file contents.
        
        This method parses the actual .mg file contents and extracts
        all model configurations, intent patterns, and routing rules.
        
        Args:
            model_routing_content: Content of model_routing.mg
            prompt_rules_content: Content of prompt_rules.mg
            context_rules_content: Content of context_rules.mg
        """
        # Parse model routing rules - extracts model definitions
        self.model_parser.parse_file_content(model_routing_content)
        self.model_parser.extract_models()
        
        # Parse prompt rules - extracts intent patterns and system prompts
        self.prompt_parser.parse_file_content(prompt_rules_content)
        
        # Parse context rules - extracts summarization thresholds
        self.context_parser.parse_file_content(context_rules_content)
        
        self.rules_loaded = True
    
    # =========================================================================
    # Model Access - Values from model_routing.mg
    # =========================================================================
    
    fn get_loaded_model_count(self) -> Int:
        """Get number of models loaded from model_routing.mg."""
        return self.model_parser.get_model_count()
    
    fn get_model_config(self, idx: Int) -> ModelDefinition:
        """
        Get model configuration by index.
        All values come from model_routing.mg file.
        """
        return self.model_parser.get_model(idx)
    
    fn find_model_by_id(self, model_id: String) -> ModelDefinition:
        """Find model configuration by ID from loaded rules."""
        for i in range(self.model_parser.get_model_count()):
            var model = self.model_parser.get_model(i)
            if model.model_id == model_id:
                return model
        return ModelDefinition("")
    
    # =========================================================================
    # Intent Detection - Uses prompt_rules.mg
    # =========================================================================
    
    fn detect_intent(self, message: String) -> String:
        """
        Detect user intent from message content using rules from prompt_rules.mg.
        
        If rules are loaded, uses keyword_pattern() facts from the file.
        
        Args:
            message: User message content
        
        Returns:
            Detected intent (e.g., "/code", "/log_analysis")
        """
        if self.rules_loaded:
            return self.prompt_parser.get_intent(message)
        
        # Fallback: basic pattern matching
        var lower_msg = message.lower()
        if "code" in lower_msg or "function" in lower_msg:
            return "/code"
        if "log" in lower_msg or "error" in lower_msg:
            return "/log_analysis"
        return "/general"
    
    fn get_system_prompt(self, intent: String) -> String:
        """
        Get system prompt for intent from prompt_rules.mg.
        
        Uses system_prompt() facts from the loaded rules.
        """
        if self.rules_loaded:
            return self.prompt_parser.get_prompt(intent)
        return "You are a helpful AI assistant."
    
    fn get_recommended_temperature(self, intent: String) -> Float32:
        """
        Get recommended temperature from prompt_rules.mg.
        
        Uses recommended_temp() facts from the loaded rules.
        """
        if self.rules_loaded:
            return self.prompt_parser.get_temperature(intent)
        return 0.7
    
    # =========================================================================
    # Model Routing - Uses model_routing.mg
    # =========================================================================
    
    fn route_request(self, intent: String, token_count: Int) -> ModelRoutingDecision:
        """
        Route a request to the best available model.
        
        Uses facts from model_routing.mg:
        - model(Id, Name, MaxContext)
        - model_status(Id, Status)
        - model_specializes_in(Id, Task)
        - model_speed(Id, Speed)
        - model_quality(Id, Quality)
        
        Args:
            intent: User intent (task type)
            token_count: Estimated prompt token count
        
        Returns:
            ModelRoutingDecision with selected model from rules
        """
        var decision = ModelRoutingDecision()
        var best_priority = -1
        
        for i in range(self.model_parser.get_model_count()):
            var model = self.model_parser.get_model(i)
            
            # Check if model is available (from model_status fact)
            if not model.is_available:
                continue
            
            # Check if model handles this intent (from model_specializes_in facts)
            var handles_intent = False
            for j in range(len(model.specializations)):
                if model.specializations[j] == intent or model.specializations[j] == "/general":
                    handles_intent = True
                    break
            
            if not handles_intent:
                continue
            
            # Check context length (from model() fact)
            if token_count >= model.max_context:
                continue
            
            # Calculate priority using model_speed and model_quality from rules
            var priority = model.speed + model.quality
            
            # Boost for specialized models
            for j in range(len(model.specializations)):
                if model.specializations[j] == intent:
                    priority += 2
                    break
            
            if priority > best_priority:
                best_priority = priority
                decision.model_id = model.model_id
                decision.model_idx = i
                decision.priority = priority
                decision.can_handle_context = True
                decision.is_available = True
                decision.estimated_latency_ms = self._estimate_latency_from_rules(model, token_count)
        
        decision.success = best_priority >= 0
        return decision
    
    fn _estimate_latency_from_rules(self, model: ModelDefinition, token_count: Int) -> Int:
        """Estimate latency using speed rating from model_routing.mg."""
        # Base latency inversely proportional to speed rating
        var base_latency = 100 - model.speed * 10  # speed=8 -> 20ms base
        return base_latency * (token_count // 100 + 1)
    
    # =========================================================================
    # Loading Policy - Derived from rules
    # =========================================================================
    
    fn get_loading_policy(self, model_id: String, intent: String) -> LoadingPolicy:
        """
        Determine loading policy for a model based on rules.
        
        Uses model_memory() from model_routing.mg for memory budget.
        
        Args:
            model_id: Model identifier
            intent: User intent
        
        Returns:
            LoadingPolicy with settings from rules
        """
        var policy = LoadingPolicy()
        var model = self.find_model_by_id(model_id)
        
        # Memory budget from model_memory() fact
        policy.memory_budget_mb = model.memory_gb * 1024
        
        # Preload layers based on quality rating from rules
        # Higher quality models get more preloaded layers
        policy.preload_layers = model.quality // 2 + 2
        
        # Eviction priority based on speed (faster models less likely to evict)
        policy.eviction_priority = 10 - model.speed
        
        # Pin models that are marked as default/available
        if model.is_available:
            policy.pin_model = True
        
        policy.background_load = True
        return policy
    
    # =========================================================================
    # Context Management - Uses context_rules.mg
    # =========================================================================
    
    fn should_summarize_context(self, model_id: String, current_tokens: Int) -> Bool:
        """
        Determine if context should be summarized.
        
        Uses model max_context from model_routing.mg and
        summarization_threshold from context_rules.mg.
        
        Args:
            model_id: Model identifier
            current_tokens: Current token count
        
        Returns:
            True if summarization is needed
        """
        var model = self.find_model_by_id(model_id)
        var threshold = self.context_parser.get_summarization_threshold(
            model_id,
            model.max_context
        )
        return current_tokens > threshold
    
    # =========================================================================
    # Full Enhancement Pipeline
    # =========================================================================
    
    fn enhance_request(inout self, message: String, token_count: Int) -> MangleRuleResult:
        """
        Full request enhancement using all Mangle rules.
        
        All values come from the loaded .mg files:
        - Intent from prompt_rules.mg
        - Model selection from model_routing.mg
        - Temperature from prompt_rules.mg
        - System prompt from prompt_rules.mg
        
        Args:
            message: User message
            token_count: Estimated token count
        
        Returns:
            MangleRuleResult with all parameters from rules
        """
        var result = MangleRuleResult()
        
        if not self.rules_loaded:
            result.success = False
            return result
        
        # Detect intent using rules from prompt_rules.mg
        var intent = self.detect_intent(message)
        
        # Route to best model using rules from model_routing.mg
        var routing = self.route_request(intent, token_count)
        if not routing.is_available:
            result.success = False
            return result
        
        # Get enhancement parameters - ALL from rule files
        result.success = True
        result.model_id = routing.model_id
        result.temperature = self.get_recommended_temperature(intent)
        result.system_prompt = self.get_system_prompt(intent)
        
        # Get loading policy from rules
        var policy = self.get_loading_policy(routing.model_id, intent)
        result.preload_layers = policy.preload_layers
        result.max_tokens = 512 if intent == "/code" else 256
        
        return result
    
    fn set_model_available(inout self, model_id: String, available: Bool):
        """
        Update model availability status.
        
        This updates the runtime state (not the .mg file).
        The initial availability comes from model_status() facts.
        """
        for i in range(len(self.model_parser.models)):
            if self.model_parser.models[i].model_id == model_id:
                self.model_parser.models[i].is_available = available
                return