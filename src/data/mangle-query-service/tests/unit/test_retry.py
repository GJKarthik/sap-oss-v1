"""
Unit Tests for Retry Middleware

Day 2 Deliverable: Comprehensive tests for retry.py
Target: >80% code coverage
"""

import asyncio
import pytest
import time
from unittest.mock import AsyncMock, MagicMock, patch
from dataclasses import dataclass

from mangle_query_service.middleware.retry import (
    RetryStrategy,
    RetryConfig,
    RetryContext,
    calculate_delay,
    is_retryable_status_code,
    is_retryable_exception,
    retry_async,
    with_retry,
    RetryableHTTPClient,
    StructuredError,
    ErrorCodes,
    create_error_from_status,
    create_error_from_exception,
)


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def default_config():
    """Default retry configuration."""
    return RetryConfig()


@pytest.fixture
def fast_config():
    """Fast retry config for testing."""
    return RetryConfig(
        max_retries=2,
        base_delay=0.01,  # 10ms for fast tests
        max_delay=0.05,
        jitter_factor=0.0,  # No jitter for deterministic tests
    )


# ========================================
# RetryConfig Tests
# ========================================

class TestRetryConfig:
    """Tests for RetryConfig."""
    
    def test_default_values(self):
        """Test default configuration values."""
        config = RetryConfig()
        
        assert config.max_retries == 3
        assert config.base_delay == 1.0
        assert config.max_delay == 8.0
        assert config.exponential_base == 2.0
        assert config.jitter_factor == 0.25
        assert config.strategy == RetryStrategy.EXPONENTIAL
    
    def test_aggressive_preset(self):
        """Test aggressive preset."""
        config = RetryConfig.aggressive()
        
        assert config.max_retries == 5
        assert config.base_delay == 0.5
        assert config.max_delay == 16.0
    
    def test_conservative_preset(self):
        """Test conservative preset."""
        config = RetryConfig.conservative()
        
        assert config.max_retries == 2
        assert config.base_delay == 2.0
    
    def test_no_retry_preset(self):
        """Test no retry preset."""
        config = RetryConfig.no_retry()
        
        assert config.max_retries == 0
    
    def test_retryable_status_codes(self):
        """Test default retryable status codes."""
        config = RetryConfig()
        
        assert 500 in config.retryable_status_codes
        assert 502 in config.retryable_status_codes
        assert 503 in config.retryable_status_codes
        assert 504 in config.retryable_status_codes
        assert 429 in config.retryable_status_codes
    
    def test_non_retryable_status_codes(self):
        """Test default non-retryable status codes."""
        config = RetryConfig()
        
        assert 400 in config.non_retryable_status_codes
        assert 401 in config.non_retryable_status_codes
        assert 404 in config.non_retryable_status_codes


# ========================================
# calculate_delay Tests
# ========================================

class TestCalculateDelay:
    """Tests for delay calculation."""
    
    def test_exponential_backoff(self):
        """Test exponential backoff delay calculation."""
        config = RetryConfig(
            base_delay=1.0,
            exponential_base=2.0,
            max_delay=100.0,
            jitter_factor=0.0,
            strategy=RetryStrategy.EXPONENTIAL,
        )
        
        # attempt 1: 1 * 2^1 = 2
        assert calculate_delay(1, config) == 2.0
        # attempt 2: 1 * 2^2 = 4
        assert calculate_delay(2, config) == 4.0
        # attempt 3: 1 * 2^3 = 8
        assert calculate_delay(3, config) == 8.0
    
    def test_linear_backoff(self):
        """Test linear backoff delay calculation."""
        config = RetryConfig(
            base_delay=2.0,
            max_delay=100.0,
            jitter_factor=0.0,
            strategy=RetryStrategy.LINEAR,
        )
        
        # attempt 1: 2 * 1 = 2
        assert calculate_delay(1, config) == 2.0
        # attempt 2: 2 * 2 = 4
        assert calculate_delay(2, config) == 4.0
        # attempt 3: 2 * 3 = 6
        assert calculate_delay(3, config) == 6.0
    
    def test_fixed_delay(self):
        """Test fixed delay strategy."""
        config = RetryConfig(
            base_delay=3.0,
            jitter_factor=0.0,
            strategy=RetryStrategy.FIXED,
        )
        
        assert calculate_delay(1, config) == 3.0
        assert calculate_delay(2, config) == 3.0
        assert calculate_delay(3, config) == 3.0
    
    def test_max_delay_cap(self):
        """Test max delay is capped."""
        config = RetryConfig(
            base_delay=1.0,
            exponential_base=2.0,
            max_delay=5.0,
            jitter_factor=0.0,
            strategy=RetryStrategy.EXPONENTIAL,
        )
        
        # attempt 3: 1 * 2^3 = 8, capped to 5
        assert calculate_delay(3, config) == 5.0
        # attempt 4: 1 * 2^4 = 16, capped to 5
        assert calculate_delay(4, config) == 5.0
    
    def test_jitter_applied(self):
        """Test jitter is applied within expected range."""
        config = RetryConfig(
            base_delay=1.0,
            exponential_base=2.0,
            max_delay=100.0,
            jitter_factor=0.25,
            strategy=RetryStrategy.EXPONENTIAL,
        )
        
        # Run multiple times to check jitter variation
        delays = [calculate_delay(1, config) for _ in range(100)]
        
        # Base delay at attempt 1 = 2.0
        # With 25% jitter, range should be ~1.5 to ~2.5
        min_delay = min(delays)
        max_delay = max(delays)
        
        assert min_delay >= 1.4  # Allow some margin
        assert max_delay <= 2.6
        # Should have variation (not all same value)
        assert max_delay > min_delay


