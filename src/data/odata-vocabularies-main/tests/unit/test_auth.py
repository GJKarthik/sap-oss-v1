"""
Unit Tests for Authentication Middleware

Tests API key, JWT, rate limiting, and OAuth authentication.
"""

import pytest
import time
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from config.settings import AuthConfig
from middleware.auth import AuthMiddleware, RateLimiter, AuthResult


class TestRateLimiter:
    """Tests for rate limiter"""
    
    def test_allows_first_request(self):
        """Test first request is allowed"""
        limiter = RateLimiter(max_requests=10, window_seconds=60)
        allowed, info = limiter.is_allowed("client1")
        
        assert allowed == True
        assert info["remaining"] == 9
    
    def test_tracks_multiple_requests(self):
        """Test tracking multiple requests"""
        limiter = RateLimiter(max_requests=10, window_seconds=60)
        
        for i in range(5):
            allowed, info = limiter.is_allowed("client1")
        
        assert allowed == True
        assert info["remaining"] == 5
    
    def test_blocks_when_limit_exceeded(self):
        """Test blocking when rate limit exceeded"""
        limiter = RateLimiter(max_requests=3, window_seconds=60)
        
        # Use up all requests
        for _ in range(3):
            limiter.is_allowed("client1")
        
        # Fourth request should be blocked
        allowed, info = limiter.is_allowed("client1")
        
        assert allowed == False
        assert info["remaining"] == 0
        assert "retry_after" in info
    
    def test_separate_clients(self):
        """Test separate rate limits per client"""
        limiter = RateLimiter(max_requests=3, window_seconds=60)
        
        # Use up client1's limit
        for _ in range(3):
            limiter.is_allowed("client1")
        
        # client2 should still be allowed
        allowed, _ = limiter.is_allowed("client2")
        
        assert allowed == True
    
    def test_window_reset(self):
        """Test window resets after timeout"""
        limiter = RateLimiter(max_requests=2, window_seconds=1)
        
        # Use up limit
        limiter.is_allowed("client1")
        limiter.is_allowed("client1")
        allowed1, _ = limiter.is_allowed("client1")
        
        assert allowed1 == False
        
        # Wait for window to expire
        time.sleep(1.1)
        
        allowed2, info = limiter.is_allowed("client1")
        
        assert allowed2 == True
        assert info["remaining"] == 1


class TestAuthResult:
    """Tests for AuthResult class"""
    
    def test_success_result(self):
        """Test successful auth result"""
        result = AuthResult(
            success=True,
            user_id="user123",
            role="admin"
        )
        
        assert result.success == True
        assert result.user_id == "user123"
        assert result.role == "admin"
        assert result.error is None
    
    def test_failure_result(self):
        """Test failed auth result"""
        result = AuthResult(
            success=False,
            error="Invalid credentials"
        )
        
        assert result.success == False
        assert result.error == "Invalid credentials"
        assert result.user_id is None
    
    def test_to_dict(self):
        """Test converting to dictionary"""
        result = AuthResult(
            success=True,
            user_id="user123",
            role="admin",
            metadata={"auth_method": "api_key"}
        )
        
        d = result.to_dict()
        
        assert d["success"] == True
        assert d["user_id"] == "user123"
        assert d["role"] == "admin"
        assert d["metadata"]["auth_method"] == "api_key"


