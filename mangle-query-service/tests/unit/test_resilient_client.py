"""
Unit Tests for Resilient HTTP Client

Day 4 Deliverable: Comprehensive tests for resilient_client.py
Target: >80% code coverage
"""

import pytest
import time
from unittest.mock import AsyncMock, MagicMock, patch
from dataclasses import dataclass

from mangle_query_service.middleware.resilient_client import (
    ResilientClientConfig,
    RequestMetrics,
    MetricsCollector,
    ResilientHTTPClient,
    create_resilient_client,
    get_resilient_client,
    get_llm_client,
    get_metadata_client,
    get_elasticsearch_client,
)
from mangle_query_service.middleware.circuit_breaker import CircuitBreakerOpen


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def config():
    """Default resilient client configuration."""
    return ResilientClientConfig()


@pytest.fixture
def fast_config():
    """Fast config for testing."""
    return ResilientClientConfig(
        base_timeout=1.0,
        max_retries=2,
        retry_base_delay=0.1,
        retry_max_delay=0.5,
        cb_failure_threshold=3,
        cb_recovery_timeout=0.1,
        enable_metrics=True,
    )


@pytest.fixture
def mock_http_client():
    """Mock HTTP client."""
    mock = MagicMock()
    mock.request = AsyncMock(return_value=MagicMock(status_code=200))
    return mock


# ========================================
# ResilientClientConfig Tests
# ========================================

class TestResilientClientConfig:
    """Tests for ResilientClientConfig."""
    
    def test_default_values(self):
        """Test default configuration values."""
        config = ResilientClientConfig()
        
        assert config.base_timeout == 30.0
        assert config.max_retries == 3
        assert config.cb_failure_threshold == 5
        assert config.enable_retry is True
        assert config.enable_circuit_breaker is True
    
    def test_for_llm_backend(self):
        """Test LLM backend preset."""
        config = ResilientClientConfig.for_llm_backend()
        
        assert config.base_timeout == 120.0
        assert config.read_timeout == 120.0
        assert config.max_retries == 2
        assert config.cb_failure_threshold == 3
    
    def test_for_metadata_service(self):
        """Test metadata service preset."""
        config = ResilientClientConfig.for_metadata_service()
        
        assert config.base_timeout == 5.0
        assert config.read_timeout == 10.0
        assert config.max_retries == 3
        assert config.cb_failure_threshold == 10
    
    def test_for_elasticsearch(self):
        """Test Elasticsearch preset."""
        config = ResilientClientConfig.for_elasticsearch()
        
        assert config.base_timeout == 10.0
        assert config.read_timeout == 30.0
        assert config.cb_failure_threshold == 5
    
    def test_to_retry_config(self):
        """Test conversion to RetryConfig."""
        config = ResilientClientConfig(
            max_retries=5,
            retry_base_delay=2.0,
            retry_max_delay=16.0,
        )
        
        retry_config = config.to_retry_config()
        
        assert retry_config.max_retries == 5
        assert retry_config.base_delay == 2.0
        assert retry_config.max_delay == 16.0
    
    def test_to_circuit_breaker_config(self):
        """Test conversion to CircuitBreakerConfig."""
        config = ResilientClientConfig(
            cb_failure_threshold=10,
            cb_success_threshold=3,
            cb_recovery_timeout=60.0,
        )
        
        cb_config = config.to_circuit_breaker_config()
        
        assert cb_config.failure_threshold == 10
        assert cb_config.success_threshold == 3
        assert cb_config.recovery_timeout == 60.0


# ========================================
# RequestMetrics Tests
# ========================================

class TestRequestMetrics:
    """Tests for RequestMetrics."""
    
    def test_default_values(self):
        """Test default metric values."""
        metrics = RequestMetrics(
            method="GET",
            url="http://test.com/api",
            backend="http://test.com",
        )
        
        assert metrics.method == "GET"
        assert metrics.url == "http://test.com/api"
        assert metrics.status_code is None
        assert metrics.duration_ms == 0.0
        assert metrics.retry_count == 0
        assert metrics.success is False
    
    def test_set_values(self):
        """Test setting metric values."""
        metrics = RequestMetrics(
            method="POST",
            url="http://api.example.com/v1/chat",
            backend="http://api.example.com",
            status_code=200,
            duration_ms=150.5,
            retry_count=2,
            success=True,
        )
        
        assert metrics.status_code == 200
        assert metrics.duration_ms == 150.5
        assert metrics.retry_count == 2
        assert metrics.success is True


# ========================================
# MetricsCollector Tests
# ========================================