# ========================================
# RetryContext Tests
# ========================================

class TestRetryContext:
    """Tests for RetryContext."""
    
    def test_initial_state(self):
        """Test initial context state."""
        context = RetryContext()
        
        assert context.attempt == 0
        assert context.total_attempts == 0
        assert context.total_delay == 0.0
        assert context.last_error is None
        assert context.last_status_code is None
    
    def test_record_attempt(self):
        """Test recording attempts."""
        context = RetryContext()
        
        context.record_attempt()
        assert context.attempt == 1
        assert context.total_attempts == 1
        
        context.record_attempt()
        assert context.attempt == 2
        assert context.total_attempts == 2
    
    def test_record_error(self):
        """Test recording errors."""
        context = RetryContext()
        error = ValueError("test error")
        
        context.record_error(error)
        
        assert context.last_error is error
    
    def test_record_status_code(self):
        """Test recording status codes."""
        context = RetryContext()
        
        context.record_status_code(500)
        
        assert context.last_status_code == 500
    
    def test_elapsed_time(self):
        """Test elapsed time calculation."""
        context = RetryContext()
        
        time.sleep(0.01)  # 10ms
        
        assert context.elapsed_time >= 0.01
    
    def test_to_dict(self):
        """Test conversion to dict."""
        context = RetryContext()
        context.record_attempt()
        context.record_status_code(503)
        
        result = context.to_dict()
        
        assert result["attempt"] == 1
        assert result["total_attempts"] == 1
        assert result["last_status_code"] == 503
        assert "elapsed_ms" in result


# ========================================
# is_retryable Tests
# ========================================

class TestIsRetryable:
    """Tests for retryable checks."""
    
    def test_retryable_status_codes(self):
        """Test retryable status code detection."""
        config = RetryConfig()
        
        assert is_retryable_status_code(500, config) is True
        assert is_retryable_status_code(502, config) is True
        assert is_retryable_status_code(503, config) is True
        assert is_retryable_status_code(504, config) is True
        assert is_retryable_status_code(429, config) is True
    
    def test_non_retryable_status_codes(self):
        """Test non-retryable status code detection."""
        config = RetryConfig()
        
        assert is_retryable_status_code(400, config) is False
        assert is_retryable_status_code(401, config) is False
        assert is_retryable_status_code(403, config) is False
        assert is_retryable_status_code(404, config) is False
    
    def test_success_codes_not_retryable(self):
        """Test success codes are not retryable."""
        config = RetryConfig()
        
        assert is_retryable_status_code(200, config) is False
        assert is_retryable_status_code(201, config) is False
        assert is_retryable_status_code(204, config) is False
    
    def test_retryable_exceptions(self):
        """Test retryable exception detection."""
        config = RetryConfig()
        
        assert is_retryable_exception(ConnectionError(), config) is True
        assert is_retryable_exception(TimeoutError(), config) is True
        assert is_retryable_exception(asyncio.TimeoutError(), config) is True
    
    def test_non_retryable_exceptions(self):
        """Test non-retryable exceptions."""
        config = RetryConfig()
        
        assert is_retryable_exception(ValueError(), config) is False
        assert is_retryable_exception(TypeError(), config) is False
        assert is_retryable_exception(KeyError(), config) is False


# ========================================
# retry_async Tests
# ========================================

