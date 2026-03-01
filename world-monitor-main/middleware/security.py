"""
Security Middleware for World Monitor

Provides:
- Rate limiting (token bucket)
- Security headers (OWASP recommended)
- Input validation
- Health checks
"""

import time
import threading
import hashlib
from typing import Dict, Optional, Callable, Any
from dataclasses import dataclass, field
from functools import wraps


# ============================================================================
# Rate Limiting
# ============================================================================

@dataclass
class RateLimitConfig:
    """Rate limit configuration"""
    requests_per_window: int = 100
    window_seconds: int = 60
    burst_size: int = 20
    per_ip: bool = True
    per_user: bool = True


class TokenBucket:
    """Token bucket for rate limiting"""
    
    def __init__(self, max_tokens: float, refill_rate: float):
        self.tokens = max_tokens
        self.max_tokens = max_tokens
        self.refill_rate = refill_rate
        self.last_update = time.time()
        self.lock = threading.Lock()
    
    def _refill(self) -> None:
        now = time.time()
        elapsed = now - self.last_update
        tokens_to_add = elapsed * self.refill_rate
        self.tokens = min(self.max_tokens, self.tokens + tokens_to_add)
        self.last_update = now
    
    def try_consume(self, count: float = 1.0) -> bool:
        with self.lock:
            self._refill()
            if self.tokens >= count:
                self.tokens -= count
                return True
            return False
    
    def remaining(self) -> int:
        with self.lock:
            self._refill()
            return int(self.tokens)


@dataclass
class RateLimitResult:
    """Rate limit check result"""
    allowed: bool
    remaining: int
    reset_seconds: int
    retry_after: Optional[int] = None


class RateLimiter:
    """Rate limiter with per-key tracking"""
    
    def __init__(self, config: RateLimitConfig = None):
        self.config = config or RateLimitConfig()
        self.buckets: Dict[str, TokenBucket] = {}
        self.lock = threading.Lock()
        self.cleanup_interval = 300  # 5 minutes
        self.last_cleanup = time.time()
    
    def _get_bucket(self, key: str) -> TokenBucket:
        with self.lock:
            if key not in self.buckets:
                max_tokens = self.config.requests_per_window + self.config.burst_size
                refill_rate = self.config.requests_per_window / self.config.window_seconds
                self.buckets[key] = TokenBucket(max_tokens, refill_rate)
            return self.buckets[key]
    
    def check_limit(self, key: str) -> RateLimitResult:
        """Check if request should be allowed"""
        self._maybe_cleanup()
        bucket = self._get_bucket(key)
        
        if bucket.try_consume(1):
            return RateLimitResult(
                allowed=True,
                remaining=bucket.remaining(),
                reset_seconds=self.config.window_seconds
            )
        else:
            refill_rate = self.config.requests_per_window / self.config.window_seconds
            return RateLimitResult(
                allowed=False,
                remaining=0,
                reset_seconds=self.config.window_seconds,
                retry_after=int(1 / refill_rate) + 1
            )
    
    def check_ip_limit(self, ip: str) -> RateLimitResult:
        """Check rate limit by IP"""
        if not self.config.per_ip:
            return RateLimitResult(allowed=True, remaining=999, reset_seconds=0)
        return self.check_limit(f"ip:{ip}")
    
    def check_user_limit(self, user_id: str) -> RateLimitResult:
        """Check rate limit by user"""
        if not self.config.per_user:
            return RateLimitResult(allowed=True, remaining=999, reset_seconds=0)
        return self.check_limit(f"user:{user_id}")
    
    def _maybe_cleanup(self) -> None:
        """Cleanup old buckets"""
        now = time.time()
        if now - self.last_cleanup > self.cleanup_interval:
            with self.lock:
                # Remove buckets not used in cleanup_interval
                stale = [k for k, v in self.buckets.items() 
                         if now - v.last_update > self.cleanup_interval]
                for key in stale:
                    del self.buckets[key]
                self.last_cleanup = now


