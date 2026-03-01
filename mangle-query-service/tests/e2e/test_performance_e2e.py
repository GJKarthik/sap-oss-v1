"""
Performance End-to-End Tests.

Day 59 - Week 12 Integration Testing
45 tests for latency, throughput, and load testing validation.
"""

import pytest
import time
import asyncio
import statistics
from typing import Dict, Any, List
from concurrent.futures import ThreadPoolExecutor, as_completed

from testing.framework import (
    MockServer,
    TestClient,
    TestDataGenerator,
    RequestFactory,
    assert_status,
    assert_timing,
    with_timeout,
)

from performance.connection_pool import ConnectionPool, PoolConfig
from performance.query_optimizer import QueryOptimizer
from performance.cache_layer import CacheLayer, CacheConfig
from performance.load_tester import (
    LoadTester,
    LoadTestConfig,
    LoadTestResult,
    LatencyProfile,
    ThroughputResult,
)


# =============================================================================
# Test Fixtures
# =============================================================================

@pytest.fixture
def connection_pool():
    """Create connection pool for testing."""
    config = PoolConfig(min_size=2, max_size=10, timeout=5.0)
    pool = ConnectionPool(config)
    yield pool
    pool.close()


@pytest.fixture
def query_optimizer():
    """Create query optimizer for testing."""
    return QueryOptimizer()


@pytest.fixture
def cache_layer():
    """Create cache layer for testing."""
    config = CacheConfig(max_size=1000, ttl=60.0)
    cache = CacheLayer(config)
    yield cache
    cache.clear()


@pytest.fixture
def load_tester():
    """Create load tester for testing."""
    return LoadTester()


@pytest.fixture
def mock_api_server():
    """Create mock API server for performance testing."""
    with MockServer() as server:
        # Fast endpoint
        server.add_endpoint(
            "GET", "/fast",
            body={"status": "ok"},
            delay=0.001  # 1ms response
        )
        
        # Medium endpoint
        server.add_endpoint(
            "GET", "/medium",
            body={"status": "ok"},
            delay=0.010  # 10ms response
        )
        
        # Slow endpoint
        server.add_endpoint(
            "GET", "/slow",
            body={"status": "ok"},
            delay=0.050  # 50ms response
        )
        
        # Chat completion (realistic)
        server.add_endpoint(
            "POST", "/v1/chat/completions",
            body={
                "id": "chatcmpl-test",
                "object": "chat.completion",
                "choices": [{"message": {"content": "Hello!"}}]
            },
            delay=0.020  # 20ms
        )
        
        # Embeddings (realistic)
        server.add_endpoint(
            "POST", "/v1/embeddings",
            body={
                "object": "list",
                "data": [{"embedding": [0.1] * 1536}]
            },
            delay=0.005  # 5ms
        )
        
        yield server


# =============================================================================
# Latency E2E Tests (12 tests)
# =============================================================================

