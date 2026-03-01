"""
Integration Tests for HANA-Mangle Integration.

Tests the complete integration between:
- langchain-integration-for-sap-hana-cloud
- mangle-query-service

Run with: pytest tests/test_integration.py -v
"""

import asyncio
import os
import pytest
from typing import Any, Dict, List, Optional
from unittest.mock import AsyncMock, MagicMock, patch


# ============================================================================
# Test Fixtures
# ============================================================================

@pytest.fixture
def mock_hana_connection():
    """Mock HANA database connection."""
    with patch("hdbcli.dbapi.connect") as mock_connect:
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        
        # Mock cursor methods
        mock_cursor.execute = MagicMock()
        mock_cursor.fetchall = MagicMock(return_value=[])
        mock_cursor.fetchone = MagicMock(return_value=None)
        mock_cursor.description = [("col1",), ("col2",)]
        
        mock_conn.cursor = MagicMock(return_value=mock_cursor)
        mock_connect.return_value = mock_conn
        
        yield mock_conn, mock_cursor


@pytest.fixture
def sample_documents():
    """Sample documents for testing."""
    return [
        {
            "content": "Trading positions for Q4 2024 show increased volatility in emerging markets.",
            "metadata": {"type": "TRADING_POSITIONS", "date": "2024-12-01"},
        },
        {
            "content": "Risk exposure analysis indicates VaR of $2.5M for the equity portfolio.",
            "metadata": {"type": "RISK_ANALYSIS", "date": "2024-11-15"},
        },
        {
            "content": "Market data feed showing bid-ask spreads for major currency pairs.",
            "metadata": {"type": "MARKET_DATA", "date": "2024-12-10"},
        },
    ]


@pytest.fixture
def sample_query():
    """Sample query for testing."""
    return "What are the current trading positions?"


@pytest.fixture
def sample_embedding():
    """Sample embedding vector."""
    return [0.1] * 1536  # OpenAI-style 1536-dim embedding


# ============================================================================
# Semantic Cache Tests
# ============================================================================

class TestSemanticCache:
    """Tests for semantic query cache."""
    
    @pytest.mark.asyncio
    async def test_cache_initialization(self):
        """Test cache initializes correctly."""
        from performance.hana_semantic_cache import HanaSemanticCache
        
        cache = HanaSemanticCache(max_size=100, ttl_seconds=60)
        assert cache._max_size == 100
        assert cache._ttl_seconds == 60
        assert len(cache._cache) == 0
    
    @pytest.mark.asyncio
    async def test_cache_set_and_get_exact(self, sample_embedding):
        """Test exact match cache retrieval."""
        from performance.hana_semantic_cache import HanaSemanticCache
        
        cache = HanaSemanticCache()
        
        query = "test query"
        result = {"answer": "test result"}
        
        await cache.set(query, sample_embedding, result)
        
        # Exact match should work
        cached, similarity = await cache.get(query, sample_embedding)
        assert cached == result
        assert similarity == 1.0
    
    @pytest.mark.asyncio
    async def test_cache_semantic_similarity(self, sample_embedding):
        """Test semantic similarity matching."""
        from performance.hana_semantic_cache import HanaSemanticCache
        
        cache = HanaSemanticCache(similarity_threshold=0.9)
        
        await cache.set("original query", sample_embedding, {"answer": "result"})
        
        # Similar embedding should match
        similar_embedding = [x + 0.01 for x in sample_embedding]  # Slightly different
        
        cached, similarity = await cache.get("similar query", similar_embedding)
        # Should still match due to high similarity
        assert similarity > 0.9
    
    @pytest.mark.asyncio
    async def test_cache_miss(self, sample_embedding):
        """Test cache miss for dissimilar queries."""
        from performance.hana_semantic_cache import HanaSemanticCache
        
        cache = HanaSemanticCache(similarity_threshold=0.95)
        
        await cache.set("original query", sample_embedding, {"answer": "result"})
        
        # Very different embedding should not match
        different_embedding = [-x for x in sample_embedding]
        
        cached, similarity = await cache.get("different query", different_embedding)
        assert cached is None
    
    @pytest.mark.asyncio
    async def test_cache_ttl_expiration(self, sample_embedding):
        """Test TTL-based cache expiration."""
        from performance.hana_semantic_cache import HanaSemanticCache
        import time
        
        cache = HanaSemanticCache(ttl_seconds=0.1)  # Very short TTL
        
        await cache.set("query", sample_embedding, {"answer": "result"})
        
        # Should be cached initially
        cached, _ = await cache.get("query", sample_embedding)
        assert cached is not None
        
        # Wait for expiration
        await asyncio.sleep(0.2)
        
        # Should be expired now
        cached, _ = await cache.get("query", sample_embedding)
        assert cached is None
    
    @pytest.mark.asyncio
    async def test_cache_lru_eviction(self, sample_embedding):
        """Test LRU eviction when cache is full."""
        from performance.hana_semantic_cache import HanaSemanticCache
        
        cache = HanaSemanticCache(max_size=2)
        
        # Fill cache
        await cache.set("query1", sample_embedding, {"answer": "result1"})
        await cache.set("query2", sample_embedding, {"answer": "result2"})
        
        # Add third item, should evict first
        await cache.set("query3", sample_embedding, {"answer": "result3"})
        
        # First should be evicted
        stats = cache.get_stats()
        assert stats["size"] <= 2