# ============================================================================
# Security Headers
# ============================================================================

@dataclass
class SecurityHeadersConfig:
    """Security headers configuration"""
    enable_hsts: bool = True
    hsts_max_age: int = 31536000
    hsts_include_subdomains: bool = True
    frame_options: str = "DENY"
    content_type_nosniff: bool = True
    xss_protection: bool = True
    referrer_policy: str = "strict-origin-when-cross-origin"
    csp_enabled: bool = True
    cache_control: str = "no-store, no-cache, must-revalidate"


def get_security_headers(config: SecurityHeadersConfig = None) -> Dict[str, str]:
    """Generate security headers dictionary"""
    config = config or SecurityHeadersConfig()
    headers = {}
    
    # HSTS
    if config.enable_hsts:
        hsts_value = f"max-age={config.hsts_max_age}"
        if config.hsts_include_subdomains:
            hsts_value += "; includeSubDomains"
        headers["Strict-Transport-Security"] = hsts_value
    
    # X-Frame-Options
    if config.frame_options:
        headers["X-Frame-Options"] = config.frame_options
    
    # X-Content-Type-Options
    if config.content_type_nosniff:
        headers["X-Content-Type-Options"] = "nosniff"
    
    # X-XSS-Protection
    if config.xss_protection:
        headers["X-XSS-Protection"] = "1; mode=block"
    
    # Referrer-Policy
    headers["Referrer-Policy"] = config.referrer_policy
    
    # Content-Security-Policy
    if config.csp_enabled:
        headers["Content-Security-Policy"] = (
            "default-src 'none'; "
            "script-src 'none'; "
            "style-src 'none'; "
            "img-src 'none'; "
            "connect-src 'self'; "
            "frame-ancestors 'none'; "
            "base-uri 'none'; "
            "form-action 'none'"
        )
    
    # Cache-Control
    if config.cache_control:
        headers["Cache-Control"] = config.cache_control
    
    # Additional headers
    headers["X-DNS-Prefetch-Control"] = "off"
    headers["X-Download-Options"] = "noopen"
    headers["X-Permitted-Cross-Domain-Policies"] = "none"
    headers["Cross-Origin-Embedder-Policy"] = "require-corp"
    headers["Cross-Origin-Opener-Policy"] = "same-origin"
    headers["Cross-Origin-Resource-Policy"] = "same-origin"
    
    return headers


# ============================================================================
# Health Checks
# ============================================================================

@dataclass
class ComponentHealth:
    """Health status for a component"""
    name: str
    status: str  # "healthy", "degraded", "unhealthy"
    latency_ms: Optional[float] = None
    message: Optional[str] = None


@dataclass
class HealthResponse:
    """Health check response"""
    status: str
    version: str
    uptime_seconds: float
    components: list = field(default_factory=list)


class HealthService:
    """Health check service"""
    
    def __init__(self, version: str = "1.0.0"):
        self.version = version
        self.start_time = time.time()
        self.checkers: Dict[str, Callable[[], ComponentHealth]] = {}
    
    def register_checker(self, name: str, checker: Callable[[], ComponentHealth]) -> None:
        """Register a health checker"""
        self.checkers[name] = checker
    
    def liveness(self) -> HealthResponse:
        """Liveness probe - is the service running?"""
        return HealthResponse(
            status="healthy",
            version=self.version,
            uptime_seconds=time.time() - self.start_time
        )
    
    def readiness(self) -> HealthResponse:
        """Readiness probe - is the service ready to accept traffic?"""
        components = []
        overall_status = "healthy"
        
        for name, checker in self.checkers.items():
            try:
                start = time.time()
                health = checker()
                health.latency_ms = (time.time() - start) * 1000
                components.append(health)
                
                if health.status == "unhealthy":
                    overall_status = "unhealthy"
                elif health.status == "degraded" and overall_status == "healthy":
                    overall_status = "degraded"
            except Exception as e:
                components.append(ComponentHealth(
                    name=name,
                    status="unhealthy",
                    message=str(e)
                ))
                overall_status = "unhealthy"
        
        return HealthResponse(
            status=overall_status,
            version=self.version,
            uptime_seconds=time.time() - self.start_time,
            components=components
        )
    
    def to_dict(self, response: HealthResponse) -> dict:
        """Convert health response to dictionary"""
        return {
            "status": response.status,
            "version": response.version,
            "uptime_seconds": round(response.uptime_seconds, 2),
            "components": [
                {
                    "name": c.name,
                    "status": c.status,
                    "latency_ms": round(c.latency_ms, 2) if c.latency_ms else None,
                    "message": c.message
                }
                for c in response.components
            ]
        }


