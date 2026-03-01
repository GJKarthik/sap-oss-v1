"""
Rate Limiting for Production Deployments.

Production-ready rate limiting with:
- Token bucket algorithm
- Per-client and global limits
- Adaptive rate limiting based on system load
"""

import asyncio
import logging
import os
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, Optional

logger = logging.getLogger(__name__)

# Configuration
GLOBAL_RATE_LIMIT = int(os.getenv("RATE_LIMIT_GLOBAL", "1000"))  # requests/minute
PER_CLIENT_RATE_LIMIT = int(os.getenv("RATE_LIMIT_PER_CLIENT", "100"))
BURST_MULTIPLIER = float(os.getenv("RATE_LIMIT_BURST_MULTIPLIER", "1.5"))
ADAPTIVE_ENABLED = os.getenv("RATE_LIMIT_ADAPTIVE", "true").lower() == "true"


@dataclass
class TokenBucket:
    """Token bucket for rate limiting."""
    capacity: float
    tokens: float
    refill_rate: float  # tokens per second
    last_refill: float = field(default_factory=time.time)
    
    def consume(self, tokens: int = 1) -> bool:
        """Try to consume tokens. Returns True if successful."""
        now = time.time()
        
        # Refill tokens
        elapsed = now - self.last_refill
        self.tokens = min(self.capacity, self.tokens + elapsed * self.refill_rate)
        self.last_refill = now
        
        # Try to consume
        if self.tokens >= tokens:
            self.tokens -= tokens
            return True
        return False
    
    def time_until_available(self, tokens: int = 1) -> float:
        """Calculate wait time until tokens are available."""
        if self.tokens >= tokens:
            return 0.0
        
        needed = tokens - self.tokens
        return needed / self.refill_rate


@dataclass
class RateLimitStats:
    """Statistics for rate limiting."""
    total_requests: int = 0
    allowed_requests: int = 0
    denied_requests: int = 0
    total_wait_time: float = 0.0


