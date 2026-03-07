"""
Rate limiter middleware for MCP and OpenAI servers.

Implements:
- Token bucket rate limiting
- Per-IP rate limiting
- Per-API-key rate limiting
- Sliding window counters
"""

import time
import threading
from collections import defaultdict
from typing import Optional, Tuple
from dataclasses import dataclass, field


@dataclass
class RateLimitConfig:
    """Rate limit configuration."""
    requests_per_second: float = 10.0
    requests_per_minute: float = 100.0
    burst_size: int = 20
    window_seconds: int = 60
    enabled: bool = True


@dataclass
class TokenBucket:
    """Token bucket for rate limiting."""
    capacity: float
    fill_rate: float  # tokens per second
    tokens: float = field(init=False)
    last_update: float = field(default_factory=time.time)
    
    def __post_init__(self):
        self.tokens = self.capacity
    
    def consume(self, tokens: float = 1.0) -> bool:
        """Try to consume tokens. Returns True if successful."""
        now = time.time()
        elapsed = now - self.last_update
        
        # Refill tokens
        self.tokens = min(self.capacity, self.tokens + elapsed * self.fill_rate)
        self.last_update = now
        
        if self.tokens >= tokens:
            self.tokens -= tokens
            return True
        return False
    
    def get_wait_time(self, tokens: float = 1.0) -> float:
        """Get time to wait until tokens are available."""
        if self.tokens >= tokens:
            return 0.0
        deficit = tokens - self.tokens
        return deficit / self.fill_rate