class TestMetricsCollector:
    """Tests for MetricsCollector."""
    
    def test_record_success(self):
        """Test recording successful request."""
        collector = MetricsCollector()
        
        metrics = RequestMetrics(
            method="GET",
            url="http://test.com/api",
            backend="http://test.com",
            status_code=200,
            duration_ms=100.0,
            success=True,
        )
        
        collector.record(metrics)
        summary = collector.get_summary()
        
        assert summary["total_requests"] == 1
        assert summary["total_errors"] == 0
        assert summary["error_rate"] == 0.0
    
    def test_record_error(self):
        """Test recording failed request."""
        collector = MetricsCollector()
        
        metrics = RequestMetrics(
            method="GET",
            url="http://test.com/api",
            backend="http://test.com",
            error="Connection refused",
            success=False,
        )
        
        collector.record(metrics)
        summary = collector.get_summary()
        
        assert summary["total_requests"] == 1
        assert summary["total_errors"] == 1
        assert summary["error_rate"] == 1.0
    
    def test_backend_stats(self):
        """Test per-backend statistics."""
        collector = MetricsCollector()
        
        # Record requests to two backends
        collector.record(RequestMetrics(
            method="GET",
            url="http://backend1.com/api",
            backend="http://backend1.com",
            duration_ms=100.0,
            success=True,
        ))
        collector.record(RequestMetrics(
            method="GET",
            url="http://backend2.com/api",
            backend="http://backend2.com",
            duration_ms=200.0,
            success=True,
        ))
        
        summary = collector.get_summary()
        
        assert "http://backend1.com" in summary["backend_stats"]
        assert "http://backend2.com" in summary["backend_stats"]
        assert summary["backend_stats"]["http://backend1.com"]["requests"] == 1
    
    def test_recent_requests(self):
        """Test getting recent requests."""
        collector = MetricsCollector()
        
        for i in range(5):
            collector.record(RequestMetrics(
                method="GET",
                url=f"http://test.com/api/{i}",
                backend="http://test.com",
                success=True,
            ))
        
        recent = collector.get_recent(3)
        
        assert len(recent) == 3
        assert recent[-1].url == "http://test.com/api/4"
    
    def test_max_history(self):
        """Test history is bounded."""
        collector = MetricsCollector(max_history=5)
        
        for i in range(10):
            collector.record(RequestMetrics(
                method="GET",
                url=f"http://test.com/api/{i}",
                backend="http://test.com",
                success=True,
            ))
        
        recent = collector.get_recent(100)
        
        assert len(recent) == 5
    
    def test_average_duration(self):
        """Test rolling average duration."""
        collector = MetricsCollector()
        
        collector.record(RequestMetrics(
            method="GET",
            url="http://test.com/api",
            backend="http://test.com",
            duration_ms=100.0,
            success=True,
        ))
        collector.record(RequestMetrics(
            method="GET",
            url="http://test.com/api",
            backend="http://test.com",
            duration_ms=200.0,
            success=True,
        ))
        
        summary = collector.get_summary()
        
        assert summary["backend_stats"]["http://test.com"]["avg_duration_ms"] == 150.0


# ========================================
# ResilientHTTPClient Tests
# ========================================

class TestResilientHTTPClient:
    """Tests for ResilientHTTPClient."""
    
    def test_init_default_config(self):
        """Test initialization with default config."""
        client = ResilientHTTPClient()
        
        assert client.config is not None
        assert client.config.enable_retry is True
        assert client.config.enable_circuit_breaker is True
    
    def test_init_custom_config(self, fast_config):
        """Test initialization with custom config."""
        client = ResilientHTTPClient(fast_config)
        
        assert client.config.max_retries == 2
        assert client.config.cb_failure_threshold == 3
    
    def test_extract_backend(self, fast_config):
        """Test backend extraction from URL."""
        client = ResilientHTTPClient(fast_config)
        
        backend = client._extract_backend("http://api.example.com:8080/v1/chat")
        assert backend == "http://api.example.com:8080"
        
        backend = client._extract_backend("https://secure.api.com/resource")
        assert backend == "https://secure.api.com"
    
    @pytest.mark.asyncio
    async def test_get_request(self, fast_config, mock_http_client):
        """Test GET request."""
        client = ResilientHTTPClient(fast_config, mock_http_client)
        
        response = await client.get("http://api.example.com/resource")
        
        assert response.status_code == 200
        mock_http_client.request.assert_called()
    
    @pytest.mark.asyncio
    async def test_post_request(self, fast_config, mock_http_client):
        """Test POST request."""
        client = ResilientHTTPClient(fast_config, mock_http_client)
        
        response = await client.post(
            "http://api.example.com/resource",
            json={"key": "value"},
        )
        
        assert response.status_code == 200
    
    @pytest.mark.asyncio
    async def test_metrics_recorded(self, fast_config, mock_http_client):
        """Test metrics are recorded."""
        client = ResilientHTTPClient(fast_config, mock_http_client)
        
        await client.get("http://api.example.com/resource")
        
        metrics = client.get_metrics()
        assert metrics is not None
        assert metrics["total_requests"] == 1
    
    @pytest.mark.asyncio
    async def test_circuit_breaker_opens(self, fast_config, mock_http_client):
        """Test circuit breaker opens after failures."""
        mock_http_client.request = AsyncMock(return_value=MagicMock(status_code=500))
        client = ResilientHTTPClient(fast_config, mock_http_client)
        
        # Make requests until circuit opens (3 failures)
        for _ in range(3):
            await client.get("http://failing.api.com/resource")
        
        # Next request should fail with CircuitBreakerOpen
        with pytest.raises(CircuitBreakerOpen):
            await client.get("http://failing.api.com/resource")
    
    @pytest.mark.asyncio
    async def test_circuit_breaker_stats(self, fast_config, mock_http_client):
        """Test circuit breaker stats retrieval."""
        client = ResilientHTTPClient(fast_config, mock_http_client)
        
        await client.get("http://api.example.com/resource")
        
        stats = client.get_circuit_breaker_stats("http://api.example.com")
        
        assert "state" in stats
        assert "total_successes" in stats
    
    @pytest.mark.asyncio
    async def test_reset_circuit_breaker(self, fast_config, mock_http_client):
        """Test circuit breaker reset."""
        mock_http_client.request = AsyncMock(return_value=MagicMock(status_code=500))
        client = ResilientHTTPClient(fast_config, mock_http_client)
        
        # Open the circuit
        for _ in range(3):
            await client.get("http://failing.api.com/resource")
        
        # Reset it
        client.reset_circuit_breaker("http://failing.api.com")
        
        # Should be able to make requests again
        mock_http_client.request = AsyncMock(return_value=MagicMock(status_code=200))
        response = await client.get("http://failing.api.com/resource")
        assert response.status_code == 200
    
    @pytest.mark.asyncio
    async def test_close(self, fast_config, mock_http_client):
        """Test client close."""
        mock_http_client.close = AsyncMock()
        client = ResilientHTTPClient(fast_config, mock_http_client)
        
        await client.close()
        
        mock_http_client.close.assert_called_once()
    
    @pytest.mark.asyncio
    async def test_context_manager(self, fast_config, mock_http_client):
        """Test async context manager."""
        mock_http_client.close = AsyncMock()
        
        async with ResilientHTTPClient(fast_config, mock_http_client) as client:
            response = await client.get("http://api.example.com/resource")
            assert response.status_code == 200
        
        mock_http_client.close.assert_called_once()