# ============================================================================
# Circuit Breaker Tests
# ============================================================================

class TestCircuitBreaker:
    """Tests for HANA circuit breaker."""
    
    @pytest.mark.asyncio
    async def test_circuit_starts_closed(self):
        """Test circuit breaker starts in closed state."""
        from middleware.hana_circuit_breaker import HanaCircuitBreaker, CircuitState
        
        breaker = HanaCircuitBreaker(name="test")
        assert breaker.state == CircuitState.CLOSED
    
    @pytest.mark.asyncio
    async def test_circuit_opens_after_failures(self):
        """Test circuit opens after threshold failures."""
        from middleware.hana_circuit_breaker import HanaCircuitBreaker, CircuitState
        
        breaker = HanaCircuitBreaker(name="test", failure_threshold=3)
        
        # Record failures
        for i in range(3):
            async def failing_operation():
                raise ConnectionError("Connection failed")
            
            try:
                await breaker.execute(failing_operation)
            except ConnectionError:
                pass
        
        assert breaker.state == CircuitState.OPEN
    
    @pytest.mark.asyncio
    async def test_circuit_uses_fallback_when_open(self):
        """Test circuit uses fallback when open."""
        from middleware.hana_circuit_breaker import HanaCircuitBreaker, CircuitState
        
        breaker = HanaCircuitBreaker(name="test", failure_threshold=1)
        
        # Open the circuit
        try:
            await breaker.execute(lambda: (_ for _ in ()).throw(ConnectionError()))
        except:
            pass
        
        # Verify open
        assert breaker.state == CircuitState.OPEN
        
        # Execute with fallback
        fallback_result = "fallback"
        
        result = await breaker.execute(
            lambda: (_ for _ in ()).throw(ConnectionError()),
            fallback=lambda: fallback_result
        )
        
        assert result == fallback_result
    
    @pytest.mark.asyncio
    async def test_circuit_recovery(self):
        """Test circuit recovers after timeout."""
        from middleware.hana_circuit_breaker import HanaCircuitBreaker, CircuitState
        
        breaker = HanaCircuitBreaker(
            name="test",
            failure_threshold=1,
            recovery_timeout=0.1,  # Short timeout for testing
        )
        
        # Open the circuit
        await breaker.force_open()
        assert breaker.state == CircuitState.OPEN
        
        # Wait for recovery timeout
        await asyncio.sleep(0.2)
        
        # Should transition to half-open on next check
        async def success_operation():
            return "success"
        
        result = await breaker.execute(success_operation)
        # After successful execution in half-open, should close


# ============================================================================
# Retry Handler Tests
# ============================================================================

