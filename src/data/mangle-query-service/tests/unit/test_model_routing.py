"""
Unit Tests for Model Registry and Router

Day 8 Deliverable: Tests for model selection and routing
Target: >80% code coverage
"""

import pytest
import time
from unittest.mock import MagicMock, patch

from routing.model_registry import (
    ModelProvider,
    ModelCapability,
    ModelTier,
    ModelDefinition,
    BackendDefinition,
    ModelRegistry,
    get_model_registry,
)
from routing.model_router import (
    RoutingStrategy,
    BackendHealth,
    RoutingDecision,
    ModelRouter,
    get_model_router,
)


# ========================================
# ModelDefinition Tests
# ========================================

class TestModelDefinition:
    """Tests for ModelDefinition class."""
    
    def test_basic_creation(self):
        model = ModelDefinition(
            id="test-model",
            provider=ModelProvider.OPENAI,
            backend_id="test-backend",
            display_name="Test Model",
        )
        
        assert model.id == "test-model"
        assert model.provider == ModelProvider.OPENAI
        assert model.enabled is True
    
    def test_supports_capability(self):
        model = ModelDefinition(
            id="test-model",
            provider=ModelProvider.OPENAI,
            backend_id="test-backend",
            display_name="Test Model",
            capabilities={ModelCapability.CHAT, ModelCapability.STREAMING},
        )
        
        assert model.supports(ModelCapability.CHAT)
        assert model.supports(ModelCapability.STREAMING)
        assert not model.supports(ModelCapability.EMBEDDING)
    
    def test_supports_all_capabilities(self):
        model = ModelDefinition(
            id="test-model",
            provider=ModelProvider.OPENAI,
            backend_id="test-backend",
            display_name="Test Model",
            capabilities={ModelCapability.CHAT, ModelCapability.STREAMING},
        )
        
        assert model.supports_all([ModelCapability.CHAT, ModelCapability.STREAMING])
        assert not model.supports_all([ModelCapability.CHAT, ModelCapability.EMBEDDING])
    
    def test_to_dict(self):
        model = ModelDefinition(
            id="gpt-4",
            provider=ModelProvider.OPENAI,
            backend_id="gpt-4",
            display_name="GPT-4",
        )
        
        result = model.to_dict()
        
        assert result["id"] == "gpt-4"
        assert result["object"] == "model"
        assert result["owned_by"] == "openai"
    
    def test_to_detailed_dict(self):
        model = ModelDefinition(
            id="gpt-4",
            provider=ModelProvider.OPENAI,
            backend_id="gpt-4",
            display_name="GPT-4",
            tier=ModelTier.PREMIUM,
            context_window=8192,
        )
        
        result = model.to_detailed_dict()
        
        assert result["context_window"] == 8192
        assert result["tier"] == "premium"


# ========================================
# ModelRegistry Tests
# ========================================

class TestModelRegistry:
    """Tests for ModelRegistry class."""
    
    def test_default_models_registered(self):
        registry = ModelRegistry()
        
        # Should have default models
        assert registry.get_model("gpt-4") is not None
        assert registry.get_model("gpt-3.5-turbo") is not None
        assert registry.get_model("claude-3-opus") is not None
    
    def test_get_model_by_id(self):
        registry = ModelRegistry()
        
        model = registry.get_model("gpt-4")
        
        assert model is not None
        assert model.id == "gpt-4"
        assert model.provider == ModelProvider.OPENAI
    
    def test_get_model_by_alias(self):
        registry = ModelRegistry()
        
        model = registry.get_model("gpt-4-0613")
        
        assert model is not None
        assert model.id == "gpt-4"
    
    def test_get_model_not_found(self):
        registry = ModelRegistry()
        
        model = registry.get_model("nonexistent-model")
        
        assert model is None
    
    def test_register_custom_model(self):
        registry = ModelRegistry()
        
        custom = ModelDefinition(
            id="custom-model",
            provider=ModelProvider.LOCAL,
            backend_id="custom",
            display_name="Custom Model",
        )
        registry.register_model(custom)
        
        assert registry.get_model("custom-model") is not None
    
    def test_list_models(self):
        registry = ModelRegistry()
        
        models = registry.list_models()
        
        assert len(models) > 0
        assert all(m.enabled for m in models)
    
    def test_list_chat_models(self):
        registry = ModelRegistry()
        
        models = registry.list_chat_models()
        
        assert len(models) > 0
        assert all(m.supports(ModelCapability.CHAT) for m in models)
    
    def test_list_embedding_models(self):
        registry = ModelRegistry()
        
        models = registry.list_embedding_models()
        
        assert len(models) > 0
        assert all(m.supports(ModelCapability.EMBEDDING) for m in models)
    
    def test_model_exists(self):
        registry = ModelRegistry()
        
        assert registry.model_exists("gpt-4")
        assert not registry.model_exists("nonexistent")
    
    def test_resolve_alias(self):
        registry = ModelRegistry()
        
        assert registry.resolve_alias("gpt-4-0613") == "gpt-4"
        assert registry.resolve_alias("gpt-4") == "gpt-4"
    
    def test_get_backend_for_model(self):
        registry = ModelRegistry()
        
        backend = registry.get_backend_for_model("gpt-4")
        
        assert backend is not None
        assert backend.provider == ModelProvider.OPENAI


# ========================================
# BackendHealth Tests
# ========================================

