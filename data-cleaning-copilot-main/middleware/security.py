"""
Security Middleware for Data Cleaning Copilot

Provides:
- Rate limiting (token bucket)
- Security headers (OWASP recommended)
- Input validation (critical for data cleaning)
- Health checks
"""

import time
import threading
import re
from typing import Dict, Optional, Callable, Any, List
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
        self.cleanup_interval = 300
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
        if not self.config.per_ip:
            return RateLimitResult(allowed=True, remaining=999, reset_seconds=0)
        return self.check_limit(f"ip:{ip}")
    
    def check_user_limit(self, user_id: str) -> RateLimitResult:
        if not self.config.per_user:
            return RateLimitResult(allowed=True, remaining=999, reset_seconds=0)
        return self.check_limit(f"user:{user_id}")


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
    
    if config.enable_hsts:
        hsts_value = f"max-age={config.hsts_max_age}"
        if config.hsts_include_subdomains:
            hsts_value += "; includeSubDomains"
        headers["Strict-Transport-Security"] = hsts_value
    
    if config.frame_options:
        headers["X-Frame-Options"] = config.frame_options
    
    if config.content_type_nosniff:
        headers["X-Content-Type-Options"] = "nosniff"
    
    if config.xss_protection:
        headers["X-XSS-Protection"] = "1; mode=block"
    
    headers["Referrer-Policy"] = config.referrer_policy
    
    if config.csp_enabled:
        headers["Content-Security-Policy"] = (
            "default-src 'none'; "
            "script-src 'none'; "
            "connect-src 'self'; "
            "frame-ancestors 'none'"
        )
    
    if config.cache_control:
        headers["Cache-Control"] = config.cache_control
    
    headers["X-DNS-Prefetch-Control"] = "off"
    headers["Cross-Origin-Embedder-Policy"] = "require-corp"
    headers["Cross-Origin-Opener-Policy"] = "same-origin"
    headers["Cross-Origin-Resource-Policy"] = "same-origin"
    
    return headers


# ============================================================================
# Data Validation (Critical for Data Cleaning)
# ============================================================================

class DataValidator:
    """
    Input validation specifically designed for data cleaning operations.
    Prevents injection attacks and malformed data from entering pipelines.
    """
    
    # Maximum sizes to prevent DoS
    MAX_STRING_LENGTH = 10000
    MAX_ARRAY_SIZE = 10000
    MAX_OBJECT_DEPTH = 10
    
    @staticmethod
    def sanitize_string(value: str, max_length: int = None) -> str:
        """Sanitize string input"""
        if not isinstance(value, str):
            raise ValueError("Expected string input")
        max_len = max_length or DataValidator.MAX_STRING_LENGTH
        value = value[:max_len]
        value = value.replace('\x00', '')  # Remove null bytes
        return value
    
    @staticmethod
    def validate_column_name(name: str) -> bool:
        """Validate column name (prevent SQL injection)"""
        # Only allow alphanumeric, underscore, and limited special chars
        pattern = r'^[a-zA-Z_][a-zA-Z0-9_]*$'
        return bool(re.match(pattern, name)) and len(name) <= 128
    
    @staticmethod
    def validate_table_name(name: str) -> bool:
        """Validate table name (prevent SQL injection)"""
        # Schema.table format allowed
        pattern = r'^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?$'
        return bool(re.match(pattern, name)) and len(name) <= 256
    
    @staticmethod
    def sanitize_sql_identifier(identifier: str) -> str:
        """Sanitize SQL identifier by quoting"""
        # Remove any quotes first
        clean = identifier.replace('"', '').replace("'", '')
        # Validate it's a valid identifier
        if not DataValidator.validate_column_name(clean):
            raise ValueError(f"Invalid SQL identifier: {identifier}")
        return f'"{clean}"'
    
    @staticmethod
    def validate_data_type(value: Any, expected_type: str) -> bool:
        """Validate data matches expected type"""
        type_checks = {
            'string': lambda x: isinstance(x, str),
            'integer': lambda x: isinstance(x, int) and not isinstance(x, bool),
            'float': lambda x: isinstance(x, (int, float)) and not isinstance(x, bool),
            'boolean': lambda x: isinstance(x, bool),
            'array': lambda x: isinstance(x, list),
            'object': lambda x: isinstance(x, dict),
            'null': lambda x: x is None,
        }
        checker = type_checks.get(expected_type.lower())
        if not checker:
            return False
        return checker(value)
    
    @staticmethod
    def validate_email(email: str) -> bool:
        """Validate email format"""
        pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        return bool(re.match(pattern, email)) and len(email) <= 254
    
    @staticmethod
    def validate_url(url: str) -> bool:
        """Validate URL format"""
        pattern = r'^https?://[a-zA-Z0-9.-]+(/[^\s]*)?$'
        return bool(re.match(pattern, url)) and len(url) <= 2048
    
    @staticmethod
    def escape_html(value: str) -> str:
        """Escape HTML special characters"""
        return (value
                .replace('&', '&amp;')
                .replace('<', '&lt;')
                .replace('>', '&gt;')
                .replace('"', '&quot;')
                .replace("'", '&#x27;'))
    
    @staticmethod
    def validate_json_depth(obj: Any, max_depth: int = None, current_depth: int = 0) -> bool:
        """Check JSON object depth (prevent stack overflow)"""
        max_d = max_depth or DataValidator.MAX_OBJECT_DEPTH
        if current_depth > max_d:
            return False
        
        if isinstance(obj, dict):
            return all(
                DataValidator.validate_json_depth(v, max_d, current_depth + 1)
                for v in obj.values()
            )
        elif isinstance(obj, list):
            if len(obj) > DataValidator.MAX_ARRAY_SIZE:
                return False
            return all(
                DataValidator.validate_json_depth(item, max_d, current_depth + 1)
                for item in obj
            )
        return True
    
    @staticmethod
    def sanitize_filename(filename: str) -> str:
        """Sanitize filename (prevent path traversal)"""
        # Remove path separators
        filename = filename.replace('/', '').replace('\\', '')
        filename = filename.replace('..', '')
        # Remove null bytes
        filename = filename.replace('\x00', '')
        # Limit length
        filename = filename[:255]
        # Only allow safe characters
        safe = re.sub(r'[^a-zA-Z0-9._-]', '_', filename)
        return safe


