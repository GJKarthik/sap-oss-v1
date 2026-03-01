"""
Model Router for Backend Selection

Day 8 Deliverable: Routing logic for model requests
- Backend selection based on model
- Load balancing
- Fallback handling
- Health-aware routing

Usage:
    from routing.model_router import ModelRouter
    
    router = ModelRouter()
    backend = router.route_request("gpt-4")
"""

import logging
import random
import time
from typing import Optional, Dict, Any, List
from dataclasses import dataclass, field
from enum import Enum

from routing.model_registry import (
    ModelRegistry,
    ModelDefinition,
    BackendDefinition,
    ModelCapability,
    ModelTier,
    get_model_registry,
)

logger = logging.getLogger(__name__)


# ========================================
# Routing Strategy
# ========================================

class RoutingStrategy(str, Enum):
    """Backend selection strategies."""
    DIRECT = "direct"  # Route to model's provider
    ROUND_ROBIN = "round_robin"  # Rotate among backends
    WEIGHTED = "weighted"  # Weight by priority
    LATENCY = "latency"  # Route to lowest latency
    COST = "cost"  # Route to lowest cost
    FAILOVER = "failover"  # Primary with fallback


# ========================================
# Backend Health
# ========================================

@dataclass
class BackendHealth:
    """Health status of a backend."""
    backend_id: str
    healthy: bool = True
    last_check: float = field(default_factory=time.time)
    consecutive_failures: int = 0
    avg_latency_ms: float = 0.0
    error_rate: float = 0.0
    
    def mark_success(self, latency_ms: float) -> None:
        """Mark a successful request."""
        self.healthy = True
        self.consecutive_failures = 0
        # Exponential moving average for latency
        self.avg_latency_ms = 0.9 * self.avg_latency_ms + 0.1 * latency_ms
        self.last_check = time.time()
    
    def mark_failure(self) -> None:
        """Mark a failed request."""
        self.consecutive_failures += 1
        if self.consecutive_failures >= 3:
            self.healthy = False
        self.last_check = time.time()
    
    def should_recheck(self, interval: float = 30.0) -> bool:
        """Check if health should be rechecked."""
        return time.time() - self.last_check > interval


# ========================================
# Routing Decision
# ========================================

@dataclass
class RoutingDecision:
    """Result of routing decision."""
    model: ModelDefinition
    backend: BackendDefinition
    backend_model_id: str  # ID to use with backend
    fallback_backends: List[BackendDefinition] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)


# ========================================
# Model Router
# ========================================