# ========================================
# Factory Function Tests
# ========================================

class TestFactoryFunctions:
    """Tests for factory functions."""
    
    def test_create_resilient_client(self):
        """Test create_resilient_client."""
        client1 = create_resilient_client("test-client")
        client2 = create_resilient_client("test-client")
        
        # Same name returns same instance
        assert client1 is client2
    
    def test_create_with_config(self):
        """Test create with custom config."""
        config = ResilientClientConfig.for_llm_backend()
        client = create_resilient_client("llm-test", config)
        
        assert client.config.base_timeout == 120.0
    
    def test_get_resilient_client_exists(self):
        """Test get existing client."""
        create_resilient_client("existing-client")
        client = get_resilient_client("existing-client")
        
        assert client is not None
    
    def test_get_resilient_client_not_exists(self):
        """Test get non-existing client."""
        client = get_resilient_client("nonexistent-client")
        
        assert client is None
    
    def test_get_llm_client(self):
        """Test get_llm_client helper."""
        client = get_llm_client()
        
        assert client is not None
        assert client.config.base_timeout == 120.0
    
    def test_get_metadata_client(self):
        """Test get_metadata_client helper."""
        client = get_metadata_client()
        
        assert client is not None
        assert client.config.base_timeout == 5.0
    
    def test_get_elasticsearch_client(self):
        """Test get_elasticsearch_client helper."""
        client = get_elasticsearch_client()
        
        assert client is not None
        assert client.config.base_timeout == 10.0


# ========================================
# Integration Tests (No Retry/CB)
# ========================================

class TestDisabledFeatures:
    """Tests with retry and circuit breaker disabled."""
    
    @pytest.mark.asyncio
    async def test_retry_disabled(self, mock_http_client):
        """Test with retry disabled."""
        config = ResilientClientConfig(
            enable_retry=False,
            enable_circuit_breaker=False,
            enable_metrics=True,
        )
        client = ResilientHTTPClient(config, mock_http_client)
        
        response = await client.get("http://api.example.com/resource")
        
        # Should only call once (no retry)
        assert mock_http_client.request.call_count == 1
    
    @pytest.mark.asyncio
    async def test_circuit_breaker_disabled(self, mock_http_client):
        """Test with circuit breaker disabled."""
        mock_http_client.request = AsyncMock(return_value=MagicMock(status_code=500))
        
        config = ResilientClientConfig(
            enable_retry=False,
            enable_circuit_breaker=False,
        )
        client = ResilientHTTPClient(config, mock_http_client)
        
        # Should not raise CircuitBreakerOpen even after many failures
        for _ in range(10):
            response = await client.get("http://failing.api.com/resource")
            assert response.status_code == 500
    
    @pytest.mark.asyncio
    async def test_metrics_disabled(self, mock_http_client):
        """Test with metrics disabled."""
        config = ResilientClientConfig(
            enable_metrics=False,
            enable_circuit_breaker=False,
        )
        client = ResilientHTTPClient(config, mock_http_client)
        
        await client.get("http://api.example.com/resource")
        
        metrics = client.get_metrics()
        assert metrics is None


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])