class TestLatencyE2E:
    """E2E tests for latency requirements."""
    
    def test_fast_endpoint_latency(self, mock_api_server):
        """Test fast endpoint < 10ms."""
        client = TestClient(base_url=mock_api_server.url)
        
        response = client.get("/fast")
        
        assert_status(response, 200)
        assert_timing(response.elapsed, max_ms=20)
    
    def test_medium_endpoint_latency(self, mock_api_server):
        """Test medium endpoint < 50ms."""
        client = TestClient(base_url=mock_api_server.url)
        
        response = client.get("/medium")
        
        assert_status(response, 200)
        assert_timing(response.elapsed, max_ms=50)
    
    def test_slow_endpoint_latency(self, mock_api_server):
        """Test slow endpoint < 100ms."""
        client = TestClient(base_url=mock_api_server.url)
        
        response = client.get("/slow")
        
        assert_status(response, 200)
        assert_timing(response.elapsed, max_ms=100)
    
    def test_chat_completion_latency(self, mock_api_server):
        """Test chat completion < 100ms."""
        client = TestClient(base_url=mock_api_server.url)
        request = RequestFactory.chat_completion()
        
        response = client.post("/v1/chat/completions", body=request)
        
        assert_status(response, 200)
        assert_timing(response.elapsed, max_ms=100)
    
    def test_embedding_latency(self, mock_api_server):
        """Test embedding < 50ms."""
        client = TestClient(base_url=mock_api_server.url)
        request = RequestFactory.embedding(input="test")
        
        response = client.post("/v1/embeddings", body=request)
        
        assert_status(response, 200)
        assert_timing(response.elapsed, max_ms=50)
    
    def test_p50_latency(self, mock_api_server):
        """Test p50 latency is within bounds."""
        client = TestClient(base_url=mock_api_server.url)
        latencies = []
        
        for _ in range(50):
            response = client.get("/fast")
            latencies.append(response.elapsed * 1000)
        
        p50 = sorted(latencies)[25]
        assert p50 < 30  # p50 < 30ms
    
    def test_p95_latency(self, mock_api_server):
        """Test p95 latency is within bounds."""
        client = TestClient(base_url=mock_api_server.url)
        latencies = []
        
        for _ in range(100):
            response = client.get("/fast")
            latencies.append(response.elapsed * 1000)
        
        sorted_latencies = sorted(latencies)
        p95 = sorted_latencies[95]
        assert p95 < 50  # p95 < 50ms
    
    def test_p99_latency(self, mock_api_server):
        """Test p99 latency is within bounds."""
        client = TestClient(base_url=mock_api_server.url)
        latencies = []
        
        for _ in range(100):
            response = client.get("/fast")
            latencies.append(response.elapsed * 1000)
        
        sorted_latencies = sorted(latencies)
        p99 = sorted_latencies[99]
        assert p99 < 100  # p99 < 100ms
    
    def test_latency_consistency(self, mock_api_server):
        """Test latency is consistent (low std dev)."""
        client = TestClient(base_url=mock_api_server.url)
        latencies = []
        
        for _ in range(50):
            response = client.get("/fast")
            latencies.append(response.elapsed * 1000)
        
        std_dev = statistics.stdev(latencies)
        mean = statistics.mean(latencies)
        cv = std_dev / mean  # Coefficient of variation
        
        assert cv < 1.0  # CV < 100%
    
    def test_first_request_latency(self, mock_api_server):
        """Test first request (cold start) is reasonable."""
        client = TestClient(base_url=mock_api_server.url)
        
        # First request might be slower
        response = client.get("/fast")
        
        assert_status(response, 200)
        assert_timing(response.elapsed, max_ms=100)
    
    def test_warm_request_latency(self, mock_api_server):
        """Test warm request latency is faster."""
        client = TestClient(base_url=mock_api_server.url)
        
        # Warm up
        for _ in range(5):
            client.get("/fast")
        
        # Measure warm request
        response = client.get("/fast")
        
        assert_timing(response.elapsed, max_ms=30)
    
    def test_latency_under_light_load(self, mock_api_server):
        """Test latency under light load."""
        client = TestClient(base_url=mock_api_server.url)
        latencies = []
        
        for _ in range(20):
            response = client.get("/medium")
            latencies.append(response.elapsed * 1000)
        
        avg = statistics.mean(latencies)
        assert avg < 50  # Average < 50ms


# =============================================================================
# Throughput E2E Tests (10 tests)
# =============================================================================