# ============================================================================
# Health Checks
# ============================================================================

@dataclass
class ComponentHealth:
    """Health status for a component"""
    name: str
    status: str
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
        self.checkers[name] = checker
    
    def liveness(self) -> HealthResponse:
        return HealthResponse(
            status="healthy",
            version=self.version,
            uptime_seconds=time.time() - self.start_time
        )
    
    def readiness(self) -> HealthResponse:
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
                    name=name, status="unhealthy", message=str(e)
                ))
                overall_status = "unhealthy"
        
        return HealthResponse(
            status=overall_status,
            version=self.version,
            uptime_seconds=time.time() - self.start_time,
            components=components
        )
    
    def to_dict(self, response: HealthResponse) -> dict:
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
# Decorators
# ============================================================================

def rate_limited(limiter: RateLimiter, key_func: Callable = None):
    """Decorator for rate limiting"""
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            key = key_func(*args, **kwargs) if key_func else func.__name__
            result = limiter.check_limit(key)
            if not result.allowed:
                raise RateLimitExceeded(
                    f"Rate limit exceeded. Retry after {result.retry_after}s"
                )
            return func(*args, **kwargs)
        return wrapper
    return decorator


def validated_input(validator_func: Callable):
    """Decorator for input validation"""
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            validator_func(*args, **kwargs)
            return func(*args, **kwargs)
        return wrapper
    return decorator


class RateLimitExceeded(Exception):
    """Exception raised when rate limit is exceeded"""
    pass


class ValidationError(Exception):
    """Exception raised when validation fails"""
    pass


# ============================================================================
# Tests
# ============================================================================

def _test_data_validator():
    """Test data validator"""
    v = DataValidator()
    
    # Column names
    assert v.validate_column_name("valid_column")
    assert v.validate_column_name("Column123")
    assert not v.validate_column_name("1invalid")
    assert not v.validate_column_name("has space")
    assert not v.validate_column_name("has;semicolon")
    
    # Table names
    assert v.validate_table_name("schema.table")
    assert v.validate_table_name("simple_table")
    assert not v.validate_table_name("../etc/passwd")
    
    # SQL injection prevention
    try:
        v.sanitize_sql_identifier("DROP TABLE users;--")
        assert False, "Should have raised"
    except ValueError:
        pass
    
    # Filename sanitization
    assert v.sanitize_filename("../../../etc/passwd") == "etcpasswd"
    assert v.sanitize_filename("safe_file.csv") == "safe_file.csv"
    
    # JSON depth
    shallow = {"a": {"b": 1}}
    deep = {"a": {"b": {"c": {"d": {"e": {"f": {"g": {"h": {"i": {"j": {"k": 1}}}}}}}}}}}
    assert v.validate_json_depth(shallow)
    assert not v.validate_json_depth(deep)
    
    print("✓ Data validator tests passed")


def _test_rate_limiter():
    """Test rate limiter"""
    limiter = RateLimiter(RateLimitConfig(
        requests_per_window=5,
        window_seconds=60,
        burst_size=0
    ))
    
    for i in range(5):
        result = limiter.check_limit("test")
        assert result.allowed
    
    result = limiter.check_limit("test")
    assert not result.allowed
    
    print("✓ Rate limiter tests passed")


def _test_security_headers():
    """Test security headers"""
    headers = get_security_headers()
    
    assert headers["X-Frame-Options"] == "DENY"
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert "Strict-Transport-Security" in headers
    
    print("✓ Security headers tests passed")


if __name__ == "__main__":
    _test_data_validator()
    _test_rate_limiter()
    _test_security_headers()
    print("\nAll tests passed! ✅")