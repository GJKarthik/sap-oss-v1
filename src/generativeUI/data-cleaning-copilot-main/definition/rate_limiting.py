# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Rate limiting for Data Cleaning Copilot endpoints.

Provides:
- Token bucket rate limiting
- Sliding window rate limiting
- Per-client and global rate limits
- Configurable limits via environment variables
"""

import os
import time
import threading
import functools
from typing import Any, Callable, Dict, Optional, Tuple
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from loguru import logger

# =============================================================================
# Rate Limit Configuration
# =============================================================================

# Default rate limits (can be overridden via environment variables)
DEFAULT_RATE_LIMITS = {
    # Format: (requests_per_window, window_seconds)
    "mcp_tools_call": (100, 60),  # 100 requests per minute
    "mcp_resources_read": (200, 60),  # 200 requests per minute
    "api_chat": (30, 60),  # 30 requests per minute
    "api_validate": (20, 60),  # 20 requests per minute
    "llm_call": (50, 60),  # 50 LLM calls per minute
    "sandbox_execute": (100, 60),  # 100 sandbox executions per minute
    "global": (1000, 60),  # 1000 total requests per minute
}

# Per-client limits (more restrictive than global)
DEFAULT_CLIENT_LIMITS = {
    "mcp_tools_call": (20, 60),  # 20 per client per minute
    "api_chat": (10, 60),  # 10 per client per minute
    "llm_call": (10, 60),  # 10 LLM calls per client per minute
}


@dataclass
class RateLimitConfig:
    """Configuration for a rate limit."""

    max_requests: int
    window_seconds: float
    burst_allowance: int = 0  # Extra requests allowed in bursts

    @classmethod
    def from_env(cls, key: str, default: Tuple[int, float]) -> "RateLimitConfig":
        """Load rate limit from environment variable."""
        env_key = f"RATE_LIMIT_{key.upper()}"
        env_value = os.environ.get(env_key)

        if env_value:
            try:
                parts = env_value.split(",")
                max_requests = int(parts[0])
                window_seconds = float(parts[1]) if len(parts) > 1 else default[1]
                burst = int(parts[2]) if len(parts) > 2 else 0
                return cls(max_requests, window_seconds, burst)
            except (ValueError, IndexError):
                logger.warning(f"Invalid rate limit config in {env_key}: {env_value}")

        return cls(default[0], default[1])


# =============================================================================
# Token Bucket Rate Limiter
# =============================================================================


@dataclass
class TokenBucket:
    """Token bucket implementation for rate limiting."""

    capacity: float
    refill_rate: float  # tokens per second
    tokens: float = field(default=None)
    last_refill: float = field(default=None)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def __post_init__(self):
        if self.tokens is None:
            self.tokens = self.capacity
        if self.last_refill is None:
            self.last_refill = time.monotonic()

    def _refill(self) -> None:
        """Refill tokens based on elapsed time."""
        now = time.monotonic()
        elapsed = now - self.last_refill
        self.tokens = min(self.capacity, self.tokens + elapsed * self.refill_rate)
        self.last_refill = now

    def consume(self, tokens: int = 1) -> bool:
        """
        Try to consume tokens from the bucket.

        Returns True if successful, False if rate limited.
        """
        with self.lock:
            self._refill()
            if self.tokens >= tokens:
                self.tokens -= tokens
                return True
            return False

    def get_wait_time(self, tokens: int = 1) -> float:
        """Get time to wait before tokens are available."""
        with self.lock:
            self._refill()
            if self.tokens >= tokens:
                return 0.0
            needed = tokens - self.tokens
            return needed / self.refill_rate


# =============================================================================
# Sliding Window Rate Limiter
# =============================================================================


@dataclass
class SlidingWindowEntry:
    """Entry in the sliding window counter."""

    timestamp: float
    count: int = 1


class SlidingWindowLimiter:
    """Sliding window rate limiter implementation."""

    def __init__(self, max_requests: int, window_seconds: float):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._requests: Dict[str, list] = defaultdict(list)
        self._lock = threading.Lock()

    def _cleanup_old_entries(self, key: str, now: float) -> None:
        """Remove entries outside the current window."""
        cutoff = now - self.window_seconds
        self._requests[key] = [ts for ts in self._requests[key] if ts > cutoff]

    def is_allowed(self, key: str = "global") -> Tuple[bool, Dict[str, Any]]:
        """
        Check if a request is allowed.

        Returns (allowed, info) where info contains:
        - remaining: requests remaining in window
        - reset_after: seconds until window resets
        - limit: max requests allowed
        """
        now = time.monotonic()

        with self._lock:
            self._cleanup_old_entries(key, now)

            current_count = len(self._requests[key])
            remaining = max(0, self.max_requests - current_count)

            # Calculate reset time
            if self._requests[key]:
                oldest = min(self._requests[key])
                reset_after = max(0, (oldest + self.window_seconds) - now)
            else:
                reset_after = self.window_seconds

            info = {
                "remaining": remaining,
                "reset_after": round(reset_after, 2),
                "limit": self.max_requests,
                "window_seconds": self.window_seconds,
            }

            if current_count >= self.max_requests:
                return False, info

            self._requests[key].append(now)
            info["remaining"] = remaining - 1
            return True, info

    def get_stats(self, key: str = "global") -> Dict[str, Any]:
        """Get current rate limit stats for a key."""
        now = time.monotonic()

        with self._lock:
            self._cleanup_old_entries(key, now)
            current_count = len(self._requests[key])

            return {
                "current_requests": current_count,
                "max_requests": self.max_requests,
                "remaining": max(0, self.max_requests - current_count),
                "window_seconds": self.window_seconds,
            }


# =============================================================================
# Rate Limiter Manager
# =============================================================================


class RateLimiterManager:
    """
    Manages multiple rate limiters for different endpoints and clients.
    """

    def __init__(self):
        self._limiters: Dict[str, SlidingWindowLimiter] = {}
        self._client_limiters: Dict[Tuple[str, str], SlidingWindowLimiter] = {}
        self._lock = threading.Lock()
        self._enabled = os.environ.get("RATE_LIMITING_ENABLED", "true").lower() == "true"
        self._init_limiters()

    def _init_limiters(self) -> None:
        """Initialize rate limiters from configuration."""
        # Global/endpoint limiters
        for key, default in DEFAULT_RATE_LIMITS.items():
            config = RateLimitConfig.from_env(key, default)
            self._limiters[key] = SlidingWindowLimiter(
                config.max_requests + config.burst_allowance, config.window_seconds
            )

    def _get_client_limiter(self, endpoint: str, client_id: str) -> Optional[SlidingWindowLimiter]:
        """Get or create a per-client rate limiter."""
        if endpoint not in DEFAULT_CLIENT_LIMITS:
            return None

        key = (endpoint, client_id)
        with self._lock:
            if key not in self._client_limiters:
                default = DEFAULT_CLIENT_LIMITS[endpoint]
                config = RateLimitConfig.from_env(f"{endpoint}_client", default)
                self._client_limiters[key] = SlidingWindowLimiter(config.max_requests, config.window_seconds)
            return self._client_limiters[key]

    def check_rate_limit(
        self, endpoint: str, client_id: Optional[str] = None
    ) -> Tuple[bool, Dict[str, Any]]:
        """
        Check if a request should be rate limited.

        Parameters
        ----------
        endpoint : str
            Endpoint identifier (e.g., "mcp_tools_call", "api_chat")
        client_id : Optional[str]
            Client identifier for per-client limiting

        Returns
        -------
        Tuple[bool, Dict[str, Any]]
            (allowed, info) where info contains rate limit details
        """
        if not self._enabled:
            return True, {"rate_limiting": "disabled"}

        result_info = {}

        # Check global limit
        if "global" in self._limiters:
            allowed, info = self._limiters["global"].is_allowed("global")
            result_info["global"] = info
            if not allowed:
                return False, {
                    "error": "global_rate_limit_exceeded",
                    "retry_after": info["reset_after"],
                    **result_info,
                }

        # Check endpoint limit
        if endpoint in self._limiters:
            allowed, info = self._limiters[endpoint].is_allowed(endpoint)
            result_info["endpoint"] = info
            if not allowed:
                return False, {
                    "error": f"{endpoint}_rate_limit_exceeded",
                    "retry_after": info["reset_after"],
                    **result_info,
                }

        # Check per-client limit
        if client_id:
            client_limiter = self._get_client_limiter(endpoint, client_id)
            if client_limiter:
                allowed, info = client_limiter.is_allowed(client_id)
                result_info["client"] = info
                if not allowed:
                    return False, {
                        "error": f"{endpoint}_client_rate_limit_exceeded",
                        "retry_after": info["reset_after"],
                        **result_info,
                    }

        return True, result_info

    def get_stats(self, endpoint: Optional[str] = None) -> Dict[str, Any]:
        """Get rate limit statistics."""
        stats = {}

        if endpoint:
            if endpoint in self._limiters:
                stats[endpoint] = self._limiters[endpoint].get_stats(endpoint)
        else:
            for key, limiter in self._limiters.items():
                stats[key] = limiter.get_stats(key)

        return stats

    def is_enabled(self) -> bool:
        """Check if rate limiting is enabled."""
        return self._enabled

    def set_enabled(self, enabled: bool) -> None:
        """Enable or disable rate limiting."""
        self._enabled = enabled
        logger.info(f"Rate limiting {'enabled' if enabled else 'disabled'}")


# Global rate limiter instance
_rate_limiter: Optional[RateLimiterManager] = None


def get_rate_limiter() -> RateLimiterManager:
    """Get the global rate limiter instance."""
    global _rate_limiter
    if _rate_limiter is None:
        _rate_limiter = RateLimiterManager()
    return _rate_limiter


# =============================================================================
# Rate Limit Decorators
# =============================================================================


def rate_limited(
    endpoint: str,
    get_client_id: Optional[Callable[..., str]] = None,
):
    """
    Decorator to apply rate limiting to a function.

    Parameters
    ----------
    endpoint : str
        Endpoint identifier for rate limiting
    get_client_id : Optional[Callable[..., str]]
        Function to extract client ID from function arguments

    Example
    -------
    @rate_limited("api_chat", get_client_id=lambda request: request.client.host)
    def handle_chat(request):
        ...
    """

    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            limiter = get_rate_limiter()

            client_id = None
            if get_client_id:
                try:
                    client_id = get_client_id(*args, **kwargs)
                except Exception:
                    pass

            allowed, info = limiter.check_rate_limit(endpoint, client_id)

            if not allowed:
                raise RateLimitExceeded(
                    endpoint=endpoint,
                    retry_after=info.get("retry_after", 60),
                    info=info,
                )

            return func(*args, **kwargs)

        @functools.wraps(func)
        async def async_wrapper(*args, **kwargs):
            limiter = get_rate_limiter()

            client_id = None
            if get_client_id:
                try:
                    client_id = get_client_id(*args, **kwargs)
                except Exception:
                    pass

            allowed, info = limiter.check_rate_limit(endpoint, client_id)

            if not allowed:
                raise RateLimitExceeded(
                    endpoint=endpoint,
                    retry_after=info.get("retry_after", 60),
                    info=info,
                )

            return await func(*args, **kwargs)

        import asyncio

        if asyncio.iscoroutinefunction(func):
            return async_wrapper
        return wrapper

    return decorator


# =============================================================================
# Rate Limit Exception
# =============================================================================


class RateLimitExceeded(Exception):
    """Exception raised when rate limit is exceeded."""

    def __init__(
        self,
        endpoint: str,
        retry_after: float,
        info: Optional[Dict[str, Any]] = None,
    ):
        self.endpoint = endpoint
        self.retry_after = retry_after
        self.info = info or {}
        super().__init__(f"Rate limit exceeded for {endpoint}. Retry after {retry_after}s")

    def to_response_headers(self) -> Dict[str, str]:
        """Get HTTP headers for rate limit response."""
        return {
            "Retry-After": str(int(self.retry_after)),
            "X-RateLimit-Limit": str(self.info.get("endpoint", {}).get("limit", "")),
            "X-RateLimit-Remaining": str(self.info.get("endpoint", {}).get("remaining", "")),
            "X-RateLimit-Reset": str(int(time.time() + self.retry_after)),
        }


# =============================================================================
# HTTP Middleware Utilities
# =============================================================================


def get_rate_limit_headers(endpoint: str, client_id: Optional[str] = None) -> Dict[str, str]:
    """
    Get rate limit headers for successful responses.

    Parameters
    ----------
    endpoint : str
        Endpoint identifier
    client_id : Optional[str]
        Client identifier

    Returns
    -------
    Dict[str, str]
        HTTP headers with rate limit info
    """
    limiter = get_rate_limiter()

    if not limiter.is_enabled():
        return {}

    stats = limiter.get_stats(endpoint)
    endpoint_stats = stats.get(endpoint, {})

    return {
        "X-RateLimit-Limit": str(endpoint_stats.get("max_requests", "")),
        "X-RateLimit-Remaining": str(endpoint_stats.get("remaining", "")),
        "X-RateLimit-Window": str(endpoint_stats.get("window_seconds", "")),
    }


def create_rate_limit_response(exc: RateLimitExceeded) -> Dict[str, Any]:
    """
    Create a JSON-RPC or REST error response for rate limit exceeded.

    Parameters
    ----------
    exc : RateLimitExceeded
        The rate limit exception

    Returns
    -------
    Dict[str, Any]
        Error response body
    """
    return {
        "error": {
            "code": -32029,  # Custom JSON-RPC error code for rate limiting
            "message": f"Rate limit exceeded: {exc.endpoint}",
            "data": {
                "endpoint": exc.endpoint,
                "retry_after": exc.retry_after,
                **exc.info,
            },
        }
    }


# =============================================================================
# MCP Handler Integration
# =============================================================================


def check_mcp_rate_limit(handler: Any, method: str) -> Optional[Dict[str, Any]]:
    """
    Check rate limit for MCP request.

    Parameters
    ----------
    handler : BaseHTTPRequestHandler
        The HTTP request handler
    method : str
        MCP method being called

    Returns
    -------
    Optional[Dict[str, Any]]
        Error response if rate limited, None if allowed
    """
    limiter = get_rate_limiter()

    if not limiter.is_enabled():
        return None

    # Determine endpoint based on method
    if method == "tools/call":
        endpoint = "mcp_tools_call"
    elif method == "resources/read":
        endpoint = "mcp_resources_read"
    else:
        endpoint = "global"

    # Get client ID from handler
    client_id = handler.client_address[0] if handler.client_address else None

    allowed, info = limiter.check_rate_limit(endpoint, client_id)

    if not allowed:
        return {
            "jsonrpc": "2.0",
            "id": None,
            "error": {
                "code": -32029,
                "message": f"Rate limit exceeded",
                "data": info,
            },
        }

    return None