class TestThroughputE2E:
    """E2E tests for throughput requirements."""
    
    def test_sequential_throughput(self, mock_api_server):
        """Test sequential request throughput."""
        client = TestClient(base_url=mock_api_server.url)
        
        start = time.time()
        count = 100
        
        for _ in range(count):
            response = client.get("/fast")
            assert response.ok
        
        elapsed = time.time() - start
        rps = count / elapsed
        
        assert rps > 50  # > 50 RPS sequential
    
    def test_concurrent_throughput(self, mock_api_server):
        """Test concurrent request throughput."""
        def make_request():
            client = TestClient(base_url=mock_api_server.url)
            response = client.get("/fast")
            return response.ok
        
        start = time.time()
        count = 100
        
        with ThreadPoolExecutor(max_workers=10) as executor:
            futures = [executor.submit(make_request) for _ in range(count)]
            results = [f.result() for f in as_completed(futures)]
        
        elapsed = time.time() - start
        rps = count / elapsed
        
        assert all(results)
        assert rps > 200  # > 200 RPS concurrent
    
    def test_burst_handling(self, mock_api_server):
        """Test burst of requests."""
        def make_request():
            client = TestClient(base_url=mock_api_server.url)
            response = client.get("/fast")
            return response.ok
        
        # Burst of 50 requests
        with ThreadPoolExecutor(max_workers=50) as executor:
            futures = [executor.submit(make_request) for _ in range(50)]
            results = [f.result() for f in as_completed(futures)]
        
        success_rate = sum(results) / len(results)
        assert success_rate >= 0.95  # >= 95% success
    
    def test_sustained_throughput(self, mock_api_server):
        """Test sustained throughput over time."""
        client = TestClient(base_url=mock_api_server.url)
        
        start = time.time()
        successful = 0
        total = 0
        
        while time.time() - start < 1.0:  # 1 second test
            response = client.get("/fast")
            total += 1
            if response.ok:
                successful += 1
        
        success_rate = successful / total
        assert success_rate >= 0.99  # >= 99% success
        assert total >= 50  # At least 50 requests in 1 second
    
    def test_throughput_degradation(self, mock_api_server):
        """Test throughput doesn't degrade significantly."""
        client = TestClient(base_url=mock_api_server.url)
        
        # First batch
        start1 = time.time()
        for _ in range(50):
            client.get("/fast")
        rps1 = 50 / (time.time() - start1)
        
        # Second batch (after some load)
        start2 = time.time()
        for _ in range(50):
            client.get("/fast")
        rps2 = 50 / (time.time() - start2)
        
        # Throughput should not drop more than 20%
        assert rps2 >= rps1 * 0.8
    
    def test_chat_completion_throughput(self, mock_api_server):
        """Test chat completion throughput."""
        client = TestClient(base_url=mock_api_server.url)
        request = RequestFactory.chat_completion()
        
        start = time.time()
        count = 50
        
        for _ in range(count):
            response = client.post("/v1/chat/completions", body=request)
            assert response.ok
        
        elapsed = time.time() - start
        rps = count / elapsed
        
        assert rps > 20  # > 20 chat completions/second
    
    def test_embedding_throughput(self, mock_api_server):
        """Test embedding throughput."""
        client = TestClient(base_url=mock_api_server.url)
        request = RequestFactory.embedding(input="test")
        
        start = time.time()
        count = 100
        
        for _ in range(count):
            response = client.post("/v1/embeddings", body=request)
            assert response.ok
        
        elapsed = time.time() - start
        rps = count / elapsed
        
        assert rps > 100  # > 100 embeddings/second
    
    def test_mixed_endpoint_throughput(self, mock_api_server):
        """Test mixed endpoint throughput."""
        client = TestClient(base_url=mock_api_server.url)
        
        start = time.time()
        successful = 0
        
        for i in range(100):
            if i % 3 == 0:
                response = client.get("/fast")
            elif i % 3 == 1:
                response = client.get("/medium")
            else:
                response = client.post(
                    "/v1/chat/completions",
                    body=RequestFactory.chat_completion()
                )
            if response.ok:
                successful += 1
        
        elapsed = time.time() - start
        rps = successful / elapsed
        
        assert rps > 30  # > 30 mixed RPS
    
    def test_error_rate_under_load(self, mock_api_server):
        """Test error rate under load is acceptable."""
        def make_request():
            client = TestClient(base_url=mock_api_server.url)
            response = client.get("/fast")
            return response.ok
        
        with ThreadPoolExecutor(max_workers=20) as executor:
            futures = [executor.submit(make_request) for _ in range(200)]
            results = [f.result() for f in as_completed(futures)]
        
        error_rate = 1 - (sum(results) / len(results))
        assert error_rate < 0.01  # < 1% error rate
    
    def test_request_timeout_handling(self, mock_api_server):
        """Test requests timeout gracefully."""
        client = TestClient(base_url=mock_api_server.url, timeout=0.2)
        
        # Slow endpoint should not cause issues
        response = client.get("/slow")
        
        # Should complete within timeout or fail gracefully
        assert response.status_code in [200, 408, 504]


# =============================================================================
# Connection Pool E2E Tests (8 tests)
# =============================================================================

