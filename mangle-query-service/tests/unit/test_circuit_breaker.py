"""
Unit Tests for Circuit Breaker

Day 3 Deliverable: Comprehensive tests for circuit_breaker.py
Target: >80% code coverage
"""

import pytest
import time
from unittest.mock import AsyncMock, MagicMock, patch
from dataclasses import dataclass

from mangle_query_service.middleware.circuit_breaker import (
    CircuitState,
    CircuitBreakerConfig,
    CircuitBreakerState,
    CircuitBreaker,
    CircuitBreakerOpen,
    CircuitBreakerContext,
    with_circuit_breaker,
    CircuitBreakerHTTPClient,
    CircuitBreakerRegistry,
    get_circuit_breaker,
    get_all_circuit_breaker_stats,
)


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def config():
    """Default circuit breaker configuration."""
    return CircuitBreakerConfig()


@pytest.fixture
def fast_config():
    """Fast config for testing."""
    return CircuitBreakerConfig(
        failure_threshold=3,
        success_threshold=2,
        recovery_timeout=0.1,  # 100ms for fast tests
        failure_window=60.0,
    )


@pytest.fixture
def circuit_breaker(fast_config):
    """Create circuit breaker with fast config."""
    return CircuitBreaker(fast_config)


# ========================================
# CircuitState Tests
# ========================================

class TestCircuitState:
    """Tests for CircuitState enum."""
    
    def test_states_exist(self):
        """Test all states exist."""
        assert CircuitState.CLOSED.value == "closed"
        assert CircuitState.OPEN.value == "open"
        assert CircuitState.HALF_OPEN.value == "half_open"


# ========================================
# CircuitBreakerConfig Tests
# ========================================

class TestCircuitBreakerConfig:
    """Tests for CircuitBreakerConfig."""
    
    def test_default_values(self):
        """Test default configuration values."""
        config = CircuitBreakerConfig()
        
        assert config.failure_threshold == 5
        assert config.success_threshold == 2
        assert config.recovery_timeout == 30.0
        assert config.failure_window == 60.0
    
    def test_strict_preset(self):
        """Test strict preset."""
        config = CircuitBreakerConfig.strict()
        
        assert config.failure_threshold == 3
        assert config.success_threshold == 3
        assert config.recovery_timeout == 60.0
    
    def test_lenient_preset(self):
        """Test lenient preset."""
        config = CircuitBreakerConfig.lenient()
        
        assert config.failure_threshold == 10
        assert config.success_threshold == 1
        assert config.recovery_timeout == 15.0
    
    def test_failure_status_codes(self):
        """Test default failure status codes."""
        config = CircuitBreakerConfig()
        
        assert 500 in config.failure_status_codes
        assert 502 in config.failure_status_codes
        assert 503 in config.failure_status_codes
        assert 504 in config.failure_status_codes


# ========================================
# CircuitBreakerOpen Exception Tests
# ========================================

class TestCircuitBreakerOpen:
    """Tests for CircuitBreakerOpen exception."""
    
    def test_exception_message(self):
        """Test exception message."""
        exc = CircuitBreakerOpen("backend-api", 25.5)
        
        assert exc.backend == "backend-api"
        assert exc.time_until_recovery == 25.5
        assert "backend-api" in str(exc)
        assert "25.5" in str(exc)
    
    def test_custom_message(self):
        """Test custom message."""
        exc = CircuitBreakerOpen("backend", 10.0, "Custom message")
        
        assert str(exc) == "Custom message"


# ========================================
# CircuitBreaker Tests
# ========================================

