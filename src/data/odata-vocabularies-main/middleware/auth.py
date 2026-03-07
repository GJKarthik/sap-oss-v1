"""
Authentication Middleware for OData Vocabularies MCP Server

Production-ready authentication with API keys, JWT, and rate limiting.
"""

import logging
import time
import hashlib
from typing import Any, Callable, Dict, List, Optional, Tuple
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from functools import wraps
import threading
import json

logger = logging.getLogger(__name__)


@dataclass
class RateLimitEntry:
    """Rate limit tracking for a client"""
    request_count: int = 0
    window_start: float = 0.0


class RateLimiter:
    """
    Token bucket rate limiter.
    
    Features:
    - Per-client rate limiting
    - Sliding window algorithm
    - Thread-safe
    """
    
    def __init__(self, max_requests: int = 100, window_seconds: int = 60):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._clients: Dict[str, RateLimitEntry] = {}
        self._lock = threading.Lock()
    
    def is_allowed(self, client_id: str) -> Tuple[bool, Dict]:
        """
        Check if request is allowed for client.
        
        Args:
            client_id: Client identifier (API key, IP, etc.)
            
        Returns:
            Tuple of (allowed, info dict)
        """
        current_time = time.time()
        
        with self._lock:
            if client_id not in self._clients:
                self._clients[client_id] = RateLimitEntry(
                    request_count=1,
                    window_start=current_time
                )
                return True, {
                    "remaining": self.max_requests - 1,
                    "reset_at": current_time + self.window_seconds
                }
            
            entry = self._clients[client_id]
            
            # Check if window has expired
            if current_time - entry.window_start >= self.window_seconds:
                entry.request_count = 1
                entry.window_start = current_time
                return True, {
                    "remaining": self.max_requests - 1,
                    "reset_at": current_time + self.window_seconds
                }
            
            # Check if within limit
            if entry.request_count < self.max_requests:
                entry.request_count += 1
                return True, {
                    "remaining": self.max_requests - entry.request_count,
                    "reset_at": entry.window_start + self.window_seconds
                }
            
            # Rate limited
            return False, {
                "remaining": 0,
                "reset_at": entry.window_start + self.window_seconds,
                "retry_after": int(entry.window_start + self.window_seconds - current_time)
            }


class AuthResult:
    """Authentication result"""
    
    def __init__(self, success: bool, user_id: str = None, role: str = None, 
                 error: str = None, metadata: Dict = None):
        self.success = success
        self.user_id = user_id
        self.role = role
        self.error = error
        self.metadata = metadata or {}
    
    def to_dict(self) -> Dict:
        return {
            "success": self.success,
            "user_id": self.user_id,
            "role": self.role,
            "error": self.error,
            "metadata": self.metadata
        }


