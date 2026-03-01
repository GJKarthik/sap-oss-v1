"""
Model Registry - Mangle-Based Configuration

Day 8 Refactored: Loads model definitions from Mangle rules
- NO hardcoded OpenAI/Anthropic direct API access
- All models accessed via SAP AI Core or private vLLM
- Configuration loaded from rules/model_registry.mg

Usage:
    from routing.model_registry import ModelRegistry, get_model_registry
    
    registry = get_model_registry()
    model = registry.get_model("gpt-4")  # Via SAP AI Core
"""

import logging
import os
import re
from typing import Optional, Dict, Any, List, Set
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

logger = logging.getLogger(__name__)


# ========================================
# Provider Types - SAP AI Core & Private LLM ONLY
# ========================================

class ModelProvider(str, Enum):
    """
    Model providers - SAP AI Core and private deployments only.
    
    NO direct external API providers (OpenAI, Anthropic, etc.)
    All access goes through SAP AI Core proxy or private vLLM.
    """
    SAP_AI_CORE = "sap_ai_core"
    PRIVATE_LLM = "private_llm"
    VLLM = "vllm"


# ========================================
# Model Capabilities
# ========================================

class ModelCapability(str, Enum):
    """Capabilities that models can support."""
    CHAT = "chat"
    COMPLETION = "completion"
    EMBEDDING = "embedding"
    FUNCTION_CALLING = "function_calling"
    TOOL_USE = "tool_use"
    JSON_MODE = "json_mode"
    STREAMING = "streaming"


# ========================================
# Model Tiers
# ========================================

class ModelTier(str, Enum):
    """Model pricing/performance tiers."""
    PREMIUM = "premium"
    STANDARD = "standard"
    ECONOMY = "economy"


# ========================================
# Model Definition
# ========================================

