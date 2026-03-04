#!/usr/bin/env python3
"""
API Authentication Module
Validates Bearer tokens and API keys
"""

import os
import secrets
import hashlib
import logging
from datetime import datetime, timedelta
from typing import Optional, Dict
from functools import wraps

from fastapi import HTTPException, Header, Depends, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

logger = logging.getLogger(__name__)

# Security configuration
VALID_API_KEYS: Dict[str, dict] = {}  # In production, use database/vault
DEFAULT_API_KEY = os.getenv("MODELOPT_API_KEY", "")
REQUIRE_AUTH = os.getenv("MODELOPT_REQUIRE_AUTH", "false").lower() == "true"

security = HTTPBearer(auto_error=False)


def generate_api_key(name: str = "default") -> str:
    """Generate a new API key"""
    key = f"mo-{secrets.token_hex(24)}"
    key_hash = hashlib.sha256(key.encode()).hexdigest()
    VALID_API_KEYS[key_hash] = {
        "name": name,
        "created_at": datetime.utcnow().isoformat(),
        "last_used": None,
    }
    return key


def validate_api_key(api_key: str) -> bool:
    """Validate an API key"""
    if not api_key:
        return False
    
    # Check against default key
    if DEFAULT_API_KEY and api_key == DEFAULT_API_KEY:
        return True
    
    # Check against registered keys
    key_hash = hashlib.sha256(api_key.encode()).hexdigest()
    if key_hash in VALID_API_KEYS:
        VALID_API_KEYS[key_hash]["last_used"] = datetime.utcnow().isoformat()
        return True
    
    return False


def extract_token(authorization: str) -> Optional[str]:
    """Extract token from Authorization header"""
    if not authorization:
        return None
    
    if authorization.startswith("Bearer "):
        return authorization[7:]
    
    return authorization


async def verify_auth(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security),
    authorization: Optional[str] = Header(None),
) -> Optional[str]:
    """
    Dependency to verify authentication
    Returns the API key if valid, None if auth not required
    """
    # Get token from credentials or header
    token = None
    if credentials:
        token = credentials.credentials
    elif authorization:
        token = extract_token(authorization)
    
    # If auth not required and no token, allow access
    if not REQUIRE_AUTH and not token:
        return None
    
    # If auth required, validate token
    if REQUIRE_AUTH:
        if not token:
            raise HTTPException(
                status_code=401,
                detail={
                    "error": {
                        "message": "Missing authentication credentials",
                        "type": "authentication_error",
                        "param": None,
                        "code": "missing_token"
                    }
                }
            )
        
        if not validate_api_key(token):
            raise HTTPException(
                status_code=401,
                detail={
                    "error": {
                        "message": "Invalid API key provided",
                        "type": "authentication_error",
                        "param": None,
                        "code": "invalid_api_key"
                    }
                }
            )
    
    # If token provided but auth not required, still validate
    if token and not validate_api_key(token):
        logger.warning(f"Invalid API key attempted: {token[:10]}...")
    
    return token


class RateLimiter:
    """Simple in-memory rate limiter"""
    
    def __init__(self, requests_per_minute: int = 60):
        self.requests_per_minute = requests_per_minute
        self.requests: Dict[str, list] = {}
    
    def is_allowed(self, client_id: str) -> bool:
        """Check if request is allowed"""
        now = datetime.utcnow()
        window_start = now - timedelta(minutes=1)
        
        # Get or create request list for client
        if client_id not in self.requests:
            self.requests[client_id] = []
        
        # Remove old requests
        self.requests[client_id] = [
            t for t in self.requests[client_id] 
            if t > window_start
        ]
        
        # Check limit
        if len(self.requests[client_id]) >= self.requests_per_minute:
            return False
        
        # Record request
        self.requests[client_id].append(now)
        return True


rate_limiter = RateLimiter()


async def check_rate_limit(request: Request):
    """Dependency to check rate limit"""
    client_ip = request.client.host if request.client else "unknown"
    
    if not rate_limiter.is_allowed(client_ip):
        raise HTTPException(
            status_code=429,
            detail={
                "error": {
                    "message": "Rate limit exceeded. Please try again later.",
                    "type": "rate_limit_error",
                    "param": None,
                    "code": "rate_limit_exceeded"
                }
            }
        )


# Initialize with default key if set
if DEFAULT_API_KEY:
    logger.info("Default API key configured")
else:
    logger.info("No API key required (MODELOPT_REQUIRE_AUTH=false)")