class TestCircuitBreaker:
    """Tests for CircuitBreaker."""
    
    def test_initial_state_closed(self, circuit_breaker):
        """Test initial state is CLOSED."""
        state = circuit_breaker.get_state("backend")
        assert state == CircuitState.CLOSED
    
    def test_can_execute_when_closed(self, circuit_breaker):
        """Test can execute when CLOSED."""
        assert circuit_breaker.can_execute("backend") is True
    
    def test_record_success_increments_counter(self, circuit_breaker):
        """Test success increments counter."""
        circuit_breaker.record_success("backend")
        stats = circuit_breaker.get_stats("backend")
        
        assert stats["total_successes"] == 1
    
    def test_record_failure_increments_counter(self, circuit_breaker):
        """Test failure increments counter."""
        circuit_breaker.record_failure("backend")
        stats = circuit_breaker.get_stats("backend")
        
        assert stats["total_failures"] == 1
    
    def test_opens_after_failure_threshold(self, circuit_breaker):
        """Test circuit opens after failure threshold."""
        backend = "backend"
        
        # Record failures up to threshold
        for _ in range(3):  # fast_config.failure_threshold
            circuit_breaker.record_failure(backend)
        
        assert circuit_breaker.get_state(backend) == CircuitState.OPEN
        assert circuit_breaker.can_execute(backend) is False
    
    def test_time_until_recovery(self, circuit_breaker):
        """Test time until recovery calculation."""
        backend = "backend"
        
        # Open the circuit
        for _ in range(3):
            circuit_breaker.record_failure(backend)
        
        recovery_time = circuit_breaker.time_until_recovery(backend)
        
        # Should be close to recovery_timeout (0.1s)
        assert 0.0 < recovery_time <= 0.1
    
    def test_transitions_to_half_open(self, circuit_breaker):
        """Test circuit transitions to HALF_OPEN after recovery timeout."""
        backend = "backend"
        
        # Open the circuit
        for _ in range(3):
            circuit_breaker.record_failure(backend)
        
        assert circuit_breaker.get_state(backend) == CircuitState.OPEN
        
        # Wait for recovery timeout
        time.sleep(0.15)  # Slightly more than 0.1s
        
        assert circuit_breaker.get_state(backend) == CircuitState.HALF_OPEN
        assert circuit_breaker.can_execute(backend) is True
    
    def test_half_open_to_closed_on_success(self, circuit_breaker):
        """Test HALF_OPEN transitions to CLOSED on success."""
        backend = "backend"
        
        # Open the circuit
        for _ in range(3):
            circuit_breaker.record_failure(backend)
        
        # Wait for recovery
        time.sleep(0.15)
        assert circuit_breaker.get_state(backend) == CircuitState.HALF_OPEN
        
        # Record successes (need 2 for fast_config)
        circuit_breaker.record_success(backend)
        circuit_breaker.record_success(backend)
        
        assert circuit_breaker.get_state(backend) == CircuitState.CLOSED
    
    def test_half_open_to_open_on_failure(self, circuit_breaker):
        """Test HALF_OPEN transitions to OPEN on any failure."""
        backend = "backend"
        
        # Open the circuit
        for _ in range(3):
            circuit_breaker.record_failure(backend)
        
        # Wait for recovery
        time.sleep(0.15)
        assert circuit_breaker.get_state(backend) == CircuitState.HALF_OPEN
        
        # Record failure - should immediately open
        circuit_breaker.record_failure(backend)
        
        assert circuit_breaker.get_state(backend) == CircuitState.OPEN
    
    def test_reset_clears_state(self, circuit_breaker):
        """Test reset clears backend state."""
        backend = "backend"
        
        # Open the circuit
        for _ in range(3):
            circuit_breaker.record_failure(backend)
        
        assert circuit_breaker.get_state(backend) == CircuitState.OPEN
        
        # Reset
        circuit_breaker.reset(backend)
        
        # Should be CLOSED again
        assert circuit_breaker.get_state(backend) == CircuitState.CLOSED
    
    def test_stats_includes_all_fields(self, circuit_breaker):
        """Test stats includes all expected fields."""
        backend = "backend"
        circuit_breaker.record_success(backend)
        circuit_breaker.record_failure(backend)
        
        stats = circuit_breaker.get_stats(backend)
        
        assert "backend" in stats
        assert "state" in stats
        assert "total_failures" in stats
        assert "total_successes" in stats
        assert "times_opened" in stats
        assert "failures_in_window" in stats
        assert "consecutive_successes" in stats
        assert "time_until_recovery" in stats
    
    def test_per_backend_isolation(self, circuit_breaker):
        """Test each backend has isolated state."""
        backend1 = "backend1"
        backend2 = "backend2"
        
        # Open circuit for backend1
        for _ in range(3):
            circuit_breaker.record_failure(backend1)
        
        # Backend1 should be OPEN
        assert circuit_breaker.get_state(backend1) == CircuitState.OPEN
        
        # Backend2 should still be CLOSED
        assert circuit_breaker.get_state(backend2) == CircuitState.CLOSED


# ========================================
# CircuitBreakerContext Tests
# ========================================