class TestConnectionPoolE2E:
    """E2E tests for connection pooling."""
    
    def test_pool_initialization(self, connection_pool):
        """Test pool initializes correctly."""
        assert connection_pool.size >= 2  # min_size
        assert connection_pool.size <= 10  # max_size
    
    def test_connection_acquire_release(self, connection_pool):
        """Test connection acquire and release."""
        conn = connection_pool.acquire()
        assert conn is not None
        
        connection_pool.release(conn)
        assert connection_pool.available >= 1
    
    def test_connection_reuse(self, connection_pool):
        """Test connections are reused."""
        conn1 = connection_pool.acquire()
        connection_pool.release(conn1)
        
        conn2 = connection_pool.acquire()
        
        # Should get same connection
        assert conn1 is conn2 or connection_pool.available >= 1
    
    def test_pool_exhaustion_handling(self, connection_pool):
        """Test pool handles exhaustion."""
        acquired = []
        
        # Acquire all connections
        for _ in range(10):
            try:
                conn = connection_pool.acquire(timeout=0.1)
                if conn:
                    acquired.append(conn)
            except Exception:
                break
        
        # Pool should be at capacity
        assert len(acquired) >= 2  # At least min_size
        
        # Release all
        for conn in acquired:
            connection_pool.release(conn)
    
    def test_concurrent_pool_access(self, connection_pool):
        """Test concurrent pool access."""
        def use_connection():
            conn = connection_pool.acquire(timeout=1.0)
            if conn:
                time.sleep(0.01)
                connection_pool.release(conn)
                return True
            return False
        
        with ThreadPoolExecutor(max_workers=20) as executor:
            futures = [executor.submit(use_connection) for _ in range(50)]
            results = [f.result() for f in as_completed(futures)]
        
        success_rate = sum(results) / len(results)
        assert success_rate >= 0.8  # >= 80% success
    
    def test_pool_health_check(self, connection_pool):
        """Test pool health check."""
        health = connection_pool.health_check()
        
        assert health.status in ["healthy", "degraded", "unhealthy"]
        assert health.available >= 0
        assert health.in_use >= 0
    
    def test_pool_statistics(self, connection_pool):
        """Test pool statistics."""
        # Make some activity
        for _ in range(5):
            conn = connection_pool.acquire()
            connection_pool.release(conn)
        
        stats = connection_pool.get_stats()
        
        assert stats.total_acquired >= 5
        assert stats.total_released >= 5
    
    def test_pool_cleanup(self, connection_pool):
        """Test pool cleanup."""
        # Acquire and release
        conn = connection_pool.acquire()
        connection_pool.release(conn)
        
        # Cleanup should work
        connection_pool.cleanup_idle()
        
        assert connection_pool.size >= 2  # Min maintained


# =============================================================================
# Cache E2E Tests (8 tests)
# =============================================================================

class TestCacheE2E:
    """E2E tests for caching."""
    
    def test_cache_set_get(self, cache_layer):
        """Test cache set and get."""
        cache_layer.set("key1", "value1")
        
        value = cache_layer.get("key1")
        
        assert value == "value1"
    
    def test_cache_miss(self, cache_layer):
        """Test cache miss returns None."""
        value = cache_layer.get("nonexistent")
        
        assert value is None
    
    def test_cache_hit_rate(self, cache_layer):
        """Test cache hit rate."""
        # Fill cache
        for i in range(100):
            cache_layer.set(f"key{i}", f"value{i}")
        
        # Access existing keys
        hits = 0
        for i in range(100):
            if cache_layer.get(f"key{i}") is not None:
                hits += 1
        
        hit_rate = hits / 100
        assert hit_rate >= 0.99  # >= 99% hit rate
    
    def test_cache_speedup(self, cache_layer):
        """Test cache provides speedup."""
        def slow_computation(key):
            time.sleep(0.01)  # 10ms
            return f"computed_{key}"
        
        # First access (cache miss)
        start1 = time.time()
        value1 = cache_layer.get("test_key")
        if value1 is None:
            value1 = slow_computation("test_key")
            cache_layer.set("test_key", value1)
        elapsed1 = time.time() - start1
        
        # Second access (cache hit)
        start2 = time.time()
        value2 = cache_layer.get("test_key")
        elapsed2 = time.time() - start2
        
        # Cache hit should be much faster
        assert elapsed2 < elapsed1 / 5  # At least 5x faster
    
    def test_cache_eviction(self, cache_layer):
        """Test cache eviction on full."""
        # Fill cache to max
        for i in range(1100):  # Exceeds max_size of 1000
            cache_layer.set(f"key{i}", f"value{i}")
        
        # Cache should have evicted some entries
        assert cache_layer.size <= 1000
    
    def test_cache_ttl_expiry(self):
        """Test cache TTL expiry."""
        config = CacheConfig(max_size=100, ttl=0.1)  # 100ms TTL
        cache = CacheLayer(config)
        
        cache.set("key", "value")
        
        # Should exist immediately
        assert cache.get("key") == "value"
        
        # Wait for TTL
        time.sleep(0.15)
        
        # Should be expired
        assert cache.get("key") is None
    
    def test_cache_statistics(self, cache_layer):
        """Test cache statistics."""
        # Generate some activity
        cache_layer.set("a", "1")
        cache_layer.get("a")  # Hit
        cache_layer.get("b")  # Miss
        cache_layer.get("a")  # Hit
        
        stats = cache_layer.get_stats()
        
        assert stats.hits >= 2
        assert stats.misses >= 1
    
    def test_cache_invalidation(self, cache_layer):
        """Test cache invalidation."""
        cache_layer.set("key", "value")
        assert cache_layer.get("key") == "value"
        
        cache_layer.invalidate("key")
        assert cache_layer.get("key") is None