class TestRetryAsync:
    """Tests for async retry function."""
    
    @pytest.mark.asyncio
    async def test_success_first_try(self, fast_config):
        """Test success on first attempt."""
        call_count = 0
        
        async def success():
            nonlocal call_count
            call_count += 1
            return "success"
        
        result = await retry_async(success, fast_config)
        
        assert result == "success"
        assert call_count == 1
    
    @pytest.mark.asyncio
    async def test_success_after_retry(self, fast_config):
        """Test success after retries."""
        call_count = 0
        
        async def fail_then_succeed():
            nonlocal call_count
            call_count += 1
            if call_count < 3:
                raise ConnectionError("Temporary failure")
            return "success"
        
        result = await retry_async(fail_then_succeed, fast_config)
        
        assert result == "success"
        assert call_count == 3
    
    @pytest.mark.asyncio
    async def test_all_retries_exhausted(self, fast_config):
        """Test all retries exhausted raises exception."""
        call_count = 0
        
        async def always_fail():
            nonlocal call_count
            call_count += 1
            raise ConnectionError("Persistent failure")
        
        with pytest.raises(ConnectionError):
            await retry_async(always_fail, fast_config)
        
        # max_retries=2 means 3 total attempts
        assert call_count == 3
    
    @pytest.mark.asyncio
    async def test_non_retryable_exception(self, fast_config):
        """Test non-retryable exception raises immediately."""
        call_count = 0
        
        async def bad_request():
            nonlocal call_count
            call_count += 1
            raise ValueError("Bad request")
        
        with pytest.raises(ValueError):
            await retry_async(bad_request, fast_config)
        
        # Should fail immediately without retry
        assert call_count == 1
    
    @pytest.mark.asyncio
    async def test_retryable_status_code(self, fast_config):
        """Test retry on retryable status code."""
        call_count = 0
        
        @dataclass
        class MockResponse:
            status_code: int
        
        async def return_503_then_200():
            nonlocal call_count
            call_count += 1
            if call_count < 3:
                return MockResponse(status_code=503)
            return MockResponse(status_code=200)
        
        result = await retry_async(return_503_then_200, fast_config)
        
        assert result.status_code == 200
        assert call_count == 3
    
    @pytest.mark.asyncio
    async def test_no_retry_on_success_status(self, fast_config):
        """Test no retry on success status codes."""
        call_count = 0
        
        @dataclass
        class MockResponse:
            status_code: int
        
        async def return_200():
            nonlocal call_count
            call_count += 1
            return MockResponse(status_code=200)
        
        result = await retry_async(return_200, fast_config)
        
        assert result.status_code == 200
        assert call_count == 1
    
    @pytest.mark.asyncio
    async def test_no_retry_on_client_error(self, fast_config):
        """Test no retry on client error status codes."""
        call_count = 0
        
        @dataclass
        class MockResponse:
            status_code: int
        
        async def return_400():
            nonlocal call_count
            call_count += 1
            return MockResponse(status_code=400)
        
        result = await retry_async(return_400, fast_config)
        
        assert result.status_code == 400
        assert call_count == 1
    
    @pytest.mark.asyncio
    async def test_on_retry_callback(self, fast_config):
        """Test on_retry callback is called."""
        call_count = 0
        retry_contexts = []
        
        async def fail_twice():
            nonlocal call_count
            call_count += 1
            if call_count < 3:
                raise ConnectionError("Fail")
            return "success"
        
        def on_retry(context):
            retry_contexts.append(context.attempt)
        
        await retry_async(fail_twice, fast_config, on_retry=on_retry)
        
        # Called before 2nd and 3rd attempts
        assert len(retry_contexts) == 2


# ========================================
# with_retry Decorator Tests
# ========================================

class TestWithRetryDecorator:
    """Tests for with_retry decorator."""
    
    @pytest.mark.asyncio
    async def test_decorator_success(self):
        """Test decorator with successful function."""
        call_count = 0
        config = RetryConfig(max_retries=2, base_delay=0.01, jitter_factor=0)
        
        @with_retry(config)
        async def my_function():
            nonlocal call_count
            call_count += 1
            return "result"
        
        result = await my_function()
        
        assert result == "result"
        assert call_count == 1
    
    @pytest.mark.asyncio
    async def test_decorator_retry(self):
        """Test decorator with retries."""
        call_count = 0
        config = RetryConfig(max_retries=2, base_delay=0.01, jitter_factor=0)
        
        @with_retry(config)
        async def fail_then_succeed():
            nonlocal call_count
            call_count += 1
            if call_count < 2:
                raise TimeoutError("Timeout")
            return "success"
        
        result = await fail_then_succeed()
        
        assert result == "success"
        assert call_count == 2


# ========================================
# RetryableHTTPClient Tests
# ========================================

class TestRetryableHTTPClient:
    """Tests for RetryableHTTPClient."""
    
    @pytest.mark.asyncio
    async def test_get_with_retry(self):
        """Test GET request with retry."""
        mock_http_client = MagicMock()
        mock_http_client.request = AsyncMock(return_value=MagicMock(status_code=200))
        
        config = RetryConfig(max_retries=1, base_delay=0.01, jitter_factor=0)
        client = RetryableHTTPClient(mock_http_client, config)
        
        result = await client.get("http://example.com")
        
        assert result.status_code == 200
        mock_http_client.request.assert_called_once()
    
    @pytest.mark.asyncio
    async def test_post_with_retry(self):
        """Test POST request with retry."""
        mock_http_client = MagicMock()
        mock_http_client.request = AsyncMock(return_value=MagicMock(status_code=201))
        
        config = RetryConfig(max_retries=1, base_delay=0.01, jitter_factor=0)
        client = RetryableHTTPClient(mock_http_client, config)
        
        result = await client.post("http://example.com", json={"key": "value"})
        
        assert result.status_code == 201