@dataclass
class ModelDefinition:
    """
    Definition of a model available through SAP AI Core or private LLM.
    
    Loaded from Mangle rules/model_registry.mg facts.
    """
    id: str
    provider: ModelProvider
    backend_id: str
    display_name: str
    capabilities: Set[ModelCapability] = field(default_factory=set)
    tier: ModelTier = ModelTier.STANDARD
    context_window: int = 4096
    max_output_tokens: Optional[int] = None
    enabled: bool = True
    
    def supports(self, capability: ModelCapability) -> bool:
        """Check if model supports a capability."""
        return capability in self.capabilities
    
    def supports_all(self, capabilities: List[ModelCapability]) -> bool:
        """Check if model supports all given capabilities."""
        return all(c in self.capabilities for c in capabilities)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to OpenAI-compatible model object."""
        return {
            "id": self.id,
            "object": "model",
            "created": 0,
            "owned_by": self.provider.value,
        }
    
    def to_detailed_dict(self) -> Dict[str, Any]:
        """Convert to detailed model info."""
        return {
            **self.to_dict(),
            "display_name": self.display_name,
            "provider": self.provider.value,
            "capabilities": [c.value for c in self.capabilities],
            "context_window": self.context_window,
            "max_output_tokens": self.max_output_tokens,
            "tier": self.tier.value,
            "enabled": self.enabled,
        }


# ========================================
# Backend Definition
# ========================================

@dataclass
class BackendDefinition:
    """
    Backend configuration for SAP AI Core or private LLM.
    
    Base URL loaded dynamically from environment/config.
    """
    id: str
    provider: ModelProvider
    base_url: str = ""  # Loaded from env at runtime
    priority: int = 100
    timeout_ms: int = 60000
    streaming_support: bool = True
    enabled: bool = True


# ========================================
# Mangle Facts Parser
# ========================================

class MangleFactsLoader:
    """
    Loads model configuration from Mangle rules file.
    
    Parses extensional facts from rules/model_registry.mg
    """
    
    def __init__(self, rules_path: Optional[str] = None):
        if rules_path is None:
            # Default path relative to this module
            base_dir = Path(__file__).parent.parent
            rules_path = str(base_dir / "rules" / "model_registry.mg")
        self.rules_path = rules_path
        self._facts: Dict[str, List[tuple]] = {}
    
    def load(self) -> None:
        """Load and parse Mangle facts from rules file."""
        if not os.path.exists(self.rules_path):
            logger.warning(f"Mangle rules not found: {self.rules_path}")
            return
        
        with open(self.rules_path, 'r') as f:
            content = f.read()
        
        self._parse_facts(content)
    
    def _parse_facts(self, content: str) -> None:
        """Parse Mangle fact declarations."""
        # Pattern for simple facts: predicate("arg1", "arg2", ...).
        fact_pattern = re.compile(
            r'^(\w+)\(([^)]+)\)\.\s*$',
            re.MULTILINE
        )
        
        for match in fact_pattern.finditer(content):
            predicate = match.group(1)
            args_str = match.group(2)
            
            # Parse arguments
            args = self._parse_args(args_str)
            
            if predicate not in self._facts:
                self._facts[predicate] = []
            self._facts[predicate].append(tuple(args))
    
    def _parse_args(self, args_str: str) -> List[Any]:
        """Parse fact arguments."""
        args = []
        # Simple string parsing for quoted args
        current = ""
        in_string = False
        
        for char in args_str:
            if char == '"' and not in_string:
                in_string = True
            elif char == '"' and in_string:
                in_string = False
                args.append(current)
                current = ""
            elif char == ',' and not in_string:
                # Check if current is a number
                stripped = current.strip()
                if stripped and stripped.isdigit():
                    args.append(int(stripped))
                current = ""
            elif in_string or char not in ' \t':
                current += char
        
        # Handle last arg if number
        stripped = current.strip()
        if stripped and stripped.isdigit():
            args.append(int(stripped))
        
        return args
    
    def get_facts(self, predicate: str) -> List[tuple]:
        """Get all facts for a predicate."""
        return self._facts.get(predicate, [])
    
    def get_models(self) -> List[Dict[str, Any]]:
        """Get model definitions from facts."""
        models = []
        for fact in self.get_facts("model"):
            if len(fact) >= 4:
                models.append({
                    "id": fact[0],
                    "display_name": fact[1],
                    "provider": fact[2],
                    "backend_id": fact[3],
                })
        return models
    
    def get_backends(self) -> List[Dict[str, Any]]:
        """Get backend definitions from facts."""
        backends = []
        for fact in self.get_facts("backend"):
            if len(fact) >= 3:
                backends.append({
                    "id": fact[0],
                    "provider": fact[1],
                    "base_url": fact[2],
                })
        return backends
    
    def is_enabled(self, predicate: str, model_id: str) -> bool:
        """Check if a model is enabled."""
        for fact in self.get_facts(predicate):
            if len(fact) >= 1 and fact[0] == model_id:
                return True
        return False
    
    def get_capabilities(self, model_id: str) -> Set[str]:
        """Get capabilities for a model."""
        caps = set()
        for fact in self.get_facts("model_capability"):
            if len(fact) >= 2 and fact[0] == model_id:
                caps.add(fact[1])
        return caps
    
    def get_context_window(self, model_id: str) -> Optional[int]:
        """Get context window for a model."""
        for fact in self.get_facts("model_context_window"):
            if len(fact) >= 2 and fact[0] == model_id:
                return fact[1]
        return None
    
    def get_tier(self, model_id: str) -> Optional[str]:
        """Get tier for a model."""
        for fact in self.get_facts("model_tier"):
            if len(fact) >= 2 and fact[0] == model_id:
                return fact[1]
        return None
    
    def get_aliases(self) -> Dict[str, str]:
        """Get model aliases."""
        aliases = {}
        for fact in self.get_facts("model_alias"):
            if len(fact) >= 2:
                aliases[fact[0]] = fact[1]
        return aliases


# ========================================
# Model Registry
# ========================================

class ModelRegistry:
    """
    Registry of available models loaded from Mangle rules.
    
    All models are accessed through SAP AI Core or private vLLM.
    NO direct external API access.
    """
    
    def __init__(self, load_from_mangle: bool = True):
        self._models: Dict[str, ModelDefinition] = {}
        self._backends: Dict[str, BackendDefinition] = {}
        self._aliases: Dict[str, str] = {}
        
        if load_from_mangle:
            self._load_from_mangle()
        else:
            # Fallback to minimal defaults
            self._register_defaults()
    
    def _load_from_mangle(self) -> None:
        """Load configuration from Mangle rules."""
        loader = MangleFactsLoader()
        loader.load()
        
        # Register backends
        for backend_data in loader.get_backends():
            provider = self._parse_provider(backend_data["provider"])
            backend = BackendDefinition(
                id=backend_data["id"],
                provider=provider,
                base_url=self._get_backend_url(backend_data["id"]),
                enabled=loader.is_enabled("backend_enabled", backend_data["id"]),
            )
            self._backends[backend.id] = backend
        
        # Register models
        for model_data in loader.get_models():
            provider = self._parse_provider(model_data["provider"])
            capabilities = {
                self._parse_capability(c)
                for c in loader.get_capabilities(model_data["id"])
            }
            
            tier_str = loader.get_tier(model_data["id"])
            tier = ModelTier(tier_str) if tier_str else ModelTier.STANDARD
            
            model = ModelDefinition(
                id=model_data["id"],
                provider=provider,
                backend_id=model_data["backend_id"],
                display_name=model_data["display_name"],
                capabilities=capabilities,
                tier=tier,
                context_window=loader.get_context_window(model_data["id"]) or 4096,
                enabled=loader.is_enabled("model_enabled", model_data["id"]),
            )
            self._models[model.id] = model
        
        # Register aliases
        self._aliases = loader.get_aliases()
        
        logger.info(
            f"Loaded {len(self._models)} models and {len(self._backends)} backends from Mangle"
        )
    
    def _parse_provider(self, provider_str: str) -> ModelProvider:
        """Parse provider string to enum."""
        provider_map = {
            "sap_ai_core": ModelProvider.SAP_AI_CORE,
            "private_llm": ModelProvider.PRIVATE_LLM,
            "vllm": ModelProvider.VLLM,
        }
        return provider_map.get(provider_str, ModelProvider.SAP_AI_CORE)
    
    def _parse_capability(self, cap_str: str) -> ModelCapability:
        """Parse capability string to enum."""
        cap_map = {
            "chat": ModelCapability.CHAT,
            "completion": ModelCapability.COMPLETION,
            "embedding": ModelCapability.EMBEDDING,
            "function_calling": ModelCapability.FUNCTION_CALLING,
            "tool_use": ModelCapability.TOOL_USE,
            "json_mode": ModelCapability.JSON_MODE,
            "streaming": ModelCapability.STREAMING,
        }
        return cap_map.get(cap_str, ModelCapability.CHAT)
    
    def _get_backend_url(self, backend_id: str) -> str:
        """Get backend URL from environment."""
        # URLs loaded from environment, not hardcoded
        env_map = {
            "aicore_primary": "AICORE_BASE_URL",
            "vllm_primary": "VLLM_BASE_URL",
        }
        env_var = env_map.get(backend_id, f"{backend_id.upper()}_BASE_URL")
        return os.environ.get(env_var, "")
    
    def _register_defaults(self) -> None:
        """Register minimal defaults when Mangle rules not available."""
        # SAP AI Core backend
        self._backends["aicore_primary"] = BackendDefinition(
            id="aicore_primary",
            provider=ModelProvider.SAP_AI_CORE,
            base_url=os.environ.get("AICORE_BASE_URL", ""),
            priority=100,
        )
        
        # Private vLLM backend
        self._backends["vllm_primary"] = BackendDefinition(
            id="vllm_primary",
            provider=ModelProvider.VLLM,
            base_url=os.environ.get("VLLM_BASE_URL", ""),
            priority=90,
        )
        
        # Minimal model set via AI Core
        self._models["gpt-4"] = ModelDefinition(
            id="gpt-4",
            provider=ModelProvider.SAP_AI_CORE,
            backend_id="aicore_primary",
            display_name="GPT-4 via AI Core",
            capabilities={
                ModelCapability.CHAT,
                ModelCapability.FUNCTION_CALLING,
                ModelCapability.STREAMING,
            },
            tier=ModelTier.PREMIUM,
            context_window=8192,
        )
    
    def register_model(self, model: ModelDefinition) -> None:
        """Register a model."""
        self._models[model.id] = model
    
    def register_alias(self, alias: str, model_id: str) -> None:
        """Register a model alias."""
        self._aliases[alias] = model_id
    
    def resolve_alias(self, model_id: str) -> str:
        """Resolve model alias to canonical ID."""
        return self._aliases.get(model_id, model_id)
    
    def get_model(self, model_id: str) -> Optional[ModelDefinition]:
        """Get model by ID or alias."""
        canonical_id = self.resolve_alias(model_id)
        return self._models.get(canonical_id)
    
    def model_exists(self, model_id: str) -> bool:
        """Check if model exists."""
        canonical_id = self.resolve_alias(model_id)
        return canonical_id in self._models
    
    def list_models(
        self,
        enabled_only: bool = True,
    ) -> List[ModelDefinition]:
        """List all models."""
        models = list(self._models.values())
        if enabled_only:
            models = [m for m in models if m.enabled]
        return models
    
    def list_chat_models(self) -> List[ModelDefinition]:
        """List models with chat capability."""
        return [
            m for m in self.list_models()
            if m.supports(ModelCapability.CHAT)
        ]
    
    def list_embedding_models(self) -> List[ModelDefinition]:
        """List models with embedding capability."""
        return [
            m for m in self.list_models()
            if m.supports(ModelCapability.EMBEDDING)
        ]
    
    def get_backend(self, backend_id: str) -> Optional[BackendDefinition]:
        """Get backend by ID."""
        return self._backends.get(backend_id)
    
    def get_backend_for_model(
        self,
        model_id: str,
    ) -> Optional[BackendDefinition]:
        """Get backend for a model."""
        model = self.get_model(model_id)
        if not model:
            return None
        return self._backends.get(model.backend_id)


# ========================================
# Global Registry Instance
# ========================================

_registry: Optional[ModelRegistry] = None


def get_model_registry() -> ModelRegistry:
    """Get global model registry instance."""
    global _registry
    if _registry is None:
        _registry = ModelRegistry()
    return _registry


# ========================================
# Exports
# ========================================

__all__ = [
    "ModelProvider",
    "ModelCapability",
    "ModelTier",
    "ModelDefinition",
    "BackendDefinition",
    "ModelRegistry",
    "MangleFactsLoader",
    "get_model_registry",
]