class TestCircuitBreakerContext:
    """Tests for CircuitBreakerContext."""
    
    @pytest.mark.asyncio
    async def test_success_records_success(self, circuit_breaker):
        """Test successful execution records success."""
        backend = "backend"
        
        async with CircuitBreakerContext(circuit_breaker, backend):
            pass  # Success
        
        stats = circuit_breaker.get_stats(backend)
        assert stats["total_successes"] == 1
    
    @pytest.mark.asyncio
    async def test_exception_records_failure(self, circuit_breaker):
        """Test exception records failure."""
        backend = "backend"
        
        with pytest.raises(ValueError):
            async with CircuitBreakerContext(circuit_breaker, backend):
                raise ValueError("Test error")
        
        stats = circuit_breaker.get_stats(backend)
        assert stats["total_failures"] == 1
    
    @pytest.mark.asyncio
    async def test_mark_failure_records_failure(self, circuit_breaker):
        """Test mark_failure() records failure."""
        backend = "backend"
        
        async with CircuitBreakerContext(circuit_breaker, backend) as ctx:
            ctx.mark_failure()
        
        stats = circuit_breaker.get_stats(backend)
        assert stats["total_failures"] == 1
    
    @pytest.mark.asyncio
    async def test_open_circuit_raises_exception(self, circuit_breaker):
        """Test open circuit raises CircuitBreakerOpen."""
        backend = "backend"
        
        # Open the circuit
        for _ in range(3):
            circuit_breaker.record_failure(backend)
        
        with pytest.raises(CircuitBreakerOpen) as exc_info:
            async with CircuitBreakerContext(circuit_breaker, backend):
                pass
        
        assert exc_info.value.backend == backend


# ========================================
# with_circuit_breaker Decorator Tests
# ========================================

class TestWithCircuitBreakerDecorator:
    """Tests for with_circuit_breaker decorator."""
    
    @pytest.mark.asyncio
    async def test_decorator_success(self, circuit_breaker):
        """Test decorator with successful function."""
        backend = "backend"
        
        @with_circuit_breaker(circuit_breaker, backend)
        async def my_function():
            return "success"
        
        result = await my_function()
        
        assert result == "success"
        stats = circuit_breaker.get_stats(backend)
        assert stats["total_successes"] == 1
    
    @pytest.mark.asyncio
    async def test_decorator_failure(self, circuit_breaker):
        """Test decorator with failing function."""
        backend = "backend"
        
        @with_circuit_breaker(circuit_breaker, backend)
        async def failing_function():
            raise ConnectionError("Failed")
        
        with pytest.raises(ConnectionError):
            await failing_function()
        
        stats = circuit_breaker.get_stats(backend)
        assert stats["total_failures"] == 1


# ========================================
# CircuitBreakerHTTPClient Tests
# ========================================

class TestCircuitBreakerHTTPClient:
    """Tests for CircuitBreakerHTTPClient."""
    
    def test_extract_backend(self, fast_config):
        """Test backend extraction from URL."""
        mock_http = MagicMock()
        client = CircuitBreakerHTTPClient(mock_http, fast_config)
        
        backend = client._extract_backend("http://api.example.com:8080/path")
        assert backend == "http://api.example.com:8080"
        
        backend = client._extract_backend("https://secure.api.com/v1/resource")
        assert backend == "https://secure.api.com"
    
    @pytest.mark.asyncio
    async def test_get_success(self, fast_config):
        """Test successful GET request."""
        mock_http = MagicMock()
        mock_http.request = AsyncMock(return_value=MagicMock(status_code=200))
        
        client = CircuitBreakerHTTPClient(mock_http, fast_config)
        response = await client.get("http://api.example.com/resource")
        
        assert response.status_code == 200
        mock_http.request.assert_called_once()
    
    @pytest.mark.asyncio
    async def test_server_error_marks_failure(self, fast_config):
        """Test server error marks failure."""
        mock_http = MagicMock()
        mock_http.request = AsyncMock(return_value=MagicMock(status_code=500))
        
        client = CircuitBreakerHTTPClient(mock_http, fast_config)
        
        # Make requests until circuit opens
        for _ in range(3):
            await client.get("http://api.example.com/resource")
        
        # Next request should fail with CircuitBreakerOpen
        with pytest.raises(CircuitBreakerOpen):
            await client.get("http://api.example.com/resource")
    
    @pytest.mark.asyncio
    async def test_get_all_stats(self, fast_config):
        """Test getting stats for all backends."""
        mock_http = MagicMock()
        mock_http.request = AsyncMock(return_value=MagicMock(status_code=200))
        
        client = CircuitBreakerHTTPClient(mock_http, fast_config)
        
        await client.get("http://backend1.com/api")
        await client.get("http://backend2.com/api")
        
        stats = client.get_all_stats()
        
        assert "http://backend1.com" in stats
        assert "http://backend2.com" in stats


# ========================================
# CircuitBreakerRegistry Tests
# ========================================