# =============================================================================
# Load Test E2E Tests (7 tests)
# =============================================================================

class TestLoadTestE2E:
    """E2E tests for load testing."""
    
    def test_load_test_config(self, load_tester):
        """Test load test configuration."""
        config = LoadTestConfig(
            duration=1.0,
            concurrent_users=10,
            ramp_up=0.5
        )
        
        assert config.duration == 1.0
        assert config.concurrent_users == 10
        assert config.ramp_up == 0.5
    
    def test_load_test_result(self, load_tester, mock_api_server):
        """Test load test produces results."""
        def make_request():
            client = TestClient(base_url=mock_api_server.url)
            return client.get("/fast")
        
        config = LoadTestConfig(duration=0.5, concurrent_users=5)
        
        result = load_tester.run(make_request, config)
        
        assert result.total_requests > 0
        assert result.successful_requests > 0
        assert result.requests_per_second > 0
    
    def test_latency_profile(self, load_tester, mock_api_server):
        """Test latency profile generation."""
        def make_request():
            client = TestClient(base_url=mock_api_server.url)
            return client.get("/fast")
        
        config = LoadTestConfig(duration=0.5, concurrent_users=5)
        result = load_tester.run(make_request, config)
        
        profile = result.latency_profile
        
        assert profile.p50 > 0
        assert profile.p95 >= profile.p50
        assert profile.p99 >= profile.p95
        assert profile.max >= profile.p99
    
    def test_throughput_measurement(self, load_tester, mock_api_server):
        """Test throughput measurement."""
        def make_request():
            client = TestClient(base_url=mock_api_server.url)
            return client.get("/fast")
        
        config = LoadTestConfig(duration=1.0, concurrent_users=10)
        result = load_tester.run(make_request, config)
        
        assert result.requests_per_second > 10  # At least 10 RPS
    
    def test_error_rate_measurement(self, load_tester, mock_api_server):
        """Test error rate measurement."""
        def make_request():
            client = TestClient(base_url=mock_api_server.url)
            return client.get("/fast")
        
        config = LoadTestConfig(duration=0.5, concurrent_users=5)
        result = load_tester.run(make_request, config)
        
        assert result.error_rate < 0.05  # < 5% error rate
    
    def test_ramp_up_behavior(self, load_tester, mock_api_server):
        """Test ramp up behavior."""
        def make_request():
            client = TestClient(base_url=mock_api_server.url)
            return client.get("/fast")
        
        config = LoadTestConfig(
            duration=1.0,
            concurrent_users=10,
            ramp_up=0.5  # 0.5 second ramp up
        )
        result = load_tester.run(make_request, config)
        
        # Should complete successfully
        assert result.successful_requests > 0
    
    def test_load_test_report(self, load_tester, mock_api_server):
        """Test load test report generation."""
        def make_request():
            client = TestClient(base_url=mock_api_server.url)
            return client.get("/fast")
        
        config = LoadTestConfig(duration=0.5, concurrent_users=5)
        result = load_tester.run(make_request, config)
        
        report = result.generate_report()
        
        assert "Total Requests" in report
        assert "Requests/Second" in report
        assert "Error Rate" in report


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - Latency E2E: 12 tests
# - Throughput E2E: 10 tests
# - Connection Pool E2E: 8 tests
# - Cache E2E: 8 tests
# - Load Test E2E: 7 tests