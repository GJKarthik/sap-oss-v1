# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Tests for Enhanced AI Core Client.

These tests cover both unit tests (with mocks) and integration tests
(with real AI Core when credentials are available).
"""

import asyncio
import json
import os
import time
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

# Import the modules to test
from hana_ai.aicore.enhanced_client import (
    AICoreConfig,
    CacheEntry,
    EnhancedAICoreClient,
    ModelCapability,
    ModelInfo,
    ModelRouter,
    ModelTier,
    RateLimiter,
    ResponseCache,
    RoutingStrategy,
    TokenBudget,
    TokenUsage,
)


class TestAICoreConfig(unittest.TestCase):
    """Tests for AICoreConfig."""
    
    def test_from_env_with_values(self):
        """Test loading config from environment."""
        with patch.dict(os.environ, {
            "AICORE_CLIENT_ID": "test-client-id",
            "AICORE_CLIENT_SECRET": "test-secret",
            "AICORE_AUTH_URL": "https://auth.test.com",
            "AICORE_BASE_URL": "https://api.test.com",
            "AICORE_RESOURCE_GROUP": "test-group",
            "AICORE_CACHE_ENABLED": "true",
            "AICORE_RATE_LIMIT_RPM": "120",
        }):
            config = AICoreConfig.from_env()
            
            self.assertEqual(config.client_id, "test-client-id")
            self.assertEqual(config.client_secret, "test-secret")
            self.assertEqual(config.auth_url, "https://auth.test.com")
            self.assertEqual(config.base_url, "https://api.test.com")
            self.assertEqual(config.resource_group, "test-group")
            self.assertTrue(config.cache_enabled)
            self.assertEqual(config.rate_limit_requests_per_minute, 120)
    
    def test_is_ready(self):
        """Test configuration readiness check."""
        config = AICoreConfig(
            client_id="id",
            client_secret="secret",
            auth_url="https://auth.test.com",
            base_url="https://api.test.com",
        )
        self.assertTrue(config.is_ready())
        
        # Missing base_url
        config_incomplete = AICoreConfig(
            client_id="id",
            client_secret="secret",
            auth_url="https://auth.test.com",
            base_url="",
        )
        self.assertFalse(config_incomplete.is_ready())


class TestTokenUsage(unittest.TestCase):
    """Tests for TokenUsage."""
    
    def test_add(self):
        """Test adding token usage."""
        usage1 = TokenUsage(prompt_tokens=100, completion_tokens=50, total_tokens=150)
        usage2 = TokenUsage(prompt_tokens=200, completion_tokens=100, total_tokens=300)
        
        combined = usage1.add(usage2)
        
        self.assertEqual(combined.prompt_tokens, 300)
        self.assertEqual(combined.completion_tokens, 150)
        self.assertEqual(combined.total_tokens, 450)


class TestTokenBudget(unittest.TestCase):
    """Tests for TokenBudget."""
    
    def test_check_budget_success(self):
        """Test budget check when within limits."""
        budget = TokenBudget(
            daily_limit=1000,
            hourly_limit=100,
            per_request_limit=50
        )
        
        ok, reason = budget.check_budget(30)
        self.assertTrue(ok)
        self.assertEqual(reason, "OK")
    
    def test_check_budget_exceeds_per_request(self):
        """Test budget check when exceeding per-request limit."""
        budget = TokenBudget(per_request_limit=50)
        
        ok, reason = budget.check_budget(100)
        self.assertFalse(ok)
        self.assertIn("per-request limit", reason)
    
    def test_record_usage(self):
        """Test recording token usage."""
        budget = TokenBudget(daily_limit=1000, hourly_limit=100)
        
        budget.record_usage(50)
        remaining = budget.get_remaining()
        
        self.assertEqual(remaining["daily"], 950)
        self.assertEqual(remaining["hourly"], 50)


class TestResponseCache(unittest.TestCase):
    """Tests for ResponseCache."""
    
    def test_cache_set_and_get(self):
        """Test setting and getting from cache."""
        cache = ResponseCache(max_size=10, ttl_seconds=3600)
        
        messages = [{"role": "user", "content": "Hello"}]
        model = "test-model"
        response = "Hello, how can I help?"
        usage = TokenUsage(total_tokens=10)
        
        cache.set(messages, model, response, usage)
        
        cached = cache.get(messages, model)
        
        self.assertIsNotNone(cached)
        self.assertEqual(cached.response, response)
        self.assertEqual(cached.model_id, model)
    
    def test_cache_miss(self):
        """Test cache miss."""
        cache = ResponseCache(max_size=10, ttl_seconds=3600)
        
        messages = [{"role": "user", "content": "Hello"}]
        
        cached = cache.get(messages, "nonexistent-model")
        
        self.assertIsNone(cached)
    
    def test_cache_expiration(self):
        """Test cache entry expiration."""
        cache = ResponseCache(max_size=10, ttl_seconds=1)  # 1 second TTL
        
        messages = [{"role": "user", "content": "Hello"}]
        model = "test-model"
        
        cache.set(messages, model, "response", TokenUsage())
        
        # Should hit
        self.assertIsNotNone(cache.get(messages, model))
        
        # Wait for expiration
        time.sleep(1.1)
        
        # Should miss (expired)
        self.assertIsNone(cache.get(messages, model))
    
    def test_cache_lru_eviction(self):
        """Test LRU eviction when cache is full."""
        cache = ResponseCache(max_size=2, ttl_seconds=3600)
        
        # Add 3 entries (should evict first)
        cache.set([{"role": "user", "content": "1"}], "m1", "r1", TokenUsage())
        cache.set([{"role": "user", "content": "2"}], "m2", "r2", TokenUsage())
        cache.set([{"role": "user", "content": "3"}], "m3", "r3", TokenUsage())
        
        # First should be evicted
        self.assertIsNone(cache.get([{"role": "user", "content": "1"}], "m1"))
        
        # Others should remain
        self.assertIsNotNone(cache.get([{"role": "user", "content": "2"}], "m2"))
        self.assertIsNotNone(cache.get([{"role": "user", "content": "3"}], "m3"))
    
    def test_cache_stats(self):
        """Test cache statistics."""
        cache = ResponseCache(max_size=10, ttl_seconds=3600)
        
        messages = [{"role": "user", "content": "Hello"}]
        cache.set(messages, "model", "response", TokenUsage())
        
        # Hit
        cache.get(messages, "model")
        # Miss
        cache.get([{"role": "user", "content": "Other"}], "model")
        
        stats = cache.get_stats()
        
        self.assertEqual(stats["hits"], 1)
        self.assertEqual(stats["misses"], 1)
        self.assertEqual(stats["hit_rate"], 0.5)


class TestRateLimiter(unittest.TestCase):
    """Tests for RateLimiter."""
    
    def test_acquire_within_limits(self):
        """Test acquiring tokens within limits."""
        limiter = RateLimiter(requests_per_minute=60, tokens_per_minute=10000)
        
        # Should not wait
        async def test():
            wait_time = await limiter.acquire(100)
            self.assertEqual(wait_time, 0.0)
        
        asyncio.run(test())
    
    def test_get_remaining(self):
        """Test getting remaining capacity."""
        limiter = RateLimiter(requests_per_minute=60, tokens_per_minute=10000)
        
        remaining = limiter.get_remaining()
        
        self.assertEqual(remaining["requests"], 60)
        self.assertEqual(remaining["tokens"], 10000)


class TestModelInfo(unittest.TestCase):
    """Tests for ModelInfo."""
    
    def test_from_deployment_anthropic(self):
        """Test creating ModelInfo from Anthropic deployment."""
        deployment = {
            "id": "d123",
            "status": "RUNNING",
            "details": {
                "resources": {
                    "backend_details": {
                        "model": {"name": "anthropic.claude-3-sonnet"}
                    }
                }
            }
        }
        
        model = ModelInfo.from_deployment(deployment)
        
        self.assertEqual(model.deployment_id, "d123")
        self.assertEqual(model.status, "RUNNING")
        self.assertTrue(model.is_anthropic)
        self.assertEqual(model.tier, ModelTier.PREMIUM)
        self.assertIn(ModelCapability.REASONING, model.capabilities)
    
    def test_from_deployment_embedding(self):
        """Test creating ModelInfo from embedding deployment."""
        deployment = {
            "id": "d456",
            "status": "RUNNING",
            "details": {
                "resources": {
                    "backend_details": {
                        "model": {"name": "text-embedding-ada-002"}
                    }
                }
            }
        }
        
        model = ModelInfo.from_deployment(deployment)
        
        self.assertEqual(model.deployment_id, "d456")
        self.assertFalse(model.is_anthropic)
        self.assertEqual(model.tier, ModelTier.ECONOMY)
        self.assertIn(ModelCapability.EMBEDDING, model.capabilities)


class TestModelRouter(unittest.TestCase):
    """Tests for ModelRouter."""
    
    def setUp(self):
        """Set up test models."""
        self.chat_model_economy = ModelInfo(
            deployment_id="chat-economy",
            model_name="gpt-3.5-turbo",
            status="RUNNING",
            capabilities=[ModelCapability.CHAT],
            tier=ModelTier.ECONOMY,
            cost_per_1k_tokens=0.001,
        )
        
        self.chat_model_premium = ModelInfo(
            deployment_id="chat-premium",
            model_name="claude-3-sonnet",
            status="RUNNING",
            capabilities=[ModelCapability.CHAT, ModelCapability.REASONING],
            tier=ModelTier.PREMIUM,
            cost_per_1k_tokens=0.01,
        )
        
        self.embed_model = ModelInfo(
            deployment_id="embed",
            model_name="text-embedding-ada-002",
            status="RUNNING",
            capabilities=[ModelCapability.EMBEDDING],
            tier=ModelTier.ECONOMY,
        )
    
    def test_select_model_by_capability(self):
        """Test selecting model by capability."""
        router = ModelRouter()
        router.register_model(self.chat_model_economy)
        router.register_model(self.embed_model)
        
        # Should find chat model
        chat = router.select_model(ModelCapability.CHAT)
        self.assertEqual(chat.deployment_id, "chat-economy")
        
        # Should find embedding model
        embed = router.select_model(ModelCapability.EMBEDDING)
        self.assertEqual(embed.deployment_id, "embed")
    
    def test_select_model_cost_optimized(self):
        """Test cost-optimized routing."""
        router = ModelRouter(strategy=RoutingStrategy.COST_OPTIMIZED)
        router.register_model(self.chat_model_economy)
        router.register_model(self.chat_model_premium)
        
        selected = router.select_model(ModelCapability.CHAT)
        
        # Should select cheaper model
        self.assertEqual(selected.deployment_id, "chat-economy")
    
    def test_select_model_quality_optimized(self):
        """Test quality-optimized routing."""
        router = ModelRouter(strategy=RoutingStrategy.QUALITY_OPTIMIZED)
        router.register_model(self.chat_model_economy)
        router.register_model(self.chat_model_premium)
        
        selected = router.select_model(ModelCapability.CHAT)
        
        # Should select premium model
        self.assertEqual(selected.deployment_id, "chat-premium")
    
    def test_select_model_prefer_tier(self):
        """Test preferring specific tier."""
        router = ModelRouter()
        router.register_model(self.chat_model_economy)
        router.register_model(self.chat_model_premium)
        
        selected = router.select_model(
            ModelCapability.CHAT,
            prefer_tier=ModelTier.PREMIUM
        )
        
        self.assertEqual(selected.deployment_id, "chat-premium")
    
    def test_no_suitable_model(self):
        """Test when no suitable model is available."""
        router = ModelRouter()
        router.register_model(self.embed_model)
        
        selected = router.select_model(ModelCapability.CHAT)
        
        self.assertIsNone(selected)


class TestEnhancedAICoreClientUnit(unittest.TestCase):
    """Unit tests for EnhancedAICoreClient (with mocks)."""
    
    def test_extract_content_anthropic(self):
        """Test extracting content from Anthropic response."""
        client = EnhancedAICoreClient(AICoreConfig(
            client_id="",
            client_secret="",
            auth_url="",
            base_url="",
        ))
        
        result = {"content": [{"text": "Hello from Claude"}]}
        content = client._extract_content(result, is_anthropic=True)
        
        self.assertEqual(content, "Hello from Claude")
    
    def test_extract_content_openai(self):
        """Test extracting content from OpenAI-style response."""
        client = EnhancedAICoreClient(AICoreConfig(
            client_id="",
            client_secret="",
            auth_url="",
            base_url="",
        ))
        
        result = {"choices": [{"message": {"content": "Hello from GPT"}}]}
        content = client._extract_content(result, is_anthropic=False)
        
        self.assertEqual(content, "Hello from GPT")
    
    def test_extract_usage(self):
        """Test extracting token usage."""
        client = EnhancedAICoreClient(AICoreConfig(
            client_id="",
            client_secret="",
            auth_url="",
            base_url="",
        ))
        
        # Anthropic style
        result_anthropic = {"usage": {"input_tokens": 100, "output_tokens": 50}}
        usage = client._extract_usage(result_anthropic)
        self.assertEqual(usage.prompt_tokens, 100)
        self.assertEqual(usage.completion_tokens, 50)
        
        # OpenAI style
        result_openai = {"usage": {"prompt_tokens": 200, "completion_tokens": 100, "total_tokens": 300}}
        usage = client._extract_usage(result_openai)
        self.assertEqual(usage.prompt_tokens, 200)
        self.assertEqual(usage.completion_tokens, 100)
        self.assertEqual(usage.total_tokens, 300)


class TestEnhancedAICoreClientIntegration(unittest.TestCase):
    """
    Integration tests for EnhancedAICoreClient.
    
    These tests require real AI Core credentials to run.
    Set AICORE_* environment variables to enable.
    """
    
    @classmethod
    def setUpClass(cls):
        """Check if AI Core credentials are available."""
        config = AICoreConfig.from_env()
        cls.skip_integration = not config.is_ready()
        
        if cls.skip_integration:
            print("\n⚠️  Skipping integration tests - AICORE_* env vars not set")
    
    def setUp(self):
        """Skip if no credentials."""
        if self.skip_integration:
            self.skipTest("AI Core credentials not available")
    
    def test_initialize_and_list_models(self):
        """Test initializing client and listing models."""
        async def run():
            client = EnhancedAICoreClient()
            await client.initialize()
            
            models = client.get_models()
            
            self.assertIsInstance(models, list)
            self.assertGreater(len(models), 0)
            
            for model in models:
                self.assertIsInstance(model, ModelInfo)
                self.assertIsNotNone(model.deployment_id)
                self.assertIsNotNone(model.model_name)
            
            print(f"\n✅ Found {len(models)} AI Core deployments:")
            for m in models:
                print(f"   - {m.deployment_id}: {m.model_name} ({m.tier.value})")
        
        asyncio.run(run())
    
    def test_chat_completion(self):
        """Test chat completion with real AI Core."""
        async def run():
            client = EnhancedAICoreClient()
            await client.initialize()
            
            response = await client.chat(
                "What is 2 + 2? Reply with just the number.",
                max_tokens=10
            )
            
            self.assertIn("content", response)
            self.assertIn("model", response)
            self.assertIn("usage", response)
            self.assertIn("4", response["content"])
            
            print(f"\n✅ Chat response: {response['content'][:100]}")
            print(f"   Model: {response['model']}")
            print(f"   Usage: {response['usage']}")
        
        asyncio.run(run())
    
    def test_chat_with_cache(self):
        """Test chat completion caching."""
        async def run():
            client = EnhancedAICoreClient()
            await client.initialize()
            
            question = "What color is the sky? Reply in one word."
            
            # First request (cache miss)
            response1 = await client.chat(question, max_tokens=10)
            self.assertFalse(response1.get("cached", False))
            
            # Second request (cache hit)
            response2 = await client.chat(question, max_tokens=10)
            self.assertTrue(response2.get("cached", False))
            
            # Same content
            self.assertEqual(response1["content"], response2["content"])
            
            print(f"\n✅ Cache test passed")
            print(f"   First request: {response1['latency_ms']:.1f}ms (not cached)")
            print(f"   Second request: cached")
        
        asyncio.run(run())
    
    def test_chat_with_routing_strategies(self):
        """Test different routing strategies."""
        async def run():
            client = EnhancedAICoreClient()
            await client.initialize()
            
            # Skip if only one model
            if len(client.get_models()) < 2:
                print("\n⚠️  Skipping routing test - need 2+ models")
                return
            
            for strategy in [RoutingStrategy.COST_OPTIMIZED, RoutingStrategy.QUALITY_OPTIMIZED]:
                response = await client.chat(
                    "Say hello.",
                    routing_strategy=strategy,
                    max_tokens=10,
                    use_cache=False  # Ensure fresh request
                )
                print(f"\n✅ {strategy.value}: Used model {response['model']}")
        
        asyncio.run(run())
    
    def test_embeddings(self):
        """Test embedding generation."""
        async def run():
            client = EnhancedAICoreClient()
            await client.initialize()
            
            # Check if embedding model exists
            embed_model = client.router.select_model(ModelCapability.EMBEDDING)
            if not embed_model:
                print("\n⚠️  Skipping embedding test - no embedding model")
                return
            
            result = await client.embed(["Hello world", "Goodbye world"])
            
            self.assertIn("embeddings", result)
            self.assertEqual(len(result["embeddings"]), 2)
            self.assertIsInstance(result["embeddings"][0], list)
            self.assertGreater(len(result["embeddings"][0]), 100)  # Typically 1536 dims
            
            print(f"\n✅ Generated embeddings:")
            print(f"   Count: {len(result['embeddings'])}")
            print(f"   Dimensions: {len(result['embeddings'][0])}")
            print(f"   Model: {result['model']}")
        
        asyncio.run(run())
    
    def test_get_stats(self):
        """Test getting client statistics."""
        async def run():
            client = EnhancedAICoreClient()
            await client.initialize()
            
            # Make a request to generate some stats
            await client.chat("Hello", max_tokens=10)
            
            stats = client.get_stats()
            
            self.assertIn("total_usage", stats)
            self.assertIn("budget_remaining", stats)
            self.assertIn("rate_limit_remaining", stats)
            self.assertIn("cache_stats", stats)
            self.assertIn("models", stats)
            
            print(f"\n✅ Client stats: {json.dumps(stats, indent=2)}")
        
        asyncio.run(run())


if __name__ == "__main__":
    unittest.main(verbosity=2)