# ========================================
# StructuredError Tests
# ========================================

class TestStructuredError:
    """Tests for StructuredError."""
    
    def test_to_dict_basic(self):
        """Test basic to_dict conversion."""
        error = StructuredError(
            error_code="BAD_REQUEST",
            message="Invalid input",
        )
        
        result = error.to_dict()
        
        assert result["error"]["code"] == "BAD_REQUEST"
        assert result["error"]["message"] == "Invalid input"
    
    def test_to_dict_with_details(self):
        """Test to_dict with details."""
        error = StructuredError(
            error_code="VALIDATION_ERROR",
            message="Validation failed",
            details={"field": "email", "issue": "invalid format"},
        )
        
        result = error.to_dict()
        
        assert result["error"]["details"]["field"] == "email"
    
    def test_to_dict_with_retry_after(self):
        """Test to_dict with retry_after."""
        error = StructuredError(
            error_code="RATE_LIMITED",
            message="Rate limited",
            retry_after=60.0,
        )
        
        result = error.to_dict()
        
        assert result["error"]["retry_after"] == 60.0
    
    def test_to_dict_with_request_id(self):
        """Test to_dict with request_id."""
        error = StructuredError(
            error_code="INTERNAL_ERROR",
            message="Error",
            request_id="req-12345",
        )
        
        result = error.to_dict()
        
        assert result["error"]["request_id"] == "req-12345"


class TestErrorCodes:
    """Tests for ErrorCodes."""
    
    def test_error_code_values(self):
        """Test error code values exist."""
        assert ErrorCodes.BAD_REQUEST == "BAD_REQUEST"
        assert ErrorCodes.UNAUTHORIZED == "UNAUTHORIZED"
        assert ErrorCodes.INTERNAL_ERROR == "INTERNAL_ERROR"
        assert ErrorCodes.RATE_LIMITED == "RATE_LIMITED"
        assert ErrorCodes.BACKEND_TIMEOUT == "BACKEND_TIMEOUT"


class TestCreateErrorFromStatus:
    """Tests for create_error_from_status."""
    
    def test_400_error(self):
        """Test 400 error creation."""
        error = create_error_from_status(400, "Bad request")
        
        assert error.error_code == ErrorCodes.BAD_REQUEST
        assert error.message == "Bad request"
    
    def test_401_error(self):
        """Test 401 error creation."""
        error = create_error_from_status(401, "Unauthorized")
        
        assert error.error_code == ErrorCodes.UNAUTHORIZED
    
    def test_429_rate_limit(self):
        """Test 429 rate limit with retry_after."""
        error = create_error_from_status(429, "Rate limited")
        
        assert error.error_code == ErrorCodes.RATE_LIMITED
        assert error.retry_after == 60.0
    
    def test_500_error(self):
        """Test 500 error creation."""
        error = create_error_from_status(500, "Internal error")
        
        assert error.error_code == ErrorCodes.INTERNAL_ERROR
    
    def test_unknown_status(self):
        """Test unknown status defaults to INTERNAL_ERROR."""
        error = create_error_from_status(599, "Unknown error")
        
        assert error.error_code == ErrorCodes.INTERNAL_ERROR


class TestCreateErrorFromException:
    """Tests for create_error_from_exception."""
    
    def test_timeout_error(self):
        """Test TimeoutError conversion."""
        error = create_error_from_exception(TimeoutError("Timed out"))
        
        assert error.error_code == ErrorCodes.TIMEOUT
        assert error.retry_after == 5.0
    
    def test_connection_error(self):
        """Test ConnectionError conversion."""
        error = create_error_from_exception(ConnectionError("Failed to connect"))
        
        assert error.error_code == ErrorCodes.BACKEND_UNAVAILABLE
        assert error.retry_after == 10.0
    
    def test_generic_exception(self):
        """Test generic exception conversion."""
        error = create_error_from_exception(ValueError("Something went wrong"))
        
        assert error.error_code == ErrorCodes.INTERNAL_ERROR
        assert "ValueError" in error.details["type"]
    
    def test_with_request_id(self):
        """Test exception with request ID."""
        error = create_error_from_exception(
            ValueError("Error"),
            request_id="req-99999",
        )
        
        assert error.request_id == "req-99999"


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])