class AuthMiddleware:
    """
    Authentication middleware with multiple strategies.
    
    Supports:
    - API Key authentication
    - JWT authentication
    - OAuth 2.0 token validation
    - Rate limiting per client
    """
    
    def __init__(self, config: "AuthConfig"):
        """
        Initialize auth middleware.
        
        Args:
            config: AuthConfig from settings
        """
        self.config = config
        self.rate_limiter = RateLimiter(
            max_requests=config.rate_limit_requests,
            window_seconds=config.rate_limit_window_seconds
        )
        self._jwt_available = False
        
        # Try to import JWT library
        try:
            import jwt
            self._jwt = jwt
            self._jwt_available = True
        except ImportError:
            logger.warning("PyJWT not installed - JWT auth disabled")
    
    def authenticate(self, request: Dict) -> AuthResult:
        """
        Authenticate a request.
        
        Args:
            request: Request dict with headers, method, etc.
            
        Returns:
            AuthResult with success/failure info
        """
        if not self.config.enabled:
            return AuthResult(
                success=True,
                user_id="anonymous",
                role="user",
                metadata={"auth_method": "disabled"}
            )
        
        headers = request.get("headers", {})
        
        # Try API Key auth first
        api_key = self._extract_api_key(headers)
        if api_key:
            return self._authenticate_api_key(api_key)
        
        # Try JWT auth
        jwt_token = self._extract_jwt(headers)
        if jwt_token:
            return self._authenticate_jwt(jwt_token)
        
        # Try OAuth bearer token
        bearer_token = self._extract_bearer_token(headers)
        if bearer_token:
            return self._authenticate_oauth(bearer_token)
        
        return AuthResult(
            success=False,
            error="No valid authentication credentials provided"
        )
    
    def _extract_api_key(self, headers: Dict) -> Optional[str]:
        """Extract API key from headers"""
        # X-API-Key header
        api_key = headers.get("X-API-Key") or headers.get("x-api-key")
        if api_key:
            return api_key
        
        # Authorization: ApiKey xxx
        auth_header = headers.get("Authorization") or headers.get("authorization")
        if auth_header and auth_header.lower().startswith("apikey "):
            return auth_header[7:]
        
        return None
    
    def _extract_jwt(self, headers: Dict) -> Optional[str]:
        """Extract JWT from headers"""
        auth_header = headers.get("Authorization") or headers.get("authorization")
        if auth_header and auth_header.lower().startswith("bearer "):
            token = auth_header[7:]
            # Check if it looks like a JWT (has 3 parts)
            if token.count(".") == 2:
                return token
        return None
    
    def _extract_bearer_token(self, headers: Dict) -> Optional[str]:
        """Extract OAuth bearer token"""
        auth_header = headers.get("Authorization") or headers.get("authorization")
        if auth_header and auth_header.lower().startswith("bearer "):
            return auth_header[7:]
        return None
    
    def _authenticate_api_key(self, api_key: str) -> AuthResult:
        """Authenticate using API key"""
        # Hash the provided key for comparison
        key_hash = hashlib.sha256(api_key.encode()).hexdigest()
        
        # Check against configured keys
        for i, configured_key in enumerate(self.config.api_keys):
            # Support both plain and hashed keys
            if configured_key == api_key or configured_key == key_hash:
                return AuthResult(
                    success=True,
                    user_id=f"api_key_{i}",
                    role="api_user",
                    metadata={"auth_method": "api_key"}
                )
        
        return AuthResult(
            success=False,
            error="Invalid API key"
        )
    
    def _authenticate_jwt(self, token: str) -> AuthResult:
        """Authenticate using JWT"""
        if not self._jwt_available:
            return AuthResult(
                success=False,
                error="JWT authentication not available"
            )
        
        if not self.config.jwt_secret:
            return AuthResult(
                success=False,
                error="JWT secret not configured"
            )
        
        try:
            payload = self._jwt.decode(
                token,
                self.config.jwt_secret,
                algorithms=[self.config.jwt_algorithm]
            )
            
            return AuthResult(
                success=True,
                user_id=payload.get("sub") or payload.get("user_id"),
                role=payload.get("role", "user"),
                metadata={
                    "auth_method": "jwt",
                    "exp": payload.get("exp"),
                    "iat": payload.get("iat")
                }
            )
            
        except self._jwt.ExpiredSignatureError:
            return AuthResult(success=False, error="JWT token expired")
        except self._jwt.InvalidTokenError as e:
            return AuthResult(success=False, error=f"Invalid JWT: {str(e)}")
    
    def _authenticate_oauth(self, token: str) -> AuthResult:
        """Authenticate using OAuth token"""
        if not self.config.oauth_token_url:
            return AuthResult(
                success=False,
                error="OAuth not configured"
            )
        
        try:
            import requests
            
            # Introspect token
            response = requests.post(
                self.config.oauth_token_url.replace("/token", "/introspect"),
                data={"token": token},
                auth=(self.config.oauth_client_id, self.config.oauth_client_secret),
                timeout=10
            )
            
            if response.status_code == 200:
                data = response.json()
                if data.get("active"):
                    return AuthResult(
                        success=True,
                        user_id=data.get("sub") or data.get("username"),
                        role=data.get("scope", "user"),
                        metadata={
                            "auth_method": "oauth",
                            "client_id": data.get("client_id"),
                            "exp": data.get("exp")
                        }
                    )
            
            return AuthResult(success=False, error="Invalid OAuth token")
            
        except Exception as e:
            return AuthResult(success=False, error=f"OAuth validation failed: {str(e)}")
    
    def check_rate_limit(self, client_id: str) -> Tuple[bool, Dict]:
        """
        Check rate limit for client.
        
        Args:
            client_id: Client identifier
            
        Returns:
            Tuple of (allowed, info)
        """
        if not self.config.rate_limit_enabled:
            return True, {"rate_limiting": "disabled"}
        
        return self.rate_limiter.is_allowed(client_id)
    
    def generate_jwt(self, user_id: str, role: str = "user", 
                     extra_claims: Dict = None) -> Optional[str]:
        """
        Generate a JWT token.
        
        Args:
            user_id: User identifier
            role: User role
            extra_claims: Additional JWT claims
            
        Returns:
            JWT token string
        """
        if not self._jwt_available or not self.config.jwt_secret:
            return None
        
        now = datetime.utcnow()
        payload = {
            "sub": user_id,
            "role": role,
            "iat": now,
            "exp": now + timedelta(hours=self.config.jwt_expiry_hours)
        }
        
        if extra_claims:
            payload.update(extra_claims)
        
        return self._jwt.encode(
            payload,
            self.config.jwt_secret,
            algorithm=self.config.jwt_algorithm
        )


def require_auth(middleware: AuthMiddleware):
    """
    Decorator for requiring authentication on MCP tool handlers.
    
    Args:
        middleware: AuthMiddleware instance
    """
    def decorator(func: Callable):
        @wraps(func)
        def wrapper(arguments: Dict, *args, **kwargs):
            # Extract request context
            request_context = arguments.get("_request_context", {})
            
            # Authenticate
            auth_result = middleware.authenticate(request_context)
            if not auth_result.success:
                return {
                    "error": "Authentication failed",
                    "details": auth_result.error
                }
            
            # Check rate limit
            client_id = auth_result.user_id or request_context.get("client_ip", "unknown")
            allowed, rate_info = middleware.check_rate_limit(client_id)
            if not allowed:
                return {
                    "error": "Rate limit exceeded",
                    "retry_after": rate_info.get("retry_after")
                }
            
            # Add auth context to arguments
            arguments["_auth"] = auth_result.to_dict()
            
            return func(arguments, *args, **kwargs)
        
        return wrapper
    return decorator


# Singleton instance
_middleware: Optional[AuthMiddleware] = None


def get_auth_middleware(config: "AuthConfig" = None) -> AuthMiddleware:
    """Get or create the AuthMiddleware singleton"""
    global _middleware
    if _middleware is None:
        if config is None:
            from config.settings import get_settings
            config = get_settings().auth
        _middleware = AuthMiddleware(config)
    return _middleware