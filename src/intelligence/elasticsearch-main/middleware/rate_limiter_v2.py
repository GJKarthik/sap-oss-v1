"""
Enhanced Rate Limiting Middleware v2.

Day 44 Implementation - Week 9 Security Hardening
Provides sliding window rate limiting, tiered limits, and burst protection.
"""

import time
import asyncio
import logging
import hashlib
from typing import Optional, Dict, Any, List, Tuple
from dataclasses import dataclass, field
from enum import Enum
from collections import defaultdict
import threading

from fastapi import Request, HTTPException
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger(__name__)


# =============================================================================
# Rate Limit Tiers
# =============================================================================

class RateLimitTier(str, Enum):
    """Rate limit tiers for different user types."""
    FREE = "free"
    STANDARD = "standard"
    PREMIUM = "premium"
    ENTERPRISE = "enterprise"
    INTERNAL = "internal"


@dataclass
class TierLimits:
    """Rate limits for a specific tier."""
    requests_per_minute: int
    requests_per_hour: int
    requests_per_day: int
    tokens_per_minute: int
    tokens_per_day: int
    burst_limit: int  # Max concurrent requests
    
    @classmethod
    def for_tier(cls, tier: RateLimitTier) -> "TierLimits":
        """Get limits for a specific tier."""
        limits = {
            RateLimitTier.FREE: cls(
                requests_per_minute=20,
                requests_per_hour=200,
                requests_per_day=1000,
                tokens_per_minute=10000,
                tokens_per_day=100000,
                burst_limit=3,
            ),
            RateLimitTier.STANDARD: cls(
                requests_per_minute=60,
                requests_per_hour=1000,
                requests_per_day=10000,
                tokens_per_minute=60000,
                tokens_per_day=1000000,
                burst_limit=10,
            ),
            RateLimitTier.PREMIUM: cls(
                requests_per_minute=200,
                requests_per_hour=5000,
                requests_per_day=50000,
                tokens_per_minute=200000,
                tokens_per_day=10000000,
                burst_limit=30,
            ),
            RateLimitTier.ENTERPRISE: cls(
                requests_per_minute=1000,
                requests_per_hour=20000,
                requests_per_day=200000,
                tokens_per_minute=1000000,
                tokens_per_day=100000000,
                burst_limit=100,
            ),
            RateLimitTier.INTERNAL: cls(
                requests_per_minute=10000,
                requests_per_hour=100000,
                requests_per_day=1000000,
                tokens_per_minute=10000000,
                tokens_per_day=1000000000,
                burst_limit=500,
            ),
        }
        return limits.get(tier, limits[RateLimitTier.FREE])


# =============================================================================
# Endpoint-Specific Limits
# =============================================================================

@dataclass
class EndpointLimits:
    """Rate limits for specific endpoints."""
    endpoint: str
    multiplier: float  # Multiplier applied to tier limits
    burst_multiplier: float = 1.0
    
    @classmethod
    def get_defaults(cls) -> Dict[str, "EndpointLimits"]:
        """Get default endpoint limits."""
        return {
            "/v1/chat/completions": cls("/v1/chat/completions", 1.0, 1.0),
            "/v1/embeddings": cls("/v1/embeddings", 2.0, 2.0),  # Higher limits
            "/v1/audio/transcriptions": cls("/v1/audio/transcriptions", 0.5, 0.5),
            "/v1/audio/speech": cls("/v1/audio/speech", 0.5, 0.5),
            "/v1/images/generations": cls("/v1/images/generations", 0.2, 0.3),
            "/v1/fine_tuning/jobs": cls("/v1/fine_tuning/jobs", 0.1, 0.1),
            "/v1/assistants": cls("/v1/assistants", 1.0, 1.0),
            "/v1/threads": cls("/v1/threads", 1.0, 1.0),
            "/v1/files": cls("/v1/files", 0.5, 0.5),
        }


# =============================================================================
# Sliding Window Counter
# =============================================================================