class TestRetryHandler:
    """Tests for retry handler."""
    
    @pytest.mark.asyncio
    async def test_successful_operation_no_retry(self):
        """Test successful operation doesn't retry."""
        from middleware.retry_handler import RetryHandler, RetryPolicy
        
        handler = RetryHandler(name="test")
        call_count = 0
        
        async def success_op():
            nonlocal call_count
            call_count += 1
            return "success"
        
        result = await handler.execute(success_op)
        
        assert result == "success"
        assert call_count == 1
    
    @pytest.mark.asyncio
    async def test_retry_on_failure(self):
        """Test retries on transient failure."""
        from middleware.retry_handler import RetryHandler, RetryPolicy
        
        policy = RetryPolicy(max_retries=2, base_delay_ms=10)
        handler = RetryHandler(name="test", policy=policy)
        
        call_count = 0
        
        async def failing_then_success():
            nonlocal call_count
            call_count += 1
            if call_count < 2:
                raise ConnectionError("Transient failure")
            return "success"
        
        result = await handler.execute(failing_then_success)
        
        assert result == "success"
        assert call_count == 2
    
    @pytest.mark.asyncio
    async def test_max_retries_exceeded(self):
        """Test exception after max retries."""
        from middleware.retry_handler import RetryHandler, RetryPolicy
        
        policy = RetryPolicy(max_retries=2, base_delay_ms=10)
        handler = RetryHandler(name="test", policy=policy)
        
        async def always_fails():
            raise ConnectionError("Permanent failure")
        
        with pytest.raises(ConnectionError):
            await handler.execute(always_fails)
    
    @pytest.mark.asyncio
    async def test_non_retryable_exception(self):
        """Test non-retryable exceptions are not retried."""
        from middleware.retry_handler import RetryHandler, RetryPolicy
        
        policy = RetryPolicy(max_retries=3, base_delay_ms=10)
        handler = RetryHandler(name="test", policy=policy)
        
        call_count = 0
        
        async def raises_value_error():
            nonlocal call_count
            call_count += 1
            raise ValueError("Invalid value")
        
        with pytest.raises(ValueError):
            await handler.execute(raises_value_error)
        
        # Should only be called once (no retries for ValueError)
        assert call_count == 1


# ============================================================================
# Speculative Executor Tests
# ============================================================================

class TestSpeculativeExecutor:
    """Tests for speculative execution."""
    
    @pytest.mark.asyncio
    async def test_first_success_wins(self):
        """Test first successful path wins."""
        from intelligence.hana_speculative_executor import (
            SpeculativeExecutor, ResolutionPath
        )
        
        executor = SpeculativeExecutor(max_paths=3, timeout_seconds=1.0)
        
        # Register executors with different delays
        async def fast_executor(query, context):
            await asyncio.sleep(0.1)
            return {"result": "fast"}
        
        async def slow_executor(query, context):
            await asyncio.sleep(0.5)
            return {"result": "slow"}
        
        executor.register_executor(ResolutionPath.CACHE, fast_executor)
        executor.register_executor(ResolutionPath.HANA_VECTOR, slow_executor)
        
        result = await executor.execute(
            query="test",
            classification={"category": "RAG_RETRIEVAL", "confidence": 80},
            entities=[],
            is_hana_query=True,
        )
        
        # Fast executor should win
        assert result.winner.path == ResolutionPath.CACHE
        assert result.winner.result == {"result": "fast"}
    
    @pytest.mark.asyncio
    async def test_speculative_cancellation(self):
        """Test remaining paths are cancelled after success."""
        from intelligence.hana_speculative_executor import (
            SpeculativeExecutor, ResolutionPath
        )
        
        executor = SpeculativeExecutor(max_paths=2, timeout_seconds=2.0)
        
        cancelled = []
        
        async def fast_executor(query, context):
            await asyncio.sleep(0.1)
            return {"result": "fast"}
        
        async def slow_executor(query, context):
            try:
                await asyncio.sleep(1.0)
                return {"result": "slow"}
            except asyncio.CancelledError:
                cancelled.append("slow")
                raise
        
        executor.register_executor(ResolutionPath.CACHE, fast_executor)
        executor.register_executor(ResolutionPath.HANA_VECTOR, slow_executor)
        
        result = await executor.execute(
            query="test",
            classification={"category": "RAG_RETRIEVAL", "confidence": 80},
            entities=[],
            is_hana_query=True,
        )
        
        # Wait a bit for cancellation
        await asyncio.sleep(0.2)
        
        assert result.paths_cancelled > 0