class TestCircuitBreakerRegistry:
    """Tests for CircuitBreakerRegistry."""
    
    def test_get_or_create(self):
        """Test get_or_create creates new breaker."""
        registry = CircuitBreakerRegistry()
        
        cb = registry.get_or_create("test-breaker")
        
        assert cb is not None
        assert isinstance(cb, CircuitBreaker)
    
    def test_get_or_create_returns_same(self):
        """Test get_or_create returns same breaker."""
        registry = CircuitBreakerRegistry()
        
        cb1 = registry.get_or_create("test-breaker")
        cb2 = registry.get_or_create("test-breaker")
        
        assert cb1 is cb2
    
    def test_get_returns_none_if_not_exists(self):
        """Test get returns None if not exists."""
        registry = CircuitBreakerRegistry()
        
        cb = registry.get("nonexistent")
        
        assert cb is None
    
    def test_reset_removes_breaker(self):
        """Test reset removes breaker."""
        registry = CircuitBreakerRegistry()
        
        cb = registry.get_or_create("test-breaker")
        registry.reset("test-breaker")
        
        assert registry.get("test-breaker") is None


# ========================================
# Global Functions Tests
# ========================================

class TestGlobalFunctions:
    """Tests for global circuit breaker functions."""
    
    def test_get_circuit_breaker(self):
        """Test get_circuit_breaker returns breaker."""
        cb = get_circuit_breaker("test-global")
        
        assert cb is not None
        assert isinstance(cb, CircuitBreaker)
    
    def test_get_all_circuit_breaker_stats(self):
        """Test get_all_circuit_breaker_stats returns dict."""
        # Create some breakers with activity
        cb = get_circuit_breaker("stats-test")
        cb.record_success("backend-a")
        
        stats = get_all_circuit_breaker_stats()
        
        assert isinstance(stats, dict)


# ========================================
# State Transitions Tests
# ========================================

class TestStateTransitions:
    """Tests for state machine transitions."""
    
    def test_closed_to_open(self, fast_config):
        """Test CLOSED → OPEN transition."""
        cb = CircuitBreaker(fast_config)
        backend = "test"
        
        # Initial state
        assert cb.get_state(backend) == CircuitState.CLOSED
        
        # Record failures
        for _ in range(3):
            cb.record_failure(backend)
        
        # Should be OPEN
        assert cb.get_state(backend) == CircuitState.OPEN
        
        stats = cb.get_stats(backend)
        assert stats["times_opened"] == 1
    
    def test_open_to_half_open(self, fast_config):
        """Test OPEN → HALF_OPEN transition."""
        cb = CircuitBreaker(fast_config)
        backend = "test"
        
        # Open the circuit
        for _ in range(3):
            cb.record_failure(backend)
        
        assert cb.get_state(backend) == CircuitState.OPEN
        
        # Wait for recovery
        time.sleep(0.15)
        
        assert cb.get_state(backend) == CircuitState.HALF_OPEN
    
    def test_half_open_to_closed(self, fast_config):
        """Test HALF_OPEN → CLOSED transition."""
        cb = CircuitBreaker(fast_config)
        backend = "test"
        
        # Open and wait for half-open
        for _ in range(3):
            cb.record_failure(backend)
        time.sleep(0.15)
        
        assert cb.get_state(backend) == CircuitState.HALF_OPEN
        
        # Record successes
        cb.record_success(backend)
        cb.record_success(backend)
        
        assert cb.get_state(backend) == CircuitState.CLOSED
    
    def test_half_open_to_open(self, fast_config):
        """Test HALF_OPEN → OPEN transition on failure."""
        cb = CircuitBreaker(fast_config)
        backend = "test"
        
        # Open and wait for half-open
        for _ in range(3):
            cb.record_failure(backend)
        time.sleep(0.15)
        
        assert cb.get_state(backend) == CircuitState.HALF_OPEN
        
        # Record failure
        cb.record_failure(backend)
        
        assert cb.get_state(backend) == CircuitState.OPEN
        
        stats = cb.get_stats(backend)
        assert stats["times_opened"] == 2  # Opened twice


# ========================================
# Sliding Window Tests
# ========================================

class TestSlidingWindow:
    """Tests for sliding window failure tracking."""
    
    def test_old_failures_pruned(self):
        """Test old failures outside window are pruned."""
        config = CircuitBreakerConfig(
            failure_threshold=3,
            failure_window=0.1,  # 100ms window
        )
        cb = CircuitBreaker(config)
        backend = "test"
        
        # Record 2 failures
        cb.record_failure(backend)
        cb.record_failure(backend)
        
        # Wait for failures to expire
        time.sleep(0.15)
        
        # Record 2 more failures
        cb.record_failure(backend)
        cb.record_failure(backend)
        
        # Should still be CLOSED because old failures expired
        assert cb.get_state(backend) == CircuitState.CLOSED


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])