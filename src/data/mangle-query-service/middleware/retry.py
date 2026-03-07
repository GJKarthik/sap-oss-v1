"""
Retry Middleware with Exponential Backoff

Day 2 Deliverable: Robust retry logic for HTTP requests
- Exponential backoff (1s, 2s, 4s, 8s max)
- Jitter to prevent thundering herd
- Configurable retry conditions
- Integration with HTTP client

Prevents cascade failures from transient errors.
"""

import asyncio
import random
import time
import logging
from typing import Optional, Callable, Any, TypeVar, Awaitable, Set, Type
from dataclasses import dataclass, field
from functools import wraps
from enum import Enum

logger = logging.getLogger(__name__)


# ========================================
# Configuration
# ========================================

class RetryStrategy(Enum):
    """Retry strategy types."""
    EXPONENTIAL = "exponential"
    LINEAR = "linear"
    FIXED = "fixed"


@dataclass
class RetryConfig:
    """Retry configuration."""
    
    # Max retry attempts (not including initial request)
    max_retries: int = 3
    
    # Base delay in seconds
    base_delay: float = 1.0
    
    # Max delay cap in seconds
    max_delay: float = 8.0
    
    # Multiplier for exponential backoff
    exponential_base: float = 2.0
    
    # Jitter factor (0.0 to 1.0)
    # 0.5 means delay can vary by ±50%
    jitter_factor: float = 0.25
    
    # Strategy
    strategy: RetryStrategy = RetryStrategy.EXPONENTIAL
    
    # Retryable status codes (5xx by default)
    retryable_status_codes: Set[int] = field(default_factory=lambda: {
        500, 502, 503, 504, 429  # Server errors + rate limiting
    })
    
    # Non-retryable status codes (client errors)
    non_retryable_status_codes: Set[int] = field(default_factory=lambda: {
        400, 401, 403, 404, 405, 422  # Client errors - don't retry
    })
    
    # Retryable exceptions
    retryable_exceptions: tuple = field(default_factory=lambda: (
        ConnectionError,
        TimeoutError,
        asyncio.TimeoutError,
    ))
    
    @classmethod
    def aggressive(cls) -> "RetryConfig":
        """Aggressive retry config for critical requests."""
        return cls(
            max_retries=5,
            base_delay=0.5,
            max_delay=16.0,
            jitter_factor=0.3,
        )
    
    @classmethod
    def conservative(cls) -> "RetryConfig":
        """Conservative retry config for non-critical requests."""
        return cls(
            max_retries=2,
            base_delay=2.0,
            max_delay=8.0,
            jitter_factor=0.2,
        )
    
    @classmethod
    def no_retry(cls) -> "RetryConfig":
        """No retry - for idempotency-sensitive operations."""
        return cls(max_retries=0)


# ========================================
# Backoff Calculation
# ========================================

def calculate_delay(
    attempt: int,
    config: RetryConfig,
) -> float:
    """
    Calculate delay for retry attempt.
    
    Args:
        attempt: Current attempt number (1-indexed)
        config: Retry configuration
        
    Returns:
        Delay in seconds with jitter applied
    """
    if config.strategy == RetryStrategy.EXPONENTIAL:
        # Exponential: base * (exp_base ^ attempt)
        # attempt 1: 1 * 2^1 = 2s
        # attempt 2: 1 * 2^2 = 4s
        # attempt 3: 1 * 2^3 = 8s
        delay = config.base_delay * (config.exponential_base ** attempt)
    
    elif config.strategy == RetryStrategy.LINEAR:
        # Linear: base * attempt
        delay = config.base_delay * attempt
    
    else:  # FIXED
        delay = config.base_delay
    
    # Cap at max delay
    delay = min(delay, config.max_delay)
    
    # Apply jitter
    if config.jitter_factor > 0:
        jitter_range = delay * config.jitter_factor
        jitter = random.uniform(-jitter_range, jitter_range)
        delay = max(0.1, delay + jitter)  # Minimum 100ms
    
    return delay


# ========================================
# Retry Context
# ========================================

@dataclass
class RetryContext:
    """Context for retry operation."""
    
    attempt: int = 0
    total_attempts: int = 0
    total_delay: float = 0.0
    last_error: Optional[Exception] = None
    last_status_code: Optional[int] = None
    start_time: float = field(default_factory=time.time)
    
    @property
    def elapsed_time(self) -> float:
        """Total elapsed time."""
        return time.time() - self.start_time
    
    def record_attempt(self, delay: float = 0.0):
        """Record an attempt."""
        self.attempt += 1
        self.total_attempts += 1
        self.total_delay += delay
    
    def record_error(self, error: Exception):
        """Record an error."""
        self.last_error = error
    
    def record_status_code(self, status_code: int):
        """Record HTTP status code."""
        self.last_status_code = status_code
    
    def to_dict(self) -> dict:
        """Convert to dict for logging."""
        return {
            "attempt": self.attempt,
            "total_attempts": self.total_attempts,
            "total_delay_ms": self.total_delay * 1000,
            "elapsed_ms": self.elapsed_time * 1000,
            "last_error": str(self.last_error) if self.last_error else None,
            "last_status_code": self.last_status_code,
        }


