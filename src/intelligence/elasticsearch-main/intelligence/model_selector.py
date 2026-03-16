"""
Adaptive Model Selector for Mangle Query Service.

Selects the optimal LLM model based on query characteristics,
cost constraints, and historical performance data.
"""

import asyncio
import hashlib
import os
from typing import Any, Dict, List, Optional, Tuple
from dataclasses import dataclass
from datetime import datetime
import json

# Configuration
ENABLE_MODEL_SELECTION = os.getenv("ENABLE_MODEL_SELECTION", "true").lower() == "true"
DEFAULT_MODEL = os.getenv("DEFAULT_MODEL", "gpt-4")
FAST_MODEL = os.getenv("FAST_MODEL", "gpt-3.5-turbo")
PREMIUM_MODEL = os.getenv("PREMIUM_MODEL", "gpt-4-turbo")


@dataclass
class ModelProfile:
    """Profile for an LLM model."""
    name: str
    tier: str  # "fast", "standard", "premium"
    cost_per_1k_tokens: float
    avg_latency_ms: float
    strength_categories: List[str]
    max_context_length: int
    supports_streaming: bool = True


# Model registry with profiles
MODEL_PROFILES: Dict[str, ModelProfile] = {
    "gpt-3.5-turbo": ModelProfile(
        name="gpt-3.5-turbo",
        tier="fast",
        cost_per_1k_tokens=0.0015,
        avg_latency_ms=300,
        strength_categories=["factual", "simple", "cache_miss"],
        max_context_length=16384,
    ),
    "gpt-4": ModelProfile(
        name="gpt-4",
        tier="standard",
        cost_per_1k_tokens=0.03,
        avg_latency_ms=800,
        strength_categories=["analytical", "knowledge", "reasoning"],
        max_context_length=8192,
    ),
    "gpt-4-turbo": ModelProfile(
        name="gpt-4-turbo",
        tier="premium",
        cost_per_1k_tokens=0.01,
        avg_latency_ms=500,
        strength_categories=["analytical", "knowledge", "complex", "long_context"],
        max_context_length=128000,
    ),
    "claude-3-sonnet": ModelProfile(
        name="claude-3-sonnet",
        tier="standard",
        cost_per_1k_tokens=0.015,
        avg_latency_ms=600,
        strength_categories=["knowledge", "reasoning", "safety"],
        max_context_length=200000,
    ),
    "claude-3-opus": ModelProfile(
        name="claude-3-opus",
        tier="premium",
        cost_per_1k_tokens=0.075,
        avg_latency_ms=1200,
        strength_categories=["complex", "reasoning", "safety", "analysis"],
        max_context_length=200000,
    ),
}


@dataclass
class SelectionResult:
    """Result of model selection."""
    model: str
    reason: str
    confidence: float
    alternatives: List[str]
    estimated_cost: float
    estimated_latency_ms: float