class TestAuthMiddleware:
    """Tests for AuthMiddleware"""
    
    def test_disabled_auth_allows_all(self):
        """Test disabled auth allows all requests"""
        config = AuthConfig(enabled=False)
        middleware = AuthMiddleware(config)
        
        result = middleware.authenticate({"headers": {}})
        
        assert result.success == True
        assert result.user_id == "anonymous"
    
    def test_valid_api_key(self):
        """Test valid API key authentication"""
        config = AuthConfig(
            enabled=True,
            api_keys=["valid-api-key"]
        )
        middleware = AuthMiddleware(config)
        
        result = middleware.authenticate({
            "headers": {"X-API-Key": "valid-api-key"}
        })
        
        assert result.success == True
        assert result.metadata.get("auth_method") == "api_key"
    
    def test_invalid_api_key(self):
        """Test invalid API key rejected"""
        config = AuthConfig(
            enabled=True,
            api_keys=["valid-api-key"]
        )
        middleware = AuthMiddleware(config)
        
        result = middleware.authenticate({
            "headers": {"X-API-Key": "wrong-key"}
        })
        
        assert result.success == False
        assert "Invalid" in result.error
    
    def test_api_key_from_authorization_header(self):
        """Test API key from Authorization header"""
        config = AuthConfig(
            enabled=True,
            api_keys=["my-api-key"]
        )
        middleware = AuthMiddleware(config)
        
        result = middleware.authenticate({
            "headers": {"Authorization": "ApiKey my-api-key"}
        })
        
        assert result.success == True
    
    def test_no_credentials_fails(self):
        """Test request without credentials fails"""
        config = AuthConfig(enabled=True, api_keys=["key"])
        middleware = AuthMiddleware(config)
        
        result = middleware.authenticate({"headers": {}})
        
        assert result.success == False
        assert "No valid authentication" in result.error
    
    def test_rate_limit_check(self):
        """Test rate limit checking"""
        config = AuthConfig(
            enabled=False,
            rate_limit_enabled=True,
            rate_limit_requests=3,
            rate_limit_window_seconds=60
        )
        middleware = AuthMiddleware(config)
        
        # First 3 should pass
        for _ in range(3):
            allowed, _ = middleware.check_rate_limit("test-client")
            assert allowed == True
        
        # Fourth should fail
        allowed, info = middleware.check_rate_limit("test-client")
        assert allowed == False
    
    def test_rate_limit_disabled(self):
        """Test rate limiting can be disabled"""
        config = AuthConfig(
            enabled=False,
            rate_limit_enabled=False
        )
        middleware = AuthMiddleware(config)
        
        # Should always pass when disabled
        for _ in range(100):
            allowed, _ = middleware.check_rate_limit("test-client")
            assert allowed == True


class TestJWTAuthentication:
    """Tests for JWT authentication"""
    
    def test_jwt_generation(self):
        """Test JWT token generation"""
        config = AuthConfig(
            enabled=True,
            jwt_secret="test-secret-at-least-32-characters-long",
            jwt_algorithm="HS256",
            jwt_expiry_hours=24
        )
        middleware = AuthMiddleware(config)
        
        # Skip if PyJWT not available
        if not middleware._jwt_available:
            pytest.skip("PyJWT not installed")
        
        token = middleware.generate_jwt("user123", "admin")
        
        assert token is not None
        assert len(token) > 0
        assert token.count(".") == 2  # JWT has 3 parts
    
    def test_jwt_authentication_valid(self):
        """Test valid JWT authentication"""
        config = AuthConfig(
            enabled=True,
            jwt_secret="test-secret-at-least-32-characters-long",
            jwt_algorithm="HS256"
        )
        middleware = AuthMiddleware(config)
        
        if not middleware._jwt_available:
            pytest.skip("PyJWT not installed")
        
        # Generate a valid token
        token = middleware.generate_jwt("user123", "admin")
        
        # Authenticate with it
        result = middleware.authenticate({
            "headers": {"Authorization": f"Bearer {token}"}
        })
        
        assert result.success == True
        assert result.user_id == "user123"
        assert result.role == "admin"
    
    def test_jwt_without_secret_fails(self):
        """Test JWT fails without configured secret"""
        config = AuthConfig(
            enabled=True,
            jwt_secret=""  # No secret
        )
        middleware = AuthMiddleware(config)
        
        if not middleware._jwt_available:
            pytest.skip("PyJWT not installed")
        
        result = middleware.authenticate({
            "headers": {"Authorization": "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJ0ZXN0IjoidGVzdCJ9.test"}
        })
        
        assert result.success == False