@dataclass
class SlidingWindowCounter:
    """Sliding window counter for rate limiting."""
    window_seconds: int = 60
    max_requests: int = 100
    _counts: dict = field(default_factory=dict)
    _lock: threading.Lock = field(default_factory=threading.Lock)
    
    def _get_window_key(self, timestamp: float) -> int:
        """Get window key for timestamp."""
        return int(timestamp // self.window_seconds)
    
    def increment(self) -> Tuple[bool, int]:
        """
        Increment counter and check if allowed.
        Returns (allowed, current_count).
        """
        now = time.time()
        current_window = self._get_window_key(now)
        
        with self._lock:
            # Clean old windows
            old_windows = [k for k in self._counts if k < current_window - 1]
            for k in old_windows:
                del self._counts[k]
            
            # Get counts
            prev_count = self._counts.get(current_window - 1, 0)
            curr_count = self._counts.get(current_window, 0)
            
            # Calculate weighted count (sliding window)
            elapsed_ratio = (now % self.window_seconds) / self.window_seconds
            weighted_count = prev_count * (1 - elapsed_ratio) + curr_count
            
            if weighted_count >= self.max_requests:
                return False, int(weighted_count)
            
            # Increment current window
            self._counts[current_window] = curr_count + 1
            return True, int(weighted_count) + 1
    
    def get_remaining(self) -> int:
        """Get remaining requests in current window."""
        now = time.time()
        current_window = self._get_window_key(now)
        
        with self._lock:
            prev_count = self._counts.get(current_window - 1, 0)
            curr_count = self._counts.get(current_window, 0)
            
            elapsed_ratio = (now % self.window_seconds) / self.window_seconds
            weighted_count = prev_count * (1 - elapsed_ratio) + curr_count
            
            return max(0, self.max_requests - int(weighted_count))


class RateLimiter:
    """
    Rate limiter with multiple strategies.
    
    Uses both token bucket (for burst control) and sliding window
    (for sustained rate limiting).
    """
    
    def __init__(self, config: Optional[RateLimitConfig] = None):
        self.config = config or RateLimitConfig()
        self._buckets: dict[str, TokenBucket] = {}
        self._windows: dict[str, SlidingWindowCounter] = {}
        self._lock = threading.Lock()
        
        # Track blocked requests for metrics
        self._blocked_count = 0
        self._total_requests = 0
    
    def _get_bucket(self, key: str) -> TokenBucket:
        """Get or create token bucket for key."""
        if key not in self._buckets:
            self._buckets[key] = TokenBucket(
                capacity=self.config.burst_size,
                fill_rate=self.config.requests_per_second
            )
        return self._buckets[key]
    
    def _get_window(self, key: str) -> SlidingWindowCounter:
        """Get or create sliding window for key."""
        if key not in self._windows:
            self._windows[key] = SlidingWindowCounter(
                window_seconds=self.config.window_seconds,
                max_requests=int(self.config.requests_per_minute)
            )
        return self._windows[key]
    
    def check(self, key: str) -> Tuple[bool, dict]:
        """
        Check if request is allowed.
        
        Args:
            key: Identifier for rate limiting (IP, API key, etc.)
        
        Returns:
            Tuple of (allowed, metadata)
        """
        if not self.config.enabled:
            return True, {"rate_limit_enabled": False}
        
        with self._lock:
            self._total_requests += 1
            
            bucket = self._get_bucket(key)
            window = self._get_window(key)
            
            # Check both limits
            bucket_allowed = bucket.consume(1.0)
            window_allowed, window_count = window.increment()
            
            allowed = bucket_allowed and window_allowed
            
            if not allowed:
                self._blocked_count += 1
            
            return allowed, {
                "rate_limit_enabled": True,
                "allowed": allowed,
                "bucket_tokens": bucket.tokens,
                "window_count": window_count,
                "window_remaining": window.get_remaining(),
                "retry_after": 0 if allowed else bucket.get_wait_time()
            }
    
    def get_headers(self, key: str) -> dict:
        """Get rate limit headers for response."""
        if not self.config.enabled:
            return {}
        
        window = self._get_window(key)
        remaining = window.get_remaining()
        
        return {
            "X-RateLimit-Limit": str(int(self.config.requests_per_minute)),
            "X-RateLimit-Remaining": str(remaining),
            "X-RateLimit-Reset": str(int(time.time()) + self.config.window_seconds)
        }
    
    def get_metrics(self) -> dict:
        """Get rate limiter metrics."""
        return {
            "total_requests": self._total_requests,
            "blocked_requests": self._blocked_count,
            "block_rate": self._blocked_count / max(1, self._total_requests),
            "active_buckets": len(self._buckets),
            "active_windows": len(self._windows)
        }
    
    def cleanup(self, max_age_seconds: int = 3600):
        """Clean up old rate limit state."""
        # In production, implement TTL-based cleanup
        pass


# Global rate limiters for different endpoints
_mcp_limiter: Optional[RateLimiter] = None
_openai_limiter: Optional[RateLimiter] = None


def get_mcp_limiter() -> RateLimiter:
    """Get MCP endpoint rate limiter."""
    global _mcp_limiter
    if _mcp_limiter is None:
        _mcp_limiter = RateLimiter(RateLimitConfig(
            requests_per_second=20.0,
            requests_per_minute=200.0,
            burst_size=50
        ))
    return _mcp_limiter


def get_openai_limiter() -> RateLimiter:
    """Get OpenAI-compatible endpoint rate limiter."""
    global _openai_limiter
    if _openai_limiter is None:
        _openai_limiter = RateLimiter(RateLimitConfig(
            requests_per_second=10.0,
            requests_per_minute=100.0,
            burst_size=20
        ))
    return _openai_limiter


def rate_limit_middleware(limiter: RateLimiter, get_key):
    """
    Create rate limiting middleware.
    
    Args:
        limiter: RateLimiter instance
        get_key: Function to extract rate limit key from request
    
    Returns:
        Middleware function for use with web frameworks
    """
    def middleware(handler):
        async def wrapped(request, *args, **kwargs):
            key = get_key(request)
            allowed, metadata = limiter.check(key)
            
            if not allowed:
                # Return 429 Too Many Requests
                from fastapi import HTTPException
                raise HTTPException(
                    status_code=429,
                    detail={
                        "error": "rate_limit_exceeded",
                        "message": "Too many requests",
                        "retry_after": metadata.get("retry_after", 1)
                    },
                    headers=limiter.get_headers(key)
                )
            
            response = await handler(request, *args, **kwargs)
            
            # Add rate limit headers to response
            for header, value in limiter.get_headers(key).items():
                response.headers[header] = value
            
            return response
        return wrapped
    return middleware


# FastAPI dependency for rate limiting
def rate_limit_dependency(limiter: Optional[RateLimiter] = None):
    """
    Create FastAPI dependency for rate limiting.
    
    Usage:
        from fastapi import Depends
        
        @app.post("/v1/chat/completions")
        async def chat(request: Request, _: None = Depends(rate_limit_dependency())):
            ...
    """
    if limiter is None:
        limiter = get_openai_limiter()
    
    async def dependency(request):
        # Get client IP or API key
        key = request.client.host if request.client else "unknown"
        
        # Check for API key in header
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            # Use hashed API key for rate limiting
            import hashlib
            key = hashlib.sha256(auth.encode()).hexdigest()[:16]
        
        allowed, metadata = limiter.check(key)
        
        if not allowed:
            from fastapi import HTTPException
            raise HTTPException(
                status_code=429,
                detail={
                    "error": {
                        "type": "rate_limit_exceeded",
                        "message": "Rate limit exceeded. Please retry after some time."
                    }
                },
                headers=limiter.get_headers(key)
            )
    
    return dependency


if __name__ == "__main__":
    # Test rate limiter
    import random
    
    limiter = RateLimiter(RateLimitConfig(
        requests_per_second=5.0,
        requests_per_minute=30.0,
        burst_size=10
    ))
    
    print("Testing rate limiter...")
    
    # Simulate requests
    for i in range(50):
        client_ip = f"192.168.1.{random.randint(1, 3)}"
        allowed, meta = limiter.check(client_ip)
        print(f"Request {i+1} from {client_ip}: {'✓' if allowed else '✗'} "
              f"(remaining: {meta.get('window_remaining', 'N/A')})")
        time.sleep(0.1)
    
    print("\nMetrics:", limiter.get_metrics())