class AdaptiveModelSelector:
    """
    Select optimal model based on query characteristics and constraints.
    
    Considers:
    - Query complexity (token count, nested structure)
    - Classification category (analytical, factual, knowledge)
    - Cost constraints (per-request budget)
    - Latency requirements (SLA targets)
    - Historical performance for similar queries
    """
    
    def __init__(
        self,
        default_model: str = DEFAULT_MODEL,
        fast_model: str = FAST_MODEL,
        premium_model: str = PREMIUM_MODEL,
    ):
        self.default_model = default_model
        self.fast_model = fast_model
        self.premium_model = premium_model
        
        # Performance tracking
        self.model_performance: Dict[str, Dict[str, float]] = {}
        
        # Stats
        self.stats = {
            "selections": 0,
            "upgrades": 0,
            "downgrades": 0,
        }
    
    async def select_model(
        self,
        query: str,
        classification: Dict[str, Any],
        messages: List[Dict[str, Any]],
        constraints: Optional[Dict[str, Any]] = None,
    ) -> SelectionResult:
        """
        Select optimal model for the query.
        
        Args:
            query: User query text
            classification: Query classification result
            messages: Full message history
            constraints: Optional constraints (max_cost, max_latency_ms, prefer_tier)
            
        Returns:
            SelectionResult with selected model and reasoning
        """
        if not ENABLE_MODEL_SELECTION:
            return SelectionResult(
                model=self.default_model,
                reason="Model selection disabled",
                confidence=100,
                alternatives=[],
                estimated_cost=0,
                estimated_latency_ms=0,
            )
        
        self.stats["selections"] += 1
        constraints = constraints or {}
        
        # Analyze query characteristics
        complexity = self._analyze_complexity(query, messages, classification)
        
        # Get category from classification
        category = classification.get("category", "llm_required")
        if hasattr(category, "value"):
            category = category.value
        
        # Initial model selection based on category
        initial_model = self._select_by_category(category)
        
        # Adjust based on complexity
        adjusted_model = self._adjust_for_complexity(initial_model, complexity)
        
        # Apply constraints
        final_model = self._apply_constraints(adjusted_model, constraints, complexity)
        
        # Track upgrades/downgrades
        if final_model != initial_model:
            if self._get_tier_rank(final_model) > self._get_tier_rank(initial_model):
                self.stats["upgrades"] += 1
            else:
                self.stats["downgrades"] += 1
        
        # Get profile for cost/latency estimates
        profile = MODEL_PROFILES.get(final_model, MODEL_PROFILES.get(self.default_model))
        
        # Estimate tokens
        estimated_tokens = self._estimate_tokens(query, messages)
        
        return SelectionResult(
            model=final_model,
            reason=self._build_reason(category, complexity, constraints, initial_model, final_model),
            confidence=complexity.get("confidence", 75),
            alternatives=self._get_alternatives(final_model, constraints),
            estimated_cost=(estimated_tokens / 1000) * profile.cost_per_1k_tokens if profile else 0,
            estimated_latency_ms=profile.avg_latency_ms if profile else 500,
        )
    
    def _analyze_complexity(
        self,
        query: str,
        messages: List[Dict[str, Any]],
        classification: Dict[str, Any],
    ) -> Dict[str, Any]:
        """Analyze query complexity for model selection."""
        # Token estimation (rough: 4 chars per token)
        query_tokens = len(query) // 4
        message_tokens = sum(len(str(m.get("content", ""))) // 4 for m in messages)
        total_tokens = query_tokens + message_tokens
        
        # Complexity indicators
        has_aggregation = any(kw in query.lower() for kw in ["total", "sum", "average", "count", "group"])
        has_comparison = any(kw in query.lower() for kw in ["compare", "difference", "vs", "versus"])
        has_explanation = any(kw in query.lower() for kw in ["explain", "why", "how", "describe"])
        has_multiple_entities = len(classification.get("entities", [])) > 1
        
        # Compute complexity score (0-100)
        complexity_score = 30  # Base
        
        if total_tokens > 2000:
            complexity_score += 20
        elif total_tokens > 500:
            complexity_score += 10
        
        if has_aggregation:
            complexity_score += 10
        if has_comparison:
            complexity_score += 15
        if has_explanation:
            complexity_score += 15
        if has_multiple_entities:
            complexity_score += 10
        
        # Classification confidence affects complexity
        confidence = classification.get("confidence", 50)
        if confidence < 60:
            complexity_score += 15  # Ambiguous queries are harder
        
        return {
            "score": min(100, complexity_score),
            "total_tokens": total_tokens,
            "has_aggregation": has_aggregation,
            "has_comparison": has_comparison,
            "has_explanation": has_explanation,
            "has_multiple_entities": has_multiple_entities,
            "confidence": confidence,
        }
    
    def _select_by_category(self, category: str) -> str:
        """Select initial model based on query category."""
        # Map categories to appropriate models
        category_models = {
            "analytical": self.default_model,  # Need reasoning
            "factual": self.fast_model,  # Simple lookup
            "knowledge": self.default_model,  # Need knowledge
            "hierarchy": self.fast_model,  # Structured data
            "timeseries": self.default_model,  # Analysis needed
            "metadata": self.fast_model,  # Simple
            "llm_required": self.default_model,
            "cache": self.fast_model,  # Won't be used anyway
        }
        
        return category_models.get(category, self.default_model)
    
    def _adjust_for_complexity(self, model: str, complexity: Dict[str, Any]) -> str:
        """Adjust model selection based on complexity score."""
        score = complexity.get("score", 50)
        
        # High complexity: upgrade to premium
        if score >= 75:
            return self.premium_model
        
        # Medium-high complexity: use standard
        if score >= 50:
            return self.default_model
        
        # Low complexity: can use fast model
        if score < 35:
            return self.fast_model
        
        return model
    
    def _apply_constraints(
        self,
        model: str,
        constraints: Dict[str, Any],
        complexity: Dict[str, Any],
    ) -> str:
        """Apply user constraints to model selection."""
        # Explicit model override
        if "model" in constraints:
            return constraints["model"]
        
        # Tier preference
        prefer_tier = constraints.get("prefer_tier")
        if prefer_tier:
            return self._get_model_for_tier(prefer_tier)
        
        # Max cost constraint
        max_cost = constraints.get("max_cost")
        if max_cost is not None:
            profile = MODEL_PROFILES.get(model)
            if profile:
                estimated_tokens = complexity.get("total_tokens", 500)
                estimated_cost = (estimated_tokens / 1000) * profile.cost_per_1k_tokens
                
                if estimated_cost > max_cost:
                    # Downgrade to cheaper model
                    return self._find_cheaper_model(max_cost, estimated_tokens)
        
        # Max latency constraint
        max_latency = constraints.get("max_latency_ms")
        if max_latency is not None:
            profile = MODEL_PROFILES.get(model)
            if profile and profile.avg_latency_ms > max_latency:
                # Downgrade to faster model
                return self.fast_model
        
        return model
    
    def _get_model_for_tier(self, tier: str) -> str:
        """Get the default model for a tier."""
        tier_models = {
            "fast": self.fast_model,
            "standard": self.default_model,
            "premium": self.premium_model,
        }
        return tier_models.get(tier, self.default_model)
    
    def _find_cheaper_model(self, max_cost: float, estimated_tokens: int) -> str:
        """Find a model that fits within cost budget."""
        # Sort models by cost
        affordable = []
        for name, profile in MODEL_PROFILES.items():
            cost = (estimated_tokens / 1000) * profile.cost_per_1k_tokens
            if cost <= max_cost:
                affordable.append((name, cost, profile.tier))
        
        if not affordable:
            return self.fast_model  # Cheapest option
        
        # Return the most capable affordable model
        tier_rank = {"fast": 0, "standard": 1, "premium": 2}
        affordable.sort(key=lambda x: tier_rank.get(x[2], 0), reverse=True)
        return affordable[0][0]
    
    def _get_tier_rank(self, model: str) -> int:
        """Get numeric tier rank for comparison."""
        profile = MODEL_PROFILES.get(model)
        if not profile:
            return 1
        
        tier_ranks = {"fast": 0, "standard": 1, "premium": 2}
        return tier_ranks.get(profile.tier, 1)
    
    def _get_alternatives(self, selected: str, constraints: Dict[str, Any]) -> List[str]:
        """Get alternative model suggestions."""
        alternatives = []
        selected_profile = MODEL_PROFILES.get(selected)
        
        if not selected_profile:
            return []
        
        for name, profile in MODEL_PROFILES.items():
            if name != selected:
                # Suggest alternatives from adjacent tiers
                tier_diff = abs(self._get_tier_rank(name) - self._get_tier_rank(selected))
                if tier_diff <= 1:
                    alternatives.append(name)
        
        return alternatives[:2]  # Max 2 alternatives
    
    def _estimate_tokens(self, query: str, messages: List[Dict[str, Any]]) -> int:
        """Estimate total tokens for the request."""
        query_tokens = len(query) // 4
        message_tokens = sum(len(str(m.get("content", ""))) // 4 for m in messages)
        completion_estimate = 500  # Assume ~500 token response
        
        return query_tokens + message_tokens + completion_estimate
    
    def _build_reason(
        self,
        category: str,
        complexity: Dict[str, Any],
        constraints: Dict[str, Any],
        initial: str,
        final: str,
    ) -> str:
        """Build human-readable reason for selection."""
        parts = [f"Category: {category}"]
        
        score = complexity.get("score", 50)
        parts.append(f"Complexity: {score}/100")
        
        if complexity.get("has_aggregation"):
            parts.append("aggregation query")
        if complexity.get("has_explanation"):
            parts.append("explanation needed")
        
        if final != initial:
            if self._get_tier_rank(final) > self._get_tier_rank(initial):
                parts.append(f"upgraded from {initial}")
            else:
                parts.append(f"downgraded from {initial}")
        
        if constraints.get("max_cost"):
            parts.append(f"cost limit: ${constraints['max_cost']}")
        
        return " | ".join(parts)
    
    def get_stats(self) -> Dict[str, Any]:
        """Get model selection statistics."""
        return {
            **self.stats,
            "upgrade_rate": (
                self.stats["upgrades"] / self.stats["selections"] * 100
                if self.stats["selections"] > 0 else 0
            ),
            "downgrade_rate": (
                self.stats["downgrades"] / self.stats["selections"] * 100
                if self.stats["selections"] > 0 else 0
            ),
        }


# Singleton instance
_selector: Optional[AdaptiveModelSelector] = None
_selector_lock = asyncio.Lock()


async def get_model_selector() -> AdaptiveModelSelector:
    """Get or create the model selector singleton."""
    global _selector
    
    async with _selector_lock:
        if _selector is None:
            _selector = AdaptiveModelSelector()
        return _selector