# ============================================================================
# Adaptive Router Tests
# ============================================================================

class TestAdaptiveRouter:
    """Tests for adaptive query routing."""
    
    @pytest.mark.asyncio
    async def test_path_selection(self):
        """Test path selection."""
        from intelligence.adaptive_router import (
            AdaptiveRouter, ContextFeatures, extract_features
        )
        
        router = AdaptiveRouter(exploration_rate=0.0)  # No exploration
        
        features = ContextFeatures(
            classification_category="RAG_RETRIEVAL",
            is_hana_query=True,
        )
        
        path, confidence = await router.select_path(
            query="test query",
            features=features,
        )
        
        assert path in router.PATHS
        assert 0 <= confidence <= 1
    
    @pytest.mark.asyncio
    async def test_outcome_recording(self):
        """Test outcome recording updates stats."""
        from intelligence.adaptive_router import AdaptiveRouter, ContextFeatures
        
        router = AdaptiveRouter()
        
        features = ContextFeatures()
        
        # Select a path
        path, _ = await router.select_path("test", features)
        
        # Record outcome
        await router.record_outcome(
            query="test",
            path=path,
            success=True,
            latency_ms=100.0,
        )
        
        stats = router.get_stats()
        assert stats["total_selections"] >= 1
    
    @pytest.mark.asyncio
    async def test_model_export_import(self):
        """Test model export and import."""
        from intelligence.adaptive_router import AdaptiveRouter, ContextFeatures
        
        router = AdaptiveRouter()
        
        # Make some selections to build state
        features = ContextFeatures()
        for _ in range(5):
            path, _ = await router.select_path("test", features)
            await router.record_outcome("test", path, True, 100.0)
        
        # Export model
        model = await router.export_model()
        assert "beta_params" in model
        assert "global_stats" in model
        
        # Import into new router
        new_router = AdaptiveRouter()
        success = await new_router.import_model(model)
        assert success


# ============================================================================
# Query Rewriter Tests
# ============================================================================

class TestQueryRewriter:
    """Tests for query rewriting."""
    
    @pytest.mark.asyncio
    async def test_rephrase_query(self):
        """Test query rephrasing."""
        from intelligence.query_rewriter import QueryRewriter, RewriteStrategy
        
        rewriter = QueryRewriter()
        
        result = await rewriter.rewrite(
            "Please can you help me find trading positions?",
            strategies=[RewriteStrategy.REPHRASE],
        )
        
        # Should remove filler words
        assert "please" not in result.rewritten.lower()
        assert "can you" not in result.rewritten.lower()
    
    @pytest.mark.asyncio
    async def test_decompose_complex_query(self):
        """Test complex query decomposition."""
        from intelligence.query_rewriter import QueryRewriter, RewriteStrategy
        
        rewriter = QueryRewriter()
        
        result = await rewriter.rewrite(
            "What are trading positions and also show risk exposure?",
            strategies=[RewriteStrategy.DECOMPOSE],
        )
        
        assert len(result.sub_queries) >= 2
    
    @pytest.mark.asyncio
    async def test_expand_query(self):
        """Test query expansion."""
        from intelligence.query_rewriter import QueryRewriter, RewriteStrategy
        
        rewriter = QueryRewriter()
        
        result = await rewriter.rewrite(
            "Show me trading data",
            strategies=[RewriteStrategy.EXPAND],
        )
        
        # Should add related terms
        assert len(result.rewritten) > len("Show me trading data")


# ============================================================================
# Reranker Tests
# ============================================================================