# ========================================
# Retry Logic
# ========================================

def is_retryable_status_code(status_code: int, config: RetryConfig) -> bool:
    """Check if status code is retryable."""
    if status_code in config.non_retryable_status_codes:
        return False
    if status_code in config.retryable_status_codes:
        return True
    # Default: retry 5xx, don't retry 4xx
    return status_code >= 500


def is_retryable_exception(
    exception: Exception,
    config: RetryConfig,
) -> bool:
    """Check if exception is retryable."""
    return isinstance(exception, config.retryable_exceptions)


T = TypeVar("T")


async def retry_async(
    func: Callable[[], Awaitable[T]],
    config: Optional[RetryConfig] = None,
    on_retry: Optional[Callable[[RetryContext], None]] = None,
) -> T:
    """
    Execute async function with retry logic.
    
    Args:
        func: Async function to execute
        config: Retry configuration
        on_retry: Optional callback before each retry
        
    Returns:
        Result from successful function call
        
    Raises:
        Last exception if all retries exhausted
    """
    config = config or RetryConfig()
    context = RetryContext()
    
    last_exception: Optional[Exception] = None
    
    for attempt in range(config.max_retries + 1):
        context.record_attempt()
        
        try:
            result = await func()
            
            # Check if result has status_code (HTTP response)
            if hasattr(result, 'status_code'):
                status_code = result.status_code
                context.record_status_code(status_code)
                
                if is_retryable_status_code(status_code, config):
                    if attempt < config.max_retries:
                        delay = calculate_delay(attempt + 1, config)
                        
                        logger.warning(
                            f"Retryable status {status_code}, "
                            f"attempt {attempt + 1}/{config.max_retries + 1}, "
                            f"waiting {delay:.2f}s",
                            extra={"retry_context": context.to_dict()}
                        )
                        
                        if on_retry:
                            on_retry(context)
                        
                        await asyncio.sleep(delay)
                        context.total_delay += delay
                        continue
            
            # Success
            if context.total_attempts > 1:
                logger.info(
                    f"Request succeeded after {context.total_attempts} attempts",
                    extra={"retry_context": context.to_dict()}
                )
            
            return result
            
        except Exception as e:
            last_exception = e
            context.record_error(e)
            
            if not is_retryable_exception(e, config):
                logger.error(
                    f"Non-retryable exception: {type(e).__name__}: {e}",
                    extra={"retry_context": context.to_dict()}
                )
                raise
            
            if attempt < config.max_retries:
                delay = calculate_delay(attempt + 1, config)
                
                logger.warning(
                    f"Retryable exception {type(e).__name__}, "
                    f"attempt {attempt + 1}/{config.max_retries + 1}, "
                    f"waiting {delay:.2f}s",
                    extra={"retry_context": context.to_dict()}
                )
                
                if on_retry:
                    on_retry(context)
                
                await asyncio.sleep(delay)
                context.total_delay += delay
            else:
                logger.error(
                    f"All {config.max_retries + 1} attempts failed",
                    extra={"retry_context": context.to_dict()}
                )
    
    # All retries exhausted
    if last_exception:
        raise last_exception
    
    # Should never reach here
    raise RuntimeError("Retry logic error: no result or exception")


# ========================================
# Decorator
# ========================================

def with_retry(
    config: Optional[RetryConfig] = None,
    on_retry: Optional[Callable[[RetryContext], None]] = None,
):
    """
    Decorator to add retry logic to async functions.
    
    Usage:
        @with_retry(RetryConfig(max_retries=3))
        async def make_request():
            return await client.get(url)
    """
    def decorator(func: Callable[..., Awaitable[T]]) -> Callable[..., Awaitable[T]]:
        @wraps(func)
        async def wrapper(*args, **kwargs) -> T:
            async def call():
                return await func(*args, **kwargs)
            return await retry_async(call, config, on_retry)
        return wrapper
    return decorator


# ========================================
# HTTP Client Integration
# ========================================