class TestBackendHealth:
    """Tests for BackendHealth class."""
    
    def test_initial_healthy(self):
        health = BackendHealth(backend_id="test")
        
        assert health.healthy is True
        assert health.consecutive_failures == 0
    
    def test_mark_success(self):
        health = BackendHealth(backend_id="test")
        health.consecutive_failures = 2
        
        health.mark_success(latency_ms=100.0)
        
        assert health.healthy is True
        assert health.consecutive_failures == 0
        assert health.avg_latency_ms > 0
    
    def test_mark_failure(self):
        health = BackendHealth(backend_id="test")
        
        health.mark_failure()
        health.mark_failure()
        
        assert health.healthy is True
        assert health.consecutive_failures == 2
    
    def test_unhealthy_after_three_failures(self):
        health = BackendHealth(backend_id="test")
        
        health.mark_failure()
        health.mark_failure()
        health.mark_failure()
        
        assert health.healthy is False
        assert health.consecutive_failures == 3
    
    def test_latency_ema(self):
        health = BackendHealth(backend_id="test")
        
        health.mark_success(100.0)
        health.mark_success(200.0)
        
        # EMA should be weighted
        assert 0 < health.avg_latency_ms < 200
    
    def test_should_recheck(self):
        health = BackendHealth(backend_id="test")
        health.last_check = time.time() - 60
        
        assert health.should_recheck(interval=30.0)
        
        health.last_check = time.time()
        assert not health.should_recheck(interval=30.0)


# ========================================
# ModelRouter Tests
# ========================================

class TestModelRouter:
    """Tests for ModelRouter class."""
    
    def test_basic_routing(self):
        router = ModelRouter()
        
        decision = router.route("gpt-4")
        
        assert decision is not None
        assert decision.model.id == "gpt-4"
        assert decision.backend is not None
    
    def test_route_with_alias(self):
        router = ModelRouter()
        
        decision = router.route("gpt-4-0613")
        
        assert decision is not None
        assert decision.model.id == "gpt-4"
    
    def test_route_nonexistent_model(self):
        router = ModelRouter()
        
        decision = router.route("nonexistent")
        
        assert decision is None
    
    def test_route_chat(self):
        router = ModelRouter()
        
        decision = router.route_chat("gpt-4")
        
        assert decision is not None
        assert decision.model.supports(ModelCapability.CHAT)
    
    def test_route_embedding(self):
        router = ModelRouter()
        
        decision = router.route_embedding("text-embedding-3-small")
        
        assert decision is not None
        assert decision.model.supports(ModelCapability.EMBEDDING)
    
    def test_route_chat_fails_for_embedding_model(self):
        router = ModelRouter()
        
        decision = router.route_chat("text-embedding-3-small")
        
        assert decision is None
    
    def test_route_with_required_capabilities(self):
        router = ModelRouter()
        
        decision = router.route(
            "gpt-4",
            required_capabilities=[ModelCapability.CHAT, ModelCapability.STREAMING],
        )
        
        assert decision is not None
    
    def test_report_success(self):
        router = ModelRouter()
        
        router.report_success("openai", latency_ms=50.0)
        
        health = router.get_backend_health("openai")
        assert health.healthy
        assert health.avg_latency_ms > 0
    
    def test_report_failure(self):
        router = ModelRouter()
        
        router.report_failure("openai")
        
        health = router.get_backend_health("openai")
        assert health.consecutive_failures == 1
    
    def test_is_backend_healthy(self):
        router = ModelRouter()
        
        assert router.is_backend_healthy("openai")
        
        # Make unhealthy
        for _ in range(3):
            router.report_failure("openai")
        
        assert not router.is_backend_healthy("openai")


# ========================================
# Routing Strategy Tests
# ========================================

class TestRoutingStrategies:
    """Tests for different routing strategies."""
    
    def test_direct_strategy(self):
        router = ModelRouter(strategy=RoutingStrategy.DIRECT)
        
        decision = router.route("gpt-4")
        
        assert decision is not None
        assert decision.backend.provider == ModelProvider.OPENAI
    
    def test_failover_strategy(self):
        router = ModelRouter(strategy=RoutingStrategy.FAILOVER)
        
        decision = router.route("gpt-4")
        
        assert decision is not None
    
    def test_round_robin_strategy(self):
        router = ModelRouter(strategy=RoutingStrategy.ROUND_ROBIN)
        
        # Should not fail
        decision = router.route("gpt-4")
        
        assert decision is not None
    
    def test_weighted_strategy(self):
        router = ModelRouter(strategy=RoutingStrategy.WEIGHTED)
        
        decision = router.route("gpt-4")
        
        assert decision is not None


# ========================================
# Routing Decision Tests
# ========================================

class TestRoutingDecision:
    """Tests for RoutingDecision class."""
    
    def test_decision_has_backend_model_id(self):
        router = ModelRouter()
        
        decision = router.route("gpt-4-turbo")
        
        assert decision is not None
        # backend_model_id may differ from requested id
        assert decision.backend_model_id is not None
    
    def test_decision_has_metadata(self):
        router = ModelRouter()
        
        decision = router.route("gpt-4")
        
        assert "strategy" in decision.metadata


# ========================================
# Global Instance Tests
# ========================================

class TestGlobalInstances:
    """Tests for global singleton instances."""
    
    def test_get_model_registry(self):
        registry1 = get_model_registry()
        registry2 = get_model_registry()
        
        # Should be same instance
        assert registry1 is registry2
    
    def test_get_model_router(self):
        router1 = get_model_router()
        router2 = get_model_router()
        
        assert router1 is router2


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])