# ============================================================================
# Input Validation
# ============================================================================

class InputValidator:
    """Input validation utilities"""
    
    @staticmethod
    def sanitize_string(value: str, max_length: int = 1000) -> str:
        """Sanitize string input"""
        if not isinstance(value, str):
            raise ValueError("Expected string input")
        # Truncate to max length
        value = value[:max_length]
        # Remove null bytes
        value = value.replace('\x00', '')
        return value
    
    @staticmethod
    def validate_email(email: str) -> bool:
        """Basic email validation"""
        import re
        pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        return bool(re.match(pattern, email))
    
    @staticmethod
    def validate_uuid(value: str) -> bool:
        """Validate UUID format"""
        import re
        pattern = r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        return bool(re.match(pattern, value.lower()))
    
    @staticmethod
    def escape_html(value: str) -> str:
        """Escape HTML special characters"""
        return (value
                .replace('&', '&amp;')
                .replace('<', '&lt;')
                .replace('>', '&gt;')
                .replace('"', '&quot;')
                .replace("'", '&#x27;'))


# ============================================================================
# Decorators
# ============================================================================

def rate_limited(limiter: RateLimiter, key_func: Callable = None):
    """Decorator for rate limiting"""
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            # Get key from function or use default
            if key_func:
                key = key_func(*args, **kwargs)
            else:
                key = func.__name__
            
            result = limiter.check_limit(key)
            if not result.allowed:
                raise RateLimitExceeded(
                    f"Rate limit exceeded. Retry after {result.retry_after} seconds."
                )
            return func(*args, **kwargs)
        return wrapper
    return decorator


class RateLimitExceeded(Exception):
    """Exception raised when rate limit is exceeded"""
    pass


# ============================================================================
# Tests
# ============================================================================

def _test_rate_limiter():
    """Test rate limiter"""
    limiter = RateLimiter(RateLimitConfig(
        requests_per_window=5,
        window_seconds=60,
        burst_size=0
    ))
    
    # First 5 should pass
    for i in range(5):
        result = limiter.check_limit("test")
        assert result.allowed, f"Request {i+1} should be allowed"
    
    # 6th should be blocked
    result = limiter.check_limit("test")
    assert not result.allowed, "6th request should be blocked"
    assert result.retry_after is not None
    
    print("✓ Rate limiter tests passed")


def _test_security_headers():
    """Test security headers"""
    headers = get_security_headers()
    
    assert "X-Frame-Options" in headers
    assert headers["X-Frame-Options"] == "DENY"
    assert "X-Content-Type-Options" in headers
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert "Strict-Transport-Security" in headers
    
    print("✓ Security headers tests passed")


def _test_health_service():
    """Test health service"""
    health = HealthService(version="2.0.0")
    
    # Liveness
    response = health.liveness()
    assert response.status == "healthy"
    assert response.version == "2.0.0"
    
    # Readiness with no checkers
    response = health.readiness()
    assert response.status == "healthy"
    
    # Add a checker
    health.register_checker("db", lambda: ComponentHealth(name="db", status="healthy"))
    response = health.readiness()
    assert len(response.components) == 1
    
    print("✓ Health service tests passed")


if __name__ == "__main__":
    _test_rate_limiter()
    _test_security_headers()
    _test_health_service()
    print("\nAll tests passed! ✅")