class RetryableHTTPClient:
    """
    HTTP client wrapper with automatic retry.
    
    Wraps AsyncHTTPClient with retry logic.
    
    Usage:
        from connectors.http_client import AsyncHTTPClient
        
        client = RetryableHTTPClient(AsyncHTTPClient())
        response = await client.post(url, json=data)
    """
    
    def __init__(
        self,
        http_client,
        config: Optional[RetryConfig] = None,
    ):
        self.http_client = http_client
        self.config = config or RetryConfig()
    
    async def request(
        self,
        method: str,
        url: str,
        config: Optional[RetryConfig] = None,
        **kwargs,
    ):
        """Make HTTP request with retry."""
        retry_config = config or self.config
        
        async def make_request():
            return await self.http_client.request(method, url, **kwargs)
        
        return await retry_async(make_request, retry_config)
    
    async def get(self, url: str, **kwargs):
        """GET with retry."""
        return await self.request("GET", url, **kwargs)
    
    async def post(self, url: str, **kwargs):
        """POST with retry."""
        return await self.request("POST", url, **kwargs)
    
    async def put(self, url: str, **kwargs):
        """PUT with retry."""
        return await self.request("PUT", url, **kwargs)
    
    async def delete(self, url: str, **kwargs):
        """DELETE with retry."""
        return await self.request("DELETE", url, **kwargs)


# ========================================
# Structured Errors
# ========================================

@dataclass
class StructuredError:
    """Structured error response for API."""
    
    error_code: str
    message: str
    details: Optional[dict] = None
    retry_after: Optional[float] = None
    request_id: Optional[str] = None
    
    def to_dict(self) -> dict:
        """Convert to dict for JSON response."""
        result = {
            "error": {
                "code": self.error_code,
                "message": self.message,
            }
        }
        if self.details:
            result["error"]["details"] = self.details
        if self.retry_after is not None:
            result["error"]["retry_after"] = self.retry_after
        if self.request_id:
            result["error"]["request_id"] = self.request_id
        return result


class ErrorCodes:
    """Standard error codes."""
    
    # Client errors
    BAD_REQUEST = "BAD_REQUEST"
    UNAUTHORIZED = "UNAUTHORIZED"
    FORBIDDEN = "FORBIDDEN"
    NOT_FOUND = "NOT_FOUND"
    VALIDATION_ERROR = "VALIDATION_ERROR"
    
    # Server errors
    INTERNAL_ERROR = "INTERNAL_ERROR"
    SERVICE_UNAVAILABLE = "SERVICE_UNAVAILABLE"
    TIMEOUT = "TIMEOUT"
    RATE_LIMITED = "RATE_LIMITED"
    
    # Backend errors
    BACKEND_ERROR = "BACKEND_ERROR"
    BACKEND_TIMEOUT = "BACKEND_TIMEOUT"
    BACKEND_UNAVAILABLE = "BACKEND_UNAVAILABLE"
    
    # Retry exhausted
    RETRY_EXHAUSTED = "RETRY_EXHAUSTED"


def create_error_from_status(
    status_code: int,
    message: str,
    details: Optional[dict] = None,
    request_id: Optional[str] = None,
) -> StructuredError:
    """Create structured error from HTTP status code."""
    
    error_code_map = {
        400: ErrorCodes.BAD_REQUEST,
        401: ErrorCodes.UNAUTHORIZED,
        403: ErrorCodes.FORBIDDEN,
        404: ErrorCodes.NOT_FOUND,
        422: ErrorCodes.VALIDATION_ERROR,
        429: ErrorCodes.RATE_LIMITED,
        500: ErrorCodes.INTERNAL_ERROR,
        502: ErrorCodes.BACKEND_ERROR,
        503: ErrorCodes.SERVICE_UNAVAILABLE,
        504: ErrorCodes.BACKEND_TIMEOUT,
    }
    
    error_code = error_code_map.get(status_code, ErrorCodes.INTERNAL_ERROR)
    
    retry_after = None
    if status_code == 429:
        retry_after = 60.0  # Default retry-after for rate limiting
    
    return StructuredError(
        error_code=error_code,
        message=message,
        details=details,
        retry_after=retry_after,
        request_id=request_id,
    )


def create_error_from_exception(
    exception: Exception,
    request_id: Optional[str] = None,
) -> StructuredError:
    """Create structured error from exception."""
    
    if isinstance(exception, TimeoutError):
        return StructuredError(
            error_code=ErrorCodes.TIMEOUT,
            message="Request timed out",
            details={"exception": str(exception)},
            retry_after=5.0,
            request_id=request_id,
        )
    
    if isinstance(exception, ConnectionError):
        return StructuredError(
            error_code=ErrorCodes.BACKEND_UNAVAILABLE,
            message="Backend service unavailable",
            details={"exception": str(exception)},
            retry_after=10.0,
            request_id=request_id,
        )
    
    return StructuredError(
        error_code=ErrorCodes.INTERNAL_ERROR,
        message="An unexpected error occurred",
        details={"exception": str(exception), "type": type(exception).__name__},
        request_id=request_id,
    )