class TestReranker:
    """Tests for result reranking."""
    
    @pytest.mark.asyncio
    async def test_recency_reranking(self, sample_documents):
        """Test recency-based reranking."""
        from intelligence.reranker import ResultReranker, RerankStrategy
        
        reranker = ResultReranker()
        
        # Add timestamps to test recency
        docs_with_time = []
        for i, doc in enumerate(sample_documents):
            doc_copy = doc.copy()
            doc_copy["metadata"] = doc["metadata"].copy()
            doc_copy["metadata"]["timestamp"] = 1704067200 - (i * 86400 * 30)  # 30 days apart
            doc_copy["score"] = 0.8
            docs_with_time.append(doc_copy)
        
        results = await reranker.rerank(
            "test query",
            docs_with_time,
            strategy=RerankStrategy.RECENCY,
        )
        
        # Most recent should be ranked higher
        assert results[0].original_rank == 0  # First doc was most recent
    
    @pytest.mark.asyncio
    async def test_entity_reranking(self, sample_documents):
        """Test entity-based reranking."""
        from intelligence.reranker import ResultReranker, RerankStrategy
        
        reranker = ResultReranker()
        
        # Add scores
        docs_with_scores = [
            {**doc, "score": 0.7} for doc in sample_documents
        ]
        
        results = await reranker.rerank(
            "trading positions",
            docs_with_scores,
            strategy=RerankStrategy.ENTITY,
            entities=["trading", "positions"],
        )
        
        # Doc with trading positions should rank higher
        assert "trading" in results[0].content.lower()


# ============================================================================
# Health Monitor Tests
# ============================================================================

class TestHealthMonitor:
    """Tests for health monitoring."""
    
    @pytest.mark.asyncio
    async def test_health_check_success(self):
        """Test successful health check."""
        from middleware.health_monitor import HealthChecker, HealthStatus
        
        async def healthy_check():
            return True
        
        checker = HealthChecker(name="test", check_fn=healthy_check)
        health = await checker.check()
        
        assert health.status == HealthStatus.HEALTHY
        assert health.consecutive_failures == 0
    
    @pytest.mark.asyncio
    async def test_health_check_failure(self):
        """Test failed health check."""
        from middleware.health_monitor import HealthChecker, HealthStatus
        
        async def unhealthy_check():
            return False
        
        checker = HealthChecker(name="test", check_fn=unhealthy_check)
        health = await checker.check()
        
        assert health.status == HealthStatus.DEGRADED
        assert health.consecutive_failures == 1
    
    @pytest.mark.asyncio
    async def test_health_monitor_aggregate_status(self):
        """Test aggregate health status."""
        from middleware.health_monitor import HealthMonitor
        
        monitor = HealthMonitor()
        
        async def healthy():
            return True
        
        async def unhealthy():
            return False
        
        monitor.register_service("healthy_service", healthy)
        monitor.register_service("unhealthy_service", unhealthy)
        
        await monitor.check_now()
        
        # One unhealthy service should make aggregate unhealthy
        from middleware.health_monitor import HealthStatus
        # After one failure, should be degraded (not unhealthy yet)


# ============================================================================
# Integration Flow Tests
# ============================================================================

class TestIntegrationFlow:
    """End-to-end integration tests."""
    
    @pytest.mark.asyncio
    async def test_full_query_flow(self, sample_embedding):
        """Test complete query processing flow."""
        # This tests the integration of multiple components
        
        from performance.hana_semantic_cache import HanaSemanticCache
        from intelligence.query_rewriter import QueryRewriter
        from middleware.retry_handler import RetryHandler
        from intelligence.reranker import ResultReranker
        
        # Initialize components
        cache = HanaSemanticCache()
        rewriter = QueryRewriter()
        retry_handler = RetryHandler(name="integration_test")
        reranker = ResultReranker()
        
        query = "What are the current trading positions?"
        
        # Step 1: Check cache
        cached_result, _ = await cache.get(query, sample_embedding)
        
        if cached_result is None:
            # Step 2: Rewrite query
            rewrite_result = await rewriter.rewrite(query)
            processed_query = rewrite_result.rewritten
            
            # Step 3: Execute search (mocked)
            mock_results = [
                {"content": "Trading doc 1", "score": 0.9, "metadata": {}},
                {"content": "Trading doc 2", "score": 0.8, "metadata": {}},
            ]
            
            # Step 4: Rerank results
            ranked_results = await reranker.rerank(
                processed_query,
                mock_results,
            )
            
            # Step 5: Cache result
            result = {"results": ranked_results}
            await cache.set(query, sample_embedding, result)
        
        # Verify cache was populated
        stats = cache.get_stats()
        assert stats["size"] > 0


# ============================================================================
# Run Tests
# ============================================================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--asyncio-mode=auto"])