class SlidingWindowCounter:
    """
    Sliding window rate limiter using a fixed window with sliding correction.
    
    This is more accurate than a simple fixed window but more memory-efficient
    than tracking every individual request timestamp.
    """
    
    def __init__(self, window_size_seconds: int, limit: int):
        self.window_size = window_size_seconds
        self.limit = limit
        self._lock = threading.Lock()
        self._current_window_start = 0
        self._current_count = 0
        self._previous_count = 0
    
    def _get_window_start(self, now: float) -> int:
        """Get the start of the current window."""
        return int(now // self.window_size) * self.window_size
    
    def is_allowed(self, now: float = None) -> Tuple[bool, int, int]:
        """
        Check if a request is allowed.
        
        Returns: (allowed, current_count, limit)
        """
        if now is None:
            now = time.time()
        
        with self._lock:
            window_start = self._get_window_start(now)
            
            # Check if we've moved to a new window
            if window_start != self._current_window_start:
                # How much of the current window has passed
                time_into_window = now - window_start
                window_fraction = time_into_window / self.window_size
                
                if window_start > self._current_window_start + self.window_size:
                    # More than one full window has passed
                    self._previous_count = 0
                else:
                    # Move current to previous
                    self._previous_count = self._current_count
                
                self._current_count = 0
                self._current_window_start = window_start
            else:
                time_into_window = now - window_start
                window_fraction = time_into_window / self.window_size
            
            # Calculate weighted count using sliding window approximation
            previous_weight = 1 - window_fraction
            weighted_count = (self._previous_count * previous_weight) + self._current_count
            
            if weighted_count >= self.limit:
                return False, int(weighted_count), self.limit
            
            return True, int(weighted_count), self.limit
    
    def record(self, count: int = 1, now: float = None):
        """Record a request."""
        if now is None:
            now = time.time()
        
        with self._lock:
            window_start = self._get_window_start(now)
            
            # Update window if needed
            if window_start != self._current_window_start:
                if window_start > self._current_window_start + self.window_size:
                    self._previous_count = 0
                else:
                    self._previous_count = self._current_count
                self._current_count = 0
                self._current_window_start = window_start
            
            self._current_count += count
    
    def get_remaining(self, now: float = None) -> int:
        """Get remaining requests in current window."""
        allowed, current, limit = self.is_allowed(now)
        return max(0, limit - current)
    
    def get_reset_time(self, now: float = None) -> int:
        """Get seconds until window reset."""
        if now is None:
            now = time.time()
        window_start = self._get_window_start(now)
        return int(window_start + self.window_size - now)


# =============================================================================
# Rate Limit State
# =============================================================================

@dataclass
class RateLimitState:
    """Rate limit state for a single client."""
    client_id: str
    tier: RateLimitTier
    minute_counter: SlidingWindowCounter = None
    hour_counter: SlidingWindowCounter = None
    day_counter: SlidingWindowCounter = None
    token_minute_counter: SlidingWindowCounter = None
    token_day_counter: SlidingWindowCounter = None
    concurrent_requests: int = 0
    last_request_time: float = 0
    _lock: threading.Lock = field(default_factory=threading.Lock)
    
    def __post_init__(self):
        limits = TierLimits.for_tier(self.tier)
        self.minute_counter = SlidingWindowCounter(60, limits.requests_per_minute)
        self.hour_counter = SlidingWindowCounter(3600, limits.requests_per_hour)
        self.day_counter = SlidingWindowCounter(86400, limits.requests_per_day)
        self.token_minute_counter = SlidingWindowCounter(60, limits.tokens_per_minute)
        self.token_day_counter = SlidingWindowCounter(86400, limits.tokens_per_day)
    
    def check_request_limits(self, endpoint_multiplier: float = 1.0) -> Tuple[bool, str, Dict]:
        """Check if request is within rate limits."""
        now = time.time()
        
        # Check minute limit
        allowed, count, limit = self.minute_counter.is_allowed(now)
        if not allowed:
            return False, "rate_limit_exceeded", {
                "limit_type": "requests_per_minute",
                "current": count,
                "limit": limit,
                "reset_seconds": self.minute_counter.get_reset_time(now),
            }
        
        # Check hour limit
        allowed, count, limit = self.hour_counter.is_allowed(now)
        if not allowed:
            return False, "rate_limit_exceeded", {
                "limit_type": "requests_per_hour",
                "current": count,
                "limit": limit,
                "reset_seconds": self.hour_counter.get_reset_time(now),
            }
        
        # Check day limit
        allowed, count, limit = self.day_counter.is_allowed(now)
        if not allowed:
            return False, "rate_limit_exceeded", {
                "limit_type": "requests_per_day",
                "current": count,
                "limit": limit,
                "reset_seconds": self.day_counter.get_reset_time(now),
            }
        
        return True, "", {}
    
    def check_burst_limit(self, burst_limit: int) -> Tuple[bool, str]:
        """Check if within burst limit."""
        with self._lock:
            if self.concurrent_requests >= burst_limit:
                return False, "Too many concurrent requests"
            return True, ""
    
    def acquire_request(self) -> bool:
        """Acquire a request slot."""
        with self._lock:
            self.concurrent_requests += 1
            self.last_request_time = time.time()
            return True
    
    def release_request(self):
        """Release a request slot."""
        with self._lock:
            self.concurrent_requests = max(0, self.concurrent_requests - 1)
    
    def record_request(self, token_count: int = 0):
        """Record a completed request."""
        now = time.time()
        self.minute_counter.record(1, now)
        self.hour_counter.record(1, now)
        self.day_counter.record(1, now)
        
        if token_count > 0:
            self.token_minute_counter.record(token_count, now)
            self.token_day_counter.record(token_count, now)
    
    def get_headers(self) -> Dict[str, str]:
        """Get rate limit headers for response."""
        now = time.time()
        limits = TierLimits.for_tier(self.tier)
        
        return {
            "X-RateLimit-Limit-Requests": str(limits.requests_per_minute),
            "X-RateLimit-Remaining-Requests": str(self.minute_counter.get_remaining(now)),
            "X-RateLimit-Reset-Requests": str(self.minute_counter.get_reset_time(now)),
            "X-RateLimit-Limit-Tokens": str(limits.tokens_per_minute),
            "X-RateLimit-Remaining-Tokens": str(self.token_minute_counter.get_remaining(now)),
            "X-RateLimit-Reset-Tokens": str(self.token_minute_counter.get_reset_time(now)),
        }


# =============================================================================
# Rate Limiter Manager
# =============================================================================

class RateLimiterManager:
    """Manages rate limit state for all clients."""
    
    def __init__(self):
        self._clients: Dict[str, RateLimitState] = {}
        self._lock = threading.Lock()
        self._endpoint_limits = EndpointLimits.get_defaults()
        self._cleanup_interval = 3600  # Cleanup every hour
        self._last_cleanup = time.time()
    
    def get_client_state(self, client_id: str, tier: RateLimitTier = RateLimitTier.FREE) -> RateLimitState:
        """Get or create rate limit state for a client."""
        with self._lock:
            if client_id not in self._clients:
                self._clients[client_id] = RateLimitState(
                    client_id=client_id,
                    tier=tier,
                )
            
            # Periodic cleanup
            if time.time() - self._last_cleanup > self._cleanup_interval:
                self._cleanup_stale_clients()
            
            return self._clients[client_id]
    
    def _cleanup_stale_clients(self):
        """Remove clients that haven't made requests in a long time."""
        now = time.time()
        stale_threshold = 86400  # 24 hours
        
        stale_clients = [
            client_id
            for client_id, state in self._clients.items()
            if now - state.last_request_time > stale_threshold
        ]
        
        for client_id in stale_clients:
            del self._clients[client_id]
        
        self._last_cleanup = now
        logger.info(f"Cleaned up {len(stale_clients)} stale rate limit entries")
    
    def get_endpoint_multiplier(self, path: str) -> Tuple[float, float]:
        """Get rate limit multiplier for endpoint."""
        for endpoint, limits in self._endpoint_limits.items():
            if path.startswith(endpoint):
                return limits.multiplier, limits.burst_multiplier
        return 1.0, 1.0
    
    def update_tier(self, client_id: str, tier: RateLimitTier):
        """Update client tier (e.g., after authentication)."""
        with self._lock:
            if client_id in self._clients:
                # Create new state with new tier
                old_state = self._clients[client_id]
                self._clients[client_id] = RateLimitState(
                    client_id=client_id,
                    tier=tier,
                )


# =============================================================================
# Rate Limit Middleware
# =============================================================================

class RateLimitMiddleware(BaseHTTPMiddleware):
    """FastAPI middleware for rate limiting."""
    
    def __init__(self, app, manager: RateLimiterManager = None):
        super().__init__(app)
        self.manager = manager or RateLimiterManager()
    
    def _get_client_id(self, request: Request) -> str:
        """Extract client ID from request."""
        # Try API key from header
        api_key = request.headers.get("Authorization", "")
        if api_key.startswith("Bearer "):
            api_key = api_key[7:]
        
        if api_key:
            # Hash API key for privacy
            return hashlib.sha256(api_key.encode()).hexdigest()[:32]
        
        # Fall back to IP address
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            return forwarded.split(",")[0].strip()
        
        return request.client.host if request.client else "unknown"
    
    def _get_tier(self, request: Request) -> RateLimitTier:
        """Determine rate limit tier from request."""
        # Check for tier header (set by auth middleware)
        tier_header = request.headers.get("X-Rate-Limit-Tier")
        if tier_header:
            try:
                return RateLimitTier(tier_header.lower())
            except ValueError:
                pass
        
        # Check for API key presence
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer sk-"):
            return RateLimitTier.STANDARD
        elif auth.startswith("Bearer ent-"):
            return RateLimitTier.ENTERPRISE
        
        return RateLimitTier.FREE
    
    async def dispatch(self, request: Request, call_next):
        """Process request through rate limiter."""
        # Skip rate limiting for health checks
        if request.url.path in ("/health", "/ready", "/metrics"):
            return await call_next(request)
        
        client_id = self._get_client_id(request)
        tier = self._get_tier(request)
        state = self.manager.get_client_state(client_id, tier)
        
        # Get endpoint-specific multipliers
        req_mult, burst_mult = self.manager.get_endpoint_multiplier(request.url.path)
        
        # Check burst limit
        tier_limits = TierLimits.for_tier(tier)
        burst_limit = int(tier_limits.burst_limit * burst_mult)
        allowed, msg = state.check_burst_limit(burst_limit)
        
        if not allowed:
            return self._rate_limit_response(
                "Too many concurrent requests",
                {"type": "burst_limit", "limit": burst_limit},
                state.get_headers()
            )
        
        # Check rate limits
        allowed, reason, details = state.check_request_limits(req_mult)
        
        if not allowed:
            return self._rate_limit_response(
                f"Rate limit exceeded: {details.get('limit_type', 'unknown')}",
                details,
                state.get_headers()
            )
        
        # Acquire request slot
        state.acquire_request()
        
        try:
            response = await call_next(request)
            
            # Record the request
            state.record_request()
            
            # Add rate limit headers
            for key, value in state.get_headers().items():
                response.headers[key] = value
            
            return response
        finally:
            state.release_request()
    
    def _rate_limit_response(
        self,
        message: str,
        details: Dict,
        headers: Dict[str, str]
    ) -> JSONResponse:
        """Create rate limit error response."""
        response = JSONResponse(
            status_code=429,
            content={
                "error": {
                    "message": message,
                    "type": "rate_limit_error",
                    "code": "rate_limit_exceeded",
                    "details": details,
                }
            }
        )
        
        for key, value in headers.items():
            response.headers[key] = value
        
        # Add Retry-After header
        if "reset_seconds" in details:
            response.headers["Retry-After"] = str(details["reset_seconds"])
        
        return response


# =============================================================================
# Factory Functions
# =============================================================================

def create_rate_limiter() -> RateLimiterManager:
    """Create a rate limiter manager."""
    return RateLimiterManager()


def create_rate_limit_middleware(app=None) -> RateLimitMiddleware:
    """Create rate limit middleware."""
    manager = create_rate_limiter()
    return RateLimitMiddleware(app, manager)


def get_tier_limits(tier: RateLimitTier) -> TierLimits:
    """Get rate limits for a tier."""
    return TierLimits.for_tier(tier)