class RateLimiter:
    """
    Production-ready rate limiter.
    
    Features:
    - Token bucket algorithm
    - Global and per-client limits
    - Adaptive limits based on CPU/memory
    - Graceful backpressure
    """
    
    def __init__(
        self,
        global_limit: int = GLOBAL_RATE_LIMIT,
        per_client_limit: int = PER_CLIENT_RATE_LIMIT,
        burst_multiplier: float = BURST_MULTIPLIER,
        adaptive: bool = ADAPTIVE_ENABLED,
    ):
        self.global_limit = global_limit
        self.per_client_limit = per_client_limit
        self.burst_multiplier = burst_multiplier
        self.adaptive = adaptive
        
        # Global bucket
        self._global_bucket = TokenBucket(
            capacity=global_limit * burst_multiplier,
            tokens=global_limit * burst_multiplier,
            refill_rate=global_limit / 60.0,  # per second
        )
        
        # Per-client buckets
        self._client_buckets: Dict[str, TokenBucket] = {}
        self._stats = RateLimitStats()
        self._lock = asyncio.Lock()
        
        # Adaptive rate limiting
        self._load_factor = 1.0
    
    def _get_client_bucket(self, client_id: str) -> TokenBucket:
        """Get or create bucket for client."""
        if client_id not in self._client_buckets:
            effective_limit = self.per_client_limit * self._load_factor
            self._client_buckets[client_id] = TokenBucket(
                capacity=effective_limit * self.burst_multiplier,
                tokens=effective_limit * self.burst_multiplier,
                refill_rate=effective_limit / 60.0,
            )
        return self._client_buckets[client_id]
    
    async def acquire(
        self,
        client_id: str = "default",
        tokens: int = 1,
        wait: bool = True,
        max_wait: float = 5.0,
    ) -> bool:
        """
        Acquire rate limit tokens.
        
        Args:
            client_id: Client identifier for per-client limits
            tokens: Number of tokens to consume
            wait: Whether to wait if rate limited
            max_wait: Maximum wait time in seconds
        
        Returns:
            True if acquired, False if rate limited
        """
        async with self._lock:
            self._stats.total_requests += 1
            
            # Update adaptive load factor
            if self.adaptive:
                self._update_load_factor()
            
            # Check global limit
            if not self._global_bucket.consume(tokens):
                if wait:
                    wait_time = self._global_bucket.time_until_available(tokens)
                    if wait_time <= max_wait:
                        self._stats.total_wait_time += wait_time
                        await asyncio.sleep(wait_time)
                        self._global_bucket.consume(tokens)
                    else:
                        self._stats.denied_requests += 1
                        return False
                else:
                    self._stats.denied_requests += 1
                    return False
            
            # Check per-client limit
            client_bucket = self._get_client_bucket(client_id)
            if not client_bucket.consume(tokens):
                if wait:
                    wait_time = client_bucket.time_until_available(tokens)
                    if wait_time <= max_wait:
                        self._stats.total_wait_time += wait_time
                        await asyncio.sleep(wait_time)
                        client_bucket.consume(tokens)
                    else:
                        self._stats.denied_requests += 1
                        return False
                else:
                    self._stats.denied_requests += 1
                    return False
            
            self._stats.allowed_requests += 1
            return True
    
    def _update_load_factor(self) -> None:
        """Update load factor based on system metrics."""
        try:
            import psutil
            
            cpu_percent = psutil.cpu_percent()
            memory_percent = psutil.virtual_memory().percent
            
            # Reduce limits when system is under load
            if cpu_percent > 80 or memory_percent > 85:
                self._load_factor = 0.5
            elif cpu_percent > 60 or memory_percent > 70:
                self._load_factor = 0.75
            else:
                self._load_factor = 1.0
                
        except ImportError:
            self._load_factor = 1.0
    
    def cleanup_old_clients(self, max_age_seconds: float = 3600) -> int:
        """Remove stale client buckets."""
        now = time.time()
        cutoff = now - max_age_seconds
        
        to_remove = [
            client_id for client_id, bucket in self._client_buckets.items()
            if bucket.last_refill < cutoff
        ]
        
        for client_id in to_remove:
            del self._client_buckets[client_id]
        
        return len(to_remove)
    
    def get_stats(self) -> Dict[str, Any]:
        """Get rate limiter statistics."""
        return {
            "total_requests": self._stats.total_requests,
            "allowed_requests": self._stats.allowed_requests,
            "denied_requests": self._stats.denied_requests,
            "deny_rate": (
                self._stats.denied_requests / self._stats.total_requests
                if self._stats.total_requests > 0 else 0
            ),
            "avg_wait_time": (
                self._stats.total_wait_time / self._stats.allowed_requests
                if self._stats.allowed_requests > 0 else 0
            ),
            "active_clients": len(self._client_buckets),
            "load_factor": self._load_factor,
            "config": {
                "global_limit": self.global_limit,
                "per_client_limit": self.per_client_limit,
                "adaptive": self.adaptive,
            }
        }


# Singleton
_limiter: Optional[RateLimiter] = None


async def get_rate_limiter() -> RateLimiter:
    """Get or create rate limiter singleton."""
    global _limiter
    if _limiter is None:
        _limiter = RateLimiter()
    return _limiter


def rate_limited(
    tokens: int = 1,
    client_id_param: str = "client_id",
):
    """Decorator for rate-limited functions."""
    def decorator(func: Callable) -> Callable:
        async def wrapper(*args, **kwargs):
            limiter = await get_rate_limiter()
            client_id = kwargs.get(client_id_param, "default")
            
            if not await limiter.acquire(client_id, tokens):
                raise RateLimitExceeded(f"Rate limit exceeded for {client_id}")
            
            return await func(*args, **kwargs)
        return wrapper
    return decorator


class RateLimitExceeded(Exception):
    """Exception when rate limit is exceeded."""
    pass