class ModelRouter:
    """
    Routes model requests to appropriate backends.
    
    Responsibilities:
    - Validate model availability
    - Select backend based on strategy
    - Track backend health
    - Provide fallback options
    """
    
    def __init__(
        self,
        registry: Optional[ModelRegistry] = None,
        strategy: RoutingStrategy = RoutingStrategy.DIRECT,
    ):
        self.registry = registry or get_model_registry()
        self.strategy = strategy
        self._health: Dict[str, BackendHealth] = {}
        self._round_robin_idx: Dict[str, int] = {}
    
    def route(
        self,
        model_id: str,
        required_capabilities: Optional[List[ModelCapability]] = None,
    ) -> Optional[RoutingDecision]:
        """
        Route a request to appropriate backend.
        
        Args:
            model_id: Requested model ID
            required_capabilities: Required model capabilities
        
        Returns:
            Routing decision or None if model not found
        """
        # Resolve alias and get model
        model = self.registry.get_model(model_id)
        if not model:
            logger.warning(f"Model not found: {model_id}")
            return None
        
        # Check capabilities
        if required_capabilities:
            for cap in required_capabilities:
                if not model.supports(cap):
                    logger.warning(
                        f"Model {model_id} missing capability: {cap.value}"
                    )
                    return None
        
        # Check if enabled
        if not model.enabled:
            logger.warning(f"Model disabled: {model_id}")
            return None
        
        # Select backend
        backend = self._select_backend(model)
        if not backend:
            logger.error(f"No backend available for model: {model_id}")
            return None
        
        # Get fallbacks
        fallbacks = self._get_fallback_backends(model, backend)
        
        return RoutingDecision(
            model=model,
            backend=backend,
            backend_model_id=model.backend_id,
            fallback_backends=fallbacks,
            metadata={
                "strategy": self.strategy.value,
                "resolved_from": model_id if model_id != model.id else None,
            },
        )
    
    def route_chat(self, model_id: str) -> Optional[RoutingDecision]:
        """Route a chat completion request."""
        return self.route(
            model_id,
            required_capabilities=[ModelCapability.CHAT],
        )
    
    def route_embedding(self, model_id: str) -> Optional[RoutingDecision]:
        """Route an embedding request."""
        return self.route(
            model_id,
            required_capabilities=[ModelCapability.EMBEDDING],
        )
    
    def _select_backend(
        self,
        model: ModelDefinition,
    ) -> Optional[BackendDefinition]:
        """Select backend based on strategy."""
        if self.strategy == RoutingStrategy.DIRECT:
            return self._select_direct(model)
        elif self.strategy == RoutingStrategy.ROUND_ROBIN:
            return self._select_round_robin(model)
        elif self.strategy == RoutingStrategy.WEIGHTED:
            return self._select_weighted(model)
        elif self.strategy == RoutingStrategy.LATENCY:
            return self._select_lowest_latency(model)
        elif self.strategy == RoutingStrategy.FAILOVER:
            return self._select_failover(model)
        else:
            return self._select_direct(model)
    
    def _select_direct(
        self,
        model: ModelDefinition,
    ) -> Optional[BackendDefinition]:
        """Select backend directly by provider."""
        return self.registry.get_backend_for_model(model.id)
    
    def _select_round_robin(
        self,
        model: ModelDefinition,
    ) -> Optional[BackendDefinition]:
        """Select backend using round-robin."""
        candidates = self._get_healthy_backends(model)
        if not candidates:
            return self._select_direct(model)
        
        key = model.provider.value
        idx = self._round_robin_idx.get(key, 0)
        backend = candidates[idx % len(candidates)]
        self._round_robin_idx[key] = idx + 1
        
        return backend
    
    def _select_weighted(
        self,
        model: ModelDefinition,
    ) -> Optional[BackendDefinition]:
        """Select backend by priority weight."""
        candidates = self._get_healthy_backends(model)
        if not candidates:
            return self._select_direct(model)
        
        # Weight by priority
        total_weight = sum(b.priority for b in candidates)
        if total_weight == 0:
            return random.choice(candidates)
        
        r = random.uniform(0, total_weight)
        cumulative = 0
        for backend in candidates:
            cumulative += backend.priority
            if r <= cumulative:
                return backend
        
        return candidates[-1]
    
    def _select_lowest_latency(
        self,
        model: ModelDefinition,
    ) -> Optional[BackendDefinition]:
        """Select backend with lowest latency."""
        candidates = self._get_healthy_backends(model)
        if not candidates:
            return self._select_direct(model)
        
        # Sort by latency
        def get_latency(b: BackendDefinition) -> float:
            health = self._health.get(b.id)
            return health.avg_latency_ms if health else float("inf")
        
        return min(candidates, key=get_latency)
    
    def _select_failover(
        self,
        model: ModelDefinition,
    ) -> Optional[BackendDefinition]:
        """Select primary backend with failover."""
        # Get primary (highest priority)
        candidates = self._get_healthy_backends(model)
        if not candidates:
            return self._select_direct(model)
        
        return max(candidates, key=lambda b: b.priority)
    
    def _get_healthy_backends(
        self,
        model: ModelDefinition,
    ) -> List[BackendDefinition]:
        """Get healthy backends for a model's provider."""
        candidates = []
        
        for backend in self.registry._backends.values():
            if backend.provider != model.provider:
                continue
            if not backend.enabled:
                continue
            
            # Check health
            health = self._get_health(backend.id)
            if health.healthy:
                candidates.append(backend)
        
        return candidates
    
    def _get_fallback_backends(
        self,
        model: ModelDefinition,
        primary: BackendDefinition,
    ) -> List[BackendDefinition]:
        """Get fallback backends in priority order."""
        fallbacks = []
        
        for backend in self.registry._backends.values():
            if backend.id == primary.id:
                continue
            if backend.provider != model.provider:
                continue
            if not backend.enabled:
                continue
            
            fallbacks.append(backend)
        
        return sorted(fallbacks, key=lambda b: -b.priority)
    
    def _get_health(self, backend_id: str) -> BackendHealth:
        """Get or create health tracker for backend."""
        if backend_id not in self._health:
            self._health[backend_id] = BackendHealth(backend_id=backend_id)
        return self._health[backend_id]
    
    def report_success(
        self,
        backend_id: str,
        latency_ms: float,
    ) -> None:
        """Report successful request to backend."""
        health = self._get_health(backend_id)
        health.mark_success(latency_ms)
    
    def report_failure(self, backend_id: str) -> None:
        """Report failed request to backend."""
        health = self._get_health(backend_id)
        health.mark_failure()
    
    def get_backend_health(self, backend_id: str) -> BackendHealth:
        """Get health status for a backend."""
        return self._get_health(backend_id)
    
    def is_backend_healthy(self, backend_id: str) -> bool:
        """Check if backend is healthy."""
        return self._get_health(backend_id).healthy


# ========================================
# Routing __init__.py
# ========================================

_router: Optional[ModelRouter] = None


def get_model_router() -> ModelRouter:
    """Get global model router instance."""
    global _router
    if _router is None:
        _router = ModelRouter()
    return _router


# ========================================
# Exports
# ========================================

__all__ = [
    "RoutingStrategy",
    "BackendHealth",
    "RoutingDecision",
    "ModelRouter",
    "get_model_router",
]